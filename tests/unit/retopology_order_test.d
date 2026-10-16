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

import vibe3d.documents.model.document;
import vibe3d.mesh.core.mesh    : Mesh;
import vibe3d.editing.contracts.seltype : SelMode;
import retopology_order : entersItemSequence, retopologyDrawSequence, SeqEntry;

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
