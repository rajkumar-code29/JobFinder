"""Interview prep pack: MCQs, technical, coding and behavioral questions."""
from __future__ import annotations

import json

from .. import db, llm

SYSTEM = ("You are a hiring manager and senior interviewer for this exact role. You write realistic interview "
          "questions that match what this company and role would actually ask, at the right seniority.")

PROMPT = """Create an interview preparation pack for this candidate and job.

JOB: {title} @ {company} ({location})
{jd}

CANDIDATE: {profile}

LIKELY FOCUS AREAS: {focus}

Return ONLY JSON:
{{"overview": {{"role_summary": str, "interview_process_guess": [str], "company_notes": str}},
  "mcq": [{{"id": int, "topic": str, "difficulty": "easy|medium|hard", "question": str,
            "options": [str, str, str, str], "answer_index": 0-3,
            "explanation": "why the right answer is right", "why_wrong": [str, str, str, str]}}],
  "technical": [{{"id": int, "topic": str, "question": str, "what_they_look_for": [str],
                  "model_answer": str, "follow_ups": [str]}}],
  "coding": [{{"id": int, "title": str, "difficulty": "easy|medium|hard", "prompt": str,
               "examples": [{{"input": str, "output": str}}], "constraints": [str], "hints": [str],
               "language": str, "solution": str, "complexity": str, "explanation": str}}],
  "behavioral": [{{"id": int, "question": str, "why_asked": str, "star_outline": str}}],
  "questions_to_ask": [str]}}
Counts: 15 mcq (mix of difficulties, grounded in the JD's tech stack), 8 technical, 3 coding (in the role's
primary language; if the role is non-coding, make them role-appropriate practical exercises), 5 behavioral that
use the candidate's real experience, 5 questions_to_ask. "why_wrong" has one entry per option ("" for the correct one)."""


def _strs(v) -> list[str]:
    if isinstance(v, str):
        return [v] if v.strip() else []
    return [str(x) for x in v] if isinstance(v, list) else []


def _items(v) -> list[dict]:
    return [x for x in v if isinstance(x, dict)] if isinstance(v, list) else []


def clean_pack(pack) -> dict:
    """Coerce the pack into the shape the app expects and drop broken entries."""
    pack = pack if isinstance(pack, dict) else {}
    ov = pack.get("overview") if isinstance(pack.get("overview"), dict) else {}
    mcq = []
    for q in _items(pack.get("mcq")):
        options = _strs(q.get("options"))
        try:
            answer = int(q.get("answer_index"))
        except (TypeError, ValueError):
            continue
        if q.get("question") and len(options) >= 2 and 0 <= answer < len(options):
            why = _strs(q.get("why_wrong"))
            mcq.append({**q, "question": str(q["question"]), "options": options, "answer_index": answer,
                        "explanation": str(q.get("explanation") or ""), "why_wrong": (why + [""] * len(options))[:len(options)]})
    technical = [{**q, "question": str(q["question"]), "what_they_look_for": _strs(q.get("what_they_look_for")),
                  "follow_ups": _strs(q.get("follow_ups")), "model_answer": str(q.get("model_answer") or "")}
                 for q in _items(pack.get("technical")) if q.get("question")]
    coding = [{**q, "title": str(q.get("title") or "Coding exercise"), "prompt": str(q["prompt"]),
               "examples": [e for e in _items(q.get("examples"))], "constraints": _strs(q.get("constraints")),
               "hints": _strs(q.get("hints")), "solution": str(q.get("solution") or "")}
              for q in _items(pack.get("coding")) if q.get("prompt")]
    behavioral = [{**q, "question": str(q["question"]), "star_outline": str(q.get("star_outline") or "")}
                  for q in _items(pack.get("behavioral")) if q.get("question")]
    if not (mcq or technical or coding):
        raise ValueError("interview pack came back empty or unreadable")
    return {
        "overview": {"role_summary": str(ov.get("role_summary") or ""), "company_notes": str(ov.get("company_notes") or ""),
                     "interview_process_guess": _strs(ov.get("interview_process_guess"))},
        "mcq": mcq, "technical": technical, "coding": coding, "behavioral": behavioral,
        "questions_to_ask": _strs(pack.get("questions_to_ask")),
    }


def run(run: db.PipelineRun, job: dict, profile_brief: str, report: dict) -> None:
    with run.agent("coach", job["job_id"], "Preparing interview questions") as task:
        pack = llm.ask_json(PROMPT.format(
            title=job["title"], company=job["company"], location=job["location"], jd=job["description"][:10000],
            profile=profile_brief[:8000], focus=", ".join(report.get("interview_focus") or [])), agent="coach",
            system=SYSTEM, temperature=0.5)
        model = llm.last_model
        pack = clean_pack(pack)
        path = db.upload(f"{db.job_dir(job)}/interview.json", json.dumps(pack, indent=2, ensure_ascii=False).encode(), "application/json")
        files = {**(job.get("files") or {}), "interview": path}
        meta = db.model_meta(job, "coach", model)
        db.update_job(job["job_id"], {"files": files, "meta": meta})
        job.update(files=files, meta=meta)
        task.message = f"{len(pack['mcq'])} MCQ, {len(pack.get('technical', []))} technical, {len(pack.get('coding', []))} coding"
