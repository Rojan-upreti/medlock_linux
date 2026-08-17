from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.db import db_status, get_db
from app.services import hardware, llama
from app.settings import get_settings

router = APIRouter(tags=["health"])


@router.get("/health")
async def health(db: Session = Depends(get_db)):
    settings = get_settings()
    llama_h = await llama.llama_health()
    gpu = hardware.probe()
    paths = hardware.disk_paths()
    models = hardware.model_status()
    dbinfo = db_status()
    cloud_blocked = settings.cloud_llm_blocked()
    checks = {
        "cloud_llm_blocked": cloud_blocked,
        "llama_server": llama_h.get("ok", False),
        "database": dbinfo.get("ok", False),
        "model_file": bool(models.get("ok")),
        "logs_writable": paths.get("logs", {}).get("writable", False),
        "data_writable": paths.get("data", {}).get("writable", False),
    }
    ok = all(
        [
            cloud_blocked,
            paths.get("logs", {}).get("writable", False),
            paths.get("data", {}).get("writable", False),
        ]
    )
    status = "ok" if ok and llama_h.get("ok") else "degraded"
    return {
        "status": status,
        "ok": ok,
        "checks": checks,
        "llama": llama_h,
        "database": dbinfo,
        "gpu": {
            "nvidia_gpu_present": gpu.get("nvidia_gpu_present"),
            "is_gb10": gpu.get("is_gb10"),
            "cuda_version": gpu.get("cuda_version"),
            "arch": gpu.get("arch"),
        },
        "models": models,
        "paths": paths,
        "demo": settings.MEDLOCK_DEMO,
        "servicenow_enabled": settings.SERVICENOW_ENABLED,
        "bind": {"host": settings.MEDLOCK_HOST, "port": settings.MEDLOCK_PORT},
    }
