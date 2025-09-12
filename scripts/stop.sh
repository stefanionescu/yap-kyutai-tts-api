#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load envs if available
if [ -f "${BASE_DIR}/env.sh" ]; then
  # shellcheck disable=SC1090
  source "${BASE_DIR}/env.sh"
fi

SESSION="${TTS_TMUX_SESSION:-yap-tts}"
TMUX_BIN="${TMUX_BIN:-tmux}"

echo "[stop] Stopping tmux session: ${SESSION}"
${TMUX_BIN} has-session -t "${SESSION}" 2>/dev/null && ${TMUX_BIN} kill-session -t "${SESSION}" || true

# Also stop moshi-server if it was launched without tmux (nohup fallback)
# Try to match by port first; fall back to a generic worker match
PIDS=""
if command -v pgrep >/dev/null 2>&1; then
  if [ -n "${TTS_PORT:-}" ]; then
    PIDS="$(pgrep -f "moshi-server.*worker.*--port[[:space:]]*${TTS_PORT}")" || true
  fi
  if [ -z "$PIDS" ]; then
    PIDS="$(pgrep -f "moshi-server.*worker")" || true
  fi
else
  PIDS="$(ps aux | grep -E "moshi-server.*worker" | grep -v grep | awk '{print $2}')" || true
fi
if [ -n "$PIDS" ]; then
  echo "[stop] Killing moshi-server PIDs (non-tmux): $PIDS"
  for pid in $PIDS; do
    kill "$pid" 2>/dev/null || true
  done
  sleep 2
  for pid in $PIDS; do
    kill -9 "$pid" 2>/dev/null || true
  done
fi

# Paths to clean, keeping repo and Jupyter/web console intact
SCRIPT_DIR="${BASE_DIR}"
VOICE_ROOT="${VOICES_DIR:-${ROOT_DIR}/.data/voices}"
DSM_DIR="${DSM_REPO_DIR:-${ROOT_DIR}/.data/delayed-streams-modeling}"

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

# Remove smoke-test WAV outputs kept inside repo
TEST_WAV="${ROOT_DIR}/.data/out.wav"
if [ -f "${TEST_WAV}" ]; then
  echo "[stop] Removing smoke-test WAV: ${TEST_WAV}"
  rm -f "${TEST_WAV}"
fi
# Also remove any other top-level WAVs in .data (keeps voices under .data/voices)
if ls "${ROOT_DIR}/.data/"*.wav >/dev/null 2>&1; then
  echo "[stop] Removing top-level WAVs in ${ROOT_DIR}/.data"
  rm -f "${ROOT_DIR}/.data/"*.wav || true
fi

# Clear Hugging Face caches and common caches
# Include variations for HF_HOME and XDG paths
CACHE_PATHS=(
  "$HOME/.cache/huggingface"
  "/root/.cache/huggingface"
  "$HOME/.cache/huggingface_hub"
  "/root/.cache/huggingface_hub"
  "$HOME/.cache/torch"
  "/root/.cache/torch"
  "$HOME/.cache/uv"
  "/root/.cache/uv"
  "$HOME/.cargo/registry"
  "$HOME/.cargo/git"
  "$HOME/.cache/moshi"
  "/workspace/.cache/huggingface"
  "/workspace/.cache/huggingface_hub"
  "/root/.cache/moshi"
  "/workspace/.cache/torch"
  "/workspace/.cache/uv"
  "/workspace/.cache/moshi"
  "$HOME/.cache/pip"
  "/root/.cache/pip"
  "/workspace/.cache/pip"
  "$HOME/.cache/cmake"
  "/root/.cache/cmake"
  "/workspace/.cache/cmake"
)

# Add HF_HOME and XDG_CACHE_HOME if defined
if [ -n "${HF_HOME:-}" ]; then
  CACHE_PATHS+=("${HF_HOME}")
fi
if [ -n "${XDG_CACHE_HOME:-}" ]; then
  CACHE_PATHS+=("${XDG_CACHE_HOME}/huggingface")
fi

for p in "${CACHE_PATHS[@]}"; do
  [ -e "$p" ] && { echo "[stop] Removing cache: $p"; rm -rf "$p"; }
done

# Optionally purge entire cache roots to reclaim more space
for p in "$HOME/.cache" "/root/.cache" "/workspace/.cache"; do
  [ -e "$p" ] && { echo "[stop] Purging cache root: $p"; rm -rf "$p"; }
done

# Remove NVIDIA CUDA compute caches and Torch extensions (can be hundreds of MB)
for p in \
  "$HOME/.nv/ComputeCache" \
  "/root/.nv/ComputeCache" \
  "/var/tmp/nv" \
  "/var/tmp/NVIDIA" \
  "$HOME/.cache/torch_extensions" \
  "/root/.cache/torch_extensions" \
  "/workspace/.cache/torch_extensions"; do
  [ -e "$p" ] && { echo "[stop] Removing GPU/extension cache: $p"; rm -rf "$p"; }
done

# Remove uv's shared data dir and binaries
for p in \
  "$HOME/.local/share/uv" \
  "/root/.local/share/uv" \
  "$HOME/.local/bin/uv" \
  "/root/.local/bin/uv"; do
  [ -e "$p" ] && { echo "[stop] Removing uv data/bin: $p"; rm -rf "$p"; }
done

# Remove installed moshi-server binary to free space (will reinstall on next run)
if [ -f "$HOME/.cargo/bin/moshi-server" ]; then
  echo "[stop] Removing moshi-server binary"
  rm -f "$HOME/.cargo/bin/moshi-server"
fi

# Migration cleanup: legacy external paths used by older defaults
LEGACY_PATHS=(
  "/workspace/voices"
  "/workspace/delayed-streams-modeling"
  "/workspace/logs"
  "${ROOT_DIR}/../server"
)
for p in "${LEGACY_PATHS[@]}"; do
  [ -e "$p" ] && { echo "[stop] Removing legacy path: $p"; rm -rf "$p"; }
done

# Optionally remove Rust toolchains (saves a lot of space on ephemeral pods)
if [ "${PURGE_RUSTUP:-1}" = "1" ] && [ -d "$HOME/.rustup" ]; then
  echo "[stop] Removing rustup toolchains: $HOME/.rustup"
  rm -rf "$HOME/.rustup"
fi

# Clean apt caches if available
if command -v apt-get >/dev/null 2>&1; then
  echo "[stop] Cleaning apt caches"
  apt-get clean
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* || true
fi

# Keep logs by default; delete if requested
if [ "${PURGE_LOGS:-0}" = "1" ]; then
  LOG_DIR="${TTS_LOG_DIR:-/workspace/logs}"
  [ -d "${LOG_DIR}" ] && { echo "[stop] Purging logs in ${LOG_DIR}"; rm -rf "${LOG_DIR}"; }
fi

echo "[stop] Cleanup complete. Repo and Jupyter/web console preserved."
