# -------- YAP TTS RUNPOD ENV --------
# Compute ROOT_DIR fallback from this file location if not provided by caller
__ENV_SH_DIR__="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-${__ENV_SH_DIR__%/scripts}}"

TTS_ADDR=0.0.0.0
TTS_PORT=8089
TTS_LOG_DIR=${TTS_LOG_DIR:-${ROOT_DIR}/.data/logs}
TTS_TMUX_SESSION=yap-tts
TTS_CONFIG=${TTS_CONFIG:-${ROOT_DIR}/.data/server/config-tts.toml}
DSM_REPO_DIR=${DSM_REPO_DIR:-${ROOT_DIR}/.data/delayed-streams-modeling}

# Voice assets
VOICES_DIR=${VOICES_DIR:-${ROOT_DIR}/.data/voices}
TTS_VOICE=${TTS_VOICE:-ears/p004/freeform_speech_01.wav}

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
