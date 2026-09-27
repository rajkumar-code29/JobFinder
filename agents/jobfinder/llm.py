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


_pool: KeyPool | None = None
_budget = 0
calls_made = 0
_clients: dict[str, genai.Client] = {}
_last_call: dict[str, float] = {}


def activate(pool: KeyPool, budget: int) -> None:
    global _pool, _budget, calls_made
    _pool, _budget, calls_made = pool, budget, 0


def _client(key) -> genai.Client:
    if key.fingerprint not in _clients:
        _clients[key.fingerprint] = genai.Client(api_key=key.value)
    return _clients[key.fingerprint]


def _pace(key) -> None:
    wait = config.GEMINI_MIN_INTERVAL_SEC - (time.monotonic() - _last_call.get(key.fingerprint, 0.0))
    if wait > 0:
        time.sleep(wait)
    _last_call[key.fingerprint] = time.monotonic()


def _retry_delay(msg: str) -> float:
    m = re.search(r"retry in ([\d.]+)s", msg) or re.search(r"retryDelay['\"]?:\s*['\"]?(\d+)s", msg)
    return float(m.group(1)) + 2 if m else 30.0


def _generate(prompt: str, *, system: str | None, model: str, json_mode: bool, search: bool, temperature: float):
    global calls_made
    if _pool is None:
        raise RuntimeError("llm.activate() was not called")
    cfg = types.GenerateContentConfig(system_instruction=system, temperature=temperature)
    if search:
        # Grounding and JSON mime type can't be combined; we parse JSON out of the text instead.
        cfg.tools = [types.Tool(google_search=types.GoogleSearch())]
    elif json_mode:
        cfg.response_mime_type = "application/json"

    server_errors = 0
    for _ in range(len(_pool.keys) * 4 + 6):
        if calls_made >= _budget:
            raise BudgetExceeded(f"Gemini call budget of {_budget} used for this run")
        try:
            key = _pool.get(model)
        except NoKeyAvailable:
            wait = _pool.seconds_until_free(model)
            if wait is not None and wait <= 120:
                log.info("All Gemini keys cooling down, waiting %.0fs", wait)
                time.sleep(wait + 1)
                continue
            if not _pool:
                raise KeysExhausted("No Gemini API key: add one in Settings → API keys")
            raise KeysExhausted(f"All Gemini keys have hit their limit for {model}; they reset at midnight Pacific")

        _pace(key)
        calls_made += 1
        try:
            resp = _client(key).models.generate_content(model=model, contents=prompt, config=cfg)
            _pool.used(key)
            return resp
        except errors.APIError as exc:
            code, msg = getattr(exc, "code", None), str(exc)
            if code == 429:
                calls_made -= 1  # rejected calls don't count against the budget
                if "PerDay" in msg or "per day" in msg.lower():
                    _pool.park(key, model, next_pacific_midnight(), "daily free-tier quota reached")
                else:
                    _pool.cool(key, model, _retry_delay(msg))
                    log.info("Gemini %s per-minute limit, switching key", key.name)
                continue
            if code in (400, 401, 403) and re.search(r"API[_ ]KEY|api key|PERMISSION_DENIED|not valid", msg, re.I):
                calls_made -= 1
                _pool.park(key, ALL_SCOPES, utcnow() + timedelta(hours=24), f"rejected by Gemini (HTTP {code}): invalid or unauthorized key")
                continue
            if code in (500, 502, 503, 504) and server_errors < 3:
                server_errors += 1
                time.sleep(10 * server_errors)
                continue
            raise
    raise KeysExhausted("Gemini kept rejecting requests; try again next run")


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
    model = config.GEMINI_FAST_MODEL if fast else config.GEMINI_MODEL
    resp = _generate(prompt, system=system, model=model, json_mode=True, search=False, temperature=temperature)
    return _parse_json(resp.text)


def search_json(prompt: str, *, system: str | None = None) -> tuple[object, list[dict]]:
    """Grounded with Google Search. Returns (parsed_json, sources[{title, uri}])."""
    resp = _generate(prompt, system=system, model=config.GEMINI_MODEL, json_mode=False, search=True, temperature=0.2)
    sources = []
    try:
        meta = resp.candidates[0].grounding_metadata
        for chunk in (meta.grounding_chunks or []) if meta else []:
            if chunk.web:
                sources.append({"title": chunk.web.title, "uri": chunk.web.uri})
    except (AttributeError, IndexError):
        pass
    return _parse_json(resp.text), sources
