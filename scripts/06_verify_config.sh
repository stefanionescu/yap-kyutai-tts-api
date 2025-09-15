#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

echo "[06-verify] Verifying TTS configuration and voice setup"
echo "[06-verify] ROOT_DIR: ${ROOT_DIR}"
echo "[06-verify] VOICES_DIR: ${VOICES_DIR}"
echo "[06-verify] TTS_CONFIG: ${TTS_CONFIG}"

ERRORS=0

# 1) Check config file exists and has correct voice settings
echo ""
echo "=== Config file verification ==="
if [ ! -f "${TTS_CONFIG}" ]; then
  echo "[06-verify] ERROR: Config file missing: ${TTS_CONFIG}"
  ERRORS=$((ERRORS + 1))
else
  echo "[06-verify] Config file exists: ${TTS_CONFIG}"
  
  # Check voice settings in config
  echo ""
  echo "=== Current config voice settings ==="
  grep -A3 -B3 "voice_folder\|default_voice\|n_q\|hf_repo\|batch_size\|text_tokenizer_file\|log_folder" "${TTS_CONFIG}" || true
  
  # Validate specific settings for 1.6B
  if grep -q 'voice_folder.*hf-snapshot' "${TTS_CONFIG}"; then
    echo "[06-verify] ERROR: Config still uses HF snapshot, should use local path"
    ERRORS=$((ERRORS + 1))
  fi

  if ! grep -q 'n_q = 32' "${TTS_CONFIG}"; then
    echo "[06-verify] ERROR: Config should have n_q = 32 (training baseline) for 1.6B model"
    ERRORS=$((ERRORS + 1))
  fi

  # CFG settings should NOT be present (1.6B is CFG-distilled)
  if grep -q 'cfg_is_no_text\|cfg_coef\|padding_between' "${TTS_CONFIG}"; then
    echo "[06-verify] ERROR: Config should NOT have CFG settings (1.6B is CFG-distilled)"
    ERRORS=$((ERRORS + 1))
  fi

  if ! grep -q 'batch_size = 32' "${TTS_CONFIG}"; then
    echo "[06-verify] ERROR: Config should have batch_size = 32 (optimal for L40S)"
    ERRORS=$((ERRORS + 1))
  fi

  if ! grep -q 'log_folder.*moshi-server-logs' "${TTS_CONFIG}"; then
    echo "[06-verify] ERROR: Config should have log_folder with moshi-server-logs"
    ERRORS=$((ERRORS + 1))
  fi

  if ! grep -q 'default_voice.*ears/p004' "${TTS_CONFIG}"; then
    echo "[06-verify] ERROR: Config should have default_voice under ears/p004 (attribute name)"
    ERRORS=$((ERRORS + 1))
  fi

  if ! grep -q 'hf_repo.*tts-1.6b-en_fr' "${TTS_CONFIG}"; then
    echo "[06-verify] ERROR: Config should have hf_repo = kyutai/tts-1.6b-en_fr"
    ERRORS=$((ERRORS + 1))
  fi

  # Check tokenizer is using local path, not hf://
  if grep -q 'text_tokenizer_file.*hf://' "${TTS_CONFIG}"; then
    echo "[06-verify] ERROR: Config should use local tokenizer path, not hf://"
    ERRORS=$((ERRORS + 1))
  fi
fi

# 2) Check if voices directory exists and has content
echo ""
echo "=== Voices directory verification ==="
if [ ! -d "${VOICES_DIR}" ]; then
  echo "[06-verify] ERROR: Voices directory missing: ${VOICES_DIR}"
  ERRORS=$((ERRORS + 1))
else
  VOICE_COUNT=$(find "${VOICES_DIR}" -type f \( -name '*.safetensors' -o -name '*.wav' \) | wc -l)
  echo "[06-verify] Voices directory exists with ${VOICE_COUNT} files"
  
  if [ "$VOICE_COUNT" -lt 100 ]; then
    echo "[06-verify] ERROR: Too few voice files (expected 900+, got ${VOICE_COUNT})"
    ERRORS=$((ERRORS + 1))
  fi
  
  # Check specifically for p004 files
  echo ""
  echo "=== P004 voice files ==="
  P004_FILES=$(find "${VOICES_DIR}/ears/p004" -maxdepth 1 -type f | wc -l)
  if [ "$P004_FILES" -eq 0 ]; then
    echo "[06-verify] ERROR: No p004 voice files found"
    ERRORS=$((ERRORS + 1))
  else
    echo "[06-verify] Found ${P004_FILES} p004 voice files:"
    find "${VOICES_DIR}/ears/p004" -maxdepth 1 -type f | head -5
  fi
fi

# 3) Check if server is running and accessible
echo ""
echo "=== Server connectivity ==="
if command -v curl >/dev/null 2>&1; then
  if curl -s --max-time 5 "http://127.0.0.1:${TTS_PORT}/api/build_info" >/dev/null; then
    echo "[06-verify] Server is responding on port ${TTS_PORT}"
  else
    echo "[06-verify] WARNING: Server not responding on port ${TTS_PORT} (may still be starting)"
  fi
else
  echo "[06-verify] curl not available, skipping server connectivity check"
fi

# 4) Check recent server logs for voice loading
echo ""
echo "=== Server logs (voice loading) ==="
if [ -f "${TTS_LOG_DIR}/tts-server.log" ]; then
  echo "[06-verify] Recent voice-related log entries:"
  grep -i "voice\|loading\|warming\|p004\|ears" "${TTS_LOG_DIR}/tts-server.log" | tail -10 || echo "No voice-related logs found"
else
  echo "[06-verify] WARNING: Server log file not found: ${TTS_LOG_DIR}/tts-server.log"
fi

# Summary
echo ""
echo "=== Verification Summary ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "[06-verify] ✅ All checks passed! Configuration looks correct."
  echo "[06-verify] Voice: ${TTS_VOICE:-ears/p004/freeform_speech_01.wav}"
  echo "[06-verify] Server: ws://127.0.0.1:${TTS_PORT}/api/tts_streaming"
else
  echo "[06-verify] ❌ Found ${ERRORS} configuration errors that need fixing"
  echo "[06-verify] Run: rm -f '${TTS_CONFIG}' && bash scripts/02_fetch_tts_configs.sh"
  exit 1
fi
