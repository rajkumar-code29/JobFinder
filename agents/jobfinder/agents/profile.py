"""Profile agent: knows the parent resume + parent cover letter. Re-parses only when a file changes."""
from __future__ import annotations

import hashlib
import json

from .. import db, docs, llm

SYSTEM = "You are a meticulous technical recruiter who extracts structured, factual data from resumes. Never invent facts."

PROMPT = """Parse this resume into JSON with exactly these keys:
{{"name": str, "email": str, "phone": str, "location": str, "links": [str],
  "headline": str, "summary": "3-4 sentence professional summary",
  "years_experience": number, "seniority": "junior|mid|senior|lead|principal",
  "titles": ["5-8 job titles this person is a strong fit for, most relevant first"],
  "search_keywords": ["8-15 keywords a recruiter would search to find this person"],
  "skills": ["every hard skill, tool, language, framework, platform mentioned"],
  "skills_by_category": {{"category": [skills]}},
  "experience": [{{"company": str, "title": str, "start": str, "end": str, "location": str, "highlights": [str]}}],
  "education": [{{"institution": str, "degree": str, "year": str}}],
  "certifications": [str], "projects": [{{"name": str, "description": str, "tech": [str]}}],
  "domains": ["industries/domains worked in"]}}
Use "NA" for unknown strings.

RESUME:
{resume}

ADDITIONAL CONTEXT FROM THE CANDIDATE'S MASTER COVER LETTER (for background only):
{cover}"""


def _pick(files: list[dict], prefer: tuple[str, ...]) -> list[dict]:
    return sorted(files, key=lambda f: next((i for i, ext in enumerate(prefer) if f["name"].lower().endswith(ext)), 99))


def load_parent_files(user_id: str) -> dict | None:
    """Parent documents live in parent/<user_id>/resume/ and parent/<user_id>/cover_letter/."""
    resume_files = _pick(db.list_files(f"{user_id}/resume", db.PARENT_BUCKET), (".docx", ".pdf"))
    cover_files = _pick(db.list_files(f"{user_id}/cover_letter", db.PARENT_BUCKET), (".docx", ".pdf", ".txt"))
    if not resume_files:
        return None
    out = {"resume_files": [f"{user_id}/resume/{f['name']}" for f in resume_files]}
    docx = next((f for f in resume_files if f["name"].lower().endswith(".docx")), None)
    out["resume_docx"] = f"{user_id}/resume/{docx['name']}" if docx else None
    out["cover_letter"] = f"{user_id}/cover_letter/{cover_files[0]['name']}" if cover_files else None
    return out


def run(run: db.PipelineRun) -> dict | None:
    """Returns the profile, or None when the user hasn't uploaded a resume yet."""
    files = load_parent_files(run.user_id)
    if files is None:
        return None
    with run.agent("profile", message="Reading parent resume and cover letter") as task:
        primary = files["resume_docx"] or files["resume_files"][0]
        resume_bytes = db.download(primary, db.PARENT_BUCKET)
        cover_bytes = db.download(files["cover_letter"], db.PARENT_BUCKET) if files["cover_letter"] else b""
        r_hash = hashlib.sha256(resume_bytes).hexdigest()
        c_hash = hashlib.sha256(cover_bytes).hexdigest() if cover_bytes else "NA"

        profile = db.get_profile(run.user_id)
        if profile["resume_hash"] == r_hash and profile["cover_letter_hash"] == c_hash and profile["structured"]:
            task.message = "Parent documents unchanged – using cached profile"
            return {**profile, **files}

        resume_text = docs.any_text(primary, resume_bytes)
        cover_text = docs.any_text(files["cover_letter"], cover_bytes) if cover_bytes else "NA"
        data = llm.ask_json(PROMPT.format(resume=resume_text[:30000], cover=cover_text[:12000]), agent="profile", system=SYSTEM)
        values = {
            "resume_filename": primary.rsplit("/", 1)[1],
            "resume_hash": r_hash, "cover_letter_hash": c_hash,
            "resume_text": resume_text, "cover_letter_text": cover_text,
            "summary": data.get("summary") or "NA",
            "skills": data.get("skills") or [], "titles": data.get("titles") or [],
            "structured": data,
        }
        db.update_profile(run.user_id, values)
        task.message = f"Profile parsed: {len(values['skills'])} skills, fits {', '.join(values['titles'][:3])}"
        return {**profile, **values, **files}


def brief(profile: dict) -> str:
    """Compact profile for prompts."""
    s = profile.get("structured") or {}
    keep = {k: s.get(k) for k in ("name", "headline", "summary", "years_experience", "seniority", "titles",
                                  "skills_by_category", "experience", "education", "certifications", "projects", "domains")}
    return json.dumps(keep, ensure_ascii=False)[:20000]
