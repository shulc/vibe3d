// Task 1290 — what a mesh that is NOT a manifold must still answer correctly.
//
// Two shapes drive everything here, and both are ORDINARY reachable state, not
// corruption: an edge carrying THREE incident faces (Edge Extend builds them on
// purpose, an LWO import brings them in) and a face with TWO corners (the
// kernel's arity floor is two, not three).
//
// Every block below is written so that reverting the fix it guards turns it
// RED. The mutations that were actually run are recorded in
// doc/tasks/work/1290-nonmanifold-degrade.md; the assertion messages name the
// value each one comes back with.
//
// A NOTE ON WHY THE FIXTURE IS OPEN. A closed solid is useless here for the
// same reason it is useless for the facing predicate: on a cube every edge has
// exactly two faces, so a 3-face edge cannot exist and every candidate rule
// agrees. Only an open fan separates them.
module tests.unit.nonmanifold_degrade_test;

import std.algorithm : sort, canFind;
import std.array     : array;
import std.format    : format;

import math : Vec3;
import mesh;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// Three quads sharing edge (0,1) — the "book" / non-manifold fan.
///
/// Faces 0 and 2 traverse the spine 0→1 and face 1 traverses it 1→0, which is
/// the only way three faces CAN meet on one edge: no orientation makes all
/// three pairwise-opposite. Every other edge in the fixture has exactly one
/// face, so the spine is the mesh's single anomaly and nothing else can be
/// blamed for an answer.
Mesh nmdThreeQuadFan() {
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0),   // 0  spine
        Vec3(1, 0, 0),   // 1  spine
        Vec3(1, 1, 0),   // 2
        Vec3(0, 1, 0),   // 3
        Vec3(1, -1, 0),  // 4
        Vec3(0, -1, 0),  // 5
        Vec3(1, 0, 1),   // 6
        Vec3(0, 0, 1),   // 7
    ];
    m.faces = [
        [0u, 1u, 2u, 3u],   // face 0 — +Y sheet
        [1u, 0u, 5u, 4u],   // face 1 — −Y sheet
        [0u, 1u, 6u, 7u],   // face 2 — +Z sheet, out of the other two's plane
    ];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    return m;
}

/// A quad plus a standing TWO-CORNER face on one of its edges.
Mesh nmdQuadPlusTwoCornerFace() {
    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)];
    m.faces = [[0u, 1u, 2u, 3u], [0u, 1u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    return m;
}

/// Face rings as a canonical SET of sorted rings — element ORDER differs
/// between runs and between kernels, so nothing here compares positionally.
uint[][] nmdFaceSet(ref const Mesh m) {
    uint[][] out_;
    foreach (f; m.faces) {
        auto r = f.dup;
        sort(r);
        out_ ~= r;
    }
    sort(out_);
    return out_;
}

uint[] nmdSorted(uint[] a) { auto r = a.dup; sort(r); return r; }

// ---------------------------------------------------------------------------
// P2 — the root: a non-manifold edge must not read as an open boundary
// ---------------------------------------------------------------------------
//
// `buildLoops`' treatment A gives EVERY dart on a 3-face edge `twin == ~0u`,
// which is the same sentinel an open rim carries. That single ambiguity is the
// root of the whole cascade below: the ordered twin-walk truncates at such an
// edge exactly as it does at a rim, so it enumerated one face of three and the
// vertex fans stopped dead in the middle.

unittest { // the spine is recognised as non-manifold at all
    auto m = nmdThreeQuadFan();
    immutable uint ei = m.edgeIndex(0, 1);
    assert(ei != ~0u, "setup: edge (0,1) must exist");

    assert(m.edgePolygonCounts()[ei] == 3,
        "setup: the truthful counter must see all three faces on the spine");

    assert(m.isEdgeNonManifold(ei),
        "a spine with three incident faces must report non-manifold; before "
        ~ "task 1290 nothing in the mesh could tell it from an open rim, "
        ~ "because both carry twin == ~0u on every dart");

    // Non-vacuous: an ordinary rim edge of the SAME fixture must answer false,
    // otherwise the predicate above would pass by saying "yes" to everything.
    immutable uint rim = m.edgeIndex(2, 3);
    assert(rim != ~0u, "setup: edge (2,3) must exist");
    assert(!m.isEdgeNonManifold(rim),
        "a one-face rim edge must NOT report non-manifold");
}

unittest { // facesAroundEdge yields the TRUE incident set, not one face
    auto m = nmdThreeQuadFan();
    immutable uint ei = m.edgeIndex(0, 1);

    uint[] got;
    foreach (fi; m.facesAroundEdge(ei)) got ~= fi;
    assert(nmdSorted(got) == [0u, 1u, 2u],
        format("facesAroundEdge on a 3-face spine must yield all three faces "
             ~ "as a SET; got %s. Before task 1290 it yielded exactly one "
             ~ "([2]): the ordered twin-walk stopped at twin == ~0u and the "
             ~ "CSR arm it could have used was capped at two faces by a "
             ~ "uint[2].", nmdSorted(got)));

    // The manifold contract is unchanged: a rim edge still yields its one face
    // and a genuine two-face edge still yields two. Without this the block
    // above could be satisfied by a range that simply returns everything.
    uint[] rimFaces;
    foreach (fi; m.facesAroundEdge(m.edgeIndex(2, 3))) rimFaces ~= fi;
    assert(rimFaces == [0u], "a rim edge must still yield its single face");
}

unittest { // a 3-face edge is not a border, and the fan walk does not truncate
    auto m = nmdThreeQuadFan();
    immutable uint ei = m.edgeIndex(0, 1);

    assert(!m.isEdgeBorder(ei),
        "an edge with three incident faces is not an open border; before task "
        ~ "1290 isEdgeBorder said TRUE, because it counts through the ring "
        ~ "walk and the ring walk saw one face");

    // Vertex 0 sits on four edges: the spine plus three genuine rims
    // ((0,3), (0,5), (0,7)). The ordered fan walk used to stop at the spine
    // and report 2 of the 3 rims.
    uint[] incident;
    foreach (e; m.edgesAroundVertex(0)) incident ~= e;
    assert(incident.length == 4,
        format("edgesAroundVertex(0) must enumerate all four incident edges; "
             ~ "got %d. Before task 1290 the twin-walk truncated at the spine "
             ~ "and returned 2.", incident.length));
    assert(m.borderEdgeCountAtVertex(0) == 3,
        format("vertex 0 touches exactly three genuine border edges; got %d "
             ~ "(2 before task 1290, from the truncated fan)",
               m.borderEdgeCountAtVertex(0)));
}

unittest { // the spine cannot be reported smooth
    auto m = nmdThreeQuadFan();
    immutable uint ei = m.edgeIndex(0, 1);

    auto sharp = m.computeEdgeSharpness(40.0f);
    assert(sharp[ei].interior,
        "a 3-face spine is interior, not a boundary left at EdgeSharpness.init");
    assert(sharp[ei].sharp,
        "three sheets meeting on one edge is a crease; before task 1290 this "
        ~ "was false — the dart loop skipped every twin == ~0u dart, so "
        ~ "MeshSmooth.lockSharp never locked it and smoothing pulled the "
        ~ "sheets through each other");
    assert(sharp[ei].faceA != sharp[ei].faceB,
        "the reported pair must be two distinct incident faces");

    // Still non-vacuous on the manifold side: a rim edge stays at init.
    immutable uint rim = m.edgeIndex(2, 3);
    assert(!sharp[rim].interior, "a rim edge must stay a boundary edge");
}

// ---------------------------------------------------------------------------
// P1 — the only state corruption: dissolving a 3-face edge
// ---------------------------------------------------------------------------

unittest { // dissolve declines an edge it cannot merge, instead of merging two
           // of the three and lying about it
    foreach (keepConsumedVerts; [true, false]) {
        auto m = nmdThreeQuadFan();
        const before = nmdFaceSet(m);
        immutable size_t vBefore = m.vertices.length;
        immutable size_t eBefore = m.edges.length;

        auto mask = new bool[](m.edges.length);
        mask[m.edgeIndex(0, 1)] = true;

        immutable size_t n = m.removeEdgesByMask(mask, keepConsumedVerts);

        assert(n == 0,
            format("dissolving an edge with three incident faces must dissolve "
                 ~ "NOTHING and say so; got %d. Before task 1290 it returned 1 "
                 ~ "while the edge was still standing: the union-find took the "
                 ~ "FIRST TWO faces in dart order, merged faces 0 and 1 into "
                 ~ "the hexagon [0,5,4,1,2,3], and left face 2 = [0,1,6,7] "
                 ~ "bounding an edge the merged polygon no longer touches.",
                   n));
        assert(nmdFaceSet(m) == before,
            format("the mesh must be left alone; faces went %s -> %s",
                   before, nmdFaceSet(m)));
        assert(m.vertices.length == vBefore && m.edges.length == eBefore,
            "no vertex or edge may be consumed by a dissolve that did nothing");
    }
}

unittest { // …and the ordinary two-face dissolve is untouched by that gate
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
        Vec3(1, -1, 0), Vec3(0, -1, 0),
    ];
    m.faces = [[0u, 1u, 2u, 3u], [1u, 0u, 5u, 4u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    auto mask = new bool[](m.edges.length);
    mask[m.edgeIndex(0, 1)] = true;
    immutable size_t n = m.removeEdgesByMask(mask);

    assert(n == 1, "a plain interior edge must still dissolve");
    assert(m.faces.length == 1, "its two faces must still merge into one");
    assert(nmdSorted(m.faces[0].dup) == [0u, 1u, 2u, 3u, 4u, 5u],
        format("the merged polygon must carry all six corners; got %s",
               nmdSorted(m.faces[0].dup)));
    assert(m.edgeIndex(0, 1) == ~0u, "the dissolved edge must be gone");
}

// ---------------------------------------------------------------------------
// P3 — a two-corner face is legal state and must survive the kernels
// ---------------------------------------------------------------------------

unittest { // faceted subdivide leaves it alone instead of doubling a corner
    foreach (selectTwoCorner; [true, false]) {
        auto m = nmdQuadPlusTwoCornerFace();
        auto faceMask = new bool[](m.faces.length);
        faceMask[0] = !selectTwoCorner;   // the quad
        faceMask[1] =  selectTwoCorner;   // the two-corner face

        auto sub = facetedSubdivide(m, faceMask);

        size_t twoCorner = 0;
        foreach (f; sub.faces) {
            if (f.length == 2) ++twoCorner;
            foreach (k; 0 .. f.length) {
                immutable uint a = f[k], b = f[(k + 1) % f.length];
                assert(a != b,
                    format("faceted subdivide must not emit a face with a "
                         ~ "repeated adjacent corner; got %s (selected=%s). "
                         ~ "Before task 1290 a selected [0,1] came back as "
                         ~ "[0,4,5,4] + [1,4,5,4] — two zero-area quads with a "
                         ~ "doubled corner — and an UNSELECTED [0,1] next to a "
                         ~ "selected quad was widened to [0,4,1,4].",
                           f, selectTwoCorner));
            }
        }
        assert(twoCorner == 1,
            format("the two-corner face must survive as exactly one "
                 ~ "two-corner face (selected=%s); found %d",
                   selectTwoCorner, twoCorner));
    }
}

unittest { // an edge extrude does not annihilate a bystanding two-corner face
    // A cube with a standing [6,7] face, extruding the very edge that face
    // stands on. `faceIndices` in the side-face rewrite is EVERY face, so the
    // two-corner face reaches it; on a 2-ring `prev` and `next` are the same
    // vertex, each corner emitted its inset twice, the face was inflated to
    // four corners, the consecutive-dup reduce collapsed it back to two, and
    // the sub-3 drop deleted it — leaving a face set byte-identical to the
    // same extrude on a clean cube.
    Mesh m = makeCube();
    m.faces ~= [6u, 7u];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    size_t twoCornerBefore = 0;
    foreach (f; m.faces) if (f.length == 2) ++twoCornerBefore;
    assert(twoCornerBefore == 1, "setup: exactly one two-corner face");

    auto emask = new bool[](m.edges.length);
    immutable uint ei = m.edgeIndex(6, 7);
    assert(ei != ~0u, "setup: edge (6,7) must exist");
    emask[ei] = true;

    // task 1903 Stage H: extrudeEdgesByMask takes `ref MeshEditBatch` now;
    // this fixture reads no op-log, so the batch is unrecorded.
    { auto ed = MeshEditBatch.unrecorded(m, kExtrudeEditScope);
      ed.extrudeEdgesByMask(emask, 0.2f, 0.1f);
      ed.close(); }

    size_t twoCornerAfter = 0;
    foreach (f; m.faces) if (f.length == 2) ++twoCornerAfter;
    assert(twoCornerAfter == 1,
        format("the pre-existing two-corner face must survive an edge extrude "
             ~ "that is not about it; %d -> %d",
               twoCornerBefore, twoCornerAfter));

    foreach (fi, f; m.faces)
        foreach (k; 0 .. f.length)
            assert(f[k] != f[(k + 1) % f.length],
                format("face %d came back with a repeated adjacent corner: %s",
                       fi, f));
}
