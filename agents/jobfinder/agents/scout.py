"""Scout agents: fetch postings from every enabled source, keep only resume-relevant ones, store them."""
from __future__ import annotations

import logging
import secrets
from datetime import datetime, timezone

from .. import db, llm
from ..sources import aggregators, boards, google_search
from ..sources.base import (NA, RawJob, country_name, fetch_page_details, format_salary, location_matches,
                            normalize_location)

log = logging.getLogger("jobfinder")

RELEVANCE_PROMPT = """Candidate profile:
{profile}

Target roles: {roles}. Preferred locations: {countries}. Remote acceptable: {remote}.

For each job below, rate 0-100 how relevant it is to THIS candidate's resume (skills, seniority, domain, role type).
Be strict: unrelated roles, very different seniority, or a different profession score below 40.
A job clearly located outside the preferred locations (and not remote-friendly when remote is acceptable) scores below 30.
Return ONLY JSON: [{{"i": index, "score": int, "reason": "one short sentence"}}] for every job.

JOBS:
{jobs}"""


def new_job_id() -> str:
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return f"JF-{datetime.now(timezone.utc):%Y%m%d}-" + "".join(secrets.choice(alphabet) for _ in range(5))


def _hour() -> int:
    return datetime.now(timezone.utc).hour


def collect(run: db.PipelineRun, settings: dict, roles: list[str], force_all: bool, pools: dict) -> list[RawJob]:
    countries = [normalize_location(c) for c in settings["countries"]] or ["us"]
    src = settings.get("sources") or {}
    hour = _hour()
    plan = [
        # (name, enabled, due this hour?, fetcher)
        ("adzuna", src.get("adzuna", True), True, lambda: aggregators.adzuna(roles, countries, pools["adzuna"])),
        ("arbeitnow", src.get("arbeitnow", True), True, lambda: aggregators.arbeitnow(roles, countries)),
        ("remotive", src.get("remotive", True) and settings["remote_ok"], hour % 6 == 0, lambda: aggregators.remotive(roles, countries)),
        ("jsearch", src.get("jsearch", True), hour == 6, lambda: aggregators.jsearch(roles, countries, pools["rapidapi"])),
        ("google_search", src.get("google_search", True), hour % 4 == 0, lambda: google_search.search_roles(roles, countries)),
    ]
    raw: list[RawJob] = []
    for name, enabled, due, fetch in plan:
        if not enabled or not (due or (force_all and name != "jsearch")):
            continue
        with run.agent("scout", message=f"Scanning {name}") as task:
            found = fetch()
            raw += found
            task.message = f"{name}: {len(found)} postings"

    for board in settings.get("job_boards") or []:
        url = (board or {}).get("url", "").strip()
        if not url or not board.get("enabled", True):
            continue
        with run.agent("scout", message=f"Scanning board {url}") as task:
            found, handled = boards.fetch_board(url, roles)
            if not handled and (hour % 4 == 0 or force_all):
                found = google_search.search_site(url, roles, countries)
            raw += found
            task.message = f"{url}: {len(found)} postings" + ("" if handled else " (via Google search)")
    return raw


def prefilter(jobs: list[RawJob], settings: dict, profile: dict, roles: list[str]) -> list[RawJob]:
    """Cheap keyword gate before spending LLM calls."""
    countries = [normalize_location(c) for c in settings["countries"]]
    excludes = [x.lower() for x in settings.get("exclude_keywords") or []]
    role_words = {w for r in roles for w in r.lower().split() if len(w) > 2 and w not in {"senior", "junior", "lead", "engineer", "developer", "and"}}
    skills = [s.lower() for s in (profile.get("skills") or []) if len(s) > 1][:60]
    extra = [k.lower() for k in settings.get("keywords") or []]
    kept = []
    for j in jobs:
        title = j.title.lower()
        if any(x in title for x in excludes):
            continue
        if j.country not in countries and location_matches(j.location, countries, settings["remote_ok"]) is False:
            continue
        text = f"{title}\n{j.description.lower()[:6000]}"
        skill_hits = sum(1 for s in skills if s in text)
        if any(w in title for w in role_words) or any(k in text for k in extra) or skill_hits >= 3:
            kept.append(j)
    return kept


def rate(jobs: list[RawJob], settings: dict, profile_brief: str, roles: list[str]) -> list[tuple[RawJob, int, str]]:
    out = []
    for start in range(0, len(jobs), 15):
        batch = jobs[start:start + 15]
        listing = "\n\n".join(
            f"[{i}] {j.title} @ {j.company} ({j.location})\n{j.description[:900]}" for i, j in enumerate(batch)
        )
        res = llm.ask_json(RELEVANCE_PROMPT.format(
            profile=profile_brief[:6000], roles=", ".join(roles),
            countries=", ".join(country_name(normalize_location(c)) for c in settings["countries"]),
            remote=settings["remote_ok"], jobs=listing), fast=True, temperature=0)
        scores = {int(r["i"]): r for r in res if isinstance(r, dict) and "i" in r} if isinstance(res, list) else {}
        for i, j in enumerate(batch):
            r = scores.get(i, {})
            out.append((j, int(r.get("score", 0)), r.get("reason", NA)))
    return out


def run(run: db.PipelineRun, settings: dict, profile: dict, profile_brief: str, pools: dict, force_all: bool = False) -> int:
    roles = settings.get("target_roles") or (profile.get("titles") or [])[:3]
    if not roles:
        raise RuntimeError("No target roles: set them in Settings or upload a resume first")

    raw = collect(run, settings, roles, force_all, pools)
    run.scanned += len(raw)
    run.note(f"Scanned {len(raw)} postings")

    # De-duplicate against the database and across sources.
    fps = db.recent_fingerprints(run.user_id)
    fresh: list[RawJob] = []
    by_source: dict[str, list[RawJob]] = {}
    for j in raw:
        by_source.setdefault(j.source, []).append(j)
    for source, items in by_source.items():
        known = db.existing_keys(run.user_id, source, [j.external_id for j in items])
        for j in items:
            fp = db.fingerprint(j.company, j.title)
            if j.external_id in known or fp in fps:
                continue
            fps.add(fp)
            fresh.append(j)

    fresh = _hydrate_new(run, fresh)
    candidates = prefilter(fresh, settings, profile, roles)
    run.note(f"{len(fresh)} new, {len(candidates)} pass keyword filter")
    if not candidates:
        return 0

    with run.agent("scout", message=f"Rating relevance of {len(candidates)} jobs against resume") as task:
        rated = rate(candidates, settings, profile_brief, roles)
        keep = [(j, s, why) for j, s, why in rated if s >= settings["min_relevance"]]
        task.message = f"{len(keep)} of {len(candidates)} jobs match the resume (≥{settings['min_relevance']})"

    stored = 0
    for job, score, why in sorted(keep, key=lambda x: -x[1]):
        if len(job.description) < 800 or job.description == NA:
            _enrich(job)
        row = job.as_row()
        row.update(job_id=new_job_id(), user_id=run.user_id, relevance=score, relevance_reason=why, status="new")
        if job.salary_text != NA:
            row["salary_source"] = "job_posting"
        if est := job.extra.get("adzuna_estimate"):
            row["meta"] = {"adzuna_estimate": est}
        try:
            db.insert_job(row)
            stored += 1
        except Exception as exc:  # unique violation from a concurrent insert, etc.
            log.warning("insert failed for %s: %s", job.title, exc)
    run.matched += stored
    return stored


MAX_HYDRATE_PER_RUN = 40


def _hydrate_new(run: db.PipelineRun, jobs: list[RawJob]) -> list[RawJob]:
    """Workday/SmartRecruiters lists are title-only: fetch full details for new jobs only (capped per run).
    Jobs beyond the cap are skipped this run and picked up by a later one."""
    thin = [j for j in jobs if "hydrate" in j.extra]
    if not thin:
        return jobs
    ready, done, failed = [j for j in jobs if "hydrate" not in j.extra], 0, 0
    for j in thin[:MAX_HYDRATE_PER_RUN]:
        try:
            boards.hydrate(j)
            ready.append(j)
            done += 1
        except Exception as exc:
            failed += 1
            log.warning("details for %s failed: %s", j.title, exc)
    run.note(f"Loaded details for {done} new Workday/SmartRecruiters jobs"
             + (f", {len(thin) - MAX_HYDRATE_PER_RUN} left for the next run" if len(thin) > MAX_HYDRATE_PER_RUN else "")
             + (f", {failed} failed" if failed else ""))
    return ready


def _enrich(job: RawJob) -> None:
    details = fetch_page_details(job.url)
    if details.get("description") and len(details["description"]) > len(job.description if job.description != NA else ""):
        job.description = details["description"]
    if job.salary_text == NA and (details.get("salary_min") or details.get("salary_max")):
        job.salary_min, job.salary_max = details.get("salary_min"), details.get("salary_max")
        job.salary_currency = details.get("salary_currency") or NA
        job.salary_text = format_salary(job.salary_min, job.salary_max, job.salary_currency, details.get("salary_period") or NA)
    if details.get("final_url") and job.apply_url == NA:
        job.apply_url = details["final_url"]
