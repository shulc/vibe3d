#python
"""Setup: cube + select polygons matching pattern + activate ACEN.<mode>
+ xfrm.<tool>. Caller does real mouse drag to trigger ACEN evaluate.

Usage:
    @modo_drag_setup.py [tmpdir] [acen_mode] [pattern] [tool]

tmpdir:     output dir for state.json (default /tmp)
acen_mode:  select (default), selectauto, auto, border, origin, local
pattern:    single_top (default) or asymmetric
tool:       scale (default) or move

Per-worker isolation: pass a unique tmpdir (e.g. /tmp/worker_3) so
parallel MODO instances don't clash on state.json.
"""
import lx
import modo
import json

args = list(lx.args())
# Optional first arg is a tmpdir starting with `/`; otherwise legacy
# 3-arg form (acen_mode, pattern, tool).
tmpdir = "/tmp"
if args and args[0].startswith("/"):
    tmpdir = args.pop(0)
acen_mode = args[0] if len(args) > 0 else "select"
pattern   = args[1] if len(args) > 1 else "single_top"
tool      = args[2] if len(args) > 2 else "scale"
state_path = tmpdir + "/modo_drag_state.json"


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

# Pick polygons matching the pattern. Track BOTH the selected
# polygons (for cluster computation) and the unique vertex positions
# they expose (so the verifier can identify the selection from
# state.json without re-deriving it from PATTERN_POLYS at runtime —
# matters for `sphere_top` whose verts depend on segments and aren't
# hardcoded).
selected_polys = []
first = True
for p in mesh.geometry.polygons:
    pick = False
    if targets is None:
        if pattern == "sphere_top":
            pick = poly_centroid_y(p) > 0.001
    else:
        pick = vert_set(p) in targets
    if pick:
        p.select(replace=first)
        first = False
        selected_polys.append(p)
selected = len(selected_polys)

# Per-poly vert sets, for cluster grouping by shared edges (matches
# vibe3d's computeLocalFaceClustersFull algorithm).
poly_vsets = []
for p in selected_polys:
    poly_vsets.append([(round(v.position[0], 4),
                        round(v.position[1], 4),
                        round(v.position[2], 4)) for v in p.vertices])

# Union-find over selected polygons connected via shared edges.
n_polys = len(poly_vsets)
parent = list(range(n_polys))
def _find(i):
    while parent[i] != i:
        parent[i] = parent[parent[i]]
        i = parent[i]
    return i
def _union(i, j):
    a, b = _find(i), _find(j)
    if a != b: parent[a] = b
def _share_edge(a, b):
    sa = poly_vsets[a]
    sb = poly_vsets[b]
    for i in range(len(sa)):
        e0a = sa[i]; e1a = sa[(i + 1) % len(sa)]
        for j in range(len(sb)):
            e0b = sb[j]; e1b = sb[(j + 1) % len(sb)]
            if (e0a == e0b and e1a == e1b) or (e0a == e1b and e1a == e0b):
                return True
    return False
for i in range(n_polys):
    for j in range(i + 1, n_polys):
        if _share_edge(i, j):
            _union(i, j)

# Group polys by cluster id; the cluster's verts are the union of its
# polys' verts.
cluster_map = {}    # root -> [poly indices]
for i in range(n_polys):
    cluster_map.setdefault(_find(i), []).append(i)
clusters = []   # list of unique sorted vert-position lists, one per cluster
for poly_indices in cluster_map.values():
    cluster_verts = set()
    for pi in poly_indices:
        for v in poly_vsets[pi]:
            cluster_verts.add(v)
    clusters.append(sorted(cluster_verts))

# Flat selected-vert list (union of all clusters).
selected_verts_set = set()
for c in clusters:
    selected_verts_set.update(c)
selected_verts = sorted(selected_verts_set)

# Border verts: ON an edge that bounds the selection. An edge is a
# border edge if exactly ONE of its two adjacent polygons is selected.
# Identify selected polys by their vertex-position set (poly_vsets is
# already populated above as a list of vertex tuples per selected poly).
selected_vset_keys = set(frozenset(vs) for vs in poly_vsets)
edge_count = {}      # canonical edge -> count of selected polys adjacent
edge_count_total = {}# canonical edge -> total count of polys adjacent
for q in mesh.geometry.polygons:
    qvs = [(round(v.position[0], 4), round(v.position[1], 4),
            round(v.position[2], 4)) for v in q.vertices]
    is_selected = frozenset(qvs) in selected_vset_keys
    for j in range(len(qvs)):
        a = qvs[j]; b = qvs[(j + 1) % len(qvs)]
        e = (a, b) if a < b else (b, a)
        edge_count_total[e] = edge_count_total.get(e, 0) + 1
        if is_selected:
            edge_count[e] = edge_count.get(e, 0) + 1
border_verts_set = set()
for e, sel_n in edge_count.items():
    tot = edge_count_total[e]
    # Exactly one selected neighbour, AND the edge is not "open" (only
    # one polygon adjacent total) — open edges count as border too.
    if sel_n == 1 and tot >= 1 and tot - sel_n >= 1 or sel_n == 1 and tot == 1:
        border_verts_set.add(e[0]); border_verts_set.add(e[1])
border_verts = sorted(border_verts_set)


# ---- read camera + viewport via View3Dport.View(Current()) →
# View3D cast. View3Dport.View() is undocumented in the Python dump
# (Pixel-Fondue/modo-api) but exists at runtime; cast the returned
# Unknown to lx.object.View3D.
#
# Used by the cross-engine parity test to drive vibe3d through the
# SAME camera MODO is using, so screen-pixel drags produce equivalent
# world-space results.
#
# We do NOT dump To3D(drag_x, drag_y, ...) here — its flag/coord
# convention isn't documented and the values returned don't match
# MODO's empirical actr.auto pivot. See memory note
# `modo_view3d_python_api.md` for the discovery + caveat.
camera = None
try:
    _vp  = lx.service.View3Dport()
    _v3d = lx.object.View3D(_vp.View(_vp.Current()))
    bnd  = _v3d.Bounds()              # (x, y, w, h) viewport pixels
    cen  = _v3d.Center()              # focus point
    ev   = _v3d.EyeVector()           # (distance, focus, fwd)
    dist = float(ev[0]); fpos = ev[1]; fwd = ev[2]
    eye  = (fpos[0] - fwd[0] * dist,
            fpos[1] - fwd[1] * dist,
            fpos[2] - fwd[2] * dist)
    drag_x = float(args[3]) if len(args) > 3 else 1020.0
    drag_y = float(args[4]) if len(args) > 4 else 560.0
    camera = {
        "bounds":   [int(bnd[0]), int(bnd[1]), int(bnd[2]), int(bnd[3])],
        "center":   [float(cen[0]), float(cen[1]), float(cen[2])],
        "eye":      [eye[0], eye[1], eye[2]],
        "fwd":      [float(fwd[0]), float(fwd[1]), float(fwd[2])],
        "distance": dist,
        "drag":     [drag_x, drag_y],
    }
except Exception as _e:
    camera = {"error": repr(_e)}

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
with open(state_path, "w") as f:
    json.dump({
        "acen_mode":      acen_mode,
        "pattern":        pattern,
        "tool":           tool,
        "segments":       segments,
        "selected":       selected,
        "before":         verts,
        # Verifier reads these instead of falling back to PATTERN_POLYS,
        # so runtime-selection patterns (sphere_top) get the same full
        # invariant check as hardcoded ones.
        "selected_verts": [list(v) for v in selected_verts],
        "clusters":       [[list(v) for v in c] for c in clusters],
        "border_verts":   [list(v) for v in border_verts],
        "camera":         camera,
    }, f, indent=2)

target_count = len(targets) if targets is not None else -1
lx.out("setup: pattern=%s acen=%s tool=%s selected=%d/%d targets, "
       "%d cluster(s)" %
       (pattern, acen_mode, tool, selected, target_count, len(clusters)))
