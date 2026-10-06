// One parameter frame, one plane hit, one principal axis, one view quantum
// (task 9408, interaction-layer wave W1). `primitivePlacementFrame` is the ONE
// headless frame (the old `currentWorkplaneFrame` / `primitiveParameterFrame`
// pair is folded into it), the per-tool `localCursorPlane` forwarders are gone
// (callers call `workplaneCursorPlaneHit`), the most-facing local axis is
// `viewPrincipalAxis` + `axisUnit`, and the view's vector quantum is
// `viewVectorQuantum`; the pen reads them too since P1 (task 9415).
//
// Counts are WHOLE IDENTIFIERS over every production `source/**/*.d` (in-source
// `*_test.d` modules excluded) in the code view: comments, strings and unittest
// bodies blanked; an import line counts. The deleted names are counted in the
// RAW text of every source file (comments and string mixins included).
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — score mutations one at
// a time.
module tests.unit.workplane_frame_census_test;

import std.algorithm : canFind, endsWith, sort;
import std.array : array, join;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName, baseName;
import std.regex : ctRegex, matchAll;
import std.string : splitLines;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, countIdent;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// COMPILER PIN: the folded and the new names, by the compiler, not by text.
static import tools.create.create_common;
static import viewgrid;
static assert(![__traits(allMembers, tools.create.create_common)].canFind("currentWorkplaneFrame"));
static assert(![__traits(allMembers, tools.create.create_common)].canFind("primitiveParameterFrame"));
static assert([__traits(allMembers, tools.create.create_common)].canFind("primitivePlacementFrame"));
static assert([__traits(allMembers, tools.create.create_common)].canFind("viewPrincipalAxis"));
static assert([__traits(allMembers, tools.create.create_common)].canFind("axisUnit"));
static assert([__traits(allMembers, viewgrid)].canFind("viewVectorQuantum"));

private struct Src { string rel, raw, code; }

/// Every `source/**/*.d`; `production` drops the in-source `*_test.d` modules.
private Src[] sources(bool production) {
    Src[] r;
    foreach (e; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        if (production && e.name.endsWith("_test.d")) continue;
        auto raw = readText(e.name);
        r ~= Src(e.name[repoRoot.length + 1 .. $], raw,
                 blankUnittestBodies(blankNonCode(raw)));
    }
    return r;
}

/// "file:count" for every production file naming `ident`, sorted.
private string roster(const Src[] srcs, string ident) {
    string[] rows;
    foreach (s; srcs) {
        const n = countIdent(s.code, ident);
        if (n) rows ~= format("%s:%s", baseName(s.rel), n);
    }
    rows.sort();
    return rows.join(" ");
}

unittest // W1: the folded frames, the forwarders, the axis switch, the quantum
{
    const all = sources(false), prod = sources(true);
    // FLOOR: the scan sees the tree (measured 2026-10-05: 587 + 1 in-source test
    // module, so all = prod + 1).
    assert(prod.length > 550, format("only %s production files scanned "
        ~ "(measured 587)", prod.length));
    assert(all.length == prod.length + 1, format("%s source files, %s production; "
        ~ "measured exactly one in-source *_test.d module", all.length, prod.length));

    // Positive control of the counter and of the switch needle.
    assert(countIdent("a.viewVectorQuantum(x); auto d = &viewVectorQuantum;",
                      "viewVectorQuantum") == 2, "identifier counter is blind");
    // The index → unit-axis construction, in its two spellings: a switch whose
    // case body is ONE assignment, and the ternary triple.
    auto sw = ctRegex!(`case\s+0\s*:\s*\w+\s*=\s*Vec3\(\s*1\s*,\s*0\s*,\s*0\s*\)\s*;\s*break`);
    auto tern = ctRegex!(`==\s*0\s*\?\s*1\s*:\s*0\s*,[^;]*==\s*1\s*\?\s*1\s*:\s*0\s*,[^;]*==\s*2\s*\?\s*1\s*:\s*0`);
    assert(!matchAll("    case 0: pn = Vec3(1, 0, 0); break;", sw).empty
        && !matchAll("Vec3(k == 0 ? 1 : 0, k == 1 ? 1 : 0, k == 2 ? 1 : 0)", tern).empty,
           "axis-unit needles match nothing");
    assert(matchAll("case 0: n = Vec3(1, 0, 0); a1 = Vec3(0, 1, 0); break;", sw).empty,
           "the switch needle must not take a basis TABLE (normal + two axes)");

    // NEEDLE (raw text, every source file): the folded frame accessors and the
    // per-tool plane forwarders are gone, in code, comments and mixin strings.
    // State: RED before W1 (raw tokens on cb5aec75: currentWorkplaneFrame 18,
    // primitiveParameterFrame 14, localCursorPlane 22).
    foreach (dead; ["currentWorkplaneFrame", "primitiveParameterFrame", "localCursorPlane"]) {
        size_t n;
        string[] where;
        foreach (s; all) if (auto k = countIdent(s.raw, dead)) { n += k; where ~= s.rel; }
        assert(n == 0, format("%s still named %s times in %s", dead, n, where));
    }

    // STRUCTURAL: the index → unit-axis construction lives in `axisUnit` (the
    // pen's copies folded at P1 / P3, tasks 9415 / 9417). Basis tables (a normal plus two
    // in-plane axes per case) are a different construction and not counted.
    // State: the switch row is RED before W1 (vertex_place.d); the ternary row
    // is GREEN before (create_common.d's sat in `screenToPlacementLocal`) and
    // guards growth only.
    string[] switchFiles, ternFiles;
    foreach (s; prod) {
        if (!matchAll(s.code, sw).empty) switchFiles ~= baseName(s.rel);
        foreach (m; matchAll(s.code, tern)) ternFiles ~= baseName(s.rel);
    }
    ternFiles.sort();
    assert(switchFiles.length == 0, format("axis-unit switch in %s", switchFiles));
    assert(ternFiles == ["create_common.d"],
           format("axis-unit ternary in %s", ternFiles));

    // Task 9418: the two create-tool copies now use the same principal-axis reader.
    auto principalCopy = ctRegex!(`mostFacingAxis\s*\(\s*camBack\s*,\s*Vec3\(\s*1\s*,\s*0\s*,\s*0\s*\)`);
    assert(!matchAll("mostFacingAxis(camBack, Vec3(1, 0, 0),", principalCopy).empty,
           "principal-axis copy needle is blind");
    string[] principalCopies;
    foreach (src; prod)
        foreach (_; matchAll(src.code, principalCopy)) principalCopies ~= src.rel;
    assert(principalCopies.length == 0,
           format("inline principal-axis copies in %s", principalCopies));

    // PIN: the call-site rosters (definition + import + calls per file).
    // Polarity: each row is RED before W1 (the name did not exist, or had a
    // different reader set) and GREEN after. W2 (task 9411): the vertex tool
    // places through `screenToPlacementLocal` on `primitivePlacementFrame`,
    // and the placement click reads `viewVectorQuantum` in create_common
    // (task 9404: + the free point's no-surface fallback, `backgroundPoint`).
    const string[string] want = [
        // the grid sub-step is read through `viewVectorQuantum` everywhere but
        // its home; task 9415: the pen joins (P1); drag.d: the handle drag's quantum forms
        "viewGridSubStep": "viewgrid.d:2",
        // create_common.d: + the free point's q of its plane point (task 9499);
        // array_tool.d: the snapped press hit P0 of the offset haul (task 9527)
        "viewVectorQuantum": "array_tool.d:2 create_common.d:4 drag.d:2 http_providers.d:2 pen.d:2 "
            ~ "poly_extrude.d:2 transform.d:2 viewgrid.d:2",
        "viewPrincipalAxis": "box.d:2 create_common.d:2 pen.d:2 primitive_create_tool.d:2",
        // radial_array_tool.d: its own unrelated `axisUnit()` member (5); create_common.d: + the
        // centre box's locked axis in `snapMoverCentre` (task 9472)
        // vertex_place.d: the drag plane's normal (task 9499)
        "axisUnit": "create_common.d:3 overlay_space.d:2 pen.d:4 radial_array_tool.d:5 vertex_place.d:2",
        // edge_extend.d: the work-plane symmetry plane mapped once more (task 9452)
        "primitivePlacementFrame": "arc.d:3 box.d:4 create_common.d:2 edge_extend.d:2 pen.d:2 "
            ~ "poly_extrude.d:2 primitive_create_tool.d:4 slice_tool.d:4 sphere.d:2 transform.d:2 "
            ~ "vertex_place.d:3",
        "workplaneCursorPlaneHit": "box.d:6 create_common.d:1 pen.d:2 "
            ~ "primitive_create_tool.d:5 torus.d:3 tube.d:5",
    ];
    assert(want.length == 6, "roster table lost a row");
    string bad;
    foreach (name, rows; want) {
        const got = roster(prod, name);
        if (got != rows) bad ~= format("\n%s roster:\n  got  %s\n  want %s", name, got, rows);
    }
    assert(bad.length == 0, bad);
}
