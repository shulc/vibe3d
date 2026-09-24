#!/usr/bin/env bash
# Usage: build.sh <assimp-source-root> <ldc-root> <D-runtime-lib-dir> <output-dir>
# Example source root: bindbc-assimp6/extern/assimp (the pinned Assimp submodule).
set -euo pipefail

assimp_src=$(realpath "$1")
ldc_root=$(realpath "$2")
d_lib=$(realpath "$3")
out=$(mkdir -p "$4" && realpath "$4")
here=$(cd "$(dirname "$0")" && pwd)
emsdk_root=${EMSDK:-$HOME/emsdk}
source "$emsdk_root/emsdk_env.sh" >/dev/null
export PATH="/usr/bin:$PATH"  # system CMake, Emscripten clang/emcc still on PATH

emcmake cmake -S "$assimp_src" -B "$out/assimp-build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DASSIMP_BUILD_ALL_IMPORTERS_BY_DEFAULT=OFF \
  -DASSIMP_BUILD_ALL_EXPORTERS_BY_DEFAULT=OFF \
  -DASSIMP_BUILD_GLTF_IMPORTER=ON -DASSIMP_BUILD_ZLIB=ON \
  -DASSIMP_BUILD_ASSIMP_TOOLS=OFF -DASSIMP_BUILD_TESTS=OFF \
  -DASSIMP_BUILD_SAMPLES=OFF -DASSIMP_INSTALL=OFF \
  -DASSIMP_WARNINGS_AS_ERRORS=OFF -DASSIMP_BUILD_DRACO=OFF \
  -DCMAKE_CXX_FLAGS=-fwasm-exceptions -DCMAKE_C_FLAGS=-fwasm-exceptions \
  >"$out/configure.log"
cmake --build "$out/assimp-build" --target assimp -j "${VIBE3D_WEB_JOBS:-8}" \
  >"$out/build.log"

em++ "$here/assimp_module.cpp" -O2 -fwasm-exceptions \
  -I"$assimp_src/include" -I"$out/assimp-build/include" \
  "$out/assimp-build/lib/libassimp.a" \
  "$out/assimp-build/contrib/zlib/libzlibstatic.a" \
  -sMODULARIZE=1 -sEXPORT_NAME=createAssimp -sALLOW_MEMORY_GROWTH=1 \
  -sEXPORTED_FUNCTIONS=_malloc,_free,_vibe_eh_probe,_vibe_import_glb,_vibe_result_ptr,_vibe_result_len,_vibe_error \
  -sEXPORTED_RUNTIME_METHODS=HEAPU8,UTF8ToString -sENVIRONMENT=web,node \
  --no-entry -o "$out/assimp_module.js"

"$ldc_root/bin/ldc2" -c -mtriple=wasm32-unknown-emscripten \
  -of="$out/d_consumer.o" "$here/d_consumer.d"
emcc "$out/d_consumer.o" \
  "$d_lib/libphobos2-ldc.a" "$d_lib/libdruntime-ldc.a" \
  -sMODULARIZE=1 -sEXPORT_NAME=createDConsumer -sALLOW_MEMORY_GROWTH=1 \
  -sENVIRONMENT=web,node \
  -sEXPORTED_FUNCTIONS=_main,_malloc,_free,_vibe_d_eh_probe,_vibe_consume_scene,_vibe_d_parts,_vibe_d_vertices,_vibe_d_faces \
  -sEXPORTED_RUNTIME_METHODS=HEAPU8,UTF8ToString \
  -o "$out/d_consumer.js"

echo "ASSIMP-WASM $(stat -c%s "$out/assimp_module.wasm") bytes"
echo "D-WASM $(stat -c%s "$out/d_consumer.wasm") bytes"
