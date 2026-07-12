# Vibe3D AI 3D worker

This directory contains the optional image-to-mesh worker for the AI 3D MVP.
The first implementation is a deterministic fake backend that exercises the
HTTP protocol without loading model code, CUDA, Torch, or TripoSR weights.

Run the fake worker locally:

```sh
python3 -m vibe3d_ai3d_worker serve --host 127.0.0.1 --port 47831 --data-dir /tmp/vibe3d-ai3d-worker
```

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
