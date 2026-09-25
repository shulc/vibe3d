#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_root=${VIBE3D_AUTOREMESHER_SOURCE:-$HOME/Code/D-AutoRemesher}
out=${1:-$here/.build/web-remesh}
mkdir -p "$out/obj"
if [[ ! -f $source_root/c_api/autoremesher_c.cpp ]]; then
    source_root="$here/.build/web-remesh-source"
    if [[ ! -d $source_root/.git ]]; then
        git clone https://github.com/shulc/D-AutoRemesher.git "$source_root"
    fi
    git -C "$source_root" checkout --detach f1b3f920a91186ad67078490f6a462479252f13e
    git -C "$source_root" submodule update --init --depth 1 third_party/autoremesher
fi
source_root=$(realpath "$source_root")
out=$(realpath "$out")
upstream="$source_root/third_party/autoremesher"
geogram="$upstream/thirdparty/geogram/geogram-1.8.3/src/lib"
[[ -f "$source_root/c_api/autoremesher_c.cpp" && -f "$upstream/src/AutoRemesher/autoremesher.cpp" ]] || {
    echo "AutoRemesher source missing: $source_root (set VIBE3D_AUTOREMESHER_SOURCE)" >&2
    exit 2
}
patch="$source_root/patches/quadextractor-preserve-boundaries.patch"
if ! git -C "$upstream" apply --reverse --check "$patch" >/dev/null 2>&1; then
    if [[ $source_root == "$here/.build/web-remesh-source" ]] &&
            git -C "$upstream" apply --check "$patch" >/dev/null 2>&1; then
        git -C "$upstream" apply "$patch"
    else
        echo "AutoRemesher boundary patch is not applied in $upstream" >&2
        exit 2
    fi
fi

emsdk_root=${EMSDK:-$HOME/emsdk}
# shellcheck disable=SC1090
source "$emsdk_root/emsdk_env.sh" >/dev/null
export PATH="/usr/bin:$PATH"

includes=(
    -I"$here/web/remesh_tbb" -I"$source_root/shim" -I"$source_root/c_api"
    -I"$upstream/include" -I"$upstream/src"
    -I"$upstream/thirdparty/eigen" -I"$upstream/thirdparty/isotropicremesher"
    -I"$geogram" -I"$geogram/geogram/third_party/libMeshb/sources"
    -I"$geogram/geogram/NL" -I"$upstream/thirdparty/geogram"
)
common=(-O2 -fwasm-exceptions -fno-strict-aliasing -w -DNDEBUG
    -D_USE_MATH_DEFINES -DNOMINMAX "${includes[@]}")
export source_root upstream out
if ! printf '%s\n' "${common[@]}" | cmp -s - "$out/flags.txt"; then
    printf '%s\n' "${common[@]}" >"$out/flags.txt"
fi
compile_one() {
    local rel=$1 src obj
    src="$upstream/$rel"
    obj="$out/obj/${rel//\//_}.o"
    if [[ -s $obj && $obj -nt $src && $obj -nt $out/flags.txt ]]; then return; fi
    if [[ $src == *.c ]]; then
        emcc -std=gnu99 "${common[@]}" -c "$src" -o "$obj"
    else
        em++ -std=c++14 "${common[@]}" -c "$src" -o "$obj"
    fi
}
while IFS= read -r rel; do
    [[ -n $rel ]] || continue
    compile_one "$rel"
done <"$source_root/sources.txt"
em++ -std=c++14 "${common[@]}" -c "$source_root/c_api/autoremesher_c.cpp" -o "$out/obj/c_api.o"
em++ -std=c++14 "${common[@]}" -Dmain=autoremesher_cli_main \
    -c "$source_root/cli/autoremesher_cli.cpp" -o "$out/obj/cli.o"
em++ -std=c++14 "${common[@]}" -c "$here/web/remesh_module.cpp" -o "$out/obj/module.o"
em++ "$out"/obj/*.o -O2 -fwasm-exceptions \
    -sUSE_ZLIB=1 -lnodefs.js \
    -sMODULARIZE=1 -sEXPORT_NAME=createRemesher -sALLOW_MEMORY_GROWTH=1 \
    -sEXPORTED_FUNCTIONS=_vibe_remesh \
    -sEXPORTED_RUNTIME_METHODS=FS \
    -sFORCE_FILESYSTEM=1 -sENVIRONMENT=worker,node \
    --no-entry -o "$out/remesh_module.js"
echo "REMESH-WASM $(stat -c%s "$out/remesh_module.wasm") bytes"
