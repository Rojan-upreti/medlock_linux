#!/usr/bin/env bash
# Desktop launcher: ensure the background service is up, then open the UI.
# Closing this window does not stop MedLock.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"

PROJECT_DIR="${PROJECT_DIR:-$SCRIPT_DIR}"
VENV="${PROJECT_DIR}/.venv"
ENVF="${PROJECT_DIR}/.env"
cd "$PROJECT_DIR"
export PROJECT_DIR
export PYTHONPATH="${PROJECT_DIR}${PYTHONPATH:+:$PYTHONPATH}"
export MEDLOCK_SKIP_NEMOCLAW_DOWNLOAD="${MEDLOCK_SKIP_NEMOCLAW_DOWNLOAD:-1}"

[[ -x "${VENV}/bin/python" ]] || die "Virtualenv missing. Run ./install.sh"
[[ -f "$ENVF" ]] || die ".env missing. Run ./install.sh"
# shellcheck disable=SC1091
source "${VENV}/bin/activate"
set -a
# shellcheck disable=SC1091
source "$ENVF"
set +a

if [[ -z "${MEDLOCK_DATA:-}" || -z "${MEDLOCK_WORKSPACE:-}" ]]; then
  eval "$(python -m app.workspace)"
  [[ -n "${MEDLOCK_DATA:-}" ]] || die "Workspace setup failed"
fi
export MEDLOCK_DATA
export WORKSPACE_NAME="${MEDLOCK_WORKSPACE:-$(basename "$MEDLOCK_DATA")}"
mkdir -p "${MEDLOCK_DATA}/data/uploads" "${MEDLOCK_DATA}/data/documents" "${MEDLOCK_DATA}/logs"
log_ok "Workspace: ${WORKSPACE_NAME}  (${MEDLOCK_DATA})"

HOST="${MEDLOCK_HOST:-127.0.0.1}"
PORT="${MEDLOCK_PORT:-8000}"
HEALTH="http://${HOST}:${PORT}/health"

service_active() {
  have_cmd systemctl && systemctl --user is-active --quiet local-enterprise-agent.service
}

ensure_servers() {
  local unit="local-enterprise-agent.service"
  if have_cmd systemctl && systemctl --user cat "$unit" >/dev/null 2>&1; then
    if systemctl --user is-active --quiet "$unit" \
      && curl -fsS --max-time 2 "$HEALTH" >/dev/null 2>&1; then
      return 0
    fi
    log_info "Starting MedLock background service"
    systemctl --user reset-failed "$unit" 2>/dev/null || true
    if systemctl --user restart "$unit" 2>/dev/null; then
      if wait_for_http "$HEALTH" 90; then
        return 0
      fi
    else
      log_warn "Could not start user systemd unit; starting servers in the background"
    fi
  elif curl -fsS --max-time 2 "$HEALTH" >/dev/null 2>&1; then
    return 0
  fi
  nohup "${PROJECT_DIR}/run.sh" --demo --host "$HOST" --port "$PORT" \
    >> "${MEDLOCK_DATA}/logs/app.log" 2>&1 &
  if ! wait_for_http "$HEALTH" 90; then
    die "MedLock did not become healthy. Check ${MEDLOCK_DATA}/logs/app.log and ${PROJECT_DIR}/logs/systemd.err.log"
  fi
}

ensure_servers
log_ok "MedLock is running at ${HEALTH%/health}/"
log_info "Closing this window leaves MedLock running. Stop with: systemctl --user stop local-enterprise-agent"
python -m app.desktop --url "http://${HOST}:${PORT}" --name "${WORKSPACE_NAME}"
