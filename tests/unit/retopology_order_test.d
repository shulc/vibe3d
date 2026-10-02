// The item draw sequence of the retopology display (`retopology_order`):
// which layers enter it, in which order, and on which side of the primary.
//
// Captured rule (C1 (b)): foreground items draw in REVERSE layer order,
// independent of which one is the primary; a same-as-active backdrop joins
// the same sequence (C5). The pixels are `tests/test_retopology_multi_item.d`;
// these cells name the exact split, which pixels read only through blends.
// Each positive cell is followed by the rival rule it refutes.
module tests.unit.retopology_order_test;

import std.format : format;

import document;
import mesh    : Mesh;
import seltype : SelMode;
import retopology_order : entersItemSequence, retopologyDrawSequence, SeqEntry;

private Layer named(string n) { auto l = new Layer; l.name = n; return l; }

/// Layer indices of `s`.
private size_t[] idx(const SeqEntry[] s) {
    size_t[] o;
    foreach (e; s) o ~= e.layerIndex;
    return o;
}

// L0 background (never selected), L1..L3 foreground with L2 the primary.
private Document fourLayers() {
    Mesh m;
    auto doc = Document.bootstrap(m);          // L0, selected
    foreach (n; ["L1", "L2", "L3"]) doc.layers ~= named(n);
    doc.selectItem(doc.layers[2], SelMode.Set); // flushes L0 to background
    doc.selectItem(doc.layers[1], SelMode.Add);
    doc.selectItem(doc.layers[3], SelMode.Add);
    return doc;
}

unittest { // the rig's premise: roles and the primary are what the cells assume
    auto doc = fourLayers();
    assert(doc.hasEditTarget() && doc.activeIndex() == 2,
        format("rig: L2 must be the primary, got index %s", doc.activeIndex()));
    assert(doc.roleOf(doc.layers[0]) == LayerRole.Background, "rig: L0 background");
    foreach (i; 1 .. 4)
        assert(doc.roleOf(doc.layers[i]) == LayerRole.Foreground,
            format("rig: L%s must be foreground", i));
}

unittest { // foreground only: reverse order, split around the primary
    auto doc = fourLayers();
    SeqEntry[] before, after;
    retopologyDrawSequence(doc, false, before, after);
    assert(idx(before) == [3] && idx(after) == [1],
        format("expected before [3] / after [1], got %s / %s", idx(before), idx(after)));
    assert(before[0].foreground && after[0].foreground, "both are foreground entries");
    // Rival (c) "every non-primary before the primary" puts L1 in `before`;
    // rival (a) "layer order" puts L1 first and L3 after the primary.
    assert(after.length == 1 && before.length == 1,
        "rivals (a)/(c)/(d): the split must straddle the primary");
    assert(!entersItemSequence(doc, 0, false),
        "L0 (background role) stays in the backdrop pass unless it joins");
    assert(!entersItemSequence(doc, 2, true), "the primary never enters");
}

unittest { // a joined backdrop enters as a backdrop entry, at its own index
    auto doc = fourLayers();
    SeqEntry[] before, after;
    retopologyDrawSequence(doc, true, before, after);
    assert(idx(before) == [3] && idx(after) == [1, 0],
        format("expected before [3] / after [1, 0], got %s / %s",
               idx(before), idx(after)));
    assert(after[0].foreground && !after[1].foreground,
        "L0 draws with the backdrop plan, L1 with the active one");
}

unittest { // reverse order WITHIN a side (the forward rival swaps it)
    Mesh m;
    auto doc = Document.bootstrap(m);
    foreach (n; ["L1", "L2", "L3", "L4"]) doc.layers ~= named(n);
    doc.selectItem(doc.layers[1], SelMode.Set);
    foreach (i; 2 .. 5) doc.selectItem(doc.layers[i], SelMode.Add);
    assert(doc.activeIndex() == 1, "rig: L1 must be the primary");
    SeqEntry[] before, after;
    retopologyDrawSequence(doc, true, before, after);
    assert(idx(before) == [4, 3, 2] && idx(after) == [0],
        format("expected before [4, 3, 2] / after [0], got %s / %s",
               idx(before), idx(after)));
}

unittest { // hidden and non-geometry layers never enter; storage is reused
    auto doc = fourLayers();
    doc.layers[3].visible = false;
    auto plane = named("plane");
    plane.kind = ItemKind.ImagePlane;
    doc.layers ~= plane;
    doc.selectItem(plane, SelMode.Add);
    assert(doc.activeIndex() == 2, "rig: L2 stays the primary");
    SeqEntry[] before = [SeqEntry(9, true), SeqEntry(8, true)];
    SeqEntry[] after  = [SeqEntry(7, false)];
    retopologyDrawSequence(doc, true, before, after);
    assert(before.length == 0 && idx(after) == [1, 0],
        format("expected before [] / after [1, 0], got %s / %s",
               idx(before), idx(after)));
}

unittest { // no edit target: every entry is `before`, all of them backdrop
    Document doc;
    doc.layers = [named("A"), named("B")];
    assert(!doc.hasEditTarget(), "rig: nothing may hold the target");
    SeqEntry[] before, after;
    retopologyDrawSequence(doc, true, before, after);
    assert(idx(before) == [1, 0] && after.length == 0,
        format("expected before [1, 0] / after [], got %s / %s",
               idx(before), idx(after)));
    assert(!before[0].foreground && !before[1].foreground,
        "with no target every layer is background");
    retopologyDrawSequence(doc, false, before, after);
    assert(before.length == 0 && after.length == 0,
        "a non-joined backdrop leaves every layer to the backdrop pass");
}

// ---------------------------------------------------------------------------
// Source census of the sequence's wiring in `source/ui/viewport_render.d`.
// Pixels cannot see these: every plan reaching `drawPlainItem` resolves
// `dim == 1.0` today (owner decision D6), which `useProgram` already seeds,
// so a dropped or misplaced `setDim` changes no pixel. A `setDim` BEFORE its
// program's `useProgram` would be overwritten by it, so the order is pinned.
// ---------------------------------------------------------------------------
private string rendererCode() {
    import std.file : readText;
    import std.path : buildPath, dirName;
    import tests.unit.census_symbols : blankNonCode;
    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    return blankNonCode(readText(buildPath(root, "source", "ui", "viewport_render.d")));
}

/// The body of the one method whose head is `head`, braces balanced.
private string bodyOf(string code, string head) {
    import std.string : indexOf;
    import tests.unit.census_symbols : countOccurrences;
    assert(countOccurrences(code, head) == 1,
        format("census: expected `%s` once in viewport_render.d", head));
    immutable ptrdiff_t at = code.indexOf(head);
    immutable ptrdiff_t open = code.indexOf('{', at);
    int depth = 0;
    foreach (i; open .. code.length) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0) return code[open .. i + 1];
    }
    assert(false, "census: unbalanced body of " ~ head);
}

unittest { // each program's plan state follows its useProgram, in the item's own draw
    import std.string : indexOf;
    import tests.unit.census_symbols : countOccurrences;
    immutable code = rendererCode();
    immutable plain = bodyOf(code, "void drawPlainItem(");
    immutable lines = bodyOf(code, "void drawItemLinesAndDots(");
    // Identifier prefixes, not whole calls: the seam's arguments may grow.
    enum litApply = "lit.applyPlan(", litRestore = "lit.restorePlanDefaults(";
    // Floor: exactly one plan write per program, two in all.
    assert(countOccurrences(plain, litApply) == 1
        && countOccurrences(plain, litRestore) == 1
        && countOccurrences(lines, "shader.setDim(plan.dim);") == 1,
        "census: drawPlainItem / drawItemLinesAndDots must each apply the plan once "
        ~ "(lit: applyPlan + restorePlanDefaults; flat: setDim)");
    assert(plain.indexOf("lit.useProgram(model, vp);") >= 0
        && plain.indexOf("lit.useProgram(model, vp);") < plain.indexOf(litApply),
        "census: the lit program's plan must be written AFTER its useProgram, which re-seeds it");
    assert(lines.indexOf("shader.useProgram(model, vp);") >= 0
        && lines.indexOf("shader.useProgram(model, vp);")
           < lines.indexOf("shader.setDim(plan.dim);"),
        "census: the flat program's dim must be written AFTER its useProgram, which re-seeds it");
    // Restored after the item, each program.
    assert(plain.indexOf(litApply) < plain.indexOf("g.drawFaces(")
        && plain.indexOf(litRestore) > plain.indexOf("g.drawFaces(")
        && lines.indexOf("shader.setDim(1.0f);") > lines.indexOf("g.drawVertices("),
        "census: an item's plan must be applied before and restored after its draws");
    // Its own materials: bound after its program, before its faces.
    immutable ptrdiff_t bind = plain.indexOf("bindLayerSurfaces(g, lyr, plan, lit, weightMapName);");
    assert(bind > plain.indexOf("lit.useProgram(model, vp);")
        && bind < plain.indexOf("g.drawFaces("),
        "census: drawPlainItem must bind the item's own materials before its faces");
    // The backdrop pass uses the same helper (definition + two calls).
    assert(countOccurrences(code, "bindLayerSurfaces(") == 3,
        format("census: expected bindLayerSurfaces defined once and called twice, "
               ~ "found %d occurrences", countOccurrences(code, "bindLayerSurfaces(")));
}
