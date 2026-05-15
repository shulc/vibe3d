#python
# Stage-1 probe for the taper deform: verify MODO's headless
# `xfrm.taper` + `tool.doApply` evaluates the falloff stage and
# scales by the requested factor. Unlike xfrm.twist (which routes
# through the broken `xfrm.rotate angle` headless path), the
# taper preset wires `xfrm.transform` and the SX/SY/SZ attrs are
# the same channel shear's TX/TY/TZ went through — those work
# headlessly (proven by probe_shear.py).
#
# Setup mirrors the other probes:
#   cube segmentsY=4, no selection, falloff.linear start=(0,+0.5,0)
#   end=(0,-0.5,0) shape=Linear. SX=2.0 → top row scales 2× along
#   X about ACEN (origin), bottom stays at original ±0.5.
#
# Per-row expected (origin pivot, X-axis scale by 1+(SX-1)·w):
#   y=-0.50 → no change         (X stays ±0.5)
#   y=-0.25 → 1.25× X           (X = ±0.625)
#   y= 0.0  → 1.5×  X           (X = ±0.75)
#   y=+0.25 → 1.75× X           (X = ±0.875)
#   y=+0.5  → 2.0×  X           (X = ±1.0)

import lx
import json
import traceback

args = list(lx.args())
if len(args) < 2:
    raise RuntimeError("probe_taper: expected <out_path> <log_path>")
OUT_PATH = args[0]
LOG_PATH = args[1]

LOG = open(LOG_PATH, "w")
def log(*a):
    LOG.write(" ".join(str(x) for x in a) + "\n")
    LOG.flush()

CONFIG = {
    "SX": 2.0,
    "falloff": {
        "type":  "linear",
        "shape": "linear",
        "start": [0.0,  0.5, 0.0],
        "end":   [0.0, -0.5, 0.0],
    },
}

try:
    log("--- probe_taper start ---")
    log("config:", CONFIG)

    lx.eval("scene.new")
    lx.eval('tool.set "prim.cube" on 0')
    for k, v in [("cenX", 0), ("cenY", 0), ("cenZ", 0),
                 ("sizeX", 1), ("sizeY", 1), ("sizeZ", 1),
                 ("segmentsX", 1), ("segmentsY", 4), ("segmentsZ", 1),
                 ("radius", 0)]:
        lx.eval('tool.attr prim.cube %s %g' % (k, v))
    lx.eval("tool.doApply")
    lx.eval('tool.set "prim.cube" off 0')
    log("cube created")

    lx.eval("select.typeFrom polygon")
    lx.eval("select.drop polygon")

    lx.eval('tool.set "xfrm.taper" on 0')
    log("xfrm.taper activated")

    f = CONFIG["falloff"]
    lx.eval('tool.attr "falloff.linear" startX %g' % f["start"][0])
    lx.eval('tool.attr "falloff.linear" startY %g' % f["start"][1])
    lx.eval('tool.attr "falloff.linear" startZ %g' % f["start"][2])
    lx.eval('tool.attr "falloff.linear" endX %g' % f["end"][0])
    lx.eval('tool.attr "falloff.linear" endY %g' % f["end"][1])
    lx.eval('tool.attr "falloff.linear" endZ %g' % f["end"][2])
    lx.eval('tool.attr "falloff.linear" shape 0')
    log("falloff handles pinned")

    # xfrm.transform SX — same channel that worked for shear's TX.
    # MODO 9 headless `xfrm.scale factor:N` documented as broken (pivots
    # at world origin regardless of ACEN); xfrm.transform SX takes the
    # ACEN center properly, per modo_dump.py's run_xfrm_translate doc.
    lx.eval('tool.attr "xfrm.transform" SX %g' % CONFIG["SX"])
    log("SX set to %g" % CONFIG["SX"])

    lx.eval("tool.doApply")
    lx.eval('tool.set "xfrm.taper" off 0')
    log("doApply done")

    import modo
    scene = modo.Scene()
    meshes = [m for m in scene.items("mesh") if len(m.geometry.vertices) > 0]
    if not meshes:
        raise RuntimeError("no non-empty mesh in scene")
    mesh = max(meshes, key=lambda m: len(m.geometry.vertices))
    verts = [list(v.position) for v in mesh.geometry.vertices]

    out = {
        "verts":   verts,
        "n_verts": len(verts),
        "config":  CONFIG,
    }
    with open(OUT_PATH, "w") as fh:
        json.dump(out, fh, indent=2)
    log("wrote", OUT_PATH, "n_verts=", len(verts))

except Exception:
    log("EXCEPTION:")
    log(traceback.format_exc())
finally:
    LOG.close()
