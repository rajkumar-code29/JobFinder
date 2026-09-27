"""Writer agent: tailored cover letter. The parent cover letter is background only – never copied."""
from __future__ import annotations

from datetime import date

from .. import db, docs, llm

SYSTEM = ("You write concise, specific, human-sounding cover letters. No clichés ('I am writing to express…', "
          "'passionate', 'perfect fit'), no repeating the resume line by line, no invented facts.")

PROMPT = """Write a cover letter for this job.

JOB: {title} @ {company} ({location})
{jd}

CANDIDATE PROFILE: {profile}

CANDIDATE'S MASTER COVER LETTER — background about the person ONLY. Do NOT reuse its sentences or structure;
write a new letter specific to this job:
{parent}

ADJACENT SKILLS ADDED TO THE TAILORED RESUME (mention only if genuinely relevant, framed honestly as familiarity):
{added}

Requirements: 250-350 words, 3-4 body paragraphs: a hook tied to this company/role, 2 concrete achievements mapped to
the JD's top requirements, why this company, a confident close. Today is {today}.
Return ONLY JSON: {{"date": str, "recipient": "Hiring Manager or named person if the JD names one", "company": str,
"company_location": str, "subject": "Application for <title>", "greeting": str, "paragraphs": [str],
"closing": "Sincerely,"}}"""


def run(run: db.PipelineRun, job: dict, profile: dict, profile_brief: str) -> None:
    with run.agent("writer", job["job_id"], "Writing cover letter") as task:
        letter = llm.ask_json(PROMPT.format(
            title=job["title"], company=job["company"], location=job["location"], jd=job["description"][:8000],
            profile=profile_brief[:8000], parent=(profile.get("cover_letter_text") or "NA")[:8000],
            added=", ".join(a.get("skill", "") for a in job.get("added_skills") or []) or "none",
            today=date.today().strftime("%d %B %Y")), system=SYSTEM, temperature=0.7)
        s = profile.get("structured") or {}
        header = {"name": s.get("name"), "email": s.get("email"), "phone": s.get("phone"),
                  "location": s.get("location"), "link": (s.get("links") or [None])[0]}
        data = docs.cover_letter_docx(header, letter)
        prefix = db.job_dir(job)
        files = {**(job.get("files") or {}), "cover_letter_docx": db.upload(f"{prefix}/Cover Letter.docx", data, docs.DOCX_MIME)}
        try:
            pdf = docs.docx_to_pdf(data, "Cover Letter")
        except Exception:
            pdf = None
        if pdf:
            files["cover_letter_pdf"] = db.upload(f"{prefix}/Cover Letter.pdf", pdf, docs.PDF_MIME)
        db.update_job(job["job_id"], {"files": files})
        job["files"] = files
        task.message = f"Cover letter written ({sum(len(p.split()) for p in letter.get('paragraphs', []))} words)"
