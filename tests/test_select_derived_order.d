// Task 0554 follow-up — `select.connect` and `select.fill` commit derived
// selections that must carry a selection-history value.
//
// Both used the state-RESTORE setter (`setXSelectedFrom`), which writes the
// Select bit and nothing else, so everything they selected on the user's
// behalf landed with order 0 ("not manually selected", sorts LAST). That is
// observable, not merely untidy — measured on a 5x5 grid / a two-component
// mesh, against the same history replayed as literal clicks:
//
//   select.fill.holes      -> click -> select.between   144/144 diverge
//   select.fill.holes      -> click -> select.more       30/144
//   select.fill.holes              -> select.less          9/9
//   select.fill.holes              -> select.more          6/9
//   select.fill.insideLoop -> click -> select.between     12/16
//   select.fill.insideLoop -> click -> select.loop        10/16
//   select.fill.insideLoop         -> select.less          1/1  (silent no-op)
//   select.connect                 -> select.less         72/72
//   select.connect (vertex)-> click -> makePolygon order 3840/3840
//
// The last one is a GEOMETRY consequence: `mesh.makePolygon` derives face
// WINDING from vertex click order.
//
// This file asserts two independent things:
//   1. the CONTRACT — committing a derived selection stamps exactly as
//      `Mesh.selectX` would: the added elements take the next counter values
//      in ascending index order, survivors keep their order, the counter
//      advances by exactly the number added. The expectation is built from
//      the counter's PRE value and the added SET, never from the order array.
//   2. the OUTCOMES that actually diverged, via a click-replay oracle whose
//      history is likewise derived from membership alone.

import mesh;
import math;
import view;
import editmode;
import commands.select.connect : SelectConnect;
import commands.select.fill    : SelectFillHoles, SelectFillInsideLoop;
import commands.select.less    : SelectLess;
import commands.select.between : SelectBetween;

import std.algorithm : sort, canFind;
import std.format    : format;

void main() {}

// ---------------------------------------------------------------------------
// Fixtures / helpers
// ---------------------------------------------------------------------------

private Mesh grid5() {
    auto m = makeGridPlane(5);          // 25 quads, 36 verts
    m.syncSelection();
    return m;
}

// Two disjoint 3x3 grid planes offset in X — two connected components, so a
// flood fill from one leaves the other clickable.
private Mesh twoGrids() {
    enum int n = 3, side = n + 1;
    Mesh m;
    foreach (comp; 0 .. 2) {
        immutable float xoff = comp * 10.0f;
        immutable uint  base = cast(uint) m.vertices.length;
        foreach (i; 0 .. side) foreach (j; 0 .. side)
            m.vertices ~= Vec3(xoff + 2.0f * j / n, 0.0f, 2.0f * i / n);
        foreach (i; 0 .. n) foreach (j; 0 .. n) {
            immutable uint v00 = base + cast(uint)(i * side + j);
            m.addFace([v00, v00 + 1, v00 + side + 1, v00 + side]);
        }
    }
    m.buildLoops();
    m.syncSelection();
    return m;
}

private int[] selFaces(ref Mesh m) {
    int[] r; foreach (i; 0 .. m.faces.length) if (m.isFaceSelected(i)) r ~= cast(int) i; return r;
}
private int[] selVerts(ref Mesh m) {
    int[] r; foreach (i; 0 .. m.vertices.length) if (m.isVertexSelected(i)) r ~= cast(int) i; return r;
}

private View v() { return new View(0, 0, 800, 600); }

// The order a history consumer reads: by stamped order, "0 or absent" last,
// index as tie-break. This is the sort shared by select.loop's seed scan,
// select.more / select.less / select.between, and mesh.makePolygon (which
// turns it into face WINDING).
private int[] historyRead(const int[] order, const int[] selected) {
    static int ordOf(const int[] o, int i) {
        return (i < cast(int) o.length && o[i] > 0) ? o[i] : int.max;
    }
    auto s = selected.dup;
    s.sort!((x, y) {
        int ox = ordOf(order, x), oy = ordOf(order, y);
        return ox != oy ? ox < oy : x < y;
    });
    return s;
}

// Assert the bulk-select contract on one domain. `before`/`after` are the
// selected-index lists either side of the command; `orderAfter` is the live
// order array; `ctrBefore` the counter before. The expectation is computed
// from ctrBefore and the added SET — not from orderAfter.
private void assertStampContract(string what, const int[] before, const int[] after,
                                 const int[] orderBefore, const int[] orderAfter,
                                 int ctrBefore, int ctrAfter) {
    int[] added;
    foreach (e; after) if (!before.canFind(e)) added ~= e;
    assert(added.length > 0,
        format("%s: fixture is inert — the command added nothing, so it cannot " ~
               "witness the stamping contract", what));

    // Added elements take the next counter values, ascending index order.
    int expect = ctrBefore;
    foreach (e; added) {
        ++expect;
        assert(orderAfter[e] == expect,
            format("%s: element %d was ADDED by the command but carries " ~
                   "selection-order %d, expected %d (counter was %d before, " ~
                   "added set %s). Order 0 means \"not manually selected\" and " ~
                   "sorts LAST, behind anything clicked afterwards.",
                   what, e, orderAfter[e], expect, ctrBefore, added));
    }
    assert(ctrAfter == expect,
        format("%s: counter advanced to %d, expected %d (%d elements added)",
               what, ctrAfter, expect, added.length));

    // Survivors keep the order of the click that made them.
    foreach (e; after)
        if (before.canFind(e))
            assert(orderAfter[e] == orderBefore[e],
                format("%s: surviving element %d lost its order (%d -> %d)",
                       what, e, orderBefore[e], orderAfter[e]));
}

// ---------------------------------------------------------------------------
// select.fill.holes — contract + the select.less outcome
// ---------------------------------------------------------------------------

unittest {
    // Ring of 8 faces around face 12; the fill swallows the enclosed hole.
    immutable int[] seeds = [6, 7, 8, 11, 13, 16, 17, 18];
    immutable int   hole  = 12;

    auto m = grid5();
    m.clearFaceSelection();
    foreach (s; seeds) m.selectFace(s);

    auto before      = selFaces(m);
    auto orderBefore = m.faceSelectionOrder.dup;
    auto ctrBefore   = m.faceSelectionOrderCounter;

    { auto vw = v(); assert((new SelectFillHoles(&m, vw, EditMode.Polygons)).apply()); }

    auto after = selFaces(m);
    assert(after.canFind(hole), "fixture: fill.holes did not swallow the hole");
    assertStampContract("select.fill.holes", before, after,
                        orderBefore, m.faceSelectionOrder,
                        ctrBefore, m.faceSelectionOrderCounter);

    // Outcome: select.less drops "the most recently selected element". The
    // fill's face is the newest thing in the selection, so it must go — not
    // the last user click.
    { auto vw = v(); assert((new SelectLess(&m, vw, EditMode.Polygons)).apply()); }
    auto afterLess = selFaces(m);
    assert(!afterLess.canFind(hole),
        format("select.less after select.fill.holes did not drop the face the " ~
               "fill had just added (%d); it dropped a user click instead. " ~
               "Selection is now %s.", hole, afterLess));
    foreach (s; seeds)
        assert(afterLess.canFind(s),
            format("select.less dropped user-clicked face %d instead of the " ~
                   "fill's own newest face %d. Selection is now %s.",
                   s, hole, afterLess));
}

// ---------------------------------------------------------------------------
// select.fill.holes -> click -> select.between (144/144 divergent pre-fix)
// ---------------------------------------------------------------------------

unittest {
    immutable int[] seeds = [6, 7, 8, 11, 13, 16, 17, 18];
    immutable int   click = 3;

    auto m = grid5();
    m.clearFaceSelection();
    foreach (s; seeds) m.selectFace(s);
    { auto vw = v(); (new SelectFillHoles(&m, vw, EditMode.Polygons)).apply(); }
    auto afterFill = selFaces(m);

    assert(!afterFill.canFind(click), "fixture: click face already selected");
    m.selectFace(click);

    // True history, from the clicks and the fill's MEMBERSHIP alone.
    int[] hist;
    foreach (s; seeds)     if (afterFill.canFind(s))  hist ~= s;
    foreach (e; afterFill) if (!seeds.canFind(e))     hist ~= e;
    hist ~= click;

    assert(historyRead(m.faceSelectionOrder, selFaces(m)) == hist,
        format("select.fill.holes lost the history of its own output.\n" ~
               "  consumers read : %s\n  true history   : %s",
               historyRead(m.faceSelectionOrder, selFaces(m)), hist));

    { auto vw = v(); (new SelectBetween(&m, vw, EditMode.Polygons)).apply(); }
    auto got = selFaces(m);

    auto o = grid5();
    o.clearFaceSelection();
    foreach (x; hist) o.selectFace(x);
    { auto vw = v(); (new SelectBetween(&o, vw, EditMode.Polygons)).apply(); }
    auto want = selFaces(o);

    assert(got == want,
        format("select.between disagrees with the same history replayed as " ~
               "clicks:\n  command path : %s\n  click replay : %s\n  history      : %s",
               got, want, hist));
}

// ---------------------------------------------------------------------------
// select.fill.insideLoop — every committed face is derived, so pre-fix the
// whole selection was unstamped and select.less became a silent no-op.
// ---------------------------------------------------------------------------

unittest {
    auto m = grid5();
    m.clearEdgeSelection();
    m.clearFaceSelection();

    // Barrier: the perimeter of the central 3x3 face block, in the 6x6 vertex
    // grid (vertex(i,j) = i*6 + j).
    static uint vid(int i, int j) { return cast(uint)(i * 6 + j); }
    foreach (j; 1 .. 4) {
        m.selectEdge(cast(int) m.edgeIndex(vid(1, j), vid(1, j + 1)));
        m.selectEdge(cast(int) m.edgeIndex(vid(4, j), vid(4, j + 1)));
    }
    foreach (i; 1 .. 4) {
        m.selectEdge(cast(int) m.edgeIndex(vid(i, 1), vid(i + 1, 1)));
        m.selectEdge(cast(int) m.edgeIndex(vid(i, 4), vid(i + 1, 4)));
    }

    auto before      = selFaces(m);
    auto orderBefore = m.faceSelectionOrder.dup;
    auto ctrBefore   = m.faceSelectionOrderCounter;
    assert(before.length == 0, "fixture: expected no prior face selection");

    EditMode em = EditMode.Edges;
    { auto vw = v(); assert((new SelectFillInsideLoop(&m, vw, em, &em)).apply()); }

    auto after = selFaces(m);
    assert(after.length == 9,
        format("fixture: expected the enclosed 3x3 block, got %s", after));
    assertStampContract("select.fill.insideLoop", before, after,
                        orderBefore, m.faceSelectionOrder,
                        ctrBefore, m.faceSelectionOrderCounter);

    // Outcome: select.less must have something to drop. Pre-fix every face
    // carried order 0, so its find-highest loop found nothing and the command
    // silently did nothing at all.
    { auto vw = v(); (new SelectLess(&m, vw, EditMode.Polygons)).apply(); }
    auto afterLess = selFaces(m);
    assert(afterLess.length == after.length - 1,
        format("select.less after select.fill.insideLoop was a silent no-op — " ~
               "the fill's faces carry no selection order, so there is no " ~
               "\"most recent\" element to drop. Selection %s -> %s",
               after, afterLess));
}

// ---------------------------------------------------------------------------
// select.connect (vertex) -> click -> the order mesh.makePolygon reads as
// face WINDING (3840/3840 divergent pre-fix).
// ---------------------------------------------------------------------------

unittest {
    immutable int[] seeds = [0, 1];     // component A
    immutable int   click = 16;         // component B

    auto m = twoGrids();
    m.clearVertexSelection();
    foreach (s; seeds) m.selectVertex(s);

    auto before      = selVerts(m);
    auto orderBefore = m.vertexSelectionOrder.dup;
    auto ctrBefore   = m.vertexSelectionOrderCounter;

    { auto vw = v(); assert((new SelectConnect(&m, vw, EditMode.Vertices)).apply()); }

    auto after = selVerts(m);
    assert(after.length == 16,
        format("fixture: expected connect to fill component A (16 verts), got %s", after));
    assertStampContract("select.connect (vertices)", before, after,
                        orderBefore, m.vertexSelectionOrder,
                        ctrBefore, m.vertexSelectionOrderCounter);

    assert(!after.canFind(click), "fixture: click vertex already selected");
    m.selectVertex(click);

    int[] hist;
    foreach (s; seeds) if (after.canFind(s))  hist ~= s;
    foreach (e; after) if (!seeds.canFind(e)) hist ~= e;
    hist ~= click;

    // mesh.makePolygon builds its face by walking exactly this order, so a
    // wrong order here is a wrong winding.
    auto got = historyRead(m.vertexSelectionOrder, selVerts(m));
    assert(got == hist,
        format("the vertex order mesh.makePolygon would wind a face from does " ~
               "not match the true selection history:\n" ~
               "  makePolygon would read : %s\n  true history           : %s\n" ~
               "Vertex %d was clicked LAST but does not come last — the vertices " ~
               "select.connect added carry no history value.", got, hist, click));
}

// ---------------------------------------------------------------------------
// select.connect (polygon) -> select.less (72/72 divergent pre-fix)
// ---------------------------------------------------------------------------

unittest {
    immutable int[] seeds = [0, 1];

    auto m = twoGrids();
    m.clearFaceSelection();
    foreach (s; seeds) m.selectFace(s);

    auto before      = selFaces(m);
    auto orderBefore = m.faceSelectionOrder.dup;
    auto ctrBefore   = m.faceSelectionOrderCounter;

    { auto vw = v(); assert((new SelectConnect(&m, vw, EditMode.Polygons)).apply()); }

    auto after = selFaces(m);
    assert(after.length == 9,
        format("fixture: expected connect to fill component A (9 faces), got %s", after));
    assertStampContract("select.connect (polygons)", before, after,
                        orderBefore, m.faceSelectionOrder,
                        ctrBefore, m.faceSelectionOrderCounter);

    // The newest element is the last face the flood fill reached, not a seed.
    int[] added;
    foreach (e; after) if (!seeds.canFind(e)) added ~= e;
    immutable int newest = added[$ - 1];

    { auto vw = v(); (new SelectLess(&m, vw, EditMode.Polygons)).apply(); }
    auto afterLess = selFaces(m);
    assert(!afterLess.canFind(newest),
        format("select.less after select.connect did not drop the newest face " ~
               "(%d, the last one the flood fill reached); selection is now %s",
               newest, afterLess));
    foreach (s; seeds)
        assert(afterLess.canFind(s),
            format("select.less dropped user-clicked face %d instead of the " ~
                   "flood fill's newest face %d", s, newest));
}
