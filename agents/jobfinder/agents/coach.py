"""Coach agent: interview prep pack (MCQ with explanations, technical Q&A, coding problems, behavioral)."""
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


def run(run: db.PipelineRun, job: dict, profile_brief: str, report: dict) -> None:
    with run.agent("coach", job["job_id"], "Preparing interview questions") as task:
        pack = llm.ask_json(PROMPT.format(
            title=job["title"], company=job["company"], location=job["location"], jd=job["description"][:10000],
            profile=profile_brief[:8000], focus=", ".join(report.get("interview_focus") or [])), system=SYSTEM, temperature=0.5)
        # Guard against malformed MCQs so the app never crashes on them.
        pack["mcq"] = [q for q in pack.get("mcq", [])
                       if isinstance(q.get("options"), list) and len(q["options"]) >= 2
                       and isinstance(q.get("answer_index"), int) and 0 <= q["answer_index"] < len(q["options"])]
        path = db.upload(f"{db.job_dir(job)}/interview.json", json.dumps(pack, indent=2, ensure_ascii=False).encode(), "application/json")
        files = {**(job.get("files") or {}), "interview": path}
        db.update_job(job["job_id"], {"files": files})
        job["files"] = files
        task.message = f"{len(pack['mcq'])} MCQ, {len(pack.get('technical', []))} technical, {len(pack.get('coding', []))} coding"
