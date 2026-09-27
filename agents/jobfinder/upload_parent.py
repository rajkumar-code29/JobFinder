"""Upload your parent resume / cover letter from the command line (the app can do this too).

  python -m jobfinder.upload_parent --resume ~/Documents/Me_Resume.docx ~/Documents/Me_Resume.pdf --cover ~/Documents/Cover\\ Letter.docx
"""
import argparse
import mimetypes
from pathlib import Path

from . import db


def put(folder: str, paths: list[str]) -> None:
    for old in db.list_files(folder, db.PARENT_BUCKET):
        db.sb.storage.from_(db.PARENT_BUCKET).remove([f"{folder}/{old['name']}"])
    for p in paths:
        path = Path(p).expanduser()
        mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        db.upload(f"{folder}/{path.name}", path.read_bytes(), mime, bucket=db.PARENT_BUCKET)
        print(f"uploaded parent/{folder}/{path.name}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--resume", nargs="*", default=[])
    ap.add_argument("--cover", nargs="*", default=[])
    a = ap.parse_args()
    if a.resume:
        put("resume", a.resume)
    if a.cover:
        put("cover_letter", a.cover)
