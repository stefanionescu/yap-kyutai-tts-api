#!/usr/bin/env bash
# -------- VERIFICATION --------
# All verification and testing logic

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Verify config file exists and has correct settings
verify_config_file() {
  local script_name="$1"
  local config_file="$2"
  
  local errors=0
  
  log_info "$script_name" "Config file verification"
  
  if [ ! -f "$config_file" ]; then
    log_error "$script_name" "Config file missing: $config_file"
    return 1
  fi
  
  log_success "$script_name" "Config file exists: $config_file"
  
  # Show current config voice settings
  log_info "$script_name" "Current config voice settings:"
  grep -A3 -B3 "voice_folder\|default_voice\|n_q\|hf_repo\|batch_size\|text_tokenizer_file\|log_folder" "$config_file" >&2 || true
  
  # Validate specific settings for 1.6B
  if grep -q 'voice_folder.*hf-snapshot' "$config_file"; then
    log_error "$script_name" "Config still uses HF snapshot, should use local path"
    ((errors++))
  fi

  if ! grep -q 'n_q = 24' "$config_file"; then
    log_error "$script_name" "Config should have n_q = 24 (inference baseline) for 1.6B model"
    ((errors++))
  fi

  # Accept cfg_* and padding_between/interleaved_text_only fields (Unmute uses them)
  # No error here; informational only
  if grep -E '^[[:space:]]*cfg_is_no_text[[:space:]]*=|^[[:space:]]*cfg_coef[[:space:]]*=' "$config_file"; then
    log_info "$script_name" "CFG-related fields present (ok)"
  fi
  if grep -E '^[[:space:]]*padding_between[[:space:]]*=|^[[:space:]]*interleaved_text_only[[:space:]]*=' "$config_file"; then
    log_info "$script_name" "Padding/interleave fields present (ok)"
  fi

  # batch_size must match our target concurrency (from env or default 32)
  local expected_bs
  expected_bs="${TTS_BATCH_SIZE:-16}"
  if ! grep -q "batch_size = ${expected_bs}" "$config_file"; then
    log_error "$script_name" "Config should have batch_size = ${expected_bs}"
    ((errors++))
  fi

  if ! grep -q 'log_folder.*moshi-server-logs' "$config_file"; then
    log_error "$script_name" "Config should have log_folder with moshi-server-logs"
    ((errors++))
  fi

  if ! grep -q 'default_voice.*ears/p004' "$config_file"; then
    log_error "$script_name" "Config should have default_voice under ears/p004 (attribute name)"
    ((errors++))
  fi

  if ! grep -q 'hf_repo.*tts-1.6b-en_fr' "$config_file"; then
    log_error "$script_name" "Config should have hf_repo = kyutai/tts-1.6b-en_fr"
    ((errors++))
  fi

  # Check tokenizer is using local path, not hf://
  if grep -q 'text_tokenizer_file.*hf://' "$config_file"; then
    log_error "$script_name" "Config should use local tokenizer path, not hf://"
    ((errors++))
  fi
  
  if [ $errors -eq 0 ]; then
    log_success "$script_name" "Config file validation passed"
    return 0
  else
    log_error "$script_name" "Config file has $errors validation errors"
    return 1
  fi
}

# Verify voices directory and required voices
verify_voice_setup() {
  local script_name="$1"
  local voices_dir="$2"
  
  local errors=0
  
  log_info "$script_name" "Voices directory verification"
  
  if [ ! -d "$voices_dir" ]; then
    log_error "$script_name" "Voices directory missing: $voices_dir"
    return 1
  fi
  
  local voice_count
  voice_count=$(find "$voices_dir" -type f \( -name '*.safetensors' -o -name '*.wav' \) | wc -l)
  log_info "$script_name" "Voices directory exists with $voice_count files"
  
  if [ "$voice_count" -lt 100 ]; then
    log_error "$script_name" "Too few voice files (expected 900+, got $voice_count)"
    ((errors++))
  fi
  
  # Use our comprehensive voice validation function
  log_info "$script_name" "Required voices validation"
  source "$(dirname "${BASH_SOURCE[0]}")/voice_management.sh"
  if ! validate_all_voices "$script_name" "$voices_dir"; then
    log_error "$script_name" "Required voices validation failed"
    ((errors++))
  fi
  
  # Check specifically for p004 files
  log_info "$script_name" "P004 voice files"
  local p004_files
  p004_files=$(find "${voices_dir}/ears/p004" -maxdepth 1 -type f | wc -l)
  if [ "$p004_files" -eq 0 ]; then
    log_error "$script_name" "No p004 voice files found"
    ((errors++))
  else
    log_info "$script_name" "Found $p004_files p004 voice files:"
    find "${voices_dir}/ears/p004" -maxdepth 1 -type f | head -5 >&2
  fi
  
  if [ $errors -eq 0 ]; then
    log_success "$script_name" "Voice setup verification passed"
    return 0
  else
    log_error "$script_name" "Voice setup has $errors validation errors"
    return 1
  fi
}

# Verify server connectivity
verify_server_connectivity() {
  local script_name="$1"
  local port="$2"
  
  log_info "$script_name" "Server connectivity"
  
  if command_exists curl; then
    if curl -s --max-time 5 "http://127.0.0.1:$port/api/build_info" >/dev/null; then
      log_success "$script_name" "Server is responding on port $port"
      return 0
    else
      log_warning "$script_name" "Server not responding on port $port (may still be starting)"
      return 1
    fi
  else
    log_warning "$script_name" "curl not available, skipping server connectivity check"
    return 0
  fi
}

# Check server logs for specific patterns
verify_server_logs() {
  local script_name="$1"
  local log_file="$2"
  local pattern="${3:-voice|loading|warming|p004|ears}"
  local description="${4:-voice-related}"
  
  log_info "$script_name" "Server logs ($description)"
  
  if [ -f "$log_file" ]; then
    log_info "$script_name" "Recent $description log entries:"
    grep -i "$pattern" "$log_file" | tail -10 >&2 || log_info "$script_name" "No $description logs found"
  else
    log_warning "$script_name" "Server log file not found: $log_file"
  fi
}

# Run complete verification suite
run_full_verification() {
  local script_name="$1"
  local config_file="$2"
  local voices_dir="$3"
  local port="$4"
  local log_file="$5"
  local tts_voice="${6:-}"
  
  log_info "$script_name" "Running complete verification suite"
  
  local total_errors=0
  
  # 1) Verify config file
  if ! verify_config_file "$script_name" "$config_file"; then
    ((total_errors++))
  fi
  
  # 2) Verify voice setup  
  if ! verify_voice_setup "$script_name" "$voices_dir"; then
    ((total_errors++))
  fi
  
  # 3) Verify server connectivity
  verify_server_connectivity "$script_name" "$port" || true  # Don't fail on this
  
  # 4) Check server logs
  verify_server_logs "$script_name" "$log_file" || true  # Don't fail on this
  
  # Summary
  log_info "$script_name" "Verification Summary"
  
  if [ "$total_errors" -eq 0 ]; then
    log_success "$script_name" "All checks passed! Configuration looks correct."
    if [ -n "$tts_voice" ]; then
      log_info "$script_name" "Voice: $tts_voice"
    fi
    log_info "$script_name" "Server: ws://127.0.0.1:$port/api/tts_streaming"
    return 0
  else
    log_error "$script_name" "Found $total_errors configuration errors that need fixing"
    log_error "$script_name" "Run: rm -f '$config_file' && bash scripts/02_fetch_tts_configs.sh"
    return 1
  fi
}
