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
SHARED_GROQ_KEYS = _split(env("GROQ_API_KEYS")) + _split(env("GROQ_API_KEY"))
SHARED_OPENROUTER_KEYS = _split(env("OPENROUTER_API_KEYS")) + _split(env("OPENROUTER_API_KEY"))

# Model routing (see llm.py): quality work (tailoring, interview prep, cover letters) uses a "flash" model,
# high-volume work (relevance rating, ATS scoring, salary/job search) uses a "flash-lite" model.
# "auto" = newest stable model of that family your key can use. Each model has its own free daily allowance,
# so when one is used up the agents move on to the next model of the family (set GEMINI_USE_ALL_MODELS=false
# to stick to one), and finally to flash-lite.
GEMINI_MODEL = env("GEMINI_MODEL", "auto")
GEMINI_FAST_MODEL = env("GEMINI_FAST_MODEL", "auto")
GEMINI_USE_ALL_MODELS = (env("GEMINI_USE_ALL_MODELS", "true") or "true").lower() != "false"
# Starting gap between calls per key+model; unset = matched to free-tier limits (flash 5/min, flash-lite 15/min).
GEMINI_MIN_INTERVAL_SEC = float(env("GEMINI_MIN_INTERVAL_SEC")) if env("GEMINI_MIN_INTERVAL_SEC") else None

NA = "NA"
MAX_ATTEMPTS = 3
HTTP_TIMEOUT = 25
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
