#!/usr/bin/env python3
"""
Warmup moshi-server by sending short texts and discarding output after writing WAVs to .data/warmup.
Measures TTFB and wall-to-final to prime caches and JIT.
"""
from __future__ import annotations
import argparse, asyncio, os, time, json, wave
from pathlib import Path
from typing import Optional, Iterable
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
    qp = []
    if voice_path:
        qp.append(f"voice={quote(voice_path)}")
    qp.append("format=PcmMessagePack")  # server converts to raw PCM frames
    qp.append("max_seq_len=768")
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
    sr = msg.get("sample_rate") or msg.get("sr") or 24000
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

    t0 = time.perf_counter()
    ttfb: Optional[float] = None
    sample_rate = 24000
    pcm_chunks: list[np.ndarray] = []

    async with connect(url, **ws_options) as ws:
        # Kyutai-style streaming: send text in ~12-token chunks with proper spacing
        def create_chunks(text: str, target_tokens_per_chunk: int = 12) -> list[str]:
            """Split text into chunks of approximately target_tokens_per_chunk tokens."""
            words = text.split()
            chunks = []
            current_chunk = []
            
            for word in words:
                current_chunk.append(word)
                # Rough estimate: average ~1.3 tokens per word for English
                if len(current_chunk) >= max(1, target_tokens_per_chunk // 1.3):
                    chunks.append(" ".join(current_chunk))
                    current_chunk = []
            
            if current_chunk:
                chunks.append(" ".join(current_chunk))
            
            return chunks
        
        chunks = create_chunks(text)
        # Merge tiny first two chunks if they're too small for good priming
        if len(chunks) >= 2 and len(chunks[0].split()) < 10:
            chunks = [" ".join(chunks[:2])] + chunks[2:]
        
        for i, chunk in enumerate(chunks):
            # Add leading space to every chunk, including the first, to keep SPM segmentation consistent
            fragment = (" " + chunk)
            await ws.send(msgpack.packb({"type": "Text", "text": fragment}, use_bin_type=True))
        
        # End-of-sentence to trigger synthesis
        await ws.send(msgpack.packb({"type": "Eos"}, use_bin_type=True))

        async for raw in ws:
            if not isinstance(raw, (bytes, bytearray)):
                continue
            msg = msgpack.unpackb(raw, raw=False)

            mtype = msg.get("type")
            if mtype in ("Audio", "Pcm", "AudioPcm", "AudioChunk", "AudioF32", "AudioI16"):
                pcm_i16, sr = _extract_pcm(msg)
                if pcm_i16.size > 0:
                    if ttfb is None:
                        ttfb = time.perf_counter() - t0
                    sample_rate = sr
                    pcm_chunks.append(pcm_i16)
            elif mtype in ("End", "Final", "Done", "Marker"):
                break
            elif mtype in ("Error",):
                raise RuntimeError(f"server error: {msg}")

    wall = time.perf_counter() - t0

    if pcm_chunks:
        pcm = np.concatenate(pcm_chunks, dtype=np.int16)
        _write_wav_int16(out_path, pcm, sample_rate)
        audio_s = len(pcm) / float(sample_rate)
        return {
            "ttfb_s": float(ttfb or 0.0),
            "wall_s": float(wall),
            "audio_s": float(audio_s),
            "rtf": float((wall / audio_s) if audio_s > 0 else 0.0),
            "xrt": float((audio_s / wall) if wall > 0 else 0.0),
            "samples": int(len(pcm)),
            "sr": int(sample_rate),
        }
    else:
        return {
            "ttfb_s": 0.0,
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
    ap.add_argument("--voice", default=str(DATA_DIR / "voices" / "ears" / "p004" / "freeform_speech_01.wav"))
    ap.add_argument("--text", default="Warming up the model and caches.")
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
    print(f"TTFB: {res['ttfb_s']:.4f}s")
    print(f"Wall: {res['wall_s']:.4f}s") 
    print(f"Audio: {res['audio_s']:.4f}s")
    print(f"RTF: {res['rtf']:.4f}")
    print(f"xRT: {res['xrt']:.4f}")
    print(f"Samples: {res['samples']}")
    print(f"Sample rate: {res['sr']}Hz")
    
    return 0

if __name__ == "__main__":
    raise SystemExit(main())