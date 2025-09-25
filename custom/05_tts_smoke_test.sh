#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${BASE_DIR%/scripts}"
source "${BASE_DIR}/env.sh"

SERVER="${YAP_PUBLIC_WS_URL:-ws://${YAP_CLIENT_HOST:-127.0.0.1}:${TTS_PORT}}"
# Send the relative voice key understood by the server (not an absolute path)
# Use the precomputed embedding for 1.6B model instead of .wav
VOICE_KEY="${TTS_VOICE:-ears/p058/freeform_speech_01.wav.1e68beda@240.safetensors}"
OUT="${ROOT_DIR}/.data/warmup/warmup.wav"
mkdir -p "$(dirname "$OUT")"

# Set default API key if not already set
: "${KYUTAI_API_KEY:=public_token}"
export KYUTAI_API_KEY

echo "[smoke] Server: $SERVER"
echo "[smoke] Voice:  $VOICE_KEY"
echo "[smoke] Out:    $OUT"
echo "[smoke] Using existing config: ${TTS_CONFIG}"

# Use the venv created in 01_install_tts_server.sh at repo root
"${ROOT_DIR}/.venv/bin/python" "${ROOT_DIR}/test/warmup.py" \
  --server "${SERVER#ws://}" \
  --voice "${VOICE_KEY}" \
  --text "Hey, how are you?"