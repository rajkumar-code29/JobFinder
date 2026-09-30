"""Thin Gemini wrapper: JSON output, Google-Search grounding, per-user key pool with fallback,
per-key pacing and a per-user call budget. Call `activate()` before processing each user."""
from __future__ import annotations

import json
import logging
import re
import time
from datetime import timedelta

from google import genai
from google.genai import errors, types

from . import config
from .keys import ALL_SCOPES, KeyPool, NoKeyAvailable, next_pacific_midnight, utcnow

log = logging.getLogger("jobfinder")


class StopUser(RuntimeError):
    """Stop LLM work for the current user this run; queued jobs continue next run."""


class BudgetExceeded(StopUser):
    pass


class KeysExhausted(StopUser):
    pass


class ModelUnavailable(StopUser):
    pass


_pool: KeyPool | None = None
_budget = 0
calls_made = 0
_clients: dict[str, genai.Client] = {}
_last_call: dict[str, float] = {}

# Google retires model versions ("…is no longer available…"). When that happens we ask the API which models
# exist and switch to the newest one of the same family for the rest of the run.
_replacements: dict[str, str] = {}
_retired: set[str] = set()
notices: list[str] = []  # surfaced in the run log by the pipeline
_fallbacks_noted: set[tuple[str, str]] = set()
_MODEL_NAME = re.compile(r"^gemini-(\d+(?:\.\d+)?)-(flash-lite|flash|pro)(?:-(.+))?$")


def _family(name: str) -> str | None:
    m = _MODEL_NAME.match(name)
    return m.group(2) if m else None


def _rank(name: str) -> tuple:
    """Newest version first; stable before preview/experimental/dated variants."""
    m = _MODEL_NAME.match(name)
    suffix = m.group(3) or ""
    stable = suffix in ("", "latest")
    return (float(m.group(1)), stable, suffix == "")


def _find_replacement(model: str, key) -> str | None:
    family = _family(model) or ("flash-lite" if "lite" in model else "flash")
    available = []
    for m in _client(key).models.list():
        name = (m.name or "").removeprefix("models/")
        actions = m.supported_actions or []
        if _family(name) == family and name not in _retired and ("generateContent" in actions or not actions):
            available.append(name)
    return max(available, key=_rank) if available else None


def _resolve(model: str) -> str:
    return _replacements.get(model, model)


def activate(pool: KeyPool, budget: int) -> None:
    """Start a user's turn: their key pool and budget. Notices are per user, so they reset too."""
    global _pool, _budget, calls_made
    _pool, _budget, calls_made = pool, budget, 0
    notices.clear()
    _fallbacks_noted.clear()


def _client(key) -> genai.Client:
    if key.fingerprint not in _clients:
        _clients[key.fingerprint] = genai.Client(api_key=key.value)
    return _clients[key.fingerprint]


MAX_WAIT_PER_CALL = 240  # seconds one request may spend waiting out per-minute limits before giving up
_interval: dict[str, float] = {}  # "<key>:<model>" -> seconds between calls; grows when Gemini says "too many"


def _slot(key, model: str) -> str:
    return f"{key.fingerprint}:{model}"


def _pace(key, model: str) -> None:
    slot = _slot(key, model)
    wait = _interval.get(slot, config.GEMINI_MIN_INTERVAL_SEC) - (time.monotonic() - _last_call.get(slot, 0.0))
    if wait > 0:
        time.sleep(wait)
    _last_call[slot] = time.monotonic()


def _slow_down(key, model: str) -> None:
    """Free-tier per-minute limits differ per model; converge on the real one by doubling the gap (max 60s)."""
    slot = _slot(key, model)
    _interval[slot] = min(60.0, max(_interval.get(slot, config.GEMINI_MIN_INTERVAL_SEC) * 2, 12.0))


def _retry_delay(msg: str) -> float:
    m = re.search(r"retry in ([\d.]+)s", msg) or re.search(r"retryDelay['\"]?:\s*['\"]?(\d+)s", msg)
    return float(m.group(1)) + 2 if m else 30.0


def _reason(code, msg: str) -> str:
    """Short, human-readable version of Google's error for the run log."""
    quota = re.search(r"quotaId['\"]?:\s*['\"]?([\w-]+)", msg) or re.search(r"metric:\s*[\w.-]*/([\w-]+)", msg)
    limit = re.search(r"limit:\s*(\d+)", msg)
    if quota or limit:
        return f"HTTP {code}: {quota.group(1) if quota else 'quota'}" + (f", limit {limit.group(1)}" if limit else "")
    text = re.search(r"'message':\s*'([^']+)", msg)
    return f"HTTP {code}: {(text.group(1) if text else msg)[:160]}"


def _add_notice(note: str) -> None:
    if note not in notices:
        notices.append(note)
        log.warning(note)


def _generate(prompt: str, *, system: str | None, chain: list[str], json_mode: bool, search: bool, temperature: float):
    """Try each model in `chain` in order (main model, then the lighter fallback) across all keys."""
    global calls_made
    if _pool is None:
        raise RuntimeError("llm.activate() was not called")
    if not _pool:
        raise KeysExhausted("No Gemini API key: add one in Settings → API keys")
    cfg = types.GenerateContentConfig(system_instruction=system, temperature=temperature)
    if search:
        # Grounding and JSON mime type can't be combined; we parse JSON out of the text instead.
        cfg.tools = [types.Tool(google_search=types.GoogleSearch())]
    elif json_mode:
        cfg.response_mime_type = "application/json"

    deadline = time.monotonic() + MAX_WAIT_PER_CALL
    last_error, server_errors = "no response", 0
    for position, configured in enumerate(chain):
        model = _resolve(configured)
        for _ in range(200):  # safety net; the deadline normally ends the loop
            if calls_made >= _budget:
                raise BudgetExceeded(f"Gemini call budget of {_budget} used for this run")
            try:
                key = _pool.get(model)
            except NoKeyAvailable:
                wait = _pool.seconds_until_free(model)
                if wait is not None and time.monotonic() + wait < deadline:
                    log.info("Gemini keys cooling down for %s, waiting %.0fs", model, wait)
                    time.sleep(wait + 1)
                    continue
                break  # every key is used up (or out of time) for this model: try the next model in the chain

            _pace(key, model)
            calls_made += 1
            try:
                resp = _client(key).models.generate_content(model=model, contents=prompt, config=cfg)
                _pool.used(key)
                return resp
            except errors.APIError as exc:
                code, msg = getattr(exc, "code", None), str(exc)
                if code == 429:
                    calls_made -= 1  # rejected calls don't count against the budget
                    last_error = _reason(code, msg)
                    if re.search(r"limit:\s*0\b", msg):
                        _pool.park(key, model, utcnow() + timedelta(hours=24), f"{model} is not available on this key's free tier")
                    elif "PerDay" in msg or "per day" in msg.lower():
                        _pool.park(key, model, next_pacific_midnight(), "daily free-tier quota reached")
                    else:
                        _pool.cool(key, model, _retry_delay(msg))
                        _slow_down(key, model)
                    continue
                if code == 404 and re.search(r"model", msg, re.I):
                    calls_made -= 1
                    last_error = _reason(code, msg)
                    _retired.add(model)
                    replacement = _find_replacement(model, key)
                    if not replacement:
                        break
                    _replacements[configured] = replacement
                    _add_notice(f"Gemini model {model} was retired by Google; switched to {replacement}. "
                                f"Update GEMINI_MODEL/GEMINI_FAST_MODEL.")
                    model = replacement
                    continue
                if code in (400, 401, 403) and re.search(r"API[_ ]KEY|api key|PERMISSION_DENIED|not valid", msg, re.I):
                    calls_made -= 1
                    last_error = _reason(code, msg)
                    _pool.park(key, ALL_SCOPES, utcnow() + timedelta(hours=24), f"rejected by Gemini (HTTP {code}): invalid or unauthorized key")
                    continue
                if code in (500, 502, 503, 504) and server_errors < 3:
                    server_errors += 1
                    time.sleep(10 * server_errors)
                    continue
                raise
        if position + 1 < len(chain) and (model, chain[position + 1]) not in _fallbacks_noted:
            _fallbacks_noted.add((model, chain[position + 1]))
            _add_notice(f"Gemini {model} unavailable for now ({last_error}); using {_resolve(chain[position + 1])} "
                        f"for the rest of this run.")
    raise KeysExhausted(f"Gemini limits reached on every key and model ({last_error}). "
                        f"Per-minute limits clear within a minute, daily limits at midnight Pacific.")


def _parse_json(text: str):
    text = (text or "").strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    fence = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    if fence:
        try:
            return json.loads(fence.group(1))
        except json.JSONDecodeError:
            pass
    start = min([i for i in (text.find("{"), text.find("[")) if i >= 0], default=-1)
    if start >= 0:
        end = max(text.rfind("}"), text.rfind("]"))
        return json.loads(text[start:end + 1])
    raise ValueError(f"Model did not return JSON: {text[:300]}")


def _chain(fast: bool) -> list[str]:
    """Bulk rating uses the light model only; everything else prefers the main model and falls back to the light one."""
    chain = [config.GEMINI_FAST_MODEL] if fast else [config.GEMINI_MODEL, config.GEMINI_FAST_MODEL]
    return list(dict.fromkeys(chain))


def ask_json(prompt: str, *, system: str | None = None, fast: bool = False, temperature: float = 0.3):
    resp = _generate(prompt, system=system, chain=_chain(fast), json_mode=True, search=False, temperature=temperature)
    return _parse_json(resp.text)


def search_json(prompt: str, *, system: str | None = None) -> tuple[object, list[dict]]:
    """Grounded with Google Search. Returns (parsed_json, sources[{title, uri}])."""
    resp = _generate(prompt, system=system, chain=_chain(False), json_mode=False, search=True, temperature=0.2)
    sources = []
    try:
        meta = resp.candidates[0].grounding_metadata
        for chunk in (meta.grounding_chunks or []) if meta else []:
            if chunk.web:
                sources.append({"title": chunk.web.title, "uri": chunk.web.uri})
    except (AttributeError, IndexError):
        pass
    return _parse_json(resp.text), sources
