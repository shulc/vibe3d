#python
# Stage-1 probe for the twist deform: verify MODO's headless
# `xfrm.twist` + `tool.doApply` evaluates the falloff stage and
# rotates by the requested angle (NOT 2× the angle, the
# `xfrm.rotate` headless quirk documented in modo_dump.py's
# run_xfrm_rotate). The twist preset wires xfrm.transform under
# the hood — RY is set via tool.attr xfrm.transform RY <degrees>.
#
# Setup mirrors probe_shear.py:
#   cube segmentsY=4 → 5 vert rows along Y at y ∈ {-0.5, ..., 0.5}.
#   No selection — falloff weights drive the per-vertex contribution.
#
# Falloff: linear, start=(0, +0.5, 0), end=(0, -0.5, 0), shape=Linear.
#   weight=1 at top, weight=0 at bottom.
#
# Rotation: RY=30° around the world Y axis (default AXIS-stage
# orientation). Expected per-row Y-axis rotation:
#   y=-0.50 → 0°    (row stays put, X/Z unchanged)
#   y=-0.25 → 7.5°
#   y= 0.00 → 15°
#   y=+0.25 → 22.5°
#   y=+0.50 → 30°
#
# Each row's verts rotate around the world Y axis (passes through
# origin), so for row at height y the post-rotation X' / Z' are
#   X' = X·cosθ + Z·sinθ
#   Z' = -X·sinθ + Z·cosθ
# with θ = RY · weight(y).

import lx
import json
import math
import traceback

args = list(lx.args())
if len(args) < 2:
    raise RuntimeError("probe_twist: expected <out_path> <log_path>")
OUT_PATH = args[0]
LOG_PATH = args[1]

LOG = open(LOG_PATH, "w")
def log(*a):
    LOG.write(" ".join(str(x) for x in a) + "\n")
    LOG.flush()

CONFIG = {
    "RY": 30.0,
    "falloff": {
        "type":  "linear",
        "shape": "linear",
        "start": [0.0,  0.5, 0.0],
        "end":   [0.0, -0.5, 0.0],
    },
}

try:
    log("--- probe_twist start ---")
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

    lx.eval('tool.set "xfrm.twist" on 0')
    log("xfrm.twist activated")

    f = CONFIG["falloff"]
    lx.eval('tool.attr "falloff.linear" startX %g' % f["start"][0])
    lx.eval('tool.attr "falloff.linear" startY %g' % f["start"][1])
    lx.eval('tool.attr "falloff.linear" startZ %g' % f["start"][2])
    lx.eval('tool.attr "falloff.linear" endX %g' % f["end"][0])
    lx.eval('tool.attr "falloff.linear" endY %g' % f["end"][1])
    lx.eval('tool.attr "falloff.linear" endZ %g' % f["end"][2])
    lx.eval('tool.attr "falloff.linear" shape 0')
    log("falloff handles pinned")

    # xfrm.twist's preset wires `xfrm.rotate` (not xfrm.transform) per
    # MODO 9 resrc/presets.cfg — the attr is `angle`, not RY. Per
    # modo_dump.py's run_xfrm_rotate the headless `xfrm.rotate angle`
    # doApply produces 2× the requested angle (90 → 180); this probe
    # confirms whether the same quirk hits the preset path. If it
    # does, we either halve the angle here or skip MODO-side twist
    # entirely and source the reference rotation via direct vertex
    # math (run_rotate in modo_dump.py).
    lx.eval('tool.attr "xfrm.rotate" angle %g' % CONFIG["RY"])
    log("angle set to %g" % CONFIG["RY"])

    lx.eval("tool.doApply")
    lx.eval('tool.set "xfrm.twist" off 0')
    log("doApply done")

    import modo
    scene = modo.Scene()
    meshes = [m for m in scene.items("mesh") if len(m.geometry.vertices) > 0]
    if not meshes:
        raise RuntimeError("no non-empty mesh in scene")
    mesh = max(meshes, key=lambda m: len(m.geometry.vertices))
    verts = [list(v.position) for v in mesh.geometry.vertices]

    out = {
        "verts": verts,
        "n_verts": len(verts),
        "config": CONFIG,
    }
    with open(OUT_PATH, "w") as fh:
        json.dump(out, fh, indent=2)
    log("wrote", OUT_PATH, "n_verts=", len(verts))

except Exception:
    log("EXCEPTION:")
    log(traceback.format_exc())
finally:
    LOG.close()
