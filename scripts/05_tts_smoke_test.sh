#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${BASE_DIR%/scripts}"
source "${BASE_DIR}/env.sh"

SERVER="${YAP_PUBLIC_WS_URL:-ws://${YAP_CLIENT_HOST:-127.0.0.1}:${TTS_PORT}}"
VOICE="${VOICES_DIR:-${ROOT_DIR}/.data/voices}/${TTS_VOICE:-ears/p004/freeform_speech_01.wav}"
OUT="${ROOT_DIR}/.data/warmup/warmup.wav"
mkdir -p "$(dirname "$OUT")"

# Set default API key if not already set
: "${KYUTAI_API_KEY:=public_token}"
export KYUTAI_API_KEY

echo "[smoke] Server: $SERVER"
echo "[smoke] Voice:  $VOICE"
echo "[smoke] Out:    $OUT"

# Use the venv created in 01_install_tts_server.sh at repo root
"${ROOT_DIR}/.venv/bin/python" "${ROOT_DIR}/test/warmup.py" \
  --server "${SERVER#ws://}" \
  --voice "${VOICE}" \
  --text "Hey, how are you?"