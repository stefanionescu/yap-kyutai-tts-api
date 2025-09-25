# Exact copy of Kyutai's public Docker setup
FROM nvidia/cuda:12.8.1-devel-ubuntu22.04 AS base

# Set environment variables to avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies, including dos2unix to handle Windows line endings
RUN apt-get update && apt-get install -y \
    curl \
    jq \
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
    python3-pip \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y
ENV PATH="/root/.cargo/bin:$PATH"

COPY --from=ghcr.io/astral-sh/uv:0.7.2 /uv /uvx /bin/

WORKDIR /app

# When starting the container for the first time, we need to compile and download
# everything, so disregarding healthcheck failure for 10 minutes is fine.
# We have a volume storing the build cache, so subsequent starts will be faster.
HEALTHCHECK --start-period=10m \
    CMD curl --fail http://localhost:8089/api/build_info || exit 1

EXPOSE 8089
ENV RUST_BACKTRACE=1
ENV RUST_LOG=${RUST_LOG:-info}

RUN wget https://raw.githubusercontent.com/Yap-With-AI/moshi/bf359af7694add34c13e65d2f009f0cb474d87cc/rust/moshi-server/pyproject.toml
RUN wget https://raw.githubusercontent.com/Yap-With-AI/moshi/bf359af7694add34c13e65d2f009f0cb474d87cc/rust/moshi-server/uv.lock

# Install Python test/client dependencies from requirements.txt into a project venv
COPY requirements.txt /app/requirements.txt
# Create a project-local virtualenv so interactive shells use it too
RUN uv venv && \
    uv pip install --python /app/.venv/bin/python -r /app/requirements.txt

# Copy config and startup script (from repo configs)
COPY configs/config.toml /app/config.toml
COPY test/ /app/test/
COPY docker/scripts/start_moshi.sh ./start_moshi.sh

# Ensure the startup script is runnable inside the container.
RUN dos2unix ./start_moshi.sh && chmod +x ./start_moshi.sh

# Create python symlink for tests (system fallback)
RUN ln -sf /usr/bin/python3 /usr/bin/python

# Default to the project venv for interactive sessions
ENV VIRTUAL_ENV=/app/.venv
ENV PATH=/app/.venv/bin:$PATH

ENTRYPOINT ["uv", "run", "--locked", "./start_moshi.sh"]
