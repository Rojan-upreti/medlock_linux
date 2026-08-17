#!/usr/bin/env bash
# Optional NemoClaw + OpenShell + OpenClaw wiring against local llama.cpp :8081.
# Never pipes curl | bash. Skipped in --offline.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PROJECT_DIR="${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
INSTALLER_URL="${NEMOCLAW_INSTALLER_URL:-https://www.nvidia.com/nemoclaw.sh}"
INSTALLER_PATH="${PROJECT_DIR}/backups/nemoclaw-installer.sh"
TOKEN="${NEMOCLAW_LLAMACPP_LOCAL_TOKEN:-${LLAMA_API_KEY:-}}"
MODEL="${SERVED_MODEL_NAME:-medlock-llm}"
SANDBOX="${NEMOCLAW_SANDBOX_NAME:-medlock-assistant}"

if [[ "${MEDLOCK_OFFLINE:-0}" == "1" ]]; then
  log_warn "Skipping NemoClaw (--offline). Wire it later with ./scripts/setup_nemoclaw.sh"
  exit 0
fi

if [[ "${MEDLOCK_SKIP_NEMOCLAW:-0}" == "1" ]]; then
  log_info "Skipping NemoClaw (MEDLOCK_SKIP_NEMOCLAW=1)"
  exit 0
fi

if [[ -z "$TOKEN" ]]; then
  die "NEMOCLAW_LLAMACPP_LOCAL_TOKEN / LLAMA_API_KEY is empty"
fi

if ! have_cmd curl; then
  die "curl is required to download the NemoClaw installer"
fi

log_step "NemoClaw / OpenShell / OpenClaw"

if have_cmd nemoclaw; then
  log_ok "nemoclaw CLI already on PATH"
else
  log_info "NemoClaw installer URL: ${INSTALLER_URL}"
  log_warn "This downloads NVIDIA OpenShell + NemoClaw and may need Docker + network."
  if ! confirm "Download and run the NemoClaw installer (saved to ${INSTALLER_PATH} first)?"; then
    log_warn "Skipped NemoClaw. Chat and admin still work locally."
    exit 0
  fi
  mkdir -p "${PROJECT_DIR}/backups"
  curl -fsSL "$INSTALLER_URL" -o "$INSTALLER_PATH"
  chmod 750 "$INSTALLER_PATH"
  log_info "Saved installer ($(wc -c < "$INSTALLER_PATH") bytes). Review it if you wish, then continuing."
  bash "$INSTALLER_PATH"
fi

have_cmd nemoclaw || {
  log_warn "nemoclaw still not on PATH. Open a new shell or add NVIDIA's bin dir. Skipping onboard."
  exit 0
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
  NEMOCLAW_ENDPOINT_URL="http://127.0.0.1:${MEDLOCK_PORT:-8000}/v1" \
  NEMOCLAW_MODEL="$MODEL" \
  NEMOCLAW_SANDBOX_NAME="$SANDBOX" \
  NEMOCLAW_COMPATIBLE_AUTH_MODE=none \
  nemoclaw onboard --non-interactive --yes-i-accept-third-party-software
}

log_info "Onboarding NemoClaw against llama.cpp on 127.0.0.1:8081"
if onboard_llama; then
  log_ok "NemoClaw onboarded with llama-cpp provider"
  exit 0
fi

log_warn "Native llama.cpp fingerprint failed; trying custom OpenAI-compatible endpoint via MedLock :8000/v1"
if onboard_custom; then
  log_ok "NemoClaw onboarded with custom OpenAI-compatible provider"
  exit 0
fi

log_warn "NemoClaw onboard failed. Local MedLock chat still works. See README_INSTALL.md"
exit 0
