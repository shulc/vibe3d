#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
emsdk_root=${EMSDK:-"$HOME/emsdk"}
ldc=${VIBE3D_LDC:-"$HOME/.local/dlang/ldc2-1.43.0-linux-x86_64/bin/ldc2"}
out_root="$repo_root/.build/web-deps"
source_root="$out_root/src"
build_root="$out_root/build"
lib_root="$out_root/lib"
llvm_readobj="$emsdk_root/upstream/bin/llvm-readobj"

if [[ ! -f "$emsdk_root/emsdk_env.sh" ]]; then
    echo "missing Emscripten environment: $emsdk_root/emsdk_env.sh" >&2
    exit 2
fi
if [[ ! -x "$ldc" ]]; then
    echo "missing LDC 1.43 compiler: $ldc" >&2
    exit 2
fi
if [[ ! -x "$llvm_readobj" ]]; then
    echo "missing llvm-readobj from Emscripten LLVM: $llvm_readobj" >&2
    exit 2
fi

# emsdk prepends its bundled CMake. The wave-16 probe established that the
# system CMake must win, while emcc/em++/emar remain available later in PATH.
# shellcheck disable=SC1090
source "$emsdk_root/emsdk_env.sh" >/dev/null
export PATH="/usr/bin:$PATH"

for tool in dub git emcmake cmake ninja emar python3; do
    if ! command -v "$tool" >/dev/null; then
        echo "required tool not found after emsdk setup: $tool" >&2
        exit 2
    fi
done

describe=$(cd "$repo_root" && TMPDIR=/var/tmp dub describe \
    --config=web \
    --arch=wasm32-unknown-emscripten \
    --compiler="$ldc")

package_path()
{
    local package_name=$1
    PACKAGE_NAME="$package_name" python3 -c '
import json, os, sys
name = os.environ["PACKAGE_NAME"]
matches = [p["path"] for p in json.load(sys.stdin)["packages"]
           if p["name"] == name and p.get("active", False)]
if len(matches) != 1:
    raise SystemExit(f"expected one active package {name}, got {matches}")
print(matches[0])
' <<<"$describe"
}

imgui_src=$(package_path d_imgui)
osd_src=$(package_path d-opensubdiv)
bvh_src=$(package_path d-bvh)
stb_src=$(package_path d-stb-image)

# Dub clones git dependencies without populating their submodules. Do this in
# the build-local DUB_HOME selected by build_web.sh; never repair the shared
# native package cache as a side effect of a browser build.
for package_root in "$imgui_src" "$osd_src" "$bvh_src" "$stb_src"; do
    git -C "$package_root" submodule update --init --recursive
done

for required in \
    "$imgui_src/extern/cimgui/cimgui.cpp" \
    "$osd_src/extern/OpenSubdiv/CMakeLists.txt" \
    "$bvh_src/extern/nanort/nanort.h" \
    "$stb_src/extern/stb/stb_image.h"; do
    if [[ ! -f "$required" ]]; then
        echo "dependency source/submodule is missing: $required" >&2
        echo "populate the pinned package source before running this script" >&2
        exit 2
    fi
done

# The d_imgui project hard-codes its archive below CMAKE_CURRENT_SOURCE_DIR/lib.
# Configure a private source mirror so even that archive stays outside the dub
# package's native lib directory. The other projects keep all output in -B.
cmake -E remove_directory "$out_root"
cmake -E make_directory "$source_root/d_imgui" "$build_root" "$lib_root"
cmake -E copy "$imgui_src/CMakeLists.txt" "$source_root/d_imgui/CMakeLists.txt"
cmake -E copy_directory "$imgui_src/cmake" "$source_root/d_imgui/cmake"
cmake -E copy_directory "$imgui_src/extern" "$source_root/d_imgui/extern"
cmake -E copy_directory "$imgui_src/source" "$source_root/d_imgui/source"

# WebAssembly validates indirect-call signatures. Refuse upstream drift instead
# of applying a broad sed that can silently patch zero or several functions.
python3 "$repo_root/tools/patch_imgui_font_atlas_abi.py" \
    "$source_root/d_imgui/source/imgui_vibe3d.cpp"

emcmake cmake -S "$source_root/d_imgui" -B "$build_root/d_imgui" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="-sUSE_SDL=2" \
    -DCMAKE_CXX_FLAGS="-sUSE_SDL=2 -DIMGUI_IMPL_OPENGL_ES3"
cmake --build "$build_root/d_imgui" --target cimgui_docking -j 8

emcmake cmake -S "$osd_src" -B "$build_root/d-opensubdiv" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release
cmake --build "$build_root/d-opensubdiv" --target osdc -j 8

emcmake cmake -S "$bvh_src" -B "$build_root/d-bvh" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release
cmake --build "$build_root/d-bvh" --target dbvh_c -j 8

emcmake cmake -S "$stb_src" -B "$build_root/d-stb-image" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release
cmake --build "$build_root/d-stb-image" --target stb_image_c -j 8

copy_archive()
{
    local search_root=$1
    local archive_name=$2
    local found
    mapfile -t found < <(find "$search_root" -type f -name "$archive_name" -print)
    if [[ ${#found[@]} -ne 1 ]]; then
        echo "expected one $archive_name below $search_root, got ${#found[@]}" >&2
        printf '%s\n' "${found[@]}" >&2
        exit 2
    fi
    cmake -E copy "${found[0]}" "$lib_root/$archive_name"
}

copy_archive "$source_root/d_imgui" libcimgui_docking.a
copy_archive "$build_root/d-opensubdiv" libosdc.a
copy_archive "$build_root/d-opensubdiv" libosdCPU.a
copy_archive "$build_root/d-opensubdiv" libosdGPU.a
copy_archive "$build_root/d-bvh" libdbvh_c.a
copy_archive "$build_root/d-stb-image" libstb_image_c.a

echo "web archives: $lib_root"
for archive in "$lib_root"/*.a; do
    echo "ARCHIVE $(basename "$archive")"
    emar t "$archive"
    architecture=$("$llvm_readobj" --file-headers "$archive" | grep 'Arch:' | sort -u)
    printf '%s\n' "$architecture"
    if [[ "$architecture" != "Arch: wasm32" ]]; then
        echo "archive architecture mismatch for $archive: expected only 'Arch: wasm32'" >&2
        exit 3
    fi
done
