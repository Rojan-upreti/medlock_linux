#!/usr/bin/env bash
# Start MedLock (llama-server + FastAPI) on loopback. Never prints secrets.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"

HOST="127.0.0.1"
PORT="8000"
DEMO=0
DRY_RUN=0
WINDOW=0

usage() {
  cat <<'EOF'
Usage: ./run.sh [--host 127.0.0.1] [--port 8000] [--demo] [--window] [--dry-run]

  --demo     Use only synthetic/local demo data
  --window   Open the standalone desktop app after the server is up
  --dry-run  Validate config without starting processes
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --demo) DEMO=1; shift ;;
    --window) WINDOW=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

PROJECT_DIR="${PROJECT_DIR:-$SCRIPT_DIR}"
ENVF="${PROJECT_DIR}/.env"
VENV="${PROJECT_DIR}/.venv"
CFG="${PROJECT_DIR}/config/local.yaml"

[[ -d "$VENV" ]] || die "Virtualenv missing. Run ./install.sh"
[[ -f "$ENVF" ]] || die ".env missing. Run ./install.sh"
[[ -f "$CFG" ]] || die "config/local.yaml missing. Run ./install.sh"

set -a
# shellcheck disable=SC1090
source "$ENVF"
set +a
if [[ -z "${MEDLOCK_DATA:-}" ]]; then
  MEDLOCK_DATA="${MEDLOCK_DATA_ROOT:-${HOME}/MedLock}/${MEDLOCK_WORKSPACE:-MedLock}"
fi
mkdir -p "${MEDLOCK_DATA}/data/uploads" "${MEDLOCK_DATA}/data/documents" "${MEDLOCK_DATA}/logs"
export MEDLOCK_DATA
LOG_DIR="${MEDLOCK_DATA}/logs"
mkdir -p "$LOG_DIR"
# shellcheck disable=SC1091
source "${VENV}/bin/activate"

export MEDLOCK_HOST="$HOST"
export MEDLOCK_PORT="$PORT"
export MEDLOCK_DEMO="$DEMO"
export PYTHONPATH="${PROJECT_DIR}${PYTHONPATH:+:$PYTHONPATH}"

python3 - "$CFG" <<'PY'
import sys, yaml
from pathlib import Path
cfg = yaml.safe_load(Path(sys.argv[1]).read_text())
inf = cfg.get("inference") or {}
if inf.get("allow_cloud_llm") is True or inf.get("mode") != "local":
    sys.exit("Refusing to start: config permits cloud LLM inference. Set inference.mode=local and allow_cloud_llm=false")
print("cloud LLM blocked: ok")
PY

MODEL_PATH="${MODEL_PATH:-}"
BUNDLED="${PROJECT_DIR}/llm/qwen2.5-0.5b/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf"
if [[ -z "$MODEL_PATH" || ! -f "$MODEL_PATH" ]]; then
  if [[ -f "$BUNDLED" ]]; then
    MODEL_PATH="$BUNDLED"
    log_info "Using bundled Qwen GGUF"
  else
    die "Local GGUF not found (MODEL_PATH=${MODEL_PATH:-unset}). Place Qwen at ${BUNDLED}, upload in the admin hub, or re-run install.sh --download-models"
  fi
fi
python3 "${PROJECT_DIR}/scripts/check_models.py" --model-path "$MODEL_PATH" >/dev/null \
  || die "MODEL_PATH failed GGUF validation: ${MODEL_PATH}"

LLAMA_BIN="${LLAMA_SERVER_BIN:-}"
if [[ -z "$LLAMA_BIN" || ! -x "$LLAMA_BIN" ]]; then
  die "llama-server binary missing (LLAMA_SERVER_BIN). Re-run install.sh"
fi

LLAMA_HOST="${LLAMA_HOST:-127.0.0.1}"
LLAMA_PORT="${LLAMA_PORT:-8081}"
SERVED="${SERVED_MODEL_NAME:-medlock-llm}"
API_KEY="${LLAMA_API_KEY:-}"
[[ -n "$API_KEY" ]] || die "LLAMA_API_KEY is empty"

llama_cmd=(
  "$LLAMA_BIN"
  --model "$MODEL_PATH"
  --host "$LLAMA_HOST"
  --port "$LLAMA_PORT"
  --api-key "$API_KEY"
  --alias "$SERVED"
  --ctx-size "${LLAMA_CTX:-8192}"
  --n-gpu-layers "${LLAMA_N_GPU_LAYERS:-99}"
  --metrics
)
if [[ -n "${MMPROJ_PATH:-}" && -f "${MMPROJ_PATH}" ]]; then
  llama_cmd+=(--mmproj "$MMPROJ_PATH")
fi

app_cmd=(
  python -m uvicorn app.main:app
  --host "$HOST"
  --port "$PORT"
  --app-dir "$PROJECT_DIR"
)

if [[ "$DRY_RUN" == "1" ]]; then
  log_ok "Dry-run passed"
  log_info "Would start llama-server: ${LLAMA_BIN} --model <redacted-path> --host ${LLAMA_HOST} --port ${LLAMA_PORT}"
  log_info "Would start uvicorn on ${HOST}:${PORT}"
  exit 0
fi

if [[ "$DEMO" == "1" ]]; then
  log_info "Demo mode: synthetic/local data only"
  export MEDLOCK_DEMO=1
fi

# Stop leftover llama-server we started (same pid file only)
PIDF="${LOG_DIR}/llama-server.pid"
if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  log_info "llama-server already running (pid $(cat "$PIDF"))"
else
  log_info "Starting llama-server on ${LLAMA_HOST}:${LLAMA_PORT}"
  "${llama_cmd[@]}" >> "${LOG_DIR}/llama-server.log" 2>&1 &
  echo $! > "$PIDF"
fi

if [[ "$WINDOW" != "1" ]]; then
  cleanup() {
    if [[ -f "${LOG_DIR}/uvicorn.pid" ]]; then
      local upid
      upid="$(cat "${LOG_DIR}/uvicorn.pid" || true)"
      if [[ -n "$upid" ]] && kill -0 "$upid" 2>/dev/null; then
        kill "$upid" 2>/dev/null || true
      fi
    fi
    if [[ -f "$PIDF" ]]; then
      local pid
      pid="$(cat "$PIDF" || true)"
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
      fi
    fi
  }
  trap cleanup EXIT INT TERM
fi

if ! wait_for_http "http://${LLAMA_HOST}:${LLAMA_PORT}/health" 120; then
  log_warn "llama-server /health did not respond; /v1/models may still come up. Check ${LOG_DIR}/llama-server.log"
else
  log_ok "llama-server healthy"
  if [[ "${MEDLOCK_SKIP_NEMOCLAW:-0}" != "1" && ! -f "${LOG_DIR}/.nemoclaw-onboarded" ]]; then
    if "${PROJECT_DIR}/scripts/setup_nemoclaw.sh"; then
      : > "${LOG_DIR}/.nemoclaw-onboarded"
    fi
  fi
fi

if ! reclaim_tcp_port "$HOST" "$PORT"; then
  die "Port ${PORT} is in use by another process. Stop it, then retry."
fi

log_ok "MedLock listening on http://${HOST}:${PORT}"
if [[ "$WINDOW" == "1" ]]; then
  log_info "Starting desktop window (workspace: ${WORKSPACE_NAME:-MedLock})"
  "${app_cmd[@]}" >> "${LOG_DIR}/app.log" 2>&1 &
  echo $! > "${LOG_DIR}/uvicorn.pid"
  if ! wait_for_http "http://${HOST}:${PORT}/health" 60; then
    die "MedLock did not become healthy. Check ${LOG_DIR}/app.log"
  fi
  python -m app.desktop --url "http://${HOST}:${PORT}" --name "${WORKSPACE_NAME:-MedLock}"
  exit 0
fi
log_info "Chat:  http://${CHAT_HOSTNAME:-medlock.chat}:${PORT}   (or http://${HOST}:${PORT}/)"
log_info "Admin: http://${ADMIN_HOSTNAME:-medlock.admin}:${PORT} (or http://${HOST}:${PORT}/admin)"
exec "${app_cmd[@]}"
