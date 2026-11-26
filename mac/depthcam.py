# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#   "coremltools==9.0",
#   "huggingface-hub",
#   "numpy",
#   "opencv-python",
#   "pyvirtualcam>=0.14",
# ]
# ///
"""Depth Pro 2 virtual camera for OBS on Apple silicon.

Reads the webcam, runs Depth Pro 2 (Core ML, on the GPU), keeps everything nearer than the
cut-off distance, replaces the rest, and sends the result to the OBS Virtual Camera.

    uv run depthcam.py                      # blur the background
    uv run depthcam.py --background color   # green screen, for a chroma key
    uv run depthcam.py --background image --bg-image beach.jpg

Preview window keys: + / -  cut-off ±5 cm    a  auto cut-off    [ / ]  edge softness
                     b  next background      q  quit
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import cv2
import numpy as np

SIZES = ["640x360", "854x480", "896x512", "1138x640", "1280x720"]
BACKGROUNDS = ["blur", "color", "image", "depth"]


def to_frame_input(rgb: np.ndarray) -> np.ndarray:
    """RGB uint8 (H, W, 3) to the packages' input: float16 (1, 3, H, W) in [0, 1]."""
    return np.ascontiguousarray((rgb.astype(np.float16) / 255).transpose(2, 0, 1)[None])


class CoreMLDepth:
    """Depth Pro 2 Core ML package, unbuffered with a window of 4, plus the field-of-view model."""

    FOV_SAMPLES = 16

    def __init__(self, size: tuple[int, int], model: str):
        import coremltools as ct
        from huggingface_hub import snapshot_download

        self.w, self.h = size
        package, fov = f"{model}_w4.mlpackage", "depthpro2-fov_512x896.mlpackage"
        print("Fetching the Core ML packages (once, ~150 MB)...")
        root = Path(
            snapshot_download("apple/DepthPro2-coreml", allow_patterns=[f"{package}/*", f"{fov}/*"])
        )
        print(f"Compiling {package} at {self.w}x{self.h} for the GPU (a few seconds)...")
        units = ct.ComputeUnit.CPU_AND_GPU
        self.model = ct.models.MLModel(
            str(root / package), compute_units=units, function_name=f"res_{self.w}x{self.h}"
        )
        self.state = self.model.make_state()
        self.fov = ct.models.MLModel(str(root / fov), compute_units=units)
        self.vertical_fovs: list[float] = []

    def focal_px(self) -> float:
        """Focal length in pixels of the model's frame, from the median vertical field of view."""
        v = sorted(self.vertical_fovs)[(len(self.vertical_fovs) - 1) // 2]
        return 0.5 * self.h / np.tan(np.radians(v) / 2)

    def depth(self, rgb: np.ndarray) -> np.ndarray:
        """Depth in meters (h, w) for a 16:9 RGB frame; inf where infinitely far."""
        if len(self.vertical_fovs) < self.FOV_SAMPLES:  # like the Mac demo: median of the first 16
            small = cv2.resize(rgb, (896, 512), interpolation=cv2.INTER_AREA)
            fov = self.fov.predict({"frame": to_frame_input(small)})["fov"].reshape(-1)
            self.vertical_fovs.append(float(fov[1]))
            if len(self.vertical_fovs) == self.FOV_SAMPLES:
                print(f"Focal length: {self.focal_px():.0f} px at {self.w}x{self.h}")
        x = cv2.resize(rgb, (self.w, self.h), interpolation=cv2.INTER_AREA)
        out = self.model.predict({"frame": to_frame_input(x)}, state=self.state)
        inverse = np.asarray(out["inverse_depth"], dtype=np.float32).reshape(self.h, self.w)
        with np.errstate(divide="ignore", invalid="ignore"):
            return np.where(inverse > 0, self.focal_px() / (self.w * inverse), np.inf)


class TorchDepth:
    """The same model through PyTorch (CPU or MPS): a fallback, and for testing off a Mac."""

    def __init__(self, size: tuple[int, int], model: str):
        from depth_pro_2 import create_model_and_transforms

        self.w, self.h = size
        self.model, self.transform = create_model_and_transforms(model)
        self.stream = self.model.stream(window=4, mode="unbuffered")

    def depth(self, rgb: np.ndarray) -> np.ndarray:
        x = cv2.resize(rgb, (self.w, self.h), interpolation=cv2.INTER_AREA)
        prediction = self.stream.step(self.transform(x))[-1]
        return prediction["depth"].float().cpu().numpy()


def open_camera(source: str, width: int, height: int) -> cv2.VideoCapture:
    if source.isdigit():
        backend = cv2.CAP_AVFOUNDATION if hasattr(cv2, "CAP_AVFOUNDATION") else cv2.CAP_ANY
        cap = cv2.VideoCapture(int(source), backend)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        cap.set(cv2.CAP_PROP_FPS, 30)
    else:  # a video file, for testing
        cap = cv2.VideoCapture(source)
    if not cap.isOpened():
        raise SystemExit(
            f"Cannot open camera {source!r}. On macOS, allow your terminal to use the camera in "
            "System Settings > Privacy & Security > Camera, then try again."
        )
    return cap


def crop_16x9(width: int, height: int) -> tuple[int, int, int, int]:
    """The centered 16:9 box (x, y, w, h) of a frame; the models take 16:9 frames."""
    w, h = min(width, height * 16 // 9), min(height, width * 9 // 16)
    w, h = w - w % 2, h - h % 2
    return (width - w) // 2, (height - h) // 2, w, h


def auto_cutoff(depth: np.ndarray) -> float:
    """The depth in the middle of the frame, where you sit, plus 40 cm."""
    h, w = depth.shape
    center = depth[int(h * 0.3) : int(h * 0.7), int(w * 0.35) : int(w * 0.65)]
    center = center[np.isfinite(center)]
    return float(np.median(center)) + 0.4 if center.size else 1.5


def colorize(depth: np.ndarray) -> np.ndarray:
    """Depth as a color image, near warm and far cold, on a log scale from 0.3 to 6 m."""
    with np.errstate(divide="ignore"):
        v = 1 - (np.log(np.clip(depth, 0.3, 6)) - np.log(0.3)) / (np.log(6) - np.log(0.3))
    return cv2.applyColorMap((v * 255).astype(np.uint8), cv2.COLORMAP_TURBO)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--camera", default="0", help="camera index (default 0), or a video file")
    parser.add_argument("--size", default="640x360", choices=SIZES,
                        help="model input size: larger is sharper and slower (default 640x360)")
    parser.add_argument("--model", default="depthpro2-s", help="depthpro2-s (default) or depthpro2-b")
    parser.add_argument("--background", default="blur", choices=BACKGROUNDS)
    parser.add_argument("--bg-color", default="00b140", help="hex RGB for --background color")
    parser.add_argument("--bg-image", help="image file for --background image")
    parser.add_argument("--cutoff", type=float, help="cut-off distance in meters (default: auto)")
    parser.add_argument("--softness", type=float, default=0.12, help="edge softness in meters")
    parser.add_argument("--backend", default="coreml", choices=["coreml", "torch"])
    parser.add_argument("--no-vcam", action="store_true", help="preview only, no virtual camera")
    parser.add_argument("--no-preview", action="store_true", help="no preview window")
    parser.add_argument("--max-frames", type=int, help="stop after this many frames (testing)")
    parser.add_argument("--dump", help="save the last output frame to this image (testing)")
    args = parser.parse_args()

    size = tuple(int(v) for v in args.size.split("x"))
    backend = (CoreMLDepth if args.backend == "coreml" else TorchDepth)(size, args.model)

    cap = open_camera(args.camera, 1280, 720)
    ok, frame = cap.read()
    if not ok:
        raise SystemExit("The camera returned no frame.")
    x0, y0, W, H = crop_16x9(frame.shape[1], frame.shape[0])
    print(f"Camera {frame.shape[1]}x{frame.shape[0]}, output {W}x{H}, model {args.size}")

    vcam = None
    if not args.no_vcam:
        import pyvirtualcam

        try:
            vcam = pyvirtualcam.Camera(W, H, fps=30, fmt=pyvirtualcam.PixelFormat.RGB)
        except RuntimeError as e:
            raise SystemExit(
                f"No virtual camera: {e}\nInstall OBS 30+, open it, click Start Virtual Camera, "
                "allow the system extension if macOS asks, click Stop Virtual Camera, then retry."
            )
        print(f"Sending to virtual camera: {vcam.device}")

    r, g, b = (int(args.bg_color[i : i + 2], 16) for i in (0, 2, 4))
    color_bg = np.full((H, W, 3), (b, g, r), np.uint8)
    image_bg = None
    if args.bg_image:
        img = cv2.imread(args.bg_image)
        if img is None:
            raise SystemExit(f"Cannot read {args.bg_image}")
        s = max(W / img.shape[1], H / img.shape[0])
        img = cv2.resize(img, (round(img.shape[1] * s), round(img.shape[0] * s)), interpolation=cv2.INTER_AREA)
        ix, iy = (img.shape[1] - W) // 2, (img.shape[0] - H) // 2
        image_bg = img[iy : iy + H, ix : ix + W]

    mode = args.background
    if mode == "image" and image_bg is None:
        raise SystemExit("--background image needs --bg-image FILE")
    cutoff, softness, auto_pending = args.cutoff, args.softness, args.cutoff is None
    total, frames, t_report, infer_total, out = 0, 0, time.perf_counter(), 0.0, None

    while True:
        ok, frame = cap.read()
        if not ok:
            break
        frame = np.ascontiguousarray(frame[y0 : y0 + H, x0 : x0 + W])
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)

        t = time.perf_counter()
        depth = backend.depth(rgb)
        infer_total += time.perf_counter() - t

        if auto_pending and total >= 4:  # let the first frames settle, then measure
            cutoff, auto_pending = auto_cutoff(depth), False
            print(f"Auto cut-off: {cutoff:.2f} m")
        current = cutoff if cutoff is not None else 1.5

        if mode == "depth":
            out = cv2.resize(colorize(depth), (W, H), interpolation=cv2.INTER_LINEAR)
        else:
            alpha = np.clip((current + softness / 2 - depth) / softness, 0, 1)
            alpha = np.nan_to_num(alpha, nan=0).astype(np.float32)
            alpha = cv2.GaussianBlur(cv2.resize(alpha, (W, H), interpolation=cv2.INTER_LINEAR), (0, 0), 1.5)
            if mode == "blur":
                small = cv2.resize(frame, (W // 8, H // 8), interpolation=cv2.INTER_AREA)
                bg = cv2.resize(cv2.GaussianBlur(small, (0, 0), 3), (W, H), interpolation=cv2.INTER_LINEAR)
            else:
                bg = color_bg if mode == "color" else image_bg
            out = cv2.blendLinear(frame, bg, alpha, 1 - alpha)

        if vcam:
            vcam.send(cv2.cvtColor(out, cv2.COLOR_BGR2RGB))

        total += 1
        frames += 1
        now = time.perf_counter()
        if now - t_report >= 2:
            print(f"{frames / (now - t_report):5.1f} fps, model {1000 * infer_total / frames:4.0f} ms, "
                  f"cut-off {current:.2f} m", flush=True)
            frames, t_report, infer_total = 0, now, 0.0

        if not args.no_preview:
            view = cv2.flip(out, 1)  # mirrored like a selfie; the virtual camera is not mirrored
            cv2.putText(view, f"cut-off {current:.2f} m  soft {softness * 100:.0f} cm  [{mode}]  "
                        "+/- a [ ] b q", (12, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)
            cv2.imshow("Depth Pro 2 camera", view)
            key = cv2.waitKey(1) & 0xFF
            if key in (ord("q"), 27):
                break
            elif key in (ord("+"), ord("=")):
                cutoff = current + 0.05
            elif key == ord("-"):
                cutoff = max(0.2, current - 0.05)
            elif key == ord("a"):
                auto_pending = True
            elif key == ord("]"):
                softness = min(0.6, softness + 0.02)
            elif key == ord("["):
                softness = max(0.01, softness - 0.02)
            elif key == ord("b"):
                choices = [m for m in BACKGROUNDS if m != "image" or image_bg is not None]
                mode = choices[(choices.index(mode) + 1) % len(choices)]

        if args.max_frames and total >= args.max_frames:
            break

    if args.dump and out is not None:
        cv2.imwrite(args.dump, out)
    cap.release()
    if vcam:
        vcam.close()
    if not args.no_preview:
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
