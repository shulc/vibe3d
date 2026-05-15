#!/usr/bin/env python3
"""Stage-1 probe (vibe3d side) for the twist deform: drive vibe3d's
`xfrm.twist` preset via `tool.attr xfrm.twist RY 30 + tool.doApply`,
then verify against an ANALYTICAL reference (no MODO comparison —
MODO's headless xfrm.rotate doApply produces nonsense per a
documented quirk in modo_dump.py).

Reference math: each vert at world position (x, y, z) gets rotated
around the world Y axis through origin by  θ = RY · weight(y)
where weight = (y - end_y) / (start_y - end_y) clamped to [0,1].
With start=(0,+0.5,0) end=(0,-0.5,0) and RY=30°, the per-row
rotation is:
   y=-0.50 → 0°    y=-0.25 → 7.5°   y=0.0 → 15°
   y=+0.25 → 22.5°  y=+0.50 → 30°
Y stays put (rotation axis = Y), X and Z rotate as
   X' = X·cosθ + Z·sinθ
   Z' = -X·sinθ + Z·cosθ

PASS criterion: every vibe3d vert position matches the analytical
reference within EPS=1e-4.

Caller is responsible for spawning `vibe3d --test --http-port 8090`.
"""
import argparse
import json
import math
import sys
import urllib.request

CONFIG = {
    "RY": 30.0,
    "falloff": {
        "type":  "linear",
        "shape": "linear",
        "start": [0.0,  0.5, 0.0],
        "end":   [0.0, -0.5, 0.0],
    },
}


def http(port, path, body=""):
    url = "http://localhost:%d%s" % (port, path)
    req = urllib.request.Request(url, data=body.encode("utf-8"), method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read().decode("utf-8")


def get(port, path):
    url = "http://localhost:%d%s" % (port, path)
    with urllib.request.urlopen(url, timeout=10) as r:
        return r.read().decode("utf-8")


def cmd(port, argstring):
    raw = http(port, "/api/command", argstring)
    j = json.loads(raw)
    if j.get("status") != "ok":
        raise RuntimeError("cmd %r failed: %s" % (argstring, raw))


def vec3str(v):
    """Quoted comma-separated form for FalloffStage parseVec3."""
    return '"%g,%g,%g"' % (v[0], v[1], v[2])


def linear_weight(y, start_y, end_y):
    """Linear falloff: 1 at start, 0 at end, clamped outside."""
    span = start_y - end_y
    if abs(span) < 1e-9:
        return 0.0
    t = (y - end_y) / span
    return max(0.0, min(1.0, t))


def expected_vert(orig_x, orig_y, orig_z):
    w = linear_weight(orig_y, CONFIG["falloff"]["start"][1],
                              CONFIG["falloff"]["end"][1])
    theta = math.radians(CONFIG["RY"] * w)
    c, s = math.cos(theta), math.sin(theta)
    x_new = orig_x * c + orig_z * s
    z_new = -orig_x * s + orig_z * c
    return [x_new, orig_y, z_new]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out_path")
    ap.add_argument("--port", type=int, default=8090)
    args = ap.parse_args()
    port = args.port

    cmd(port, "scene.reset")
    cmd(port, "select.typeFrom polygon")
    cmd(port, "prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
              "segmentsX:1 segmentsY:4 segmentsZ:1 radius:0")

    # Capture the BEFORE positions so we can compute per-vert expected
    # outputs by rotating each original. Doing this against the live
    # mesh avoids hardcoding the cube's vert layout (which may shift
    # if vibe3d's prim.cube ever changes its emit order).
    before = json.loads(get(port, "/api/model"))["vertices"]
    before = [list(v) for v in before]

    cmd(port, "tool.set xfrm.twist on")
    f = CONFIG["falloff"]
    cmd(port, "tool.pipe.attr falloff start " + vec3str(f["start"]))
    cmd(port, "tool.pipe.attr falloff end "   + vec3str(f["end"]))
    cmd(port, "tool.pipe.attr falloff shape " + f["shape"])
    cmd(port, "tool.attr xfrm.twist RY %g" % CONFIG["RY"])
    cmd(port, "tool.doApply")

    after = json.loads(get(port, "/api/model"))["vertices"]
    after = [list(v) for v in after]

    EPS = 1e-4
    fails = 0
    for i, (orig, got) in enumerate(zip(before, after)):
        exp = expected_vert(*orig)
        d = max(abs(exp[k] - got[k]) for k in range(3))
        if d > EPS:
            fails += 1
            print(f"  vert {i:2d}: orig=({orig[0]:+.4f},{orig[1]:+.4f},{orig[2]:+.4f})  "
                  f"got=({got[0]:+.4f},{got[1]:+.4f},{got[2]:+.4f})  "
                  f"expected=({exp[0]:+.4f},{exp[1]:+.4f},{exp[2]:+.4f})  Δ={d:.6f}")

    out = {"verts": after, "n_verts": len(after), "config": CONFIG,
           "source": "vibe3d", "fails_vs_analytical": fails}
    with open(args.out_path, "w") as fh:
        json.dump(out, fh, indent=2)
    print("wrote %s n_verts=%d fails=%d" % (args.out_path, len(after), fails))
    sys.exit(0 if fails == 0 else 1)


if __name__ == "__main__":
    main()
