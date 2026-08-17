from __future__ import annotations

from sqlalchemy.orm import Session

from app.db import AuditEvent
from app.services.redact import redact, truncate_text


def log_event(
    db: Session,
    *,
    event_type: str,
    path: str | None = None,
    method: str | None = None,
    client_host: str | None = None,
    api_key_id: str | None = None,
    model: str | None = None,
    request_in: dict | None = None,
    request_out: dict | None = None,
    status_code: int | None = None,
    latency_ms: int | None = None,
    error: str | None = None,
) -> None:
    payload_in = redact(request_in) if request_in is not None else None
    payload_out = redact(request_out) if request_out is not None else None
    if isinstance(payload_in, dict) and "messages" in payload_in:
        msgs = []
        for m in payload_in.get("messages") or []:
            if isinstance(m, dict):
                msgs.append({**m, "content": truncate_text(str(m.get("content") or ""), 2000)})
            else:
                msgs.append(m)
        payload_in = {**payload_in, "messages": msgs}
    event = AuditEvent(
        event_type=event_type,
        path=path,
        method=method,
        client_host=client_host,
        api_key_id=api_key_id,
        model=model,
        request_in=payload_in,
        request_out=payload_out,
        status_code=status_code,
        latency_ms=latency_ms,
        error=error,
    )
    db.add(event)
    db.commit()
