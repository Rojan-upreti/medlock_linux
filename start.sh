#!/usr/bin/env bash
# One command: install if needed, then open the MedLock desktop app.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
chmod +x MedLock.sh start.sh run.sh install.sh verify_install.sh uninstall.sh 2>/dev/null || true
chmod +x scripts/*.sh 2>/dev/null || true
if [[ " $* " == *" --fresh "* ]] || [[ ! -x .venv/bin/python || ! -f .env || ! -f config/local.yaml ]]; then
  ./install.sh "$@"
else
  .venv/bin/pip install -q -r requirements.txt
  PYTHONPATH="${PWD}${PYTHONPATH:+:$PYTHONPATH}" .venv/bin/python -c \
    "from pathlib import Path; from app.workspace import _install_shortcut; _install_shortcut(Path('.').resolve())" \
    >/dev/null 2>&1 || true
fi
exec ./MedLock.sh
