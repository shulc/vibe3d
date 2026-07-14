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
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}"
TRELLIS_REPO_URL="${TRELLIS_REPO_URL:-https://github.com/microsoft/TRELLIS.git}"

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
  --help                Show this message and exit 0.
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
    echo "  1. mkdir -p '$LOCATION'"
    echo "  2. $PYTHON -m venv '$VENV_DIR'   (skipped if it already exists)"
    echo "  3. '$VENV_PYTHON' -m pip install --upgrade pip setuptools wheel"
    echo "  4. '$VENV_PYTHON' -m pip install torch torchvision --index-url '$TORCH_INDEX_URL'"
    if [ "$TRELLIS_IS_CLONE_TARGET" -eq 1 ]; then
        echo "  5. git clone '$TRELLIS_REPO_URL' '$TRELLIS_ROOT'   (skipped if it already exists)"
    else
        echo "  5. (skipped: --trellis-root points at an existing checkout)"
    fi
    echo "  6. '$VENV_PYTHON' -m pip install <TRELLIS mesh-only runtime deps>"
    echo "     (xformers, spconv, easydict, plyfile, trimesh, huggingface_hub,"
    echo "      pillow, opencv-python-headless, rembg, onnxruntime, tqdm, scipy,"
    echo "      utils3d; deliberately NOT nvdiffrast / diffoctreerast /"
    echo "      diff-gaussian-rasterization — the worker only ever requests"
    echo "      formats=['mesh'], see vibe3d_ai3d_worker/server.py)"
    echo "  7. '$VENV_PYTHON' -m pip install -e '$SCRIPT_DIR'"
    echo "  8. write $CONFIG_PATH"
    echo
    echo "The model weights (jetx/TRELLIS-image-large, ~4 GB) are NOT downloaded"
    echo "by this script. Run download_model.sh (or 'fetch-model') separately,"
    echo "once, after this finishes."
}

print_plan

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

echo "-- installing torch (index: $TORCH_INDEX_URL)"
"$VENV_PYTHON" -m pip install torch torchvision --index-url "$TORCH_INDEX_URL"

if [ "$TRELLIS_IS_CLONE_TARGET" -eq 1 ]; then
    if [ -d "$TRELLIS_ROOT/.git" ]; then
        echo "-- TRELLIS checkout already present at $TRELLIS_ROOT, reusing"
    else
        echo "-- cloning TRELLIS ($TRELLIS_REPO_URL) -> $TRELLIS_ROOT"
        git clone "$TRELLIS_REPO_URL" "$TRELLIS_ROOT"
    fi
else
    if [ ! -d "$TRELLIS_ROOT" ]; then
        echo "error: --trellis-root '$TRELLIS_ROOT' does not exist" >&2
        exit 1
    fi
    echo "-- using existing TRELLIS checkout at $TRELLIS_ROOT"
fi

# Mesh-only runtime dependency set (task 0403). Deliberately excludes the
# CUDA source-build extensions TRELLIS' setup.sh normally builds for its
# gaussian-splat / radiance-field output formats (nvdiffrast,
# diff-gaussian-rasterization, diffoctreerast) — the worker only ever
# requests formats=['mesh'] (server.py TrellisBackend.generate), so none of
# those are needed. Pin/adjust versions for your CUDA toolkit as needed;
# these are unpinned to stay portable across CUDA 12.x builds.
echo "-- installing TRELLIS mesh-only runtime dependencies"
"$VENV_PYTHON" -m pip install \
    "xformers" \
    "spconv-cu120" \
    "easydict" \
    "plyfile" \
    "trimesh" \
    "huggingface_hub" \
    "pillow" \
    "opencv-python-headless" \
    "rembg" \
    "onnxruntime" \
    "tqdm" \
    "scipy" \
    "numpy" \
    "fast-simplification" \
    "utils3d @ git+https://github.com/EasternJournalist/utils3d.git"

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
