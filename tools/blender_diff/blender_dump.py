"""Run a comparison case in Blender and dump the resulting geometry.

Usage:
  blender --background --python blender_dump.py -- <case.json> <out.json>

Case schema:
  {
    "preops": [              # optional: setup operations before the main ops
      {"op": "split_edge", "v0": [x,y,z], "v1": [x,y,z]}
    ],
    "ops": [
      {"op": "bevel",
       "edges": [{"v0": [x,y,z], "v1": [x,y,z]}, ...],
       "width": float,
       "segments": int,
       "superR": float}     # super-ellipse exponent: 2.0 = circle (default)
    ],
    "tolerance": float       # consumed by diff.py, ignored here
  }

Note: Blender's bevel `profile` parameter is a [0..1] knob with 0.5 = circle;
there is no clean closed-form inverse for the super-ellipse exponent. We
support superR=2.0 (Blender profile=0.5) explicitly; other values raise.
"""
import bpy
import bmesh
import json
import sys

argv = sys.argv
argv = argv[argv.index("--") + 1:] if "--" in argv else []
if len(argv) != 2:
    print("usage: blender_dump.py <case.json> <out.json>", file=sys.stderr)
    sys.exit(2)

with open(argv[0]) as f:
    case = json.load(f)
out_path = argv[1]

# Wipe scene and start fresh.
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)

primitive = case.get("primitive", "cube")
if primitive == "cube":
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, 0, 0))
elif primitive == "diamond":
    verts = [
        (-1.0,  0.0,  0.05),
        ( 0.0, -1.0, -0.05),
        ( 1.0,  0.0,  0.05),
        ( 0.0,  1.0, -0.05),
    ]
    faces = [(0, 1, 2, 3), (0, 3, 2, 1)]
    new_mesh = bpy.data.meshes.new("Diamond")
    new_mesh.from_pydata(verts, [], faces)
    new_mesh.update()
    new_obj = bpy.data.objects.new("Diamond", new_mesh)
    bpy.context.collection.objects.link(new_obj)
    bpy.context.view_layer.objects.active = new_obj
    new_obj.select_set(True)
elif primitive == "octahedron":
    verts = [
        ( 1.0, 0.0, 0.0), (-1.0, 0.0, 0.0),
        ( 0.0, 1.0, 0.0), ( 0.0,-1.0, 0.0),
        ( 0.0, 0.0, 1.0), ( 0.0, 0.0,-1.0),
    ]
    faces = [
        (4, 0, 2), (4, 2, 1), (4, 1, 3), (4, 3, 0),
        (5, 2, 0), (5, 1, 2), (5, 3, 1), (5, 0, 3),
    ]
    new_mesh = bpy.data.meshes.new("Octahedron")
    new_mesh.from_pydata(verts, [], faces)
    new_mesh.update()
    new_obj = bpy.data.objects.new("Octahedron", new_mesh)
    bpy.context.collection.objects.link(new_obj)
    bpy.context.view_layer.objects.active = new_obj
    new_obj.select_set(True)
elif primitive == "lshape":
    # Match vibe3d's makeLShape exactly: 6-vert profile in XY extruded along Z.
    verts = [
        (-1.0, -1.0,  0.5), ( 1.0, -1.0,  0.5), ( 1.0,  0.0,  0.5),
        ( 0.0,  0.0,  0.5), ( 0.0,  1.0,  0.5), (-1.0,  1.0,  0.5),
        (-1.0, -1.0, -0.5), ( 1.0, -1.0, -0.5), ( 1.0,  0.0, -0.5),
        ( 0.0,  0.0, -0.5), ( 0.0,  1.0, -0.5), (-1.0,  1.0, -0.5),
    ]
    faces = [
        (0, 1, 2, 3, 4, 5),         # front cap (+Z)
        (6, 11, 10, 9, 8, 7),       # back cap  (-Z)
        (0, 6, 7, 1),
        (1, 7, 8, 2),
        (2, 8, 9, 3),
        (3, 9, 10, 4),
        (4, 10, 11, 5),
        (5, 11, 6, 0),
    ]
    new_mesh = bpy.data.meshes.new("LShape")
    new_mesh.from_pydata(verts, [], faces)
    new_mesh.update()
    new_obj = bpy.data.objects.new("LShape", new_mesh)
    bpy.context.collection.objects.link(new_obj)
    bpy.context.view_layer.objects.active = new_obj
    new_obj.select_set(True)
else:
    raise ValueError(f"unknown primitive: {primitive}")

obj = bpy.context.active_object
mesh = obj.data
bpy.ops.object.mode_set(mode='EDIT')

EPS = 1e-4
def vmatch(a, b):
    return all(abs(a[i] - b[i]) < EPS for i in range(3))

def select_edges(bm, endpoint_pairs):
    for v in bm.verts: v.select = False
    for e in bm.edges: e.select = False
    for f in bm.faces: f.select = False
    found = 0
    for e in bm.edges:
        a = tuple(e.verts[0].co); b = tuple(e.verts[1].co)
        for ep in endpoint_pairs:
            pa, pb = tuple(ep["v0"]), tuple(ep["v1"])
            if (vmatch(a, pa) and vmatch(b, pb)) or (vmatch(a, pb) and vmatch(b, pa)):
                e.select = True
                found += 1
                break
    if found != len(endpoint_pairs):
        raise RuntimeError(f"edge match: requested {len(endpoint_pairs)}, found {found}")

def find_edge(bm, v0, v1):
    for e in bm.edges:
        a = tuple(e.verts[0].co); b = tuple(e.verts[1].co)
        if (vmatch(a, v0) and vmatch(b, v1)) or (vmatch(a, v1) and vmatch(b, v0)):
            return e
    raise RuntimeError(f"edge not found: {v0} ↔ {v1}")

def run_op(op):
    bm = bmesh.from_edit_mesh(mesh)
    bm.verts.ensure_lookup_table()
    bm.edges.ensure_lookup_table()
    if op["op"] == "split_edge":
        e = find_edge(bm, tuple(op["v0"]), tuple(op["v1"]))
        bmesh.ops.subdivide_edges(bm, edges=[e], cuts=1)
        bmesh.update_edit_mesh(mesh)
    elif op["op"] == "subdivide":
        # Match vibe3d's mesh.subdivide (Catmull-Clark via source/mesh.d:catmullClark).
        # Blender's bmesh.ops.subdivide_edges and bpy.ops.mesh.subdivide both
        # produce different vertex placements (corners stay or get pushed
        # onto a sphere). The Subsurf modifier is closer but uses limit-
        # surface positions. Vibe3D's CC is the textbook formulation:
        #   face point      = face centroid
        #   edge point      = (a + b + f0 + f1) / 4   (interior)
        #                   = (a + b) / 2             (boundary)
        #   updated vertex  = (F + 2R + (n-3)v) / n   (interior, valence n)
        # We reproduce it manually below; see source/mesh.d:1220 for the
        # reference D implementation.
        from mathutils import Vector
        bm.verts.ensure_lookup_table()
        bm.edges.ensure_lookup_table()
        bm.faces.ensure_lookup_table()

        old_verts_pos = [Vector(v.co) for v in bm.verts]
        old_face_verts = [[v.index for v in f.verts] for f in bm.faces]
        old_edges = [(e.verts[0].index, e.verts[1].index) for e in bm.edges]
        old_edge_face_count = [len(e.link_faces) for e in bm.edges]
        old_vert_faces = [[f.index for f in v.link_faces] for v in bm.verts]
        old_vert_edges = [[e.index for e in v.link_edges] for v in bm.verts]
        old_face_edges = [[e.index for e in f.edges] for f in bm.faces]

        nV = len(old_verts_pos); nE = len(old_edges); nF = len(old_face_verts)

        face_pts = []
        for f in old_face_verts:
            c = Vector()
            for vi in f: c += old_verts_pos[vi]
            face_pts.append(c / len(f))

        edge_to_faces = [[] for _ in range(nE)]
        for fi, fe in enumerate(old_face_edges):
            for ei in fe: edge_to_faces[ei].append(fi)
        edge_pts = []
        for ei, (a, b) in enumerate(old_edges):
            if old_edge_face_count[ei] == 2:
                f0, f1 = edge_to_faces[ei][0], edge_to_faces[ei][1]
                edge_pts.append((old_verts_pos[a] + old_verts_pos[b]
                                 + face_pts[f0] + face_pts[f1]) / 4)
            else:
                edge_pts.append((old_verts_pos[a] + old_verts_pos[b]) / 2)

        new_orig = []
        for vi in range(nV):
            n = len(old_vert_faces[vi])
            v_co = old_verts_pos[vi]
            if n == 0:
                new_orig.append(v_co); continue
            boundary = any(old_edge_face_count[ei] < 2 for ei in old_vert_edges[vi])
            if boundary:
                sum_v = Vector(v_co); cnt = 1
                for ei in old_vert_edges[vi]:
                    if old_edge_face_count[ei] >= 2: continue
                    a, b = old_edges[ei]
                    sum_v += (old_verts_pos[a] + old_verts_pos[b]) / 2; cnt += 1
                new_orig.append(sum_v / cnt)
            else:
                F = Vector()
                for fi in old_vert_faces[vi]: F += face_pts[fi]
                F /= n
                R = Vector()
                m = len(old_vert_edges[vi])
                for ei in old_vert_edges[vi]:
                    a, b = old_edges[ei]
                    R += (old_verts_pos[a] + old_verts_pos[b]) / 2
                R /= m
                new_orig.append((F + 2*R + (n - 3) * v_co) / n)

        bm.clear()
        new_verts = []
        for p in new_orig:    new_verts.append(bm.verts.new(p))
        fp_offset = nV
        for p in face_pts:    new_verts.append(bm.verts.new(p))
        ep_offset = nV + nF
        for p in edge_pts:    new_verts.append(bm.verts.new(p))
        bm.verts.ensure_lookup_table()

        for fi, fv in enumerate(old_face_verts):
            fe = old_face_edges[fi]
            k = len(fv)
            ev_to_e = {}
            for ei in fe:
                a, b = old_edges[ei]
                ev_to_e[(min(a, b), max(a, b))] = ei
            for i in range(k):
                v_curr = fv[i]
                v_next = fv[(i + 1) % k]
                v_prev = fv[(i - 1) % k]
                e_next = ev_to_e[(min(v_curr, v_next), max(v_curr, v_next))]
                e_prev = ev_to_e[(min(v_prev, v_curr), max(v_prev, v_curr))]
                quad = [
                    new_verts[v_curr],
                    new_verts[ep_offset + e_next],
                    new_verts[fp_offset + fi],
                    new_verts[ep_offset + e_prev],
                ]
                try: bm.faces.new(quad)
                except ValueError: pass
        bmesh.update_edit_mesh(mesh)
    elif op["op"] == "move_vertex":
        from_co = tuple(op["from"])
        to_co   = tuple(op["to"])
        for v in bm.verts:
            if vmatch(tuple(v.co), from_co):
                v.co = to_co
                break
        else:
            raise RuntimeError(f"move_vertex: no vert at {from_co}")
        bmesh.update_edit_mesh(mesh)
    elif op["op"] == "bevel":
        super_r = op.get("superR", 2.0)
        if abs(super_r - 2.0) > 1e-6:
            raise NotImplementedError(
                f"superR={super_r}: only circular profile (superR=2.0) supported")
        miter_outer = op.get("miter_outer", "SHARP").upper()
        miter_inner = op.get("miter_inner", "SHARP").upper()
        clamp_overlap = bool(op.get("clamp_overlap", True))
        select_edges(bm, op["edges"])
        bmesh.update_edit_mesh(mesh)
        bpy.ops.mesh.bevel(
            offset_type='OFFSET',
            offset=op["width"],
            segments=op["segments"],
            profile=0.5,
            affect='EDGES',
            miter_outer=miter_outer,
            miter_inner=miter_inner,
            clamp_overlap=clamp_overlap,
        )
    else:
        raise ValueError(f"unknown op: {op['op']}")

for op in case.get("preops", []):
    run_op(op)
for op in case["ops"]:
    run_op(op)

bm = bmesh.from_edit_mesh(mesh)
bm.verts.ensure_lookup_table()
bm.faces.ensure_lookup_table()
out = {
    "vertexCount": len(bm.verts),
    "faceCount": len(bm.faces),
    "vertices": [list(v.co) for v in bm.verts],
    "faces":    [[v.index for v in f.verts] for f in bm.faces],
    "source":   "blender",
}
bpy.ops.object.mode_set(mode='OBJECT')
with open(out_path, "w") as f:
    json.dump(out, f, indent=2)
print(f"[blender_dump] wrote {out_path}: {out['vertexCount']} verts, {out['faceCount']} faces")
