#!/usr/bin/env bash
# Add 127.0.0.1 CHAT_HOSTNAME ADMIN_HOSTNAME to /etc/hosts. Asks before sudo.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CHAT_HOSTNAME="${CHAT_HOSTNAME:-medlock.chat}"
ADMIN_HOSTNAME="${ADMIN_HOSTNAME:-medlock.admin}"
MARKER="# medlock-local-enterprise-agent"

if grep -qE "[[:space:]]${CHAT_HOSTNAME}([[:space:]]|$)" /etc/hosts 2>/dev/null \
  && grep -qE "[[:space:]]${ADMIN_HOSTNAME}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
  log_ok "/etc/hosts already maps ${CHAT_HOSTNAME} and ${ADMIN_HOSTNAME}"
  exit 0
fi

line="127.0.0.1 ${CHAT_HOSTNAME} ${ADMIN_HOSTNAME} ${MARKER}"
log_info "Proposed /etc/hosts line:"
printf '    %s\n' "$line"

if ! confirm "Add this mapping to /etc/hosts? (requires sudo)"; then
  log_warn "Skipped hosts mapping. Use http://127.0.0.1:PORT/ and http://127.0.0.1:PORT/admin"
  exit 0
fi

have_cmd sudo || die "sudo is not available; add the line to /etc/hosts manually"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# Strip a previous MedLock marker line, then append.
sudo grep -v "${MARKER}" /etc/hosts > "$tmp" || true
printf '%s\n' "$line" >> "$tmp"
sudo cp "$tmp" /etc/hosts
log_ok "Updated /etc/hosts"
