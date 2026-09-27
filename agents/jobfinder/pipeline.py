"""Hourly pipeline: Profile → Scout → for each queued job: Salary → Scorer → Tailor → Coach → Writer.

Usage:  python -m jobfinder.pipeline [--trigger manual] [--all-sources] [--skip-scout] [--job JF-...]
Each job resumes from its last completed stage, so a run cut short by the LLM budget loses nothing.
"""
from __future__ import annotations

import argparse
import json
import logging
import sys

from . import config, db, llm
from .agents import coach, profile as profile_agent, salary, scorer, scout, tailor, writer

log = logging.getLogger("jobfinder")


def process(run: db.PipelineRun, job: dict, profile: dict, brief: str, settings: dict) -> None:
    jid = job["job_id"]
    if job["status"] == "new":
        salary.run(run, job)
        report = scorer.run(run, job, profile)
    else:
        report = json.loads(db.download(job["files"]["report_json"]))

    if job["status"] == "scored":
        tailor.run(run, job, profile, report, settings["target_ats"])

    files = job.get("files") or {}
    if "interview" not in files:
        coach.run(run, job, brief, report)
    if "cover_letter_docx" not in job.get("files", {}):
        writer.run(run, job, profile, brief)

    db.update_job(jid, {"status": "ready", "error": None})
    run.processed += 1
    run.note(f"{jid} ready: {job['title']} @ {job['company']} (ATS {job.get('ats_score')}→{job.get('tailored_ats_score')})")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trigger", default="schedule")
    ap.add_argument("--all-sources", action="store_true", help="ignore per-source hourly throttles (except JSearch)")
    ap.add_argument("--skip-scout", action="store_true")
    ap.add_argument("--job", help="(re)process a single job id")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    db.expire_stale_agent_runs()
    run = db.PipelineRun(args.trigger)
    status = "success"
    try:
        settings = db.get_settings()
        profile = profile_agent.run(run)
        brief = profile_agent.brief(profile)

        if not args.skip_scout and not args.job:
            with run.agent("scout", message="Scout orchestration") as task:
                stored = scout.run(run, settings, profile, brief, force_all=args.all_sources or args.trigger == "manual")
                task.message = f"Scanned {run.scanned}, stored {stored} relevant new jobs"
            run.save()

        if args.job:
            queue = db.sb.table("jobs").select("*").eq("job_id", args.job).execute().data
            for j in queue:  # full reprocess
                j.update(status="new", files={}, attempts=0)
        else:
            queue = db.queued_jobs(settings["max_jobs_per_run"])
        run.note(f"Processing {len(queue)} job(s)")

        for job in queue:
            try:
                process(run, job, profile, brief, settings)
            except llm.BudgetExceeded as exc:
                run.note(f"Stopping: {exc}. Remaining jobs continue next run.")
                break
            except Exception as exc:
                attempts = int(job.get("attempts") or 0) + 1
                values = {"attempts": attempts, "error": str(exc)[:2000]}
                if attempts >= config.MAX_ATTEMPTS:
                    values["status"] = "error"
                db.update_job(job["job_id"], values)
            run.save()
    except llm.BudgetExceeded as exc:
        run.note(f"Stopping: {exc}")
    except Exception as exc:
        status = "error"
        run.errors += 1
        run.note(f"Pipeline failed: {exc}")
        log.exception("pipeline failed")
    finally:
        run.note(f"Done. LLM calls used: {llm.calls_made}")
        run.save(status)
    return 0 if status == "success" else 1


if __name__ == "__main__":
    sys.exit(main())
