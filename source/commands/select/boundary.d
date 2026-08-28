module commands.select.boundary;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

// ---------------------------------------------------------------------------
// select.boundary — face selection → edge selection.
//
// The border of the selected polygon set: with polygons selected it produces
// the ring of edges around that set (a discontinuous selection gives several
// rings); with NOTHING selected the whole mesh is the set, so what is left is
// the mesh's own open boundary — the holes.
//
// ---------------------------------------------------------------------------
// The law, and why it is not the one the reference DOCUMENTS
// ---------------------------------------------------------------------------
// Let `A` be the active polygon set — the selected polygons, or ALL polygons
// when none is selected. For each edge, let `s` be how many polygons OF `A`
// use it and `u` how many polygons NOT in `A` use it:
//
//     edge is on the boundary  ⟺  s == 1  ||  (s >= 1 && u >= 1)
//
// Read the other way round: an edge with at least one active polygon is a
// border UNLESS it is interior to the set — used by two or more active
// polygons and by no inactive one. A lone active polygon on an edge is
// always a border, because there is nothing on the other side.
//
// The reference's own help states the mechanism as *"select all edges
// bordered by an odd number of selected polygons"*. On a manifold mesh (every
// edge used by 1 or 2 polygons) that is the SAME predicate. It parts company
// only where an edge carries three or more polygons, and there the measured
// behaviour follows the rule above, not the documented parity:
//
//   * three polygons on one edge, ALL selected — parity says odd → select;
//     measured: NOT selected (it is interior to the set).
//   * three polygons on one edge, two selected — parity says even → skip;
//     measured: SELECTED (the third polygon is on the other side).
//
// Both were measured on a T-junction built in the reference engine (a box
// stacked on a box, welded, then stripped to a single wall) and on a
// coincident-duplicate polygon. The scoreboard over every captured case:
// this rule 38/38, "odd number of selected" 26/38, "exactly one selected"
// 32/38, "at least one selected and one unselected" 28/38. Capture and
// scoring belong to task 1050; the frozen cases are
// `tests/fixtures/select_boundary.json`.
//
// ---------------------------------------------------------------------------
// NOT the same law as select.byStat.edge's open-border row (task 1061)
// ---------------------------------------------------------------------------
// `commands/select/by_stat.d`'s `EdgeStat.polygonCount compare:equal
// value:1` answers a different question: exactly one adjacent polygon,
// over the WHOLE MESH, selection-independent. THIS command answers relative
// to the ACTIVE polygon set (selected, or all when none is selected). They
// coincide only when nothing is selected — measured
// (`edge_boundary_tagged_open_cube.identical_with_a_polygon_selected`):
// with one polygon selected the reference's boundary answer is
// byte-identical to the no-selection case, where THIS command would answer
// that polygon's own four edges. `label()` below states the scope at the
// UI surface; the cross-asserting discriminator unittest near the bottom
// of this file constructs and runs `SelectByStatEdge` on the same mesh
// state and asserts the two answers differ.
//
// Two more measured facts this command reproduces:
//   * the POLYGON selection survives — this is not a converter that consumes
//     its input (unlike `select.convert`, which clears the source).
//   * the component mode ends on Edges. Measured indirectly: a `select.invert`
//     issued afterwards inverted the EDGE selection (4 → 8 on a cube), not the
//     polygon one, so the mode had moved.
//
// A VERTEX selection does not feed it. Measured on an open mesh in vertex mode
// with vertices selected and no polygon selected: the answer was the mesh's
// hole, i.e. the empty-polygon-selection branch, not anything keyed on the
// selected vertices.
//
// Undo: SelectionSnapshot, like the rest of the select.* growth family, plus
// the EditMode switch (which the snapshot does not carry), routed back through
// the same promote hook — the shape `select.fill.insideLoop` established.
// ---------------------------------------------------------------------------
class SelectBoundary : Command {
    private SelectionSnapshot       snap;
    private EditMode                priorEditMode;
    private bool                    modeSwitched;
    private EditMode*               editModePtr;
    private void delegate(EditMode) promoteType;

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr) {
        super(mesh, view, editMode);
        this.editModePtr = editModePtr;
    }

    override string name() const { return "select.boundary"; }

    // States the scope that distinguishes this command from
    // select.byStat.edge's open-border row (task 1061) — this one is
    // relative to the ACTIVE polygon set, not the whole mesh.
    override string label() const { return "Select Border Of Polygon Set"; }

    /// Lockstep hook with the app's geometry-type funnel. Optional: a
    /// headless/unit-test construction without one writes `*editModePtr`.
    SelectBoundary setPromoteHook(void delegate(EditMode) h) {
        promoteType = h;
        return this;
    }

    protected override void revertImpl() {
        snap.restore(*mesh);
        if (modeSwitched && editModePtr !is null) {
            if (promoteType !is null) promoteType(priorEditMode);
            else                      *editModePtr = priorEditMode;
        }
    }

    protected override bool applyImpl() {
        snap          = SelectionSnapshot.capture(*mesh);
        noteUndoRecorded();   // task 2500 — the flag and the image, one statement apart
        priorEditMode = editModePtr !is null ? *editModePtr : editMode;
        mesh.syncSelection();

        const size_t nf = mesh.faces.length;
        const size_t ne = mesh.edges.length;
        if (ne == 0) return true;

        // The active set. `hasAnySelectedFaces` is the same "is there a
        // polygon selection at all" question the reference branches on.
        const bool useAll = !mesh.hasAnySelectedFaces();

        // Per-edge active/inactive incidence, counted straight off `faces[]`
        // through the canonical (min,max) key — the same honest count
        // `Mesh.edgePolygonCounts` makes, and for the same reason: a ring walk
        // (`facesAroundEdge`) cannot witness a third polygon on an edge, and
        // this rule is decided precisely by that third polygon.
        uint[ulong] idx;
        foreach (i; 0 .. ne)
            idx[edgeKey(mesh.edges[i][0], mesh.edges[i][1])] = cast(uint) i;

        auto act   = new int[](ne);
        auto inact = new int[](ne);
        foreach (fi; 0 .. nf) {
            const uint[] f = mesh.faces[fi];
            if (f.length == 0) continue;
            const bool inSet = useAll || mesh.isFaceSelected(fi);
            foreach (k; 0 .. f.length) {
                auto p = edgeKey(f[k], f[(k + 1) % f.length]) in idx;
                if (p is null) continue;   // face edge with no edges[] entry
                if (inSet) ++act[*p];
                else       ++inact[*p];
            }
        }

        auto want = new bool[](ne);
        foreach (ei; 0 .. ne)
            want[ei] = act[ei] == 1 || (act[ei] >= 1 && inact[ei] >= 1);

        // selectEdgesFrom, not setEdgesSelectedFrom: these edges are selected
        // on the user's behalf and must carry a selection-history value, or
        // they sort behind anything clicked afterwards (see the primitive's
        // doc comment in mesh.d). Same choice as select.fill.*.
        mesh.selectEdgesFrom(want);

        if (editModePtr !is null && *editModePtr != EditMode.Edges) {
            modeSwitched = true;
            if (promoteType !is null) promoteType(EditMode.Edges);
            else                      *editModePtr = EditMode.Edges;
        }
        return true;
    }
}

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
