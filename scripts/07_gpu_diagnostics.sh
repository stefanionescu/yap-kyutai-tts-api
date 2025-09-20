#!/usr/bin/env bash
set -euo pipefail

# Load environment and utility modules
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"
source "$SCRIPT_DIR/utils/common.sh"

SCRIPT_NAME="07-gpu-diag"

log_info "$SCRIPT_NAME" "GPU and PyTorch diagnostics"

PYTHON_BIN="${ROOT_DIR}/.venv/bin/python"

# Check if Python environment exists
if [ ! -x "$PYTHON_BIN" ]; then
    log_error "$SCRIPT_NAME" "Python venv not found at $PYTHON_BIN"
    log_error "$SCRIPT_NAME" "Run: bash scripts/01_install_tts_server.sh"
    exit 1
fi

log_info "$SCRIPT_NAME" "=== CUDA System Check ==="
echo "CUDA Compiler:"
nvcc --version 2>/dev/null || echo "nvcc not found"
echo ""

echo "NVIDIA Driver:"
nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo "nvidia-smi not found"
echo ""

echo "GPU Clocks:"
nvidia-smi -q -d CLOCK | grep -A2 "Applications Clocks" 2>/dev/null || echo "Clock info not available"
echo ""

log_info "$SCRIPT_NAME" "=== PyTorch CUDA Check ==="
"$PYTHON_BIN" - <<'PY'
import torch
import sys

print(f"Python: {sys.version}")
print(f"PyTorch version: {torch.__version__}")
print(f"CUDA available: {torch.cuda.is_available()}")

if torch.cuda.is_available():
    print(f"CUDA version (PyTorch): {torch.version.cuda}")
    print(f"GPU count: {torch.cuda.device_count()}")
    print(f"Current GPU: {torch.cuda.current_device()}")
    print(f"GPU name: {torch.cuda.get_device_name()}")
    print(f"GPU memory: {torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB")
    
    # Test GPU compute
    print("\nTesting GPU compute...")
    try:
        x = torch.randn(1000, 1000, device='cuda')
        y = torch.randn(1000, 1000, device='cuda')
        z = torch.matmul(x, y)
        print("✅ GPU matmul test passed")
        
        # Test mixed precision
        with torch.autocast(device_type='cuda'):
            z_amp = torch.matmul(x.half(), y.half())
        print("✅ Mixed precision test passed")
        
        # Test flash attention if available
        try:
            from torch.nn.functional import scaled_dot_product_attention
            q = torch.randn(1, 8, 100, 64, device='cuda')
            k = torch.randn(1, 8, 100, 64, device='cuda')
            v = torch.randn(1, 8, 100, 64, device='cuda')
            out = scaled_dot_product_attention(q, k, v)
            print("✅ Flash attention test passed")
        except Exception as e:
            print(f"❌ Flash attention test failed: {e}")
            
    except Exception as e:
        print(f"❌ GPU compute test failed: {e}")
else:
    print("❌ CUDA not available - PyTorch is using CPU only!")
    print("This explains poor performance!")
PY

log_info "$SCRIPT_NAME" "=== Environment Variables ==="
echo "CUDA_VISIBLE_DEVICES: ${CUDA_VISIBLE_DEVICES:-not set}"
echo "LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:-not set}"
echo "RAYON_NUM_THREADS: ${RAYON_NUM_THREADS:-not set}"
echo "TOKIO_WORKER_THREADS: ${TOKIO_WORKER_THREADS:-not set}"
echo ""

log_info "$SCRIPT_NAME" "=== GPU Utilization Test ==="
echo "Starting GPU stress test for 10 seconds..."
"$PYTHON_BIN" - <<'PY'
import torch
import time

if not torch.cuda.is_available():
    print("❌ CUDA not available, skipping GPU test")
    exit()

print("Running GPU stress test...")
device = torch.device('cuda')

# Create large tensors to stress GPU
for i in range(10):
    print(f"Iteration {i+1}/10")
    # Large matrix operations
    x = torch.randn(2048, 2048, device=device)
    y = torch.randn(2048, 2048, device=device)
    
    start = time.time()
    for _ in range(50):
        z = torch.matmul(x, y)
        torch.cuda.synchronize()
    elapsed = time.time() - start
    print(f"  50 matmuls took {elapsed:.3f}s ({50/elapsed:.1f} ops/sec)")
    
    time.sleep(0.5)

print("✅ GPU stress test completed")
print("Check 'nvidia-smi' in another terminal to verify GPU utilization spiked to ~100%")
PY

log_success "$SCRIPT_NAME" "Diagnostics complete"
log_info "$SCRIPT_NAME" "If CUDA is not available or GPU utilization is low, reinstall with:"
log_info "$SCRIPT_NAME" "  bash scripts/01_install_tts_server.sh"
