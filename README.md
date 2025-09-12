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

Logs: `${TTS_LOG_DIR}/tts-server.log` (default `.data/logs/tts-server.log`).

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

### Security
To restrict access, set `authorized_ids = ["<token>"]` in your TOML config, and have clients send `kyutai-api-key: <token>`.

---

For deeper integration (custom configs, multiple voices, or colocated STT), update `scripts/env.sh` and rerun `scripts/main.sh`. If you need the config file to live inside this repo, change `TTS_CONFIG` and re-run `scripts/02_fetch_tts_configs.sh`.
