#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
artifact_root=${VIBE3D_WEB_ARTIFACT_ROOT:-"$repo_root/.build/web-artifacts"}
emcc=${EMCC:-"${EMSDK:-$HOME/emsdk}/upstream/emscripten/emcc"}
args=("$@")
output=

for ((i = 0; i < ${#args[@]}; ++i)); do
    if [[ ${args[i]} == -o && $((i + 1)) -lt ${#args[@]} ]]; then
        output=${args[i + 1]}
        break
    fi
done

# LDC names an Emscripten executable *.wasm. Give the final invocation a JS
# target so emcc emits its browser loader as well, then leave the wasm at the
# exact path LDC/dub expect.
if [[ $output == *.wasm ]]; then
    js_output=${output%.wasm}.js
    args[i + 1]=$js_output
    "$emcc" "${args[@]}"
    mkdir -p "$artifact_root"
    cp "$js_output" "$artifact_root/vibe3d.js"
    cp "$output" "$artifact_root/vibe3d.wasm"
    data_output=${js_output%.js}.data
    if [[ -f $data_output ]]; then
        cp "$data_output" "$artifact_root/vibe3d.data"
    fi
else
    # LDC hands every -Xcc flag to its C preprocessing calls as well. emcc
    # ignores its other link-only flags there but forwards `--js-library` to
    # clang, which rejects it (measured, task 7420), so drop it before compiling.
    compile_args=()
    for ((j = 0; j < ${#args[@]}; ++j)); do
        if [[ ${args[j]} == --js-library ]]; then ((++j)); continue; fi
        [[ ${args[j]} == --js-library=* ]] && continue
        compile_args+=("${args[j]}")
    done
    exec "$emcc" "${compile_args[@]}"
fi
