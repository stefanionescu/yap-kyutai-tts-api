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
    qp: List[str] = []
    if voice_path:
        qp.append(f"voice={quote(voice_path)}")
    qp.append("format=PcmMessagePack")
    # Let server use default seq_len instead of constraining to 128
    qp.append("temp=0.2")
    qp.append("seed=42")
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
        # NOTE: v15 dropped the old "compression" kwarg; use "extensions" if needed.
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
        metrics = {"ttfb_e2e_s": None, "ttfb_server_s": None}
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
                words = text.split()
                for i, word in enumerate(words):
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
    ttfb_e2e = [r.get("ttfb_e2e_s", 0.0) for r in results if r.get("ttfb_e2e_s", 0.0) > 0]
    ttfb_srv = [r.get("ttfb_server_s", 0.0) for r in results if r.get("ttfb_server_s", 0.0) > 0]

    print(f"\n== {title} ==")
    print(f"n={len(results)}")
    print(f"Wall s      | avg={stats.mean(wall):.4f}  p50={stats.median(wall):.4f}  p95={p(wall,0.95):.4f}")
    if ttfb_e2e:
        print(f"TTFB (e2e)  | avg={stats.mean(ttfb_e2e):.4f}  p50={stats.median(ttfb_e2e):.4f}  p95={p(ttfb_e2e,0.95):.4f}")
    if ttfb_srv:
        print(f"TTFB (srv)  | avg={stats.mean(ttfb_srv):.4f}  p50={stats.median(ttfb_srv):.4f}  p95={p(ttfb_srv,0.95):.4f}")
    print(f"Audio s     | avg={stats.mean(audio):.4f}")
    print(f"RTF         | avg={stats.mean(rtf):.4f}  p50={stats.median(rtf):.4f}  p95={p(rtf,0.95):.4f}")
    print(f"xRT         | avg={stats.mean(xrt):.4f}")
    print(f"Throughput  | avg={stats.mean([r.get('throughput_min_per_min',0.0) for r in results]):.2f} min/min")


DEFAULT_TEXT = "Wow, you're so hot and handsome! Can't wait for the app to be done so we can talk. See you there sweetie!"

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
    ap.add_argument("--voice", type=str, default=os.environ.get("TTS_VOICE", "ears/p004/freeform_speech_01.wav.1e68beda@240.safetensors"), help="Reference voice path on the server filesystem")
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


