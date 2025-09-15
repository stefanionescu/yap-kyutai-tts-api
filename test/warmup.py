#!/usr/bin/env python3
"""
Warmup moshi-server by sending short texts and discarding output after writing WAVs to .data/warmup.
Measures TTFB and wall-to-final to prime caches and JIT.
"""
from __future__ import annotations
import argparse, asyncio, os, time, json, wave
from pathlib import Path
from typing import Optional, Iterable, List
import msgpack, numpy as np
from websockets.asyncio.client import connect
from urllib.parse import quote

ROOT_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT_DIR / ".data"
WARM_DIR = DATA_DIR / "warmup"
WARM_DIR.mkdir(parents=True, exist_ok=True)

def _ws_url(server: str, voice_path: Optional[str]) -> str:
    base = server if server.startswith(("ws://", "wss://")) else f"ws://{server}"
    base = base.rstrip("/")
    qp: List[str] = [
        "format=PcmMessagePack",
        "max_seq_len=128",
        "temp=0.2",
        "seed=42",
    ]
    if voice_path:
        qp.append(f"voice={quote(voice_path)}")
    return f"{base}/api/tts_streaming?{'&'.join(qp)}"

def _write_wav_int16(path: Path, pcm_i16: np.ndarray, sr: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)  # 16-bit
        wf.setframerate(sr)
        wf.writeframes(pcm_i16.tobytes())

def _extract_pcm(msg: dict) -> tuple[np.ndarray, int]:
    """Return (int16 mono samples, sample_rate) or (empty, sr). Accept multiple shapes."""
    # Moshi/Mimi always operates at 24 kHz - force this regardless of server claims
    sr = 24000
    # candidate fields in order of likelihood
    candidates: Iterable[str] = ("pcm", "data", "pcm_i16", "pcm_f32", "samples")
    for k in candidates:
        if k in msg and msg[k] is not None:
            arr = np.asarray(msg[k])
            if arr.size == 0:
                return np.empty(0, np.int16), sr
            if arr.dtype.kind == "f":
                arr = np.clip(arr, -1.0, 1.0)
                return (arr * 32767.0).astype(np.int16), sr
            # ints: assume already in [-32768,32767]
            return arr.astype(np.int16, copy=False), sr
    return np.empty(0, np.int16), sr

async def _run(server: str, text: str, voice_path: Optional[str], out_path: Path, api_key: str) -> dict:
    url = _ws_url(server, voice_path)
    headers = {"kyutai-api-key": api_key} if api_key else {}
    ws_options = {
        "additional_headers": headers,  # websockets v15 API
        "max_size": None,
        "ping_interval": 30,
        "ping_timeout": 30,
        "max_queue": None,
        "write_limit": 2**22,
        "open_timeout": 30,
        "close_timeout": 0.5,
    }

    # We'll measure both:
    # 1) end-to-end TTFB (includes WS connect) -> ttfb_e2e_s
    # 2) server TTFB (post-connect, post-send) -> ttfb_server_s (matches Kyutai's claim)
    t0_e2e = time.perf_counter()
    time_to_first_audio_e2e: Optional[float] = None
    time_to_first_audio_server: Optional[float] = None
    sample_rate = 24000
    pcm_chunks: list[np.ndarray] = []

    async with connect(url, **ws_options) as ws:
        # True full-duplex: concurrent reader/sender for optimal TTFB
        t0_server_holder = {"t0": None}

        async def reader():
            nonlocal sample_rate, time_to_first_audio_e2e, time_to_first_audio_server
            try:
                while True:
                    raw = await ws.recv()
                    if not isinstance(raw, (bytes, bytearray)):
                        continue
                    msg = msgpack.unpackb(raw, raw=False)

                    mtype = msg.get("type")
                    if mtype in ("Audio", "Pcm", "AudioPcm", "AudioChunk", "AudioF32", "AudioI16"):
                        pcm_i16, sr = _extract_pcm(msg)
                        if pcm_i16.size > 0:
                            if time_to_first_audio_e2e is None:
                                time_to_first_audio_e2e = time.perf_counter() - t0_e2e
                            if time_to_first_audio_server is None and t0_server_holder["t0"] is not None:
                                time_to_first_audio_server = time.perf_counter() - t0_server_holder["t0"]
                            sample_rate = sr
                            pcm_chunks.append(pcm_i16)
                    elif mtype in ("End", "Final", "Done", "Marker"):
                        break
                    elif mtype in ("Error",):
                        raise RuntimeError(f"server error: {msg}")
            except (asyncio.CancelledError, Exception):
                # Connection closed or task cancelled, exit gracefully
                pass

        async def sender():
            try:
                words = text.split()
                for i, word in enumerate(words):
                    fragment = word if i == 0 else (" " + word)
                    await ws.send(msgpack.packb({"type": "Text", "text": fragment}, use_bin_type=True))
                    if t0_server_holder["t0"] is None:
                        t0_server_holder["t0"] = time.perf_counter()
                    # tiny yield to let reader run
                    await asyncio.sleep(0)
                # End-of-sentence to trigger synthesis
                await ws.send(msgpack.packb({"type": "Eos"}, use_bin_type=True))
            except (asyncio.CancelledError, Exception):
                # Connection closed or task cancelled, exit gracefully
                pass

        # run both concurrently, handle exceptions gracefully
        await asyncio.gather(reader(), sender(), return_exceptions=True)

    wall = time.perf_counter() - t0_e2e

    if pcm_chunks:
        pcm = np.concatenate(pcm_chunks, dtype=np.int16)
        _write_wav_int16(out_path, pcm, sample_rate)
        audio_s = len(pcm) / float(sample_rate)
        return {
            "ttfb_e2e_s": float(time_to_first_audio_e2e or 0.0),
            "ttfb_server_s": float(time_to_first_audio_server or 0.0),
            "wall_s": float(wall),
            "audio_s": float(audio_s),
            "rtf": float((wall / audio_s) if audio_s > 0 else 0.0),
            "xrt": float((audio_s / wall) if wall > 0 else 0.0),
            "samples": int(len(pcm)),
            "sr": int(sample_rate),
        }
    else:
        return {
            "ttfb_e2e_s": 0.0,
            "ttfb_server_s": 0.0,
            "wall_s": float(wall),
            "audio_s": 0.0,
            "rtf": 0.0,
            "xrt": 0.0,
            "samples": 0,
            "sr": int(sample_rate),
        }

def main() -> int:
    ap = argparse.ArgumentParser(description="Warmup Kyutai TTS over WebSocket (PCM MessagePack)")
    ap.add_argument("--server", default="127.0.0.1:8089")
    ap.add_argument("--voice", default=os.getenv("TTS_VOICE", "ears/p004/freeform_speech_01.wav.1e68beda@240.safetensors"))
    ap.add_argument("--text", default="Wow, you're so hot and handsome! Can't wait for the app to be done so we can talk. See you there sweetie!")
    ap.add_argument("--api-key", default=None, help="API key for authentication (defaults to KYUTAI_API_KEY env var or 'public_token')")
    args = ap.parse_args()

    api_key = args.api_key or os.getenv("KYUTAI_API_KEY") or "public_token"
    out = WARM_DIR / "warmup.wav"
    res = asyncio.run(_run(args.server, args.text, args.voice, out, api_key))

    if res.get("samples", 0) > 0:
        print(f"Saved warmup WAV: {out}")
    else:
        print("No audio received (check logs / config).")
    
    # Print results without JSON formatting
    print(f"TTFB (e2e): {res['ttfb_e2e_s']:.4f}s")
    print(f"TTFB (srv): {res['ttfb_server_s']:.4f}s") 
    print(f"Wall: {res['wall_s']:.4f}s") 
    print(f"Audio: {res['audio_s']:.4f}s")
    print(f"RTF: {res['rtf']:.4f}")
    print(f"xRT: {res['xrt']:.4f}")
    print(f"Samples: {res['samples']}")
    print(f"Sample rate: {res['sr']}Hz")
    
    return 0

if __name__ == "__main__":
    raise SystemExit(main())