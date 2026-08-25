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
//   C. A CLICK ON A ROW'S `+` REACHES THAT ROW'S ACTION — AND A CLICK ON ITS
//      `-` REACHES THE OTHER ONE. `/api/stats` reports labels and numbers; it
//      says nothing about which command a cell is wired to. This presses the
//      real widget, in BOTH columns: the version of this file that pressed only
//      at a fixed inset landed inside the first button every time, so a minus
//      cell wired to the add arguments would have stayed green through the whole
//      suite (the drawn record's remove arguments come from the model, and the
//      HTTP test fires the remove command itself rather than through the
//      widget). Measured — that mutation was applied and this file reddened.
//
//   D. A DISABLED ROW'S TOOLTIP IS ACTUALLY EMITTED. `reason` in the drawn
//      record is copied from the model, so it says a tip EXISTS, not that one
//      was drawn; `DrawnStatRow.tipShown` is written from the hover query
//      itself. Both action cells are hovered, because the query is per-item.
//
//   E. THE COLUMN HEADERS SIT OVER THEIR COLUMNS. The row records where each
//      numeric slot began, the header record does the same, and this compares
//      them — the one relationship no row-model assertion can express.

import command   : Command, g_testMode;
import document  : Document, Layer;
import editmode  : EditMode;
import mesh;
import mesh_edit_delta : MeshEditTracker, MeshEditScope;
import seltype   : SelType, SelMode;
import ui.panels : drawStatisticsBody;
import ui.stat_rows;
import ui.stat_record : drawnStatRows, drawnStatFrame;
import tests.unit.ui.headless_panel : HeadlessPanel, openPanel;
import tests.unit.ui.stat_dispatch  : dispatchStatAction;
import std.algorithm : canFind;
import std.conv : to;
import std.math : abs;

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
    f.pendingChanges       = mm.undeliveredChanges_;
    f.pendingSelDomains    = mm.undeliveredSelDomains_;
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

    // The action cell's DRAWN width, read from the frame record. A constant
    // here would rot with the font — and 0 here is what made the second column
    // untested for the whole of stage 4.
    immutable float actionW = drawnStatFrame().actionW;
    assert(actionW > 12.0f,
        "the frame must publish its action-cell width, got " ~ actionW.to!string);

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

    // ---- THE SECOND COLUMN, pressed where it actually is ------------------
    // `+6` past the first cell's right edge, i.e. inside the `-` cell. Nothing
    // in this file pressed here before, so nothing checked that the minus
    // button carries the REMOVE arguments rather than a copy of the add ones.
    ui.pressRowAt(target, actionW);
    ui.release();

    assert(rig.fired.length == 2,
        "the second press must fire exactly one more command, got "
        ~ rig.fired.length.to!string);
    assert(rig.fired[1].canFind("select.byStat.polygon"), rig.fired[1]);
    assert(rig.fired[1].canFind(`"compare":"equal","value":4`), rig.fired[1]);
    assert(rig.fired[1].canFind(`"mode":"remove"`),
        "the SECOND column is `-`, i.e. mode:remove — " ~ rig.fired[1]);
    assert(!rig.fired[1].canFind(`"mode":"add"`), rig.fired[1]);

    // …and by value: the six quads it just selected are deselected again.
    assert(rig.mesh().countSelectedFaces() == 0,
        "the `-` click must reach the REMOVE action: "
        ~ rig.mesh().countSelectedFaces().to!string);
}

// ---------------------------------------------------------------------------
// D — a disabled row's reason is a TOOLTIP THE SCREEN DRAWS, in both cells.
//
// The mistake this catches is small and completely silent: `IsItemHovered()`
// with no flags is false for a disabled item, so every unmeasured,
// structural-zero and inert row carries a reason string no user can read, while
// the model — and therefore `/api/stats` — reports one.
//
// What it does NOT catch, said plainly because the review predicted otherwise
// and the mutation disagreed: moving the query inside the `BeginDisabled`
// bracket. That comes back GREEN — `IsItemHovered` reads the flag state
// captured when the button was submitted, not the current stack. This file
// pins the FLAG and the per-cell query; the bracket is style, not behaviour.
// ---------------------------------------------------------------------------
unittest {
    auto rig = makeRig();
    rig.exp.category["Polygons/By Type"] = true;

    const bool prevTestMode = g_testMode;
    g_testMode = true;
    scope (exit) g_testMode = prevTestMode;

    auto ui = openPanel(() {
        drawStatisticsBody(&rig.doc, rig.current, rig.exp, rig.runner());
    }, "Statistics");
    scope (exit) ui.close();

    ui.frame();

    // Guarded, because the `-` hover below offsets by exactly this: at 0 the
    // second probe would repeat the first and pass without testing anything.
    immutable float actionW = drawnStatFrame().actionW;
    assert(actionW > 12.0f,
        "the frame must publish its action-cell width, got " ~ actionW.to!string);
    auto rows = drawnStatRows();
    size_t target = size_t.max;
    string wantReason;
    foreach (i, ref r; rows) {
        // A row with buttons that are NOT clickable — the only kind that has a
        // tooltip to show at all.
        if (!r.hasActions || r.actionsEnabled || r.reason.length == 0) continue;
        target     = i + 1;              // +1 for the header line
        wantReason = r.reason;
        break;
    }
    assert(target != size_t.max,
        "the fixture must draw at least one disabled row with a reason");

    // Nothing is hovered yet, so nothing may claim to have drawn a tip.
    foreach (ref r; rows)
        assert(!r.tipShown, "no tip without a pointer on the row: " ~ r.label);

    // ---- the `+` cell ----
    ui.hoverRowAt(target, 0.0f);
    ui.frame();                          // one settled frame under the pointer
    auto hovered = drawnStatRows();
    assert(hovered.length >= target, "the frame must still record its rows");
    assert(hovered[target - 1].reason == wantReason,
        "row addressing moved: " ~ hovered[target - 1].label);
    assert(hovered[target - 1].tipShown,
        "a disabled row must DRAW its reason when hovered: "
        ~ hovered[target - 1].label ~ " / " ~ wantReason);

    // …and exactly that row, not the panel at large.
    size_t shown = 0;
    foreach (ref r; hovered) if (r.tipShown) ++shown;
    assert(shown == 1, "exactly one row shows a tip, got " ~ shown.to!string);

    // ---- the `-` cell: a SECOND query, over a second `BeginDisabled` ----
    ui.hoverRowAt(target, actionW);
    ui.frame();
    auto hovered2 = drawnStatRows();
    assert(hovered2[target - 1].tipShown,
        "the second action cell must show the reason too: "
        ~ hovered2[target - 1].label);

    // ---- and a LIVE row shows none: the tip belongs to the disabled state ----
    size_t liveRow = size_t.max;
    foreach (i, ref r; rows)
        if (r.hasActions && r.actionsEnabled) { liveRow = i + 1; break; }
    assert(liveRow != size_t.max, "the fixture must draw a live row too");
    ui.hoverRowAt(liveRow, 0.0f);
    ui.frame();
    foreach (ref r; drawnStatRows())
        assert(!r.tipShown, "a live row has no tip: " ~ r.label);
}

// ---------------------------------------------------------------------------
// E — the column HEADERS sit over the columns they name.
//
// The drawn record used to begin after the header line, so the header's own
// geometry was the one part of this panel nothing could see. It shipped wrong:
// "Name" was followed by a spacer of the FULL name-column width (advancing by
// the width of the word more than the column), and "Sel" by an arbitrary
// quarter-of-Num pad, so both titles sat to the right of their columns while the
// widths above were being recomputed FROM them.
// ---------------------------------------------------------------------------
unittest {
    auto rig = makeRig();
    rig.exp.category["Polygons/By Vertex"] = true;

    const bool prevTestMode = g_testMode;
    g_testMode = true;
    scope (exit) g_testMode = prevTestMode;

    auto ui = openPanel(() {
        drawStatisticsBody(&rig.doc, rig.current, rig.exp, rig.runner());
    }, "Statistics");
    scope (exit) ui.close();

    ui.frame();

    auto hdr  = drawnStatFrame();
    auto rows = drawnStatRows();
    assert(rows.length > 0);
    assert(hdr.numX > 0 && hdr.selX > hdr.numX,
        "the header must publish its two slot origins");

    // EVERY row, because a column is a property of the whole table: the section
    // rows, the indented categories and the twice-indented leaves all end their
    // name column at the same x, and the header must land on it too.
    foreach (ref r; rows) {
        assert(abs(r.numX - hdr.numX) < 0.5f,
            "the Num header is not over the Num column: header " ~ hdr.numX.to!string
            ~ " vs row '" ~ r.label ~ "' " ~ r.numX.to!string);
        assert(abs(r.selX - hdr.selX) < 0.5f,
            "the Sel header is not over the Sel column: header " ~ hdr.selX.to!string
            ~ " vs row '" ~ r.label ~ "' " ~ r.selX.to!string);
    }
}
