#!/usr/bin/env bash
#
# Linux with-render release bundler. Produces a self-contained zip
# that runs without LD_LIBRARY_PATH tweaks or sibling working trees
# on the target machine.
#
# Output layout:
#   vibe3d-linux-render.zip
#     vibe3d                     — the executable
#     config/                    — tool presets + button sets
#     rpr/
#       libNorthstar64.so        — RPR plugin
#       libRadeonProRender64.so  — RPR core dlopen target
#       libTahoe64.so            — legacy plugin (loaded conditionally)
#       libRprLoadStore64.so     — scene I/O
#       libProRenderGLTF.so      — glTF I/O
#       hipbin/                  — precompiled HIP kernels (AMD GPU)
#     lib/
#       libOpenImageIO.so* / libOpenColorIO.so* / libembree4.so*
#       libOpenImageDenoise.so* / libOpenEXR.so* / libOpenEXRCore.so*
#       libIex.so* / libIlmThread.so* / libImath.so*
#       libosdCPU.so* / libsycl.so* / libtbb.so*
#
# Resolves dep paths via `dub describe --config=with-render` so the
# script works for both dub-cache and add-local'd render packages.
#
# Usage:
#   ./tools/release/bundle_linux.sh [--no-build] [--output <path>]
#
# Exits non-zero on the first failure; relies on `set -e`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="${REPO_ROOT}/vibe3d-linux-render.zip"
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
    # Compiler defaults to ldc2 (optimized release); override with DC=dmd etc.
    DC="${DC:-ldc2}"
    echo "[bundle] dub build --config=with-render --build=release --compiler=$DC"
    dub build --config=with-render --build=release --compiler="$DC"
else
    echo "[bundle] --no-build: reusing existing ./vibe3d"
fi

if [[ ! -x ./vibe3d ]]; then
    echo "[bundle] ./vibe3d not found" >&2
    exit 1
fi

STAGE="$(mktemp -d)/vibe3d-linux-render"
STAGE_PARENT="$(dirname "$STAGE")"
mkdir -p "$STAGE/rpr" "$STAGE/lib"
cleanup() { rm -rf "$STAGE_PARENT"; }
trap cleanup EXIT

echo "[bundle] resolving dep paths via dub describe"
DESCRIBE_JSON="$(dub describe --config=with-render 2>/dev/null \
    | sed -n '/^{/,$p')"        # strip dub's leading warning lines
D_CYCLES_PATH="$(echo "$DESCRIBE_JSON" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(p['path'] for p in d['packages'] if p['name']=='d-cycles'))")"
BINDBC_RPR_PATH="$(echo "$DESCRIBE_JSON" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(p['path'] for p in d['packages'] if p['name']=='bindbc-rpr'))")"

CYCLES_LIB_BASE="${D_CYCLES_PATH%/}/extern/blender/lib/linux_x64"
RPR_BIN_BASE="${BINDBC_RPR_PATH%/}/extern/RadeonProRenderSDK/RadeonProRender/binUbuntu20"
RPR_HIPBIN="${BINDBC_RPR_PATH%/}/extern/RadeonProRenderSDK/hipbin"

echo "[bundle]   d-cycles base    : $CYCLES_LIB_BASE"
echo "[bundle]   bindbc-rpr base  : $RPR_BIN_BASE"
echo "[bundle]   hipbin           : $RPR_HIPBIN"

# --- RPR runtime ------------------------------------------------------------
echo "[bundle] copying RPR runtime"
if [[ ! -d "$RPR_BIN_BASE" ]]; then
    echo "[bundle] $RPR_BIN_BASE not present — D-RadeonProRender submodule missing?" >&2
    exit 1
fi
# Everything that ships with the SDK except the headless tools we don't ship.
for f in libNorthstar64.so libRadeonProRender64.so libTahoe64.so \
         libRprLoadStore64.so libProRenderGLTF.so; do
    src="$RPR_BIN_BASE/$f"
    if [[ -f "$src" ]]; then
        cp -L "$src" "$STAGE/rpr/$f"
    else
        echo "[bundle]   missing optional: $f"
    fi
done
if [[ -d "$RPR_HIPBIN" ]]; then
    cp -r "$RPR_HIPBIN" "$STAGE/rpr/hipbin"
fi

# --- Cycles runtime ---------------------------------------------------------
echo "[bundle] copying Cycles runtime"
# The exact set of .so files vibe3d's binary depends on. Listed
# explicitly (vs grep'ing readelf) so missing libs fail loud rather
# than yield a half-bundled zip. Globs cover versioned soname symlinks.
declare -A CYCLES_DEPS=(
    [openimageio]="libOpenImageIO.so* libOpenImageIO_Util.so*"
    [opencolorio]="libOpenColorIO.so*"
    [embree]="libembree4.so*"
    [openimagedenoise]="libOpenImageDenoise.so*"
    [openexr]="libOpenEXR.so* libOpenEXRCore.so* libIex.so* libIlmThread.so*"
    [imath]="libImath.so*"
    [opensubdiv]="libosdCPU.so*"
    # dpcpp: libsycl + its private Unified Runtime loader + adapter
    # plugins. libur_loader pulls libur_adapter_*; libsycl dlopens
    # libur_loader by SONAME, so it has to sit next to libsycl in lib/.
    [dpcpp]="libsycl.so* libur_loader.so* libur_adapter_*.so*"
    [tbb]="libtbb.so*"
)
for subdir in "${!CYCLES_DEPS[@]}"; do
    libdir="$CYCLES_LIB_BASE/$subdir/lib"
    if [[ ! -d "$libdir" ]]; then
        echo "[bundle] missing $libdir" >&2
        exit 1
    fi
    for pattern in ${CYCLES_DEPS[$subdir]}; do
        # shellcheck disable=SC2206
        matches=( $libdir/$pattern )
        if [[ ! -e "${matches[0]}" ]]; then
            echo "[bundle] no matches for $libdir/$pattern" >&2
            exit 1
        fi
        for m in "${matches[@]}"; do
            cp -P "$m" "$STAGE/lib/"     # preserve symlinks; the SONAME
                                          # entry usually points at one of them.
        done
    done
done

# --- Executable + config ---------------------------------------------------
# Copy these BEFORE the ldd closure loop so ldd can probe the staged
# binary with the staged lib/ in LD_LIBRARY_PATH.
cp -P ./vibe3d "$STAGE/vibe3d"
if [[ -d config ]]; then
    cp -r config "$STAGE/config"
fi
[[ -f LICENSE ]]                 && cp LICENSE                 "$STAGE/LICENSE"
[[ -f THIRD_PARTY_LICENSES.md ]] && cp THIRD_PARTY_LICENSES.md "$STAGE/THIRD_PARTY_LICENSES.md"

# Iterate ldd until the closure is complete — covers any transitive
# dep introduced by a Cycles lib that isn't already explicitly listed
# above. Each round, ldd reports `not found` symbols; we search the
# Cycles lib bundle for matching SONAMEs and copy them in.
echo "[bundle] closing transitive ldd dependencies"
for round in 1 2 3 4 5; do
    missing=()
    while IFS= read -r line; do
        # ldd's "name => not found" line.
        soname="${line%% *}"
        [[ -z "$soname" ]] && continue
        missing+=("$soname")
    done < <(LD_LIBRARY_PATH="$STAGE/lib:$STAGE/rpr" ldd "$STAGE/vibe3d" 2>/dev/null \
              | grep "not found" | awk '{print $1}')
    # also probe bundled libs themselves
    for lib in "$STAGE"/lib/*.so*; do
        while IFS= read -r line; do
            soname="${line%% *}"
            [[ -z "$soname" ]] && continue
            missing+=("$soname")
        done < <(LD_LIBRARY_PATH="$STAGE/lib:$STAGE/rpr" ldd "$lib" 2>/dev/null \
                  | grep "not found" | awk '{print $1}')
    done
    # dedup
    if ((${#missing[@]} == 0)); then break; fi
    missing=( $(printf "%s\n" "${missing[@]}" | sort -u) )
    echo "[bundle]   round $round: ${#missing[@]} missing"
    for soname in "${missing[@]}"; do
        found="$(find "$CYCLES_LIB_BASE" -maxdepth 4 -name "$soname" 2>/dev/null | head -1)"
        if [[ -z "$found" ]]; then
            # Also look in dpcpp/lib for un-aliased filenames (libur_*).
            found="$(find "$CYCLES_LIB_BASE/dpcpp/lib" -name "$soname" 2>/dev/null | head -1)"
        fi
        if [[ -z "$found" ]]; then
            echo "[bundle]   FAIL: can't locate $soname under $CYCLES_LIB_BASE" >&2
            exit 1
        fi
        cp -P "$found" "$STAGE/lib/$soname"
        # Also pull the alias symlinks pointing at this SONAME — keeps
        # dlopen("libur_loader.so") (no version) working too.
        base="${soname%.so.*}.so"
        for alias_ in "$(dirname "$found")"/${base}*; do
            [[ -e "$alias_" ]] || continue
            cp -P "$alias_" "$STAGE/lib/"
        done
    done
done

# --- Quick relocate smoke ---------------------------------------------------
# Verify the staged tree has no missing libs BEFORE shipping. ldd against
# the staged binary using only the staged lib/ + rpr/ paths catches a
# bundle that's missing a transitive .so.
echo "[bundle] verifying relocatable staging"
MISSING=$(LD_LIBRARY_PATH="$STAGE/lib:$STAGE/rpr" ldd "$STAGE/vibe3d" 2>/dev/null \
            | grep "not found" || true)
if [[ -n "$MISSING" ]]; then
    echo "[bundle] FAIL: staged binary still has missing libs:" >&2
    echo "$MISSING" >&2
    exit 1
fi

# --- Zip --------------------------------------------------------------------
echo "[bundle] zipping → $OUTPUT"
(cd "$(dirname "$STAGE")" && zip -r "$OUTPUT" "$(basename "$STAGE")" >/dev/null)

SZ=$(du -sh "$OUTPUT" | awk '{print $1}')
echo "[bundle] done: $OUTPUT ($SZ)"
