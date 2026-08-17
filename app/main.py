from __future__ import annotations

from contextlib import asynccontextmanager
from pathlib import Path
import logging

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.db import get_engine, get_session
from app.routers import admin, chat, health, openai_v1
from app.services.llama import LlamaError
from app.services.rag import maybe_bootstrap_demo
from app.settings import get_settings

log = logging.getLogger("medlock")

STATIC = Path(__file__).resolve().parent / "static"


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    if not settings.cloud_llm_blocked():
        raise RuntimeError("Refusing to start: config permits cloud LLM inference")
    get_engine()
    db = get_session()
    try:
        maybe_bootstrap_demo(db)
    except Exception:
        log.exception("demo RAG bootstrap failed")
    finally:
        db.close()
    yield


app = FastAPI(
    title="MedLock",
    description="Local-only enterprise inference control plane. Cloud LLM use is disabled.",
    version="1.0.0",
    lifespan=lifespan,
)

app.include_router(health.router)
app.include_router(openai_v1.router)
app.include_router(chat.router)
app.include_router(admin.router)

if STATIC.is_dir():
    app.mount("/static", StaticFiles(directory=str(STATIC)), name="static")


@app.exception_handler(LlamaError)
async def llama_error_handler(_request: Request, exc: LlamaError):
    return JSONResponse({"error": {"message": str(exc), "type": "llama_error"}}, status_code=exc.status_code)


@app.exception_handler(Exception)
async def unhandled_error(_request: Request, exc: Exception):
    if isinstance(exc, (HTTPException, StarletteHTTPException)):
        raise exc
    log.exception("unhandled error")
    return JSONResponse(
        {"error": {"message": str(exc) or "Internal Server Error", "type": type(exc).__name__}},
        status_code=500,
    )


def _wants_admin(request: Request) -> bool:
    settings = get_settings()
    host = (request.headers.get("host") or "").split(":")[0].lower()
    if host == settings.ADMIN_HOSTNAME.lower():
        return True
    path = request.url.path
    return path == "/admin" or path.startswith("/admin/")


@app.get("/")
async def root(request: Request):
    if _wants_admin(request):
        return FileResponse(STATIC / "admin.html")
    return FileResponse(STATIC / "chat.html")


@app.get("/admin")
async def admin_page():
    return FileResponse(STATIC / "admin.html")


@app.get("/chat")
async def chat_page():
    return FileResponse(STATIC / "chat.html")
