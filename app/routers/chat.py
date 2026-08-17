from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, Response
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.db import Attachment, Conversation, Message, get_db
from app.services.files import MAX_BYTES, extract_text, kind_for, save_bytes, uploads_root, vision_enabled
from app.services.letters import classify_letter, filename_for, letter_title, render_letter_pdf
from app.services.rag import ingest_text
from app.settings import get_settings

router = APIRouter(prefix="/api", tags=["chat"])


class NewConversation(BaseModel):
    title: str | None = None


class LetterPdfRequest(BaseModel):
    content: str = Field(min_length=1, max_length=80000)
    kind: str | None = None
    title: str | None = None
    conversation_id: str | None = None


@router.get("/conversations")
def list_conversations(db: Session = Depends(get_db)):
    settings = get_settings()
    q = db.query(Conversation).order_by(Conversation.updated_at.desc())
    if settings.MEDLOCK_DEMO:
        q = q.filter(Conversation.demo.is_(True))
    rows = q.limit(200).all()
    return [
        {
            "id": r.id,
            "title": r.title,
            "model": r.model,
            "created_at": r.created_at.isoformat() if r.created_at else None,
            "updated_at": r.updated_at.isoformat() if r.updated_at else None,
        }
        for r in rows
    ]


@router.post("/conversations")
def create_conversation(body: NewConversation, db: Session = Depends(get_db)):
    settings = get_settings()
    row = Conversation(title=body.title or "New chat", model=settings.SERVED_MODEL_NAME, demo=settings.MEDLOCK_DEMO)
    db.add(row)
    db.commit()
    db.refresh(row)
    return {"id": row.id, "title": row.title}


@router.get("/conversations/{cid}")
def get_conversation(cid: str, db: Session = Depends(get_db)):
    row = db.get(Conversation, cid)
    if not row:
        raise HTTPException(404, "conversation not found")
    msgs = (
        db.query(Message)
        .filter(Message.conversation_id == cid)
        .order_by(Message.created_at.asc())
        .all()
    )
    return {
        "id": row.id,
        "title": row.title,
        "model": row.model,
        "messages": [
            {
                "id": m.id,
                "role": m.role,
                "content": m.content,
                "latency_ms": m.latency_ms,
                "rag_used": m.rag_used,
                "created_at": m.created_at.isoformat() if m.created_at else None,
            }
            for m in msgs
        ],
    }


@router.delete("/conversations/{cid}")
def delete_conversation(cid: str, db: Session = Depends(get_db)):
    row = db.get(Conversation, cid)
    if not row:
        raise HTTPException(404, "conversation not found")
    db.delete(row)
    db.commit()
    return {"ok": True}


def _ensure_conversation(db: Session, cid: str | None) -> Conversation:
    settings = get_settings()
    if cid:
        row = db.get(Conversation, cid)
        if row:
            return row
    row = Conversation(title="New chat", model=settings.SERVED_MODEL_NAME, demo=settings.MEDLOCK_DEMO)
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


def _attachment_payload(row: Attachment) -> dict:
    return {
        "id": row.id,
        "conversation_id": row.conversation_id,
        "filename": row.filename,
        "mime_type": row.mime_type,
        "kind": row.kind,
        "byte_size": row.byte_size,
        "extracted_chars": row.extracted_chars,
        "has_text": row.extracted_chars > 0,
        "preview_url": f"/api/attachments/{row.id}/file" if row.kind == "image" else None,
        "vision": vision_enabled() if row.kind == "image" else False,
    }


@router.post("/attachments")
async def upload_attachment(
    file: UploadFile = File(...),
    conversation_id: str | None = Form(default=None),
    db: Session = Depends(get_db),
):
    filename = file.filename or "upload"
    kind = kind_for(filename, file.content_type)
    if not kind:
        raise HTTPException(400, "Supported files: PDF, PNG, JPG, WEBP, GIF, TXT, MD")
    data = await file.read()
    cid = (conversation_id or "").strip() or None
    if not data:
        raise HTTPException(400, "Empty file")
    if len(data) > MAX_BYTES:
        raise HTTPException(400, "File is larger than 12 MB")
    conv = _ensure_conversation(db, cid)
    path = save_bytes(filename, data)
    text = extract_text(path, kind)
    doc_id = None
    if text.strip():
        header = f"Chat attachment `{path.name}`.\n\n"
        doc = ingest_text(
            db,
            header + text,
            filename=path.name,
            source_path=str(path),
            mime_type=file.content_type or kind,
            demo=get_settings().MEDLOCK_DEMO,
        )
        doc_id = doc.id
    row = Attachment(
        conversation_id=conv.id,
        filename=path.name,
        mime_type=file.content_type,
        kind=kind,
        byte_size=len(data),
        source_path=str(path),
        extracted_chars=len(text),
        extracted_text=text or None,
        document_id=doc_id,
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    payload = _attachment_payload(row)
    payload["note"] = (
        "Extracted text is available to the assistant."
        if text.strip()
        else (
            "Image stored locally. This GGUF has no vision projector, so describe the finding in text "
            "or install Tesseract for OCR."
            if kind == "image" and not vision_enabled()
            else "No extractable text (scanned PDF pages need OCR)."
        )
    )
    return payload


@router.get("/conversations/{cid}/attachments")
def list_attachments(cid: str, db: Session = Depends(get_db)):
    row = db.get(Conversation, cid)
    if not row:
        raise HTTPException(404, "conversation not found")
    rows = db.query(Attachment).filter(Attachment.conversation_id == cid).order_by(Attachment.created_at.asc()).all()
    return [_attachment_payload(r) for r in rows]


@router.get("/attachments/{aid}/file")
def download_attachment(aid: str, db: Session = Depends(get_db)):
    row = db.get(Attachment, aid)
    if not row:
        raise HTTPException(404, "attachment not found")
    path = Path(row.source_path).resolve()
    root = uploads_root().resolve()
    if root not in path.parents:
        raise HTTPException(404, "file missing")
    if not path.is_file():
        raise HTTPException(404, "file missing")
    return FileResponse(path, filename=row.filename, media_type=row.mime_type or "application/octet-stream")


@router.post("/letters/pdf")
def download_letter_pdf(body: LetterPdfRequest):
    kind = (body.kind or "").strip().lower() or classify_letter("", body.content) or "letter"
    title = (body.title or "").strip() or letter_title(kind)
    try:
        pdf = render_letter_pdf(kind=kind, content=body.content, title=title)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(500, str(exc)) from exc
    name = filename_for(kind)
    return Response(
        content=pdf,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{name}"'},
    )
