"""Hourly pipeline, run for every enabled user in turn:
Profile → Scout → for each queued job: Salary → Scorer → Tailor → Coach → Writer.

Each user gets their own API-key pool (their keys first, then the shared keys if their account allows it)
and their own Gemini call budget, so one user can't use up another's limits.

Usage:  python -m jobfinder.pipeline [--trigger manual] [--all-sources] [--skip-scout] [--user EMAIL] [--job JF-...]
Each job resumes from its last completed stage, so a run cut short by a budget or limit loses nothing.
"""
from __future__ import annotations

import argparse
import json
import logging
import sys

from . import config, db, llm
from .agents import coach, profile as profile_agent, salary, scorer, scout, tailor, writer
from .keys import KeyStateStore, build_pools

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


def run_user(account: dict, args, store: KeyStateStore, only_job: dict | None) -> bool:
    uid = account["user_id"]
    run = db.PipelineRun(args.trigger, uid)
    run.note(f"User {db.user_label(uid)}")
    status = "success"
    pools = build_pools(account, db.user_api_keys(uid), store)
    llm.activate(pools["gemini"], int(account.get("llm_calls_per_run") or 40))
    try:
        if not pools["gemini"]:
            run.note("No Gemini API key available: add one in Settings → API keys. Skipping this user.")
            return True
        settings = db.get_settings(uid)
        profile = profile_agent.run(run)
        if profile is None:
            run.note("No parent resume uploaded yet (Settings → Parent documents). Skipping this user.")
            return True
        brief = profile_agent.brief(profile)

        if not args.skip_scout and not only_job:
            try:
                with run.agent("scout", message="Scout orchestration") as task:
                    stored = scout.run(run, settings, profile, brief, pools, force_all=args.all_sources or args.trigger == "manual")
                    task.message = f"Scanned {run.scanned}, stored {stored} relevant new jobs"
            except (llm.BudgetExceeded, llm.KeysExhausted):
                raise  # nothing left to process with either
            except Exception as exc:
                # Scouting failed, but jobs already in the queue can still be scored/tailored.
                run.note(f"Scout failed ({exc}); continuing with already queued jobs")
            run.save()

        if only_job:
            queue = [{**only_job, "status": "new", "files": {}, "attempts": 0}]  # full reprocess
        else:
            queue = db.queued_jobs(uid, settings["max_jobs_per_run"])
        run.note(f"Processing {len(queue)} job(s)")

        for job in queue:
            try:
                process(run, job, profile, brief, settings)
            except llm.StopUser as exc:
                run.note(f"Stopping: {exc}. Remaining jobs continue next run.")
                break
            except Exception as exc:
                attempts = int(job.get("attempts") or 0) + 1
                values = {"attempts": attempts, "error": str(exc)[:2000]}
                if attempts >= config.MAX_ATTEMPTS:
                    values["status"] = "error"
                db.update_job(job["job_id"], values)
            run.save()
    except llm.StopUser as exc:
        run.note(f"Stopping: {exc}")
    except Exception as exc:
        status = "error"
        run.errors += 1
        run.note(f"Pipeline failed: {exc}")
        log.exception("pipeline failed for user %s", uid)
    finally:
        for notice in llm.notices:
            run.note(notice)
        run.note(f"Done. Gemini calls used: {llm.calls_made}/{account.get('llm_calls_per_run')}")
        run.save(status)
    return status == "success"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trigger", default="schedule")
    ap.add_argument("--all-sources", action="store_true", help="ignore per-source hourly throttles (except JSearch)")
    ap.add_argument("--skip-scout", action="store_true")
    ap.add_argument("--user", help="only run for this user (email)")
    ap.add_argument("--job", help="(re)process a single job id")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    db.expire_stale_agent_runs()
    store = KeyStateStore()
    accounts = db.active_accounts()
    only_job = None

    if args.job:
        rows = db.sb.table("jobs").select("*").eq("job_id", args.job).execute().data
        if not rows:
            log.error("Job %s not found", args.job)
            return 1
        only_job = rows[0]
        accounts = [a for a in accounts if a["user_id"] == only_job["user_id"]]
    elif args.user:
        wanted = next((u for u in db.sb.auth.admin.list_users() if (u.email or "").lower() == args.user.lower()), None)
        if not wanted:
            log.error("No user with email %s", args.user)
            return 1
        accounts = [a for a in accounts if a["user_id"] == wanted.id]

    ok = True
    for account in accounts:
        ok = run_user(account, args, store, only_job) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
