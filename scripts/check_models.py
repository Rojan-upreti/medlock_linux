#!/usr/bin/env python3
"""Validate local GGUF LLM and embedding artifacts.

Exit 0 if required files exist and look like GGUF (or a documented embedding dir).
Exit 1 on missing/invalid models. Prints JSON to stdout.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any

GGUF_MAGIC = b"GGUF"


def _gguf_info(path: Path) -> dict[str, Any]:
    info: dict[str, Any] = {
        "path": str(path),
        "exists": path.is_file(),
        "size_bytes": path.stat().st_size if path.is_file() else 0,
        "valid_magic": False,
        "error": None,
    }
    if not path.is_file():
        info["error"] = "file not found"
        return info
    if path.stat().st_size < 16:
        info["error"] = "file too small to be a GGUF"
        return info
    try:
        with path.open("rb") as fh:
            magic = fh.read(4)
        info["valid_magic"] = magic == GGUF_MAGIC
        if not info["valid_magic"]:
            info["error"] = f"bad magic {magic!r}, expected GGUF"
    except OSError as exc:
        info["error"] = str(exc)
    return info


def _embedding_info(path: Path) -> dict[str, Any]:
    info: dict[str, Any] = {
        "path": str(path) if path else "",
        "exists": False,
        "kind": None,
        "error": None,
    }
    if not path or str(path) in {"", "."}:
        info["error"] = "embedding path not set"
        return info
    if path.is_file() and path.suffix.lower() == ".gguf":
        g = _gguf_info(path)
        info.update({"exists": g["exists"], "kind": "gguf", "valid_magic": g["valid_magic"], "size_bytes": g["size_bytes"], "error": g["error"]})
        return info
    if path.is_dir():
        # sentence-transformers / fastembed cache or HF snapshot
        markers = list(path.rglob("config.json")) + list(path.rglob("*.onnx")) + list(path.glob("*.gguf"))
        info["exists"] = True
        info["kind"] = "directory"
        info["file_count"] = sum(1 for _ in path.rglob("*") if _.is_file())
        if not markers and info["file_count"] == 0:
            info["error"] = "embedding directory is empty"
        return info
    info["error"] = "embedding path does not exist"
    return info


def collect(model_path: str, embedding_path: str, mmproj_path: str | None) -> dict[str, Any]:
    llm = _gguf_info(Path(model_path).expanduser()) if model_path else {
        "path": "",
        "exists": False,
        "valid_magic": False,
        "error": "MODEL_PATH not set",
    }
    emb = _embedding_info(Path(embedding_path).expanduser()) if embedding_path else {
        "path": "",
        "exists": False,
        "error": "EMBEDDING_MODEL_PATH not set",
    }
    mmproj = None
    if mmproj_path:
        mmproj = _gguf_info(Path(mmproj_path).expanduser())
    ok = bool(llm.get("exists") and llm.get("valid_magic"))
    return {
        "ok": ok,
        "llm": llm,
        "embedding": emb,
        "mmproj": mmproj,
        "embedding_optional": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate MedLock model files")
    parser.add_argument("--model-path", default=os.environ.get("MODEL_PATH", ""))
    parser.add_argument("--embedding-path", default=os.environ.get("EMBEDDING_MODEL_PATH", ""))
    parser.add_argument("--mmproj-path", default=os.environ.get("MMPROJ_PATH", ""))
    parser.add_argument("--pretty", action="store_true")
    parser.add_argument("--require-embedding", action="store_true")
    args = parser.parse_args()
    data = collect(args.model_path, args.embedding_path, args.mmproj_path or None)
    print(json.dumps(data, indent=2 if args.pretty else None))
    if not data["ok"]:
        return 1
    if args.require_embedding and data["embedding"].get("error"):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
