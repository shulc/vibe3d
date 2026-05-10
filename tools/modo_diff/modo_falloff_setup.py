#python
"""Activate a Falloff stage in MODO's toolpipe with explicit endpoint
attrs and patch the per-worker `modo_drag_state.json` so the verifier
can compute per-vertex weights.

Called by run_acen_drag.py AFTER modo_drag_setup.py has built the
geometry/selection/ACEN/transform-tool stack but BEFORE the actual
mouse drag. MODO's slot system places `falloff.<type>` into the WGHT
slot regardless of activation order, so it correctly evaluates ahead
of `xfrm.<tool>` at drag time.

Usage:
    @modo_falloff_setup.py <tmpdir> linear <sx> <sy> <sz> <ex> <ey> <ez> \\
                           [shape] [p0] [p1]

`shape` is one of: linear, easeIn, easeOut, smooth, custom (default
linear). `p0` / `p1` are the Custom shape tangent params (in/out, both
default 0.0). MODO encodes shape as an integer 0..4 matching the order
linear / easeIn / easeOut / smooth / custom (see resrc/cmdhelptools
.cfg's `falloff-shape` ArgumentType — same order vibe3d's
FalloffShape enum uses).

Setting `startX/Y/Z` and `endX/Y/Z` implicitly disables MODO's
auto-position-by-selection-bbox; toggling the `auto` attr explicitly
BEFORE start/end leaves the tool in a pending interactive-drag state
that hangs subsequent `lx.eval` calls (observed in MODO 9 headless).
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
    start  = [float(args[2]), float(args[3]), float(args[4])]
    end    = [float(args[5]), float(args[6]), float(args[7])]
    shape  = args[8] if len(args) > 8 else "linear"
    p0     = float(args[9])  if len(args) > 9  else 0.0
    p1     = float(args[10]) if len(args) > 10 else 0.0

    if ftype == "linear":
        lx.eval('tool.set "falloff.linear" on 0')
        lx.eval('tool.attr "falloff.linear" startX %f' % start[0])
        lx.eval('tool.attr "falloff.linear" startY %f' % start[1])
        lx.eval('tool.attr "falloff.linear" startZ %f' % start[2])
        lx.eval('tool.attr "falloff.linear" endX %f' % end[0])
        lx.eval('tool.attr "falloff.linear" endY %f' % end[1])
        lx.eval('tool.attr "falloff.linear" endZ %f' % end[2])
        lx.eval('tool.attr "falloff.linear" shape %d'
                % SHAPE_INT.get(shape, 0))
        # `p0`/`p1` are the Custom shape's tangent params and are
        # hidden in MODO's UI when shape != custom; setting them via
        # tool.attr in that state hangs lx.eval (headless MODO 9).
        # Skip them entirely for non-custom shapes.
        if shape == "custom":
            lx.eval('tool.attr "falloff.linear" p0 %f' % p0)
            lx.eval('tool.attr "falloff.linear" p1 %f' % p1)
    else:
        lx.out("modo_falloff_setup: unknown falloff type '%s'" % ftype)

    state_path = tmpdir + "/modo_drag_state.json"
    try:
        with open(state_path) as f:
            state = json.load(f)
        state["falloff"] = {
            "type":  ftype,
            "start": start,
            "end":   end,
            "shape": shape,
            "in":    p0,
            "out":   p1,
        }
        with open(state_path, "w") as f:
            json.dump(state, f, indent=2)
        lx.out("modo_falloff_setup: %s shape=%s start=%s end=%s in=%g out=%g"
               % (ftype, shape, start, end, p0, p1))
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
