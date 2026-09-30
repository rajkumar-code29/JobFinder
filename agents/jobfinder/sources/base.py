from __future__ import annotations

import copy
import html
import json
import logging
import re
from dataclasses import dataclass, field

import requests
from bs4 import BeautifulSoup

from .. import config
from .countries import ALIASES, COUNTRIES

log = logging.getLogger("jobfinder")
NA = config.NA

CURRENCY = {"us": "USD", "gb": "GBP", "in": "INR", "ca": "CAD", "au": "AUD", "de": "EUR", "fr": "EUR", "nl": "EUR",
            "ie": "EUR", "es": "EUR", "it": "EUR", "at": "EUR", "be": "EUR", "sg": "SGD", "nz": "NZD", "ch": "CHF",
            "pl": "PLN", "br": "BRL", "mx": "MXN", "za": "ZAR"}


# Place names that are also parts of other places ("New Jersey", "Georgia, US") – never treat these
# as proof that a job is in a different country.
_AMBIGUOUS = {"jersey", "georgia", "guernsey", "jordan", "chad", "niger", "turkey", "victoria", "washington"}


def normalize_location(value: str) -> str:
    """ISO codes, country names and known aliases become a lower-case ISO code (e.g. "UK" -> "gb").
    Anything else is a custom location (a city, region…) and is kept as typed."""
    v = (value or "").strip()
    low = v.lower()
    if low in COUNTRIES:
        return low
    for code, name in COUNTRIES.items():
        if name.lower() == low:
            return code
    for code, words in ALIASES.items():
        if low in words:
            return code
    return v


def is_country(value: str) -> bool:
    return value in COUNTRIES


def country_name(value: str) -> str:
    """Country name for an ISO code; custom locations are returned as typed."""
    return COUNTRIES.get(value, value)


def _mentions(text: str, word: str) -> bool:
    return re.search(rf"(?<![a-z]){re.escape(word)}(?![a-z])", text) is not None


def location_matches(location: str, wanted: list[str], remote_ok: bool) -> bool | None:
    """True: in a wanted place (or acceptable remote). False: clearly in some other country.
    None: can't tell (e.g. only a city we don't know) – the Scout's AI rating decides."""
    raw = location or ""
    loc = raw.lower()
    if not loc or loc == "na":
        return None
    if remote_ok and any(w in loc for w in ("remote", "anywhere", "worldwide")):
        return True
    for w in wanted:
        words = [country_name(w).lower(), *ALIASES.get(w, [])]
        if any(_mentions(loc, x) for x in words):
            return True
        if is_country(w) and re.search(rf"\b{w.upper()}\b", raw):  # "Austin, TX, US"
            return True
    for code, name in COUNTRIES.items():
        for x in (name.lower(), *ALIASES.get(code, [])):
            if x not in _AMBIGUOUS and _mentions(loc, x):
                return False
    return None


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

    def clone(self) -> "RawJob":
        """Independent copy (own `extra` dict) – cached feeds hand one to each user."""
        c = copy.copy(self)
        c.extra = dict(self.extra)
        return c

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
