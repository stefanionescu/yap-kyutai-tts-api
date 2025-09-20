# Yap Kyutai TTS API - Production Docker Image
# Based on Kyutai's public setup with performance optimizations
FROM nvidia/cuda:12.8.1-devel-ubuntu22.04 AS base

# Set environment variables to avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    build-essential \
    ca-certificates \
    libssl-dev \
    git \
    pkg-config \
    cmake \
    wget \
    openssh-client \
    dos2unix \
    jq \
    tmux \
    libportaudio2 \
    libsndfile1 \
    libopus-dev \
    python3 \
    python3-pip \
    python3-dev \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# Install Rust
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y
ENV PATH="/root/.cargo/bin:$PATH"

# Install UV package manager
COPY --from=ghcr.io/astral-sh/uv:0.7.2 /uv /uvx /bin/

WORKDIR /app

# Download Kyutai's pinned Python dependencies
RUN wget -O pyproject.toml https://raw.githubusercontent.com/kyutai-labs/moshi/bf359af7694add34c13e65d2f009f0cb474d87cc/rust/moshi-server/pyproject.toml
RUN wget -O uv.lock https://raw.githubusercontent.com/kyutai-labs/moshi/bf359af7694add34c13e65d2f009f0cb474d87cc/rust/moshi-server/uv.lock

# Install Python dependencies first (required for moshi-server compilation)
# Use system Python3 and install to system site-packages for simpler paths
RUN python3 -m pip install --upgrade pip
RUN python3 -m pip install --index-url https://download.pytorch.org/whl/cu128 torch torchvision torchaudio
RUN python3 -m pip install huggingface_hub sentencepiece numpy safetensors pydantic

# Set Python path for cargo compilation
ENV PYO3_PYTHON=/usr/bin/python3
RUN python3 -c "import sysconfig; print('LIBDIR:', sysconfig.get_config_var('LIBDIR'))"

# Set CUDA paths for candle-kernels compilation
ENV CUDA_ROOT=/usr/local/cuda
ENV CUDA_PATH=/usr/local/cuda
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=/usr/local/cuda/bin:$PATH
ENV LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/local/cuda/lib64:/usr/local/cuda/targets/x86_64-linux/lib
ENV LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/targets/x86_64-linux/lib

# Verify CUDA installation for candle-kernels
RUN nvcc --version
RUN ls -la /usr/local/cuda/bin/nvcc
RUN ls -la /usr/local/cuda/lib64/

# Set CUDA compute capability for L40S/A100 (helps candle-kernels)
ENV CUDA_COMPUTE_CAP=89

# Copy application files
COPY . .

# Install moshi-server with CUDA support (after Python is available)
RUN CARGO_TARGET_DIR=/app/target cargo install --features cuda moshi-server@0.6.3

# Create startup script
COPY docker/start_server.sh /app/start_server.sh
RUN chmod +x /app/start_server.sh

# Copy optimized config
COPY docker/config.toml /app/config.toml

# Health check
HEALTHCHECK --start-period=10m \
    CMD curl --fail http://localhost:8089/api/build_info || exit 1

EXPOSE 8089
ENV RUST_BACKTRACE=1

ENTRYPOINT ["/app/start_server.sh"]
