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

# Ensure Mimi codec tokens per frame (n_q) is set to 16, as required by 0.75B
if grep -qE '^[[:space:]]*n_q[[:space:]]*=' "${DEST_CFG}"; then
  sed -i 's/^[[:space:]]*n_q[[:space:]]*=.*/n_q = 16/' "${DEST_CFG}" || true
else
  printf '\n# Enforce Mimi codec tokens per frame for 0.75B EN\n# Do not reduce at inference time\nn_q = 16\n' >> "${DEST_CFG}"
fi

# Ensure modules.tts_py block exists with batch_size and n_q configured
if ! grep -q "^\[modules.tts_py\]" "${DEST_CFG}"; then
  cat >> "${DEST_CFG}" <<EOF

[modules.tts_py]
type = "Py"
path = "/api/tts_streaming"
batch_size = ${TTS_BATCH_SIZE:-32}
n_q = 16
EOF
else
  # Update existing batch_size value inside the tts_py block
  awk -v bs="${TTS_BATCH_SIZE:-32}" '
    BEGIN{inblk=0}
    /^\[modules\.tts_py\]/{inblk=1}
    /^\[/{if(inblk){inblk=0}}
    {if(inblk && $1 ~ /^batch_size/){$0="batch_size = " bs}; print}
  ' "${DEST_CFG}" > "${DEST_CFG}.tmp" && mv "${DEST_CFG}.tmp" "${DEST_CFG}"
fi

# Try to set a top-level num_workers if the key exists; otherwise append it once
if grep -qE '^[[:space:]]*num_workers[[:space:]]*=' "${DEST_CFG}"; then
  sed -i "s/^[[:space:]]*num_workers[[:space:]]*=.*/num_workers = ${TTS_NUM_WORKERS:-12}/" "${DEST_CFG}" || true
else
  printf '\n# Worker pool size for concurrent synthesis\nnum_workers = %s\n' "${TTS_NUM_WORKERS:-12}" >> "${DEST_CFG}"
fi

echo "[02-tts] Wrote ${DEST_CFG}"

# Ensure requested voice asset is present
VOICES_DIR="${VOICES_DIR:-${ROOT_DIR}/.data/voices}"
VOICE_REL="${TTS_VOICE:-ears/p004/freeform_speech_01.wav}"
VOICE_DST="${VOICES_DIR}/${VOICE_REL}"
mkdir -p "$(dirname "${VOICE_DST}")"

if [ ! -f "${VOICE_DST}" ]; then
  echo "[02-tts] Downloading voice asset: ${VOICE_REL}"
  URL="https://huggingface.co/kyutai/tts-voices/resolve/main/${VOICE_REL}"
  if ! curl -fL -o "${VOICE_DST}.tmp" "${URL}" 2>/dev/null && ! wget -q -O "${VOICE_DST}.tmp" "${URL}"; then
    echo "[02-tts] WARNING: Could not download voice asset from Hugging Face: ${VOICE_REL}"
  else
    mv "${VOICE_DST}.tmp" "${VOICE_DST}"
    echo "[02-tts] Saved voice to ${VOICE_DST}"
  fi
fi
