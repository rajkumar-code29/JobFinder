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


class RateLimited(StopUser):
    """Circuit breaker tripped: Gemini keeps saying 'too many requests'. Stop, don't hammer the account."""


class Paused(StopUser):
    """An admin switched the agents off (kill switch): stop everything at the next step."""


class SearchUnavailable(RuntimeError):
    """Google-grounded search is being rate-limited: skip search for the rest of the run (other work continues)."""


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
    """Stable before preview/dated variants, then newest version first."""
    m = _MODEL_NAME.match(name)
    suffix = m.group(3) or ""
    return (suffix in ("", "latest"), float(m.group(1)), suffix == "")


_SPECIAL = re.compile(r"tts|image|audio|live|transcribe|robotics|native|embedding|computer", re.I)
_discovered: dict[str, list[str]] | None = None
FALLBACK_MODELS = {"flash": ["gemini-3.5-flash"], "flash-lite": ["gemini-3.5-flash-lite"]}


def _discover(key) -> dict[str, list[str]]:
    """Text models this key can call, per family, best first. One cheap list call per run."""
    global _discovered
    if _discovered is None:
        found: dict[str, list[str]] = {"flash": [], "flash-lite": []}
        try:
            for m in _client(key).models.list():
                name = (m.name or "").removeprefix("models/")
                family, actions = _family(name), (m.supported_actions or [])
                if family in found and not _SPECIAL.search(name) and (not actions or "generateContent" in actions):
                    found[family].append(name)
        except Exception as exc:
            log.warning("could not list Gemini models (%s); using defaults", exc)
        for family, names in found.items():
            names.sort(key=_rank, reverse=True)
            if not any(_rank(n)[0] for n in names):  # no stable model at all: keep previews
                continue
            found[family] = [n for n in names if _rank(n)[0]]
        _discovered = found
    return _discovered


def _family_models(family: str, preferred: str, key) -> list[str]:
    names = _discover(key)[family] or FALLBACK_MODELS[family]
    first = [] if preferred == "auto" else [preferred]
    if config.GEMINI_USE_ALL_MODELS:
        rest = names          # each model has its own daily allowance: use them in turn
    else:
        rest = [] if first else names[:1]
    return list(dict.fromkeys(first + rest))


def _find_replacement(model: str, key) -> str | None:
    family = _family(model) or ("flash-lite" if "lite" in model else "flash")
    candidates = [n for n in _discover(key)[family] if n not in _retired]
    return candidates[0] if candidates else None


def build_chain(tier: str, key) -> list[str]:
    """Models to try, in order, for a kind of work.
    light    – rating/scoring: flash-lite models (500/day each on the free tier)
    search   – Google-grounded search: flash-lite, then flash
    standard – tailoring, interview prep, cover letters: flash models (20/day each), then flash-lite"""
    lite = _family_models("flash-lite", config.GEMINI_FAST_MODEL, key)
    flash = _family_models("flash", config.GEMINI_MODEL, key)
    chain = {"light": lite, "search": lite + flash, "standard": flash + lite}[tier]
    now = time.monotonic()
    chain = [m for m in dict.fromkeys(chain) if m not in _retired]
    # Models Google reported as overloaded go to the back for a few minutes (still tried if nothing else is left).
    return [m for m in chain if _overloaded.get(m, 0) <= now] + [m for m in chain if _overloaded.get(m, 0) > now]


def _resolve(model: str) -> str:
    return _replacements.get(model, model)


# Circuit breaker. Only per-minute style rejections count: daily-limit / "limit: 0" answers park the key and are
# never retried, so they aren't hammering.
MAX_CONSECUTIVE_REJECTIONS = 4   # in a row without any success
MAX_REJECTIONS_PER_RUN = 12
MAX_SEARCH_REJECTIONS = 2        # Google-grounded search gives up sooner; it's optional
BREAKER_PAUSE = timedelta(hours=1)
_rejections = _consecutive = _search_rejections = 0
_rejected_keys: dict[str, object] = {}
_search_disabled = False
_on_event = None
_should_stop = lambda: False  # noqa: E731 – replaced per run with the kill-switch check
_overloaded: dict[str, float] = {}  # model -> monotonic time until which it's skipped (503 "high demand")
OVERLOAD_PAUSE = 300


def activate(pool: KeyPool, budget: int, on_event=None, should_stop=None) -> None:
    """Start a user's turn: their key pool, budget and breaker. Notices are per user, so they reset too."""
    global _pool, _budget, calls_made, _rejections, _consecutive, _search_rejections, _search_disabled, _on_event, _should_stop
    _should_stop = should_stop or (lambda: False)
    _pool, _budget, calls_made = pool, budget, 0
    _rejections = _consecutive = _search_rejections = 0
    _search_disabled = False
    _rejected_keys.clear()
    _on_event = on_event
    notices.clear()
    _fallbacks_noted.clear()


def _event(message: str) -> None:
    log.warning(message)
    if _on_event:
        try:
            _on_event(message)
        except Exception:
            pass


def _rejected(key, model: str, reason: str, search: bool) -> None:
    """Count a per-minute style rejection; trip the breaker when Gemini keeps refusing."""
    global _rejections, _consecutive, _search_rejections, _search_disabled
    _rejections += 1
    _consecutive += 1
    _rejected_keys[key.fingerprint] = key
    if _rejections <= 6:
        _event(f"Gemini rejected a request ({model}, {reason})")
    if search:
        _search_rejections += 1
        if _search_rejections >= MAX_SEARCH_REJECTIONS:
            _search_disabled = True
            _event("Google-grounded search keeps being rate-limited: skipping it for the rest of this run")
            raise SearchUnavailable("Google search rate-limited")
    if _consecutive >= MAX_CONSECUTIVE_REJECTIONS or _rejections >= MAX_REJECTIONS_PER_RUN:
        until = utcnow() + BREAKER_PAUSE
        for k in _rejected_keys.values():
            _pool.park(k, ALL_SCOPES, until, f"paused by circuit breaker after repeated 429s ({reason})")
        raise RateLimited(
            f"Gemini rejected {_rejections} requests ({reason}). Stopped Gemini work for this run to protect the "
            f"account; the rejected keys are paused until {until:%H:%M} UTC.")


def _client(key) -> genai.Client:
    if key.fingerprint not in _clients:
        _clients[key.fingerprint] = genai.Client(api_key=key.value)
    return _clients[key.fingerprint]


MAX_WAIT_PER_CALL = 90   # seconds one request may spend waiting out per-minute limits before giving up
MAX_WAIT_PER_SEARCH = 30
_interval: dict[str, float] = {}  # "<key>:<model>" -> seconds between calls; grows when Gemini says "too many"


def _slot(key, model: str) -> str:
    return f"{key.fingerprint}:{model}"


def _base_interval(model: str) -> float:
    """Start at the free-tier pace for the family (flash 5/min, flash-lite 15/min) unless configured."""
    if config.GEMINI_MIN_INTERVAL_SEC is not None:
        return config.GEMINI_MIN_INTERVAL_SEC
    return {"flash": 12.5, "flash-lite": 4.5}.get(_family(model) or "", 6.0)


def _pace(key, model: str) -> None:
    slot = _slot(key, model)
    wait = _interval.get(slot, _base_interval(model)) - (time.monotonic() - _last_call.get(slot, 0.0))
    if wait > 0:
        time.sleep(wait)
    _last_call[slot] = time.monotonic()


def _slow_down(key, model: str) -> None:
    """Free-tier per-minute limits differ per model; converge on the real one by doubling the gap (max 60s)."""
    slot = _slot(key, model)
    _interval[slot] = min(60.0, max(_interval.get(slot, _base_interval(model)) * 2, 12.0))


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


def _generate(prompt: str, *, system: str | None, tier: str, json_mode: bool, search: bool, temperature: float):
    """Try each model of the tier's chain in order, across all keys."""
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

    global _consecutive
    if search and _search_disabled:
        raise SearchUnavailable("Google search skipped for the rest of this run (rate-limited)")
    chain = build_chain(tier, _pool.keys[0])
    deadline = time.monotonic() + (MAX_WAIT_PER_SEARCH if search else MAX_WAIT_PER_CALL)
    last_error, server_errors = "no response", 0
    for position, configured in enumerate(chain):
        model = _resolve(configured)
        for _ in range(200):  # safety net; the deadline normally ends the loop
            if _should_stop():
                raise Paused("Agents paused by an admin")
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
                _consecutive = 0
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
                        _rejected(key, model, last_error, search)  # may stop the run (breaker)
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
                if code in (500, 502, 503, 504):
                    # "This model is currently experiencing high demand": not our quota, not the key. Move on to the
                    # next model in the chain instead of failing the job; come back to this one in a few minutes.
                    calls_made -= 1
                    server_errors += 1
                    last_error = _reason(code, msg)
                    _overloaded[model] = time.monotonic() + OVERLOAD_PAUSE
                    if server_errors <= 3:
                        _event(f"Gemini {model} overloaded ({last_error}); trying the next model")
                    break
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


def ask_json(prompt: str, *, system: str | None = None, fast: bool = False, temperature: float = 0.3):
    """fast=True for high-volume work (rating, scoring) on flash-lite; otherwise flash with flash-lite fallback.
    Malformed JSON gets one retry with a stricter instruction before failing."""
    tier = "light" if fast else "standard"
    resp = _generate(prompt, system=system, tier=tier, json_mode=True, search=False, temperature=temperature)
    try:
        return _parse_json(resp.text)
    except ValueError as exc:  # json.JSONDecodeError is a ValueError
        _event(f"Model returned invalid JSON ({exc}); retrying once")
        resp = _generate(prompt + "\n\nReturn ONLY valid JSON: double-quoted keys and strings, no comments, "
                         "no trailing commas.", system=system, tier=tier, json_mode=True, search=False, temperature=0)
        return _parse_json(resp.text)


def search_json(prompt: str, *, system: str | None = None) -> tuple[object, list[dict]]:
    """Grounded with Google Search. Returns (parsed_json, sources[{title, uri}])."""
    resp = _generate(prompt, system=system, tier="search", json_mode=False, search=True, temperature=0.2)
    sources = []
    try:
        meta = resp.candidates[0].grounding_metadata
        for chunk in (meta.grounding_chunks or []) if meta else []:
            if chunk.web:
                sources.append({"title": chunk.web.title, "uri": chunk.web.uri})
    except (AttributeError, IndexError):
        pass
    return _parse_json(resp.text), sources
