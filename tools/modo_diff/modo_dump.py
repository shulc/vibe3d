#python
# Apply a comparison case to MODO and dump the resulting geometry to JSON.
#
# Usage (called by run.d, not directly by user):
#   modo_cl reads commands from stdin; the pipeline is:
#       echo '@modo_dump.py
#       app.quit' | modo_cl
#   with environment variables:
#       MODO_CASE_PATH=/path/to/case.json
#       MODO_OUT_PATH=/path/to/out.json
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
    """Reset to a single-mesh scene with a unit cube at origin."""
    lx.eval("scene.new")
    lx.eval('tool.set "prim.cube" on 0')
    lx.eval('tool.attr prim.cube cenX 0.0')
    lx.eval('tool.attr prim.cube cenY 0.0')
    lx.eval('tool.attr prim.cube cenZ 0.0')
    lx.eval('tool.attr prim.cube sizeX 1.0')
    lx.eval('tool.attr prim.cube sizeY 1.0')
    lx.eval('tool.attr prim.cube sizeZ 1.0')
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


def run_op(op):
    kind = op["op"]
    if kind == "polygon_bevel":
        run_polygon_bevel(op)
    elif kind == "move_vertex":
        run_move_vertex(op)
    elif kind == "delete" or kind == "remove":
        run_delete_or_remove(op, kind)
    else:
        raise NotImplementedError("modo_dump: unsupported op '%s'" % kind)


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
    lx.eval("app.quit")
