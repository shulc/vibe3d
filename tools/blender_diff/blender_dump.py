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

def find_face(bm, target_verts):
    # Match a face by SET of vertex coordinates (winding/start ignored).
    for f in bm.faces:
        if len(f.verts) != len(target_verts):
            continue
        face_coords = [tuple(v.co) for v in f.verts]
        used = [False] * len(target_verts)
        ok = True
        for fc in face_coords:
            found = False
            for j, t in enumerate(target_verts):
                if used[j]:
                    continue
                if vmatch(fc, t):
                    used[j] = True
                    found   = True
                    break
            if not found:
                ok = False
                break
        if ok:
            return f
    raise RuntimeError(f"face not found with {len(target_verts)} verts at {target_verts}")

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
    elif op["op"] == "polygon_bevel":
        # Vibe3D's polygon "bevel" = MODO Bevel Polygon (inset + extrude
        # per face). For each selected face F: allocate N new verts, replace
        # F with the new ring, emit N side-wall quads, position each new
        # vert via PERPENDICULAR-EDGE-OFFSET (Blender bmesh.ops.inset
        # thickness; MODO Inset):
        #   new[i] = offset_meet(orig[i], ePrev, eNext, faceNormal, inset, inset)
        #          + faceNormal * shift
        # where ePrev / eNext are unit directions from orig[i] to its prev /
        # next neighbour in the face. We replicate manually (rather than
        # using bmesh.ops.inset_individual / inset_region) so the diff
        # isolates vibe3d's MODO-group semantic — group mode in Blender's
        # `inset_region` computes a unified region boundary, which differs
        # from MODO/vibe3d's per-face center/normal + first-face-wins.
        from mathutils import Vector

        def offset_in_plane(edge_dir, face_norm):
            p = face_norm.cross(edge_dir)
            return p.normalized() if p.length > 1e-6 else Vector((0, 1, 0))

        def offset_meet(jv, e_prev, e_next, face_norm, w_prev, w_next):
            # Mirror of math.d:offsetMeet — perpendicular offset of two
            # in-face edges from a corner; meets at intersection of offset
            # lines (or midpoint when edges are collinear).
            p1 = jv + offset_in_plane(-e_prev, face_norm) * w_prev
            p2 = jv + offset_in_plane( e_next, face_norm) * w_next
            r = p2 - p1
            denom = e_prev.cross(e_next).dot(face_norm)
            if abs(denom) < 1e-6:
                if w_prev > 0 and w_next == 0: return p1
                if w_next > 0 and w_prev == 0: return p2
                return (p1 + p2) * 0.5
            t = r.cross(e_next).dot(face_norm) / denom
            return p1 + e_prev * t

        insert    = float(op["insert"])
        shift     = float(op["shift"])
        group     = bool(op.get("group", False))

        # Process faces in JSON listing order (matches vibe3d, which sorts
        # selFaceIdx by faceSelectionOrder — vibe3d_dump selects faces in
        # JSON order, so JSON order = selection order = processing order).
        # This determines which face's inset position is used at shared
        # corners under group=true.
        target_faces = []
        for fdef in op["faces"]:
            target = [tuple(v) for v in fdef]
            target_faces.append(find_face(bm, target))

        # Internal edges (shared between two selected faces) — only for group.
        # Build under DIRECTED keys so we can ask "is the prev→V edge in F
        # shared with another selected face?" by looking up F's winding.
        internal_directed = set()
        internal_undirected = set()
        if group:
            sel_face_set = set(f.index for f in target_faces)
            sel_directed = set()
            for f in target_faces:
                fv = list(f.verts)
                M = len(fv)
                for i in range(M):
                    sel_directed.add((fv[i].index, fv[(i + 1) % M].index))
            for (a, b) in sel_directed:
                if (b, a) in sel_directed:
                    internal_directed.add((a, b))
                    internal_undirected.add((min(a, b), max(a, b)))

        # Build per-vertex adjacency among selected faces for MODO-style
        # shared-corner accumulation (only for group=true).
        vert_to_faces = {}  # vert_index → list of (face_obj, corner_idx)
        if group:
            for f in target_faces:
                fv = list(f.verts)
                for i, v in enumerate(fv):
                    vert_to_faces.setdefault(v.index, []).append((f, i))

        def solve3x3_lsq(rows, targets, fallback):
            """Solve A·d = b in least-squares sense via 3×3 normal equations."""
            AtA = [[0.0]*3 for _ in range(3)]
            Atb = [0.0]*3
            for row, t in zip(rows, targets):
                for i in range(3):
                    for j in range(3):
                        AtA[i][j] += row[i] * row[j]
                    Atb[i] += row[i] * t
            det = (AtA[0][0]*(AtA[1][1]*AtA[2][2] - AtA[1][2]*AtA[2][1])
                 - AtA[0][1]*(AtA[1][0]*AtA[2][2] - AtA[1][2]*AtA[2][0])
                 + AtA[0][2]*(AtA[1][0]*AtA[2][1] - AtA[1][1]*AtA[2][0]))
            if abs(det) < 1e-9:
                return fallback
            inv = 1.0 / det
            dx = (Atb[0]*(AtA[1][1]*AtA[2][2] - AtA[1][2]*AtA[2][1])
                - AtA[0][1]*(Atb[1]*AtA[2][2] - AtA[1][2]*Atb[2])
                + AtA[0][2]*(Atb[1]*AtA[2][1] - AtA[1][1]*Atb[2]))
            dy = (AtA[0][0]*(Atb[1]*AtA[2][2] - AtA[1][2]*Atb[2])
                - Atb[0]*(AtA[1][0]*AtA[2][2] - AtA[1][2]*AtA[2][0])
                + AtA[0][2]*(AtA[1][0]*Atb[2] - Atb[1]*AtA[2][0]))
            dz = (AtA[0][0]*(AtA[1][1]*Atb[2] - Atb[1]*AtA[2][1])
                - AtA[0][1]*(AtA[1][0]*Atb[2] - Atb[1]*AtA[2][0])
                + Atb[0]*(AtA[1][0]*AtA[2][1] - AtA[1][1]*AtA[2][0]))
            return Vector((dx*inv, dy*inv, dz*inv))

        def shared_corner_pos(V_pos, faces_at_V, insert, shift):
            """MODO-style accumulated shift at vertices shared between
            multiple selected faces. Each face contributes a shift along
            its normal; each non-shared adjacent edge contributes an
            inset along its inward perpendicular."""
            rows = []
            targets = []
            for (f, ci) in faces_at_V:
                fv = list(f.verts)
                N = len(fv)
                e1 = fv[1].co - fv[0].co
                e2 = fv[2].co - fv[0].co
                cr = e1.cross(e2)
                fn = cr.normalized() if cr.length > 1e-6 else Vector((0, 1, 0))
                rows.append(fn); targets.append(shift)
                prev_i = (ci - 1 + N) % N
                next_i = (ci + 1) % N
                v_idx = fv[ci].index
                prev_v = fv[prev_i].index
                next_v = fv[next_i].index
                # Edge prev→V (winding direction = V - prev). Non-shared if
                # not in internal_directed under that key.
                if (prev_v, v_idx) not in internal_directed:
                    wd = (fv[ci].co - fv[prev_i].co)
                    if wd.length > 1e-6:
                        wd = wd.normalized()
                        rows.append(fn.cross(wd))
                        targets.append(insert)
                # Edge V→next.
                if (v_idx, next_v) not in internal_directed:
                    wd = (fv[next_i].co - fv[ci].co)
                    if wd.length > 1e-6:
                        wd = wd.normalized()
                        rows.append(fn.cross(wd))
                        targets.append(insert)
            d = solve3x3_lsq(rows, targets, Vector((0, 0, 0)))
            return V_pos + d

        # Snapshot per-face data BEFORE topology mutation (vert references
        # invalidate after we delete/replace faces).
        per_face = []
        group_vert_map = {}  # orig vert idx → new vert (for group mode)
        for f in target_faces:
            verts = list(f.verts)
            origPos = [Vector(v.co) for v in verts]
            N = len(verts)
            center = Vector((0, 0, 0))
            for p in origPos: center += p
            center /= N
            e1 = origPos[1] - origPos[0]
            e2 = origPos[2] - origPos[0]
            cr = e1.cross(e2)
            clen = cr.length
            normal = cr / clen if clen > 1e-6 else Vector((0, 1, 0))

            new_positions = []
            for i in range(N):
                v_idx = verts[i].index
                if group and len(vert_to_faces.get(v_idx, [])) >= 2:
                    # Shared corner — use MODO-style accumulated shift.
                    new_positions.append(
                        shared_corner_pos(origPos[i],
                                          vert_to_faces[v_idx],
                                          insert, shift))
                else:
                    prev_i = (i + N - 1) % N
                    next_i = (i + 1) % N
                    e_prev = (origPos[prev_i] - origPos[i])
                    e_prev = e_prev.normalized() if e_prev.length > 1e-6 else Vector((1, 0, 0))
                    e_next = (origPos[next_i] - origPos[i])
                    e_next = e_next.normalized() if e_next.length > 1e-6 else Vector((1, 0, 0))
                    in_plane = offset_meet(origPos[i], e_prev, e_next, normal,
                                            insert, insert)
                    new_positions.append(in_plane + normal * shift)
            per_face.append({
                "verts":         verts,
                "origPos":       origPos,
                "newPositions":  new_positions,
                "N":             N,
                "origFaceIdx":   f.index,
            })

        # Drop internal mesh edges (group mode only). Doing this BEFORE
        # face creation keeps the new top region one connected polygon.
        if group and internal_undirected:
            edges_to_remove = []
            for e in bm.edges:
                a, b = e.verts[0].index, e.verts[1].index
                if (min(a, b), max(a, b)) in internal_undirected:
                    edges_to_remove.append(e)
            bmesh.ops.delete(bm, geom=edges_to_remove, context='EDGES')
            bm.faces.ensure_lookup_table()

        bm.verts.ensure_lookup_table()
        bm.faces.ensure_lookup_table()

        # Create the inset top + side walls per face.
        for pfd in per_face:
            origVerts = pfd["verts"]
            N = pfd["N"]
            newVerts = []
            for i in range(N):
                if group:
                    ov = origVerts[i].index
                    if ov in group_vert_map:
                        newVerts.append(group_vert_map[ov])
                    else:
                        nv = bm.verts.new(pfd["newPositions"][i])
                        newVerts.append(nv)
                        group_vert_map[ov] = nv
                else:
                    nv = bm.verts.new(pfd["newPositions"][i])
                    newVerts.append(nv)
            bm.verts.ensure_lookup_table()

            # Remove the old face (we replace it with the new top). Re-find
            # by vert set: face indices may have shifted after prior face
            # creation/deletion AND the lookup table can be stale.
            bm.faces.ensure_lookup_table()
            old_face = None
            origVertIdxSet = set(v.index for v in origVerts)
            for f in bm.faces:
                if set(v.index for v in f.verts) == origVertIdxSet:
                    old_face = f
                    break
            if old_face is not None:
                bm.faces.remove(old_face)
                bm.faces.ensure_lookup_table()

            try:
                bm.faces.new(newVerts)
            except ValueError:
                pass  # face may already exist in group mode (duplicate corners)

            # Side-wall quads (skip internal edges in group mode).
            for i in range(N):
                ni = (i + 1) % N
                if group:
                    a, b = origVerts[i].index, origVerts[ni].index
                    if (min(a, b), max(a, b)) in internal_undirected:
                        continue
                try:
                    bm.faces.new([origVerts[i], origVerts[ni],
                                  newVerts[ni],  newVerts[i]])
                except ValueError:
                    pass

        bm.normal_update()
        bmesh.update_edit_mesh(mesh)
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
