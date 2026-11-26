# depthkey: Mac virtual camera (Apple silicon)

Runs Depth Pro 2 on the Mac GPU (Core ML), keeps everything nearer than a cut-off distance,
replaces the background and sends the result to the **OBS Virtual Camera**, which you then add in
OBS as a normal camera.

Needs Apple silicon, macOS 15+, OBS 30+ and [uv](https://docs.astral.sh/uv/).
(No Docker here: Docker on macOS can reach neither the GPU nor the camera.)

## One-time setup

```bash
brew install uv
brew install --cask obs
```

1. Open OBS, click **Start Virtual Camera**. If macOS asks, allow the camera extension
   (System Settings › General › Login Items & Extensions › Camera Extensions). Click **Stop Virtual Camera**.
2. Clone this repo, or just copy `depthcam.py`.

## Run

```bash
uv run depthcam.py                       # blurred background
uv run depthcam.py --background color    # green screen
uv run depthcam.py --background image --bg-image office.jpg
uv run depthcam.py --size 854x480        # sharper edges, a bit slower
```

The first run installs the dependencies and downloads the models (~150 MB). macOS asks to let
your terminal use the camera: allow it, then start again.

Wait about a second for the auto cut-off. Keys in the preview window:
`+`/`-` cut-off ±5 cm · `a` auto again · `[`/`]` edge softness · `b` next background · `q` quit.

## In OBS

- **Sources › + › Video Capture Device › Device: OBS Virtual Camera.**
- With `--background color`: right-click the source › **Filters › + Chroma Key** for a transparent background.
- Don't click OBS's own **Start Virtual Camera** while `depthcam.py` runs: there is only one virtual camera.

## Speed (Apple's numbers for S, window 4, M4 Max GPU)

| `--size` | model time |
|---|---|
| 640x360 (default) | 13 ms |
| 854x480 | 26 ms |
| 896x512 | 30 ms |
| 1280x720 | 88 ms |

Slower chips (M1/M2) take longer. The terminal prints fps and model time every 2 s.

## Options

`--camera N` (another camera index) · `--cutoff 1.2` (fixed, in meters) · `--softness 0.12` ·
`--bg-color 00b140` · `--model depthpro2-b` (sharper, slower) · `--no-preview` · `--no-vcam` ·
`--backend torch` (PyTorch fallback, needs `depth_pro_2` installed).

The model weights are licensed for non-commercial research use only.
