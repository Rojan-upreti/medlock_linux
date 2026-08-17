from __future__ import annotations

import logging
from typing import Any

import httpx

from app.settings import get_settings

log = logging.getLogger("medlock.llama")


class LlamaError(RuntimeError):
    def __init__(self, message: str, status_code: int = 502):
        super().__init__(message)
        self.status_code = status_code


def _headers() -> dict[str, str]:
    settings = get_settings()
    key = settings.LLAMA_API_KEY
    h = {"Content-Type": "application/json"}
    if key:
        h["Authorization"] = f"Bearer {key}"
    return h


async def llama_health() -> dict[str, Any]:
    settings = get_settings()
    url = f"{settings.llama_base()}/health"
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            r = await client.get(url, headers=_headers())
            return {"ok": r.status_code < 500, "status_code": r.status_code, "url": url}
    except Exception as exc:
        return {"ok": False, "error": str(exc), "url": url}


async def llama_models() -> dict[str, Any]:
    settings = get_settings()
    url = f"{settings.llama_base()}/v1/models"
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            r = await client.get(url, headers=_headers())
            r.raise_for_status()
            return r.json()
    except Exception as exc:
        return {"object": "list", "data": [], "error": str(exc)}


async def chat_completions(payload: dict[str, Any], stream: bool = False) -> httpx.Response:
    settings = get_settings()
    url = f"{settings.llama_base()}/v1/chat/completions"
    body = dict(payload)
    body.setdefault("model", settings.SERVED_MODEL_NAME)
    timeout = httpx.Timeout(300.0, connect=10.0)
    client = httpx.AsyncClient(timeout=timeout)
    try:
        if stream:
            req = client.build_request("POST", url, headers=_headers(), json=body)
            resp = await client.send(req, stream=True)
            resp.extensions["medlock_client"] = client
            return resp
        resp = await client.post(url, headers=_headers(), json=body)
        await client.aclose()
        return resp
    except httpx.HTTPError as exc:
        await client.aclose()
        raise LlamaError(f"llama-server unreachable: {exc}") from exc


async def embeddings(texts: list[str]) -> list[list[float]] | None:
    """Try llama-server embeddings endpoint; return None if unsupported."""
    settings = get_settings()
    url = f"{settings.llama_base()}/v1/embeddings"
    body = {"model": settings.SERVED_MODEL_NAME, "input": texts}
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            r = await client.post(url, headers=_headers(), json=body)
            if r.status_code >= 400:
                return None
            data = r.json()
            items = sorted(data.get("data") or [], key=lambda x: x.get("index", 0))
            return [it["embedding"] for it in items]
    except Exception:
        return None
