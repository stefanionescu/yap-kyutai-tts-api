# -------- YAP TTS RUNPOD ENV --------
TTS_ADDR=0.0.0.0
TTS_PORT=8000
TTS_LOG_DIR=/workspace/logs
TTS_TMUX_SESSION=yap-tts
TTS_CONFIG=${TTS_CONFIG:-${ROOT_DIR}/../server/config-tts-en-hf.toml}
# Optional: auth (same header as your STT path)
YAP_API_KEY=public_token

# Voice assets
VOICES_DIR=${VOICES_DIR:-/workspace/voices}
TTS_VOICE=${TTS_VOICE:-ears/p004/freeform_speech_01.wav}
