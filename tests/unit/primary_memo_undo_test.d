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
// MUTATION (M1): `primary()` compares only `primaryMemoValid_` and
// `noteLayerListChanged()` is emptied. This cell reddens.
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
    auto head   = doc.layers[3];
    auto nextUp = doc.layers[1];

    auto view = new View(0, 0, 800, 600);
    auto del  = new LayerDelete(doc.activeMesh(), view, EditMode.Vertices,
                                &doc, null);
    del.setIndex(3);
    assert(del.apply(), "setup: the layer delete must apply");
    assert(doc.layers.length == 7, "population floor: one layer was removed");

    // WARM THE MEMO on the POST-DELETE answer, so the undo below has a stale
    // value to be caught holding. Warming before the delete instead would test
    // the delete path over again and say nothing about the revert.
    assert(doc.primary is nextUp, "setup: the delete moved the target");

    assert(del.revert(), "setup: the undo of the delete must succeed");
    assert(doc.layers.length == 8,
        "population floor: the undo reinserted exactly the one layer, so the "
      ~ "assertion below is made over a list that really changed back");
    assert(doc.layers[3] is head, "setup: the layer came back at its own index");

    assert(doc.primary is head,
        "undo must hand the edit target back to the restored layer — the "
      ~ "target is derived from the selection state the snapshot restored, "
      ~ "so a memo that outlived the undo answers the successor forever");
}
