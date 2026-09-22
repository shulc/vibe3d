#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
chromium=${VIBE3D_CHROMIUM:-$(command -v chromium-browser || command -v chromium || true)}
[[ -n $chromium ]] || { echo "Chromium not found" >&2; exit 2; }
if [[ ${VIBE3D_WEB_RUNNER_NO_BUILD:-0} != 1 ]]; then
    VIBE3D_WEB_OPTIMIZED=1 "$repo_root/tools/build_web.sh"
fi
artifact_root="$repo_root/.build/web-artifacts"
for artifact in vibe3d.js vibe3d.wasm vibe3d.data; do
    [[ -s "$artifact_root/$artifact" ]] || { echo "missing artifact: $artifact_root/$artifact" >&2; exit 2; }
done

scratch=$(mktemp -d "${TMPDIR:-/var/tmp}/vibe3d-web-runner.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

for mode in normal spreset; do
    js="$artifact_root/vibe3d.js"
    if [[ $mode == spreset ]]; then
        js="$scratch/vibe3d-spreset.js"
        python3 "$repo_root/tools/spreset.py" "$artifact_root/vibe3d.js" "$js"
    fi
    python3 - "$artifact_root" "$js" "$scratch/$mode.html" "$mode" <<'PY'
import base64, pathlib, sys
root, js_path, output = map(pathlib.Path, sys.argv[1:4])
mode = sys.argv[4]
wasm = base64.b64encode((root / "vibe3d.wasm").read_bytes()).decode()
data = base64.b64encode((root / "vibe3d.data").read_bytes()).decode()
js = js_path.read_text().replace(
    "var fetched = Module['getPreloadedPackage'] && Module['getPreloadedPackage'](REMOTE_PACKAGE_NAME, REMOTE_PACKAGE_SIZE);",
    "var fetched = window.__vibeData;")
token = f"w16-r-{mode}-argv"
html = f'''<!doctype html><meta charset="utf-8"><style>html,body{{margin:0;overflow:hidden}}canvas{{display:block;width:800px;height:600px}}#report{{display:none}}</style>
<canvas id="canvas" width="1280" height="720"></canvas><pre id="report">BOOT mode={mode}</pre>
<script>
const report = document.getElementById('report');
const canvas = document.getElementById('canvas');
window.onerror = (m,s,l,c,e) => report.textContent += `\\nERROR ${{m}} @${{l}}:${{c}} ${{e?.stack || ''}}`;
const append = (kind, value) => {{
  report.textContent += `\\n${{kind}} ${{value}}`;
}};
var Module = {{
  canvas,
  arguments: ['--web-first-frame-probe', '--web-probe-argument', '{token}', '--no-http', '--window', '800x600'],
  wasmBinary: Uint8Array.from(atob('{wasm}'), c => c.charCodeAt(0)),
  print: x => append('OUT', x),
  printErr: x => append('ERR', x),
  onRuntimeInitialized: () => report.textContent += '\\nRUNTIME-READY'
}};
window.__vibeData = Uint8Array.from(atob('{data}'), c => c.charCodeAt(0)).buffer;
</script><script>{js}</script>'''
output.write_text(html)
PY
    deadline=${VIBE3D_WEB_RUNNER_TIMEOUT:-90}
    timeout "$((deadline + 5))" node "$repo_root/tools/web_cdp_capture.mjs" \
        "$chromium" "file://$scratch/$mode.html" "$scratch/$mode.dom" \
        "$scratch/$mode.png" "$scratch/profile-$mode" "$((deadline * 1000))"
    if grep -Eq '^(ERROR|ERR Aborted)' "$scratch/$mode.dom"; then
        sed -n '/<pre id="report">/,/<\/pre>/p' "$scratch/$mode.dom" >&2
        exit 3
    fi
    grep -q 'RUNTIME-READY' "$scratch/$mode.dom" || { echo "$mode: runtime did not initialize" >&2; exit 3; }
    receipt=$(grep -Eo 'OUT WEB-FIRST-FRAME-COMPLETE subpatch=1 thickSubmissions=[1-9][0-9]* cells=[1-9][0-9]* previewFaces=[1-9][0-9]* viewport=[0-9,]+' "$scratch/$mode.dom" | head -1 || true)
    ack=$(grep -Eo 'OUT WEB-RUNNER-INPUT-ACK source=sdl generation=router frame=[0-9]+ mouse=321,234' "$scratch/$mode.dom" | head -1 || true)
    live=$(grep -Eo "OUT WEB-RUNNER-LIVE args=w16-r-$mode-argv input=mouse-motion source=imgui-io generation=new-frame mouse=321,234 context=live frame=[0-9]+ inputFrame=[0-9]+" "$scratch/$mode.dom" | head -1 || true)
    window=$(grep -Eo 'OUT WEB-WINDOW-READY window=800x600 framebuffer=800x600 dpiRc=0 dpi=[0-9.]+ icon=page-owned' "$scratch/$mode.dom" | head -1 || true)
    window_input=$(grep -Eo 'OUT WEB-WINDOW-INPUT source=router-consumers generation=production keyboard=down\+up text=imgui buttons=down\+up wheel=handler resize=layout focus=owned window=640x480 framebuffer=640x480 layout=490x424' "$scratch/$mode.dom" | head -1 || true)
    [[ -n $receipt ]] || { echo "$mode: first-frame receipt missing" >&2; sed -n '/<pre id="report">/,/<\/pre>/p' "$scratch/$mode.dom" >&2; exit 3; }
    [[ -n $ack ]] || { echo "$mode: routed input acknowledgement missing" >&2; sed -n '/<pre id="report">/,/<\/pre>/p' "$scratch/$mode.dom" >&2; exit 3; }
    [[ -n $live ]] || { echo "$mode: argv/input/live-context receipt missing" >&2; sed -n '/<pre id="report">/,/<\/pre>/p' "$scratch/$mode.dom" >&2; exit 3; }
    [[ -n $window ]] || { echo "$mode: initial window/DPI/framebuffer receipt missing" >&2; sed -n '/<pre id="report">/,/<\/pre>/p' "$scratch/$mode.dom" >&2; exit 3; }
    [[ -n $window_input ]] || { echo "$mode: browser window/input receipt missing" >&2; sed -n '/<pre id="report">/,/<\/pre>/p' "$scratch/$mode.dom" >&2; exit 3; }
    python3 - "$ack" "$live" <<'PY'
import re, sys
ack, live = sys.argv[1:]
input_frame = int(re.search(r"frame=(\d+)", ack).group(1))
live_frame = int(re.search(r" frame=(\d+)", live).group(1))
reported_input = int(re.search(r"inputFrame=(\d+)", live).group(1))
if reported_input != input_frame or live_frame <= input_frame:
    raise SystemExit(f"live receipt was not produced on a following production tick: ack={ack!r} live={live!r}")
PY
    viewport=${receipt##*viewport=}
    python3 "$repo_root/tools/check_web_frame_pixels.py" "$scratch/$mode.png" "$viewport"
    echo "WEB-RUNNER mode=$mode build=O2 runtime=ready frame=1 argv=intact closure=invoked stack=reset-safe input=mouse-motion window-input=complete context=live"
done
