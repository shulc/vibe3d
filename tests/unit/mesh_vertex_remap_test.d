// mesh_vertex_remap_test -- the spatial-hash weld remap against the naive one, and `protectBelow`.
//
// The hash rewrite is correct only if it produces the SAME remap as the
// quadratic all-pairs scan it replaced. That reference scan travelled here
// with the blocks: it is written out independently rather than recorded as
// an expected answer, so a bug shared by both sides cannot make them agree.
// `protectBelow` is the arm where a pair straddling the plane welds and a
// pair entirely below it must not.
//
// These blocks stood in the body of `struct Mesh` until task 3160 -- step 1
// of `doc/tasks/work/2910-mesh-struct-seams.md`, which took fifty `unittest`
// blocks out of a 16 782-line struct body. They are HERE rather than at
// module scope in `mesh.d` because they compile against `Mesh`'s PUBLIC API
// alone: the criterion `tests/unit/README.md` states and task 0706 set. The
// eighteen blocks that read a `private` name stayed behind under the same
// rule, at module scope in `mesh.d`. Bodies are byte-identical to what stood
// in the struct, dedented by four columns; the only edit is the member enum
// `Marks`, which is spelled `Mesh.Marks` outside the body.
//
// ONE PRIVATE FIXTURE TRAVELLED WITH THEM: `naiveWeldRemap_` (the naive all-pairs reference scan) was a
// `version (unittest) private` helper at module scope in `mesh.d` with NO
// reader outside these blocks, so it moved here and is `private` here.
// Nothing was widened; a fixture whose readers sit on BOTH sides of the
// seam -- `looseTestVertAt` and friends -- could not travel, and its
// blocks stayed in `mesh.d` for exactly that reason.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT, so a mutation that
// should redden two blocks here only ever proves the first. Run them in
// isolation.
module tests.unit.mesh_vertex_remap_test;

import mesh;
import math : Vec3;
import tests.unit.mesh_by_value_gate;

// The seam's compile-time gate: nothing in this module may take a `Mesh` by
// VALUE. `tests/unit/mesh_by_value_gate.d` says why nothing behavioural
// catches that, and carries the gate's own positive control.
private void byValueGateAnchor() {}
mixin MeshByValueGate!(__traits(parent, byValueGateAnchor));

// ---------------------------------------------------------------------------
// weldCoincidentVertices — reference fixture (task 0396, spatial-hash rewrite)
// ---------------------------------------------------------------------------

// Reference copy of the PRE-spatial-hash weldCoincidentVertices remap
// computation (naive O(V²) all-pairs scan). Kept ONLY so the unittests below
// can cross-check the spatial-hash rewrite's equivalence — this is not
// called from any production path.
version (unittest) private int[] naiveWeldRemap_(const Vec3[] verts, double epsSq, size_t protectBelow) {
    int[] remap;
    remap.length = verts.length;
    foreach (i; 0 .. verts.length) remap[i] = cast(int)i;
    foreach (i; 0 .. verts.length) {
        if (remap[i] != cast(int)i) continue;
        foreach (j; i + 1 .. verts.length) {
            if (remap[j] != cast(int)j) continue;
            if (i < protectBelow && j < protectBelow) continue;
            Vec3 d = verts[i] - verts[j];
            if (d.x * d.x + d.y * d.y + d.z * d.z < epsSq)
                remap[j] = cast(int)i;
        }
    }
    return remap;
}

unittest { // spatial-hash rewrite reproduces the naive remap exactly, incl.
    // cell-boundary crossings and the non-transitive chaining quirk.
    //
    // Layout (eps = 0.1, epsSq = 0.01, cellSize = 0.1):
    //   0,1: far anchors (A,B) — never welded, used to recover each cluster
    //        vertex's applied remap target via its face's 3rd corner.
    //   2:   v0 = (0,0,0)            — representative of a 3-cluster
    //   3:   v1 = (0.02,0,0)         — welds to v0 (dist 0.02 < eps)
    //   4:   v2 = (0.05,0,0)         — welds to v0 (dist 0.05 < eps)
    //   5:   b0 = (5.099,0,0)        — cell 50; welds b1 (adjacent-cell pair)
    //   6:   b1 = (5.101,0,0)        — cell 51; dist to b0 = 0.002 < eps
    //   7:   f0 = (20,0,0)           — independent (dist to f1 = 0.5 > eps)
    //   8:   f1 = (20.5,0,0)         — independent
    //   9:   P  = (50,0,0)           — claims Q; NOT within eps of R
    //   10:  Q  = (50.06,0,0)        — welds to P (dist 0.06 < eps)
    //   11:  R  = (50.12,0,0)        — dist to Q = 0.06 < eps, dist to P =
    //        0.12 >= eps; since Q is claimed (not a representative) by the
    //        time R is considered, R must stay UNWELDED — non-transitive.
    import std.conv : to;
    Mesh m;
    m.vertices = [
        Vec3(1000, 1000, 1000),   // 0: anchor A
        Vec3(1000, 1000, 1001),   // 1: anchor B
        Vec3(0, 0, 0),            // 2: v0
        Vec3(0.02f, 0, 0),        // 3: v1
        Vec3(0.05f, 0, 0),        // 4: v2
        Vec3(5.099f, 0, 0),       // 5: b0
        Vec3(5.101f, 0, 0),       // 6: b1
        Vec3(20, 0, 0),           // 7: f0
        Vec3(20.5f, 0, 0),        // 8: f1
        Vec3(50, 0, 0),           // 9: P
        Vec3(50.06f, 0, 0),       // 10: Q
        Vec3(50.12f, 0, 0),       // 11: R
    ];
    // One triangle per cluster vertex: [A, B, v]. A and B are never welded
    // and never coincide with any cluster vertex or each other, so the 3rd
    // corner after weld directly reveals remap[v] (no corner-collapse can
    // touch a 3-distinct-corner face).
    foreach (k; 2 .. m.vertices.length)
        m.faces ~= [0u, 1u, cast(uint)k];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    immutable double epsSq = 0.01; // eps = 0.1

    // Reference remap via the naive O(V²) scan, computed BEFORE any mutation.
    int[] refRemap = naiveWeldRemap_(m.vertices, epsSq, 0);
    int[] expected = [0,1, 2,2,2, 5,5, 7,8, 9,9,11];
    assert(refRemap == expected,
        "naive reference remap sanity check failed: " ~ refRemap.to!string
        ~ " vs " ~ expected.to!string);

    size_t refWelded = 0;
    foreach (i, r; refRemap) if (r != cast(int)i) ++refWelded;

    size_t welded = m.weldCoincidentVertices(epsSq);
    assert(welded == refWelded,
        "spatial-hash weld count must match naive: got " ~ uintToStr(welded)
        ~ " vs " ~ uintToStr(refWelded));
    assert(m.vertices.length == 12, "weldCoincidentVertices must not touch vertices[]");
    assert(m.faces.length == 10, "no face should be dropped (all corners stay distinct)");

    // Recover the APPLIED remap from each face's 3rd corner and compare to
    // the naive reference element-by-element — this catches a wrong
    // representative choice even when the welded COUNT happens to match.
    foreach (fi, ref f; m.faces) {
        uint origV = cast(uint)(fi + 2);
        uint appliedTarget = f[2];
        uint expectedTarget = cast(uint)refRemap[origV];
        assert(appliedTarget == expectedTarget,
            "face for orig vertex " ~ origV.to!string ~ ": applied remap target "
            ~ appliedTarget.to!string ~ " != naive " ~ expectedTarget.to!string);
    }
}

unittest { // protectBelow: both-below pair must NOT weld; below/above pair must
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0),   // 0: below protectBelow
        Vec3(0, 0, 0),   // 1: below protectBelow, coincident with 0
        Vec3(0, 0, 0),   // 2: at/above protectBelow, coincident with 0 and 1
    ];
    m.faces = [[0u, 1u, 2u]];  // degenerate on purpose; weld doesn't care about area
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    immutable double epsSq = 0.01;
    immutable size_t protectBelow = 2;

    int[] refRemap = naiveWeldRemap_(m.vertices, epsSq, protectBelow);
    // 0,1 both < protectBelow → skip. 0,2: 0<protectBelow but 2>=protectBelow → eligible → weld.
    assert(refRemap == [0, 1, 0],
        "reference: vert 1 stays independent (protected pair), vert 2 welds to 0");

    size_t refWelded = 0;
    foreach (i, r; refRemap) if (r != cast(int)i) ++refWelded;

    size_t welded = m.weldCoincidentVertices(epsSq, protectBelow);
    assert(welded == refWelded, "protectBelow weld count must match naive reference");
    assert(welded == 1, "exactly one weld (2→0) expected under protectBelow=2");
}
