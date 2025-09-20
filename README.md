# Yap Kyutai TTS API

**Production-ready Text-To-Speech service** using Kyutai's state-of-the-art TTS models with the high-performance Rust `moshi-server`.

## **Key Features**
- **🤖 Model**: `kyutai/tts-1.6b-en_fr` (English & French, 1.6B parameters)
- **🎯 Performance**: Optimized for L40S GPUs with CUDA acceleration
- **🔊 Multi-Voice**: 6 different voices supported out-of-the-box
- **🚀 High Throughput**: Batched processing with 24 concurrent workers
- **📦 Modular**: Clean, maintainable script architecture
- **🔒 Secure**: Token-based authentication support

## **Specifications**
- **Default Port**: `8089` 
- **Default Voice**: `ears/p004/freeform_speech_01.wav`
- **Batch Size**: `24` (optimized for throughput + latency)
- **Workers**: `24` concurrent synthesis tasks
- **Runtime**: Native Rust server with Python ML backend

> ⚠️ **RunPod Only**: These scripts are designed for RunPod pods with CUDA GPUs

## **What's Included**

### **Core Scripts** (Modular & Clean!)
- **🔧 `01_install_tts_server.sh`**: System setup (Rust, Python, packages)
- **📥 `02_fetch_tts_configs.sh`**: Model & voice downloads + config generation  
- **🚀 `03_start_tts_server.sh`**: Server startup with health monitoring
- **✅ `06_verify_config.sh`**: Complete system validation
- **🧪 `05_tts_smoke_test.sh`**: Audio synthesis testing
- **📦 `04_setup_test_deps.sh`**: Test environment setup
- **🎵 `main.sh`**: One-command orchestrator  
- **🛑 `stop.sh`**: Clean shutdown & cleanup

### **Utility Modules** (`scripts/utils/`)
- **`common.sh`**: Logging & utility functions
- **`hf_operations.sh`**: HuggingFace downloads & token validation
- **`voice_management.sh`**: Multi-voice validation & management
- **`server_operations.sh`**: Server building & process management
- **`system_setup.sh`**: Environment & dependency installation
- **`verification.sh`**: Comprehensive system verification

## **Prerequisites**

### **Hardware**
- 🎮 **NVIDIA GPU** with CUDA 12.x (NVRTC required)
- 💾 **8GB+ GPU Memory** (for 1.6B model)
- 🌐 **Internet Access** (HuggingFace model downloads)

### **Environment** 
- 🔑 **HF_TOKEN** - **REQUIRED** HuggingFace token for model access
- 🐧 **RunPod Environment** with root access

## ⚙️ **Configuration**

### **Data Storage** (All local under `.data/`)
| Component | Default Path | Override Variable |
|-----------|--------------|-------------------|
| **Config** | `.data/server/config-tts.toml` | `TTS_CONFIG` |
| **Logs** | `.data/logs/` | `TTS_LOG_DIR` | 
| **Voices** | `.data/voices/` | `VOICES_DIR` |
| **Models** | `.data/models/` | - |

### **Performance Tuning** (Optimized for L40S)
| Parameter | Default | Description |
|-----------|---------|-------------|
| **TTS_BATCH_SIZE** | `16` | Dynamic batching for `/api/tts_streaming` |
| **TTS_NUM_WORKERS** | `24` | Concurrent synthesis tasks |
| **TTS_MAX_QUEUE_LEN** | `32` | Request queue length for burst handling |
| **TTS_RAYON_THREADS** | `1` | CPU threads (avoid GPU contention) |
| **TTS_TOKIO_THREADS** | Auto | Async runtime threads |
| **TTS_PORT** | `8089` | Server listening port |
| **TTS_ADDR** | `0.0.0.0` | Server bind address |

### **HuggingFace Settings** (Anti-throttling)
- **HF_HUB_DISABLE_XET**: `1` (reduces parallelism)  
- **HF_HUB_ENABLE_HF_TRANSFER**: `0` (disables XET transfers)

### **🎵 Supported Voices** (Auto-validated)
- `ears/p058/freeform_speech_01.wav` 
- `ears/p059/freeform_speech_01.wav`
- `ears/p068/freeform_speech_01.wav`
- `ears/p081/freeform_speech_01.wav` 
- `ears/p086/freeform_speech_01.wav`
- `ears/p100/freeform_speech_01.wav`

## **Quick Start**

### **Set Your HuggingFace Token** (Required!)
```bash
export HF_TOKEN=<your-hf-token>  # Get from: https://huggingface.co/settings/tokens
```

### **One Command Deploy** 
```bash
bash scripts/main.sh
```

### **What Happens** ✨
1. **🔍 Token Validation**: Checks HF_TOKEN before any downloads
2. **📦 System Setup**: Rust toolchain, Python venv, system packages  
3. **⬇️ Model Download**: `kyutai/tts-1.6b-en_fr` (1.6B English/French)
4. **🎵 Voice Download**: All 6 supported voices with validation
5. **⚙️ Config Generation**: Optimized TOML with `n_q=24`, `batch_size=24`
6. **🔨 Server Build**: Native Rust `moshi-server` with CUDA features
7. **🚀 Server Start**: tmux session with health monitoring
8. **✅ Validation**: Complete system verification
9. **🧪 Smoke Test**: Synthesis test to `.data/out.wav`  
10. **📊 Test Setup**: Benchmark dependencies installation

### **Performance Profile** (L40S Optimized)
- **Model**: 1.6B parameters, English + French
- **Quantization**: `n_q = 24` (optimal quality/speed)  
- **Concurrency**: 24 workers, batch size 24
- **Memory**: CPU-efficient threading, minimal heap fragmentation

## **Monitoring & Logs**

### **Server Logs**
```bash
# 👀 Live monitoring  
tail -f .data/logs/tts-server.log

# 📜 Last 100 lines
tail -n 100 .data/logs/tts-server.log

# 🔍 Search for errors
grep -i "error\|fail\|warn" .data/logs/tts-server.log | tail -20
```

### **✅ Health Check**  
```bash
# 🏥 Complete system verification
bash scripts/06_verify_config.sh

# 🌐 Quick connectivity test  
curl -s http://127.0.0.1:8089/api/build_info
```

## **Performance Testing**

### **Warmup & Benchmarks**
```bash
# 🚀 Activate environment  
source .venv/bin/activate

# 🔥 Model warmup (recommended first)
python test/warmup.py

# 📊 Performance benchmark
python test/bench.py
```

### **Advanced Testing**
```bash
# 🎯 Custom warmup
python test/warmup.py \
  --server 127.0.0.1:8089 \
  --voice ".data/voices/ears/p004/freeform_speech_01.wav" \
  --text "Custom warmup text here"

# 💪 Stress test  
python test/bench.py \
  --n 50 --concurrency 10 \
  --voice ".data/voices/ears/p058/freeform_speech_01.wav" \
  --text "Stress testing the TTS server" \
  --text "Multiple text variations for testing"
```

### **Voice Testing**
```bash
# 🔄 Test all supported voices
for voice in ears/p058 ears/p059 ears/p068 ears/p081 ears/p086 ears/p100; do
  python test/warmup.py --voice ".data/voices/$voice/freeform_speech_01.wav"
done
```

## 🌐 **Remote Client Usage**

### **💻 Local Machine Setup**
```bash  
# 🐍 Create local environment
python3 -m venv .venv && source .venv/bin/activate

# 📦 Install client dependencies  
pip install -r requirements.txt

# 🔑 Set API credentials (if auth enabled)
export KYUTAI_API_KEY=<your-api-key>

# 🚀 Connect to your RunPod server
python test/client.py
```

### **Authentication Setup** 
```bash
# On RunPod: Edit config to enable auth
echo 'authorized_ids = ["your-secret-token"]' >> .data/server/config-tts.toml

# Restart server  
bash scripts/stop.sh && bash scripts/03_start_tts_server.sh

# Client: Use the token
export KYUTAI_API_KEY=your-secret-token
```

## **Shutdown & Cleanup**

### **Standard Cleanup**
```bash  
bash scripts/stop.sh
```

### **Deep Cleaning**  
```bash
# 📋 Also remove logs  
PURGE_LOGS=1 bash scripts/stop.sh

# 🗑️ Nuclear option (removes everything)
PURGE_VENV=1 PURGE_LOGS=1 bash scripts/stop.sh
```

### **🔒 What Gets Removed/Preserved**

| **Removed** (Safe Cleanup) | **Preserved** (Fast Restart) |
|----------------------------|-------------------------------|
| ❌ Python `.venv` | ✅ Downloaded models & voices |
| ❌ Build caches | ✅ Server configuration |  
| ❌ HuggingFace cache | ✅ Git repository |
| ❌ Torch cache | ✅ Jupyter console |
| ❌ tmux sessions | ✅ Log files (unless `PURGE_LOGS=1`) |

## 🎛️ **Customization**

### **Change Voice**  
```bash
# Edit scripts/env.sh
TTS_SPEAKER_DIR=ears/p058  # Choose from supported voices
# Restart: bash scripts/stop.sh && bash scripts/03_start_tts_server.sh
```

### **Change Port**
```bash  
# Edit scripts/env.sh
TTS_PORT=8090  # Your custom port
# Restart server
```

### **Performance Tuning**
```bash
# Edit scripts/env.sh - Example for high-end GPU:
TTS_BATCH_SIZE=16          # Larger batches
TTS_NUM_WORKERS=16         # More workers  
TTS_MAX_QUEUE_LEN=24       # Bigger queue
```

### **Version Info**
- **Model**: `kyutai/tts-1.6b-en_fr` (1.6B parameters)
- **Moshi**: Latest from GitHub (`aee53fc` commit)
- **Quantization**: `n_q = 24` (1.6B optimal)

## **Security & Authentication**

### **Enable Authentication**
```bash
# Add to .data/server/config-tts.toml
authorized_ids = ["your-secret-token"]

# Client usage  
curl -H "kyutai-api-key: your-secret-token" http://localhost:8089/api/build_info
```

## **Troubleshooting**

| **Problem** | **Solution** |
|-------------|--------------|
| 🔑 **"HF_TOKEN not set"** | `export HF_TOKEN=<token>` before running scripts |
| 🚫 **"Port not opening"** | Check `.data/logs/tts-server.log`, verify GPU availability |
| ❌ **"Voice embedding not found"** | Run `bash scripts/02_fetch_tts_configs.sh` to re-download |
| 🐌 **Slow synthesis** | Increase `TTS_BATCH_SIZE` and `TTS_NUM_WORKERS` |
| 💥 **High concurrency errors** | Raise `TTS_MAX_QUEUE_LEN`, check GPU memory |
| 🔧 **"Worker argument error"** | Rust binary conflict - scripts handle this automatically |

### **Performance Tips**
- **GPU Memory**: Monitor with `nvidia-smi` - 1.6B model needs ~6GB
- **Concurrency**: Start with defaults, scale up gradually  
- **Batching**: Higher batch size = better throughput, higher latency
- **Voices**: All 6 voices are validated on startup

---

## **Advanced Usage**

### **Multi-Voice Setup**
All voices auto-downloaded and validated:
```bash  
# Test different voices programmatically
voices=("p058" "p059" "p068" "p081" "p086" "p100")
for v in "${voices[@]}"; do
  curl -X POST -H "Content-Type: application/json" \
    -d '{"text":"Hello from voice '$v'","voice":"ears/'$v'/freeform_speech_01.wav"}' \
    http://localhost:8089/api/tts_streaming
done
```

### **Production Deployment** 
```bash
# High-performance configuration
export TTS_BATCH_SIZE=16 TTS_NUM_WORKERS=16
bash scripts/main.sh
```

## **Docker Deployment**

### **Build and Push Image**
```bash
# Build Docker image
./docker/build.sh

# Build and push to Docker Hub
DOCKER_REPO=your-username/kyutai-tts PUSH=true ./docker/build.sh

# Custom tag
TAG=v1.0 DOCKER_REPO=your-username/kyutai-tts PUSH=true ./docker/build.sh
```

### **Run Locally**
```bash
# Run with GPU support
docker run --gpus all -p 8089:8089 \
  -e HUGGING_FACE_HUB_TOKEN=$HF_TOKEN \
  your-username/kyutai-tts:latest

# Test connection
curl http://localhost:8089/api/build_info
```

### **Deploy on RunPod/Cloud**
1. **Use image**: `your-username/kyutai-tts:latest` (or your custom repo)
2. **Environment variables**:
   - `HUGGING_FACE_HUB_TOKEN` (required)
3. **Expose ports**: `8089`
4. **GPU required**: NVIDIA with CUDA 12.x
5. **Memory**: 8GB+ GPU, 16GB+ system RAM

### **Performance Targets**
- **Single stream TTFB**: ~220ms
- **16 concurrent TTFB**: ~350ms  
- **32 concurrent TTFB**: ~400ms
- **Batch size**: 32 (optimized for L40S)
