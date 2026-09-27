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

GEMINI_API_KEY = env("GEMINI_API_KEY", required=True)
GEMINI_MODEL = env("GEMINI_MODEL", "gemini-2.5-flash")
GEMINI_FAST_MODEL = env("GEMINI_FAST_MODEL", "gemini-2.5-flash-lite")
GEMINI_MIN_INTERVAL_SEC = float(env("GEMINI_MIN_INTERVAL_SEC", "6"))
LLM_MAX_CALLS_PER_RUN = int(env("LLM_MAX_CALLS_PER_RUN", "60"))

ADZUNA_APP_ID = env("ADZUNA_APP_ID")
ADZUNA_APP_KEY = env("ADZUNA_APP_KEY")
RAPIDAPI_KEY = env("RAPIDAPI_KEY")

NA = "NA"
MAX_ATTEMPTS = 3
HTTP_TIMEOUT = 25
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
