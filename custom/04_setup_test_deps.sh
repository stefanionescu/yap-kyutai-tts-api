#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${BASE_DIR%/scripts}"

echo "[test-deps] Setting up test dependencies in existing venv"

# Use the venv created by 01_install_tts_server.sh (at repo root)
VENV_DIR="${ROOT_DIR}/.venv"
VENV_PY="${VENV_DIR}/bin/python"

if [ ! -x "$VENV_PY" ]; then
    echo "[test-deps] ERROR: venv not found at ${VENV_DIR}"
    echo "[test-deps] Run scripts/01_install_tts_server.sh first"
    exit 1
fi

echo "[test-deps] Using venv: ${VENV_DIR}"

# Ensure pip is installed in the venv
echo "[test-deps] Seeding pip into venv..."
if ! "$VENV_PY" -m ensurepip --upgrade 2>/dev/null; then
    echo "[test-deps] ensurepip failed, falling back to uv pip install"
    uv pip install --python "$VENV_PY" pip
fi

# Upgrade packaging basics
echo "[test-deps] Upgrading packaging tools..."
"$VENV_PY" -m pip install -U pip setuptools wheel

# Install test dependencies
echo "[test-deps] Installing test dependencies from requirements.txt..."
"$VENV_PY" -m pip install -r "${ROOT_DIR}/requirements.txt"

# Ensure CLI for HuggingFace like docker/start script
echo "[test-deps] Installing huggingface_hub CLI for login..."
uvx --from 'huggingface_hub[cli]' huggingface-cli -h >/dev/null 2>&1 || true

# Verify installation
echo "[test-deps] Verifying test dependencies..."
"$VENV_PY" -c "import msgpack, websockets, numpy; print('[test-deps] All test dependencies installed successfully')"

echo "[test-deps] Setup complete!"
echo "[test-deps] To run tests, use: .venv/bin/python test/warmup.py"
echo "[test-deps] Or activate venv with: source .venv/bin/activate"
