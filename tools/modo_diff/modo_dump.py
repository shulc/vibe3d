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
    scene = modo.Scene()
    meshes = [m for m in scene.items("mesh") if len(m.geometry.vertices) > 0]
    if not meshes:
        raise RuntimeError("no non-empty mesh in scene")
    # Cube has 8 verts; use the cube specifically.
    for m in meshes:
        if len(m.geometry.vertices) >= 8:
            m.select(replace=True)
            return m
    raise RuntimeError("no cube-like mesh")


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


def run_op(op):
    kind = op["op"]
    if kind == "polygon_bevel":
        run_polygon_bevel(op)
    elif kind == "move_vertex":
        run_move_vertex(op)
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
