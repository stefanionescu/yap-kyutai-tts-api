#!/usr/bin/env python3
"""
Benchmark WebSocket streaming for Kyutai TTS (moshi-server).

Sends text prompts and receives PCM audio over WS, saving WAVs to .data/bench.
Reports wall, audio duration, TTFB (first audio chunk), RTF, xRT, throughput.
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import os
import statistics as stats
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Tuple, Optional

import msgpack  # type: ignore
import numpy as np  # type: ignore
from websockets.asyncio.client import connect  # type: ignore
from urllib.parse import quote
import wave


ROOT_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT_DIR / ".data"
BENCH_DIR = DATA_DIR / "bench"
RESULTS_DIR = ROOT_DIR / "test" / "results"
RESULTS_DIR.mkdir(parents=True, exist_ok=True)
BENCH_DIR.mkdir(parents=True, exist_ok=True)


def _ws_url(server: str, voice_path: Optional[str]) -> str:
    if server.startswith(("ws://", "wss://")):
        base = server.rstrip("/")
    else:
        base = f"ws://{server.strip().rstrip('/')}"
    qp = []
    if voice_path:
        qp.append(f"voice={quote(voice_path)}")
    qp.append("format=PcmMessagePack")
    # Optional: reduce KV cache to limit VRAM usage under high concurrency
    qp.append("max_seq_len=512")
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
    sr = msg.get("sample_rate") or msg.get("sr") or 24000
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
        # NOTE: v15 dropped the old "compression" kwarg; use "extensions" if needed.
    }

    t0 = time.perf_counter()
    time_to_first_audio: Optional[float] = None
    sample_rate = 24000  # fallback if not provided by server
    pcm_chunks: List[np.ndarray] = []  # accumulate as int16 chunks

    async with connect(url, **ws_options) as ws:  # type: ignore
        # Kyutai-style streaming: send text in ~8-token chunks with proper spacing, then Eos to trigger synthesis
        def create_chunks(text: str, target_tokens_per_chunk: int = 8) -> List[str]:
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
        for i, chunk in enumerate(chunks):
            # Add leading space to every chunk except the very first
            fragment = ((" " if i > 0 else "") + chunk)
            await ws.send(msgpack.packb({"type": "Text", "text": fragment}, use_bin_type=True))
        await ws.send(msgpack.packb({"type": "Eos"}, use_bin_type=True))

        async for raw in ws:  # server sends binary msgpack frames
            if not isinstance(raw, (bytes, bytearray)):
                continue
            data = msgpack.unpackb(raw, raw=False)
            kind = data.get("type")

            if kind in ("Audio", "Pcm", "AudioPcm", "AudioChunk", "AudioF32", "AudioI16"):
                pcm_i16, sr = _extract_pcm(data)
                if pcm_i16.size > 0:
                    if time_to_first_audio is None:
                        time_to_first_audio = time.perf_counter() - t0
                    sample_rate = sr
                    pcm_chunks.append(pcm_i16)

            elif kind in ("End", "Final", "Done", "Marker"):
                # End of stream
                break
            elif kind == "Error":
                raise RuntimeError(f"Server error: {data}")
            else:
                # Ignore other server messages
                continue

    wall_s = time.perf_counter() - t0

    # Write WAV and compute audio seconds
    if pcm_chunks:
        pcm_int16 = np.concatenate(pcm_chunks, dtype=np.int16)
        _write_wav_int16(out_path, pcm_int16, sample_rate)
        audio_s = len(pcm_int16) / float(sample_rate)
    else:
        audio_s = 0.0

    rtf = (wall_s / audio_s) if audio_s > 0 else float("inf")
    xrt = (audio_s / wall_s) if wall_s > 0 else 0.0

    return {
        "wall_s": float(wall_s),
        "audio_s": float(audio_s),
        "ttfb_s": float(time_to_first_audio or 0.0),
        "rtf": float(rtf),
        "xrt": float(xrt),
        "throughput_min_per_min": float(xrt),
    }


def _summarize(title: str, results: List[Dict[str, float]]) -> None:
    if not results:
        print(f"{title}: no results")
        return

    def p(v: List[float], q: float) -> float:
        k = max(0, min(len(v) - 1, int(round(q * (len(v) - 1)))))
        return sorted(v)[k]

    wall = [r.get("wall_s", 0.0) for r in results]
    audio = [r.get("audio_s", 0.0) for r in results]
    rtf = [r.get("rtf", 0.0) for r in results]
    xrt = [r.get("xrt", 0.0) for r in results]
    ttfb_vals = [r.get("ttfb_s", 0.0) for r in results if r.get("ttfb_s", 0.0) > 0]

    print(f"\n== {title} ==")
    print(f"n={len(results)}")
    print(f"Wall s      | avg={stats.mean(wall):.4f}  p50={stats.median(wall):.4f}  p95={p(wall,0.95):.4f}")
    if ttfb_vals:
        print(f"TTFB s      | avg={stats.mean(ttfb_vals):.4f}  p50={stats.median(ttfb_vals):.4f}  p95={p(ttfb_vals,0.95):.4f}")
    print(f"Audio s     | avg={stats.mean(audio):.4f}")
    print(f"RTF         | avg={stats.mean(rtf):.4f}  p50={stats.median(rtf):.4f}  p95={p(rtf,0.95):.4f}")
    print(f"xRT         | avg={stats.mean(xrt):.4f}")
    print(f"Throughput  | avg={stats.mean([r.get('throughput_min_per_min',0.0) for r in results]):.2f} min/min")


DEFAULT_TEXT = "This is a test for the Yap TTS API. Hello there! I'm super happy to meet you."

def _load_texts(inline_texts: Optional[List[str]]) -> List[str]:
    if inline_texts:
        return [t for t in inline_texts if t and t.strip()]
    return [DEFAULT_TEXT]


async def bench_ws(
    server: str,
    total_reqs: int,
    concurrency: int,
    voice_path: Optional[str],
    texts: List[str],
    api_key: str,
) -> Tuple[List[Dict[str, float]], int, int]:
    sem = asyncio.Semaphore(max(1, concurrency))
    results: List[Dict[str, float]] = []
    errors_total = 0

    async def worker(req_idx: int):
        nonlocal errors_total
        async with sem:
            # Choose text in round-robin
            text = texts[req_idx % len(texts)]
            # Unique output path per request
            ts = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
            out_path = BENCH_DIR / f"bench_{ts}_{req_idx:05d}.wav"
            try:
                r = await _tts_one(server, text, voice_path, out_path, api_key=api_key)
                results.append(r)
            except Exception as e:
                errors_total += 1
                err_path = RESULTS_DIR / "bench_errors.txt"
                with contextlib.suppress(Exception):
                    with open(err_path, "a", encoding="utf-8") as ef:
                        ef.write(f"{datetime.utcnow().isoformat()}Z idx={req_idx} err={e}\n")

    tasks = [asyncio.create_task(worker(i)) for i in range(total_reqs)]
    await asyncio.gather(*tasks, return_exceptions=True)
    return results[:total_reqs], 0, errors_total


def main() -> None:
    ap = argparse.ArgumentParser(description="WebSocket streaming benchmark (Kyutai TTS)")
    ap.add_argument("--server", default="127.0.0.1:8089", help="host:port or ws://host:port or full URL")
    ap.add_argument("--n", type=int, default=10, help="Total requests")
    ap.add_argument("--concurrency", type=int, default=10, help="Max concurrent sessions")
    ap.add_argument("--voice", type=str, default=str(DATA_DIR / "voices" / "ears" / "p004" / "freeform_speech_01.wav"), help="Reference voice path on the server filesystem")
    ap.add_argument("--text", action="append", default=None, help="Inline text prompt (repeat for multiple)")
    ap.add_argument("--api-key", default=None, help="API key for authentication (defaults to KYUTAI_API_KEY env var or 'public_token')")
    args = ap.parse_args()
    
    # Determine API key: CLI arg -> env var -> default to public_token
    api_key = args.api_key or os.getenv("KYUTAI_API_KEY") or "public_token"

    texts = _load_texts(args.text)

    print(f"Benchmark → WS (TTS) | n={args.n} | concurrency={args.concurrency} | server={args.server}")
    print(f"Voice: {args.voice}")
    print(f"Texts: {len(texts)}")

    t0 = time.time()
    results, _rejected, errors = asyncio.run(bench_ws(args.server, args.n, args.concurrency, args.voice, texts, api_key))
    elapsed = time.time() - t0

    _summarize("TTS Streaming", results)
    print(f"Errors: {errors}")
    print(f"Total elapsed: {elapsed:.4f}s")
    if results:
        total_audio = sum(r.get("audio_s", 0.0) for r in results)
        print(f"Total audio synthesized: {total_audio:.2f}s")
        print(f"Overall throughput: {total_audio/elapsed:.2f} min/min")

    # per-session JSONL
    try:
        metrics_path = RESULTS_DIR / "bench_metrics.jsonl"
        with open(metrics_path, "w", encoding="utf-8") as f:
            for rec in results:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        print(f"Saved per-session metrics to {metrics_path}")
    except Exception as e:
        print(f"Warning: could not write metrics JSONL: {e}")


if __name__ == "__main__":
    main()


