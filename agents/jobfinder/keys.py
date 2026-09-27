"""API key pools with automatic fallback.

Keys are tried in order. When a key hits a limit it is parked until the provider resets it (remembered in the
`key_state` table so later runs skip it), and the next key is used. Short per-minute limits only park a key
in memory for the retry delay.
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
    """Gemini daily quotas reset at midnight Pacific time."""
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
    row_id: str | None = None  # api_keys.id for keys a user added; None for shared (GitHub secret) keys
    label: str = ""

    @property
    def fingerprint(self) -> str:
        return hashlib.sha256(f"{self.provider}:{self.app_id or ''}:{self.value}".encode()).hexdigest()[:24]

    @property
    def name(self) -> str:
        who = self.label or ("shared key" if self.row_id is None else "key")
        return f"{who} …{self.value[-4:]}"


class KeyStateStore:
    """Loads parked keys once per run and persists new parking decisions."""

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
        if key.row_id:  # show it on the user's Settings screen
            db.sb.table("api_keys").update(
                {"exhausted_until": until.isoformat(), "last_error": f"{scope}: {error}"[:500]}
            ).eq("id", key.row_id).execute()
        log.warning("%s %s parked until %s (%s)", key.provider, key.name, until.isoformat(timespec="minutes"), error)

    def touch(self, key: Key) -> None:
        if key.row_id and key.row_id not in self._touched:
            self._touched.add(key.row_id)
            db.sb.table("api_keys").update({"last_used_at": utcnow().isoformat(), "last_error": None}).eq("id", key.row_id).execute()


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
        """If every usable key is only cooling (per-minute limit), how long until the first frees up."""
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


def build_pools(account: dict, user_keys: list[dict], store: KeyStateStore) -> dict[str, KeyPool]:
    """User's own keys first (by priority), then the shared keys if the account may use them."""
    from . import config

    own = sorted(user_keys, key=lambda r: (r.get("priority") or 0, r.get("created_at") or ""))
    shared = account.get("use_shared_keys", False)

    def mine(provider):
        return [Key(provider, r["key_value"], r.get("app_id"), r["id"], r.get("label") or "") for r in own if r["provider"] == provider]

    return {
        "gemini": KeyPool("gemini", mine("gemini") + ([Key("gemini", k) for k in config.SHARED_GEMINI_KEYS] if shared else []), store),
        "adzuna": KeyPool("adzuna", mine("adzuna") + ([Key("adzuna", k, a) for a, k in config.SHARED_ADZUNA_KEYS] if shared else []), store),
        "rapidapi": KeyPool("rapidapi", mine("rapidapi") + ([Key("rapidapi", k) for k in config.SHARED_RAPIDAPI_KEYS] if shared else []), store),
    }
