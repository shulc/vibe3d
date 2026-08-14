// Module unittests for `ui.item_rows`, moved verbatim out of source/ui/item_rows.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ui.item_rows_test;

import document : Document, Layer, ItemKind, kindInfo;
import mesh     : makeCube;
import seltype  : SelMode;
import ui.item_rows;

// ---------------------------------------------------------------------------
// I1 — the list is the scene root plus the SCENE ITEMS, carrying the DOCUMENT
// index.
//
// Discriminating four ways at once: the count (a root-less implementation
// reads 4, a resource-blind one reads 6), which row is the root, per-row
// identity (`is`, so "some item" cannot pass), and the index (ordinals would
// read 1/2/3/4 where the layers are 0/2/3/4).
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;
    auto f = makeItemFixture();
    assert(f.doc.layers.length == 6, "fixture: 4 scene items + 2 resources");

    ItemRow[] rows;
    itemRowsInto(&f.doc, "", false, true, rows);

    assert(rows.length == 5,
        "the root plus the four SCENE items — an image resource is not a row "
        ~ "here, it lives in the Images list; got " ~ to!string(rows.length));

    assert(rows[0].isRoot,      "row 0 is the scene root");
    assert(rows[0].layer is null, "…and it names no layer");
    assert(rows[0].index == kNoLayerIndex,
        "…and no document index; got " ~ to!string(rows[0].index));

    assert(rows[1].layer is f.meshA,  "row 1 is meshA");
    assert(rows[2].layer is f.plane,  "row 2 is the plane");
    assert(rows[3].layer is f.meshB,  "row 3 is meshB");
    assert(rows[4].layer is f.marker, "row 4 is the marker");

    assert(rows[1].index == 0, "carries the LAYER index; got " ~ to!string(rows[1].index));
    assert(rows[2].index == 2, "carries the LAYER index; got " ~ to!string(rows[2].index));
    assert(rows[3].index == 4, "carries the LAYER index; got " ~ to!string(rows[3].index));
    assert(rows[4].index == 5, "carries the LAYER index; got " ~ to!string(rows[4].index));

    // Vacuity guard, and it earns its place: the index axis only
    // discriminates while a row's layer index differs from BOTH numbers a
    // wrong implementation could report — its position in `rows` (root
    // included) and its position among the items (root excluded). Assert that
    // at least one row separates all three, or the equalities above could be
    // satisfied by an ordinal.
    bool separates = false;
    foreach (i, r; rows) {
        if (r.isRoot) continue;
        if (r.index != i && r.index != i - 1) separates = true;
    }
    assert(separates,
        "vacuity guard: no row's layer index differs from both its `rows` "
        ~ "position and its item position — with one interleaved resource "
        ~ "those two shifts cancel and an ordinal-reporting implementation "
        ~ "reads the right number for every row");
    assert(f.doc.layers[1] is f.clipA && f.doc.layers[3] is f.clipB,
        "fixture precondition: BOTH resources really are interleaved, which "
        ~ "is what breaks the cancellation the guard above tests for");
}

// ---------------------------------------------------------------------------
// I2 — the root row names the DOCUMENT, with the unsaved-changes marker.
//
// Discriminating: all four (path × dirty) combinations produce four different
// strings, so a full-path implementation, a marker-less one, and one that put
// the marker in FRONT (the window title's form) each read differently.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeItemFixture();
    ItemRow[] rows;

    itemRowsInto(&f.doc, "", false, true, rows);
    assert(rows[0].name == "untitled",
        "a document that was never saved; got '" ~ rows[0].name ~ "'");

    itemRowsInto(&f.doc, "", true, true, rows);
    assert(rows[0].name == "untitled*",
        "…and the marker is appended, not prepended — '*untitled' is the "
        ~ "window title's form and would break the name column's left edge; "
        ~ "got '" ~ rows[0].name ~ "'");

    immutable p = "/home/somebody/scenes/dragon.v3d";
    itemRowsInto(&f.doc, p, false, true, rows);
    assert(rows[0].name == "dragon.v3d",
        "the BASE NAME, not the path — a path pushes the identifying part "
        ~ "off the right edge; got '" ~ rows[0].name ~ "'");

    itemRowsInto(&f.doc, p, true, true, rows);
    assert(rows[0].name == "dragon.v3d*",
        "base name plus marker; got '" ~ rows[0].name ~ "'");

    // The four differ pairwise, which is what makes the assertions above a
    // test of the rule rather than of one branch.
    assert(documentRootName("", false)  != documentRootName("", true));
    assert(documentRootName("", false)  != documentRootName(p, false));
    assert(documentRootName(p, false)   != documentRootName(p, true));

    // A path with no directory part is still the base name, and a trailing
    // separator does not swallow the file.
    assert(documentRootName("scene.v3d", false) == "scene.v3d");
}

// ---------------------------------------------------------------------------
// I3 — indent depth follows the PARENT CHAIN, and a child is drawn under its
// parent.
//
// Discriminating: a constant-depth implementation reads 1 where the chain
// gives 2 and 3; an implementation that indents but leaves rows in `layers`
// order puts the child ABOVE the parent it is indented under (marker is layer
// 4, meshB layer 3, and the chain makes marker meshA's grandchild — so
// document order and tree order disagree on every row).
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;
    auto f = makeItemFixture();
    ItemRow[] rows;

    itemRowsInto(&f.doc, "", false, true, rows);
    foreach (r; rows[1 .. $])
        assert(r.depth == 1,
            "control: with no parents set, every item is top level; got "
            ~ to!string(r.depth));
    assert(rows[0].depth == 0, "the root is depth 0");

    // meshB under meshA, marker under meshB — a two-deep chain.
    f.meshB.parent  = f.meshA;
    f.marker.parent = f.meshB;
    itemRowsInto(&f.doc, "", false, true, rows);

    assert(rows.length == 5, "reparenting moves rows, it does not lose them");
    assert(rows[1].layer is f.meshA  && rows[1].depth == 1,
        "the parent stays at the top level; got depth "
        ~ to!string(rows[1].depth));
    assert(rows[2].layer is f.meshB  && rows[2].depth == 2,
        "the child follows its parent IMMEDIATELY and is one deeper — in "
        ~ "`layers` order meshB is layer 4 and the plane (layer 2) would come "
        ~ "first; got row '" ~ rows[2].name ~ "' at depth "
        ~ to!string(rows[2].depth));
    assert(rows[3].layer is f.marker && rows[3].depth == 3,
        "and the grandchild is two deeper; got row '" ~ rows[3].name
        ~ "' at depth " ~ to!string(rows[3].depth));
    assert(rows[4].layer is f.plane  && rows[4].depth == 1,
        "the unparented plane comes after the whole subtree, still top "
        ~ "level; got row '" ~ rows[4].name ~ "'");

    // An ancestor with NO ROW is walked past, not treated as a parent: the
    // clip is a document resource, so a child of it hangs at the top level
    // rather than vanishing with its unlisted parent.
    f.meshB.parent  = f.clipA;
    f.marker.parent = f.meshB;
    itemRowsInto(&f.doc, "", false, true, rows);
    assert(rows.length == 5, "no row is lost to an unlisted ancestor");
    size_t bi = 0, mi = 0;
    foreach (i, r; rows) {
        if (r.layer is f.meshB)  bi = i;
        if (r.layer is f.marker) mi = i;
    }
    assert(rows[bi].depth == 1,
        "a child of an UNLISTED item hangs at the top level; got "
        ~ to!string(rows[bi].depth));
    assert(rows[mi].depth == 2 && mi == bi + 1,
        "…and its own child is still drawn under IT; got depth "
        ~ to!string(rows[mi].depth) ~ " at row " ~ to!string(mi));
}

// ---------------------------------------------------------------------------
// I4 — the ROLE cell reports the SELECTION, and the first element of it.
//
// Task 0672 rewrote this test with the enum it asserts. It used to require
// `Primary` on the edit target and `Focus` on the focus; the capture found the
// reference draws neither, and the state the owner reported — an unselected
// edit target drawn as selected — is exactly what those two arms produced.
//
// Discriminating, in one fixture, against every wrong reading that survives
// the rewrite:
//
//   * an implementation that still asks `isPrimary` FIRST reads a non-None
//     role on meshA in the second half, where meshA is the latched target and
//     is not selected at all;
//   * one that keys the loud treatment on the edit target reads
//     `SelectedFirst` on meshA rather than on the plane in the D1 half —
//     the plane cannot be an edit target in principle;
//   * one that keys it on the FOCUS reads it on the marker (the newest touch,
//     i.e. the other end of the queue) rather than on meshA;
//   * one that ignores selection ORDER reads the same token on every selected
//     row.
// ---------------------------------------------------------------------------
unittest {
    import seltype : SelMode;
    import std.conv : to;
    auto f = makeItemFixture();
    ItemRow[] rows;

    itemRowsInto(&f.doc, "", false, true, rows);
    assert(rows[1].role == RowRole.SelectedFirst,
        "the baseline: the sole selected item is also the first one; got "
        ~ to!string(rows[1].role));
    foreach (r; rows[2 .. $])
        assert(r.role == RowRole.None,
            "…and nothing else is in the selection; got " ~ to!string(r.role));

    RowRole roleOfLayer(Layer l) {
        foreach (r; rows) if (r.layer is l) return r.role;
        assert(false, "layer has no row");
    }

    // The plane joins the set, then the marker — neither can become the edit
    // target, so the target stays on meshA while the FOCUS moves to the marker.
    f.doc.selectItem(f.plane,  SelMode.Add);
    f.doc.selectItem(f.marker, SelMode.Add);
    itemRowsInto(&f.doc, "", false, true, rows);

    assert(f.doc.focusedItem is f.marker && f.doc.isPrimary(f.meshA),
        "fixture precondition: the focus (newest touch) and the edit target "
        ~ "are on DIFFERENT rows, or 'the role follows neither' is untestable");

    assert(roleOfLayer(f.meshA)  == RowRole.SelectedFirst,
        "the first element of the selection; got " ~ to!string(roleOfLayer(f.meshA)));
    assert(roleOfLayer(f.plane)  == RowRole.Selected, "a later member");
    assert(roleOfLayer(f.marker) == RowRole.Selected,
        "…and so is the FOCUS: it is the NEWEST touch, the opposite end of the "
        ~ "queue from the one the treatment marks; got "
        ~ to!string(roleOfLayer(f.marker)));
    assert(roleOfLayer(f.meshB)  == RowRole.None, "not in the set at all");

    // Three rows, three DIFFERENT roles — the vacuity guard for the equalities
    // above. If any two coincided, a wrong implementation could satisfy both.
    assert(roleOfLayer(f.meshA) != roleOfLayer(f.plane)
        && roleOfLayer(f.plane) != roleOfLayer(f.meshB),
        "vacuity guard: the three selection states really are distinct here");

    // ---- D1: the first element is not the edit target -------------------
    // `set plane; add meshA`. The plane heads the selection and can NEVER be
    // the edit target; meshA IS the target and is second. This is the cell
    // that separated "the loud treatment marks the target" from "it marks the
    // first element" in the capture, and it separates them here.
    f.doc.selectItem(f.plane, SelMode.Set);
    f.doc.selectItem(f.meshA, SelMode.Add);
    itemRowsInto(&f.doc, "", false, true, rows);

    assert(f.doc.isPrimary(f.meshA) && f.doc.firstSelectedItem is f.plane,
        "fixture precondition: the edit target and the first-selected item "
        ~ "are different rows, and the first one cannot be a target at all");
    assert(roleOfLayer(f.plane) == RowRole.SelectedFirst,
        "the FIRST element takes it — even though it can never be an edit "
        ~ "target; got " ~ to!string(roleOfLayer(f.plane)));
    assert(roleOfLayer(f.meshA) == RowRole.Selected,
        "…and the actual edit target does not; got "
        ~ to!string(roleOfLayer(f.meshA)));

    // ---- The owner's state: the target, deselected ----------------------
    // An exclusive select of the plane leaves meshA LATCHED as the edit target
    // (task 0671) while dropping it from the selection. Its row is an ORDINARY
    // row — `roleOf` asking `isPrimary` first is what this reads against.
    f.doc.selectItem(f.plane, SelMode.Set);
    itemRowsInto(&f.doc, "", false, true, rows);

    assert(f.doc.isPrimary(f.meshA) && !f.meshA.selected,
        "fixture precondition: the edit target is latched onto a DESELECTED "
        ~ "mesh — the state the owner reported");
    assert(roleOfLayer(f.meshA) == RowRole.None,
        "the edit target is not a row treatment; got "
        ~ to!string(roleOfLayer(f.meshA)));
    assert(roleOfLayer(f.meshB) == RowRole.None,
        "…and it reads the same as a row that was never anything");
}

// ---------------------------------------------------------------------------
// I4b — the guard that decides whether a plain row click DISPATCHES.
//
// `isSoleSelection` replaces two guards that asked whether the row was the
// EDIT TARGET. Discriminating on exactly the state where the two answers part
// company: with the target latched onto a deselected mesh, the old guards said
// "already current" and swallowed the click that would have selected it back.
// ---------------------------------------------------------------------------
unittest {
    import seltype : SelMode;
    auto f = makeItemFixture();
    ItemRow[] rows;

    bool soleOf(Layer l) {
        foreach (r; rows) if (r.layer is l) return r.isSoleSelection;
        assert(false, "layer has no row");
    }

    itemRowsInto(&f.doc, "", false, true, rows);
    assert(soleOf(f.meshA), "the sole selected row: a `set` on it changes nothing");
    assert(!soleOf(f.meshB), "…and no other row claims to be");

    f.doc.selectItem(f.plane, SelMode.Add);
    itemRowsInto(&f.doc, "", false, true, rows);
    assert(!soleOf(f.meshA) && !soleOf(f.plane),
        "with TWO rows selected an exclusive click on either one narrows the "
        ~ "selection, so neither may be guarded out");

    f.doc.selectItem(f.plane, SelMode.Set);
    itemRowsInto(&f.doc, "", false, true, rows);
    assert(f.doc.isPrimary(f.meshA) && !f.meshA.selected,
        "fixture precondition: the latched-target state");
    assert(!soleOf(f.meshA),
        "the latched edit target is NOT the selection, so clicking its row "
        ~ "must dispatch — `document.isPrimary` here read true and swallowed "
        ~ "the click, which is 0671's app.d defect still standing in the panel");
    assert(soleOf(f.plane), "…while the row that IS the whole selection is guarded");
}

// ---------------------------------------------------------------------------
// I5 — the eye cell, the root's ABSENT eye, and the dim state.
//
// Discriminating for visibility: one item is hidden and the others are not,
// so an implementation reading a constant, or the document's own state,
// reads the same value on every row.
//
// Discriminating for `dimmed`: THREE rows are selected and only the primary is
// greyed. The state is reachable on exactly one row and only while a mesh-less
// item holds the focus — the document invariant keeps the mesh edit target
// selected, while the item gizmo narrows onto the focus and drops it. An
// implementation that greyed every non-current selected row reads `true` on
// the plane too; one that greyed nothing reads 0.
// ---------------------------------------------------------------------------
unittest {
    import seltype : SelMode;
    auto f = makeItemFixture();
    ItemRow[] rows;

    f.plane.visible = false;
    itemRowsInto(&f.doc, "", false, true, rows);

    ItemRow rowOf(Layer l) {
        foreach (r; rows) if (r.layer is l) return r;
        assert(false, "layer has no row");
    }
    assert(!rowOf(f.plane).visible,  "the hidden item reports hidden");
    assert(rowOf(f.meshA).visible,   "…and its neighbours are untouched");
    assert(rowOf(f.meshB).visible,   "…all of them");
    foreach (r; rows[1 .. $])
        assert(r.canToggleVisible, "every ITEM row has a working eye");

    assert(rows[0].canToggleVisible == false,
        "the ROOT has no eye: there is no document-wide visibility state "
        ~ "behind one, and a cell that cannot be clicked is the dead ornament "
        ~ "this panel is not allowed to draw");

    // Nothing is dimmed while a mesh holds the focus.
    foreach (r; rows[1 .. $])
        assert(!r.dimmed,
            "control: with the focus on the mesh, the selection and the "
            ~ "moving set agree, so no row is greyed");

    // Focus a mesh-LESS item while the mesh stays selected: the gizmo narrows
    // onto the focus, and the mesh row is the one that says so. THREE rows end
    // up selected — the mesh primary, the plane and the marker — so "only the
    // primary greys" is a claim about a set, not about the one selected row
    // there happened to be.
    //
    // BOTH are `Add` (task 0668). The plane used to join via `Set`, and the
    // three-row state was then produced by the document FORCING the mesh to
    // stay selected. 0668 removed that forcing from the exclusive path, so the
    // state this test needs is now reached the way a user reaches it — by
    // ctrl-adding to a selection that already holds the mesh.
    f.doc.selectItem(f.plane,  SelMode.Add);
    f.doc.selectItem(f.marker, SelMode.Add);
    itemRowsInto(&f.doc, "", false, true, rows);

    assert(f.doc.primary is f.meshA && f.doc.primary.selected,
        "fixture precondition: the mesh edit target is STILL selected — that "
        ~ "is the whole reason a selected row can fail to move");
    assert(f.plane.selected && f.marker.selected,
        "fixture precondition: two OTHER rows are selected too, or 'only one "
        ~ "row greys' would be trivially true");
    assert(rowOf(f.doc.primary).dimmed,
        "the selected-but-not-moving row is greyed");
    assert(!rowOf(f.plane).dimmed && !rowOf(f.marker).dimmed,
        "…and the rows the gizmo does move are not — an implementation that "
        ~ "greyed every SELECTED row reads true for both of these");
    assert(!rowOf(f.meshB).dimmed,
        "…and a row outside the selection is never greyed: greying says "
        ~ "'selected but not moving', which has nothing to say about a row "
        ~ "that is not selected");

    // The total, stated as the consequence of the four readings above rather
    // than as an independent check: one greyed row out of five.
    size_t dimCount = 0;
    foreach (r; rows) if (r.dimmed) ++dimCount;
    import std.conv : to;
    assert(dimCount == 1,
        "exactly one row is greyed; got " ~ to!string(dimCount));
}

// ---------------------------------------------------------------------------
// I6 — the TYPE glyph is that row's kind.
//
// Discriminating: three different listed kinds are present, so an
// implementation drawing a constant glyph, or the first item's glyph, reads
// the same token three times where the correct one reads three different
// tokens. The root's glyph is a fourth.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;
    auto f = makeItemFixture();
    ItemRow[] rows;
    itemRowsInto(&f.doc, "", false, true, rows);

    ItemGlyph glyphOf(Layer l) {
        foreach (r; rows) if (r.layer is l) return r.glyph;
        assert(false, "layer has no row");
    }
    assert(rows[0].glyph  == ItemGlyph.Scene, "the root draws the scene glyph");
    assert(glyphOf(f.meshA)  == ItemGlyph.Mesh,  "got " ~ to!string(glyphOf(f.meshA)));
    assert(glyphOf(f.meshB)  == ItemGlyph.Mesh,  "got " ~ to!string(glyphOf(f.meshB)));
    assert(glyphOf(f.plane)  == ItemGlyph.Plane, "got " ~ to!string(glyphOf(f.plane)));
    assert(glyphOf(f.marker) == ItemGlyph.Empty, "got " ~ to!string(glyphOf(f.marker)));

    // Four DISTINCT tokens are in play, which is what makes the equalities
    // above discriminating rather than four readings of one constant.
    assert(rows[0].glyph != glyphOf(f.meshA)
        && glyphOf(f.meshA) != glyphOf(f.plane)
        && glyphOf(f.plane) != glyphOf(f.marker),
        "vacuity guard: the glyphs really do differ by kind");

    // No row draws NOTHING. `glyphFor` has a `None` arm (the resource kind),
    // and the compile-time proof above says a LISTED kind never reaches it —
    // this is the runtime reading of that same statement over real rows.
    foreach (r; rows)
        assert(r.glyph != ItemGlyph.None,
            "every drawn row has a glyph; an empty type cell reads as "
            ~ "'unknown kind' and is indistinguishable from a drawing bug");
}

// ---------------------------------------------------------------------------
// I7 — the root's collapse.
//
// Discriminating: collapsed reads ONE row and it is the root. An
// implementation that collapsed the root ITSELF away reads rows whose first
// entry is an item; one that ignored the flag reads five.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;
    auto f = makeItemFixture();
    ItemRow[] rows;

    itemRowsInto(&f.doc, "", false, false, rows);
    assert(rows.length == 1,
        "collapsed, the list is the root alone; got " ~ to!string(rows.length));
    assert(rows[0].isRoot,
        "…and what survives is the ROOT, not the first item — collapsing a "
        ~ "tree hides the children, not the node you clicked");
    assert(rows[0].name.length > 0, "…still naming the document");

    itemRowsInto(&f.doc, "", false, true, rows);
    assert(rows.length == 5, "expanding brings them back; got "
        ~ to!string(rows.length));
}

// ---------------------------------------------------------------------------
// I8 — the rename editor's seed is the RAW name.
//
// Discriminating on exactly the case where the two differ: an unnamed item
// DISPLAYS the placeholder and SEEDS with nothing. Seeding with the display
// form means Enter renames the item to the literal "(unnamed)", after which
// "no name" cannot be recovered.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeItemFixture();
    ItemRow[] rows;
    itemRowsInto(&f.doc, "", false, true, rows);

    foreach (r; rows[1 .. $])
        assert(r.renameSeed == r.name,
            "a named item seeds the editor with what it displays");

    f.meshB.name = "";
    itemRowsInto(&f.doc, "", false, true, rows);

    ItemRow rowOf(Layer l) {
        foreach (r; rows) if (r.layer is l) return r;
        assert(false, "layer has no row");
    }
    assert(rowOf(f.meshB).name == kUnnamedText,
        "an unnamed item DISPLAYS the placeholder; got '"
        ~ rowOf(f.meshB).name ~ "'");
    assert(rowOf(f.meshB).renameSeed == "",
        "…and seeds the editor with NOTHING; got '"
        ~ rowOf(f.meshB).renameSeed ~ "'");
    assert(rowOf(f.meshB).name != rowOf(f.meshB).renameSeed,
        "vacuity guard: the display form and the seed really are different "
        ~ "strings here — everywhere else they coincide and the assertions "
        ~ "above would be inert");

    assert(!rows[0].canRename,
        "the root is not renameable: it names the FILE, and renaming a file "
        ~ "is Save As, not an inline edit in a list");
}

// ---------------------------------------------------------------------------
// I9 — the Add-Item menu dispatches command ids that EXIST.
//
// Discriminating without restating the literals: each choice's `command` is
// compared to the command class's own `name()`. A typo in the menu — the
// failure mode a list of string literals invites, and one that shows up as a
// button that silently does nothing — reads a different string here.
// ---------------------------------------------------------------------------
unittest {
    import commands.layer.commands       : LayerAdd;
    import commands.image_plane.commands : ImagePlaneAdd;
    import view     : View;
    import editmode : EditMode;

    auto f = makeItemFixture();
    auto v = new View(0, 0, 800, 600);

    auto add   = new LayerAdd(f.doc.activeMesh(), v, EditMode.Vertices,
                              &f.doc, null);
    auto plane = new ImagePlaneAdd(f.doc.activeMesh(), v, EditMode.Vertices,
                                   &f.doc);

    assert(kAddItemChoices.length == 2,
        "two creatable kinds today; an entry added here without a command "
        ~ "behind it will fail the identity checks below");
    assert(kAddItemChoices[0].command == add.name(),
        "the Mesh entry dispatches the layer-add command's OWN id; got '"
        ~ kAddItemChoices[0].command ~ "' vs '" ~ add.name() ~ "'");
    assert(kAddItemChoices[1].command == plane.name(),
        "the Image Plane entry dispatches the plane-add command's OWN id; got '"
        ~ kAddItemChoices[1].command ~ "' vs '" ~ plane.name() ~ "'");
    assert(add.name() != plane.name(),
        "vacuity guard: the two commands really have different ids, so the "
        ~ "two assertions above cannot both pass on one wrong string");

    foreach (c; kAddItemChoices) {
        assert(c.label.length > 0, "every entry is readable");
        assert(c.args.length > 0,
            "every entry carries a JSON argument object — an empty string is "
            ~ "not parseable and the dispatch would be refused");
        import std.json : parseJSON, JSONType;
        assert(parseJSON(c.args).type == JSONType.object,
            "…and it really is an object: '" ~ c.args ~ "'");
    }
}

