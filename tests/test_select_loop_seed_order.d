// Task 0554 — `select.loop` must not destroy the selection history it reads.
//
// Both non-edge branches of `select.loop` pick their seed from the selected
// elements sorted by `vertex/faceSelectionOrder` ("0 or absent" -> int.max, so
// an UNSTAMPED element sorts last). The commit path
// (`setVerticesSelectedFrom` / `setFacesSelectedFrom`) is a state-RESTORE
// setter: it writes the Select bit and nothing else. So every element the walk
// ADDED came out with order 0 and sorted behind anything the user clicked
// afterwards — even though the walk had selected it first. The oldest-first
// rule the walk documents for itself was inverted for exactly the elements the
// walk itself produced, and that changes the band the next loop lands on.
//
// Convention asserted here (reading (a) of the task): a derived selection is
// stamped exactly as `Mesh.selectX` stamps a click — an element that was NOT
// already selected takes the next counter value, an already-selected one keeps
// the order it had. That is already the behaviour of `select.loop`'s own Edges
// branch (`mesh.selectEdge`, commands/select/loop.d) and of every other
// derived-selection command in the family (ring.d, expand.d, between.d,
// more.d). The walk returns a `bool[]`, so — like expand.d, the closest
// analogue — the added elements are stamped in ascending index order. Note
// that this leaves the walk-added block's INTERNAL order exactly as it was
// before the fix (the old sort tie-broke the order-0 elements by index too);
// only the block's position relative to LATER clicks changes. That is why a
// single-`select.loop` fixture cannot observe this at all.
//
// Pure kernel/command test (no HTTP): drives the real `SelectLoop` command over
// a grid. Two assertions, both non-vacuous (mutation-verified against the
// pre-fix commit):
//
//   1. mechanism — the post-loop selection order must equal the TRUE history
//      (surviving seed clicks in click order, then the walk's own output, then
//      the later click), computed here WITHOUT reading the order array.
//   2. outcome   — replaying that true history as literal clicks on a fresh
//      mesh and re-running the walk must reproduce the command path's result.

import mesh;
import view;
import editmode;
import commands.select.loop : SelectLoop;

import std.algorithm : sort, canFind;
import std.format    : format;

void main() {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private Mesh grid5() {
    auto m = makeGridPlane(5);      // 25 quads, 36 vertices
    m.syncSelection();
    return m;
}

private int[] selectedFaceIdx(ref Mesh m) {
    int[] r;
    foreach (i; 0 .. m.faces.length) if (m.isFaceSelected(i)) r ~= cast(int) i;
    return r;
}

private int[] selectedVertIdx(ref Mesh m) {
    int[] r;
    foreach (i; 0 .. m.vertices.length) if (m.isVertexSelected(i)) r ~= cast(int) i;
    return r;
}

// Run the real command (not the bare kernel) so the commit path is under test.
private void runLoop(ref Mesh m, EditMode mode) {
    auto v   = new View(0, 0, 800, 600);
    auto cmd = new SelectLoop(&m, v, mode);
    assert(cmd.apply(), "select.loop apply() returned false");
}

// The selected elements in the order the walk's own seed scan reads them: by
// stamped order, "0 or absent" last, index as tie-break. Mirrors
// mesh.selectLoopFaces / selectLoopVertices verbatim.
private int[] seedScanOrder(const int[] order, const int[] selected) {
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

// The history the user actually produced, derived from the clicks and the
// walk's membership ALONE — never from the order array under test.
//   surviving seed clicks (in click order) ++ walk-added (index order) ++ later click
private int[] trueHistory(const int[] clicks, const int[] afterLoop, int later) {
    int[] h;
    foreach (c; clicks) if (afterLoop.canFind(c)) h ~= c;
    foreach (e; afterLoop) if (!clicks.canFind(e)) h ~= e;
    h ~= later;
    return h;
}

private int[] ordersOf(const int[] idx, const int[] order) {
    int[] r;
    foreach (i; idx) r ~= (i < cast(int) order.length ? order[i] : 0);
    return r;
}

// ---------------------------------------------------------------------------
// Polygon mode — click 0,2 -> loop -> shift-add 1 -> loop
// ---------------------------------------------------------------------------

unittest {
    immutable int[] clicks = [0, 2];
    immutable int   added  = 1;      // the "shift-click" after the first loop

    auto m = grid5();
    m.clearFaceSelection();
    foreach (c; clicks) m.selectFace(c);

    runLoop(m, EditMode.Polygons);
    auto afterLoop1 = selectedFaceIdx(m);
    assert(afterLoop1.length > clicks.length,
        "fixture is inert: select.loop added no polygons to the seed selection");
    assert(!m.isFaceSelected(added), "fixture: polygon to add is already selected");

    m.selectFace(added);                       // the shift-click

    auto want = trueHistory(clicks, afterLoop1, added);
    auto got  = seedScanOrder(m.faceSelectionOrder, selectedFaceIdx(m));

    // --- 1. Mechanism. ---
    assert(got == want,
        format("select.loop lost the selection history of its own output.\n" ~
               "  seed scan reads : %s\n" ~
               "  true history    : %s\n" ~
               "  stamped orders  : %s\n" ~
               "Polygon %d was clicked LAST but does not seed last: the polygons " ~
               "select.loop had already selected came out with order 0 " ~
               "(\"not manually selected\"), so they sort behind it and the " ~
               "oldest-first seed rule is inverted.",
               got, want, ordersOf(got, m.faceSelectionOrder), added));

    // --- 2. Outcome: that history, replayed as literal clicks, must agree. ---
    auto oracle = grid5();
    oracle.clearFaceSelection();
    foreach (fi; want) oracle.selectFace(fi);

    runLoop(m,      EditMode.Polygons);
    runLoop(oracle, EditMode.Polygons);

    auto gotSel  = selectedFaceIdx(m);
    auto wantSel = selectedFaceIdx(oracle);
    assert(gotSel == wantSel,
        format("select.loop's second pass disagrees with the same selection " ~
               "history replayed as clicks:\n  command path : %s\n  click replay : %s\n" ~
               "  history      : %s", gotSel, wantSel, want));
}

// ---------------------------------------------------------------------------
// Vertex mode — click 0,1 -> loop -> shift-add 7 -> loop
// ---------------------------------------------------------------------------

unittest {
    immutable int[] clicks = [0, 1];
    immutable int   added  = 7;

    auto m = grid5();
    m.clearVertexSelection();
    foreach (c; clicks) m.selectVertex(c);

    runLoop(m, EditMode.Vertices);
    auto afterLoop1 = selectedVertIdx(m);
    assert(afterLoop1.length > clicks.length,
        "fixture is inert: select.loop added no vertices to the seed selection");
    assert(!m.isVertexSelected(added), "fixture: vertex to add is already selected");

    m.selectVertex(added);

    auto want = trueHistory(clicks, afterLoop1, added);
    auto got  = seedScanOrder(m.vertexSelectionOrder, selectedVertIdx(m));

    assert(got == want,
        format("select.loop lost the selection history of its own output.\n" ~
               "  seed scan reads : %s\n" ~
               "  true history    : %s\n" ~
               "  stamped orders  : %s\n" ~
               "Vertex %d was clicked LAST but does not seed last: the vertices " ~
               "select.loop had already selected came out with order 0 " ~
               "(\"not manually selected\"), so they sort behind it and the " ~
               "oldest-first seed rule is inverted.",
               got, want, ordersOf(got, m.vertexSelectionOrder), added));

    auto oracle = grid5();
    oracle.clearVertexSelection();
    foreach (vi; want) oracle.selectVertex(vi);

    runLoop(m,      EditMode.Vertices);
    runLoop(oracle, EditMode.Vertices);

    auto gotSel  = selectedVertIdx(m);
    auto wantSel = selectedVertIdx(oracle);
    assert(gotSel == wantSel,
        format("select.loop's second pass disagrees with the same selection " ~
               "history replayed as clicks:\n  command path : %s\n  click replay : %s\n" ~
               "  history      : %s", gotSel, wantSel, want));
}
