#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
echo "[01-tts] Installing moshi TTS server…"

export PATH="${CUDA_PREFIX:-/usr/local/cuda}/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Ensure cargo
if ! command -v cargo >/dev/null 2>&1; then
  curl https://sh.rustup.rs -sSf | sh -s -- -y
  export PATH="$HOME/.cargo/bin:$PATH"
fi

# Ensure uv for pinned Python deps
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

# Create a controlled venv for the Python shim under scripts/
cd "${SCRIPT_DIR}"
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
