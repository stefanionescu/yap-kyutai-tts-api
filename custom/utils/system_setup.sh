#!/usr/bin/env bash
# -------- SYSTEM SETUP --------
# System packages, Rust, and Python environment setup

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Install system packages for TTS server
install_system_packages() {
  local script_name="$1"
  
  log_info "$script_name" "Installing system dependencies"
  
  export DEBIAN_FRONTEND=noninteractive
  if command_exists apt-get; then
    apt-get update -y
    # Parity with docker/Dockerfile
    apt-get install -y --no-install-recommends \
      curl jq \
      build-essential \
      ca-certificates \
      libssl-dev \
      git \
      pkg-config \
      cmake \
      wget \
      openssh-client \
      dos2unix \
      python3 \
      python3-pip
    log_success "$script_name" "System packages installed"
  else
    log_warning "$script_name" "apt-get not available, skipping system package installation"
  fi
  
  # OpenSSL discovery hints (common on Ubuntu/Debian)
  export OPENSSL_DIR=/usr/lib/x86_64-linux-gnu
  export OPENSSL_LIB_DIR=/usr/lib/x86_64-linux-gnu
  export OPENSSL_INCLUDE_DIR=/usr/include
}

# Setup Rust toolchain
setup_rust_toolchain() {
  local script_name="$1"
  
  log_info "$script_name" "Setting up Rust toolchain"
  
  # Ensure rustup/cargo and select a default toolchain
  if ! command_exists rustup; then
    log_info "$script_name" "Installing Rust via rustup"
    curl https://sh.rustup.rs -sSf | sh -s -- -y
  fi
  
  # Ensure cargo/rustup in PATH for this shell
  # shellcheck source=/dev/null
  source "$HOME/.cargo/env" 2>/dev/null || true
  export PATH="$HOME/.cargo/bin:$PATH"
  
  # Install & select a default toolchain (idempotent)
  rustup set profile minimal
  rustup toolchain install stable --profile minimal
  rustup default stable
  
  # Verify toolchain is usable
  if rustc -V >/dev/null 2>&1 && cargo -V >/dev/null 2>&1; then
    log_success "$script_name" "Rust toolchain ready: $(rustc -V | head -1)"
  else
    log_error "$script_name" "Rust toolchain setup failed"
    return 1
  fi
}

# Setup Python virtual environment  
setup_python_environment() {
  local script_name="$1"
  local repo_root="$2"
  
  log_info "$script_name" "Setting up Python virtual environment"
  
  # Ensure uv for pinned Python deps
  if ! command_exists uv; then
    log_info "$script_name" "Installing uv package manager"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  fi
  
  # Prefer a known-good uv version (parity with Docker image 0.7.2) if available
  if command_exists uv; then
    log_info "$script_name" "uv version: $(uv --version 2>/dev/null || echo unknown)"
  fi
  
  # Avoid uv hardlink warnings across filesystems
  export UV_LINK_MODE=copy
  
  # Create a controlled venv at repo root
  cd "$repo_root"
  if [ -d ".venv" ]; then
    log_info "$script_name" "Replacing existing venv"
    uv venv --clear
  else
    log_info "$script_name" "Creating new venv"
    uv venv
  fi
  
  # shellcheck source=/dev/null
  source .venv/bin/activate
  log_success "$script_name" "Python virtual environment ready"
}

# Install Python dependencies from moshi manifests
install_python_deps() {
  local script_name="$1"
  local repo_root="$2"
  local moshi_root="${3:-${repo_root}/moshi}"
  
  log_info "$script_name" "Installing Python dependencies"
  
  cd "$repo_root"
  
  # Use the repository-pinned pyproject and uv.lock (parity with Dockerfile)
  cp "${moshi_root}/rust/moshi-server/pyproject.toml" pyproject.toml
  cp "${moshi_root}/rust/moshi-server/uv.lock" uv.lock
  uv sync --locked --no-dev
  
  # Install test dependencies as Dockerfile does (into our venv instead of --system)
  log_info "$script_name" "Installing test dependencies (msgpack websockets python-dotenv numpy)"
  uv pip install --python "$(pwd)/.venv/bin/python" msgpack websockets python-dotenv numpy
  
  log_success "$script_name" "Python dependencies installed"
}

# Setup Python library paths for Rust runtime
setup_python_lib_paths() {
  local script_name="$1"
  local python_bin="$2"
  
  log_info "$script_name" "Setting up Python library paths"
  
  # Make Python's lib visible to the Rust build/runtime
  local py_libdir
  py_libdir="$("$python_bin" - <<'PY'
import sysconfig; print(sysconfig.get_config_var("LIBDIR") or "")
PY
)"
  
  if [ -n "${py_libdir}" ]; then
    export LD_LIBRARY_PATH="${py_libdir}:${LD_LIBRARY_PATH:-}"
    log_info "$script_name" "Added Python lib directory to LD_LIBRARY_PATH: $py_libdir"
  fi
  
  # Ensure the embedded Python used by pyo3 points to our venv
  export PYO3_PYTHON="$python_bin"

  # Provide explicit stdlib and site-packages paths so any spawned Python
  # processes (e.g., torch compile helpers) resolve encodings correctly.
  # These are derived from the venv's interpreter to ensure compatibility.
  local base_prefix
  base_prefix="$("$python_bin" - <<'PY'
import sys
print(sys.base_prefix or sys.prefix)
PY
)"

  local py_site_pkgs
  py_site_pkgs="$("$python_bin" - <<'PY'
import site
paths = []
paths.extend([p for p in site.getsitepackages() if 'site-packages' in p])
try:
    usp = site.getusersitepackages()
    if usp:
        paths.append(usp)
except Exception:
    pass
print(':'.join(paths))
PY
)"

  export PYTHONHOME="$base_prefix"
  export PYTHONPATH="${py_site_pkgs}:${PYTHONPATH:-}"
  export PYTHONNOUSERSITE=1
  
  log_success "$script_name" "Python environment configured for Rust runtime"
}
