"""Supabase access + agent activity tracking."""
from __future__ import annotations

import logging
import traceback
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone

from supabase import Client, create_client

from . import config

log = logging.getLogger("jobfinder")

sb: Client = create_client(config.SUPABASE_URL, config.SUPABASE_SERVICE_ROLE_KEY)

JOBS_BUCKET = "jobs"
PARENT_BUCKET = "parent"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# ---------------------------------------------------------------- settings/profile
def get_settings() -> dict:
    return sb.table("settings").select("*").eq("id", 1).single().execute().data


def get_profile() -> dict:
    return sb.table("profile").select("*").eq("id", 1).single().execute().data


def update_profile(values: dict) -> None:
    sb.table("profile").update({**values, "updated_at": now_iso()}).eq("id", 1).execute()


# ---------------------------------------------------------------- jobs
def existing_keys(source: str, external_ids: list[str]) -> set[str]:
    found: set[str] = set()
    for i in range(0, len(external_ids), 100):
        chunk = external_ids[i:i + 100]
        rows = sb.table("jobs").select("external_id").eq("source", source).in_("external_id", chunk).execute().data
        found.update(r["external_id"] for r in rows)
    return found


def recent_fingerprints(days: int = 45) -> set[str]:
    """company|title fingerprints of recent jobs, for cross-source de-duplication."""
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    rows = sb.table("jobs").select("company,title").gte("created_at", since).limit(5000).execute().data
    return {fingerprint(r["company"], r["title"]) for r in rows}


def fingerprint(company: str, title: str) -> str:
    norm = lambda s: " ".join("".join(c.lower() if c.isalnum() else " " for c in (s or "")).split())
    return f"{norm(company)}|{norm(title)}"


def insert_job(row: dict) -> dict:
    return sb.table("jobs").insert(row).execute().data[0]


def update_job(job_id: str, values: dict) -> None:
    sb.table("jobs").update(values).eq("job_id", job_id).execute()


def queued_jobs(limit: int) -> list[dict]:
    return (
        sb.table("jobs").select("*")
        .in_("status", ["new", "scored", "tailored"])
        .lt("attempts", config.MAX_ATTEMPTS)
        .order("relevance", desc=True)
        .order("created_at", desc=True)
        .limit(limit)
        .execute().data
    )


# ---------------------------------------------------------------- storage
def upload(path: str, data: bytes, content_type: str, bucket: str = JOBS_BUCKET) -> str:
    sb.storage.from_(bucket).upload(path, data, {"content-type": content_type, "upsert": "true"})
    return path


def download(path: str, bucket: str = JOBS_BUCKET) -> bytes:
    return sb.storage.from_(bucket).download(path)


def list_files(prefix: str, bucket: str) -> list[dict]:
    items = sb.storage.from_(bucket).list(prefix) or []
    return [i for i in items if i.get("id")]  # folders have no id


# ---------------------------------------------------------------- runs
class PipelineRun:
    def __init__(self, trigger: str):
        self.id = sb.table("pipeline_runs").insert({"trigger": trigger}).execute().data[0]["id"]
        self.scanned = self.matched = self.processed = self.errors = 0
        self.lines: list[str] = []

    def note(self, msg: str) -> None:
        log.info(msg)
        self.lines.append(f"{datetime.now(timezone.utc):%H:%M:%S} {msg}")

    def save(self, status: str | None = None) -> None:
        values = {
            "jobs_scanned": self.scanned, "jobs_matched": self.matched,
            "jobs_processed": self.processed, "errors": self.errors,
            "log": "\n".join(self.lines[-400:]),
        }
        if status:
            values.update(status=status, finished_at=now_iso())
        sb.table("pipeline_runs").update(values).eq("id", self.id).execute()

    @contextmanager
    def agent(self, name: str, job_id: str | None = None, message: str | None = None):
        """Record an agent task in agent_runs so the dashboard can show live activity and errors."""
        row = sb.table("agent_runs").insert(
            {"pipeline_run": self.id, "agent": name, "job_id": job_id, "message": message}
        ).execute().data[0]
        task = AgentTask(row["id"], message)
        try:
            yield task
        except Exception as exc:
            self.errors += 1
            self.note(f"[{name}] {job_id or ''} ERROR {exc}")
            log.debug(traceback.format_exc())
            sb.table("agent_runs").update(
                {"status": "error", "message": f"{exc}"[:2000], "finished_at": now_iso()}
            ).eq("id", row["id"]).execute()
            raise
        else:
            sb.table("agent_runs").update(
                {"status": "success", "message": task.message, "finished_at": now_iso()}
            ).eq("id", row["id"]).execute()


class AgentTask:
    def __init__(self, row_id: str, message: str | None):
        self.id = row_id
        self.message = message


def expire_stale_agent_runs() -> None:
    """A killed workflow leaves rows stuck in 'running'; close them so the dashboard stays honest."""
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
    sb.table("agent_runs").update(
        {"status": "error", "message": "timed out (runner stopped)", "finished_at": now_iso()}
    ).eq("status", "running").lt("started_at", cutoff).execute()
    sb.table("pipeline_runs").update(
        {"status": "error", "finished_at": now_iso()}
    ).eq("status", "running").lt("started_at", cutoff).execute()
