#!/usr/bin/env python3
"""
Single TTS warmup request like bench.py but for one transaction only.
"""
from __future__ import annotations

import argparse
import asyncio
import os
import time
from datetime import datetime
from pathlib import Path
from typing import List, Optional, Dict

import msgpack  # type: ignore
import numpy as np  # type: ignore
from websockets.asyncio.client import connect  # type: ignore
from urllib.parse import quote
import wave


ROOT_DIR = Path(__file__).resolve().parent.parent
WARMUP_DIR = ROOT_DIR / ".data" / "warmup"
WARMUP_DIR.mkdir(parents=True, exist_ok=True)


def _ws_url(server: str, voice_path: Optional[str]) -> str:
    if server.startswith(("ws://", "wss://")):
        base = server.rstrip("/")
    else:
        base = f"ws://{server.strip().rstrip('/')}"
    qp: List[str] = []
    if voice_path:
        qp.append(f"voice={quote(voice_path)}")
    qp.append("format=PcmMessagePack")
    return f"{base}/api/tts_streaming?{'&'.join(qp)}"


def _write_wav_int16(output_path: Path, pcm_int16: np.ndarray, sample_rate: int) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(output_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm_int16.tobytes())


def _extract_pcm(msg: dict) -> tuple[np.ndarray, int]:
    """Return (int16 mono samples, sample_rate) or (empty, sr). Accept multiple shapes."""
    # Moshi/Mimi always operates at 24 kHz - force this regardless of server claims  
    sr = 24000
    # candidate fields in order of likelihood
    candidates = ("pcm", "data", "pcm_i16", "pcm_f32", "samples")
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


async def _tts_one(
    server: str,
    text: str,
    voice_path: Optional[str],
    out_path: Path,
    *,
    api_key: Optional[str] = None,
) -> Dict[str, float]:
    url = _ws_url(server, voice_path)

    headers = {"kyutai-api-key": api_key} if api_key else {}

    ws_options = {
        "additional_headers": headers,     # v15 name
        "max_size": None,                  # allowed (no limit)
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
    sample_rate = 24000  # fallback if not provided by server
    pcm_chunks: List[np.ndarray] = []  # accumulate as int16 chunks
    # 1.6B uses speaker embeddings; no prefix trimming needed
    prefix_samples_to_drop = 0
    # Sample rate verification to rule out SR mismatch
    sr_seen = set()

    async with connect(url, **ws_options) as ws:  # type: ignore
        # True full-duplex: concurrent reader/sender for optimal TTFB
        t0_server_holder = {"t0": None}

        async def reader():
            nonlocal sample_rate, time_to_first_audio_e2e, time_to_first_audio_server, prefix_samples_to_drop
            try:
                while True:
                    raw = await ws.recv()
                    if not isinstance(raw, (bytes, bytearray)):
                        continue
                    data = msgpack.unpackb(raw, raw=False)
                    kind = data.get("type")

                    if kind in ("Audio", "Pcm", "AudioPcm", "AudioChunk", "AudioF32", "AudioI16"):
                        pcm_i16, sr = _extract_pcm(data)
                        if pcm_i16.size > 0:
                            # No prefix trimming for 1.6B embeddings
                            if prefix_samples_to_drop > 0:
                                if pcm_i16.size <= prefix_samples_to_drop:
                                    prefix_samples_to_drop -= pcm_i16.size
                                    continue
                                pcm_i16 = pcm_i16[prefix_samples_to_drop:]
                                prefix_samples_to_drop = 0
                            if time_to_first_audio_e2e is None:
                                time_to_first_audio_e2e = time.perf_counter() - t0_e2e
                            if time_to_first_audio_server is None and t0_server_holder["t0"] is not None:
                                time_to_first_audio_server = time.perf_counter() - t0_server_holder["t0"]
                            sample_rate = sr
                            sr_seen.add(sr)  # Track sample rates for verification
                            pcm_chunks.append(pcm_i16)
                    elif kind in ("End", "Final", "Done", "Marker"):
                        break
                    elif kind == "Error":
                        raise RuntimeError(f"Server error: {data}")
            except (asyncio.CancelledError, Exception):
                # Connection closed or task cancelled, exit gracefully
                pass

        async def sender():
            try:
                # Send the full sentence in one go (no word-by-word streaming)
                await ws.send(msgpack.packb({"type": "Text", "text": text}, use_bin_type=True))
                if t0_server_holder["t0"] is None:
                    t0_server_holder["t0"] = time.perf_counter()
                await asyncio.sleep(0)
                await ws.send(msgpack.packb({"type": "Eos"}, use_bin_type=True))
            except (asyncio.CancelledError, Exception):
                # Connection closed or task cancelled, exit gracefully
                pass

        # run both concurrently, handle exceptions gracefully
        await asyncio.gather(reader(), sender(), return_exceptions=True)

    wall_s = time.perf_counter() - t0_e2e

    # Write WAV and compute audio seconds
    if pcm_chunks:
        pcm_int16 = np.concatenate(pcm_chunks, dtype=np.int16)
        _write_wav_int16(out_path, pcm_int16, sample_rate)
        audio_s = len(pcm_int16) / float(sample_rate)
        
        # Verify sample rate consistency
        if len(sr_seen) != 1:
            print(f"WARNING: Mixed sample rates in stream {out_path.name}: {sr_seen}")
    else:
        audio_s = 0.0

    rtf = (wall_s / audio_s) if audio_s > 0 else float("inf")
    xrt = (audio_s / wall_s) if wall_s > 0 else 0.0

    return {
        "wall_s": float(wall_s),
        "audio_s": float(audio_s),
        "ttfb_e2e_s": float(time_to_first_audio_e2e or 0.0),
        "ttfb_server_s": float(time_to_first_audio_server or 0.0),
        "rtf": float(rtf),
        "xrt": float(xrt),
        "throughput_min_per_min": float(xrt),
    }


def main() -> None:
    ap = argparse.ArgumentParser(description="Single TTS warmup request")
    ap.add_argument("--server", default="127.0.0.1:8089", help="Server address")
    ap.add_argument("--voice", default=os.environ.get("TTS_VOICE", "ears/p004/freeform_speech_01.wav.1e68beda@240.safetensors"), help="Voice path")
    ap.add_argument("--api-key", default=None, help="API key (defaults to KYUTAI_API_KEY env var or 'public_token')")
    ap.add_argument("--text", default="This is a warmup request to test the TTS system.", help="Text to synthesize")
    args = ap.parse_args()
    
    # Determine API key
    api_key = args.api_key or os.getenv("KYUTAI_API_KEY") or "public_token"
    
    # Output file
    ts = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    out_path = WARMUP_DIR / f"warmup_{ts}.wav"
    
    print(f"Warmup TTS request")
    print(f"Server: {args.server}")
    print(f"Voice: {args.voice}")
    print(f"Text: '{args.text}'")
    print(f"Output: {out_path}")
    
    result = asyncio.run(_tts_one(args.server, args.text, args.voice, out_path, api_key=api_key))
    
    print(f"\n== Results ==")
    print(f"TTFB (e2e): {result['ttfb_e2e_s']:.3f}s")
    print(f"TTFB (srv): {result['ttfb_server_s']:.3f}s")
    print(f"Wall time: {result['wall_s']:.3f}s")
    print(f"Audio duration: {result['audio_s']:.3f}s")
    print(f"RTF: {result['rtf']:.3f}")
    print(f"xRT: {result['xrt']:.3f}")
    print(f"Saved: {out_path}")


if __name__ == "__main__":
    main()