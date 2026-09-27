"""Tailor agent: applies the Scorer's suggestions to a copy of the parent .docx (formatting preserved),
re-scores, and iterates until the target ATS score or the pass limit. Saved under the parent's file name."""
from __future__ import annotations

import json
from pathlib import Path

from .. import db, docs, llm
from . import scorer

MAX_PASSES = 2

SYSTEM = ("You are an expert resume writer. You tailor resumes to a specific job so they pass ATS filters and "
          "impress recruiters, while keeping the candidate's real history intact.")

PROMPT = """Tailor this resume for the job below. Target ATS score: {target}%+ (current: {current}%).

RULES
- Never change: name, contact details, employers, job titles held, dates, degrees, institutions.
- Rewrite summary, skills lines and experience bullets to mirror the JD's language and required keywords,
  quantifying impact where the original implies it.
- You MAY add closely *adjacent* skills (tools/tech very close to what the candidate demonstrably uses) when the JD
  requires them. List EVERY skill you add that is not evidenced in the original resume in "added_skills" so the
  candidate can review it. Do not add unrelated skills, certifications, degrees or employers.
- Keep length roughly the same (±15%). Keep bullets concise. Keep each paragraph's existing "Label:" prefix if it has one.
- Edit by paragraph index. Use "inserts" to add a new bullet after an existing bullet (it copies that bullet's style).

JOB: {title} @ {company}
{jd}

SCORER SUGGESTIONS
{suggestions}

RESUME PARAGRAPHS (idx: text)
{paragraphs}

Return ONLY JSON:
{{"edits": [{{"idx": int, "new_text": str}}], "inserts": [{{"after_idx": int, "text": str}}],
  "added_skills": [{{"skill": str, "why": "which JD requirement + which resume evidence makes it adjacent"}}],
  "changes_summary": [str]}}"""


def _pass(doc_bytes: bytes, job: dict, rep: dict, target: int) -> tuple[bytes, dict]:
    paras = docs.numbered_paragraphs(doc_bytes)
    listing = "\n".join(f"{p['idx']}: {p['text']}" for p in paras)
    plan = llm.ask_json(PROMPT.format(
        target=target, current=rep.get("ats_score"), title=job["title"], company=job["company"],
        jd=job["description"][:10000],
        suggestions=json.dumps({k: rep.get(k) for k in ("keyword_match", "gaps", "suggestions")}, ensure_ascii=False),
        paragraphs=listing[:25000]), system=SYSTEM, temperature=0.4)
    return docs.apply_edits(doc_bytes, plan.get("edits", []), plan.get("inserts", [])), plan


def run(run: db.PipelineRun, job: dict, profile: dict, report: dict, target: int) -> dict:
    with run.agent("tailor", job["job_id"], f"Tailoring resume (target {target}%)") as task:
        if not profile.get("resume_docx"):
            raise RuntimeError("Tailoring needs a .docx parent resume – upload one in Settings")
        parent = db.download(profile["resume_docx"], db.PARENT_BUCKET)

        current, rep, added, changes = parent, report, [], []
        passes = 0
        for passes in range(1, MAX_PASSES + 1):
            current, plan = _pass(current, job, rep, target)
            added += [a for a in plan.get("added_skills", []) if isinstance(a, dict)]
            changes += plan.get("changes_summary", [])
            rep = scorer.score(job, docs.docx_text(current))
            if int(rep.get("ats_score") or 0) >= target:
                break

        stem = Path(profile["resume_filename"]).stem
        prefix = db.job_dir(job)
        files = dict(job.get("files") or {})
        files["resume_docx"] = db.upload(f"{prefix}/{stem}.docx", current, docs.DOCX_MIME)
        try:
            pdf = docs.docx_to_pdf(current, stem)
        except Exception:
            pdf = None
        if pdf:
            files["resume_pdf"] = db.upload(f"{prefix}/{stem}.pdf", pdf, docs.PDF_MIME)

        # dedupe added skills by name
        seen, unique_added = set(), []
        for a in added:
            key = str(a.get("skill", "")).lower()
            if key and key not in seen:
                seen.add(key)
                unique_added.append(a)

        tailored = {**rep, "passes": passes, "changes_summary": changes, "added_skills": unique_added}
        db.upload(f"{prefix}/tailored_report.json", json.dumps(tailored, indent=2, ensure_ascii=False).encode(), "application/json")
        md = scorer.report_markdown(job, report, tailored)
        if unique_added:
            md += "\n## ⚠️ Adjacent skills added — review before applying\n" + "\n".join(
                f"- **{a['skill']}** — {a.get('why', '')}" for a in unique_added) + "\n"
        if changes:
            md += "\n## Changes made\n" + "\n".join(f"- {c}" for c in changes) + "\n"
        db.upload(f"{prefix}/Suggestions Report.md", md.encode(), "text/markdown")
        files["tailored_report"] = f"{prefix}/tailored_report.json"

        values = {"tailored_ats_score": int(rep.get("ats_score") or 0), "added_skills": unique_added,
                  "files": files, "status": "tailored"}
        db.update_job(job["job_id"], values)
        job.update(values)
        task.message = (f"Tailored in {passes} pass(es): ATS {job['ats_score']}% → {values['tailored_ats_score']}%"
                        + (f", {len(unique_added)} adjacent skill(s) to review" if unique_added else ""))
        return tailored
