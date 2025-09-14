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

# Ensure the top-level tokenizer settings exist (root of TOML, before any [table])
#  - Use the SentencePiece text tokenizer shipped with 0.75B EN
#  - Align with model config: text_card=8000, existing_text_padding_id=3
#  - Standard SPM BOS/EOS ids
TEXT_SPM="hf://kyutai/tts-0.75b-en-public/tokenizer_spm_8k_en_fr_audio.model"
# Remove any wrong tokenizer.json occurrences anywhere
sed -i '/tokenizer\.json/d' "${DEST_CFG}"

# Find the first table header line to keep our top-level keys truly at root
FIRST_HDR_LINE=$(grep -n '^\[' "${DEST_CFG}" | head -n 1 | cut -d: -f1 || true)
if [ -n "${FIRST_HDR_LINE:-}" ]; then
  # Split into head (root) and tail (tables)
  head -n "$((FIRST_HDR_LINE - 1))" "${DEST_CFG}" \
    | sed -E \
        -e '/^text_tokenizer_file\s*=.*/d' \
        -e '/^text_card\s*=.*/d' \
        -e '/^existing_text_padding_id\s*=.*/d' \
        -e '/^text_bos_token\s*=.*/d' \
        -e '/^text_eos_token\s*=.*/d' \
    > "${DEST_CFG}.head"
  cat > "${DEST_CFG}.root_keys" <<EOF

# --- Text tokenizer (Kyutai TTS 0.75B EN) ---
text_tokenizer_file = "${TEXT_SPM}"
text_card = 8000
existing_text_padding_id = 3
text_bos_token = 1
text_eos_token = 2
EOF
  tail -n +"${FIRST_HDR_LINE}" "${DEST_CFG}" > "${DEST_CFG}.tail"
  cat "${DEST_CFG}.head" "${DEST_CFG}.root_keys" "${DEST_CFG}.tail" > "${DEST_CFG}.tmp" && mv "${DEST_CFG}.tmp" "${DEST_CFG}"
  rm -f "${DEST_CFG}.head" "${DEST_CFG}.root_keys" "${DEST_CFG}.tail"
else
  # No tables found: just append the block at the end (still root)
  cat >> "${DEST_CFG}" <<EOF

# --- Text tokenizer (Kyutai TTS 0.75B EN) ---
text_tokenizer_file = "${TEXT_SPM}"
text_card = 8000
existing_text_padding_id = 3
text_bos_token = 1
text_eos_token = 2
EOF
fi

# Ensure modules.tts_py block exists with batch_size and tokenization settings configured
if ! grep -q "^\[modules.tts_py\]" "${DEST_CFG}"; then
  cat >> "${DEST_CFG}" <<EOF

[modules.tts_py]
type = "Py"
path = "/api/tts_streaming"
batch_size = ${TTS_BATCH_SIZE:-64}
# Pin text tokenizer (SentencePiece) and BOS for 0.75B EN model
text_tokenizer_file = "hf://kyutai/tts-0.75b-en-public/tokenizer_spm_8k_en_fr_audio.model"
text_bos_token = 1
EOF
else
  # Ensure batch_size and tokenization settings exist or override inside the tts_py block
  awk -v bs="${TTS_BATCH_SIZE:-64}" '
    BEGIN{inblk=0; inserted=0}
    /^\[modules\.tts_py\]/{print; inblk=1; inserted=0; next}
    {
      if(inblk){
        if(!inserted){ 
          print "batch_size = " bs
          print "# Pin tokenizer and BOS for 0.75B EN model"
          print "text_tokenizer_file = \"hf://kyutai/tts-0.75b-en-public/tokenizer_spm_8k_en_fr_audio.model\""
          print "text_bos_token = 1"
          inserted=1 
        }
        if($0 ~ /^\[/){ inblk=0 }
        if($1 ~ /^batch_size|^text_tokenizer_file|^text_bos_token/){ next }
      }
      print
    }
  ' "${DEST_CFG}" > "${DEST_CFG}.tmp" && mv "${DEST_CFG}.tmp" "${DEST_CFG}"
fi

# Ensure modules.tts_py.py sub-table exists and set Python-side overrides for 0.75B EN
VOICE_REL="${TTS_VOICE:-ears/p004/freeform_speech_01.wav}"
VOICE_FOLDER_PATTERN="${VOICES_DIR:-${ROOT_DIR}/.data/voices}"
if ! grep -q "^\[modules.tts_py.py\]" "${DEST_CFG}"; then
  cat >> "${DEST_CFG}" <<EOF

[modules.tts_py.py]
# Python module overrides for tts.py
n_q = 16
voice_folder = "${VOICE_FOLDER_PATTERN}"
default_voice = "${VOICE_REL}"
# Stability > raw TTFB for the first 200 ms
interleaved_text_only = 1
initial_padding = 1
final_padding = 2
max_padding = 4
padding_between = 1
padding_bonus = 1.0
cfg_coef = 1.0
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
      if(inblk && $1 ~ /^cfg_coef/){$0="cfg_coef = 1.0"}
      if(inblk && $1 ~ /^padding_between/){$0="padding_between = 1"}
      if(inblk && $1 ~ /^interleaved_text_only/){$0="interleaved_text_only = 1"}
      if(inblk && $1 ~ /^initial_padding/){$0="initial_padding = 1"}
      if(inblk && $1 ~ /^final_padding/){$0="final_padding = 2"}
      if(inblk && $1 ~ /^max_padding/){$0="max_padding = 4"}
      if(inblk && $1 ~ /^padding_bonus/){$0="padding_bonus = 1.0"}
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
