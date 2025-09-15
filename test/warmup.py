#!/usr/bin/env python3
"""
Warmup script with WebSocket connection reuse and word-by-word sending.

This demonstrates proper TTFB measurement by reusing WebSocket connections
while sending text word-by-word like the other test clients.
"""
from __future__ import annotations

import argparse
import asyncio
import os
import time
from pathlib import Path
from typing import List, Optional

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
    # Let server use default seq_len instead of constraining to 128
    qp.append("temp=0.2")
    qp.append("seed=42")
    return f"{base}/api/tts_streaming?{'&'.join(qp)}"


async def warmup_with_reuse(
    server: str,
    texts: List[str],
    voice_path: Optional[str] = None,
    api_key: Optional[str] = None,
) -> None:
    """
    Demonstrates WebSocket connection reuse with word-by-word sending.
    This eliminates connection overhead while matching test client behavior.
    """
    url = _ws_url(server, voice_path)
    headers = {"kyutai-api-key": api_key} if api_key else {}
    
    ws_options = {
        "additional_headers": headers,
        "max_size": None,
        "ping_interval": 30,
        "ping_timeout": 30,
        "max_queue": None,
        "write_limit": 2**22,
        "open_timeout": 30,
        "close_timeout": 0.5,
    }

    print(f"Connecting to {url}")
    print(f"Warming up with {len(texts)} requests using connection reuse...")
    
    async with connect(url, **ws_options) as ws:  # type: ignore
        for i, text in enumerate(texts):
            print(f"\nRequest {i+1}/{len(texts)}: '{text[:50]}{'...' if len(text) > 50 else ''}'")
            
            # Metrics for this request only
            t0_request = time.perf_counter()
            ttfb_request: Optional[float] = None
            pcm_chunks: List[np.ndarray] = []
            sample_rate = 24000
            sr_seen = set()
            
            # Send request word by word
            words = text.split()
            send_time = time.perf_counter()  # Start timing from first word
            for j, word in enumerate(words):
                fragment = word if j == 0 else (" " + word)
                await ws.send(msgpack.packb({"type": "Text", "text": fragment}, use_bin_type=True))
                await asyncio.sleep(0)  # tiny yield
            await ws.send(msgpack.packb({"type": "Eos"}, use_bin_type=True))
            
            # Receive response
            while True:
                raw = await ws.recv()
                if not isinstance(raw, (bytes, bytearray)):
                    continue
                    
                data = msgpack.unpackb(raw, raw=False)
                kind = data.get("type")
                
                if kind in ("Audio", "Pcm", "AudioPcm", "AudioChunk", "AudioF32", "AudioI16"):
                    # Extract PCM data  
                    arr = None
                    for k in ("pcm", "data", "pcm_i16", "pcm_f32", "samples"):
                        if k in data and data[k] is not None:
                            arr = np.asarray(data[k])
                            break
                    
                    if arr is not None and arr.size > 0:
                        if ttfb_request is None:
                            ttfb_request = time.perf_counter() - send_time
                        
                        # Force 24kHz (Moshi/Mimi standard)
                        sample_rate = 24000
                        sr_seen.add(sample_rate)
                        
                        if arr.dtype.kind == "f":
                            arr = np.clip(arr, -1.0, 1.0)
                            pcm_i16 = (arr * 32767.0).astype(np.int16)
                        else:
                            pcm_i16 = arr.astype(np.int16, copy=False)
                        
                        pcm_chunks.append(pcm_i16)
                        
                elif kind in ("End", "Final", "Done", "Marker"):
                    break
                elif kind == "Error":
                    print(f"  Server error: {data}")
                    break
            
            # Compute metrics for this request
            wall_time = time.perf_counter() - t0_request
            
            if pcm_chunks:
                pcm_int16 = np.concatenate(pcm_chunks, dtype=np.int16)
                audio_s = len(pcm_int16) / float(sample_rate)
                
                # Save audio file
                ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
                out_path = WARMUP_DIR / f"warmup_{ts}_{i:02d}.wav"
                with wave.open(str(out_path), "wb") as wf:
                    wf.setnchannels(1)
                    wf.setsampwidth(2)
                    wf.setframerate(sample_rate)
                    wf.writeframes(pcm_int16.tobytes())
                
                # Check for sample rate issues
                if len(sr_seen) != 1:
                    print(f"  WARNING: Mixed sample rates: {sr_seen}")
                
                rtf = wall_time / audio_s if audio_s > 0 else float("inf")
                print(f"  TTFB (server): {ttfb_request or 0:.3f}s")
                print(f"  Wall time: {wall_time:.3f}s")
                print(f"  Audio duration: {audio_s:.3f}s") 
                print(f"  RTF: {rtf:.3f}")
                print(f"  Saved: {out_path.name}")
            else:
                print(f"  No audio received")

    print(f"\nWarmup completed. Audio files saved to {WARMUP_DIR}")


def main():
    ap = argparse.ArgumentParser(description="TTS warmup with connection reuse")
    ap.add_argument("--server", default="127.0.0.1:8089", help="Server address")
    ap.add_argument("--voice", default=os.environ.get("TTS_VOICE", "ears/p004/freeform_speech_01.wav.1e68beda@240.safetensors"), help="Voice path")
    ap.add_argument("--api-key", default=None, help="API key (defaults to KYUTAI_API_KEY env var or 'public_token')")
    ap.add_argument("--text", action="append", default=None, help="Text to synthesize (repeat for multiple)")
    args = ap.parse_args()
    
    # Default texts if none provided
    texts = args.text or [
        "This is a warmup request to load the model.",
        "The quick brown fox jumps over the lazy dog.",
        "Hello, this is a test of the TTS system with proper connection reuse.",
        "Connection reuse should show better TTFB measurements."
    ]
    
    # Determine API key
    api_key = args.api_key or os.getenv("KYUTAI_API_KEY") or "public_token"
    
    asyncio.run(warmup_with_reuse(args.server, texts, args.voice, api_key))


if __name__ == "__main__":
    main()