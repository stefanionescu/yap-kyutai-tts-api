#!/bin/bash
set -ex

# Set up Python library path
export LD_LIBRARY_PATH=$(python3 -c 'import sysconfig; print(sysconfig.get_config_var("LIBDIR"))')

# Login to HuggingFace if token provided
if [ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]; then
    uvx --from 'huggingface_hub[cli]' huggingface-cli login --token $HUGGING_FACE_HUB_TOKEN
fi

# Performance optimizations
export NVIDIA_TF32_OVERRIDE=1
export TORCH_ALLOW_TF32_CUBLAS=1
export TORCH_ALLOW_TF32_CUDNN=1
export CUDA_DEVICE_MAX_CONNECTIONS=64
export RAYON_NUM_THREADS=8
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1

# Disable deterministic workspace for speed
unset CUBLAS_WORKSPACE_CONFIG || true

# Enable torch optimizations
unset TORCHINDUCTOR_DISABLE || true
unset PYTORCH_JIT || true
unset NO_TORCH_COMPILE || true
unset NO_CUDA_GRAPH || true

# Start moshi-server
exec /root/.cargo/bin/moshi-server worker --config /app/config.toml --addr 0.0.0.0 --port 8089 "$@"
