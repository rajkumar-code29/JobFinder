"""Upload someone's resume / cover letter from the command line.

  python -m jobfinder.upload_parent --email you@example.com --resume ~/Documents/Me_Resume.docx ~/Documents/Me_Resume.pdf --cover ~/Documents/Cover\\ Letter.docx
"""
import argparse
import mimetypes
from pathlib import Path

from . import db


def put(user_id: str, folder: str, paths: list[str]) -> None:
    prefix = f"{user_id}/{folder}"
    for old in db.list_files(prefix, db.PARENT_BUCKET):
        db.sb.storage.from_(db.PARENT_BUCKET).remove([f"{prefix}/{old['name']}"])
    for p in paths:
        path = Path(p).expanduser()
        mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        db.upload(f"{prefix}/{path.name}", path.read_bytes(), mime, bucket=db.PARENT_BUCKET)
        print(f"uploaded parent/{prefix}/{path.name}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--email", required=True, help="the app user these documents belong to")
    ap.add_argument("--resume", nargs="*", default=[])
    ap.add_argument("--cover", nargs="*", default=[])
    a = ap.parse_args()
    user = next((u for u in db.sb.auth.admin.list_users() if (u.email or "").lower() == a.email.lower()), None)
    if not user:
        raise SystemExit(f"No app user with email {a.email}")
    if a.resume:
        put(user.id, "resume", a.resume)
    if a.cover:
        put(user.id, "cover_letter", a.cover)
