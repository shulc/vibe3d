// Task 4061 review — INVALIDATION PATH 6 of 6: the seat-moving mutators,
// `selectItem` and `setPrimary`.
//
// `setPrimary` HAS NO OTHER GUARD SINCE THIS REVIEW. The memo used to carry a
// third key term, the front-seat stamp `selSeatFront_`, which `setPrimary` and
// `latchEditTarget` move. It was dropped: both functions already invalidate on
// the line above the move, so the term could never be the reason a memo was
// dropped — a key term that cannot fire is a key term nobody can test. Dropping
// it makes the explicit call the sole guard, which is why these cells exist.
//
// MUTATIONS, one cell each:
//   * cell (a) — delete `invalidatePrimaryMemo()` from `selectItem`.
//   * cell (b) — delete it from `setPrimary`. Cell (a) stays green in that run.
module tests.unit.primary_memo_select_test;

// --- cell (a): selectItem replaces the current selection --------------------
unittest {
    import document;
    import seltype : SelMode;
    import tests.unit.primary_memo_fixture : layeredDocument;

    auto doc = layeredDocument(4);
    auto a = doc.layers[1], b = doc.layers[2];

    doc.selectItem(a, SelMode.Set);
    assert(doc.primary is a, "setup (and the memo warms here): a is the target");

    auto blockBefore = doc.layers.ptr;
    doc.selectItem(b, SelMode.Set);
    assert(doc.layers.ptr is blockBefore, "cell premise: no list slot moved");

    assert(doc.primary is b,
        "an exclusive select moves the edit target, and nothing about the "
      ~ "layer LIST changes when it does");
}

// --- cell (b): setPrimary re-seats at the FRONT -----------------------------
unittest {
    import document;
    import seltype : SelMode;
    import tests.unit.primary_memo_fixture : layeredDocument;

    auto doc = layeredDocument(4);
    auto a = doc.layers[1], b = doc.layers[2];

    doc.selectItem(a, SelMode.Set);
    doc.selectItem(b, SelMode.Add);
    assert(a.selected && b.selected, "population floor: both are selected");
    assert(doc.primary is a,
        "setup (and the memo warms here): an ADD never promotes — the queue "
      ~ "HEAD keeps the target, so the answer is still the earlier seat");

    auto blockBefore = doc.layers.ptr;
    doc.setPrimary(b);
    assert(doc.layers.ptr is blockBefore, "cell premise: no list slot moved");

    assert(doc.primary is b,
        "setPrimary re-seats at the FRONT of the queue, which is the one "
      ~ "affordance that moves the target without changing the selected SET");
}
