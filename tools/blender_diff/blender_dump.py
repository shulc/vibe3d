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
    elif op["op"] == "bevel":
        super_r = op.get("superR", 2.0)
        if abs(super_r - 2.0) > 1e-6:
            raise NotImplementedError(
                f"superR={super_r}: only circular profile (superR=2.0) supported")
        select_edges(bm, op["edges"])
        bmesh.update_edit_mesh(mesh)
        bpy.ops.mesh.bevel(
            offset_type='OFFSET',
            offset=op["width"],
            segments=op["segments"],
            profile=0.5,
            affect='EDGES',
            miter_outer='SHARP',
            miter_inner='SHARP',
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
