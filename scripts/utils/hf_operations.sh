#!/usr/bin/env bash
# -------- HUGGINGFACE OPERATIONS --------
# HuggingFace token validation & download operations

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Function to check HF_TOKEN is set and not empty
check_hf_token() {
  local script_name="${1:-hf-ops}"
  
  if [ -z "${HF_TOKEN:-}" ]; then
    log_error "$script_name" "HF_TOKEN environment variable is not set or is empty."
    echo "Please set your HuggingFace token: export HF_TOKEN=your_token_here" >&2
    echo "You can get a token from: https://huggingface.co/settings/tokens" >&2
    exit 1
  fi
  
  log_info "$script_name" "HF_TOKEN is set and available for HuggingFace operations"
}

# Download HuggingFace model with error handling
download_hf_model() {
  local script_name="$1"
  local repo_name="$2"
  local local_dir="$3"
  local python_bin="${4:-python}"
  
  log_info "$script_name" "Downloading model $repo_name to $local_dir"
  
  ensure_dir "$local_dir"
  export MODEL_DIR="$local_dir"
  export HF_REPO="$repo_name"
  
  "$python_bin" - <<'PY'
import os
import sys
from huggingface_hub import snapshot_download

dst = os.environ.get("MODEL_DIR")
repo = os.environ.get("HF_REPO", "")

if not dst:
    print("ERROR: MODEL_DIR not set")
    sys.exit(1)

if not repo:
    print("ERROR: HF_REPO not set") 
    sys.exit(1)
    
print(f"Downloading {repo} to {dst}")
try:
    snapshot_download(repo, local_dir=dst, local_dir_use_symlinks=False, resume_download=True)
    print(f"Downloaded {repo} to {dst}")
except Exception as e:
    print(f"ERROR downloading {repo}: {e}")
    sys.exit(1)
PY
  
  local exit_code=$?
  if [ $exit_code -eq 0 ]; then
    log_success "$script_name" "Model download completed"
  else
    log_error "$script_name" "Model download failed"
    return 1
  fi
}

# Download HuggingFace voices with error handling
download_hf_voices() {
  local script_name="$1"
  local voices_dir="$2" 
  local python_bin="${3:-python}"
  local allow_patterns="${4:-}"
  
  log_info "$script_name" "Downloading voices to $voices_dir"
  
  ensure_dir "$voices_dir"
  export VOICES_DIR="$voices_dir"
  export ALLOW_PATTERNS="$allow_patterns"
  
  "$python_bin" - <<'PY'
import os
import sys
from huggingface_hub import snapshot_download

dst = os.environ.get('VOICES_DIR')
patterns = os.environ.get('ALLOW_PATTERNS', '')

if not dst:
    print('ERROR: VOICES_DIR not set')
    sys.exit(1)

print(f'Downloading voices to: {dst}')
try:
    kwargs = {
        'local_dir': dst,
        'local_dir_use_symlinks': False,
        'resume_download': True
    }
    
    if patterns:
        kwargs['allow_patterns'] = patterns.split(',')
    
    snapshot_download('kyutai/tts-voices', **kwargs)
    print('Voices snapshot downloaded.')
except Exception as e:
    print(f'ERROR downloading voices: {e}')
    sys.exit(1)
PY

  local exit_code=$?
  if [ $exit_code -eq 0 ]; then
    log_success "$script_name" "Voices download completed"
  else
    log_error "$script_name" "Voices download failed"
    return 1
  fi
}
