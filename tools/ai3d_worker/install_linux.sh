#!/usr/bin/env bash
#
# install_linux.sh — provision the optional AI-generation runtime (TRELLIS
# image-to-3D backend) that the editor's Generate 3D panel drives via
# source/ai3d/worker_manager.d (task 0403). This is the end-user-facing
# "Install" button's implementation: the user never runs `python -m ... serve`
# by hand, and never runs this script by hand either in the common case — the
# editor spawns it and streams its output into the panel.
#
# What this script does:
#   1. Creates a Python venv at <location>/venv.
#   2. Installs a CUDA build of torch into that venv.
#   3. Installs the TRELLIS runtime's own Python dependencies (mesh-only
#      path — deliberately skips the CUDA source-build extensions TRELLIS
#      needs only for its gaussian/radiance-field output formats; the worker
#      requests formats=['mesh'] only, see vibe3d_ai3d_worker/server.py).
#   4. Installs this worker package itself (`pip install -e`) so
#      `python -m vibe3d_ai3d_worker serve` resolves inside the venv.
#   5. References an existing TRELLIS checkout (--trellis-root) or clones
#      microsoft/TRELLIS to <location>/TRELLIS.
#   6. Writes the config handshake file the editor reads:
#        ${XDG_DATA_HOME:-~/.local/share}/vibe3d/ai3d.json
#
# What this script deliberately does NOT do:
#   - Download the ~4 GB TRELLIS model weights. That is a SEPARATE, explicit
#     step (download_model.sh / `fetch-model`) — never bundled into install,
#     never triggered automatically by this script or by the worker itself.
#   - Touch anything outside <location> and the config file above.
#
# Usage:
#   install_linux.sh [--location DIR] [--trellis-root DIR] [--dry-run] [--help]
#
#   --location DIR      Where to install the venv + (if cloned) TRELLIS.
#                        Default: ~/.local/share/vibe3d/ai3d
#   --trellis-root DIR   Use an existing TRELLIS checkout instead of cloning
#                        one. Must already exist; not modified by this script
#                        beyond what its own dependency install touches.
#   --dry-run            Print the full plan (every command this script WOULD
#                        run, and the exact size/location warnings) and exit
#                        0 WITHOUT creating, downloading, or writing anything.
#                        Fully offline-safe — this is the mode the automated
#                        test suite exercises (never the real install).
#   --help               Print usage and exit 0.
#
# Idempotent: re-running with the same --location reuses the existing venv
# (pip install is itself idempotent) and skips re-cloning TRELLIS if
# --trellis-root (or the default clone target) already exists and looks like
# a real checkout.
#
# Env overrides:
#   PYTHON              Python interpreter to build the venv from (default:
#                        python3 — must be >= 3.10, matching TRELLIS/torch's
#                        own floor; the venv itself then owns its own python).
#   TORCH_INDEX_URL      pip --index-url for the torch install (default: the
#                        CUDA 12.8 wheel index — override for a different CUDA
#                        toolkit / CPU-only build).
#   TRELLIS_REPO_URL     git remote to clone when --trellis-root is not given
#                        (default: the upstream microsoft/TRELLIS mirror).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# spconv-cu120 (a mesh-path TRELLIS dep) publishes wheels ONLY for Python
# 3.10-3.11. The system default python3 on recent distros (e.g. Fedora 43 =
# 3.14) is too new -> pip aborts with "No matching distribution found for
# spconv-cu120" ~6-8 GB into the install. Auto-pick a supported interpreter
# unless PYTHON was set explicitly.
if [ -z "${PYTHON:-}" ]; then
    PYTHON=python3
    for _cand in python3.11 python3.10; do
        if command -v "$_cand" >/dev/null 2>&1; then PYTHON="$_cand"; break; fi
    done
fi
# torch 2.4.0 / cu121 — the version TRELLIS's whole CUDA stack (kaolin, xformers,
# spconv) publishes wheels for. cu121 runtime runs fine on any driver whose CUDA
# is >= 12.1 (backward compatible), so newer drivers (e.g. 13.x) are OK.
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu121}"
TORCH_VERSION="${TORCH_VERSION:-2.4.0}"
TORCHVISION_VERSION="${TORCHVISION_VERSION:-0.19.0}"
# xformers build matched to torch 2.4.0 (per TRELLIS setup.sh's own table).
XFORMERS_VERSION="${XFORMERS_VERSION:-0.0.27.post2}"
TRELLIS_REPO_URL="${TRELLIS_REPO_URL:-https://github.com/microsoft/TRELLIS.git}"

# GPU preflight thresholds. REQUIRED_CUDA is derived from the torch wheel index
# (cu128 -> 12.8) so it tracks TORCH_INDEX_URL; MIN_VRAM_MB is the FP16 mesh-only
# TRELLIS floor (~5 GB, +headroom). Both overridable via env; the whole check is
# skippable with --skip-gpu-check / VIBE3D_SKIP_GPU_CHECK=1.
_cutag="$(printf '%s' "$TORCH_INDEX_URL" | grep -oE 'cu[0-9]+' | grep -oE '[0-9]+' | head -1)"
if [ -n "$_cutag" ] && [ "${#_cutag}" -ge 3 ]; then
    REQUIRED_CUDA="${VIBE3D_REQUIRED_CUDA:-${_cutag:0:2}.${_cutag:2}}"
else
    REQUIRED_CUDA="${VIBE3D_REQUIRED_CUDA:-12.8}"
fi
MIN_VRAM_MB="${VIBE3D_MIN_VRAM_MB:-6000}"
SKIP_GPU_CHECK="${VIBE3D_SKIP_GPU_CHECK:-0}"

DEFAULT_LOCATION="${XDG_DATA_HOME:-$HOME/.local/share}/vibe3d/ai3d"
CONFIG_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/vibe3d"
CONFIG_PATH="$CONFIG_DIR/ai3d.json"
DEFAULT_PORT=47831

LOCATION=""
TRELLIS_ROOT_ARG=""
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: install_linux.sh [--location DIR] [--trellis-root DIR] [--dry-run] [--help]

Provisions the optional AI-generation runtime (venv + torch + TRELLIS
runtime deps + this worker package) that the editor's Generate 3D panel
"Install" button drives. Does NOT download the ~4 GB model weights — run
download_model.sh (or `python -m vibe3d_ai3d_worker fetch-model`) separately
for that, once, after this script finishes.

Options:
  --location DIR       Install location (default: ~/.local/share/vibe3d/ai3d,
                        honoring $XDG_DATA_HOME).
  --trellis-root DIR    Use an existing TRELLIS checkout instead of cloning
                        one to <location>/TRELLIS.
  --dry-run             Print the plan and exit 0. Creates, downloads, and
                        writes NOTHING. Fully offline-safe.
  --skip-gpu-check      Proceed even if the NVIDIA GPU / CUDA / VRAM preflight
                        fails (also VIBE3D_SKIP_GPU_CHECK=1).
  --help                Show this message and exit 0.

Env: PYTHON, TORCH_INDEX_URL, TRELLIS_REPO_URL, VIBE3D_REQUIRED_CUDA,
     VIBE3D_MIN_VRAM_MB, VIBE3D_SKIP_GPU_CHECK.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --location)
            [ $# -ge 2 ] || { echo "error: --location requires a value" >&2; exit 2; }
            LOCATION="$2"; shift 2 ;;
        --trellis-root)
            [ $# -ge 2 ] || { echo "error: --trellis-root requires a value" >&2; exit 2; }
            TRELLIS_ROOT_ARG="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        --skip-gpu-check)
            SKIP_GPU_CHECK=1; shift ;;
        --help|-h)
            usage; exit 0 ;;
        *)
            echo "error: unrecognized argument: $1" >&2
            usage >&2
            exit 2 ;;
    esac
done

LOCATION="${LOCATION:-$DEFAULT_LOCATION}"
VENV_DIR="$LOCATION/venv"
VENV_PYTHON="$VENV_DIR/bin/python"

# Refuse an unsupported Python up front (actionable message) rather than a deep
# pip failure many GB in. spconv-cu120 wheels exist only for 3.10-3.11.
PYVER="$("$PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo '?')"
case "$PYVER" in
    3.10|3.11) : ;;
    *)
        PYMSG="$PYTHON is Python $PYVER — unsupported. TRELLIS's spconv-cu120 ships wheels only for Python 3.10-3.11. Install python3.11 (e.g. 'sudo dnf install python3.11') or set PYTHON=python3.11 and re-run."
        if [ "$DRY_RUN" -eq 1 ]; then echo "WARNING: $PYMSG"
        else echo "error: $PYMSG" >&2; exit 3; fi ;;
esac

# A venv left over from a previous run on a DIFFERENT Python (e.g. the too-new
# system default) would be silently reused and fail the same way. Detect the
# mismatch and tell the user to remove it.
if [ "$DRY_RUN" -ne 1 ] && [ -x "$VENV_PYTHON" ]; then
    EXISTING_PYVER="$("$VENV_PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo '?')"
    if [ "$EXISTING_PYVER" != "$PYVER" ]; then
        echo "error: existing venv at $VENV_DIR is Python $EXISTING_PYVER, but this run uses $PYVER." >&2
        echo "       Remove the stale venv and re-run:  rm -rf '$VENV_DIR'" >&2
        exit 3
    fi
fi

if [ -n "$TRELLIS_ROOT_ARG" ]; then
    TRELLIS_ROOT="$TRELLIS_ROOT_ARG"
    TRELLIS_IS_CLONE_TARGET=0
else
    TRELLIS_ROOT="$LOCATION/TRELLIS"
    TRELLIS_IS_CLONE_TARGET=1
fi

# ---------------------------------------------------------------------------
# The plan — printed in both --dry-run and real-run mode, up front, so the
# editor's Install confirmation popup and the streamed log both show exactly
# what is about to happen before any of it happens.
# ---------------------------------------------------------------------------
gpu_fail() {
    if [ "$DRY_RUN" -eq 1 ] || [ "$SKIP_GPU_CHECK" -eq 1 ]; then
        echo "WARNING: $1"
    else
        echo "error: $1" >&2
        echo "       (override with --skip-gpu-check, or VIBE3D_SKIP_GPU_CHECK=1)" >&2
        exit 4
    fi
}

# Preflight: refuse the multi-GB install if there is no usable NVIDIA GPU, the
# driver is too old for the torch CUDA build, or VRAM is below the TRELLIS
# FP16 floor — before any download happens.
preflight_gpu() {
    echo "-- GPU preflight (need NVIDIA + driver CUDA >= $REQUIRED_CUDA + >= $MIN_VRAM_MB MiB VRAM)"
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        gpu_fail "no NVIDIA driver found (nvidia-smi missing). TRELLIS needs an NVIDIA GPU with CUDA."
        return
    fi
    if ! nvidia-smi >/dev/null 2>&1; then
        gpu_fail "nvidia-smi is present but failed to run — NVIDIA driver problem (reboot / reinstall the driver?)."
        return
    fi
    local name cuda vram
    name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
    cuda="$(nvidia-smi 2>/dev/null | grep -oE 'CUDA Version: [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    # largest VRAM across GPUs, in MiB
    vram="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | grep -E '^[0-9]+$' | sort -n | tail -1)"
    echo "   detected: ${name:-unknown GPU}, driver CUDA ${cuda:-?}, ${vram:-?} MiB VRAM"
    if [ -n "$cuda" ]; then
        if [ "$(printf '%s\n%s\n' "$REQUIRED_CUDA" "$cuda" | sort -V | head -1)" != "$REQUIRED_CUDA" ]; then
            gpu_fail "NVIDIA driver supports CUDA $cuda, but torch ($TORCH_INDEX_URL) needs CUDA >= $REQUIRED_CUDA. Update the NVIDIA driver."
        fi
    else
        gpu_fail "could not read the driver's CUDA version from nvidia-smi (need >= $REQUIRED_CUDA)."
    fi
    if [ -n "$vram" ]; then
        if [ "$vram" -lt "$MIN_VRAM_MB" ]; then
            gpu_fail "GPU has ${vram} MiB VRAM, but TRELLIS (FP16, mesh-only) needs ~$MIN_VRAM_MB MiB and will likely OOM."
        fi
    else
        gpu_fail "could not read GPU VRAM from nvidia-smi (need >= $MIN_VRAM_MB MiB)."
    fi
}

print_plan() {
    echo "vibe3d AI-3D runtime install plan"
    echo "=================================="
    echo "  install location:   $LOCATION"
    echo "  venv:                $VENV_DIR"
    echo "  estimated size:      ~6-8 GB (torch + CUDA runtime + TRELLIS deps;"
    echo "                       the ~4 GB model weights are a SEPARATE step,"
    echo "                       see download_model.sh — never fetched here)"
    if [ "$TRELLIS_IS_CLONE_TARGET" -eq 1 ]; then
        echo "  TRELLIS checkout:    will clone $TRELLIS_REPO_URL -> $TRELLIS_ROOT"
    else
        echo "  TRELLIS checkout:    using existing $TRELLIS_ROOT"
    fi
    echo "  torch index:         $TORCH_INDEX_URL"
    echo "  worker package:      pip install -e $SCRIPT_DIR"
    echo "  config written to:   $CONFIG_PATH"
    echo
    echo "Steps:"
    echo "  0. GPU preflight: NVIDIA driver present, driver CUDA >= $REQUIRED_CUDA,"
    echo "     >= $MIN_VRAM_MB MiB VRAM (skip with --skip-gpu-check)"
    echo "  1. mkdir -p '$LOCATION'"
    echo "  2. $PYTHON -m venv '$VENV_DIR'   (skipped if it already exists)"
    echo "  3. '$VENV_PYTHON' -m pip install --upgrade pip setuptools wheel"
    echo "  4. '$VENV_PYTHON' -m pip install torch==$TORCH_VERSION torchvision==$TORCHVISION_VERSION --index-url '$TORCH_INDEX_URL'"
    if [ "$TRELLIS_IS_CLONE_TARGET" -eq 1 ]; then
        echo "  5. git clone --recursive '$TRELLIS_REPO_URL' '$TRELLIS_ROOT'   (skipped if present)"
    else
        echo "  5. (using existing checkout)"
    fi
    echo "     + git submodule update --init --recursive   (flexicubes)"
    echo "  6. TRELLIS setup.sh --basic --spconv (in the venv) for the basic deps"
    echo "     + spconv; then xformers $XFORMERS_VERSION + kaolin pinned to torch"
    echo "     $TORCH_VERSION explicitly (setup.sh's exact-version match skips the"
    echo "     +cuXXX suffix). NOT nvdiffrast/diffoctreerast/mipgaussian (worker"
    echo "     only requests formats=['mesh']). + fast-simplification."
    echo "  7. '$VENV_PYTHON' -m pip install -e '$SCRIPT_DIR'"
    echo "  8. write $CONFIG_PATH"
    echo
    echo "The model weights (jetx/TRELLIS-image-large, ~4 GB) are NOT downloaded"
    echo "by this script. Run download_model.sh (or 'fetch-model') separately,"
    echo "once, after this finishes."
}

print_plan

echo
preflight_gpu

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "--dry-run: no changes made."
    exit 0
fi

echo
echo "Installing..."

mkdir -p "$LOCATION"

if [ -x "$VENV_PYTHON" ]; then
    echo "-- venv already exists at $VENV_DIR, reusing"
else
    echo "-- creating venv at $VENV_DIR"
    "$PYTHON" -m venv "$VENV_DIR"
fi

echo "-- upgrading pip/setuptools/wheel"
"$VENV_PYTHON" -m pip install --upgrade pip setuptools wheel

echo "-- installing torch $TORCH_VERSION / torchvision $TORCHVISION_VERSION (index: $TORCH_INDEX_URL)"
"$VENV_PYTHON" -m pip install "torch==$TORCH_VERSION" "torchvision==$TORCHVISION_VERSION" --index-url "$TORCH_INDEX_URL"

if [ "$TRELLIS_IS_CLONE_TARGET" -eq 1 ]; then
    if [ -d "$TRELLIS_ROOT/.git" ]; then
        echo "-- TRELLIS checkout already present at $TRELLIS_ROOT, reusing"
    else
        echo "-- cloning TRELLIS ($TRELLIS_REPO_URL, --recursive) -> $TRELLIS_ROOT"
        git clone --recursive "$TRELLIS_REPO_URL" "$TRELLIS_ROOT"
    fi
else
    if [ ! -d "$TRELLIS_ROOT" ]; then
        echo "error: --trellis-root '$TRELLIS_ROOT' does not exist" >&2
        exit 1
    fi
    echo "-- using existing TRELLIS checkout at $TRELLIS_ROOT"
fi

# flexicubes (the mesh extractor on the worker's formats=['mesh'] decode path) is
# a git submodule; populate it whether we cloned fresh or reused a checkout.
echo "-- initializing TRELLIS submodules (flexicubes)"
git -C "$TRELLIS_ROOT" submodule update --init --recursive

# Install the TRELLIS runtime deps via TRELLIS' OWN setup.sh, which version-matches
# xformers / spconv / kaolin to the installed torch. A hand-picked list drifts:
# kaolin is required by the flexicubes mesh extractor, and the whole CUDA stack
# only ships wheels for torch 2.4.x. Mesh-only flags: --basic --xformers --spconv
# --kaolin; deliberately NOT --nvdiffrast / --diffoctreerast / --mipgaussian
# (gaussian / radiance-field outputs the worker never requests — it only ever asks
# formats=['mesh'], see server.py TrellisBackend). Run with the venv on PATH so
# setup.sh's bare `pip` / `python` resolve to it.
echo "-- installing TRELLIS basic + spconv deps via setup.sh (--basic --spconv)"
( cd "$TRELLIS_ROOT" && PATH="$VENV_DIR/bin:$PATH" VIRTUAL_ENV="$VENV_DIR" bash setup.sh --basic --spconv )

# setup.sh's --xformers / --kaolin match torch by an EXACT version string and skip
# our "$TORCH_VERSION+cuXXX" (the +cuXXX local-version suffix breaks its `case` and
# prints "Unsupported PyTorch version"), so install them EXPLICITLY here, pinned to
# the torch / cuda we installed above. This is exactly what closed the owner's
# "No module named 'kaolin'" generation failure.
CU_TAG="$(printf '%s' "$TORCH_INDEX_URL" | grep -oE 'cu[0-9]+' | head -1)"
echo "-- installing xformers $XFORMERS_VERSION (index: $TORCH_INDEX_URL)"
"$VENV_PYTHON" -m pip install "xformers==$XFORMERS_VERSION" --index-url "$TORCH_INDEX_URL"
echo "-- installing kaolin (torch-${TORCH_VERSION}_${CU_TAG} wheel index)"
"$VENV_PYTHON" -m pip install kaolin \
    -f "https://nvidia-kaolin.s3.us-east-2.amazonaws.com/torch-${TORCH_VERSION}_${CU_TAG}.html"

# fast_simplification: the worker's quadric decimate (server.py TrellisBackend),
# not part of TRELLIS setup.sh's basic set.
echo "-- installing fast-simplification (worker mesh decimate)"
"$VENV_PYTHON" -m pip install fast-simplification

echo "-- installing vibe3d_ai3d_worker (editable) from $SCRIPT_DIR"
"$VENV_PYTHON" -m pip install -e "$SCRIPT_DIR"

echo "-- writing config: $CONFIG_PATH"
mkdir -p "$CONFIG_DIR"
TRELLIS_ROOT_ABS="$(cd "$TRELLIS_ROOT" && pwd)"
VENV_PYTHON_ABS="$(cd "$(dirname "$VENV_PYTHON")" && pwd)/$(basename "$VENV_PYTHON")"

# Hand-built JSON (no jq dependency): every value is a controlled path/string
# with no embedded quotes, so this simple escaping (backslash + double-quote)
# is sufficient and keeps this script dependency-free.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

cat > "$CONFIG_PATH" <<EOF
{
  "version": 1,
  "installed": true,
  "python": "$(json_escape "$VENV_PYTHON_ABS")",
  "backend": "trellis",
  "trellisRoot": "$(json_escape "$TRELLIS_ROOT_ABS")",
  "modelCacheDir": null,
  "port": $DEFAULT_PORT
}
EOF

echo
echo "Install complete."
echo "  venv:    $VENV_PYTHON_ABS"
echo "  TRELLIS: $TRELLIS_ROOT_ABS"
echo "  config:  $CONFIG_PATH"
echo
echo "Next step (separate, explicit, NOT run by this script):"
echo "  tools/ai3d_worker/download_model.sh"
echo "to fetch the ~4 GB model weights before starting the worker."
