#python
"""Activate a Falloff stage in MODO's toolpipe with explicit endpoint
attrs and patch the per-worker `modo_drag_state.json` so the verifier
can compute per-vertex weights.

Called by run_acen_drag.py AFTER modo_drag_setup.py has built the
geometry/selection/ACEN/transform-tool stack but BEFORE the actual
mouse drag. MODO's slot system places `falloff.<type>` into the WGHT
slot regardless of activation order, so it correctly evaluates ahead
of `xfrm.<tool>` at drag time.

Usage (linear):
    @modo_falloff_setup.py <tmpdir> linear <sx> <sy> <sz> <ex> <ey> <ez> \\
                           [shape] [p0] [p1]
Usage (radial):
    @modo_falloff_setup.py <tmpdir> radial <cx> <cy> <cz> <sx> <sy> <sz> \\
                           [shape] [p0] [p1]

`shape` is one of: linear, easeIn, easeOut, smooth, custom (default
linear). `p0` / `p1` are the Custom shape tangent params (in/out, both
default 0.0). MODO encodes shape as an integer 0..4 matching the order
linear / easeIn / easeOut / smooth / custom (see resrc/cmdhelptools
.cfg's `falloff-shape` ArgumentType — same order vibe3d's
FalloffShape enum uses).

Setting endpoint / center / size attrs implicitly disables MODO's
auto-position-by-selection-bbox; toggling the `auto` attr explicitly
BEFORE those attrs leaves the tool in a pending interactive-drag
state that hangs subsequent `lx.eval` calls (observed in MODO 9
headless).
"""
import lx
import json

SHAPE_INT = {
    "linear":  0,
    "easeIn":  1,
    "easeOut": 2,
    "smooth":  3,
    "custom":  4,
}

args = list(lx.args())
if len(args) < 8:
    lx.out("modo_falloff_setup: expected >=8 args, got %d" % len(args))
else:
    tmpdir = args[0]
    ftype  = args[1]
    # arg slots 2..7 are interpreted per type:
    #   linear: startX, startY, startZ, endX, endY, endZ
    #   radial: cenX,   cenY,   cenZ,   sizX, sizY, sizZ
    a      = [float(args[2]), float(args[3]), float(args[4])]
    b      = [float(args[5]), float(args[6]), float(args[7])]
    shape  = args[8] if len(args) > 8 else "linear"
    p0     = float(args[9])  if len(args) > 9  else 0.0
    p1     = float(args[10]) if len(args) > 10 else 0.0

    state_extra = {}
    if ftype == "linear":
        start, end = a, b
        lx.eval('tool.set "falloff.linear" on 0')
        lx.eval('tool.attr "falloff.linear" startX %f' % start[0])
        lx.eval('tool.attr "falloff.linear" startY %f' % start[1])
        lx.eval('tool.attr "falloff.linear" startZ %f' % start[2])
        lx.eval('tool.attr "falloff.linear" endX %f' % end[0])
        lx.eval('tool.attr "falloff.linear" endY %f' % end[1])
        lx.eval('tool.attr "falloff.linear" endZ %f' % end[2])
        lx.eval('tool.attr "falloff.linear" shape %d'
                % SHAPE_INT.get(shape, 0))
        if shape == "custom":
            lx.eval('tool.attr "falloff.linear" p0 %f' % p0)
            lx.eval('tool.attr "falloff.linear" p1 %f' % p1)
        state_extra = {"start": start, "end": end}
    elif ftype == "radial":
        center, size = a, b
        lx.eval('tool.set "falloff.radial" on 0')
        lx.eval('tool.attr "falloff.radial" cenX %f' % center[0])
        lx.eval('tool.attr "falloff.radial" cenY %f' % center[1])
        lx.eval('tool.attr "falloff.radial" cenZ %f' % center[2])
        lx.eval('tool.attr "falloff.radial" sizX %f' % size[0])
        lx.eval('tool.attr "falloff.radial" sizY %f' % size[1])
        lx.eval('tool.attr "falloff.radial" sizZ %f' % size[2])
        lx.eval('tool.attr "falloff.radial" shape %d'
                % SHAPE_INT.get(shape, 0))
        if shape == "custom":
            lx.eval('tool.attr "falloff.radial" p0 %f' % p0)
            lx.eval('tool.attr "falloff.radial" p1 %f' % p1)
        state_extra = {"center": center, "size": size}
    else:
        lx.out("modo_falloff_setup: unknown falloff type '%s'" % ftype)

    # `p0`/`p1` are the Custom shape's tangent params and are hidden
    # in MODO's UI when shape != custom; setting them via tool.attr
    # in that state hangs lx.eval (headless MODO 9). The conditional
    # `if shape == "custom"` blocks above guard against that.

    state_path = tmpdir + "/modo_drag_state.json"
    try:
        with open(state_path) as f:
            state = json.load(f)
        falloff_state = {
            "type":  ftype,
            "shape": shape,
            "in":    p0,
            "out":   p1,
        }
        falloff_state.update(state_extra)
        state["falloff"] = falloff_state
        with open(state_path, "w") as f:
            json.dump(state, f, indent=2)
        lx.out("modo_falloff_setup: %s shape=%s a=%s b=%s in=%g out=%g"
               % (ftype, shape, a, b, p0, p1))
    except Exception as e:
        lx.out("modo_falloff_setup: state.json patch failed: %r" % e)

    # Sentinel: orchestrator waits on this to detect that the script
    # actually ran (falloff activation has no observable side-effect on
    # `before` verts; if the script silently failed the downstream drag
    # would still appear to "work" with weight=1 everywhere, producing
    # a false-positive PASS).
    try:
        with open(tmpdir + "/modo_falloff.done", "w") as f:
            f.write("ok")
    except Exception:
        pass
