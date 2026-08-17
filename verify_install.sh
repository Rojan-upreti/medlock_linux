#!/usr/bin/env bash
# Verify a MedLock install. Prints PASS / WARN / FAIL and exits nonzero on FAIL.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"

PROJECT_DIR="${PROJECT_DIR:-$SCRIPT_DIR}"
PASS=0
WARN=0
FAIL=0

record() {
  local level="$1"; shift
  case "$level" in
    PASS) PASS=$((PASS + 1)); log_ok "$*" ;;
    WARN) WARN=$((WARN + 1)); log_warn "$*" ;;
    FAIL) FAIL=$((FAIL + 1)); log_error "$*" ;;
  esac
}

log_step "MedLock verify_install"

if [[ -x "${PROJECT_DIR}/.venv/bin/python" ]]; then
  record PASS "virtualenv exists: ${PROJECT_DIR}/.venv"
else
  record FAIL "virtualenv missing. Run ./install.sh"
fi

if [[ -f "${PROJECT_DIR}/app/main.py" ]]; then
  record PASS "application entrypoint app/main.py"
else
  record FAIL "app/main.py missing"
fi

if [[ -f "${PROJECT_DIR}/requirements.txt" ]]; then
  record PASS "requirements.txt present"
else
  record FAIL "requirements.txt missing"
fi

if [[ -x "${PROJECT_DIR}/.venv/bin/python" ]]; then
  if "${PROJECT_DIR}/.venv/bin/python" - <<'PY'
mods = ["fastapi", "uvicorn", "httpx", "yaml", "sqlalchemy", "huggingface_hub", "pypdf", "PIL"]
failed = []
for m in mods:
    name = m
    try:
        __import__(name)
    except Exception as exc:
        failed.append(f"{name}: {exc}")
if failed:
    raise SystemExit("; ".join(failed))
PY
  then
    record PASS "required Python imports"
  else
    record FAIL "Python imports failed. From ${PROJECT_DIR}: .venv/bin/pip install -r requirements.txt"
  fi
  if "${PROJECT_DIR}/.venv/bin/python" -c "import webview" >/dev/null 2>&1; then
    record PASS "pywebview import (desktop window)"
  else
    record WARN "pywebview missing or failed to import; desktop app falls back to Chromium --app="
  fi
fi

CFG="${PROJECT_DIR}/config/local.yaml"
if [[ -f "$CFG" ]]; then
  PYBIN="${PROJECT_DIR}/.venv/bin/python"
  [[ -x "$PYBIN" ]] || PYBIN="python3"
  if "$PYBIN" - "$CFG" <<'PY'
import sys, yaml
from pathlib import Path
cfg = yaml.safe_load(Path(sys.argv[1]).read_text()) or {}
inf = cfg.get("inference") or {}
ok = inf.get("mode") == "local" and inf.get("allow_cloud_llm") is False
emb = (cfg.get("embeddings") or {}).get("mode") == "local"
if not ok:
    raise SystemExit("cloud LLM not blocked")
if not emb:
    raise SystemExit("embeddings are not local")
print("ok")
PY
  then
    record PASS "config exists and blocks cloud LLM inference"
  else
    record FAIL "config/local.yaml permits cloud LLM or is invalid"
  fi
else
  record FAIL "config/local.yaml missing"
fi

if [[ -f "${PROJECT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"
  set +a
  mode="$(stat -c '%a' "${PROJECT_DIR}/.env" 2>/dev/null || stat -f '%OLp' "${PROJECT_DIR}/.env")"
  if [[ "$mode" == "600" || "$mode" == "400" ]]; then
    record PASS ".env permissions ${mode}"
  else
    record WARN ".env permissions are ${mode} (expected 600). chmod 600 ${PROJECT_DIR}/.env"
  fi
else
  record FAIL ".env missing"
fi

if [[ -n "${MODEL_PATH:-}" && -f "${MODEL_PATH}" ]]; then
  if python3 "${PROJECT_DIR}/scripts/check_models.py" --model-path "$MODEL_PATH" >/dev/null; then
    record PASS "LLM GGUF valid: ${MODEL_PATH}"
  else
    record FAIL "LLM GGUF failed validation: ${MODEL_PATH}"
  fi
else
  record FAIL "MODEL_PATH missing or not a file. Upload a GGUF in the admin hub or pass --model-path"
fi

if [[ -n "${EMBEDDING_MODEL_PATH:-}" && -e "${EMBEDDING_MODEL_PATH}" ]]; then
  record PASS "embedding path present: ${EMBEDDING_MODEL_PATH}"
else
  record WARN "embedding model not on disk; lexical fallback will be used until prefetch"
fi

if python3 "${PROJECT_DIR}/scripts/check_gpu.py" >/tmp/medlock-gpu.json 2>/dev/null; then
  if python3 - <<'PY'
import json
d=json.load(open("/tmp/medlock-gpu.json"))
raise SystemExit(0 if d.get("nvidia_gpu_present") else 3)
PY
  then
    record PASS "NVIDIA GPU visible via nvidia-smi"
  else
    record WARN "No NVIDIA GPU. CPU fallback is allowed."
  fi
else
  record WARN "GPU probe failed; CPU fallback"
fi

for d in logs data data/documents data/uploads config backups packaging; do
  if [[ -d "${PROJECT_DIR}/$d" && -w "${PROJECT_DIR}/$d" ]]; then
    record PASS "writable ${d}/"
  else
    record FAIL "not writable: ${PROJECT_DIR}/$d"
  fi
done

if [[ -x "${PROJECT_DIR}/MedLock.sh" ]]; then
  record PASS "desktop launcher MedLock.sh"
else
  record FAIL "MedLock.sh missing or not executable. chmod +x MedLock.sh or re-run ./install.sh"
fi

if [[ -f "${PROJECT_DIR}/packaging/MedLock.desktop" ]]; then
  record PASS "desktop shortcut template packaging/MedLock.desktop"
else
  record FAIL "packaging/MedLock.desktop missing"
fi

if [[ -f "${PROJECT_DIR}/app/desktop.py" ]]; then
  record PASS "desktop window helper app/desktop.py"
else
  record FAIL "app/desktop.py missing"
fi

if [[ -f "${PROJECT_DIR}/systemd/local-enterprise-agent.service" ]]; then
  if grep -q '__DATA_DIR__' "${PROJECT_DIR}/systemd/local-enterprise-agent.service"; then
    record PASS "systemd unit template has data-dir placeholder"
  else
    record FAIL "systemd/local-enterprise-agent.service missing __DATA_DIR__"
  fi
else
  record FAIL "systemd/local-enterprise-agent.service missing"
fi

if [[ -d "${HOME}/MedLock" && -w "${HOME}/MedLock" ]]; then
  record PASS "writable default folder ${HOME}/MedLock"
fi

if [[ -n "${MEDLOCK_DATA:-}" ]]; then
  if [[ -d "${MEDLOCK_DATA}" && -w "${MEDLOCK_DATA}" ]]; then
    record PASS "writable data dir ${MEDLOCK_DATA}"
  else
    record WARN "MEDLOCK_DATA is set but not writable yet: ${MEDLOCK_DATA}"
  fi
else
  record WARN "MEDLOCK_DATA unset; run ./install.sh and choose a folder"
fi

UNIT="${HOME}/.config/systemd/user/local-enterprise-agent.service"
if [[ -f "$UNIT" ]]; then
  record PASS "systemd user unit installed"
  if have_cmd systemctl && systemctl --user is-enabled --quiet local-enterprise-agent.service 2>/dev/null; then
    record PASS "systemd unit enabled"
  else
    record WARN "systemd unit not enabled. ./install.sh --with-systemd --yes"
  fi
  if have_cmd systemctl && systemctl --user is-active --quiet local-enterprise-agent.service 2>/dev/null; then
    record PASS "systemd unit active"
  else
    record WARN "systemd unit not running. systemctl --user start local-enterprise-agent"
  fi
else
  record WARN "systemd user unit missing (install with ./install.sh, or you passed --without-systemd)"
fi

if [[ "${SERVICENOW_ENABLED:-false}" == "true" ]]; then
  if [[ -n "${SERVICENOW_INSTANCE_URL:-}" && -n "${SERVICENOW_CLIENT_ID:-}" && -n "${SERVICENOW_CLIENT_SECRET:-}" ]]; then
    record PASS "ServiceNow variables are set (values hidden)"
  else
    record WARN "SERVICENOW_ENABLED=true but some credentials are empty"
  fi
else
  record PASS "ServiceNow disabled (default)"
fi

HEALTH_URL="http://${MEDLOCK_HOST:-127.0.0.1}:${MEDLOCK_PORT:-8000}/health"
if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
  record PASS "application health endpoint ${HEALTH_URL}"
else
  record WARN "health endpoint not responding (start with ./MedLock.sh or: systemctl --user start local-enterprise-agent): ${HEALTH_URL}"
fi

if [[ -n "${LLAMA_SERVER_BIN:-}" && -x "${LLAMA_SERVER_BIN}" ]]; then
  record PASS "llama-server binary ${LLAMA_SERVER_BIN}"
else
  record FAIL "LLAMA_SERVER_BIN missing. Re-run ./install.sh"
fi

echo
printf '%s======== VERIFY REPORT ========%s\n' "${C_BOLD}" "${C_RESET}"
printf '  PASS %s\n  WARN %s\n  FAIL %s\n' "$PASS" "$WARN" "$FAIL"
if (( FAIL > 0 )); then
  log_error "VERIFY FAIL"
  exit 1
fi
if (( WARN > 0 )); then
  log_warn "VERIFY PASS WITH WARNINGS"
  exit 0
fi
log_ok "VERIFY PASS"
exit 0
