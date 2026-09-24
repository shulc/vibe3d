#!/usr/bin/env bash
# Usage: build_web_assimp.sh <assimp-source-root> <output-dir>
set -euo pipefail

assimp_src=$(realpath "$1")
out=$(mkdir -p "$2" && realpath "$2")
here=$(cd "$(dirname "$0")" && pwd)
emsdk_root=${EMSDK:-$HOME/emsdk}
source "$emsdk_root/emsdk_env.sh" >/dev/null
export PATH="/usr/bin:$PATH"  # system CMake, Emscripten clang/emcc still on PATH

emcmake cmake -S "$assimp_src" -B "$out/assimp-build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DASSIMP_BUILD_ALL_IMPORTERS_BY_DEFAULT=OFF \
  -DASSIMP_BUILD_ALL_EXPORTERS_BY_DEFAULT=OFF \
  -DASSIMP_BUILD_GLTF_IMPORTER=ON -DASSIMP_BUILD_OBJ_IMPORTER=ON \
  -DASSIMP_BUILD_FBX_IMPORTER=ON -DASSIMP_BUILD_GLTF_EXPORTER=ON \
  -DASSIMP_BUILD_OBJ_EXPORTER=ON -DASSIMP_BUILD_FBX_EXPORTER=ON \
  -DASSIMP_BUILD_ZLIB=ON \
  -DASSIMP_BUILD_ASSIMP_TOOLS=OFF -DASSIMP_BUILD_TESTS=OFF \
  -DASSIMP_BUILD_SAMPLES=OFF -DASSIMP_INSTALL=OFF \
  -DASSIMP_WARNINGS_AS_ERRORS=OFF -DASSIMP_BUILD_DRACO=OFF \
  -DCMAKE_CXX_FLAGS=-fwasm-exceptions -DCMAKE_C_FLAGS=-fwasm-exceptions \
  >"$out/configure.log"
cmake --build "$out/assimp-build" --target assimp -j "${VIBE3D_WEB_JOBS:-8}" \
  >"$out/build.log"

em++ "$here/../web/assimp_module.cpp" -O2 -fwasm-exceptions \
  -I"$assimp_src/include" -I"$out/assimp-build/include" \
  "$out/assimp-build/lib/libassimp.a" \
  "$out/assimp-build/contrib/zlib/libzlibstatic.a" \
  -sMODULARIZE=1 -sEXPORT_NAME=createAssimp -sALLOW_MEMORY_GROWTH=1 \
  -sEXPORTED_FUNCTIONS=_malloc,_free,_vibe_import_file,_vibe_export_file,_vibe_result_ptr,_vibe_result_len,_vibe_error \
  -sEXPORTED_RUNTIME_METHODS=FS,HEAPU8,UTF8ToString,stringToUTF8,lengthBytesUTF8 \
  -sFORCE_FILESYSTEM=1 -sENVIRONMENT=web,node \
  --no-entry -o "$out/assimp_module.js"

echo "ASSIMP-WASM $(stat -c%s "$out/assimp_module.wasm") bytes"
