#!/usr/bin/env bash
set -euo pipefail

# Kept as the compatibility entry point used by W16-L.  W16-R strengthens it
# to the permanent two-mode browser runner (normal + forced stack reset).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_web_browser_runner.sh" "$@"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
chromium=${VIBE3D_CHROMIUM:-$(command -v chromium-browser || command -v chromium || true)}
if [[ -z $chromium ]]; then
    echo "Chromium not found" >&2
    exit 2
fi
artifact_root="$repo_root/.build/web-artifacts"
for artifact in "$artifact_root/vibe3d.js" "$artifact_root/vibe3d.wasm" "$artifact_root/vibe3d.data"; do
    [[ -s $artifact ]] || { echo "missing artifact: $artifact" >&2; exit 2; }
done

scratch=$(mktemp -d "${TMPDIR:-/var/tmp}/vibe3d-web-frame.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

python3 - "$artifact_root" "$scratch/index.html" <<'PY'
import base64, pathlib, sys
root, output = map(pathlib.Path, sys.argv[1:])
wasm = base64.b64encode((root / "vibe3d.wasm").read_bytes()).decode()
data = base64.b64encode((root / "vibe3d.data").read_bytes()).decode()
js = (root / "vibe3d.js").read_text()
js = js.replace(
    "var fetched = Module['getPreloadedPackage'] && Module['getPreloadedPackage'](REMOTE_PACKAGE_NAME, REMOTE_PACKAGE_SIZE);",
    "var fetched = window.__vibeData;")
html = f'''<!doctype html><meta charset="utf-8"><style>html,body{{margin:0;overflow:hidden}}canvas{{display:block}}#report{{display:none}}</style>
<canvas id="canvas" width="1280" height="720"></canvas><pre id="report">BOOT</pre>
<script>
const report = document.getElementById('report');
window.onerror = (m,s,l,c,e) => report.textContent += `\\nERROR ${{m}} @${{l}}:${{c}} ${{e?.stack || ''}}`;
var Module = {{
  canvas: document.getElementById('canvas'),
  arguments: ['--web-first-frame-probe', '--no-http', '--window', '800x600'],
  wasmBinary: Uint8Array.from(atob('{wasm}'), c => c.charCodeAt(0)),
  print: x => report.textContent += `\\nOUT ${{x}}`,
  printErr: x => report.textContent += `\\nERR ${{x}}`,
  onRuntimeInitialized: () => report.textContent += '\\nRUNTIME-READY'
}};
window.__vibeData = Uint8Array.from(atob('{data}'), c => c.charCodeAt(0)).buffer;
</script><script>{js}</script>'''
output.write_text(html)
PY

"$chromium" --headless --no-sandbox --disable-gpu \
    --enable-unsafe-swiftshader --use-angle=swiftshader \
    --window-size=1280,720 --virtual-time-budget=30000 \
    --screenshot="$scratch/frame.png" --dump-dom \
    "file://$scratch/index.html" >"$scratch/dom.txt"
cp "$scratch/frame.png" "$repo_root/.build/web-first-frame.png"

if grep -Eq '^(ERROR|ERR Aborted)' "$scratch/dom.txt"; then
    sed -n '/<pre id="report">/,/<\/pre>/p' "$scratch/dom.txt" >&2
    exit 3
fi
grep -q 'RUNTIME-READY' "$scratch/dom.txt" || {
    echo "runtime did not initialize" >&2
    exit 3
}
receipt=$(grep -Eo 'OUT WEB-FIRST-FRAME-COMPLETE subpatch=1 thickSubmissions=[1-9][0-9]* cells=[1-9][0-9]* previewFaces=[1-9][0-9]* viewport=[0-9,]+' \
    "$scratch/dom.txt" | head -1 || true)
[[ -n $receipt ]] || {
    echo "post-frame production witness missing" >&2
    sed -n '/<pre id="report">/,/<\/pre>/p' "$scratch/dom.txt" >&2
    exit 3
}
echo "$receipt"
[[ -s "$scratch/frame.png" ]] || { echo "first-frame screenshot is empty" >&2; exit 3; }
viewport=$(sed -n 's/.*viewport=\([0-9][0-9]*,[0-9][0-9]*,[0-9][0-9]*,[0-9][0-9]*\).*/\1/p' "$scratch/dom.txt" | head -1)
[[ -n $viewport ]] || { echo "viewport bounds missing from receipt" >&2; exit 3; }
python3 "$repo_root/tools/check_web_frame_pixels.py" "$scratch/frame.png" "$viewport"
echo "WEB-FIRST-FRAME runtime=ready subpatch=1 thick=1 screenshot=.build/web-first-frame.png"
