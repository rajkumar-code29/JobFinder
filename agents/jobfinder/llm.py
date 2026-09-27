"""Thin Gemini wrapper: JSON output, Google-Search grounding, free-tier pacing and a per-run call budget."""
from __future__ import annotations

import json
import logging
import re
import time

from google import genai
from google.genai import errors, types

from . import config

log = logging.getLogger("jobfinder")

_client = genai.Client(api_key=config.GEMINI_API_KEY)
_last_call = 0.0
calls_made = 0


class BudgetExceeded(RuntimeError):
    """Raised when this run has used its LLM budget; remaining work waits for the next run."""


def _pace() -> None:
    global _last_call, calls_made
    if calls_made >= config.LLM_MAX_CALLS_PER_RUN:
        raise BudgetExceeded(f"LLM call budget of {config.LLM_MAX_CALLS_PER_RUN} used for this run")
    wait = config.GEMINI_MIN_INTERVAL_SEC - (time.monotonic() - _last_call)
    if wait > 0:
        time.sleep(wait)
    _last_call = time.monotonic()
    calls_made += 1


def _generate(prompt: str, *, system: str | None, model: str, json_mode: bool, search: bool, temperature: float):
    cfg = types.GenerateContentConfig(system_instruction=system, temperature=temperature)
    if search:
        # Grounding and JSON mime type can't be combined; we parse JSON out of the text instead.
        cfg.tools = [types.Tool(google_search=types.GoogleSearch())]
    elif json_mode:
        cfg.response_mime_type = "application/json"

    for attempt in range(5):
        _pace()
        try:
            return _client.models.generate_content(model=model, contents=prompt, config=cfg)
        except errors.APIError as exc:
            code = getattr(exc, "code", None)
            if code in (429, 500, 503) and attempt < 4:
                delay = min(90, 15 * (attempt + 1))
                m = re.search(r"retry in ([\d.]+)s", str(exc))
                if m:
                    delay = float(m.group(1)) + 2
                log.warning("Gemini %s, retrying in %.0fs", code, delay)
                time.sleep(delay)
                continue
            raise


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
