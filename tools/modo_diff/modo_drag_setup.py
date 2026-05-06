#python
"""Setup: cube + select polygons matching pattern + activate ACEN.<mode>
+ xfrm.scale. Caller does real mouse drag to trigger ACEN evaluate.

Usage:
    @modo_drag_setup.py [acen_mode] [pattern]

acen_mode:  select (default), selectauto, auto, border, origin, local
pattern:    single_top (default) or asymmetric

Patterns:
    single_top  — unit cube, select the y=+0.5 face (4 verts).
                  All ACEN modes resolve to the top centroid (0, 0.5, 0)
                  except origin / auto.
    asymmetric  — 2x2x2-segment cube, select two adjacent top polygons
                  (-X half of top face: -X-Z corner + -X+Z corner) and
                  one disjoint bottom polygon (+X+Z corner). This gives
                  two non-adjacent clusters whose centroids differ from
                  the combined selection centroid AND from the bbox
                  center, so Select / Border / Local diverge.
"""
import lx
import modo
import json

args = lx.args()
acen_mode = args[0] if len(args) > 0 else "select"
pattern   = args[1] if len(args) > 1 else "single_top"


def get_active_mesh():
    for itm in modo.Scene().iterItems("mesh"):
        return itm


# ---- pattern definitions: vertex-sets identifying each target polygon
def vset(*verts):
    return frozenset(verts)


PATTERNS = {
    "single_top": {
        "segments": 1,
        "polys": [
            vset((-0.5, 0.5, -0.5), (0.5, 0.5, -0.5),
                 (0.5, 0.5,  0.5), (-0.5, 0.5,  0.5)),
        ],
    },
    "asymmetric": {
        "segments": 2,
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
}

if pattern not in PATTERNS:
    lx.out("unknown pattern '%s', using single_top" % pattern)
    pattern = "single_top"
spec = PATTERNS[pattern]
segments = spec["segments"]
targets  = spec["polys"]


# ---- create the cube via Unit Cube macro pattern, with segments override
lx.eval("scene.new")
lx.eval('tool.set "prim.cube" on 0')
lx.eval('tool.reset "prim.cube"')
lx.eval('tool.attr prim.cube segmentsX %d' % segments)
lx.eval('tool.attr prim.cube segmentsY %d' % segments)
lx.eval('tool.attr prim.cube segmentsZ %d' % segments)
lx.eval('tool.apply')
lx.eval('tool.set "prim.cube" off 0')


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

selected = 0
first = True
for p in mesh.geometry.polygons:
    if vert_set(p) in targets:
        p.select(replace=first)
        first = False
        selected += 1


# ---- activate ACEN.<mode> + xfrm.scale
lx.eval('tool.set "actr.%s" on 0' % acen_mode)
lx.eval('tool.set "xfrm.scale" on 0')


# ---- dump initial state
verts = sorted([list(v.position) for v in mesh.geometry.vertices])
with open("/tmp/modo_drag_state.json", "w") as f:
    json.dump({
        "acen_mode": acen_mode,
        "pattern":   pattern,
        "segments":  segments,
        "selected":  selected,
        "before":    verts,
    }, f, indent=2)

lx.out("setup: pattern=%s acen=%s selected=%d/%d targets" %
       (pattern, acen_mode, selected, len(targets)))
