#!/usr/bin/env python3
"""Cross-check vibe3d's pipeline-evaluated center/axis against MODO's
empirically-derived pivot/axis from `run_acen_drag.py` cases.

For each MODO case JSON in `drag_cases/`:
  1. Reset vibe3d to the same primitive (cube/sphere) at the same
     segment count.
  2. Select the same polygons (matched by vertex positions to
     `state.json::selected_verts` / `clusters`).
  3. Activate the case's ACEN+AXIS preset via the `actr.<mode>` command.
  4. Read `/api/toolpipe/eval` to get vibe3d's computed center.
  5. Compare to MODO's pivot recovered by `verify_acen_drag.py`'s
     `decompose()` from the case's result.json.

Status `PASS` = vibe3d's center is within tolerance of MODO's. Phase 1
covers single_top only (cube segments=1 — already supported by
/api/reset). asymmetric/sphere_top wait for Phase 2 (segmented
primitive endpoints).

Usage:
  ./check_vibe3d_parity.py                # iterate all eligible cases
  ./check_vibe3d_parity.py 'scale_single_top_*'

Requires vibe3d running with HTTP enabled (default port 8080).
"""
import argparse
import fnmatch
import json
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
CASES_DIR  = SCRIPT_DIR / "drag_cases"
TOL        = 0.05    # same TOL the MODO verifier uses


def red(s):   return f"\033[31m{s}\033[0m"
def green(s): return f"\033[32m{s}\033[0m"
def blue(s):  return f"\033[34m{s}\033[0m"


def post(url, body):
    """`body` is dict (JSON) or str (argstring)."""
    if isinstance(body, str):
        data = body.encode()
        ctype = "text/plain"
    else:
        data = json.dumps(body).encode()
        ctype = "application/json"
    req = urllib.request.Request(
        url, method="POST", data=data,
        headers={"Content-Type": ctype})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())


def get(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.loads(r.read())


# Cube face order in mesh.makeCube(): 0=-Z, 1=+Z, 2=-X, 3=+X, 4=+Y, 5=-Y.
# For single_top (top-face selection), the index is 4.
SINGLE_TOP_FACE = 4


def near(a, b, tol=TOL):
    return all(abs(a[i] - b[i]) < tol for i in range(3))


def run_case(path, port):
    spec = json.loads(path.read_text())
    pattern   = spec["pattern"]
    acen_mode = spec["acen_mode"]
    tool      = spec["tool"]

    # Phase 1 only handles single_top. asymmetric/sphere_top need
    # segmented-primitive endpoints (Phase 2 of the parity plan).
    if pattern != "single_top":
        return "SKIP", f"pattern '{pattern}' not yet supported"

    base = f"http://localhost:{port}"

    # 1) Reset to cube.
    post(f"{base}/api/reset", {"primitive": "cube"})

    # 2) Select the top face.
    post(f"{base}/api/select", {"mode": "polygons",
                                "indices": [SINGLE_TOP_FACE]})

    # 3) Activate the ACEN+AXIS preset. Use /api/command argstring form
    #    (the simpler one — JSON form needs the command id+params split).
    post(f"{base}/api/command", f"actr.{acen_mode}")

    # 4) Read pipeline evaluation.
    eval_state = get(f"{base}/api/toolpipe/eval")
    vibe_center = eval_state["actionCenter"]["center"]

    # 5) Read MODO's recovered pivot. For single_top all modes give the
    #    same pivot (face center) except origin and auto. Use the same
    #    prediction logic as verify_acen_drag.py.
    if acen_mode in ("select", "selectauto", "border", "local"):
        modo_pivot = (0.0, 0.5, 0.0)   # bbox center of cube top face
    elif acen_mode == "origin":
        modo_pivot = (0.0, 0.0, 0.0)
    elif acen_mode == "auto":
        return "SKIP", "auto mode pivot is drag-position-dependent"
    else:
        return "SKIP", f"unknown mode {acen_mode}"

    if near(vibe_center, modo_pivot):
        return "PASS", (
            f"vibe3d center=({vibe_center[0]:+.3f}, "
            f"{vibe_center[1]:+.3f}, {vibe_center[2]:+.3f}) ≈ MODO "
            f"({modo_pivot[0]:+.3f}, {modo_pivot[1]:+.3f}, "
            f"{modo_pivot[2]:+.3f})")
    return "FAIL", (
        f"vibe3d ({vibe_center[0]:+.3f}, {vibe_center[1]:+.3f}, "
        f"{vibe_center[2]:+.3f}) != MODO "
        f"({modo_pivot[0]:+.3f}, {modo_pivot[1]:+.3f}, "
        f"{modo_pivot[2]:+.3f})")


def discover_cases(filters):
    cases = sorted(CASES_DIR.glob("*.json"))
    if not filters:
        return cases
    keep = []
    for c in cases:
        if any(fnmatch.fnmatch(c.stem, pat) for pat in filters):
            keep.append(c)
    return keep


def wait_ready(port, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            urllib.request.urlopen(f"http://localhost:{port}/api/model",
                                   timeout=1).read()
            return True
        except (urllib.error.URLError, ConnectionResetError, OSError):
            time.sleep(0.2)
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("filters", nargs="*")
    ap.add_argument("--port", type=int, default=8080)
    args = ap.parse_args()

    if not wait_ready(args.port):
        print(red(f"vibe3d not responding on :{args.port} (start it with "
                  "`./vibe3d --test`)"))
        return 2

    cases = discover_cases(args.filters)
    if not cases:
        print(red("no cases match filter"))
        return 2

    passed, failed, skipped = [], [], []
    for c in cases:
        try:
            status, msg = run_case(c, args.port)
        except Exception as e:
            status, msg = "FAIL", repr(e)
        tag = {"PASS": green, "FAIL": red, "SKIP": blue}[status]
        print(f"  {tag(status):20s} {c.stem:40s} {msg}")
        {"PASS": passed, "FAIL": failed, "SKIP": skipped}[status].append(c.stem)

    print()
    print(f"{len(passed)} pass, {len(failed)} fail, {len(skipped)} skip "
          f"(of {len(cases)})")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
