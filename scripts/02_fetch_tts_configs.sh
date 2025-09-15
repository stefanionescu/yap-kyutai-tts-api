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

# Ensure p004 voice files are downloaded first
VOICE_REL="${TTS_VOICE:-ears/p004/freeform_speech_01.wav}"
VOICES_DIR="${VOICES_DIR:-${ROOT_DIR}/.data/voices}"
echo "[02-tts] Downloading p004 voice files..."
"${ROOT_DIR}/.venv/bin/python" - <<'PY'
from huggingface_hub import snapshot_download
import os
voices_dir = os.environ.get('VOICES_DIR', '.data/voices')
snapshot_download(
    "kyutai/tts-voices",
    local_dir=voices_dir,
    local_dir_use_symlinks=False,
    allow_patterns=["ears/p004/*"],
    resume_download=True,
)
print("OK: p004 voice is local")
PY

# --- Hard override the Python TTS submodule block to force a single speaker ---
cat >> "${DEST_CFG}" <<'EOF'

[modules.tts_py.py]
# Only load p004 embeddings from local disk (no HF random sampling)
voice_folder = "${VOICES_DIR}/ears/p004/*.safetensors"
default_voice = "ears/p004/freeform_speech_01.wav"

# sensible low-latency defaults; we'll tune below
n_q = 16
interleaved_text_only = 2
initial_padding = 3
final_padding = 2
max_padding = 4
padding_between = 1
padding_bonus = 1.0
cfg_coef = 1.2
EOF

echo "[02-tts] Wrote ${DEST_CFG}"

# Add verification script to check config took effect
cat >> "${DEST_CFG}" <<'VERIFY'

# --- End of config ---
# To verify this config is loaded, check server logs for:
# voice_folder = <your>/.data/voices/ears/p004/*.safetensors
# default_voice = ears/p004/freeform_speech_01.wav
VERIFY

echo "[02-tts] Configuration complete. After starting the server, verify with:"
echo "  grep -nE 'voice_folder|default_voice' \"\${TTS_CONFIG}\""
echo "  grep -nE 'loading voices|default voice' \"\${TTS_LOG_DIR}/tts-server.log\""
