"""Key pools with fallback.

A key that hits a daily/hard limit is parked in key_state until it resets; per-minute limits only cool it
in memory. The next key in the pool is used meanwhile.
"""
from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from . import db

log = logging.getLogger("jobfinder")
ALL_SCOPES = "*"


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def next_pacific_midnight() -> datetime:
    """Gemini quotas reset at midnight PT."""
    now = datetime.now(ZoneInfo("America/Los_Angeles"))
    return (now + timedelta(days=1)).replace(hour=0, minute=5, second=0, microsecond=0).astimezone(timezone.utc)


def first_of_next_month() -> datetime:
    now = utcnow()
    return (now.replace(day=28) + timedelta(days=4)).replace(day=1, hour=0, minute=5, second=0, microsecond=0)


class NoKeyAvailable(RuntimeError):
    pass


@dataclass(frozen=True)
class Key:
    provider: str
    value: str
    app_id: str | None = None
    row_id: str | None = None  # row in `table`, for status in the app
    label: str = ""
    table: str = "api_keys"    # or shared_api_keys

    @property
    def fingerprint(self) -> str:
        return hashlib.sha256(f"{self.provider}:{self.app_id or ''}:{self.value}".encode()).hexdigest()[:24]

    @property
    def name(self) -> str:
        who = self.label or ("shared key" if self.row_id is None else "key")
        return f"{who} …{self.value[-4:]}"


class KeyStateStore:
    """Parked keys, loaded once per run."""

    def __init__(self):
        rows = db.sb.table("key_state").select("id,exhausted_until").gt("exhausted_until", utcnow().isoformat()).execute().data
        self._until = {r["id"]: datetime.fromisoformat(r["exhausted_until"]) for r in rows}
        self._touched: set[str] = set()

    def parked_until(self, key: Key, scope: str) -> datetime | None:
        found = [self._until.get(f"{key.fingerprint}:{s}") for s in (scope, ALL_SCOPES)]
        found = [t for t in found if t and t > utcnow()]
        return max(found) if found else None

    def park(self, key: Key, scope: str, until: datetime, error: str) -> None:
        self._until[f"{key.fingerprint}:{scope}"] = until
        db.sb.table("key_state").upsert({
            "id": f"{key.fingerprint}:{scope}", "provider": key.provider,
            "exhausted_until": until.isoformat(), "last_error": error[:500], "updated_at": utcnow().isoformat(),
        }).execute()
        if key.row_id:
            values = {"exhausted_until": until.isoformat(), "last_error": f"{scope}: {error}"[:500]}
            if key.table == "shared_api_keys":
                values["in_use"] = False
            db.sb.table(key.table).update(values).eq("id", key.row_id).execute()
        log.warning("%s %s parked until %s (%s)", key.provider, key.name, until.isoformat(timespec="minutes"), error)

    def touch(self, key: Key) -> None:
        """Mark a key as used (once per run). Shared keys also get in_use."""
        if not key.row_id or key.row_id in self._touched:
            return
        self._touched.add(key.row_id)
        values = {"last_used_at": utcnow().isoformat(), "last_error": None}
        if key.table == "shared_api_keys":
            db.sb.table(key.table).update({"in_use": False}).eq("provider", key.provider).neq("id", key.row_id).execute()
            values["in_use"] = True
        db.sb.table(key.table).update(values).eq("id", key.row_id).execute()


class KeyPool:
    def __init__(self, provider: str, keys: list[Key], store: KeyStateStore):
        seen, unique = set(), []
        for k in keys:
            if k.value and k.fingerprint not in seen:
                seen.add(k.fingerprint)
                unique.append(k)
        self.provider, self.keys, self.store = provider, unique, store
        self._cooling: dict[str, datetime] = {}

    def __bool__(self) -> bool:
        return bool(self.keys)

    def _ready(self, key: Key, scope: str, now: datetime) -> bool:
        return self.store.parked_until(key, scope) is None and self._cooling.get(f"{key.fingerprint}:{scope}", now) <= now

    def get(self, scope: str = "default") -> Key:
        now = utcnow()
        for k in self.keys:
            if self._ready(k, scope, now):
                return k
        raise NoKeyAvailable(f"no {self.provider} key available for {scope}")

    def seconds_until_free(self, scope: str = "default") -> float | None:
        """Seconds until a cooling key is usable again, or None."""
        now = utcnow()
        waits = [(self._cooling[f"{k.fingerprint}:{scope}"] - now).total_seconds()
                 for k in self.keys
                 if self.store.parked_until(k, scope) is None and f"{k.fingerprint}:{scope}" in self._cooling]
        return max(0.0, min(waits)) if waits else None

    def cool(self, key: Key, scope: str, seconds: float) -> None:
        self._cooling[f"{key.fingerprint}:{scope}"] = utcnow() + timedelta(seconds=seconds)

    def park(self, key: Key, scope: str, until: datetime, error: str) -> None:
        self.store.park(key, scope, until, error)

    def used(self, key: Key) -> None:
        self.store.touch(key)


PROVIDERS = ("gemini", "groq", "openrouter", "adzuna", "rapidapi")
AI_PROVIDERS = ("gemini", "groq", "openrouter")


def shared_keys(store: KeyStateStore) -> dict[str, list[Key]]:
    """Shared pool in the order set in the app.

    Env keys are registered in shared_api_keys by fingerprint only, so they can be reordered/disabled there.
    Falls back to the env keys if the table isn't there (pre-004)."""
    from . import config

    env_keys = ([Key("gemini", k) for k in config.SHARED_GEMINI_KEYS]
                + [Key("adzuna", k, a) for a, k in config.SHARED_ADZUNA_KEYS]
                + [Key("rapidapi", k) for k in config.SHARED_RAPIDAPI_KEYS]
                + [Key("groq", k) for k in config.SHARED_GROQ_KEYS]
                + [Key("openrouter", k) for k in config.SHARED_OPENROUTER_KEYS])
    by_fp = {k.fingerprint: k for k in env_keys}
    try:
        rows = db.sync_shared_keys([
            {"provider": k.provider, "source": "github", "fingerprint": k.fingerprint, "hint": f"…{k.value[-4:]}",
             "label": "GitHub secret", "app_id": k.app_id} for k in env_keys])
    except Exception as exc:
        log.warning("shared_api_keys unavailable (%s); using GitHub-secret keys only", exc)
        return {p: [k for k in env_keys if k.provider == p] for p in PROVIDERS}

    pools: dict[str, list[Key]] = {p: [] for p in PROVIDERS}
    for r in rows:
        if r["source"] == "github":
            env = by_fp.get(r["fingerprint"])
            if env and r["provider"] in pools:  # gone from secrets -> skip
                pools[r["provider"]].append(Key(env.provider, env.value, env.app_id, r["id"], r["label"] or "GitHub secret", "shared_api_keys"))
        elif r.get("key_value") and r["provider"] in pools:
            pools[r["provider"]].append(Key(r["provider"], r["key_value"], r.get("app_id"), r["id"], r["label"] or "", "shared_api_keys"))
    return pools


def build_pools(account: dict, user_keys: list[dict], store: KeyStateStore, shared: dict[str, list[Key]]) -> dict[str, KeyPool]:
    """Own keys first, then the shared pool if allowed."""
    own = sorted(user_keys, key=lambda r: (r.get("priority") or 0, r.get("created_at") or ""))
    use_shared = account.get("use_shared_keys", False)

    def pool(provider):
        mine = [Key(provider, r["key_value"], r.get("app_id"), r["id"], r.get("label") or "") for r in own if r["provider"] == provider]
        return KeyPool(provider, mine + (shared.get(provider, []) if use_shared else []), store)

    return {p: pool(p) for p in PROVIDERS}
