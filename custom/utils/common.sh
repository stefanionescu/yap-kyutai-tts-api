#!/usr/bin/env bash
# -------- COMMON UTILITIES --------
# Basic utility functions & standardized logging

# Standardized logging with script prefix
log_info() {
  local script_name="${1:-unknown}"
  local message="$2"
  echo "[$script_name] $message" >&2
}

log_error() {
  local script_name="${1:-unknown}"
  local message="$2"
  echo "[$script_name] ERROR: $message" >&2
}

log_success() {
  local script_name="${1:-unknown}"
  local message="$2"
  echo "[$script_name] ✅ $message" >&2
}

log_warning() {
  local script_name="${1:-unknown}"
  local message="$2"
  echo "[$script_name] WARNING: $message" >&2
}

# Safe directory creation
ensure_dir() {
  local dir="$1"
  if [ -n "$dir" ]; then
    mkdir -p "$dir"
  fi
}

# Check if command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Get script directory helper
get_script_dir() {
  cd "$(dirname "${BASH_SOURCE[1]}")" && pwd
}

# Get repo root from any script location
get_repo_root() {
  local script_dir
  script_dir="$(get_script_dir)"
  echo "${script_dir%/scripts}"
}
