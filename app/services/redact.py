from __future__ import annotations

import hashlib
import logging
import re
from typing import Any

log = logging.getLogger("medlock")

SECRET_KEYS = re.compile(
    r"(api[_-]?key|token|password|secret|authorization|bearer|client_secret)",
    re.I,
)


def hash_api_key(raw: str) -> str:
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def redact(value: Any) -> Any:
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            if SECRET_KEYS.search(str(k)):
                out[k] = "***REDACTED***"
            else:
                out[k] = redact(v)
        return out
    if isinstance(value, list):
        return [redact(v) for v in value]
    if isinstance(value, str) and len(value) > 24 and SECRET_KEYS.search(value):
        return "***REDACTED***"
    return value


def truncate_text(text: str, limit: int = 4000) -> str:
    if text is None:
        return ""
    if len(text) <= limit:
        return text
    return text[:limit] + f"… <truncated {len(text) - limit} chars>"
