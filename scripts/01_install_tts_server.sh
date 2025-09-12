#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
echo "[01-tts] Preparing environment and Python deps for local moshi TTS server…"

export PATH="${CUDA_PREFIX:-/usr/local/cuda}/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

# --- Ensure native deps for openssl-sys and networking ---
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y --no-install-recommends build-essential pkg-config libssl-dev libopus-dev cmake ca-certificates tmux libportaudio2 libsndfile1
fi
# OpenSSL discovery hints (common on Ubuntu/Debian)
export OPENSSL_DIR=/usr/lib/x86_64-linux-gnu
export OPENSSL_LIB_DIR=/usr/lib/x86_64-linux-gnu
export OPENSSL_INCLUDE_DIR=/usr/include
# Avoid uv hardlink warnings across filesystems
export UV_LINK_MODE=copy

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Ensure rustup/cargo and select a default toolchain
if ! command -v rustup >/dev/null 2>&1; then
  curl https://sh.rustup.rs -sSf | sh -s -- -y
fi
# Ensure cargo/rustup in PATH for this shell
source "$HOME/.cargo/env" 2>/dev/null || true
export PATH="$HOME/.cargo/bin:$PATH"
# Install & select a default toolchain (idempotent)
rustup set profile minimal
rustup toolchain install stable --profile minimal
rustup default stable
# Optional: verify toolchain is usable
rustc -V || true
cargo -V || true

# Ensure uv for pinned Python deps
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

# Create a controlled venv at repo root
cd "${SCRIPT_DIR}/.."  # Go to repo root
uv venv
source .venv/bin/activate

# Use local moshi repo's moshi-server Python manifests to install exact deps
MOSHI_ROOT="$(pwd)/moshi"
if [ -f "${MOSHI_ROOT}/rust/moshi-server/pyproject.toml" ] && [ -f "${MOSHI_ROOT}/rust/moshi-server/uv.lock" ]; then
  echo "[01-tts] Installing Python deps from local moshi rust/moshi-server manifests"
  cp -f "${MOSHI_ROOT}/rust/moshi-server/pyproject.toml" ./pyproject.toml
  cp -f "${MOSHI_ROOT}/rust/moshi-server/uv.lock" ./uv.lock
  uv sync --frozen --no-dev
else
  echo "[01-tts] WARNING: Local moshi manifests not found; falling back to fetching from GitHub"
  MOSHI_REF="aee53fc"
  [ -f pyproject.toml ] || wget -q "https://raw.githubusercontent.com/kyutai-labs/moshi/${MOSHI_REF}/rust/moshi-server/pyproject.toml"
  [ -f uv.lock ] || wget -q "https://raw.githubusercontent.com/kyutai-labs/moshi/${MOSHI_REF}/rust/moshi-server/uv.lock"
  uv sync --frozen --no-dev
fi

# Make Python's lib visible to the Rust build/runtime
export LD_LIBRARY_PATH="$(python - <<'PY'
import sysconfig; print(sysconfig.get_config_var("LIBDIR"))
PY
):${LD_LIBRARY_PATH:-}"

# GCC 15 workaround used by Kyutai (SentencePiece)
export CXXFLAGS="-include cstdint"

echo "[01-tts] Python deps ready; local moshi-server will be built in the start script."
