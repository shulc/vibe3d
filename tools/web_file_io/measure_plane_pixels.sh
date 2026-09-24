#!/usr/bin/env bash
# Desktop measurement behind the browser lane's image-plane pixel floor (task
# 7450, cell I3 of tools/web_file_io/case_images.mjs). A live desktop editor on
# its own Xvfb, at the browser lane's window size (1280x720), opens
# tests/fixtures/web_io/plane_scene.v3d with `file.load` three ways and the
# whole screen is grabbed after each:
#   with-image  the fixture folder, where magenta8.png sits beside the .v3d
#   missing     a copy of the .v3d alone in an empty folder (the I4 control)
#   no-plane    `scene.reset` (the default cube, the C0 control)
# and the pixels within +-8 of (255,0,255) are counted per grab. It prints one
# `PLANE-PIXELS <case> magenta=<n> of <w>x<h>` line per case. Not a gate: run
# it when the fixture, the plane draw or the lane's window size changes, and
# carry the numbers to case_images.mjs's floor with this command.
#
# usage: tools/web_file_io/measure_plane_pixels.sh [--http-port N]   (default 8550)
#        VIBE3D_PLANE_PIXELS_KEEP=1 keeps the grabs and prints their folder.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
port=8550
if [[ ${1:-} == --http-port ]]; then port=$2; fi
fixtures="$repo_root/tests/fixtures/web_io"
scratch=$(mktemp -d "${TMPDIR:-/var/tmp}/vibe3d-plane-pixels.XXXXXX")
pid=
editor_pid=
cleanup() {
    [[ -z $editor_pid ]] || kill "$editor_pid" 2>/dev/null || true
    [[ -z $pid ]] || timeout 20 tail --pid="$pid" -f /dev/null || true
    if [[ -n ${VIBE3D_PLANE_PIXELS_KEEP:-} ]]; then echo "kept $scratch" >&2; else rm -rf "$scratch"; fi
}
trap cleanup EXIT

# Software GL over GLX and NO --test: under --test (even with --visible) the
# grabbed viewport was blank for all three cases (measured 2026-09-24), so the
# editor runs as a normal window and is driven through --http-port only.
env -u WAYLAND_DISPLAY SDL_VIDEODRIVER=x11 SDL_VIDEO_X11_FORCE_EGL=0 \
    LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe MESA_LOADER_DRIVER_OVERRIDE=llvmpipe \
    __GLX_VENDOR_LIBRARY_NAME=mesa VIBE3D_CONFIG_DIR="$scratch/config" \
    setsid xvfb-run -a -s "-screen 0 1280x720x24" "$repo_root/vibe3d" \
    --window 1280x720 --http-port "$port" </dev/null >"$scratch/vibe3d.log" 2>&1 &
pid=$!
for _ in $(seq 1 200); do
    curl -sf "http://127.0.0.1:$port/api/layers" >/dev/null 2>&1 && break
    sleep 0.1
done
editor_pid=$(ss -ltnpH "sport = :$port" | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
[[ -n $editor_pid ]] || { echo "editor did not start on port $port" >&2; cat "$scratch/vibe3d.log" >&2; exit 1; }
display=$(tr '\0' '\n' <"/proc/$editor_pid/environ" | sed -n 's/^DISPLAY=//p')

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
grab() {   # grab <case>
    sleep 2
    import -display "$display" -window root "$scratch/$1.png"
    python3 - "$scratch/$1.png" "$1" <<'EOF'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
n = sum(1 for r, g, b in image.getdata() if r >= 247 and g <= 8 and b >= 247)
print(f"PLANE-PIXELS {sys.argv[2]} magenta={n} of {image.width}x{image.height}")
EOF
}

mkdir -p "$scratch/alone"
cp "$fixtures/plane_scene.v3d" "$scratch/alone/plane_scene.v3d"
cmd scene.reset
grab no-plane
cmd file.load "{\"path\":\"$fixtures/plane_scene.v3d\"}"
grab with-image
cmd file.load "{\"path\":\"$scratch/alone/plane_scene.v3d\"}"
grab missing
