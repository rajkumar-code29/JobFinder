"""Company career boards added by URL in Settings. Public ATS feeds are read directly when the URL is
recognised (Greenhouse, Lever, Ashby, Workable, Workday, SmartRecruiters); anything else (LinkedIn, Indeed,
a custom careers page…) is searched through Gemini + Google Search instead."""
from __future__ import annotations

import logging
import re
from urllib.parse import urlparse

import requests

from .. import config
from .base import NA, RawJob, format_salary, get_json, html_to_text

log = logging.getLogger("jobfinder")


_SAFE = re.compile(r"[^A-Za-z0-9_.-]")
_LOCALE = re.compile(r"^[a-z]{2}(-[A-Za-z]{2})?$")  # Workday URLs often start with /en-US/


def detect(url: str) -> tuple[str, str] | None:
    """Return (ats, slug) for known ATS URLs, else None."""
    u = urlparse(url if "://" in url else f"https://{url}")
    host, parts = u.netloc.lower(), [p for p in u.path.split("/") if p]
    if host.endswith((".myworkdayjobs.com", ".myworkdaysite.com")):
        # https://<tenant>.wd5.myworkdayjobs.com/[en-US/]<site>/…
        parts = [p for p in parts if not _LOCALE.match(p)]
        if not parts:
            return None
        return "workday", "/".join(_SAFE.sub("", x) for x in (host, host.split(".")[0], parts[0]))
    if host in ("jobs.smartrecruiters.com", "careers.smartrecruiters.com") and parts:
        return "smartrecruiters", _SAFE.sub("", parts[0])
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


def workday(slug: str, roles: list[str]) -> list[RawJob]:
    """Workday's career-site JSON API. The list only has titles/locations, so each job carries a `hydrate`
    callable that the Scout runs for *new* jobs only (full description, country, employment type)."""
    host, tenant, site = slug.split("/")
    base = f"https://{host}/wday/cxs/{tenant}/{site}"
    headers = {"User-Agent": config.USER_AGENT, "Accept": "application/json", "Content-Type": "application/json"}
    seen: dict[str, dict] = {}
    for role in (roles or [""])[:3]:
        for offset in (0, 20):  # Workday caps pages at 20
            r = requests.post(f"{base}/jobs", json={"appliedFacets": {}, "limit": 20, "offset": offset, "searchText": role},
                              headers=headers, timeout=config.HTTP_TIMEOUT)
            r.raise_for_status()
            postings = r.json().get("jobPostings") or []
            for p in postings:
                if p.get("externalPath"):
                    seen.setdefault(p["externalPath"], p)
            if len(postings) < 20:
                break
    company = tenant.replace("-", " ").title()

    def hydrate(path: str):
        def run() -> dict:
            info = requests.get(f"{base}{path}", headers=headers, timeout=config.HTTP_TIMEOUT).json().get("jobPostingInfo") or {}
            country = (info.get("country") or {}).get("descriptor")
            loc = ", ".join(x for x in [info.get("location"), country] if x and x not in (info.get("location") or ""))
            return {"description": html_to_text(info.get("jobDescription")), "location": loc or info.get("location"),
                    "employment_type": info.get("timeType"), "apply_url": info.get("externalUrl"),
                    "remote": info.get("remoteType"), "posted_at": info.get("startDate")}
        return run

    jobs = []
    for path, p in seen.items():
        job_url = f"https://{host}/{site}{path}"
        job = RawJob(source="workday", external_id=f"{tenant}:{path.rsplit('_', 1)[-1]}", title=p.get("title") or NA,
                     company=company, location=p.get("locationsText") or NA, url=job_url, apply_url=job_url,
                     posted_at=p.get("postedOn") or NA)
        job.extra["hydrate"] = hydrate(path)
        jobs.append(job)
    return jobs


def smartrecruiters(slug: str, roles: list[str]) -> list[RawJob]:
    """SmartRecruiters public Posting API (search by role, full description via `hydrate`)."""
    base = f"https://api.smartrecruiters.com/v1/companies/{slug}/postings"
    seen: dict[str, dict] = {}
    for role in (roles or [""])[:3]:
        data = get_json(base, params={"q": role, "limit": 100})
        for p in data.get("content") or []:
            seen.setdefault(p["id"], p)

    def hydrate(pid: str):
        def run() -> dict:
            d = get_json(f"{base}/{pid}")
            sections = (d.get("jobAd") or {}).get("sections") or {}
            text = "\n\n".join(
                f"{sec.get('title') or ''}\n{html_to_text(sec.get('text'))}"
                for key in ("jobDescription", "qualifications", "additionalInformation", "companyDescription")
                if (sec := sections.get(key)) and sec.get("text"))
            return {"description": text or NA, "apply_url": d.get("applyUrl"), "url": d.get("postingUrl")}
        return run

    jobs = []
    for pid, p in seen.items():
        loc = p.get("location") or {}
        job = RawJob(
            source="smartrecruiters", external_id=f"{slug}:{pid}", title=p.get("name") or NA,
            company=(p.get("company") or {}).get("name") or slug,
            location=loc.get("fullLocation") or ", ".join(x for x in [loc.get("city"), loc.get("country")] if x) or NA,
            country=(loc.get("country") or NA).lower() if loc.get("country") else NA,
            url=f"https://jobs.smartrecruiters.com/{slug}/{pid}", apply_url=f"https://jobs.smartrecruiters.com/{slug}/{pid}",
            remote="yes" if loc.get("remote") else ("hybrid" if loc.get("hybrid") else "no"),
            employment_type=(p.get("typeOfEmployment") or {}).get("label") or NA,
            posted_at=p.get("releasedDate") or NA,
        )
        job.extra["hydrate"] = hydrate(pid)
        jobs.append(job)
    return jobs


# Feeds that return every open job at the company ignore the roles argument.
FETCHERS = {
    "greenhouse": lambda slug, roles: greenhouse(slug),
    "lever": lambda slug, roles: lever(slug),
    "ashby": lambda slug, roles: ashby(slug),
    "workable": lambda slug, roles: workable(slug),
    "workday": workday,
    "smartrecruiters": smartrecruiters,
}

_board_cache: dict[str, list[RawJob]] = {}


def fetch_board(url: str, roles: list[str]) -> tuple[list[RawJob], bool]:
    """Returns (jobs, handled). handled=False means the URL needs the Google-search fallback.
    Results are cached per run, so users following the same company share one fetch."""
    hit = detect(url)
    if not hit:
        return [], False
    ats, slug = hit
    if ats not in ("workday", "smartrecruiters"):
        slug = _SAFE.sub("", slug)
    cache_key = f"{ats}:{slug}:" + ("|".join(sorted(r.lower() for r in roles[:3])) if ats in ("workday", "smartrecruiters") else "")
    if cache_key not in _board_cache:
        _board_cache[cache_key] = FETCHERS[ats](slug, roles)
    return [j.clone() for j in _board_cache[cache_key]], True


def hydrate(job: RawJob) -> None:
    """Fill in details for feeds whose list endpoint is thin (Workday, SmartRecruiters)."""
    fn = job.extra.pop("hydrate", None)
    if not fn:
        return
    for key, value in (fn() or {}).items():
        if value:
            setattr(job, key, value)
