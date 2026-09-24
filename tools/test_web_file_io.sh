#!/usr/bin/env bash
# Browser lane for web file I/O (task 7420): builds and stages the optimized
# web editor exactly as tools/test_web_editor.sh does, then drives the real
# page in headless Chromium through tools/web_file_io/case_v3d.mjs in both the
# normal and the reset-stack (spreset) artifact.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
chromium=${VIBE3D_CHROMIUM:-$(command -v chromium-browser || command -v chromium || true)}
[[ -n $chromium ]] || { echo "Chromium not found" >&2; exit 2; }
"$repo_root/tools/stage_web_editor.sh"

scratch=$(mktemp -d "${TMPDIR:-/var/tmp}/vibe3d-web-file-io.XXXXXX")
server_pid=
cleanup() {
    [[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null || true
    [[ -z ${VIBE3D_WEB_FILE_IO_KEEP:-} ]] || { echo "kept $scratch" >&2; return; }
    rm -rf "$scratch"
}
trap cleanup EXIT
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$repo_root/.build/web-editor" \
    >"$scratch/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 100); do
    port=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$scratch/server.log" | head -1)
    [[ -z ${port:-} ]] || break
    sleep 0.05
done
[[ -n ${port:-} ]] || { cat "$scratch/server.log" >&2; exit 3; }

cp "$repo_root/.build/web-editor/vibe3d.js" "$scratch/vibe3d-normal.js"
for mode in normal spreset; do
    if [[ $mode == normal ]]; then
        cp "$scratch/vibe3d-normal.js" "$repo_root/.build/web-editor/vibe3d.js"
    else
        python3 "$repo_root/tools/spreset.py" "$scratch/vibe3d-normal.js" \
            "$repo_root/.build/web-editor/vibe3d.js"
    fi
    timeout 240 node "$repo_root/tools/web_file_io/case_v3d.mjs" \
        "$chromium" "http://127.0.0.1:$port" "$scratch" \
        "$repo_root/tests/fixtures/web_io" "$mode"
done
cp "$scratch/vibe3d-normal.js" "$repo_root/.build/web-editor/vibe3d.js"
