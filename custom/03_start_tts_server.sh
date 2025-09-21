#!/usr/bin/env bash
set -euo pipefail

# Load environment and utility modules
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"
source "$SCRIPT_DIR/utils/common.sh"
source "$SCRIPT_DIR/utils/voice_management.sh"
source "$SCRIPT_DIR/utils/server_operations.sh"
source "$SCRIPT_DIR/utils/system_setup.sh"

SCRIPT_NAME="03-tts"

log_info "$SCRIPT_NAME" "Preparing environment (Docker parity)"

export PATH="${CUDA_PREFIX:-/usr/local/cuda}/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
export CUDARC_NVRTC_PATH="${CUDARC_NVRTC_PATH:-${CUDA_PREFIX:-/usr/local/cuda}/lib64/libnvrtc.so}"
export HF_HOME HF_HUB_ENABLE_HF_TRANSFER HF_HUB_DISABLE_XET

# Replicate docker/start_moshi_server_public.sh environment knobs
export CUDA_MODULE_LOADING=${CUDA_MODULE_LOADING:-EAGER}
export RAYON_NUM_THREADS=${RAYON_NUM_THREADS:-1}
export OMP_NUM_THREADS=${OMP_NUM_THREADS:-1}
export MKL_NUM_THREADS=${MKL_NUM_THREADS:-1}
export TOKENIZERS_PARALLELISM=${TOKENIZERS_PARALLELISM:-false}
export CUDA_DEVICE_MAX_CONNECTIONS=${CUDA_DEVICE_MAX_CONNECTIONS:-16}

# No extra env beyond the public start script to keep parity

CFG="${TTS_CONFIG}"
LOG_DIR="${TTS_LOG_DIR}"
SESSION="${TTS_TMUX_SESSION}"
PORT="${TTS_PORT}"
ADDR="${TTS_ADDR}"
PYTHON_BIN="${ROOT_DIR}/.venv/bin/python"
ensure_dir "${LOG_DIR}"

log_info "$SCRIPT_NAME" "Starting moshi TTS server…"
log_info "$SCRIPT_NAME" "Using config: ${CFG}"
log_info "$SCRIPT_NAME" "ROOT_DIR: ${ROOT_DIR}"

# Debug: Show voice and model configuration
log_info "$SCRIPT_NAME" "Voice & model config lines:"
grep -nE 'hf_repo|n_q|batch_size|voice_folder|default_voice|text_tokenizer_file|cfg_is_no_text|padding_between|cfg_coef|log_folder|hf-snapshot' "${CFG}" >&2 || log_info "$SCRIPT_NAME" "No relevant config found"
log_info "$SCRIPT_NAME" "Reusing config at ${CFG} (no re-generation here)"

# Docker flow does not validate local voices; uses hf-snapshot://

# Show auth configuration so you know if the server requires API keys
log_info "$SCRIPT_NAME" "Auth configuration:"
grep -n 'authorized_ids' "$CFG" >&2 || log_info "$SCRIPT_NAME" "No auth configured (server is open)"

# Setup Python library paths for Rust runtime and add CUDA libs (parity)
setup_python_lib_paths "$SCRIPT_NAME" "$PYTHON_BIN"
export LD_LIBRARY_PATH="$("$PYTHON_BIN" - <<'PY'
import sysconfig; print(sysconfig.get_config_var("LIBDIR") or "")
PY
):${CUDA_PREFIX:-/usr/local/cuda}/lib64:${LD_LIBRARY_PATH:-}"

# HuggingFace login (Docker public script logs in unconditionally)
uvx --from 'huggingface_hub[cli]' huggingface-cli login --token "${HUGGING_FACE_HUB_TOKEN:-}" || true

# Install moshi-server at startup like Docker public script
CARGO_TARGET_DIR="${ROOT_DIR}/target" cargo install --features cuda moshi-server@0.6.3 | cat || true
MOSHI_BIN="$HOME/.cargo/bin/moshi-server"

# Start server directly (like docker entrypoint)
LOG_FILE="${LOG_DIR}/tts-server.log"
ulimit -n 1048576 || true

echo "[${SCRIPT_NAME}] Logging to: ${LOG_FILE}"
nohup "$MOSHI_BIN" worker --config "$CFG" --addr "$ADDR" --port "$PORT" \
  > "$LOG_FILE" 2>&1 &

# Wait for server to be ready
if ! wait_for_server_ready "$SCRIPT_NAME" "$PORT" 600 "$LOG_FILE"; then
    exit 1
fi

log_success "$SCRIPT_NAME" "Bound at ws://${ADDR}:${PORT}"
log_info "$SCRIPT_NAME" "Logs: ${LOG_FILE}"

# Show GPU/device initialization logs
show_server_logs "$SCRIPT_NAME" "$LOG_FILE" "CUDA|Cuda|device|loading" 10
log_info "$SCRIPT_NAME" "GPU/device initialization shown above"

# Show voice loading hints from the log  
show_server_logs "$SCRIPT_NAME" "$LOG_FILE" "voice|embedding|p004|safetensors|default_voice" 10
log_info "$SCRIPT_NAME" "Voice loading hints shown above"
