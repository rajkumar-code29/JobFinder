from __future__ import annotations

import html
import json
import logging
import re
from dataclasses import dataclass, field

import requests
from bs4 import BeautifulSoup

from .. import config

log = logging.getLogger("jobfinder")
NA = config.NA

COUNTRIES = {
    "us": "United States", "gb": "United Kingdom", "in": "India", "ca": "Canada", "au": "Australia",
    "de": "Germany", "fr": "France", "nl": "Netherlands", "ie": "Ireland", "sg": "Singapore",
    "ae": "United Arab Emirates", "nz": "New Zealand", "es": "Spain", "it": "Italy", "ch": "Switzerland",
    "at": "Austria", "be": "Belgium", "pl": "Poland", "se": "Sweden", "dk": "Denmark", "no": "Norway",
    "fi": "Finland", "pt": "Portugal", "br": "Brazil", "mx": "Mexico", "za": "South Africa",
    "jp": "Japan", "sa": "Saudi Arabia", "qa": "Qatar", "my": "Malaysia", "hk": "Hong Kong",
}
ALIASES = {"gb": ["uk", "england", "london", "scotland"], "us": ["usa", "u.s."], "ae": ["uae", "dubai", "abu dhabi"],
           "in": ["bengaluru", "bangalore", "hyderabad", "pune", "chennai", "mumbai", "delhi", "gurgaon", "noida"]}
CURRENCY = {"us": "USD", "gb": "GBP", "in": "INR", "ca": "CAD", "au": "AUD", "de": "EUR", "fr": "EUR", "nl": "EUR",
            "ie": "EUR", "es": "EUR", "it": "EUR", "at": "EUR", "be": "EUR", "sg": "SGD", "nz": "NZD", "ch": "CHF",
            "pl": "PLN", "br": "BRL", "mx": "MXN", "za": "ZAR"}


def country_name(code: str) -> str:
    return COUNTRIES.get(code.lower(), code.upper())


def location_matches(location: str, countries: list[str], remote_ok: bool) -> bool:
    loc = (location or "").lower()
    if not loc or loc == "na":
        return True
    if remote_ok and ("remote" in loc or "anywhere" in loc or "worldwide" in loc):
        return True
    for code in countries:
        words = [country_name(code).lower(), *ALIASES.get(code, [])]
        if any(w in loc for w in words) or re.search(rf"\b{re.escape(code)}\b", loc):
            return True
    return False


@dataclass
class RawJob:
    source: str
    external_id: str
    title: str
    company: str
    location: str = NA
    country: str = NA
    description: str = NA
    url: str = NA
    apply_url: str = NA
    remote: str = NA
    employment_type: str = NA
    posted_at: str = NA
    salary_min: float | None = None
    salary_max: float | None = None
    salary_currency: str = NA
    salary_period: str = NA
    salary_text: str = NA
    extra: dict = field(default_factory=dict)

    def as_row(self) -> dict:
        row = {k: v for k, v in self.__dict__.items() if k not in ("extra", "salary_period")}
        for k, v in row.items():
            if isinstance(v, str) and not v.strip():
                row[k] = NA
        row["title"] = (row["title"] or NA)[:300]
        row["company"] = (row["company"] or NA)[:200]
        return row


def html_to_text(raw: str | None) -> str:
    if not raw:
        return NA
    raw = html.unescape(raw)  # Greenhouse double-escapes
    text = BeautifulSoup(raw, "html.parser").get_text("\n")
    text = re.sub(r"\n\s*\n+", "\n\n", text)
    return text.strip() or NA


def get_json(url: str, **kwargs):
    headers = {"User-Agent": config.USER_AGENT, "Accept": "application/json", **kwargs.pop("headers", {})}
    r = requests.get(url, headers=headers, timeout=config.HTTP_TIMEOUT, **kwargs)
    r.raise_for_status()
    return r.json()


def fetch_page_details(url: str) -> dict:
    """Best-effort full JD from a posting page: JSON-LD JobPosting first, then visible text."""
    if not url or url == NA:
        return {}
    try:
        r = requests.get(url, headers={"User-Agent": config.USER_AGENT}, timeout=config.HTTP_TIMEOUT, allow_redirects=True)
        if r.status_code >= 400 or "text/html" not in r.headers.get("content-type", ""):
            return {}
    except requests.RequestException:
        return {}
    soup = BeautifulSoup(r.text, "html.parser")
    out: dict = {"final_url": r.url}
    for tag in soup.find_all("script", type="application/ld+json"):
        try:
            data = json.loads(tag.string or "")
        except (json.JSONDecodeError, TypeError):
            continue
        items = data if isinstance(data, list) else data.get("@graph", [data]) if isinstance(data, dict) else []
        for item in items:
            if isinstance(item, dict) and item.get("@type") == "JobPosting":
                out["description"] = html_to_text(item.get("description"))
                out["date_posted"] = item.get("datePosted")
                org = item.get("hiringOrganization")
                if isinstance(org, dict):
                    out["company"] = org.get("name")
                salary = item.get("baseSalary")
                if isinstance(salary, dict):
                    value = salary.get("value") or {}
                    if isinstance(value, dict):
                        out["salary_min"] = value.get("minValue") or value.get("value")
                        out["salary_max"] = value.get("maxValue") or value.get("value")
                        out["salary_period"] = value.get("unitText")
                    out["salary_currency"] = salary.get("currency")
                return out
    for t in soup(["script", "style", "nav", "header", "footer", "noscript", "svg", "form"]):
        t.decompose()
    main = soup.find("main") or soup.find("article") or soup.body
    text = re.sub(r"\n\s*\n+", "\n\n", main.get_text("\n") if main else "").strip()
    if len(text) > 400:
        out["description"] = text[:15000]
    return out


def format_salary(lo, hi, currency: str, period: str = NA) -> str:
    if lo is None and hi is None:
        return NA
    fmt = lambda v: f"{float(v):,.0f}"
    rng = fmt(lo) if hi is None or lo == hi else (fmt(hi) if lo is None else f"{fmt(lo)} – {fmt(hi)}")
    per = f" / {period.lower()}" if period and period != NA else ""
    cur = f"{currency} " if currency and currency != NA else ""
    return f"{cur}{rng}{per}"
