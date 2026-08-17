#!/usr/bin/env bash
# Create the MedLock directory tree. Idempotent; never deletes user data.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PROJECT_DIR="${1:-${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}}"

dirs=(
  "${PROJECT_DIR}/app"
  "${PROJECT_DIR}/app/routers"
  "${PROJECT_DIR}/app/services"
  "${PROJECT_DIR}/app/static"
  "${PROJECT_DIR}/config"
  "${PROJECT_DIR}/data/uploads"
  "${PROJECT_DIR}/data/documents"
  "${PROJECT_DIR}/data/vectorstore"
  "${PROJECT_DIR}/data/demo_data"
  "${PROJECT_DIR}/packaging"
  "${PROJECT_DIR}/logs"
  "${PROJECT_DIR}/models"
  "${PROJECT_DIR}/models/embeddings"
  "${PROJECT_DIR}/scripts"
  "${PROJECT_DIR}/systemd"
  "${PROJECT_DIR}/backups"
  "${PROJECT_DIR}/db"
  "${PROJECT_DIR}/llm"
  "${PROJECT_DIR}/llm/qwen2.5-0.5b"
  "${PROJECT_DIR}/llm/medgemma-1.5-4b-it"
)

log_step "Creating directory tree under ${PROJECT_DIR}"
for d in "${dirs[@]}"; do
  mkdir -p "$d"
done

keep_files=(
  "${PROJECT_DIR}/data/uploads/.gitkeep"
  "${PROJECT_DIR}/data/documents/.gitkeep"
  "${PROJECT_DIR}/data/vectorstore/.gitkeep"
  "${PROJECT_DIR}/data/demo_data/.gitkeep"
  "${PROJECT_DIR}/logs/.gitkeep"
  "${PROJECT_DIR}/models/.gitkeep"
  "${PROJECT_DIR}/models/embeddings/.gitkeep"
  "${PROJECT_DIR}/backups/.gitkeep"
  "${PROJECT_DIR}/llm/.gitkeep"
  "${PROJECT_DIR}/llm/qwen2.5-0.5b/.gitkeep"
  "${PROJECT_DIR}/llm/medgemma-1.5-4b-it/.gitkeep"
)
for f in "${keep_files[@]}"; do
  [[ -e "$f" ]] || : > "$f"
done

chmod 755 "${PROJECT_DIR}/logs" "${PROJECT_DIR}/data" "${PROJECT_DIR}/config" "${PROJECT_DIR}/backups" 2>/dev/null || true
log_ok "Directory tree ready"
