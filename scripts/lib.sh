#!/usr/bin/env bash
# Shared helpers for MedLock installer scripts. Safe to source repeatedly.

if [[ -n "${MEDLOCK_LIB_LOADED:-}" ]]; then
  return 0
fi
MEDLOCK_LIB_LOADED=1

# Disable color when stdout is not a TTY or NO_COLOR is set (accessible default).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
else
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

log_info()  { printf '%s[INFO]%s %s\n'  "${C_BLUE}" "${C_RESET}" "$*"; }
log_ok()    { printf '%s[ OK ]%s %s\n'  "${C_GREEN}" "${C_RESET}" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n'  "${C_YELLOW}" "${C_RESET}" "$*"; }
log_error() { printf '%s[FAIL]%s %s\n'  "${C_RED}" "${C_RESET}" "$*" >&2; }
log_step()  { printf '\n%s==>%s %s%s%s\n' "${C_CYAN}" "${C_RESET}" "${C_BOLD}" "$*" "${C_RESET}"; }

die() {
  trap - ERR
  log_error "$*"
  exit 1
}

script_dir() {
  local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  cd "$(dirname "$src")" && pwd
}

repo_root_from_scripts() {
  cd "$(script_dir)/.." && pwd
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

in_docker_group() {
  local user="${1:-${USER:-$(id -un)}}"
  local members
  members="$(getent group docker 2>/dev/null | awk -F: '{print $4}')" || return 1
  [[ ",${members}," == *",${user},"* ]]
}

# Run docker even in this login session, before the docker group has taken effect.
medlock_docker() {
  have_cmd docker || return 127
  if docker info >/dev/null 2>&1; then
    docker "$@"
    return $?
  fi
  if in_docker_group; then
    sg docker -c "docker $(printf '%q ' "$@")"
    return $?
  fi
  if have_cmd sudo; then
    sudo docker "$@"
    return $?
  fi
  docker "$@"
}

confirm() {
  # confirm "question"  -> returns 0 on yes
  local prompt="${1:-Continue?}"
  local reply
  if [[ "${MEDLOCK_YES:-0}" == "1" ]]; then
    log_info "${prompt} [auto-yes]"
    return 0
  fi
  if [[ "${MEDLOCK_NONINTERACTIVE:-0}" == "1" ]]; then
    log_warn "${prompt} [non-interactive: no]"
    return 1
  fi
  read -r -p "${prompt} [y/N] " reply
  [[ "${reply}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

require_file() {
  [[ -f "$1" ]] || die "Required file missing: $1"
}

chmod_secret() {
  local path="$1"
  if [[ -f "$path" ]]; then
    chmod 600 "$path" || log_warn "Could not chmod 600 $path"
  fi
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

bytes_to_human() {
  local bytes="${1:-0}"
  if have_cmd numfmt; then
    numfmt --to=iec --suffix=B "$bytes" 2>/dev/null && return 0
  fi
  awk -v b="$bytes" 'BEGIN {
    split("B KB MB GB TB", u, " ");
    i=1; while (b>=1024 && i<5) { b/=1024; i++ }
    printf "%.1f%s\n", b, u[i]
  }'
}

wait_for_http() {
  local url="$1"
  local timeout="${2:-90}"
  local elapsed=0
  while (( elapsed < timeout )); do
    if have_cmd curl && curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

tcp_port_free() {
  local host="${1:-127.0.0.1}"
  local port="${2:?}"
  python3 - "$host" "$port" <<'PY'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind((host, port))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

# Stop leftover listeners on host:port so this run can bind (systemd restart vs old uvicorn).
reclaim_tcp_port() {
  local host="${1:-127.0.0.1}"
  local port="${2:?}"
  local n
  if tcp_port_free "$host" "$port"; then
    return 0
  fi
  log_warn "Port ${port} is already in use; stopping leftover MedLock process so this instance can start"
  if have_cmd pkill; then
    pkill -f "uvicorn app.main:app" >/dev/null 2>&1 || true
  fi
  if have_cmd fuser; then
    fuser -k "${port}/tcp" >/dev/null 2>&1 || true
  fi
  if have_cmd lsof; then
    lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null | xargs -r kill >/dev/null 2>&1 || true
  fi
  python3 - "$port" <<'PY' || true
import glob, os, signal, sys
port = int(sys.argv[1])
needle = f"{port:04X}"
inodes = set()
for path in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        lines = open(path, encoding="utf-8").read().splitlines()[1:]
    except OSError:
        continue
    for line in lines:
        parts = line.split()
        if len(parts) < 10 or parts[3] != "0A":
            continue
        if parts[1].rsplit(":", 1)[-1].upper() == needle:
            inodes.add(parts[9])
for fd in glob.glob("/proc/[0-9]*/fd/[0-9]*"):
    try:
        dest = os.readlink(fd)
    except OSError:
        continue
    if dest.startswith("socket:[") and dest[8:-1] in inodes:
        try:
            os.kill(int(fd.split("/")[2]), signal.SIGTERM)
        except OSError:
            pass
PY
  for n in 1 2 3 4 5 6; do
    if tcp_port_free "$host" "$port"; then
      return 0
    fi
    sleep 0.5
  done
  if have_cmd pkill; then
    pkill -9 -f "uvicorn app.main:app" >/dev/null 2>&1 || true
  fi
  sleep 0.5
  tcp_port_free "$host" "$port"
}
