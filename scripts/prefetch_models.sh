#!/usr/bin/env bash
# One-time online prefetch of the bundled Qwen GGUF + embedding model into llm/ and models/.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PROJECT_DIR="${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
MODEL_DIR="${MODEL_DIR:-${PROJECT_DIR}/models}"
LLM_DIR="${LLM_DIR:-${PROJECT_DIR}/llm/qwen2.5-0.5b}"
HF_REPO="${HF_LLM_REPO:-bartowski/Qwen2.5-0.5B-Instruct-GGUF}"
HF_FILE="${HF_LLM_FILE:-Qwen2.5-0.5B-Instruct-Q4_K_M.gguf}"
EMB_REPO="${HF_EMB_REPO:-BAAI/bge-small-en-v1.5}"

mkdir -p "$LLM_DIR" "${MODEL_DIR}/embeddings"

if [[ "${MEDLOCK_OFFLINE:-0}" == "1" ]]; then
  die "prefetch_models.sh cannot run with --offline"
fi

log_step "Prefetch local models"
cat <<EOF
Default LLM
  Hugging Face repo : ${HF_REPO}
  File              : ${HF_FILE}
  Approx size       : ~400 MB
  License           : Apache-2.0 (review the Hugging Face model card before use)
  Destination       : ${LLM_DIR}

Default embeddings
  Hugging Face repo : ${EMB_REPO}
  Approx size       : ~130 MB
  Destination       : ${MODEL_DIR}/embeddings/bge-small-en-v1.5
EOF

if ! confirm "Download these models now?"; then
  die "Download declined"
fi

if [[ -x "${PROJECT_DIR}/.venv/bin/python" ]]; then
  PY="${PROJECT_DIR}/.venv/bin/python"
else
  PY="python3"
fi

"$PY" - <<PY
import os, sys
from pathlib import Path

repo = os.environ.get("HF_LLM_REPO", "${HF_REPO}")
filename = os.environ.get("HF_LLM_FILE", "${HF_FILE}")
dest = Path("${LLM_DIR}")
emb_repo = "${EMB_REPO}"
emb_dest = Path("${MODEL_DIR}/embeddings/bge-small-en-v1.5")

try:
    from huggingface_hub import hf_hub_download, snapshot_download
except ImportError:
    sys.exit("huggingface_hub is not installed. Run install.sh first or: pip install huggingface_hub")

target = dest / filename
if target.exists() and target.stat().st_size > 1_000_000:
    print(f"LLM already present: {target}")
else:
    print(f"Downloading {repo}/{filename} ...")
    path = hf_hub_download(repo_id=repo, filename=filename, local_dir=str(dest))
    print(f"Saved LLM: {path}")

if any(emb_dest.rglob("config.json")):
    print(f"Embedding model already present: {emb_dest}")
else:
    print(f"Downloading {emb_repo} ...")
    snapshot_download(repo_id=emb_repo, local_dir=str(emb_dest))
    print(f"Saved embeddings: {emb_dest}")
PY

log_ok "Prefetch complete"
