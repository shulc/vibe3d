// weld_remap_core_census_test — the two weld remaps share ONE face-collapse
// core and ONE edge-set re-key (task 9435). `Mesh.applyVertexRemapAndRebuild`
// and `Mesh.applyVertexRemap` each kept a private copy of both blocks; the
// copies now live in `Mesh.collapseFacesThroughRemap` and
// `Mesh.rekeyEdgeSetsThroughRemap`, and each twin keeps only its own tail.
// Behaviour is witnessed elsewhere (vert.merge / cleanup / selection-set
// cells); this module pins the PRODUCTION WIRING those cells cannot see: who
// calls the cores, and that no third copy of the collapse grows back.
// Order per assert block: scanner control, population floor, roster.
module tests.unit.weld_remap_core_census_test;

import std.algorithm : count, sort;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : splitLines, indexOf;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
                                   enclosingSymbols, symbolAt;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// Enclosing declaration of every occurrence of `needle` in `src`'s CODE
/// (comments, strings and unittest bodies blanked), one entry per hit.
private string[] declsOf(string src, string needle) {
    const code = blankUnittestBodies(blankNonCode(src));
    const syms = enclosingSymbols(code);
    string[] outp;
    foreach (li, ln; code.splitLines())
        foreach (_; 0 .. ln.count(needle))
            outp ~= symbolAt(syms, li);
    sort(outp);
    return outp;
}

private string meshSrc() { return readText(buildPath(repoRoot, "source", "mesh.d")); }

unittest { // scanner control: a call is seen with its declaration; prose is not
    enum probe = "struct M {\n"
               ~ "    void a() {\n        core(1);\n    }\n"
               ~ "    // core( in a comment\n"
               ~ "    void b() {\n        auto s = \"core(\";\n    }\n"
               ~ "}\n";
    assert(declsOf(probe, "core(") == ["M.a"],
           format("scanner control: expected [\"M.a\"], found %s", declsOf(probe, "core(")));
}

unittest { // both twins, and only they, reach the two cores
    const src = meshSrc();
    static foreach (needle; ["collapseFacesThroughRemap(", "rekeyEdgeSetsThroughRemap("]) {{
        const got = declsOf(src, needle);
        // Floor: the declaration line plus one call per twin.
        assert(got.length == 3, format("`%s`: expected 3 occurrences in source/mesh.d "
            ~ "(its declaration + one call in each weld remap), found %d: %s",
            needle, got.length, got));
        // A declaration line belongs to its enclosing scope, `Mesh`.
        const string[] want = ["Mesh", "Mesh.applyVertexRemap",
                               "Mesh.applyVertexRemapAndRebuild"];
        assert(got == want, format("`%s` call roster: expected %s, found %s — a weld "
            ~ "remap that stopped calling the shared core carries its own copy again",
            needle, want, got));
    }}
}

unittest { // the deleted copies stay deleted
    const src = meshSrc();
    // The wrap-around trim and the edge-set pre-image pair occur in the cores only.
    const trim = declsOf(src, "f[$ - 1] == f[0]");
    assert(trim == ["Mesh.collapseFacesThroughRemap"], format(
        "the wrap-around duplicate trim must live only in the collapse core; found %s", trim));
    foreach (needle; ["captureEdgeSetImage(", "recordEdgeSetMerge("]) {
        const got = declsOf(src, needle);
        assert(got.length == 2, format("`%s`: expected 2 occurrences (declaration + the "
            ~ "re-key core's call), found %d: %s", needle, got.length, got));
        assert(got.count("Mesh.rekeyEdgeSetsThroughRemap") == 1, format(
            "`%s` must be called from `Mesh.rekeyEdgeSetsThroughRemap` alone; found %s",
            needle, got));
    }
    // No module outside mesh.d names either core.
    size_t outside;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        if (de.name == buildPath(repoRoot, "source", "mesh.d")) continue;
        const code = blankNonCode(readText(de.name));
        if (code.indexOf("collapseFacesThroughRemap") >= 0
            || code.indexOf("rekeyEdgeSetsThroughRemap") >= 0) ++outside;
    }
    assert(outside == 0, format("%d source modules besides mesh.d name a weld core", outside));
}
