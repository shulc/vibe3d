// Task 4061 review — INVALIDATION PATHS 3 and 4 of 6: layer REORDER, and the
// in-place permutation the pointer key cannot see.
//
// WHY ORDER MATTERS AT ALL, and it is not obvious: the walk breaks ties on
// `selSeat` by `layers` INDEX (`nthEditTargetCandidate`'s own doc comment says
// so — without the tie-break two seat-equal candidates would be mutually
// unordered). So a pure reorder, which touches no selection state whatsoever,
// can move the edit target. The review measured that deleting
// `noteLayerListChanged()` from `LayerReorder.moveLayer` left the module lane
// green at 473: there was no cell here at all.
//
// A CUBE-SHAPED TRAP AVOIDED. Every layer in the fixture carrying a DISTINCT
// seat would make this cell pass under every candidate rule, because the seat
// alone would decide and the tie-break would never run. The two candidates
// below are given the SAME seat on purpose; the array index is then the only
// thing that can pick between them, which is precisely the term a reorder
// moves.
//
// The two cells redden under two DIFFERENT mutations and are ordered so one
// run buys both halves:
//   * cell (a) is guarded by the memo's `(block, length)` key — the reorder is
//     two slice reconcatenations, so the block moves. It reddens under M1
//     (`primary()` compares only `primaryMemoValid_`, `noteLayerListChanged()`
//     emptied).
//   * cell (b) holds the block and the length CONSTANT and asserts it, so the
//     key is blind by construction and the belt is the only guard left. It
//     reddens under M2 (`noteLayerListChanged()` emptied, key intact) — under
//     which cell (a) above it stays green, which is the same run's evidence
//     that the key really does carry the reorder on its own.
module tests.unit.primary_memo_order_test;

// --- cell (a): the real `layer.reorder` command moves the tie-break ---------
unittest {
    import commands.layer.commands : LayerReorder;
    import document;
    import editmode : EditMode;
    import tests.unit.primary_memo_fixture : layeredDocument, setIntParam;
    import view : View;

    auto doc = layeredDocument(4);

    // Assemble a seat TIE by direct field write — the same mid-assembly shape
    // several loaders and three `revert()` paths use, and the reason the walk
    // documents a tie-break in the first place.
    doc.layers[0].selected = false;
    auto a = doc.layers[1], b = doc.layers[2];
    a.selected = true;  a.selSeat = 5;
    b.selected = true;  b.selSeat = 5;

    assert(a.selSeat == b.selSeat,
        "cell premise: the two candidates are seat-tied, so ONLY the array "
      ~ "index can decide between them");
    assert(doc.primary is a,
        "setup (and the memo warms here): the lower index wins the tie");

    auto view    = new View(0, 0, 800, 600);
    auto reorder = new LayerReorder(doc.activeMesh(), view, EditMode.Vertices,
                                    &doc, null);
    setIntParam(reorder, "from", 1);   // move `a` to the back, past `b`
    setIntParam(reorder, "to",   3);
    assert(reorder.apply(), "setup: the reorder must apply");
    assert(doc.layers[1] is b && doc.layers[3] is a,
        "population floor: the reorder really did move both candidates");

    assert(doc.primary is b,
        "a reorder moves the edit target through the tie-break, with no "
      ~ "selection state touched at all — the memo must not survive it");
}

// --- cell (b): an in-place permutation, which the pointer key cannot see ----
unittest {
    import document;
    import tests.unit.primary_memo_fixture : layeredDocument;

    auto doc = layeredDocument(4);
    doc.layers[0].selected = false;
    auto a = doc.layers[1], b = doc.layers[2];
    a.selected = true;  a.selSeat = 5;
    b.selected = true;  b.selSeat = 5;

    assert(doc.primary is a, "setup: the memo warms holding the lower index");

    // Swap two SLOTS. No append, no reconcatenation, no truncation: there is
    // no such write in the tree today, and this cell is the reason
    // `noteLayerListChanged()` is kept after the key made the other 21 sites
    // redundant.
    auto blockBefore = doc.layers.ptr;
    auto lenBefore   = doc.layers.length;
    auto tmp = doc.layers[1];
    doc.layers[1] = doc.layers[2];
    doc.layers[2] = tmp;
    assert(doc.layers.ptr is blockBefore && doc.layers.length == lenBefore,
        "cell premise: an in-place permutation moves NEITHER the array block "
      ~ "nor its length — if this ever fails the cell has stopped testing the "
      ~ "belt and started testing the key");
    assert(doc.layers[1] is b && doc.layers[2] is a,
        "population floor: the swap really did exchange the two candidates");

    doc.noteLayerListChanged();
    assert(doc.primary is b,
        "the list-changed note is the ONLY guard against an in-place "
      ~ "permutation: the (block, length) key is provably blind to it");
}
