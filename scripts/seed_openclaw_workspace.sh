#!/usr/bin/env bash
# Copy hospital-admin OpenClaw workspace files onto this machine.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
PROJECT_DIR="${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
export PROJECT_DIR PYTHONPATH="${PROJECT_DIR}${PYTHONPATH:+:$PYTHONPATH}"
py="${PROJECT_DIR}/.venv/bin/python"
[[ -x "$py" ]] || py=python3
"$py" - <<'PY'
from app.services.nemoclaw import seed_workspace
print(seed_workspace())
PY
