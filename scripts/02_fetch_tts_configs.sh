#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
echo "[02-tts] Preparing config & voices (no DSM dependency)"
echo "[02-tts] ROOT_DIR: ${ROOT_DIR}"
echo "[02-tts] VOICES_DIR: ${VOICES_DIR}"
echo "[02-tts] TTS_CONFIG: ${TTS_CONFIG}"

# Copy or reuse the reference TTS config; prefer reusing existing
DEST_CFG="${TTS_CONFIG}"
LEGACY_CFG="${ROOT_DIR}/.data/server/config-tts-en-hf.toml"
if [ -f "$LEGACY_CFG" ] && [ ! -f "$DEST_CFG" ]; then
  echo "[02-tts] Migrating legacy config name: $LEGACY_CFG -> $DEST_CFG"
  mkdir -p "$(dirname "$DEST_CFG")"
  mv "$LEGACY_CFG" "$DEST_CFG"
fi

mkdir -p "$(dirname "${DEST_CFG}")"

# Download 1.6B model locally to avoid hf:// runtime indirection
MODEL_DIR="${ROOT_DIR}/.data/models/tts-1.6b-en_fr"
mkdir -p "${MODEL_DIR}"
# Snapshot once; reuse forever
if [ ! -f "${MODEL_DIR}/tokenizer_spm_8k_en_fr_audio.model" ]; then
  echo "[02-tts] Downloading tts-1.6b-en_fr model to ${MODEL_DIR}"
  export MODEL_DIR
  "${ROOT_DIR}/.venv/bin/python" - <<'PY'
import os
from huggingface_hub import snapshot_download
dst = os.environ.get("MODEL_DIR")
if not dst:
    print("ERROR: MODEL_DIR not set")
    exit(1)
print(f"Downloading tts-1.6b-en_fr to {dst}")
snapshot_download("kyutai/tts-1.6b-en_fr", local_dir=dst, local_dir_use_symlinks=False, resume_download=True)
print(f"Downloaded tts-1.6b-en_fr to {dst}")
PY
  echo "[02-tts] Model download completed"
  # Verify the tokenizer file exists
  if [ ! -f "${MODEL_DIR}/tokenizer_spm_8k_en_fr_audio.model" ]; then
    echo "[02-tts] ERROR: Tokenizer file not found after download: ${MODEL_DIR}/tokenizer_spm_8k_en_fr_audio.model"
    echo "[02-tts] Falling back to hf:// path"
    TEXT_SPM="hf://kyutai/tts-1.6b-en_fr/tokenizer_spm_8k_en_fr_audio.model"
  else
    echo "[02-tts] ✓ Tokenizer verified: ${MODEL_DIR}/tokenizer_spm_8k_en_fr_audio.model"
    TEXT_SPM="${MODEL_DIR}/tokenizer_spm_8k_en_fr_audio.model"
  fi
else
  echo "[02-tts] Model already present at ${MODEL_DIR}"
  TEXT_SPM="${MODEL_DIR}/tokenizer_spm_8k_en_fr_audio.model"
fi

VOICE_REL="${TTS_VOICE:-ears/p004/freeform_speech_01.wav.@240.safetensors}"
VOICE_FOLDER_PATTERN="${VOICES_DIR}"
BS_VAL="${TTS_BATCH_SIZE:-32}"

# Derive the attribute name expected by tts.py (default_voice should NOT include the embedding suffix)
# If VOICE_REL looks like an embedding file (e.g., freeform.wav.<hash>@240.safetensors), trim to the *.wav base.
VOICE_REL_BASE="${VOICE_REL}"
case "${VOICE_REL_BASE}" in
  *.safetensors)
    # Keep everything through the first .wav occurrence
    VOICE_REL_BASE=$(printf "%s" "${VOICE_REL_BASE}" | sed -E 's|(.*\.wav).*|\1|')
    ;;
esac

echo "[02-tts] Writing minimal server config to ${DEST_CFG}"
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
n_q = 32
voice_folder = "${VOICE_FOLDER_PATTERN}"
default_voice = "${VOICE_REL_BASE}"
EOF

echo "[02-tts] Wrote ${DEST_CFG}"

# Download the entire voices repository once (all datasets) and reuse thereafter
VOICES_DIR="${VOICES_DIR:-${ROOT_DIR}/.data/voices}"
mkdir -p "${VOICES_DIR}"

# Check if voices actually exist (not just empty directory)
VOICE_COUNT=$(find "${VOICES_DIR}" -type f \( -name '*.safetensors' -o -name '*.wav' \) | wc -l)
if [ "$VOICE_COUNT" -gt 0 ]; then
  echo "[02-tts] Voices already present in ${VOICES_DIR} ($VOICE_COUNT files, skip download)"
else
  echo "[02-tts] Downloading ALL voices to ${VOICES_DIR} (kyutai/tts-voices)"
  export VOICES_DIR MODEL_DIR
  "${ROOT_DIR}/.venv/bin/python" - <<'PY'
import os, sys
dst = os.environ.get('VOICES_DIR')
model_dir = os.environ.get('MODEL_DIR')
print(f'Downloading to: {dst}')
try:
    from huggingface_hub import snapshot_download
    snapshot_download('kyutai/tts-voices', local_dir=dst, local_dir_use_symlinks=False, resume_download=True)
    print('Voices snapshot downloaded.')
except Exception as e:
    print(f'[02-tts] ERROR downloading voices: {e}')
    sys.exit(1)
PY
  echo "[02-tts] Voices download completed"
fi

# Ensure the p004 embedding exists locally; some snapshots may miss it on first pass
P004_DIR="${VOICES_DIR}/ears/p004"
mkdir -p "${P004_DIR}"
P004_EMB_COUNT=$(find "${P004_DIR}" -maxdepth 1 -type f -name "*.safetensors" | wc -l)
if [ "${P004_EMB_COUNT}" -eq 0 ]; then
  echo "[02-tts] Ensuring p004 voice embedding is present"
  export VOICES_DIR
  "${ROOT_DIR}/.venv/bin/python" - <<'PY'
import os, sys
dst = os.environ.get('VOICES_DIR')
try:
    from huggingface_hub import snapshot_download
    snapshot_download('kyutai/tts-voices', local_dir=dst, local_dir_use_symlinks=False,
                      resume_download=True, allow_patterns=['ears/p004/*'])
    print('p004 voice ensured.')
except Exception as e:
    print(f'[02-tts] WARNING: could not ensure p004 voice: {e}')
PY
fi