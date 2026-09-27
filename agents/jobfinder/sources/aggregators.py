"""Free job-search APIs. Each function returns list[RawJob] and never raises for a single bad query."""
from __future__ import annotations

import copy
import logging
import time
from datetime import timedelta

import requests

from .. import config
from ..keys import ALL_SCOPES, KeyPool, NoKeyAvailable, first_of_next_month, utcnow
from .base import CURRENCY, NA, RawJob, country_name, format_salary, get_json, html_to_text

log = logging.getLogger("jobfinder")

_feed_cache: dict[str, list[RawJob]] = {}


def _cached(name: str, fetch) -> list[RawJob]:
    """Keyless feeds are the same for every user: fetch once per run, hand each user a copy."""
    if name not in _feed_cache:
        _feed_cache[name] = fetch()
    return [copy.copy(j) for j in _feed_cache[name]]


def _pooled_get(pool: KeyPool, build) -> dict | None:
    """GET with key fallback. build(key) -> (url, params, headers). Returns None once every key is used up."""
    for _ in range(len(pool.keys) * 3 + 1):
        try:
            key = pool.get()
        except NoKeyAvailable:
            return None
        url, params, headers = build(key)
        r = requests.get(url, params=params, timeout=config.HTTP_TIMEOUT,
                         headers={"User-Agent": config.USER_AGENT, "Accept": "application/json", **headers})
        text = r.text[:200].lower()
        if r.status_code == 429 or (r.status_code == 403 and "limit" in text):
            if "second" in text:
                time.sleep(2)
                continue
            if "month" in text:
                until = first_of_next_month()
            elif "day" in text or "daily" in text:
                until = (utcnow() + timedelta(days=1)).replace(hour=0, minute=5, second=0, microsecond=0)
            else:
                until = utcnow() + timedelta(hours=1)
            pool.park(key, "default", until, f"HTTP {r.status_code}: {r.text[:150]}")
            continue
        if r.status_code in (401, 403):
            pool.park(key, ALL_SCOPES, utcnow() + timedelta(hours=24), f"HTTP {r.status_code}: invalid key or not subscribed")
            continue
        r.raise_for_status()
        pool.used(key)
        return r.json()
    return None

ADZUNA_COUNTRIES = {"gb", "us", "au", "at", "be", "br", "ca", "ch", "de", "es", "fr", "in", "it", "mx", "nl", "nz", "pl", "sg", "za"}


def adzuna(roles: list[str], countries: list[str], pool: KeyPool) -> list[RawJob]:
    """https://developer.adzuna.com – free key. Descriptions are snippets; the Scout enriches them later."""
    if not pool:
        log.info("Adzuna: no key, skipping")
        return []
    jobs = []
    for cc in countries:
        if cc not in ADZUNA_COUNTRIES:
            continue
        for role in roles:
            try:
                data = _pooled_get(pool, lambda k, cc=cc, role=role: (
                    f"https://api.adzuna.com/v1/api/jobs/{cc}/search/1",
                    {"app_id": k.app_id, "app_key": k.value, "what": role,
                     "results_per_page": 50, "max_days_old": 3, "sort_by": "date"},
                    {}))
            except Exception as exc:
                log.warning("Adzuna %s/%s failed: %s", cc, role, exc)
                continue
            if data is None:
                log.warning("Adzuna: every key has hit its limit, stopping")
                return jobs
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


def jsearch(roles: list[str], countries: list[str], pool: KeyPool) -> list[RawJob]:
    """JSearch on RapidAPI (Google for Jobs index: LinkedIn, Indeed, Glassdoor…). Free tier = 200 req/month,
    so we send one combined query per country and the pipeline only calls this once a day."""
    if not pool:
        log.info("JSearch: no key, skipping")
        return []
    jobs = []
    query_roles = " OR ".join(roles[:3])
    for cc in countries:
        try:
            data = _pooled_get(pool, lambda k, cc=cc: (
                "https://jsearch.p.rapidapi.com/search",
                {"query": f"{query_roles} in {country_name(cc)}", "page": 1, "num_pages": 1,
                 "date_posted": "3days", "country": cc},
                {"X-RapidAPI-Key": k.value, "X-RapidAPI-Host": "jsearch.p.rapidapi.com"}))
        except Exception as exc:
            log.warning("JSearch %s failed: %s", cc, exc)
            continue
        if data is None:
            log.warning("JSearch: every key has hit its limit, stopping")
            return jobs
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
    """https://remotive.com/api – remote jobs, full descriptions. They ask for ≤4 calls/day, so we pull the whole
    recent feed once (every 6h, shared by all users) and let the Scout filter it per user."""
    return _cached("remotive", _remotive_feed)


def _remotive_feed() -> list[RawJob]:
    jobs = []
    try:
        data = get_json("https://remotive.com/api/remote-jobs", params={"limit": 500})
    except Exception as exc:
        log.warning("Remotive failed: %s", exc)
        return jobs
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
    return _cached("arbeitnow", _arbeitnow_feed)


def _arbeitnow_feed() -> list[RawJob]:
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
