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


# ---------------------------------------------------------------- users
def active_accounts() -> list[dict]:
    return sb.table("accounts").select("*").eq("enabled", True).order("created_at").execute().data


def user_api_keys(user_id: str) -> list[dict]:
    return sb.table("api_keys").select("*").eq("user_id", user_id).execute().data


def user_label(user_id: str) -> str:
    try:
        email = sb.auth.admin.get_user_by_id(user_id).user.email or ""
        return email.split("@")[0][:3] + "…@" + email.split("@")[-1] if "@" in email else user_id[:8]
    except Exception:
        return user_id[:8]


# ---------------------------------------------------------------- settings/profile
def get_settings(user_id: str) -> dict:
    return sb.table("settings").select("*").eq("user_id", user_id).single().execute().data


def get_profile(user_id: str) -> dict:
    return sb.table("profile").select("*").eq("user_id", user_id).single().execute().data


def update_profile(user_id: str, values: dict) -> None:
    sb.table("profile").update({**values, "updated_at": now_iso()}).eq("user_id", user_id).execute()


# ---------------------------------------------------------------- jobs
def existing_keys(user_id: str, source: str, external_ids: list[str]) -> set[str]:
    found: set[str] = set()
    for i in range(0, len(external_ids), 100):
        chunk = external_ids[i:i + 100]
        rows = sb.table("jobs").select("external_id").eq("user_id", user_id).eq("source", source).in_("external_id", chunk).execute().data
        found.update(r["external_id"] for r in rows)
    return found


def all_rows(build, page: int = 1000) -> list[dict]:
    """Supabase returns at most 1000 rows per request; page through everything.
    `build` returns a fresh query builder each call."""
    out, start = [], 0
    while True:
        rows = build().range(start, start + page - 1).execute().data
        out += rows
        if len(rows) < page:
            return out
        start += page


def recent_fingerprints(user_id: str, days: int = 45) -> set[str]:
    """company|title fingerprints of recent jobs, for cross-source de-duplication."""
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    rows = all_rows(lambda: sb.table("jobs").select("company,title").eq("user_id", user_id)
                    .gte("created_at", since).order("created_at"))
    return {fingerprint(r["company"], r["title"]) for r in rows}


# ---------------------------------------------------------------- postings the AI already rated
SEEN_DAYS = 45


def seen_lookup(user_id: str, context: str, keys: list[tuple[str, str, str]]) -> tuple[dict, dict]:
    """keys = [(source, external_id, fingerprint)]. Returns ({(source, external_id): row}, {fingerprint: row})
    for postings already rated under the same resume/roles/locations context."""
    by_key, by_fp = {}, {}
    since = (datetime.now(timezone.utc) - timedelta(days=SEEN_DAYS)).isoformat()
    cols = "source,external_id,fingerprint,relevance,reason"
    by_source: dict[str, list[str]] = {}
    for source, ext, _ in keys:
        by_source.setdefault(source, []).append(ext)
    for source, ids in by_source.items():
        for i in range(0, len(ids), 100):
            rows = (sb.table("seen_postings").select(cols).eq("user_id", user_id).eq("context", context)
                    .eq("source", source).in_("external_id", ids[i:i + 100]).gte("seen_at", since).execute().data)
            by_key.update({(r["source"], r["external_id"]): r for r in rows})
    fps = sorted({fp for _, _, fp in keys})
    for i in range(0, len(fps), 100):
        rows = (sb.table("seen_postings").select(cols).eq("user_id", user_id).eq("context", context)
                .in_("fingerprint", fps[i:i + 100]).gte("seen_at", since).execute().data)
        by_fp.update({r["fingerprint"]: r for r in rows})
    return by_key, by_fp


def record_seen(user_id: str, context: str, rows: list[dict]) -> None:
    """rows = [{source, external_id, fingerprint, relevance, reason}]"""
    stamp = now_iso()
    payload = [{**r, "user_id": user_id, "context": context, "seen_at": stamp} for r in rows]
    for i in range(0, len(payload), 500):
        sb.table("seen_postings").upsert(payload[i:i + 500], on_conflict="user_id,source,external_id").execute()


def prune_seen() -> None:
    cutoff = (datetime.now(timezone.utc) - timedelta(days=SEEN_DAYS)).isoformat()
    sb.table("seen_postings").delete().lt("seen_at", cutoff).execute()


def fingerprint(company: str, title: str) -> str:
    norm = lambda s: " ".join("".join(c.lower() if c.isalnum() else " " for c in (s or "")).split())
    return f"{norm(company)}|{norm(title)}"


def insert_job(row: dict) -> dict:
    return sb.table("jobs").insert(row).execute().data[0]


def update_job(job_id: str, values: dict) -> None:
    sb.table("jobs").update(values).eq("job_id", job_id).execute()


def queued_jobs(user_id: str, limit: int) -> list[dict]:
    return (
        sb.table("jobs").select("*").eq("user_id", user_id)
        .in_("status", ["new", "scored", "tailored"])
        .lt("attempts", config.MAX_ATTEMPTS)
        .order("relevance", desc=True)
        .order("created_at", desc=True)
        .limit(limit)
        .execute().data
    )


# ---------------------------------------------------------------- storage
def job_dir(job: dict) -> str:
    """Storage folder for a job: jobs/<user_id>/<job_id>/"""
    return f"{job['user_id']}/{job['job_id']}"


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
    def __init__(self, trigger: str, user_id: str):
        self.user_id = user_id
        self.id = sb.table("pipeline_runs").insert({"trigger": trigger, "user_id": user_id}).execute().data[0]["id"]
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
            {"pipeline_run": self.id, "user_id": self.user_id, "agent": name, "job_id": job_id, "message": message}
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


def scheduled_run_since(minutes: int) -> bool:
    since = (datetime.now(timezone.utc) - timedelta(minutes=minutes)).isoformat()
    rows = sb.table("pipeline_runs").select("id").eq("trigger", "schedule").gte("started_at", since).limit(1).execute().data
    return bool(rows)


def expire_stale_agent_runs() -> None:
    """A killed workflow leaves rows stuck in 'running'; close them so the dashboard stays honest."""
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
    sb.table("agent_runs").update(
        {"status": "error", "message": "timed out (runner stopped)", "finished_at": now_iso()}
    ).eq("status", "running").lt("started_at", cutoff).execute()
    sb.table("pipeline_runs").update(
        {"status": "error", "finished_at": now_iso()}
    ).eq("status", "running").lt("started_at", cutoff).execute()
