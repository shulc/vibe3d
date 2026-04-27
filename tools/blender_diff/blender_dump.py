"""Run a comparison case in Blender and dump the resulting geometry.

Usage:
  blender --background --python blender_dump.py -- <case.json> <out.json>

Case schema:
  {
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

# Default cube: size=1 → vertices at ±0.5, matching vibe3d's makeCube().
bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, 0, 0))
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

for op in case["ops"]:
    bm = bmesh.from_edit_mesh(mesh)
    bm.verts.ensure_lookup_table()
    bm.edges.ensure_lookup_table()
    if op["op"] == "bevel":
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
