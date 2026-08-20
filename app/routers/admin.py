from __future__ import annotations

import os
import secrets
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Depends, File, HTTPException, Query, Request, UploadFile
from pydantic import BaseModel, Field
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.db import ApiKey, AuditEvent, Conversation, Message, User, get_db, list_tables, table_preview
from app.services import hardware, llama, nemoclaw
from app.services.auth import create_user, hash_password, owner_count, public_user, require_admin, validate_password
from app.services.rag import ingest_directory, ingest_file
from app.services.redact import hash_api_key, redact
from app.settings import get_settings

router = APIRouter(prefix="/api/admin", tags=["admin"])


def _client_host(request: Request) -> str:
    host = (request.client.host if request.client else "") or ""
    if host.startswith("::ffff:"):
        host = host[7:]
    return host


class KeyCreate(BaseModel):
    name: str = Field(min_length=1, max_length=128)


class ChatUserCreate(BaseModel):
    username: str = Field(min_length=2, max_length=64)
    password: str = Field(min_length=8, max_length=256)


class PasswordReset(BaseModel):
    password: str = Field(min_length=8, max_length=256)


class AgentPrompt(BaseModel):
    prompt: str = Field(min_length=1, max_length=8000)
    conversation_id: str | None = None


class HfDownload(BaseModel):
    repo_id: str
    filename: str
    confirm: bool = False


@router.get("/overview")
async def overview(_: Any = Depends(require_admin), db: Session = Depends(get_db)):
    settings = get_settings()
    gpu = hardware.probe()
    models = hardware.model_status()
    llama_h = await llama.llama_health()
    llama_models = await llama.llama_models()
    msg_count = db.query(func.count(Message.id)).scalar() or 0
    conv_count = db.query(func.count(Conversation.id)).scalar() or 0
    audit_count = db.query(func.count(AuditEvent.id)).scalar() or 0
    avg_latency = db.query(func.avg(Message.latency_ms)).filter(Message.role == "assistant").scalar()
    cfg = settings.yaml_config()
    return {
        "product": "MedLock",
        "cloud_llm_blocked": settings.cloud_llm_blocked(),
        "inference": cfg.get("inference"),
        "embeddings": cfg.get("embeddings"),
        "network": cfg.get("network"),
        "safety": cfg.get("safety"),
        "gpu": gpu,
        "models": models,
        "llama": llama_h,
        "served_models": llama_models,
        "stats": {
            "conversations": conv_count,
            "messages": msg_count,
            "audit_events": audit_count,
            "avg_latency_ms": int(avg_latency) if avg_latency else None,
        },
        "endpoints": {
            "chat": f"http://{settings.CHAT_HOSTNAME}:{settings.MEDLOCK_PORT}/",
            "admin": f"http://{settings.ADMIN_HOSTNAME}:{settings.MEDLOCK_PORT}/",
            "openai": f"http://127.0.0.1:{settings.MEDLOCK_PORT}/v1/chat/completions",
            "llama": f"http://127.0.0.1:{settings.LLAMA_PORT}/v1",
        },
        "demo": settings.MEDLOCK_DEMO,
        "servicenow_enabled": settings.SERVICENOW_ENABLED,
        "servicenow_configured": bool(settings.SERVICENOW_INSTANCE_URL and settings.SERVICENOW_CLIENT_ID),
        "paths": hardware.disk_paths(),
        "nemoclaw": nemoclaw.stack_status(),
    }


@router.get("/config")
def read_config(_: Any = Depends(require_admin)):
    settings = get_settings()
    cfg = settings.yaml_config()
    # Never allow UI to see secrets from .env
    return {"config": cfg, "cloud_llm_blocked": settings.cloud_llm_blocked()}


@router.get("/stats")
def stats(_: Any = Depends(require_admin), db: Session = Depends(get_db)):
    recent = (
        db.query(AuditEvent)
        .order_by(AuditEvent.created_at.desc())
        .limit(25)
        .all()
    )
    by_type = db.query(AuditEvent.event_type, func.count(AuditEvent.id)).group_by(AuditEvent.event_type).all()
    ids = [e.user_id for e in recent if e.user_id]
    names = {u.id: u.username for u in db.query(User).filter(User.id.in_(ids)).all()} if ids else {}
    return {
        "by_type": {k: v for k, v in by_type},
        "recent": [
            {
                "id": e.id,
                "created_at": e.created_at.isoformat() if e.created_at else None,
                "event_type": e.event_type,
                "path": e.path,
                "status_code": e.status_code,
                "latency_ms": e.latency_ms,
                "model": e.model,
                "error": e.error,
                "user_id": e.user_id,
                "username": (
                    names.get(e.user_id)
                    or ((e.request_in or {}).get("username") if isinstance(e.request_in, dict) else None)
                ),
            }
            for e in recent
        ],
    }


@router.get("/tables")
def tables(_: Any = Depends(require_admin), db: Session = Depends(get_db)):
    return {"tables": list_tables(db)}


@router.get("/tables/{table}")
def table_rows(
    table: str,
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    _: Any = Depends(require_admin),
    db: Session = Depends(get_db),
):
    try:
        data = table_preview(db, table, limit=limit, offset=offset)
    except ValueError as exc:
        raise HTTPException(404, str(exc)) from exc
    data["rows"] = [redact(r) for r in data["rows"]]
    return data


@router.post("/keys")
def create_key(body: KeyCreate, _: Any = Depends(require_admin), db: Session = Depends(get_db)):
    raw = "mlk_" + secrets.token_urlsafe(32)
    row = ApiKey(name=body.name, key_prefix=raw[:10], key_hash=hash_api_key(raw))
    db.add(row)
    db.commit()
    db.refresh(row)
    return {
        "id": row.id,
        "name": row.name,
        "key_prefix": row.key_prefix,
        "key": raw,
        "warning": "Copy this key now. It will not be shown again.",
    }


@router.get("/keys")
def list_keys(_: Any = Depends(require_admin), db: Session = Depends(get_db)):
    rows = db.query(ApiKey).order_by(ApiKey.created_at.desc()).all()
    return [
        {
            "id": r.id,
            "name": r.name,
            "key_prefix": r.key_prefix,
            "created_at": r.created_at.isoformat() if r.created_at else None,
            "last_used_at": r.last_used_at.isoformat() if r.last_used_at else None,
            "revoked": r.revoked,
        }
        for r in rows
    ]


@router.post("/keys/{kid}/revoke")
def revoke_key(kid: str, _: Any = Depends(require_admin), db: Session = Depends(get_db)):
    row = db.get(ApiKey, kid)
    if not row:
        raise HTTPException(404, "key not found")
    row.revoked = True
    db.commit()
    return {"ok": True}


@router.get("/logs")
def tail_logs(name: str = "llama-server.log", lines: int = 200, _: Any = Depends(require_admin)):
    settings = get_settings()
    allowed = {
        "llama-server.log",
        "app.log",
        "systemd.out.log",
        "systemd.err.log",
        "nemoclaw.log",
        "openshell-gateway.log",
    }
    if name not in allowed:
        raise HTTPException(400, "unknown log file")
    path = settings.data_dir() / "logs" / name
    if not path.is_file():
        return {"name": name, "lines": [], "missing": True}
    text = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return {"name": name, "lines": text[-lines:], "missing": False}


@router.post("/models/upload")
async def upload_gguf(
    file: UploadFile = File(...),
    _: Any = Depends(require_admin),
):
    settings = get_settings()
    if not file.filename or not file.filename.lower().endswith(".gguf"):
        raise HTTPException(400, "Only .gguf files are accepted")
    dest_dir = settings.PROJECT_DIR / "llm" / "uploads"
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / Path(file.filename).name
    size = 0
    with dest.open("wb") as fh:
        while True:
            chunk = await file.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            fh.write(chunk)
    with dest.open("rb") as fh:
        magic = fh.read(4)
    if magic != b"GGUF":
        dest.unlink(missing_ok=True)
        raise HTTPException(400, "File is not a GGUF (bad magic)")
    env_path = settings.PROJECT_DIR / ".env"
    _upsert_env(env_path, "MODEL_PATH", str(dest))
    return {"ok": True, "path": str(dest), "size_bytes": size, "note": "Restart ./run.sh to load this model"}


@router.post("/models/huggingface")
def download_hf(body: HfDownload, _: Any = Depends(require_admin)):
    if not body.confirm:
        raise HTTPException(400, "Set confirm=true after reviewing license and size")
    settings = get_settings()
    dest = settings.PROJECT_DIR / "llm" / "hf" / body.repo_id.replace("/", "__")
    dest.mkdir(parents=True, exist_ok=True)
    try:
        from huggingface_hub import hf_hub_download
    except ImportError as exc:
        raise HTTPException(500, "huggingface_hub is not installed") from exc
    path = hf_hub_download(repo_id=body.repo_id, filename=body.filename, local_dir=str(dest))
    _upsert_env(settings.PROJECT_DIR / ".env", "MODEL_PATH", path)
    return {"ok": True, "path": path, "note": "Restart ./run.sh to load this model"}


@router.get("/models/huggingface/search")
def search_hf(q: str = Query(..., min_length=2), _: Any = Depends(require_admin)):
    try:
        from huggingface_hub import HfApi
    except ImportError as exc:
        raise HTTPException(500, "huggingface_hub is not installed") from exc
    api = HfApi()
    models = api.list_models(search=q, filter="gguf", limit=15)
    return {
        "results": [
            {"id": m.id, "downloads": getattr(m, "downloads", None), "tags": list(getattr(m, "tags", []) or [])[:12]}
            for m in models
        ]
    }


@router.post("/documents/ingest")
async def ingest(
    file: UploadFile | None = File(default=None),
    _: Any = Depends(require_admin),
    db: Session = Depends(get_db),
):
    settings = get_settings()
    if file and file.filename:
        dest = settings.data_dir() / "data" / "documents" / Path(file.filename).name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(await file.read())
        doc = ingest_file(db, dest, demo=False)
        return {"ok": True, "document_id": doc.id, "filename": doc.filename}
    n = ingest_directory(db, settings.data_dir() / "data" / "documents", demo=False)
    return {"ok": True, "ingested": n}


@router.get("/nemoclaw")
def nemoclaw_status(_: Any = Depends(require_admin)):
    return nemoclaw.stack_status()


@router.post("/nemoclaw/onboard")
def nemoclaw_onboard(user: User = Depends(require_admin), db: Session = Depends(get_db)):
    result = nemoclaw.onboard()
    nemoclaw.audit_cli(
        db,
        event_type="nemoclaw.onboard",
        user=user,
        path="/api/admin/nemoclaw/onboard",
        status_code=200 if result.get("ok") else 500,
        request_in={"via": "admin"},
        request_out={"ok": result.get("ok"), "exit_code": result.get("exit_code")},
        error=None if result.get("ok") else str(result.get("error") or result.get("output") or "")[:500],
    )
    return result


@router.post("/nemoclaw/start")
def nemoclaw_start(user: User = Depends(require_admin), db: Session = Depends(get_db)):
    result = nemoclaw.start_sandbox()
    nemoclaw.audit_cli(
        db,
        event_type="nemoclaw.start",
        user=user,
        path="/api/admin/nemoclaw/start",
        status_code=200 if result.get("ok") else 503,
        request_in={"cmd": result.get("cmd")},
        error=None if result.get("ok") else result.get("error"),
    )
    return result


@router.post("/nemoclaw/stop")
def nemoclaw_stop(user: User = Depends(require_admin), db: Session = Depends(get_db)):
    result = nemoclaw.stop_sandbox()
    nemoclaw.audit_cli(
        db,
        event_type="nemoclaw.stop",
        user=user,
        path="/api/admin/nemoclaw/stop",
        status_code=200 if result.get("ok") else 503,
        request_in={"cmd": result.get("cmd")},
        error=None if result.get("ok") else result.get("error"),
    )
    return result


@router.get("/nemoclaw/logs")
def nemoclaw_logs(lines: int = 200, _: User = Depends(require_admin)):
    return nemoclaw.tail_logs(lines)


@router.post("/nemoclaw/prompt")
async def nemoclaw_prompt(body: AgentPrompt, user: User = Depends(require_admin), db: Session = Depends(get_db)):
    result = await nemoclaw.prompt_agent(body.prompt)
    if result.get("ok") and body.conversation_id:
        conv = db.get(Conversation, body.conversation_id)
        if conv and conv.user_id == user.id:
            settings = get_settings()
            db.add(
                Message(
                    conversation_id=conv.id,
                    role="user",
                    content=body.prompt,
                    model=settings.SERVED_MODEL_NAME,
                )
            )
            db.add(
                Message(
                    conversation_id=conv.id,
                    role="assistant",
                    content=str(result.get("text") or ""),
                    model=settings.SERVED_MODEL_NAME,
                    rag_used=False,
                )
            )
            db.commit()
    nemoclaw.audit_cli(
        db,
        event_type="nemoclaw.prompt",
        user=user,
        path="/api/admin/nemoclaw/prompt",
        status_code=200 if result.get("ok") else 500,
        request_in={"prompt": body.prompt, "via": result.get("via"), "conversation_id": body.conversation_id},
        request_out={"ok": result.get("ok")},
        error=None if result.get("ok") else str(result.get("error") or "")[:500],
    )
    return result


@router.get("/users")
def list_users(_: User = Depends(require_admin), db: Session = Depends(get_db)):
    rows = db.query(User).order_by(User.created_at.asc()).all()
    return {"users": [public_user(u) for u in rows]}


@router.post("/users")
def add_chat_user(body: ChatUserCreate, _: User = Depends(require_admin), db: Session = Depends(get_db)):
    try:
        user = create_user(db, body.username, body.password, "chat")
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return public_user(user)


@router.post("/users/{uid}/disable")
def disable_user(uid: str, _: User = Depends(require_admin), db: Session = Depends(get_db)):
    user = db.get(User, uid)
    if not user:
        raise HTTPException(404, "User not found")
    if user.role == "owner" and owner_count(db) <= 1:
        raise HTTPException(400, "Cannot disable the last owner")
    user.disabled = True
    db.commit()
    return public_user(user)


@router.post("/users/{uid}/enable")
def enable_user(uid: str, _: User = Depends(require_admin), db: Session = Depends(get_db)):
    user = db.get(User, uid)
    if not user:
        raise HTTPException(404, "User not found")
    user.disabled = False
    db.commit()
    return public_user(user)


@router.post("/users/{uid}/password")
def reset_user_password(uid: str, body: PasswordReset, _: User = Depends(require_admin), db: Session = Depends(get_db)):
    user = db.get(User, uid)
    if not user:
        raise HTTPException(404, "User not found")
    try:
        validate_password(body.password)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    user.password_hash = hash_password(body.password)
    db.commit()
    return {"ok": True, "id": user.id}


def _upsert_env(path: Path, key: str, value: str) -> None:
    if not path.exists():
        path.write_text(f"{key}={value}\n", encoding="utf-8")
        os.chmod(path, 0o600)
        return
    lines = path.read_text(encoding="utf-8").splitlines()
    found = False
    out = []
    for line in lines:
        if line.startswith(f"{key}="):
            out.append(f"{key}={value}")
            found = True
        else:
            out.append(line)
    if not found:
        out.append(f"{key}={value}")
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)
