module bevel;

import std.math : sin, cos, acos, pow, fabs, sqrt, PI;

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

// Miter pattern at corners where the bevel changes direction. Sharp is the
// default (Blender's "SHARP") — strips meet at the original vertex via
// existing sharp-miter logic. Arc inserts curved patch geometry at reflex
// corners (Blender's miter_inner="ARC"), used for stylized bevels.
enum MiterPattern {
    Sharp,
    Arc,
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

// Largest user-facing width that won't push any BoundVert past the far end
// of an adjacent non-bev edge (which would invert geometry).
//
// At each endpoint of every beveled edge, the BV slides along each adjacent
// non-bev edge. For a 90° corner that slide distance equals the offset; for
// other angles it's offset / sin(angle). A safe conservative bound is half
// the shortest such adjacent non-bev edge — that handles both 90° corners
// (BV reaches midpoint) and the case where bev edges sit at both ends of
// the same non-bev edge (each slides up to half the length).
//
// `currentMode` is needed because Width/Depth/Percent modes scale the
// user width before it becomes the actual offsetSpec; we invert that
// scaling so the returned limit is in the SAME units as the user's width.
//
// Returns float.infinity if no beveled edges have any non-bev neighbors.
float computeLimitOffset(Mesh* mesh, bool[] selectedEdges,
                         BevelWidthMode mode = BevelWidthMode.Offset) {
    float limit = float.infinity;
    foreach (ei, sel; selectedEdges) {
        if (!sel || ei >= mesh.edges.length) continue;
        // The user's width is multiplied by widthCoefficient(ei, mode) to
        // yield the actual offsetSpec on this edge. Invert the coefficient
        // so the returned limit applies to the user's width directly.
        float coef = widthCoefficient(mesh, cast(uint)ei, mode);
        if (coef < 1e-6f) continue;          // flat / degenerate — no constraint
        uint[2] endpoints = [mesh.edges[ei][0], mesh.edges[ei][1]];
        foreach (vi; endpoints) {
            Vec3 vp = mesh.vertices[vi];
            foreach (otherEi; mesh.edgesAroundVertex(vi)) {
                if (otherEi == cast(uint)ei) continue;
                if (otherEi < selectedEdges.length && selectedEdges[otherEi])
                    continue;             // other bev edge — both ends pull, handled by its own pass
                Vec3 op = mesh.vertices[mesh.edgeOtherVertex(otherEi, vi)];
                float halfLen = (op - vp).length * 0.5f;
                float perEdge = halfLen / coef;
                if (perEdge < limit) limit = perEdge;
            }
        }
    }
    return limit;
}

// True iff at least one beveled EdgeHalf incident to bv.vert has reflex
// dihedral (interior angle on the bulk side > 180°). Used to trigger
// Blender's sharp-miter-at-reflex behavior in populateBoundVerts.
//
// Reflex test (for an edge with adjacent faces F1 and F2, where F1 has the
// edge in its CCW forward direction): cross(n_F1, n_F2) is anti-aligned with
// the F1-forward edge direction iff the dihedral is reflex. Equivalently, the
// signed sine of the dihedral angle (about the edge axis) is negative.
private bool hasAnyReflexBevEdge(Mesh* mesh, ref const BevVert bv) {
    foreach (ref eh; bv.edges) {
        if (!eh.isBev || eh.edgeIdx == ~0u) continue;
        if (eh.fnext >= cast(uint)mesh.faces.length) continue;
        if (eh.fprev >= cast(uint)mesh.faces.length) continue;
        // Pick F1 = the face whose CCW winding traverses the edge in the
        // same direction as a fixed orientation, F2 = the other face. Use
        // fnext as F1; the edge in fnext goes from bv.vert toward
        // edgeOtherVertex by construction.
        Vec3 n1 = mesh.faceNormal(eh.fnext);
        Vec3 n2 = mesh.faceNormal(eh.fprev);
        uint other = mesh.edgeOtherVertex(eh.edgeIdx, bv.vert);
        Vec3 fwd  = safeNormalize(mesh.vertices[other] - bv.origPos);
        if (dot(cross(n1, n2), fwd) < -1e-4f) return true;
    }
    return false;
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
    Vec3   start;            // BoundVert position (sample[0])
    Vec3   middle;           // bv.origPos — original vertex
    Vec3   end;              // next BoundVert position (sample[seg])
    Vec3   planeNormal;      // sum of adjacent face normals (unit)
    float  superR = 2.0f;    // 2 = circle, 1 = straight line, 4 = closer to square
    Vec3[] sample;           // seg+1 points along the super-ellipse curve
    int[]  sampleVertIds;    // seg+1 mesh vertex ids (filled in materialize)
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
    // For selCount ≥ 2: two consecutive corner BoundVerts may slide on the
    // SAME non-beveled edge (one from each flanking face). They must be the
    // same mesh vertex to keep the topology manifold. The later sibling sets
    // aliasOf := index of the earlier one in BevVert.boundVerts and shares
    // its vertId / position; cap-polygon construction skips aliases.
    int     aliasOf    = -1;
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
    // M_ADJ cap canonical grid (selCount == valence, even seg ≥ 2). Indexing
    // matches Blender's bmesh_bevel.cc:
    //   adjGridVids[i * (ns2 + 1) * (ns + 1) + j * (ns + 1) + k] for canonical
    //   (i, j, k); non-canonical (i, j, k) are resolved through `adjCanonVid`.
    // adjGridDirs[idx] stores (positionAtUnitWidth - origPos) for linear width
    // scaling in updateEdgeBevelPositions. The center (only canonical at
    // i=0, j=ns2, k=ns2 for even ns) is stored separately as adjCenterVid /
    // adjCenterDir for readability.
    int         adjCenterVid = -1;
    Vec3        adjCenterDir = Vec3(0, 0, 0);
    int[]       adjGridVids;
    Vec3[]      adjGridDirs;
    MiterPattern miterInner = MiterPattern.Sharp;
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
                                float widthL = 1.0f, float widthR = 1.0f,
                                int seg = 1, float superR = 2.0f,
                                MiterPattern miterInner = MiterPattern.Sharp)
{
    if (seg < 1)  seg = 1;
    if (seg > 64) seg = 64;
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

    // 1) Collect every vertex that is incident to at least one beveled edge.
    bool[uint] bevVertSet;
    foreach (ei, sel; selectedEdges) {
        if (!sel || ei >= mesh.edges.length) continue;
        bevVertSet[mesh.edges[ei][0]] = true;
        bevVertSet[mesh.edges[ei][1]] = true;
    }

    // 2) For every beveled vertex pick a starting dart anchored at one of its
    //    beveled edges (so EdgeHalf[bevEdgeIdx] sits at index 0 of the ring),
    //    then build/populate a single BevVert that covers all incident
    //    beveled edges (selCount may be ≥ 1).
    BevVert[uint] bvByVert;
    foreach (vert; bevVertSet.keys) {
        uint startDart = ~0u;
        foreach (ei, sel; selectedEdges) {
            if (!sel || ei >= mesh.edges.length) continue;
            uint va = mesh.edges[ei][0];
            uint vb = mesh.edges[ei][1];
            uint other = (va == vert) ? vb : (vb == vert ? va : ~0u);
            if (other == ~0u) continue;
            ulong key = (cast(ulong)vert << 32) | other;
            if (auto p = key in dirLoopMap) { startDart = *p; break; }
        }
        BevVert bv = buildBevVert(mesh, vert, selectedEdges, startDart);
        populateBoundVerts(mesh, bv, mode, widthL, widthR, seg, superR, miterInner);
        materializeBevVert(mesh, bv, faceSnapped, op.faceSnaps);

        // For selCount ≥ 2 there is no F_other left to absorb the BoundVert
        // ring — every face around bv.vert had its corner replaced by a BV.
        // Close the open cap. Two layouts:
        //   - useMAdj(bv): N quads sharing a center vertex (one Catmull-Clark
        //     step on the BoundVert ring). Each quad is bounded by a corner
        //     BV, two cap-profile midpoints (which are also strip cross-section
        //     midpoints — see strip emission below), and the center.
        //   - Otherwise: a single N-gon connecting all non-aliased BVs in CCW.
        if (bv.selCount >= 2 && bv.boundVerts.length >= 3) {
            int[] capBvs;
            foreach (i, ref bnd; bv.boundVerts) {
                if (bnd.aliasOf >= 0) continue;  // collapsed onto an earlier BV
                capBvs ~= cast(int)i;
            }
            if (capBvs.length >= 3) {
                if (useMAdj(bv)) {
                    // M_ADJ cap quads. Per panel i ∈ [0, n), per (j, k) ∈
                    // [0, ns2-1] × [0, ns2-1+odd]: emit a quad whose corners
                    // are (i, j, k), (i, j, k+1), (i, j+1, k+1), (i, j+1, k)
                    // resolved through the canon mapping.
                    //   even seg: ns2 × ns2 quads per panel, all sharing the
                    //             center vertex at (i, ns2, ns2).
                    //   odd seg:  ns2 × (ns2+1) quads per panel; the n
                    //             interior verts at (i, ns2, ns2) form a
                    //             central n-gon emitted below.
                    int n   = cast(int)bv.boundVerts.length;
                    int ns  = bv.vmesh.seg;
                    int ns2 = ns / 2;
                    int odd = ns % 2;
                    foreach (pi; 0 .. n) {
                        foreach (jj; 0 .. ns2) {
                            foreach (kk; 0 .. ns2 + odd) {
                                int v00 = adjCanonVid(bv, pi, jj,     kk);
                                int v01 = adjCanonVid(bv, pi, jj,     kk + 1);
                                int v11 = adjCanonVid(bv, pi, jj + 1, kk + 1);
                                int v10 = adjCanonVid(bv, pi, jj + 1, kk);
                                if (v00 < 0 || v01 < 0 || v11 < 0 || v10 < 0)
                                    continue;
                                mesh.faces ~= [
                                    cast(uint)v00, cast(uint)v01,
                                    cast(uint)v11, cast(uint)v10,
                                ];
                            }
                        }
                    }
                    // Central n-gon for odd seg: connect interior verts
                    // (i, ns2, ns2) for i ∈ [0, n) in increasing-i order so
                    // the polygon's outward normal matches the cap quads
                    // (each cap edge is shared with exactly one quad whose
                    // boundary traverses it in the opposite direction).
                    if (odd) {
                        uint[] central;
                        central.reserve(n);
                        bool ok = true;
                        foreach (pi; 0 .. n) {
                            int v = adjCanonVid(bv, cast(int)pi, ns2, ns2);
                            if (v < 0) { ok = false; break; }
                            central ~= cast(uint)v;
                        }
                        if (ok) mesh.faces ~= central;
                    }
                } else {
                    uint[] cap;
                    cap.reserve(capBvs.length);
                    foreach (i; capBvs)
                        cap ~= cast(uint)bv.boundVerts[i].vertId;
                    mesh.faces ~= cap;
                }
            }
        }
        bvByVert[vert] = bv;
    }

    // 3) For every beveled edge, build the bevel-quad strip joining the two
    //    endpoints' "left/right" cap-profile BoundVerts.
    foreach (ei, sel; selectedEdges) {
        if (!sel || ei >= mesh.edges.length) continue;
        uint va = mesh.edges[ei][0];
        uint vb = mesh.edges[ei][1];
        auto pBvA = va in bvByVert;
        auto pBvB = vb in bvByVert;
        if (pBvA is null || pBvB is null) continue;

        // Find the EdgeHalf index in each endpoint's ring that points at this
        // beveled edge — for selCount ≥ 2 we can no longer rely on the cached
        // bv.bevEdgeIdx (which only stores the *first* beveled EH in the ring).
        int ehAIdx = findEhIdxForEdge(*pBvA, cast(uint)ei);
        int ehBIdx = findEhIdxForEdge(*pBvB, cast(uint)ei);
        if (ehAIdx < 0 || ehBIdx < 0) continue;

        int qA_l = boundVertIdxForEh  (*pBvA, ehAIdx);
        int qA_r = boundVertIdxForEhTo(*pBvA, ehAIdx);
        int qB_l = boundVertIdxForEh  (*pBvB, ehBIdx);
        int qB_r = boundVertIdxForEhTo(*pBvB, ehBIdx);
        if (qA_l < 0 || qA_r < 0 || qB_l < 0 || qB_r < 0) continue;

        // sa/sb are the strip cross-sections at v_a / v_b: a `seg+1`-long
        // sequence of mesh vert ids running from qX_l (canonical L face) to
        // qX_r (canonical R face). Two layouts:
        //   - selCount == 1: qX_l's CCW-next BV is qX_r, so qX_l's cap
        //     profile already runs from qX_l to qX_r through F_other.
        //   - useMAdj(bv): qX_r's CCW-next BV is qX_l (closed BoundVert
        //     ring). qX_r's cap profile runs qX_r → qX_l, so reversing it
        //     yields the strip cross-section qX_l → qX_r passing through the
        //     M_ADJ midpoint that's also shared with the cap quads.
        int[] capSamples(ref BevVert bv, int qL, int qR) {
            if (bv.selCount == 1) return bv.boundVerts[qL].profile.sampleVertIds.dup;
            if (useMAdj(bv)) {
                auto p = bv.boundVerts[qR].profile.sampleVertIds;
                int[] r;
                r.length = p.length;
                foreach (i, _; p) r[i] = p[$ - 1 - i];
                return r;
            }
            // selCount ≥ 2 without M_ADJ — typically the alias case with two
            // bev EHs flanking a single non-bev EH (selCount=2 valence=3 etc.).
            // The unique cap edge runs between the chosen leftBV and its
            // CCW-next; midpoints are allocated only on leftBV's profile.
            // Use it forward when qL == leftBV, reversed when qR == leftBV.
            // The leftBV picked here must match materializeBevVert's choice —
            // it scans for a non-degenerate profile (i.e. CCW-next is not
            // alias-merged back to it), so the cap edge is geometrically real.
            int leftBV = -1;
            int M = cast(int)bv.boundVerts.length;
            foreach (i; 0 .. M) {
                if (bv.boundVerts[i].aliasOf >= 0) continue;
                int nextI = (cast(int)i + 1) % M;
                if (bv.boundVerts[nextI].aliasOf == cast(int)i) continue;
                leftBV = cast(int)i;
                break;
            }
            if (leftBV < 0)
                leftBV = boundVertIdxForEh(bv, bv.bevEdgeIdx);
            if (leftBV < 0) return null;
            if (qL == leftBV) return bv.boundVerts[leftBV].profile.sampleVertIds.dup;
            if (qR == leftBV) {
                auto p = bv.boundVerts[leftBV].profile.sampleVertIds;
                int[] r;
                r.length = p.length;
                foreach (i, _; p) r[i] = p[$ - 1 - i];
                return r;
            }
            return null;
        }
        int[] sa = capSamples(*pBvA, qA_l, qA_r);
        int[] sb = capSamples(*pBvB, qB_l, qB_r);
        int strip = (sa.length > 0) ? cast(int)sa.length - 1 : 0;

        bool useProfileStrip = strip >= 2
                               && sb.length == sa.length;
        if (!useProfileStrip) {
            op.bevelQuadFaces ~= cast(int)mesh.faces.length;
            mesh.faces ~= [
                cast(uint)pBvA.boundVerts[qA_l].vertId,
                cast(uint)pBvA.boundVerts[qA_r].vertId,
                cast(uint)pBvB.boundVerts[qB_l].vertId,
                cast(uint)pBvB.boundVerts[qB_r].vertId,
            ];
        } else {
            foreach (kk; 0 .. strip) {
                op.bevelQuadFaces ~= cast(int)mesh.faces.length;
                mesh.faces ~= [
                    cast(uint)sa[kk],
                    cast(uint)sa[kk + 1],
                    cast(uint)sb[strip - kk - 1],
                    cast(uint)sb[strip - kk],
                ];
            }
        }
    }

    foreach (vert; bvByVert.keys)
        op.bevVerts ~= bvByVert[vert];

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
// Scale all BoundVerts and their profile sample vertices by `width`. The
// BoundVerts themselves slide via origPos + slideDir * width; intermediate
// profile sample points are shifted by the same `width` factor relative to
// origPos along the parametric profile curve direction.
// ---------------------------------------------------------------------------

void updateEdgeBevelPositions(Mesh* mesh, ref const BevelOp op, float width)
{
    foreach (ref bv; op.bevVerts) {
        foreach (ref bnd; bv.boundVerts) {
            if (bnd.vertId >= 0 && bnd.vertId < cast(int)mesh.vertices.length)
                mesh.vertices[bnd.vertId] = bv.origPos + bnd.slideDir * width;
        }
        // Non-M_ADJ profile intermediates (selCount==1 leftBV cap profile
        // splice into F_other). M_ADJ paths route every profile through the
        // canonical grid below, so their direct sampleVertIds writes would
        // be redundant — keep them anyway for safety; the grid pass writes
        // the same position.
        foreach (ref bnd; bv.boundVerts) {
            auto p = &bnd.profile;
            int seg = cast(int)p.sample.length - 1;
            if (seg <= 1) continue;
            foreach (k; 1 .. seg) {
                int vid = (k < cast(int)p.sampleVertIds.length) ? p.sampleVertIds[k] : -1;
                if (vid < 0 || vid >= cast(int)mesh.vertices.length) continue;
                mesh.vertices[vid] = bv.origPos + (p.sample[k] - bv.origPos) * width;
            }
        }
        // M_ADJ canonical grid: every interior + boundary canonical position.
        foreach (idx, vid; bv.adjGridVids) {
            if (vid < 0 || vid >= cast(int)mesh.vertices.length) continue;
            mesh.vertices[vid] = bv.origPos + bv.adjGridDirs[idx] * width;
        }
        if (bv.adjCenterVid >= 0
            && bv.adjCenterVid < cast(int)mesh.vertices.length)
            mesh.vertices[bv.adjCenterVid] = bv.origPos + bv.adjCenterDir * width;
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
    // Restore vertex POSITIONS as well, not just the array length. The first
    // apply may have slid reused-vertex BoundVerts (e.g. v_0 → 0.3 along a
    // non-bev edge); without restoring those positions, a follow-up apply
    // would read the slid coordinates as bv.origPos and chain another offset
    // on top — producing a cumulative, ever-drifting bevel on every mode/
    // width change.
    mesh.vertices           = op.origVertices.dup;
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
                        float widthL = 1.0f, float widthR = 1.0f,
                        int seg = 1, float superR = 2.0f,
                        MiterPattern miterInner = MiterPattern.Sharp)
{
    bv.miterInner = miterInner;
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
        bnd.pos        = meetUnit;

        // Reuse rule: first BV after the first beveled EdgeHalf in CCW.
        if (!reuseAssigned && eh1.isBev) {
            bnd.reusesOrig = true;
            bnd.vertId     = cast(int)bv.vert;
            reuseAssigned  = true;
        }

        bv.boundVerts ~= bnd;
    }

    // selCount ≥ 2 may produce two consecutive isOnEdge BoundVerts that both
    // slide on the SAME non-beveled edge (one from each adjacent face). They
    // must collapse to one mesh vertex to keep the topology manifold; mark
    // the later one as an alias of the earlier and copy its position so any
    // downstream consumer (cap polygon, profile sample) sees a single point.
    int M = cast(int)bv.boundVerts.length;
    foreach (i; 0 .. M) {
        auto bnd = &bv.boundVerts[i];
        if (!bnd.isOnEdge || bnd.aliasOf >= 0) continue;
        // The non-beveled flanking EH index of this corner.
        int slideEh = bv.edges[bnd.ehFromIdx].isBev ? bnd.ehToIdx : bnd.ehFromIdx;
        foreach (j; 0 .. cast(int)i) {
            auto bnd2 = &bv.boundVerts[j];
            if (!bnd2.isOnEdge || bnd2.aliasOf >= 0) continue;
            int slideEh2 = bv.edges[bnd2.ehFromIdx].isBev ? bnd2.ehToIdx : bnd2.ehFromIdx;
            // Same non-bev slide edge AND coincident positions → genuine
            // weld (selCount ≥ 2 with two BVs landing on the same non-bev
            // edge from different faces). For selCount=1 valence=2 with
            // collinear non-bev support the BVs share the slide-edge index
            // but sit at DIFFERENT perpendicular positions on each face —
            // those must stay independent.
            Vec3 d = bnd.pos - bnd2.pos;
            if (slideEh == slideEh2 && d.length < 1e-4f) {
                bnd.aliasOf    = j;
                bnd.pos        = bnd2.pos;
                bnd.slideDir   = bnd2.slideDir;
                // Don't propagate reusesOrig — only the canonical alias-target
                // BV may own bv.vert.
                break;
            }
        }
    }

    // Stage 9e Sharp miter at reflex (selCount ≥ 2, miterInner=Sharp): when
    // at least one beveled edge has reflex dihedral, force all BVs in
    // non-BEV-BEV faces to collapse onto bv.vert. Skipped for Arc miter,
    // which generates patch geometry in materializeBevVert instead.
    if (bv.selCount >= 2 && bv.miterInner == MiterPattern.Sharp
        && hasAnyReflexBevEdge(mesh, bv)) {
        // Pick the earliest non-BEV-BEV BV as the anchor sitting at bv.vert.
        // Subsequent same-class BVs alias to it (aliasOf must point to an
        // earlier index, so anchor must come first in iteration).
        int anchor = -1;
        foreach (i, ref bnd; bv.boundVerts) {
            if (bnd.aliasOf >= 0) continue;
            EdgeHalf ehFrom = bv.edges[bnd.ehFromIdx];
            EdgeHalf ehTo   = bv.edges[bnd.ehToIdx];
            if (ehFrom.isBev && ehTo.isBev) continue;  // BEV-BEV face — keep
            anchor = cast(int)i;
            break;
        }
        if (anchor >= 0) {
            // Move reusesOrig to the anchor so it owns bv.vert.
            foreach (i, ref bnd; bv.boundVerts)
                if (cast(int)i != anchor) bnd.reusesOrig = false;
            bv.boundVerts[anchor].reusesOrig = true;
            bv.boundVerts[anchor].vertId     = cast(int)bv.vert;
            bv.boundVerts[anchor].pos        = bv.origPos;
            bv.boundVerts[anchor].slideDir   = Vec3(0, 0, 0);
            // Alias every other non-BEV-BEV BV to the anchor.
            foreach (i, ref bnd; bv.boundVerts) {
                if (cast(int)i == anchor || bnd.aliasOf >= 0) continue;
                EdgeHalf ehFrom = bv.edges[bnd.ehFromIdx];
                EdgeHalf ehTo   = bv.edges[bnd.ehToIdx];
                if (ehFrom.isBev && ehTo.isBev) continue;
                bnd.aliasOf  = anchor;
                bnd.pos      = bv.origPos;
                bnd.slideDir = Vec3(0, 0, 0);
            }
        }
    }

    // Compute each BoundVert's profile (curve to the next BV in CCW). Stage 6
    // fills positions only; vertex ids are assigned in materializeBevVert.
    foreach (i; 0 .. M) {
        auto next = (i + 1) % M;
        bv.boundVerts[i].profile = computeProfile(mesh, bv,
                                                   bv.boundVerts[i],
                                                   bv.boundVerts[next],
                                                   seg, superR);
    }

    bv.vmesh.kind = (seg == 1) ? VMeshKind.POLY : VMeshKind.ADJ;
    bv.vmesh.seg  = seg;
}

// Sample a quarter super-ellipse curve from `start` to `end` with the curve
// bulging away from `middle`. The map sends (1, 0) → start, (0, 1) → end,
// and (u, v) on the unit super-ellipse |u|^r + |v|^r = 1 in the first
// quadrant onto the curve via the CONVEX-bevel parameterization
//   P(u, v) = origPos + (1 - v) * (start - origPos) + (1 - u) * (end - origPos)
// equivalent to using `offset = origPos + dStart + dEnd` as the super-ellipse
// "middle" with axes -dEnd and -dStart. For perpendicular dStart, dEnd of
// equal length w, every sample lies at distance w from `offset` (NOT from
// origPos): the cap arcs around the inscribed sphere tangent to the two
// bev-flanking faces, bulging *toward* the original sharp corner — the
// rounded-bevel direction Blender uses.
//
// Boundary checks:
//   t=0 → (u, v) = (1, 0) → P = origPos + 0·dStart + 1·dEnd = … wait no:
//   the formula gives P = origPos + (1-0)·dStart + (1-1)·dEnd = origPos +
//   dStart = start. ✓
//   t=1 → (u, v) = (0, 1) → P = origPos + (1-1)·dStart + (1-0)·dEnd = end. ✓
private Profile computeProfile(Mesh* mesh, ref const BevVert bv,
                                ref const BoundVert curr, ref const BoundVert next,
                                int seg, float superR)
{
    Profile p;
    p.start  = curr.pos;
    p.middle = bv.origPos;
    p.end    = next.pos;
    p.superR = superR;

    Vec3 nA = (curr.face != ~0u) ? mesh.faceNormal(curr.face) : Vec3(0, 1, 0);
    Vec3 nB = (next.face != ~0u) ? mesh.faceNormal(next.face) : Vec3(0, 1, 0);
    p.planeNormal = safeNormalize(nA + nB);

    if (seg < 1) seg = 1;
    p.sample = new Vec3[](seg + 1);
    Vec3 dStart = p.start - p.middle;
    Vec3 dEnd   = p.end   - p.middle;
    foreach (k; 0 .. seg + 1) {
        float t  = cast(float)k / cast(float)seg;
        float th = t * cast(float)(PI * 0.5);
        float ct = cos(th), st = sin(th);
        // Super-ellipse exponents in the unit-quadrant frame.
        //   r=2 → u=cos(th), v=sin(th);  r=1 → u=cos²(th), v=sin²(th) (linear);
        //   r→∞ → u, v → 1 (square cap that collapses to origPos at t=0.5).
        float u = pow(ct, 2.0f / superR);
        float v = pow(st, 2.0f / superR);
        p.sample[k] = p.middle + dStart * (1.0f - v) + dEnd * (1.0f - u);
    }
    return p;
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

// Locate the EdgeHalf in `bv.edges` that wraps the given mesh edge index.
// Useful for selCount ≥ 2 where bv.bevEdgeIdx only records the first
// beveled EH in the ring.
private int findEhIdxForEdge(ref const BevVert bv, uint edgeIdx) {
    foreach (i, ref eh; bv.edges)
        if (eh.edgeIdx == edgeIdx) return cast(int)i;
    return -1;
}

// True iff every EdgeHalf around this BevVert is part of the bevel selection.
// Cube-corner-style: with selCount == valence the BoundVert ring has no
// "F_other" gap, so M_ADJ subdivision is well-defined and qA_r's CCW-next
// always wraps back to qA_l (each cap-profile midpoint coincides with the
// strip cross-section midpoint of the bev edge between qA_l and qA_r).
private bool isAllBevAtVert(ref const BevVert bv) {
    foreach (ref eh; bv.edges)
        if (!eh.isBev) return false;
    return bv.edges.length > 0;
}

// True iff this BevVert should use M_ADJ topology in the cap and bev strips.
// Even ns shares a single center vertex (adjCenterVid); odd ns has no shared
// center — instead each panel contributes one interior vertex and they form
// an n-gon "central polygon" emitted alongside the cap quads.
private bool useMAdj(ref const BevVert bv) {
    return bv.vmesh.kind == VMeshKind.ADJ
        && bv.vmesh.seg  >= 2
        && isAllBevAtVert(bv)
        && bv.boundVerts.length >= 3;
}

// Profile fullness for the M_ADJ cap center placement (Blender's
// find_profile_fullness, bmesh_bevel.cc). The cap center is positioned at
//   center = boundverts_center + fullness * (origPos - boundverts_center)
// so fullness ∈ [0, 1] interpolates from a flat cap (0) toward the original
// vertex (1). Values were chosen by Blender via offline optimization to give
// the closest fit to a sphere on a cube corner; we reuse the table for
// circle profiles (superR ≈ 2). Non-circle profiles fall back to a sensible
// constant — Stage 7.2d only targets circle profiles.
private float findCapFullness(float superR, int seg) {
    static immutable float[11] circleFullness = [
        0.0f,   // seg=1 (no M_ADJ cap, kept for completeness)
        0.559f, // seg=2
        0.642f, // seg=3
        0.551f, // seg=4
        0.646f, // seg=5
        0.624f, // seg=6
        0.646f, // seg=7
        0.619f, // seg=8
        0.647f, // seg=9
        0.639f, // seg=10
        0.647f, // seg=11
    ];
    if (superR > 1.99f && superR < 2.01f && seg >= 1 && seg <= 11)
        return circleFullness[seg - 1];
    if (superR < 1.01f) return 0.0f;       // straight-line profile → flat cap
    return 0.55f;                          // fallback for other super_r
}

// Flat-array stride for the canonical M_ADJ grid: (ns2 + 1) rows × (ns + 1)
// columns per panel. Includes some non-canonical slots for indexing simplicity.
private size_t adjFlatIdx(int i, int j, int k, int ns) {
    return cast(size_t)i * cast(size_t)((ns / 2) + 1) * cast(size_t)(ns + 1)
         + cast(size_t)j * cast(size_t)(ns + 1)
         + cast(size_t)k;
}

// Resolve any (i, j, k) — canonical or not — to its mesh vertex ID via the
// equivalence rules from Blender's mesh_vert_canon. Recursively rewrites
// non-canonical positions to their canonical counterpart.
private int adjCanonVid(ref const BevVert bv, int i, int j, int k) {
    int n   = cast(int)bv.boundVerts.length;
    int ns  = bv.vmesh.seg;
    int ns2 = ns / 2;
    int odd = ns % 2;
    if (n == 0) return -1;

    if (!odd && j == ns2 && k == ns2)
        return bv.adjCenterVid;
    if (j <= ns2 - 1 + odd && k <= ns2) {
        size_t idx = adjFlatIdx(i, j, k, ns);
        if (idx >= bv.adjGridVids.length) return -1;
        return bv.adjGridVids[idx];
    }
    if (k <= ns2)
        return adjCanonVid(bv, (i + n - 1) % n, k, ns - j);
    return adjCanonVid(bv, (i + 1) % n, ns - k, j);
}

// Compute (positionAtUnitWidth - origPos) for canonical (i, j, k). Used
// during materialize to seed adjGridDirs; updateEdgeBevelPositions later
// scales these linearly with the user width.
private Vec3 adjCanonDirAtUnitWidth(ref const BevVert bv, int i, int j, int k) {
    int n   = cast(int)bv.boundVerts.length;
    int ns  = bv.vmesh.seg;
    int ns2 = ns / 2;

    Vec3 origPos = bv.origPos;

    // (i, 0, k) for k in [0, ns2]: on cap arc i, super-ellipse sample.
    if (j == 0)
        return bv.boundVerts[i].profile.sample[k] - origPos;

    // (i, j, 0) for j in [1, ns2-1+odd]: equivalent to (i-1, 0, ns-j) — on
    // cap arc (i-1)'s super-ellipse, NOT a bilinear point. Match the canon
    // mapping exactly so both panels see the same position for this vertex.
    if (k == 0)
        return bv.boundVerts[(i + n - 1) % n].profile.sample[ns - j] - origPos;

    Vec3 center = bv.adjCenterDir;

    // (i, j, ns2) for j in [1, ns2]: on the panel mid-line going from
    // midpoint(i) (at j=0) to the center (at j=ns2). Linear blend.
    if (k == ns2) {
        Vec3 midI = bv.boundVerts[i].profile.sample[ns2] - origPos;
        float v = cast(float)j / cast(float)ns2;
        return midI * (1.0f - v) + center * v;
    }

    // True interior: bilinear over the panel quad (BV_i, midpoint(i),
    // midpoint(i-1), center).
    Vec3 BV_i    = bv.boundVerts[i].slideDir;
    Vec3 mid_i   = bv.boundVerts[i].profile.sample[ns2] - origPos;
    Vec3 mid_im1 = bv.boundVerts[(i + n - 1) % n].profile.sample[ns2] - origPos;
    float u = cast(float)k / cast(float)ns2;
    float v = cast(float)j / cast(float)ns2;
    return BV_i    * ((1.0f - u) * (1.0f - v))
         + mid_i   * (u          * (1.0f - v))
         + mid_im1 * ((1.0f - u) * v)
         + center  * (u          * v);
}

// Assign new vertex ids, snapshot faces, patch each face around bv.vert.
//
// New layout (post-stage-7): for every face F around bv.vert, the corner BV
// (if any) is the BoundVert with bnd.face == F.
//
//   - selCount ≥ 2 case: every face has a corner BoundVert (because for any
//     consecutive EdgeHalf pair at least one is beveled). Each face's v
//     corner is replaced by that BV (or kept if BV reuses the original).
//   - selCount == 1 case: exactly one face — the F_other between the two
//     non-beveled EdgeHalfs flanking the bev edge — has no corner BV. We
//     splice the cap profile sample points into it, going from the prev
//     adjacent BV through the F_other "front" to the next adjacent BV.
//
// For the cap profile (the BoundVert sitting CCW after the first beveled EH)
// allocate (seg-1) intermediate mesh vertices when seg ≥ 2; the bev-edge
// side profile is left symbolic since the bevel quad strip covers it.
private void materializeBevVert(Mesh* mesh, ref BevVert bv,
                                ref bool[int] faceSnapped,
                                ref FaceSnap[] faceSnaps)
{
    if (bv.bevEdgeIdx < 0 || bv.boundVerts.length == 0) return;

    // Allocate vertex ids. Aliased BoundVerts inherit vertId from their alias
    // target so two corners sharing the same non-beveled edge resolve to the
    // same mesh vertex (manifold topology for selCount ≥ 2).
    //
    // We seed every new vertex at bv.origPos rather than bnd.pos. When apply
    // is called at unit widths (the BevelTool path), bnd.pos lands at
    // "offset_meet at width=1" — for orthogonal cube edges this can land
    // exactly on an existing vertex (e.g. the two-bev corner BV at v_6 lands
    // at v_4). That seeds a degenerate face whose normal falls back to a
    // default direction, which then poisons the offset_meet in any later
    // BevVert that reads that face's normal during its own populate. Seeding
    // at origPos keeps every new vertex at the original corner position
    // until updateEdgeBevelPositions writes the final width-scaled value.
    foreach (i, ref bnd; bv.boundVerts) {
        if (bnd.aliasOf >= 0 && bnd.aliasOf < cast(int)i) {
            bnd.vertId     = bv.boundVerts[bnd.aliasOf].vertId;
            bnd.reusesOrig = bv.boundVerts[bnd.aliasOf].reusesOrig;
        } else if (!bnd.reusesOrig) {
            bnd.vertId = cast(int)mesh.addVertex(bv.origPos);
        }
    }

    int M = cast(int)bv.boundVerts.length;
    // Pick a leftBV whose cap profile is *non-degenerate* — i.e. its CCW-next
    // BoundVert is not aliased back to it. The default
    // boundVertIdxForEh(bevEdgeIdx) picks the BV CCW-after the first bev EH,
    // but for selCount=2 with the non-bev EH lying *between* the two bev EHs
    // in CCW order, that BV is the alias-target sliding on the non-bev edge.
    // Its profile to the next BV (which alias-merges back to it) collapses
    // start == end, so the super-ellipse midpoint becomes meaningless. The
    // corner BV (between two bev EHs) always has a real profile that the
    // bev strips on both flanking bev edges can reuse via capSamples.
    int leftBVidxAlloc = -1;
    foreach (i; 0 .. M) {
        if (bv.boundVerts[i].aliasOf >= 0) continue;
        int nextI = (cast(int)i + 1) % M;
        if (bv.boundVerts[nextI].aliasOf == cast(int)i) continue;
        leftBVidxAlloc = cast(int)i;
        break;
    }
    if (leftBVidxAlloc < 0)
        leftBVidxAlloc = boundVertIdxForEh(bv, bv.bevEdgeIdx);
    bool madj = useMAdj(bv);

    if (madj) {
        // M_ADJ: build the canonical (i, j, k) grid and route every profile's
        // sampleVertIds through it. The face-patching loop below still runs
        // afterwards (every face around bv.vert has a corner BV under M_ADJ —
        // there is no F_other to splice into).
        materializeBevVertMAdj(mesh, bv);
    } else {
        foreach (i; 0 .. M) {
            auto p = &bv.boundVerts[i].profile;
            int seg = (p.sample.length > 0) ? cast(int)p.sample.length - 1 : 1;
            p.sampleVertIds.length = seg + 1;
            p.sampleVertIds[0]   = bv.boundVerts[i].vertId;
            p.sampleVertIds[seg] = bv.boundVerts[(i + 1) % M].vertId;
            // Allocate intermediate sample vertices only for the leftBV cap
            // profile (selCount == 1 splices it into F_other).
            if (cast(int)i == leftBVidxAlloc) {
                foreach (k; 1 .. seg) {
                    p.sampleVertIds[k] = cast(int)mesh.addVertex(bv.origPos);
                }
            } else {
                foreach (k; 1 .. seg)
                    p.sampleVertIds[k] = -1;
            }
        }
    }

    int N = cast(int)bv.edges.length;
    int leftBVidx = leftBVidxAlloc;     // reuse the non-degenerate selection

    foreach (k; 0 .. N) {
        uint faceIdx = bv.edges[k].fnext;
        if (faceIdx >= cast(uint)mesh.faces.length) continue;

        snapshotFace(mesh, faceIdx, faceSnapped, faceSnaps);

        // Find the corner BV for this face: it lives between EdgeHalfs k
        // and (k+1)%N, which is exactly bv.boundVerts[*].face == faceIdx.
        int cornerBVidx = -1;
        foreach (i, ref bnd; bv.boundVerts)
            if (bnd.face == faceIdx) { cornerBVidx = cast(int)i; break; }

        if (cornerBVidx >= 0) {
            // selCount ≥ 1 with at least one bev EH at this corner: replace
            // bv.vert with the BV's vertex (no-op when the BV reuses bv.vert).
            uint vid = cast(uint)bv.boundVerts[cornerBVidx].vertId;
            if (vid != bv.vert)
                replaceVertInFace(mesh, faceIdx, bv.vert, vid);
            continue;
        }

        // F_other handling depends on valence (selCount == 1):
        //   valence=3: the unique F_OTHER face spans both sides of bev →
        //     splice the full cap profile [BV_left, ..., BV_right]
        //     (face grows by `seg` verts).
        //   valence ≥ 4: each F_OTHER face is on one specific side of the
        //     bev edge (closer to either BV_left or BV_right in the CCW
        //     ring). Replace v.vert with that single side's BV — face
        //     length is preserved. Without this rule, splicing the full
        //     cap into every F_OTHER would insert BVs on the WRONG side
        //     of the vertex (e.g. a +X-side BV ends up in a -X-side face).
        //   Equidistant F_OTHERs (only at odd valence ≥ 5) sit directly
        //     opposite the bev edge → full cap splice as in valence=3.
        if (leftBVidx < 0) continue;
        int knext = (cast(int)k + 1) % N;
        int F_OTHER_count = N - 2;
        bool fullSplice = (F_OTHER_count <= 1);
        int chosenBVidx = -1;
        if (!fullSplice) {
            int distLeft  = (cast(int)k - bv.bevEdgeIdx + N) % N;
            int distRight = (bv.bevEdgeIdx - knext + N) % N;
            if (distLeft < distRight) {
                chosenBVidx = leftBVidx;
            } else if (distRight < distLeft) {
                chosenBVidx = (leftBVidx + 1) % cast(int)bv.boundVerts.length;
            } else {
                fullSplice = true;
            }
        }
        if (fullSplice) {
            auto cap = bv.boundVerts[leftBVidx].profile;
            int seg = cast(int)cap.sampleVertIds.length - 1;
            if (seg < 1) seg = 1;
            uint[] toInsert;
            toInsert.length = seg + 1;
            for (int j = 0; j <= seg; j++)
                toInsert[j] = cast(uint)cap.sampleVertIds[seg - j];
            spliceInManyAtCorner(mesh, faceIdx, bv.vert, toInsert);
        } else {
            uint vid = cast(uint)bv.boundVerts[chosenBVidx].vertId;
            if (vid != bv.vert)
                replaceVertInFace(mesh, faceIdx, bv.vert, vid);
        }
    }

    // Stage 9b TRI_FAN cap (Blender's bevel_build_endpoint case for valence=2
    // selCount=1): exactly one beveled edge with one non-bev "support" edge
    // on the opposite side. The bev's slide produces one BoundVert per face;
    // Blender additionally puts an "edge-slide TIP" vertex on the non-bev
    // edge at distance offset from bv.vert and fans triangles from TIP
    // through the cap-profile samples.
    if (bv.selCount == 1 && bv.edges.length == 2 && bv.boundVerts.length == 2
        && leftBVidx >= 0)
    {
        materializeTriFanEndpoint(mesh, bv, leftBVidx);
    }
}

// TRI_FAN cap for selCount=1 valence=2: allocate the edge-slide TIP, splice
// it into both incident faces between the bev BV and the non-bev far end,
// and emit `seg` fan triangles from TIP through the cap profile.
private void materializeTriFanEndpoint(Mesh* mesh, ref BevVert bv, int leftBVidx) {
    int nonBevEh = -1;
    foreach (i, ref eh; bv.edges) if (!eh.isBev) { nonBevEh = cast(int)i; break; }
    if (nonBevEh < 0) return;
    int bevEh = (nonBevEh + 1) % cast(int)bv.edges.length;
    float w = bv.edges[bevEh].offsetLSpec;
    if (w < 1e-6f) return;

    Vec3 nonBevDir = computeSlideDirForEdge(mesh, bv, nonBevEh);
    Vec3 tipPos    = bv.origPos + nonBevDir * w;
    uint tipVid    = cast(uint)mesh.addVertex(tipPos);

    uint nonBevFar = mesh.edgeOtherVertex(bv.edges[nonBevEh].edgeIdx, bv.vert);

    // Splice TIP into each face between the bev BV (replacement of bv.vert)
    // and the non-bev far endpoint, in face winding order. Because the two
    // incident faces traverse the (BV, nonBevFar) edge in opposite directions,
    // we just locate the consecutive-pair containing both verts and insert
    // TIP between them.
    foreach (k; 0 .. cast(int)bv.edges.length) {
        uint faceIdx = bv.edges[k].fnext;
        if (faceIdx >= cast(uint)mesh.faces.length) continue;
        int cornerBVidx = -1;
        foreach (i, ref bnd; bv.boundVerts)
            if (bnd.face == faceIdx) { cornerBVidx = cast(int)i; break; }
        if (cornerBVidx < 0) continue;
        uint bvVid = cast(uint)bv.boundVerts[cornerBVidx].vertId;

        auto face = mesh.faces[faceIdx];
        int n = cast(int)face.length;
        int idxBV = -1, idxFar = -1;
        foreach (i, vi; face) {
            if (vi == bvVid)     idxBV  = cast(int)i;
            if (vi == nonBevFar) idxFar = cast(int)i;
        }
        if (idxBV < 0 || idxFar < 0) continue;

        int insertAfter = -1;
        if ((idxBV  + 1) % n == idxFar) insertAfter = idxBV;
        else if ((idxFar + 1) % n == idxBV) insertAfter = idxFar;
        if (insertAfter < 0) continue;

        uint[] newFace;
        newFace.reserve(n + 1);
        foreach (i; 0 .. n) {
            newFace ~= face[i];
            if (cast(int)i == insertAfter) newFace ~= tipVid;
        }
        mesh.faces[faceIdx] = newFace;
    }

    // Emit fan triangles from TIP through consecutive cap profile samples.
    // Profile of leftBV runs CCW around the cap; emit triangles with vertex
    // order [sample[k], sample[k+1], TIP] which gives a CCW outward winding
    // when the profile itself is laid out CCW from outside.
    auto p = bv.boundVerts[leftBVidx].profile;
    foreach (k; 0 .. cast(int)p.sampleVertIds.length - 1) {
        int a = p.sampleVertIds[k];
        int b = p.sampleVertIds[k + 1];
        if (a < 0 || b < 0) continue;
        mesh.faces ~= [cast(uint)a, cast(uint)b, tipVid];
    }
}

// Allocate the M_ADJ canonical grid for `bv` and wire up profile.sampleVertIds
// of every cap profile to point into the grid via the canon mapping. New mesh
// vertices are seeded at bv.origPos; updateEdgeBevelPositions writes the
// per-vertex final positions later (origPos + adjGridDirs[idx] * width).
//
// Storage layout: bv.adjGridVids has length n * (ns2 + 1) * (ns + 1). Only
// canonical slots are populated; non-canonical lookups go through adjCanonVid
// which recursively resolves to the canonical (i', j', k').
private void materializeBevVertMAdj(Mesh* mesh, ref BevVert bv) {
    int n   = cast(int)bv.boundVerts.length;
    int ns  = bv.vmesh.seg;
    int ns2 = ns / 2;
    int odd = ns % 2;
    if (n < 3 || ns < 2) return;

    size_t cells = cast(size_t)n * cast(size_t)(ns2 + 1) * cast(size_t)(ns + 1);
    bv.adjGridVids.length = cells;
    bv.adjGridDirs.length = cells;
    bv.adjGridVids[] = -1;

    // Center first (referenced by the bilinear formulas via bv.adjCenterDir).
    // Blender-style fullness blend: center sits at
    //   center = boundverts_center + fullness * (origPos - boundverts_center)
    // i.e. (1-f) of the way from origPos toward the BV centroid. Working in
    // slide-direction space (relative to origPos) this collapses to
    //   adjCenterDir = (1 - fullness) * average(BV.slideDir).
    if (!odd) {
        Vec3 bvSum = Vec3(0, 0, 0);
        foreach (ref bnd; bv.boundVerts)
            bvSum = bvSum + bnd.slideDir;
        Vec3 bvCenter = bvSum * (1.0f / cast(float)n);
        float superR  = bv.boundVerts[0].profile.superR;
        float fullness = findCapFullness(superR, ns);
        bv.adjCenterDir = bvCenter * (1.0f - fullness);
        bv.adjCenterVid = cast(int)mesh.addVertex(bv.origPos);
    }

    // Corner BVs occupy (i, 0, 0).
    foreach (i; 0 .. n) {
        size_t idx = adjFlatIdx(i, 0, 0, ns);
        bv.adjGridVids[idx] = bv.boundVerts[i].vertId;
        bv.adjGridDirs[idx] = bv.boundVerts[i].slideDir;
    }

    // Boundary cap-arc points (i, 0, k) for k=1..ns2.
    foreach (i; 0 .. n) {
        foreach (k; 1 .. ns2 + 1) {
            size_t idx = adjFlatIdx(i, 0, k, ns);
            bv.adjGridVids[idx] = cast(int)mesh.addVertex(bv.origPos);
            bv.adjGridDirs[idx] = adjCanonDirAtUnitWidth(bv, i, 0, k);
        }
    }

    // Interior canonical positions (j=1..ns2-1+odd, k=0..ns2). For even ns
    // jMax = ns2-1; for odd ns also include j=ns2 (the center row before
    // (i==0, k==ns2) collapses to the center vertex). We currently skip odd
    // here (useMAdj filters it out).
    int jMax = ns2 - 1 + odd;
    foreach (i; 0 .. n) {
        foreach (j; 1 .. jMax + 1) {
            foreach (k; 0 .. ns2 + 1) {
                size_t idx = adjFlatIdx(i, j, k, ns);
                bv.adjGridVids[idx] = cast(int)mesh.addVertex(bv.origPos);
                bv.adjGridDirs[idx] = adjCanonDirAtUnitWidth(bv, i, j, k);
            }
        }
    }

    // Wire profile.sampleVertIds through the grid. profile of panel i runs
    // from (i, 0, 0) at sampleVertIds[0] to (i, 0, ns) at sampleVertIds[ns]
    // (which is canonical (i+1, 0, 0) — corner BV of the next panel).
    foreach (i; 0 .. n) {
        auto p = &bv.boundVerts[i].profile;
        p.sampleVertIds.length = ns + 1;
        foreach (kk; 0 .. ns + 1) {
            p.sampleVertIds[kk] = adjCanonVid(bv, i, 0, kk);
        }
    }

    // Cube-corner override: replace the bilinear cap geometry with the
    // sphere-octant template Blender uses in tri_corner_adj_vmesh. This is
    // a no-op for non-cube-corner cases (different valence, non-orthogonal
    // bev edges, etc.).
    overrideCubeCornerCap(mesh, bv);
}

// True iff this BevVert is a "cube corner" candidate: 3 BoundVerts whose
// flanking face normals are mutually perpendicular and whose slideDirs are
// equal length. For a cube vertex with 3 mutually orthogonal bev edges this
// holds; for other 3-edge corners (e.g. octahedron tip with non-perpendicular
// face normals) the detection fails and the cap stays on the bilinear
// approximation.
private bool isCubeCornerLike(ref const BevVert bv, Mesh* mesh) {
    if (!isAllBevAtVert(bv)) return false;
    if (bv.boundVerts.length != 3) return false;
    Vec3 d0 = bv.boundVerts[0].slideDir;
    Vec3 d1 = bv.boundVerts[1].slideDir;
    Vec3 d2 = bv.boundVerts[2].slideDir;
    float r0 = d0.length;
    if (r0 < 1e-6f) return false;
    if (fabs(d1.length - r0) > 1e-3f * r0) return false;
    if (fabs(d2.length - r0) > 1e-3f * r0) return false;
    Vec3 n0 = mesh.faceNormal(bv.boundVerts[0].face);
    Vec3 n1 = mesh.faceNormal(bv.boundVerts[1].face);
    Vec3 n2 = mesh.faceNormal(bv.boundVerts[2].face);
    if (fabs(dot(n0, n1)) > 1e-3f) return false;
    if (fabs(dot(n1, n2)) > 1e-3f) return false;
    if (fabs(dot(n2, n0)) > 1e-3f) return false;
    return true;
}

// Place every M_ADJ canonical position on the sphere octant centered at the
// "offset point" — the sphere of radius `width` tangent to all 3 bev-flanking
// faces — following Blender's tri_corner_adj_vmesh + make_unit_cube_map +
// snap_to_superellipsoid path.
//
// Affine map (Blender's `mat`):
//   position = sphere_center + width · (a · n_0 + b · n_1 + c · n_2)
// where n_i are the outward face normals of BV[i]'s face, sphere_center
// satisfies BV[i].pos == sphere_center + width · n_i for any i, and (a, b, c)
// lies on the unit superellipsoid |a|^r + |b|^r + |c|^r = 1.
//
// Canonical position → unit-frame (a_0, a_1, a_2):
//   (i, 0, 0)         BV_i                  → a_i = 1, others = 0
//   (i, 0, k)  k>0    cap arc i sample[k]   → (a_i, a_{i+1}) = (cos(t·π/2), sin(t·π/2)),
//                                              t = k/ns; others = 0
//   (i, j, 0)  j>0    cap arc (i-1) sample  → mirror of above with t = (ns-j)/ns
//   (i, j, k)  >0,>0  panel i interior      → (a_{i-1}, a_i, a_{i+1}) = (j/ns2, 1, k/ns2)
//                                              followed by snap to unit superellipsoid
//   center            shared (1, 1, 1)      → snap to unit superellipsoid
//
// Boundary placement is exact (matches Blender's `get_profile_point` on the
// inscribed sphere). Interior is bilinear-in-unit-frame + snap; this is an
// approximation to Blender's iterative Catmull-Clark + snap (~2% off in the
// interior for ns=4) but coincides on the cap-strip boundary so the strip
// connects cleanly to the cap.
private void overrideCubeCornerCap(Mesh* mesh, ref BevVert bv) {
    if (!isCubeCornerLike(bv, mesh)) return;

    int n   = cast(int)bv.boundVerts.length;
    int ns  = bv.vmesh.seg;
    int ns2 = ns / 2;
    int odd = ns % 2;

    Vec3[3] N;
    N[0] = mesh.faceNormal(bv.boundVerts[0].face);
    N[1] = mesh.faceNormal(bv.boundVerts[1].face);
    N[2] = mesh.faceNormal(bv.boundVerts[2].face);

    // For perpendicular face normals, |slideDir| == width · √2 (BV is the
    // offset_meet of two width-offset perpendicular bev edges in the face).
    float width = bv.boundVerts[0].slideDir.length / sqrt(2.0f);
    if (width < 1e-6f) return;

    Vec3 sphereCenter = bv.boundVerts[0].pos - N[0] * width;

    float superR = bv.boundVerts[0].profile.superR;
    if (superR < 1e-3f) superR = 1e-3f;

    // Snap (a_0, a_1, a_2) to the unit superellipsoid then map to world via
    // the affine cube-corner frame. Returns world position (NOT dir).
    Vec3 mapUnitToWorld(float a0, float a1, float a2) {
        float aa = fabs(a0), ab = fabs(a1), ac = fabs(a2);
        float sum = pow(aa, superR) + pow(ab, superR) + pow(ac, superR);
        if (sum > 1e-10f) {
            float scale = pow(sum, -1.0f / superR);
            a0 *= scale; a1 *= scale; a2 *= scale;
        }
        return sphereCenter + (N[0] * a0 + N[1] * a1 + N[2] * a2) * width;
    }

    // Cap arc sample at parameter t ∈ [0, 1] from BV_a (a-axis = 1) to BV_b
    // (b-axis = 1). For r=2 the (cos, sin) pair already lies on the unit
    // circle so the snap is a no-op.
    Vec3 arcSampleUnit(int a, int b, float t) {
        float th = t * cast(float)(PI * 0.5);
        float[3] uvw = [0, 0, 0];
        uvw[a] = cos(th);
        uvw[b] = sin(th);
        return mapUnitToWorld(uvw[0], uvw[1], uvw[2]);
    }

    if (ns == 2) {
        // Cap-arc midpoints (i, 0, 1): SLERP midpoint of BV_i and BV_{i+1}.
        foreach (i; 0 .. n) {
            int inext = (i + 1) % n;
            float[3] uvw = [0, 0, 0];
            uvw[i]     = 1.0f;
            uvw[inext] = 1.0f;
            size_t idx = adjFlatIdx(cast(int)i, 0, 1, ns);
            bv.adjGridDirs[idx] = mapUnitToWorld(uvw[0], uvw[1], uvw[2])
                                - bv.origPos;
        }
        if (bv.adjCenterVid >= 0)
            bv.adjCenterDir = mapUnitToWorld(1.0f, 1.0f, 1.0f) - bv.origPos;
        return;
    }

    // seg ≥ 4: rebuild every canonical (i, j, k) directly from unit-frame
    // coords. Boundary cap arcs (j=0 or k=0) come from the unit-circle
    // parameterization — perfect match to Blender. Interior comes from
    // bilinear-in-unit-frame + superellipsoid snap.
    foreach (i; 0 .. n) {
        int iprev = (i + n - 1) % n;
        int inext = (i + 1) % n;

        foreach (j; 0 .. ns2 + odd) {
            foreach (k; 0 .. ns2 + 1) {
                size_t idx = adjFlatIdx(cast(int)i, cast(int)j, cast(int)k, ns);
                if (idx >= bv.adjGridDirs.length) continue;
                if (bv.adjGridVids[idx] < 0) continue;

                Vec3 world;
                if (j == 0 && k == 0) {
                    world = bv.boundVerts[i].pos;
                } else if (j == 0) {
                    float t = cast(float)k / cast(float)ns;
                    world = arcSampleUnit(cast(int)i, inext, t);
                } else if (k == 0) {
                    float t = cast(float)(ns - j) / cast(float)ns;
                    world = arcSampleUnit(iprev, cast(int)i, t);
                } else {
                    // Bilinear-in-unit-frame for true interior. For even ns
                    // the (j=ns2, k=ns2) corner of every panel maps to the
                    // shared center (1,1,1) which is correct. For odd ns
                    // there is no shared center — using the same formula
                    // would collapse all n panel interiors onto (1,1,1)/√3.
                    // Pull the (j, k) ↔ (u, v) map by 1/(ns) so that
                    // (j=ns2, k=ns2) odd lands at u = v = 2·ns2/ns < 1, an
                    // approximation of Blender's iterative-CC interior at
                    // ~3% on ns=3.
                    float denom = cast(float)(odd ? (2 * ns2 + 1) : (2 * ns2));
                    float u = cast(float)(2 * k) / denom;
                    float v = cast(float)(2 * j) / denom;
                    float[3] uvw = [0, 0, 0];
                    uvw[iprev] = v;
                    uvw[i]     = 1.0f;
                    uvw[inext] = u;
                    world = mapUnitToWorld(uvw[0], uvw[1], uvw[2]);
                }
                bv.adjGridDirs[idx] = world - bv.origPos;
            }
        }
    }

    if (bv.adjCenterVid >= 0)
        bv.adjCenterDir = mapUnitToWorld(1.0f, 1.0f, 1.0f) - bv.origPos;
}

private void spliceInManyAtCorner(Mesh* mesh, uint faceIdx,
                                  uint corner, uint[] insertSeq)
{
    auto face = mesh.faces[faceIdx];
    int idx = -1;
    foreach (i, vi; face) if (vi == corner) { idx = cast(int)i; break; }
    if (idx < 0) return;

    uint[] newFace;
    newFace.reserve(face.length + insertSeq.length - 1);
    newFace ~= face[0 .. idx];
    newFace ~= insertSeq;
    newFace ~= face[idx + 1 .. $];
    mesh.faces[faceIdx] = newFace;
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
