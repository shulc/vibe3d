#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
artifact_root="$repo_root/.build/web-artifacts"
editor_root="$repo_root/.build/web-editor"

if [[ ${VIBE3D_WEB_EDITOR_NO_BUILD:-0} != 1 ]]; then
    VIBE3D_WEB_OPTIMIZED=1 "$repo_root/tools/build_web.sh"
fi
for artifact in vibe3d.js vibe3d.wasm vibe3d.data assimp_module.js assimp_module.wasm remesh_module.js remesh_module.wasm; do
    [[ -s "$artifact_root/$artifact" ]] || {
        echo "missing web artifact: $artifact_root/$artifact" >&2
        exit 2
    }
done

cmake -E make_directory "$editor_root"
cmake -E copy "$repo_root/web/editor/index.html" "$editor_root/index.html"
cmake -E copy "$repo_root/assets/icon/vibe3d.svg" "$editor_root/favicon.svg"
cmake -E copy "$repo_root/assets/icon/vibe3d.ico" "$editor_root/favicon.ico"
cmake -E copy "$artifact_root/vibe3d.js" "$editor_root/vibe3d.js"
cmake -E copy "$artifact_root/vibe3d.wasm" "$editor_root/vibe3d.wasm"
cmake -E copy "$artifact_root/vibe3d.data" "$editor_root/vibe3d.data"
cmake -E copy "$artifact_root/assimp_module.js" "$editor_root/assimp_module.js"
cmake -E copy "$artifact_root/assimp_module.wasm" "$editor_root/assimp_module.wasm"
cmake -E copy "$artifact_root/remesh_module.js" "$editor_root/remesh_module.js"
cmake -E copy "$artifact_root/remesh_module.wasm" "$editor_root/remesh_module.wasm"
cmake -E copy "$repo_root/web/remesh_worker.js" "$editor_root/remesh_worker.js"
printf 'WEB-EDITOR staged=%s/index.html\n' "$editor_root"
