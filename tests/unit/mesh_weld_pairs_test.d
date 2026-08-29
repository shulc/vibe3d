// mesh_weld_pairs_test -- `weldVertexPairs` -- what one call welds, and what it refuses whole.
//
// The two grab arms (edge and vertex) and the three refusals: a chain is
// refused whole rather than followed one link deep, a non-adjacent same-face
// pair is refused exactly as `weldVertexPair` refuses it, and a vertex
// cannot be absorbed twice -- the FIRST pair wins, which is a property of
// the loop and not of the pair set.
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
// ONE PRIVATE FIXTURE TRAVELLED WITH THEM: `makeWeldPairStrip` (the two-quad strip rig) was a
// `version (unittest) private` helper at module scope in `mesh.d` with NO
// reader outside these blocks, so it moved here and is `private` here.
// Nothing was widened; a fixture whose readers sit on BOTH sides of the
// seam -- `looseTestVertAt` and friends -- could not travel, and its
// blocks stayed in `mesh.d` for exactly that reason.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT, so a mutation that
// should redden two blocks here only ever proves the first. Run them in
// isolation.
module tests.unit.mesh_weld_pairs_test;

import mesh;
import math : Vec3;
import tests.unit.mesh_by_value_gate;

// The seam's compile-time gate: nothing in this module may take a `Mesh` by
// VALUE. `tests/unit/mesh_by_value_gate.d` says why nothing behavioural
// catches that, and carries the gate's own positive control.
private void byValueGateAnchor() {}
mixin MeshByValueGate!(__traits(parent, byValueGateAnchor));

// ---------------------------------------------------------------------------
// weldVertexPairs (task 0555) — N independent absorptions in one pass.
//
// The rig is a two-quad strip, which is the shape the reference measurement
// was taken on and the smallest mesh where the interesting deltas appear:
//
//     3 ---- 4 ---- 5          F0 = [0,1,4,3]   F1 = [1,2,5,4]
//     |  F0  |  F1  |          V=6  E=7  F=2
//     0 ---- 1 ---- 2
// ---------------------------------------------------------------------------
version (unittest) private Mesh makeWeldPairStrip() {
    Mesh m;
    m.addVertex(Vec3(-1, 0, 0)); m.addVertex(Vec3(0, 0, 0)); m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(-1, 1, 0)); m.addVertex(Vec3(0, 1, 0)); m.addVertex(Vec3(1, 1, 0));
    m.addFace([0u, 1u, 4u, 3u]);
    m.addFace([1u, 2u, 5u, 4u]);
    m.rebuildEdges();
    m.buildLoops();
    return m;
}

unittest { // the EDGE-grab cell: two pairs, welded independently, in ONE call
    import std.conv : to;
    import std.math : abs;
    Mesh m = makeWeldPairStrip();
    assert(m.vertices.length == 6 && m.edges.length == 7 && m.faces.length == 2,
        "strip rig: expected V=6 E=7 F=2, got V=" ~ m.vertices.length.to!string
        ~ " E=" ~ m.edges.length.to!string ~ " F=" ~ m.faces.length.to!string);

    // Drag the middle edge 1-4 onto the right edge 2-5: vertex 1 is absorbed
    // by 2 and vertex 4 by 5, each into its OWN target. This is the measured
    // delta (task 0545): dV -2, dE -3, dF -1.
    uint[2][] pairs = [[2u, 1u], [5u, 4u]];
    assert(m.weldVertexPairs(pairs) == 2,
        "both endpoints must be absorbed, independently — one call, two welds");

    assert(m.vertices.length == 4,
        "edge-grab weld: expected V=4 (dV -2), got " ~ m.vertices.length.to!string);
    assert(m.edges.length == 4,
        "edge-grab weld: expected E=4 (dE -3), got " ~ m.edges.length.to!string);
    assert(m.faces.length == 1,
        "edge-grab weld: expected F=1 (dF -1) — the quad the grabbed edge was "
        ~ "dragged across collapses; got " ~ m.faces.length.to!string);

    // The survivors sit where the TARGETS were, never at a midpoint: the grab
    // is absorbed INTO the target, the target does not move to meet it.
    bool at10 = false, at11 = false;
    foreach (v; m.vertices) {
        if (abs(v.x - 1.0f) < 1e-6f && abs(v.y)        < 1e-6f) at10 = true;
        if (abs(v.x - 1.0f) < 1e-6f && abs(v.y - 1.0f) < 1e-6f) at11 = true;
    }
    assert(at10 && at11, "both weld targets must survive at their own positions");
    foreach (v; m.vertices)
        assert(abs(v.x) > 1e-6f,
            "no survivor may sit at x=0 — that is where the absorbed grab was");
}

unittest { // the VERTEX-grab cell: one pair, and BOTH quads become triangles
    import std.conv : to;
    Mesh m = makeWeldPairStrip();
    uint[2][] pairs = [[4u, 1u]];      // vertex 1 dragged onto vertex 4
    assert(m.weldVertexPairs(pairs) == 1, "the single grab must be absorbed");
    assert(m.vertices.length == 5,
        "vertex-grab weld: expected V=5 (dV -1), got " ~ m.vertices.length.to!string);
    assert(m.faces.length == 2,
        "vertex-grab weld: both faces survive, got " ~ m.faces.length.to!string);
    foreach (i, ref f; m.faces)
        assert(f.length == 3,
            "vertex-grab weld: face " ~ i.to!string ~ " must be a TRIANGLE (the "
            ~ "measured 'two quads become triangles'), got length " ~ f.length.to!string);
}

unittest { // a CHAIN is refused whole, not silently followed one link deep
    import std.conv : to;
    Mesh m = makeWeldPairStrip();
    // [4,1] absorbs 1 into 4 while [1,0] absorbs 0 into 1 — vertex 1 is both a
    // target and a casualty. BOTH links are refused rather than one being
    // applied and the other left pointing at a dead vertex: the rewrite reads
    // the remap once per corner and does not chase, so a surviving link would
    // be silent corruption. Order-independent by construction.
    uint[2][] pairs = [[4u, 1u], [1u, 0u]];
    immutable size_t welded = m.weldVertexPairs(pairs);
    assert(welded == 0,
        "a chain must be refused whole — expected 0 welds, got " ~ welded.to!string);
    assert(m.vertices.length == 6 && m.faces.length == 2,
        "chain reject: the mesh must be untouched, got V="
        ~ m.vertices.length.to!string ~ " F=" ~ m.faces.length.to!string);
}

unittest { // non-adjacent same-face pairs are refused, exactly as weldVertexPair
    import std.conv : to;
    Mesh m = makeWeldPairStrip();
    // 0 and 4 are the diagonal of F0 = [0,1,4,3] — welding them would leave a
    // self-touching polygon.
    uint[2][] pairs = [[4u, 0u]];
    assert(m.weldVertexPairs(pairs) == 0,
        "a non-adjacent same-face pair must be refused");
    assert(m.vertices.length == 6 && m.faces.length == 2,
        "non-adjacent reject: the mesh must be untouched, got V="
        ~ m.vertices.length.to!string ~ " F=" ~ m.faces.length.to!string);
}

unittest { // one vertex cannot be absorbed twice; the first pair wins
    import std.conv : to;
    Mesh m = makeWeldPairStrip();
    uint[2][] pairs = [[4u, 1u], [2u, 1u]];
    assert(m.weldVertexPairs(pairs) == 1,
        "a second claim on the same drop must be refused — expected 1 weld");
    assert(m.vertices.length == 5,
        "double-absorb reject: expected V=5, got " ~ m.vertices.length.to!string);
}
