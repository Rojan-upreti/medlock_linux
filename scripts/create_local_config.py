#!/usr/bin/env python3
"""Generate config/local.yaml from environment variables and safe defaults.

Does not overwrite an existing config unless --force is passed.
Cloud LLM inference is always forced off.
CPU-only machines get a smaller context and n_gpu_layers=0 even when yaml already exists.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
from pathlib import Path

import yaml

DEFAULTS = {
    "project": {
        "name": "MedLock",
        "bind_host": "127.0.0.1",
        "bind_port": 8000,
        "chat_hostname": "medlock.chat",
        "admin_hostname": "medlock.admin",
    },
    "inference": {
        "mode": "local",
        "allow_cloud_llm": False,
        "backend": "llama.cpp",
        "llama_host": "127.0.0.1",
        "llama_port": 8081,
        "served_model_name": "medlock-llm",
        "n_gpu_layers": 99,
        "context_length": 8192,
    },
    "embeddings": {
        "mode": "local",
        "allow_cloud": False,
        "model_name": "BAAI/bge-small-en-v1.5",
    },
    "rag": {
        "enabled": True,
        "top_k": 5,
        "chunk_size": 800,
        "chunk_overlap": 120,
        "documents_dir": "data/documents",
        "demo_data_dir": "data/demo_data",
    },
    "network": {
        "servicenow_enabled": False,
        "allow_outbound_except_servicenow": False,
    },
    "safety": {
        "require_human_confirmation_for_writes": True,
        "medical_disclaimer": True,
    },
    "logging": {
        "redact_secrets": True,
        "level": "INFO",
        "dir": "logs",
    },
    "nemoclaw": {
        "enabled": False,
        "sandbox_name": "medlock-assistant",
        "provider": "llama-cpp",
    },
}


def _as_bool(value: str | None, default: bool) -> bool:
    if value is None or value == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _as_int(value: str | None, default: int) -> int:
    if value is None or value == "":
        return default
    return int(value)


def has_nvidia_gpu() -> bool:
    if shutil.which("nvidia-smi") is None:
        return False
    try:
        proc = subprocess.run(
            ["nvidia-smi", "-L"],
            capture_output=True,
            timeout=5,
            check=False,
        )
        return proc.returncode == 0
    except Exception:
        return False


def apply_cpu_inference(cfg: dict) -> bool:
    """Shrink GPU defaults on CPU-only boxes. Returns True if cfg changed."""
    if has_nvidia_gpu():
        return False
    inf = cfg.setdefault("inference", {})
    changed = False
    if int(inf.get("n_gpu_layers") or 0) != 0:
        inf["n_gpu_layers"] = 0
        changed = True
    ctx = int(inf.get("context_length") or 2048)
    if ctx > 2048:
        inf["context_length"] = 2048
        changed = True
    return changed


def build_config(project_dir: Path) -> dict:
    cfg = yaml.safe_load(yaml.safe_dump(DEFAULTS))
    cfg["project"]["bind_host"] = os.environ.get("MEDLOCK_HOST", "127.0.0.1")
    cfg["project"]["bind_port"] = _as_int(os.environ.get("MEDLOCK_PORT"), 8000)
    cfg["project"]["chat_hostname"] = os.environ.get("CHAT_HOSTNAME", "medlock.chat")
    cfg["project"]["admin_hostname"] = os.environ.get("ADMIN_HOSTNAME", "medlock.admin")
    cfg["project"]["dir"] = str(project_dir)
    cfg["inference"]["mode"] = "local"
    cfg["inference"]["allow_cloud_llm"] = False
    cfg["inference"]["llama_host"] = os.environ.get("LLAMA_HOST", "127.0.0.1")
    cfg["inference"]["llama_port"] = _as_int(os.environ.get("LLAMA_PORT"), 8081)
    cfg["inference"]["served_model_name"] = os.environ.get("SERVED_MODEL_NAME", "medlock-llm")
    cfg["inference"]["model_path"] = os.environ.get("MODEL_PATH", "")
    cfg["inference"]["mmproj_path"] = os.environ.get("MMPROJ_PATH", "")
    cfg["inference"]["llama_server_bin"] = os.environ.get("LLAMA_SERVER_BIN", "")
    cfg["embeddings"]["mode"] = "local"
    cfg["embeddings"]["allow_cloud"] = False
    cfg["embeddings"]["model_name"] = os.environ.get("EMBEDDING_MODEL_NAME", "BAAI/bge-small-en-v1.5")
    cfg["embeddings"]["model_path"] = os.environ.get("EMBEDDING_MODEL_PATH", "")
    cfg["network"]["servicenow_enabled"] = _as_bool(os.environ.get("SERVICENOW_ENABLED"), False)
    cfg["logging"]["redact_secrets"] = True
    cfg["safety"]["require_human_confirmation_for_writes"] = True
    apply_cpu_inference(cfg)
    return cfg


def cloud_llm_blocked(cfg: dict) -> bool:
    inf = cfg.get("inference") or {}
    return inf.get("mode") == "local" and inf.get("allow_cloud_llm") is False


def _write(path: Path, cfg: dict) -> None:
    path.write_text(yaml.safe_dump(cfg, sort_keys=False), encoding="utf-8")
    os.chmod(path, 0o640)


def main() -> int:
    parser = argparse.ArgumentParser(description="Write MedLock local.yaml")
    parser.add_argument("--project-dir", default=os.environ.get("PROJECT_DIR", "."))
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--print", action="store_true", dest="do_print")
    args = parser.parse_args()
    project_dir = Path(args.project_dir).expanduser().resolve()
    out = project_dir / "config" / "local.yaml"
    out.parent.mkdir(parents=True, exist_ok=True)
    cfg = build_config(project_dir)
    if not cloud_llm_blocked(cfg):
        raise SystemExit("Refusing to write a config that allows cloud LLM inference")
    if out.exists() and not args.force:
        existing = yaml.safe_load(out.read_text(encoding="utf-8")) or {}
        if apply_cpu_inference(existing):
            _write(out, existing)
            print(f"Updated CPU inference defaults in {out}")
            cfg = existing
        else:
            print(f"Keeping existing {out}")
        if args.do_print:
            print(yaml.safe_dump(cfg, sort_keys=False))
        return 0
    _write(out, cfg)
    print(f"Wrote {out}")
    if args.do_print:
        print(yaml.safe_dump(cfg, sort_keys=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
