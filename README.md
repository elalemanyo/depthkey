# depthkey

Webcam background removal by **depth** instead of a green screen or person segmentation:
everything nearer than a cut-off distance stays, the rest is blurred, replaced or keyed out.
Depth comes from Apple's [Depth Pro 2](https://huggingface.co/apple/DepthPro2), which estimates
metric depth per pixel and stays steady from frame to frame.

Because it cuts by distance, it keeps whatever is near you (the mug you hold up, your chair, a
second person), not just a detected person.

Two ways to run it:

| | Where the model runs | Speed | For |
|---|---|---|---|
| [**Mac virtual camera**](mac/) | Your Mac's GPU (Core ML) | real time | OBS, Zoom, any app that takes a camera |
| [**Browser demo**](#browser-demo) | A Docker container (CPU) | ~3–5 fps | Trying it out |

## Mac virtual camera

Apple silicon, macOS 15+, OBS 30+. Sends the result to the OBS Virtual Camera.

```bash
uv run mac/depthcam.py
```

Setup and options: [`mac/README.md`](mac/README.md).

## Browser demo

The browser captures the webcam and streams frames over a WebSocket to a container running
Depth Pro 2; the page composites the result.

```bash
docker compose up -d --build
open http://localhost:8000
```

Browsers allow the camera only on `https` or `localhost`. To serve it from another machine,
put it behind an HTTPS proxy (`compose.devbox.yml` is an example with Caddy).

- **Auto** sets the cut-off to the depth in the middle of the frame + 40 cm.
- **Model input width**: 256 ≈ 5 fps, 320 ≈ 3 fps on an 8-core CPU.
- **Show the processed frame** keeps video and mask in sync; off gives smooth video with a lagging mask.

Settings in `compose.yml`:

| Variable | Default | |
|---|---|---|
| `MODEL` | `depthpro2-s` | `depthpro2-b/l/h` are sharper but far too slow on a CPU; rebuild with `--build-arg MODEL=…` |
| `WINDOW` | `2` | Frames the model attends to; higher is steadier and slower |
| `TORCH_THREADS` | `8` | |

## License

This repository contains only glue code; it is not affiliated with Apple. The Depth Pro 2 code and
weights are downloaded at build or run time and are under Apple's licenses: the
[weights](https://github.com/apple-aiml-research/ml-depth-pro-2/blob/main/LICENSE_MODEL) are for
non-commercial research use only.
