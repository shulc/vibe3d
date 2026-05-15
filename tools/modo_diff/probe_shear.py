#python
# Stage-1 probe for the Deform cross-engine diff plan: verify MODO's
# headless `xfrm.shear` + `tool.doApply` actually evaluates the
# attached falloff stage, OR if it just uniformly translates every
# vert by TX (the same headless-doesn't-evaluate-toolpipe quirk that
# bites ACEN — see modo_dump.py's run_xfrm_rotate docstring).
#
# We don't compare to vibe3d here — just dump MODO's output and
# eyeball whether the gradient is right. If MODO IS falloff-aware,
# we'll see top verts (y=+0.5) shifted by full TX in X, bottom verts
# (y=-0.5) untouched, and a monotonic ramp through the middle rows.
#
# Usage (caller runs modo_cl):
#   echo '@probe_shear.py /tmp/probe_shear.json /tmp/probe_shear.log
#   app.quit' | modo_cl
#
# Reads tmpdir path from positional @-args. Output JSON shape:
#   {
#     "verts": [[x,y,z], ...],   // post-shear positions
#     "n_verts": 60,
#     "config": { "TX": 0.5, "falloff": {...} }
#   }
#
# Geometry: prim.cube with segmentsY=4 → 5 vertex rows along Y at
# y ∈ {-0.5, -0.25, 0, 0.25, 0.5}. With falloff start=(0,+0.5,0)
# end=(0,-0.5,0) shape=Linear and TX=0.5, we expect each row's X
# offset to be:
#   y=+0.50 → +0.500   (weight 1.0)
#   y=+0.25 → +0.375   (weight 0.75)
#   y= 0.00 → +0.250   (weight 0.5)
#   y=-0.25 → +0.125   (weight 0.25)
#   y=-0.50 → +0.000   (weight 0.0)

import lx
import json
import traceback

args = list(lx.args())
if len(args) < 2:
    raise RuntimeError("probe_shear: expected <out_path> <log_path>")
OUT_PATH = args[0]
LOG_PATH = args[1]

LOG = open(LOG_PATH, "w")
def log(*a):
    LOG.write(" ".join(str(x) for x in a) + "\n")
    LOG.flush()

CONFIG = {
    "TX": 0.5,
    "falloff": {
        "type":  "linear",
        "shape": "linear",
        "start": [0.0,  0.5, 0.0],
        "end":   [0.0, -0.5, 0.0],
    },
}

try:
    log("--- probe_shear start ---")
    log("config:", CONFIG)

    # Geometry: segmented cube. segmentsY=4 gives the 5-row Y gradient.
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

    # No selection -- xfrm.move with falloff should weight the whole mesh.
    # (Selecting all polygons would also work; empty selection is the
    # cleaner test of "falloff drives which verts move", since selection
    # masking is a separate concern.)
    lx.eval("select.typeFrom polygon")
    lx.eval("select.drop polygon")

    # Activate the preset. presets.cfg pulls in falloff.linear + xfrm.transform.
    lx.eval('tool.set "xfrm.shear" on 0')
    log("xfrm.shear activated")

    # Pin the falloff handles explicitly (disables auto-fit-to-bbox).
    f = CONFIG["falloff"]
    lx.eval('tool.attr "falloff.linear" startX %g' % f["start"][0])
    lx.eval('tool.attr "falloff.linear" startY %g' % f["start"][1])
    lx.eval('tool.attr "falloff.linear" startZ %g' % f["start"][2])
    lx.eval('tool.attr "falloff.linear" endX %g' % f["end"][0])
    lx.eval('tool.attr "falloff.linear" endY %g' % f["end"][1])
    lx.eval('tool.attr "falloff.linear" endZ %g' % f["end"][2])
    lx.eval('tool.attr "falloff.linear" shape 0')   # 0 = Linear
    log("falloff handles pinned")

    # Set the numeric translate magnitude on xfrm.transform.
    # xfrm.shear's preset wires xfrm.transform with TX/TY/TZ at 0; we
    # just override TX. (TY/TZ stay 0 from the preset baseline.)
    lx.eval('tool.attr "xfrm.transform" TX %g' % CONFIG["TX"])
    log("TX set to %g" % CONFIG["TX"])

    lx.eval("tool.doApply")
    lx.eval('tool.set "xfrm.shear" off 0')
    log("doApply done")

    # Dump verts.
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
    with open(OUT_PATH, "w") as f:
        json.dump(out, f, indent=2)
    log("wrote", OUT_PATH, "n_verts=", len(verts))

except Exception:
    log("EXCEPTION:")
    log(traceback.format_exc())
finally:
    LOG.close()
