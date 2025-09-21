#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${BASE_DIR%/scripts}"

# Load shared envs if present
if [ -f "${BASE_DIR}/env.sh" ]; then
  # shellcheck disable=SC1090
  source "${BASE_DIR}/env.sh"
fi

# Load TTS envs
# shellcheck disable=SC1090
source "${BASE_DIR}/env.sh"

export PATH="${CUDA_PREFIX:-/usr/local/cuda}/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

echo "[main] Starting TTS provisioning and server startup"

bash "${BASE_DIR}/01_install_tts_server.sh"

echo "[main] Running GPU diagnostics"
bash "${BASE_DIR}/07_gpu_diagnostics.sh"

bash "${BASE_DIR}/02_fetch_tts_configs.sh"

UV_BIN="$(command -v uv || true)"
if [ -n "$UV_BIN" ]; then
  echo "[main] Starting server via uv run --locked (Docker parity)"
  (cd "$ROOT_DIR" && uv run --locked "${BASE_DIR}/03_start_tts_server.sh")
else
  echo "[main] uv not found; starting server directly"
  bash "${BASE_DIR}/03_start_tts_server.sh"
fi

echo "[main] Setting up test dependencies"
bash "${BASE_DIR}/04_setup_test_deps.sh"

echo "[main] Running smoke test"
bash "${BASE_DIR}/05_tts_smoke_test.sh"

echo "[main] Verifying configuration"
bash "${BASE_DIR}/06_verify_config.sh"

echo "[main] Done. Server should be up at ws://${TTS_ADDR}:${TTS_PORT}"
