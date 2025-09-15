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
TTS_CONFIG=${TTS_CONFIG:-${ROOT_DIR}/.data/server/config-tts.toml}
DSM_REPO_DIR=${DSM_REPO_DIR:-${ROOT_DIR}/.data/delayed-streams-modeling}

# Voices root
VOICES_DIR=${VOICES_DIR:-${ROOT_DIR}/.data/voices}

# ---- 1.6B model settings ----
# Model repo for 1.6B
TTS_HF_REPO=${TTS_HF_REPO:-kyutai/tts-1.6b-en_fr}
# Choose speaker directory (p004 by default)
TTS_SPEAKER_DIR=${TTS_SPEAKER_DIR:-ears/p004}

# Auto-detect the exact 1.6B speaker embedding file (*.@240.safetensors)
_SPK_ABS_DIR="${VOICES_DIR}/${TTS_SPEAKER_DIR}"
_EMB_FILE=""
if [ -d "$_SPK_ABS_DIR" ]; then
  _EMB_FILE="$(
    find "$_SPK_ABS_DIR" -maxdepth 1 -type f -name "freeform_speech_01.wav.*@240.safetensors" -print -quit
  )"
  if [ -z "$_EMB_FILE" ]; then
    _EMB_FILE="$(find "$_SPK_ABS_DIR" -maxdepth 1 -type f -name "*@240.safetensors" -print -quit)"
  fi
fi

# Ensure TTS_VOICE is always defined to avoid set -u errors in callers
TTS_VOICE="${TTS_VOICE:-}"

if [ -n "$_EMB_FILE" ]; then
  # Store as a path relative to VOICES_DIR (what server config expects)
  TTS_VOICE="${_EMB_FILE#${VOICES_DIR}/}"
  export TTS_VOICE
  echo "[env] Using speaker embedding: ${TTS_VOICE}" >&2
else
  echo "[env] WARNING: No 1.6B speaker embedding found in ${_SPK_ABS_DIR} (*@240.safetensors)" >&2
fi

# Tuning knobs (override as needed)
# Batching window/size for the TTS module (locked to 32)
TTS_BATCH_SIZE=32
export TTS_BATCH_SIZE
# Worker threads inside moshi-server (concurrent synthesis tasks)
# Match/beat your benchmark concurrency to avoid queueing
TTS_NUM_WORKERS=${TTS_NUM_WORKERS:-32}
# Optional server-side request queue length (if supported by your moshi build)
TTS_MAX_QUEUE_LEN=${TTS_MAX_QUEUE_LEN:-256}
# Rayon CPU threads (Candle). Keep low to avoid CPU thrash on GPU runs
TTS_RAYON_THREADS=${TTS_RAYON_THREADS:-1}
# Tokio runtime worker threads (keep modest to avoid oversubscription)
TTS_TOKIO_THREADS=${TTS_TOKIO_THREADS:-4}
