# Yap Kyutai TTS API

Production-ready Text-To-Speech service using Kyutai’s moshi-server.

## Overview

This repo supports two mutually exclusive run modes. Choose ONE:

1) Docker (recommended)
- Build a minimal image that runs moshi-server inside a container
- Good for clean, reproducible environments

2) Local scripts on an L40S GPU
- Use the shell scripts under `custom/` to install, fetch models/voices, and run locally
- Useful when you want full control on a baremetal/VM with an NVIDIA GPU

Do not mix both at the same time on the same machine.

## Requirements

- NVIDIA GPU with CUDA 12.x (L40S recommended)
- A HuggingFace token with access to `kyutai/tts-1.6b-en_fr`
- Outbound internet to download models and voices

## Option 1: Docker

Build the image:

```bash
./docker/scripts/build.sh
```

Run the container:

```bash
docker run --gpus all -p 8089:8089 \
  -e HUGGING_FACE_HUB_TOKEN=$HF_TOKEN \
  yapai/kyutai-tts:latest
```

Health checks and module info (uses jq with python fallback):

```bash
curl -s http://127.0.0.1:8089/api/build_info | jq . || \
  curl -s http://127.0.0.1:8089/api/build_info | python -m json.tool

curl -s http://127.0.0.1:8089/api/modules_info | jq . || \
  curl -s http://127.0.0.1:8089/api/modules_info | python -m json.tool
```

Notes:
- The Docker build context is minimized via `docker/.dockerignore`.
- The image copies `configs/config.toml` to `/app/config.toml`, and `docker/scripts/start_moshi_server_public.sh` into `/app/`.
- The image also includes `test/` under `/app/test/` for convenience.
- The server binary is installed at container start using `cargo install --features cuda moshi-server@0.6.3`.

## Option 2: Local scripts on an L40S GPU

Set your HuggingFace token:

```bash
export HF_TOKEN=<your-hf-token>
```

Run the one-shot setup and start:

```bash
bash custom/main.sh
```

Note:
- When using the `custom/` scripts, run them in an environment equivalent to the Docker base image: `nvidia/cuda:12.8.1-devel-ubuntu22.04` (Ubuntu 22.04 with CUDA 12.8 devel toolchain). This ensures compatible compilers, libraries, and drivers.

This will:
- Install system deps, Rust toolchain, and a Python venv
- Download the model and voices
- Generate and verify configuration
- Build and start moshi-server with CUDA support

To stop/cleanup:

```bash
bash custom/stop.sh
```

## Configuration

The container and scripts use `configs/config.toml`. Key fields:

- `authorized_ids`: API keys allowed for requests
- `modules.tts_py`: TTS module exposed at `/api/tts_streaming`
  - `batch_size`: effective slots for streaming TTS
  - `text_tokenizer_file`, `hf_repo`: model and tokenizer
  - `voice_folder`, `default_voice`: voice embeddings
- `modules.tts_py.py` section (Python-side TTS params):
  - `cfg_coef`: classifier-free guidance coefficient (2.0 = stronger guidance; 1.0 = disabled)
  - `cfg_is_no_text`: whether CFG uses no-text branch
  - `padding_between`: extra pauses between words (set low to avoid word gaps)
  - `padding_bonus`: increases the probability of pauses when punctuation/pauses are likely
  - `max_consecutive_pads`: cap on how many pads in a row
  - `n_q`: number of audio codebooks to generate

Adjust these to tune latency and prosody.

## Performance

- TTFB measurement parity: the official Kyutai client streams words one-by-one over WebSocket. Use `test/warmup.py` or `test/bench.py` which now send words individually and parse PCM frames.
- For single-stream testing, keep `batch_size` modest (e.g., 16). Increase batch size only when increasing concurrency.
- To reduce CPU contention and smooth TTFB, the container sets:
  - `CUDA_MODULE_LOADING=EAGER`
- `CUDA_DEVICE_MAX_CONNECTIONS=16` (tune as needed)
  - `RAYON_NUM_THREADS=1`, `OMP_NUM_THREADS=1`, `MKL_NUM_THREADS=1`

## Testing

Activate the virtual environment (created by `custom/01_install_tts_server.sh`):

```bash
source .venv/bin/activate
python -V
```

Warmup (single request):

```bash
python test/warmup.py
```

Benchmark (concurrency):

```bash
python test/bench.py --n 16 --concurrency 16
```

Both scripts save outputs and print TTFB (end-to-end and server), wall time, audio duration, and throughput.

Streaming mode notes:
- The official Kyutai client streams word-by-word. Our test clients support three modes via `--stream-mode`:
  - `sentence`
  - `word`
  - `first_sentence_then_words` (default)
- Example: `python test/warmup.py --server 127.0.0.1:8089 --stream-mode sentence`

## Repository Layout (runtime-relevant)

- `docker/`
  - `Dockerfile`: container build
  - `.dockerignore`: build context minimization
  - `scripts/`: `start_moshi_server_public.sh` (entrypoint), `build.sh` (image build)
- `configs/`
  - `config.toml`: shared configuration used by Docker and the local scripts
- `custom/` (only for local, non-Docker runs)
  - `main.sh` and other helpers to install, build, and run on a GPU host
- `test/`
  - `warmup.py`, `bench.py`, `client.py`: WebSocket clients for local or remote testing

## Troubleshooting

- Build runs out of space: ensure `.dockerignore` excludes `.git` and LFS content; clean with `docker system prune -a --volumes` if needed
- Slow first audio: confirm you’re testing on localhost to remove RTT; verify `CUDA_DEVICE_MAX_CONNECTIONS`, and do not oversize batch for single-stream
- Voice loading errors: check `voice_folder` and `default_voice` paths in `config.toml`