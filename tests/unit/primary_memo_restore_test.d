// Task 4061 review — INVALIDATION PATH 5 of 6: `restoreItemSelection`, plus
// `resetSelectionState` beside it.
//
// `restoreItemSelection` is the un-masking cell. In production it is reached
// through `LayerDelete.revertImpl` / `LayerDuplicate.revertImpl`, both of
// which reinsert into `layers` FIRST — so the list key has already dropped the
// memo by the time the restore runs, and deleting the restore's own
// `invalidatePrimaryMemo()` changes nothing observable there. That is why the
// review could delete it and stay green at 473 modules. Here the restore is
// called DIRECTLY, with the array untouched between the warm read and the
// assertion, so the explicit invalidation is the only guard in the frame.
//
// MUTATIONS, one cell each:
//   * cell (a) — delete `invalidatePrimaryMemo()` from `restoreItemSelection`.
//   * cell (b) — delete it from `resetSelectionState` (cell (a) above stays
//     green in that run, which is the run's own evidence that the two calls
//     are independent).
module tests.unit.primary_memo_restore_test;

// --- cell (a): restoreItemSelection, with no list mutation in the frame -----
unittest {
    import document;
    import seltype : SelMode;
    import tests.unit.primary_memo_fixture : layeredDocument;

    auto doc = layeredDocument(4);
    auto a = doc.layers[1], b = doc.layers[2];

    doc.selectItem(a, SelMode.Set);
    assert(doc.primary is a, "setup: a is the edit target");
    auto snapshot = doc.captureItemSelection();

    doc.selectItem(b, SelMode.Set);
    assert(doc.primary is b, "setup (and the memo warms here): b took over");

    auto blockBefore = doc.layers.ptr;
    auto lenBefore   = doc.layers.length;
    doc.restoreItemSelection(snapshot);
    assert(doc.layers.ptr is blockBefore && doc.layers.length == lenBefore,
        "cell premise: the restore touched no list SLOT, so the memo's "
      ~ "(block, length) key cannot be what saves this — in production this "
      ~ "call always follows a reinsert, which is what masked it");

    assert(doc.primary is a,
        "restoring the captured selection state must restore the edit target "
      ~ "derived from it");
}

// --- cell (b): resetSelectionState empties the answer ----------------------
unittest {
    import document;
    import seltype : SelMode;
    import tests.unit.primary_memo_fixture : layeredDocument;

    auto doc = layeredDocument(4);
    doc.selectItem(doc.layers[2], SelMode.Set);
    assert(doc.primary is doc.layers[2],
        "setup (and the memo warms here): a non-null edit target");

    auto blockBefore = doc.layers.ptr;
    doc.resetSelectionState();
    assert(doc.layers.ptr is blockBefore,
        "cell premise: the reset touched no list slot");

    assert(doc.primary is null,
        "a reset selection state leaves NO edit target — a memo that outlives "
      ~ "it hands out a layer nothing selects");
}
