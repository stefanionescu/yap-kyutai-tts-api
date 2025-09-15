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

# Copy or reuse the reference TTS config; prefer reusing existing
DEST_CFG="${TTS_CONFIG}"
LEGACY_CFG="${ROOT_DIR}/.data/server/config-tts-en-hf.toml"
if [ -f "$LEGACY_CFG" ] && [ ! -f "$DEST_CFG" ]; then
  echo "[02-tts] Migrating legacy config name: $LEGACY_CFG -> $DEST_CFG"
  mkdir -p "$(dirname "$DEST_CFG")"
  mv "$LEGACY_CFG" "$DEST_CFG"
fi
mkdir -p "$(dirname "${DEST_CFG}")"
if [ -f "${DEST_CFG}" ]; then
  echo "[02-tts] Using existing server config (no changes): ${DEST_CFG}"
else
  cp -f "${DSM_DIR}/configs/config-tts.toml" "${DEST_CFG}"

# Portable in-place sed (macOS/BSD and GNU)
sedi() {
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"
  else
    # BSD/macOS sed
    sed -i '' "$@"
  fi
}

# Point to the public, smaller English-only model
sedi 's#kyutai/tts-1.6b-en_fr#kyutai/tts-0.75b-en-public#g' "${DEST_CFG}" || true

# Ensure the top-level tokenizer settings exist (root of TOML, before any [table])
#  - Use the SentencePiece text tokenizer shipped with 0.75B EN
#  - Align with model config: text_card=8000, existing_text_padding_id=3
#  - Standard SPM BOS/EOS ids
TEXT_SPM="hf://kyutai/tts-0.75b-en-public/tokenizer_spm_8k_en_fr_audio.model"
# Remove any wrong tokenizer.json occurrences anywhere
sedi '/tokenizer\.json/d' "${DEST_CFG}"

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
  # Keep keys like "ears/p004/freeform_speech_01.wav" (relative key) and point
  # the voice_folder to the local voices mirror so we don't hit HF at runtime.
  VOICE_REL="${TTS_VOICE:-ears/p004/freeform_speech_01.wav}"
  VOICES_DIR="${VOICES_DIR:-${ROOT_DIR}/.data/voices}"
  VOICE_FOLDER_PATTERN="${VOICES_DIR}/**/*.safetensors"
  DEFAULT_VOICE_KEY="${VOICE_REL}"
  if ! grep -q "^\[modules.tts_py.py\]" "${DEST_CFG}"; then
    cat >> "${DEST_CFG}" <<EOF

[modules.tts_py.py]
# Python module overrides for tts.py
n_q = 16
voice_folder = "${VOICE_FOLDER_PATTERN}"
default_voice = "${DEFAULT_VOICE_KEY}"
# Leave generation pacing at library defaults to avoid startup artifacts
# (interleaved_text_only defaults to 2 for a brief text-only warmup)
EOF
  else
    awk -v voice_folder="${VOICE_FOLDER_PATTERN}" -v default_voice="${DEFAULT_VOICE_KEY}" '
    BEGIN{inblk=0}
    /^\[modules\.tts_py\.py\]/{inblk=1}
    /^\[/{if(inblk){inblk=0}}
    {
      if(inblk && $1 ~ /^n_q/){$0="n_q = 16"}
      if(inblk && $1 ~ /^voice_folder/){$0="voice_folder = \"" voice_folder "\""}
      if(inblk && $1 ~ /^default_voice/){$0="default_voice = \"" default_voice "\""}
      if(inblk && $1 ~ /^(cfg_coef|padding_between|interleaved_text_only|initial_padding|final_padding|max_padding|padding_bonus)/){next}
      print
    }
  ' "${DEST_CFG}" > "${DEST_CFG}.tmp" && mv "${DEST_CFG}.tmp" "${DEST_CFG}"
  fi

  echo "[02-tts] Wrote ${DEST_CFG}"
fi

# Download the entire voices repository once (all datasets) and reuse thereafter
VOICES_DIR="${VOICES_DIR:-${ROOT_DIR}/.data/voices}"
mkdir -p "${VOICES_DIR}"
if find "${VOICES_DIR}" -type f \( -name '*.safetensors' -o -name '*.wav' \) | head -n 1 >/dev/null; then
  echo "[02-tts] Voices already present in ${VOICES_DIR} (skip download)"
else
  echo "[02-tts] Downloading ALL voices to ${VOICES_DIR} (kyutai/tts-voices)"
  "${ROOT_DIR}/.venv/bin/python" - <<'PY'
import os, sys
dst = os.environ.get('VOICES_DIR')
try:
    from huggingface_hub import snapshot_download
    snapshot_download('kyutai/tts-voices', local_dir=dst, local_dir_use_symlinks=False, resume_download=True)
    print('Voices snapshot downloaded.')
except Exception as e:
    print(f'[02-tts] ERROR downloading voices: {e}')
    sys.exit(1)
PY
fi
