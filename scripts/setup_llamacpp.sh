#!/usr/bin/env bash
# Clone and build llama.cpp into LLAMACPP_DIR. Idempotent.
# On GB10 / DGX Spark uses CMAKE_CUDA_ARCHITECTURES=121.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

LLAMACPP_DIR="${LLAMACPP_DIR:-${1:-$HOME/llama.cpp}}"
OFFLINE="${MEDLOCK_OFFLINE:-0}"
FORCE_REBUILD="${MEDLOCK_FORCE_REBUILD:-0}"
CUDA_ARCH="${MEDLOCK_CUDA_ARCH:-}"

mkdir -p "$(dirname "$LLAMACPP_DIR")"

find_server_bin() {
  local root="$1"
  local candidates=(
    "${root}/build/bin/llama-server"
    "${root}/llama-server"
    "${root}/bin/llama-server"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

log_step "llama.cpp at ${LLAMACPP_DIR}"

if existing="$(find_server_bin "$LLAMACPP_DIR")" && [[ "$FORCE_REBUILD" != "1" ]]; then
  log_ok "Reusing existing llama-server: ${existing}"
  printf '%s\n' "$existing"
  exit 0
fi

if [[ "$OFFLINE" == "1" ]]; then
  die "llama-server not found under ${LLAMACPP_DIR} and --offline forbids cloning. Build llama.cpp first or pass --llamacpp-dir to an existing install."
fi

if [[ ! -d "${LLAMACPP_DIR}/.git" && ! -f "${LLAMACPP_DIR}/CMakeLists.txt" ]]; then
  have_cmd git || die "git is required to clone llama.cpp"
  log_info "Cloning ggml-org/llama.cpp"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMACPP_DIR"
else
  log_info "Source already present; skipping clone"
fi

have_cmd cmake || die "cmake is required to build llama.cpp. Install: sudo apt-get install -y cmake build-essential"
have_cmd make || die "make is required. Install: sudo apt-get install -y build-essential"

cmake_args=( -S "$LLAMACPP_DIR" -B "${LLAMACPP_DIR}/build" -DLLAMA_CURL=OFF -DCMAKE_BUILD_TYPE=Release )
if have_cmd nvcc || have_cmd nvidia-smi; then
  cmake_args+=( -DGGML_CUDA=ON )
  if [[ -z "$CUDA_ARCH" ]] && have_cmd python3; then
    CUDA_ARCH="$(python3 "${SCRIPT_DIR}/check_gpu.py" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('cuda_architectures') or '')" || true)"
  fi
  if [[ -n "$CUDA_ARCH" ]]; then
    cmake_args+=( -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" )
    log_info "CUDA architectures: ${CUDA_ARCH}"
  else
    log_warn "Could not detect CUDA arch; letting CMake default"
  fi
else
  log_warn "No NVIDIA toolchain detected; building CPU-only llama.cpp"
  cmake_args+=( -DGGML_CUDA=OFF )
fi

cmake "${cmake_args[@]}"
cmake --build "${LLAMACPP_DIR}/build" --config Release -j"$(nproc 2>/dev/null || echo 4)" --target llama-server

bin="$(find_server_bin "$LLAMACPP_DIR")" || die "Build finished but llama-server was not found"
log_ok "llama-server ready: ${bin}"
printf '%s\n' "$bin"
