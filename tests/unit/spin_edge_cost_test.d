// Task 1471 — the STRUCTURAL gate for the bulk spin.
//
// `mesh.spinEdge` was measured quadratic in the face count: 145.7 ms at 576
// faces, 539.8 ms at 1024, 2374.8 ms at 2304, 7072.5 ms at 4096 — exponent
// 1.98, which extrapolates to ~66 minutes for ONE apply on the perf lane's
// 99 856-face grid. The root is NOT task 1330's (the hide-derive count is a
// flat 1/1/1 across three sizes — measured through the 1373 rig in
// `command_hide_derive_test.d`, which this task adds the spin to). It is that
// one apply performs S spins and each spin rebuilt the edge array, rebuilt the
// half-edge loops and committed — three O(M) passes — so the cost was S x O(M)
// with S growing with the mesh.
//
// WHY THESE ARE COUNTS AND NOT TIMES. A time assertion on a shared host is a
// flake; a count is control flow and is the same on any machine at any load.
// The claim being pinned is structural — "the derived-structure rebuild happens
// once per ROUND, and the round count does not grow with the mesh" — so counts
// state it directly instead of correlating with it.
//
// WHAT DELIBERATELY IS NOT HERE:
//   * no `<= MAX_SPIN_ROUNDS` assertion anywhere. The cap is introduced by the
//     very fix under test, so comparing against it could not fail: a runaway
//     round count would hide BEHIND the clamp. Linearity is asserted as
//     EQUALITY across three mesh sizes (K2), and the clamp is separately
//     asserted never to have fired (K2-cap).
//   * no ceiling on the eager hide-derive count (K1c asserts only `> 1`). The
//     eager regime is task 1333's open cost; pinning a ceiling would freeze an
//     open cost as if it were settled — the same reasoning
//     `command_hide_derive_test.d`'s clause (2b) states for itself.
module tests.unit.spin_edge_cost_test;

import std.algorithm : canFind, min;
import std.conv      : to;
import std.format    : format;

import command;
import mesh;
import view;
import editmode;
import math : Vec3;
import selection_product : repointToEdgeKeys;
import commands.mesh.spin_edge : MeshSpinEdge;

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

private void selectAllFaces(ref Mesh m) {
    m.syncSelection();
    foreach (i; 0 .. m.faces.length) m.selectFace(cast(uint)i);
}

// Ring equality up to rotation AND direction — a winding regression must not
// slip through a set comparison.
private bool ringsEqual(const(uint)[] a, const(uint)[] b) {
    if (a.length != b.length) return false;
    immutable n = a.length;
    if (n == 0) return true;
    foreach (dir; 0 .. 2) {
        foreach (off; 0 .. n) {
            bool ok = true;
            foreach (k; 0 .. n) {
                immutable size_t idx = dir == 0 ? (off + k) % n
                                                : (off + n - k) % n;
                if (a[k] != b[idx]) { ok = false; break; }
            }
            if (ok) return true;
        }
    }
    return false;
}

private bool meshesMatch(ref Mesh a, ref Mesh b, out string why) {
    if (a.vertices.length != b.vertices.length) {
        why = format("vertex count %d vs %d", a.vertices.length, b.vertices.length);
        return false;
    }
    foreach (i; 0 .. a.vertices.length)
        if (a.vertices[i] != b.vertices[i]) {
            why = format("vertex %d moved: %s vs %s", i, a.vertices[i], b.vertices[i]);
            return false;
        }
    if (a.faces.length != b.faces.length) {
        why = format("face count %d vs %d", a.faces.length, b.faces.length);
        return false;
    }
    foreach (i; 0 .. a.faces.length)
        if (!ringsEqual(a.faces[i], b.faces[i])) {
            why = format("face %d ring %s vs %s", i,
                         a.faces[i].to!string, b.faces[i].to!string);
            return false;
        }
    if (a.edges.length != b.edges.length) {
        why = format("edge count %d vs %d", a.edges.length, b.edges.length);
        return false;
    }
    why = "";
    return true;
}

// The four-face fixture K4 is built on. Eight vertices; f0/f1 share edge (0,1)
// and f2/f3 share edge (2,4). Derived against the kernel's own ring arithmetic:
// spinning (0,1) yields c = 2 and e = 4, so the FIRST target's product is
// literally the SECOND target's key, while the two face pairs are disjoint —
// which is what lets the Edges branch's transaction gate wave the selection
// through and makes the round kernel's product-deferral observable.
private Mesh makeProductCollidesFixture() {
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
        Vec3(2, 0, 0), Vec3(2, 1, 0), Vec3(3, 1, 0), Vec3(3, 0, 0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([1u, 0u, 4u, 5u]);
    m.addFace([2u, 4u, 6u]);
    m.addFace([4u, 2u, 7u]);
    m.buildLoops();
    return m;
}

// Three triangles sharing vertex pairs — the same shape as
// `foldover_makes_third_face` in tests/fixtures/spin_gate_narrower.json. A
// spin here creates a diagonal that ALREADY EXISTS (ledger row 17), which the
// kernel deliberately performs rather than refusing.
private Mesh makeFoldOverFixture() {
    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
    m.addFace([0u, 1u, 2u]);
    m.addFace([0u, 2u, 3u]);
    m.addFace([1u, 2u, 3u]);
    m.buildLoops();
    return m;
}

// ---------------------------------------------------------------------------
// K1c — the hide-derive instrument is not stuck at its deferred value
// ---------------------------------------------------------------------------

unittest {
    // With one face hidden, `beginHideDeriveBatch` arms NO deferral
    // (`g_hideDeriveDeferSafe = !anyHideBitSet()`), so the count becomes a
    // direct read of how many times the command commits. It must therefore be
    // strictly greater than the deferred regime's 1.
    //
    // The bound is deliberately open on top. Before the fix the number was
    // ~2S+1 (measured: 31 on a 4x4 grid); after it, ~2R+1. Both are > 1, so
    // this arm survives the fix instead of going red the moment the fix works
    // — which is exactly what an upper bound tied to S would have done.
    View v = new View(0, 0, 800, 600);
    Mesh m = makeGridPlane(4);
    selectAllFaces(m);
    m.setFaceHidden(0, true);
    assert(m.isFaceHidden(0), "fixture: face 0 must be hidden");

    auto c = new MeshSpinEdge(&m, v, EditMode.Polygons);
    g_hideDeriveRuns = 0;
    const bool applied = c.apply();
    assert(applied, "K1c fixture: the spin must actually apply");
    assert(g_hideDeriveRuns > 1,
           format("K1c: with a face hidden the deferral is OFF, so the derive " ~
                  "count is a direct read of the command's commits — got %d, " ~
                  "which means the instrument is stuck rather than measuring",
                  g_hideDeriveRuns));
}

// ---------------------------------------------------------------------------
// K2 / K2-cap / K2b — the rebuild count does not grow with the mesh
// ---------------------------------------------------------------------------

unittest {
    View v = new View(0, 0, 800, 600);
    immutable int[] sizes = [8, 16, 32];       // 64 / 256 / 1024 faces
    size_t[] rebuilds, loops, spins, rounds;

    foreach (gridN; sizes) {
        Mesh m = makeGridPlane(gridN);
        selectAllFaces(m);
        auto c = new MeshSpinEdge(&m, v, EditMode.Polygons);
        g_rebuildEdgesRuns = 0;
        g_buildLoopsRuns   = 0;
        const bool applied = c.apply();
        assert(applied,
               format("K2 fixture: the spin must apply on a %dx%d grid, or the " ~
                      "counts below are vacuous", gridN, gridN));
        rebuilds ~= g_rebuildEdgesRuns;
        loops    ~= g_buildLoopsRuns;
        spins    ~= g_spinsApplied;
        rounds   ~= g_spinRounds;

        // K2-cap. Without this, a runaway round count would simply stop at
        // MAX_SPIN_ROUNDS and the equality above could be satisfied by the
        // CLAMP rather than by the conflict graph.
        assert(!g_spinRoundsCapped,
               format("K2-cap: MAX_SPIN_ROUNDS fired on a %dx%d grid (%d rounds, " ~
                      "%d spins). The cap is a backstop against an infinite loop, " ~
                      "not a working regime — if it fires, the greedy round pick " ~
                      "is not converging and no linearity claim below means " ~
                      "anything", gridN, gridN, g_spinRounds, g_spinsApplied));
        assert(g_spinRounds >= 1,
               "K2-cap: a successful apply must have run at least one round");

        // K2b — the instrument is live. Not `>= 0`, which is unfalsifiable:
        // deleting the increment must fail this on a zero.
        assert(g_rebuildEdgesRuns >= 1 && g_buildLoopsRuns >= 1,
               format("K2b: an apply that spun %d edges recorded %d rebuildEdges " ~
                      "and %d buildLoops — the counter is dead",
                      g_spinsApplied, g_rebuildEdgesRuns, g_buildLoopsRuns));
    }

    // The spin count MUST grow, or the equality below is trivially satisfied
    // by a command that does nothing more on a bigger mesh.
    foreach (k; 1 .. spins.length)
        assert(spins[k] > spins[k - 1] * 2,
               format("K2 precondition: spins per apply did not grow with the " ~
                      "mesh (%s at %s). Without a growing S, equal rebuild " ~
                      "counts prove nothing", spins.to!string, sizes.to!string));

    foreach (k; 1 .. rebuilds.length) {
        assert(rebuilds[k] == rebuilds[0] && loops[k] == loops[0],
               format("K2: the derived-structure rebuild per ONE apply grew with " ~
                      "the mesh. rebuildEdges %s, buildLoops %s, rounds %s for " ~
                      "%s spins at grid sizes %s. That is the quadratic itself — " ~
                      "S x O(M) with S proportional to the mesh — and the fix is " ~
                      "to pay the rebuild once per ROUND, not once per spin",
                      rebuilds.to!string, loops.to!string, rounds.to!string,
                      spins.to!string, sizes.to!string));
    }
}

// ---------------------------------------------------------------------------
// K3a — a clean grid spins with NO fold-over, and to a 2-manifold result
// ---------------------------------------------------------------------------

unittest {
    // TWO laws with very different standing, and the difference is measured
    // rather than assumed — do not read them as interchangeable.
    //
    //   (1) ZERO COLLISIONS. This is the DISCRIMINATOR. Deleting the round's
    //       "the two faces have not already been rewritten this round" check
    //       makes an 8x8 grid report SEVEN fold-over collisions instead of
    //       none (measured 2026-08-20).
    //
    //   (2) 2-MANIFOLD, no repeated ring vertex, V/F/E unchanged. A regression
    //       guard, and NOT what the mutation above breaks: run with clause (1)
    //       disabled, the same mutation leaves the 8x8 result 2-manifold, quad
    //       only, 144 edges before and after, and the whole suite GREEN
    //       (measured). It is kept because it is the property a reader of this
    //       file will assume is being protected, and because it is true — but
    //       nobody should believe it is doing the work here.
    View v = new View(0, 0, 800, 600);
    Mesh m = makeGridPlane(8);                  // 64 faces
    immutable size_t vBefore = m.vertices.length;
    immutable size_t fBefore = m.faces.length;
    immutable size_t eBefore = m.edges.length;
    selectAllFaces(m);

    auto c = new MeshSpinEdge(&m, v, EditMode.Polygons);
    const bool applied = c.apply();
    assert(applied, "K3a fixture: the spin must apply");
    assert(g_spinsApplied > 1,
           format("K3a fixture: a mass spin, not one — got %d", g_spinsApplied));

    // (1) — and the size is load-bearing, because the general claim it
    // replaces is FALSE. "On a quad grid the new diagonal cannot already
    // exist" was the reason offered for this line; measured 2026-08-20, a 4x4
    // grid with every face selected produces TWO collisions and a result with
    // two three-face edges, and so do 5x5, a level-1 and a level-2 subdivided
    // cube. 8x8 and 16x16 produce zero. This is a measurement at a stated
    // size, not a property of quad grids.
    assert(g_spinCollisions == 0,
           format("K3a: the round kernel performed %d fold-over spins on a " ~
                  "clean 8x8 grid (%s). A spin whose new diagonal already " ~
                  "exists leaves a three-face edge (ledger row 17); on this " ~
                  "fixture the greedy round pick is supposed to make that " ~
                  "unreachable, so a non-zero count means two spins in one " ~
                  "round shared a face", g_spinCollisions,
                  g_spinCollisionKeys.to!string));

    // (2)
    auto counts = m.edgePolygonCounts();        // NOT facesAroundEdge: the ring
                                                // walk under-reports a
                                                // non-manifold fan as ONE face
    foreach (i, n; counts)
        assert(n <= 2,
               format("K3a: edge %d borders %d faces after the spin", i, n));

    foreach (fi, ref f; m.faces) {
        bool[uint] seen;
        foreach (vv; f) {
            assert((vv in seen) is null,
                   format("K3a: face %d has a repeated vertex: %s",
                          fi, f.to!string));
            seen[vv] = true;
        }
    }

    assert(m.vertices.length == vBefore && m.faces.length == fBefore &&
           m.edges.length == eBefore,
           format("K3a: a spin moves no vertex, adds no face and — with no " ~
                  "fold-over — destroys no edge, but counts went %d/%d/%d -> " ~
                  "%d/%d/%d", vBefore, fBefore, eBefore,
                  m.vertices.length, m.faces.length, m.edges.length));
}

// ---------------------------------------------------------------------------
// K3b — where a fold-over DOES happen, every non-manifold edge is one
// ---------------------------------------------------------------------------

private void assertFoldOverAccountedFor(ref Mesh m, string label) {
    assert(g_spinCollisions >= 1,
           label ~ ": this fixture exists to produce a fold-over — a spin " ~
           "whose new diagonal already exists (ledger row 17). Zero " ~
           "collisions means the fixture, or the fold-over law, changed, and " ~
           "the inclusion below would be `empty in empty`");

    auto counts = m.edgePolygonCounts();
    ulong[] nonManifold;
    foreach (i, n; counts)
        if (n > 2) nonManifold ~= edgeKey(m.edges[i][0], m.edges[i][1]);

    assert(nonManifold.length >= 1,
           format("%s: %d collisions were recorded but no edge ends up with " ~
                  "more than two faces. Row 17 says a fold-over spin LEAVES a " ~
                  "three-face edge; if it no longer does, the law moved",
                  label, g_spinCollisions));

    // INCLUSION, not equality: two collisions can land on one edge, and an
    // edge that gains a third face can also gain a fourth.
    foreach (k; nonManifold)
        assert(g_spinCollisionKeys.canFind(k),
               format("%s: edge key %d borders more than two faces but is not " ~
                      "one of the diagonals a spin collided on (%s). A " ~
                      "non-manifold edge that no spin created is damage, not " ~
                      "row 17", label, k, g_spinCollisionKeys.to!string));
}

unittest {
    View v = new View(0, 0, 800, 600);
    Mesh m = makeFoldOverFixture();
    selectAllFaces(m);
    auto c = new MeshSpinEdge(&m, v, EditMode.Polygons);
    assert(c.apply(), "K3b fixture: the spin must apply");
    assertFoldOverAccountedFor(m, "K3b/three-triangles");
}

unittest {
    // The SAME law on a mesh where the round grouping is what produces the
    // fold-over, and this cell is the one that records a real behaviour
    // change, so read it carefully.
    //
    // Measured 2026-08-20 with every face selected: the pre-1471 sequential
    // pass (one `Mesh.spinEdge` per key) spins 17 of 24 targets here and
    // leaves 40 edges, 2-manifold. The round kernel spins 18 and leaves 38
    // edges with two three-face edges. It is not alone — 5x5 (31 -> 34 spins,
    // 0 -> 1 non-manifold), subdivideCube(1) (28 -> 31, 0 -> 1) and
    // subdivideCube(2) (116 -> 122, 0 -> 2) do the same, while 8x8, 16x16 and
    // the L-shape stay clean on both paths. Rounds resolve every target
    // against ROUND-START topology, so they perform spins the sequential pass
    // had already refused, and some of those are fold-overs.
    //
    // What is asserted is the BOUND, not the count: every non-manifold edge
    // must be a diagonal a spin actually collided on. That is exactly the
    // task's own "H-broken" line — "non-manifold edges IN EXCESS of the row-17
    // collisions" — so it holds today and would still hold if the branch were
    // later given an incremental-adjacency kernel that produced zero of both.
    // It does not freeze the degradation as correct.
    View v = new View(0, 0, 800, 600);
    Mesh m = makeGridPlane(4);
    selectAllFaces(m);
    auto c = new MeshSpinEdge(&m, v, EditMode.Polygons);
    assert(c.apply(), "K3b/grid4 fixture: the spin must apply");
    assertFoldOverAccountedFor(m, "K3b/grid4");
}

// ---------------------------------------------------------------------------
// K4-geometry — the batch equals the sequence on the Edges branch
// ---------------------------------------------------------------------------

unittest {
    // Differential: the SAME input driven through the old one-spin-at-a-time
    // path (`Mesh.spinEdge`, which still rebuilds and commits per call) and
    // through `spinEdgesByKeys`. The Edges branch promises bit-identity, so a
    // difference here is that promise broken.
    Mesh seq = makeProductCollidesFixture();
    Mesh bat = makeProductCollidesFixture();

    immutable ulong kA = edgeKey(0, 1);
    immutable ulong kB = edgeKey(2, 4);

    // PRECONDITION 1: the first target's PRODUCT is the second target's KEY.
    // Read off the kernel's ring arithmetic and asserted here so an edit to the
    // fixture cannot quietly turn this arm into a test of two unrelated spins.
    {
        Mesh probe = makeProductCollidesFixture();
        immutable uint ei = probe.edgeIndexByKey(kA);
        assert(ei != ~0u, "K4 fixture: edge (0,1) must exist");
        uint[2] diag;
        assert(probe.spinEdge(ei, diag), "K4 fixture: (0,1) must spin");
        assert(edgeKey(diag[0], diag[1]) == kB,
               format("K4 precondition: spinning (0,1) must produce (2,4) — the " ~
                      "second target's key — but produced (%d,%d)",
                      diag[0], diag[1]));
    }
    // PRECONDITION 2: the two face pairs are DISJOINT, so the Edges branch's
    // transaction gate passes the selection through instead of cancelling.
    {
        Mesh probe = makeProductCollidesFixture();
        auto ef = probe.buildEdgeFaces();
        auto pA = kA in ef, pB = kB in ef;
        assert(pA !is null && pB !is null, "K4 fixture: both edges interior");
        immutable int a0 = (*pA)[0], a1 = (*pA)[1];
        immutable int b0 = (*pB)[0], b1 = (*pB)[1];
        assert(a0 >= 0 && a1 >= 0 && b0 >= 0 && b1 >= 0,
               "K4 fixture: neither target may be a boundary edge");
        assert(a0 != b0 && a0 != b1 && a1 != b0 && a1 != b1,
               format("K4 precondition: face pairs {%d,%d} and {%d,%d} must be " ~
                      "disjoint or the transaction gate cancels the command",
                      a0, a1, b0, b1));
    }

    immutable ulong[] keys = [kA, kB];

    size_t seqAffected = 0;
    ulong[] seqProducts;
    foreach (k; keys) {
        immutable uint ei = seq.edgeIndexByKey(k);
        if (ei == ~0u) continue;
        uint[2] diag;
        if (seq.spinEdge(ei, diag)) {
            ++seqAffected;
            seqProducts ~= edgeKey(diag[0], diag[1]);
        }
    }

    ulong[] batProducts;
    immutable size_t batAffected = bat.spinEdgesByKeys(keys, batProducts);

    assert(seqAffected == 1,
           format("K4 fixture: the sequential pass must spin exactly one of the " ~
                  "two — the second sees a 4-face edge and refuses — got %d",
                  seqAffected));
    assert(batAffected == seqAffected,
           format("K4: batch spun %d, sequence spun %d. The round kernel must " ~
                  "DEFER a target whose edge is the product of a spin already " ~
                  "taken this round; without that it resolves the second target " ~
                  "against round-start topology and performs a spin the " ~
                  "sequential pass refuses", batAffected, seqAffected));
    assert(batProducts == seqProducts,
           format("K4: product keys %s vs %s",
                  batProducts.to!string, seqProducts.to!string));

    string why;
    assert(meshesMatch(seq, bat, why), "K4: batch != sequence — " ~ why);
}

// ---------------------------------------------------------------------------
// K4-order — the batch preserves the SELECTION ORDER the sequence produces
// ---------------------------------------------------------------------------

unittest {
    // The Edges branch collects its keys by walking `selectedEdges`, i.e. in
    // EDGE-INDEX order, and `repointToEdgeKeys` turns the product order into
    // `edgeSelectionOrder[]` stamps that live in `MeshSnapshot` and survive
    // undo. So a kernel that sorted its keys would silently rewrite the
    // post-spin selection order. This arm is what forbids it.
    //
    // The fixture is SEARCHED rather than hand-picked so the precondition it
    // needs — index order != key order — is a property the test establishes,
    // not one it hopes for.
    Mesh probe = makeGridPlane(4);
    auto counts = probe.edgePolygonCounts();
    auto ef = probe.buildEdgeFaces();

    uint ia = ~0u, ib = ~0u;
    outer: foreach (uint i; 0 .. cast(uint)probe.edges.length) {
        if (counts[i] != 2) continue;
        immutable ulong ki = edgeKey(probe.edges[i][0], probe.edges[i][1]);
        auto pi = ki in ef;
        if (pi is null || (*pi)[0] < 0 || (*pi)[1] < 0) continue;
        foreach (uint j; i + 1 .. cast(uint)probe.edges.length) {
            if (counts[j] != 2) continue;
            immutable ulong kj = edgeKey(probe.edges[j][0], probe.edges[j][1]);
            auto pj = kj in ef;
            if (pj is null || (*pj)[0] < 0 || (*pj)[1] < 0) continue;
            // disjoint face pairs, so the transaction gate lets both through
            if ((*pi)[0] == (*pj)[0] || (*pi)[0] == (*pj)[1] ||
                (*pi)[1] == (*pj)[0] || (*pi)[1] == (*pj)[1]) continue;
            if (ki <= kj) continue;      // we want index order != key order
            ia = i; ib = j;
            break outer;
        }
    }
    assert(ia != ~0u,
           "K4-order fixture: no pair of interior edges on a 4x4 grid has " ~
           "index order differing from key order with disjoint face pairs — " ~
           "the arm would be vacuous");

    // PRECONDITION, asserted: sorting by key would REVERSE this pair.
    assert(edgeKey(probe.edges[ia][0], probe.edges[ia][1]) >
           edgeKey(probe.edges[ib][0], probe.edges[ib][1]),
           "K4-order precondition: the selected edges must be in a different " ~
           "order by INDEX than by KEY, or a sorting kernel is indistinguishable");

    View v = new View(0, 0, 800, 600);

    // (a) the real command, which goes through spinEdgesByKeys.
    Mesh bat = makeGridPlane(4);
    bat.syncSelection();
    bat.selectEdge(cast(int)ia);
    bat.selectEdge(cast(int)ib);
    auto c = new MeshSpinEdge(&bat, v, EditMode.Edges);
    assert(c.apply(), "K4-order: the command must apply");

    // (b) the old sequential path, reproduced: keys in edge-INDEX order,
    //     one `spinEdge` each, then the same re-point.
    Mesh seq = makeGridPlane(4);
    seq.syncSelection();
    seq.selectEdge(cast(int)ia);
    seq.selectEdge(cast(int)ib);
    ulong[] selKeys;
    foreach (size_t i, bool sel; seq.selectedEdges)
        if (sel) selKeys ~= edgeKey(seq.edges[i][0], seq.edges[i][1]);
    assert(selKeys.length == 2, "K4-order: two edges selected");
    ulong[] seqProducts;
    size_t seqAffected = 0;
    foreach (k; selKeys) {
        immutable uint ei = seq.edgeIndexByKey(k);
        if (ei == ~0u) continue;
        uint[2] diag;
        if (seq.spinEdge(ei, diag)) {
            ++seqAffected;
            seqProducts ~= edgeKey(diag[0], diag[1]);
        }
    }
    assert(seqAffected == 2,
           format("K4-order fixture: both edges must spin, or the order arm " ~
                  "compares one stamp — got %d", seqAffected));
    repointToEdgeKeys(&seq, seqProducts);

    string why;
    assert(meshesMatch(seq, bat, why), "K4-order: batch != sequence — " ~ why);

    assert(seq.edgeSelectionOrder.length == bat.edgeSelectionOrder.length,
           format("K4-order: stamp array lengths %d vs %d",
                  seq.edgeSelectionOrder.length, bat.edgeSelectionOrder.length));
    foreach (i; 0 .. min(seq.edgeSelectionOrder.length,
                         bat.edgeSelectionOrder.length))
        assert(seq.edgeSelectionOrder[i] == bat.edgeSelectionOrder[i],
               format("K4-order: edgeSelectionOrder[%d] is %d in the batch and " ~
                      "%d in the sequence. The kernel re-ordered the keys, so " ~
                      "`repointToEdgeKeys` stamped the products in a different " ~
                      "order — and those stamps go into MeshSnapshot and " ~
                      "survive undo", i, bat.edgeSelectionOrder[i],
                      seq.edgeSelectionOrder[i]));
}
