"""Salary from the JD, else an estimate from salary sites, else NA."""
from __future__ import annotations

import re

from .. import db, llm
from ..sources.base import NA, format_salary

MONEY = re.compile(
    r"(?P<cur>[$£€₹]|USD|GBP|EUR|INR|CAD|AUD|SGD|AED)\s?(?P<lo>\d[\d,.]*\s?[kKmL]?)\s*(?:-|–|to)\s*(?:[$£€₹]|USD|GBP|EUR|INR|CAD|AUD|SGD|AED)?\s?(?P<hi>\d[\d,.]*\s?[kKmL]?)"
)
SYMBOL = {"$": "USD", "£": "GBP", "€": "EUR", "₹": "INR"}

PROMPT = """Find the typical salary range for this role using Google Search.
Prefer Glassdoor for this exact company + title; otherwise Levels.fyi, Payscale, Indeed, AmbitionBox (India) or
another salary site for the same title and location.
Role: {title}
Company: {company}
Location: {location}
Return ONLY JSON: {{"found": bool, "min": number|null, "max": number|null, "currency": "ISO code",
"period": "year|month|hour", "site": "glassdoor|levels.fyi|...", "basis": "company+title|title+location",
"url": str|null}}
If you cannot find a credible figure, return {{"found": false}}."""


def _num(s: str) -> float:
    s = s.replace(",", "").strip()
    mult = 1
    if s[-1:] in "kK":
        mult, s = 1_000, s[:-1]
    elif s[-1:] in "mM":
        mult, s = 1_000_000, s[:-1]
    elif s[-1:] == "L":  # lakh
        mult, s = 100_000, s[:-1]
    return float(s) * mult


def from_description(text: str) -> dict | None:
    m = MONEY.search(text or "")
    if not m:
        return None
    try:
        lo, hi = _num(m["lo"]), _num(m["hi"])
    except ValueError:
        return None
    if hi < 1000:  # hourly or noise
        period = "hour"
    else:
        period = "year"
    cur = SYMBOL.get(m["cur"], m["cur"])
    return {"salary_min": lo, "salary_max": hi, "salary_currency": cur,
            "salary_text": format_salary(lo, hi, cur, period), "salary_source": "job_posting"}


def run(run: db.PipelineRun, job: dict) -> None:
    """Checked once per job."""
    meta = job.get("meta") or {}
    if job["salary_text"] != NA or meta.get("salary_checked"):
        return
    with run.agent("salary", job["job_id"], "Looking for salary") as task:
        found = from_description(job["description"])
        if not found:
            try:
                data, sources = llm.search_json(PROMPT.format(title=job["title"], company=job["company"], location=job["location"]), agent="salary")
            except llm.StopUser:
                raise
            except Exception:
                data, sources = {}, []
            if isinstance(data, dict) and data.get("found") and (data.get("min") or data.get("max")):
                site = data.get("site") or "web"
                found = {
                    "salary_min": data.get("min"), "salary_max": data.get("max"),
                    "salary_currency": data.get("currency") or NA,
                    "salary_text": format_salary(data.get("min"), data.get("max"), data.get("currency") or NA, data.get("period") or NA)
                                   + f" (est. {site}, {data.get('basis') or 'similar roles'})",
                    "salary_source": f"estimate:{site}",
                    "meta": {**meta, "salary_sources": sources[:5], "salary_url": data.get("url")},
                }
        if not found and (est := (job.get("meta") or {}).get("adzuna_estimate")):
            found = {"salary_min": est["min"], "salary_max": est["max"], "salary_currency": est["currency"],
                     "salary_text": format_salary(est["min"], est["max"], est["currency"], "year") + " (est. Adzuna)",
                     "salary_source": "estimate:adzuna"}
        found = found or {}
        found["meta"] = {**found.get("meta", meta), "salary_checked": True}
        db.update_job(job["job_id"], found)
        job.update(found)
        task.message = f"Salary: {found['salary_text']}" if "salary_text" in found else "Salary not available - stored as NA"
