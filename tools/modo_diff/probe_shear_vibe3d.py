#!/usr/bin/env python3
"""Stage-1 probe (vibe3d side): replicate the MODO shear probe through
vibe3d's HTTP API and dump verts in the same JSON shape as
probe_shear.py. Caller pairs the two outputs and computes per-vertex
distance.

Caller is responsible for spawning `vibe3d --test --http-port <port>`
beforehand. Defaults to port 8090 (matches what `run_test.d --port
8090` uses to dodge the user's own dev instance on 8080).

Usage:
    python3 probe_shear_vibe3d.py <out_path> [--port 8090]

The case is hard-coded to match probe_shear.py exactly:
    cube segmentsY=4, no selection, falloff.linear start=(0,+0.5,0)
    end=(0,-0.5,0) shape=Linear, TX=0.5.
"""
import argparse
import json
import sys
import urllib.request

CONFIG = {
    "TX": 0.5,
    "falloff": {
        "type":  "linear",
        "shape": "linear",
        "start": [0.0,  0.5, 0.0],
        "end":   [0.0, -0.5, 0.0],
    },
}


def http(port, path, body=""):
    """POST `body` to vibe3d's HTTP API; return the parsed JSON response.
    /api/command and /api/select POSTs return a small JSON envelope with
    a `status` field — callers should check status == "ok"."""
    url = "http://localhost:%d%s" % (port, path)
    req = urllib.request.Request(url, data=body.encode("utf-8"),
                                 method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read().decode("utf-8")


def get(port, path):
    url = "http://localhost:%d%s" % (port, path)
    with urllib.request.urlopen(url, timeout=10) as r:
        return r.read().decode("utf-8")


def cmd(port, argstring):
    """Run a vibe3d command via /api/command argstring form. Raises if
    the response status isn't `ok` so quirks surface immediately."""
    raw = http(port, "/api/command", argstring)
    j = json.loads(raw)
    if j.get("status") != "ok":
        raise RuntimeError("cmd %r failed: %s" % (argstring, raw))


def vec3str(v):
    """Pack a 3-vector into the comma-separated form FalloffStage's
    setAttr (`case "start"`, `case "end"`, ...) parses via parseVec3.
    Wrapped in double quotes — vibe3d's argstring parser only accepts
    barewords [a-zA-Z0-9_./-], so the comma in the vec3 literal forces
    the value through the quoted-string branch."""
    return '"%g,%g,%g"' % (v[0], v[1], v[2])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out_path")
    ap.add_argument("--port", type=int, default=8090)
    args = ap.parse_args()
    port = args.port
    out_path = args.out_path

    # Reset, switch to polygon mode (xfrm.shear is selection-aware; we
    # don't select anything but the mode controls which API code paths
    # honour selectedFaces vs falling back to the whole mesh).
    cmd(port, "scene.reset")
    cmd(port, "select.typeFrom polygon")

    # Geometry: prim.cube with segmentsY=4 — matches the MODO probe's
    # tessellation so per-row Y values align bit-for-bit.
    cmd(port, "prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
              "segmentsX:1 segmentsY:4 segmentsZ:1 radius:0")

    # Activate the deform preset. tool_presets.yaml wires this as
    # base=move + falloff.type=linear + falloff.shape=linear.
    cmd(port, "tool.set xfrm.shear on")

    # Pin the falloff handles. Setting `start` / `end` after the auto-fit
    # ran during `tool.set` overrides them — there's no separate
    # auto/manual flag in FalloffStage (just the field values).
    f = CONFIG["falloff"]
    cmd(port, "tool.pipe.attr falloff start " + vec3str(f["start"]))
    cmd(port, "tool.pipe.attr falloff end "   + vec3str(f["end"]))
    cmd(port, "tool.pipe.attr falloff shape " + f["shape"])

    # Numeric translate via the new MoveTool TX/TY/TZ attrs.
    cmd(port, "tool.attr xfrm.shear TX %g" % CONFIG["TX"])

    # Headless apply — wraps applyHeadless() in a snapshot pair.
    cmd(port, "tool.doApply")

    # Dump verts in the same shape as probe_shear.py. /api/model
    # returns vertices as [[x,y,z], ...].
    model = json.loads(get(port, "/api/model"))
    verts = [list(v) for v in model["vertices"]]
    out = {
        "verts":   verts,
        "n_verts": len(verts),
        "config":  CONFIG,
        "source":  "vibe3d",
    }
    with open(out_path, "w") as fh:
        json.dump(out, fh, indent=2)
    print("wrote %s n_verts=%d" % (out_path, len(verts)))


if __name__ == "__main__":
    main()
