from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import secrets
import time
from typing import Any

from fastapi import Depends, HTTPException, Request, Response
from sqlalchemy.orm import Session

from app.db import User, get_db
from app.settings import get_settings

COOKIE = "medlock_session"
SESSION_DAYS = 14
MIN_PASSWORD = 8
USERNAME_RE = re.compile(r"^[A-Za-z0-9._-]{2,64}$")
ITERATIONS = 210_000


def normalize_username(raw: str) -> str:
    return (raw or "").strip()


def validate_username(raw: str) -> str:
    name = normalize_username(raw)
    if not USERNAME_RE.match(name):
        raise ValueError("Username must be 2–64 letters, numbers, dot, dash, or underscore.")
    return name


def validate_password(raw: str) -> str:
    if not raw or len(raw) < MIN_PASSWORD:
        raise ValueError(f"Password must be at least {MIN_PASSWORD} characters.")
    return raw


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, ITERATIONS)
    return f"pbkdf2$sha256${ITERATIONS}${salt.hex()}${digest.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        kind, algo, iters, salt_hex, digest_hex = stored.split("$")
        if kind != "pbkdf2" or algo != "sha256":
            return False
        digest = hashlib.pbkdf2_hmac(
            "sha256",
            password.encode("utf-8"),
            bytes.fromhex(salt_hex),
            int(iters),
        )
        return hmac.compare_digest(digest.hex(), digest_hex)
    except Exception:
        return False


def _secret() -> bytes:
    raw = (get_settings().MEDLOCK_SESSION_SECRET or "").strip()
    if not raw or raw == "change-me":
        raise HTTPException(500, "MEDLOCK_SESSION_SECRET is not configured")
    return raw.encode("utf-8")


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _unb64(text: str) -> bytes:
    pad = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + pad)


def issue_session(user: User) -> str:
    payload = {
        "uid": user.id,
        "u": user.username,
        "r": user.role,
        "exp": int(time.time()) + SESSION_DAYS * 86400,
    }
    raw = _b64(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    sig = _b64(hmac.new(_secret(), raw.encode("ascii"), hashlib.sha256).digest())
    return f"{raw}.{sig}"


def read_session(token: str | None) -> dict[str, Any] | None:
    if not token or "." not in token:
        return None
    raw, sig = token.rsplit(".", 1)
    expect = _b64(hmac.new(_secret(), raw.encode("ascii"), hashlib.sha256).digest())
    if not hmac.compare_digest(expect, sig):
        return None
    try:
        payload = json.loads(_unb64(raw))
    except Exception:
        return None
    if int(payload.get("exp") or 0) < int(time.time()):
        return None
    return payload


def set_session_cookie(response: Response, user: User) -> None:
    response.set_cookie(
        COOKIE,
        issue_session(user),
        httponly=True,
        samesite="lax",
        max_age=SESSION_DAYS * 86400,
        path="/",
    )


def clear_session_cookie(response: Response) -> None:
    response.delete_cookie(COOKIE, path="/")


def user_from_request(request: Request, db: Session) -> User | None:
    try:
        payload = read_session(request.cookies.get(COOKIE))
    except HTTPException:
        return None
    if not payload:
        return None
    user = db.get(User, str(payload.get("uid") or ""))
    if not user or user.disabled:
        return None
    return user


def require_user(request: Request, db: Session = Depends(get_db)) -> User:
    user = user_from_request(request, db)
    if not user:
        raise HTTPException(status_code=401, detail="Login required")
    return user


def require_admin(user: User = Depends(require_user)) -> User:
    if user.role != "owner":
        raise HTTPException(status_code=403, detail="Admin access required")
    return user


def public_user(user: User) -> dict[str, Any]:
    return {
        "id": user.id,
        "username": user.username,
        "role": user.role,
        "disabled": user.disabled,
        "created_at": user.created_at.isoformat() if user.created_at else None,
    }


def owner_count(db: Session) -> int:
    return db.query(User).filter(User.role == "owner", User.disabled.is_(False)).count()


def create_user(db: Session, username: str, password: str, role: str) -> User:
    name = validate_username(username)
    validate_password(password)
    if role not in {"owner", "chat"}:
        raise ValueError("Role must be owner or chat.")
    if db.query(User).filter(User.username == name).first():
        raise ValueError("That username is already taken.")
    if role == "owner" and owner_count(db) > 0:
        raise ValueError("An owner account already exists.")
    user = User(username=name, password_hash=hash_password(password), role=role)
    db.add(user)
    db.commit()
    db.refresh(user)
    return user
