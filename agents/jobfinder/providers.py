"""OpenAI-compatible chat providers (Groq, OpenRouter, …). Gemini is handled natively in llm.py.

To add another provider: an entry here, its name in the api_keys / shared_api_keys provider lists
(migration 006) and in the app's providerInfo."""
from __future__ import annotations

import requests

OPENAI_COMPATIBLE = {
    "groq": {
        "label": "Groq",
        "base_url": "https://api.groq.com/openai/v1",
        # Free tier: 8k tokens per minute per model, so a single request must stay below that.
        "max_request_tokens": 7500,
        "tokens_per_minute": 8000,
        "min_interval": 2.1,  # 30 requests/minute
    },
    "openrouter": {
        "label": "OpenRouter",
        "base_url": "https://openrouter.ai/api/v1",
        "max_request_tokens": None,
        "tokens_per_minute": None,
        "min_interval": 3.1,  # 20 requests/minute on free models
        "headers": {"HTTP-Referer": "https://jobs.rajkumar.codes", "X-Title": "JobFinder"},
    },
}

# Models offered in the app's routing editor (any "<provider>:<model id>" can also be typed in).
SUGGESTED_MODELS = {
    "groq": ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3.8-27b"],
    "openrouter": [],
}


class ProviderError(Exception):
    def __init__(self, code: int, message: str, retry_after: float | None = None):
        super().__init__(f"HTTP {code}: {message}")
        self.code, self.message, self.retry_after = code, message, retry_after


def label(provider: str) -> str:
    return "Gemini" if provider == "gemini" else OPENAI_COMPATIBLE.get(provider, {}).get("label", provider)


def chat(provider: str, api_key: str, model: str, system: str | None, prompt: str, *, json_mode: bool,
         temperature: float, max_tokens: int, timeout: int = 180) -> tuple[str, int | None]:
    """One chat completion. Returns (text, total_tokens or None). Raises ProviderError on HTTP errors."""
    cfg = OPENAI_COMPATIBLE[provider]
    messages = ([{"role": "system", "content": system}] if system else []) + [{"role": "user", "content": prompt}]
    body = {"model": model, "messages": messages, "temperature": temperature, "max_tokens": max_tokens}
    if json_mode:
        body["response_format"] = {"type": "json_object"}
    r = requests.post(f"{cfg['base_url']}/chat/completions", json=body, timeout=timeout,
                      headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json",
                               **cfg.get("headers", {})})
    if r.status_code >= 400:
        try:
            err = r.json().get("error") or {}
            message = err.get("message") if isinstance(err, dict) else str(err)
        except ValueError:
            message = r.text[:300]
        retry = r.headers.get("retry-after")
        raise ProviderError(r.status_code, message or r.reason, float(retry) if retry and retry.replace(".", "").isdigit() else None)
    data = r.json()
    try:
        text = data["choices"][0]["message"]["content"] or ""
    except (KeyError, IndexError, TypeError):
        raise ProviderError(502, f"unexpected response: {str(data)[:200]}")
    return text, (data.get("usage") or {}).get("total_tokens")
