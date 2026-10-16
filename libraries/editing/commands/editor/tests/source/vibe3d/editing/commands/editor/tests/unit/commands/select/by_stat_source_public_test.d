module vibe3d.editing.commands.editor.tests.unit.commands.select.by_stat_source_public_test;

import vibe3d.editing.commands.editor.commands.select.by_stat;

import vibe3d.editing.commands.runtime.command;
import vibe3d.mesh.core.mesh;
import vibe3d.viewport.camera.view;
import vibe3d.editing.contracts.editmode;
import vibe3d.editing.params.params   : Param;
import vibe3d.mesh.snapshot.snapshot : SelectionSnapshot;
import std.algorithm : canFind;
import std.conv       : to;

// ---------------------------------------------------------------------------
// Module unittests (task 1061 §6/Phase 1-3).
// ---------------------------------------------------------------------------
version (unittest) {
    import std.algorithm : sort;
    import vibe3d.util.math.math      : Vec3;
    import vibe3d.documents.model.document  : Document, Layer;
    import vibe3d.editing.contracts.seltype   : SelMode;
    // The boundary-law discriminator (§3): this module reaches INTO
    // boundary.d for the unittest only — a direction that does not exist
    // outside version(unittest). Legal in D for class references; no
    // `static this()` is added to either module (a circular import with
    // module constructors throws `ModuleCtorError` at startup).
    import vibe3d.editing.commands.editor.commands.select.boundary : SelectBoundary;

    private View freshView() { return new View(0, 0, 1, 1); }

    private uint[2][] selectedEdgePairs(Mesh* m) {
        uint[2][] outp;
        foreach (ei; 0 .. m.edges.length) {
            if (!m.isEdgeSelected(ei)) continue;
            uint a = m.edges[ei][0], b = m.edges[ei][1];
            outp ~= a < b ? [a, b] : [b, a];
        }
        outp.sort();
        return outp;
    }

    private size_t[] selectedVertexIdx(Mesh* m) {
        size_t[] outp;
        foreach (vi; 0 .. m.vertices.length) if (m.isVertexSelected(vi)) outp ~= vi;
        return outp;
    }

    private size_t[] selectedFaceIdx(Mesh* m) {
        size_t[] outp;
        foreach (fi; 0 .. m.faces.length) if (m.isFaceSelected(fi)) outp ~= fi;
        return outp;
    }

    private void setParam(Command c, string name, string val) {
        foreach (ref p; c.params()) if (p.name == name) *p.sptr = val;
    }
    private void setParamI(Command c, string name, int val) {
        foreach (ref p; c.params()) if (p.name == name) *p.iptr = val;
    }

    // Open unit box (the +Y face missing) — same shape `boundary.d`'s
    // `openBox()` uses, reproduced here so this module does not need a
    // non-unittest import of that private helper.
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
        m.syncSelection();
        return m;
    }
}

// 1. Non-manifold stacked-cube cell — the cell that kills the open-border
// row's rival "!= 2" reading, and cannot go through HTTP (mesh.cleanup
// would unifyFaces the coincident duplicate away). Reconstructed exactly
// from edge_by_polygon_count + edge_boundary_nonmanifold: lower unit cube
// (6 quads) + the upper cube's bottom quad (coincident with the lower
// cube's top) + the upper cube's -Z wall (y in [0.5,1.5]).
unittest {
    auto m = new Mesh;
    *m = makeCube();       // lower cube, 6 quads, verts 0..7
    m.vertices ~= [
        Vec3(-0.5f, 1.5f, -0.5f), Vec3(0.5f, 1.5f, -0.5f),   // 8, 9
        Vec3(0.5f, 1.5f, 0.5f),   Vec3(-0.5f, 1.5f, 0.5f),   // 10, 11
    ];
    // upper cube's bottom quad == lower cube's top quad (3,7,6,2), duplicated
    m.addFace([3, 7, 6, 2]);
    // upper cube's -Z wall: (3,2 at y=0.5) up to (8,9 at y=1.5)
    m.addFace([3, 2, 9, 8]);
    m.buildLoops();
    m.syncSelection();

    // Each call clears the prior edge selection first — mode:add (the
    // default) unions with whatever is already selected, and successive
    // calls in this test must not accumulate into each other.
    uint[2][] runEq(int val) {
        m.clearEdgeSelection();
        View v = freshView();
        auto c = new SelectByStatEdge(m, v, EditMode.Vertices, null);
        setParam(c, "test", "polygonCount");
        setParam(c, "compare", "equal");
        setParamI(c, "value", val);
        c.apply();
        return selectedEdgePairs(m);
    }
    uint[2][] runMore(int val) {
        m.clearEdgeSelection();
        View v = freshView();
        auto c = new SelectByStatEdge(m, v, EditMode.Vertices, null);
        setParam(c, "test", "polygonCount");
        setParam(c, "compare", "more");
        setParamI(c, "value", val);
        c.apply();
        return selectedEdgePairs(m);
    }

    auto eq1 = runEq(1);
    assert(eq1.length == 3, "the wall's 3 free edges have exactly 1 adjacent polygon, got "
        ~ eq1.length.to!string);

    auto eq3 = runEq(3);
    assert(eq3.length == 3, "the 3 top-ring edges (excluding the doubled edge) have "
        ~ "exactly 3 adjacent polygons, got " ~ eq3.length.to!string);

    auto more2 = runMore(2);
    assert(more2.length == 4, "more 2 (strict) must include the eq3 edges plus the "
        ~ "shared top edge (4 polygons) — a '!= 2' reading would answer differently, got "
        ~ more2.length.to!string);
}

// 2. The boundary-law discriminator (§3). BOTH directions asserted, and
// this module's half constructs+runs SelectBoundary, not merely its own
// command — a one-sided mirror (only re-testing SelectByStatEdge) would
// catch nothing about the "unify the two laws" mutation.
unittest {
    auto m = openBox();
    m.selectFace(3);   // the +Z wall: ring 2,3,7,6 (boundary.d's own fixture)

    View v1 = freshView();
    auto stat = new SelectByStatEdge(m, v1, EditMode.Edges, null);
    setParam(stat, "test", "polygonCount");
    setParam(stat, "compare", "equal");
    setParamI(stat, "value", 1);
    stat.apply();
    auto holeAnswer = selectedEdgePairs(m);

    // Re-select the wall (the stat command replaced the edge selection but
    // left the face selection alone) and run SelectBoundary on the SAME
    // mesh state.
    m.clearEdgeSelection();
    EditMode mode = EditMode.Polygons;
    View v2 = freshView();
    auto bnd = new SelectBoundary(m, v2, mode, &mode);
    bnd.apply();
    auto wallAnswer = selectedEdgePairs(m);

    assert(holeAnswer.length == 4, "the mesh's own hole has exactly 4 one-polygon edges");
    assert(wallAnswer.length == 4, "select.boundary on one selected wall returns its 4 edges");
    assert(holeAnswer != wallAnswer,
        "the two laws must disagree here — select.byStat.edge answers the mesh's hole "
        ~ "regardless of selection, select.boundary answers the SELECTED wall; "
        ~ "identical answers means the two laws were unified");
}

// 3. Tag borders: the tagged face's own open edge is excluded. A naive
// "differs from anything, or has <2 faces" rule would include it.
unittest {
    auto m = openBox();
    m.faceMaterial.length = m.faces.length;
    m.faceMaterial[2] = 1;   // face index 2 = [1,2,6,5], the +X wall

    View v = freshView();
    auto c = new SelectByStatEdge(m, v, EditMode.Vertices, null);
    setParam(c, "test", "materialBoundary");
    c.apply();
    auto got = selectedEdgePairs(m);
    assert(got.length == 3,
        "3 boundary edges, the tagged face's own open edge excluded, got "
        ~ got.length.to!string);
    // edge (5,6) is the +X wall's edge bordering the (missing +Y) hole —
    // only 1 adjacent polygon — and must NOT be selected. The wall's other
    // 3 edges (1,2)/(2,6)/(5,1) each border a differently-tagged neighbour
    // and must all be selected.
    bool openEdgeIn = false;
    foreach (e; got) if (e[0] == 5 && e[1] == 6) openEdgeIn = true;
    assert(!openEdgeIn, "the tagged face's own open edge leaked into the boundary");
}

// 4. Weight map: non-zero, not entry presence; clearing a subset partitions
// correctly.
unittest {
    auto m = new Mesh;
    *m = makeCube();
    m.syncSelection();
    auto wm = m.addWeightMap("W");
    assert(wm !is null);
    foreach (vi; 0 .. m.vertices.length) m.setVertexWeight("W", vi, 1.0f);
    // Clear the +X vertices only (1, 2, 5, 6 in makeCube()'s layout).
    foreach (vi; [1, 2, 5, 6]) m.setVertexWeight("W", vi, 0.0f);

    View v = freshView();
    auto c = new SelectByStatVertex(m, v, EditMode.Vertices, null);
    setParam(c, "test", "weightMap");
    setParam(c, "map", "W");
    c.apply();
    auto got = selectedVertexIdx(m);
    assert(got == [0UL, 3UL, 4UL, 7UL],
        "only the -X vertices (never cleared) must come back, got " ~ got.to!string);
}

// 4b. Weight map: a NEGATIVE value also selects. Every measured cell in the
// capture is 0.0, 0.5 or 1.0 — this arm is an unmeasured extrapolation from
// `!= 0.0f`, spelled out in the header note above. Mutation that reddens
// this: `!= 0.0f` narrowed to `> 0.0f` (verified — that swap left the whole
// test suite green with test 4 alone, which is exactly why this case exists).
unittest {
    auto m = new Mesh;
    *m = makeCube();
    m.syncSelection();
    auto wm = m.addWeightMap("W");
    assert(wm !is null);
    foreach (vi; 0 .. m.vertices.length) m.setVertexWeight("W", vi, 0.0f);
    m.setVertexWeight("W", 0, -1.0f);

    View v = freshView();
    auto c = new SelectByStatVertex(m, v, EditMode.Vertices, null);
    setParam(c, "test", "weightMap");
    setParam(c, "map", "W");
    c.apply();
    auto got = selectedVertexIdx(m);
    assert(got == [0UL],
        "a negative weight must select ('!= 0.0f', not '> 0.0f'), got " ~ got.to!string);
}

// 4c. Weight map: naming a map that does not exist is rejected, not
// silently treated as an all-zero map. Mutation that reddens this: deleting
// (or short-circuiting) the `weightMapNames().canFind` guard — apply() then
// runs to completion instead of throwing, so `collectExceptionMsg` below
// returns an empty string and the `canFind("NoSuchMap")` assert fails.
unittest {
    import std.exception : collectExceptionMsg;

    auto m = new Mesh;
    *m = makeCube();
    m.syncSelection();

    View v = freshView();
    auto c = new SelectByStatVertex(m, v, EditMode.Vertices, null);
    setParam(c, "test", "weightMap");
    setParam(c, "map", "NoSuchMap");
    auto msg = collectExceptionMsg(c.apply());
    assert(msg.canFind("NoSuchMap"), "must name the missing map: " ~ msg);
}

// 5. Polygon `less` is strictly-less — the anomaly is NOT reproduced.
// Mutation that reddens this: implementing `less` as `more` for polygons.
unittest {
    auto m = new Mesh;
    // 5 quads + 2 tris (any positions — vertexCount is winding-arity only).
    foreach (i; 0 .. 20)
        m.addVertex(Vec3(cast(float) i, 0, 0));
    m.addFace([0u, 1u, 2u]);            // tri
    m.addFace([3u, 4u, 5u]);            // tri
    m.addFace([6u, 7u, 8u, 9u]);        // quad
    m.addFace([10u, 11u, 12u, 13u]);    // quad
    m.addFace([14u, 15u, 16u, 17u]);    // quad
    m.buildLoops();
    m.syncSelection();

    View v = freshView();
    auto c = new SelectByStatPolygon(m, v, EditMode.Polygons, null);
    setParam(c, "test", "vertexCount");
    setParam(c, "compare", "less");
    setParamI(c, "value", 4);
    c.apply();
    auto got = selectedFaceIdx(m);
    assert(got == [0UL, 1UL],
        "'less 4' (strict) must return only the 2 triangles — the reference's "
        ~ "anomaly (less behaving as more) would return NOTHING instead on this "
        ~ "stand (max arity here is 4, so 'more 4' strictly selects no polygon "
        ~ "at all, not the quads), got " ~ got.to!string);
}

// 6. Argument hygiene: each rejection throws and names the offending
// argument.
unittest {
    import std.exception : collectExceptionMsg;

    auto m = new Mesh;
    *m = makeCube();
    m.syncSelection();

    // compare != all requires value >= 0.
    {
        View v = freshView();
        auto c = new SelectByStatVertex(m, v, EditMode.Vertices, null);
        setParam(c, "test", "edgeCount");
        setParam(c, "compare", "equal");
        // value left at its default sentinel -1.
        auto msg = collectExceptionMsg(c.apply());
        assert(msg.canFind("value"), "must name 'value': " ~ msg);
    }
    // compare == all ignores value — the mirror direction of the check
    // above. Proven by probe before this fix existed: `select.byStat.polygon
    // compare:all value:7` raised nothing and returned all six faces.
    {
        View v = freshView();
        auto c = new SelectByStatPolygon(m, v, EditMode.Polygons, null);
        setParam(c, "test", "vertexCount");
        setParam(c, "compare", "all");
        setParamI(c, "value", 7);
        auto msg = collectExceptionMsg(c.apply());
        assert(msg.canFind("value"), "must name 'value': " ~ msg);
    }
    // test:weightMap requires map set.
    {
        View v = freshView();
        auto c = new SelectByStatVertex(m, v, EditMode.Vertices, null);
        setParam(c, "test", "weightMap");
        auto msg = collectExceptionMsg(c.apply());
        assert(msg.canFind("map"), "must name 'map': " ~ msg);
    }
    // every other test requires map == "".
    {
        View v = freshView();
        auto c = new SelectByStatVertex(m, v, EditMode.Vertices, null);
        setParam(c, "test", "edgeCount");
        setParam(c, "map", "W");
        auto msg = collectExceptionMsg(c.apply());
        assert(msg.canFind("map"), "must name 'map': " ~ msg);
    }
    // materialBoundary rejects a non-default compare/value.
    {
        View v = freshView();
        auto c = new SelectByStatEdge(m, v, EditMode.Edges, null);
        setParam(c, "test", "materialBoundary");
        setParam(c, "compare", "equal");
        setParamI(c, "value", 2);
        auto msg = collectExceptionMsg(c.apply());
        assert(msg.canFind("compare"), "must name 'compare': " ~ msg);
    }
    // unparsable test / compare / mode throw, quoting the value.
    {
        View v = freshView();
        auto c = new SelectByStatPolygon(m, v, EditMode.Polygons, null);
        setParam(c, "compare", "bogus");
        auto msg = collectExceptionMsg(c.apply());
        assert(msg.canFind("bogus"), "must quote the bad value: " ~ msg);
    }
}

// 7. mode:remove subtracts, and compare:all takes everything (union +
// difference both directions, the anti-inert core of §6).
unittest {
    auto m = new Mesh;
    *m = makeCube();
    m.syncSelection();

    View v1 = freshView();
    auto add = new SelectByStatPolygon(m, v1, EditMode.Polygons, null);
    setParam(add, "test", "vertexCount");
    setParam(add, "compare", "all");
    add.apply();
    assert(selectedFaceIdx(m).length == 6, "compare:all must select every polygon");

    View v2 = freshView();
    auto rm = new SelectByStatPolygon(m, v2, EditMode.Polygons, null);
    setParam(rm, "test", "vertexCount");
    setParam(rm, "compare", "all");
    setParam(rm, "mode", "remove");
    rm.apply();
    assert(selectedFaceIdx(m).length == 0,
        "mode:remove with compare:all must subtract everything");
}

// 8. Undo restores the exact prior selection AND the prior EditMode.
unittest {
    auto m = new Mesh;
    *m = makeCube();
    m.syncSelection();
    m.selectFace(1);

    EditMode mode = EditMode.Polygons;
    View v = freshView();
    auto c = new SelectByStatEdge(m, v, mode, &mode);
    setParam(c, "test", "polygonCount");
    setParam(c, "compare", "all");
    c.apply();
    assert(mode == EditMode.Edges, "setup: the command promotes to Edges");
    assert(c.revert(), "revert must report success");
    assert(mode == EditMode.Polygons, "undo must restore the prior EditMode");
    assert(selectedFaceIdx(m) == [1UL], "undo must restore the prior face selection");
    assert(selectedEdgePairs(m).length == 0, "undo must clear the edge selection it made");
}

// 9. Multi-layer scope (§4.1): two foreground layers, both with real
// geometry and a real edge selection; the command must empty the
// PRIMARY's selection and leave the second layer's untouched. Pins the
// `divergence-deliberate` row that nothing pinned before task 1061.
unittest {
    Mesh a = makeCube();
    auto doc = Document.bootstrap(a);          // layer "Layer 1" == A, primary
    auto b = new Layer;
    b.name = "B";
    b.meshRef() = makeCube();
    doc.layers ~= b;

    // Select every edge on BOTH meshes (through their own selection state —
    // Document does not itself carry selection, each Mesh does).
    auto aMesh = doc.primary.meshOrNull();
    aMesh.syncSelection();
    foreach (ei; 0 .. aMesh.edges.length) aMesh.selectEdge(cast(int) ei);
    auto bMesh = b.meshOrNull();
    bMesh.syncSelection();
    foreach (ei; 0 .. bMesh.edges.length) bMesh.selectEdge(cast(int) ei);

    doc.selectItem(b, SelMode.Add);            // both layers foreground; A stays primary
    assert(doc.primary is doc.layers[0], "setup: A is still primary");
    // The two premises this test's own comparison silently relies on: if B
    // were NOT foreground, or had no edges, "B's selection count == B's edge
    // count" would read 0 == 0 and the scope assertion below would pass for
    // the wrong reason — proving nothing about scope at all.
    assert(doc.foreground(b), "setup: B must be foreground for this to test scope");
    assert(bMesh.edges.length > 0, "setup: B must have real geometry for this to test scope");

    // Construct against the PRIMARY's mesh only — never a non-primary layer.
    View v = freshView();
    auto c = new SelectByStatEdge(doc.primary.meshOrNull(), v, EditMode.Edges, null);
    setParam(c, "test", "polygonCount");
    setParam(c, "compare", "all");
    setParam(c, "mode", "remove");
    c.apply();

    assert(selectedEdgePairs(aMesh).length == 0,
        "the anti-inert half: A's edge selection must be emptied");
    size_t bSelected = 0;
    foreach (ei; 0 .. bMesh.edges.length) if (bMesh.isEdgeSelected(ei)) ++bSelected;
    assert(bSelected == bMesh.edges.length,
        "the scope half: B's edge selection must be UNTOUCHED — a command widened to "
        ~ "every foreground layer would empty it too");
}
