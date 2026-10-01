"""Supabase helpers and run/agent logging."""
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


# users
def active_accounts() -> list[dict]:
    return sb.table("accounts").select("*").eq("enabled", True).order("created_at").execute().data


def user_api_keys(user_id: str) -> list[dict]:
    return sb.table("api_keys").select("*").eq("user_id", user_id).execute().data


def sync_shared_keys(github_keys: list[dict]) -> list[dict]:
    """Register env keys by fingerprint (not value) and return enabled shared keys in order."""
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


# settings/profile
def get_settings(user_id: str) -> dict:
    return sb.table("settings").select("*").eq("user_id", user_id).single().execute().data


def get_profile(user_id: str) -> dict:
    return sb.table("profile").select("*").eq("user_id", user_id).single().execute().data


def update_profile(user_id: str, values: dict) -> None:
    sb.table("profile").update({**values, "updated_at": now_iso()}).eq("user_id", user_id).execute()


# jobs
def existing_keys(user_id: str, source: str, external_ids: list[str]) -> set[str]:
    found: set[str] = set()
    for i in range(0, len(external_ids), 100):
        chunk = external_ids[i:i + 100]
        rows = sb.table("jobs").select("external_id").eq("user_id", user_id).eq("source", source).in_("external_id", chunk).execute().data
        found.update(r["external_id"] for r in rows)
    return found


def all_rows(build, page: int = 1000) -> list[dict]:
    """Page past PostgREST's 1000-row cap. build() must return a new query each time."""
    out, start = [], 0
    while True:
        rows = build().range(start, start + page - 1).execute().data
        out += rows
        if len(rows) < page:
            return out
        start += page


def recent_fingerprints(user_id: str, days: int = 45) -> set[str]:
    """company|title of recent jobs, for cross-source dedupe."""
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    rows = all_rows(lambda: sb.table("jobs").select("company,title").eq("user_id", user_id)
                    .gte("created_at", since).order("created_at"))
    return {fingerprint(r["company"], r["title"]) for r in rows}


# seen postings
SEEN_DAYS = 45


def seen_lookup(user_id: str, context: str, keys: list[tuple[str, str, str]]) -> tuple[dict, dict]:
    """Earlier ratings for these (source, external_id, fingerprint) keys under the same context,
    plus anything the user deleted."""
    by_key, by_fp = {}, {}  # old rows are pruned at the start of each run
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
        for r in rows:  # deleted marker wins over a rating from another site
            if r["context"] == "*" or r["fingerprint"] not in by_fp:
                by_fp[r["fingerprint"]] = r
    return by_key, by_fp


def record_seen(user_id: str, context: str, rows: list[dict]) -> None:
    """Upsert ratings (source, external_id, fingerprint, relevance, reason)."""
    stamp = now_iso()
    payload = [{**r, "user_id": user_id, "context": context, "seen_at": stamp} for r in rows]
    for i in range(0, len(payload), 500):
        sb.table("seen_postings").upsert(payload[i:i + 500], on_conflict="user_id,source,external_id").execute()


def cleanup_old_jobs(user_id: str, days: int) -> int:
    """Remove unapplied jobs older than `days` (files first) and mark them as deleted.
    Skips jobs in a batch that's still open."""
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    rows = (sb.table("jobs").select("id,job_id,source,external_id,company,title,batch_id")
            .eq("user_id", user_id).neq("status", "applied").lt("created_at", cutoff).limit(200).execute().data)
    if not rows:
        return 0
    open_batches = {b["id"] for b in sb.table("batches").select("id").eq("user_id", user_id)
                    .eq("status", "processing").execute().data}
    removed = 0
    for r in rows:
        if r.get("batch_id") in open_batches:
            continue
        prefix = f"{user_id}/{r['job_id']}"
        files = [f"{prefix}/{f['name']}" for f in list_files(prefix, JOBS_BUCKET)]
        if files:
            sb.storage.from_(JOBS_BUCKET).remove(files)
        sb.table("seen_postings").upsert({
            "user_id": user_id, "source": r["source"], "external_id": r["external_id"],
            "fingerprint": fingerprint(r["company"], r["title"]), "context": "*", "relevance": -1,
            "reason": f"auto-deleted after {days} days (never applied)", "seen_at": now_iso()},
            on_conflict="user_id,source,external_id").execute()
        sb.table("jobs").delete().eq("id", r["id"]).execute()
        removed += 1
    return removed


def prune_seen() -> None:
    cutoff = (datetime.now(timezone.utc) - timedelta(days=SEEN_DAYS)).isoformat()
    sb.table("seen_postings").delete().lt("seen_at", cutoff).neq("context", "*").execute()


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


# storage
def model_routing() -> dict[str, list[str]]:
    """Per-agent model order from the DB (empty means use the defaults)."""
    try:
        rows = sb.table("model_routing").select("agent,chain").execute().data
    except Exception as exc:
        log.warning("model_routing unavailable (%s); using defaults", exc)
        return {}
    return {r["agent"]: r["chain"] for r in rows if r.get("chain")}


def record_model_stats(rows: list[dict]) -> None:
    """Add this run's counters to today's model_stats rows."""
    if not rows:
        return
    day = datetime.now(timezone.utc).date().isoformat()
    fields = ("ok", "rate_limited", "overloaded", "invalid_json", "too_large", "errors", "ms")
    try:
        for r in rows:
            existing = (sb.table("model_stats").select("*").eq("day", day).eq("agent", r["agent"])
                        .eq("model", r["model"]).execute().data)
            base = existing[0] if existing else {"day": day, "agent": r["agent"], "model": r["model"]}
            sb.table("model_stats").upsert({**base, **{f: int(base.get(f) or 0) + int(r.get(f) or 0) for f in fields}},
                                           on_conflict="day,agent,model").execute()
    except Exception as exc:
        log.warning("could not record model stats: %s", exc)


def model_meta(job: dict, agent: str, model: str | None) -> dict:
    """Copy of job.meta with meta.models[agent] set."""
    meta = dict(job.get("meta") or {})
    if model:
        meta["models"] = {**(meta.get("models") or {}), agent: model}
    return meta


def job_dir(job: dict) -> str:
    """jobs/<user_id>/<job_id>"""
    return f"{job['user_id']}/{job['job_id']}"


def upload(path: str, data: bytes, content_type: str, bucket: str = JOBS_BUCKET) -> str:
    sb.storage.from_(bucket).upload(path, data, {"content-type": content_type, "upsert": "true"})
    return path


def download(path: str, bucket: str = JOBS_BUCKET) -> bytes:
    return sb.storage.from_(bucket).download(path)


def list_files(prefix: str, bucket: str) -> list[dict]:
    items = sb.storage.from_(bucket).list(prefix) or []
    return [i for i in items if i.get("id")]  # skip folders


# runs
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
        if time.monotonic() - self._saved_at > 15:  # so the app sees the log while it runs
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
    def agent(self, name: str, job_id: str | None = None, message: str | None = None):
        """Log an agent task to agent_runs."""
        row = sb.table("agent_runs").insert(
            {"pipeline_run": self.id, "user_id": self.user_id, "agent": name, "job_id": job_id, "message": message}
        ).execute().data[0]
        task = AgentTask(row["id"], message)
        try:
            yield task
        except BaseException as exc:  # incl. KeyboardInterrupt when the workflow is cancelled
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
    """Only one run at a time (workflow concurrency group), so anything still 'running' is left over."""
    sb.table("agent_runs").update(
        {"status": "error", "message": "stopped (the run ended unexpectedly)", "finished_at": now_iso()}
    ).eq("status", "running").execute()
    sb.table("pipeline_runs").update(
        {"status": "error", "finished_at": now_iso()}
    ).eq("status", "running").execute()


# batches
def open_batch(user_id: str) -> dict | None:
    rows = (sb.table("batches").select("*").eq("user_id", user_id).eq("status", "processing")
            .order("number", desc=True).limit(1).execute().data)
    return rows[0] if rows else None


def unbatched_jobs(user_id: str, limit: int) -> list[dict]:
    """Jobs not in a batch yet, best match first."""
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
