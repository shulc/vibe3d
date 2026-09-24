#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
chromium=${VIBE3D_CHROMIUM:-$(command -v chromium-browser || command -v chromium || true)}
[[ -n $chromium ]] || { echo 'Chromium not found' >&2; exit 2; }
assimp_version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["versions"]["bindbc-assimp6"]["version"])' "$repo_root/dub.selections.json")
assimp_source="${VIBE3D_ASSIMP_SOURCE:-$HOME/.dub/packages/bindbc-assimp6/$assimp_version/bindbc-assimp6/extern/assimp}"
"$repo_root/tools/stage_web_editor.sh"
if [[ ! -f $assimp_source/CMakeLists.txt ]]; then
    assimp_source="$repo_root/.build/web-assimp-source/extern/assimp"
fi
[[ -f $assimp_source/CMakeLists.txt ]] || { echo "Assimp source missing: $assimp_source" >&2; exit 2; }
scratch=$(mktemp -d "${TMPDIR:-/var/tmp}/vibe3d-assimp-io.XXXXXX")
server_pid=
cleanup() {
    [[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null || true
    if [[ ${VIBE3D_WEB_ASSIMP_KEEP:-0} == 1 ]]; then
        echo "kept $scratch"
    else
        python3 - "$scratch" <<'PY'
import shutil,sys
shutil.rmtree(sys.argv[1])
PY
    fi
}
trap cleanup EXIT
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$repo_root/.build/web-editor" >"$scratch/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 100); do
    port=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$scratch/server.log" | head -1)
    [[ -z ${port:-} ]] || break
    sleep .05
done
[[ -n ${port:-} ]] || { cat "$scratch/server.log" >&2; exit 3; }
node "$repo_root/tools/web_file_io/case_assimp.mjs" "$chromium" "http://127.0.0.1:$port" "$scratch" "$assimp_source"
python3 - "$scratch" <<'PY'
from pathlib import Path
from zipfile import ZipFile
import sys
root = Path(sys.argv[1])
for ext, expected in {'obj': {'Untitled.obj', 'Untitled.mtl'},
                      'gltf': {'Untitled.gltf', 'Untitled.bin'}}.items():
    files = list((root / f'downloads-file-export-{ext}').iterdir())
    assert len(files) == 1, (ext, files)
    with ZipFile(files[0]) as z:
        assert {x.filename for x in z.infolist()} == expected, ext
        assert z.testzip() is None, ext
    print(f'WEB-ASSIMP archive {ext} ok')
PY
