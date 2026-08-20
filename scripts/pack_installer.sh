#!/usr/bin/env bash
# Freeze this MedLock tree into ~/Desktop/nvdiahackathon.tar.gz plus ./install.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${MEDLOCK_PACK_OUT:-${HOME}/Desktop}"
PACK_VERSION="${MEDLOCK_PACK_VERSION:-1.2}"
ARCHIVE_NAME="nvdiahackathon-v${PACK_VERSION}.tar.gz"
ALIAS_NAME="nvdiahackathon.tar.gz"
BOOTSTRAP_SRC="${PROJECT_DIR}/packaging/install-from-archive"

usage() {
  cat <<'EOF'
Pack a frozen MedLock installer snapshot (code, GGUF, embeddings, venv, llama.cpp).

Usage: ./scripts/pack_installer.sh [--out-dir DIR]

Writes:
  DIR/nvdiahackathon-v1.2.tar.gz
  DIR/nvdiahackathonv1.2.tar.gz  (same file, alias)
  DIR/nvdiahackathon.tar.gz  (same file, alias)
  DIR/nvdiahackathon.gz      (same file, alias)
  DIR/install                (./install nvdiahackathon-v1.2.tar.gz)

Omits .env, .git, .venv, chats/uploads/logs, and __pycache__.
Includes vendor/nemoclaw/ when present (offline NemoClaw/OpenShell CLIs).
The extracted installer creates a fresh .venv in the folder you choose.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" == "--out-dir" ]]; then
  OUT_DIR="${2:?--out-dir requires DIR}"
  shift 2
fi
[[ $# -eq 0 ]] || die "Unknown extra args: $*  (try --help)"

OUT_DIR="${OUT_DIR/#\~/$HOME}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
[[ -f "$BOOTSTRAP_SRC" ]] || die "Missing $BOOTSTRAP_SRC"

ARCHIVE="${OUT_DIR}/${ARCHIVE_NAME}"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/medlock-pack.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

log_step "Packing frozen installer"
log_info "Source: ${PROJECT_DIR}"
log_info "Output: ${ARCHIVE}"

mkdir -p "${STAGE}/nvdiahackathon"
if have_cmd rsync; then
  rsync -a \
    --exclude='.env' \
    --exclude='.git/' \
    --exclude='y/.git/' \
    --exclude='y/' \
    --exclude='.venv/' \
    --exclude='__pycache__/' \
    --exclude='*.pyc' \
    --exclude='*.pyo' \
    --exclude='data/*.sqlite' \
    --exclude='data/*.sqlite-*' \
    --exclude='data/uploads/*' \
    --exclude='logs/*' \
    --exclude='*.pid' \
    --exclude='.cache/' \
    --exclude='tmp/' \
    "${PROJECT_DIR}/" "${STAGE}/nvdiahackathon/"
else
  die "rsync is required to pack the installer"
fi
# Keep empty runtime dirs in the snapshot.
mkdir -p "${STAGE}/nvdiahackathon/data/uploads" "${STAGE}/nvdiahackathon/logs"
: > "${STAGE}/nvdiahackathon/data/uploads/.gitkeep"
: > "${STAGE}/nvdiahackathon/logs/.gitkeep"

tar -czf "$ARCHIVE" -C "$STAGE" nvdiahackathon
chmod 644 "$ARCHIVE"

for alias_name in "$ALIAS_NAME" "nvdiahackathon.gz" "nvdiahackathon-v${PACK_VERSION}.gz" "nvdiahackathonv${PACK_VERSION}.tar.gz"; do
  alias_path="${OUT_DIR}/${alias_name}"
  rm -f "$alias_path"
  ln -s "$ARCHIVE_NAME" "$alias_path"
done

install -m 0755 "$BOOTSTRAP_SRC" "${OUT_DIR}/install"
install -m 0755 "$BOOTSTRAP_SRC" "${OUT_DIR}/install.sh"

size="$(bytes_to_human "$(stat -c%s "$ARCHIVE")")"
log_ok "Wrote ${ARCHIVE} (${size})"
log_ok "Wrote aliases: ${ALIAS_NAME}, nvdiahackathon.gz"
log_ok "Wrote ${OUT_DIR}/install and ${OUT_DIR}/install.sh"
log_info "Install from that folder with:"
log_info "  cd ${OUT_DIR} && ./install.sh ${ARCHIVE_NAME}"
log_info "  or: ./install.sh ${ALIAS_NAME}"
