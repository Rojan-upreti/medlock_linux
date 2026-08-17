#!/usr/bin/env bash
# Uninstall MedLock runtime pieces. Never deletes project files or user data by default.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"

PROJECT_DIR="${PROJECT_DIR:-$SCRIPT_DIR}"
PURGE=0
PURGE_WORKSPACES=0
REMOVE_MODELS=0
REMOVE_VENV=0
REMOVE_SYSTEMD=0
REMOVE_CACHE=0
YES=0
STOP_DOCKER=0

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [options]

Default: stop the user systemd unit and llama-server pids if present. Does not
delete project files, models, Postgres data, ~/MedLock workspaces, or .env.
MedLock is a single install per account; re-run ./install.sh and type REINSTALL
to replace it.

  --remove-venv         Delete [PROJECT_DIR]/.venv
  --remove-systemd      Disable and remove the user systemd unit
  --remove-cache        Delete pip/hf caches under the project only
  --remove-models       Delete GGUF files under llm/ and models/ (separate confirmation)
  --stop-docker         docker compose down for db/docker-compose.yml (keeps volume unless --purge)
  --purge               DESTROYS generated install files (.env, config/local.yaml, project logs/sqlite)
                        Interactive mode requires typing DELETE
  --purge-workspaces    Also delete the chosen data folder, ~/MedLock, and Desktop/MedLock.desktop
  --yes                 Skip yes/no prompts (still requires typed DELETE for purge unless CI=1)
  --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove-venv) REMOVE_VENV=1; shift ;;
    --remove-systemd) REMOVE_SYSTEMD=1; shift ;;
    --remove-cache) REMOVE_CACHE=1; shift ;;
    --remove-models) REMOVE_MODELS=1; shift ;;
    --stop-docker) STOP_DOCKER=1; shift ;;
    --purge) PURGE=1; shift ;;
    --purge-workspaces) PURGE_WORKSPACES=1; shift ;;
    --yes) YES=1; MEDLOCK_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

log_step "MedLock uninstall"
log_info "Project: ${PROJECT_DIR}"
if [[ -f "${PROJECT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"
  set +a
fi
log_warn "Chats in ${MEDLOCK_DATA:-~/MedLock} are kept unless you pass --purge-workspaces."

if have_cmd systemctl; then
  systemctl --user stop local-enterprise-agent.service 2>/dev/null || true
  log_ok "Stopped user systemd unit (if it was running)"
fi

stop_pidfile() {
  local pidfile="$1"
  [[ -f "$pidfile" ]] || return 0
  local pid
  pid="$(cat "$pidfile" || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" || true
    log_ok "Stopped pid ${pid} (${pidfile})"
  fi
}

if [[ "$REMOVE_SYSTEMD" == "1" || "$PURGE" == "1" ]]; then
  if have_cmd systemctl; then
    systemctl --user disable --now local-enterprise-agent.service 2>/dev/null || true
    rm -f "${HOME}/.config/systemd/user/local-enterprise-agent.service"
    systemctl --user daemon-reload 2>/dev/null || true
    log_ok "Removed user systemd unit (if it existed)"
  fi
fi

if [[ -f "${PROJECT_DIR}/logs/llama-server.pid" ]]; then
  stop_pidfile "${PROJECT_DIR}/logs/llama-server.pid"
fi
if [[ -n "${MEDLOCK_DATA:-}" && -f "${MEDLOCK_DATA}/logs/llama-server.pid" ]]; then
  stop_pidfile "${MEDLOCK_DATA}/logs/llama-server.pid"
fi
if [[ -n "${MEDLOCK_DATA:-}" && -f "${MEDLOCK_DATA}/logs/uvicorn.pid" ]]; then
  stop_pidfile "${MEDLOCK_DATA}/logs/uvicorn.pid"
fi
if [[ -d "${HOME}/MedLock" ]]; then
  shopt -s nullglob
  for pidfile in "${HOME}/MedLock/"*/logs/llama-server.pid "${HOME}/MedLock/"*/logs/uvicorn.pid; do
    stop_pidfile "$pidfile"
  done
  shopt -u nullglob
fi

if [[ "$STOP_DOCKER" == "1" || "$PURGE" == "1" ]]; then
  if have_cmd docker && [[ -f "${PROJECT_DIR}/db/docker-compose.yml" ]]; then
    if [[ "$PURGE" == "1" ]]; then
      docker compose --env-file "${PROJECT_DIR}/.env" -f "${PROJECT_DIR}/db/docker-compose.yml" down -v || true
    else
      docker compose --env-file "${PROJECT_DIR}/.env" -f "${PROJECT_DIR}/db/docker-compose.yml" down || true
    fi
  fi
fi

if [[ "$REMOVE_VENV" == "1" || "$PURGE" == "1" ]]; then
  if [[ "$YES" == "1" ]] || confirm "Delete ${PROJECT_DIR}/.venv ?"; then
    rm -rf "${PROJECT_DIR}/.venv"
    log_ok "Removed virtualenv"
  fi
fi

if [[ "$REMOVE_CACHE" == "1" || "$PURGE" == "1" ]]; then
  rm -rf "${PROJECT_DIR}/.cache" "${PROJECT_DIR}/tmp"
  log_ok "Removed project caches"
fi

if [[ "$REMOVE_MODELS" == "1" ]]; then
  log_warn "This deletes GGUF and embedding files under llm/ and models/."
  if [[ "$YES" == "1" ]] || confirm "Delete local model files?"; then
    find "${PROJECT_DIR}/llm" "${PROJECT_DIR}/models" -type f \( -name '*.gguf' -o -name '*.onnx' -o -name '*.safetensors' -o -name '*.bin' \) -delete 2>/dev/null || true
    log_ok "Removed model weight files (directories kept)"
  fi
fi

if [[ "$PURGE" == "1" ]]; then
  log_warn "PURGE will delete .env, config/local.yaml, leftover project logs/sqlite, and backups of generated config."
  log_warn "This does NOT uninstall llama.cpp from LLAMACPP_DIR, apt packages, or ~/MedLock workspaces."
  typed=""
  if [[ "${CI:-}" == "1" && "$YES" == "1" ]]; then
    typed="DELETE"
  else
    read -r -p "Type DELETE to confirm purge: " typed
  fi
  if [[ "$typed" != "DELETE" ]]; then
    die "Purge aborted"
  fi
  rm -f "${PROJECT_DIR}/.env" "${PROJECT_DIR}/config/local.yaml" "${PROJECT_DIR}/config/local.json"
  rm -rf "${PROJECT_DIR}/logs/"* "${PROJECT_DIR}/data/medlock.sqlite" "${PROJECT_DIR}/data/medlock.sqlite-wal" "${PROJECT_DIR}/data/medlock.sqlite-shm" "${PROJECT_DIR}/data/vectorstore/"* "${PROJECT_DIR}/data/uploads/"*
  log_ok "Purged generated runtime files. GGUFs kept unless --remove-models. Workspaces in ~/MedLock kept unless --purge-workspaces."
fi

if [[ "$PURGE_WORKSPACES" == "1" ]]; then
  log_warn "This deletes the workspace data folder (chats, uploads, logs) and the desktop shortcut."
  typed=""
  if [[ "${CI:-}" == "1" && "$YES" == "1" ]]; then
    typed="DELETE"
  else
    read -r -p "Type DELETE to remove workspace data: " typed
  fi
  if [[ "$typed" != "DELETE" ]]; then
    die "Workspace purge aborted"
  fi
  if [[ -n "${MEDLOCK_DATA:-}" && -d "${MEDLOCK_DATA}" ]]; then
    rm -rf "${MEDLOCK_DATA}"
  fi
  rm -rf "${HOME}/MedLock"
  rm -rf "${HOME}/.config/medlock"
  rm -f "${HOME}/Desktop/MedLock.desktop"
  log_ok "Removed workspace data and the desktop shortcut"
fi

log_ok "Uninstall step finished"
log_info "Project source tree left in place: ${PROJECT_DIR}"
