#!/usr/bin/env bash
# Regenerate tests/fixtures/web_io/ (task 7420) through the PRODUCTION command
# path of a live desktop editor: two_layers.v3d is authored with /api/command,
# two_layers.resave.v3d is that file opened with `file.load` and saved again
# with `file.save` (the same FileLoad -> FileSave path the browser takes), and
# truncated.v3d is the first 200 bytes of the first.
#
# usage: tools/web_file_io/make_fixtures.sh [--http-port N]   (default 8520)
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
port=8520
if [[ ${1:-} == --http-port ]]; then port=$2; fi
out="$repo_root/tests/fixtures/web_io"
mkdir -p "$out"
scratch=$(mktemp -d "${TMPDIR:-/var/tmp}/vibe3d-web-io-fixtures.XXXXXX")
pid=
editor_pid=
cleanup() {
    # The editor is the process LISTENING on our port (xvfb-run and setsid
    # stand between $! and it); killing it lets xvfb-run reap its own Xvfb.
    [[ -z $editor_pid ]] || kill "$editor_pid" 2>/dev/null || true
    # Never kill the wrapper itself: that orphans its Xvfb (measured).
    [[ -z $pid ]] || timeout 20 tail --pid="$pid" -f /dev/null || true
    rm -rf "$scratch"
}
trap cleanup EXIT

# Own X display (xvfb-run -a) and own config dir, never the desktop session.
env -u WAYLAND_DISPLAY SDL_VIDEODRIVER=x11 VIBE3D_CONFIG_DIR="$scratch/config" \
    setsid xvfb-run -a "$repo_root/vibe3d" --test --http-port "$port" \
    </dev/null >"$scratch/vibe3d.log" 2>&1 &
pid=$!
for _ in $(seq 1 200); do
    curl -sf "http://127.0.0.1:$port/api/layers" >/dev/null 2>&1 && break
    sleep 0.1
done
editor_pid=$(ss -ltnpH "sport = :$port" | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
[[ -n $editor_pid ]] || { echo "editor did not start on port $port" >&2; cat "$scratch/vibe3d.log" >&2; exit 1; }

cmd() {   # cmd <id> [params-json]
    local body reply
    if [[ $# -gt 1 ]]; then body="{\"id\":\"$1\",\"params\":$2}"
    else body="{\"id\":\"$1\"}"; fi
    reply=$(curl -s -X POST --data "$body" "http://127.0.0.1:$port/api/command")
    if [[ $reply != *'"status":"ok"'* && $reply != *'"status": "ok"'* ]]; then
        echo "command failed: $body -> $reply" >&2
        exit 1
    fi
}

cmd scene.reset
cmd layer.add '{"name":"B"}'
cmd prim.sphere
cmd file.save "{\"path\":\"$scratch/two_layers.v3d\"}"
cmd scene.reset
cmd file.load "{\"path\":\"$scratch/two_layers.v3d\"}"
cmd file.save "{\"path\":\"$scratch/two_layers.resave.v3d\"}"

cp "$scratch/two_layers.v3d" "$out/two_layers.v3d"
cp "$scratch/two_layers.resave.v3d" "$out/two_layers.resave.v3d"
head -c 200 "$out/two_layers.v3d" >"$out/truncated.v3d"
sha256sum "$out"/*.v3d
