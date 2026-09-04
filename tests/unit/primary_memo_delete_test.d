// Task 4061 review — INVALIDATION PATH 1 of 6: the layer-DELETE apply path.
//
// `layer.delete` splices the edit target out of `layers`. If the memo does not
// notice, `primary` answers a `Layer` that is NOT a member any more — the very
// state `document_selection.d`'s deleted-`rehomePrimary` comment used to say
// had no representation. Commands bind a `Mesh*` off that answer, so nothing
// catches it; it is dereferenced.
//
// WHAT GUARDS IT: the memo's `(block, length)` key. The splice is
// `layers[0 .. i] ~ layers[i+1 .. $]`, a fresh allocation of a shorter array,
// so both terms move. `noteLayerListChanged()` is called too and is a belt.
//
// MUTATION (M1): make `primary()` compare only `primaryMemoValid_` and empty
// `noteLayerListChanged()`'s body — i.e. the memo stops noticing list changes
// at all. This cell reddens.
module tests.unit.primary_memo_delete_test;

unittest {
    import commands.layer.commands : LayerDelete;
    import document;
    import editmode : EditMode;
    import seltype  : SelMode;
    import tests.unit.primary_memo_fixture : layeredDocument;
    import view : View;

    auto doc = layeredDocument(8);

    // Multi-select in the order 3 → 1 → 6. The edit target is the OLDEST
    // current seat, so it is layers[3] and not the newest touch — a cell that
    // selected one layer could not tell a stale memo from a correct answer.
    doc.selectItem(doc.layers[3], SelMode.Set);
    doc.selectItem(doc.layers[1], SelMode.Add);
    doc.selectItem(doc.layers[6], SelMode.Add);
    auto head    = doc.layers[3];
    auto nextUp  = doc.layers[1];

    // WARM THE MEMO. Without this read the cell would exercise a cold memo and
    // pass whatever the invalidation does — the "check that runs at the wrong
    // moment" shape. Everything after this point is judged against a memo that
    // is already holding `head`.
    assert(doc.primary is head,
        "setup: the oldest current seat heads the walk, not the newest touch");

    auto view = new View(0, 0, 800, 600);
    auto del  = new LayerDelete(doc.activeMesh(), view, EditMode.Vertices,
                                &doc, null);
    del.setIndex(3);
    assert(del.apply(), "setup: the layer delete must apply");
    assert(doc.layers.length == 7,
        "population floor: the delete removed exactly one layer, so the "
      ~ "assertions below are made over a list that really changed");

    bool stillAMember = false;
    foreach (l; doc.layers) if (l is head) stillAMember = true;
    assert(!stillAMember, "setup: the deleted layer left the list");

    assert(doc.primary !is head,
        "a spliced-out layer must never come back as the edit target: "
      ~ "commands bind a Mesh* off this answer");
    assert(doc.primary is nextUp,
        "after the head is deleted the next current seat becomes the target");
}
