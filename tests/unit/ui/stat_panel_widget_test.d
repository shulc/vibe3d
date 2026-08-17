// The Statistics panel, DRAWN — task 1100 Stage 4, verifications B and C.
//
// Two things are proved here that no assertion against the row model can:
//
//   B. DRAWING THIS PANEL MUTATES NOTHING. The kernel and the row model take
//      the mesh as `const`, so a count written as "run the row's command and
//      look at the selection" does not compile there. The ONE hole `const`
//      cannot close is the drawer's command-dispatch delegate — a clickable
//      column has to be able to fire a command — so the guard around that hole
//      is a mesh FINGERPRINT taken across real draw frames.
//
//      The fingerprint is `tests/unit/mesh_ops/edge_bevel_test.d`'s, reused
//      verbatim: three version counters, BOTH pending-change words, the three
//      marks arrays, the three selection-order arrays, `faceMaterial`,
//      `facePart`, and a `MeshEditTracker` over `beginEditBatch` asserted
//      empty. The version counters and the pending words are what catch an
//      apply-then-revert count: undo restores the marks byte for byte and
//      leaves those moved.
//
//   C. A CLICK ON A ROW'S `+` REACHES THAT ROW'S ACTION. `/api/stats` reports
//      labels and numbers; it says nothing about which command a cell is wired
//      to. This presses the real widget.

import command   : Command, g_testMode;
import document  : Document, Layer;
import editmode  : EditMode;
import mesh;
import mesh_edit_delta : MeshEditTracker, MeshEditScope;
import seltype   : SelType, SelMode;
import ui.panels : drawStatisticsBody;
import ui.stat_rows;
import ui.stat_record : drawnStatRows;
import tests.unit.ui.headless_panel : HeadlessPanel, openPanel;
import tests.unit.ui.stat_dispatch  : dispatchStatAction;
import std.algorithm : canFind;
import std.conv : to;

// ---------------------------------------------------------------------------
// The rig: a mesh, a document whose primary is that layer, an expand state, and
// a REAL dispatcher.
// ---------------------------------------------------------------------------
private struct Rig {
    Document   doc;
    StatExpand exp;
    SelType    current = SelType.Polygon;
    string[]   fired;          ///< every (id, args) the drawer dispatched

    Mesh* mesh() { return &doc.primary.meshRef(); }

    /// THE DELEGATE THE DRAWER HOLDS, and it is a REAL dispatcher — it
    /// constructs and applies the actual `Command` object.
    ///
    /// This is not a detail. If it were a recording stub that fired nothing,
    /// verification B's mutation ("count this row by firing its own action and
    /// undoing it") would become INERT: the drawer would mutate in production
    /// and the test would stay green. The stub is the guard on the guard, and
    /// it is the defect class every round of review on this task caught at
    /// least one of.
    /// The last command this dispatcher applied, so `history.undo` can revert
    /// it. That is not a convenience: without a WORKING undo here, a drawer
    /// that counted by "fire the row's action, then undo it" would be caught
    /// only because the undo did not happen — and the version counters and
    /// pending words in the fingerprint, which are what catch a count that
    /// undoes CORRECTLY, would never be exercised.
    Command last;

    void delegate(string, string) runner() {
        return (string id, string args) {
            fired ~= id ~ " " ~ args;
            if (id == "history.undo") {
                if (last !is null) { last.revert(); last = null; }
                return;
            }
            auto r = dispatchStatAction(&doc, mesh(), EditMode.Polygons,
                                        current, id, args);
            if (r.ran) last = r.cmd;
        };
    }
}

private Rig makeRig() {
    Rig r;
    // EXPAND EXPLICITLY, never inheriting the first-open default. That default
    // is ours rather than measured, so it is exactly the constant that moves;
    // a test that leaned on it would go red for a reason unrelated to what it
    // checks. (Measured: it does — flipping the default reddened this file
    // before this line existed.)
    foreach (t; [SelType.Vertex, SelType.Edge, SelType.Polygon, SelType.Item])
        r.exp.section[cast(size_t) t] = true;
    Mesh m = makeCube();
    r.doc = Document.bootstrap(m);
    r.mesh().syncSelection();
    r.mesh().faceMaterial.length = r.mesh().faces.length;
    r.mesh().faceMaterial[0] = 1;
    r.mesh().surfaces = [Surface("Default"), Surface("Red")];
    return r;
}

// ---------------------------------------------------------------------------
// The fingerprint (edge_bevel_test.d:5985-6016), reused verbatim.
// ---------------------------------------------------------------------------
private struct Fingerprint {
    uint[]  vertexMarks, edgeMarks, faceMarks;
    int[]   vertexSelectionOrder, edgeSelectionOrder, faceSelectionOrder;
    uint[]  faceMaterial, facePart;
    ulong   mutationVersion, topologyVersion, structVersion;
    uint    pendingChanges, pendingSelDomains;
}

private Fingerprint take(Mesh* mm) {
    Fingerprint f;
    f.vertexMarks          = mm.vertexMarks.dup;
    f.edgeMarks            = mm.edgeMarks.dup;
    f.faceMarks            = mm.faceMarks.dup;
    f.vertexSelectionOrder = mm.vertexSelectionOrder.dup;
    f.edgeSelectionOrder   = mm.edgeSelectionOrder.dup;
    f.faceSelectionOrder   = mm.faceSelectionOrder.dup;
    f.faceMaterial         = mm.faceMaterial.dup;
    f.facePart             = mm.facePart.dup;
    f.mutationVersion      = mm.mutationVersion;
    f.topologyVersion      = mm.topologyVersion;
    f.structVersion        = mm.structVersion;
    f.pendingChanges       = mm.pendingChanges_;
    f.pendingSelDomains    = mm.pendingSelDomains_;
    return f;
}

private void assertSame(Fingerprint a, Fingerprint b, string what) {
    assert(a.vertexMarks == b.vertexMarks && a.edgeMarks == b.edgeMarks
        && a.faceMarks == b.faceMarks, what ~ ": the marks arrays moved");
    assert(a.vertexSelectionOrder == b.vertexSelectionOrder
        && a.edgeSelectionOrder == b.edgeSelectionOrder
        && a.faceSelectionOrder == b.faceSelectionOrder,
        what ~ ": the selection ORDER moved");
    assert(a.faceMaterial == b.faceMaterial && a.facePart == b.facePart,
        what ~ ": a parallel attribute moved");
    assert(a.mutationVersion == b.mutationVersion
        && a.topologyVersion == b.topologyVersion
        && a.structVersion == b.structVersion,
        what ~ ": a version counter moved — this is what an apply-then-revert "
        ~ "count leaves behind after the marks are restored byte for byte");
    assert(a.pendingChanges == b.pendingChanges
        && a.pendingSelDomains == b.pendingSelDomains,
        what ~ ": a pending-change word moved, for the same reason");
}

// ---------------------------------------------------------------------------
// B — several real frames, including one with a category expanded and one in
// the no-edit-target state, mutate NOTHING.
// ---------------------------------------------------------------------------
unittest {
    auto rig = makeRig();
    rig.mesh().selectFace(0);
    rig.mesh().selectFace(2);           // a real selection, so `Sel` is live

    auto before = take(rig.mesh());
    MeshEditTracker recorder;
    rig.mesh().beginEditBatch(&recorder, MeshEditScope.Geometry);
    assert(rig.mesh().isRecordingEdits());

    auto ui = openPanel(() {
        drawStatisticsBody(&rig.doc, rig.current, rig.exp, rig.runner());
    }, "Statistics");
    scope (exit) ui.close();

    foreach (i; 0 .. 3) ui.frame();

    // …with a category expanded, so every leaf is built and counted.
    rig.exp.category["Polygons/By Vertex"] = true;
    rig.exp.category["Polygons/Material"]  = true;
    rig.exp.category["Vertices/By Edge"]   = true;
    foreach (i; 0 .. 3) ui.frame();

    assertSame(before, take(rig.mesh()), "drawing the panel");
    assert(recorder.isEmpty(), "drawing must not write an edit record");
    assert(rig.mesh().endEditBatch().isEmpty(),
        "…and must finish with an empty delta");
    // THE GUARD ON THE GUARD, and it is not where the plan expected it to be.
    // The predicted hole was: replace the dispatcher above with a stub that
    // records and fires nothing, and a drawer that "counts" by firing a row's
    // action becomes invisible to the FINGERPRINT (nothing mutates, so nothing
    // moves). MEASURED: that mutation does not go green, because this line
    // catches it independently — the drawer fired at all, and no frame may.
    //
    // Both guards are kept. The fingerprint is what catches a drawer that
    // mutates the mesh by some other route; this line is what catches one that
    // goes through the delegate. A real dispatcher is still load-bearing for
    // verification C below, which asserts the click reached the ACTION and not
    // merely the delegate.
    assert(rig.fired.length == 0, "no frame may fire a command by itself");

    // …and in the NO-EDIT-TARGET state, which this panel's own `-` button can
    // produce and in which a wrong guard is a fault rather than a wrong number.
    Document empty;
    auto a = new Layer; a.name = "A";
    auto b = new Layer; b.name = "B";
    empty.layers = [a, b];
    assert(empty.primary is null && !empty.hasEditTarget());
    StatExpand e2;
    foreach (t; [SelType.Vertex, SelType.Edge, SelType.Polygon, SelType.Item])
        e2.section[cast(size_t) t] = true;
    auto ui2 = openPanel(() {
        drawStatisticsBody(&empty, SelType.Item, e2, null);
    }, "Statistics2");
    scope (exit) ui2.close();
    foreach (i; 0 .. 2) ui2.frame();     // must not fault
}

// ---------------------------------------------------------------------------
// C — a real click on a leaf row's `+` reaches THAT row's action.
// ---------------------------------------------------------------------------
unittest {
    auto rig = makeRig();
    rig.exp.category["Polygons/By Vertex"] = true;
    rig.mesh().clearFaceSelection();

    const bool prevTestMode = g_testMode;
    g_testMode = true;                  // the drawn record is --test-gated
    scope (exit) g_testMode = prevTestMode;

    auto ui = openPanel(() {
        drawStatisticsBody(&rig.doc, rig.current, rig.exp, rig.runner());
    }, "Statistics");
    scope (exit) ui.close();

    ui.frame();                          // settle the layout and publish a frame

    // Find the drawn row we mean to press, BY THE RECORD the frame published —
    // so the index is the one the panel actually drew, not one this test
    // assumed. Row 0 of the harness's grid is the column-header line.
    auto rows = drawnStatRows();
    assert(rows.length > 0, "the frame must have recorded its rows");
    size_t target = size_t.max;
    string wantCmd;
    foreach (i, ref r; rows) {
        if (r.level != "leaf" || r.label != "4") continue;
        if (!r.hasActions || !r.actionsEnabled) continue;
        target  = i + 1;                 // +1 for the header line
        wantCmd = r.addCommand;
        break;
    }
    assert(target != size_t.max, "the Polygons → By Vertex → 4 row must be drawn");
    assert(wantCmd == "select.byStat.polygon", wantCmd);

    ui.pressRow(target);                 // asserts SOME item took ActiveId
    ui.release();

    assert(rig.fired.length == 1,
        "exactly one command fired, got " ~ rig.fired.length.to!string
        ~ (rig.fired.length ? (" :: " ~ rig.fired[0]) : ""));
    assert(rig.fired[0].canFind("select.byStat.polygon"), rig.fired[0]);
    assert(rig.fired[0].canFind(`"compare":"equal","value":4`), rig.fired[0]);
    assert(rig.fired[0].canFind(`"mode":"add"`),
        "the FIRST column is `+`, i.e. mode:add — " ~ rig.fired[0]);

    // …and it did what that row says: the six quads are now selected.
    assert(rig.mesh().countSelectedFaces() == 6,
        "the click must reach the ACTION, not just the delegate: "
        ~ rig.mesh().countSelectedFaces().to!string);
}
