#!/usr/bin/env bash
# One-time online fetch of NVIDIA NemoClaw/OpenShell/OpenClaw into vendor/nemoclaw/.
# Never pipes curl | bash. After this, install/start use the local copy only.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PROJECT_DIR="${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
VENDOR="${PROJECT_DIR}/vendor/nemoclaw"
INSTALLER_URL="${NEMOCLAW_INSTALLER_URL:-https://www.nvidia.com/nemoclaw.sh}"
INSTALLER="${VENDOR}/installer/nemoclaw.sh"
BIN="${VENDOR}/bin"
LOG_DIR="${MEDLOCK_DATA:-$PROJECT_DIR}/logs"
mkdir -p "$BIN" "${VENDOR}/installer" "$LOG_DIR"
LOGF="${LOG_DIR}/nemoclaw.log"

if [[ "${MEDLOCK_OFFLINE:-0}" == "1" ]]; then
  die "fetch_nemoclaw.sh needs network. For offline install, copy vendor/nemoclaw/ into this tree first."
fi
have_cmd curl || die "curl is required to fetch the NemoClaw installer"

log_step "Fetch NemoClaw into ${VENDOR}"
log_warn "This contacts NVIDIA once. Review ${INSTALLER} if you wish, then the script continues."
if [[ ! -s "$INSTALLER" ]]; then
  curl -fsSL "$INSTALLER_URL" -o "$INSTALLER"
  chmod 750 "$INSTALLER"
  log_ok "Saved installer ($(wc -c < "$INSTALLER") bytes)"
else
  log_ok "Keeping existing installer"
fi
cp -a "$INSTALLER" "${PROJECT_DIR}/backups/nemoclaw-installer.sh" 2>/dev/null || mkdir -p "${PROJECT_DIR}/backups"

if ! confirm "Run the saved NVIDIA installer to populate vendor/nemoclaw/bin?"; then
  log_warn "Installer saved but not run. Re-run ./scripts/fetch_nemoclaw.sh"
  exit 0
fi

# Non-interactive: NVIDIA refuses a pipe/no-TTY unless this notice is accepted.
# Same flags MedLock already uses in setup_nemoclaw.sh onboard.
export NEMOCLAW_NON_INTERACTIVE="${NEMOCLAW_NON_INTERACTIVE:-1}"
export NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE="${NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE:-1}"
export NEMOCLAW_NO_EXPRESS="${NEMOCLAW_NO_EXPRESS:-1}"
export NEMOCLAW_PROVIDER="${NEMOCLAW_PROVIDER:-llama-cpp}"
set +e
bash "$INSTALLER" --non-interactive --yes-i-accept-third-party-software 2>&1 | tee -a "$LOGF"
installer_rc="${PIPESTATUS[0]}"
set -e
if [[ "${installer_rc}" != "0" ]]; then
  log_warn "NVIDIA installer exited ${installer_rc} (often Docker/sudo on CPU laptops). Vendoring OpenShell binaries next."
fi
export PATH="${HOME}/.local/bin:${HOME}/.nemoclaw/bin:${PATH}"

# Pinned to the OpenShell release NemoClaw lkg trusts (scripts/install-openshell.sh).
OPENSHELL_TAG="${NEMOCLAW_OPENSHELL_PIN:-v0.0.85}"
vendor_openshell_release() {
  local arch tag="$OPENSHELL_TAG" tmp asset expected
  case "$(uname -m)" in
    x86_64 | amd64) arch="x86_64" ;;
    aarch64 | arm64) arch="aarch64" ;;
    *)
      log_warn "No OpenShell asset for $(uname -m)"
      return 1
      ;;
  esac
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/medlock-openshell.XXXXXX")"
  declare -A assets=(
    ["openshell-${arch}-unknown-linux-musl.tar.gz"]=openshell
    ["openshell-gateway-${arch}-unknown-linux-gnu.tar.gz"]=openshell-gateway
    ["openshell-sandbox-${arch}-unknown-linux-gnu.tar.gz"]=openshell-sandbox
    ["openshell-driver-vm-${arch}-unknown-linux-gnu.tar.gz"]=openshell-driver-vm
  )
  declare -A pins=(
    ["v0.0.85:openshell-x86_64-unknown-linux-musl.tar.gz"]=078fa086f506832c3d47d992e6109f26074bdd55916ce268e47c3971423459eb
    ["v0.0.85:openshell-gateway-x86_64-unknown-linux-gnu.tar.gz"]=718cc9f942f88565cacb13c39717b128d6acc8d336212d42d26243f36ab19ece
    ["v0.0.85:openshell-sandbox-x86_64-unknown-linux-gnu.tar.gz"]=94306f057d862cd5c34a0daa7692491733bc5ca528a7b92f9f62f717fb70a9be
    ["v0.0.85:openshell-driver-vm-x86_64-unknown-linux-gnu.tar.gz"]=8b0c63ebf547335ae545734d98ed38ea9681c437fe219d248f2f001ef39f8f16
    ["v0.0.85:openshell-aarch64-unknown-linux-musl.tar.gz"]=3cf353e7994d5835a233fe0641f9a860779190b054d0f90a04c897be782734b8
    ["v0.0.85:openshell-gateway-aarch64-unknown-linux-gnu.tar.gz"]=09f2823f6e9c5f70f4482b200206eac455d789618da4ebe4acff042d794e7162
    ["v0.0.85:openshell-sandbox-aarch64-unknown-linux-gnu.tar.gz"]=2c52b2971aecf125e41ed160d8d2f2addf04031906ca88f120ae3d436dd6b8f7
  )
  for asset in "${!assets[@]}"; do
    local key="${tag}:${asset}"
    expected="${pins[$key]:-}"
    [[ -n "$expected" ]] || {
      log_warn "No pinned SHA-256 for ${key} — skip"
      continue
    }
    log_info "Download ${asset}"
    curl -fsSL "https://github.com/NVIDIA/OpenShell/releases/download/${tag}/${asset}" -o "${tmp}/${asset}"
    actual="$(sha256sum "${tmp}/${asset}" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
      rm -rf "$tmp"
      die "OpenShell checksum mismatch for ${asset}"
    fi
    tar -xzf "${tmp}/${asset}" -C "$tmp"
    install -m 755 "${tmp}/${assets[$asset]}" "${BIN}/${assets[$asset]}"
    log_ok "vendored ${assets[$asset]} (${tag})"
  done
  rm -rf "$tmp"
}

copy_cli() {
  local name="$1"
  local src=""
  local candidate
  for candidate in \
    "$(command -v "$name" 2>/dev/null || true)" \
    "${HOME}/.local/bin/${name}" \
    "${HOME}/.nemoclaw/bin/${name}" \
    "${BIN}/${name}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      src="$candidate"
      break
    fi
  done
  if [[ -n "$src" ]]; then
    if [[ "$src" != "${BIN}/${name}" ]]; then
      cp -a "$src" "${BIN}/${name}"
      chmod 755 "${BIN}/${name}"
    fi
    log_ok "vendored ${name} <- ${src}"
    return 0
  fi
  log_warn "${name} not found after installer"
  return 1
}

copied=0
copy_cli nemoclaw && copied=1 || true
copy_cli openshell && copied=1 || true
copy_cli openclaw && copied=1 || true
copy_cli openshell-gateway || true
copy_cli openshell-sandbox || true
copy_cli openshell-driver-vm || true
if [[ "$copied" != "1" || ! -x "${BIN}/openshell-driver-vm" ]]; then
  log_warn "Downloading pinned OpenShell ${OPENSHELL_TAG} into vendor/nemoclaw/bin"
  vendor_openshell_release
  copy_cli openshell && copied=1 || true
  copy_cli openshell-gateway || true
  copy_cli openshell-sandbox || true
  copy_cli openshell-driver-vm || true
fi
[[ "$copied" == "1" ]] || die "No CLIs found after installer. Check ${LOGF}"

PYTHONPATH="${PROJECT_DIR}${PYTHONPATH:+:$PYTHONPATH}" \
  "${PROJECT_DIR}/.venv/bin/python" - <<'PY' 2>/dev/null || true
from app.db import get_session
from app.services.nemoclaw import audit_cli
db = get_session()
try:
    audit_cli(db, event_type="nemoclaw.fetch", request_in={"source": "vendor/nemoclaw"}, status_code=200)
finally:
    db.close()
PY

log_ok "Local copy ready at ${BIN}"
log_info "Install/start will not download NemoClaw again."
