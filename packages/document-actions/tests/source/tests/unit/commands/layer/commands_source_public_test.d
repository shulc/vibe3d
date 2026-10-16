module tests.unit.commands.layer.commands_source_public_test;

import document : Document, Layer, ItemKind;
import commands.layer.commands : layerDeleteButtonState;
import vibe3d.editing.contracts.seltype : SelMode;

unittest {
    import mesh : makeCube;

    auto doc = Document.bootstrap(makeCube());
    auto meshA = doc.layers[0];

    auto added = new Layer;
    added.name    = "Empty";
    added.kind    = ItemKind.Empty;
    added.visible = true;
    doc.layers ~= added;
    doc.setActive(doc.layers.length - 1);   // mirrors LayerAdd.apply()'s doc.setActive(addedIndex)

    // TASK 0668 inverts every row below. `setActive` is an exclusive select,
    // and an exclusive select of a kind that cannot be primary now clears the
    // edit target instead of sparing it. This shape is not user-reachable
    // through `layer.add` itself (no `kind` param, per the header above) — but
    // it IS the shape `imagePlane.add` and `layer.duplicate` reach, so the
    // formula is worth pinning here where the call site is isolated.
    assert(doc.primary is meshA,
        "§L2 as amended by 0671: `setActive` onto a non-mesh target leaves the "
        ~ "mesh edit target LATCHED — 0668's `is null` is what this task undoes");
    assert(!meshA.selected,
        "…and the mesh is dropped from the SELECTION, not spared: 0668's half "
        ~ "of the answer is unchanged, and it is what matches the reference's set");
    assert(doc.foreground(meshA) && !doc.background(meshA),
        "…so it stays FOREGROUND — an item that is still being edited must not "
        ~ "derive as a dimmed, read-only, snappable background layer");
    assert(doc.focusedItem is added, "§L2 (LayerAdd): focus moves to the new item");
    {
        size_t selCount = 0;
        foreach (l; doc.layers) if (l.selected) ++selCount;
        assert(selCount == 1,
            "§L2/0668 (LayerAdd): the selected set is exactly {target}, size 1");
    }
}

unittest {
    import mesh : makeCube;

    auto doc = Document.bootstrap(makeCube());
    auto meshA = doc.layers[0];
    auto meshB = new Layer; meshB.name = "MeshB"; meshB.meshRef() = makeCube();
    auto empty = new Layer; empty.name = "Empty"; empty.kind = ItemKind.Empty;
    doc.layers ~= meshB;
    doc.layers ~= empty;

    doc.selectItem(empty, SelMode.Set);          // a plain CLICK
    assert(doc.primary is meshA, "0671: the plain click leaves the mesh latched");
    assert(doc.activeIndex == 0, "…so activeIndex names MeshA, not the clicked row");
    assert(!meshA.selected && !meshB.selected,
        "…and neither mesh is left in the SELECTION");

    auto state = layerDeleteButtonState(&doc);
    assert(state.index == doc.indexOf(empty),
        "the Delete button targets the FOCUSED row, which is NOT the edit "
        ~ "target here — a formula reading `activeIndex` deletes MeshA");
    assert(state.index != doc.activeIndex,
        "…and the two really are different rows in this state, so the row "
        ~ "above is discriminating rather than incidentally equal");
}
