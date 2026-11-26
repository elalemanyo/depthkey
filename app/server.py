"""Depth Pro 2 over a WebSocket: the browser sends JPEG frames, gets depth in millimeters back.

Reply layout (little-endian): uint16 width, uint16 height, float32 inference ms,
float32 focal length px, then width*height uint16 depth in mm (0 = unknown, 65535 = far).
"""

import asyncio
import io
import logging
import os
import struct
import threading
import time
from pathlib import Path

import numpy as np
import torch
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from PIL import Image

from depth_pro_2 import create_model_and_transforms

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("depthkey")

MODEL = os.environ.get("MODEL", "depthpro2-s")
WINDOW = int(os.environ.get("WINDOW", "2"))
torch.backends.nnpack.set_flags(False)  # unsupported on this CPU; avoids log spam
torch.set_num_threads(int(os.environ.get("TORCH_THREADS", os.cpu_count() or 4)))

model, transform = create_model_and_transforms(MODEL)
log.info("Loaded %s on %s, window %d", MODEL, next(model.parameters()).device, WINDOW)

# One model, many tabs: run one inference at a time.
lock = threading.Lock()
STATIC = Path(__file__).parent / "static"

app = FastAPI()


@app.get("/")
def index():
    return FileResponse(STATIC / "index.html")


@app.get("/health")
def health():
    return {"model": MODEL, "window": WINDOW, "threads": torch.get_num_threads()}


def predict(stream, jpeg: bytes) -> tuple[bytes, tuple[int, int]]:  # (reply, (h, w))
    image = np.asarray(Image.open(io.BytesIO(jpeg)).convert("RGB"))
    h, w = image.shape[:2]
    start = time.perf_counter()
    with lock:
        predictions = stream.step(transform(image))
    ms = (time.perf_counter() - start) * 1000
    if not predictions:  # unbuffered mode returns one per step; guard anyway
        return b"", (h, w)
    p = predictions[-1]
    depth = p["depth"]
    if depth is None:
        depth = 1.0 / p["inverse_depth"].clamp_min(1e-6)  # relative only
    mm = torch.nan_to_num(depth * 1000, nan=0, posinf=65535).clamp(0, 65535)
    mm = mm.to(torch.int32).cpu().numpy()
    f_px = float(p["focallength_px"]) if p["focallength_px"] is not None else 0.0
    header = struct.pack("<HHff", w, h, ms, f_px)
    return header + mm.astype("<u2").tobytes(), (h, w)


@app.websocket("/ws")
async def ws(socket: WebSocket):
    await socket.accept()
    stream = None
    try:
        while True:
            message = await socket.receive()
            if message.get("type") == "websocket.disconnect":
                break
            if message.get("text") == "reset":
                stream = None
                continue
            jpeg = message.get("bytes")
            if not jpeg:
                continue
            # A stream belongs to one camera and frame size; the server opens a new one on change.
            if stream is None:
                stream = model.stream(window=WINDOW, mode="unbuffered")
            try:
                reply, _ = await asyncio.to_thread(predict, stream, jpeg)
            except ValueError:  # frame size changed mid-stream
                stream = model.stream(window=WINDOW, mode="unbuffered")
                reply, _ = await asyncio.to_thread(predict, stream, jpeg)
            if reply:
                await socket.send_bytes(reply)
    except WebSocketDisconnect:
        pass
