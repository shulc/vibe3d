module bevel;

import math;
import mesh;

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
    int     ehFromIdx = -1;   // index into BevVert.edges of the EdgeHalf this BV sits on
    int     ehToIdx   = -1;
    Profile profile;
    bool    isOnEdge   = false;
    int     vertId     = -1;
    bool    reusesOrig = false;  // when true, vertId == BevVert.vert
    Vec3    slideDir   = Vec3(0, 0, 0);
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
// ---------------------------------------------------------------------------

BevelOp applyEdgeBevelTopology(Mesh* mesh, const(bool)[] selectedEdges)
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
        populateBoundVerts(mesh, bvA);
        populateBoundVerts(mesh, bvB);

        materializeBevVert(mesh, bvA, faceSnapped, op.faceSnaps);
        materializeBevVert(mesh, bvB, faceSnapped, op.faceSnaps);

        // Bevel quad replaces the beveled edge. Shared with patched faces:
        //   (BV_left_a, BV_right_a) shared with F_other_a (=F5 for cube),
        //   (BV_right_a, BV_left_b) shared with edges[bev].fprev,
        //   (BV_left_b, BV_right_b) shared with F_other_b,
        //   (BV_right_b, BV_left_a) shared with edges[bev].fnext.
        // CCW order from outside: [BV_left_a, BV_right_a, BV_left_b, BV_right_b].
        if (bvA.bevEdgeIdx >= 0 && bvB.bevEdgeIdx >= 0 &&
            bvA.boundVerts.length >= 2 && bvB.boundVerts.length >= 2)
        {
            int qA_l = boundVertIdxForEh(bvA, leftEhIdx(bvA));
            int qA_r = boundVertIdxForEh(bvA, rightEhIdx(bvA));
            int qB_l = boundVertIdxForEh(bvB, leftEhIdx(bvB));
            int qB_r = boundVertIdxForEh(bvB, rightEhIdx(bvB));
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

// Populate BoundVerts on a BevVert assembled by buildBevVert. Stage 1 only
// handles selCount == 1: one BoundVert per non-beveled EdgeHalf, the one
// immediately CCW after the beveled EdgeHalf reuses the original vertex.
private void populateBoundVerts(Mesh* mesh, ref BevVert bv)
{
    if (bv.selCount != 1 || bv.bevEdgeIdx < 0) return;

    int N = cast(int)bv.edges.length;
    int leftIdx = (bv.bevEdgeIdx + 1) % N;

    foreach (k; 0 .. N) {
        if (k == bv.bevEdgeIdx) continue;

        BoundVert bnd;
        bnd.ehFromIdx  = cast(int)k;
        bnd.ehToIdx    = cast(int)k;
        bnd.isOnEdge   = true;
        bnd.slideDir   = computeSlideDirForEdge(mesh, bv, cast(int)k);
        bnd.pos        = bv.origPos;
        bnd.reusesOrig = (cast(int)k == leftIdx);
        bnd.vertId     = bnd.reusesOrig ? cast(int)bv.vert : -1;
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

private int boundVertIdxForEh(ref const BevVert bv, int ehIdx) {
    foreach (i, ref bnd; bv.boundVerts)
        if (bnd.ehFromIdx == ehIdx) return cast(int)i;
    return -1;
}

// Assign new vertex ids, snapshot faces, patch each face around bv.vert:
//   - F = edges[bevEdgeIdx].fnext: keep bv.vert (BV_left = bv.vert).
//   - F = edges[bevEdgeIdx].fprev: replace bv.vert with BV_right (new vert).
//   - F_other: insert [BV on prev edge, BV on next edge] at the corner.
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
            // BV_left at corner = bv.vert (reused). No index change.
            continue;
        }

        if (faceIdx == fBevPrev) {
            // BV_right at corner = new vert.
            int bIdx = boundVertIdxForEh(bv, rightEhIdx(bv));
            if (bIdx < 0) continue;
            replaceVertInFace(mesh, faceIdx, bv.vert,
                              cast(uint)bv.boundVerts[bIdx].vertId);
            continue;
        }

        // F_other: prev-entering edge = edges[(k+1) % N], next-leaving edge = edges[k].
        int prevEhIdx = (k + 1) % N;
        int nextEhIdx = k;
        int bvPrevIdx = boundVertIdxForEh(bv, prevEhIdx);
        int bvNextIdx = boundVertIdxForEh(bv, nextEhIdx);
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
