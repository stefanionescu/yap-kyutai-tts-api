# -------- YAP TTS RUNPOD ENV --------
# Force ROOT_DIR to be this repo directory (not /workspace or external)
__ENV_SH_DIR__="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__REPO_ROOT__="${__ENV_SH_DIR__%/scripts}"
ROOT_DIR="${__REPO_ROOT__}"

echo "[env] ROOT_DIR forced to repo: ${ROOT_DIR}" >&2

TTS_ADDR=0.0.0.0
TTS_PORT=8089
TTS_LOG_DIR=${TTS_LOG_DIR:-${ROOT_DIR}/.data/logs}
TTS_TMUX_SESSION=yap-tts
TTS_CONFIG=${TTS_CONFIG:-${ROOT_DIR}/configs/config.toml}
DSM_REPO_DIR=${DSM_REPO_DIR:-${ROOT_DIR}/.data/delayed-streams-modeling}

# Voices root
VOICES_DIR=${VOICES_DIR:-${ROOT_DIR}/.data/voices}

# ---- 1.6B model settings ----
# Model repo for 1.6B
TTS_HF_REPO=${TTS_HF_REPO:-kyutai/tts-1.6b-en_fr}
# Choose speaker directory (p004 by default)
TTS_SPEAKER_DIR=${TTS_SPEAKER_DIR:-ears/p004}

# Auto-detect the freeform_speech_01.wav file for p004 voice
_SPK_ABS_DIR="${VOICES_DIR}/${TTS_SPEAKER_DIR}"
_WAV_FILE=""
if [ -d "$_SPK_ABS_DIR" ]; then
  _WAV_FILE="$(
    find "$_SPK_ABS_DIR" -maxdepth 1 -type f -name "freeform_speech_01.wav" -print -quit
  )"
  if [ -z "$_WAV_FILE" ]; then
    _WAV_FILE="$(find "$_SPK_ABS_DIR" -maxdepth 1 -type f -name "*.wav" -print -quit)"
  fi
fi

# Ensure TTS_VOICE is always defined to avoid set -u errors in callers
TTS_VOICE="${TTS_VOICE:-}"

if [ -n "$_WAV_FILE" ]; then
  # Store as a path relative to VOICES_DIR (what server config expects)
  TTS_VOICE="${_WAV_FILE#${VOICES_DIR}/}"
  export TTS_VOICE
  echo "[env] Using voice WAV file: ${TTS_VOICE}" >&2
else
  echo "[env] WARNING: No WAV files found in ${_SPK_ABS_DIR} (*.wav)" >&2
fi

# Tuning knobs (override as needed)
# Batching window/size for the TTS module (match your target concurrency)
TTS_BATCH_SIZE=16
export TTS_BATCH_SIZE
# Worker threads inside moshi-server (concurrent synthesis tasks)
# Match/beat your benchmark concurrency to avoid queueing
TTS_NUM_WORKERS=${TTS_NUM_WORKERS:-32}
# Optional server-side request queue length (if supported by your moshi build)
TTS_MAX_QUEUE_LEN=${TTS_MAX_QUEUE_LEN:-64}
# Rayon CPU threads (Candle). Higher for better GPU feeding
TTS_RAYON_THREADS=${TTS_RAYON_THREADS:-8}
# Tokio runtime worker threads; default to CPU cores if unset
TTS_TOKIO_THREADS=${TTS_TOKIO_THREADS:-}
# Interleave text-only steps before audio decode (0 best TTFB)
TTS_INTERLEAVED_TEXT_ONLY=${TTS_INTERLEAVED_TEXT_ONLY:-0}

# HuggingFace Hub settings to avoid throttling bursts
export HF_HUB_DISABLE_XET=${HF_HUB_DISABLE_XET:-1}
export HF_HUB_ENABLE_HF_TRANSFER=${HF_HUB_ENABLE_HF_TRANSFER:-0}

# Linux allocator + OpenMP caps for stable latency under load
export MALLOC_ARENA_MAX=${MALLOC_ARENA_MAX:-2}
export OMP_NUM_THREADS=${OMP_NUM_THREADS:-1}
export MKL_NUM_THREADS=${MKL_NUM_THREADS:-1}
export OMP_PROC_BIND=${OMP_PROC_BIND:-close}
export OMP_PLACES=${OMP_PLACES:-cores}
export KMP_BLOCKTIME=${KMP_BLOCKTIME:-0}
