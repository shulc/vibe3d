module poly_bevel;

import std.math : abs, sqrt;

import math;
import mesh;

// ---------------------------------------------------------------------------
// Polygon "bevel" — inset + extrude on selected faces (MODO Bevel Polygon
// semantics).
//
// For each selected face F (with N vertices):
//   1. Allocate N new mesh vertices.
//   2. Replace F with the new vertex ring (the "top" face).
//   3. Emit N side-wall quads connecting each old vertex to the corresponding
//      new vertex: [orig[i], orig[i+1], new[i+1], new[i]].
//   4. Position each new vertex via PERPENDICULAR-EDGE-OFFSET (MODO Inset):
//        new[i] = offsetMeet(orig[i], ePrev, eNext, faceNormal, inset, inset)
//                + faceNormal * shift
//      where ePrev / eNext are unit directions from orig[i] to its prev /
//      next neighbour in the face, and `inset` is the perpendicular distance
//      each boundary edge moves inward (in the face plane). Identity = 0.
//      This is `bmesh.ops.inset` thickness, NOT a multiplicative scale.
//      For irregular polygons (long-thin, trapezoid, etc.) the per-edge
//      perpendicular offset preserves edge parallelism — long and short
//      edges both move inward by `inset` distance, not by a uniform scale
//      factor toward the centroid.
//
// Group mode (groupPolygons=true): adjacent selected faces share new vertices
// at their shared boundary, AND their internal shared edges are removed
// (instead of generating side-wall quads). The resulting top region is one
// connected inset patch matching the union of selected faces. PER-FACE
// normal/center is used regardless of group mode (matches MODO; differs
// from Blender's `inset_region` which computes a unified region boundary).
//
// Lifecycle: applyPolyBevel returns a PolyBevelOp that can be passed to:
//   - updatePolyBevelPositions: re-slide new verts on every drag without
//     rebuilding topology (interactive tool path).
//   - revertPolyBevel: restore the mesh to its pre-apply state (interactive
//     tool path on tool deactivate or parameter reset).
// ---------------------------------------------------------------------------

struct PolyBevelOp {
    struct FaceData {
        Vec3   center;          // face centroid (pre-apply)
        Vec3   normal;          // unit face normal (pre-apply)
        Vec3[] origPos;         // pre-apply positions of the N face corners
        int[]  newVerts;        // mesh vertex IDs of the new (top) ring
        int    origFaceIdx;     // index in mesh.faces of the (now top) face
        uint[] origFaceVerts;   // pre-apply vertex IDs of the face's corners
    }
    FaceData[] faces;

    // Multi-face shared corners (group mode only). Per shared origVid, the
    // new mesh vertex ID + the constraint geometry (face normals and
    // non-shared adjacent edges' inward perpendiculars). Recomputed once
    // at apply time; updatePolyBevelPositions solves the 3×3 LSQ system
    // per call so interactive insetAmount/shiftAmount drag-update produces
    // the same MODO-style accumulated-shift placement as the initial apply.
    struct SharedCornerData {
        int    newVid;
        Vec3   origV;
        Vec3[] normals;
        Vec3[] perps;
    }
    SharedCornerData[] sharedCorners;

    // Pre-apply mesh state for revert.
    size_t    origVertCount;
    size_t    origFaceCount;
    uint[2][] origEdges;
    bool[]    origSelectedEdges;
    int[]     origEdgeOrder;
    bool      groupPolygons;
}

// Compute the new (inset) corner position for a face vertex i.
// inset >= 0: perpendicular distance each adjacent edge moves inward
//             (in the face plane). For a 1×1 square with inset=0.1 the new
//             corner sits 0.1 in from each edge → (0.1, 0.1) of original.
// inset <  0: outset (boundary moves outward). offsetMeet handles negative.
private Vec3 polyInsetCorner(in Vec3[] origPos, int i, Vec3 faceNormal,
                              float inset, float shift)
{
    int N     = cast(int)origPos.length;
    int prevI = (i + N - 1) % N;
    int nextI = (i + 1) % N;
    Vec3 ePrev = safeNormalize(origPos[prevI] - origPos[i]);
    Vec3 eNext = safeNormalize(origPos[nextI] - origPos[i]);
    Vec3 inPlane = offsetMeet(origPos[i], ePrev, eNext, faceNormal,
                               inset, inset);
    return inPlane + faceNormal * shift;
}

// Solve A·d = b in the least-squares sense via the 3×3 normal equations.
// `rows`/`targets` define A (k×3) and b (k-vector). When AtA is singular
// (degenerate constraint geometry), returns `fallback`.
private Vec3 solve3x3LeastSquares(const(Vec3)[] rows, const(float)[] targets,
                                    Vec3 fallback)
{
    // AtA (3×3) and Atb (3-vec).
    float[9] AtA = 0;
    Vec3 Atb = Vec3(0, 0, 0);
    foreach (i, row; rows) {
        float t = targets[i];
        AtA[0] += row.x * row.x; AtA[1] += row.x * row.y; AtA[2] += row.x * row.z;
        AtA[3] += row.y * row.x; AtA[4] += row.y * row.y; AtA[5] += row.y * row.z;
        AtA[6] += row.z * row.x; AtA[7] += row.z * row.y; AtA[8] += row.z * row.z;
        Atb.x += row.x * t;
        Atb.y += row.y * t;
        Atb.z += row.z * t;
    }
    float det = AtA[0] * (AtA[4] * AtA[8] - AtA[5] * AtA[7])
              - AtA[1] * (AtA[3] * AtA[8] - AtA[5] * AtA[6])
              + AtA[2] * (AtA[3] * AtA[7] - AtA[4] * AtA[6]);
    if (abs(det) < 1e-9f) return fallback;
    float invDet = 1.0f / det;
    // Cramer's rule on AtA · d = Atb.
    float dx = Atb.x * (AtA[4] * AtA[8] - AtA[5] * AtA[7])
             - AtA[1] * (Atb.y * AtA[8] - AtA[5] * Atb.z)
             + AtA[2] * (Atb.y * AtA[7] - AtA[4] * Atb.z);
    float dy = AtA[0] * (Atb.y * AtA[8] - AtA[5] * Atb.z)
             - Atb.x * (AtA[3] * AtA[8] - AtA[5] * AtA[6])
             + AtA[2] * (AtA[3] * Atb.z - Atb.y * AtA[6]);
    float dz = AtA[0] * (AtA[4] * Atb.z - Atb.y * AtA[7])
             - AtA[1] * (AtA[3] * Atb.z - Atb.y * AtA[6])
             + Atb.x * (AtA[3] * AtA[7] - AtA[4] * AtA[6]);
    return Vec3(dx * invDet, dy * invDet, dz * invDet);
}

// MODO-style group-mode shared-corner placement. Vertex V is shared between
// 2+ selected faces; its new position is the simultaneous solution of:
//   (P - V) · n_k = shift   for each face F_k incident to V
//   (P - V) · p_j = inset   for each non-shared adjacent boundary edge,
//                            where p_j is its inward perpendicular in the
//                            face plane.
//
// Differs from `polyInsetCorner` (which uses per-face inset+shift) by
// accumulating shifts from ALL faces that share V — see MODO Bevel
// "Group Polygons" semantics. For a non-shared corner (V in 1 face with
// 2 non-shared adjacent edges) this reduces to polyInsetCorner.
private Vec3 sharedCornerPos(in Vec3 V,
                              const(Vec3)[] faceNormals,
                              const(Vec3)[] nonSharedInwardPerps,
                              float inset, float shift)
{
    Vec3[] rows;
    float[] targets;
    foreach (n; faceNormals) { rows ~= n; targets ~= shift; }
    foreach (p; nonSharedInwardPerps) { rows ~= p; targets ~= inset; }
    Vec3 d = solve3x3LeastSquares(rows, targets, Vec3(0, 0, 0));
    return V + d;
}

PolyBevelOp applyPolyBevel(Mesh* mesh, const(int)[] selFaceIdx,
                            float inset, float shift,
                            bool groupPolygons)
{
    PolyBevelOp op;
    op.origVertCount     = mesh.vertices.length;
    op.origFaceCount     = mesh.faces.length;
    op.origEdges         = mesh.edges.dup;
    op.origSelectedEdges = mesh.selectedEdges.dup;
    op.origEdgeOrder     = mesh.edgeSelectionOrder.dup;
    op.groupPolygons     = groupPolygons;
    if (selFaceIdx.length == 0) return op;

    bool[ulong] internalEdgeSet;
    int[uint]   groupVertMap;
    Vec3[uint]  sharedNewPos;     // origVertId → MODO-style multi-face new pos

    if (groupPolygons) {
        // Identify internal edges (shared between two selected faces). Used
        // both to remove the original mesh edge and to skip side-wall quad
        // emission on those edges.
        bool[ulong] selEdges;
        foreach (fi; selFaceIdx) {
            auto face = mesh.faces[fi];
            int M = cast(int)face.length;
            foreach (i; 0 .. M) {
                ulong key = (cast(ulong)face[i] << 32) | face[(i + 1) % M];
                selEdges[key] = true;
            }
        }
        foreach (key; selEdges.byKey()) {
            uint a = cast(uint)(key >> 32);
            uint b = cast(uint)(key & 0xFFFF_FFFF);
            ulong rev = (cast(ulong)b << 32) | a;
            if (rev in selEdges)
                internalEdgeSet[key] = true;
        }

        // MODO-style group semantics: at each vertex shared between 2+
        // selected faces, accumulate shifts from ALL faces and inset only
        // along NON-SHARED adjacent edges. See sharedCornerPos. Build the
        // per-vertex new position now so the per-face emission loop just
        // looks them up. Non-shared (single-face) verts keep using
        // polyInsetCorner inside the loop.
        int[][uint] vertToFaces;
        foreach (origFi; selFaceIdx) {
            auto face = mesh.faces[origFi];
            foreach (i, ov; face) vertToFaces[ov] ~= origFi;
        }
        foreach (ov, fis; vertToFaces) {
            if (fis.length < 2) continue;
            Vec3 V = mesh.vertices[ov];
            Vec3[] normals;
            Vec3[] perps;
            foreach (origFi; fis) {
                auto face = mesh.faces[origFi];
                int N = cast(int)face.length;
                int cIdx = -1;
                foreach (k, fv; face) if (fv == ov) { cIdx = cast(int)k; break; }
                if (cIdx < 0) continue;
                int prevI = (cIdx - 1 + N) % N;
                int nextI = (cIdx + 1) % N;
                uint prevV = face[prevI];
                uint nextV = face[nextI];
                Vec3 fn;
                {
                    Vec3 a = mesh.vertices[face[1]] - mesh.vertices[face[0]];
                    Vec3 b = mesh.vertices[face[2]] - mesh.vertices[face[0]];
                    Vec3 cr = cross(a, b);
                    float l = sqrt(cr.x*cr.x + cr.y*cr.y + cr.z*cr.z);
                    fn = l > 1e-6f ? cr / l : Vec3(0, 1, 0);
                }
                normals ~= fn;
                // Edge prev→V (winding direction: V - prev). Inward perp =
                // cross(faceNormal, windingDir) — see polyInsetCorner /
                // edge bevel offsetMeet conventions. Add as inset
                // constraint iff this edge is NOT shared with another
                // selected face (= not in internalEdgeSet under the
                // winding key).
                ulong keyIn = (cast(ulong)prevV << 32) | ov;
                if (keyIn !in internalEdgeSet) {
                    Vec3 wd = safeNormalize(V - mesh.vertices[prevV]);
                    perps ~= safeNormalize(cross(fn, wd));
                }
                // Edge V→next (winding direction: next - V).
                ulong keyOut = (cast(ulong)ov << 32) | nextV;
                if (keyOut !in internalEdgeSet) {
                    Vec3 wd = safeNormalize(mesh.vertices[nextV] - V);
                    perps ~= safeNormalize(cross(fn, wd));
                }
            }
            sharedNewPos[ov] = sharedCornerPos(V, normals, perps, inset, shift);
            // Stash the constraint geometry keyed by origVid; resolve to
            // newVid after the face-emission loop populates groupVertMap.
            PolyBevelOp.SharedCornerData sc;
            sc.newVid  = cast(int)ov;   // temporarily holds origVid
            sc.origV   = V;
            sc.normals = normals;
            sc.perps   = perps;
            op.sharedCorners ~= sc;
        }

        // Drop internal mesh edges (undirected) so the inset top is one
        // contiguous polygon group.
        if (internalEdgeSet.length > 0) {
            bool[ulong] internalPairs;
            foreach (key; internalEdgeSet.byKey()) {
                uint a = cast(uint)(key >> 32);
                uint b = cast(uint)(key & 0xFFFF_FFFF);
                uint mn = a < b ? a : b, mx = a < b ? b : a;
                internalPairs[(cast(ulong)mn << 32) | mx] = true;
            }
            uint[2][] kept;
            bool[]    keptSel;
            int[]     keptOrd;
            foreach (ei, e; mesh.edges) {
                uint mn = e[0] < e[1] ? e[0] : e[1];
                uint mx = e[0] < e[1] ? e[1] : e[0];
                if (((cast(ulong)mn << 32) | mx) in internalPairs) continue;
                kept    ~= e;
                keptSel ~= ei < mesh.selectedEdges.length     ? mesh.selectedEdges[ei]      : false;
                keptOrd ~= ei < mesh.edgeSelectionOrder.length ? mesh.edgeSelectionOrder[ei] : 0;
            }
            mesh.edges              = kept;
            mesh.selectedEdges      = keptSel;
            mesh.edgeSelectionOrder = keptOrd;
        }
    }

    foreach (origFi; selFaceIdx) {
        uint[] origFaceVerts = mesh.faces[origFi].dup;
        int N = cast(int)origFaceVerts.length;
        if (N < 3) continue;

        Vec3[] origPos = new Vec3[](N);
        foreach (i; 0 .. N)
            origPos[i] = mesh.vertices[origFaceVerts[i]];

        Vec3 center = Vec3(0, 0, 0);
        foreach (p; origPos) center += p;
        float invN = 1.0f / cast(float)N;
        center = center * invN;

        Vec3 e1 = origPos[1] - origPos[0];
        Vec3 e2 = origPos[2] - origPos[0];
        Vec3 cr = cross(e1, e2);
        float clen = sqrt(cr.x*cr.x + cr.y*cr.y + cr.z*cr.z);
        Vec3 faceNormal = clen > 1e-6f ? cr / clen : Vec3(0, 1, 0);

        int[] newVerts = new int[](N);
        foreach (i; 0 .. N) {
            uint ov = origFaceVerts[i];
            // For shared corners under group mode, use the precomputed
            // multi-face accumulated position (MODO-style); otherwise
            // fall back to per-face perpendicular inset+shift.
            Vec3 placed;
            if (groupPolygons && (ov in sharedNewPos)) {
                placed = sharedNewPos[ov];
            } else {
                placed = polyInsetCorner(origPos, cast(int)i,
                                          faceNormal, inset, shift);
            }
            if (groupPolygons) {
                if (auto p = ov in groupVertMap) {
                    newVerts[i] = *p;
                } else {
                    int nv = cast(int)mesh.addVertex(placed);
                    newVerts[i]      = nv;
                    groupVertMap[ov] = nv;
                }
            } else {
                newVerts[i] = cast(int)mesh.addVertex(placed);
            }
        }

        uint[] topFace = new uint[](N);
        foreach (i; 0 .. N) topFace[i] = cast(uint)newVerts[i];
        mesh.faces[origFi] = topFace;

        foreach (i; 0 .. N) {
            int next = (i + 1) % N;
            if (groupPolygons) {
                ulong key = (cast(ulong)origFaceVerts[i] << 32) | origFaceVerts[next];
                if (key in internalEdgeSet) continue;
            }
            mesh.addFace([origFaceVerts[i],        origFaceVerts[next],
                          cast(uint)newVerts[next], cast(uint)newVerts[i]]);
        }

        PolyBevelOp.FaceData fd;
        fd.center        = center;
        fd.normal        = faceNormal;
        fd.origPos       = origPos;
        fd.newVerts      = newVerts;
        fd.origFaceIdx   = origFi;
        fd.origFaceVerts = origFaceVerts;
        op.faces ~= fd;
    }

    // Resolve sharedCorners' temporary origVid (in newVid field) to the
    // actual newVid via groupVertMap, now that the face emission loop has
    // populated it. updatePolyBevelPositions reads sharedCorners.newVid
    // directly to overwrite the per-face polyInsetCorner result with the
    // multi-face MODO-style accumulated position.
    foreach (ref sc; op.sharedCorners) {
        uint origVid = cast(uint)sc.newVid;
        if (auto pNew = origVid in groupVertMap) sc.newVid = *pNew;
        else                                      sc.newVid = -1;
    }

    // Side-wall quads + the new top inset face introduce edges that aren't
    // in mesh.edges. Without this rebuild, edge-mode selection / picking /
    // edge-bevel can't see the new edges. Mirror what edge bevel does at
    // the end of applyEdgeBevelTopology.
    mesh.rebuildEdgesFromFaces();
    mesh.syncSelection();
    return op;
}

// Re-slide every new vertex of an applied poly bevel to (inset, shift)
// without rebuilding topology. Per-face origPos/normal are captured at
// apply time and reused on every update — the user's drag of the gizmo
// only changes the two scalar parameters.
//
// In group mode, vertices shared between 2+ selected faces are repositioned
// AFTER the per-face pass by re-solving the multi-face least-squares system
// stored in op.sharedCorners. This keeps interactive insetAmount/shiftAmount
// drag-update consistent with the initial apply (MODO accumulated-shift
// semantics) — without it, last-face-wins per-face polyInsetCorner gives
// per-face shifts at shared corners instead of accumulated.
void updatePolyBevelPositions(Mesh* mesh, ref const PolyBevelOp op,
                               float inset, float shift)
{
    foreach (ref fd; op.faces) {
        int N = cast(int)fd.newVerts.length;
        foreach (i; 0 .. N) {
            int vid = fd.newVerts[i];
            if (vid < 0 || vid >= cast(int)mesh.vertices.length) continue;
            mesh.vertices[vid] = polyInsetCorner(fd.origPos, cast(int)i,
                                                  fd.normal, inset, shift);
        }
    }
    // Overwrite shared corners with the multi-face accumulated solution.
    foreach (ref sc; op.sharedCorners) {
        if (sc.newVid < 0 || sc.newVid >= cast(int)mesh.vertices.length)
            continue;
        Vec3[] rows;
        float[] targets;
        foreach (n; sc.normals) { rows ~= n; targets ~= shift; }
        foreach (p; sc.perps)   { rows ~= p; targets ~= inset; }
        Vec3 d = solve3x3LeastSquares(rows, targets, Vec3(0, 0, 0));
        mesh.vertices[sc.newVid] = sc.origV + d;
    }
}

// Restore the mesh to its pre-apply state.
void revertPolyBevel(Mesh* mesh, ref const PolyBevelOp op)
{
    foreach (ref fd; op.faces) {
        if (fd.origFaceIdx >= 0 && fd.origFaceIdx < cast(int)mesh.faces.length)
            mesh.faces[fd.origFaceIdx] = fd.origFaceVerts.dup;
    }
    mesh.vertices.length    = op.origVertCount;
    mesh.faces.length       = op.origFaceCount;
    mesh.edges              = op.origEdges.dup;
    mesh.selectedEdges      = op.origSelectedEdges.dup;
    mesh.edgeSelectionOrder = op.origEdgeOrder.dup;
    mesh.syncSelection();
}
