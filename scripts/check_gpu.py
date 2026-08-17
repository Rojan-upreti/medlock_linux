#!/usr/bin/env python3
"""Probe NVIDIA GPU / CUDA / GB10 unified-memory characteristics.

Prints JSON to stdout. Exit 0 always unless --strict is set and no GPU is found.
On DGX Spark / Dell Pro Max GB10, nvidia-smi VRAM is misleading; prefer free -h.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


def _run(cmd: list[str], timeout: int = 15) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except FileNotFoundError:
        return 127, "", f"not found: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def _meminfo() -> dict[str, Any]:
    info: dict[str, Any] = {"mem_total_kb": None, "mem_available_kb": None}
    try:
        text = Path("/proc/meminfo").read_text(encoding="utf-8")
    except OSError:
        return info
    for line in text.splitlines():
        if line.startswith("MemTotal:"):
            info["mem_total_kb"] = int(line.split()[1])
        elif line.startswith("MemAvailable:"):
            info["mem_available_kb"] = int(line.split()[1])
    return info


def _disk_free(path: str) -> dict[str, Any]:
    usage = shutil.disk_usage(path)
    return {
        "path": path,
        "total_bytes": usage.total,
        "free_bytes": usage.free,
        "used_bytes": usage.used,
    }


def _detect_gb10(nvidia_smi: str, uname_m: str) -> bool:
    blob = nvidia_smi.lower()
    markers = ("gb10", "dgx spark", "nvidia spark", "grace blackwell")
    if any(m in blob for m in markers):
        return True
    # Dell Pro Max with GB10 is aarch64 + NVIDIA GPU + large unified RAM.
    mem = _meminfo()
    total_gb = (mem.get("mem_total_kb") or 0) / (1024 * 1024)
    if uname_m in {"aarch64", "arm64"} and total_gb >= 90 and "nvidia" in blob:
        return True
    return False


def _cuda_version_from_nvcc() -> str | None:
    code, out, _ = _run(["nvcc", "--version"])
    if code != 0:
        return None
    m = re.search(r"release\s+([0-9.]+)", out)
    return m.group(1) if m else out.splitlines()[-1] if out else None


def _cuda_version_from_smi(smi: str) -> str | None:
    m = re.search(r"CUDA Version:\s*([0-9.]+)", smi)
    return m.group(1) if m else None


def collect() -> dict[str, Any]:
    uname_m = platform.machine()
    code, smi_out, smi_err = _run(
        [
            "nvidia-smi",
            "--query-gpu=name,driver_version,memory.total,compute_cap",
            "--format=csv,noheader",
        ]
    )
    code_full, smi_full, _ = _run(["nvidia-smi"])
    nvidia_present = code == 0 or code_full == 0
    raw = smi_full or smi_out or smi_err
    is_gb10 = _detect_gb10(raw, uname_m) if nvidia_present else False

    gpus: list[dict[str, str]] = []
    if code == 0 and smi_out:
        for line in smi_out.splitlines():
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 2:
                gpus.append(
                    {
                        "name": parts[0],
                        "driver_version": parts[1],
                        "memory_total": parts[2] if len(parts) > 2 else "",
                        "compute_cap": parts[3] if len(parts) > 3 else "",
                    }
                )

    cuda_arch = None
    if is_gb10:
        cuda_arch = "121"
    elif gpus:
        cap = gpus[0].get("compute_cap") or ""
        m = re.match(r"(\d+)\.(\d+)", cap)
        if m:
            cuda_arch = f"{m.group(1)}{m.group(2)}"

    mem = _meminfo()
    result: dict[str, Any] = {
        "os": platform.platform(),
        "python": sys.version.split()[0],
        "arch": uname_m,
        "nvidia_smi_available": shutil.which("nvidia-smi") is not None,
        "nvidia_gpu_present": nvidia_present,
        "gpus": gpus,
        "cuda_version": _cuda_version_from_nvcc() or _cuda_version_from_smi(raw),
        "nvcc_available": shutil.which("nvcc") is not None,
        "is_gb10": is_gb10,
        "cuda_architectures": cuda_arch,
        "unified_memory_note": (
            "GB10 uses unified LPDDR5x. Do not size models from nvidia-smi VRAM; use MemAvailable."
            if is_gb10
            else None
        ),
        "memory": mem,
        "disk": _disk_free(os.environ.get("PROJECT_DIR", ".")),
        "cpu_count": os.cpu_count(),
        "docker_available": shutil.which("docker") is not None,
    }
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="MedLock GPU / CUDA probe")
    parser.add_argument("--strict", action="store_true", help="Exit 2 if no NVIDIA GPU")
    parser.add_argument("--pretty", action="store_true")
    args = parser.parse_args()
    data = collect()
    print(json.dumps(data, indent=2 if args.pretty else None))
    if args.strict and not data["nvidia_gpu_present"]:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
