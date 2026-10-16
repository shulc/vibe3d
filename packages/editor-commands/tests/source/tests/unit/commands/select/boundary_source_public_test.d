module tests.unit.commands.select.boundary_source_public_test;

import commands.select.boundary;

import command;
import mesh;
import view;
import vibe3d.editing.contracts.editmode;
import snapshot : SelectionSnapshot;

// ---------------------------------------------------------------------------
// Unit tests. The reference-parity cases live in
// tests/unit/select_boundary_test.d against the frozen fixture; what is
// pinned HERE is the predicate itself on the three shapes that separate it
// from its rivals, so a rewrite of the loop above cannot quietly fall back to
// the documented-but-wrong parity rule.
// ---------------------------------------------------------------------------
version (unittest) {
    import std.algorithm : sort;
    import std.conv      : to;
    import math          : Vec3;
    // The boundary-law discriminator (task 1061 §3): this file reaches
    // INTO by_stat.d for the mirror unittest only — an import direction
    // that does not exist outside version(unittest). Legal in D for class
    // references; no `static this()` is added to either module (a circular
    // import with module constructors throws `ModuleCtorError` at
    // startup).
    import commands.select.by_stat : SelectByStatEdge;

    // Run the command headlessly and return the selected edges as sorted
    // (min,max) vertex-index pairs — the engine-independent key. The Mesh is
    // heap-held by the caller so the `Mesh*` outlives this frame (same shape
    // as the other command unittests).
    private uint[2][] boundaryOf(Mesh* m, EditMode em = EditMode.Polygons) {
        View v = new View(0, 0, 1, 1);
        EditMode mode = em;
        auto c = new SelectBoundary(m, v, mode, &mode);
        c.apply();
        uint[2][] outp;
        foreach (ei; 0 .. m.edges.length) {
            if (!m.isEdgeSelected(ei)) continue;
            uint a = m.edges[ei][0], b = m.edges[ei][1];
            outp ~= a < b ? [a, b] : [b, a];
        }
        outp.sort();
        return outp;
    }

    // The MIRROR half of the discriminator (task 1061 §3.3): actually
    // constructs and runs `SelectByStatEdge`, in the shape of
    // `by_tag.d:186-201`'s `runByTag` — NOT a re-assertion of
    // `SelectBoundary`'s own behaviour, which is already covered four times
    // over above and would catch nothing about "route select.boundary
    // through the statistics command" (or vice versa).
    private uint[2][] byStatOpenBorderOf(Mesh* m) {
        View v = new View(0, 0, 1, 1);
        EditMode mode = EditMode.Edges;
        auto c = new SelectByStatEdge(m, v, mode, &mode);
        foreach (ref p; c.params()) {
            if (p.name == "test")    *p.sptr = "polygonCount";
            if (p.name == "compare") *p.sptr = "equal";
            if (p.name == "value")   *p.iptr = 1;
        }
        c.apply();
        uint[2][] outp;
        foreach (ei; 0 .. m.edges.length) {
            if (!m.isEdgeSelected(ei)) continue;
            uint a = m.edges[ei][0], b = m.edges[ei][1];
            outp ~= a < b ? [a, b] : [b, a];
        }
        outp.sort();
        return outp;
    }

    // A closed unit box minus its +Y face: the one shape that separates
    // "nothing selected → nothing" from "nothing selected → the holes".
    private Mesh* openBox() {
        auto m = new Mesh;
        m.vertices = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3( 0.5f, -0.5f, -0.5f),
            Vec3( 0.5f, -0.5f,  0.5f), Vec3(-0.5f, -0.5f,  0.5f),
            Vec3(-0.5f,  0.5f, -0.5f), Vec3( 0.5f,  0.5f, -0.5f),
            Vec3( 0.5f,  0.5f,  0.5f), Vec3(-0.5f,  0.5f,  0.5f),
        ];
        m.faces = [[0, 3, 2, 1], [0, 1, 5, 4], [1, 2, 6, 5],
                   [2, 3, 7, 6], [3, 0, 4, 7]];     // no top (4,5,6,7)
        m.rebuildEdges();
        m.syncSelection();      // grow the mark arrays before selecting
        return m;
    }
}

// One selected face on a closed cube → exactly its own four edges, and the
// face selection survives.
unittest {
    auto m = new Mesh;
    *m = makeCube();
    m.syncSelection();          // grow the mark arrays before selecting
    m.selectFace(5);
    auto ring = m.faces[5].dup;
    auto got  = boundaryOf(m);
    assert(got.length == 4,
        "one selected quad must produce its four border edges, got "
        ~ got.length.to!string);
    assert(m.isFaceSelected(5),
        "the polygon selection must survive select.boundary (measured)");
    // every returned edge must be one of the face's own ring edges
    foreach (e; got) {
        bool onRing = false;
        foreach (k; 0 .. ring.length) {
            uint a = ring[k], b = ring[(k + 1) % ring.length];
            if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a)) {
                onRing = true;
                break;
            }
        }
        assert(onRing, "returned an edge that is not on the selected face");
    }
}

// Nothing selected + a CLOSED mesh → nothing. The whole mesh becomes the
// active set, every edge is interior to it, and no edge survives. Mutation
// that trips it: dropping the `useAll` branch (then s == 0 everywhere, which
// also answers empty — so this case alone cannot pin the branch; the open-mesh
// case below is what does).
unittest {
    auto m = new Mesh;
    *m = makeCube();
    assert(boundaryOf(m).length == 0,
        "a closed mesh with no selection has no boundary");
}

// Nothing selected + an OPEN mesh → the hole. THIS is the case that pins the
// empty-selection branch: without `useAll` the answer would be empty.
unittest {
    auto m = openBox();
    const uint[4] hole = [4, 5, 6, 7];    // the missing +Y face's ring
    auto got = boundaryOf(m);
    assert(got.length == 4,
        "an open mesh with no selection must yield the hole's edges, got "
        ~ got.length.to!string);
    foreach (e; got) {
        bool onHole = false;
        foreach (k; 0 .. hole.length) {
            uint a = hole[k], b = hole[(k + 1) % hole.length];
            if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a))
                onHole = true;
        }
        assert(onHole, "an edge outside the hole leaked into the answer");
    }
}

// An open mesh WITH a selection: the selection wins, the hole does not come
// along. Measured — a hole-flavoured rule ("always include open edges") would
// return the top ring as well.
unittest {
    auto m = openBox();
    m.selectFace(0);                      // the bottom quad, far from the hole
    auto got = boundaryOf(m);
    assert(got.length == 4,
        "with a selection the answer is the selection's border only, got "
        ~ got.length.to!string);
    foreach (e; got)
        assert(e[0] < 4 && e[1] < 4,
            "an edge of the hole (verts 4..7) leaked in although a polygon "
            ~ "was selected");
}

// And the reverse-side case that separates this rule from "at least one
// selected AND at least one unselected": select the wall that BORDERS the
// hole. Its top edge has exactly one polygon — itself — so there is nothing
// unselected on the other side, yet the edge IS part of the answer.
unittest {
    auto m = openBox();
    m.selectFace(3);                      // the +Z wall: ring 2,3,7,6
    auto got = boundaryOf(m);
    bool topEdgeIn = false;
    foreach (e; got) if (e[0] == 6 && e[1] == 7) topEdgeIn = true;
    assert(topEdgeIn,
        "the selected wall's open top edge must be in the answer — a "
        ~ "'needs an unselected neighbour' rule would drop it");
    assert(got.length == 4, "and the wall contributes exactly its four edges");
}

// THE DISCRIMINATOR. A T-junction: three DISTINCT polygons on one edge.
//
//   * all three active  → interior → OUT.  (parity says odd → IN)
//   * two of three      → border   → IN.   (parity says even → OUT)
//
// Both directions are asserted, because a rule that got only one of them
// right would still be wrong — and "odd number of selected polygons" is
// exactly such a rule. This is the reference's own documented wording, so a
// future reader who re-reads that help and "fixes" the code to match will
// turn this test red, which is the point.
unittest {
    auto m = new Mesh;
    m.vertices = [
        Vec3(-0.5f, 0.0f, 0.0f),   // 0 ─┐ the shared edge is 0—1
        Vec3( 0.5f, 0.0f, 0.0f),   // 1 ─┘
        Vec3( 0.5f, 1.0f, 0.0f),   // 2   wing A (0,1,2,3) in +Y
        Vec3(-0.5f, 1.0f, 0.0f),   // 3
        Vec3( 0.5f, 0.0f, 1.0f),   // 4   wing B (0,1,4,5) in +Z
        Vec3(-0.5f, 0.0f, 1.0f),   // 5
        Vec3( 0.5f, 0.0f, -1.0f),  // 6   wing C (0,1,6,7) in −Z
        Vec3(-0.5f, 0.0f, -1.0f),  // 7
    ];
    m.faces = [[0, 1, 2, 3], [0, 1, 4, 5], [0, 1, 6, 7]];
    m.rebuildEdges();
    m.syncSelection();

    uint sharedEdge = uint.max;
    foreach (ei; 0 .. m.edges.length) {
        uint a = m.edges[ei][0], b = m.edges[ei][1];
        if ((a == 0 && b == 1) || (a == 1 && b == 0)) sharedEdge = cast(uint) ei;
    }
    assert(sharedEdge != uint.max, "fixture is malformed: no 0—1 edge");

    // all three wings active
    m.selectFace(0); m.selectFace(1); m.selectFace(2);
    auto all3 = boundaryOf(m);
    bool sharedIn = false;
    foreach (e; all3) if (e[0] == 0 && e[1] == 1) sharedIn = true;
    assert(!sharedIn,
        "three active polygons on one edge: the edge is INTERIOR and must be "
        ~ "excluded — 'odd number of selected polygons' would include it");

    // two of the three active
    m.clearFaceSelection();
    m.clearEdgeSelection();
    m.selectFace(0); m.selectFace(1);
    auto two = boundaryOf(m);
    sharedIn = false;
    foreach (e; two) if (e[0] == 0 && e[1] == 1) sharedIn = true;
    assert(sharedIn,
        "two active polygons and one inactive on one edge: the edge IS a "
        ~ "border — 'odd number of selected polygons' would exclude it");
}

// THE MIRROR DISCRIMINATOR (task 1061 §3). select.boundary answers relative
// to the ACTIVE polygon set; select.byStat.edge's open-border row
// (`test:polygonCount compare:equal value:1`) answers the whole mesh,
// selection-independent. With the +Z wall selected, select.boundary
// returns the WALL's own four edges (measured above, `:264-275`);
// select.byStat.edge returns the mesh's HOLE — byte-identical to what it
// answers with nothing selected. Two separate mesh instances (same STATE,
// not the same object) so running one command cannot contaminate the
// other's edge-selection read. Deleting either law, or routing one through
// the other in EITHER direction, must turn this red — and it can only do
// that because this half actually constructs and drives
// `SelectByStatEdge`, not merely `SelectBoundary` a second time.
unittest {
    auto mA = openBox();
    mA.selectFace(3);                     // the +Z wall: ring 2,3,7,6
    auto wallAnswer = boundaryOf(mA);

    auto mB = openBox();
    mB.selectFace(3);
    auto holeAnswer = byStatOpenBorderOf(mB);

    assert(wallAnswer.length == 4,
        "select.boundary must answer the selected wall's 4 edges");
    assert(holeAnswer.length == 4,
        "select.byStat.edge must answer the mesh's hole, 4 edges");
    assert(wallAnswer != holeAnswer,
        "the two laws must disagree with a polygon selected — identical "
        ~ "answers means the two laws were unified");

    bool topEdgeIn = false;
    foreach (e; wallAnswer) if (e[0] == 6 && e[1] == 7) topEdgeIn = true;
    assert(topEdgeIn,
        "select.boundary's wall answer must include the open top edge (6,7)");

    foreach (e; holeAnswer)
        assert(e[0] >= 4 && e[1] >= 4,
            "select.byStat.edge must answer ONLY the hole (verts 4..7), "
            ~ "selection-independent");
}
