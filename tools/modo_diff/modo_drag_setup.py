#python
"""Setup: cube + select polygons matching pattern + activate ACEN.<mode>
+ xfrm.<tool>. Caller does real mouse drag to trigger ACEN evaluate.

Usage:
    @modo_drag_setup.py [acen_mode] [pattern] [tool]

acen_mode:  select (default), selectauto, auto, border, origin, local
pattern:    single_top (default) or asymmetric
tool:       scale (default) or move
"""
import lx
import modo
import json

args = lx.args()
acen_mode = args[0] if len(args) > 0 else "select"
pattern   = args[1] if len(args) > 1 else "single_top"
tool      = args[2] if len(args) > 2 else "scale"


def get_active_mesh():
    for itm in modo.Scene().iterItems("mesh"):
        return itm


# ---- pattern definitions: vertex-sets identifying each target polygon
def vset(*verts):
    return frozenset(verts)


PATTERNS = {
    "single_top": {
        "primitive": "cube",
        "segments":  1,
        "polys": [
            vset((-0.5, 0.5, -0.5), (0.5, 0.5, -0.5),
                 (0.5, 0.5,  0.5), (-0.5, 0.5,  0.5)),
        ],
    },
    "asymmetric": {
        "primitive": "cube",
        "segments":  2,
        "polys": [
            # top, -X, -Z corner
            vset((-0.5, 0.5, -0.5), (0.0, 0.5, -0.5),
                 (0.0, 0.5,  0.0), (-0.5, 0.5,  0.0)),
            # top, -X, +Z corner (adjacent — same cluster as above)
            vset((-0.5, 0.5,  0.0), (0.0, 0.5,  0.0),
                 (0.0, 0.5,  0.5), (-0.5, 0.5,  0.5)),
            # bottom, +X, +Z corner (disjoint — own cluster)
            vset((0.0, -0.5,  0.0), (0.5, -0.5,  0.0),
                 (0.5, -0.5,  0.5), (0.0, -0.5,  0.5)),
        ],
    },
    # Sphere top half: prim.sphere with default tessellation, then we
    # SELECT all faces whose centroid Y > 0 by walking the geometry at
    # runtime (no hardcoded vert table — sphere verts depend on segments).
    "sphere_top": {
        "primitive": "sphere",
        "segments":  1,
        "polys":     None,   # signals "select faces with centroid.y > 0"
    },
}

if pattern not in PATTERNS:
    lx.out("unknown pattern '%s', using single_top" % pattern)
    pattern = "single_top"
spec = PATTERNS[pattern]
primitive = spec["primitive"]
segments  = spec["segments"]
targets   = spec["polys"]


# ---- create the primitive via macro pattern with segments override
lx.eval("scene.new")
lx.eval('tool.set "prim.%s" on 0' % primitive)
lx.eval('tool.reset "prim.%s"' % primitive)
if primitive == "cube":
    lx.eval('tool.attr prim.cube segmentsX %d' % segments)
    lx.eval('tool.attr prim.cube segmentsY %d' % segments)
    lx.eval('tool.attr prim.cube segmentsZ %d' % segments)
lx.eval('tool.apply')
lx.eval('tool.set "prim.%s" off 0' % primitive)


# ---- enter polygon selection mode and pick all matching faces
lx.eval("select.typeFrom polygon")
lx.eval("select.drop polygon")

mesh = get_active_mesh()

def vert_set(p):
    """Return a frozenset of vertex positions, snapped to the same
    grid as PATTERNS so floating-point comparisons match."""
    out = []
    for v in p.vertices:
        x, y, z = v.position
        out.append((round(x, 4), round(y, 4), round(z, 4)))
    return frozenset(out)

def poly_centroid_y(p):
    ys = [v.position[1] for v in p.vertices]
    return sum(ys) / max(1, len(ys))

selected = 0
first = True
for p in mesh.geometry.polygons:
    pick = False
    if targets is None:
        # Runtime selection: pattern-specific. sphere_top → centroid.y > 0.
        if pattern == "sphere_top":
            pick = poly_centroid_y(p) > 0.001
    else:
        pick = vert_set(p) in targets
    if pick:
        p.select(replace=first)
        first = False
        selected += 1


# ---- activate ACEN.<mode> + xfrm.<tool>
lx.eval('tool.set "actr.%s" on 0' % acen_mode)
# `xfrm.rotate` exists but is mode-disabled headless; the
# `TransformRotate` tool preset wraps `xfrm.transform` with rotate-only
# attrs (T=0 R=1 S=0) and does respond to drag in the GUI.
if tool == "rotate":
    lx.eval('tool.set "TransformRotate" on 0')
else:
    lx.eval('tool.set "xfrm.%s" on 0' % tool)


# ---- dump initial state
verts = sorted([list(v.position) for v in mesh.geometry.vertices])
with open("/tmp/modo_drag_state.json", "w") as f:
    json.dump({
        "acen_mode": acen_mode,
        "pattern":   pattern,
        "tool":      tool,
        "segments":  segments,
        "selected":  selected,
        "before":    verts,
    }, f, indent=2)

target_count = len(targets) if targets is not None else -1
lx.out("setup: pattern=%s acen=%s tool=%s selected=%d/%d targets" %
       (pattern, acen_mode, tool, selected, target_count))
