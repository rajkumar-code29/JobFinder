"""Hourly pipeline, run for every enabled user in turn:
Profile → batch workflow (see batch.py): Scout fills Batch #N → Salary (all) → Scorer (all, ranked) →
Tailor → Coach → Writer one job at a time in rank order. An admin can pause everything (control.py).

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

from . import batch, control, db, llm
from .agents import coach, profile as profile_agent, salary, scorer, tailor, writer
from .keys import AI_PROVIDERS, KeyStateStore, build_pools, shared_keys

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


def run_user(account: dict, args, store: KeyStateStore, shared: dict, only_job: dict | None) -> bool:
    uid = account["user_id"]
    run = db.PipelineRun(args.trigger, uid)
    run.note(f"User {db.user_label(uid)}")
    status = "success"
    pools = build_pools(account, db.user_api_keys(uid), store, shared)
    llm.activate({p: pools[p] for p in AI_PROVIDERS}, int(account.get("llm_calls_per_run") or 40),
                 on_event=run.note, should_stop=control.paused)
    try:
        if not any(pools[p] for p in AI_PROVIDERS):
            run.note("No AI provider key available (Gemini, Groq, …): add one in Settings → API keys. Skipping this user.")
            return True
        settings = db.get_settings(uid)
        profile = profile_agent.run(run)
        if profile is None:
            run.note("No parent resume uploaded yet (Settings → Parent documents). Skipping this user.")
            return True
        brief = profile_agent.brief(profile)

        if only_job:  # --job: full reprocess of one job, outside the batch flow
            try:
                process(run, {**only_job, "status": "new", "files": {}, "attempts": 0}, profile, brief, settings)
            except llm.StopUser:
                raise
            except Exception as exc:
                db.update_job(only_job["job_id"], {"error": str(exc)[:2000]})
                raise
        else:
            current = db.open_batch(uid)
            if current is None and not args.skip_scout:
                current = batch.start(run, settings, profile, brief, pools,
                                      force_all=args.all_sources or args.trigger == "manual")
            elif current is not None:
                run.note(f"Continuing Batch #{current['number']} (no new scan until it's finished)")
            run.save()
            if current is not None:
                batch.process(run, current, profile, brief, settings)
    except llm.Paused:
        run.note("Agents paused by an admin – stopping")
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
        db.record_model_stats(llm.take_stats())
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
    ap.add_argument("--compare", type=int, help="run a model comparison (admin → Models → Compare)")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    if control.paused():
        log.info("Agents are paused by an admin (Home → Resume agents) – nothing to do.")
        return 0
    if args.compare:
        from . import compare
        return compare.run(args.compare)
    db.expire_stale_agent_runs()
    if args.trigger == "schedule" and not (args.job or args.user) and db.scheduled_run_since(minutes=40):
        # The Cloudflare scheduler and GitHub's backup cron can both fire; one scheduled run per slot is enough.
        log.info("A scheduled run already happened in the last 40 minutes – skipping.")
        return 0
    try:
        db.prune_seen()
    except Exception as exc:  # e.g. migration 003 not applied yet
        log.warning("could not prune seen_postings: %s", exc)
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

    shared = shared_keys(store)
    llm.set_routing(db.model_routing())
    ok = True
    for account in accounts:
        if control.paused():
            log.info("Agents paused by an admin – skipping the remaining users.")
            break
        ok = run_user(account, args, store, shared, only_job) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
