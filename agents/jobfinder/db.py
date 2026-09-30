"""Supabase access + agent activity tracking."""
from __future__ import annotations

import logging
import time
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


def sync_shared_keys(github_keys: list[dict]) -> list[dict]:
    """Register GitHub-secret keys (by fingerprint, never the value) and return the enabled shared keys in order."""
    if github_keys:
        sb.table("shared_api_keys").upsert(github_keys, on_conflict="fingerprint", ignore_duplicates=True).execute()
    return (sb.table("shared_api_keys").select("*").eq("enabled", True)
            .order("priority").order("created_at").execute().data)


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
    by_key, by_fp = {}, {}  # rows older than SEEN_DAYS are pruned at the start of each run (except "deleted" markers)
    cols = "source,external_id,fingerprint,relevance,reason,context"
    by_source: dict[str, list[str]] = {}
    for source, ext, _ in keys:
        by_source.setdefault(source, []).append(ext)
    for source, ids in by_source.items():
        for i in range(0, len(ids), 100):
            rows = (sb.table("seen_postings").select(cols).eq("user_id", user_id).in_("context", [context, "*"])
                    .eq("source", source).in_("external_id", ids[i:i + 100]).execute().data)
            by_key.update({(r["source"], r["external_id"]): r for r in rows})
    fps = sorted({fp for _, _, fp in keys})
    for i in range(0, len(fps), 100):
        rows = (sb.table("seen_postings").select(cols).eq("user_id", user_id).in_("context", [context, "*"])
                .in_("fingerprint", fps[i:i + 100]).execute().data)
        for r in rows:  # a "deleted" marker beats any rating of the same job on another site
            if r["context"] == "*" or r["fingerprint"] not in by_fp:
                by_fp[r["fingerprint"]] = r
    return by_key, by_fp


def record_seen(user_id: str, context: str, rows: list[dict]) -> None:
    """rows = [{source, external_id, fingerprint, relevance, reason}]"""
    stamp = now_iso()
    payload = [{**r, "user_id": user_id, "context": context, "seen_at": stamp} for r in rows]
    for i in range(0, len(payload), 500):
        sb.table("seen_postings").upsert(payload[i:i + 500], on_conflict="user_id,source,external_id").execute()


def prune_seen() -> None:
    cutoff = (datetime.now(timezone.utc) - timedelta(days=SEEN_DAYS)).isoformat()
    sb.table("seen_postings").delete().lt("seen_at", cutoff).neq("context", "*").execute()  # keep "deleted" markers


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
        self._saved_at = 0.0

    def note(self, msg: str) -> None:
        log.info(msg)
        self.lines.append(f"{datetime.now(timezone.utc):%H:%M:%S} {msg}")
        if time.monotonic() - self._saved_at > 15:  # keep the app's run log live, even if the run is cancelled
            try:
                self.save()
            except Exception:
                pass

    def save(self, status: str | None = None) -> None:
        values = {
            "jobs_scanned": self.scanned, "jobs_matched": self.matched,
            "jobs_processed": self.processed, "errors": self.errors,
            "log": "\n".join(self.lines[-400:]),
        }
        if status:
            values.update(status=status, finished_at=now_iso())
        sb.table("pipeline_runs").update(values).eq("id", self.id).execute()
        self._saved_at = time.monotonic()

    @contextmanager
    def agent(self, name: str, job_id: str | None = None, message: str | None = None):  # noqa: C901
        """Record an agent task in agent_runs so the dashboard can show live activity and errors."""
        row = sb.table("agent_runs").insert(
            {"pipeline_run": self.id, "user_id": self.user_id, "agent": name, "job_id": job_id, "message": message}
        ).execute().data[0]
        task = AgentTask(row["id"], message)
        try:
            yield task
        except BaseException as exc:  # includes cancellation (KeyboardInterrupt), so no task stays "running"
            if not isinstance(exc, Exception):
                sb.table("agent_runs").update(
                    {"status": "error", "message": "stopped (run cancelled)", "finished_at": now_iso()}
                ).eq("id", row["id"]).execute()
                raise
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
    """Only one pipeline runs at a time (GitHub concurrency group), so anything still 'running' when a new run
    starts belongs to a run that was cancelled or crashed: close it so the dashboard stays honest."""
    sb.table("agent_runs").update(
        {"status": "error", "message": "stopped (the run ended unexpectedly)", "finished_at": now_iso()}
    ).eq("status", "running").execute()
    sb.table("pipeline_runs").update(
        {"status": "error", "finished_at": now_iso()}
    ).eq("status", "running").execute()


# ---------------------------------------------------------------- batches
def open_batch(user_id: str) -> dict | None:
    rows = (sb.table("batches").select("*").eq("user_id", user_id).eq("status", "processing")
            .order("number", desc=True).limit(1).execute().data)
    return rows[0] if rows else None


def unbatched_jobs(user_id: str, limit: int) -> list[dict]:
    """Relevant jobs waiting for a batch (best match first)."""
    return (sb.table("jobs").select("id,job_id,relevance").eq("user_id", user_id).eq("status", "new")
            .is_("batch_id", "null").lt("attempts", config.MAX_ATTEMPTS)
            .order("relevance", desc=True).order("created_at").limit(limit).execute().data)


def create_batch(user_id: str, job_ids: list[str]) -> dict:
    last = sb.table("batches").select("number").eq("user_id", user_id).order("number", desc=True).limit(1).execute().data
    number = (last[0]["number"] if last else 0) + 1
    batch = sb.table("batches").insert({"user_id": user_id, "number": number, "job_count": len(job_ids)}).execute().data[0]
    for i in range(0, len(job_ids), 100):
        sb.table("jobs").update({"batch_id": batch["id"]}).in_("id", job_ids[i:i + 100]).execute()
    return batch


def batch_jobs(batch_id: str) -> list[dict]:
    return sb.table("jobs").select("*").eq("batch_id", batch_id).execute().data


def update_batch(batch_id: str, values: dict) -> None:
    sb.table("batches").update(values).eq("id", batch_id).execute()
