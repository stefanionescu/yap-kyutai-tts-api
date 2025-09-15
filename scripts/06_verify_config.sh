#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

echo "[06-verify] Checking TTS configuration..."

# Check if config file exists
if [ ! -f "${TTS_CONFIG}" ]; then
  echo "ERROR: Config file not found at ${TTS_CONFIG}"
  echo "Run scripts/02_fetch_tts_configs.sh first"
  exit 1
fi

echo "[06-verify] Config file: ${TTS_CONFIG}"
echo ""

# Check for p004-specific settings in config
echo "=== Config Verification ==="
echo "Expected voice settings:"
if grep -q "voice_folder.*p004.*safetensors" "${TTS_CONFIG}"; then
  echo "✓ voice_folder pointing to p004 embeddings: $(grep 'voice_folder' "${TTS_CONFIG}" | cut -d= -f2 | tr -d ' "')"
else
  echo "✗ voice_folder not set to p004 embeddings"
  echo "  Found: $(grep 'voice_folder' "${TTS_CONFIG}" 2>/dev/null || echo 'MISSING')"
fi

if grep -q 'default_voice.*ears/p004/freeform_speech_01.wav' "${TTS_CONFIG}"; then
  echo "✓ default_voice set to p004: $(grep 'default_voice' "${TTS_CONFIG}" | cut -d= -f2 | tr -d ' "')"
else
  echo "✗ default_voice not set correctly"
  echo "  Found: $(grep 'default_voice' "${TTS_CONFIG}" 2>/dev/null || echo 'MISSING')"
fi

# Check for improved quality settings
echo ""
echo "Quality settings:"
if grep -q 'interleaved_text_only.*[12]' "${TTS_CONFIG}"; then
  echo "✓ interleaved_text_only set for better onset: $(grep 'interleaved_text_only' "${TTS_CONFIG}" | cut -d= -f2 | tr -d ' ')"
else
  echo "✗ interleaved_text_only not set optimally (should be 1 or 2)"
fi

if grep -q 'cfg_coef.*1\.[0-3]' "${TTS_CONFIG}"; then
  echo "✓ cfg_coef set for less robotic sound: $(grep 'cfg_coef' "${TTS_CONFIG}" | cut -d= -f2 | tr -d ' ')"
else
  echo "✗ cfg_coef not in optimal range 1.0-1.3"
  echo "  Found: $(grep 'cfg_coef' "${TTS_CONFIG}" 2>/dev/null || echo 'MISSING')"
fi

# Check if p004 files exist locally
echo ""
echo "=== Local Files Verification ==="
VOICES_DIR="${VOICES_DIR:-${ROOT_DIR}/.data/voices}"
P004_DIR="${VOICES_DIR}/ears/p004"

if [ -d "${P004_DIR}" ]; then
  echo "✓ p004 directory exists: ${P004_DIR}"
  
  if [ -f "${P004_DIR}/freeform_speech_01.wav" ]; then
    echo "✓ p004 WAV file found"
  else
    echo "✗ p004 WAV file missing"
  fi
  
  if ls "${P004_DIR}"/*.safetensors >/dev/null 2>&1; then
    echo "✓ p004 embedding files found: $(ls "${P004_DIR}"/*.safetensors | wc -l) files"
  else
    echo "✗ p004 embedding files (.safetensors) missing"
  fi
else
  echo "✗ p004 directory missing: ${P004_DIR}"
  echo "  Run scripts/02_fetch_tts_configs.sh to download"
fi

echo ""
echo "=== Runtime Verification (when server is running) ==="
echo "To verify the server is actually using these settings:"
echo "1. Start the server: scripts/03_start_tts_server.sh"
echo "2. Check server logs:"
echo "   grep -nE 'loading voices|default voice|voice_folder' \"\${TTS_LOG_DIR}/tts-server.log\""
echo "3. You should NOT see 'hf-snapshot://.../**/*.safetensors' in the logs"
echo "4. You SHOULD see references to your local p004 files"
echo ""

# Summary
echo "=== Summary ==="
config_ok=true
if ! grep -q "voice_folder.*p004.*safetensors" "${TTS_CONFIG}"; then config_ok=false; fi
if ! grep -q 'default_voice.*ears/p004/freeform_speech_01.wav' "${TTS_CONFIG}"; then config_ok=false; fi
if [ ! -f "${P004_DIR}/freeform_speech_01.wav" ]; then config_ok=false; fi
if ! ls "${P004_DIR}"/*.safetensors >/dev/null 2>&1; then config_ok=false; fi

if [ "$config_ok" = true ]; then
  echo "✅ Configuration looks good for p004 voice consistency!"
else
  echo "❌ Configuration needs fixes. Re-run scripts/02_fetch_tts_configs.sh"
  exit 1
fi
