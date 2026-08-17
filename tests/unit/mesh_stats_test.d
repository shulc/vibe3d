// The Statistics query kernel — `source/mesh_stats.d` (task 1100 Stage 1).
//
// Five things are checked here, and the fifth is checked by the COMPILER:
//
//   1. NUMBERS — the histogram of every fixed-count row on two fixtures whose
//      answers task 1061 already measured, plus the section total's identity
//      with the sum of a partition category's rows (frame A: 1+0+4+919+6952+489
//      = 8365 = the Vertices section's own Num — the same arithmetic, on a
//      fixture small enough to write out).
//   2. EQUIVALENCE, TOTAL — for EVERY `(test, compare, value)` tuple the tree
//      emits: the count driver's `num` equals the mask driver's popcount, AND
//      the shipped command's resulting selection equals that mask composed with
//      its mode. Not a sample: the tuple table below is the whole tree, and
//      `stat_rows_test.d` sweeps the emitted tree against the same predicate so
//      a row family added there without a tuple here is caught.
//   3. THE `Sel` GATE — `wantSel == false` leaves `selKnown` false and reads no
//      marks at all (the fixture has a real selection, so a driver that read
//      the marks and then discarded `selKnown` would still report `sel > 0`).
//   4. THE UNSYNCED-MARKS PROPERTY — a const kernel cannot call
//      `syncSelection()`, so on a mesh grown without one `sel` is low by exactly
//      the unsynced tail. That is a recorded property of the const design, not a
//      bug to be found in six months.
//   5. NO MUTATION, AT COMPILE TIME — `static assert(!__traits(compiles, …))`
//      over a `Command` construction against the kernel's own `const(Mesh)*`.
//      `Command`'s constructor takes a mutable `Mesh*`, so "count by applying
//      the command and looking at the selection" cannot be WRITTEN here. The
//      mutation is to delete the `const` — a one-line diff a reviewer sees.

import mesh;
import mesh_stats;
import math : Vec3;
import view : View;
import editmode : EditMode;
import command : Command;
import commands.select.by_stat : SelectByStatVertex, SelectByStatEdge,
                                 SelectByStatPolygon;
import std.algorithm : count, canFind;
import std.conv : to;

// ---------------------------------------------------------------------------
// Fixtures. `openBox` and the stacked non-manifold cell are the two task-1061
// stands whose answers were measured against the reference; they are rebuilt
// here rather than imported because `by_stat.d`'s copies are private to its own
// `version (unittest)` block.
// ---------------------------------------------------------------------------
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

/// Lower unit cube + the upper cube's bottom quad (coincident with the lower
/// cube's top) + the upper cube's -Z wall. The cell that carries a 3- and a
/// 4-polygon edge.
private Mesh* stackedCube() {
    auto m = new Mesh;
    *m = makeCube();
    m.vertices ~= [
        Vec3(-0.5f, 1.5f, -0.5f), Vec3(0.5f, 1.5f, -0.5f),
        Vec3(0.5f, 1.5f, 0.5f),   Vec3(-0.5f, 1.5f, 0.5f),
    ];
    m.addFace([3, 7, 6, 2]);
    m.addFace([3, 2, 9, 8]);
    m.buildLoops();
    m.syncSelection();
    return m;
}

private Mesh* freshCube() {
    auto m = new Mesh;
    *m = makeCube();
    m.syncSelection();
    return m;
}

private View freshView() { return new View(0, 0, 1, 1); }

private void setParam(Command c, string name, string val) {
    foreach (ref p; c.params()) if (p.name == name) *p.sptr = val;
}
private void setParamI(Command c, string name, int val) {
    foreach (ref p; c.params()) if (p.name == name) *p.iptr = val;
}

// ---------------------------------------------------------------------------
// 1. NUMBERS — the histogram of every fixed-count row, and the section total.
// ---------------------------------------------------------------------------
unittest {
    auto m = openBox();
    auto ctx = buildStatContext(*m);

    // Vertices → By Edge. Every vertex of the open box carries exactly three
    // edges (two ring edges + one vertical), so five of the six rows are ZERO
    // rows — which are rows the panel must still show.
    long byEdge(Compare c, int v) {
        return vertexStatCount(ctx, VertexStat.edgeCount, c, v, "", false).num;
    }
    assert(byEdge(Compare.equal, 0) == 0);
    assert(byEdge(Compare.equal, 1) == 0);
    assert(byEdge(Compare.equal, 2) == 0);
    assert(byEdge(Compare.equal, 3) == 8, "every vertex has 3 edges, got "
        ~ byEdge(Compare.equal, 3).to!string);
    assert(byEdge(Compare.equal, 4) == 0);
    assert(byEdge(Compare.more,  4) == 0);

    // Vertices → By Polygon: the four bottom vertices touch bottom + 2 walls,
    // the four top ones touch 2 walls each (the top face is missing).
    long byPoly(Compare c, int v) {
        return vertexStatCount(ctx, VertexStat.polygonCount, c, v, "", false).num;
    }
    assert(byPoly(Compare.equal, 2) == 4, "the 4 top vertices touch 2 polygons");
    assert(byPoly(Compare.equal, 3) == 4, "the 4 bottom vertices touch 3");

    // Edges → By Polygon: the hole's 4 edges have one adjacent polygon, the
    // other 8 have two.
    long edgePoly(Compare c, int v) {
        return edgeStatCount(ctx, EdgeStat.polygonCount, c, v, false).num;
    }
    assert(edgePoly(Compare.equal, 1) == 4, "the hole's 4 open edges");
    assert(edgePoly(Compare.equal, 2) == 8);
    assert(edgePoly(Compare.more,  4) == 0);

    // Polygons → By Vertex: five quads.
    assert(polygonStatCount(ctx, PolygonStat.vertexCount, Compare.equal, 4, false).num == 5);

    // THE SECTION TOTAL IS THE SUM OF A PARTITION CATEGORY (§4/L8, frame A).
    // The section row's Num is the element count; a By-Edge/By-Polygon/By-Vertex
    // category partitions the same set, so the two must agree — and they do
    // because both come out of this kernel.
    long vertSum = 0;
    foreach (v; 0 .. 5) vertSum += byEdge(Compare.equal, v);
    vertSum += byEdge(Compare.more, 4);
    assert(vertSum == cast(long) m.vertices.length,
        "By Edge must partition the vertices: " ~ vertSum.to!string ~ " vs "
        ~ m.vertices.length.to!string);

    long edgeSum = 0;
    foreach (v; 1 .. 5) edgeSum += edgePoly(Compare.equal, v);
    edgeSum += edgePoly(Compare.more, 4);
    // Edges → By Polygon starts at 1, so an edge with ZERO adjacent polygons
    // (a bare wire edge) is in no row. The open box has none, which is what
    // makes this an equality here and a documented inequality in general.
    assert(edgeStatCount(ctx, EdgeStat.polygonCount, Compare.equal, 0, false).num == 0,
        "setup: this fixture has no bare wire edges");
    assert(edgeSum == cast(long) m.edges.length,
        "By Polygon must partition the edges: " ~ edgeSum.to!string);

    // The stacked non-manifold cell: the answers task 1061 measured.
    auto s = stackedCube();
    auto sctx = buildStatContext(*s);
    assert(edgeStatCount(sctx, EdgeStat.polygonCount, Compare.equal, 1, false).num == 3,
        "the wall's 3 free edges");
    assert(edgeStatCount(sctx, EdgeStat.polygonCount, Compare.equal, 3, false).num == 3,
        "the 3 top-ring edges");
    assert(edgeStatCount(sctx, EdgeStat.polygonCount, Compare.more, 2, false).num == 4,
        "more 2 (strict) adds the shared 4-polygon top edge");
}

// ---------------------------------------------------------------------------
// 2. EQUIVALENCE, TOTAL — every tuple the tree emits, both directions.
// ---------------------------------------------------------------------------

/// Every `(test, compare, value)` the Statistics tree emits for this component.
/// Kept as a table so the sweep below is TOTAL rather than sampled; the tree
/// that emits them is `source/ui/stat_rows.d`, and its own test sweeps the
/// emitted leaves against this same kernel so neither list can drift alone.
private struct VTuple { VertexStat t; Compare c; int v; string map; }
private struct ETuple { EdgeStat t;   Compare c; int v; }
private struct PTuple { PolygonStat t; Compare c; int v; }

private immutable VTuple[] kVertexTuples = [
    // section row — `compare:all`, no `value` key (risk 6)
    VTuple(VertexStat.edgeCount,    Compare.all,   -1, ""),
    // By Edge 0,1,2,3,4,>4
    VTuple(VertexStat.edgeCount,    Compare.equal,  0, ""),
    VTuple(VertexStat.edgeCount,    Compare.equal,  1, ""),
    VTuple(VertexStat.edgeCount,    Compare.equal,  2, ""),
    VTuple(VertexStat.edgeCount,    Compare.equal,  3, ""),
    VTuple(VertexStat.edgeCount,    Compare.equal,  4, ""),
    VTuple(VertexStat.edgeCount,    Compare.more,   4, ""),
    // By Polygon 0,1,2,3,4,>4
    VTuple(VertexStat.polygonCount, Compare.equal,  0, ""),
    VTuple(VertexStat.polygonCount, Compare.equal,  1, ""),
    VTuple(VertexStat.polygonCount, Compare.equal,  2, ""),
    VTuple(VertexStat.polygonCount, Compare.equal,  3, ""),
    VTuple(VertexStat.polygonCount, Compare.equal,  4, ""),
    VTuple(VertexStat.polygonCount, Compare.more,   4, ""),
    // By Vertex Map, one row per weight map
    VTuple(VertexStat.weightMap,    Compare.all,   -1, "W"),
];

private immutable ETuple[] kEdgeTuples = [
    ETuple(EdgeStat.polygonCount,     Compare.all,   -1),   // section row
    ETuple(EdgeStat.polygonCount,     Compare.equal,  1),   // By Polygon 1 == By Boundary Geometry
    ETuple(EdgeStat.polygonCount,     Compare.equal,  2),
    ETuple(EdgeStat.polygonCount,     Compare.equal,  3),
    ETuple(EdgeStat.polygonCount,     Compare.equal,  4),
    ETuple(EdgeStat.polygonCount,     Compare.more,   4),
    ETuple(EdgeStat.materialBoundary, Compare.all,   -1),
    ETuple(EdgeStat.partBoundary,     Compare.all,   -1),
];

private immutable PTuple[] kPolygonTuples = [
    PTuple(PolygonStat.vertexCount, Compare.all,   -1),     // section row
    PTuple(PolygonStat.vertexCount, Compare.equal,  1),
    PTuple(PolygonStat.vertexCount, Compare.equal,  2),
    PTuple(PolygonStat.vertexCount, Compare.equal,  3),
    PTuple(PolygonStat.vertexCount, Compare.equal,  4),
    PTuple(PolygonStat.vertexCount, Compare.more,   4),
];

private string compareToken(Compare c) {
    final switch (c) {
        case Compare.all:   return "all";
        case Compare.equal: return "equal";
        case Compare.less:  return "less";
        case Compare.more:  return "more";
    }
}

unittest {
    // A stand with a weight map, two materials and two parts, so every tuple
    // above has something to answer over.
    Mesh* stand() {
        auto m = stackedCube();
        m.addWeightMap("W");
        foreach (vi; 0 .. m.vertices.length) m.setVertexWeight("W", vi, vi % 2 == 0 ? 1.0f : 0.0f);
        m.faceMaterial.length = m.faces.length;
        m.facePart.length     = m.faces.length;
        m.faceMaterial[0] = 1;
        m.faceMaterial[3] = 2;
        m.facePart[1]     = 7;
        return m;
    }

    // ---- vertices ----
    foreach (tu; kVertexTuples) {
        auto m   = stand();
        auto ctx = buildStatContext(*m);
        auto mask  = vertexStatMask(ctx, tu.t, tu.c, tu.v, tu.map);
        auto cnt   = vertexStatCount(ctx, tu.t, tu.c, tu.v, tu.map, false);
        assert(cnt.num == cast(long) mask.count!(x => x),
            "count/mask disagree for vertex tuple " ~ tu.to!string);

        // ... and the COMMAND's answer is that mask composed with its mode.
        foreach (mode; ["add", "remove"]) {
            auto mm = stand();
            mm.selectVertex(0);              // a prior selection both modes must respect
            mm.selectVertex(1);
            auto mctx = buildStatContext(*mm);
            auto want = vertexStatMask(mctx, tu.t, tu.c, tu.v, tu.map).dup;
            foreach (vi; 0 .. want.length)
                want[vi] = (mode == "add") ? (want[vi] || mm.isVertexSelected(vi))
                                           : (!want[vi] && mm.isVertexSelected(vi));
            View v = freshView();
            auto c = new SelectByStatVertex(mm, v, EditMode.Vertices, null);
            setParam(c, "test", tu.t.to!string);
            setParam(c, "compare", compareToken(tu.c));
            if (tu.c != Compare.all) setParamI(c, "value", tu.v);
            if (tu.map.length) setParam(c, "map", tu.map);
            setParam(c, "mode", mode);
            assert(c.apply(), "the command must run for " ~ tu.to!string);
            foreach (vi; 0 .. want.length)
                assert(mm.isVertexSelected(vi) == want[vi],
                    "command vs mask+" ~ mode ~ " disagree at vertex "
                    ~ vi.to!string ~ " for " ~ tu.to!string);
        }
    }

    // ---- edges ----
    foreach (tu; kEdgeTuples) {
        auto m   = stand();
        auto ctx = buildStatContext(*m);
        auto mask = edgeStatMask(ctx, tu.t, tu.c, tu.v);
        auto cnt  = edgeStatCount(ctx, tu.t, tu.c, tu.v, false);
        assert(cnt.num == cast(long) mask.count!(x => x),
            "count/mask disagree for edge tuple " ~ tu.to!string);

        foreach (mode; ["add", "remove"]) {
            auto mm = stand();
            mm.selectEdge(0);
            mm.selectEdge(1);
            auto mctx = buildStatContext(*mm);
            auto want = edgeStatMask(mctx, tu.t, tu.c, tu.v).dup;
            foreach (ei; 0 .. want.length)
                want[ei] = (mode == "add") ? (want[ei] || mm.isEdgeSelected(ei))
                                           : (!want[ei] && mm.isEdgeSelected(ei));
            View v = freshView();
            auto c = new SelectByStatEdge(mm, v, EditMode.Edges, null);
            setParam(c, "test", tu.t.to!string);
            setParam(c, "compare", compareToken(tu.c));
            if (tu.c != Compare.all) setParamI(c, "value", tu.v);
            setParam(c, "mode", mode);
            assert(c.apply(), "the command must run for " ~ tu.to!string);
            foreach (ei; 0 .. want.length)
                assert(mm.isEdgeSelected(ei) == want[ei],
                    "command vs mask+" ~ mode ~ " disagree at edge "
                    ~ ei.to!string ~ " for " ~ tu.to!string);
        }
    }

    // ---- polygons ----
    foreach (tu; kPolygonTuples) {
        auto m   = stand();
        auto ctx = buildStatContext(*m);
        auto mask = polygonStatMask(ctx, tu.t, tu.c, tu.v);
        auto cnt  = polygonStatCount(ctx, tu.t, tu.c, tu.v, false);
        assert(cnt.num == cast(long) mask.count!(x => x),
            "count/mask disagree for polygon tuple " ~ tu.to!string);

        foreach (mode; ["add", "remove"]) {
            auto mm = stand();
            mm.selectFace(0);
            auto mctx = buildStatContext(*mm);
            auto want = polygonStatMask(mctx, tu.t, tu.c, tu.v).dup;
            foreach (fi; 0 .. want.length)
                want[fi] = (mode == "add") ? (want[fi] || mm.isFaceSelected(fi))
                                           : (!want[fi] && mm.isFaceSelected(fi));
            View v = freshView();
            auto c = new SelectByStatPolygon(mm, v, EditMode.Polygons, null);
            setParam(c, "test", tu.t.to!string);
            setParam(c, "compare", compareToken(tu.c));
            if (tu.c != Compare.all) setParamI(c, "value", tu.v);
            setParam(c, "mode", mode);
            assert(c.apply(), "the command must run for " ~ tu.to!string);
            foreach (fi; 0 .. want.length)
                assert(mm.isFaceSelected(fi) == want[fi],
                    "command vs mask+" ~ mode ~ " disagree at face "
                    ~ fi.to!string ~ " for " ~ tu.to!string);
        }
    }
}

// ---------------------------------------------------------------------------
// 3. THE `Sel` GATE — `wantSel == false` reads no marks.
// ---------------------------------------------------------------------------
unittest {
    auto m = freshCube();
    foreach (vi; 0 .. m.vertices.length) m.selectVertex(cast(int) vi);
    foreach (fi; 0 .. m.faces.length)    m.selectFace(cast(int) fi);
    auto ctx = buildStatContext(*m);

    // Gate SHUT. The fixture is fully selected, so a driver that read the marks
    // and merely dropped `selKnown` would still report a non-zero `sel` here —
    // which is what makes this an assertion about READING and not about
    // reporting.
    auto shut = vertexStatCount(ctx, VertexStat.edgeCount, Compare.all, -1, "", false);
    assert(shut.num == 8, "num is computed regardless of the gate");
    assert(!shut.selKnown, "a shut gate must leave selKnown false");
    assert(shut.sel == 0, "a shut gate must not read the marks at all");

    auto shutF = polygonStatCount(ctx, PolygonStat.vertexCount, Compare.all, -1, false);
    assert(!shutF.selKnown && shutF.sel == 0);

    // Gate OPEN.
    auto open = vertexStatCount(ctx, VertexStat.edgeCount, Compare.all, -1, "", true);
    assert(open.selKnown, "an open gate reports selKnown");
    assert(open.sel == 8, "…and the real number, got " ~ open.sel.to!string);

    // A partial selection, so `sel < num` is a state the row model can render.
    auto m2 = freshCube();
    m2.selectFace(0);
    m2.selectFace(2);
    auto ctx2 = buildStatContext(*m2);
    auto part = polygonStatCount(ctx2, PolygonStat.vertexCount, Compare.equal, 4, true);
    assert(part.num == 6 && part.sel == 2 && part.selKnown,
        "2 of 6 faces selected: " ~ part.to!string);
}

// ---------------------------------------------------------------------------
// 4. THE UNSYNCED-MARKS PROPERTY (§1.6).
//
// A `const(Mesh)*` kernel cannot call `syncSelection()` — that is a mutation
// which resizes ten arrays. So on a mesh whose geometry grew without one, the
// marks arrays are legitimately SHORTER than the geometry and every reader
// returns false past their end. `num` is unaffected (it reads geometry); `sel`
// is low by exactly the unsynced tail. Recorded here as a property, with the
// repair asserted immediately after it.
// ---------------------------------------------------------------------------
unittest {
    auto m = freshCube();
    foreach (fi; 0 .. m.faces.length) m.selectFace(cast(int) fi);
    assert(m.faceMarks.length == m.faces.length, "setup: synced to begin with");

    // Grow the geometry WITHOUT syncing: a second cube's worth of faces.
    const size_t base = m.vertices.length;
    foreach (i; 0 .. 4) m.addVertex(Vec3(2.0f + i, 0, 0));
    m.addFace([cast(uint)(base + 0), cast(uint)(base + 1),
               cast(uint)(base + 2), cast(uint)(base + 3)]);
    assert(m.faceMarks.length < m.faces.length,
        "setup: the marks array is now short of the geometry");

    auto ctx = buildStatContext(*m);
    auto before = polygonStatCount(ctx, PolygonStat.vertexCount, Compare.equal, 4, true);
    assert(before.num == cast(long) m.faces.length,
        "num counts GEOMETRY and is unaffected by unsynced marks");
    assert(before.sel == 6,
        "sel is low by exactly the unsynced tail (the new face reads unselected), got "
        ~ before.sel.to!string);

    // The repair, which only a mutable caller can perform.
    m.syncSelection();
    foreach (fi; 0 .. m.faces.length) m.selectFace(cast(int) fi);
    auto ctx2 = buildStatContext(*m);
    auto after = polygonStatCount(ctx2, PolygonStat.vertexCount, Compare.equal, 4, true);
    assert(after.sel == cast(long) m.faces.length,
        "after syncSelection the tail is countable, got " ~ after.sel.to!string);
}

// ---------------------------------------------------------------------------
// 5. NO MUTATION, AT COMPILE TIME (the card's trap 1, owner decision Р3).
//
// The kernel's parameters are `const`. `Command`'s constructor wants a mutable
// `Mesh*`, so the short cut the card forbids — "run select.byStat and see how
// many got selected" — is not merely discouraged here, it does not compile.
// MUTATION: delete the `const` from `StatContext.mesh` and this static assert
// is the thing that reddens, before any test runs.
// ---------------------------------------------------------------------------
unittest {
    static assert(!__traits(compiles, {
        StatContext ctx;
        View v = new View(0, 0, 1, 1);
        auto c = new SelectByStatVertex(ctx.mesh, v, EditMode.Vertices, null);
        c.apply();
    }), "a counting path must NOT be able to construct a mutating command — "
      ~ "if this compiles, the const proof has been deleted");

    // The positive half: the same construction over a MUTABLE pointer does
    // compile, so the assert above is about `const` and not about a typo.
    static assert(__traits(compiles, {
        Mesh* m;
        View v = new View(0, 0, 1, 1);
        auto c = new SelectByStatVertex(m, v, EditMode.Vertices, null);
        c.apply();
    }));
}

// ---------------------------------------------------------------------------
// THE TWO ARMS OF `buildEdgeFaceLists` ANSWER THE SAME THING.
//
// Stage 5's measurement gave this function a fast arm off the half-edge loops:
// the hashed build was 67 ms of an 84 ms panel rebuild on a 99 856-face /
// 200 344-edge grid, and every `select.byStat.*` command paid the same 67 ms,
// including the two components that never read this array.
//
// A second implementation of an adjacency is exactly the kind of thing that
// drifts, so the fast arm is compared against the hashed algorithm
// RE-IMPLEMENTED HERE, in this test's own arithmetic — not against the
// function's own fallback, which would only be comparing it with itself. The
// fixtures are the awkward ones: a non-manifold stack carrying a doubled face
// and a 4-polygon edge, an open box with a hole, and a plain cube.
// ---------------------------------------------------------------------------
private uint[][] hashedEdgeFacesIndependently(const ref Mesh m) {
    const size_t ne = m.edges.length;
    auto outp = new uint[][](ne);
    uint[ulong] idx;
    foreach (i; 0 .. ne)
        idx[edgeKey(m.edges[i][0], m.edges[i][1])] = cast(uint) i;
    foreach (fi; 0 .. m.faces.length) {
        const(uint)[] f = m.faces[fi];
        if (f.length == 0) continue;
        foreach (k; 0 .. f.length) {
            auto p = edgeKey(f[k], f[(k + 1) % f.length]) in idx;
            if (p is null) continue;
            outp[*p] ~= cast(uint) fi;
        }
    }
    return outp;
}

unittest {
    void armsAgree(Mesh* m, string what) {
        // `rebuildEdges()` bumps the structure stamp and does NOT rebuild the
        // loops, so a fixture built that way (the open box, and therefore two
        // of `by_stat.d`'s own unittests) runs the FALLBACK. Build them here,
        // because this arm is what the test is for.
        if (!m.loopsValid()) m.buildLoops();
        assert(m.loopsValid(),
            "setup: " ~ what ~ " must have VALID loops, or the fast arm this "
            ~ "test exists for never runs");
        auto fast = buildEdgeFaceLists(*m);
        auto want = hashedEdgeFacesIndependently(*m);
        assert(fast.length == want.length,
            what ~ ": the arms disagree on the edge count");
        foreach (ei; 0 .. fast.length)
            assert(fast[ei] == want[ei],
                what ~ ": the arms disagree at edge " ~ ei.to!string
                ~ " — loops " ~ fast[ei].to!string
                ~ " vs hashed " ~ want[ei].to!string);
    }

    armsAgree(stackedCube(), "the non-manifold stack");
    armsAgree(openBox(),     "the open box");
    armsAgree(freshCube(),   "a cube");

    // …and with the loops STALE, the function itself must fall back rather than
    // read a stamp it cannot trust. `addFace` bumps `structVersion` and
    // deliberately does not rebuild the loops, which is the mid-edit state a
    // real session spends time in.
    auto m = freshCube();
    m.addFace([0u, 1u, 2u]);
    assert(!m.loopsValid(), "setup: addFace leaves the loops stale");
    auto fallback = buildEdgeFaceLists(*m);
    auto want     = hashedEdgeFacesIndependently(*m);
    assert(fallback.length == want.length);
    foreach (ei; 0 .. fallback.length)
        assert(fallback[ei] == want[ei],
            "the stale-loop fallback must still be right at edge " ~ ei.to!string);
}
