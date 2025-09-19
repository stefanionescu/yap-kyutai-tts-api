#!/usr/bin/env bash
# -------- SERVER OPERATIONS --------
# Server building, startup & health checks

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Build local moshi-server binary from the checked-out repo
build_moshi_server() {
  local script_name="$1"
  local repo_root="$2"
  local python_bin="$3"
  
  local moshi_root="${repo_root}/moshi"
  
  if [ -d "${moshi_root}/rust/moshi-server" ]; then
    log_info "$script_name" "Building local moshi-server with CUDA…"
    
    (cd "${moshi_root}/rust/moshi-server" && \
     env PYO3_PYTHON="$python_bin" cargo clean && \
     env PYO3_PYTHON="$python_bin" cargo build -r --features=cuda | cat)
    
    local moshi_bin="${moshi_root}/rust/target/release/moshi-server"
    if [ ! -x "$moshi_bin" ]; then
      # Some setups place target at repo root
      moshi_bin="${moshi_root}/rust/target/release/moshi-server"
    fi
    
    if [ -x "$moshi_bin" ]; then
      log_success "$script_name" "Moshi server built successfully: $moshi_bin"
      echo "$moshi_bin"
      return 0
    else
      log_error "$script_name" "Moshi server binary not found after build"
      return 1
    fi
  else
    log_error "$script_name" "Local moshi repo not found at $moshi_root"
    return 1
  fi
}

# Start server using tmux
start_server_tmux() {
  local script_name="$1"
  local session_name="$2"
  local moshi_bin="$3"
  local config_file="$4"
  local addr="$5"
  local port="$6"
  local repo_root="$7"
  local log_file="$8"
  
  local tmux_bin="${TMUX_BIN:-tmux}"
  
  if ! command_exists "$tmux_bin"; then
    log_error "$script_name" "tmux not available"
    return 1
  fi
  
  log_info "$script_name" "Using tmux session '$session_name'"
  
  # Kill existing session if it exists
  $tmux_bin has-session -t "$session_name" 2>/dev/null && $tmux_bin kill-session -t "$session_name"
  
  # Raise file descriptor limit for high concurrency
  ulimit -n 1048576 || true
  
  # Build environment variable string
  # Ensure venv bin is first on PATH so any spawned python uses the venv interpreter
  local venv_bin_path="${repo_root}/.venv/bin"
  local env_vars="LD_LIBRARY_PATH='${LD_LIBRARY_PATH}'"
  env_vars="$env_vars PYO3_PYTHON='${PYO3_PYTHON}'"
  # Ensure Python stdlib/encodings and site-packages are visible to child processes
  env_vars="$env_vars PYTHONHOME='${PYTHONHOME}'"
  env_vars="$env_vars PYTHONPATH='${PYTHONPATH}'"
  env_vars="$env_vars PYTHONNOUSERSITE='${PYTHONNOUSERSITE}'"
  env_vars="$env_vars RAYON_NUM_THREADS='${RAYON_NUM_THREADS}'"
  env_vars="$env_vars TOKIO_WORKER_THREADS='${TOKIO_WORKER_THREADS}'"
  env_vars="$env_vars MALLOC_ARENA_MAX='${MALLOC_ARENA_MAX}'"
  env_vars="$env_vars RUST_LOG='${RUST_LOG}'"
  env_vars="$env_vars RUST_BACKTRACE='${RUST_BACKTRACE}'"
  env_vars="$env_vars CUDA_DEVICE_MAX_CONNECTIONS='${CUDA_DEVICE_MAX_CONNECTIONS}'"
  env_vars="$env_vars CUDA_VISIBLE_DEVICES='${CUDA_VISIBLE_DEVICES}'"
  env_vars="$env_vars CUDA_DEVICE_ORDER='${CUDA_DEVICE_ORDER}'"
  env_vars="$env_vars NVIDIA_TF32_OVERRIDE='${NVIDIA_TF32_OVERRIDE}'"
  env_vars="$env_vars TORCH_ALLOW_TF32_CUBLAS='${TORCH_ALLOW_TF32_CUBLAS}'"
  env_vars="$env_vars TORCH_ALLOW_TF32_CUDNN='${TORCH_ALLOW_TF32_CUDNN}'"
  env_vars="$env_vars TORCHINDUCTOR_DISABLE='${TORCHINDUCTOR_DISABLE}'"
  env_vars="$env_vars PYTORCH_JIT='${PYTORCH_JIT}'"
  # Pass HF Hub knobs to avoid XET throttling/bridge fetches
  env_vars="$env_vars HF_HOME='${HF_HOME:-}'"
  env_vars="$env_vars HF_HUB_DISABLE_XET='${HF_HUB_DISABLE_XET:-1}'"
  env_vars="$env_vars HF_HUB_ENABLE_HF_TRANSFER='${HF_HUB_ENABLE_HF_TRANSFER:-0}'"
  # Propagate Python environment robustly and basic shell context
  env_vars="$env_vars PYTHONHOME='${PYTHONHOME}'"
  env_vars="$env_vars PYTHONPATH='${PYTHONPATH}'"
  env_vars="$env_vars PYTHONNOUSERSITE='${PYTHONNOUSERSITE}'"
  env_vars="$env_vars PYTHONEXECUTABLE='${PYO3_PYTHON}'"
  env_vars="$env_vars VIRTUAL_ENV='${repo_root}/.venv'"
  env_vars="$env_vars HOME='${HOME}'"
  env_vars="$env_vars PATH='${venv_bin_path}:${PATH}'"
  env_vars="$env_vars HF_TOKEN='${HF_TOKEN:-}'"
  
  $tmux_bin new-session -d -s "$session_name" \
    "cd '$repo_root' && env -i $env_vars '$moshi_bin' worker --config '$config_file' --addr '$addr' --port '$port' 2>&1 | tee '$log_file'"
  
  log_success "$script_name" "Server started in tmux session '$session_name'"
}

# Start server using nohup (fallback)
start_server_nohup() {
  local script_name="$1"
  local moshi_bin="$2"
  local config_file="$3"
  local addr="$4"
  local port="$5"
  local repo_root="$6"
  local log_file="$7"
  
  log_info "$script_name" "tmux not found; using nohup fallback"
  
  # Raise file descriptor limit for high concurrency
  ulimit -n 1048576 || true
  
  # Build environment variable string (same as tmux version)
  local venv_bin_path="${repo_root}/.venv/bin"
  local env_vars="LD_LIBRARY_PATH='${LD_LIBRARY_PATH}'"
  env_vars="$env_vars PYO3_PYTHON='${PYO3_PYTHON}'"
  env_vars="$env_vars PYTHONHOME='${PYTHONHOME}'"
  env_vars="$env_vars PYTHONPATH='${PYTHONPATH}'"
  env_vars="$env_vars PYTHONNOUSERSITE='${PYTHONNOUSERSITE}'"
  env_vars="$env_vars RAYON_NUM_THREADS='${RAYON_NUM_THREADS}'"
  env_vars="$env_vars TOKIO_WORKER_THREADS='${TOKIO_WORKER_THREADS}'"
  env_vars="$env_vars MALLOC_ARENA_MAX='${MALLOC_ARENA_MAX}'"
  env_vars="$env_vars RUST_LOG='${RUST_LOG}'"
  env_vars="$env_vars RUST_BACKTRACE='${RUST_BACKTRACE}'"
  env_vars="$env_vars CUDA_DEVICE_MAX_CONNECTIONS='${CUDA_DEVICE_MAX_CONNECTIONS}'"
  env_vars="$env_vars CUDA_VISIBLE_DEVICES='${CUDA_VISIBLE_DEVICES}'"
  env_vars="$env_vars CUDA_DEVICE_ORDER='${CUDA_DEVICE_ORDER}'"
  env_vars="$env_vars NVIDIA_TF32_OVERRIDE='${NVIDIA_TF32_OVERRIDE}'"
  env_vars="$env_vars TORCH_ALLOW_TF32_CUBLAS='${TORCH_ALLOW_TF32_CUBLAS}'"
  env_vars="$env_vars TORCH_ALLOW_TF32_CUDNN='${TORCH_ALLOW_TF32_CUDNN}'"
  env_vars="$env_vars TORCHINDUCTOR_DISABLE='${TORCHINDUCTOR_DISABLE}'"
  env_vars="$env_vars PYTORCH_JIT='${PYTORCH_JIT}'"
  # Pass HF Hub knobs to avoid XET throttling/bridge fetches
  env_vars="$env_vars HF_HOME='${HF_HOME:-}'"
  env_vars="$env_vars HF_HUB_DISABLE_XET='${HF_HUB_DISABLE_XET:-1}'"
  env_vars="$env_vars HF_HUB_ENABLE_HF_TRANSFER='${HF_HUB_ENABLE_HF_TRANSFER:-0}'"
  env_vars="$env_vars PYTHONHOME='${PYTHONHOME}'"
  env_vars="$env_vars PYTHONPATH='${PYTHONPATH}'"
  env_vars="$env_vars PYTHONNOUSERSITE='${PYTHONNOUSERSITE}'"
  env_vars="$env_vars PYTHONEXECUTABLE='${PYO3_PYTHON}'"
  env_vars="$env_vars VIRTUAL_ENV='${repo_root}/.venv'"
  env_vars="$env_vars HOME='${HOME}'"
  env_vars="$env_vars PATH='${venv_bin_path}:${PATH}'"
  env_vars="$env_vars HF_TOKEN='${HF_TOKEN:-}'"
  
  nohup sh -c "cd '$repo_root' && env -i $env_vars '$moshi_bin' worker --config '$config_file' --addr '$addr' --port '$port'" \
    > "$log_file" 2>&1 &
  
  log_success "$script_name" "Server started with nohup (PID: $!)"
}

# Wait for server to be ready (port check)
wait_for_server_ready() {
  local script_name="$1"
  local port="$2"
  local timeout="${3:-240}"
  local log_file="${4:-}"

  log_info "$script_name" "Waiting for server to be ready on port $port (timeout: ${timeout}s)"

  for i in $(seq 1 "$timeout"); do
    # Ready if TCP port is open
    (exec 3<>/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1 && { exec 3>&-; log_success "$script_name" "Server is ready on port $port"; return 0; }

    # Or, ready if log already reports listening
    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
      if grep -qiE "listening[[:space:]]*on|listeningon" "$log_file"; then
        log_success "$script_name" "Server reported listening in logs"
        return 0
      fi
    fi

    sleep 1
  done

  log_error "$script_name" "TTS server didn't report ready within ${timeout}s"
  if [ -n "$log_file" ] && [ -f "$log_file" ]; then
    echo "Recent server logs:" >&2
    tail -n 100 "$log_file" >&2 || true
  fi
  return 1
}

# Setup server environment variables
setup_server_environment() {
  local script_name="$1"
  
  log_info "$script_name" "Setting up server environment"
  
  # GPU and CUDA settings
  export CUDA_DEVICE_MAX_CONNECTIONS="${CUDA_DEVICE_MAX_CONNECTIONS:-32}"
  unset CUDA_LAUNCH_BLOCKING || true
  export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
  export CUDA_DEVICE_ORDER="${CUDA_DEVICE_ORDER:-PCI_BUS_ID}"
  
  # PyTorch CUDA allocator tuning for smoother latency under bursts
  export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True,max_split_size_mb:64}"
  
  # Disable Torch Inductor to improve first-call TTFB for short utterances
  export TORCHINDUCTOR_DISABLE="${TORCHINDUCTOR_DISABLE:-1}"
  export PYTORCH_JIT="${PYTORCH_JIT:-0}"
  
  # Prefer TF32 for faster matmuls on Ampere+ (harmless on others)
  export NVIDIA_TF32_OVERRIDE="${NVIDIA_TF32_OVERRIDE:-1}"
  export TORCH_ALLOW_TF32_CUBLAS="${TORCH_ALLOW_TF32_CUBLAS:-1}"
  export TORCH_ALLOW_TF32_CUDNN="${TORCH_ALLOW_TF32_CUDNN:-1}"
  
  # Do not force deterministic cublas workspace (costs latency)
  unset CUBLAS_WORKSPACE_CONFIG
  
  # Threading environment
  export RAYON_NUM_THREADS="${TTS_RAYON_THREADS:-1}"
  export TOKIO_WORKER_THREADS="${TTS_TOKIO_THREADS:-$(nproc --all 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 16)}"
  
  # Logging
  export RUST_LOG="${RUST_LOG:-warn,hyper=warn,axum=warn}"
  export RUST_BACKTRACE="${RUST_BACKTRACE:-full}"
  
  log_success "$script_name" "Server environment configured"
}

# Show server logs with filtering
show_server_logs() {
  local script_name="$1"
  local log_file="$2"
  local filter_pattern="${3:-}"
  local line_count="${4:-10}"
  
  if [ -f "$log_file" ]; then
    if [ -n "$filter_pattern" ]; then
      log_info "$script_name" "Recent logs matching '$filter_pattern':"
      tail -n +1 "$log_file" | grep -E "$filter_pattern" -n | tail -n "$line_count" || echo "No matching logs found"
    else
      log_info "$script_name" "Recent server logs:"
      tail -n "$line_count" "$log_file" || true
    fi
  else
    log_warning "$script_name" "Log file not found: $log_file"
  fi
}
