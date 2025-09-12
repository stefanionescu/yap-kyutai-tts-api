# -------- YAP TTS RUNPOD ENV --------
# Compute ROOT_DIR fallback from this file location if not provided by caller
__ENV_SH_DIR__="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-${__ENV_SH_DIR__%/scripts}}"

TTS_ADDR=0.0.0.0
TTS_PORT=8089
TTS_LOG_DIR=${TTS_LOG_DIR:-${ROOT_DIR}/.data/logs}
TTS_TMUX_SESSION=yap-tts
TTS_CONFIG=${TTS_CONFIG:-${ROOT_DIR}/.data/server/config-tts-en-hf.toml}
DSM_REPO_DIR=${DSM_REPO_DIR:-${ROOT_DIR}/.data/delayed-streams-modeling}

# Voice assets
VOICES_DIR=${VOICES_DIR:-${ROOT_DIR}/.data/voices}
TTS_VOICE=${TTS_VOICE:-ears/p004/freeform_speech_01.wav}
