"""Admin kill switch (Home → Pause agents). Checked before every source, job step and Gemini call."""
from __future__ import annotations

import logging
import time

from . import db

log = logging.getLogger("jobfinder")
_cache = (0.0, False)
CACHE_SECONDS = 10


def paused() -> bool:
    global _cache
    checked_at, value = _cache
    if time.monotonic() - checked_at < CACHE_SECONDS:
        return value
    try:
        rows = db.sb.table("agent_control").select("paused").eq("id", 1).execute().data
        value = bool(rows and rows[0]["paused"])
    except Exception as exc:  # table missing (migration 005 not applied) → never paused
        log.debug("agent_control unavailable: %s", exc)
        value = False
    _cache = (time.monotonic(), value)
    return value
