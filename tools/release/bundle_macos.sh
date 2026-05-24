#!/usr/bin/env bash
#
# macOS with-render release bundler. Mirrors bundle_linux.sh but uses
# the .dylib extension, the macOS Blender lib bundle (lib/macos_arm64/),
# and `otool -L` for transitive-dep probing instead of ldd. The Cycles
# + RPR rpaths in vibe3d's binary are already @executable_path-relative
# (D-Cycles da80823, D-RadeonProRender f1c1fab) so the staged tree is
# directly relocatable.
#
# UNTESTED locally — vibe3d's primary dev box is Linux. CI is the first
# real verification.
#
# Usage:
#   ./tools/release/bundle_macos.sh [--no-build] [--output <path>]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="${REPO_ROOT}/vibe3d-macos-render.zip"
BUILD=true

while (($#)); do
    case "$1" in
        --no-build) BUILD=false; shift ;;
        --output)   OUTPUT="$2"; shift 2 ;;
        *) echo "[bundle] unknown arg: $1" >&2; exit 1 ;;
    esac
done

cd "$REPO_ROOT"

if [[ "$BUILD" == true ]]; then
    dub build --config=with-render --build=release
fi
if [[ ! -x ./vibe3d ]]; then
    echo "[bundle] ./vibe3d not found" >&2
    exit 1
fi

STAGE="$(mktemp -d)/vibe3d-macos-render"
STAGE_PARENT="$(dirname "$STAGE")"
mkdir -p "$STAGE/rpr" "$STAGE/lib"
cleanup() { rm -rf "$STAGE_PARENT"; }
trap cleanup EXIT

DESCRIBE_JSON="$(dub describe --config=with-render 2>/dev/null | sed -n '/^{/,$p')"
D_CYCLES_PATH="$(echo "$DESCRIBE_JSON" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(p['path'] for p in d['packages'] if p['name']=='d-cycles'))")"
BINDBC_RPR_PATH="$(echo "$DESCRIBE_JSON" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(p['path'] for p in d['packages'] if p['name']=='bindbc-rpr'))")"

CYCLES_LIB_BASE="${D_CYCLES_PATH%/}/extern/blender/lib/macos_arm64"
RPR_BIN_BASE="${BINDBC_RPR_PATH%/}/extern/RadeonProRenderSDK/RadeonProRender/binMacOS"
RPR_HIPBIN="${BINDBC_RPR_PATH%/}/extern/RadeonProRenderSDK/hipbin"

# --- RPR runtime ----------------------------------------------------------
echo "[bundle] copying RPR runtime from $RPR_BIN_BASE"
for f in libNorthstar64.dylib libRadeonProRender64.dylib libTahoe64.dylib \
         libRprLoadStore64.dylib libProRenderGLTF.dylib; do
    [[ -f "$RPR_BIN_BASE/$f" ]] && cp -L "$RPR_BIN_BASE/$f" "$STAGE/rpr/$f"
done
[[ -d "$RPR_HIPBIN" ]] && cp -R "$RPR_HIPBIN" "$STAGE/rpr/hipbin"

# --- Cycles runtime -------------------------------------------------------
echo "[bundle] copying Cycles runtime from $CYCLES_LIB_BASE"
declare -a CYCLES_SUBDIRS=( openimageio opencolorio embree openimagedenoise
                            openexr imath opensubdiv tbb )
for subdir in "${CYCLES_SUBDIRS[@]}"; do
    libdir="$CYCLES_LIB_BASE/$subdir/lib"
    if [[ ! -d "$libdir" ]]; then
        echo "[bundle]   skip missing $libdir"
        continue
    fi
    for f in "$libdir"/*.dylib*; do
        [[ -e "$f" ]] || continue
        cp -P "$f" "$STAGE/lib/"
    done
done

cp -P ./vibe3d "$STAGE/vibe3d"
[[ -d config ]] && cp -R config "$STAGE/config"
[[ -f LICENSE ]] && cp LICENSE "$STAGE/LICENSE"
[[ -f THIRD_PARTY_LICENSES.md ]] && cp THIRD_PARTY_LICENSES.md "$STAGE/THIRD_PARTY_LICENSES.md"

# --- Verify ---------------------------------------------------------------
# otool -L lists every dylib the binary references. After our rpath
# rewrites, references should be either @rpath-prefixed or system libs;
# none should point at an absolute path under D-Cycles' cache.
echo "[bundle] verifying staged binary"
if otool -L "$STAGE/vibe3d" 2>/dev/null \
   | grep -E "/(D-Cycles|D-RadeonProRender|\.dub/packages)/" >/dev/null; then
    echo "[bundle] FAIL: staged binary still references dev-tree paths:" >&2
    otool -L "$STAGE/vibe3d" \
      | grep -E "/(D-Cycles|D-RadeonProRender|\.dub/packages)/" >&2
    exit 1
fi

# --- Zip ------------------------------------------------------------------
echo "[bundle] zipping → $OUTPUT"
(cd "$STAGE_PARENT" && zip -r "$OUTPUT" "$(basename "$STAGE")" >/dev/null)
SZ=$(du -sh "$OUTPUT" | awk '{print $1}')
echo "[bundle] done: $OUTPUT ($SZ)"
