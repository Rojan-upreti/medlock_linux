#!/usr/bin/env bash
# Wipe chats, attachments, audit, and leftover sqlite so install starts empty.
# Never deletes .env, venv, GGUF, or demo playbooks. Never prints secrets.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PURGE_HOME=0
PROJECT_DIR="${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
for arg in "$@"; do
  case "$arg" in
    --purge-home) PURGE_HOME=1 ;;
    --help|-h)
      echo "Usage: reset_runtime_data.sh [PROJECT_DIR] [--purge-home]"
      exit 0
      ;;
    *) PROJECT_DIR="$arg" ;;
  esac
done
PROJECT_DIR="${PROJECT_DIR/#\~/$HOME}"

wipe_sqlite() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  rm -f "${dir}/medlock.sqlite" "${dir}/medlock.sqlite-wal" "${dir}/medlock.sqlite-shm"
}

wipe_uploads() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 ! -name '.gitkeep' -exec rm -rf {} + 2>/dev/null || true
}

log_step "Reset runtime databases (fresh install)"

wipe_sqlite "${PROJECT_DIR}/data"
wipe_uploads "${PROJECT_DIR}/data/uploads"
if [[ -d "${PROJECT_DIR}/data/vectorstore" ]]; then
  find "${PROJECT_DIR}/data/vectorstore" -mindepth 1 ! -name '.gitkeep' -exec rm -rf {} + 2>/dev/null || true
fi

if [[ -d "${HOME}/MedLock" ]]; then
  shopt -s nullglob
  for ws in "${HOME}/MedLock"/*; do
    [[ -d "$ws" ]] || continue
    wipe_sqlite "${ws}/data"
    wipe_uploads "${ws}/data/uploads"
  done
  shopt -u nullglob
  rm -f "${HOME}/MedLock/.migrated-from-install"
  if [[ "$PURGE_HOME" == "1" ]]; then
    shopt -s nullglob
    for ws in "${HOME}/MedLock"/*; do
      [[ -d "$ws" ]] || continue
      [[ "$(basename "$ws")" == .* ]] && continue
      rm -rf "$ws"
    done
    shopt -u nullglob
    rm -f "${HOME}/MedLock/last-workspace"
    log_ok "Removed previous ~/MedLock workspaces"
  fi
fi

if [[ -f "${PROJECT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"
  set +a
  if [[ "$PURGE_HOME" == "1" && -n "${MEDLOCK_DATA:-}" && -d "${MEDLOCK_DATA}" ]]; then
    case "${MEDLOCK_DATA}" in
      "${HOME}/MedLock"/*) ;;
      *)
        log_warn "Removing previous data folder ${MEDLOCK_DATA}"
        rm -rf "${MEDLOCK_DATA}"
        ;;
    esac
  fi
  if [[ -x "${PROJECT_DIR}/.venv/bin/python" ]]; then
    "${PROJECT_DIR}/.venv/bin/python" - <<'PY' || true
import os
host = os.environ.get("POSTGRES_HOST", "127.0.0.1")
port = os.environ.get("POSTGRES_PORT", "5432")
user = os.environ.get("POSTGRES_USER", "medlock")
name = os.environ.get("POSTGRES_DB", "medlock")
password = os.environ.get("POSTGRES_PASSWORD", "")
try:
    import psycopg
    dsn = f"postgresql://{user}:{password}@{host}:{port}/{name}"
    with psycopg.connect(dsn, connect_timeout=3, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                TRUNCATE TABLE
                  attachments, messages, conversations,
                  chunks, documents, audit_events, api_keys
                RESTART IDENTITY CASCADE
                """
            )
    print("postgres tables truncated")
except Exception:
    print("postgres skipped (not reachable)")
PY
  fi
  if [[ "$PURGE_HOME" == "1" ]]; then
    python3 - "$PROJECT_DIR/.env" <<'PY' || true
from pathlib import Path
import sys
path = Path(sys.argv[1])
if not path.is_file():
    raise SystemExit(0)
clear = {"MEDLOCK_DATA", "MEDLOCK_DATA_ROOT", "MEDLOCK_WORKSPACE"}
out = []
for line in path.read_text(encoding="utf-8").splitlines():
    if line and not line.lstrip().startswith("#") and "=" in line:
        k = line.split("=", 1)[0].strip()
        if k in clear:
            out.append(f"{k}=")
            continue
    out.append(line)
path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
    rm -rf "${HOME}/.config/medlock"
  fi
fi

log_ok "Runtime data cleared. Next start will recreate empty databases."
