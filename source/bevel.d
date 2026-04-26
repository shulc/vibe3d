module bevel;

import std.math : sin, cos, acos;

import math;
import mesh;

// ---------------------------------------------------------------------------
// BevelWidthMode — controls how the user-facing `width` parameter is mapped
// to the actual offsetSpec on each beveled edge.
//
//   Offset:  offsetSpec = w
//   Width:   offsetSpec = w / (2 * sin(d/2))     where d = exterior dihedral
//   Depth:   offsetSpec = w / cos(d/2)
//   Percent: offsetSpec = edgeLength * w / 100
//
// The exterior dihedral d is the angle between the two adjacent face normals;
// d = 0 for a flat edge (no bevel) and d = π/2 for a 90° cube edge.
// ---------------------------------------------------------------------------

enum BevelWidthMode {
    Offset,
    Width,
    Depth,
    Percent,
}

// Returns the per-unit-user-width offset coefficient for a beveled edge,
// i.e. the value that should be passed to offsetMeet's wPrev/wNext at user
// width = 1. The runtime BoundVert position is then origPos + slideDir * w.
float widthCoefficient(Mesh* mesh, uint edgeIdx, BevelWidthMode mode) {
    final switch (mode) {
        case BevelWidthMode.Offset:
            return 1.0f;
        case BevelWidthMode.Percent: {
            float len = (mesh.vertices[mesh.edges[edgeIdx][1]]
                       - mesh.vertices[mesh.edges[edgeIdx][0]]).length;
            return len / 100.0f;
        }
        case BevelWidthMode.Width: {
            float ext = exteriorDihedral(mesh, edgeIdx);
            float s   = sin(ext * 0.5f);
            if (s < 1e-6f) return 0.0f;     // flat edge — no bevel
            return 1.0f / (2.0f * s);
        }
        case BevelWidthMode.Depth: {
            float ext = exteriorDihedral(mesh, edgeIdx);
            float c   = cos(ext * 0.5f);
            if (c < 1e-6f) return 0.0f;     // 180° dihedral — degenerate
            return 1.0f / c;
        }
    }
}

private float exteriorDihedral(Mesh* mesh, uint edgeIdx) {
    uint[2] fs;
    int n = 0;
    foreach (fi; mesh.facesAroundEdge(edgeIdx)) {
        if (n < 2) fs[n++] = fi;
    }
    if (n < 2) return 0.0f;     // boundary edge → assume flat
    Vec3 n1 = mesh.faceNormal(fs[0]);
    Vec3 n2 = mesh.faceNormal(fs[1]);
    float c = dot(n1, n2);
    if (c >  1.0f) c =  1.0f;
    if (c < -1.0f) c = -1.0f;
    return acos(c);
}

// ---------------------------------------------------------------------------
// Blender-style edge bevel data structures (stage 1).
//
// `bmesh_bevel.cc` terminology, mapped onto Vibe3D's half-edge mesh:
//
//   BevVert    — one beveled-edge endpoint (a vertex about to be split).
//   EdgeHalf   — one of the edges incident to a BevVert (CCW ring).
//   BoundVert  — a vertex on the boundary of the local bevel patch.
//   Profile    — N+1 sample points connecting two adjacent BoundVerts (stage 6).
//   VMesh      — local quad grid filling the bevel patch (stage 7).
//
// This stage 1 implementation handles selCount=1 only (one beveled edge per
// endpoint). For valence-N endpoints we generate N-1 BoundVerts (one per
// non-beveled edge); the BoundVert immediately CCW after the beveled
// EdgeHalf reuses the original vertex (no new vertex is allocated for it).
// Future stages extend this to selCount>=2, profiles, segments and miters.
// ---------------------------------------------------------------------------

struct EdgeHalf {
    uint  edgeIdx;       // index in mesh.edges
    uint  vert;          // BevVert vertex this half-edge anchors at
    bool  isReversed;    // edges[edgeIdx][0] != vert
    bool  isBev;         // ribbon edge is part of the bevel selection
    float offsetLSpec = 0.0f;
    float offsetRSpec = 0.0f;
    float offsetL     = 0.0f;
    float offsetR     = 0.0f;
    int   leftBV  = -1;  // index into BevVert.boundVerts
    int   rightBV = -1;
    uint  fprev   = ~0u; // face on the "prev" CCW side (twin's face)
    uint  fnext   = ~0u; // face containing this dart (CCW "next" side)
}

struct Profile {
    Vec3   start;
    Vec3   middle;
    Vec3   end;
    Vec3   planeNormal;
    float  superR = 2.0f;
    Vec3[] sample;
}

enum VMeshKind {
    POLY,    // single-segment cap polygon
    ADJ,     // Catmull-Clark grid
    TRI_FAN, // terminal-edge fan
    CUTOFF,  // cut-off corner
}

struct BoundVert {
    Vec3    pos;
    // EdgeHalf indices in BevVert.edges flanking this BoundVert in CCW order:
    // ehFromIdx ↔ ehToIdx with ehToIdx == (ehFromIdx + 1) % N. The face the
    // BoundVert lives in is `edges[ehFromIdx].fnext` (== edges[ehToIdx].fprev).
    int     ehFromIdx = -1;
    int     ehToIdx   = -1;
    uint    face      = ~0u;
    Profile profile;
    bool    isOnEdge   = false;  // true when one of the flanking edges is non-bev
    int     vertId     = -1;
    bool    reusesOrig = false;  // when true, vertId == BevVert.vert
    Vec3    slideDir   = Vec3(0, 0, 0);  // (offsetMeet at width=1) - origPos
}

struct VMesh {
    VMeshKind kind = VMeshKind.POLY;
    int       seg  = 1;
    int[]     gridVerts;
}

struct BevVert {
    uint        vert;
    Vec3        origPos;
    EdgeHalf[]  edges;       // CCW ring of incident edges
    int         selCount;    // number of edges with isBev = true
    BoundVert[] boundVerts;
    VMesh       vmesh;
    int         bevEdgeIdx = -1;  // index in edges[] of the (single, stage 1) beveled EdgeHalf
}

// ---------------------------------------------------------------------------
// BevelOp — output of applyEdgeBevelTopology(): everything needed to update
// vertex positions for a new width and to revert the operation.
// ---------------------------------------------------------------------------

struct FaceSnap {
    int    idx;
    uint[] orig;
}

struct BevelOp {
    BevVert[]   bevVerts;

    // Pre-bevel state for revert.
    Vec3[]      origVertices;
    uint[2][]   origEdges;
    bool[]      origSelectedEdges;
    int[]       origEdgeOrder;
    FaceSnap[]  faceSnaps;
    size_t      origVertexCount;
    size_t      origFaceCount;

    // The face index (in mesh.faces) of each bevel quad (one per beveled edge).
    int[]       bevelQuadFaces;
    // Edge indices of the bevel quads (computed after edges are rebuilt).
    int[]       bevelQuadEdges;
}

// ---------------------------------------------------------------------------
// Apply the bevel topology to the mesh. Vertices land at origPos initially;
// call updateEdgeBevelPositions() to slide BoundVerts outward by `width`.
//
// `mode` controls how the user-facing width parameter is mapped to per-edge
// offsetSpec — see BevelWidthMode. The slideDir computed for each BoundVert
// already incorporates the mode coefficient at user width = 1, so the
// runtime update path stays linear.
// ---------------------------------------------------------------------------

BevelOp applyEdgeBevelTopology(Mesh* mesh, const(bool)[] selectedEdges,
                                BevelWidthMode mode = BevelWidthMode.Offset,
                                float widthL = 1.0f, float widthR = 1.0f)
{
    BevelOp op;
    op.origVertexCount   = mesh.vertices.length;
    op.origFaceCount     = mesh.faces.length;
    op.origVertices      = mesh.vertices.dup;
    op.origEdges         = mesh.edges.dup;
    op.origSelectedEdges = selectedEdges.dup;
    op.origEdgeOrder     = mesh.edgeSelectionOrder.dup;

    mesh.buildLoops();

    // Directed-loop map: (u→v) → loop index.
    uint[ulong] dirLoopMap;
    foreach (li, ref lp; mesh.loops) {
        uint u = lp.vert;
        uint v = mesh.loops[lp.next].vert;
        dirLoopMap[(cast(ulong)u << 32) | v] = cast(uint)li;
    }

    bool[int] faceSnapped;

    foreach (ei, sel; selectedEdges) {
        if (!sel || ei >= mesh.edges.length) continue;

        uint va = mesh.edges[ei][0];
        uint vb = mesh.edges[ei][1];

        ulong keyAB = (cast(ulong)va << 32) | vb;
        ulong keyBA = (cast(ulong)vb << 32) | va;
        auto pAB = keyAB in dirLoopMap;
        auto pBA = keyBA in dirLoopMap;
        if (!pAB || !pBA) continue;     // boundary or non-manifold

        uint loopAB = *pAB;             // dart va→vb in face F1
        uint loopBA = *pBA;             // dart vb→va in face F2

        BevVert bvA = buildBevVert(mesh, va, selectedEdges, loopAB);
        BevVert bvB = buildBevVert(mesh, vb, selectedEdges, loopBA);
        populateBoundVerts(mesh, bvA, mode, widthL, widthR);
        populateBoundVerts(mesh, bvB, mode, widthL, widthR);

        materializeBevVert(mesh, bvA, faceSnapped, op.faceSnaps);
        materializeBevVert(mesh, bvB, faceSnapped, op.faceSnaps);

        // Bevel quad replaces the beveled edge. CCW order from outside:
        // [BV_left_a, BV_right_a, BV_left_b, BV_right_b], where
        //   BV_left_*  = corner BV with ehFromIdx == bevEdgeIdx (face fnext side)
        //   BV_right_* = corner BV with ehToIdx   == bevEdgeIdx (face fprev side)
        if (bvA.bevEdgeIdx >= 0 && bvB.bevEdgeIdx >= 0 &&
            bvA.boundVerts.length >= 2 && bvB.boundVerts.length >= 2)
        {
            int qA_l = boundVertIdxForEh  (bvA, bvA.bevEdgeIdx);
            int qA_r = boundVertIdxForEhTo(bvA, bvA.bevEdgeIdx);
            int qB_l = boundVertIdxForEh  (bvB, bvB.bevEdgeIdx);
            int qB_r = boundVertIdxForEhTo(bvB, bvB.bevEdgeIdx);
            if (qA_l >= 0 && qA_r >= 0 && qB_l >= 0 && qB_r >= 0) {
                op.bevelQuadFaces ~= cast(int)mesh.faces.length;
                mesh.faces ~= [
                    cast(uint)bvA.boundVerts[qA_l].vertId,
                    cast(uint)bvA.boundVerts[qA_r].vertId,
                    cast(uint)bvB.boundVerts[qB_l].vertId,
                    cast(uint)bvB.boundVerts[qB_r].vertId,
                ];
            }
        }

        op.bevVerts ~= bvA;
        op.bevVerts ~= bvB;
    }

    rebuildEdgesFromFaces(mesh);
    mesh.buildLoops();
    mesh.syncSelection();

    foreach (fi; op.bevelQuadFaces) {
        if (fi < 0 || fi >= cast(int)mesh.faces.length) continue;
        auto face = mesh.faces[fi];
        foreach (i, _; face) {
            uint a = face[i];
            uint b = face[(i + 1) % face.length];
            uint eidx = mesh.edgeIndex(a, b);
            if (eidx != ~0u) op.bevelQuadEdges ~= cast(int)eidx;
        }
    }

    return op;
}

// ---------------------------------------------------------------------------
// Apply a width: pos = origPos + slideDir * width for every BoundVert.
// ---------------------------------------------------------------------------

void updateEdgeBevelPositions(Mesh* mesh, ref const BevelOp op, float width)
{
    foreach (ref bv; op.bevVerts) {
        foreach (ref bnd; bv.boundVerts) {
            if (bnd.vertId < 0 || bnd.vertId >= cast(int)mesh.vertices.length) continue;
            mesh.vertices[bnd.vertId] = bv.origPos + bnd.slideDir * width;
        }
    }
}

// ---------------------------------------------------------------------------
// Revert the mesh to its pre-bevel state.
// ---------------------------------------------------------------------------

void revertEdgeBevelTopology(Mesh* mesh, ref const BevelOp op)
{
    foreach (ref snap; op.faceSnaps) {
        if (snap.idx >= 0 && snap.idx < cast(int)mesh.faces.length)
            mesh.faces[snap.idx] = snap.orig.dup;
    }
    mesh.vertices.length    = op.origVertexCount;
    mesh.faces.length       = op.origFaceCount;
    mesh.edges              = op.origEdges.dup;
    mesh.selectedEdges      = op.origSelectedEdges.dup;
    mesh.edgeSelectionOrder = op.origEdgeOrder.dup;
    mesh.buildLoops();
    mesh.syncSelection();
}

// ---------------------------------------------------------------------------
// buildBevVert — assemble the EdgeHalf ring around `vert` in CCW order via
// `dartsAroundVertex`. Marks each EdgeHalf whose underlying edge is in
// `selectedEdges`, counts selCount, and records the index of the (single,
// stage 1) beveled EdgeHalf in `bevEdgeIdx`. Pure data: no BoundVerts and
// no mesh mutation. Pass `startDart` to anchor the ring at a specific dart
// (e.g. the dart of a beveled edge so the beveled EdgeHalf sits at index 0);
// `~0u` falls back to `mesh.vertLoop[vert]`.
// ---------------------------------------------------------------------------

BevVert buildBevVert(Mesh* mesh, uint vert, const(bool)[] selectedEdges,
                     uint startDart = ~0u)
{
    BevVert bv;
    bv.vert    = vert;
    bv.origPos = mesh.vertices[vert];

    foreach (li; mesh.dartsAroundVertex(vert, startDart)) {
        uint nextVi = mesh.loops[mesh.loops[li].next].vert;
        ulong undirected = edgeKey(vert, nextVi);
        uint  edgeIdx    = ~0u;
        if (auto p = undirected in mesh.edgeIndexMap) edgeIdx = *p;

        EdgeHalf eh;
        eh.edgeIdx    = edgeIdx;
        eh.vert       = vert;
        eh.isReversed = (edgeIdx != ~0u && mesh.edges[edgeIdx][0] != vert);
        eh.isBev      = (edgeIdx != ~0u && edgeIdx < selectedEdges.length
                         && selectedEdges[edgeIdx]);
        eh.fnext      = mesh.loops[li].face;
        eh.fprev      = (mesh.loops[li].twin != ~0u)
                            ? mesh.loops[mesh.loops[li].twin].face
                            : ~0u;
        bv.edges ~= eh;

        if (eh.isBev) {
            bv.selCount++;
            if (bv.bevEdgeIdx < 0)
                bv.bevEdgeIdx = cast(int)bv.edges.length - 1;
        }
    }
    return bv;
}

// Populate BoundVerts on a BevVert assembled by buildBevVert.
//
// One BoundVert per CCW-adjacent EdgeHalf pair (k, (k+1)%N) where at least
// one of the two is beveled. The BoundVert lives in the common face
// `edges[k].fnext` (== `edges[(k+1)%N].fprev`) and its slide direction is
// (offsetMeet at the resolved per-edge offsets) - origPos.
//
// `widthL` / `widthR` are user widths; the actual per-edge offsetSpec is
// `widthCoefficient(mesh, edgeIdx, mode) * widthSide`. The BoundVert's
// runtime position stays linear in a uniform scale factor:
//     pos = origPos + slideDir * scale.
//
// Edge-canonical L/R: for each beveled edge we pick a single "canonical L
// face" (the first face returned by `facesAroundEdge`) so that widthL refers
// to the same physical side of the edge regardless of which endpoint we are
// processing. Without this, swapping endpoints would swap L↔R and produce a
// twisted asymmetric bevel.
//
// Reuse rule: the first BoundVert encountered whose left flanking EdgeHalf
// is the beveled one reuses the original vertex; the rest are allocated
// fresh in materialize.
void populateBoundVerts(Mesh* mesh, ref BevVert bv,
                        BevelWidthMode mode = BevelWidthMode.Offset,
                        float widthL = 1.0f, float widthR = 1.0f)
{
    if (bv.selCount < 1) return;

    // Resolve per-edge offsetSpec from the chosen width mode + per-side widths.
    foreach (ref eh; bv.edges) {
        if (!eh.isBev) {
            eh.offsetLSpec = 0.0f;
            eh.offsetRSpec = 0.0f;
            continue;
        }
        float c = widthCoefficient(mesh, eh.edgeIdx, mode);
        // Determine which of this EdgeHalf's flanking faces is the canonical
        // L face (the first face from facesAroundEdge).
        uint canonLFace = ~0u;
        foreach (fi; mesh.facesAroundEdge(eh.edgeIdx)) { canonLFace = fi; break; }
        bool nextIsCanonL = (eh.fnext == canonLFace);
        eh.offsetLSpec = c * (nextIsCanonL ? widthL : widthR);
        eh.offsetRSpec = c * (nextIsCanonL ? widthR : widthL);
    }

    int N = cast(int)bv.edges.length;
    bool reuseAssigned = false;

    foreach (k; 0 .. N) {
        int knext = (k + 1) % N;
        EdgeHalf eh1 = bv.edges[k];
        EdgeHalf eh2 = bv.edges[knext];
        if (!eh1.isBev && !eh2.isBev) continue;

        Vec3 ePrev = computeSlideDirForEdge(mesh, bv, knext); // toward prevV in face
        Vec3 eNext = computeSlideDirForEdge(mesh, bv, k);     // toward nextV in face
        Vec3 faceN = mesh.faceNormal(eh1.fnext);
        // The corner sits in face `eh1.fnext == eh2.fprev`. From this corner's
        // viewpoint, eh2 acts as the prev side (use its right offsetSpec) and
        // eh1 acts as the next side (use its left offsetSpec). Per-side
        // distinction matters from stage 5 onward — here both sides are equal.
        float wPrev = eh2.isBev ? eh2.offsetRSpec : 0.0f;
        float wNext = eh1.isBev ? eh1.offsetLSpec : 0.0f;
        Vec3 meetUnit = offsetMeet(bv.origPos, ePrev, eNext, faceN, wPrev, wNext);

        BoundVert bnd;
        bnd.ehFromIdx  = cast(int)k;
        bnd.ehToIdx    = cast(int)knext;
        bnd.face       = eh1.fnext;
        bnd.isOnEdge   = !(eh1.isBev && eh2.isBev);
        bnd.slideDir   = meetUnit - bv.origPos;
        bnd.pos        = bv.origPos;

        // Reuse rule: first BV after the first beveled EdgeHalf in CCW.
        if (!reuseAssigned && eh1.isBev) {
            bnd.reusesOrig = true;
            bnd.vertId     = cast(int)bv.vert;
            reuseAssigned  = true;
        }

        bv.boundVerts ~= bnd;
    }

    bv.vmesh.kind = VMeshKind.POLY;
    bv.vmesh.seg  = 1;
}

private Vec3 computeSlideDirForEdge(Mesh* mesh, ref const BevVert bv, int ehIdx)
{
    EdgeHalf eh = bv.edges[ehIdx];
    if (eh.edgeIdx == ~0u) return Vec3(0, 0, 0);
    uint other = (mesh.edges[eh.edgeIdx][0] == bv.vert)
                 ? mesh.edges[eh.edgeIdx][1]
                 : mesh.edges[eh.edgeIdx][0];
    return safeNormalize(mesh.vertices[other] - bv.origPos);
}

private int leftEhIdx(ref const BevVert bv) {
    int N = cast(int)bv.edges.length;
    return (bv.bevEdgeIdx + 1) % N;
}

private int rightEhIdx(ref const BevVert bv) {
    int N = cast(int)bv.edges.length;
    return (bv.bevEdgeIdx + N - 1) % N;
}

// Find the BoundVert whose left flanking EdgeHalf (ehFromIdx) is `ehIdx`.
private int boundVertIdxForEh(ref const BevVert bv, int ehIdx) {
    foreach (i, ref bnd; bv.boundVerts)
        if (bnd.ehFromIdx == ehIdx) return cast(int)i;
    return -1;
}

// Find the BoundVert whose right flanking EdgeHalf (ehToIdx) is `ehIdx`.
private int boundVertIdxForEhTo(ref const BevVert bv, int ehIdx) {
    foreach (i, ref bnd; bv.boundVerts)
        if (bnd.ehToIdx == ehIdx) return cast(int)i;
    return -1;
}

// Assign new vertex ids, snapshot faces, patch each face around bv.vert.
// Stage 3 layout: BoundVerts live at corners between consecutive EdgeHalfs.
//   - F = edges[bevEdgeIdx].fnext: corner BV is the one with ehFromIdx==bevEdgeIdx
//     (BoundVert between the bev EH and the next EH in CCW). When reused, no
//     face-index change.
//   - F = edges[bevEdgeIdx].fprev: corner BV is the one with ehToIdx==bevEdgeIdx
//     (BoundVert between the prev EH and the bev EH).
//   - F_other (face between two non-bev EdgeHalfs k, (k+1)%N): insert
//     [BV(ehFromIdx=(k+1)%N), BV(ehToIdx=k)] at the corner — pulled in from
//     the two neighboring face corners.
private void materializeBevVert(Mesh* mesh, ref BevVert bv,
                                ref bool[int] faceSnapped,
                                ref FaceSnap[] faceSnaps)
{
    if (bv.bevEdgeIdx < 0 || bv.boundVerts.length == 0) return;

    foreach (ref bnd; bv.boundVerts)
        if (!bnd.reusesOrig)
            bnd.vertId = cast(int)mesh.addVertex(bv.origPos);

    int N = cast(int)bv.edges.length;
    uint fBevNext = bv.edges[bv.bevEdgeIdx].fnext;
    uint fBevPrev = bv.edges[bv.bevEdgeIdx].fprev;

    foreach (k; 0 .. N) {
        uint faceIdx = bv.edges[k].fnext;
        if (faceIdx >= cast(uint)mesh.faces.length) continue;

        snapshotFace(mesh, faceIdx, faceSnapped, faceSnaps);

        if (faceIdx == fBevNext) {
            int bIdx = boundVertIdxForEh(bv, bv.bevEdgeIdx);
            if (bIdx < 0) continue;
            uint vid = cast(uint)bv.boundVerts[bIdx].vertId;
            if (vid != bv.vert)
                replaceVertInFace(mesh, faceIdx, bv.vert, vid);
            continue;
        }

        if (faceIdx == fBevPrev) {
            int bIdx = boundVertIdxForEhTo(bv, bv.bevEdgeIdx);
            if (bIdx < 0) continue;
            uint vid = cast(uint)bv.boundVerts[bIdx].vertId;
            if (vid != bv.vert)
                replaceVertInFace(mesh, faceIdx, bv.vert, vid);
            continue;
        }

        // F_other: prev-entering edge in this face = edges[(k+1)%N],
        // next-leaving edge = edges[k]. The two BVs to splice in come from
        // the two adjacent face corners.
        int bvPrevIdx = boundVertIdxForEh(bv, (k + 1) % N);
        int bvNextIdx = boundVertIdxForEhTo(bv, cast(int)k);
        if (bvPrevIdx < 0 || bvNextIdx < 0) continue;

        spliceInTwoAtCorner(mesh, faceIdx, bv.vert,
                            cast(uint)bv.boundVerts[bvPrevIdx].vertId,
                            cast(uint)bv.boundVerts[bvNextIdx].vertId);
    }
}

private void snapshotFace(Mesh* mesh, uint faceIdx,
                          ref bool[int] faceSnapped, ref FaceSnap[] faceSnaps)
{
    if (cast(int)faceIdx in faceSnapped) return;
    FaceSnap snap = { idx: cast(int)faceIdx, orig: mesh.faces[faceIdx].dup };
    faceSnaps ~= snap;
    faceSnapped[cast(int)faceIdx] = true;
}

private void replaceVertInFace(Mesh* mesh, uint faceIdx, uint oldV, uint newV)
{
    foreach (ref vi; mesh.faces[faceIdx])
        if (vi == oldV) { vi = newV; return; }
}

private void spliceInTwoAtCorner(Mesh* mesh, uint faceIdx,
                                 uint corner, uint bvPrev, uint bvNext)
{
    auto face = mesh.faces[faceIdx];
    int idx = -1;
    foreach (i, vi; face) if (vi == corner) { idx = cast(int)i; break; }
    if (idx < 0) return;

    uint[] newFace;
    newFace.reserve(face.length + 1);
    newFace ~= face[0 .. idx];
    newFace ~= bvPrev;
    newFace ~= bvNext;
    newFace ~= face[idx + 1 .. $];
    mesh.faces[faceIdx] = newFace;
}

private void rebuildEdgesFromFaces(Mesh* mesh)
{
    mesh.edges = [];
    bool[ulong] seen;
    foreach (face; mesh.faces) {
        foreach (i, _; face) {
            uint u = face[i];
            uint w = face[(i + 1) % face.length];
            ulong key = edgeKey(u, w);
            if (key !in seen) {
                seen[key] = true;
                mesh.edges ~= [u, w];
            }
        }
    }
}
