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


# Shared keys (GitHub secrets / .env). Used by the owner, and by other users only if accounts.use_shared_keys.
# Several keys = fallback order: when one hits its limit the next one is used.
#   GEMINI_API_KEYS=key1,key2,key3      ADZUNA_KEYS=appid1:appkey1,appid2:appkey2      RAPIDAPI_KEYS=k1,k2
SHARED_GEMINI_KEYS = _split(env("GEMINI_API_KEYS")) + _split(env("GEMINI_API_KEY"))
SHARED_ADZUNA_KEYS = [tuple(p.split(":", 1)) for p in _split(env("ADZUNA_KEYS")) if ":" in p]
if env("ADZUNA_APP_ID") and env("ADZUNA_APP_KEY"):
    SHARED_ADZUNA_KEYS.append((env("ADZUNA_APP_ID"), env("ADZUNA_APP_KEY")))
SHARED_RAPIDAPI_KEYS = _split(env("RAPIDAPI_KEYS")) + _split(env("RAPIDAPI_KEY"))

# If Google retires one of these, llm.py switches to the newest model of the same family automatically.
GEMINI_MODEL = env("GEMINI_MODEL", "gemini-3.5-flash")
GEMINI_FAST_MODEL = env("GEMINI_FAST_MODEL", "gemini-3.5-flash-lite")
GEMINI_MIN_INTERVAL_SEC = float(env("GEMINI_MIN_INTERVAL_SEC", "6"))  # per key

NA = "NA"
MAX_ATTEMPTS = 3
HTTP_TIMEOUT = 25
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
