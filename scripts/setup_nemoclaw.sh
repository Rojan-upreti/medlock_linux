#!/usr/bin/env bash
# Onboard / start / stop NemoClaw using the LOCAL copy in vendor/nemoclaw/.
# Never downloads. Same llama.cpp as chat. No cloud providers.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PROJECT_DIR="${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
ENVF="${PROJECT_DIR}/.env"
if [[ -f "$ENVF" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENVF"
  set +a
fi

ACTION="${1:-onboard}"
VENDOR_BIN="${PROJECT_DIR}/vendor/nemoclaw/bin"
VENDOR_INSTALLER="${PROJECT_DIR}/vendor/nemoclaw/installer/nemoclaw.sh"
export PATH="${VENDOR_BIN}:/usr/sbin:/sbin:${HOME}/.local/bin:${HOME}/.nemoclaw/bin:${PATH}"

TOKEN="${NEMOCLAW_LLAMACPP_LOCAL_TOKEN:-${LLAMA_API_KEY:-}}"
MODEL="${SERVED_MODEL_NAME:-medlock-llm}"
SANDBOX="${NEMOCLAW_SANDBOX_NAME:-medlock-assistant}"
LLAMA_HOST="${LLAMA_HOST:-127.0.0.1}"
LLAMA_PORT="${LLAMA_PORT:-8081}"
MEDLOCK_PORT="${MEDLOCK_PORT:-8000}"
LOG_DIR="${MEDLOCK_DATA:-$PROJECT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOGF="${LOG_DIR}/nemoclaw.log"

if [[ "${MEDLOCK_SKIP_NEMOCLAW:-0}" == "1" ]]; then
  log_info "Skipping NemoClaw (MEDLOCK_SKIP_NEMOCLAW=1)"
  exit 0
fi

unset NVIDIA_INFERENCE_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY || true
export NEMOCLAW_EXPERIMENTAL="${NEMOCLAW_EXPERIMENTAL:-0}"
export NEMOCLAW_AGENT="${NEMOCLAW_AGENT:-openclaw}"
export NEMOCLAW_SANDBOX_NAME="$SANDBOX"
export NEMOCLAW_MODEL="$MODEL"
export NEMOCLAW_LLAMACPP_LOCAL_TOKEN="${TOKEN:-}"

has_vendor() {
  [[ -x "${VENDOR_BIN}/nemoclaw" ]] || [[ -x "${VENDOR_BIN}/openshell" ]] || [[ -x "${VENDOR_BIN}/openclaw" ]]
}

if ! has_vendor && ! have_cmd nemoclaw && ! have_cmd openshell; then
  if [[ "${MEDLOCK_OFFLINE:-0}" == "1" ]]; then
    log_warn "NemoClaw vendor/ is empty and --offline. Chat still works. Run fetch on a networked box, then copy vendor/nemoclaw/."
    exit 0
  fi
  log_warn "No local NemoClaw copy. Run ./scripts/fetch_nemoclaw.sh once (saves into vendor/nemoclaw/). Chat still works."
  exit 0
fi

enable_yaml() {
  local provider="$1"
  PYTHONPATH="${PROJECT_DIR}${PYTHONPATH:+:$PYTHONPATH}" \
    "${PROJECT_DIR}/.venv/bin/python" - "$provider" <<'PY'
import sys
from app.services.nemoclaw import enable_in_yaml, seed_workspace
enable_in_yaml(sys.argv[1], True)
print(seed_workspace())
PY
}

audit() {
  local event="$1" status="${2:-200}" extra="${3:-}"
  PYTHONPATH="${PROJECT_DIR}${PYTHONPATH:+:$PYTHONPATH}" \
    "${PROJECT_DIR}/.venv/bin/python" - "$event" "$status" "$extra" <<'PY' 2>/dev/null || true
import sys
from app.db import get_session
from app.services.nemoclaw import audit_cli
db = get_session()
try:
    extra = sys.argv[3] or ""
    audit_cli(
        db,
        event_type=sys.argv[1],
        status_code=int(sys.argv[2]),
        request_in={"note": extra} if extra else {"source": "setup_nemoclaw.sh"},
    )
finally:
    db.close()
PY
}

ensure_gateway() {
  local gw="${VENDOR_BIN}/openshell-gateway"
  local pidf="${LOG_DIR}/openshell-gateway.pid"
  local driver="vm"
  if medlock_docker info >/dev/null 2>&1; then
    driver="docker"
  fi
  if curl -sS -m 2 -o /dev/null "http://127.0.0.1:17671/healthz" \
    || curl -sS -m 2 -o /dev/null "http://127.0.0.1:17670/"; then
    openshell gateway add http://127.0.0.1:17670 --local --name medlock >/dev/null 2>&1 || true
    openshell gateway select medlock >/dev/null 2>&1 || true
    return 0
  fi
  [[ -x "$gw" ]] || {
    log_warn "openshell-gateway missing in vendor/nemoclaw/bin"
    return 1
  }
  if [[ "$driver" == "vm" && ! -x "${VENDOR_BIN}/openshell-driver-vm" ]]; then
    log_warn "openshell-driver-vm missing (needed without Docker)"
    return 1
  fi
  export OPENSHELL_DRIVERS="$driver"
  nohup "$gw" --bind-address 127.0.0.1 --port 17670 --health-port 17671 --disable-tls \
    --drivers "$driver" --enable-mtls-auth false \
    >>"${LOG_DIR}/openshell-gateway.log" 2>&1 &
  echo $! >"$pidf"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sS -m 1 -o /dev/null "http://127.0.0.1:17671/healthz"; then
      break
    fi
    sleep 0.4
  done
  openshell gateway add http://127.0.0.1:17670 --local --name medlock >/dev/null 2>&1 || true
  openshell gateway select medlock >/dev/null 2>&1 || true
}

do_start() {
  log_step "Start OpenShell sandbox ${SANDBOX}"
  local ok=1
  if have_cmd openshell; then
    if ensure_gateway; then
      if openshell sandbox get "$SANDBOX" >/dev/null 2>&1; then
        log_ok "Sandbox ${SANDBOX} already exists"
        ok=0
      elif openshell sandbox create --name "$SANDBOX" --no-tty -- true 2>&1 | tee -a "$LOGF"; then
        ok=0
      else
        log_warn "openshell sandbox create failed. Chat still works."
      fi
    fi
  fi
  if [[ "$ok" != "0" ]] && have_cmd nemoclaw; then
    if nemoclaw start 2>&1 | tee -a "$LOGF"; then
      ok=0
    fi
  fi
  if [[ "$ok" == "0" ]]; then
    log_ok "Sandbox start attempted"
    audit "nemoclaw.start" 200 "sandbox=${SANDBOX}"
  else
    log_warn "Could not start sandbox. Chat still works."
    audit "nemoclaw.start" 503 "sandbox=${SANDBOX}"
  fi
  return 0
}

do_stop() {
  log_step "Stop OpenShell sandbox ${SANDBOX}"
  if have_cmd openshell; then
    openshell sandbox delete "$SANDBOX" 2>&1 | tee -a "$LOGF" || true
  fi
  if have_cmd nemoclaw; then
    nemoclaw stop 2>&1 | tee -a "$LOGF" || true
  fi
  local pidf="${LOG_DIR}/openshell-gateway.pid"
  if [[ -f "$pidf" ]]; then
    kill "$(cat "$pidf")" 2>/dev/null || true
    rm -f "$pidf"
  fi
  audit "nemoclaw.stop" 200 "sandbox=${SANDBOX}"
}

do_onboard() {
  if [[ -z "$TOKEN" ]]; then
    die "LLAMA_API_KEY is empty (needed to point NemoClaw at the same llama-server as chat)"
  fi
  log_step "NemoClaw onboard (local vendor, llama.cpp ${LLAMA_HOST}:${LLAMA_PORT})"
  {
    printf '\n==> %s onboard %s\n' "$(date -Iseconds)" "$MODEL"
  } >> "$LOGF"
  if [[ -x "$VENDOR_INSTALLER" ]]; then
    log_ok "Using local installer ${VENDOR_INSTALLER} (no download)"
  fi
  llama_ok=0
  if curl -fsS -m 5 -H "Authorization: Bearer ${TOKEN}" "http://${LLAMA_HOST}:${LLAMA_PORT}/health" >/dev/null 2>>"$LOGF"; then
    llama_ok=1
    log_ok "llama-server /health"
  else
    log_warn "llama-server /health failed on ${LLAMA_HOST}:${LLAMA_PORT}"
  fi
  if curl -fsS -m 8 -H "Authorization: Bearer ${TOKEN}" "http://${LLAMA_HOST}:${LLAMA_PORT}/v1/models" >/dev/null 2>>"$LOGF"; then
    log_ok "llama-server /v1/models (same GGUF as chat)"
  else
    [[ "$llama_ok" == "1" ]] || log_warn "llama-server not up yet; onboard may fail. Chat can still start."
  fi
  have_cmd nemoclaw || {
    log_warn "nemoclaw CLI is not vendored (NVIDIA installer needs Docker+Node). Using OpenShell only."
    enable_yaml "llama-cpp" || true
    ensure_gateway || true
    printf 'ok\n' > "${LOG_DIR}/.nemoclaw-onboarded"
    audit "nemoclaw.onboard" 200 "openshell-only"
    log_ok "OpenShell local copy is ready (KVM VM driver, no GPU). Chat still works."
    return 0
  }

  onboard_llama() {
    NEMOCLAW_PROVIDER=llama-cpp \
    NEMOCLAW_LLAMACPP_LOCAL_TOKEN="$TOKEN" \
    NEMOCLAW_MODEL="$MODEL" \
    NEMOCLAW_SANDBOX_NAME="$SANDBOX" \
    nemoclaw onboard --non-interactive --yes-i-accept-third-party-software
  }
  onboard_custom() {
    NEMOCLAW_PROVIDER=custom \
    NEMOCLAW_ENDPOINT_URL="http://127.0.0.1:${MEDLOCK_PORT}/v1" \
    NEMOCLAW_MODEL="$MODEL" \
    NEMOCLAW_SANDBOX_NAME="$SANDBOX" \
    NEMOCLAW_COMPATIBLE_AUTH_MODE=bearer \
    COMPATIBLE_API_KEY="$TOKEN" \
    nemoclaw onboard --non-interactive --yes-i-accept-third-party-software
  }

  if onboard_llama 2>&1 | tee -a "$LOGF"; then
    log_ok "Onboarded llama-cpp provider (same server as chat)"
    enable_yaml "llama-cpp" || true
    printf 'ok\n' > "${LOG_DIR}/.nemoclaw-onboarded"
    audit "nemoclaw.onboard" 200 "provider=llama-cpp"
    return 0
  fi
  log_warn "llama.cpp fingerprint failed; trying MedLock /v1 (same GGUF)"
  if onboard_custom 2>&1 | tee -a "$LOGF"; then
    log_ok "Onboarded custom provider via MedLock /v1"
    enable_yaml "custom" || true
    printf 'ok\n' > "${LOG_DIR}/.nemoclaw-onboarded"
    audit "nemoclaw.onboard" 200 "provider=custom"
    return 0
  fi
  log_warn "Onboard failed. Chat still works. Retry from /admin → OpenClaw stack."
  audit "nemoclaw.onboard" 500 "failed"
  return 0
}

case "$ACTION" in
  onboard) do_onboard ;;
  start) do_start ;;
  stop) do_stop ;;
  *) die "Usage: setup_nemoclaw.sh [onboard|start|stop]" ;;
esac
