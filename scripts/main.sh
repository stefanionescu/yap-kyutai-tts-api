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
bash "${BASE_DIR}/02_fetch_tts_configs.sh"
bash "${BASE_DIR}/03_start_tts_server.sh"

echo "[main] Running smoke test"
bash "${BASE_DIR}/04_tts_smoke_test.sh"

echo "[main] Done. Server should be up at ws://${TTS_ADDR}:${TTS_PORT}"
