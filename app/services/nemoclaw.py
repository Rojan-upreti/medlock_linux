from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from typing import Any

from app.settings import get_settings


def _which_status(name: str) -> dict[str, Any]:
    path = shutil.which(name)
    return {"installed": path is not None, "path": path}


def stack_status() -> dict[str, Any]:
    settings = get_settings()
    cfg = settings.yaml_config().get("nemoclaw") or {}
    out = {
        "openclaw": _which_status("openclaw"),
        "nemoclaw": _which_status("nemoclaw"),
        "openshell": _which_status("openshell"),
        "config_enabled": bool(cfg.get("enabled")),
        "sandbox_name": cfg.get("sandbox_name") or "medlock-assistant",
        "provider": cfg.get("provider") or "llama-cpp",
        "llama_port": settings.LLAMA_PORT,
        "note": "NemoClaw is optional. MedLock chat works without it.",
    }
    if out["nemoclaw"]["installed"]:
        try:
            proc = subprocess.run(
                ["nemoclaw", "status"],
                capture_output=True,
                text=True,
                timeout=8,
                check=False,
            )
            out["nemoclaw_status_exit"] = proc.returncode
            out["nemoclaw_status_preview"] = (proc.stdout or proc.stderr or "")[:1500]
        except Exception as exc:
            out["nemoclaw_status_error"] = str(exc)
    marker = settings.PROJECT_DIR / "backups" / "nemoclaw-installer.sh"
    out["installer_saved"] = marker.is_file()
    return out
