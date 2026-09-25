// Source census of the viewport renderer's vertex-dot pass (`drawScene`,
// "Vertex dots" block of source/ui/viewport_render.d).
//
// Why text and not pixels: the property is "in edge mode the hovered vertex
// is lit only in the cell that has the pointer". In edge mode a vertex hover
// exists only while a tool asks for multi-type hover, and it differs between
// cells only in a split layout, so a behavioural witness needs a split layout,
// such a tool and a pixel probe of the OTHER cell. The seam is one argument
// expression, so the census reads the production call text instead.
//
// Order: floor (the block is found once, and the hover-only arm it mirrors
// still gates on the same flag) -> needles (the edge arm's hover argument,
// then its mark view).
module tests.unit.vertex_dot_arm_census_test;

import std.file   : readText;
import std.format : format;
import std.path   : buildPath, dirName;
import std.string : indexOf;

import tests.unit.census_symbols : blankNonCode, countOccurrences;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// Comment- and string-free text with every whitespace run collapsed to one
/// space, so a re-wrapped argument list reads the same.
private string squeeze(string code) {
    auto o = new char[code.length];
    size_t n = 0;
    bool ws = false;
    foreach (c; code) {
        immutable bool isWs = c == ' ' || c == '\n' || c == '\t' || c == '\r';
        if (isWs) { if (!ws && n) o[n++] = ' '; ws = true; }
        else { o[n++] = c; ws = false; }
    }
    return cast(string) o[0 .. n];
}

unittest {
    immutable path = buildPath(repoRoot, "source", "ui", "viewport_render.d");
    immutable code = squeeze(blankNonCode(readText(path)));

    // ---- floor: the block, exactly once ---------------------------------
    enum head = "if (activePlan.drawVerts || selFeedbackType == SelType.Vertex "
              ~ "|| selFeedbackType == SelType.Edge) {";
    immutable size_t heads = countOccurrences(code, head);
    assert(heads == 1, format("vertex-dot census: expected the vertex-dot "
        ~ "condition once in %s, found %d; the block moved or was rewritten "
        ~ "and every needle below would read the wrong text", path, heads));
    immutable ptrdiff_t at = code.indexOf(head);
    // Slice M6: both arms hand GL the rollover-gated hover (`vertHovForDraw`).
    enum elseArm = "} else if (showVertHover && vertHovForDraw >= 0) {";
    immutable ptrdiff_t end = code.indexOf(elseArm, at);
    assert(end > at, "vertex-dot census: the hover-only arm (`showVertHover "
        ~ "&& vertHovForDraw >= 0`) no longer follows the block; the flag the "
        ~ "edge arm mirrors is gone from its reference site");
    immutable string arm = code[at .. end];
    assert(countOccurrences(arm, "gpu.drawVertices(") == 1,
        "vertex-dot census: expected exactly one drawVertices call in the arm");

    // ---- needle 1: the edge arm's hover is gated on the pointer's cell ----
    // Red when the gate is dropped (hover lit in every cell of a split layout).
    enum edgeArm = "immutable bool edgeArm = selFeedbackType == SelType.Edge;";
    assert(countOccurrences(arm, edgeArm) == 1,
        "vertex-dot census: the arm no longer derives `edgeArm` from the "
        ~ "edge selection type");
    enum hoverArg = "edgeArm && !showVertHover ? -1 : vertHovForDraw,";
    assert(countOccurrences(arm, hoverArg) == 1,
        "vertex-dot census: edge-mode hover is not gated on showVertHover "
        ~ "(the cell-has-the-pointer flag); a hovered vertex would light in "
        ~ "every cell of a split layout");

    // ---- needle 2: only edge mode drops the marks --------------------------
    // Red when polygon/item modes lose their selected vertices, or edge mode
    // gets them back.
    enum marksArg = "edgeArm ? MarkView.init : mesh.selectedVertexView(),";
    assert(countOccurrences(arm, marksArg) == 1,
        "vertex-dot census: the mark view is no longer `empty in edge mode, "
        ~ "the selection otherwise`");
}
