// Module unittests for the corner-provenance obligation (task 0830).
//
// WHAT IS BEING PINNED HERE, and why it needs its own module. The five
// declaration SHAPES are pinned by `mesh_corner_maps`'s own block; these
// blocks pin the part that only exists once a `Mesh` is involved — that the
// declaration is what decides the per-corner plane's fate, and the length test
// is only what happens when nobody declared.
//
// The discriminating case is the one a length test can never see: a rewrite
// that leaves the corner TOTAL unchanged. Before task 0830 such a rewrite ended
// with a length-correct map, so `resizePolyVertexMaps` KEPT every value — each
// one now sitting on a foreign corner. That is not a hypothetical shape: it is
// exactly what `bevelFacesByMask` shipped until task 0697, where the cap kept
// its un-inset source values and looked like a working carry. Under the
// obligation, an OPEN rewrite that says nothing loses the plane instead.
module tests.unit.mesh_corner_provenance_test;

import mesh;
import math : Vec3;

// Two quads sharing an edge, with a per-corner map whose value is a key of the
// corner's own (face, corner) position — so a value that moved to a foreign
// corner is tellable from a value that stayed, and both are tellable from zero.
private Mesh twoQuadsWithCornerMap() {
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 1, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addVertex(Vec3(2, 0, 0));
    m.addVertex(Vec3(2, 1, 0));
    m.addFace([0, 1, 2, 3]);
    m.addFace([1, 4, 5, 2]);
    m.buildLoops();

    MeshMap uv;
    uv.name   = "uv";
    uv.dim    = 2;
    uv.domain = MapDomain.PolyVertex;
    uv.data.length = m.loops.length * 2;
    foreach (li; 0 .. m.loops.length) {
        uv.data[li * 2]     = 1.0f + li;   // never 0, so a drop is unambiguous
        uv.data[li * 2 + 1] = 100.0f + li;
    }
    m.meshMaps ~= uv;
    return m;
}

private const(float)[] uvOf(ref Mesh m) {
    foreach (ref mm; m.meshMaps)
        if (mm.domain == MapDomain.PolyVertex) return mm.data;
    return null;
}

// A rewrite that swaps the two faces' windings whole. Σ arity is UNCHANGED (8
// corners before, 8 after), so every map stays length-correct and the length
// test has nothing to say — while every corner value is now on the other face.
private void swapTheTwoFaces(ref Mesh m) {
    auto f0 = m.faces[0].dup;
    auto f1 = m.faces[1].dup;
    m.faces[0] = f1;
    m.faces[1] = f0;
}

// ---------------------------------------------------------------------------
// The length test, on its own, KEEPS a corner-neutral rewrite's values. This
// block exists to establish that the hole is real before the next one shows the
// obligation closing it; delete the obligation and this is what every kernel
// gets.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = twoQuadsWithCornerMap();
    const float[] before = uvOf(m).dup;

    // No `beginCornerRewrite`: nothing is armed, nothing is declared. This is a
    // kernel that renumbers corners silently — the pre-0830 world.
    swapTheTwoFaces(m);
    m.buildLoops();

    const(float)[] after = uvOf(m);
    assert(after.length == before.length,
           "the corner total did not change, so neither can the map's length");
    assert(after == before,
           "with no declaration the length test keeps every value — that is the "
           ~ "hole task 0830 exists to close, and it must stay demonstrable");
}

// ---------------------------------------------------------------------------
// OPENING a rewrite changes the default: silence is now a DROP, not a keep.
// The corner total is identical, so this cannot be the length test firing.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = twoQuadsWithCornerMap();
    const size_t corners = m.loops.length;

    bool shouted = false;
    {
        auto rw = m.beginCornerRewrite();
        assert(rw.active(),
               "a mesh with a PolyVertex map, in step with its faces, must arm");
        swapTheTwoFaces(m);
        // …and the kernel says nothing about what became of the corners.
        //
        // Under `-debug` the obligation also SHOUTS (a `debug assert` inside
        // `resizePolyVertexMaps`). The shout comes AFTER the repair, so the end
        // state asserted below is the same in both builds; swallowing it here
        // is what lets one block assert the behaviour and, separately, that the
        // diagnostic is live where it is compiled in.
        try { m.buildLoops(); }
        catch (Throwable t) { shouted = true; }
    }
    debug assert(shouted,
                 "the undeclared-rewrite diagnostic is compiled in under -debug "
                 ~ "and must fire — a silent version of it is a guard that has "
                 ~ "stopped guarding");

    const(float)[] after = uvOf(m);
    assert(after.length == corners * 2, "the drop is length-correct");
    foreach (v; after)
        assert(v == 0.0f,
               "an open rewrite that declared nothing must DROP the plane, not "
               ~ "keep values on foreign corners");
}

// ---------------------------------------------------------------------------
// A declaration is honoured, and `Unchanged` is a real answer rather than a
// way of saying nothing: the same corner-neutral rewrite, declared as a
// relocation that names where each corner went, moves the values with it.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = twoQuadsWithCornerMap();
    const float[] before = uvOf(m).dup;

    {
        auto rw = m.beginCornerRewrite();
        swapTheTwoFaces(m);
        // New corner 0..3 is old corner 4..7 and vice versa — the swap, stated.
        const uint[] oldLoopOfNewLoop = [4u, 5u, 6u, 7u, 0u, 1u, 2u, 3u];
        m.declareCornerProvenance(rw.relocated(oldLoopOfNewLoop));
        m.buildLoops();
    }

    const(float)[] after = uvOf(m);
    foreach (i; 0 .. 4) {
        assert(after[i * 2]     == before[(i + 4) * 2],
               "the declared relocation must carry face 1's corners onto face 0");
        assert(after[(i + 4) * 2] == before[i * 2],
               "…and face 0's onto face 1");
    }
}

// ---------------------------------------------------------------------------
// A kernel that bails after opening a rewrite leaves the plane exactly as it
// found it. The handle's destructor disarms, so an abandoned rewrite cannot
// cost a mesh its per-corner data — the deliberately SAFE direction of the two
// (the other, disarming too late, drops a plane and goes red in the UV lanes).
// ---------------------------------------------------------------------------
unittest {
    Mesh m = twoQuadsWithCornerMap();
    const float[] before = uvOf(m).dup;

    {
        auto rw = m.beginCornerRewrite();
        assert(rw.active());
        // …empty mask, degenerate input, nothing to do. `faces` untouched.
    }
    m.buildLoops();

    assert(uvOf(m) == before,
           "an abandoned rewrite must leave the plane alone");
}

// ---------------------------------------------------------------------------
// Without a per-corner map there is nothing to owe, and the whole mechanism
// stays inert: no capture is taken (the O(corners) dup a kernel would otherwise
// pay on every call) and no declaration is required.
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 1, 0));
    m.addFace([0, 1, 2]);
    m.buildLoops();

    auto rw = m.beginCornerRewrite();
    assert(!rw.active(), "no PolyVertex map ⇒ no capture, no arming");
    assert(rw.oldFaces().length == 0);
    assert(rw.oldFaceLoop().length == 0);
    // Every builder degrades to a claim that costs nothing and asserts nothing.
    assert(rw.carried(null, null, null).kind() == CornerProvenance.Kind.Unchanged);
    assert(rw.relocated(null).kind()           == CornerProvenance.Kind.Unchanged);
}

// ---------------------------------------------------------------------------
// The capture's CSR offsets are prefix-summed from the windings it copied, not
// read out of `faceLoop`. That distinction is the task-0690 stale-`faceLoop`
// trap: a kernel that rewrote windings without a `buildLoops` leaves `faceLoop`
// describing a corner space nothing else is in.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = twoQuadsWithCornerMap();
    // Corrupt `faceLoop` the way a winding rewrite without a rebuild would.
    m.faceLoop[1] = 999u;

    auto rw = m.beginCornerRewrite();
    assert(rw.active());
    assert(rw.oldFaceLoop() == [0u, 4u],
           "offsets come from the captured windings, so a stale faceLoop cannot "
           ~ "poison them");
}

// ---------------------------------------------------------------------------
// A stated drop is length-correct and zeroed, and it needs no capture — a
// kernel in the drop set must not pay for windings it will never read.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = twoQuadsWithCornerMap();
    m.dropCornerProvenance(CornerDrop.SubdivideNoLaw);
    m.buildLoops();

    const(float)[] after = uvOf(m);
    assert(after.length == m.loops.length * 2);
    foreach (v; after) assert(v == 0.0f, "a stated drop zeroes the plane");
}

// ---------------------------------------------------------------------------
// The declaration is consumed EXACTLY once. A second rebuild must not re-apply
// a correspondence whose old corner space is long gone.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = twoQuadsWithCornerMap();
    const float[] before = uvOf(m).dup;

    {
        auto rw = m.beginCornerRewrite();
        m.declareCornerProvenance(rw.unchanged());
        m.buildLoops();
    }
    assert(uvOf(m) == before);

    // Second rebuild: no declaration is pending, nothing is armed, the length
    // insurance sees a length-correct map and keeps it.
    m.buildLoops();
    assert(uvOf(m) == before, "a spent declaration must not be applied twice");
}
