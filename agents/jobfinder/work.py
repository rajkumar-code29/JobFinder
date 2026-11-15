"""Work people asked (and hold credits) for: score (free), tailor = tailored resume + cover letter, interview prep.

Each request is claimed before it runs, so the hourly run and an on-demand run never do the same one twice.
finish_job_request() takes the credit on success and releases the hold on failure, with an error code the app
shows ("no credits used").
"""
from __future__ import annotations

import json
import logging

from . import control, db, llm
from .agents import coach, salary, scorer, tailor, writer

log = logging.getLogger("jobfinder")

# shown in the app next to "no credits were used"
ERRORS = {
    "E_AI_BUSY": "The AI is busy or at its daily limit. Try again later.",
    "E_AI_FAILED": "The AI couldn't produce a usable result. Try again.",
    "E_NO_RESUME": "Upload your resume (.docx) in Settings first.",
    "E_RESUME_DOCX": "Your resume needs to be a Word file (.docx) to be tailored.",
    "E_JOB_GONE": "This job was deleted.",
    "E_PAUSED": "The agents are paused by an admin. Try again later.",
    "E_INTERRUPTED": "The run stopped before finishing. Try again.",
    "E_INTERNAL": "Something went wrong on our side. Try again.",
}


def error_code(exc: BaseException) -> str:
    if isinstance(exc, llm.Paused):
        return "E_PAUSED"
    if isinstance(exc, llm.StopUser):
        return "E_AI_BUSY"
    text = str(exc).lower()
    if "docx" in text or "parent resume" in text:
        return "E_RESUME_DOCX"
    if "json" in text or "empty response" in text or "unusable" in text:
        return "E_AI_FAILED"
    return "E_INTERNAL"


def _close(run: db.PipelineRun, req: dict, ok: bool, code: str | None = None, exc: BaseException | None = None) -> None:
    detail = ERRORS.get(code or "", "") if not ok else None
    if exc is not None and not ok:
        detail = f"{detail} ({str(exc)[:300]})"
    db.finish_request(req["id"], ok, code, detail)
    if not ok:
        run.errors += 1
        run.note(f"{req['job_id']} {req['kind']}: failed with {code}, no credits used")


def process(run: db.PipelineRun, requests: list[dict], profile: dict | None, brief: str, settings: dict) -> int:
    """Work through queued requests, one job at a time. Returns how many succeeded."""
    done = 0
    by_job: dict[str, list[dict]] = {}
    for r in requests:
        by_job.setdefault(r["job_id"], []).append(r)

    pending = list(by_job.items())
    for i, (job_id, reqs) in enumerate(pending):
        claimed = [r for r in reqs if db.claim_request(r["id"])]
        if not claimed:
            continue
        rest = [r for _, later in pending[i + 1:] for r in later]
        try:
            done += _job(run, job_id, claimed, profile, brief, settings)
        except (llm.StopUser, llm.Paused) as exc:
            # nothing more will work this run: close everything still waiting, credits untouched
            code = error_code(exc)
            for r in claimed:
                if db.request_status(r["id"]) == "running":
                    _close(run, r, False, code)
            for r in rest:
                if db.claim_request(r["id"]):
                    _close(run, r, False, code)
            run.note(f"Stopped the requested work: {exc}")
            break
        run.save()
    return done


def _job(run: db.PipelineRun, job_id: str, claimed: list[dict], profile: dict | None, brief: str, settings: dict) -> int:
    kinds = {r["kind"]: r for r in claimed}
    job = db.job_by_id(job_id)
    if job is None:
        for r in claimed:
            _close(run, r, False, "E_JOB_GONE")
        return 0
    if profile is None:
        for r in claimed:
            _close(run, r, False, "E_NO_RESUME")
        return 0

    done = 0
    # scoring comes first and is free; the paid parts need its report
    if job["status"] == "new" or "score" in kinds:
        if job["status"] == "new":
            try:
                if control.paused():
                    raise llm.Paused("Agents paused by an admin")
                try:
                    salary.run(run, job)
                except (llm.StopUser, llm.Paused):
                    raise
                except Exception as exc:  # not worth failing the job over
                    log.warning("salary failed for %s: %s", job_id, exc)
                scorer.run(run, job, profile)
            except (llm.StopUser, llm.Paused):
                raise
            except Exception as exc:
                code = error_code(exc)
                for r in claimed:
                    _close(run, r, False, code, exc)
                db.update_job(job_id, {"error": str(exc)[:2000]})
                return 0
        if "score" in kinds:
            _close(run, kinds["score"], True)
            done += 1

    report = None
    if "tailor" in kinds or "interview" in kinds:
        try:
            report = json.loads(db.download(job["files"]["report_json"]))
        except Exception as exc:
            for k in ("tailor", "interview"):
                if k in kinds:
                    _close(run, kinds[k], False, "E_INTERNAL", exc)
            return done

    if "tailor" in kinds:
        try:
            if control.paused():
                raise llm.Paused("Agents paused by an admin")
            files = job.get("files") or {}
            if "resume_docx" not in files:
                tailor.run(run, job, profile, report, settings.get("target_ats") or 95)
            if "cover_letter_docx" not in (job.get("files") or {}):
                writer.run(run, job, profile, brief)
            db.update_job(job_id, {"status": "ready", "error": None})
            job["status"] = "ready"
            _close(run, kinds["tailor"], True)
            done += 1
            run.processed += 1
            run.note(f"{job_id} tailored resume and cover letter ready: {job['title']} @ {job['company']}")
        except (llm.StopUser, llm.Paused):
            raise
        except Exception as exc:
            _close(run, kinds["tailor"], False, error_code(exc), exc)
            db.update_job(job_id, {"error": str(exc)[:2000]})

    if "interview" in kinds:
        try:
            if control.paused():
                raise llm.Paused("Agents paused by an admin")
            coach.run(run, job, brief, report)
            _close(run, kinds["interview"], True)
            done += 1
            run.note(f"{job_id} interview prep ready: {job['title']} @ {job['company']}")
        except (llm.StopUser, llm.Paused):
            raise
        except Exception as exc:
            _close(run, kinds["interview"], False, error_code(exc), exc)
    return done
