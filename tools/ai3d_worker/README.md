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
to `--trellis-max-faces` (default 50000) before export. FP16-loading the model
takes ~30–60 s warm; inference itself is ~10 s at the default 12/12 sampler
steps. Raise `--trellis-ss-steps` / `--trellis-slat-steps` for finer detail at
the cost of speed. `--trellis-precision full` needs ~16 GB VRAM.

**You must download the model first** (see below). The TRELLIS backend **never
auto-downloads** — it loads strictly from the local HuggingFace cache. If the
weights are absent, `serve` prints a loud startup warning naming the download
command (but still boots so `/v1/health` works), and any generation request
returns a clean `model_missing` error instead of a silent ~4 GB pull.

## Download the model — separate script, never automatic

The `jetx/TRELLIS-image-large` weights (~4 GB) are **user-downloaded, not
distributed with Vibe3D, and never fetched automatically at generation time**.
Pull them explicitly, once, as a **separate script step** — this replaces the
old silent ~4 GB pull that used to happen inside the first `serve` job:

```sh
# Check whether the model is already cached (offline; no download, no network).
# Exit 0 = present, exit 3 = absent.
tools/ai3d_worker/download_model.sh --check

# Download it explicitly, with progress + a size/hash sanity report on finish.
# Needs the AI-generation runtime (huggingface_hub) installed.
tools/ai3d_worker/download_model.sh
```

`download_model.sh` is a thin `set -euo pipefail` wrapper that forwards every
argument to `python -m vibe3d_ai3d_worker fetch-model` (it sets `PYTHONPATH` to
its own directory, so it works from any cwd, venv-active or not — the actual
download needs `huggingface_hub`, so run it inside your AI-generation venv or
set `$PYTHON` to that interpreter). The equivalent direct form is:

```sh
python3 -m vibe3d_ai3d_worker fetch-model [--check]
```

Flags (identical on the script and the subcommand): `--model` (default
`jetx/TRELLIS-image-large`), `--cache-dir` (HuggingFace cache path; defaults to
the standard cache, honoring `$HF_HUB_CACHE` / `$HF_HOME`), `--revision` (pin a
commit/tag/branch for reproducibility), and `--check` (report cached-or-not
without downloading). `fetch-model` imports `huggingface_hub` lazily: `--check`
works in the base, stdlib-only worker env (it falls back to a filesystem probe
of the cache), while the actual download exits with a clear "install the
AI-generation runtime first" message if `huggingface_hub` is not installed. The
equivalent manual fallback is `huggingface-cli download
jetx/TRELLIS-image-large`. **Weights are never bundled.**

### What you see if you skip the download

Starting `serve --backend trellis` without the model cached prints:

```
WARNING: TRELLIS model 'jetx/TRELLIS-image-large' is not in the local cache (…)
and auto-download is disabled. Download it first, once, with
`tools/ai3d_worker/download_model.sh` (or `python -m vibe3d_ai3d_worker
fetch-model`), then start the worker.
         Starting anyway (health checks OK); generation requests will fail
until the model is downloaded.
```

A generation request against a missing model then fails fast with a
`model_missing` job error carrying that same actionable message — no network
fetch, no 4 GB surprise, no opaque crash.

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
