#!/usr/bin/env bash
#
# Download the TRELLIS image-to-3D model weights (~4 GB) into the HuggingFace
# cache — the "отдельно скриптом" step.
#
# The Vibe3D AI-3D worker NEVER auto-downloads the model at generation time.
# Run this script ONCE, explicitly, before you start the `trellis` backend.
# It is a thin wrapper around the worker's `fetch-model` subcommand; every
# argument is passed straight through.
#
# Usage:
#   tools/ai3d_worker/download_model.sh [--model ID] [--cache-dir DIR] \
#                                       [--revision REF] [--check]
#
#   (no flags)      download jetx/TRELLIS-image-large into the HF cache
#   --check         report whether the model is already cached WITHOUT
#                   downloading (offline-safe; exit 0 = present, 3 = absent)
#   --model ID      HuggingFace model id (default jetx/TRELLIS-image-large)
#   --cache-dir DIR HuggingFace cache dir (default: standard cache, honoring
#                   $HF_HUB_CACHE / $HF_HOME)
#   --revision REF  pin a commit/tag/branch for reproducibility
#
# Environment: the actual download needs `huggingface_hub` installed, so run
# this inside your AI-generation venv (or set $PYTHON to that interpreter).
# `--check` works even in a bare stdlib-only env (it falls back to a filesystem
# probe of the cache). Works whether or not a venv is active; PYTHONPATH is set
# to this directory so `-m vibe3d_ai3d_worker` resolves without an install.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"

export PYTHONPATH="${SCRIPT_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
exec "$PYTHON" -m vibe3d_ai3d_worker fetch-model "$@"
