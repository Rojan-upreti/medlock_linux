from __future__ import annotations

import json
import time
from pathlib import Path
from typing import AsyncIterator

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
from sqlalchemy.orm import Session

from app.db import ApiKey, Attachment, Conversation, Message, get_db, get_session, utcnow
from app.services import llama
from app.services.audit import log_event
from app.services.embeddings import embed_texts
from app.services.files import image_data_url, vision_enabled
from app.services.letters import FORMAT_SYSTEM, classify_letter, letter_system_prompt
from app.services.rag import build_rag_prefix, retrieve
from app.services.redact import hash_api_key
from app.settings import get_settings

router = APIRouter(prefix="/v1", tags=["openai"])


def _extract_bearer(authorization: str | None) -> str | None:
    if not authorization:
        return None
    if authorization.lower().startswith("bearer "):
        return authorization[7:].strip()
    return authorization.strip()


def resolve_api_key(
    db: Session,
    authorization: str | None,
    x_api_key: str | None,
    required: bool,
) -> ApiKey | None:
    raw = x_api_key or _extract_bearer(authorization)
    settings = get_settings()
    if not raw:
        if required:
            raise HTTPException(status_code=401, detail="API key required")
        return None
    # Accept the llama.cpp / admin local key for first-party UI.
    if raw in {settings.LLAMA_API_KEY, settings.MEDLOCK_ADMIN_TOKEN} and raw:
        return None
    digest = hash_api_key(raw)
    row = db.query(ApiKey).filter(ApiKey.key_hash == digest, ApiKey.revoked.is_(False)).first()
    if not row:
        raise HTTPException(status_code=401, detail="Invalid API key")
    row.last_used_at = utcnow()
    db.commit()
    return row


@router.post("/embeddings")
async def embeddings_endpoint(
    request: Request,
    db: Session = Depends(get_db),
    authorization: str | None = Header(default=None),
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
):
    resolve_api_key(db, authorization, x_api_key, required=False)
    payload = await request.json()
    raw = payload.get("input", payload.get("texts", []))
    if isinstance(raw, str):
        texts = [raw]
    elif isinstance(raw, list):
        texts = [str(x) for x in raw]
    else:
        raise HTTPException(400, "input must be a string or array of strings")
    vectors = embed_texts(texts)
    return {
        "object": "list",
        "data": [{"object": "embedding", "index": i, "embedding": v} for i, v in enumerate(vectors)],
        "model": get_settings().EMBEDDING_MODEL_NAME,
        "usage": {"prompt_tokens": 0, "total_tokens": 0},
    }


@router.get("/models")
async def list_models(
    request: Request,
    db: Session = Depends(get_db),
    authorization: str | None = Header(default=None),
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
):
    resolve_api_key(db, authorization, x_api_key, required=False)
    data = await llama.llama_models()
    return data


@router.post("/chat/completions")
async def chat_completions(
    request: Request,
    db: Session = Depends(get_db),
    authorization: str | None = Header(default=None),
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
):
    settings = get_settings()
    if not settings.cloud_llm_blocked():
        raise HTTPException(status_code=403, detail="Cloud LLM inference is disabled by policy")
    key_row = resolve_api_key(db, authorization, x_api_key, required=False)
    payload = await request.json()
    stream = bool(payload.get("stream"))
    messages = list(payload.get("messages") or [])
    use_rag = bool(payload.pop("rag", True))
    conversation_id = payload.pop("conversation_id", None)
    attachment_ids = [str(x) for x in (payload.pop("attachment_ids", None) or []) if x]
    user_text = ""
    for m in reversed(messages):
        if m.get("role") == "user":
            user_text = str(m.get("content") or "")
            break
    chat = [m for m in messages if m.get("role") != "system"]
    attachments: list[Attachment] = []
    if attachment_ids:
        attachments = db.query(Attachment).filter(Attachment.id.in_(attachment_ids)).all()
    if attachments and not conversation_id:
        conversation_id = attachments[0].conversation_id
    if conversation_id:
        attachments = [a for a in attachments if a.conversation_id == conversation_id]
    file_notes: list[str] = []
    image_urls: list[str] = []
    extract_blob = ""
    for att in attachments:
        text_bit = (att.extracted_text or "").strip()
        if text_bit:
            extract_blob += f"\n\n----- {att.filename} -----\n{text_bit[:8000]}"
            file_notes.append(f"{att.filename} ({att.kind}, text extracted)")
        elif att.kind == "image":
            file_notes.append(f"{att.filename} (image attached)")
            if vision_enabled():
                url = image_data_url(Path(att.source_path), att.mime_type)
                if url:
                    image_urls.append(url)
        else:
            file_notes.append(f"{att.filename} ({att.kind}, no extractable text)")

    if not user_text and attachments:
        user_text = "Please review the attached file(s) and summarize them."
        if chat and chat[-1].get("role") == "user" and not str(chat[-1].get("content") or "").strip():
            chat[-1]["content"] = user_text
        elif not chat or chat[-1].get("role") != "user":
            chat.append({"role": "user", "content": user_text})

    if extract_blob and chat:
        for i in range(len(chat) - 1, -1, -1):
            if chat[i].get("role") == "user":
                body = str(chat[i].get("content") or "")
                chat[i]["content"] = (
                    body
                    + "\n\nThe user attached local file(s). Work from this extracted text.\n"
                    + extract_blob
                )
                break

    if image_urls and chat:
        for i in range(len(chat) - 1, -1, -1):
            if chat[i].get("role") == "user":
                text_part = str(chat[i].get("content") or user_text)
                chat[i]["content"] = [{"type": "text", "text": text_part}] + [
                    {"type": "image_url", "image_url": {"url": u}} for u in image_urls
                ]
                break

    rag_hits = []
    sys_msgs = [{"role": "system", "content": FORMAT_SYSTEM}]
    letter_kind = classify_letter(user_text)
    if letter_kind:
        sys_msgs.append({"role": "system", "content": letter_system_prompt(letter_kind)})
    rag_query = user_text
    if extract_blob:
        rag_query = f"{user_text}\n{extract_blob[:1500]}"
    if use_rag and rag_query:
        rag_hits = retrieve(db, rag_query, top_k=4)
        prefix = build_rag_prefix(rag_hits)
        if prefix:
            sys_msgs.append({"role": "system", "content": prefix})
    if file_notes:
        sys_msgs.append(
            {
                "role": "system",
                "content": "Attached this turn: " + "; ".join(file_notes) + ".",
            }
        )
    messages = sys_msgs + chat
    payload["messages"] = messages
    payload.setdefault("model", settings.SERVED_MODEL_NAME)

    conv = None
    if conversation_id:
        conv = db.get(Conversation, conversation_id)
    if conv is None:
        title = (user_text or "New chat")[:80]
        conv = Conversation(title=title, model=settings.SERVED_MODEL_NAME, demo=settings.MEDLOCK_DEMO)
        db.add(conv)
        db.commit()
        db.refresh(conv)
    if user_text:
        stored = user_text
        if attachments:
            stored = user_text + "\n\n" + "\n".join(f"Attached: {a.filename}" for a in attachments)
        db.add(Message(conversation_id=conv.id, role="user", content=stored, model=settings.SERVED_MODEL_NAME, rag_used=bool(rag_hits)))
        db.commit()

    t0 = time.perf_counter()
    if stream:
        upstream = await llama.chat_completions(payload, stream=True)

        conv_id = conv.id
        key_id = key_row.id if key_row else None
        path = str(request.url.path)
        client_host = request.client.host if request.client else None

        async def gen() -> AsyncIterator[bytes]:
            assistant = []
            try:
                async for chunk in upstream.aiter_bytes():
                    assistant.append(chunk)
                    yield chunk
            finally:
                http_client = upstream.extensions.get("medlock_client")
                await upstream.aclose()
                if http_client is not None:
                    await http_client.aclose()
                text = b"".join(assistant).decode("utf-8", errors="replace")
                content = _extract_stream_text(text)
                latency = int((time.perf_counter() - t0) * 1000)
                session = get_session()
                try:
                    session.add(
                        Message(
                            conversation_id=conv_id,
                            role="assistant",
                            content=content,
                            latency_ms=latency,
                            model=settings.SERVED_MODEL_NAME,
                            rag_used=bool(rag_hits),
                        )
                    )
                    session.commit()
                    log_event(
                        session,
                        event_type="chat.completions",
                        path=path,
                        method="POST",
                        client_host=client_host,
                        api_key_id=key_id,
                        model=settings.SERVED_MODEL_NAME,
                        request_in={"stream": True, "rag_hits": len(rag_hits)},
                        request_out={"streamed_chars": len(content)},
                        status_code=200,
                        latency_ms=latency,
                    )
                except Exception:
                    session.rollback()
                finally:
                    session.close()

        return StreamingResponse(gen(), media_type="text/event-stream")

    resp = await llama.chat_completions(payload, stream=False)
    latency = int((time.perf_counter() - t0) * 1000)
    try:
        body = resp.json()
    except Exception:
        body = {"error": resp.text}
    content = ""
    try:
        content = body["choices"][0]["message"]["content"]
    except Exception:
        content = json.dumps(body)[:4000]
    usage = body.get("usage") or {}
    db.add(
        Message(
            conversation_id=conv.id,
            role="assistant",
            content=content,
            token_in=usage.get("prompt_tokens"),
            token_out=usage.get("completion_tokens"),
            latency_ms=latency,
            model=settings.SERVED_MODEL_NAME,
            rag_used=bool(rag_hits),
        )
    )
    db.commit()
    log_event(
        db,
        event_type="chat.completions",
        path=str(request.url.path),
        method="POST",
        client_host=request.client.host if request.client else None,
        api_key_id=key_row.id if key_row else None,
        model=settings.SERVED_MODEL_NAME,
        request_in={"rag_hits": len(rag_hits), "stream": False},
        request_out={"id": body.get("id"), "usage": usage},
        status_code=resp.status_code,
        latency_ms=latency,
    )
    if isinstance(body, dict):
        body["conversation_id"] = conv.id
        body["rag"] = rag_hits
    return JSONResponse(body, status_code=resp.status_code)


def _extract_stream_text(raw: str) -> str:
    parts: list[str] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            continue
        try:
            obj = json.loads(data)
            delta = ((obj.get("choices") or [{}])[0].get("delta") or {}).get("content")
            if delta:
                parts.append(delta)
        except Exception:
            continue
    return "".join(parts)
