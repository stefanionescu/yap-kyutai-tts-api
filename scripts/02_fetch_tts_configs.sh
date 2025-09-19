#!/usr/bin/env bash
set -euo pipefail

# Load environment and utility modules
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"
source "$SCRIPT_DIR/utils/common.sh"
source "$SCRIPT_DIR/utils/hf_operations.sh"
source "$SCRIPT_DIR/utils/voice_management.sh"

SCRIPT_NAME="02-tts"

# Check HF_TOKEN before proceeding with HuggingFace operations
check_hf_token "$SCRIPT_NAME"

log_info "$SCRIPT_NAME" "Preparing config & voices (no DSM dependency)"
log_info "$SCRIPT_NAME" "ROOT_DIR: ${ROOT_DIR}"
log_info "$SCRIPT_NAME" "VOICES_DIR: ${VOICES_DIR}"
log_info "$SCRIPT_NAME" "TTS_CONFIG: ${TTS_CONFIG}"

# Copy or reuse the reference TTS config; prefer reusing existing
DEST_CFG="${TTS_CONFIG}"
LEGACY_CFG="${ROOT_DIR}/.data/server/config-tts-en-hf.toml"
if [ -f "$LEGACY_CFG" ] && [ ! -f "$DEST_CFG" ]; then
  log_info "$SCRIPT_NAME" "Migrating legacy config name: $LEGACY_CFG -> $DEST_CFG"
  ensure_dir "$(dirname "$DEST_CFG")"
  mv "$LEGACY_CFG" "$DEST_CFG"
fi

ensure_dir "$(dirname "${DEST_CFG}")"

# Download 1.6B model locally to avoid hf:// runtime indirection
MODEL_DIR="${ROOT_DIR}/.data/models/tts-1.6b-en_fr"
PYTHON_BIN="${ROOT_DIR}/.venv/bin/python"

# Snapshot once; reuse forever
if [ ! -f "${MODEL_DIR}/tokenizer_spm_8k_en_fr_audio.model" ]; then
  export HF_REPO="kyutai/tts-1.6b-en_fr"
  download_hf_model "$SCRIPT_NAME" "kyutai/tts-1.6b-en_fr" "$MODEL_DIR" "$PYTHON_BIN"
  
  # Verify the tokenizer file exists
  if [ ! -f "${MODEL_DIR}/tokenizer_spm_8k_en_fr_audio.model" ]; then
    log_error "$SCRIPT_NAME" "Tokenizer file not found after download: ${MODEL_DIR}/tokenizer_spm_8k_en_fr_audio.model"
    log_warning "$SCRIPT_NAME" "Falling back to hf:// path"
    TEXT_SPM="hf://kyutai/tts-1.6b-en_fr/tokenizer_spm_8k_en_fr_audio.model"
  else
    log_success "$SCRIPT_NAME" "Tokenizer verified: ${MODEL_DIR}/tokenizer_spm_8k_en_fr_audio.model"
    TEXT_SPM="${MODEL_DIR}/tokenizer_spm_8k_en_fr_audio.model"
  fi
else
  log_info "$SCRIPT_NAME" "Model already present at ${MODEL_DIR}"
  TEXT_SPM="${MODEL_DIR}/tokenizer_spm_8k_en_fr_audio.model"
fi

VOICE_REL="${TTS_VOICE:-ears/p004/freeform_speech_01.wav}"
VOICE_FOLDER_PATTERN="${VOICES_DIR}"
BS_VAL="${TTS_BATCH_SIZE:-32}"
NW_VAL="${TTS_NUM_WORKERS:-32}"
VOICE_REL_BASE="${VOICE_REL}"
ITXT_ONLY="${TTS_INTERLEAVED_TEXT_ONLY:-0}"

# Build a minimal subset of voices to speed up CA cache loading
SUBSET_DIR="${VOICES_DIR}/subset_ears"
ensure_dir "${SUBSET_DIR}/ears"
SELECTED_SPKS=(p004 p058 p059 p068 p081 p086 p100)
for spk in "${SELECTED_SPKS[@]}"; do
  ensure_dir "${SUBSET_DIR}/ears/${spk}"
  # Link safetensors embeddings
  for f in "${VOICES_DIR}/ears/${spk}"/*.safetensors; do
    [ -f "$f" ] || continue
    ln -sf "$f" "${SUBSET_DIR}/ears/${spk}/$(basename "$f")"
  done
  # Link canonical wav for p004 so the default_voice path resolves
  if [ "$spk" = "p004" ] && [ -f "${VOICES_DIR}/ears/${spk}/freeform_speech_01.wav" ]; then
    ln -sf "${VOICES_DIR}/ears/${spk}/freeform_speech_01.wav" "${SUBSET_DIR}/ears/${spk}/freeform_speech_01.wav"
  fi
done

log_info "$SCRIPT_NAME" "Writing minimal server config to ${DEST_CFG}"
cat > "${DEST_CFG}" <<EOF
static_dir = "./static/"
log_dir = "\$HOME/tmp/tts-logs"
instance_name = "tts"
authorized_ids = ["public_token"]

# --- Text tokenizer (Kyutai TTS 1.6B EN/FR) ---
text_tokenizer_file = "${TEXT_SPM}"
text_bos_token = 1

[modules.tts_py]
type = "Py"
path = "/api/tts_streaming"
batch_size = ${BS_VAL}
text_tokenizer_file = "${TEXT_SPM}"
text_bos_token = 1

[modules.tts_py.py]
# Python module overrides for tts.py (1.6B with embeddings)
hf_repo = "${TTS_HF_REPO}"
log_folder = "\$HOME/tmp/moshi-server-logs"
# CFG distillation => no explicit CFG pass at inference
n_q = 24
padding_between = 0
interleaved_text_only = ${ITXT_ONLY}
voice_folder = "${SUBSET_DIR}"
default_voice = "ears/p004/freeform_speech_01.wav"
# All required voices are available for generation:
# - ears/p058/freeform_speech_01.wav
# - ears/p059/freeform_speech_01.wav
# - ears/p068/freeform_speech_01.wav
# - ears/p081/freeform_speech_01.wav
# - ears/p086/freeform_speech_01.wav
# - ears/p100/freeform_speech_01.wav
EOF

log_success "$SCRIPT_NAME" "Wrote ${DEST_CFG}"

# Ensure voice availability with validation and re-download if needed
ensure_voice_availability "$SCRIPT_NAME" "$VOICES_DIR" "$PYTHON_BIN"

# Ensure the p004 embedding exists locally; some snapshots may miss it on first pass  
ensure_speaker_voice "$SCRIPT_NAME" "$VOICES_DIR" "ears/p004" "$PYTHON_BIN"