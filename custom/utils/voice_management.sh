#!/usr/bin/env bash
# -------- VOICE MANAGEMENT --------
# Voice validation and management operations

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Function to validate all required voices are available
validate_all_voices() {
  local script_name="${1:-voice-mgmt}"
  local voices_base="${2:-${VOICES_DIR:-${ROOT_DIR}/.data/voices}}"
  
  local required_voices=(
    "ears/p058/freeform_speech_01.wav"
    "ears/p059/freeform_speech_01.wav"
    "ears/p068/freeform_speech_01.wav"
    "ears/p081/freeform_speech_01.wav"
    "ears/p086/freeform_speech_01.wav"
    "ears/p100/freeform_speech_01.wav"
  )
  
  log_info "$script_name" "Validating required voice files..."
  local missing_voices=()
  local found_count=0
  
  for voice in "${required_voices[@]}"; do
    local voice_path="${voices_base}/${voice}"
    if [[ "$voice" == *".wav" ]]; then
      # For .wav files, check exact path
      if [ -f "$voice_path" ]; then
        log_info "$script_name" "✓ Found: ${voice}"
        ((found_count++))
      else
        log_info "$script_name" "✗ Missing: ${voice}"
        missing_voices+=("$voice")
      fi
    else
      # For voice-donations/boom, look for any files in that directory
      if [ -d "$voice_path" ] && [ "$(find "$voice_path" -type f | wc -l)" -gt 0 ]; then
        log_info "$script_name" "✓ Found directory with files: ${voice}"
        ((found_count++))
      else
        log_info "$script_name" "✗ Missing or empty: ${voice}"
        missing_voices+=("$voice")
      fi
    fi
  done
  
  log_info "$script_name" "Voice validation: ${found_count}/${#required_voices[@]} required voices available"
  
  if [ ${#missing_voices[@]} -gt 0 ]; then
    log_error "$script_name" "Missing required voice files/directories:"
    for missing in "${missing_voices[@]}"; do
      echo "[$script_name]   - ${missing}" >&2
    done
    log_error "$script_name" "Please ensure all voices are downloaded and available"
    return 1
  fi
  
  log_success "$script_name" "All required voices are available"
  return 0
}

# Ensure voice availability with re-download if needed
ensure_voice_availability() {
  local script_name="$1"
  local voices_dir="$2"
  local python_bin="$3"
  local force_redownload="${4:-false}"
  
  # Check if voices exist (not just empty directory)
  local voice_count=0
  if [ -d "$voices_dir" ]; then
    voice_count=$(find "$voices_dir" -type f \( -name '*.safetensors' -o -name '*.wav' \) | wc -l)
  fi
  
  if [ "$voice_count" -gt 0 ] && [ "$force_redownload" != "true" ]; then
    log_info "$script_name" "Voices already present in $voices_dir ($voice_count files, skip download)"
  else
    log_info "$script_name" "Downloading ALL voices to $voices_dir (kyutai/tts-voices)"
    source "$(dirname "${BASH_SOURCE[0]}")/hf_operations.sh"
    download_hf_voices "$script_name" "$voices_dir" "$python_bin"
  fi

  # Validate that all required voices are available
  if ! validate_all_voices "$script_name" "$voices_dir"; then
    log_warning "$script_name" "Not all required voices are available. Re-downloading voices..."
    
    # Force re-download by removing and re-fetching
    log_info "$script_name" "Removing existing voices directory for fresh download"
    rm -rf "$voices_dir"
    ensure_dir "$voices_dir"
    
    source "$(dirname "${BASH_SOURCE[0]}")/hf_operations.sh"
    download_hf_voices "$script_name" "$voices_dir" "$python_bin"
    
    # Validate again after re-download
    if ! validate_all_voices "$script_name" "$voices_dir"; then
      log_error "$script_name" "FATAL ERROR: Required voices still missing after re-download"
      exit 1
    fi
  fi
}

# Verify specific voice embedding exists
verify_voice_embedding() {
  local script_name="$1"
  local voices_dir="$2"
  local voice_path="$3"
  
  local full_voice_path="${voices_dir}/${voice_path}"
  
  log_info "$script_name" "Verifying voice embedding (.safetensors):"
  log_info "$script_name" "Expected: $full_voice_path"
  
  if [ -f "$full_voice_path" ]; then
    log_success "$script_name" "Voice embedding found:"
    ls -lh "$full_voice_path" >&2
    return 0
  else
    log_error "$script_name" "Voice embedding not found: $full_voice_path"
    log_error "$script_name" "Available files:"
    find "$voices_dir" -name "*.safetensors" -o -name "*.wav" | head -10 >&2 || echo "None found" >&2
    return 1
  fi
}

# Ensure specific voice directory has files
ensure_speaker_voice() {
  local script_name="$1"
  local voices_dir="$2"
  local speaker_dir="$3"
  local python_bin="$4"
  
  local speaker_path="${voices_dir}/${speaker_dir}"
  ensure_dir "$speaker_path"
  
  local file_count=$(find "$speaker_path" -maxdepth 1 -type f -name "*.safetensors" | wc -l)
  
  if [ "$file_count" -eq 0 ]; then
    log_info "$script_name" "Ensuring $speaker_dir voice embedding is present"
    
    source "$(dirname "${BASH_SOURCE[0]}")/hf_operations.sh"
    download_hf_voices "$script_name" "$voices_dir" "$python_bin" "${speaker_dir}/*"
  else
    log_info "$script_name" "$speaker_dir embeddings available: $file_count"
  fi
}
