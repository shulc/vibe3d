// weld_remap_core_census_test — the two weld remaps share ONE face-collapse
// core and ONE edge-set re-key (task 9435). `Mesh.applyVertexRemapAndRebuild`
// and `Mesh.applyVertexRemap` each kept a private copy of both blocks; the
// copies now live in `Mesh.collapseFacesThroughRemap` and
// `Mesh.rekeyEdgeSetsThroughRemap`, and each twin keeps only its own tail.
// Behaviour is witnessed elsewhere (vert.merge / cleanup / selection-set
// cells); this module pins the PRODUCTION WIRING those cells cannot see: who
// calls the cores, and that no third copy of the collapse grows back. Both
// cores are `private`: the compiler refuses a direct call from another module;
// the string-member bypass is not text-censused here.
// Order per assert block: scanner control, population floor, roster.
module tests.unit.weld_remap_core_census_test;

import std.algorithm : count, sort;
import std.file      : readText;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : splitLines;

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

unittest { // scanner control: a call and an address are seen; prose is not
    enum probe = "struct M {\n"
               ~ "    void a() {\n        core(1);\n    }\n"
               ~ "    // core in a comment\n"
               ~ "    void b() {\n        auto s = \"core\";\n    }\n"
               ~ "    void c() {\n        auto p = &core;\n    }\n"
               ~ "}\n";
    const seen = declsOf(probe, "core");
    assert(seen == ["M.a", "M.c"],
           format("scanner control: expected [\"M.a\", \"M.c\"], found %s", seen));
}

unittest { // both twins, and only they, reach the two cores
    const src = meshSrc();
    // Keyed on the bare identifier, so `&core` and `core!` spellings count too.
    static foreach (needle; ["collapseFacesThroughRemap", "rekeyEdgeSetsThroughRemap"]) {{
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
}
