"""Local extraction for chat attachments (PDF, images, text). No cloud APIs."""

from __future__ import annotations

import base64
import logging
import re
import shutil
import subprocess
import uuid
from pathlib import Path

from app.settings import get_settings

log = logging.getLogger("medlock.files")

MAX_BYTES = 12 * 1024 * 1024
MAX_PDF_PAGES = 40
MAX_EXTRACT_CHARS = 24000

ALLOWED = {
    ".pdf": "pdf",
    ".png": "image",
    ".jpg": "image",
    ".jpeg": "image",
    ".webp": "image",
    ".gif": "image",
    ".txt": "text",
    ".md": "text",
}


def vision_enabled() -> bool:
    settings = get_settings()
    path = (settings.MMPROJ_PATH or "").strip()
    return bool(path and Path(path).expanduser().is_file())


def uploads_root() -> Path:
    root = get_settings().data_dir() / "data" / "uploads"
    root.mkdir(parents=True, exist_ok=True)
    return root


def kind_for(filename: str, mime: str | None = None) -> str | None:
    ext = Path(filename or "").suffix.lower()
    if ext in ALLOWED:
        return ALLOWED[ext]
    mime = (mime or "").lower()
    if mime == "application/pdf":
        return "pdf"
    if mime.startswith("image/"):
        return "image"
    if mime.startswith("text/"):
        return "text"
    return None


def safe_name(name: str) -> str:
    base = Path(name or "upload").name
    base = re.sub(r"[^A-Za-z0-9._-]+", "_", base).strip("._") or "upload"
    return base[:180]


def save_bytes(filename: str, data: bytes) -> Path:
    folder = uploads_root() / str(uuid.uuid4())
    folder.mkdir(parents=True, exist_ok=True)
    dest = folder / safe_name(filename)
    dest.write_bytes(data)
    return dest


def extract_text(path: Path, kind: str) -> str:
    if kind == "text":
        return path.read_text(encoding="utf-8", errors="replace")[:MAX_EXTRACT_CHARS]
    if kind == "pdf":
        return _pdf_text(path)
    if kind == "image":
        return _image_text(path)
    return ""


def _pdf_text(path: Path) -> str:
    try:
        from pypdf import PdfReader
    except Exception as exc:
        log.warning("pypdf unavailable: %s", exc)
        return ""
    try:
        reader = PdfReader(str(path))
        parts: list[str] = []
        for i, page in enumerate(reader.pages[:MAX_PDF_PAGES]):
            text = (page.extract_text() or "").strip()
            if text:
                parts.append(f"--- page {i + 1} ---\n{text}")
        return "\n\n".join(parts)[:MAX_EXTRACT_CHARS]
    except Exception as exc:
        log.warning("pdf extract failed for %s: %s", path.name, exc)
        return ""


def _image_text(path: Path) -> str:
    if not shutil.which("tesseract"):
        return ""
    try:
        proc = subprocess.run(
            ["tesseract", str(path), "stdout", "--psm", "6"],
            capture_output=True,
            timeout=45,
            check=False,
        )
        return (proc.stdout or b"").decode("utf-8", errors="replace").strip()[:MAX_EXTRACT_CHARS]
    except Exception as exc:
        log.warning("tesseract failed for %s: %s", path.name, exc)
        return ""


def image_data_url(path: Path, mime: str | None = None) -> str | None:
    try:
        from PIL import Image
    except Exception:
        raw = path.read_bytes()
        if len(raw) > 1_500_000:
            return None
        b64 = base64.b64encode(raw).decode("ascii")
        mt = mime or "image/jpeg"
        return f"data:{mt};base64,{b64}"
    img = Image.open(path)
    img = img.convert("RGB")
    img.thumbnail((1280, 1280))
    import io

    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=82)
    b64 = base64.b64encode(buf.getvalue()).decode("ascii")
    return f"data:image/jpeg;base64,{b64}"
