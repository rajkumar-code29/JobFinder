"""ATS score and suggestions for a resume vs a JD. Doesn't edit anything."""
from __future__ import annotations

import json

from .. import db, llm

SYSTEM = ("You are an ATS (applicant tracking system) engine and a senior technical recruiter. "
          "Score like real ATS parsers (keyword/skill coverage, title match, seniority, required qualifications) "
          "and like a recruiter screening for interviews. Be calibrated and honest.")

PROMPT = """JOB
Title: {title}
Company: {company}
Location: {location}
Description:
{jd}

RESUME
{resume}

Return ONLY JSON:
{{"ats_score": 0-100, "shortlist_probability": 0-100,
  "summary": "2-3 sentence verdict",
  "keyword_match": {{"matched": [str], "missing_required": [str], "missing_nice_to_have": [str]}},
  "strengths": [str], "gaps": [str],
  "seniority_fit": "under|match|over", "title_alignment": "weak|ok|strong",
  "suggestions": [{{"section": "summary|skills|experience:<company>|projects|education|other",
                    "change": "concrete edit to make", "reason": str, "impact": "high|medium|low",
                    "adjacent_skill": bool}}],
  "interview_focus": ["topics the interviewer will most likely probe"]}}
Suggestions must be specific enough for an editor to apply. Mark adjacent_skill=true when the suggestion adds a
skill not evidenced in the resume but closely related to skills it does show."""


def score(job: dict, resume_text: str) -> dict:
    return llm.ask_json(PROMPT.format(title=job["title"], company=job["company"], location=job["location"],
                                      jd=job["description"][:14000], resume=resume_text[:20000]), system=SYSTEM, temperature=0,
                        agent="scorer")


def report_markdown(job: dict, rep: dict, tailored: dict | None = None) -> str:
    km = rep.get("keyword_match") or {}
    lines = [
        f"# Suggestions Report - {job['title']} @ {job['company']}",
        f"Job ID: `{job['job_id']}`",
        "",
        f"**ATS score (parent resume):** {rep.get('ats_score')}%  ",
        f"**Shortlist probability:** {rep.get('shortlist_probability')}%  ",
        f"**Seniority fit:** {rep.get('seniority_fit')} · **Title alignment:** {rep.get('title_alignment')}",
        "",
        rep.get("summary", ""),
        "",
        "## Keywords",
        f"- **Matched:** {', '.join(km.get('matched', [])) or '-'}",
        f"- **Missing (required):** {', '.join(km.get('missing_required', [])) or '-'}",
        f"- **Missing (nice to have):** {', '.join(km.get('missing_nice_to_have', [])) or '-'}",
        "",
        "## Strengths", *[f"- {s}" for s in rep.get("strengths", [])],
        "", "## Gaps", *[f"- {s}" for s in rep.get("gaps", [])],
        "", "## Suggestions",
    ]
    for s in rep.get("suggestions", []):
        tag = " _(adjacent skill)_" if s.get("adjacent_skill") else ""
        lines.append(f"- **[{s.get('impact', '').upper()}] {s.get('section')}** - {s.get('change')}{tag}  \n  _{s.get('reason')}_")
    if rep.get("interview_focus"):
        lines += ["", "## Likely interview focus", *[f"- {s}" for s in rep["interview_focus"]]]
    if tailored:
        lines += ["", "## After tailoring",
                  f"**ATS score (tailored resume):** {tailored.get('ats_score')}%  ",
                  f"**Shortlist probability:** {tailored.get('shortlist_probability')}%", "",
                  tailored.get("summary", "")]
    return "\n".join(lines) + "\n"


def run(run: db.PipelineRun, job: dict, profile: dict) -> dict:
    with run.agent("scorer", job["job_id"], "Scoring parent resume against JD") as task:
        rep = score(job, profile["resume_text"])
        prefix = db.job_dir(job)
        db.upload(f"{prefix}/job.json", json.dumps({k: job[k] for k in (
            "job_id", "title", "company", "location", "country", "url", "apply_url", "salary_text", "salary_source",
            "posted_at", "source", "description")}, indent=2, ensure_ascii=False).encode(), "application/json")
        db.upload(f"{prefix}/report.json", json.dumps(rep, indent=2, ensure_ascii=False).encode(), "application/json")
        db.upload(f"{prefix}/Suggestions Report.md", report_markdown(job, rep).encode(), "text/markdown")
        files = {**(job.get("files") or {}), "job": f"{prefix}/job.json", "report_json": f"{prefix}/report.json",
                 "report_md": f"{prefix}/Suggestions Report.md"}
        values = {"ats_score": int(rep.get("ats_score") or 0), "shortlist_probability": int(rep.get("shortlist_probability") or 0),
                  "files": files, "status": "scored", "meta": db.model_meta(job, "scorer", llm.last_model)}
        db.update_job(job["job_id"], values)
        job.update(values)
        task.message = f"ATS {values['ats_score']}%, shortlist {values['shortlist_probability']}%"
        return rep
