#!/usr/bin/env python3
"""
Warmup moshi-server by sending short texts and discarding output after writing WAVs to .data/warmup.
Measures TTFB and wall-to-final to prime caches and JIT.
"""
from __future__ import annotations

import argparse
import asyncio
import os
import time
from pathlib import Path
from typing import Optional

import msgpack  # type: ignore
import numpy as np  # type: ignore
import websockets  # type: ignore
from urllib.parse import quote
import wave
import json

ROOT_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT_DIR / ".data"
WARM_DIR = DATA_DIR / "warmup"
WARM_DIR.mkdir(parents=True, exist_ok=True)


def _ws_url(server: str, voice_path: Optional[str]) -> str:
    if server.startswith(("ws://", "wss://")):
        base = server.rstrip("/")
    else:
        base = f"ws://{server.strip().rstrip('/')}"
    qp = []
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


async def _run(server: str, text: str, voice_path: Optional[str], out_path: Path) -> dict:
    url = _ws_url(server, voice_path)

    headers = []
    api_key = os.getenv("KYUTAI_API_KEY") or os.getenv("YAP_API_KEY")
    if api_key:
        headers.append(("kyutai-api-key", api_key))

    ws_options = {
        "extra_headers": headers,
        "compression": None,
        "max_size": None,
        "ping_interval": 20,
        "ping_timeout": 20,
        "max_queue": None,
        "write_limit": 2**22,
        "open_timeout": 10,
        "close_timeout": 0.5,
    }

    t0 = time.perf_counter()
    ttfb: float | None = None
    sample_rate = 24000
    pcm_accum: list[int] = []

    async with websockets.connect(url, **ws_options) as ws:  # type: ignore
        await ws.send(msgpack.packb({"type": "Text", "text": text}, use_bin_type=True))
        await ws.send(msgpack.packb({"type": "Flush"}, use_bin_type=True))

        async for raw in ws:
            if not isinstance(raw, (bytes, bytearray)):
                continue
            data = msgpack.unpackb(raw, raw=False)
            kind = data.get("type")
            if kind in ("Audio", "Pcm", "AudioPcm"):
                if ttfb is None:
                    ttfb = time.perf_counter() - t0
                pcm = data.get("pcm") or data.get("data") or []
                if pcm:
                    sr = data.get("sample_rate") or data.get("sr")
                    if isinstance(sr, int) and sr > 0:
                        sample_rate = sr
                    arr = np.asarray(pcm)
                    if arr.dtype.kind == "f":
                        arr = np.clip(arr, -1.0, 1.0)
                        arr = (arr * 32767.0).astype(np.int16)
                    else:
                        arr = arr.astype(np.int16)
                    pcm_accum.extend(arr.tolist())
            elif kind in ("End", "Final", "Done", "Marker"):
                break

    wall_s = time.perf_counter() - t0

    audio_s = 0.0
    if pcm_accum:
        pcm_int16 = np.asarray(pcm_accum, dtype=np.int16)
        _write_wav_int16(out_path, pcm_int16, sample_rate)
        audio_s = len(pcm_int16) / float(sample_rate)

    return {
        "ttfb_s": float(ttfb or 0.0),
        "wall_s": float(wall_s),
        "audio_s": float(audio_s),
        "rtf": float((wall_s / audio_s) if audio_s > 0 else 0.0),
        "xrt": float((audio_s / wall_s) if wall_s > 0 else 0.0),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Warmup Kyutai TTS over WebSocket")
    ap.add_argument("--server", default="127.0.0.1:8089")
    ap.add_argument("--voice", default=str(DATA_DIR / "voices" / "ears" / "p004" / "freeform_speech_01.wav"))
    ap.add_argument("--text", default="Warming up the model and caches.")
    args = ap.parse_args()

    out = WARM_DIR / "warmup.wav"
    res = asyncio.run(_run(args.server, args.text, args.voice, out))
    print(f"Saved warmup WAV: {out}")
    print(json.dumps(res, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


