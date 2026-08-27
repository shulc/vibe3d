// split_edge_provenance_test — task 1903 Stage L2-P0.
//
// ===========================================================================
// WHAT THIS MODULE IS FOR, AND WHY IT IS A PREREQUISITE RATHER THAN A TEST
// ===========================================================================
// `mesh.split_edge` used to splice the new corner into every incident winding
// with its OWN open-coded loop, inside `evaluate`, and then call
// `rebuildEdges()` / `buildLoops()` by hand. That splice changes the mesh's
// TOTAL corner count without opening a corner rewrite, so `buildLoops` reached
// the task 0830/0901 insurance branch: it zeroed every PolyVertex map WHOLE on
// the FORWARD, and — because the unit lane is a `-debug` build — tripped
//
//     debug assert(false, "corner provenance: a face rewrite reached
//     buildLoops without declaring what became of the corners, and without
//     arming beginCornerRewrite()/beginCornerRelocate() either — …")
//
// on any mesh carrying a live per-corner map. That is not a latent nicety: it
// ABORTS the module. Stage L2's parity fixture has to drive `split_edge` on a
// UV-carrying stand, so the fixture could not have been captured at all before
// this reroute — which is why L2-P0 comes before the fixture and before every
// migration, and carries NO delta content of its own.
//
// The reroute is `Mesh.addEdgePoint(ei, 0.5f)`: the same splice
// (`insertEdgePoint`) wrapped in the `beginCornerRewrite()` /
// `declareCornerProvenance()` pair the command skipped, plus the same
// `rebuildEdges()` / `buildLoops()` tail. Two things follow and BOTH are
// checked below, because either alone is satisfiable by the broken code:
//
//   * the abort is gone (cells B/C run to completion at all), and
//   * the per-corner plane is CARRIED rather than zeroed — the pre-existing
//     forward bug the reroute fixes for free.
//
// THE SECOND HALF IS THE ONE THAT SURVIVES A `-release` BUILD. Under
// `-release` the `debug assert` compiles out and the old code merely zeroed
// the map and answered `true`; only cell C's value compare can tell the two
// apart there. Under `-debug` — the lane this module actually runs in — the
// old code aborts first and cell C is never reached. Neither cell is
// redundant: they redden in different build types.
//
// SEEN RED, lane U (`dub test --config=tests`; `tests/unit/**` blocks never
// run in `./run_test.d`, which links a prebuilt library) — on the UNMODIFIED
// tree, before the reroute existed. The verbatim abort is in the task card
// (2260). This is the rare witness whose red costs nothing to obtain: it is
// the tree's own behaviour, not a planted mutation.
// ===========================================================================
module tests.unit.commands.mesh.split_edge_provenance_test;

import std.format : format;
import std.math   : abs;

import command;
import editmode;
import math : Vec3;
import mesh;
import view;

import commands.mesh.split_edge : MeshSplitEdge;

// ---------------------------------------------------------------------------
// The stand.
//
// Two quads sharing edge (1,2), with a per-corner map whose value KEYS the
// corner's own position — u = 1 + loopIndex, v = 100 + loopIndex — so that
// "kept", "moved to a foreign corner" and "zeroed" are three distinguishable
// outcomes. A cube would not do: it carries no per-corner plane at all, and
// the whole phenomenon here lives on that plane.
//
// The shared edge is deliberately an INTERIOR one: the splice must land in two
// windings, at two DIFFERENT slots (face 0 gets it at slot 2, face 1 at slot
// 4), so a carry that resolves the new corner globally instead of per face
// produces a visibly wrong number in exactly one of them.
// ---------------------------------------------------------------------------
private Mesh* standMesh() {
    auto m = new Mesh;
    m.addVertex(Vec3(0, 0, 0));   // 0
    m.addVertex(Vec3(1, 0, 0));   // 1
    m.addVertex(Vec3(1, 1, 0));   // 2
    m.addVertex(Vec3(0, 1, 0));   // 3
    m.addVertex(Vec3(2, 0, 0));   // 4
    m.addVertex(Vec3(2, 1, 0));   // 5
    m.addFace([0, 1, 2, 3]);
    m.addFace([1, 4, 5, 2]);
    m.buildLoops();
    m.syncSelection();

    MeshMap uv;
    uv.name   = "uv";
    uv.dim    = 2;
    uv.domain = MapDomain.PolyVertex;
    uv.data.length = m.loops.length * 2;
    foreach (li; 0 .. m.loops.length) {
        uv.data[li * 2]     = 1.0f   + li;   // never 0 — a drop is unambiguous
        uv.data[li * 2 + 1] = 100.0f + li;
    }
    m.meshMaps ~= uv;
    return m;
}

private const(float)[] uvOf(Mesh* m) {
    foreach (ref mm; m.meshMaps)
        if (mm.domain == MapDomain.PolyVertex) return mm.data;
    return null;
}

// Corner-major base of face `fi` in the per-corner plane, walked from `faces`
// rather than from `loops` so the helper is valid before AND after a rebuild.
private size_t cornerBase(Mesh* m, size_t fi) {
    size_t b = 0;
    foreach (k; 0 .. fi) b += m.faces[k].length;
    return b;
}

// The index of the (unique) edge whose endpoints are {a, b}.
private int edgeOf(Mesh* m, uint a, uint b) {
    foreach (i, e; m.edges)
        if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a))
            return cast(int) i;
    return -1;
}

// ---------------------------------------------------------------------------
// CELL A — non-vacuity, asserted FIRST and in this module.
//
// Everything below is a statement about a per-corner plane on a mesh whose
// windings the command actually rewrites. If the stand carried no PolyVertex
// map, or the map were out of step with `faces`, or the selected edge were a
// boundary one incident to a single face, then `addEdgePoint` would decline
// the carry (`rw.active()` is false without a map) and every assertion in
// cells B and C would hold over ANY implementation, including the one that
// zeroes the plane. This cell is what stops that.
// ---------------------------------------------------------------------------
unittest {
    auto m = standMesh();

    assert(m.hasPolyVertexMap(),
        "A: the stand must carry a PolyVertex map — without one the corner "
      ~ "carry declines and cells B/C are vacuous");
    assert(m.loops.length == 8,
        format("A: stand corner total 8 expected, got %s", m.loops.length));
    assert(uvOf(m).length == m.loops.length * 2,
        "A: the stand's map must be in step with the corner space");

    const int ei = edgeOf(m, 1, 2);
    assert(ei >= 0, "A: the stand must own edge (1,2)");

    // The shared edge is incident to BOTH faces — the splice must land twice.
    int incident = 0;
    foreach (f; m.faces)
        foreach (k, _; f) {
            const uint x = f[k], y = f[(k + 1) % f.length];
            if ((x == 1 && y == 2) || (x == 2 && y == 1)) { ++incident; break; }
        }
    assert(incident == 2,
        format("A: the selected edge must be interior (2 incident faces), got %s",
               incident));

    // Every corner value is distinct and non-zero, so "kept" / "foreign" /
    // "zeroed" are three tellable outcomes rather than two.
    auto uv = uvOf(m);
    foreach (li; 0 .. m.loops.length) {
        assert(uv[li * 2] != 0.0f && uv[li * 2 + 1] != 0.0f,
            "A: a zero corner value would make a drop indistinguishable from a keep");
        foreach (lj; 0 .. li)
            assert(uv[li * 2] != uv[lj * 2],
                "A: corner values must be distinct to detect a permutation");
    }
}

// ---------------------------------------------------------------------------
// CELL B — the reroute itself, on the GEOMETRY channel.
//
// L2-P0 carries no delta content, so the whole of its forward behaviour must
// be the behaviour the open-coded splice had: one new vertex at the edge
// midpoint, spliced between the endpoints in both incident windings, edges
// re-derived, selection reset. This cell is what makes "a routing change, not
// a behaviour change" a claim with a check under it rather than a sentence.
//
// It is ALSO the cell that reddens by ABORT on the un-rerouted tree: the
// `debug assert` fires inside `evaluate`, before the first assertion here.
// ---------------------------------------------------------------------------
unittest {
    auto m = standMesh();
    auto v = new View(0, 0, 800, 600);

    const int ei = edgeOf(m, 1, 2);
    m.selectEdge(ei);
    assert(m.hasAnySelectedEdges(), "B: the command's own precondition");

    const size_t vBefore = m.vertices.length;
    const Vec3 mid = (m.vertices[1] + m.vertices[2]) * 0.5f;

    auto c = new MeshSplitEdge(m, v, EditMode.Edges);
    assert(c.apply(), "B: mesh.split_edge must apply on this stand");

    assert(m.vertices.length == vBefore + 1,
        format("B: exactly one vertex is added, got %s", m.vertices.length - vBefore));
    const uint vm = cast(uint)(m.vertices.length - 1);
    assert(abs(m.vertices[vm].x - mid.x) < 1e-6f
        && abs(m.vertices[vm].y - mid.y) < 1e-6f
        && abs(m.vertices[vm].z - mid.z) < 1e-6f,
        format("B: the new vertex must sit at the edge midpoint, got %s", m.vertices[vm]));

    assert(m.faces.length == 2, "B: split_edge adds no face");
    assert(m.faces[0].length == 5 && m.faces[1].length == 5,
        format("B: both incident windings gain the corner, got %s / %s",
               m.faces[0].length, m.faces[1].length));
    // The new corner sits BETWEEN the two endpoints in each winding.
    foreach (fi, f; m.faces) {
        bool between = false;
        foreach (k, _; f) {
            const uint prev = f[(k + f.length - 1) % f.length];
            const uint next = f[(k + 1) % f.length];
            if (f[k] == vm && ((prev == 1 && next == 2) || (prev == 2 && next == 1)))
                between = true;
        }
        assert(between,
            format("B: face %s does not carry the new corner between the endpoints: %s",
                   fi, f));
    }

    assert(m.loops.length == 10,
        format("B: corner total must be 10 after the splice, got %s", m.loops.length));
    assert(!m.hasAnySelectedEdges(), "B: split_edge resets the selection");
}

// ---------------------------------------------------------------------------
// CELL C — the per-corner plane is CARRIED, not zeroed.
//
// The half that outlives the `debug assert`. Under `-release` the assert is
// gone and the pre-reroute code was a silent, total loss of the UV plane on
// the FORWARD — a point added on one edge cost the whole mesh its UVs. Here
// each surviving corner must still hold its own key value, and each NEW corner
// must hold the per-face average of its two endpoint corners (the law frozen
// in tests/fixtures/uv_corner_transfer.json, resolved per face — which is what
// keeps a seam a seam).
//
// The two faces receive the new corner at DIFFERENT slots and their endpoint
// corners hold different values, so a carry resolved globally rather than per
// face gets face 1 wrong while face 0 stays right.
// ---------------------------------------------------------------------------
unittest {
    auto m = standMesh();
    auto v = new View(0, 0, 800, 600);

    // Pre-op corner values, per face, by slot.
    float[][] before;
    foreach (fi, f; m.faces) {
        float[] row;
        const size_t b = cornerBase(m, fi);
        foreach (k, _; f) row ~= uvOf(m)[(b + k) * 2];
        before ~= row;
    }

    const int ei = edgeOf(m, 1, 2);
    m.selectEdge(ei);
    auto c = new MeshSplitEdge(m, v, EditMode.Edges);
    assert(c.apply(), "C: forward");

    auto uv = uvOf(m);
    assert(uv.length == m.loops.length * 2,
        format("C: the map must be in step after the rebuild: %s vs %s",
               uv.length, m.loops.length * 2));

    const uint vm = cast(uint)(m.vertices.length - 1);
    foreach (fi, f; m.faces) {
        const size_t b = cornerBase(m, fi);
        // Endpoint corner values in THIS face, for the blend below.
        float ua = float.nan, ub = float.nan;
        foreach (k, vid; f) {
            if (vid == 1) ua = uv[(b + k) * 2];
            if (vid == 2) ub = uv[(b + k) * 2];
        }
        size_t src = 0;   // slot in the PRE-op winding
        foreach (k, vid; f) {
            const float got = uv[(b + k) * 2];
            if (vid == vm) {
                const float want = 0.5f * (ua + ub);
                assert(abs(got - want) < 1e-5f,
                    format("C: face %s new corner carries %s, expected the "
                         ~ "per-face blend %s — a carry resolved globally "
                         ~ "instead of per face lands here", fi, got, want));
                continue;                     // the new corner has no source
            }
            assert(abs(got - before[fi][src]) < 1e-5f,
                format("C: face %s slot %s holds %s, expected its own pre-op "
                     ~ "value %s — 0 means the plane was ZEROED whole (the "
                     ~ "un-rerouted forward), anything else means it moved to "
                     ~ "a foreign corner", fi, k, got, before[fi][src]));
            ++src;
        }
        assert(src == before[fi].length,
            format("C: face %s matched %s of %s pre-op corners",
                   fi, src, before[fi].length));
    }
}
