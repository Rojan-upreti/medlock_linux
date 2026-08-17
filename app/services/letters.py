"""Local clinical correspondence: classify letter type and render a printable PDF."""

from __future__ import annotations

import io
import re
from datetime import date
from pathlib import Path

LETTER_KINDS = {
    "referral": "Referral letter",
    "discharge": "Discharge letter",
    "admission": "Admission record",
    "clinic": "Clinic letter",
    "admin": "Administrative letter",
    "letter": "Clinical letter",
}

_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("referral", re.compile(r"\breferral\b|\brefer\s+(the\s+)?patient\b|\brefer to\b", re.I)),
    ("discharge", re.compile(r"\bdischarge\s+(letter|summary|note|report)\b|\bdischarged\b", re.I)),
    ("admission", re.compile(r"\badmission\s+(letter|record|note|report)\b|\badmit(?:ting)?\s+(letter|note)\b", re.I)),
    ("clinic", re.compile(r"\bclinic\s+letter\b|\boutpatient\s+letter\b|\boutcome\s+letter\b", re.I)),
    ("admin", re.compile(r"\badmin(?:istrative)?\s+(letter|note|work)\b|\bsick\s+note\b|\bfit\s+note\b|\bcorrespondence\b", re.I)),
    ("letter", re.compile(r"\b(?:draft|write|compose)\b.{0,40}\bletter\b|\bletter\s+to\b", re.I)),
]

_LETTER_SHAPE = re.compile(
    r"\bdear\b.+\b(yours\s+(sincerely|faithfully)|kind\s+regards|respectfully)\b",
    re.I | re.S,
)


def classify_letter(user_text: str, assistant_text: str = "") -> str | None:
    blob = f"{user_text or ''}\n{assistant_text or ''}"
    for kind, pat in _PATTERNS:
        if pat.search(user_text or "") or pat.search(blob):
            return kind
    if _LETTER_SHAPE.search(assistant_text or ""):
        return "letter"
    return None


def letter_title(kind: str | None) -> str:
    return LETTER_KINDS.get(kind or "", "Clinical letter")


def to_plain_letter(text: str) -> str:
    s = (text or "").replace("\r\n", "\n").strip()
    s = re.sub(r"```[\s\S]*?```", lambda m: m.group(0).strip("`"), s)
    s = re.sub(r"^#{1,6}\s*", "", s, flags=re.M)
    s = re.sub(r"\*\*(.+?)\*\*", r"\1", s)
    s = re.sub(r"\*(.+?)\*", r"\1", s)
    s = re.sub(r"`([^`]+)`", r"\1", s)
    s = re.sub(r"^\s*[-*]\s+", "• ", s, flags=re.M)
    return s.strip()


def _font_file() -> Path | None:
    for path in (
        Path("/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf"),
        Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
        Path("/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf"),
        Path("/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"),
    ):
        if path.is_file():
            return path
    return None


def render_letter_pdf(*, kind: str, content: str, title: str | None = None) -> bytes:
    try:
        from fpdf import FPDF
    except ImportError as exc:
        raise RuntimeError("PDF support is not installed (fpdf2)") from exc

    heading = title or letter_title(kind)
    body = to_plain_letter(content)
    if not body:
        raise ValueError("Letter is empty")
    if len(body) > 80000:
        body = body[:80000].rstrip() + "\n\n[truncated]"

    font_path = _font_file()

    class LetterPDF(FPDF):
        def header(self) -> None:
            self.set_font(self._face, "B", 13)
            self.set_text_color(31, 74, 64)
            self.cell(0, 7, "MEDLOCK", new_x="LMARGIN", new_y="NEXT")
            self.set_font(self._face, "", 9)
            self.set_text_color(90, 90, 88)
            self.cell(0, 5, heading.upper() + "  ·  local draft — review before sending", new_x="LMARGIN", new_y="NEXT")
            self.set_draw_color(31, 74, 64)
            self.set_line_width(0.4)
            self.line(self.l_margin, self.get_y() + 2, self.w - self.r_margin, self.get_y() + 2)
            self.ln(8)
            self.set_text_color(27, 30, 28)

        def footer(self) -> None:
            self.set_y(-16)
            self.set_font(self._face, "", 8)
            self.set_text_color(110, 110, 108)
            self.cell(
                0,
                8,
                f"Generated on this machine {date.today().isoformat()}  ·  Page {self.page_no()}/{{nb}}  ·  Not official letterhead",
                align="C",
            )

    pdf = LetterPDF(format="A4")
    pdf._face = "LetterFace"
    pdf.alias_nb_pages()
    pdf.set_auto_page_break(auto=True, margin=22)
    pdf.set_margins(22, 22, 22)
    if font_path:
        pdf.add_font("LetterFace", "", str(font_path))
        bold = font_path.with_name(font_path.stem.replace("Regular", "Bold") + font_path.suffix)
        if "DejaVuSerif" in font_path.name:
            bold = font_path.with_name("DejaVuSerif-Bold.ttf")
        elif "DejaVuSans" in font_path.name:
            bold = font_path.with_name("DejaVuSans-Bold.ttf")
        elif "LiberationSerif" in font_path.name:
            bold = font_path.with_name("LiberationSerif-Bold.ttf")
        elif "LiberationSans" in font_path.name:
            bold = font_path.with_name("LiberationSans-Bold.ttf")
        if bold.is_file():
            pdf.add_font("LetterFace", "B", str(bold))
        else:
            pdf.add_font("LetterFace", "B", str(font_path))
    else:
        pdf._face = "Helvetica"
    pdf.add_page()
    pdf.set_font(pdf._face, "", 11)
    pdf.set_text_color(27, 30, 28)
    if font_path is None:
        body = body.encode("latin-1", "replace").decode("latin-1")
    pdf.multi_cell(0, 6.2, body)
    out = io.BytesIO()
    pdf.output(out)
    return out.getvalue()


def filename_for(kind: str | None) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", (kind or "letter").lower()).strip("-") or "letter"
    return f"{slug}-{date.today().isoformat()}.pdf"
