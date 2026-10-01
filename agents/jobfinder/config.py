import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")


def env(name: str, default: str | None = None, required: bool = False) -> str | None:
    value = os.environ.get(name, default)
    if value == "":
        value = default
    if required and not value:
        raise RuntimeError(f"Missing required environment variable {name}")
    return value


SUPABASE_URL = env("SUPABASE_URL", required=True)
SUPABASE_SERVICE_ROLE_KEY = env("SUPABASE_SERVICE_ROLE_KEY", required=True)

def _split(value: str | None) -> list[str]:
    return [x.strip() for x in (value or "").replace("\n", ",").split(",") if x.strip()]


# Shared keys from secrets/.env (owner, plus users with accounts.use_shared_keys).
# Comma-separated = fallback order, e.g. GEMINI_API_KEYS=k1,k2  ADZUNA_KEYS=id1:key1,id2:key2
SHARED_GEMINI_KEYS = _split(env("GEMINI_API_KEYS")) + _split(env("GEMINI_API_KEY"))
SHARED_ADZUNA_KEYS = [tuple(p.split(":", 1)) for p in _split(env("ADZUNA_KEYS")) if ":" in p]
if env("ADZUNA_APP_ID") and env("ADZUNA_APP_KEY"):
    SHARED_ADZUNA_KEYS.append((env("ADZUNA_APP_ID"), env("ADZUNA_APP_KEY")))
SHARED_RAPIDAPI_KEYS = _split(env("RAPIDAPI_KEYS")) + _split(env("RAPIDAPI_KEY"))
SHARED_GROQ_KEYS = _split(env("GROQ_API_KEYS")) + _split(env("GROQ_API_KEY"))
SHARED_OPENROUTER_KEYS = _split(env("OPENROUTER_API_KEYS")) + _split(env("OPENROUTER_API_KEY"))

# "auto" = newest stable model in the family. Every model has its own free daily quota, so by default we
# work through all of them (GEMINI_USE_ALL_MODELS=false to stick to one).
GEMINI_MODEL = env("GEMINI_MODEL", "auto")
GEMINI_FAST_MODEL = env("GEMINI_FAST_MODEL", "auto")
GEMINI_USE_ALL_MODELS = (env("GEMINI_USE_ALL_MODELS", "true") or "true").lower() != "false"
# Override the starting gap between calls (default: 12.5s flash, 4.5s flash-lite).
GEMINI_MIN_INTERVAL_SEC = float(env("GEMINI_MIN_INTERVAL_SEC")) if env("GEMINI_MIN_INTERVAL_SEC") else None

JOB_RETENTION_DAYS = int(env("JOB_RETENTION_DAYS", "30"))  # for jobs never marked applied

NA = "NA"
MAX_ATTEMPTS = 3
HTTP_TIMEOUT = 25
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
