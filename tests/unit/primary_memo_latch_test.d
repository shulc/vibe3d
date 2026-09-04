// Task 4061 review — `latchEditTarget`, `setActive`, and the DERIVATION RATE
// this task exists for.
//
// The rate pin sits LAST on purpose. It is the only cell in the six modules
// that reddens when the memo is REMOVED rather than when an invalidation is,
// so the correctness cells above it must be green for its run to mean
// anything — and they are, in the same run, by control flow: to reach a red on
// the last block, execution had to clear every straight-line assert above it.
//
// MUTATIONS, one cell each:
//   * cell (a) — delete `invalidatePrimaryMemo()` from `latchEditTarget`.
//   * cell (b) — delete it from `setActive`.
//   * cell (c) — replace `primary()`'s body with `nthEditTargetCandidate(0)`.
module tests.unit.primary_memo_latch_test;

// --- cell (a): latchEditTarget seats a DESELECTED member at the front -------
unittest {
    import document;
    import seltype : SelMode;
    import tests.unit.primary_memo_fixture : layeredDocument;

    auto doc = layeredDocument(4);
    auto a = doc.layers[1], c = doc.layers[3];

    doc.selectItem(a, SelMode.Set);
    doc.clearItemSelection();
    assert(!a.selected, "population floor: nothing is selected any more");
    assert(doc.primary is a,
        "setup (and the memo warms here): an emptied selection still has an "
      ~ "edit target — a mesh in the history bucket is still the target");

    auto blockBefore = doc.layers.ptr;
    doc.latchEditTarget(c);
    assert(doc.layers.ptr is blockBefore, "cell premise: no list slot moved");

    assert(doc.primary is c,
        "latching seats an unselected member at the FRONT of the history "
      ~ "queue, so it outranks the layer that was latched before it");
}

// --- cell (b): setActive ----------------------------------------------------
unittest {
    import document;
    import tests.unit.primary_memo_fixture : layeredDocument;

    auto doc = layeredDocument(4);
    assert(doc.primary is doc.layers[0],
        "setup (and the memo warms here): bootstrap seats layer 0");

    auto blockBefore = doc.layers.ptr;
    doc.setActive(2);
    assert(doc.layers.ptr is blockBefore, "cell premise: no list slot moved");

    assert(doc.primary is doc.layers[2],
        "setActive is an exclusive select and must move the edit target");
}

// --- cell (c): the derivation RATE, which is why the memo exists ------------
unittest {
    import document;
    import document_selection : g_editTargetDerives, resetEditTargetDerives;
    import seltype : SelMode;
    import std.format : format;
    import tests.unit.primary_memo_fixture : layeredDocument;

    auto doc = layeredDocument(8);
    doc.selectItem(doc.layers[3], SelMode.Set);
    doc.selectItem(doc.layers[1], SelMode.Add);
    doc.selectItem(doc.layers[6], SelMode.Add);
    auto head = doc.layers[3];
    assert(doc.primary is head, "setup: a stable multi-selected document");

    // A FRAME-SHAPED WINDOW: no mutation at all between the reads, which is
    // what a render frame does — the live measurement in the card's log counted
    // 78 derivations per frame over exactly this shape.
    resetEditTargetDerives();
    size_t reads = 0;
    foreach (_; 0 .. 30) {
        assert(doc.primary is head, "the answer is stable across the window");
        ++reads;
    }
    assert(reads == 30,
        "population floor: 30 reads really happened — a rate assertion over an "
      ~ "empty loop is vacuously true");

    assert(g_editTargetDerives <= 1,
        format("edit-target derivations in a mutation-free window: expected "
             ~ "<= 1 for %d reads, got %d", reads, g_editTargetDerives));
}
