"""Scout agents: fetch postings from every enabled source, keep only resume-relevant ones, store them."""
from __future__ import annotations

import hashlib
import json
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


def source_plan(settings: dict, roles: list[str], force_all: bool, pools: dict) -> list[tuple[str, callable]]:
    """(label, fetch) for every source due this run, in the order they're scanned: the user's own company
    boards first (highest intent), then the aggregators. The Scout stops as soon as the batch is full."""
    countries = [normalize_location(c) for c in settings["countries"]] or ["us"]
    src = settings.get("sources") or {}
    hour = _hour()
    plan: list[tuple[str, callable]] = []

    for board in settings.get("job_boards") or []:
        url = (board or {}).get("url", "").strip()
        if not url or not board.get("enabled", True):
            continue
        def fetch_board(url=url):
            found, handled = boards.fetch_board(url, roles)
            if not handled:
                found = google_search.search_site(url, roles, countries) if (hour % 4 == 0 or force_all) else []
            return found
        plan.append((f"board {url}", fetch_board))

    for name, enabled, due, fetch in [
        ("adzuna", src.get("adzuna", True), True, lambda: aggregators.adzuna(roles, countries, pools["adzuna"])),
        ("jsearch", src.get("jsearch", True), hour == 6, lambda: aggregators.jsearch(roles, countries, pools["rapidapi"])),
        ("remotive", src.get("remotive", True) and settings["remote_ok"], hour % 6 == 0, lambda: aggregators.remotive(roles, countries)),
        ("arbeitnow", src.get("arbeitnow", True), True, lambda: aggregators.arbeitnow(roles, countries)),
        ("google_search", src.get("google_search", True), hour % 4 == 0, lambda: google_search.search_roles(roles, countries)),
    ]:
        if enabled and (due or (force_all and name != "jsearch")):
            plan.append((name, fetch))
    return plan


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
        try:
            res = llm.ask_json(RELEVANCE_PROMPT.format(
                profile=profile_brief[:6000], roles=", ".join(roles),
                countries=", ".join(country_name(normalize_location(c)) for c in settings["countries"]),
                remote=settings["remote_ok"], jobs=listing), fast=True, temperature=0)
        except llm.StopUser:
            raise
        except Exception as exc:  # one bad batch shouldn't lose the rest; these jobs get re-rated next run
            log.warning("relevance batch failed: %s", exc)
            continue
        scores = {int(r["i"]): r for r in res if isinstance(r, dict) and "i" in r} if isinstance(res, list) else {}
        for i, j in enumerate(batch):
            r = scores.get(i, {})
            out.append((j, int(r.get("score", 0)), r.get("reason", NA)))
    return out


def run(run: db.PipelineRun, settings: dict, profile: dict, profile_brief: str, pools: dict,
        force_all: bool = False, limit: int | None = None, should_stop=lambda: False) -> int:
    """Scan sources one at a time; rate what's new; store relevant jobs (best first) until `limit` are stored."""
    roles = settings.get("target_roles") or (profile.get("titles") or [])[:3]
    if not roles:
        raise RuntimeError("No target roles: set them in Settings or upload a resume first")
    threshold = settings["min_relevance"]
    context = rating_context(profile, settings, roles)
    fps = db.recent_fingerprints(run.user_id)
    stored = 0

    for label, fetch in source_plan(settings, roles, force_all, pools):
        if should_stop():
            raise llm.Paused("Agents paused by an admin")
        try:
            with run.agent("scout", message=f"Scanning {label}") as task:
                raw = fetch()
                task.message = f"{label}: {len(raw)} postings"
        except llm.StopUser:
            raise
        except Exception:
            continue  # already logged as an agent error; the other sources still run
        run.scanned += len(raw)
        keep = _evaluate(run, raw, fps, settings, profile, profile_brief, roles, context, threshold)
        for job, score, why in sorted(keep, key=lambda x: -x[1]):
            if limit is not None and stored >= limit:
                break  # rated and remembered: picked up for a later batch without asking the AI again
            if _store(run, job, score, why):
                stored += 1
        if limit is not None and stored >= limit:
            run.note(f"Found {stored} relevant jobs – enough for this batch, stopping the scan")
            break
    run.matched += stored
    return stored


def _evaluate(run: db.PipelineRun, raw: list[RawJob], fps: set[str], settings: dict, profile: dict,
              profile_brief: str, roles: list[str], context: str, threshold: int) -> list[tuple[RawJob, int, str]]:
    """De-duplicate, skip postings already rated or deleted, then rate the rest. Returns the relevant ones."""
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
    if not fresh:
        return []

    by_key, by_fp = db.seen_lookup(run.user_id, context, [(j.source, j.external_id, db.fingerprint(j.company, j.title)) for j in fresh])
    unseen, reuse, skipped = [], [], 0
    for j in fresh:
        prev = by_key.get((j.source, j.external_id)) or by_fp.get(db.fingerprint(j.company, j.title))
        if prev is None:
            unseen.append(j)
        elif prev["relevance"] >= threshold:
            reuse.append((j, prev["relevance"], prev["reason"]))  # rated earlier and relevant: no AI call
        else:
            skipped += 1  # rejected earlier, or deleted by the user

    unseen = _hydrate_new(run, unseen)
    reused_jobs = {id(j) for j in _hydrate_new(run, [j for j, _, _ in reuse])}
    reuse = [r for r in reuse if id(r[0]) in reused_jobs]
    candidates = prefilter(unseen, settings, profile, roles)
    run.note(f"{len(fresh)} not yet saved: {skipped} already rated or deleted (skipped, no AI), "
             f"{len(unseen)} new, {len(candidates)} pass the keyword filter"
             + (f", {len(reuse)} rated earlier and relevant" if reuse else ""))

    keep = list(reuse)
    if candidates:
        with run.agent("scout", message=f"Rating relevance of {len(candidates)} jobs against resume") as task:
            rated = rate(candidates, settings, profile_brief, roles)
            db.record_seen(run.user_id, context, [
                {"source": j.source, "external_id": j.external_id, "fingerprint": db.fingerprint(j.company, j.title),
                 "relevance": score, "reason": (why or NA)[:500]}
                for j, score, why in rated])
            relevant = [(j, score, why) for j, score, why in rated if score >= threshold]
            keep += relevant
            task.message = f"{len(relevant)} of {len(candidates)} jobs match the resume (≥{threshold})"
    return keep


def _store(run: db.PipelineRun, job: RawJob, score: int, why: str) -> bool:
    """Save a relevant job, loading the complete description from the posting page when the feed only had a snippet."""
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
        return True
    except Exception as exc:  # unique violation from a concurrent insert, etc.
        log.warning("insert failed for %s: %s", job.title, exc)
        return False


def rating_context(profile: dict, settings: dict, roles: list[str]) -> str:
    """What a relevance rating depends on. If the resume, roles, locations or remote preference change,
    earlier ratings no longer apply and postings are rated again."""
    basis = {
        "resume": profile.get("resume_hash"),
        "roles": sorted(r.lower().strip() for r in roles),
        "locations": sorted(str(normalize_location(c)).lower() for c in settings["countries"]),
        "remote": bool(settings["remote_ok"]),
    }
    return hashlib.sha256(json.dumps(basis, sort_keys=True).encode()).hexdigest()[:16]


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
