#!/usr/bin/env python3
"""Ask for the first owner username/password. Prints shell assignments; never logs them."""
from __future__ import annotations

import getpass
import os
import shlex
import sys


def _tk() -> tuple[str, str] | None:
    import tkinter as tk
    from tkinter import ttk

    result: dict[str, str] = {}
    root = tk.Tk()
    root.title("MedLock owner account")
    root.resizable(False, False)
    root.configure(bg="#efeae1")
    frame = ttk.Frame(root, padding=18)
    frame.grid()
    ttk.Label(frame, text="Create the owner account").grid(column=0, row=0, columnspan=2, sticky="w")
    ttk.Label(frame, text="This username and password unlock chat and admin.").grid(
        column=0, row=1, columnspan=2, sticky="w", pady=(0, 10)
    )
    ttk.Label(frame, text="Username").grid(column=0, row=2, sticky="w")
    user = ttk.Entry(frame, width=36)
    user.grid(column=0, row=3, columnspan=2, pady=(4, 10), sticky="ew")
    user.focus()
    ttk.Label(frame, text="Password (min 8)").grid(column=0, row=4, sticky="w")
    pw = ttk.Entry(frame, width=36, show="•")
    pw.grid(column=0, row=5, columnspan=2, pady=(4, 10), sticky="ew")
    ttk.Label(frame, text="Confirm password").grid(column=0, row=6, sticky="w")
    pw2 = ttk.Entry(frame, width=36, show="•")
    pw2.grid(column=0, row=7, columnspan=2, pady=(4, 10), sticky="ew")
    err = ttk.Label(frame, text="", foreground="#8f3a32")
    err.grid(column=0, row=8, columnspan=2, sticky="w")

    def ok(_event=None) -> None:
        name = user.get().strip()
        a, b = pw.get(), pw2.get()
        if len(name) < 2:
            err.configure(text="Username must be at least 2 characters.")
            return
        if len(a) < 8:
            err.configure(text="Password must be at least 8 characters.")
            return
        if a != b:
            err.configure(text="Passwords do not match.")
            return
        result["u"] = name
        result["p"] = a
        root.destroy()

    def cancel() -> None:
        root.destroy()

    btns = ttk.Frame(frame)
    btns.grid(column=0, row=9, columnspan=2, sticky="e", pady=(8, 0))
    ttk.Button(btns, text="Cancel", command=cancel).grid(column=0, row=0, padx=(0, 8))
    ttk.Button(btns, text="Create", command=ok).grid(column=1, row=0)
    root.bind("<Return>", ok)
    root.bind("<Escape>", lambda _e: cancel())
    root.mainloop()
    if "u" not in result:
        return None
    return result["u"], result["p"]


def main() -> int:
    preset_user = os.environ.get("MEDLOCK_OWNER_USER", "").strip()
    preset_pw = os.environ.get("MEDLOCK_OWNER_PASSWORD", "")
    if preset_user and preset_pw:
        print(f"MEDLOCK_OWNER_USER={shlex.quote(preset_user)}")
        print(f"MEDLOCK_OWNER_PASSWORD={shlex.quote(preset_pw)}")
        return 0
    if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
        try:
            got = _tk()
            if got:
                print(f"MEDLOCK_OWNER_USER={shlex.quote(got[0])}")
                print(f"MEDLOCK_OWNER_PASSWORD={shlex.quote(got[1])}")
                return 0
            return 1
        except Exception:
            pass
    if not sys.stdin.isatty():
        print("Need --owner-user and --owner-password in non-interactive mode.", file=sys.stderr)
        return 2
    try:
        name = input("Owner username: ").strip()
        pw = getpass.getpass("Owner password: ")
        pw2 = getpass.getpass("Confirm password: ")
    except EOFError:
        return 1
    if len(name) < 2 or len(pw) < 8 or pw != pw2:
        print("Username (2+) and matching password (8+) required.", file=sys.stderr)
        return 2
    print(f"MEDLOCK_OWNER_USER={shlex.quote(name)}")
    print(f"MEDLOCK_OWNER_PASSWORD={shlex.quote(pw)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
