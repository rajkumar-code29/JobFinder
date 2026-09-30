"""Batch workflow, per user:

  1. Scout   – collect up to `batch_size` relevant jobs (full descriptions) → Batch #N. No new scanning while a
               batch is still being processed.
  2. Salary  – fill in missing salaries for every job in the batch.
  3. Scorer  – ATS-score every job, then rank the batch (1 = highest score).
  4. Tailor → Coach → Writer – one job at a time in rank order, until the whole batch is ready.

Each stage resumes where it stopped, so a batch can span several hourly runs (free-tier limits, kill switch).
"""
from __future__ import annotations

import json
import logging

from . import config, control, db, llm
from .agents import coach, salary, scorer, scout, tailor, writer

log = logging.getLogger("jobfinder")
ACTIVE = ("new", "scored", "tailored")


def _check() -> None:
    if control.paused():
        raise llm.Paused("Agents paused by an admin")


def _failed(run: db.PipelineRun, job: dict, exc: Exception) -> None:
    attempts = int(job.get("attempts") or 0) + 1
    values = {"attempts": attempts, "error": str(exc)[:2000]}
    if attempts >= config.MAX_ATTEMPTS:
        values["status"] = "error"
    db.update_job(job["job_id"], values)
    job.update(values)


def start(run: db.PipelineRun, settings: dict, profile: dict, brief: str, pools: dict, force_all: bool) -> dict | None:
    """Form the next batch from relevant jobs already waiting, topping up with a fresh scan if needed."""
    size = max(1, int(settings.get("batch_size") or 20))
    waiting = db.unbatched_jobs(run.user_id, size)
    if len(waiting) < size:
        with run.agent("scout", message=f"Looking for {size - len(waiting)} relevant jobs for the next batch") as task:
            stored = scout.run(run, settings, profile, brief, pools, force_all=force_all,
                               limit=size - len(waiting), should_stop=control.paused)
            task.message = f"Scanned {run.scanned} postings, saved {stored} relevant jobs"
        waiting = db.unbatched_jobs(run.user_id, size)
    if not waiting:
        run.note("No new relevant jobs found – no batch this run")
        return None
    batch = db.create_batch(run.user_id, [j["id"] for j in waiting])
    run.note(f"Batch #{batch['number']} created with {len(waiting)} jobs")
    return batch


def process(run: db.PipelineRun, batch: dict, profile: dict, brief: str, settings: dict) -> None:
    label = f"Batch #{batch['number']}"
    jobs = db.batch_jobs(batch["id"])

    def active():
        return [j for j in jobs if j["status"] in ACTIVE and int(j.get("attempts") or 0) < config.MAX_ATTEMPTS]

    # 2. Salary for every job that hasn't been checked yet
    todo = [j for j in active() if j["salary_text"] == config.NA and not (j.get("meta") or {}).get("salary_checked")]
    if todo:
        db.update_batch(batch["id"], {"stage": "salary"})
        run.note(f"{label}: salary check for {len(todo)} jobs")
        for job in todo:
            _check()
            try:
                salary.run(run, job)
            except llm.StopUser:
                raise
            except Exception as exc:  # a missing salary never blocks the batch
                log.warning("salary failed for %s: %s", job["job_id"], exc)

    # 3. Score every job, then rank the batch
    todo = [j for j in active() if j["status"] == "new"]
    if todo:
        db.update_batch(batch["id"], {"stage": "scoring"})
        run.note(f"{label}: scoring {len(todo)} jobs")
        for job in todo:
            _check()
            try:
                scorer.run(run, job, profile)
            except llm.StopUser:
                raise
            except Exception as exc:
                _failed(run, job, exc)
    if any(j["status"] == "new" for j in active()):
        run.note(f"{label}: some jobs still need scoring – continuing next run")
        return  # rank only once the whole batch is scored

    ranked = sorted([j for j in jobs if j.get("ats_score") is not None], key=lambda j: -(j["ats_score"] or 0))
    for rank, job in enumerate(ranked, 1):
        if job.get("batch_rank") != rank:
            db.update_job(job["job_id"], {"batch_rank": rank})
            job["batch_rank"] = rank

    # 4. Tailor → Coach → Writer, one job at a time, highest score first
    db.update_batch(batch["id"], {"stage": "tailoring"})
    queue = sorted([j for j in active() if j["status"] in ("scored", "tailored")], key=lambda j: j.get("batch_rank") or 999)
    per_run = max(1, int(settings.get("max_jobs_per_run") or 3))
    for job in queue[:per_run]:
        _check()
        try:
            report = json.loads(db.download(job["files"]["report_json"]))
            if job["status"] == "scored":
                tailor.run(run, job, profile, report, settings["target_ats"])
            _check()
            if "interview" not in (job.get("files") or {}):
                coach.run(run, job, brief, report)
            _check()
            if "cover_letter_docx" not in (job.get("files") or {}):
                writer.run(run, job, profile, brief)
            db.update_job(job["job_id"], {"status": "ready", "error": None})
            job["status"] = "ready"
            run.processed += 1
            run.note(f"{label} #{job['batch_rank']} ready: {job['title']} @ {job['company']} "
                     f"(ATS {job.get('ats_score')}→{job.get('tailored_ats_score')})")
        except llm.StopUser:
            raise
        except Exception as exc:
            _failed(run, job, exc)
        run.save()

    remaining = len(active())
    if remaining == 0:
        db.update_batch(batch["id"], {"status": "done", "stage": "done", "finished_at": db.now_iso()})
        run.note(f"{label} finished")
    else:
        run.note(f"{label}: {remaining} jobs still to process – continuing next run")
