#!/usr/bin/env python3
"""Stage-1 probe (vibe3d side) for the taper deform: drive vibe3d's
`xfrm.taper` preset via `tool.attr xfrm.taper SX 2.0 + tool.doApply`,
dump verts in the same JSON shape as probe_taper.py.

Caller pairs the two outputs and verifies position-set parity (just
like the shear probe). The taper preset routes through MODO's
`xfrm.transform` channel — the same one shear uses — so SX/SY/SZ
DO work headlessly (probe_taper.py confirmed it).

Caller is responsible for spawning `vibe3d --test --http-port 8090`.
"""
import argparse
import json
import sys
import urllib.request

CONFIG = {
    "SX": 2.0,
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
    return '"%g,%g,%g"' % (v[0], v[1], v[2])


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

    cmd(port, "tool.set xfrm.taper on")
    f = CONFIG["falloff"]
    cmd(port, "tool.pipe.attr falloff start " + vec3str(f["start"]))
    cmd(port, "tool.pipe.attr falloff end "   + vec3str(f["end"]))
    cmd(port, "tool.pipe.attr falloff shape " + f["shape"])
    cmd(port, "tool.attr xfrm.taper SX %g" % CONFIG["SX"])
    cmd(port, "tool.doApply")

    model = json.loads(get(port, "/api/model"))
    verts = [list(v) for v in model["vertices"]]
    out = {"verts": verts, "n_verts": len(verts), "config": CONFIG,
           "source": "vibe3d"}
    with open(args.out_path, "w") as fh:
        json.dump(out, fh, indent=2)
    print("wrote %s n_verts=%d" % (args.out_path, len(verts)))


if __name__ == "__main__":
    main()
