#python
# Apply a comparison case to MODO and dump the resulting geometry to JSON.
#
# Usage (called by run.d, not directly by user). Two argument paths:
#
#   1. Positional via @ args (preferred, single MODO session reusable):
#       @modo_dump.py /path/to/case.json /path/to/out.json /path/to/log
#      — chosen because lx.args() rebinds per @ invocation, so a long-
#      lived modo_cl can run many cases via repeated @-loads from stdin
#      (see tools/modo_diff/run.d's worker pool). Each call gets its own
#      fresh paths without restarting MODO.
#
#   2. Environment fallback (legacy single-shot):
#       MODO_CASE_PATH=/path/to/case.json
#       MODO_OUT_PATH=/path/to/out.json
#       MODO_LOG_PATH=/path/to/log
#       echo '@modo_dump.py
#       app.quit' | modo_cl
#
# Schema of case.json: same as blender_diff (see blender_dump.py / vibe3d_dump.d).
# Currently supported ops: polygon_bevel.
#
# MODO 902 quirks:
#   - Selection via lx.eval('select.element ...') silently no-ops in modo_cl
#     headless mode. Use modo.Polygon.select() (Python API) instead.
#   - poly.bevel is a TOOL, not a command. Activate via tool.set, set attrs,
#     then tool.doApply.
#   - The cube primitive tool is `prim.cube` (not `unitcube`).

import lx
import modo
import json
import os
import sys
import traceback

EPS = 1e-4

# `lx.args()` returns positionals from the @ invocation. Three-arg form
# wins; otherwise fall back to the legacy env vars.
_args = list(lx.args())
if len(_args) >= 3:
    CASE_PATH = _args[0]
    OUT_PATH  = _args[1]
    LOG_PATH  = _args[2]
else:
    CASE_PATH = os.environ.get("MODO_CASE_PATH", "")
    OUT_PATH  = os.environ.get("MODO_OUT_PATH",  "")
    LOG_PATH  = os.environ.get("MODO_LOG_PATH",  "/tmp/modo_dump.log")

LOG = open(LOG_PATH, "w")
def log(*args):
    LOG.write(" ".join(str(a) for a in args) + "\n")
    LOG.flush()


def vmatch(a, b):
    return all(abs(a[i] - b[i]) < EPS for i in range(3))


def find_polygon(mesh, target_verts):
    """Find a polygon whose vertex set matches target_verts (any order)."""
    for p in mesh.geometry.polygons:
        if len(p.vertices) != len(target_verts):
            continue
        coords = [tuple(v.position) for v in p.vertices]
        used = [False] * len(target_verts)
        ok = True
        for c in coords:
            found = False
            for j, t in enumerate(target_verts):
                if used[j]:
                    continue
                if vmatch(c, t):
                    used[j] = True
                    found = True
                    break
            if not found:
                ok = False
                break
        if ok:
            return p
    raise RuntimeError("polygon not found with verts %s" % (target_verts,))


def reset_cube():
    """Reset to a single-mesh scene with a unit cube at origin.

    MODO's prim.cube tool caches its previous attributes between sessions
    (~/.luxology/.modo902rc <ToolCache key="prim.cube">). If a prior run
    set radius>0, the next default activation would produce a rounded
    cube (~248 verts, not 8). We explicitly set radius=0 + segmentsX/Y/Z=1
    to be defensive against any cached state."""
    lx.eval("scene.new")
    lx.eval('tool.set "prim.cube" on 0')
    lx.eval('tool.attr prim.cube cenX 0.0')
    lx.eval('tool.attr prim.cube cenY 0.0')
    lx.eval('tool.attr prim.cube cenZ 0.0')
    lx.eval('tool.attr prim.cube sizeX 1.0')
    lx.eval('tool.attr prim.cube sizeY 1.0')
    lx.eval('tool.attr prim.cube sizeZ 1.0')
    lx.eval('tool.attr prim.cube segmentsX 1')
    lx.eval('tool.attr prim.cube segmentsY 1')
    lx.eval('tool.attr prim.cube segmentsZ 1')
    lx.eval('tool.attr prim.cube radius 0.0')
    lx.eval("tool.doApply")
    lx.eval('tool.set "prim.cube" off 0')


def get_active_mesh():
    """Pick the largest non-empty mesh in the scene. The first time this
    runs (before any op) it's the freshly created cube with 8 verts; after
    a delete/remove op, the cube may have shrunk (e.g. delete-vertex
    leaves 7), so don't filter on a hard >=8 threshold — just take the
    biggest one and call it the working mesh."""
    scene = modo.Scene()
    meshes = [m for m in scene.items("mesh") if len(m.geometry.vertices) > 0]
    if not meshes:
        raise RuntimeError("no non-empty mesh in scene")
    biggest = max(meshes, key=lambda m: len(m.geometry.vertices))
    biggest.select(replace=True)
    return biggest


def run_move_vertex(op):
    mesh = get_active_mesh()
    src = tuple(op["from"])
    dst = tuple(op["to"])
    for v in mesh.geometry.vertices:
        if vmatch(tuple(v.position), src):
            v.position = list(dst)
            return
    raise RuntimeError("move_vertex: no vert at %s" % (src,))


def run_polygon_bevel(op):
    mesh = get_active_mesh()
    inset = float(op["insert"])
    shift = float(op["shift"])
    group = bool(op.get("group", False))

    # Match faces by their vertex coordinates. Process them in JSON listing
    # order (= selection order) so group mode's first-face-wins matches
    # vibe3d / blender_dump.
    polys = []
    for fdef in op["faces"]:
        target = [tuple(v) for v in fdef]
        polys.append(find_polygon(mesh, target))

    # Selection mode = polygon, drop any prior selection, then select all
    # target polygons. MODO 9's modo.Polygon.select() defaults to additive
    # (no kwarg) — only the first call clears prior selection via
    # replace=True; subsequent .select() calls add.
    lx.eval("select.typeFrom polygon")
    lx.eval("select.drop polygon")
    for i, p in enumerate(polys):
        if i == 0:
            p.select(replace=True)
        else:
            p.select()
    log("selected polys:", lx.eval("query layerservice polys ? selected"))

    # Activate poly.bevel, set attrs, apply.
    lx.eval("tool.set poly.bevel on 0")
    lx.eval("tool.attr poly.bevel inset %f" % inset)
    lx.eval("tool.attr poly.bevel shift %f" % shift)
    lx.eval("tool.attr poly.bevel group %d" % (1 if group else 0))
    lx.eval("tool.doApply")
    lx.eval("tool.set poly.bevel off 0")


def find_vertex(mesh, target):
    """Find a vertex whose position matches `target` (within EPS)."""
    for v in mesh.geometry.vertices:
        if vmatch(tuple(v.position), tuple(target)):
            return v
    raise RuntimeError("vertex not found at %s" % (target,))


def select_edge_by_endpoints(mesh, v0, v1):
    """Select the edge between verts at coords v0 and v1. modo_cl headless
    forbids iterating mesh.geometry.edges (the "fire and forget" Python
    interpreter can't poll edge IDs); instead we select the two endpoint
    verts and convert to edge selection — since a unique edge connects
    any two distinct cube verts that share one, this picks exactly the
    desired edge."""
    va = find_vertex(mesh, v0)
    vb = find_vertex(mesh, v1)
    lx.eval("select.typeFrom vertex")
    lx.eval("select.drop vertex")
    va.select(replace=True)
    vb.select()
    lx.eval("select.convert edge")


def run_delete_or_remove(op, kind):
    """Execute MODO's Delete (`select.delete`) or Remove
    (`vert.remove` / `edge.remove false` / `poly.remove`) command on a
    coord-specified selection. `kind` is "delete" or "remove" — Remove
    dispatches to a per-mode command. Component selection mode is set
    per the case's `mode` field; selection is dropped first to avoid
    mode-leakage from prior ops."""
    mesh = get_active_mesh()
    mode = op["mode"]
    if mode == "polygons":
        lx.eval("select.typeFrom polygon")
        lx.eval("select.drop polygon")
        polys = []
        for fdef in op["faces"]:
            target = [tuple(v) for v in fdef]
            polys.append(find_polygon(mesh, target))
        for i, p in enumerate(polys):
            if i == 0:
                p.select(replace=True)
            else:
                p.select()
    elif mode == "edges":
        # modo_cl forbids iterating mesh.geometry.edges in headless mode,
        # so edge selection goes through vertex-set + select.convert edge:
        # collect every edge endpoint, select those verts, convert to
        # edges. This selects exactly the edges joining any two of the
        # chosen verts. Cases must be authored so the only such edges are
        # the desired ones (no spurious "diagonal" edges between picked
        # verts).
        lx.eval("select.typeFrom vertex")
        lx.eval("select.drop vertex")
        seen = []
        for spec in op["edges"]:
            for ep in (spec["v0"], spec["v1"]):
                key = tuple(round(c, 6) for c in ep)
                if key in seen:
                    continue
                seen.append(key)
                v = find_vertex(mesh, ep)
                if len(seen) == 1:
                    v.select(replace=True)
                else:
                    v.select()
        lx.eval("select.convert edge")
    elif mode == "vertices":
        lx.eval("select.typeFrom vertex")
        lx.eval("select.drop vertex")
        verts = [find_vertex(mesh, v) for v in op["vertices"]]
        for i, v in enumerate(verts):
            if i == 0:
                v.select(replace=True)
            else:
                v.select()
    else:
        raise NotImplementedError("delete/remove mode: %s" % mode)

    if kind == "delete":
        lx.eval("select.delete")
    elif kind == "remove":
        if mode == "polygons":
            lx.eval("poly.remove")
        elif mode == "edges":
            # `edge.remove false`: the second arg is a boolean for "force"
            # / "keep" depending on MODO version. False = standard remove
            # (dissolve edge, merge faces).
            lx.eval("edge.remove false")
        elif mode == "vertices":
            lx.eval("vert.remove")
    else:
        raise NotImplementedError("delete/remove kind: %s" % kind)

    # Verified empirically (query layerservice {verts,edges,polys} ?
    # selected all return None after delete/remove): MODO clears the
    # entire selection across every component type. vibe3d's
    # deleteFacesByMask + removeEdgesByMask do the same — no extra
    # parity work needed.


def run_vert_merge(op):
    """vert.merge — collects the case's `vertices` (coord list), selects
    them, and runs MODO's vert.merge with the same `range`/`dist`/`keep`
    arguments the case specifies."""
    mesh = get_active_mesh()
    lx.eval("select.typeFrom vertex")
    lx.eval("select.drop vertex")
    for i, vc in enumerate(op["vertices"]):
        v = find_vertex(mesh, vc)
        if i == 0: v.select(replace=True)
        else:      v.select()
    range_  = op.get("range", "auto")
    dist    = float(op.get("dist", 0.001))
    keep    = bool(op.get("keep", False))
    lx.eval("vert.merge range:%s dist:%f keep:%s" %
            (range_, dist, "true" if keep else "false"))


def run_vert_join(op):
    """vert.join — same selection scheme, MODO command honors `average`
    and `keep`."""
    mesh = get_active_mesh()
    lx.eval("select.typeFrom vertex")
    lx.eval("select.drop vertex")
    for i, vc in enumerate(op["vertices"]):
        v = find_vertex(mesh, vc)
        if i == 0: v.select(replace=True)
        else:      v.select()
    avg  = bool(op.get("average", True))
    keep = bool(op.get("keep", False))
    lx.eval("vert.join average:%s keep:%s" %
            ("true" if avg else "false", "true" if keep else "false"))


def select_all_polygons():
    """Switch to polygon mode and select every polygon. Used as the
    pre-step for `rotate` / `scale` ops, which act on the current
    selection.

    `select.all` returns 84800005 in modo_cl headless after a fresh
    prim.cube — the polygons aren't recognised as selectable until the
    selection is explicitly built. Iterate the mesh's polygons and
    select each one (matches the run_polygon_bevel pattern)."""
    mesh = get_active_mesh()
    lx.eval("select.typeFrom polygon")
    lx.eval("select.drop polygon")
    polys = list(mesh.geometry.polygons)
    if not polys:
        raise RuntimeError("select_all_polygons: mesh has no polygons")
    for i, p in enumerate(polys):
        if i == 0:
            p.select(replace=True)
        else:
            p.select()


def axis_label_to_attr(label):
    """Map "X"|"Y"|"Z" to the per-axis tool attribute name MODO's
    TransformRotate / TransformScale exposes."""
    if label in ("X", "x"): return "X"
    if label in ("Y", "y"): return "Y"
    if label in ("Z", "z"): return "Z"
    raise RuntimeError("axis must be X/Y/Z, got '%s'" % label)


def run_rotate(op):
    """Rotate every vertex of the active mesh by `angle` degrees around
    `axis` (X/Y/Z), pivoting at `pivot` (default origin).

    Bypasses MODO's transform-tool composition (xfrm.rotate +
    actr.origin) — those tool attribute names diverge between
    versions and require fiddly Action Center setup. Instead apply
    the rotation matrix directly to mesh.geometry.vertices, which
    matches what vibe3d's MeshTransform does internally and gives
    bit-for-bit comparable results."""
    import math
    mesh = get_active_mesh()
    angle_deg = float(op["angle"])
    axis      = op["axis"]
    pivot     = op.get("pivot", [0.0, 0.0, 0.0])
    a = math.radians(angle_deg)
    ca, sa = math.cos(a), math.sin(a)
    if axis in ("X", "x"):
        def rot(v):
            x, y, z = v[0]-pivot[0], v[1]-pivot[1], v[2]-pivot[2]
            return [x + pivot[0],
                    ca*y - sa*z + pivot[1],
                    sa*y + ca*z + pivot[2]]
    elif axis in ("Y", "y"):
        def rot(v):
            x, y, z = v[0]-pivot[0], v[1]-pivot[1], v[2]-pivot[2]
            return [ ca*x + sa*z + pivot[0],
                     y + pivot[1],
                    -sa*x + ca*z + pivot[2]]
    elif axis in ("Z", "z"):
        def rot(v):
            x, y, z = v[0]-pivot[0], v[1]-pivot[1], v[2]-pivot[2]
            return [ca*x - sa*y + pivot[0],
                    sa*x + ca*y + pivot[1],
                    z + pivot[2]]
    else:
        raise RuntimeError("axis must be X/Y/Z, got '%s'" % axis)
    for v in mesh.geometry.vertices:
        v.position = rot(list(v.position))


def run_scale(op):
    """Scale every vertex by [fx, fy, fz], pivoting at `pivot`. Direct
    matrix application — same rationale as run_rotate."""
    mesh = get_active_mesh()
    f = op["factor"]
    pivot = op.get("pivot", [0.0, 0.0, 0.0])
    fx, fy, fz = float(f[0]), float(f[1]), float(f[2])
    for v in mesh.geometry.vertices:
        p = list(v.position)
        v.position = [pivot[0] + (p[0]-pivot[0]) * fx,
                      pivot[1] + (p[1]-pivot[1]) * fy,
                      pivot[2] + (p[2]-pivot[2]) * fz]


def run_select_face(op):
    """Pick a single polygon by listing its vertex coordinates (in any
    order). Sets edit mode to polygon."""
    mesh = get_active_mesh()
    target = [tuple(v) for v in op["face"]]
    poly = find_polygon(mesh, target)
    lx.eval("select.typeFrom polygon")
    lx.eval("select.drop polygon")
    poly.select(replace=True)


def run_workplane_align(_op):
    """MODO doc menu entry "Align Work Plane to Selection" maps to the
    `workPlane.fitSelect` command (note camelCase). This snaps the
    workplane: Y = polygon normal, Z = longest edge for a single-poly
    selection (per workplane.html)."""
    lx.eval("workPlane.fitSelect")


def run_prim_cube(op):
    """`prim.cube` argstring as an op (separate from setup, which is
    one-shot at case start). Runs through the same tool.set/attr/apply
    flow as setup so the active workplane is honoured."""
    params = op.get("params", {})
    lx.eval('tool.set "prim.cube" on 0')
    for k, v in params.items():
        if isinstance(v, bool):
            lx.eval('tool.attr prim.cube %s %s' % (k, "true" if v else "false"))
        elif isinstance(v, (int, float)):
            lx.eval('tool.attr prim.cube %s %g' % (k, v))
        else:
            lx.eval('tool.attr prim.cube %s "%s"' % (k, v))
    lx.eval("tool.doApply")
    lx.eval('tool.set "prim.cube" off 0')


def run_op(op):
    kind = op["op"]
    if kind == "polygon_bevel":
        run_polygon_bevel(op)
    elif kind == "move_vertex":
        run_move_vertex(op)
    elif kind == "delete" or kind == "remove":
        run_delete_or_remove(op, kind)
    elif kind == "vert.merge":
        run_vert_merge(op)
    elif kind == "vert.join":
        run_vert_join(op)
    elif kind == "rotate":
        run_rotate(op)
    elif kind == "scale":
        run_scale(op)
    elif kind == "select_face":
        run_select_face(op)
    elif kind == "workplane_align":
        run_workplane_align(op)
    elif kind == "prim_cube":
        run_prim_cube(op)
    elif kind == "query_acen":
        run_query_acen(op)
    elif kind == "query_axis":
        run_query_axis(op)
    elif kind == "actr_set":
        run_actr_set(op)
    elif kind == "xfrm_translate":
        run_xfrm_translate(op)
    elif kind == "xfrm_rotate":
        run_xfrm_rotate(op)
    elif kind == "deform":
        run_deform(op)
    else:
        raise NotImplementedError("modo_dump: unsupported op '%s'" % kind)


# ---------------------------------------------------------------------------
# Deform op — drives a soft-deform preset (xfrm.shear / xfrm.twist /
# xfrm.taper / softMove / etc.) headlessly. Mirrors the standalone
# tools/modo_diff/probe_*.py scripts but lifted into the orchestrator.
#
# Op schema:
#   { "op": "deform",
#     "preset": "xfrm.shear",
#     "modo_method": "tool" | "analytical"   // default "tool"
#     "falloff": { "type": "linear" | "radial",
#                  "shape": "linear" | "smooth" | ...,
#                  "start": [x,y,z], "end": [x,y,z]    // linear
#                  "center": [x,y,z], "size": [x,y,z]  // radial
#                },
#     "transform": { "TX": 0.5, ... }   // attr name → value, applied to
#                                       //  xfrm.transform (or xfrm.rotate
#                                       //  for twist's modo_method=tool)
#   }
#
# `modo_method`:
#   - "tool"       : `tool.set <preset> on; tool.attr ...; tool.doApply`.
#                    Works for shear (TX/TY/TZ) and taper (SX/SY/SZ) per
#                    probe_shear.py / probe_taper.py.
#   - "analytical" : compute the deformed verts in pure Python (per-vert
#                    falloff weight × transform formula). Used for twist,
#                    where MODO 9's headless `xfrm.rotate angle` doApply
#                    produces nonsense (per-vert Y values shift off the
#                    original rows; documented in probe_twist.py and
#                    run_xfrm_rotate above).
# ---------------------------------------------------------------------------

SHAPE_INT = {
    "linear":  0,
    "easeIn":  1,
    "easeOut": 2,
    "smooth":  3,
    "custom":  4,
}


def _set_falloff_handles_modo(ftype, fall):
    """Pin the falloff stage's handle attrs explicitly. Setting start /
    end (linear) or center / size (radial) AFTER the preset's tool.set
    triggered auto-fit overrides the cached values — there's no
    separate auto/manual flag in MODO 9."""
    if ftype == "linear":
        s, e = fall["start"], fall["end"]
        for ax, v in zip(("X", "Y", "Z"), s):
            lx.eval('tool.attr "falloff.linear" start%s %g' % (ax, v))
        for ax, v in zip(("X", "Y", "Z"), e):
            lx.eval('tool.attr "falloff.linear" end%s %g' % (ax, v))
        lx.eval('tool.attr "falloff.linear" shape %d'
                % SHAPE_INT.get(fall.get("shape", "linear"), 0))
    elif ftype == "radial":
        c, sz = fall["center"], fall["size"]
        for ax, v in zip(("X", "Y", "Z"), c):
            lx.eval('tool.attr "falloff.radial" cen%s %g' % (ax, v))
        for ax, v in zip(("X", "Y", "Z"), sz):
            lx.eval('tool.attr "falloff.radial" siz%s %g' % (ax, v))
        lx.eval('tool.attr "falloff.radial" shape %d'
                % SHAPE_INT.get(fall.get("shape", "linear"), 0))
    else:
        raise NotImplementedError("deform falloff type '%s'" % ftype)


def _falloff_weight(fall, vert):
    """Per-vertex falloff weight ∈ [0, 1]. Mirrors source/falloff.d's
    linearWeight / radialWeight for shape=linear (1−t between bounds).
    Non-linear shapes (smooth / easeIn / ...) aren't applied yet —
    extend with the cubic Bezier from source/falloff.d's applyShape
    when an analytical case needs them."""
    import math as _math
    ftype = fall["type"]
    shape = fall.get("shape", "linear")
    if shape != "linear":
        raise NotImplementedError(
            "analytical deform: only shape=linear supported (got %s). "
            "Add the curve-shape post-processing to _falloff_weight if "
            "a non-linear analytical case ever comes up." % shape)
    if ftype == "linear":
        s, e = fall["start"], fall["end"]
        # Project (vert - e) onto (s - e) and clamp t ∈ [0, 1].
        dx, dy, dz = s[0]-e[0], s[1]-e[1], s[2]-e[2]
        denom = dx*dx + dy*dy + dz*dz
        if denom < 1e-18:
            return 0.0
        vx, vy, vz = vert[0]-e[0], vert[1]-e[1], vert[2]-e[2]
        t = (vx*dx + vy*dy + vz*dz) / denom
        if t < 0: return 0.0
        if t > 1: return 1.0
        return t
    if ftype == "radial":
        # Mirror radialWeight in source/falloff.d: t = ‖(pos − center) /
        # size‖. Per-axis size component ≤ 0 collapses that axis out of
        # the sum (degenerate ellipsoid is "full influence everywhere").
        center, size = fall["center"], fall["size"]
        d = [vert[i] - center[i] for i in range(3)]
        sum_, any_ = 0.0, False
        for i in range(3):
            if size[i] > 1e-9:
                u = d[i] / size[i]
                sum_ += u * u
                any_ = True
        if not any_:
            return 1.0
        t = _math.sqrt(sum_)
        if t <= 0.0: return 1.0
        if t >= 1.0: return 0.0
        return 1.0 - t
    if ftype == "cylinder":
        # Mirror cylinderWeight in source/falloff.d: perpendicular
        # distance from the cylinder axis through `center`, normalised
        # by max(size.x, size.y, size.z). Axis defaults to (0, 1, 0)
        # if absent.
        center = fall["center"]
        size   = fall["size"]
        axis   = fall.get("axis", [0.0, 1.0, 0.0])
        al2 = axis[0]*axis[0] + axis[1]*axis[1] + axis[2]*axis[2]
        if al2 < 1e-12:
            # Fall back to radial when the axis is degenerate.
            return _falloff_weight({"type": "radial", "shape": "linear",
                                    "center": center, "size": size}, vert)
        ai = 1.0 / _math.sqrt(al2)
        ax = [axis[0]*ai, axis[1]*ai, axis[2]*ai]
        d  = [vert[i] - center[i] for i in range(3)]
        along = d[0]*ax[0] + d[1]*ax[1] + d[2]*ax[2]
        perp  = [d[i] - ax[i]*along for i in range(3)]
        plen  = _math.sqrt(perp[0]*perp[0] + perp[1]*perp[1] + perp[2]*perp[2])
        r = max(size[0], size[1], size[2])
        if r <= 1e-9: return 1.0
        t = plen / r
        if t <= 0.0: return 1.0
        if t >= 1.0: return 0.0
        return 1.0 - t
    raise NotImplementedError(
        "analytical deform: falloff type '%s'" % ftype)


def _apply_deform_analytical_python(op):
    """Compute the deformed verts in Python and write them into MODO's
    mesh.geometry directly. Used when MODO's headless tool.doApply path
    is broken for the preset (twist today). Pivot is taken to be the
    origin (matches actr.auto / actr.origin on a centered cube; non-
    centered cases will need a `pivot` field)."""
    import math as _math
    mesh = get_active_mesh()
    fall = op["falloff"]
    xform = op.get("transform", {})

    rx = float(xform.get("RX", 0.0))
    ry = float(xform.get("RY", 0.0))
    rz = float(xform.get("RZ", 0.0))
    tx = float(xform.get("TX", 0.0))
    ty = float(xform.get("TY", 0.0))
    tz = float(xform.get("TZ", 0.0))
    sx = float(xform.get("SX", 1.0))
    sy = float(xform.get("SY", 1.0))
    sz = float(xform.get("SZ", 1.0))

    pivot = op.get("pivot", [0.0, 0.0, 0.0])

    for v in mesh.geometry.vertices:
        p = list(v.position)
        w = _falloff_weight(fall, p)
        # Translate (weight × delta).
        x = p[0] + tx * w
        y = p[1] + ty * w
        z = p[2] + tz * w
        # Rotate (angle × weight, around basis axes through pivot).
        # Order: X then Y then Z (matches RotateTool.applyHeadless).
        for axis_deg, axis in ((rx, "x"), (ry, "y"), (rz, "z")):
            if axis_deg == 0:
                continue
            theta = _math.radians(axis_deg * w)
            c, s = _math.cos(theta), _math.sin(theta)
            dx, dy, dz = x - pivot[0], y - pivot[1], z - pivot[2]
            if axis == "x":
                ny =  c*dy - s*dz
                nz =  s*dy + c*dz
                y, z = pivot[1] + ny, pivot[2] + nz
            elif axis == "y":
                nx =  c*dx + s*dz
                nz = -s*dx + c*dz
                x, z = pivot[0] + nx, pivot[2] + nz
            else:
                nx =  c*dx - s*dy
                ny =  s*dx + c*dy
                x, y = pivot[0] + nx, pivot[1] + ny
        # Scale (per-axis factor blended toward 1 by weight, around pivot).
        wsx = 1.0 + (sx - 1.0) * w
        wsy = 1.0 + (sy - 1.0) * w
        wsz = 1.0 + (sz - 1.0) * w
        x = pivot[0] + (x - pivot[0]) * wsx
        y = pivot[1] + (y - pivot[1]) * wsy
        z = pivot[2] + (z - pivot[2]) * wsz
        v.position = [x, y, z]


def run_deform(op):
    """Apply a soft-deform preset to MODO. Dispatches on `modo_method`."""
    method = op.get("modo_method", "tool")
    preset = op["preset"]
    if method == "analytical":
        log("deform [analytical]:", preset)
        _apply_deform_analytical_python(op)
        return
    if method != "tool":
        raise NotImplementedError("deform modo_method '%s'" % method)
    log("deform [tool]:", preset)

    # Switch to polygon mode + drop any prior selection. Without this,
    # MODO 9 headless `tool.doApply` for a soft-deform preset silently
    # no-ops (verified with shear/taper — the verts come out untouched).
    # Verified by tools/modo_diff/probe_shear.py: this exact pair was
    # the difference between a working probe and one that returned an
    # unmodified cube. Cases that need a specific selection should add
    # a select_face / preops block AFTER this (the emptied selection
    # gets repopulated).
    lx.eval("select.typeFrom polygon")
    lx.eval("select.drop polygon")

    # Activate the preset — wires falloff.<type> into the WGHT slot and
    # xfrm.transform / xfrm.rotate into the ACTR slot per resrc/presets.cfg.
    lx.eval('tool.set "%s" on 0' % preset)

    fall = op.get("falloff")
    if fall is not None:
        _set_falloff_handles_modo(fall["type"], fall)

    # Pick the right transform-tool id for this preset. xfrm.shear /
    # xfrm.taper / xfrm.softMove etc. wire xfrm.transform; xfrm.twist /
    # xfrm.swirl / xfrm.bulge / xfrm.softRotate wire xfrm.rotate; ...
    # The case JSON can override via op["modo_xfrm_tool"].
    XFRM_TOOL = op.get("modo_xfrm_tool", "xfrm.transform")
    for k, v in (op.get("transform") or {}).items():
        lx.eval('tool.attr "%s" %s %g' % (XFRM_TOOL, k, float(v)))

    lx.eval("tool.doApply")
    lx.eval('tool.set "%s" off 0' % preset)


def run_actr_set(op):
    """Activate `actr.<preset>` — combined ACEN + AXIS preset (MODO
    `cmdhelptools.cfg`'s actr.auto / actr.select / actr.element / ...).
    """
    preset = op["preset"]
    lx.eval('tool.set "actr.%s" on 0' % preset)

def run_xfrm_translate(op):
    """Apply MODO's `xfrm.move` (the canonical translate tool — not
    `xfrm.translate`, which doesn't exist). Attrs are `X`/`Y`/`Z`
    (capitalised, not `offX/offY/offZ`). `axis` selects which handle
    in the action-axis basis to translate along; selected geometry
    moves by `dist` units along that direction.
    """
    axis = op.get("axis", "x").lower()
    dist = float(op["dist"])
    lx.eval('tool.set "xfrm.move" on 0')
    attr_map = {"x": "X", "y": "Y", "z": "Z"}
    # Zero out the other two so leftover state from a previous case
    # doesn't bleed in.
    for a in ("X", "Y", "Z"):
        lx.eval('tool.attr xfrm.move %s 0' % a)
    lx.eval('tool.attr xfrm.move %s %g' % (attr_map[axis], dist))
    lx.eval('tool.doApply')
    lx.eval('tool.set "xfrm.move" off 0')

def run_xfrm_rotate(op):
    """Apply MODO's `xfrm.rotate`. **Known unreliable headlessly** —
    keep around for completeness but DO NOT rely on this for ACEN /
    AXIS cross-check. Investigation summary (2026-05):

      - `tool.attr xfrm.rotate angle 90; tool.doApply` rotates by
        180°, not 90°. Pattern: actual_rotation = angle + 90°. Likely
        because `doApply` simulates a drag whose start handle was
        never set (`startX/Y/Z` attrs are mode-disabled headlessly,
        only enabled when the "Advanced Handles" GUI mode is on).

      - `xfrm.transform RX/RY/RZ` are also mode-gated; headless
        `tool.attr xfrm.transform RX 90` errors out as "Command
        disabled".

      - `xfrm.scale factor:2` does work but uses pivot (0,0,0) for
        ANY selection — modo_cl's tool-pipe stages
        (`actr.select` / `center.select` / `axis.select`) don't
        compute selection-derived center / axis in headless mode.
        Selection is recognised for which-verts-move (xfrm.move only
        translates the selected face) but the LXpToolActionCenter
        packet is never populated by the live evaluate.

    Net: rotate-based ACEN / AXIS cross-check via tool composition is
    not reliable headlessly. Verified 2026-05 that the same limitation
    applies to FULL MODO GUI run under Xvfb (with -cmd:'@<script>'
    invocation) — `xfrm.scale factor:2` with actr.select on a selected
    face still pivots at world (0, 0, 0), not at the face centroid.
    Conclusion: MODO's ACEN/AXIS stages only evaluate during a live
    mouse-drag via the event translator path; `tool.doApply` bypasses
    that and reads the default action-center packet (= world origin).
    This is an architectural MODO design choice, not a headless quirk.

    Workaround paths considered (all deferred):
      - Record an interactive MODO event log and replay it. Verified
        2026-05 that MODO has NO mouse-event recording — its `.lxm`
        macros (via `macro.record` / `macro.runFile`) only capture
        command sequences (`tool.set X on; tool.attr Y Z; tool.apply`)
        which replay identically to direct command invocation, so
        same ACEN limitation. No `event.replay` / `event.simulate`
        / `pointer.move` / `tool.simulateDrag` / `cmds.executeHaul`
        in cmdhelp.cfg.
      - Drive MODO under Xvfb via xdotool mouse simulation (requires
        viewport projection math, gizmo screen positions — fragile).
      - Apply rotation via direct vertex math after reading ACEN /
        AXIS from a separate GUI-only export (no headless API for
        that today).

    Also tried 2026-05: `tool.apply` (the user-facing apply) instead
    of `tool.doApply` (the internal Post Mode). MODO docs distinguish
    them but the result is identical — both produce pivot=(0,0,0)
    even under full GUI MODO with Xvfb display.
    """
    angle_deg = float(op["angle"])
    lx.eval('tool.set "xfrm.rotate" on 0')
    lx.eval('tool.attr xfrm.rotate angle %g' % angle_deg)
    lx.eval('tool.doApply')
    lx.eval('tool.set "xfrm.rotate" off 0')


# Phase 7.2h: scalar query results accumulated across the case's ops.
# Both modo_dump and vibe3d_dump build the same dict shape; diff.py
# compares scalar-by-scalar.
QUERIES = {}

def _query_tool_attr(tool_id, attr):
    """Try the MODO query forms in order until one returns a number;
    otherwise NaN. modo_cl's `?` syntax varies across versions:
    - `tool.attr <tool> <attr> ?` (trailing-? query mode)
    - `?tool.attr <tool> <attr>` (lx.eval return-value prefix)
    - `query toolservice attrvalue ? <tool> <attr>`
    """
    forms = [
        '?tool.attr %s %s ?' % (tool_id, attr),
        '?tool.attr %s %s' % (tool_id, attr),
        'query toolservice attrvalue ? %s %s' % (tool_id, attr),
    ]
    last_err = None
    for f in forms:
        try:
            r = lx.eval(f)
            if r is None:
                continue
            return float(r)
        except Exception as e:
            last_err = e
    log("query: all forms failed for %s %s: %s" % (tool_id, attr, last_err))
    return float("nan")

def run_query_acen(op):
    """Activate `center.<mode>` tool, dump cen{X,Y,Z} into QUERIES under
    the keys `actionCenter.<mode>.{cenX,cenY,cenZ}`. Selection-driven
    modes (select / element / local / border) require a prior
    `select_face` op in the same case.
    """
    mode = op["mode"]
    lx.eval('tool.set "center.%s" on 0' % mode)
    tool_id = "center.%s" % mode
    for ax in ("cenX", "cenY", "cenZ"):
        QUERIES["actionCenter.%s.%s" % (mode, ax)] = _query_tool_attr(tool_id, ax)
    # Mode is also recorded so the comparison can fail loudly if vibe3d
    # ends up in a different mode.
    QUERIES["actionCenter.%s.mode" % mode] = mode

def run_query_axis(op):
    """Same shape as run_query_acen, for `axis.<mode>` tool's
    axisX/Y/Z attrs. Records them under `axis.<mode>.<key>`."""
    mode = op["mode"]
    lx.eval('tool.set "axis.%s" on 0' % mode)
    tool_id = "axis.%s" % mode
    for ax in ("axisX", "axisY", "axisZ"):
        QUERIES["axis.%s.%s" % (mode, ax)] = _query_tool_attr(tool_id, ax)


def dump_mesh(out_path):
    mesh = get_active_mesh()
    verts = [list(v.position) for v in mesh.geometry.vertices]
    faces = []
    for p in mesh.geometry.polygons:
        faces.append([v.index for v in p.vertices])
    out = {
        "vertexCount": len(verts),
        "faceCount":   len(faces),
        "vertices":    verts,
        "faces":       faces,
        "source":      "modo",
    }
    if QUERIES:
        out["queries"] = QUERIES
    with open(out_path, "w") as f:
        json.dump(out, f, indent=2)
    log("wrote", out_path, ":", len(verts), "verts,", len(faces), "faces")


def main():
    if not CASE_PATH or not OUT_PATH:
        log("ERROR: MODO_CASE_PATH / MODO_OUT_PATH not set")
        return
    log("case:", CASE_PATH, "-> out:", OUT_PATH)
    with open(CASE_PATH) as f:
        case = json.load(f)

    setup = case.get("setup")
    if setup is not None:
        # setup block takes precedence over `primitive` field.
        kind = setup.get("kind")
        if kind == "primitive":
            # Start from an empty scene and build the primitive via MODO tool commands.
            lx.eval("scene.new")
            tool = setup["tool"]
            params = setup.get("params", {})
            lx.eval('tool.set "%s" on 0' % tool)
            # MODO 902 ships Python 2.x where dict iteration order is
            # arbitrary. Some attributes (notably `method` / `axis`) gate
            # the validity of others, so we always send `method` first when
            # present, then everything else. ToolCache from a prior session
            # can also leave the tool in an unexpected mode (e.g. qball
            # disables `axis`); putting `method` first heals that.
            ordered_keys = (["method"] if "method" in params else []) \
                + [k for k in params if k != "method"]
            for k in ordered_keys:
                v = params[k]
                if isinstance(v, bool):
                    cmd = 'tool.attr %s %s %s' % (tool, k, "true" if v else "false")
                elif isinstance(v, (int, float)):
                    cmd = 'tool.attr %s %s %g' % (tool, k, v)
                else:
                    cmd = 'tool.attr %s %s "%s"' % (tool, k, v)
                log("attr:", cmd)
                lx.eval(cmd)
            lx.eval("tool.doApply")
            lx.eval('tool.set "%s" off 0' % tool)
        else:
            raise NotImplementedError("modo_dump: unsupported setup kind '%s'" % kind)
        # Future: kind == "lwo" → load from file; "macro" → run script; etc.
    else:
        # Legacy path: use `primitive` field (default: cube).
        primitive = case.get("primitive", "cube")
        if primitive != "cube":
            raise NotImplementedError("modo_dump: only 'cube' primitive supported")
        reset_cube()

    for op in case.get("preops", []):
        log("preop:", op["op"])
        run_op(op)
    for op in case["ops"]:
        log("op:", op["op"])
        run_op(op)

    dump_mesh(OUT_PATH)


try:
    main()
except Exception:
    log("EXCEPTION:")
    log(traceback.format_exc())
finally:
    LOG.close()
    # NB: don't `app.quit` here — `tools/modo_diff/run.d`'s long-lived
    # worker pool reuses the same modo_cl across many cases, so killing
    # the host process after one case would force-restart modo_cl per
    # case and lose the parallelism win. The driver (run.d or whoever
    # `printf '@modo_dump.py\napp.quit'`-pipes us) is responsible for
    # quitting MODO when its work is done.
