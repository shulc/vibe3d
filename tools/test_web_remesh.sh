#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
chromium=${VIBE3D_CHROMIUM:-$(command -v chromium-browser || command -v chromium || true)}
[[ -n $chromium ]] || { echo 'Chromium not found' >&2; exit 2; }
"$repo_root/tools/stage_web_editor.sh"
scratch=$(mktemp -d "${TMPDIR:-/var/tmp}/vibe3d-web-remesh.XXXXXX")
server_pid=
cleanup() {
    [[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null || true
    if [[ ${VIBE3D_WEB_REMESH_KEEP:-0} == 1 ]]; then
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
node "$repo_root/tools/web_file_io/case_remesh.mjs" "$chromium" "http://127.0.0.1:$port" "$scratch"
