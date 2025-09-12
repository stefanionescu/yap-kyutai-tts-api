#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
echo "[01-tts] Installing moshi TTS server…"

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

# Pull the Python dep manifests Kyutai uses for the TTS Rust server, pinned to a commit
MOSHI_REF="aee53fc"  # update if you need a newer known-good ref
[ -f pyproject.toml ] || wget -q "https://raw.githubusercontent.com/kyutai-labs/moshi/${MOSHI_REF}/rust/moshi-server/pyproject.toml"
[ -f uv.lock ] || wget -q "https://raw.githubusercontent.com/kyutai-labs/moshi/${MOSHI_REF}/rust/moshi-server/uv.lock"

# Install pinned Python dependencies into the venv
uv sync --frozen --no-dev

# Make Python's lib visible to the Rust build/runtime
export LD_LIBRARY_PATH="$(python - <<'PY'
import sysconfig; print(sysconfig.get_config_var("LIBDIR"))
PY
):${LD_LIBRARY_PATH:-}"

# GCC 15 workaround used by Kyutai (SentencePiece)
export CXXFLAGS="-include cstdint"

# Install/update the Rust server with CUDA, pinned version
MOSHI_VERSION="0.6.3"
# cargo uninstall moshi-server >/dev/null 2>&1 || true
cargo install --features cuda "moshi-server@${MOSHI_VERSION}"

echo "[01-tts] moshi-server: $(command -v moshi-server || echo '<not found>')"
