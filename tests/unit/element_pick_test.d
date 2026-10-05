// Task 9441 (HOV3): the element-pick law has ONE home, `hover_state` — the
// reach, the comparator and its edge-midpoint veto. Part 1 pins the
// comparator against the captured mixed-type rows (K-P P5*A) on its own
// inputs; part 2 is the production-text census: one comparator definition,
// the named call-site roster, no literal reach left in a picker, the deleted
// copies gone. The suite cells are tests/test_element_pick_law.d.
module tests.unit.element_pick_test;

import std.algorithm : canFind, sort;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.regex     : matchFirst, regex;
import std.string    : indexOf;

import hover_state : PickGather, electElement, kCascadeVertex, kCascadeEdge,
    kCascadePolygon, kElementPickRadiusPx;
import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, countIdent,
    enclosingSymbols, isIdentChar, lineOf, symbolAt;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private PickGather gather(float v, float e, float mid, float poly) {
    PickGather g;
    g.vertex = v; g.edge = e; g.edgeMid = mid; g.polygon = poly;
    return g;
}

unittest { // the comparator, row by row (distances in px; inf = not gathered)
    enum inf = float.infinity;
    assert(kElementPickRadiusPx == 8.0f, "the element-pick reach is the captured 8 px");
    // Controls: one class alone takes the pick; nothing gathered takes none.
    assert(electElement(gather(7, inf, inf, inf)) == kCascadeVertex, "lone vertex");
    assert(electElement(gather(inf, inf, inf, 0)) == kCascadePolygon, "lone polygon");
    assert(electElement(gather(inf, inf, inf, inf)) == -1, "empty gather");
    // P5A: vertex 7, edge 3, midpoint 25 -> the vertex (tolerance 16).
    assert(electElement(gather(7, 3, 25, inf)) == kCascadeVertex,
           "P5A: a vertex inside its doubled tolerance beats a nearer edge");
    // P5bA: the vertex at 10 px is never gathered -> the edge.
    assert(electElement(gather(inf, 3, 25, inf)) == kCascadeEdge, "P5bA: the edge");
    // P5cA: the edge's midpoint 3 px, nearer than the vertex -> the edge.
    assert(electElement(gather(7, 3, 3, inf)) == kCascadeEdge,
           "P5cA: the edge-midpoint veto removes the vertex");
    // The veto's range is strict: a midpoint AT the reach vetoes nothing.
    assert(electElement(gather(9, 3, 8, inf)) == kCascadeVertex,
           "a midpoint at exactly the reach must not veto");
    // The cascade, not V > E > F: an edge AT the reach over a polygon under
    // the cursor trails it by the whole edge tolerance and loses.
    assert(electElement(gather(inf, 3, 25, 0)) == kCascadeEdge, "edge inside its tolerance");
    assert(electElement(gather(inf, 8, 25, 0)) == kCascadePolygon,
           "an edge at the reach loses to the polygon under the cursor");
}

unittest { // production-text census
    size_t files;
    string[] cmpDefs, electSites;
    foreach (f; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        ++files;
        const rel = f.name[repoRoot.length + 1 .. $];
        const code = blankUnittestBodies(blankNonCode(readText(f.name)));
        const syms = enclosingSymbols(code);
        if (code.indexOf("bool cascadeClassWins(") >= 0) cmpDefs ~= rel;
        for (ptrdiff_t at = code.indexOf("electElement"); at >= 0;
             at = code.indexOf("electElement", at + 1)) {
            const e = at + "electElement".length;
            if ((at > 0 && isIdentChar(code[at - 1])) || code[e] != '(') continue;
            if (code[0 .. at].matchFirst(regex(`int\s+$`))) continue;   // its definition
            electSites ~= symbolAt(syms, lineOf(code, at) - 1);
        }
        foreach (gone; ["pressVertexVetoed", "kTopoPenPressPickNominalPx"])
            assert(countIdent(code, gone) == 0,
                   format("element-pick census: deleted copy `%s` is back in %s", gone, rel));
    }
    assert(files > 100, format("element-pick census: only %d source files scanned", files));

    // One comparator, in the law's home.
    assert(cmpDefs == ["source/hover_state.d"],
           format("element-pick census: comparator defined in %s", cmpDefs));

    // The comparator's call-site roster: the active-tool hover publish and the
    // topology pen's press pick (Duplicate and Remove press through it too).
    electSites.sort();
    assert(electSites.length == 2, format("element-pick census: %d call sites", electSites.length));
    assert(electSites == ["InputFrameState.publishHover", "TopologyPenTool.resolveGrabTarget"],
           format("element-pick census: call-site roster changed: %s", electSites));

    // The pickers carry no reach of their own: two instantiations, no literal.
    const ifs = blankNonCode(readText(buildPath(repoRoot, "source/input_frame_state.d")));
    size_t inst;
    for (ptrdiff_t at = ifs.indexOf("pickHover!("); at >= 0; at = ifs.indexOf("pickHover!(", at + 1)) {
        ++inst;
        const close = ifs.indexOf(")", at);
        assert(!ifs[at .. close].matchFirst(regex(`[,(]\s*\d`)),
               "element-pick census: a pickHover instantiation carries a literal reach");
    }
    assert(inst == 2, format("element-pick census: %d pickHover instantiations", inst));
    assert(ifs.indexOf("gpuSelect.pick(sm, mx, my, cast(int)kElementPickRadiusPx,") >= 0,
           "element-pick census: pickHover no longer picks at the element-pick reach");
}
