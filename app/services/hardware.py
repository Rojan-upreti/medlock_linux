from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any

from app.settings import get_settings


def probe() -> dict[str, Any]:
    settings = get_settings()
    script = settings.PROJECT_DIR / "scripts" / "check_gpu.py"
    if script.is_file():
        try:
            proc = subprocess.run(
                ["python3", str(script)],
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
            )
            if proc.returncode == 0 and proc.stdout.strip():
                return json.loads(proc.stdout)
        except Exception as exc:
            return {"error": str(exc)}
    return {"error": "check_gpu.py unavailable"}


def model_status() -> dict[str, Any]:
    settings = get_settings()
    script = settings.PROJECT_DIR / "scripts" / "check_models.py"
    cmd = ["python3", str(script), "--model-path", settings.MODEL_PATH or ""]
    if settings.EMBEDDING_MODEL_PATH:
        cmd += ["--embedding-path", settings.EMBEDDING_MODEL_PATH]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=15, check=False)
        if proc.stdout.strip():
            data = json.loads(proc.stdout)
            data["exit_code"] = proc.returncode
            return data
        return {"ok": False, "error": proc.stderr.strip() or "no output"}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def disk_paths() -> dict[str, Any]:
    settings = get_settings()
    paths = {
        "logs": settings.data_dir() / "logs",
        "data": settings.data_dir() / "data",
        "documents": settings.data_dir() / "data" / "documents",
        "config": settings.PROJECT_DIR / "config",
    }
    out = {}
    for name, path in paths.items():
        out[name] = {
            "path": str(path),
            "exists": path.exists(),
            "writable": os_writable(path),
        }
    env = settings.PROJECT_DIR / ".env"
    mode = oct(env.stat().st_mode & 0o777) if env.exists() else None
    out["env"] = {"path": str(env), "exists": env.exists(), "mode": mode}
    return out


def os_writable(path: Path) -> bool:
    try:
        path.mkdir(parents=True, exist_ok=True)
        probe = path / ".write_probe"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
        return True
    except OSError:
        return False
