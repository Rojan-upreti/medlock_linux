from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.db import User, get_db
from app.services.auth import (
    create_user,
    public_user,
    require_user,
    set_session_cookie,
    clear_session_cookie,
    user_from_request,
    verify_password,
)
from app.services.audit import log_event

router = APIRouter(prefix="/api/auth", tags=["auth"])


class LoginBody(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=256)


class SetupBody(LoginBody):
    pass


def _client_host(request: Request) -> str | None:
    return request.client.host if request.client else None


@router.get("/status")
def auth_status(request: Request, db: Session = Depends(get_db)):
    needs_setup = db.query(User.id).first() is None
    user = user_from_request(request, db)
    return {
        "needs_setup": needs_setup,
        "authenticated": bool(user),
        "user": public_user(user) if user else None,
    }


@router.post("/setup")
def setup_owner(body: SetupBody, request: Request, db: Session = Depends(get_db)):
    if db.query(User.id).first() is not None:
        raise HTTPException(400, "An owner account already exists. Sign in instead.")
    try:
        user = create_user(db, body.username, body.password, "owner")
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    log_event(
        db,
        event_type="auth.setup",
        path="/api/auth/setup",
        method="POST",
        client_host=_client_host(request),
        user_id=user.id,
        request_in={"username": user.username},
        status_code=200,
    )
    resp = JSONResponse({"ok": True, "user": public_user(user)})
    set_session_cookie(resp, user)
    return resp


@router.post("/login")
def login(body: LoginBody, request: Request, db: Session = Depends(get_db)):
    name = (body.username or "").strip()
    user = db.query(User).filter(User.username == name).first()
    if not user or user.disabled or not verify_password(body.password, user.password_hash):
        log_event(
            db,
            event_type="auth.login_failed",
            path="/api/auth/login",
            method="POST",
            client_host=_client_host(request),
            request_in={"username": name},
            status_code=401,
        )
        raise HTTPException(401, "Invalid username or password")
    log_event(
        db,
        event_type="auth.login",
        path="/api/auth/login",
        method="POST",
        client_host=_client_host(request),
        user_id=user.id,
        request_in={"username": user.username},
        status_code=200,
    )
    resp = JSONResponse({"ok": True, "user": public_user(user)})
    set_session_cookie(resp, user)
    return resp


@router.post("/logout")
def logout(request: Request, db: Session = Depends(get_db)):
    user = user_from_request(request, db)
    if user:
        log_event(
            db,
            event_type="auth.logout",
            path="/api/auth/logout",
            method="POST",
            client_host=_client_host(request),
            user_id=user.id,
            request_in={"username": user.username},
            status_code=200,
        )
    resp = JSONResponse({"ok": True})
    clear_session_cookie(resp)
    return resp


@router.get("/me")
def me(user: User = Depends(require_user)):
    return public_user(user)
