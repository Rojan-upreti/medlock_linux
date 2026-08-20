#!/usr/bin/env python3
"""Host-side NemoClaw/OpenClaw shim when NVIDIA's npm CLI is not installed.

MEDLOCK_NEMOCLAW_SHIM=1
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


def _print(obj: object) -> int:
    if isinstance(obj, dict):
        print(json.dumps(obj, indent=2))
        return 0 if obj.get("ok", True) else 1
    print(str(obj))
    return 0


def cmd_onboard() -> int:
    from app.services.nemoclaw import enable_in_yaml, seed_workspace, _ensure_gateway
    from app.settings import get_settings

    enable_in_yaml("llama-cpp", True)
    seed = seed_workspace()
    gw = _ensure_gateway()
    marker = get_settings().data_dir() / "logs" / ".nemoclaw-onboarded"
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text("ok\n", encoding="utf-8")
    return _print({"ok": bool(gw.get("ok")), "seed": seed, "gateway": gw, "provider": "llama-cpp"})


def cmd_start() -> int:
    from app.services.nemoclaw import start_sandbox

    return _print(start_sandbox())


def cmd_stop() -> int:
    from app.services.nemoclaw import stop_sandbox

    return _print(stop_sandbox())


def cmd_status() -> int:
    from app.services.nemoclaw import stack_status

    st = stack_status()
    gw = st.get("gateway") or {}
    life = "running" if gw.get("running") else (st.get("lifecycle") or "stopped")
    print(
        f"OpenShell gateway {'running' if gw.get('running') else 'stopped'} "
        f"on 127.0.0.1:{gw.get('port')} driver={gw.get('driver')} lifecycle={life}"
    )
    print(json.dumps(st, indent=2)[:4000])
    return 0


async def _prompt_llama(message: str) -> dict:
    from app.services.llama import CHAT_SYSTEM_PROMPT, LlamaError, chat_completions
    from app.services.nemoclaw import _agents_system_prompt

    payload = {
        "messages": [
            {"role": "system", "content": f"{CHAT_SYSTEM_PROMPT}\n\n{_agents_system_prompt()}"},
            {"role": "user", "content": message},
        ],
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
        }
    except LlamaError as exc:
        return {"ok": False, "error": str(exc)}


def cmd_prompt(message: str) -> int:
    result = asyncio.run(_prompt_llama(message))
    text = result.get("text") or result.get("error") or ""
    print(text)
    return 0 if result.get("ok") else 1


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] in ("agent",):
        argv = argv[1:]
    parser = argparse.ArgumentParser(prog="nemoclaw")
    sub = parser.add_subparsers(dest="cmd")
    sub.add_parser("onboard")
    sub.add_parser("start")
    sub.add_parser("stop")
    sub.add_parser("status")
    p = sub.add_parser("prompt")
    p.add_argument("message", nargs=argparse.REMAINDER)
    a = sub.add_parser("agent")
    a.add_argument("--message", dest="message_flag")
    a.add_argument("message", nargs=argparse.REMAINDER)
    parser.add_argument("--message", dest="root_message")
    parser.add_argument("--non-interactive", action="store_true")
    parser.add_argument("--yes-i-accept-third-party-software", action="store_true")
    args, unknown = parser.parse_known_args(argv)

    cmd = args.cmd
    if not cmd:
        if args.root_message:
            return cmd_prompt(args.root_message)
        parser.print_help()
        return 2
    if cmd == "onboard":
        return cmd_onboard()
    if cmd == "start":
        return cmd_start()
    if cmd == "stop":
        return cmd_stop()
    if cmd == "status":
        return cmd_status()
    if cmd in ("prompt", "agent"):
        parts = list(getattr(args, "message", None) or [])
        msg = getattr(args, "message_flag", None) or args.root_message or " ".join(parts)
        if not msg.strip():
            print("usage: nemoclaw prompt <text>", file=sys.stderr)
            return 2
        return cmd_prompt(msg.strip())
    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
