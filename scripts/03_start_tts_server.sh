#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

echo "[03-tts] Preparing environment"

export PATH="${CUDA_PREFIX:-/usr/local/cuda}/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
export CUDARC_NVRTC_PATH="${CUDARC_NVRTC_PATH:-${CUDA_PREFIX:-/usr/local/cuda}/lib64/libnvrtc.so}"
export HF_HOME HF_HUB_ENABLE_HF_TRANSFER

# Threading and allocator caps to reduce CPU thrash and make latency predictable
export RAYON_NUM_THREADS="${TTS_RAYON_THREADS:-1}"
export TOKIO_WORKER_THREADS="${TTS_TOKIO_THREADS:-4}"
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"
export MKL_NUM_THREADS="${MKL_NUM_THREADS:-1}"
# Trace logging is expensive under load; keep it lean in benchmarks
export RUST_LOG="${RUST_LOG:-info,moshi_server=info,moshi=info,candle_core=info,hyper=warn,axum=info,tokio=info}"
export RUST_BACKTRACE="${RUST_BACKTRACE:-full}"

# GPU concurrency knobs: avoid stream → connection aliasing at 8 by raising to 32
export CUDA_DEVICE_MAX_CONNECTIONS="${CUDA_DEVICE_MAX_CONNECTIONS:-32}"
unset CUDA_LAUNCH_BLOCKING || true
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
export CUDA_DEVICE_ORDER="${CUDA_DEVICE_ORDER:-PCI_BUS_ID}"

# Optionally disable Torch Inductor to avoid Python stdlib mismatch crashes during compile_worker
export TORCHINDUCTOR_DISABLE="${TORCHINDUCTOR_DISABLE:-1}"
export PYTORCH_JIT="${PYTORCH_JIT:-0}"

CFG="${TTS_CONFIG}"
LOG_DIR="${TTS_LOG_DIR}"
SESSION="${TTS_TMUX_SESSION}"
PORT="${TTS_PORT}"
ADDR="${TTS_ADDR}"
mkdir -p "${LOG_DIR}"

echo "[03-tts] Starting moshi TTS server (local build)…"
echo "[03-tts] Using config: ${CFG}"
echo "[03-tts] ROOT_DIR: ${ROOT_DIR}"

# Debug: Show voice and model configuration
echo "[03-tts] Voice & model config lines:"
grep -nE 'hf_repo|n_q|batch_size|voice_folder|default_voice|text_tokenizer_file|hf-snapshot' "${CFG}" || echo "No relevant config found"
echo "[03-tts] Reusing config at ${CFG} (no re-generation here)"

echo "[03-tts] Verifying voice embedding (.safetensors):"
echo "[03-tts] Expected: ${VOICES_DIR}/${TTS_VOICE}"
if [ -f "${VOICES_DIR}/${TTS_VOICE}" ]; then
    echo "[03-tts] ✓ Voice embedding found:"
    ls -lh "${VOICES_DIR}/${TTS_VOICE}"
    # Count available p004 embeddings
    P004_COUNT=$(find "${VOICES_DIR}/ears/p004" -maxdepth 1 -name "*.safetensors" 2>/dev/null | wc -l)
    echo "[03-tts] p004 embeddings available: ${P004_COUNT}"
else
    echo "[03-tts] ERROR: Voice embedding not found: ${VOICES_DIR}/${TTS_VOICE}" >&2
    echo "[03-tts] Available p004 files:" >&2
    find "${VOICES_DIR}" -path "*/p004/*" -type f 2>/dev/null || echo "None found" >&2
    exit 1
fi

# Show auth configuration so you know if the server requires API keys
echo "[03-tts] Auth configuration:"
grep -n 'authorized_ids' "$CFG" || echo "No auth configured (server is open)"

# Ensure Python libdir is on LD_LIBRARY_PATH for the Rust server
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY_BIN="${REPO_ROOT}/.venv/bin/python"
if [ -x "${PY_BIN}" ]; then
  PY_LIBDIR="$(${PY_BIN} - <<'PY'
import sysconfig; print(sysconfig.get_config_var("LIBDIR") or "")
PY
)"
else
  PY_LIBDIR="$(python - <<'PY'
import sysconfig; print(sysconfig.get_config_var("LIBDIR") or "")
PY
)"
fi
if [ -n "${PY_LIBDIR}" ]; then
  export LD_LIBRARY_PATH="${PY_LIBDIR}:${LD_LIBRARY_PATH:-}"
fi

# Ensure the embedded Python used by pyo3 points to our venv
export PYO3_PYTHON="${PY_BIN}"
# Use base Python stdlib for encodings, and the venv site-packages for deps
BASE_PREFIX="$(${PY_BIN} - <<'PY'
import sys
print(sys.base_prefix)
PY
)"
PY_SITE_PKGS="$(${PY_BIN} - <<'PY'
import site
paths = []
paths.extend([p for p in site.getsitepackages() if 'site-packages' in p])
try:
    paths.append(site.getusersitepackages())
except Exception:
    pass
print(':'.join(paths))
PY
)"
export PYTHONHOME="${BASE_PREFIX}"
export PYTHONPATH="${PY_SITE_PKGS}:${PYTHONPATH:-}"
export PYTHONNOUSERSITE=1

# Prefer TF32 for faster matmuls on Ampere+ (harmless on others)
export NVIDIA_TF32_OVERRIDE="${NVIDIA_TF32_OVERRIDE:-1}"
export TORCH_ALLOW_TF32_CUBLAS="${TORCH_ALLOW_TF32_CUBLAS:-1}"
export TORCH_ALLOW_TF32_CUDNN="${TORCH_ALLOW_TF32_CUDNN:-1}"

# Build local moshi-server binary from the checked-out repo to ensure we use local sources
MOSHI_ROOT="${REPO_ROOT}/moshi"
if [ -d "${MOSHI_ROOT}/rust/moshi-server" ]; then
  echo "[03-tts] Building local moshi-server with CUDA…"
  (cd "${MOSHI_ROOT}/rust/moshi-server" && env PYO3_PYTHON="${PYO3_PYTHON}" cargo clean && env PYO3_PYTHON="${PYO3_PYTHON}" cargo build -r --features=cuda | cat)
  MOSHI_BIN="${MOSHI_ROOT}/rust/target/release/moshi-server"
  if [ ! -x "$MOSHI_BIN" ]; then
    # Some setups place target at repo root
    MOSHI_BIN="${MOSHI_ROOT}/rust/target/release/moshi-server"
  fi
else
  echo "[03-tts] ERROR: Local moshi repo not found at ${MOSHI_ROOT}." >&2
  exit 1
fi

# Prefer tmux; fallback to nohup if tmux not installed
TMUX_BIN="${TMUX_BIN:-tmux}"
if command -v "${TMUX_BIN}" >/dev/null 2>&1; then
  echo "[03-tts] Using tmux session '${SESSION}'"
  ${TMUX_BIN} has-session -t "${SESSION}" 2>/dev/null && ${TMUX_BIN} kill-session -t "${SESSION}"
  # Raise file descriptor limit for high concurrency
  ulimit -n 1048576 || true
  ${TMUX_BIN} new-session -d -s "${SESSION}" \
    "cd '${REPO_ROOT}' && env LD_LIBRARY_PATH='${LD_LIBRARY_PATH}' PYO3_PYTHON='${PYO3_PYTHON}' RAYON_NUM_THREADS='${RAYON_NUM_THREADS}' TOKIO_WORKER_THREADS='${TOKIO_WORKER_THREADS}' MALLOC_ARENA_MAX='${MALLOC_ARENA_MAX}' RUST_LOG='${RUST_LOG}' RUST_BACKTRACE='${RUST_BACKTRACE}' CUDA_DEVICE_MAX_CONNECTIONS='${CUDA_DEVICE_MAX_CONNECTIONS}' CUDA_VISIBLE_DEVICES='${CUDA_VISIBLE_DEVICES}' CUDA_DEVICE_ORDER='${CUDA_DEVICE_ORDER}' NVIDIA_TF32_OVERRIDE='${NVIDIA_TF32_OVERRIDE}' TORCH_ALLOW_TF32_CUBLAS='${TORCH_ALLOW_TF32_CUBLAS}' TORCH_ALLOW_TF32_CUDNN='${TORCH_ALLOW_TF32_CUDNN}' TORCHINDUCTOR_DISABLE='${TORCHINDUCTOR_DISABLE}' PYTORCH_JIT='${PYTORCH_JIT}' '${MOSHI_BIN}' worker --config '${CFG}' --addr '${ADDR}' --port '${PORT}' 2>&1 | tee '${LOG_DIR}/tts-server.log'"
else
  echo "[03-tts] tmux not found; using nohup fallback"
  ulimit -n 1048576 || true
  nohup sh -c "cd '${REPO_ROOT}' && env LD_LIBRARY_PATH='${LD_LIBRARY_PATH}' PYO3_PYTHON='${PYO3_PYTHON}' RAYON_NUM_THREADS='${RAYON_NUM_THREADS}' TOKIO_WORKER_THREADS='${TOKIO_WORKER_THREADS}' MALLOC_ARENA_MAX='${MALLOC_ARENA_MAX}' RUST_LOG='${RUST_LOG}' RUST_BACKTRACE='${RUST_BACKTRACE}' CUDA_DEVICE_MAX_CONNECTIONS='${CUDA_DEVICE_MAX_CONNECTIONS}' CUDA_VISIBLE_DEVICES='${CUDA_VISIBLE_DEVICES}' CUDA_DEVICE_ORDER='${CUDA_DEVICE_ORDER}' NVIDIA_TF32_OVERRIDE='${NVIDIA_TF32_OVERRIDE}' TORCH_ALLOW_TF32_CUBLAS='${TORCH_ALLOW_TF32_CUBLAS}' TORCH_ALLOW_TF32_CUDNN='${TORCH_ALLOW_TF32_CUDNN}' TORCHINDUCTOR_DISABLE='${TORCHINDUCTOR_DISABLE}' PYTORCH_JIT='${PYTORCH_JIT}' '${MOSHI_BIN}' worker --config '${CFG}' --addr '${ADDR}' --port '${PORT}'" \
    > "${LOG_DIR}/tts-server.log" 2>&1 &
fi

# Wait for the port to open
for i in $(seq 1 180); do
  (exec 3<>/dev/tcp/127.0.0.1/${PORT}) >/dev/null 2>&1 && { exec 3>&-; break; }
  sleep 1
  if [ $i -eq 180 ]; then
    echo "[03-tts] ERROR: TTS server didn’t open port ${PORT} in time."
    tail -n 50 "${LOG_DIR}/tts-server.log" || true
    exit 1
  fi
done

echo "[03-tts] Bound at ws://${ADDR}:${PORT}"
echo "[03-tts] Logs: ${LOG_DIR}/tts-server.log"

# Always confirm GPU use at boot - Candle backend logs which device it picked
echo "[03-tts] GPU/device initialization:"
sleep 1
tail -n +1 "${LOG_DIR}/tts-server.log" | grep -E "CUDA|Cuda|device|loading" -n || true

# Show voice loading hints from the log
echo "[03-tts] Voice loading hints:"
sleep 1  # Give server a moment to log voice initialization
tail -n +1 "${LOG_DIR}/tts-server.log" | grep -E "voice|embedding|p004|safetensors|default_voice" -n || echo "No voice loading logs found yet"
