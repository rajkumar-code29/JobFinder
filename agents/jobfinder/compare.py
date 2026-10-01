"""Model comparisons (AI models -> Compare in the app).

Runs the same jobs through 2-4 models for one agent without saving anything to the jobs. Metrics:
scout = score vs production, scorer = ATS, tailor = ATS gain judged by the normal scorer,
coach = valid question counts, writer = word count (quality is voted on blind in the app).
"""
from __future__ import annotations

import json
import logging
import time

from . import control, db, docs, llm
from .agents import coach, profile as profile_agent, scorer, scout, tailor, writer
from .keys import AI_PROVIDERS, KeyStateStore, build_pools, shared_keys
from .sources.base import RawJob

log = logging.getLogger("jobfinder")


def _jobs(user_id: str, agent: str, count: int) -> list[dict]:
    """Recent jobs usable for this agent (tailor/coach/writer need a scoring report)."""
    q = db.sb.table("jobs").select("*").eq("user_id", user_id).order("created_at", desc=True).limit(80)
    rows = q.execute().data
    if agent in ("tailor", "coach", "writer"):
        rows = [r for r in rows if (r.get("files") or {}).get("report_json")]
    rows = [r for r in rows if r.get("description") and r["description"] != "NA"]
    rows.sort(key=lambda r: (r.get("batch_rank") or 999, -(r.get("relevance") or 0)))
    return rows[:count]


def _one(agent: str, job: dict, profile: dict, brief: str, settings: dict, parent_docx: bytes | None) -> tuple[str, dict]:
    """One agent on one job with the current routing -> (output, metrics)."""
    if agent == "scout":
        roles = settings.get("target_roles") or (profile.get("titles") or [])[:3]
        raw = RawJob(job["source"], job["external_id"], job["title"], job["company"], location=job["location"],
                     country=job["country"], description=job["description"])
        rated = scout.rate([raw], settings, brief, roles)
        if not rated:
            raise RuntimeError("no rating returned")
        score, why = rated[0][1], rated[0][2]
        return f"{score}/100 - {why}", {"score": score, "production": job.get("relevance"),
                                        "difference": None if job.get("relevance") is None else score - job["relevance"]}
    if agent == "scorer":
        rep = scorer.score(job, profile["resume_text"])
        text = rep.get("summary", "") + "\n\n" + "\n".join(f"• {s.get('change')}" for s in (rep.get("suggestions") or [])[:6])
        return text, {"ats": rep.get("ats_score"), "shortlist": rep.get("shortlist_probability"),
                      "production_ats": job.get("ats_score")}
    report = json.loads(db.download(job["files"]["report_json"]))
    if agent == "tailor":
        if not parent_docx:
            raise RuntimeError("Tailoring needs a .docx parent resume")
        tailored, plan = tailor._pass(parent_docx, job, report, settings.get("target_ats") or 95)
        plan.pop("_model", None)
        judged = scorer.score(job, docs.docx_text(tailored))  # same judge for every model
        added = [a.get("skill") for a in plan.get("added_skills", []) if isinstance(a, dict)]
        text = ("Changes:\n" + "\n".join(f"• {c}" for c in plan.get("changes_summary", []))
                + (f"\n\nAdjacent skills added: {', '.join(added)}" if added else "")
                + "\n\n--- Tailored resume ---\n" + docs.docx_text(tailored))
        before = job.get("ats_score")
        after = judged.get("ats_score")
        return text, {"ats_before": before, "ats_after": after,
                      "gain": None if before is None or after is None else after - before,
                      "edits": len(plan.get("edits", [])) + len(plan.get("inserts", [])), "added_skills": len(added)}
    if agent == "coach":
        pack = llm.ask_json(coach.PROMPT.format(
            title=job["title"], company=job["company"], location=job["location"], jd=job["description"][:10000],
            profile=brief[:8000], focus=", ".join(report.get("interview_focus") or [])),
            agent="coach", system=coach.SYSTEM, temperature=0.5)
        mcq = [q for q in pack.get("mcq", []) if isinstance(q.get("options"), list)
               and isinstance(q.get("answer_index"), int) and 0 <= q["answer_index"] < len(q["options"])]
        return json.dumps(pack, ensure_ascii=False)[:60000], {
            "mcq": len(mcq), "mcq_invalid": len(pack.get("mcq", [])) - len(mcq),
            "technical": len(pack.get("technical", [])), "coding": len(pack.get("coding", [])),
            "behavioral": len(pack.get("behavioral", []))}
    if agent == "writer":
        from datetime import date
        letter = llm.ask_json(writer.PROMPT.format(
            title=job["title"], company=job["company"], location=job["location"], jd=job["description"][:8000],
            profile=brief[:8000], parent=(profile.get("cover_letter_text") or "NA")[:8000],
            added=", ".join(a.get("skill", "") for a in job.get("added_skills") or []) or "none",
            today=date.today().strftime("%d %B %Y")), agent="writer", system=writer.SYSTEM, temperature=0.7)
        text = "\n\n".join([letter.get("greeting", ""), *letter.get("paragraphs", []), letter.get("closing", "")])
        return text, {"words": len(text.split())}
    raise ValueError(f"unknown agent {agent}")


def run(comparison_id: int) -> int:
    comp = db.sb.table("model_comparisons").select("*").eq("id", comparison_id).single().execute().data
    agent, models, uid = comp["agent"], comp["models"], comp["requested_by"]
    db.sb.table("model_comparisons").update({"status": "running"}).eq("id", comparison_id).execute()
    log.info("Comparison #%s: %s with %s", comparison_id, agent, models)
    try:
        account = db.sb.table("accounts").select("*").eq("user_id", uid).single().execute().data
        store = KeyStateStore()
        pools = build_pools(account, db.user_api_keys(uid), store, shared_keys(store))
        llm.activate({p: pools[p] for p in AI_PROVIDERS}, 250, should_stop=control.paused)
        settings = db.get_settings(uid)
        profile = db.get_profile(uid)
        files = profile_agent.load_parent_files(uid)
        profile = {**profile, **(files or {})}
        brief = profile_agent.brief(profile)
        parent = db.download(files["resume_docx"], db.PARENT_BUCKET) if files and files.get("resume_docx") else None
        jobs = _jobs(uid, agent, comp["job_count"])
        if not jobs:
            raise RuntimeError("No suitable jobs yet - run a batch first (tailor/coach/writer need scored jobs)")

        base_routing = db.model_routing()
        done = 0
        for job in jobs:
            for spec in models:
                if control.paused():
                    raise llm.Paused("Agents paused by an admin")
                llm.set_routing({**base_routing, agent: [spec]})  # no fallback
                started = time.monotonic()
                try:
                    output, metrics = _one(agent, job, profile, brief, settings, parent)
                    metrics = {**metrics, "ok": True, "seconds": round(time.monotonic() - started, 1),
                               "model_used": llm.last_model}
                except llm.Paused:
                    raise
                except Exception as exc:
                    output, metrics = None, {"ok": False, "error": str(exc)[:500],
                                             "seconds": round(time.monotonic() - started, 1)}
                db.sb.table("comparison_results").insert({
                    "comparison_id": comparison_id, "job_id": job["job_id"], "model": spec,
                    "output": output, "metrics": metrics}).execute()
                done += 1
        status, message = "done", f"{done} results for {len(jobs)} jobs"
    except Exception as exc:
        log.exception("comparison failed")
        status, message = "error", str(exc)[:500]
    finally:
        llm.set_routing(db.model_routing())
        db.record_model_stats(llm.take_stats())
    db.sb.table("model_comparisons").update(
        {"status": status, "message": message, "finished_at": db.now_iso()}).eq("id", comparison_id).execute()
    log.info("Comparison #%s %s: %s", comparison_id, status, message)
    return 0 if status == "done" else 1
