#!/usr/bin/env bash
set -euo pipefail

# Load environment and utility modules
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"
source "$SCRIPT_DIR/utils/common.sh"
source "$SCRIPT_DIR/utils/hf_operations.sh"
source "$SCRIPT_DIR/utils/voice_management.sh"

SCRIPT_NAME="02-tts"

# Check HF_TOKEN before proceeding with HuggingFace operations
check_hf_token "$SCRIPT_NAME"

log_info "$SCRIPT_NAME" "Validating Docker-parity config usage (no local downloads)"
log_info "$SCRIPT_NAME" "ROOT_DIR: ${ROOT_DIR}"
log_info "$SCRIPT_NAME" "TTS_CONFIG: ${TTS_CONFIG}"

# Use shared config from configs/config.toml
if [ ! -f "${TTS_CONFIG}" ]; then
  log_error "$SCRIPT_NAME" "TTS config not found at ${TTS_CONFIG}. Please add configs/config.toml."
  exit 1
fi

# Do NOT prefetch models or voices; Docker relies on hf:// and hf-snapshot:// at runtime
log_info "$SCRIPT_NAME" "Using config at ${TTS_CONFIG} with hf:// and hf-snapshot:// paths"
log_success "$SCRIPT_NAME" "Config ready"