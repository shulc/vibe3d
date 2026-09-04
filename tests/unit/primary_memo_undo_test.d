// Task 4061 review — INVALIDATION PATH 2 of 6: the layer-delete REVERT path.
//
// THE MASKED PAIR the review found lives here. `LayerDelete.revertImpl` does
// two things that each invalidate: it reinserts the layer (`noteLayerListChanged`)
// and then restores the selection snapshot (`restoreItemSelection`, which
// invalidates explicitly). Deleting EITHER call alone left the whole module
// lane green, so neither was individually witnessed and the card's claim that
// every site was armed was true of one site out of four.
//
// This cell is the revert half. Its guard after the fix is the memo's
// `(block, length)` key — the reinsert is `layers[0 .. i] ~ removed ~
// layers[i .. $]`, a fresh, longer array. The `restoreItemSelection` half is
// witnessed on its own, with no list change in sight, in
// `tests/unit/primary_memo_restore_test.d`; that is what un-masks the pair.
//
// WHY A THIRD SELECTION SITS BETWEEN THE DELETE AND THE UNDO, and it is the
// difference between a cell that discriminates and one that cannot: the state
// the undo restores is the state that existed BEFORE the delete. If the memo
// were warmed on that same state and never invalidated, it would answer the
// restored value by luck and this cell would pass over a memo that had stopped
// working entirely — the "fixture cannot exhibit the phenomenon" shape. So the
// memo is deliberately re-warmed on a DIFFERENT layer in between, which the
// undo must then move away from.
//
// MUTATION (M1): `primary()` compares only `primaryMemoValid_` and
// `noteLayerListChanged()` is emptied. The final assertion reddens.
module tests.unit.primary_memo_undo_test;

unittest {
    import commands.layer.commands : LayerDelete;
    import document;
    import editmode : EditMode;
    import seltype  : SelMode;
    import tests.unit.primary_memo_fixture : layeredDocument;
    import view : View;

    auto doc = layeredDocument(8);
    doc.selectItem(doc.layers[3], SelMode.Set);
    doc.selectItem(doc.layers[1], SelMode.Add);
    doc.selectItem(doc.layers[6], SelMode.Add);
    auto head = doc.layers[3];

    auto view = new View(0, 0, 800, 600);
    auto del  = new LayerDelete(doc.activeMesh(), view, EditMode.Vertices,
                                &doc, null);
    del.setIndex(3);
    assert(del.apply(), "setup: the layer delete must apply");
    assert(doc.layers.length == 7, "population floor: one layer was removed");

    // Re-warm the memo on a layer the undo will have to move AWAY from.
    auto decoy = doc.layers[5];
    doc.selectItem(decoy, SelMode.Set);
    assert(doc.primary is decoy,
        "setup (and the memo warms here): an exclusive select after the "
      ~ "delete, so the value the memo holds is NOT the one the undo restores");

    assert(del.revert(), "setup: the undo of the delete must succeed");
    assert(doc.layers.length == 8,
        "population floor: the undo reinserted exactly the one layer, so the "
      ~ "assertion below is made over a list that really changed");
    assert(doc.layers[3] is head, "setup: the layer came back at its own index");

    assert(doc.primary is head,
        "undo must hand the edit target back to the restored layer — the "
      ~ "target is derived from the selection state the snapshot restored, "
      ~ "so a memo that outlived the undo keeps answering the decoy");
}
