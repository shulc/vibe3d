// Edge Extend — the rotate/scale PIVOT, read from the frozen fixture
// `tests/fixtures/edge_extend/handles_and_pivot.json` (task 1610).
//
// THE LAW. The pivot is the MID OF THE BOUNDING BOX of the operand vertices —
// `(min + max) * 0.5` — and nothing else: not their centroid, not the action
// centre, not the whole mesh's box. Our implementation is
// `Mesh.selectionBBoxCenterEdges()`, reused rather than re-written (it is also
// what the action centre's Select MODE computes; the finding is that the extend
// arrives at the same point INDEPENDENTLY of that stage, not that it asks it).
//
// WHY THE RIG LOOKS THE WAY IT DOES — and why it must not be tidied up. Every
// oddity in it separates two candidate laws that a rounder mesh cannot:
//
//   * two selected edges sharing one vertex, with a ~13x length ratio
//       ⇒ bbox-mid and centroid land 0.774 apart (0.567 on the widest axis).
//         On any symmetric selection they coincide exactly, and a test built
//         on one is inert.
//   * two UNSELECTED vertices outside the selection
//       ⇒ the selected subset's box and the whole mesh's box land 0.570
//         apart — the NEAREST rival of the four, and the one that sets the
//         margin this file has to clear.
//   * placed off the origin, nothing axis-aligned
//       ⇒ the world origin is a distinguishable fourth candidate.
//   * a COMPOSITE rotation (rotX=25, rotZ=40) in the geometry cells
//       ⇒ a single-axis rotation leaves the pivot's third coordinate
//         unrecoverable from the output, so it cannot pin the point.
//
// The cube trap is asserted, not just described: `cube_cannot_discriminate`
// below shows all three candidates COINCIDING on a cube edge. That is how an
// earlier campaign came to record this pivot as "the selection centroid" — its
// rig could not tell. Do not add a cube cell here and call it coverage.
//
// The MOMENT the pivot is taken (tool initialisation, not drag start, not per
// evaluation) is not observable from a free function; it is pinned in
// `tests/test_fixture_edge_extend_handles_pivot.d`, which reads the same
// fixture through the armed tool.
module tests.unit.tools.edit.edge_extend_pivot_test;

import mesh;
import math : Vec3;

import std.json  : JSONValue, parseJSON;
import std.file  : readText;
import std.conv  : to;
import std.math  : abs;

// ---------------------------------------------------------------------------
// Fixture access. Hard assert on a missing/again-unreadable file — no
// try/catch (task 1062 rule): a fixture test that silently skips when its
// fixture moved is worse than no test.
// ---------------------------------------------------------------------------
private JSONValue fixture() {
    static JSONValue cached;
    static bool loaded = false;
    if (!loaded) {
        cached = parseJSON(readText("tests/fixtures/edge_extend/handles_and_pivot.json"));
        assert(cached["fixture"].str == "edge_extend_handles_and_pivot",
               "wrong fixture loaded for the edge-extend pivot test");
        loaded = true;
    }
    return cached;
}

private Vec3 v3(JSONValue a) {
    static double num(JSONValue x) {
        import std.json : JSONType;
        return x.type == JSONType.integer ? cast(double)x.integer : x.floating;
    }
    return Vec3(cast(float)num(a.array[0]),
                cast(float)num(a.array[1]),
                cast(float)num(a.array[2]));
}

private double dist(Vec3 a, Vec3 b) { return (a - b).length; }

// Tolerance. The fixture's numbers are printed to six decimals and our kernel
// runs in float32 on coordinates of order 5, so a few ulps plus the print
// rounding is ~2e-6 in the worst case. 1e-4 sits above that and still ~3000x
// BELOW the smallest thing this file has to discriminate (the 0.30 by which a
// centroid pivot displaces every ring vertex), so it can neither flake nor
// swallow the mutation.
private enum double kTol = 1e-4;

// Build the rig FROM THE FIXTURE rather than from a copy of it, so the two can
// never drift apart.
private Mesh buildRig() {
    auto rig = fixture()["rig"];
    Mesh m;
    foreach (v; rig["vertices"].array) m.vertices ~= v3(v);
    foreach (f; rig["faces"].array) {
        uint[] idx;
        foreach (i; f.array) idx ~= cast(uint)i.integer;
        m.addFace(idx);
    }
    m.buildLoops();
    m.syncSelection();
    if (m.edgeMarks.length < m.edges.length) m.resizeEdgeSelection();
    foreach (pair; rig["selected_edges"].array) {
        uint a = cast(uint)pair.array[0].integer;
        uint b = cast(uint)pair.array[1].integer;
        bool found = false;
        foreach (i; 0 .. m.edges.length) {
            uint x = m.edges[i][0], y = m.edges[i][1];
            if ((x == a && y == b) || (x == b && y == a)) {
                m.selectEdge(cast(int)i);
                found = true;
                break;
            }
        }
        assert(found, "rig edge (" ~ a.to!string ~ "," ~ b.to!string ~ ") not in the mesh");
    }
    return m;
}

private bool[] selectedEdgeMask(ref Mesh m) {
    bool[] mask;
    mask.length = m.edges.length;
    foreach (i; 0 .. m.edges.length)
        mask[i] = (m.edgeMarks[i] & Mesh.Marks.Select) != 0;
    return mask;
}

// ---------------------------------------------------------------------------
// 1. The POINT: the bbox mid of the selected vertices, and the rig separates
//    it from every rival by a margin the tolerance cannot cross.
//
//    MUTATION (run 2026-08-20): replacing the `(mn + mx) * 0.5f` in
//    Mesh.selectionBBoxCenterEdges with the mean of the same vertices turns
//    this cell RED at 0.5665 — 5665x the tolerance.
// ---------------------------------------------------------------------------
unittest {
    auto m = buildRig();
    auto cands = fixture()["pivot_candidates"];

    Vec3 pivot  = m.selectionBBoxCenterEdges();
    Vec3 winner = v3(cands["bbox_mid_of_selected_vertices"]);

    assert(dist(pivot, winner) < kTol,
        "extend pivot must be the bbox mid of the selected vertices; got ("
        ~ pivot.x.to!string ~ "," ~ pivot.y.to!string ~ "," ~ pivot.z.to!string
        ~ "), want (" ~ winner.x.to!string ~ "," ~ winner.y.to!string ~ ","
        ~ winner.z.to!string ~ ")");

    // Every OTHER candidate must be far away, or the cell above is inert.
    // These distances are the rig's whole purpose; assert them so a future
    // "simplification" of the rig fails here rather than silently going vacuous.
    foreach (name; ["centroid_of_selected_vertices",
                    "bbox_mid_of_whole_mesh",
                    "world_origin"]) {
        double d = dist(v3(cands[name]), winner);
        assert(d > 0.1,
            "rig no longer separates the pivot from `" ~ name ~ "` (only "
            ~ d.to!string ~ " away) — fix the RIG, not the assertion");
    }
    // The two numbers this rig exists to produce, recomputed here rather than
    // read from the fixture's own annotations: the mid-vs-MEAN separation (the
    // law an earlier campaign got wrong) and the nearest rival of all four (the
    // whole-mesh box, which is what the two unselected vertices buy). Both are
    // thousands of times the tolerance, so neither cell above can pass by luck.
    assert(abs(dist(v3(cands["centroid_of_selected_vertices"]), winner) - 0.7739) < 0.01,
        "the mid-vs-mean separation on this rig changed; the rig was edited");
    assert(abs(dist(v3(cands["bbox_mid_of_whole_mesh"]), winner) - 0.5701) < 0.01,
        "the selected-box vs whole-mesh-box separation changed; the rig was edited");
}

// ---------------------------------------------------------------------------
// 2. The GEOMETRY, interactive case: the kernel run about that pivot
//    reproduces the frozen ring, and the topology is the frozen topology.
//
//    MUTATION: feeding the centroid instead moves all three ring vertices by
//    0.3035 — 3000x the tolerance.
// ---------------------------------------------------------------------------
unittest {
    auto m = buildRig();
    auto c = fixture()["cases"].array[0];
    assert(c["name"].str == "interactive_rotate_pivot");
    assert(c["matched_candidate"].str == "bbox_mid_of_selected_vertices");

    Vec3 pivot = m.selectionBBoxCenterEdges();
    auto p = c["parameters"];
    size_t n = m.extendEdgesByMask(selectedEdgeMask(m),
                                   cast(float)p["inset"].floating,
                                   cast(float)p["shift"].floating,
                                   v3(p["offset"]),
                                   Vec3(cast(float)p["rotateX_deg"].floating,
                                        cast(float)p["rotateY_deg"].floating,
                                        cast(float)p["rotateZ_deg"].floating),
                                   v3(p["scale"]),
                                   cast(int)p["segments"].integer,
                                   pivot);
    assert(n == 2, "both selected edges must extend, got " ~ n.to!string);

    auto topo = fixture()["topology_after_one_application"];
    assert(m.vertices.length == cast(size_t)topo["vertex_count"].integer,
        "vertex count after one apply: got " ~ m.vertices.length.to!string);
    assert(m.faces.length == cast(size_t)topo["face_count"].integer,
        "face count after one apply: got " ~ m.faces.length.to!string);

    // The source cage is untouched (pure-add kernel) — so the ring is the
    // appended tail, one vertex per distinct selected vertex, in source order.
    auto rigVerts = fixture()["rig"]["vertices"].array;
    foreach (i; 0 .. rigVerts.length)
        assert(dist(m.vertices[i], v3(rigVerts[i])) < kTol,
            "source vertex " ~ i.to!string ~ " moved; the kernel must be pure-add");

    auto gold = c["new_ring_vertices"].array;
    assert(m.vertices.length - rigVerts.length == gold.length,
        "expected one new vertex per distinct selected vertex");
    foreach (i, g; gold) {
        Vec3 got = m.vertices[rigVerts.length + i];
        Vec3 want = v3(g);
        assert(dist(got, want) < kTol,
            "ring vertex " ~ i.to!string ~ " is " ~ dist(got, want).to!string
            ~ " off the frozen value — got (" ~ got.x.to!string ~ ","
            ~ got.y.to!string ~ "," ~ got.z.to!string ~ ")");
    }
}

// ---------------------------------------------------------------------------
// 3. The GEOMETRY, command case — the fixture's own CONTROL. The same tool,
//    the same parameters and the same rig with the pivot never populated
//    pivots at the WORLD ORIGIN, which is what our non-interactive path
//    (applyHeadless / the one-shot mesh.edge_extend command) does.
//
//    It is what makes case 2 above evidence: the two cells differ ONLY in the
//    pivot, and their outputs are 1.18 apart.
// ---------------------------------------------------------------------------
unittest {
    auto m = buildRig();
    auto c = fixture()["cases"].array[1];
    assert(c["name"].str == "command_path_rotate_pivot");
    assert(c["matched_candidate"].str == "world_origin");

    auto p = c["parameters"];
    m.extendEdgesByMask(selectedEdgeMask(m),
                        cast(float)p["inset"].floating,
                        cast(float)p["shift"].floating,
                        v3(p["offset"]),
                        Vec3(cast(float)p["rotateX_deg"].floating,
                             cast(float)p["rotateY_deg"].floating,
                             cast(float)p["rotateZ_deg"].floating),
                        v3(p["scale"]),
                        cast(int)p["segments"].integer,
                        Vec3(0, 0, 0));

    auto rigVerts = fixture()["rig"]["vertices"].array;
    auto gold = c["new_ring_vertices"].array;
    foreach (i, g; gold) {
        Vec3 got = m.vertices[rigVerts.length + i];
        assert(dist(got, v3(g)) < kTol,
            "origin-pivot ring vertex " ~ i.to!string ~ " is "
            ~ dist(got, v3(g)).to!string ~ " off the frozen value");
    }

    // And the two cases really are far apart — otherwise cell 2 would pass on
    // a wrong pivot too.
    auto interactiveGold = fixture()["cases"].array[0]["new_ring_vertices"].array;
    double worst = 0;
    foreach (i, g; gold) {
        double d = dist(v3(g), v3(interactiveGold[i]));
        if (d > worst) worst = d;
    }
    assert(worst > 1.0,
        "the two pivot paths must produce visibly different geometry; worst "
        ~ "separation is only " ~ worst.to!string);
}

// ---------------------------------------------------------------------------
// 4. cube_cannot_discriminate — the trap, asserted rather than described.
//
//    On a cube edge the bbox mid of the selection, the centroid of the same
//    vertices and the world-relative symmetry all agree, so EVERY candidate
//    law produces the same pivot and a cube-based test proves nothing. This
//    cell fails if someone ever makes the cube discriminating (in which case
//    the comment above it is what needs revisiting), and it is why the rig in
//    this file is the shape it is.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = makeCube();
    if (m.edgeMarks.length < m.edges.length) m.resizeEdgeSelection();
    // The top-front edge (-0.5,0.5,0.5)-(0.5,0.5,0.5).
    foreach (i; 0 .. m.edges.length) {
        Vec3 a = m.vertices[m.edges[i][0]], b = m.vertices[m.edges[i][1]];
        bool hit = ((a - Vec3(-0.5f, 0.5f, 0.5f)).length < 1e-4f
                 && (b - Vec3( 0.5f, 0.5f, 0.5f)).length < 1e-4f)
                || ((a - Vec3( 0.5f, 0.5f, 0.5f)).length < 1e-4f
                 && (b - Vec3(-0.5f, 0.5f, 0.5f)).length < 1e-4f);
        if (hit) { m.selectEdge(cast(int)i); break; }
    }

    Vec3 boxMid = m.selectionBBoxCenterEdges();

    // Centroid of the same two vertices, computed here in this test's own
    // arithmetic — the rejected law, spelled out so the comparison is real.
    Vec3 sum = Vec3(0, 0, 0);
    int cnt = 0;
    foreach (i; 0 .. m.edges.length) {
        if ((m.edgeMarks[i] & Mesh.Marks.Select) == 0) continue;
        foreach (vi; m.edges[i]) { sum = sum + m.vertices[vi]; ++cnt; }
    }
    Vec3 centroid = sum * (1.0f / cnt);

    assert(dist(boxMid, centroid) < 1e-6,
        "a cube edge is supposed to make the two laws indistinguishable — if "
        ~ "this fires, the anti-cube warning at the top of this file is stale");
}
