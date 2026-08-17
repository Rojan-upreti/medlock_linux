"""Standalone MedLock window. Closing it does not stop the servers."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import webbrowser
from pathlib import Path


def open_window(url: str, title: str) -> None:
    if _chrome_app(url):
        return
    if _firefox_window(url):
        return
    if _webview_ok():
        try:
            import webview

            webview.create_window(title, url, width=1240, height=820, min_size=(800, 560))
            webview.start()
            return
        except Exception:
            pass
    webbrowser.open(url)


def _webview_ok() -> bool:
    try:
        import gi  # noqa: F401

        return True
    except Exception:
        pass
    try:
        import qtpy  # noqa: F401

        return True
    except Exception:
        return False


def _chrome_app(url: str) -> bool:
    candidates = [
        "chromium-browser",
        "chromium",
        "google-chrome",
        "google-chrome-stable",
        "microsoft-edge",
        "microsoft-edge-stable",
        "/snap/bin/chromium",
        "/usr/bin/chromium-browser",
        "/usr/bin/google-chrome",
        "/usr/bin/google-chrome-stable",
    ]
    for name in candidates:
        bin_path = name if name.startswith("/") and Path(name).is_file() else shutil.which(name)
        if not bin_path:
            continue
        profile = Path(os.environ.get("MEDLOCK_DATA") or "/tmp") / "chrome-profile"
        profile.mkdir(parents=True, exist_ok=True)
        try:
            proc = subprocess.Popen(
                [
                    bin_path,
                    f"--user-data-dir={str(profile)}",
                    "--no-first-run",
                    "--disable-sync",
                    "--class=MedLock",
                    f"--app={url}",
                ]
            )
        except OSError:
            continue
        proc.wait()
        return True
    return False


def _firefox_window(url: str) -> bool:
    bin_path = shutil.which("firefox") or ("/usr/bin/firefox" if Path("/usr/bin/firefox").is_file() else None)
    if not bin_path:
        return False
    profile = Path(os.environ.get("MEDLOCK_DATA") or "/tmp") / "firefox-profile"
    profile.mkdir(parents=True, exist_ok=True)
    try:
        proc = subprocess.Popen(
            [
                bin_path,
                "--no-remote",
                "--new-instance",
                "--profile",
                str(profile),
                "--new-window",
                url,
            ]
        )
    except OSError:
        return False
    proc.wait()
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description="MedLock desktop window")
    parser.add_argument("--url", default="http://127.0.0.1:8000/")
    parser.add_argument("--name", default="MedLock")
    args = parser.parse_args()
    open_window(args.url.rstrip("/") + "/", f"MedLock — {args.name}")


if __name__ == "__main__":
    main()
