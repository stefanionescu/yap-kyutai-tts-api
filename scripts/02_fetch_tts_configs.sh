#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
echo "[02-tts] Fetching DSM repo for configs & scripts…"

DSM_DIR="${DSM_REPO_DIR:-${ROOT_DIR}/.data/delayed-streams-modeling}"
if [ ! -d "${DSM_DIR}" ]; then
  git clone --depth=1 https://github.com/kyutai-labs/delayed-streams-modeling "${DSM_DIR}"
else
  git -C "${DSM_DIR}" pull --ff-only || true
fi

# Copy the reference TTS config into your repo and retarget the model to 0.75b EN
DEST_CFG="${TTS_CONFIG}"
mkdir -p "$(dirname "${DEST_CFG}")"
cp -f "${DSM_DIR}/configs/config-tts.toml" "${DEST_CFG}"

# Point to the public, smaller English-only model
sed -i 's#kyutai/tts-1.6b-en_fr#kyutai/tts-0.75b-en-public#g' "${DEST_CFG}" || true

# Ensure modules.tts_py block exists with batch_size configured
if ! grep -q "^\[modules.tts_py\]" "${DEST_CFG}"; then
  cat >> "${DEST_CFG}" <<EOF

[modules.tts_py]
type = "Py"
path = "/api/tts_streaming"
batch_size = ${TTS_BATCH_SIZE:-64}
EOF
else
  # Update existing batch_size value inside the tts_py block
  awk -v bs="${TTS_BATCH_SIZE:-64}" '
    BEGIN{inblk=0}
    /^\[modules\.tts_py\]/{inblk=1}
    /^\[/{if(inblk){inblk=0}}
    {if(inblk && $1 ~ /^batch_size/){$0="batch_size = " bs}; print}
  ' "${DEST_CFG}" > "${DEST_CFG}.tmp" && mv "${DEST_CFG}.tmp" "${DEST_CFG}"
fi

# Ensure modules.tts_py.py sub-table exists and set Python-side overrides for 0.75B EN
VOICE_REL="${TTS_VOICE:-ears/p004/freeform_speech_01.wav}"
VOICE_FOLDER_PATTERN="hf-snapshot://kyutai/tts-voices/ears/**/*.safetensors"
if ! grep -q "^\[modules.tts_py.py\]" "${DEST_CFG}"; then
  cat >> "${DEST_CFG}" <<EOF

[modules.tts_py.py]
# Python module overrides for tts.py
n_q = 16
voice_folder = "${VOICE_FOLDER_PATTERN}"
default_voice = "${VOICE_REL}"
# cfg_coef and padding tuned for intelligibility
cfg_coef = 2.0
padding_between = 1
EOF
else
  awk -v voice_folder="${VOICE_FOLDER_PATTERN}" -v default_voice="${VOICE_REL}" '
    BEGIN{inblk=0}
    /^\[modules\.tts_py\.py\]/{inblk=1}
    /^\[/{if(inblk){inblk=0}}
    {
      if(inblk && $1 ~ /^n_q/){$0="n_q = 16"}
      if(inblk && $1 ~ /^voice_folder/){$0="voice_folder = \"" voice_folder "\""}
      if(inblk && $1 ~ /^default_voice/){$0="default_voice = \"" default_voice "\""}
      print
    }
  ' "${DEST_CFG}" > "${DEST_CFG}.tmp" && mv "${DEST_CFG}.tmp" "${DEST_CFG}"
fi

echo "[02-tts] Wrote ${DEST_CFG}"

# Optionally fetch a single reference WAV for tests; embeddings will be snapshot-downloaded lazily
VOICES_DIR="${VOICES_DIR:-${ROOT_DIR}/.data/voices}"
VOICE_DST="${VOICES_DIR}/${VOICE_REL}"
mkdir -p "$(dirname "${VOICE_DST}")"
if [ ! -f "${VOICE_DST}" ]; then
  echo "[02-tts] Downloading voice WAV for smoke test: ${VOICE_REL}"
  URL="https://huggingface.co/kyutai/tts-voices/resolve/main/${VOICE_REL}"
  if curl -fL -o "${VOICE_DST}.tmp" "${URL}" 2>/dev/null || wget -q -O "${VOICE_DST}.tmp" "${URL}"; then
    mv "${VOICE_DST}.tmp" "${VOICE_DST}"
    echo "[02-tts] Saved voice WAV to ${VOICE_DST}"
  else
    echo "[02-tts] WARNING: Could not download voice WAV: ${VOICE_REL}"
  fi
fi
