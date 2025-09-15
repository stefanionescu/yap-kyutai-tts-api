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

# Voice assets
VOICES_DIR=${VOICES_DIR:-${ROOT_DIR}/.data/voices}
# Default to specific embedding, but allow auto-discovery if file doesn't exist
TTS_VOICE_DEFAULT="ears/p004/freeform_speech_01.wav.1e68beda@240.safetensors"
TTS_VOICE=${TTS_VOICE:-$TTS_VOICE_DEFAULT}

# Auto-detect p004 @240 embedding if default doesn't exist (HF may rehash files)
if [ ! -f "${VOICES_DIR}/${TTS_VOICE}" ] && [ "${TTS_VOICE}" = "${TTS_VOICE_DEFAULT}" ]; then
    AUTO_VOICE=$(find "${VOICES_DIR}/ears/p004" -maxdepth 1 -name "*@240.safetensors" -type f | head -n1 | sed "s|${VOICES_DIR}/||" 2>/dev/null || echo "")
    if [ -n "${AUTO_VOICE}" ]; then
        echo "[env] Auto-detected p004 voice: ${AUTO_VOICE} (original ${TTS_VOICE_DEFAULT} not found)" >&2
        TTS_VOICE="${AUTO_VOICE}"
    fi
fi

# Tuning knobs (override as needed)
# Batching window/size for the TTS module
TTS_BATCH_SIZE=${TTS_BATCH_SIZE:-32}
# Worker threads inside moshi-server (concurrent synthesis tasks)
TTS_NUM_WORKERS=${TTS_NUM_WORKERS:-12}
# Optional server-side request queue length (if supported by your moshi build)
TTS_MAX_QUEUE_LEN=${TTS_MAX_QUEUE_LEN:-256}
# Rayon CPU threads (Candle). Keep low to avoid CPU thrash on GPU runs
TTS_RAYON_THREADS=${TTS_RAYON_THREADS:-1}
# Tokio runtime worker threads (keep modest to avoid oversubscription)
TTS_TOKIO_THREADS=${TTS_TOKIO_THREADS:-4}
