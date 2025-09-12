#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load envs if available
if [ -f "${BASE_DIR}/env.lib.sh" ]; then
  # shellcheck disable=SC1090
  source "${BASE_DIR}/env.lib.sh"
fi
if [ -f "${BASE_DIR}/env.sh" ]; then
  # shellcheck disable=SC1090
  source "${BASE_DIR}/env.sh"
fi

SESSION="${TTS_TMUX_SESSION:-yap-tts}"
TMUX_BIN="${TMUX_BIN:-tmux}"

echo "[stop] Stopping tmux session: ${SESSION}"
${TMUX_BIN} has-session -t "${SESSION}" 2>/dev/null && ${TMUX_BIN} kill-session -t "${SESSION}" || true

# Paths to clean, keeping repo and Jupyter/web console intact
SCRIPT_DIR="${BASE_DIR}"
VOICE_ROOT="${VOICES_DIR:-/workspace/voices}"
DSM_DIR="${DSM_REPO_DIR:-/workspace/delayed-streams-modeling}"

# Remove Python venv and lockfiles/manifests used by uv in scripts/
if [ -d "${SCRIPT_DIR}/.venv" ]; then
  echo "[stop] Removing venv: ${SCRIPT_DIR}/.venv"
  rm -rf "${SCRIPT_DIR}/.venv"
fi
for f in "${SCRIPT_DIR}/pyproject.toml" "${SCRIPT_DIR}/uv.lock"; do
  [ -f "$f" ] && { echo "[stop] Removing $f"; rm -f "$f"; }
done

# Remove downloaded DSM repo clone
if [ -d "${DSM_DIR}" ]; then
  echo "[stop] Removing DSM repo dir: ${DSM_DIR}"
  rm -rf "${DSM_DIR}"
fi

# Remove downloaded voices
if [ -d "${VOICE_ROOT}" ]; then
  echo "[stop] Removing voices dir: ${VOICE_ROOT}"
  rm -rf "${VOICE_ROOT}"
fi

# Clear Hugging Face caches and Kyutai-specific caches
for p in \
  "$HOME/.cache/huggingface" \
  "/root/.cache/huggingface" \
  "$HOME/.cache/torch" \
  "/root/.cache/torch" \
  "$HOME/.cache/uv" \
  "/root/.cache/uv" \
  "$HOME/.cargo/registry" \
  "$HOME/.cargo/git" \
  "$HOME/.cache/moshi" \
  "/workspace/.cache/huggingface"
do
  [ -e "$p" ] && { echo "[stop] Removing cache: $p"; rm -rf "$p"; }
done

# Keep logs by default; delete if requested
if [ "${PURGE_LOGS:-0}" = "1" ]; then
  LOG_DIR="${TTS_LOG_DIR:-/workspace/logs}"
  [ -d "${LOG_DIR}" ] && { echo "[stop] Purging logs in ${LOG_DIR}"; rm -rf "${LOG_DIR}"; }
fi

echo "[stop] Cleanup complete. Repo and Jupyter/web console preserved."
