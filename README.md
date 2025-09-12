# Yap TTS API

This repo runs a Text-To-Speech (TTS) service using Kyutai's DSM. It runs the Kyutai Rust `moshi-server`.

- **Model**: `kyutai/tts-0.75b-en-public` (English-only)
- **Defaults**: port `8089`, voice `ears/p004/freeform_speech_01.wav`
- **Runtime**: Rust server launched via `uv run` (ensures Python deps are active)

Do not run these scripts locally; they are intended for RunPod pods with a CUDA GPU.

### What this provides
- **Installer** for the Rust server and Python shim: `scripts/01_install_tts_server.sh`
- **Config fetch & pin** to 0.75B EN and voice download: `scripts/02_fetch_tts_configs.sh`
- **Server launcher** (tmux + health wait): `scripts/03_start_tts_server.sh`
- **Smoke test** using DSM client (mandatory): `scripts/04_tts_smoke_test.sh`
- **Test dependencies setup** with proper pip venv: `scripts/05_setup_test_deps.sh`
- **Orchestrator**: `scripts/main.sh`
- **Cleanup**: `scripts/stop.sh`

### Prerequisites (on RunPod)
- NVIDIA GPU with CUDA 12.x available (NVRTC present). Scripts export `CUDARC_NVRTC_PATH`.
- Outbound internet access to pull crates and Hugging Face assets.
- Your existing `scripts/env.sh` (optional but supported). If it's missing, the scripts still run because `main.sh`/`stop.sh` guard their sourcing.

### Environment
Edit `scripts/env.sh` to adjust ports and voice.

Notes:
- Data is stored inside this repo under `.data/` by default:
  - Config: `.data/server/config-tts-en-hf.toml` (override via `TTS_CONFIG`)
  - Logs: `.data/logs` (override via `TTS_LOG_DIR`)
  - Voices: `.data/voices` (override via `VOICES_DIR`)
  - DSM clone: `.data/delayed-streams-modeling` (override via `DSM_REPO_DIR`)

#### Tuning knobs (concurrency, batching, CPU caps)
- **TTS_BATCH_SIZE**: default `32`. Controls dynamic batching for `/api/tts_streaming`.
- **TTS_NUM_WORKERS**: default `12`. Sets `num_workers` in the server config (concurrent synth tasks).
- **TTS_MAX_QUEUE_LEN**: default `256`. Sets `max_queue_len` (if supported) to absorb brief bursts.
- **TTS_RAYON_THREADS**: default `1`. Caps Candle/Rayon CPU workers to avoid CPU thrash.
- **TTS_TOKIO_THREADS**: default `4`. Tokio runtime worker threads.
- **MALLOC_ARENA_MAX**: default `2`. Lower glibc arenas to reduce heap fragmentation under load.
- **RUST_LOG**: default `info,moshi_server=debug,moshi=info`.

These are applied automatically by `scripts/02_fetch_tts_configs.sh` (for config keys) and `scripts/03_start_tts_server.sh` (for env vars).

### Install, start, and smoke test
Run on the pod:

```bash
bash scripts/main.sh
```

What it does:
- Creates a `.venv` at repo root and installs pinned Python deps using `uv`
- Installs a pinned `moshi-server` version with CUDA support (`0.6.3` by default)
- Clones DSM and writes `.data/server/config-tts-en-hf.toml` with the model set to `kyutai/tts-0.75b-en-public`, and enforces Mimi `n_q = 16`
- Starts the Rust server via `uv run --frozen moshi-server worker --config ... --addr ... --port ...` (tmux if available, else nohup)
- Waits until the port is open
- Runs `scripts/04_tts_smoke_test.sh` to synthesize to a WAV file at `.data/out.wav` (no playback on server)
- Sets up test dependencies with proper pip in the venv via `scripts/05_setup_test_deps.sh`

Performance defaults (safe for L40S):
- `n_q = 16` enforced for Mimi (0.75B EN requirement)
- `batch_size = 32` in `[modules.tts_py]`
- `num_workers = 12` at top-level
- `RAYON_NUM_THREADS=1`, `TOKIO_WORKER_THREADS=4`, `MALLOC_ARENA_MAX=2`

Logs: `${TTS_LOG_DIR}/tts-server.log` (default `.data/logs/tts-server.log`).

Tail the server logs during a run:

```bash
tail -f .data/logs/tts-server.log
# or, if you customized TTS_LOG_DIR:
tail -f "$TTS_LOG_DIR/tts-server.log"
```

### Benchmarks and warmup
Two helper scripts generate audio to `.data/` and report useful metrics.

The `scripts/main.sh` automatically sets up test dependencies after the smoke test. To run the benchmarks:

```bash
# Activate the venv (once per terminal session)
source .venv/bin/activate

# Run tests using activated environment
python test/warmup.py
python test/bench.py

# Deactivate when done (optional)
deactivate
```

Optional flags:

```bash
# Warmup with flags (using direct python path)
.venv/bin/python test/warmup.py --server 127.0.0.1:8089 \
  --voice ".data/voices/ears/p004/freeform_speech_01.wav" \
  --text "Warming up the model and caches."

# Benchmark with flags (using direct python path)
.venv/bin/python test/bench.py --server 127.0.0.1:8089 \
  --n 20 --concurrency 5 \
  --voice ".data/voices/ears/p004/freeform_speech_01.wav" \
  --text "Hello from Kyutai TTS." --text "Another line for the benchmark."

# Or with activated venv:
python test/warmup.py --server 127.0.0.1:8089 \
  --voice ".data/voices/ears/p004/freeform_speech_01.wav"
```

### Stop and clean up
Stops the tmux session and removes caches and downloaded artifacts; preserves your repo and Jupyter/web console.

```bash
bash scripts/stop.sh
# Also remove logs:
PURGE_LOGS=1 bash scripts/stop.sh
```

Removed by `stop.sh`:
- `.venv`, `pyproject.toml`, `uv.lock`
- DSM clone at `${DSM_REPO_DIR:-<repo>/.data/delayed-streams-modeling}`
- Voices directory `${VOICES_DIR:-<repo>/.data/voices}`
- Common caches: Hugging Face, Torch, uv, Cargo registry/git

Preserved:
- This Git repo (working tree)
- Jupyter and RunPod web console

### Changing the voice
Set `TTS_VOICE` in `scripts/env.sh` to any path from `kyutai/tts-voices` (e.g., `ears/p004/freeform_speech_01.wav`). `scripts/02_fetch_tts_configs.sh` will download it on first run.

### Changing the port
`TTS_PORT` in `scripts/env.sh` controls the server port (default `8089`).

### Versions pinned
- `moshi-server`: `0.6.3` (edit `MOSHI_VERSION` in `scripts/01_install_tts_server.sh`)
- Python manifests: from Moshi commit `aee53fc` (edit `MOSHI_REF` in `scripts/01_install_tts_server.sh`)

### Auth header
`moshi-server` does not read `YAP_API_KEY` from the environment. If you enable auth in the TOML, clients must send the header `kyutai-api-key: <token>`, and the token must be included in the config's `authorized_ids` list. If `authorized_ids` is empty or missing, the server is open.

### Troubleshooting
- "unrecognized arguments: worker": Ensure your PATH resolves the Rust `moshi-server` (not the Python CLI). The scripts install the Rust binary and run it via `uv`.
- Port not opening: Check `${TTS_LOG_DIR}/tts-server.log`. Verify GPU/CUDA NVRTC is available and not in use by other processes.
- HF 401 on model: `kyutai/tts-0.75b-en-public` is public; ensure internet and, if needed, set `HF_HOME` / `HUGGING_FACE_HUB_TOKEN` in the environment.
- Slow or contended GPU: Avoid running STT and TTS on the same GPU concurrently.
- Many errors at higher concurrency: raise `TTS_BATCH_SIZE` and/or `TTS_NUM_WORKERS`; keep `TTS_RAYON_THREADS` low; consider increasing `TTS_MAX_QUEUE_LEN`. Ensure client sends `kyutai-api-key` matching `authorized_ids`. Increase client `open_timeout/ping_interval/ping_timeout` to 30s for bursts.

### Security
To restrict access, set `authorized_ids = ["<token>"]` in your TOML config, and have clients send `kyutai-api-key: <token>`.

---

For deeper integration (custom configs, multiple voices, or colocated STT), update `scripts/env.sh` and rerun `scripts/main.sh`. If you need the config file to live inside this repo, change `TTS_CONFIG` and re-run `scripts/02_fetch_tts_configs.sh`.
