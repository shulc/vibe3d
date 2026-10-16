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

import std.file : exists;

import std.algorithm : canFind, endsWith, sort;
import std.array : array, join;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName, baseName;
import std.regex : ctRegex, matchAll;
import std.string : splitLines;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, countIdent,
    wave15DirEntries, wave15ReadText, wave15LogicalPath, wave19MathPhysicalPath,
    Wave15Entry, wave15InputsIntact, wave15InputStart;

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
private Wave15Entry[] physicalEntries(string directory) {
    Wave15Entry[] result;
    // The physical census keeps the five real math bodies, excluding the five
    // compatibility modules and facade; sources still reads their actual bytes.
    if (directory == buildPath(repoRoot, "util/math/source")) {
        foreach (entry; wave15DirEntries(directory, "*.d", SpanMode.depth))
            result ~= Wave15Entry(wave19MathPhysicalPath(entry.name),
                entry.isFile, entry.isDir, entry.size);
        return result;
    }
    foreach (entry; dirEntries(directory, "*.d", SpanMode.depth))
        result ~= Wave15Entry(entry.name, entry.isFile, entry.isDir, entry.isFile ? entry.size : 0);
    return result;
}


/// Every `source/**/*.d`; `production` drops the in-source `*_test.d` modules.
private Src[] sources(bool production, bool logical = false) {
    Src[] r;
    foreach (scanSourceRoot; [buildPath(repoRoot, "source"), buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source"), buildPath(repoRoot, "packages/pipe-contracts/source"), buildPath(repoRoot, "packages/mesh-preview/source"), buildPath(repoRoot, "util/json-number/source")]
        ~ (exists(buildPath(repoRoot, "packages/selection-model/source")) ? [buildPath(repoRoot, "packages/selection-model/source")] : [])
        ~ (exists(buildPath(repoRoot, "packages/scene-query/source")) ? [buildPath(repoRoot, "packages/scene-query/source")] : [])
        ~ (exists(buildPath(repoRoot, "packages/editor-commands/source")) ? [buildPath(repoRoot, "packages/editor-commands/source")] : [])
        ~ (!logical && exists(buildPath(repoRoot, "packages/interactive-tools/source")) ? [buildPath(repoRoot, "packages/interactive-tools/source")] : [])
        ~ (!logical && exists(buildPath(repoRoot, "packages/viewport-host/source")) ? [buildPath(repoRoot, "packages/viewport-host/source")] : [])
        ~ (!logical && exists(buildPath(repoRoot, "packages/interaction-data/source")) ? [buildPath(repoRoot, "packages/interaction-data/source")] : [])
        ~ (!logical && exists(buildPath(repoRoot, "packages/ai-advisor/source")) ? [buildPath(repoRoot, "packages/ai-advisor/source")] : [])
        ~ (!logical && exists(buildPath(repoRoot, "packages/ai3d-runtime/source")) ? [buildPath(repoRoot, "packages/ai3d-runtime/source")] : [])
        ~ (!logical && exists(buildPath(repoRoot, "packages/document-actions/source")) ? [buildPath(repoRoot, "packages/document-actions/source")] : [])
        ~ (!logical && exists(buildPath(repoRoot, "packages/http-runtime/source")) ? [buildPath(repoRoot, "packages/http-runtime/source")] : [])
        ~ (!logical && exists(buildPath(repoRoot, "packages/platform-file/source")) ? [buildPath(repoRoot, "packages/platform-file/source")] : [])
        ~ (!logical && exists(buildPath(repoRoot, "packages/remesh-runtime/source")) ? [buildPath(repoRoot, "packages/remesh-runtime/source")] : [])
        ~ (!logical && exists(buildPath(repoRoot, "packages/render-model/source")) ? [buildPath(repoRoot, "packages/render-model/source")] : [])
        ~ (!logical && exists(buildPath(repoRoot, "packages/render-backends/source")) ? [buildPath(repoRoot, "packages/render-backends/source")] : [])
        ~ (!logical && exists(buildPath(repoRoot, "packages/forms-model/source")) ? [buildPath(repoRoot, "packages/forms-model/source")] : [])
        ~ (!logical && exists(buildPath(repoRoot, "packages/editor-ui/source")) ? [buildPath(repoRoot, "packages/editor-ui/source")] : []))

    foreach (e; logical ? wave15DirEntries(scanSourceRoot, "*.d", SpanMode.depth)
                       : physicalEntries(scanSourceRoot)) {
        if (production && e.name.endsWith("_test.d")) continue;
        auto raw = logical ? wave15ReadText(e.name) : readText(e.name);
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
    auto wave15Inputs = wave15InputStart();
    const all = sources(false), prod = sources(true);
    // Historical 2026-10-05: 587 production plus one source test. Wave6 moves
    // that six-block carrier to transform tests; Wave9 adds triangulate/morph_preview; independent tracked union =608.
    assert(prod.length == 608, format("%s production files scanned "
        ~ "(Wave18 physical production population 608; drag_identity is test-only)", prod.length));
    assert(all.length == prod.length, format("%s source files, %s production; "
        ~ "Wave6 source test carrier belongs to transform tests", all.length, prod.length));

    const string[] sourceCarriers = [
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
];
    Src[] logicalRaw = sources(false, true), logicalCode = sources(true, true);
    foreach (relative; sourceCarriers) {
        const raw = readText(buildPath(repoRoot, relative));
        const s = Src(relative, raw, blankUnittestBodies(blankNonCode(raw)));
        logicalRaw ~= s;
        logicalCode ~= s;
    }
    foreach (relative; [
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
]) {
        size_t rawOccurrences, codeOccurrences;
        foreach (s; logicalRaw) if (s.rel == relative) ++rawOccurrences;
        foreach (s; logicalCode) if (s.rel == relative) ++codeOccurrences;
        assert(rawOccurrences == 1 && codeOccurrences == 1,
               "workplane logical source carrier membership: " ~ relative);
    }
    assert(logicalRaw.length == 625 && logicalCode.length == 625,
           "workplane logical production and source carrier population 625");
    // The new presentation role has current physical ownership only; the
    // original logical625 population and its symbol rosters remain fixed.
    enum currentPhysicalOnly = "packages/editor-ui/source/ui/panel_host_roles.d";
    size_t currentPhysicalOnlyOccurrences;
    foreach (physical; prod) if (physical.rel == currentPhysicalOnly) ++currentPhysicalOnlyOccurrences;
    assert(currentPhysicalOnlyOccurrences == 1, "workplane current physical role membership");
    foreach (physical; prod) {
        size_t rawOccurrences, codeOccurrences;
        foreach (s; logicalRaw) if (s.rel == wave15LogicalPath(buildPath(repoRoot, physical.rel))[repoRoot.length + 1 .. $]) ++rawOccurrences;
        foreach (s; logicalCode) if (s.rel == wave15LogicalPath(buildPath(repoRoot, physical.rel))[repoRoot.length + 1 .. $]) ++codeOccurrences;
        if (physical.rel == currentPhysicalOnly)
            assert(rawOccurrences == 0 && codeOccurrences == 0,
                   "workplane current physical role must not invent an old logical source");
        else
            assert(rawOccurrences == 1 && codeOccurrences == 1,
                   "workplane logical physical source membership: " ~ physical.rel);
    }

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
        foreach (s; logicalRaw) if (auto k = countIdent(s.raw, dead)) { n += k; where ~= s.rel; }
        assert((n == 0) && wave15InputsIntact(wave15Inputs), format("%s still named %s times in %s", dead, n, where));
    }

    // STRUCTURAL: the index → unit-axis construction lives in `axisUnit` (the
    // pen's copies folded at P1 / P3, tasks 9415 / 9417). Basis tables (a normal plus two
    // in-plane axes per case) are a different construction and not counted.
    // State: the switch row is RED before W1 (vertex_place.d); the ternary row
    // is GREEN before (create_common.d's sat in `screenToPlacementLocal`) and
    // guards growth only.
    string[] switchFiles, ternFiles;
    foreach (s; logicalCode) {
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
    foreach (src; logicalCode)
        foreach (_; matchAll(src.code, principalCopy)) principalCopies ~= src.rel;
    assert(principalCopies == ["packages/spatial/source/workplane_basis.d"],
           format("inline principal-axis copies in %s (only the distinct auto-view build plane is retained)", principalCopies));

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
        const got = roster(logicalCode, name);
        if (got != rows) bad ~= format("\n%s roster:\n  got  %s\n  want %s", name, got, rows);
    }
    assert(bad.length == 0, bad);
}
