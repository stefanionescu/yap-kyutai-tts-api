## Yap Kyutai TTS API

This repo runs a Text-To-Speech (TTS) service using Kyutai's DSM. It runs the Rust `moshi-server`.

- **Model**: `kyutai/tts-0.75b-en-public` (English-only)
- **Defaults**: port `8000`, voice `ears/p004/freeform_speech_01.wav`
- **Runtime**: Rust server launched via `uv run` (ensures Python deps are active)

Do not run these scripts locally; they are intended for RunPod pods with a CUDA GPU.

### What this provides
- **Installer** for the Rust server and Python shim: `scripts/01_install_tts_server.sh`
- **Config fetch & pin** to 0.75B EN and voice download: `scripts/02_fetch_tts_configs.sh`
- **Server launcher** (tmux + health wait): `scripts/03_start_tts_server.sh`
- **Smoke test** using DSM client (mandatory): `scripts/04_tts_smoke_test.sh`
- **Orchestrator**: `scripts/main.sh`
- **Cleanup**: `scripts/stop.sh`

### Prerequisites (on RunPod)
- NVIDIA GPU with CUDA 12.x available (NVRTC present). Scripts export `CUDARC_NVRTC_PATH`.
- Outbound internet access to pull crates and Hugging Face assets.
- Your existing `scripts/env.sh` (optional but supported). If it's missing, the scripts still run because `main.sh`/`stop.sh` guard their sourcing.

### Environment
Edit `scripts/env.sh` to adjust ports and voice.

```bash
# -------- YAP TTS RUNPOD ENV --------
TTS_ADDR=0.0.0.0
TTS_PORT=8000
TTS_LOG_DIR=/workspace/logs
TTS_TMUX_SESSION=yap-tts
TTS_CONFIG=${TTS_CONFIG:-${ROOT_DIR}/../server/config-tts-en-hf.toml}

# Voice assets
VOICES_DIR=${VOICES_DIR:-/workspace/voices}
TTS_VOICE=${TTS_VOICE:-ears/p004/freeform_speech_01.wav}
```

Notes:
- The config file is written to `../server/config-tts-en-hf.toml` (sibling directory to this repo). Adjust `TTS_CONFIG` if you want it inside this repo.
- The default voice is fetched from the `kyutai/tts-voices` dataset into `${VOICES_DIR}`.

### Install, start, and smoke test
Run on the pod:

```bash
bash scripts/main.sh
```

What it does:
- Creates a `scripts/.venv` and installs pinned Python deps using `uv`
- Installs a pinned `moshi-server` version with CUDA support (`0.6.3` by default)
- Clones DSM and writes `../server/config-tts-en-hf.toml` with the model set to `kyutai/tts-0.75b-en-public`, and enforces Mimi `n_q = 16`
- Starts the Rust server via `uv run --frozen moshi-server worker --config ... --addr ... --port ...` (tmux if available, else nohup)
- Waits until the port is open
- Runs `scripts/04_tts_smoke_test.sh` to verify a basic synthesis request succeeds

Logs: `${TTS_LOG_DIR}/tts-server.log` (default `/workspace/logs/tts-server.log`).

### Stop and clean up
Stops the tmux session and removes caches and downloaded artifacts; preserves your repo and Jupyter/web console.

```bash
bash scripts/stop.sh
# Also remove logs:
PURGE_LOGS=1 bash scripts/stop.sh
```

Removed by `stop.sh`:
- `scripts/.venv`, `scripts/pyproject.toml`, `scripts/uv.lock`
- DSM clone at `${DSM_REPO_DIR:-/workspace/delayed-streams-modeling}`
- Voices directory `${VOICES_DIR:-/workspace/voices}`
- Common caches: Hugging Face, Torch, uv, Cargo registry/git

Preserved:
- This Git repo (working tree)
- Jupyter and RunPod web console

### Changing the voice
Set `TTS_VOICE` in `scripts/env.sh` to any path from `kyutai/tts-voices` (e.g., `ears/p004/freeform_speech_01.wav`). `scripts/02_fetch_tts_configs.sh` will download it on first run.

### Changing the port
`TTS_PORT` in `scripts/env.sh` controls the server port (default `8000`). If you use the DSM Python client script directly, pass `--url ws://HOST:PORT` when connecting, since DSM defaults to a different port.

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
