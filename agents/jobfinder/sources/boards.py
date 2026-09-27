"""Company career boards added by URL in Settings. Public ATS APIs are used when the URL is recognised;
anything else (LinkedIn, Indeed, a custom careers page…) is searched through Gemini + Google Search."""
from __future__ import annotations

import copy
import logging
import re
from urllib.parse import urlparse

from .base import NA, RawJob, format_salary, get_json, html_to_text

log = logging.getLogger("jobfinder")


def detect(url: str) -> tuple[str, str] | None:
    """Return (ats, slug) for known ATS URLs, else None."""
    u = urlparse(url if "://" in url else f"https://{url}")
    host, parts = u.netloc.lower(), [p for p in u.path.split("/") if p]
    if "greenhouse.io" in host:
        if "for" in (q := dict(x.split("=", 1) for x in u.query.split("&") if "=" in x)):
            return "greenhouse", q["for"]
        return ("greenhouse", parts[0]) if parts else None
    if host.endswith("lever.co") and parts:
        return "lever", parts[0]
    if host.endswith("ashbyhq.com") and parts:
        return "ashby", parts[0]
    if host == "apply.workable.com" and parts:
        return "workable", parts[0]
    if host.endswith(".workable.com"):
        return "workable", host.split(".")[0]
    return None


def greenhouse(slug: str) -> list[RawJob]:
    data = get_json(f"https://boards-api.greenhouse.io/v1/boards/{slug}/jobs", params={"content": "true"})
    company = slug
    try:
        company = get_json(f"https://boards-api.greenhouse.io/v1/boards/{slug}").get("name") or slug
    except Exception:
        pass
    return [RawJob(
        source="greenhouse", external_id=f"{slug}:{j['id']}", title=j.get("title") or NA, company=company,
        location=(j.get("location") or {}).get("name") or NA, description=html_to_text(j.get("content")),
        url=j.get("absolute_url") or NA, apply_url=j.get("absolute_url") or NA, posted_at=j.get("updated_at") or NA,
    ) for j in data.get("jobs", [])]


def lever(slug: str) -> list[RawJob]:
    data = get_json(f"https://api.lever.co/v0/postings/{slug}", params={"mode": "json"})
    jobs = []
    for j in data:
        cats = j.get("categories") or {}
        lists = "\n\n".join(f"{l.get('text')}\n{html_to_text(l.get('content'))}" for l in j.get("lists") or [])
        desc = "\n\n".join(x for x in [j.get("descriptionPlain"), lists, j.get("additionalPlain")] if x)
        job = RawJob(
            source="lever", external_id=f"{slug}:{j['id']}", title=j.get("text") or NA, company=slug.replace("-", " ").title(),
            location=cats.get("location") or NA, description=desc or NA, url=j.get("hostedUrl") or NA,
            apply_url=j.get("applyUrl") or j.get("hostedUrl") or NA, employment_type=cats.get("commitment") or NA,
            remote=j.get("workplaceType") or NA, posted_at=str(j.get("createdAt") or NA),
        )
        if sr := j.get("salaryRange"):
            job.salary_min, job.salary_max = sr.get("min"), sr.get("max")
            job.salary_currency, job.salary_period = sr.get("currency") or NA, sr.get("interval") or NA
            job.salary_text = format_salary(job.salary_min, job.salary_max, job.salary_currency, job.salary_period)
        jobs.append(job)
    return jobs


def ashby(slug: str) -> list[RawJob]:
    data = get_json(f"https://api.ashbyhq.com/posting-api/job-board/{slug}", params={"includeCompensation": "true"})
    jobs = []
    for j in data.get("jobs", []):
        job = RawJob(
            source="ashby", external_id=f"{slug}:{j['id']}", title=j.get("title") or NA, company=slug.replace("-", " ").title(),
            location=j.get("location") or NA, description=j.get("descriptionPlain") or html_to_text(j.get("descriptionHtml")),
            url=j.get("jobUrl") or NA, apply_url=j.get("applyUrl") or j.get("jobUrl") or NA,
            remote="yes" if j.get("isRemote") else "no", employment_type=j.get("employmentType") or NA,
            posted_at=j.get("publishedAt") or NA,
        )
        comp = (j.get("compensation") or {}).get("compensationTierSummary")
        if comp:
            job.salary_text = comp
        jobs.append(job)
    return jobs


def workable(slug: str) -> list[RawJob]:
    data = get_json(f"https://apply.workable.com/api/v1/widget/accounts/{slug}", params={"details": "true"})
    company = data.get("name") or slug
    return [RawJob(
        source="workable", external_id=f"{slug}:{j.get('shortcode')}", title=j.get("title") or NA, company=company,
        location=", ".join(x for x in [j.get("city"), j.get("state"), j.get("country")] if x) or NA,
        description=html_to_text(j.get("description")), url=j.get("url") or NA,
        apply_url=j.get("application_url") or j.get("url") or NA, remote="yes" if j.get("telecommuting") else NA,
        employment_type=j.get("employment_type") or NA, posted_at=j.get("published_on") or NA,
    ) for j in data.get("jobs", [])]


FETCHERS = {"greenhouse": greenhouse, "lever": lever, "ashby": ashby, "workable": workable}


_board_cache: dict[str, list[RawJob]] = {}


def fetch_board(url: str) -> tuple[list[RawJob], bool]:
    """Returns (jobs, handled). handled=False means the URL needs the Google-search fallback.
    Results are cached per run, so users following the same company share one API call."""
    hit = detect(url)
    if not hit:
        return [], False
    ats, slug = hit
    slug = re.sub(r"[^A-Za-z0-9_.-]", "", slug)
    cache_key = f"{ats}:{slug}"
    if cache_key not in _board_cache:
        _board_cache[cache_key] = FETCHERS[ats](slug)
    return [copy.copy(j) for j in _board_cache[cache_key]], True
