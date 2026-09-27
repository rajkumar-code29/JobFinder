"""Free job-search APIs. Each function returns list[RawJob] and never raises for a single bad query."""
from __future__ import annotations

import logging

from .. import config
from .base import CURRENCY, NA, RawJob, country_name, format_salary, get_json, html_to_text

log = logging.getLogger("jobfinder")

ADZUNA_COUNTRIES = {"gb", "us", "au", "at", "be", "br", "ca", "ch", "de", "es", "fr", "in", "it", "mx", "nl", "nz", "pl", "sg", "za"}


def adzuna(roles: list[str], countries: list[str]) -> list[RawJob]:
    """https://developer.adzuna.com – free key. Descriptions are snippets; the Scout enriches them later."""
    if not (config.ADZUNA_APP_ID and config.ADZUNA_APP_KEY):
        log.info("Adzuna: no key, skipping")
        return []
    jobs = []
    for cc in countries:
        if cc not in ADZUNA_COUNTRIES:
            continue
        for role in roles:
            try:
                data = get_json(
                    f"https://api.adzuna.com/v1/api/jobs/{cc}/search/1",
                    params={"app_id": config.ADZUNA_APP_ID, "app_key": config.ADZUNA_APP_KEY,
                            "what": role, "results_per_page": 50, "max_days_old": 3, "sort_by": "date"},
                )
            except Exception as exc:
                log.warning("Adzuna %s/%s failed: %s", cc, role, exc)
                continue
            for r in data.get("results", []):
                predicted = str(r.get("salary_is_predicted", "0")) == "1"
                lo, hi = r.get("salary_min"), r.get("salary_max")
                job = RawJob(
                    source="adzuna", external_id=str(r["id"]), title=r.get("title", NA),
                    company=(r.get("company") or {}).get("display_name", NA),
                    location=(r.get("location") or {}).get("display_name", NA), country=cc,
                    description=html_to_text(r.get("description")), url=r.get("redirect_url", NA),
                    apply_url=r.get("redirect_url", NA), employment_type=r.get("contract_time") or NA,
                    posted_at=r.get("created") or NA,
                )
                # Adzuna's "predicted" salaries are model estimates, not from the JD – let the Salary agent decide.
                if lo and not predicted:
                    job.salary_min, job.salary_max, job.salary_currency = lo, hi, CURRENCY.get(cc, NA)
                    job.salary_text = format_salary(lo, hi, job.salary_currency, "year")
                elif lo:
                    job.extra["adzuna_estimate"] = {"min": lo, "max": hi, "currency": CURRENCY.get(cc, NA)}
                jobs.append(job)
    return jobs


def jsearch(roles: list[str], countries: list[str]) -> list[RawJob]:
    """JSearch on RapidAPI (Google for Jobs index: LinkedIn, Indeed, Glassdoor…). Free tier = 200 req/month,
    so we send one combined query per country and the pipeline only calls this once a day."""
    if not config.RAPIDAPI_KEY:
        log.info("JSearch: no key, skipping")
        return []
    jobs = []
    query_roles = " OR ".join(roles[:3])
    for cc in countries:
        try:
            data = get_json(
                "https://jsearch.p.rapidapi.com/search",
                params={"query": f"{query_roles} in {country_name(cc)}", "page": 1, "num_pages": 1,
                        "date_posted": "3days", "country": cc},
                headers={"X-RapidAPI-Key": config.RAPIDAPI_KEY, "X-RapidAPI-Host": "jsearch.p.rapidapi.com"},
            )
        except Exception as exc:
            log.warning("JSearch %s failed: %s", cc, exc)
            continue
        for r in data.get("data", []):
            loc = ", ".join(x for x in [r.get("job_city"), r.get("job_state"), r.get("job_country")] if x) or NA
            job = RawJob(
                source="jsearch", external_id=str(r.get("job_id")), title=r.get("job_title") or NA,
                company=r.get("employer_name") or NA, location=loc, country=cc,
                description=r.get("job_description") or NA, url=r.get("job_google_link") or r.get("job_apply_link") or NA,
                apply_url=r.get("job_apply_link") or NA, remote="yes" if r.get("job_is_remote") else "no",
                employment_type=r.get("job_employment_type") or NA,
                posted_at=r.get("job_posted_at_datetime_utc") or NA,
            )
            if r.get("job_min_salary") or r.get("job_max_salary"):
                job.salary_min, job.salary_max = r.get("job_min_salary"), r.get("job_max_salary")
                job.salary_currency = r.get("job_salary_currency") or CURRENCY.get(cc, NA)
                job.salary_period = r.get("job_salary_period") or NA
                job.salary_text = format_salary(job.salary_min, job.salary_max, job.salary_currency, job.salary_period)
            jobs.append(job)
    return jobs


def remotive(roles: list[str], countries: list[str]) -> list[RawJob]:
    """https://remotive.com/api – remote jobs, full descriptions. They ask for ≤4 calls/day; the pipeline respects that."""
    jobs = []
    for role in roles[:3]:
        try:
            data = get_json("https://remotive.com/api/remote-jobs", params={"search": role, "limit": 50})
        except Exception as exc:
            log.warning("Remotive %s failed: %s", role, exc)
            continue
        for r in data.get("jobs", []):
            job = RawJob(
                source="remotive", external_id=str(r["id"]), title=r.get("title") or NA,
                company=r.get("company_name") or NA, location=r.get("candidate_required_location") or "Remote",
                description=html_to_text(r.get("description")), url=r.get("url") or NA, apply_url=r.get("url") or NA,
                remote="yes", employment_type=r.get("job_type") or NA, posted_at=r.get("publication_date") or NA,
            )
            if r.get("salary"):
                job.salary_text = r["salary"]
            jobs.append(job)
    return jobs


def arbeitnow(roles: list[str], countries: list[str]) -> list[RawJob]:
    """https://www.arbeitnow.com/api – Europe-focused feed with no search param; the Scout filters it."""
    jobs = []
    for page in (1, 2, 3):
        try:
            data = get_json("https://www.arbeitnow.com/api/job-board-api", params={"page": page})
        except Exception as exc:
            log.warning("Arbeitnow page %s failed: %s", page, exc)
            break
        for r in data.get("data", []):
            jobs.append(RawJob(
                source="arbeitnow", external_id=r["slug"], title=r.get("title") or NA,
                company=r.get("company_name") or NA, location=r.get("location") or NA,
                description=html_to_text(r.get("description")), url=r.get("url") or NA, apply_url=r.get("url") or NA,
                remote="yes" if r.get("remote") else "no", employment_type=", ".join(r.get("job_types") or []) or NA,
                posted_at=str(r.get("created_at") or NA),
            ))
    return jobs
