#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${BASE_DIR%/scripts}"

# Load shared envs if present
if [ -f "${BASE_DIR}/env.lib.sh" ]; then
  # shellcheck disable=SC1090
  source "${BASE_DIR}/env.lib.sh"
fi

# Load TTS envs
# shellcheck disable=SC1090
source "${BASE_DIR}/env.sh"

export PATH="${CUDA_PREFIX}/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

echo "[main] Starting TTS provisioning and server startup"

"${BASE_DIR}/01_install_tts_server.sh"
"${BASE_DIR}/02_fetch_tts_configs.sh"
"${BASE_DIR}/03_start_tts_server.sh"

if [ "${RUN_SMOKE_TEST:-0}" = "1" ]; then
  echo "[main] Running smoke test"
  "${BASE_DIR}/05_tts_smoke_test.sh" || echo "[main] Smoke test failed (non-fatal)."
fi

echo "[main] Done. Server should be up at ws://${TTS_ADDR}:${TTS_PORT}"
