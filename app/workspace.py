"""Workspace name + chosen data folder so the install tree does not store chats."""

from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from app.settings import project_dir

SAFE = re.compile(r"[^A-Za-z0-9._-]+")
CONFIG_DIR = Path.home() / ".config" / "medlock"


def sanitize(name: str) -> str:
    cleaned = SAFE.sub("-", (name or "").strip())
    cleaned = cleaned.strip(".-") or "MedLock"
    return cleaned[:64]


def default_data_root() -> Path:
    env = (os.environ.get("MEDLOCK_DATA_ROOT") or "").strip()
    if env:
        return Path(env).expanduser().resolve()
    saved = CONFIG_DIR / "data-root"
    if saved.is_file():
        text = saved.read_text(encoding="utf-8").strip()
        if text:
            return Path(text).expanduser().resolve()
    return Path.home() / "MedLock"


def upsert_env(env_path: Path, mapping: dict[str, str]) -> None:
    path = Path(env_path)
    lines: list[str] = []
    seen: set[str] = set()
    if path.is_file():
        for line in path.read_text(encoding="utf-8").splitlines():
            stripped = line.lstrip()
            if stripped.startswith("#") or "=" not in line:
                lines.append(line)
                continue
            key = line.split("=", 1)[0].strip()
            if key in mapping:
                lines.append(f"{key}={mapping[key]}")
                seen.add(key)
                continue
            lines.append(line)
    for key, value in mapping.items():
        if key not in seen:
            lines.append(f"{key}={value}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:
        pass


def last_workspace() -> str:
    path = CONFIG_DIR / "last-workspace"
    if path.is_file():
        text = path.read_text(encoding="utf-8").strip()
        if text:
            return sanitize(text)
    return "MedLock"


def prepare(name: str, install: Path | None = None, parent: Path | None = None) -> Path:
    install = (install or project_dir()).resolve()
    label = sanitize(name)
    base = (parent or default_data_root()).expanduser().resolve()
    root = base / label
    (root / "data" / "uploads").mkdir(parents=True, exist_ok=True)
    (root / "data" / "documents").mkdir(parents=True, exist_ok=True)
    (root / "logs").mkdir(parents=True, exist_ok=True)
    base.mkdir(parents=True, exist_ok=True)
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    (CONFIG_DIR / "last-workspace").write_text(label + "\n", encoding="utf-8")
    (CONFIG_DIR / "data-root").write_text(str(base) + "\n", encoding="utf-8")
    meta = {
        "name": label,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "install": str(install),
        "data_root": str(base),
    }
    meta_path = root / "workspace.json"
    if not meta_path.is_file():
        meta_path.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    _install_shortcut(install)
    return root


def _install_shortcut(install: Path) -> None:
    template = install / "packaging" / "MedLock.desktop"
    if not template.is_file():
        return
    text = template.read_text(encoding="utf-8").replace("PROJECT_DIR_PLACEHOLDER", str(install))
    targets = [Path.home() / "Desktop"]
    for folder in targets:
        try:
            folder.mkdir(parents=True, exist_ok=True)
            dest = folder / "MedLock.desktop"
            dest.write_text(text, encoding="utf-8")
            dest.chmod(0o755)
        except OSError:
            continue


def ask_setup(default_name: str | None = None, default_root: Path | None = None) -> tuple[str, Path]:
    """Return (workspace name, parent folder where files are stored)."""
    name_preset = os.environ.get("MEDLOCK_WORKSPACE", "").strip()
    root_preset = os.environ.get("MEDLOCK_DATA_ROOT", "").strip()
    default_name = default_name or last_workspace()
    default_root = default_root or default_data_root()
    if name_preset and root_preset:
        return sanitize(name_preset), Path(root_preset).expanduser().resolve()
    if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
        try:
            got = _tk_setup(default_name, str(default_root))
            if got:
                return sanitize(got[0]), Path(got[1]).expanduser().resolve()
        except Exception:
            pass
        got = _dialog_setup(default_name, str(default_root))
        if got:
            return sanitize(got[0]), Path(got[1]).expanduser().resolve()
    if sys.stdin.isatty():
        try:
            typed = input(f"Workspace name [{default_name}]: ").strip()
            name = sanitize(typed or default_name)
            typed_dir = input(f"Store files in [{default_root}]: ").strip()
            parent = Path(typed_dir or str(default_root)).expanduser().resolve()
            return name, parent
        except EOFError:
            return sanitize(default_name), default_root
    return sanitize(name_preset or default_name), Path(root_preset or default_root).expanduser().resolve()


def ask_name(default: str | None = None) -> str:
    name, _parent = ask_setup(default_name=default)
    return name


def _tk_setup(default_name: str, default_root: str) -> tuple[str, str] | None:
    import tkinter as tk
    from tkinter import filedialog, ttk

    result: dict[str, str] = {}
    root = tk.Tk()
    root.title("MedLock")
    root.resizable(False, False)
    root.configure(bg="#efeae1")
    frame = ttk.Frame(root, padding=18)
    frame.grid()
    ttk.Label(frame, text="Workspace name").grid(column=0, row=0, columnspan=2, sticky="w")
    name_entry = ttk.Entry(frame, width=40)
    name_entry.insert(0, default_name)
    name_entry.grid(column=0, row=1, columnspan=2, pady=(6, 12), sticky="ew")
    name_entry.focus()
    name_entry.selection_range(0, tk.END)

    ttk.Label(frame, text="Store chats, uploads, and logs in").grid(column=0, row=2, columnspan=2, sticky="w")
    dir_entry = ttk.Entry(frame, width=32)
    dir_entry.insert(0, default_root)
    dir_entry.grid(column=0, row=3, pady=(6, 12), sticky="ew")

    def browse() -> None:
        chosen = filedialog.askdirectory(
            parent=root,
            title="Choose MedLock data folder",
            initialdir=dir_entry.get() or str(Path.home()),
        )
        if chosen:
            dir_entry.delete(0, tk.END)
            dir_entry.insert(0, chosen)

    ttk.Button(frame, text="Browse…", command=browse).grid(column=1, row=3, padx=(8, 0), pady=(6, 12))

    def ok(_event=None) -> None:
        result["name"] = name_entry.get()
        result["root"] = dir_entry.get()
        root.destroy()

    def cancel() -> None:
        result["name"] = default_name
        result["root"] = default_root
        root.destroy()

    btns = ttk.Frame(frame)
    btns.grid(column=0, row=4, columnspan=2, sticky="e")
    ttk.Button(btns, text="Cancel", command=cancel).grid(column=0, row=0, padx=(0, 8))
    ttk.Button(btns, text="Continue", command=ok).grid(column=1, row=0)
    root.bind("<Return>", ok)
    root.bind("<Escape>", lambda _e: cancel())
    root.mainloop()
    if "name" not in result:
        return None
    return result["name"], result["root"] or default_root


def _dialog_setup(default_name: str, default_root: str) -> tuple[str, str] | None:
    import shutil
    import subprocess

    name = default_name
    folder = default_root
    if shutil.which("zenity"):
        proc = subprocess.run(
            [
                "zenity",
                "--entry",
                "--title=MedLock",
                "--text=Workspace name",
                f"--entry-text={default_name}",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            return None
        name = proc.stdout.strip() or default_name
        proc = subprocess.run(
            [
                "zenity",
                "--file-selection",
                "--directory",
                "--title=Store MedLock files in this folder",
                f"--filename={default_root}/",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            folder = proc.stdout.strip()
        return name, folder
    if shutil.which("kdialog"):
        proc = subprocess.run(
            ["kdialog", "--inputbox", "Workspace name", default_name],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            return None
        name = proc.stdout.strip() or default_name
        proc = subprocess.run(
            ["kdialog", "--getexistingdirectory", default_root, "Store MedLock files in this folder"],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            folder = proc.stdout.strip()
        return name, folder
    return None


def main() -> None:
    name, parent = ask_setup()
    root = prepare(name, parent=parent)
    env_path = project_dir() / ".env"
    if env_path.is_file():
        upsert_env(
            env_path,
            {
                "MEDLOCK_WORKSPACE": root.name,
                "MEDLOCK_DATA": str(root),
                "MEDLOCK_DATA_ROOT": str(parent),
            },
        )
    print(f"export WORKSPACE_NAME={json.dumps(root.name)}")
    print(f"export MEDLOCK_DATA={json.dumps(str(root))}")
    print(f"export MEDLOCK_DATA_ROOT={json.dumps(str(parent))}")


if __name__ == "__main__":
    main()
