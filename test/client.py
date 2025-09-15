#!/usr/bin/env python3
"""
Yap TTS WebSocket client.

- Connects to a remote Yap TTS server (RunPod or local)
- Sends text (word-by-word) and receives streaming PCM chunks
- Aggregates all audio and saves a WAV file under ROOT/audio/
- Tracks metrics similar to other test files (TTFB, connect, handshake)
- Supports env vars: RUNPOD_TCP_HOST, RUNPOD_TCP_PORT, RUNPOD_API_KEY, KYUTAI_API_KEY
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import time
from pathlib import Path
from typing import List, Optional, Tuple

import msgpack  # type: ignore
import numpy as np  # type: ignore
from dotenv import load_dotenv  # type: ignore
from websockets.asyncio.client import connect  # type: ignore


ROOT_DIR = Path(__file__).resolve().parent.parent
AUDIO_DIR = ROOT_DIR / "audio"
AUDIO_DIR.mkdir(parents=True, exist_ok=True)

# Load environment variables from .env file
load_dotenv(ROOT_DIR / ".env")

# Add near top:
VOICES_DIR = Path(os.getenv("VOICES_DIR", ROOT_DIR / ".data" / "voices"))

DEFAULT_TEXT = (
    "Wow, you're so hot and handsome! Can't wait for the app to be done so we can talk. See you there sweetie!"
)

# For 1.6B embeddings, we don't need voice prefix trimming
DEFAULT_TRIM_MS = 0


def _looks_like_runpod_proxy(host: str) -> bool:
    h = (host or "").lower()
    return ("proxy.runpod.net" in h) or h.endswith("runpod.net")


def _ws_url(server: str, voice_path: Optional[str]) -> str:
    """Build WebSocket URL for the TTS streaming endpoint with PCM MessagePack."""
    if server.startswith(("ws://", "wss://")):
        base = server.rstrip("/")
    else:
        base = f"ws://{server.strip().rstrip('/')}"
    qp: List[str] = [
        "format=PcmMessagePack",
        "max_seq_len=128",
        "temp=0.2",
        "seed=42",
    ]
    # Temporarily comment out voice parameter for debugging
    if voice_path:
        from urllib.parse import quote
        qp.append(f"voice={quote(voice_path)}")
    return f"{base}/api/tts_streaming?{'&'.join(qp)}"


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Yap TTS WebSocket client")
    ap.add_argument(
        "--server",
        default=os.getenv("YAP_TTS_SERVER", ""),
        help="Full server URL or host:port (overrides --host/--port)",
    )
    ap.add_argument(
        "--host",
        default=os.getenv("RUNPOD_TCP_HOST", ""),
        help="RunPod public host (defaults to RUNPOD_TCP_HOST)",
    )
    ap.add_argument(
        "--port",
        type=int,
        default=int(os.getenv("RUNPOD_TCP_PORT", "8089")),
        help="RunPod public port (defaults to RUNPOD_TCP_PORT or 8089)",
    )
    ap.add_argument(
        "--secure",
        action="store_true",
        help="Use wss:// (TLS); auto-enabled for RunPod proxy hosts",
    )
    ap.add_argument(
        "--voice",
        default=os.getenv("TTS_VOICE", "ears/p004/freeform_speech_01.wav.1e68beda@240.safetensors"),
        help="Voice path available on server (relative to voices dir)",
    )
    ap.add_argument(
        "--text",
        action="append",
        default=None,
        help="Text to synthesize (repeat flag for multiple sentences)",
    )
    ap.add_argument(
        "--kyutai-api-key",
        default=os.getenv("KYUTAI_API_KEY") or "public_token",
        help="Kyutai API key (header: kyutai-api-key), defaults to 'public_token'",
    )
    ap.add_argument(
        "--runpod-api-key",
        default=os.getenv("RUNPOD_API_KEY"),
        help="RunPod TCP API key",
    )
    ap.add_argument(
        "--outfile",
        default=None,
        help="Output WAV filename (default: tts_<timestamp>.wav under ROOT/audio)",
    )
    return ap.parse_args()


def _compose_server_from_host_port(host: str, port: int, secure: bool) -> str:
    host = (host or "").strip().strip("/")
    if not host:
        host = "127.0.0.1"
    # Auto-secure for runpod proxy
    use_tls = secure or _looks_like_runpod_proxy(host)
    scheme = "wss" if use_tls else "ws"
    # If host includes :port already, don't duplicate
    netloc = host if (":" in host) else f"{host}:{port}"
    return f"{scheme}://{netloc}"


async def tts_client(
    server: str,
    voice: Optional[str],
    texts: List[str],
    kyutai_api_key: Optional[str],
    runpod_api_key: Optional[str],
    out_path: Path,
) -> dict:
    url = _ws_url(server, voice)
    headers = {}
    # Always send kyutai-api-key if we have one (including default "public_token")
    if kyutai_api_key:
        headers["kyutai-api-key"] = kyutai_api_key
    if runpod_api_key:
        headers["runpod-api-key"] = runpod_api_key
        headers["Authorization"] = f"Bearer {runpod_api_key}"

    ws_options = {
        "additional_headers": headers,  # websockets v15 naming
        "max_size": None,
        "ping_interval": 30,
        "ping_timeout": 30,
        "max_queue": None,
        "write_limit": 2**22,
        "open_timeout": 30,
        "close_timeout": 0.5,
    }

    # 1.6B uses speaker **embeddings**; no audio prefix trimming needed.
    prefix_samples_to_drop = 0

    # Metrics - we'll measure both:
    # 1) end-to-end TTFB (includes WS connect) -> ttfb_e2e_s
    # 2) server TTFB (post-connect, post-send) -> ttfb_server_s (matches Kyutai's claim)
    connect_start = time.perf_counter()
    t0_e2e = connect_start
    time_to_first_audio_e2e: Optional[float] = None
    time_to_first_audio_server: Optional[float] = None
    final_time: Optional[float] = None
    handshake_ms: float = 0.0

    pcm_chunks: List[np.ndarray] = []
    sample_rate = 24000

    async with connect(url, **ws_options) as ws:  # type: ignore
        connect_ms = (time.perf_counter() - connect_start) * 1000.0

        # Try to capture a Ready frame for handshake timing (optional)
        first_frame: Optional[bytes] = None
        try:
            hs_start = time.perf_counter()
            raw = await asyncio.wait_for(ws.recv(), timeout=0.3)
            handshake_ms = (time.perf_counter() - hs_start) * 1000.0
            # Some servers send a metadata/ready frame first – try to extract a prefix hint
            # But we prefer our calculated prefix from the voice file
            if isinstance(raw, (bytes, bytearray)):
                try:
                    meta = msgpack.unpackb(raw, raw=False)
                    pf = meta.get("prefix_samples") or meta.get("prefix_ms")
                    # Only use server metadata if we couldn't calculate from voice file
                    if prefix_samples_to_drop == int(24000 * (DEFAULT_TRIM_MS / 1000.0)):
                        if isinstance(pf, int):
                            prefix_samples_to_drop = max(0, pf)
                        elif isinstance(pf, float):
                            prefix_samples_to_drop = int(sample_rate * (pf / 1000.0))
                except:
                    # If metadata parsing fails, keep our calculated prefix
                    pass
            first_frame = raw if isinstance(raw, (bytes, bytearray)) else None
        except asyncio.TimeoutError:
            handshake_ms = 0.0
            first_frame = None

        # True full-duplex: concurrent reader/sender for optimal TTFB
        t0_server_holder = {"t0": None}

        def _process_frame(raw: bytes) -> bool:
            nonlocal time_to_first_audio_e2e, time_to_first_audio_server, sample_rate, final_time, prefix_samples_to_drop
            data = msgpack.unpackb(raw, raw=False)
            kind = data.get("type")
            if kind in ("Audio", "Pcm", "AudioPcm", "AudioChunk", "AudioF32", "AudioI16"):
                sr = data.get("sample_rate") or data.get("sr") or 24000
                sample_rate = sr
                arr = None
                for k in ("pcm", "data", "pcm_i16", "pcm_f32", "samples"):
                    if k in data and data[k] is not None:
                        arr = np.asarray(data[k])
                        break
                if arr is None or arr.size == 0:
                    return False
                if arr.dtype.kind == "f":
                    arr = np.clip(arr, -1.0, 1.0)
                    pcm_i16 = (arr * 32767.0).astype(np.int16)
                else:
                    pcm_i16 = arr.astype(np.int16, copy=False)
                if pcm_i16.size > 0:
                    # Drop voice prefix samples once at stream start
                    if prefix_samples_to_drop > 0:
                        if pcm_i16.size <= prefix_samples_to_drop:
                            prefix_samples_to_drop -= pcm_i16.size
                            return False
                        pcm_i16 = pcm_i16[prefix_samples_to_drop:]
                        prefix_samples_to_drop = 0
                    if time_to_first_audio_e2e is None:
                        time_to_first_audio_e2e = time.perf_counter() - t0_e2e
                    if time_to_first_audio_server is None and t0_server_holder["t0"] is not None:
                        time_to_first_audio_server = time.perf_counter() - t0_server_holder["t0"]
                    pcm_chunks.append(pcm_i16)
                return False
            elif kind in ("End", "Final", "Done", "Marker"):
                final_time = time.perf_counter()
                return True
            else:
                return False

        async def reader():
            try:
                # Process the first frame (if any) before main loop
                if first_frame is not None:
                    if _process_frame(first_frame):
                        return
                # Continue with stream
                while True:
                    raw = await ws.recv()
                    if not isinstance(raw, (bytes, bytearray)):
                        continue
                    if _process_frame(raw):
                        break
            except (asyncio.CancelledError, Exception):
                # Connection closed or task cancelled, exit gracefully
                pass

        async def sender():
            try:
                all_words = []
                for text in texts:
                    all_words.extend(text.split())
                
                for i, word in enumerate(all_words):
                    fragment = word if i == 0 else (" " + word)
                    await ws.send(msgpack.packb({"type": "Text", "text": fragment}, use_bin_type=True))
                    if t0_server_holder["t0"] is None:
                        t0_server_holder["t0"] = time.perf_counter()
                    # tiny yield to let reader run
                    await asyncio.sleep(0)
                await ws.send(msgpack.packb({"type": "Eos"}, use_bin_type=True))
            except (asyncio.CancelledError, Exception):
                # Connection closed or task cancelled, exit gracefully
                pass

        # run both concurrently, handle exceptions gracefully
        await asyncio.gather(reader(), sender(), return_exceptions=True)

    wall_s = time.perf_counter() - t0_e2e
    wall_to_final_s = (final_time - t0_e2e) if final_time else wall_s

    if pcm_chunks:
        pcm_int16 = np.concatenate(pcm_chunks, dtype=np.int16)
        # Write WAV
        import wave

        out_path.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(out_path), "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(sample_rate)
            wf.writeframes(pcm_int16.tobytes())
        audio_s = len(pcm_int16) / float(sample_rate)
    else:
        audio_s = 0.0

    metrics = {
        "server": server,
        "voice": voice,
        "outfile": str(out_path),
        "wall_s": float(wall_s),
        "wall_to_final_s": float(wall_to_final_s),
        "audio_s": float(audio_s),
        "ttfb_e2e_s": float(time_to_first_audio_e2e or 0.0),
        "ttfb_server_s": float(time_to_first_audio_server or 0.0),
        "connect_ms": float(connect_ms),
        "handshake_ms": float(handshake_ms),
    }

    return metrics


def main() -> None:
    args = parse_args()
    texts = [t for t in (args.text or [DEFAULT_TEXT]) if t and t.strip()]

    # Build server string from args/env
    server_str = (args.server or "").strip()
    if not server_str:
        host = (args.host or os.getenv("RUNPOD_TCP_HOST") or "127.0.0.1").strip()
        port = args.port
        server_str = _compose_server_from_host_port(host, port, args.secure)

    ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out = Path(args.outfile) if args.outfile else (AUDIO_DIR / f"tts_{ts}.wav")

    print(f"Server: {server_str}")
    print(f"Voice:  {args.voice}")
    print(f"Out:    {out}")
    print(f"Text(s): {len(texts)}")

    res = asyncio.run(
        tts_client(
            server_str,
            args.voice,
            texts,
            args.kyutai_api_key,
            args.runpod_api_key,
            out,
        )
    )
    print("\n== Result ==")
    print(f"Saved: {res['outfile']}")
    print(f"TTFB (e2e): {res['ttfb_e2e_s']:.3f}s")
    print(f"TTFB (srv): {res['ttfb_server_s']:.3f}s")
    print(f"Wall:  {res['wall_s']:.3f}s (to Final: {res['wall_to_final_s']:.3f}s)")
    print(f"Audio: {res['audio_s']:.3f}s")
    print(f"Connect: {res['connect_ms']:.1f}ms  Handshake: {res['handshake_ms']:.1f}ms")


if __name__ == "__main__":
    main()
