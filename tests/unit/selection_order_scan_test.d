// selection_order_scan_test — "the most recently selected element" is read
// through ONE reader, and that reader filters by the Select bit BEFORE it
// ranks (task 2440).
//
// WHAT WENT WRONG. `select.less`, `select.more` and `select.between` each
// scanned the `*SelectionOrder` plane by hand — nine copies over three files —
// for the highest rank stamp, and NONE of the nine asked whether the element
// carrying that stamp was still selected. A stale non-zero stamp on an
// unselected element is a known, deliberate state: `mesh_ops/bevel_vertex.d`
// and `mesh_ops/extrude.d` both re-mask the face marks word with
// `~Marks.Select` and zero the stamp only over the range of faces they just
// created, so every SURVIVING face keeps the stamp its last click gave it and
// loses its Select bit. `faceSelectionOrder` is a carried plane
// (`mesh_planes.kFacePlanes`), so the rewrite preserves those values.
// `Mesh.selectedFaceIndicesInSelectionOrder` and
// `mesh_ops.select_loop.selectLoopFaces` had both already been written the
// other way round, and the first one's comment names the hazard and the two
// kernels outright.
//
// THE STAND, and why it is built out of a real kernel rather than by writing
// stamps into the plane by hand. The claim under test is that a state the
// SHIPPED code produces makes these three commands misbehave; a hand-planted
// stamp would only prove that the commands are sensitive to a state, not that
// anything reaches it. So `stand()` clicks five faces, runs
// `bevelVerticesByMask` through an unrecorded edit batch — the same call
// `commands/mesh/vertex_bevel.d`'s redo path makes — and clicks two more.
//
// WHAT EACH CELL IS FOR:
//
//   A  fixture — the stand really holds BOTH a live stamped selection and
//      higher stale stamps on unselected faces. Asserted first, and asserted
//      as an exact plane dump: every cell below is green on a stand where the
//      stale stamps happen not to outrank the live ones, and that stand
//      exhibits nothing.
//   B  the anti-vacuity control: an oracle spelling the OLD rule (rank first,
//      never ask about the Select bit) answers a DIFFERENT element than
//      `Mesh.lastSelectedInSelectionOrder` does on this stand. Without this
//      cell, cells C-E could be green over a stand that cannot discriminate.
//   C  select.less  — drops the last SELECTED face, not the phantom.
//   D  select.more  — extrapolates from the two selected faces, not the pair
//      of unselected ones.
//   E  select.between — same, and its failure was the loudest: it SELECTED
//      the two phantom faces themselves.
//   F  the rule, stated as an invariance rather than as three literals: the
//      answer must not change when the stale stamps are scrubbed. Scrubbing is
//      the operation `snapshot.d:452-462` already performs on the paths it
//      owns, and it changes nothing a user can see.
//   G  undo — each command's `revert()` restores the exact prior selection,
//      and the cell asserts how many steps took effect.
//   H  an UNSTAMPED selected element is deliberately still not a candidate.
//      The two sorting readers give stamp 0 the value `int.max` and sort it
//      last; taking their last entry would make an RMB-lasso element answer
//      "most recently selected". The three commands never worked that way and
//      still do not — `tests/test_select_derived_order.d` pins the visible
//      consequence for `select.fill.insideLoop`.
//   I  the vertex and edge planes. NO SHIPPED KERNEL is known to leave a stale
//      stamp on either (the two producers above are face-plane only, and
//      `clearVertexSelection` / `clearEdgeSelectionResize` zero the order
//      plane as they clear), so this cell builds the state directly and tests
//      the READER rather than a command — the point being that the filter is
//      in the shared body, not bolted onto the face arm.
module tests.unit.selection_order_scan_test;

import std.format : format;

import mesh;
import math     : Vec3;
import view;
import editmode;
import mesh_ops.bevel_vertex : bevelVerticesByMask, kBevelVertexEditScope;
import command         : Command;
import command_history : CommandHistory;

import commands.select.less    : SelectLess;
import commands.select.more    : SelectMore;
import commands.select.between : SelectBetween;

// ---------------------------------------------------------------------------
// The stand
// ---------------------------------------------------------------------------

private int[] selFaces(ref Mesh m) {
    int[] r;
    foreach (i; 0 .. m.faces.length) if (m.isFaceSelected(i)) r ~= cast(int) i;
    return r;
}

private View v() { return new View(0, 0, 800, 600); }

/// 5x5 quad grid, 25 faces, vertex(i, j) = i*6 + j.
///
/// 1. Five clicks in the BOTTOM row, in the order 24, 23, 22, 20, 21 — so the
///    two highest stamps land on faces 20 and 21, which are ADJACENT in a face
///    loop and therefore give a hand-rolled scan something actionable to
///    extrapolate from rather than a pair it would refuse.
/// 2. `bevelVerticesByMask` on vertex 14 (i=2, j=2). It touches faces 6, 7, 11
///    and 12 only, so the bottom row and the top row both stay QUADS — which
///    `select.more`/`select.between` require. It clears every Select bit,
///    resets `faceSelectionOrderCounter` to 0 and selects its own quad cap
///    (face 25, stamp 1); the five bottom-row faces keep stamps 1..5 with no
///    Select bit.
/// 3. Two more clicks, faces 0 and 3 (stamps 2 and 3), three faces apart in
///    the top row so `select.between` has a real gap to fill.
///
/// Live selection {0:2, 3:3, 25:1}; stale {20:4, 21:5, 22:3, 23:2, 24:1}. The
/// stale maximum (5) OUTRANKS every live stamp, which is the whole point.
private Mesh stand() {
    auto m = makeGridPlane(5);
    m.buildLoops();
    m.syncSelection();
    foreach (f; [24, 23, 22, 20, 21]) m.selectFace(f);

    auto vmask = new bool[](m.vertices.length);
    vmask[14] = true;
    {
        auto ed = MeshEditBatch.unrecorded(m, kBevelVertexEditScope);
        const n = ed.bevelVerticesByMask(vmask, 0.08f);
        ed.close();
        assert(n == 1, format("fixture: the bevel kernel processed %d vertices, " ~
                              "expected 1 — the stand no longer produces the " ~
                              "stale-stamp state it exists for", n));
    }
    m.selectFace(0);
    m.selectFace(3);
    return m;
}

/// The scrub `snapshot.d:452-462` performs on the paths it owns: zero the rank
/// stamp of an element that is not selected. Changes nothing observable about
/// the selection itself.
private void scrubStaleStamps(ref Mesh m) {
    foreach (i; 0 .. m.faceSelectionOrder.length)
        if (!m.isFaceSelected(i)) m.faceSelectionOrder[i] = 0;
}

private string stampDump(ref Mesh m) {
    string s;
    foreach (i; 0 .. m.faceSelectionOrder.length)
        if (m.faceSelectionOrder[i] != 0)
            s ~= format("%d:%d%s ", i, m.faceSelectionOrder[i],
                        m.isFaceSelected(i) ? "S" : "-");
    return s;
}

// ---------------------------------------------------------------------------
// A — the fixture itself
// ---------------------------------------------------------------------------
unittest {
    auto m = stand();

    assert(m.faces.length == 26,
        format("A: expected 25 grid quads + 1 bevel cap, got %d faces", m.faces.length));
    assert(selFaces(m) == [0, 3, 25],
        format("A: expected the live selection {0, 3, 25}, got %s (stamps: %s)",
               selFaces(m), stampDump(m)));

    // The exact plane, because "there are some stale stamps" is not the
    // property the cells below need — they need the stale MAXIMUM to outrank
    // every live stamp, and on a stand where it does not, every one of them is
    // green over the broken code too.
    int liveMax = 0, staleMax = 0;
    foreach (i; 0 .. m.faceSelectionOrder.length) {
        const o = m.faceSelectionOrder[i];
        if (o == 0) continue;
        if (m.isFaceSelected(i)) { if (o > liveMax)  liveMax  = o; }
        else                     { if (o > staleMax) staleMax = o; }
    }
    assert(liveMax == 3 && staleMax == 5,
        format("A: the stand must carry a stale stamp OUTRANKING every live " ~
               "one — live max %d, stale max %d (stamps: %s). With staleMax " ~
               "<= liveMax this whole file passes over the unfiltered scan too.",
               liveMax, staleMax, stampDump(m)));

    // Both loop walks the two commands need are available: the pair of stale
    // faces and the pair of live faces are all quads.
    foreach (f; [0, 3, 20, 21])
        assert(m.faces[f].length == 4,
            format("A: face %d is a %d-gon; the face-loop walk refuses anything " ~
                   "but a quad, and a refusal would make C-E inert",
                   f, m.faces[f].length));
}

// ---------------------------------------------------------------------------
// B — the anti-vacuity control: the old rule and the new one DISAGREE here
// ---------------------------------------------------------------------------
unittest {
    auto m = stand();

    // The rule the nine copies spelled: scan the plane, take the highest
    // positive stamp, never ask about the Select bit.
    int unfiltered = -1, unfilteredOrd = 0;
    foreach (i; 0 .. m.faceSelectionOrder.length) {
        const o = m.faceSelectionOrder[i];
        if (o > unfilteredOrd) { unfilteredOrd = o; unfiltered = cast(int) i; }
    }

    const sel = m.lastSelectedInSelectionOrder(EditMode.Polygons);

    assert(unfiltered == 21,
        format("B: the unfiltered scan should answer face 21 on this stand, " ~
               "got %d (stamps: %s)", unfiltered, stampDump(m)));
    assert(!m.isFaceSelected(unfiltered),
        "B: face 21 must NOT be selected — otherwise the two rules agree and " ~
        "this stand discriminates nothing");
    assert(sel.last == 3,
        format("B: Mesh.lastSelectedInSelectionOrder answered face %d, expected " ~
               "face 3 — the highest stamp among the SELECTED faces (stamps: %s)",
               sel.last, stampDump(m)));
    assert(sel.secondLast == 0,
        format("B: secondLast was face %d, expected face 0 (stamps: %s)",
               sel.secondLast, stampDump(m)));
}

// ---------------------------------------------------------------------------
// C — select.less drops the last SELECTED face
// ---------------------------------------------------------------------------
unittest {
    auto m = stand();
    const before = selFaces(m);

    { auto vw = v(); assert((new SelectLess(&m, vw, EditMode.Polygons)).apply()); }

    const after = selFaces(m);
    assert(after == [0, 25],
        format("C: select.less left %s, expected [0, 25] — it must drop face 3, " ~
               "the highest-stamped SELECTED face. Before the selected-first " ~
               "filter it aimed at face 21 (stale stamp 5, not selected) and " ~
               "the selection did not change at all. Selection %s -> %s",
               after, before, after));
    assert(after.length == before.length - 1,
        format("C: select.less removed %d elements, expected exactly 1 " ~
               "(%s -> %s)", cast(long)(before.length - after.length), before, after));
}

// ---------------------------------------------------------------------------
// D — select.more extrapolates from the two SELECTED faces
// ---------------------------------------------------------------------------
unittest {
    auto m = stand();

    { auto vw = v(); assert((new SelectMore(&m, vw, EditMode.Polygons)).apply()); }

    const after = selFaces(m);
    assert(after == [0, 1, 3, 25],
        format("D: select.more left %s, expected [0, 1, 3, 25] — it must " ~
               "extrapolate from the pair (0, 3) that is actually selected. " ~
               "Before the selected-first filter it took the phantom pair " ~
               "(20, 21) and selected face 22.", after));
}

// ---------------------------------------------------------------------------
// E — select.between fills between the two SELECTED faces
// ---------------------------------------------------------------------------
unittest {
    auto m = stand();

    { auto vw = v(); assert((new SelectBetween(&m, vw, EditMode.Polygons)).apply()); }

    const after = selFaces(m);
    assert(after == [0, 1, 2, 3, 25],
        format("E: select.between left %s, expected [0, 1, 2, 3, 25] — the run " ~
               "between the two selected faces 0 and 3. Before the " ~
               "selected-first filter it took the phantom pair (20, 21) and " ~
               "SELECTED those two faces, which the user had just watched the " ~
               "bevel deselect.", after));
}

// ---------------------------------------------------------------------------
// F — the rule: the answer does not depend on an unselected element's stamp
// ---------------------------------------------------------------------------
//
// Stated as an invariance rather than as three more literals, because this is
// the property the fix installs; C-E only pin one instance of it each.
unittest {
    static int[] run(string which, ref Mesh m) {
        auto vw = v();
        switch (which) {
            case "less":    (new SelectLess(&m, vw, EditMode.Polygons)).apply();    break;
            case "more":    (new SelectMore(&m, vw, EditMode.Polygons)).apply();    break;
            case "between": (new SelectBetween(&m, vw, EditMode.Polygons)).apply(); break;
            default: assert(false, "F: unknown command " ~ which);
        }
        return selFaces(m);
    }

    foreach (which; ["less", "more", "between"]) {
        auto asIs   = stand();
        auto scrubd = stand();
        scrubStaleStamps(scrubd);

        assert(selFaces(asIs) == selFaces(scrubd),
            "F: scrubbing a stale stamp changed the SELECTION itself — the " ~
            "oracle is not an oracle");

        const a = run(which, asIs);
        const b = run(which, scrubd);
        assert(a == b,
            format("F/%s: the answer depends on the rank stamps of elements " ~
                   "that are not selected.\n  as-is    : %s\n  scrubbed : %s\n" ~
                   "Scrubbing is what `snapshot.d:452-462` does on the paths it " ~
                   "owns; a command whose answer moves under it is reading a " ~
                   "plane it must filter first.", which, a, b));
    }
}

// ---------------------------------------------------------------------------
// G — undo, driven through the real history so "one step" is MEASURED
// ---------------------------------------------------------------------------
//
// The step count is `CommandHistory.undoEpoch`, which the history bumps
// exactly once in the SUCCESS branch of `undo()` and never anywhere else — so
// it is an independent count, not this cell restating its own literal.
unittest {
    static void oneCommandUndoes(string which) {
        auto m  = stand();
        auto vw = v();
        const before    = selFaces(m);
        const ordBefore = m.faceSelectionOrder.dup;
        const ctrBefore = m.faceSelectionOrderCounter;

        Command c;
        switch (which) {
            case "less":    c = new SelectLess(&m, vw, EditMode.Polygons);    break;
            case "more":    c = new SelectMore(&m, vw, EditMode.Polygons);    break;
            case "between": c = new SelectBetween(&m, vw, EditMode.Polygons); break;
            default: assert(false, "G: unknown command " ~ which);
        }

        assert(c.apply(), format("G/%s: apply refused", which));
        assert(selFaces(m) != before,
            format("G/%s: the forward step changed nothing (%s), so the undo " ~
                   "below would witness nothing", which, before));

        auto hist = new CommandHistory();
        hist.record(c);
        assert(hist.canUndo(),
            format("G/%s: the history refused the entry — this cell would then " ~
                   "measure zero steps and pass for the wrong reason", which));

        const epochBefore = hist.undoEpoch();
        assert(hist.undo(), format("G/%s: undo() refused", which));
        const steps = hist.undoEpoch() - epochBefore;

        assert(steps == 1,
            format("G/%s: %d undo steps took effect, expected exactly 1", which, steps));
        assert(!hist.canUndo(),
            format("G/%s: the undo stack is not empty after its single entry " ~
                   "was stepped", which));
        assert(selFaces(m) == before,
            format("G/%s: one undo step left the selection %s, expected the " ~
                   "pre-apply %s", which, selFaces(m), before));
        // The rank plane comes back SCRUBBED, not byte-identical, and that is
        // the shipped contract rather than a defect: `SelectionSnapshot.restore`
        // (`snapshot.d:452-462`) zeroes the stamp of every element the restored
        // image does not select. So the expectation is the pre-apply plane put
        // through the same rule — asserting raw equality here reddens on
        // correct code, which this cell was written doing and which the run
        // caught.
        auto ordExpected = ordBefore.dup;
        foreach (i; 0 .. ordExpected.length)
            if (!m.isFaceSelected(i)) ordExpected[i] = 0;
        assert(m.faceSelectionOrder == ordExpected,
            format("G/%s: one undo step restored the Select bits but not the " ~
                   "rank plane — %s vs %s", which, m.faceSelectionOrder, ordExpected));
        assert(m.faceSelectionOrderCounter == ctrBefore,
            format("G/%s: the rank counter came back %d, expected %d",
                   which, m.faceSelectionOrderCounter, ctrBefore));
    }

    foreach (which; ["less", "more", "between"]) oneCommandUndoes(which);

    // The no-op arm of the same contract, spelled out because the base class
    // reads the other way round (`Command.revert` returns false to mean "not
    // undoable"). `applyImpl` captures the selection snapshot BEFORE it can
    // decide there is nothing to do, so a command that changed nothing still
    // reverts successfully rather than refusing.
    auto empty = makeGridPlane(3);
    empty.buildLoops();
    empty.syncSelection();
    auto vw = v();
    auto c = new SelectLess(&empty, vw, EditMode.Polygons);
    assert(c.apply(), "G: select.less over an empty selection must still answer ok");
    assert(selFaces(empty).length == 0, "G: fixture — nothing was selected");
    assert(c.revert(),
        "G: revert() over a no-op apply must answer true — the snapshot was " ~
        "taken, so the undo succeeded; there was simply nothing to put back");
}

// ---------------------------------------------------------------------------
// H — an unstamped selected element is still not a candidate
// ---------------------------------------------------------------------------
unittest {
    auto m = makeGridPlane(3);
    m.buildLoops();
    m.syncSelection();

    // Select through the marks word directly, the way a restore-shaped setter
    // does: the Select bit goes on and no rank stamp is written.
    foreach (f; [1, 4, 7]) m.faceMarks[f] |= Mesh.Marks.Select;
    assert(selFaces(m) == [1, 4, 7], "H: fixture — three faces marked selected");
    foreach (f; [1, 4, 7])
        assert(m.faceSelectionOrder[f] == 0, "H: fixture — and none of them stamped");

    const sel = m.lastSelectedInSelectionOrder(EditMode.Polygons);
    assert(sel.last == -1 && sel.secondLast == -1,
        format("H: an entirely unstamped selection has no MOST RECENT element " ~
               "— got last=%d secondLast=%d. The two sorting readers " ~
               "(`selectedFaceIndicesInSelectionOrder`, " ~
               "`selectedVerticesBySelectionOrder`) rank stamp 0 as int.max and " ~
               "would hand back an element the user never clicked; this reader " ~
               "deliberately does not.", sel.last, sel.secondLast));

    auto vw = v();
    assert((new SelectLess(&m, vw, EditMode.Polygons)).apply());
    assert(selFaces(m) == [1, 4, 7],
        format("H: select.less over an unstamped selection must leave it alone, " ~
               "got %s. `tests/test_select_derived_order.d` pins the visible " ~
               "consequence for select.fill.insideLoop.", selFaces(m)));
}

// ---------------------------------------------------------------------------
// I — the vertex and edge planes go through the same body
// ---------------------------------------------------------------------------
//
// Built by hand rather than by a kernel, and that is stated rather than
// hidden: the two producers named at the top are FACE-plane only, and the
// vertex/edge bulk clears (`clearVertexSelection`, `clearEdgeSelectionResize`)
// zero their rank plane as they clear the bits, so no shipped path is known to
// leave a stale VERTEX or EDGE stamp today. What this cell pins is that the
// filter lives in the shared body and not in the face arm — which is what
// makes such a producer, if one ever arrives, harmless here.
unittest {
    auto m = makeGridPlane(3);
    m.buildLoops();
    m.syncSelection();

    // Vertices: 2 and 5 selected and stamped; 9 stamped HIGHER and not selected.
    m.selectVertex(2);
    m.selectVertex(5);
    m.vertexSelectionOrder[9] = 99;
    assert(!m.isVertexSelected(9), "I: fixture — vertex 9 must be unselected");

    auto vsel = m.lastSelectedInSelectionOrder(EditMode.Vertices);
    assert(vsel.last == 5 && vsel.secondLast == 2,
        format("I/vertices: got last=%d secondLast=%d, expected 5 and 2 — " ~
               "vertex 9 carries stamp 99 but is not selected", vsel.last, vsel.secondLast));

    // Edges: same shape.
    const uint e0 = m.edgeIndex(0, 1);
    const uint e1 = m.edgeIndex(1, 2);
    assert(e0 != ~0u && e1 != ~0u, "I: fixture — the grid has edges 0-1 and 1-2");
    m.selectEdge(cast(int) e0);
    m.selectEdge(cast(int) e1);
    foreach (i; 0 .. m.edges.length)
        if (i != e0 && i != e1) { m.edgeSelectionOrder[i] = 99; break; }

    auto esel = m.lastSelectedInSelectionOrder(EditMode.Edges);
    assert(esel.last == cast(int) e1 && esel.secondLast == cast(int) e0,
        format("I/edges: got last=%d secondLast=%d, expected %d and %d",
               esel.last, esel.secondLast, e1, e0));

    // And the bounds contract the callers rely on: whatever comes back is
    // inside BOTH planes, so `deselect*` — which indexes each raw — is safe.
    auto fsel = m.lastSelectedInSelectionOrder(EditMode.Polygons);
    foreach (idx; [vsel.last, vsel.secondLast])
        assert(idx < cast(int) m.vertexMarks.length
            && idx < cast(int) m.vertexSelectionOrder.length,
            "I: a returned vertex index reached past a selection plane");
    assert(fsel.last == -1,
        format("I: no face was clicked on this mesh, so the face plane has no " ~
               "most-recent element; got %d", fsel.last));
}
