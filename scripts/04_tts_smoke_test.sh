#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "${BASE_DIR}/env.sh" ]; then
  # shellcheck disable=SC1090
  source "${BASE_DIR}/env.sh"
fi
# shellcheck disable=SC1090
source "${BASE_DIR}/env.sh"

DSM_DIR="${DSM_REPO_DIR:-/workspace/delayed-streams-modeling}"
SERVER_URL="${YAP_PUBLIC_WS_URL:-ws://${YAP_CLIENT_HOST:-127.0.0.1}:${TTS_PORT}}"
VOICE_PATH="${VOICES_DIR:-/workspace/voices}/${TTS_VOICE:-ears/p004/freeform_speech_01.wav}"

echo "[smoke] Server: ${SERVER_URL}"
[ -f "${VOICE_PATH}" ] && echo "[smoke] Voice:  ${VOICE_PATH}" || echo "[smoke] Voice not found (will use server default): ${VOICE_PATH}"

# From stdin → speaker (explicit URL). If voice exists, pass it.
if [ -f "${VOICE_PATH}" ]; then
  echo "Hey, how are you?" | uv run "${DSM_DIR}/scripts/tts_rust_server.py" - - --url "${SERVER_URL}" --voice "${VOICE_PATH}"
else
  echo "Hey, how are you?" | uv run "${DSM_DIR}/scripts/tts_rust_server.py" - - --url "${SERVER_URL}"
fi

# Optional: pass a reference voice if your DSM client supports it
# echo "Hello there" | uv run "${DSM_DIR}/scripts/tts_rust_server.py" - - --url "${SERVER_URL}" --voice "${VOICE_PATH}"
# echo "Hello there" | uv run "${DSM_DIR}/scripts/tts_rust_server.py" - - --url "${SERVER_URL}" --reference "${VOICE_PATH}"
