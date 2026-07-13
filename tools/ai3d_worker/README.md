# Vibe3D AI 3D worker

This directory contains the optional image-to-mesh worker for the AI 3D MVP.
The first implementation is a deterministic fake backend that exercises the
HTTP protocol without loading model code, CUDA, Torch, or TripoSR weights.

Run the fake worker locally:

```sh
python3 -m vibe3d_ai3d_worker serve --host 127.0.0.1 --port 47831 --data-dir /tmp/vibe3d-ai3d-worker
```

Run the TripoSR backend on the prepared Fedora dev box:

```sh
cd /tmp/vibe3d-ai3d-worker.FcriPO
PYTHONPATH=$PWD ~/vibe3d-ai-mvp/TripoSR/.venv/bin/python -m vibe3d_ai3d_worker serve \
  --host 127.0.0.1 \
  --port 47831 \
  --data-dir /tmp/vibe3d-ai3d-worker \
  --backend triposr \
  --triposr-root ~/vibe3d-ai-mvp/TripoSR
```

The first TripoSR job may lazily download `model.ckpt` into the Hugging Face
cache. Warm the worker before UX testing when measuring generation time. The
default `--mc-resolution 120` is intentionally conservative so the generated OBJ
fits the editor MVP validator budget (`<= 25k` faces per part).

Run the TRELLIS backend (Microsoft Structured 3D Latents, MIT-licensed —
markedly cleaner geometry than TripoSR on clean single-object photos):

```sh
cd tools/ai3d_worker
PYTHONPATH=$PWD ~/vibe3d-ai-mvp/TRELLIS/.venv/bin/python -m vibe3d_ai3d_worker serve \
  --host 127.0.0.1 \
  --port 47831 \
  --data-dir /tmp/vibe3d-ai3d-worker \
  --backend trellis \
  --trellis-root ~/vibe3d-ai-mvp/TRELLIS \
  --trellis-precision half        # FP16: peak ~5 GB VRAM, fits an 8 GB GPU
```

TRELLIS decodes `formats=['mesh']` only, so the worker needs just the prebuilt
wheels + the pure-PyTorch flexicubes extractor — none of the CUDA source-build
extensions (nvdiffrast / diff_gaussian_rasterization / diffoctreerast). The raw
mesh is ~600k faces; the worker Z-up→Y-up rotates it and quadric-decimates down
to `--trellis-max-faces` (default 50000) before export. The first job lazily
downloads `jetx/TRELLIS-image-large` (~4 GB) into the Hugging Face cache and
FP16-loads it (~30–60 s warm); inference itself is ~10 s at the default 12/12
sampler steps. Raise `--trellis-ss-steps` / `--trellis-slat-steps` for finer
detail at the cost of speed. `--trellis-precision full` needs ~16 GB VRAM.

Scripted editor MVP path, with the editor already running in its normal test
HTTP mode:

```sh
curl -sS http://127.0.0.1:8080/api/command \
  --data 'ai3d.generate image:"/absolute/path/input.png" workerUrl:"http://127.0.0.1:47831" name:"AI 3D test"'
```

The command is explicit-only: editor startup does not contact the worker. The
current implementation is a synchronous vertical slice for MVP validation; the
production UI/controller thread will replace it.

Run contract tests:

```sh
cd tools/ai3d_worker
python3 -m unittest discover -s tests
```

On the Fedora dev box, use the documented Python 3.12 environment from
`doc/ai_3d_generation_mvp_setup.md`, not the system Python:

```sh
cd tools/ai3d_worker
PYTHONPATH=$PWD ~/vibe3d-ai-mvp/TripoSR/.venv/bin/python -m unittest discover -s tests
```
