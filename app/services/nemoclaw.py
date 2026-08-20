from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

import yaml

from app.settings import get_settings
from app.services.audit import log_event
from app.services.redact import truncate_text

log = logging.getLogger("medlock.nemoclaw")

SANDBOX_DEFAULT = "medlock-assistant"
GATEWAY_NAME = "medlock"
GATEWAY_PORT = 17670
GATEWAY_HEALTH_PORT = 17671


def vendor_bin() -> Path:
    return _project() / "vendor" / "nemoclaw" / "bin"


def _path_with_vendor() -> str:
    bin_dir = vendor_bin()
    path = os.environ.get("PATH", "")
    extras = "/usr/sbin:/sbin"
    if bin_dir.is_dir():
        return f"{bin_dir}:{extras}:{path}"
    return f"{extras}:{path}" if extras not in path else path


def _is_shim(name: str) -> bool:
    local = vendor_bin() / name
    if not local.is_file():
        return False
    try:
        head = local.read_text(encoding="utf-8", errors="ignore")[:800]
    except OSError:
        return False
    return "MEDLOCK_NEMOCLAW_SHIM=1" in head


def _which_status(name: str) -> dict[str, Any]:
    local = vendor_bin() / name
    if local.is_file() and os.access(local, os.X_OK):
        return {"installed": True, "path": str(local)}
    path = shutil.which(name, path=_path_with_vendor())
    return {"installed": path is not None, "path": path}


def _project() -> Path:
    return get_settings().PROJECT_DIR


def _log_path() -> Path:
    settings = get_settings()
    path = settings.data_dir() / "logs" / "nemoclaw.log"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def _workspace_src() -> Path:
    return _project() / "agents" / "hospital-admin"


def sandbox_name() -> str:
    cfg = get_settings().yaml_config().get("nemoclaw") or {}
    return str(cfg.get("sandbox_name") or os.environ.get("NEMOCLAW_SANDBOX_NAME") or SANDBOX_DEFAULT)


def _run(cmd: list[str], timeout: int = 30, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    merged["PATH"] = _path_with_vendor()
    if env:
        merged.update(env)
        if "PATH" not in env:
            merged["PATH"] = _path_with_vendor()
    try:
        return subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            env=merged,
        )
    except FileNotFoundError:
        return subprocess.CompletedProcess(cmd, 127, stdout="", stderr=f"{cmd[0]}: not found")


def _cmd_preview(proc: subprocess.CompletedProcess[str]) -> str:
    return ((proc.stdout or "") + (proc.stderr or "")).strip()[:2000]


def _parse_lifecycle(text: str) -> str:
    blob = (text or "").lower()
    if any(w in blob for w in ("running", "active", "started", "up", "ready")):
        return "running"
    if any(w in blob for w in ("stopped", "exited", "inactive", "down", "deleted", "not found")):
        return "stopped"
    return "unknown"


def _port_open(host: str, port: int) -> bool:
    import socket

    try:
        with socket.create_connection((host, port), timeout=1.2):
            return True
    except OSError:
        return False


def _docker_ok() -> bool:
    proc = _run(["docker", "info"], timeout=8)
    return proc.returncode == 0


def _compute_driver() -> str:
    """Docker if the daemon works; otherwise the KVM VM driver. Never require a GPU."""
    if _docker_ok():
        return "docker"
    return "vm"


def _gateway_bin() -> Path:
    return vendor_bin() / "openshell-gateway"


def _gateway_pid_path() -> Path:
    return get_settings().data_dir() / "logs" / "openshell-gateway.pid"


def _gateway_log_path() -> Path:
    return get_settings().data_dir() / "logs" / "openshell-gateway.log"


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _register_gateway() -> None:
    endpoint = f"http://127.0.0.1:{GATEWAY_PORT}"
    add = _run(
        ["openshell", "gateway", "add", endpoint, "--local", "--name", GATEWAY_NAME],
        timeout=12,
    )
    if add.returncode != 0:
        _run(["openshell", "gateway", "select", GATEWAY_NAME], timeout=8)


def _ensure_gateway() -> dict[str, Any]:
    """Start the local OpenShell gateway. v0.0.85 has no `sandbox start`."""
    if _port_open("127.0.0.1", GATEWAY_PORT):
        _register_gateway()
        return {"ok": True, "running": True, "port": GATEWAY_PORT, "note": "already listening"}
    gw = _gateway_bin()
    if not (gw.is_file() and os.access(gw, os.X_OK)):
        return {"ok": False, "error": "openshell-gateway missing from vendor/nemoclaw/bin"}
    log_path = _gateway_log_path()
    pid_path = _gateway_pid_path()
    log_path.parent.mkdir(parents=True, exist_ok=True)
    driver = _compute_driver()
    vm_bin = vendor_bin() / "openshell-driver-vm"
    if driver == "vm" and not (vm_bin.is_file() and os.access(vm_bin, os.X_OK)):
        return {
            "ok": False,
            "error": "openshell-driver-vm missing from vendor/nemoclaw/bin (needed when Docker is absent)",
        }
    with log_path.open("a", encoding="utf-8") as fh:
        fh.write(f"\n--- gateway start {GATEWAY_PORT} driver={driver} ---\n")
        proc = subprocess.Popen(
            [
                str(gw),
                "--bind-address",
                "127.0.0.1",
                "--port",
                str(GATEWAY_PORT),
                "--health-port",
                str(GATEWAY_HEALTH_PORT),
                "--disable-tls",
                "--drivers",
                driver,
                "--enable-mtls-auth",
                "false",
            ],
            stdout=fh,
            stderr=fh,
            cwd=str(_project()),
            start_new_session=True,
            env={
                **os.environ,
                "PATH": _path_with_vendor(),
                "OPENSHELL_DRIVERS": driver,
            },
        )
    pid_path.write_text(str(proc.pid), encoding="utf-8")
    import time

    for _ in range(20):
        if _port_open("127.0.0.1", GATEWAY_PORT):
            _register_gateway()
            return {
                "ok": True,
                "running": True,
                "port": GATEWAY_PORT,
                "pid": proc.pid,
                "driver": driver,
            }
        if proc.poll() is not None:
            tail = log_path.read_text(encoding="utf-8", errors="replace")[-1500:]
            return {"ok": False, "error": "openshell-gateway exited", "output": tail}
        time.sleep(0.25)
    return {"ok": False, "error": f"openshell-gateway did not bind 127.0.0.1:{GATEWAY_PORT}"}


def _stop_gateway() -> dict[str, Any]:
    pid_path = _gateway_pid_path()
    stopped = False
    if pid_path.is_file():
        try:
            pid = int(pid_path.read_text(encoding="utf-8").strip())
        except ValueError:
            pid = 0
        if pid and _pid_alive(pid):
            os.kill(pid, 15)
            stopped = True
        pid_path.unlink(missing_ok=True)
    return {"ok": True, "stopped": stopped}


def enable_in_yaml(provider: str = "llama-cpp", enabled: bool = True) -> None:
    settings = get_settings()
    path = settings.PROJECT_DIR / "config" / "local.yaml"
    cfg: dict[str, Any] = {}
    if path.is_file():
        cfg = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    block = dict(cfg.get("nemoclaw") or {})
    block["enabled"] = enabled
    block["provider"] = provider
    block["sandbox_name"] = sandbox_name() if not block.get("sandbox_name") else block["sandbox_name"]
    cfg["nemoclaw"] = block
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(cfg, sort_keys=False), encoding="utf-8")


def seed_workspace() -> dict[str, Any]:
    src = _workspace_src()
    copied: list[str] = []
    if not src.is_dir():
        return {"ok": False, "error": f"missing {src}", "copied": copied}
    dests = [
        Path.home() / ".openclaw" / "workspace",
        Path.home() / ".openclaw" / f"workspace-{sandbox_name()}",
        get_settings().data_dir() / "agents" / "hospital-admin",
    ]
    for dest in dests:
        dest.mkdir(parents=True, exist_ok=True)
        for path in src.rglob("*"):
            if not path.is_file():
                continue
            rel = path.relative_to(src)
            target = dest / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(path.read_bytes())
            copied.append(str(target))
    return {"ok": True, "copied": copied[:40], "destinations": [str(d) for d in dests]}


def _agents_system_prompt() -> str:
    src = _workspace_src()
    parts: list[str] = []
    for name in ("IDENTITY.md", "SOUL.md", "AGENTS.md"):
        path = src / name
        if path.is_file():
            parts.append(path.read_text(encoding="utf-8"))
    return "\n\n".join(parts).strip() or (
        "You are a hospital operations assistant. Answer the request directly. "
        "Prefer placeholders over invented facts. Confirm before any write."
    )


def stack_status() -> dict[str, Any]:
    settings = get_settings()
    cfg = settings.yaml_config().get("nemoclaw") or {}
    inference = settings.yaml_config().get("inference") or {}
    marker = settings.data_dir() / "logs" / ".nemoclaw-onboarded"
    installer = settings.PROJECT_DIR / "vendor" / "nemoclaw" / "installer" / "nemoclaw.sh"
    vendor = vendor_bin()
    out: dict[str, Any] = {
        "openclaw": _which_status("openclaw"),
        "nemoclaw": _which_status("nemoclaw"),
        "openshell": _which_status("openshell"),
        "config_enabled": bool(cfg.get("enabled")),
        "onboarded": marker.is_file() or bool(cfg.get("enabled")),
        "sandbox_name": cfg.get("sandbox_name") or SANDBOX_DEFAULT,
        "provider": cfg.get("provider") or "llama-cpp",
        "lifecycle": "unknown",
        "inference": {
            "host": settings.LLAMA_HOST,
            "port": settings.LLAMA_PORT,
            "served_model_name": settings.SERVED_MODEL_NAME,
            "backend": inference.get("backend") or "llama.cpp",
            "mode": inference.get("mode") or "local",
            "allow_cloud_llm": False,
        },
        "installer_saved": installer.is_file() or (settings.PROJECT_DIR / "backups" / "nemoclaw-installer.sh").is_file(),
        "vendor_dir": str(vendor),
        "vendor_ready": (
            (vendor / "openshell").is_file()
            or (vendor / "nemoclaw").is_file()
            or (vendor / "openshell-driver-vm").is_file()
        ),
        "workspace_seeded": (_workspace_src() / "AGENTS.md").is_file(),
        "docker": _docker_ok(),
        "kvm": os.access("/dev/kvm", os.R_OK | os.W_OK),
        "vm_driver": (vendor / "openshell-driver-vm").is_file(),
        "gateway": {
            "running": _port_open("127.0.0.1", GATEWAY_PORT),
            "port": GATEWAY_PORT,
            "name": GATEWAY_NAME,
            "driver": _compute_driver(),
        },
        "note": "Agents use the same local llama-server as chat. Manage this stack here, not in NVIDIA’s UI.",
    }
    if not out["docker"]:
        out["note"] = (
            "OpenShell uses the local KVM VM driver (no GPU required). "
            "First sandbox create may download a community image. Chat still uses llama-server."
        )
    preview = ""
    if out["nemoclaw"]["installed"] and not _is_shim("nemoclaw"):
        try:
            proc = _run(["nemoclaw", "status"], timeout=8)
            preview = _cmd_preview(proc)
            out["nemoclaw_status_exit"] = proc.returncode
            out["nemoclaw_status_preview"] = preview[:1500]
            out["lifecycle"] = _parse_lifecycle(preview)
        except Exception as exc:
            out["nemoclaw_status_error"] = str(exc)
    if out["openshell"]["installed"]:
        try:
            proc = _run(["openshell", "sandbox", "get", sandbox_name()], timeout=8)
            blob = _cmd_preview(proc)
            out["openshell_get_preview"] = blob[:800]
            if proc.returncode == 0:
                out["lifecycle"] = _parse_lifecycle(blob) if _parse_lifecycle(blob) != "unknown" else "running"
            elif "no active gateway" in blob.lower():
                out["lifecycle"] = "stopped"
            else:
                listed = _run(["openshell", "sandbox", "list"], timeout=8)
                out["openshell_list_preview"] = _cmd_preview(listed)[:800]
                if sandbox_name().lower() in (_cmd_preview(listed) or "").lower():
                    out["lifecycle"] = "running"
        except Exception as exc:
            out["openshell_list_error"] = str(exc)
    return out


def tail_logs(lines: int = 200) -> dict[str, Any]:
    path = _log_path()
    if not path.is_file():
        return {"name": "nemoclaw.log", "lines": [], "missing": True}
    text = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return {"name": "nemoclaw.log", "lines": text[-lines:], "missing": False}


def onboard() -> dict[str, Any]:
    settings = get_settings()
    script = settings.PROJECT_DIR / "scripts" / "setup_nemoclaw.sh"
    if not script.is_file():
        return {"ok": False, "error": "setup_nemoclaw.sh missing"}
    env = {
        "MEDLOCK_SKIP_NEMOCLAW": "0",
        "MEDLOCK_YES": "1",
        "PROJECT_DIR": str(settings.PROJECT_DIR),
        "PATH": _path_with_vendor(),
        "LLAMA_API_KEY": settings.LLAMA_API_KEY or "",
        "NEMOCLAW_LLAMACPP_LOCAL_TOKEN": settings.NEMOCLAW_LLAMACPP_LOCAL_TOKEN or settings.LLAMA_API_KEY or "",
        "SERVED_MODEL_NAME": settings.SERVED_MODEL_NAME,
        "LLAMA_HOST": settings.LLAMA_HOST,
        "LLAMA_PORT": str(settings.LLAMA_PORT),
        "MEDLOCK_PORT": str(settings.MEDLOCK_PORT),
        "NEMOCLAW_SANDBOX_NAME": sandbox_name(),
    }
    log_file = _log_path()
    try:
        with log_file.open("a", encoding="utf-8") as fh:
            fh.write("\n--- onboard ---\n")
            proc = subprocess.run(
                ["bash", str(script)],
                capture_output=True,
                text=True,
                timeout=600,
                check=False,
                env={**os.environ, **env},
                cwd=str(settings.PROJECT_DIR),
            )
            fh.write(proc.stdout or "")
            fh.write(proc.stderr or "")
        seed = seed_workspace()
        if proc.returncode == 0:
            enable_in_yaml("llama-cpp", True)
            marker = settings.data_dir() / "logs" / ".nemoclaw-onboarded"
            marker.write_text("ok\n", encoding="utf-8")
        return {
            "ok": proc.returncode == 0,
            "exit_code": proc.returncode,
            "output": ((proc.stdout or "") + (proc.stderr or ""))[-4000:],
            "seed": seed,
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "Onboard timed out after 10 minutes. Check logs/nemoclaw.log"}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def _try_cmds(candidates: list[list[str]], timeout: int = 45) -> dict[str, Any]:
    last = {"ok": False, "error": "no matching CLI"}
    for cmd in candidates:
        if not shutil.which(cmd[0], path=_path_with_vendor()):
            continue
        try:
            proc = _run(cmd, timeout=timeout)
        except Exception as exc:
            last = {"ok": False, "error": str(exc), "cmd": cmd}
            continue
        last = {
            "ok": proc.returncode == 0,
            "cmd": cmd,
            "exit_code": proc.returncode,
            "output": _cmd_preview(proc),
        }
        if proc.returncode == 0:
            return last
    return last


def _already_exists(text: str) -> bool:
    return "already exists" in (text or "").lower()


def _sandbox_present(name: str) -> tuple[bool, str, list[str]]:
    get = _run(["openshell", "sandbox", "get", name], timeout=12)
    preview = _cmd_preview(get)
    if get.returncode == 0 or _already_exists(preview):
        return True, preview, ["openshell", "sandbox", "get", name]
    listed = _run(["openshell", "sandbox", "list"], timeout=8)
    list_preview = _cmd_preview(listed)
    if name.lower() in (list_preview or "").lower():
        return True, list_preview, ["openshell", "sandbox", "list"]
    return False, preview or list_preview, ["openshell", "sandbox", "get", name]


def start_sandbox() -> dict[str, Any]:
    name = sandbox_name()
    gw = _ensure_gateway()
    if not gw.get("ok"):
        result = gw
        log_path = _log_path()
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(f"\n--- start ---\n{json.dumps(result)}\n")
        return result
    present, preview, cmd = _sandbox_present(name)
    if present:
        result = {
            "ok": True,
            "cmd": cmd,
            "output": preview,
            "gateway": gw,
            "note": f"sandbox {name} already exists — use Ask the agent below",
        }
    else:
        # OpenShell 0.0.85: create launches the sandbox. There is no `sandbox start`.
        # Do not pass --gpu (CPU/KVM is enough). `-- true` returns after boot instead of hanging.
        created = _run(
            ["openshell", "sandbox", "create", "--name", name, "--no-tty", "--", "true"],
            timeout=600,
        )
        output = _cmd_preview(created)
        ok = created.returncode == 0 or _already_exists(output)
        result = {
            "ok": ok,
            "cmd": ["openshell", "sandbox", "create", "--name", name, "--no-tty"],
            "exit_code": created.returncode,
            "output": output,
            "gateway": gw,
        }
        if _already_exists(output):
            result["note"] = f"sandbox {name} already exists — use Ask the agent below"
        elif created.returncode != 0:
            result["error"] = output or "Sandbox create failed. Chat still works on llama-server."
    log_path = _log_path()
    with log_path.open("a", encoding="utf-8") as fh:
        fh.write(f"\n--- start ---\n{json.dumps(result)}\n")
    return result


def stop_sandbox() -> dict[str, Any]:
    name = sandbox_name()
    deleted = _run(["openshell", "sandbox", "delete", name], timeout=30)
    gw = _stop_gateway()
    result = {
        "ok": True,
        "cmd": ["openshell", "sandbox", "delete", name],
        "exit_code": deleted.returncode,
        "output": _cmd_preview(deleted),
        "gateway": gw,
    }
    log_path = _log_path()
    with log_path.open("a", encoding="utf-8") as fh:
        fh.write(f"\n--- stop ---\n{json.dumps(result)}\n")
    return result


def prompt_via_cli(text: str) -> dict[str, Any] | None:
    name = sandbox_name()
    candidates: list[list[str]] = []
    if not _is_shim("nemoclaw"):
        candidates.append(["nemoclaw", "prompt", text])
    if not _is_shim("openclaw"):
        candidates.extend(
            [
                ["openclaw", "agent", "--message", text],
                ["openclaw", "--message", text],
            ]
        )
    candidates.append(["openshell", "sandbox", "exec", name, "--", "openclaw", "agent", "--message", text])
    result = _try_cmds(candidates, timeout=180)
    if result.get("ok"):
        return {"via": "cli", "text": result.get("output") or "", "cmd": result.get("cmd")}
    return None


async def prompt_agent(text: str, history: list[dict[str, str]] | None = None) -> dict[str, Any]:
    """Send a hospital-admin prompt. Prefer the local CLI; else the same llama-server as chat."""
    message = (text or "").strip()
    if not message:
        return {"ok": False, "error": "Empty prompt"}
    cli = prompt_via_cli(message)
    if cli and cli.get("text"):
        return {"ok": True, **cli}
    from app.services.llama import CHAT_SYSTEM_PROMPT, LlamaError, chat_completions

    msgs: list[dict[str, str]] = [
        {
            "role": "system",
            "content": f"{CHAT_SYSTEM_PROMPT}\n\n{_agents_system_prompt()}",
        }
    ]
    for prior in history or []:
        role = prior.get("role")
        content = str(prior.get("content") or "").strip()
        if role in ("user", "assistant") and content:
            msgs.append({"role": role, "content": content})
    msgs.append({"role": "user", "content": message})
    payload = {
        "messages": msgs,
        "max_tokens": 512,
        "stream": False,
    }
    try:
        resp = await chat_completions(payload, stream=False)
        body = resp.json()
        content = (
            ((body.get("choices") or [{}])[0].get("message") or {}).get("content")
            or body.get("error")
            or resp.text
        )
        return {
            "ok": resp.status_code < 400,
            "via": "llama",
            "text": str(content),
            "status_code": resp.status_code,
            "note": "Answered by the same local llama-server as chat (NemoClaw CLI prompt unavailable).",
        }
    except LlamaError as exc:
        return {"ok": False, "error": str(exc)}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def audit_cli(
    db,
    *,
    event_type: str,
    user=None,
    request_in: dict[str, Any] | None = None,
    request_out: dict[str, Any] | None = None,
    status_code: int | None = None,
    error: str | None = None,
    model: str | None = None,
    path: str | None = None,
    method: str | None = None,
) -> None:
    payload = dict(request_in or {})
    if user is not None:
        payload.setdefault("username", getattr(user, "username", None))
        payload.setdefault("role", getattr(user, "role", None))
    if "prompt" in payload and isinstance(payload["prompt"], str):
        payload["prompt"] = truncate_text(payload["prompt"], 2000)
    if "text" in payload and isinstance(payload["text"], str):
        payload["text"] = truncate_text(payload["text"], 2000)
    log_event(
        db,
        event_type=event_type,
        path=path or "/api/admin/nemoclaw",
        method=method or "POST",
        user_id=getattr(user, "id", None),
        model=model or get_settings().SERVED_MODEL_NAME,
        request_in=payload,
        request_out=request_out,
        status_code=status_code,
        error=error,
    )
