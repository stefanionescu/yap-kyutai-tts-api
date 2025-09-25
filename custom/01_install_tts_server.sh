#!/usr/bin/env bash
set -euo pipefail

# Load environment and utility modules
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"
source "$SCRIPT_DIR/utils/common.sh"
source "$SCRIPT_DIR/utils/hf_operations.sh"
source "$SCRIPT_DIR/utils/system_setup.sh"

SCRIPT_NAME="01-tts"

# No HF login required at install time (Docker logs in at runtime)

log_info "$SCRIPT_NAME" "Preparing environment and Python deps for local moshi TTS server (Docker parity)…"

export PATH="${CUDA_PREFIX:-/usr/local/cuda}/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

# Install system packages (match docker/Dockerfile)
install_system_packages "$SCRIPT_NAME"

# Setup Rust toolchain
setup_rust_toolchain "$SCRIPT_NAME"

# Setup Python environment with uv (parity with Docker's uv)
setup_python_environment "$SCRIPT_NAME" "$ROOT_DIR"

# Install Python dependencies from pinned uv.lock and add test deps
install_python_deps "$SCRIPT_NAME" "$ROOT_DIR"

# Setup Python library paths for Rust runtime
setup_python_lib_paths "$SCRIPT_NAME" "$ROOT_DIR/.venv/bin/python"

# GCC 15 workaround used by Kyutai
export CXXFLAGS="-include cstdint"

# Install moshi-server (pinned) with CUDA support via cargo (CARGO_TARGET_DIR parity)
log_info "$SCRIPT_NAME" "Installing moshi-server@0.6.3 with CUDA via cargo (parity with docker/start_moshi.sh)"
if ! CARGO_TARGET_DIR="${ROOT_DIR}/target" "$HOME/.cargo/bin/cargo" install --features cuda moshi-server@0.6.3 | cat; then
  log_error "$SCRIPT_NAME" "Failed to install moshi-server@0.6.3"
  exit 1
fi

log_success "$SCRIPT_NAME" "Environment setup complete - moshi-server@0.6.3 installed with CUDA"
