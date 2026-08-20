#!/usr/bin/env bash
# MedLock local enterprise installer. Idempotent for models/venv; runtime data is reset unless --keep-data.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ./install.sh testingv1.4.tar.gz → unpack the archive (asks where to save).
if [[ -n "${1:-}" && "$1" != -* ]]; then
  _archive_arg="$1"
  _archive=""
  for _cand in \
    "$_archive_arg" \
    "${PWD}/${_archive_arg}" \
    "${HOME}/Desktop/${_archive_arg}" \
    "${SCRIPT_DIR}/${_archive_arg}"; do
    if [[ -f "$_cand" ]]; then
      _archive="$_cand"
      break
    fi
  done
  if [[ -n "$_archive" ]] && tar -tzf "$_archive" >/dev/null 2>&1; then
    _bootstrap="${SCRIPT_DIR}/packaging/install-from-archive"
    if [[ ! -f "$_bootstrap" ]]; then
      _bootstrap="${HOME}/Desktop/install"
    fi
    if [[ ! -f "$_bootstrap" ]]; then
      printf '[FAIL] Missing archive installer (packaging/install-from-archive)\n' >&2
      exit 1
    fi
    exec bash "$_bootstrap" "$_archive" "${@:2}"
  fi
  unset _archive_arg _archive _cand _bootstrap
fi

# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"

FAILED_COMMAND=""
trap 'ec=$?; log_error "install.sh failed at line ${LINENO}: ${FAILED_COMMAND:-$BASH_COMMAND} (exit ${ec})"; exit "$ec"' ERR
trap 'FAILED_COMMAND=$BASH_COMMAND' DEBUG

PROJECT_DIR="${SCRIPT_DIR}"
MODEL_DIR="${HOME}/models"
MODEL_PATH=""
LLAMACPP_DIR="${HOME}/llama.cpp"
DOWNLOAD_MODELS=0
NONINTERACTIVE=0
OFFLINE=0
WITH_SYSTEMD=""
TEST_SERVICENOW=0
REPAIR=0
YES=0
SKIP_NEMOCLAW=0
START_AFTER=1
KEEP_DATA=0
FRESH=0
WITH_HOSTS=0
SELF_CONTAINED=0
LLAMACPP_DIR_CLI=0
MODEL_DIR_CLI=0
CLI_WORKSPACE=""
CLI_DATA_DIR=""
CLI_OWNER_USER=""
CLI_OWNER_PASSWORD=""
CHAT_HOSTNAME="${CHAT_HOSTNAME:-medlock.chat}"
ADMIN_HOSTNAME="${ADMIN_HOSTNAME:-medlock.admin}"
HF_LLM_REPO="bartowski/Qwen2.5-0.5B-Instruct-GGUF"
HF_LLM_FILE="Qwen2.5-0.5B-Instruct-Q4_K_M.gguf"
HF_LLM_SIZE="~400 MB"
BUNDLED_MODEL_REL="llm/qwen2.5-0.5b/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf"

usage() {
  cat <<'EOF'
MedLock installer — local LLM, local embeddings, local RAG. No cloud inference.
Installs a background user service. Desktop icon opens the UI only.
Frozen-archive installs (--self-contained) keep app, venv, models, chats, and logs
in the folder you chose. Direct ./install.sh still asks for a workspace folder.

Usage: ./install.sh [options]
       ./install.sh testingv1.4.tar.gz   unpack archive, then install (asks where to save)

  --project-dir PATH     Install / reuse this tree (default: directory of install.sh)
  --model-dir PATH       Directory to search/store GGUF files (default: ~/models)
  --model-path PATH      Exact GGUF file to use
  --llamacpp-dir PATH    llama.cpp prefix (default: ~/llama.cpp)
  --download-models      Permit Hugging Face download of the bundled Qwen 0.5B GGUF if missing
  --non-interactive      Never prompt; fail instead of downloading or using sudo
  --offline              Forbid network downloads and external checks
  --with-systemd         Install and enable a user-level systemd unit (default)
  --without-systemd      Do not install a systemd unit
  --test-servicenow      Validate optional ServiceNow env vars (never prints secrets)
  --repair               Non-destructive repair / upgrade of an existing install
  --yes                  Auto-approve prompts (sudo hosts, Docker, NemoClaw, systemd, reinstall)
  --skip-nemoclaw        Do not onboard or start NemoClaw / OpenShell (opt-out)
  --with-nemoclaw        Onboard from vendor/nemoclaw after the LLM is healthy (default)
  --with-hosts           Ask to add medlock.chat / medlock.admin to /etc/hosts (sudo)
  --start                After install, open the MedLock desktop UI (default)
  --no-start             Install only; do not launch MedLock.sh
  --keep-data            Keep existing chats/uploads (default wipes runtime data)
  --fresh                Wipe chats/uploads and re-ask workspace + data folder (no REINSTALL prompt)
  --self-contained       Keep chats, logs, venv, and llama.cpp inside this project folder
  --workspace NAME       Workspace / organization name (skips the name prompt)
  --data-dir PATH        Parent folder for chats/uploads (skips Browse…)
  --owner-user NAME      Owner username (skips the owner prompt)
  --owner-password PASS  Owner password (min 8; not written to .env)
  --help                 Show this help

Incompatible:
  --offline cannot be combined with --download-models
  --with-systemd cannot be combined with --without-systemd
  --non-interactive will not download models unless --download-models is also set
  --non-interactive will not run sudo / Docker / NemoClaw / systemd enable unless --yes is set
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-dir) PROJECT_DIR="${2:?--project-dir requires PATH}"; shift 2 ;;
      --model-dir) MODEL_DIR="${2:?--model-dir requires PATH}"; MODEL_DIR_CLI=1; shift 2 ;;
      --model-path) MODEL_PATH="${2:?--model-path requires PATH}"; shift 2 ;;
      --llamacpp-dir) LLAMACPP_DIR="${2:?--llamacpp-dir requires PATH}"; LLAMACPP_DIR_CLI=1; shift 2 ;;
      --download-models) DOWNLOAD_MODELS=1; shift ;;
      --non-interactive) NONINTERACTIVE=1; shift ;;
      --offline) OFFLINE=1; shift ;;
      --with-systemd) WITH_SYSTEMD="yes"; shift ;;
      --without-systemd) WITH_SYSTEMD="no"; shift ;;
      --test-servicenow) TEST_SERVICENOW=1; shift ;;
      --repair) REPAIR=1; shift ;;
      --yes) YES=1; shift ;;
      --skip-nemoclaw) SKIP_NEMOCLAW=1; shift ;;
      --with-nemoclaw) SKIP_NEMOCLAW=0; shift ;;
      --with-hosts) WITH_HOSTS=1; shift ;;
      --start) START_AFTER=1; shift ;;
      --no-start) START_AFTER=0; shift ;;
      --keep-data) KEEP_DATA=1; shift ;;
      --fresh) FRESH=1; KEEP_DATA=0; shift ;;
      --self-contained) SELF_CONTAINED=1; shift ;;
      --workspace) CLI_WORKSPACE="${2:?--workspace requires NAME}"; shift 2 ;;
      --data-dir) CLI_DATA_DIR="${2:?--data-dir requires PATH}"; shift 2 ;;
      --owner-user) CLI_OWNER_USER="${2:?--owner-user requires NAME}"; shift 2 ;;
      --owner-password) CLI_OWNER_PASSWORD="${2:?--owner-password requires PASS}"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown flag: $1  (try --help)" ;;
    esac
  done

  mkdir -p "$PROJECT_DIR"
  PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
  if [[ "$SELF_CONTAINED" == "1" ]]; then
    [[ "$MODEL_DIR_CLI" == "1" ]] || MODEL_DIR="${PROJECT_DIR}/models"
    [[ "$LLAMACPP_DIR_CLI" == "1" ]] || LLAMACPP_DIR="${PROJECT_DIR}/llama.cpp"
  fi
  MODEL_DIR="${MODEL_DIR/#\~/$HOME}"
  LLAMACPP_DIR="${LLAMACPP_DIR/#\~/$HOME}"
  if [[ -n "$MODEL_PATH" ]]; then
    MODEL_PATH="${MODEL_PATH/#\~/$HOME}"
  fi
  CLI_MODEL_PATH="$MODEL_PATH"

  if [[ "$OFFLINE" == "1" && "$DOWNLOAD_MODELS" == "1" ]]; then
    die "--offline cannot be combined with --download-models"
  fi
  if [[ "$WITH_SYSTEMD" == "yes" && "$WITH_SYSTEMD" == "no" ]]; then
    die "internal flag error"
  fi
  # the two systemd flags are mutually exclusive via last-writer; detect both passed:
  :

  if [[ -n "$CLI_DATA_DIR" ]]; then
    CLI_DATA_DIR="${CLI_DATA_DIR/#\~/$HOME}"
  fi

  export PROJECT_DIR MODEL_DIR MODEL_PATH LLAMACPP_DIR CLI_MODEL_PATH
  export MEDLOCK_NONINTERACTIVE="$NONINTERACTIVE"
  export MEDLOCK_OFFLINE="$OFFLINE"
  export MEDLOCK_YES="$YES"
  export MEDLOCK_SKIP_NEMOCLAW="$SKIP_NEMOCLAW"
  export CHAT_HOSTNAME ADMIN_HOSTNAME
}

# Detect if both systemd flags were passed (parse_args overwrites). Re-scan.
validate_systemd_flags() {
  local with=0 without=0
  local a
  for a in "${ORIG_ARGS[@]}"; do
    [[ "$a" == "--with-systemd" ]] && with=1
    [[ "$a" == "--without-systemd" ]] && without=1
  done
  if [[ "$with" == "1" && "$without" == "1" ]]; then
    die "--with-systemd cannot be combined with --without-systemd"
  fi
  if [[ -z "$WITH_SYSTEMD" ]]; then
    WITH_SYSTEMD="yes"
  fi
}

os_pretty() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s\n' "${PRETTY_NAME:-$ID $VERSION_ID}"
  else
    uname -a
  fi
}

preflight() {
  log_step "Preflight (no system changes yet)"
  local fail=0

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${VERSION_ID:-}" in
      22.04|24.04) log_ok "Ubuntu ${VERSION_ID}" ;;
      *) log_warn "Expected Ubuntu 22.04 or 24.04, found ${PRETTY_NAME:-unknown}. Continuing." ;;
    esac
  else
    log_warn "Not an os-release Linux; continuing anyway"
  fi

  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|aarch64|arm64) log_ok "CPU architecture ${arch}" ;;
    *) log_error "Unsupported architecture ${arch}"; fail=1 ;;
  esac

  local disk_kb ram_kb
  disk_kb="$(df -Pk "$PROJECT_DIR" | awk 'NR==2{print $4}')"
  ram_kb="$(awk '/MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  log_info "Free disk on project volume: $(bytes_to_human $((disk_kb * 1024)))"
  log_info "Available RAM: $(bytes_to_human $((ram_kb * 1024)))"
  if (( disk_kb < 8 * 1024 * 1024 )); then
    log_warn "Less than 8 GiB free disk. GGUF + venv may not fit."
  fi
  if (( ram_kb < 4 * 1024 * 1024 )); then
    log_warn "Less than 4 GiB available RAM. Inference may fail or spill to disk."
  fi

  if have_cmd nvidia-smi; then
    if nvidia-smi >/dev/null 2>&1; then
      log_ok "nvidia-smi responded"
    else
      log_warn "nvidia-smi present but failed; CPU fallback for llama.cpp"
    fi
  else
    log_warn "nvidia-smi not found; CPU fallback"
  fi

  local py=""
  local c
  for c in python3.11 python3.12 python3.10 python3; do
    if have_cmd "$c"; then
      py="$c"
      break
    fi
  done
  if [[ -z "$py" ]]; then
    log_error "Python 3.11 (or 3.10+) is required. Install: sudo apt-get install -y python3.11 python3.11-venv python3.11-dev"
    fail=1
  else
    local ver
    ver="$($py -c 'import sys; print("%d.%d"%sys.version_info[:2])')"
    log_ok "Python ${ver} via ${py}"
    echo "$py" > "${PROJECT_DIR}/.python-cmd.tmp"
  fi

  local req=(git curl wget jq)
  local opt=(cmake make gcc g++ docker)
  local r
  for r in "${req[@]}"; do
    if have_cmd "$r"; then
      log_ok "$r"
    else
      log_error "Missing required command: $r"
      fail=1
    fi
  done
  for r in "${opt[@]}"; do
    if have_cmd "$r"; then
      log_ok "$r (optional)"
    else
      log_warn "Optional command missing: $r"
    fi
  done
  if ! have_cmd docker; then
    log_info "Docker is not installed yet. This install will install Docker Engine (sudo) so Postgres can run."
  fi

  if [[ "$OFFLINE" != "1" && "$DOWNLOAD_MODELS" == "1" ]]; then
    if ! curl -fsS --max-time 8 https://huggingface.co >/dev/null 2>&1; then
      log_error "Network check to huggingface.co failed; cannot --download-models"
      fail=1
    else
      log_ok "Network reachable (huggingface.co)"
    fi
  fi

  if [[ "$fail" == "1" ]]; then
    die "Preflight failed. Fix the items marked FAIL and re-run."
  fi
}

pick_python() {
  if [[ -f "${PROJECT_DIR}/.python-cmd.tmp" ]]; then
    cat "${PROJECT_DIR}/.python-cmd.tmp"
    rm -f "${PROJECT_DIR}/.python-cmd.tmp"
    return 0
  fi
  command -v python3.11 || command -v python3
}

venv_is_local() {
  local venv="$1"
  local pybin="${venv}/bin/python"
  [[ -x "$pybin" ]] || return 1
  "$pybin" - "$PROJECT_DIR" "$venv" <<'PY'
import os, sys
project = os.path.realpath(sys.argv[1])
venv = os.path.realpath(sys.argv[2])
prefix = os.path.realpath(sys.prefix)
if prefix != venv and not prefix.startswith(project + os.sep):
    raise SystemExit(1)
bin_dir = os.path.join(venv, "bin")
for name in os.listdir(bin_dir):
    path = os.path.join(bin_dir, name)
    if os.path.islink(path):
        target = os.path.realpath(path)
        if target.startswith(project + os.sep) or target.startswith("/usr") or target.startswith("/bin"):
            continue
        if "nvdiahackathon" in target or "site-packages" in target:
            raise SystemExit(1)
        if os.path.dirname(os.path.dirname(target)) != venv and "python" in name:
            # python -> /usr/bin/python3 is fine; python -> other tree venv is not
            if "/.venv/" in target and not target.startswith(venv + os.sep):
                raise SystemExit(1)
    elif os.path.isfile(path):
        try:
            with open(path, "rb") as fh:
                first = fh.readline()
        except OSError:
            continue
        if not first.startswith(b"#!"):
            continue
        shebang = first[2:].decode("utf-8", "replace").strip().split()[0]
        if shebang.startswith("/") and "/.venv/" in shebang and not shebang.startswith(venv + os.sep):
            raise SystemExit(1)
print("ok")
PY
}

setup_venv() {
  log_step "Python virtual environment"
  local py
  py="$(pick_python)"
  local venv="${PROJECT_DIR}/.venv"
  if venv_is_local "$venv"; then
    log_ok "Reusing ${venv}"
  else
    if [[ -e "$venv" ]]; then
      log_warn "Copied or foreign .venv detected — creating a new one in ${PROJECT_DIR}"
      rm -rf "$venv"
    else
      log_info "Creating ${venv}"
    fi
    "$py" -m venv "$venv"
  fi
  "${venv}/bin/python" -m pip install --upgrade pip setuptools wheel
  require_file "${PROJECT_DIR}/requirements.txt"
  "${venv}/bin/python" -m pip install -r "${PROJECT_DIR}/requirements.txt"
  if [[ -f "${PROJECT_DIR}/requirements-embeddings.txt" && "${OFFLINE:-0}" != "1" ]]; then
    "${venv}/bin/python" -m pip install -r "${PROJECT_DIR}/requirements-embeddings.txt" \
      || log_warn "Optional embeddings extra failed; RAG will use a local lexical fallback. Later: pip install -r requirements-embeddings.txt"
  fi
  "${venv}/bin/python" - <<'PY'
mods = ["fastapi", "uvicorn", "httpx", "yaml", "sqlalchemy", "dotenv", "huggingface_hub", "pypdf", "PIL"]
failed = []
for m in mods:
    name = "yaml" if m == "yaml" else m
    try:
        __import__(name)
    except Exception as exc:
        failed.append(f"{m}: {exc}")
if failed:
    raise SystemExit("Import verification failed:\n  " + "\n  ".join(failed))
print("imports ok:", ", ".join(mods))
PY
  if "${venv}/bin/python" -c "import webview" >/dev/null 2>&1; then
    log_ok "pywebview available (desktop window)"
  else
    log_warn "pywebview import failed; desktop launcher prefers Chromium/Chrome --app="
  fi
  log_ok "Python environment ready"
}

random_secret() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
}

ensure_env() {
  log_step "Environment file"
  local envf="${PROJECT_DIR}/.env"
  local example="${PROJECT_DIR}/.env.example"
  require_file "$example"
  if [[ ! -f "$envf" ]]; then
    cp "$example" "$envf"
    local llama_key admin_token pg_pass
    llama_key="$(random_secret)"
    admin_token="$(random_secret)"
    pg_pass="$(random_secret)"
    session_secret="$(random_secret)"
    # portable in-place env updates
    python3 - "$envf" "$PROJECT_DIR" "$MODEL_DIR" "$LLAMACPP_DIR" "$llama_key" "$admin_token" "$pg_pass" "$CHAT_HOSTNAME" "$ADMIN_HOSTNAME" "$session_secret" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
vals = {
    "PROJECT_DIR": sys.argv[2],
    "MODEL_DIR": sys.argv[3],
    "LLAMACPP_DIR": sys.argv[4],
    "LLAMA_API_KEY": sys.argv[5],
    "MEDLOCK_ADMIN_TOKEN": sys.argv[6],
    "POSTGRES_PASSWORD": sys.argv[7],
    "NEMOCLAW_LLAMACPP_LOCAL_TOKEN": sys.argv[5],
    "CHAT_HOSTNAME": sys.argv[8],
    "ADMIN_HOSTNAME": sys.argv[9],
    "MEDLOCK_SESSION_SECRET": sys.argv[10],
}
text = path.read_text()
out = []
for line in text.splitlines():
    if not line or line.startswith("#") or "=" not in line:
        out.append(line)
        continue
    k, _, _ = line.partition("=")
    if k in vals:
        out.append(f"{k}={vals[k]}")
    else:
        out.append(line)
# DATABASE_URL
url = f"postgresql+psycopg://medlock:{vals['POSTGRES_PASSWORD']}@127.0.0.1:5432/medlock"
fixed = []
for line in out:
    if line.startswith("DATABASE_URL="):
        fixed.append(f"DATABASE_URL={url}")
    elif line.startswith("POSTGRES_PASSWORD="):
        fixed.append(f"POSTGRES_PASSWORD={vals['POSTGRES_PASSWORD']}")
    else:
        fixed.append(line)
path.write_text("\n".join(fixed) + "\n")
PY
    chmod_secret "$envf"
    log_ok "Wrote ${envf} (mode 600)"
  else
    log_ok "Keeping existing ${envf}"
    python3 - "$envf" "$example" <<'PY'
from pathlib import Path
import sys
env, example = Path(sys.argv[1]), Path(sys.argv[2])
existing = env.read_text(encoding="utf-8")
keys = set()
for line in existing.splitlines():
    if line and not line.lstrip().startswith("#") and "=" in line:
        keys.add(line.split("=", 1)[0].strip())
extra = []
for line in example.read_text(encoding="utf-8").splitlines():
    if not line or line.lstrip().startswith("#") or "=" not in line:
        continue
    k = line.split("=", 1)[0].strip()
    if k not in keys:
        extra.append(line)
if extra:
    env.write_text(existing.rstrip() + "\n" + "\n".join(extra) + "\n", encoding="utf-8")
PY
    chmod_secret "$envf"
  fi
  python3 - "$envf" "$(random_secret)" <<'PY'
from pathlib import Path
import sys
path, secret = Path(sys.argv[1]), sys.argv[2]
text = path.read_text(encoding="utf-8") if path.is_file() else ""
lines = []
found = False
for line in text.splitlines():
    if line.startswith("MEDLOCK_SESSION_SECRET="):
        val = line.split("=", 1)[1].strip()
        if not val or val == "change-me":
            lines.append(f"MEDLOCK_SESSION_SECRET={secret}")
        else:
            lines.append(line)
        found = True
    else:
        lines.append(line)
if not found:
    lines.append(f"MEDLOCK_SESSION_SECRET={secret}")
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
  chmod_secret "$envf"
  set -a
  # shellcheck disable=SC1090
  source "$envf"
  set +a
}

maybe_reinstall_wipe() {
  if [[ "$FRESH" == "1" ]]; then
    KEEP_DATA=0
  fi
  if [[ "$KEEP_DATA" == "1" || "$REPAIR" == "1" ]]; then
    log_info "Keeping existing chats and uploads (--keep-data / --repair)"
    return 0
  fi
  local prior=0
  [[ -f "${PROJECT_DIR}/.env" ]] && prior=1
  [[ -x "${PROJECT_DIR}/.venv/bin/python" ]] && prior=1
  [[ -d "${HOME}/MedLock" ]] && [[ -n "$(find "${HOME}/MedLock" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)" ]] && prior=1
  if [[ "$prior" != "1" && "$FRESH" != "1" ]]; then
    "${SCRIPT_DIR}/scripts/reset_runtime_data.sh" "$PROJECT_DIR"
    return 0
  fi
  log_step "Existing MedLock install detected"
  log_warn "Reinstall replaces the previous MedLock on this account."
  log_warn "Chats and uploads in the previous data folder will be deleted. Models and .venv are kept."
  local typed=""
  if [[ "$FRESH" == "1" || "$YES" == "1" || "${CI:-}" == "1" ]]; then
    typed="REINSTALL"
  elif [[ "$NONINTERACTIVE" == "1" ]]; then
    die "Existing install found. Re-run with --fresh or --yes to replace it, or --keep-data / --repair to keep chats."
  else
    read -r -p "Type REINSTALL to replace the previous install: " typed
  fi
  if [[ "$typed" != "REINSTALL" ]]; then
    die "Install aborted. Pass --fresh to wipe chats, --keep-data to keep them, or type REINSTALL."
  fi
  if have_cmd systemctl; then
    systemctl --user stop local-enterprise-agent.service 2>/dev/null || true
  fi
  "${SCRIPT_DIR}/scripts/reset_runtime_data.sh" "$PROJECT_DIR" --purge-home
  unset MEDLOCK_DATA MEDLOCK_DATA_ROOT MEDLOCK_WORKSPACE WORKSPACE_NAME || true
}

pin_workspace() {
  log_step "Workspace name and data folder"
  if [[ "$SELF_CONTAINED" == "1" ]]; then
    local label="${CLI_WORKSPACE:-$(basename "$PROJECT_DIR")}"
    mkdir -p "$PROJECT_DIR"/{data/uploads,data/documents,logs,backups}
    export MEDLOCK_WORKSPACE="$label"
    export MEDLOCK_DATA="$PROJECT_DIR"
    export MEDLOCK_DATA_ROOT="$(dirname "$PROJECT_DIR")"
    python3 - "$PROJECT_DIR/.env" "$label" "$PROJECT_DIR" "$MEDLOCK_DATA_ROOT" <<'PY'
from pathlib import Path
import sys
path, name, data, parent = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
text = path.read_text(encoding="utf-8") if path.is_file() else ""
mapping = {
    "MEDLOCK_WORKSPACE": name,
    "MEDLOCK_DATA": data,
    "MEDLOCK_DATA_ROOT": parent,
}
lines = []
seen = set()
for line in text.splitlines():
    if line and not line.lstrip().startswith("#") and "=" in line:
        key = line.split("=", 1)[0].strip()
        if key in mapping:
            lines.append(f"{key}={mapping[key]}")
            seen.add(key)
            continue
    lines.append(line)
for key, value in mapping.items():
    if key not in seen:
        lines.append(f"{key}={value}")
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
try:
    path.chmod(0o600)
except OSError:
    pass
PY
    log_ok "Everything in this folder: ${PROJECT_DIR}"
    return 0
  fi
  if [[ -n "$CLI_WORKSPACE" ]]; then
    export MEDLOCK_WORKSPACE="$CLI_WORKSPACE"
  fi
  if [[ -n "$CLI_DATA_DIR" ]]; then
    export MEDLOCK_DATA_ROOT="$CLI_DATA_DIR"
  fi
  local root
  if [[ "$KEEP_DATA" == "1" || "$REPAIR" == "1" ]] && [[ -n "${MEDLOCK_DATA:-}" && -n "${MEDLOCK_WORKSPACE:-}" ]]; then
    root="$MEDLOCK_DATA"
    log_ok "Keeping workspace ${MEDLOCK_WORKSPACE} → ${root}"
    return 0
  fi
  root="$(
    cd "$PROJECT_DIR"
    PYTHONPATH="${PROJECT_DIR}${PYTHONPATH:+:$PYTHONPATH}" \
      "${PROJECT_DIR}/.venv/bin/python" - <<'PY'
from app.workspace import ask_setup, prepare, upsert_env
from pathlib import Path
import os
name, parent = ask_setup()
root = prepare(name, parent=parent)
upsert_env(
    Path(os.environ["PROJECT_DIR"]) / ".env",
    {
        "MEDLOCK_WORKSPACE": root.name,
        "MEDLOCK_DATA": str(root),
        "MEDLOCK_DATA_ROOT": str(parent),
    },
)
print(root)
PY
  )"
  [[ -n "$root" ]] || die "Workspace setup failed"
  export MEDLOCK_DATA="$root"
  export MEDLOCK_WORKSPACE="$(basename "$root")"
  export MEDLOCK_DATA_ROOT="$(dirname "$root")"
  log_ok "Workspace ${MEDLOCK_WORKSPACE} → ${MEDLOCK_DATA}"
}

ensure_owner() {
  log_step "Owner account"
  local py="${PROJECT_DIR}/.venv/bin/python"
  [[ -x "$py" ]] || die "Python venv missing; cannot create owner account"
  export PROJECT_DIR
  if [[ -n "${MEDLOCK_DATA:-}" ]]; then
    export MEDLOCK_DATA
  fi
  if "$py" "${SCRIPT_DIR}/scripts/create_owner.py" --check >/dev/null; then
    log_ok "Owner account already exists"
    return 0
  fi
  if [[ -n "$CLI_OWNER_USER" || -n "$CLI_OWNER_PASSWORD" ]]; then
    [[ -n "$CLI_OWNER_USER" && -n "$CLI_OWNER_PASSWORD" ]] || die "Need both --owner-user and --owner-password"
    [[ ${#CLI_OWNER_PASSWORD} -ge 8 ]] || die "Owner password must be at least 8 characters"
    "$py" "${SCRIPT_DIR}/scripts/create_owner.py" --username "$CLI_OWNER_USER" --password "$CLI_OWNER_PASSWORD"
    unset CLI_OWNER_PASSWORD
    log_ok "Created owner ${CLI_OWNER_USER}"
    return 0
  fi
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    die "No owner account. Re-run with --owner-user and --owner-password."
  fi
  local assignments
  assignments="$(python3 "${SCRIPT_DIR}/scripts/prompt_owner.py")" || die "Owner account is required"
  eval "$assignments"
  [[ -n "${MEDLOCK_OWNER_USER:-}" && -n "${MEDLOCK_OWNER_PASSWORD:-}" ]] || die "Owner prompt returned no credentials"
  "$py" "${SCRIPT_DIR}/scripts/create_owner.py" --username "$MEDLOCK_OWNER_USER" --password "$MEDLOCK_OWNER_PASSWORD"
  unset MEDLOCK_OWNER_PASSWORD
  log_ok "Created owner ${MEDLOCK_OWNER_USER}"
}

find_existing_gguf() {
  local p
  local bundled="${PROJECT_DIR}/${BUNDLED_MODEL_REL}"
  [[ -n "${MODEL_PATH:-}" && -f "$MODEL_PATH" ]] && { printf '%s\n' "$MODEL_PATH"; return 0; }
  if [[ -f "$bundled" ]]; then
    printf '%s\n' "$bundled"
    return 0
  fi
  local search_roots=(
    "${PROJECT_DIR}/llm/qwen2.5-0.5b"
    "${PROJECT_DIR}/llm"
    "${PROJECT_DIR}/llm/medgemma-1.5-4b-it"
    "$MODEL_DIR"
    "${PROJECT_DIR}/models"
  )
  local root
  for root in "${search_roots[@]}"; do
    [[ -d "$root" ]] || continue
    p="$(find "$root" -type f -name '*.gguf' ! -name 'mmproj*' 2>/dev/null | head -n 1 || true)"
    if [[ -n "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

find_mmproj() {
  local dir
  dir="$(dirname "${MODEL_PATH}")"
  find "$dir" -maxdepth 2 -type f -iname '*mmproj*.gguf' 2>/dev/null | head -n 1 || true
}

resolve_model() {
  log_step "Local LLM (GGUF)"
  if MODEL_PATH="$(find_existing_gguf)"; then
    log_ok "Found GGUF: ${MODEL_PATH}"
  else
    cat <<EOF
No local GGUF found.

  Default model : Qwen2.5 0.5B Instruct (bundled lightweight CPU model)
  Source        : https://huggingface.co/${HF_LLM_REPO}
  File          : ${HF_LLM_FILE}
  Size          : ${HF_LLM_SIZE} (approx)
  License       : Apache-2.0 — review the Hugging Face model card before download
  Dest          : ${PROJECT_DIR}/${BUNDLED_MODEL_REL}

Upload a larger GGUF (MedGemma, Gemma 4, …) later from the admin hub, or pass --model-path.
EOF
    if [[ "$OFFLINE" == "1" ]]; then
      die "--offline and no local GGUF. Copy a model into ${PROJECT_DIR}/llm/ and re-run."
    fi
    log_info "Fetching bundled ${HF_LLM_FILE} (${HF_LLM_SIZE}) — this is the default if you do not pick a model"
    export HF_LLM_REPO HF_LLM_FILE MODEL_DIR PROJECT_DIR
    export LLM_DIR="${PROJECT_DIR}/llm/qwen2.5-0.5b"
    MEDLOCK_YES=1 "${SCRIPT_DIR}/scripts/prefetch_models.sh"
    MODEL_PATH="${PROJECT_DIR}/${BUNDLED_MODEL_REL}"
    [[ -f "$MODEL_PATH" ]] || die "Bundled GGUF download failed: ${MODEL_PATH}"
  fi
  export MODEL_PATH
  MMPROJ_PATH="$(find_mmproj || true)"
  export MMPROJ_PATH
  if [[ -n "$MODEL_PATH" ]]; then
    python3 "${SCRIPT_DIR}/scripts/check_models.py" --model-path "$MODEL_PATH" --pretty || die "GGUF failed validation"
  fi
  # persist into .env without printing secrets
  python3 - "$PROJECT_DIR/.env" "${MODEL_PATH}" "${MODEL_DIR}" "${MMPROJ_PATH:-}" "${LLAMACPP_DIR}" <<'PY'
from pathlib import Path
import sys
env, model, model_dir, mmproj, llama = sys.argv[1:]
p = Path(env)
lines = []
mapping = {
    "MODEL_PATH": model,
    "MODEL_DIR": model_dir,
    "MMPROJ_PATH": mmproj,
    "LLAMACPP_DIR": llama,
    "EMBEDDING_MODEL_PATH": str(Path(sys.argv[1]).parent / "models" / "embeddings" / "bge-small-en-v1.5"),
}
# EMBEDDING path relative to project
from pathlib import Path as P
proj = P(sys.argv[1]).parent
mapping["EMBEDDING_MODEL_PATH"] = str(proj / "models" / "embeddings" / "bge-small-en-v1.5")
mapping["PROJECT_DIR"] = str(proj)
seen = set()
for line in p.read_text().splitlines():
    if "=" in line and not line.startswith("#"):
        k = line.split("=", 1)[0]
        if k in mapping:
            lines.append(f"{k}={mapping[k]}")
            seen.add(k)
            continue
    lines.append(line)
for k, v in mapping.items():
    if k not in seen:
        lines.append(f"{k}={v}")
p.write_text("\n".join(lines) + "\n")
PY
}

setup_llamacpp() {
  log_step "llama.cpp"
  export LLAMACPP_DIR
  mkdir -p "$(dirname "$LLAMACPP_DIR")"
  if [[ ! -x "${LLAMACPP_DIR}/build/bin/llama-server" && -x "${HOME}/llama.cpp/build/bin/llama-server" ]]; then
    local home_llama dest_llama
    home_llama="$(cd "$HOME/llama.cpp" && pwd)"
    mkdir -p "$LLAMACPP_DIR"
    dest_llama="$(cd "$LLAMACPP_DIR" && pwd)"
    if [[ "$home_llama" != "$dest_llama" ]]; then
      log_info "Copying llama.cpp into ${LLAMACPP_DIR}"
      if have_cmd rsync; then
        rsync -a "${HOME}/llama.cpp/" "${LLAMACPP_DIR}/"
      else
        cp -a "${HOME}/llama.cpp/." "${LLAMACPP_DIR}/"
      fi
    fi
  fi
  local bin
  bin="$(LLAMACPP_DIR="$LLAMACPP_DIR" "${SCRIPT_DIR}/scripts/setup_llamacpp.sh" | tail -n 1)"
  export LLAMA_SERVER_BIN="$bin"
  python3 - "$PROJECT_DIR/.env" "$bin" "$LLAMACPP_DIR" <<'PY'
from pathlib import Path
import sys
env, bin_path, llama_dir = sys.argv[1:]
p = Path(env)
out = []
seen = set()
mapping = {"LLAMA_SERVER_BIN": bin_path, "LLAMACPP_DIR": llama_dir}
for line in p.read_text().splitlines():
    if "=" in line and not line.startswith("#"):
        k = line.split("=", 1)[0]
        if k in mapping:
            out.append(f"{k}={mapping[k]}")
            seen.add(k)
            continue
    out.append(line)
for k, v in mapping.items():
    if k not in seen:
        out.append(f"{k}={v}")
p.write_text("\n".join(out) + "\n")
PY
  log_ok "llama-server = ${LLAMA_SERVER_BIN}"
}

write_config() {
  log_step "Local config"
  set -a
  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"
  set +a
  local force=()
  if [[ "$REPAIR" == "1" ]]; then
    force=(--force)
  fi
  "${PROJECT_DIR}/.venv/bin/python" "${SCRIPT_DIR}/scripts/create_local_config.py" --project-dir "$PROJECT_DIR" "${force[@]}"
}

install_desktop() {
  log_step "Desktop launcher"
  local f
  for f in MedLock.sh start.sh run.sh install.sh verify_install.sh uninstall.sh; do
    if [[ -f "${PROJECT_DIR}/$f" ]]; then
      chmod +x "${PROJECT_DIR}/$f"
    fi
  done
  chmod +x "${PROJECT_DIR}/scripts/"*.sh 2>/dev/null || true
  if [[ -x "${PROJECT_DIR}/.venv/bin/python" && -f "${PROJECT_DIR}/packaging/MedLock.desktop" ]]; then
    (
      cd "$PROJECT_DIR"
      PYTHONPATH="${PROJECT_DIR}${PYTHONPATH:+:$PYTHONPATH}" \
        "${PROJECT_DIR}/.venv/bin/python" -c \
        "from pathlib import Path; from app.workspace import _install_shortcut; _install_shortcut(Path('.').resolve())"
    ) && log_ok "Desktop shortcut: ${HOME}/Desktop/MedLock.desktop"
  else
    log_warn "Could not write MedLock.desktop (missing venv or packaging/MedLock.desktop)"
  fi
}

install_systemd() {
  [[ "$WITH_SYSTEMD" == "yes" ]] || return 0
  log_step "systemd user unit"
  local src="${PROJECT_DIR}/systemd/local-enterprise-agent.service"
  local dest="${HOME}/.config/systemd/user/local-enterprise-agent.service"
  require_file "$src"
  mkdir -p "$(dirname "$dest")" "${PROJECT_DIR}/logs"
  local data_dir="${MEDLOCK_DATA:-${HOME}/MedLock}"
  sed -e "s|__PROJECT_DIR__|${PROJECT_DIR}|g" \
      -e "s|__USER__|${USER}|g" \
      -e "s|__DATA_DIR__|${data_dir}|g" \
      "$src" > "$dest"
  systemctl --user daemon-reload || log_warn "systemctl --user daemon-reload failed (ok if no user systemd)"
  log_ok "Installed ${dest}"
  local enable_now=0
  if [[ "$YES" == "1" ]]; then
    enable_now=1
  elif [[ "$NONINTERACTIVE" == "1" ]]; then
    log_warn "Unit installed but not enabled (pass --yes to enable in non-interactive mode)"
  elif confirm "Enable and start the MedLock background service now?"; then
    enable_now=1
  fi
  if [[ "$enable_now" == "1" ]]; then
    systemctl --user enable --now local-enterprise-agent.service
    log_ok "Enabled and started user service (survives closing the window)"
    if have_cmd loginctl; then
      if loginctl enable-linger "$USER" 2>/dev/null; then
        log_ok "Linger enabled so MedLock can start after logout"
      else
        log_info "Could not enable linger (optional). After reboot, log in once or run: loginctl enable-linger $USER"
      fi
    fi
  fi
}

test_servicenow() {
  [[ "$TEST_SERVICENOW" == "1" ]] || return 0
  log_step "ServiceNow (optional)"
  set -a
  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"
  set +a
  if [[ "${SERVICENOW_ENABLED:-false}" != "true" ]]; then
    log_warn "SERVICENOW_ENABLED is not true; skipping live test (this is the safe default)"
    return 0
  fi
  local missing=0
  for k in SERVICENOW_INSTANCE_URL SERVICENOW_CLIENT_ID SERVICENOW_CLIENT_SECRET; do
    if [[ -z "${!k:-}" ]]; then
      log_error "$k is empty"
      missing=1
    else
      log_ok "$k is set (value hidden)"
    fi
  done
  [[ "$missing" == "0" ]] || die "ServiceNow test failed: missing variables"
}

print_report() {
  log_step "Install report"
  cat <<EOF
  OS            : $(os_pretty)
  Arch          : $(uname -m)
  Project       : ${PROJECT_DIR}
  venv          : ${PROJECT_DIR}/.venv
  llama.cpp     : ${LLAMACPP_DIR}
  llama-server  : ${LLAMA_SERVER_BIN:-unknown}
  GGUF          : ${MODEL_PATH:-NONE — upload via admin hub}
  Config        : ${PROJECT_DIR}/config/local.yaml
  Chat window   : ./MedLock.sh  (opens UI; servers keep running)
  Workspace     : ${MEDLOCK_WORKSPACE:-MedLock}  (${MEDLOCK_DATA:-$PROJECT_DIR})
  Browser       : http://127.0.0.1:${MEDLOCK_PORT:-8000}/  (sign in with the owner account)
  Admin         : http://127.0.0.1:${MEDLOCK_PORT:-8000}/admin  (same owner login)
  API           : http://127.0.0.1:${MEDLOCK_PORT:-8000}/v1/chat/completions
  llama.cpp     : http://127.0.0.1:8081/v1  (loopback, API key required)
  Desktop icon  : ~/Desktop/MedLock.desktop  (Allow Launching the first time)
  Stop service  : systemctl --user stop local-enterprise-agent

Next:
  Already opening ./MedLock.sh unless you passed --no-start
  Closing the window or terminal leaves MedLock running in the background
EOF
}

main() {
  ORIG_ARGS=("$@")
  parse_args "$@"
  validate_systemd_flags

  log_step "MedLock installer"
  log_info "Project dir: ${PROJECT_DIR}"
  if [[ "$REPAIR" == "1" ]]; then
    log_info "Repair mode: non-destructive reuse of venv, models, and config"
  fi

  preflight
  "${SCRIPT_DIR}/scripts/bootstrap_directories.sh" "$PROJECT_DIR"
  maybe_reinstall_wipe
  if [[ -x "${PROJECT_DIR}/.venv/bin/python" ]]; then
    python3 "${SCRIPT_DIR}/scripts/check_gpu.py" --pretty || true
  else
    python3 "${SCRIPT_DIR}/scripts/check_gpu.py" --pretty || true
  fi
  setup_venv
  ensure_env
  pin_workspace
  if [[ -n "${CLI_MODEL_PATH:-}" ]]; then
    MODEL_PATH="$CLI_MODEL_PATH"
    export MODEL_PATH
  fi
  setup_llamacpp
  resolve_model
  write_config
  set -a
  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"
  set +a
  "${SCRIPT_DIR}/scripts/setup_docker.sh" || log_warn "Docker setup skipped; Postgres may use sqlite until Docker or a local server is ready."
  if ! "${SCRIPT_DIR}/scripts/setup_postgres.sh"; then
    log_warn "Postgres not ready. App can start later after Docker is running or you follow the printed apt commands."
  fi
  ensure_owner
  if [[ "$WITH_HOSTS" == "1" ]]; then
    CHAT_HOSTNAME="$CHAT_HOSTNAME" ADMIN_HOSTNAME="$ADMIN_HOSTNAME" "${SCRIPT_DIR}/scripts/setup_hosts.sh" || log_warn "hosts setup skipped"
  else
    log_info "Skipping /etc/hosts (use --with-hosts for medlock.chat). Serving on 127.0.0.1"
  fi
  install_desktop
  install_systemd
  test_servicenow
  print_report
  if [[ "$START_AFTER" == "1" ]]; then
    log_ok "Install finished. Starting MedLock..."
    trap - ERR DEBUG
    exec "${SCRIPT_DIR}/MedLock.sh"
  fi
  log_ok "Install finished. Open ./MedLock.sh for the UI. Servers stay up via systemd unless you passed --without-systemd."
}

main "$@"
