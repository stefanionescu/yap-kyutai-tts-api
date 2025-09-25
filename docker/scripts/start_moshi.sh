#!/bin/bash
# This is the public-facing version.
set -ex

export LD_LIBRARY_PATH=$(python3 -c 'import sysconfig; print(sysconfig.get_config_var("LIBDIR"))')

# Reduce CPU thread contention and tokenizer overhead
export CUDA_MODULE_LOADING=${CUDA_MODULE_LOADING:-EAGER}
export RAYON_NUM_THREADS=${RAYON_NUM_THREADS:-4}
export OMP_NUM_THREADS=${OMP_NUM_THREADS:-1}
export MKL_NUM_THREADS=${MKL_NUM_THREADS:-1}
export TOKENIZERS_PARALLELISM=${TOKENIZERS_PARALLELISM:-false}
export CUDA_DEVICE_MAX_CONNECTIONS=${CUDA_DEVICE_MAX_CONNECTIONS:-64}

# Performance optimizations
export NVIDIA_TF32_OVERRIDE=${NVIDIA_TF32_OVERRIDE:-1}
export TORCH_ALLOW_TF32_CUBLAS=${TORCH_ALLOW_TF32_CUBLAS:-1}
export TORCH_ALLOW_TF32_CUDNN=${TORCH_ALLOW_TF32_CUDNN:-1}
export RUST_LOG=${RUST_LOG:-info}

# Reduce memory allocator and CUDA allocator jitter under concurrency
export PYTORCH_CUDA_ALLOC_CONF=${PYTORCH_CUDA_ALLOC_CONF:-max_split_size_mb:128,expandable_segments:True}
export MALLOC_ARENA_MAX=${MALLOC_ARENA_MAX:-2}

uvx --from 'huggingface_hub[cli]' huggingface-cli login --token $HUGGING_FACE_HUB_TOKEN

CARGO_TARGET_DIR=/app/target cargo install --features cuda moshi-server@0.6.3

# Subtle detail here: We use the full path to `moshi-server` because there is a `moshi-server` binary
# from the `moshi` Python package. We'll fix this conflict soon.
/root/.cargo/bin/moshi-server worker --config /app/config.toml --addr 0.0.0.0 --port 8089
