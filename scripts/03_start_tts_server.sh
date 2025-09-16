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

log_info "$SCRIPT_NAME" "Preparing environment"

export PATH="${CUDA_PREFIX:-/usr/local/cuda}/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
export CUDARC_NVRTC_PATH="${CUDARC_NVRTC_PATH:-${CUDA_PREFIX:-/usr/local/cuda}/lib64/libnvrtc.so}"
export HF_HOME HF_HUB_ENABLE_HF_TRANSFER

# Setup server environment variables
setup_server_environment "$SCRIPT_NAME"

CFG="${TTS_CONFIG}"
LOG_DIR="${TTS_LOG_DIR}"
SESSION="${TTS_TMUX_SESSION}"
PORT="${TTS_PORT}"
ADDR="${TTS_ADDR}"
PYTHON_BIN="${ROOT_DIR}/.venv/bin/python"
ensure_dir "${LOG_DIR}"

log_info "$SCRIPT_NAME" "Starting moshi TTS server (local build)…"
log_info "$SCRIPT_NAME" "Using config: ${CFG}"
log_info "$SCRIPT_NAME" "ROOT_DIR: ${ROOT_DIR}"

# Debug: Show voice and model configuration
log_info "$SCRIPT_NAME" "Voice & model config lines:"
grep -nE 'hf_repo|n_q|batch_size|voice_folder|default_voice|text_tokenizer_file|cfg_is_no_text|padding_between|cfg_coef|log_folder|hf-snapshot' "${CFG}" >&2 || log_info "$SCRIPT_NAME" "No relevant config found"
log_info "$SCRIPT_NAME" "Reusing config at ${CFG} (no re-generation here)"

# Validate all required voices are available before starting server
log_info "$SCRIPT_NAME" "Validating all required voices are available..."
if ! validate_all_voices "$SCRIPT_NAME" "$VOICES_DIR"; then
    log_error "$SCRIPT_NAME" "Required voices missing. Please run 02_fetch_tts_configs.sh first."
    exit 1
fi

# Verify specific voice embedding exists
if ! verify_voice_embedding "$SCRIPT_NAME" "$VOICES_DIR" "$TTS_VOICE"; then
    exit 1
fi

# Show auth configuration so you know if the server requires API keys
log_info "$SCRIPT_NAME" "Auth configuration:"
grep -n 'authorized_ids' "$CFG" >&2 || log_info "$SCRIPT_NAME" "No auth configured (server is open)"

# Setup Python library paths for Rust runtime
setup_python_lib_paths "$SCRIPT_NAME" "$PYTHON_BIN"

# Build local moshi-server binary from the checked-out repo
MOSHI_BIN=$(build_moshi_server "$SCRIPT_NAME" "$ROOT_DIR" "$PYTHON_BIN")
if [ $? -ne 0 ] || [ ! -x "$MOSHI_BIN" ]; then
    log_error "$SCRIPT_NAME" "Failed to build moshi-server"
    exit 1
fi

# Start server using tmux or nohup
LOG_FILE="${LOG_DIR}/tts-server.log"
if start_server_tmux "$SCRIPT_NAME" "$SESSION" "$MOSHI_BIN" "$CFG" "$ADDR" "$PORT" "$ROOT_DIR" "$LOG_FILE"; then
    log_success "$SCRIPT_NAME" "Server started in tmux session"
elif start_server_nohup "$SCRIPT_NAME" "$MOSHI_BIN" "$CFG" "$ADDR" "$PORT" "$ROOT_DIR" "$LOG_FILE"; then
    log_success "$SCRIPT_NAME" "Server started with nohup"
else
    log_error "$SCRIPT_NAME" "Failed to start server"
    exit 1
fi

# Wait for server to be ready
if ! wait_for_server_ready "$SCRIPT_NAME" "$PORT" 180 "$LOG_FILE"; then
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
