"""AI layer for all agents: per-agent model routing across providers (Gemini natively, Groq/OpenRouter via
OpenAI-compatible APIs), per-user key pools with fallback, pacing, a circuit breaker, kill-switch checks,
a per-user call budget and per-model statistics for the scorecard.

Routing: each agent has an ordered list of model specs (admin → Models → Routing), e.g.
    tailor: ["gemini:flash", "gemini:flash-lite"]      scout: ["groq:openai/gpt-oss-120b", "gemini:flash-lite"]
"gemini:flash" / "gemini:flash-lite" expand to every available model of that family, newest first (each has its
own free daily allowance). Web-search work (salary, search) can only use Gemini (Google Search grounding).
Call `activate()` before processing each user.
"""
from __future__ import annotations

import json
import logging
import re
import time
from collections import Counter
from datetime import timedelta

import json_repair
from google import genai
from google.genai import errors, types

from . import config, providers
from .keys import ALL_SCOPES, KeyPool, NoKeyAvailable, next_pacific_midnight, utcnow

log = logging.getLogger("jobfinder")


class StopUser(RuntimeError):
    """Stop AI work for the current user this run; queued jobs continue next run."""


class BudgetExceeded(StopUser):
    pass


class KeysExhausted(StopUser):
    pass


class ModelUnavailable(StopUser):
    pass


class RateLimited(StopUser):
    """Circuit breaker tripped: a provider keeps saying 'too many requests'. Stop, don't hammer the account."""


class Paused(StopUser):
    """An admin switched the agents off (kill switch): stop everything at the next step."""


class SearchUnavailable(RuntimeError):
    """Google-grounded search is being rate-limited: skip search for the rest of the run (other work continues)."""


# ---------------------------------------------------------------------------------------------- routing
AGENTS = ("profile", "scout", "salary", "search", "scorer", "tailor", "coach", "writer")
SEARCH_AGENTS = ("salary", "search")  # need Google Search grounding → Gemini only
DEFAULT_ROUTING = {
    "profile": ["gemini:flash", "gemini:flash-lite"],
    "scout": ["gemini:flash-lite"],
    "salary": ["gemini:flash-lite", "gemini:flash"],
    "search": ["gemini:flash-lite", "gemini:flash"],
    "scorer": ["gemini:flash-lite"],
    "tailor": ["gemini:flash", "gemini:flash-lite"],
    "coach": ["gemini:flash", "gemini:flash-lite"],
    "writer": ["gemini:flash", "gemini:flash-lite"],
}
# Room for the answer. Interview packs are long (~10k tokens); a cut-off answer is broken JSON.
MAX_OUTPUT_TOKENS = {"coach": 32768, "tailor": 16384, "profile": 8192, "scorer": 8192}
DEFAULT_OUTPUT_TOKENS = 8192
_routing: dict[str, list[str]] = dict(DEFAULT_ROUTING)


def set_routing(routing: dict[str, list[str]] | None) -> None:
    """Admin-configured routing (missing agents keep the defaults)."""
    global _routing
    _routing = {**DEFAULT_ROUTING, **{a: list(c) for a, c in (routing or {}).items() if c}}


def routing() -> dict[str, list[str]]:
    return dict(_routing)


# ---------------------------------------------------------------------------------------------- state
_pools: dict[str, KeyPool] = {}
_budget = 0
calls_made = 0
last_model: str | None = None  # "provider:model" that answered the most recent successful call
_clients: dict[str, genai.Client] = {}
_next_ok: dict[str, float] = {}   # "<key>:<model>" -> monotonic time of the next allowed call
_interval: dict[str, float] = {}  # "<key>:<model>" -> seconds between calls; grows on per-minute rejections

# Google retires model versions ("…is no longer available…"): discover what exists and switch.
_replacements: dict[str, str] = {}
_retired: set[str] = set()        # "provider:model"
notices: list[str] = []           # surfaced in the run log by the pipeline
_fallbacks_noted: set[tuple[str, str]] = set()
_MODEL_NAME = re.compile(r"^gemini-(\d+(?:\.\d+)?)-(flash-lite|flash|pro)(?:-(.+))?$")
_SPECIAL = re.compile(r"tts|image|audio|live|transcribe|robotics|native|embedding|computer", re.I)
_discovered: dict[str, list[str]] | None = None
FALLBACK_MODELS = {"flash": ["gemini-3.5-flash"], "flash-lite": ["gemini-3.5-flash-lite"]}

# Circuit breaker. Only per-minute style rejections count: daily-limit / "limit: 0" answers park the key.
MAX_CONSECUTIVE_REJECTIONS = 4   # in a row without any success
MAX_REJECTIONS_PER_RUN = 12
MAX_SEARCH_REJECTIONS = 2        # Google-grounded search gives up sooner; it's optional
BREAKER_PAUSE = timedelta(hours=1)
MAX_WAIT_PER_CALL = 90           # seconds one request may spend waiting out per-minute limits
MAX_WAIT_PER_SEARCH = 30
OVERLOAD_PAUSE = 300
_rejections = _consecutive = _search_rejections = 0
_rejected_keys: dict[str, tuple[KeyPool, object]] = {}
_search_disabled = False
_on_event = None
_should_stop = lambda: False  # noqa: E731 – replaced per run with the kill-switch check
_overloaded: dict[str, float] = {}  # "provider:model" -> monotonic time until which it goes to the back

# Scorecard: per (agent, "provider:model") counters, flushed by the pipeline after each user.
_stats: dict[tuple[str, str], Counter] = {}


def activate(pools: dict[str, KeyPool] | KeyPool, budget: int, on_event=None, should_stop=None) -> None:
    """Start a user's turn: their key pools, budget and breaker. Notices are per user, so they reset too."""
    global _pools, _budget, calls_made, _rejections, _consecutive, _search_rejections, _search_disabled
    global _on_event, _should_stop, last_model
    _pools = pools if isinstance(pools, dict) else {"gemini": pools}
    _should_stop = should_stop or (lambda: False)
    _budget, calls_made, last_model = budget, 0, None
    _rejections = _consecutive = _search_rejections = 0
    _search_disabled = False
    _rejected_keys.clear()
    _on_event = on_event
    notices.clear()
    _fallbacks_noted.clear()


def take_stats() -> list[dict]:
    """Counters since the last call, for db.record_model_stats()."""
    rows = [{"agent": a, "model": m, **dict(c)} for (a, m), c in _stats.items()]
    _stats.clear()
    return rows


def _stat(agent: str, spec: str, **inc) -> None:
    c = _stats.setdefault((agent, spec), Counter())
    for k, v in inc.items():
        c[k] += v


def _event(message: str) -> None:
    log.warning(message)
    if _on_event:
        try:
            _on_event(message)
        except Exception:
            pass


def _add_notice(note: str) -> None:
    if note not in notices:
        notices.append(note)
        log.warning(note)


# ---------------------------------------------------------------------------------------------- Gemini models
def _family(name: str) -> str | None:
    m = _MODEL_NAME.match(name)
    return m.group(2) if m else None


def _rank(name: str) -> tuple:
    """Stable before preview/dated variants, then newest version first."""
    m = _MODEL_NAME.match(name)
    suffix = m.group(3) or ""
    return (suffix in ("", "latest"), float(m.group(1)), suffix == "")


def _client(key) -> genai.Client:
    if key.fingerprint not in _clients:
        _clients[key.fingerprint] = genai.Client(api_key=key.value)
    return _clients[key.fingerprint]


def _discover(key) -> dict[str, list[str]]:
    """Gemini text models this key can call, per family, best first. One cheap list call per run."""
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
            if any(_rank(n)[0] for n in names):  # prefer stable models when there are any
                found[family] = [n for n in names if _rank(n)[0]]
        _discovered = found
    return _discovered


def _gemini_family(family: str, preferred: str) -> list[str]:
    pool = _pools.get("gemini")
    names = (_discover(pool.keys[0])[family] if pool else []) or FALLBACK_MODELS[family]
    first = [] if preferred == "auto" else [preferred]
    rest = names if config.GEMINI_USE_ALL_MODELS else ([] if first else names[:1])
    return list(dict.fromkeys(first + rest))


def _find_replacement(model: str, key) -> str | None:
    family = _family(model) or ("flash-lite" if "lite" in model else "flash")
    candidates = [n for n in _discover(key)[family] if f"gemini:{n}" not in _retired]
    return candidates[0] if candidates else None


def _expand(spec: str) -> list[tuple[str, str]]:
    provider, _, model = spec.partition(":")
    if provider == "gemini" and model in ("flash", "flash-lite"):
        preferred = config.GEMINI_MODEL if model == "flash" else config.GEMINI_FAST_MODEL
        return [("gemini", m) for m in _gemini_family(model, preferred)]
    return [(provider, model)] if model else []


def build_chain(agent: str) -> list[tuple[str, str]]:
    """(provider, model) pairs to try, in order, for an agent. Skips providers without keys, retired models and
    (for web search) non-Gemini models; overloaded models go to the back for a few minutes."""
    chain: list[tuple[str, str]] = []
    for spec in _routing.get(agent) or DEFAULT_ROUTING.get(agent, ["gemini:flash"]):
        for provider, model in _expand(spec):
            if agent in SEARCH_AGENTS and provider != "gemini":
                continue
            if not _pools.get(provider) or (provider not in ("gemini",) and provider not in providers.OPENAI_COMPATIBLE):
                continue
            pair = (provider, _replacements.get(f"{provider}:{model}", model))
            if f"{pair[0]}:{pair[1]}" not in _retired and pair not in chain:
                chain.append(pair)
    now = time.monotonic()
    return ([p for p in chain if _overloaded.get(f"{p[0]}:{p[1]}", 0) <= now]
            + [p for p in chain if _overloaded.get(f"{p[0]}:{p[1]}", 0) > now])


# ---------------------------------------------------------------------------------------------- pacing
def _base_interval(provider: str, model: str) -> float:
    if provider == "gemini":
        if config.GEMINI_MIN_INTERVAL_SEC is not None:
            return config.GEMINI_MIN_INTERVAL_SEC
        return {"flash": 12.5, "flash-lite": 4.5}.get(_family(model) or "", 6.0)
    return providers.OPENAI_COMPATIBLE[provider].get("min_interval") or 3.0


def _pace(key, provider: str, model: str) -> None:
    slot = f"{key.fingerprint}:{model}"
    wait = _next_ok.get(slot, 0.0) - time.monotonic()
    if wait > 0:
        time.sleep(wait)
    _next_ok[slot] = time.monotonic() + _interval.get(slot, _base_interval(provider, model))


def _after_success(key, provider: str, model: str, tokens: int | None) -> None:
    """Token-per-minute limited providers (Groq free: 8k/min): wait long enough for the tokens just used."""
    tpm = providers.OPENAI_COMPATIBLE.get(provider, {}).get("tokens_per_minute")
    if tpm and tokens:
        slot = f"{key.fingerprint}:{model}"
        _next_ok[slot] = max(_next_ok.get(slot, 0.0), time.monotonic() + tokens / tpm * 60)


def _slow_down(key, provider: str, model: str) -> None:
    """Converge on the real per-minute limit by doubling the gap (max 60s)."""
    slot = f"{key.fingerprint}:{model}"
    _interval[slot] = min(60.0, max(_interval.get(slot, _base_interval(provider, model)) * 2, 12.0))


def _retry_delay(msg: str) -> float:
    m = (re.search(r"retry in ([\d.]+)s", msg) or re.search(r"retryDelay['\"]?:\s*['\"]?(\d+)s", msg)
         or re.search(r"try again in ([\d.]+)s", msg))
    return float(m.group(1)) + 2 if m else 30.0


def _reason(provider: str, code, msg: str) -> str:
    """Short, human-readable version of the provider's error for the run log."""
    quota = re.search(r"quotaId['\"]?:\s*['\"]?([\w-]+)", msg) or re.search(r"metric:\s*[\w.-]*/([\w-]+)", msg)
    limit = re.search(r"limit:\s*(\d+)", msg, re.I)
    if provider == "gemini" and (quota or limit):
        return f"HTTP {code}: {quota.group(1) if quota else 'quota'}" + (f", limit {limit.group(1)}" if limit else "")
    text = re.search(r"'message':\s*'([^']+)", msg)
    return f"HTTP {code}: {(text.group(1) if text else msg)[:160]}"


def _classify(provider: str, code, msg: str, retry_after: float | None):
    """→ (kind, detail): minute (seconds), day (until), limit0, overloaded, too_large, model_gone, invalid_key, other"""
    low = msg.lower()
    if code == 429:
        if re.search(r"limit:\s*0\b", msg):
            return "limit0", None
        if provider == "gemini":
            if "PerDay" in msg or "per day" in low:
                return "day", next_pacific_midnight()
            return "minute", _retry_delay(msg)
        if re.search(r"per day|\(rpd\)|\(tpd\)|per-day|free-models-per-day", low):
            return "day", utcnow() + timedelta(seconds=max(retry_after or 3600, 600))
        return "minute", (retry_after + 1 if retry_after else _retry_delay(msg))
    if code == 413 or (code == 400 and re.search(r"too large|context length|maximum context|reduce the length", low)):
        return "too_large", None
    if code == 404 and "model" in low:
        return "model_gone", None
    if code in (401, 403) or (code == 400 and re.search(r"api[_ ]key|not valid|invalid.{0,20}key", low)):
        return "invalid_key", None
    if code and int(code) >= 500:
        return "overloaded", None
    return "other", None


def _rejected(pool: KeyPool, key, provider: str, model: str, reason: str, search: bool) -> None:
    """Count a per-minute style rejection; trip the breaker when a provider keeps refusing."""
    global _rejections, _consecutive, _search_rejections, _search_disabled
    _rejections += 1
    _consecutive += 1
    _rejected_keys[key.fingerprint] = (pool, key)
    if _rejections <= 6:
        _event(f"{providers.label(provider)} rejected a request ({model}, {reason})")
    if search:
        _search_rejections += 1
        if _search_rejections >= MAX_SEARCH_REJECTIONS:
            _search_disabled = True
            _event("Google-grounded search keeps being rate-limited: skipping it for the rest of this run")
            raise SearchUnavailable("Google search rate-limited")
    if _consecutive >= MAX_CONSECUTIVE_REJECTIONS or _rejections >= MAX_REJECTIONS_PER_RUN:
        until = utcnow() + BREAKER_PAUSE
        for p, k in _rejected_keys.values():
            p.park(k, ALL_SCOPES, until, f"paused by circuit breaker after repeated 429s ({reason})")
        raise RateLimited(
            f"AI providers rejected {_rejections} requests ({reason}). Stopped AI work for this run to protect "
            f"the accounts; the rejected keys are paused until {until:%H:%M} UTC.")


# ---------------------------------------------------------------------------------------------- calls
def _call(provider: str, key, model: str, prompt: str, system: str | None, json_mode: bool, search: bool,
          temperature: float, max_tokens: int):
    """One request. Returns (text, grounding sources, tokens)."""
    if provider == "gemini":
        cfg = types.GenerateContentConfig(system_instruction=system, temperature=temperature,
                                          max_output_tokens=max_tokens)
        if search:  # grounding and JSON mime type can't be combined; JSON is parsed out of the text instead
            cfg.tools = [types.Tool(google_search=types.GoogleSearch())]
        elif json_mode:
            cfg.response_mime_type = "application/json"
        resp = _client(key).models.generate_content(model=model, contents=prompt, config=cfg)
        sources = []
        try:
            meta = resp.candidates[0].grounding_metadata
            for chunk in (meta.grounding_chunks or []) if meta else []:
                if chunk.web:
                    sources.append({"title": chunk.web.title, "uri": chunk.web.uri})
        except (AttributeError, IndexError, TypeError):
            pass
        usage = getattr(resp, "usage_metadata", None)
        try:
            if "MAX_TOKENS" in str(resp.candidates[0].finish_reason):
                _event(f"{model} hit its output limit ({max_tokens} tokens); the answer may be cut short")
        except (AttributeError, IndexError, TypeError):
            pass
        return resp.text, sources, getattr(usage, "total_token_count", None)
    text, tokens = providers.chat(provider, key.value, model, system, prompt, json_mode=json_mode,
                                  temperature=temperature, max_tokens=max_tokens)
    return text, [], tokens


def _generate(prompt: str, *, agent: str, system: str | None, json_mode: bool, search: bool, temperature: float):
    global calls_made, _consecutive, last_model
    if not _pools:
        raise RuntimeError("llm.activate() was not called")
    if search and _search_disabled:
        raise SearchUnavailable("Google search skipped for the rest of this run (rate-limited)")
    chain = build_chain(agent)
    if not chain:
        raise KeysExhausted(f"No usable model for the {agent} agent: add an API key for its providers "
                            f"(Settings → API keys) or change its routing")
    deadline = time.monotonic() + (MAX_WAIT_PER_SEARCH if search else MAX_WAIT_PER_CALL)
    est_tokens = (len(prompt) + len(system or "")) // 4
    out_tokens = MAX_OUTPUT_TOKENS.get(agent, DEFAULT_OUTPUT_TOKENS)
    last_error, server_errors = "no response", 0

    for position, (provider, model) in enumerate(chain):
        spec = f"{provider}:{model}"
        pool = _pools[provider]
        limit = providers.OPENAI_COMPATIBLE.get(provider, {}).get("max_request_tokens")
        max_tokens = out_tokens
        if limit:
            if est_tokens + 512 > limit:  # the free tier would refuse it anyway: don't spend a request
                _stat(agent, spec, too_large=1)
                last_error = f"{providers.label(provider)}: request of ~{est_tokens} tokens exceeds its {limit}-token limit"
                continue
            max_tokens = min(out_tokens, limit - est_tokens)
        for _ in range(200):  # safety net; the deadline normally ends the loop
            if _should_stop():
                raise Paused("Agents paused by an admin")
            if calls_made >= _budget:
                raise BudgetExceeded(f"AI call budget of {_budget} used for this run")
            try:
                key = pool.get(model)
            except NoKeyAvailable:
                wait = pool.seconds_until_free(model)
                if wait is not None and time.monotonic() + wait < deadline:
                    log.info("%s keys cooling down for %s, waiting %.0fs", providers.label(provider), model, wait)
                    time.sleep(wait + 1)
                    continue
                break  # every key used up (or out of time) for this model: next model in the chain

            _pace(key, provider, model)
            calls_made += 1
            started = time.monotonic()
            try:
                text, sources, tokens = _call(provider, key, model, prompt, system, json_mode, search, temperature, max_tokens)
            except (errors.APIError, providers.ProviderError) as exc:
                code = getattr(exc, "code", None)
                msg = exc.message if isinstance(exc, providers.ProviderError) else str(exc)
                kind, detail = _classify(provider, code, msg, getattr(exc, "retry_after", None))
                calls_made -= 1  # rejected calls don't count against the budget
                last_error = _reason(provider, code, msg)
                if kind == "minute":
                    _stat(agent, spec, rate_limited=1)
                    pool.cool(key, model, detail)
                    _slow_down(key, provider, model)
                    _rejected(pool, key, provider, model, last_error, search)  # may stop the run (breaker)
                    continue
                if kind in ("day", "limit0"):
                    _stat(agent, spec, rate_limited=1)
                    until = detail if kind == "day" else utcnow() + timedelta(hours=24)
                    pool.park(key, model, until, "daily free-tier limit reached" if kind == "day"
                              else f"{model} is not available on this key's free tier")
                    continue
                if kind == "too_large":
                    _stat(agent, spec, too_large=1)
                    break  # this model can't take a request this big: next model
                if kind == "model_gone":
                    _stat(agent, spec, errors=1)
                    _retired.add(spec)
                    replacement = _find_replacement(model, key) if provider == "gemini" else None
                    if not replacement:
                        _add_notice(f"{providers.label(provider)} model {model} is not available; skipping it")
                        break
                    _replacements[spec] = replacement
                    _add_notice(f"Gemini model {model} was retired by Google; switched to {replacement}.")
                    model, spec = replacement, f"gemini:{replacement}"
                    continue
                if kind == "invalid_key":
                    _stat(agent, spec, errors=1)
                    pool.park(key, ALL_SCOPES, utcnow() + timedelta(hours=24),
                              f"rejected by {providers.label(provider)} (HTTP {code}): invalid or unauthorized key")
                    continue
                if kind == "overloaded":
                    _stat(agent, spec, overloaded=1)
                    server_errors += 1
                    _overloaded[spec] = time.monotonic() + OVERLOAD_PAUSE
                    if server_errors <= 3:
                        _event(f"{providers.label(provider)} {model} overloaded ({last_error}); trying the next model")
                    break
                _stat(agent, spec, errors=1)
                raise
            except Exception:  # network errors etc.
                _stat(agent, spec, errors=1)
                raise
            pool.used(key)
            _after_success(key, provider, model, tokens)
            _consecutive = 0
            last_model = spec
            _stat(agent, spec, ok=1, ms=int((time.monotonic() - started) * 1000))
            return text, sources, spec
        if position + 1 < len(chain):
            nxt = f"{chain[position + 1][0]}:{chain[position + 1][1]}"
            if (spec, nxt) not in _fallbacks_noted:
                _fallbacks_noted.add((spec, nxt))
                _add_notice(f"{agent}: {spec} unavailable for now ({last_error}); using {nxt}")
    raise KeysExhausted(f"AI limits reached for the {agent} agent on every key and model ({last_error}). "
                        f"Per-minute limits clear within a minute, daily limits within a day.")


def _parse_json(text: str):
    """Strict JSON first; then the JSON inside a code fence or the outermost braces; then a tolerant repair
    (missing commas, trailing commas, unescaped quotes, an answer cut short) before giving up."""
    text = (text or "").strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    try:
        return _strict_parts(text)
    except ValueError:
        pass
    repaired = json_repair.loads(text)
    if isinstance(repaired, (dict, list)) and repaired:
        _event("Repaired slightly malformed JSON from the model")
        return repaired
    raise ValueError(f"Model did not return JSON: {text[:300]}")


def _strict_parts(text: str):
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


def ask_json(prompt: str, *, agent: str, system: str | None = None, temperature: float = 0.3):
    """JSON answer from the agent's routed models. Malformed JSON gets one retry with a stricter instruction."""
    text, _, spec = _generate(prompt, agent=agent, system=system, json_mode=True, search=False, temperature=temperature)
    try:
        return _parse_json(text)
    except ValueError as exc:  # json.JSONDecodeError is a ValueError
        _stat(agent, spec, invalid_json=1)
        _event(f"{spec} returned invalid JSON ({exc}); retrying once")
        text, _, spec = _generate(prompt + "\n\nReturn ONLY valid JSON: double-quoted keys and strings, no comments, "
                                  "no trailing commas.", agent=agent, system=system, json_mode=True, search=False,
                                  temperature=0)
        try:
            return _parse_json(text)
        except ValueError:
            _stat(agent, spec, invalid_json=1)
            raise


def search_json(prompt: str, *, agent: str = "search", system: str | None = None) -> tuple[object, list[dict]]:
    """Grounded with Google Search (Gemini). Returns (parsed_json, sources[{title, uri}])."""
    text, sources, spec = _generate(prompt, agent=agent, system=system, json_mode=False, search=True, temperature=0.2)
    try:
        return _parse_json(text), sources
    except ValueError:
        _stat(agent, spec, invalid_json=1)
        raise
