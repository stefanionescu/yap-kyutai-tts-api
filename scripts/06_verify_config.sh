#!/usr/bin/env bash
set -euo pipefail

# Load environment and utility modules
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"
source "$SCRIPT_DIR/utils/common.sh"
source "$SCRIPT_DIR/utils/verification.sh"

SCRIPT_NAME="06-verify"

log_info "$SCRIPT_NAME" "Verifying TTS configuration and voice setup"
log_info "$SCRIPT_NAME" "ROOT_DIR: ${ROOT_DIR}"
log_info "$SCRIPT_NAME" "VOICES_DIR: ${VOICES_DIR}"
log_info "$SCRIPT_NAME" "TTS_CONFIG: ${TTS_CONFIG}"

# Run complete verification suite
if run_full_verification "$SCRIPT_NAME" "$TTS_CONFIG" "$VOICES_DIR" "$TTS_PORT" "${TTS_LOG_DIR}/tts-server.log" "$TTS_VOICE"; then
    exit 0
else
    exit 1
fi