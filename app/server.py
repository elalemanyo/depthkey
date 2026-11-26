"""depthkey server: Depth Pro 2 for the browser.

/ws          live: the browser sends JPEG frames, gets depth in millimeters back. Reply layout
             (little-endian): uint16 width, uint16 height, float32 inference ms, float32 focal
             length px, then width*height uint16 depth in mm (0 = unknown, 65535 = far).
/api/depth   test mode: POST a photo, get its depth as a color PNG like Apple's CLI writes.
/api/turbo   the colormap of those PNGs, for the live depth view.
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
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles
from matplotlib import colormaps
from PIL import Image

from depth_pro_2 import create_model_and_transforms, load_rgb

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("depthkey")

MODEL = os.environ.get("MODEL", "depthpro2-s")
WINDOW = int(os.environ.get("WINDOW", "2"))
torch.backends.nnpack.set_flags(False)  # unsupported on this CPU; avoids log spam
torch.set_num_threads(int(os.environ.get("TORCH_THREADS", os.cpu_count() or 4)))

model, transform = create_model_and_transforms(MODEL)
log.info("Loaded %s on %s, window %d", MODEL, next(model.parameters()).device, WINDOW)

# Apple's CLI colors inverse depth with turbo, from 0 (infinitely far) to the nearest point + 20%.
TURBO = (colormaps["turbo"](np.linspace(0, 1, 256))[:, :3] * 255).astype(np.uint8)
COLOR_HEADROOM = 0.2

# One model, many tabs: run one inference at a time.
lock = threading.Lock()
STATIC = Path(__file__).parent / "static"

app = FastAPI()


@app.get("/")
def index():
    return FileResponse(STATIC / "index.html")


@app.get("/favicon.ico")
def favicon():
    return FileResponse(STATIC / "favicon-32.png")


app.mount("/static", StaticFiles(directory=STATIC), name="static")


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


@app.get("/api/turbo")
def turbo():
    return TURBO.tolist()


def depth_photo(data: bytes, max_side: int) -> tuple[bytes, dict[str, str]]:
    """Depth of one photo at up to ``max_side`` pixels, colored as Apple's CLI does."""
    try:
        image, f_px = load_rgb(io.BytesIO(data))  # upright per EXIF, focal length from EXIF
    except Exception as e:
        raise HTTPException(400, f"Not an image: {e}")
    h, w = image.shape[:2]
    scale = min(1.0, max_side / max(h, w))
    if scale < 1:
        w, h = round(w * scale), round(h * scale)
        image = np.asarray(Image.fromarray(image).resize((w, h), Image.LANCZOS))
        f_px = f_px * scale if f_px else None
    focal_source = "EXIF" if f_px else "estimated"

    start = time.perf_counter()
    with lock:
        p = model.infer(transform(image), f_px=f_px)
    ms = (time.perf_counter() - start) * 1000

    focal = float(p["focallength_px"])
    inverse = p["inverse_depth"].float().cpu().numpy() * (w / focal)  # 1/m, 0 = infinitely far
    high = float(inverse.max())
    color_scale = high * (1 + COLOR_HEADROOM) if high > 0 else 1.0
    colored = TURBO[np.clip(inverse * (256 / color_scale), 0, 255).astype(np.int32)]
    near, far = np.percentile(inverse[inverse > 0], [95, 5]) if (inverse > 0).any() else (0, 0)

    buf = io.BytesIO()
    Image.fromarray(colored).save(buf, "PNG", compress_level=1)
    headers = {
        "X-Size": f"{w}x{h}",
        "X-Infer-Ms": f"{ms:.0f}",
        "X-Focal-Px": f"{focal:.0f}",
        "X-Focal-Source": focal_source,
        "X-Depth-Range": f"{1 / near:.2f}-{1 / far:.2f}" if near and far else "",
    }
    return buf.getvalue(), headers


@app.post("/api/depth")
async def depth(request: Request, max_side: int = 1024):
    data = await request.body()
    if not data:
        raise HTTPException(400, "Send the image as the request body.")
    png, headers = await asyncio.to_thread(depth_photo, data, min(max(max_side, 256), 2048))
    return Response(png, media_type="image/png", headers=headers)
