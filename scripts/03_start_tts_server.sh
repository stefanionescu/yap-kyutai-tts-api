#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

echo "[03-tts] Preparing environment"

export PATH="${CUDA_PREFIX:-/usr/local/cuda}/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
export CUDARC_NVRTC_PATH="${CUDARC_NVRTC_PATH:-${CUDA_PREFIX:-/usr/local/cuda}/lib64/libnvrtc.so}"
export HF_HOME HF_HUB_ENABLE_HF_TRANSFER

CFG="${TTS_CONFIG}"
LOG_DIR="${TTS_LOG_DIR}"
SESSION="${TTS_TMUX_SESSION}"
PORT="${TTS_PORT}"
ADDR="${TTS_ADDR}"
mkdir -p "${LOG_DIR}"

echo "[03-tts] Starting moshi TTS server…"
echo "[03-tts] Using config: ${CFG}"

# Ensure Python libdir is on LD_LIBRARY_PATH for the Rust server
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY_BIN="${SCRIPT_DIR}/.venv/bin/python"
if [ -x "${PY_BIN}" ]; then
  PY_LIBDIR="$(${PY_BIN} - <<'PY'
import sysconfig; print(sysconfig.get_config_var("LIBDIR") or "")
PY
)"
else
  PY_LIBDIR="$(python - <<'PY'
import sysconfig; print(sysconfig.get_config_var("LIBDIR") or "")
PY
)"
fi
if [ -n "${PY_LIBDIR}" ]; then
  export LD_LIBRARY_PATH="${PY_LIBDIR}:${LD_LIBRARY_PATH:-}"
fi

# Prefer tmux; fallback to nohup if tmux not installed
TMUX_BIN="${TMUX_BIN:-tmux}"
if command -v "${TMUX_BIN}" >/dev/null 2>&1; then
  echo "[03-tts] Using tmux session '${SESSION}'"
  ${TMUX_BIN} has-session -t "${SESSION}" 2>/dev/null && ${TMUX_BIN} kill-session -t "${SESSION}"
  ${TMUX_BIN} new-session -d -s "${SESSION}" \
    "cd '${SCRIPT_DIR}' && env LD_LIBRARY_PATH='${LD_LIBRARY_PATH}' uv run --frozen moshi-server worker --config '${CFG}' --addr '${ADDR}' --port '${PORT}' 2>&1 | tee '${LOG_DIR}/tts-server.log'"
else
  echo "[03-tts] tmux not found; using nohup fallback"
  nohup sh -c "cd '${SCRIPT_DIR}' && env LD_LIBRARY_PATH='${LD_LIBRARY_PATH}' uv run --frozen moshi-server worker --config '${CFG}' --addr '${ADDR}' --port '${PORT}'" \
    > "${LOG_DIR}/tts-server.log" 2>&1 &
fi

# Wait for the port to open
for i in $(seq 1 180); do
  (exec 3<>/dev/tcp/127.0.0.1/${PORT}) >/dev/null 2>&1 && { exec 3>&-; break; }
  sleep 1
  if [ $i -eq 180 ]; then
    echo "[03-tts] ERROR: TTS server didn’t open port ${PORT} in time."
    tail -n 50 "${LOG_DIR}/tts-server.log" || true
    exit 1
  fi
done

echo "[03-tts] Bound at ws://${ADDR}:${PORT}"
echo "[03-tts] Logs: ${LOG_DIR}/tts-server.log"
