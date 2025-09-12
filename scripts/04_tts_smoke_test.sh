#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${BASE_DIR%/scripts}"

if [ -f "${BASE_DIR}/env.sh" ]; then
  # shellcheck disable=SC1090
  source "${BASE_DIR}/env.sh"
fi
# shellcheck disable=SC1090
source "${BASE_DIR}/env.sh"

DSM_DIR="${DSM_REPO_DIR:-${ROOT_DIR}/.data/delayed-streams-modeling}"
SERVER_URL="${YAP_PUBLIC_WS_URL:-ws://${YAP_CLIENT_HOST:-127.0.0.1}:${TTS_PORT}}"
VOICE_PATH="${VOICES_DIR:-${ROOT_DIR}/.data/voices}/${TTS_VOICE:-ears/p004/freeform_speech_01.wav}"
OUTPUT_WAV="${ROOT_DIR}/.data/out.wav"

echo "[smoke] Server: ${SERVER_URL}"
[ -f "${VOICE_PATH}" ] && echo "[smoke] Voice:  ${VOICE_PATH}" || echo "[smoke] Voice not found (will use server default): ${VOICE_PATH}"

# Write to WAV (no playback on servers)
mkdir -p "$(dirname "${OUTPUT_WAV}")"
printf "Hey, how are you?\n" > /tmp/tts.txt
# Run from repo root where pyproject.toml/uv.lock are located
cd "${ROOT_DIR}"
if [ -f "${VOICE_PATH}" ]; then
  uv run "${DSM_DIR}/scripts/tts_rust_server.py" \
    /tmp/tts.txt "${OUTPUT_WAV}" \
    --url "${SERVER_URL}" \
    --voice "${VOICE_PATH}"
else
  uv run "${DSM_DIR}/scripts/tts_rust_server.py" \
    /tmp/tts.txt "${OUTPUT_WAV}" \
    --url "${SERVER_URL}"
fi
echo "[smoke] Wrote: ${OUTPUT_WAV}"

# Optional: pass a reference voice if your DSM client supports it
# echo "Hello there" | uv run "${DSM_DIR}/scripts/tts_rust_server.py" - - --url "${SERVER_URL}" --voice "${VOICE_PATH}"
# echo "Hello there" | uv run "${DSM_DIR}/scripts/tts_rust_server.py" - - --url "${SERVER_URL}" --reference "${VOICE_PATH}"
