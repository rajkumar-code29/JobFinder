"""Job discovery via Gemini + Google Search grounding (no scraping). Used for:
  * general searches per role/country, and
  * board URLs we have no API for (LinkedIn, Indeed, Naukri, custom careers pages) via `site:` queries."""
from __future__ import annotations

import hashlib
import logging
from urllib.parse import urlparse

from .. import llm
from .base import NA, RawJob, country_name

log = logging.getLogger("jobfinder")

PROMPT = """Use Google Search to find currently open job postings.
Search: {query}
Only include real postings published in the last 7 days that you found in search results. Never invent postings.
Return ONLY a JSON array (max 10 items) of objects:
{{"title": str, "company": str, "location": str, "url": "direct link to the posting", "posted": str or "NA",
  "salary": str or "NA", "summary": "3-6 sentence summary of responsibilities and requirements"}}
If nothing is found return []."""


def _to_jobs(items, tag: str, cc: str) -> list[RawJob]:
    jobs = []
    for it in items if isinstance(items, list) else []:
        if not isinstance(it, dict) or not it.get("title") or not it.get("company"):
            continue
        key = hashlib.sha1(f"{it.get('company')}|{it.get('title')}|{it.get('url')}".lower().encode()).hexdigest()[:16]
        jobs.append(RawJob(
            source="google_search", external_id=key, title=it["title"], company=it["company"],
            location=it.get("location") or NA, country=cc, url=it.get("url") or NA, apply_url=it.get("url") or NA,
            description=it.get("summary") or NA, posted_at=it.get("posted") or NA,
            salary_text=it.get("salary") or NA, extra={"via": tag},
        ))
    return jobs


def search_roles(roles: list[str], countries: list[str]) -> list[RawJob]:
    jobs = []
    for cc in countries:
        query = f"({' OR '.join(repr(r) for r in roles[:3])}) jobs in {country_name(cc)}"
        try:
            items, _ = llm.search_json(PROMPT.format(query=query))
            jobs += _to_jobs(items, "roles", cc)
        except llm.BudgetExceeded:
            raise
        except Exception as exc:
            log.warning("Google search %s failed: %s", cc, exc)
    return jobs


def search_site(url: str, roles: list[str], countries: list[str]) -> list[RawJob]:
    host = urlparse(url if "://" in url else f"https://{url}").netloc
    where = " OR ".join(country_name(c) for c in countries[:4])
    query = f"site:{host} ({' OR '.join(repr(r) for r in roles[:3])}) ({where})"
    try:
        items, _ = llm.search_json(PROMPT.format(query=query))
        return _to_jobs(items, host, countries[0] if len(countries) == 1 else NA)
    except llm.BudgetExceeded:
        raise
    except Exception as exc:
        log.warning("Google site search %s failed: %s", host, exc)
        return []
