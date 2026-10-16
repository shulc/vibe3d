module tests.unit.handle_draw_funnel_census_test;


import tests.unit.census_symbols : exists = wave15Exists;

import vibe3d.editing.tools.interactive.handles.arbiter;
import vibe3d.editing.tools.interactive.handles.arbiter_source_cells;
import vibe3d.editing.tools.interactive.handles.shapes;
import vibe3d.editing.tools.interactive.tools.transform.scale;

import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.file : SpanMode;
import tests.unit.census_symbols : dirEntries = wave15DirEntries, readText = wave15ReadText;
import std.meta : AliasSeq;
import std.path : buildPath, dirName;
import std.regex : matchAll, matchFirst, regex;
import std.string : indexOf, split, splitLines, strip;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
                                   enclosingSymbols, symbolAt;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private alias kGatedHandleModules = AliasSeq!(
    vibe3d.editing.tools.interactive.handles.shapes, vibe3d.editing.tools.interactive.handles.arbiter, vibe3d.editing.tools.interactive.tools.transform.scale,
    vibe3d.editing.tools.interactive.handles.arbiter_source_cells);
private immutable string[] kGatedHandlerNames = [
    "Arrow", "BoxHandler", "CenterDiskGizmo", "CircleHandler",
    "ClickPointHandler", "CubicArrow", "EngageProbeHandle",
    "FullCircleHandler", "MoveHandler", "RotateHandler", "ScaleHandler",
    "ScaleHeadHandle", "SemicircleHandler", "ShaftedArrow",
];
private immutable string[] kCensusHandlerNames = [
    "Arrow", "BoxHandler", "CenterDiskGizmo", "CircleHandler",
    "ClickPointHandler", "CubicArrow", "EngageProbeHandle",
    "FullCircleHandler", "MoveHandler", "RotateHandler", "ScaleHandler",
    "ScaleHeadHandle", "SemicircleHandler", "ShaftedArrow",
];

private bool sameSet(const(string)[] a, const(string)[] b) pure {
    return missingFrom(a, b).length == 0 && missingFrom(b, a).length == 0;
}

private string missingFrom(const(string)[] a, const(string)[] b) pure {
    string result;
    foreach (x; a) {
        if (b.canFind(x)) continue;
        result ~= (result.length ? ", " : "") ~ x;
    }
    return result;
}

private string[] gatedHandlerNames() {
    string[] result;
    static foreach (mod; kGatedHandleModules) {
        static foreach (name; __traits(allMembers, mod)) {{
            static if (__traits(compiles, __traits(getMember, mod, name))) {
                alias Member = __traits(getMember, mod, name);
                static if (is(Member : Handler) && !is(Member == Handler))
                    if (!result.canFind(name)) result ~= name;
            }
        }}
    }
    return result;
}

private string[] derivedDrawOwners() {
    string[] result;
    static foreach (mod; kGatedHandleModules) {
        static foreach (name; __traits(allMembers, mod)) {{
            static if (__traits(compiles, __traits(getMember, mod, name))) {
                alias Member = __traits(getMember, mod, name);
                static if (is(Member : Handler) && !is(Member == Handler)) {
                    static foreach (member; __traits(derivedMembers, Member))
                        static if (member == "draw")
                            if (!result.canFind(name)) result ~= name;
                }
            }
        }}
    }
    return result;
}

private enum g1Names = gatedHandlerNames();
private enum g1DrawOwners = derivedDrawOwners();
static assert(!__traits(isVirtualMethod, Handler.draw),
    "Handler.draw must stay final/non-virtual so every ordinary leaf enters "
  ~ "the task-5480 receipt scope");
static assert(sameSet(g1Names, kGatedHandlerNames) && g1DrawOwners.length == 0,
    "the compile-time handle funnel changed:\n"
  ~ "  expected handlers missing: " ~ missingFrom(kGatedHandlerNames, g1Names) ~ "\n"
  ~ "  unrecorded handlers present: " ~ missingFrom(g1Names, kGatedHandlerNames) ~ "\n"
  ~ "  handlers declaring their own draw: " ~ missingFrom(g1DrawOwners, []));

private struct ClassDecl {
    string name;
    string moduleName;
    string[] bases;
}

private string tailName(string name) {
    auto pieces = name.split(".");
    return pieces.length ? pieces[$ - 1] : name;
}

private ClassDecl[] classesIn(string moduleName, string code) {
    auto outp = appender!(ClassDecl[]);
    auto classRe = regex(`\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*`
                       ~ `(?:\:\s*([^\{]+))?\s*\{`);
    auto baseRe = regex(`[A-Za-z_][A-Za-z0-9_.]*`);
    foreach (m; code.matchAll(classRe)) {
        ClassDecl d;
        d.name = m[1];
        d.moduleName = moduleName;
        foreach (base; m[2].split(",")) {
            auto bm = base.matchFirst(baseRe);
            if (!bm.empty) d.bases ~= tailName(bm.hit);
        }
        outp.put(d);
    }
    return outp.data;
}

private struct Scan {
    ClassDecl[] classes;
    string[] handleDrawOwners;
    string[] manualReceiptOwners;
    size_t legacyOverrides;
    size_t drawImplOverrides;
    size_t directDrawImplCalls;
}

private size_t occurrences(string haystack, string needle) {
    size_t count;
    for (size_t at; (at = haystack.indexOf(needle, at)) != size_t.max;
         at += needle.length)
        ++count;
    return count;
}

private Scan scanTree() {
    Scan result;
    foreach (scanSourceRoot; [buildPath(repoRoot, "source"), buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source"), buildPath(repoRoot, "packages/selection-model/source"), buildPath(repoRoot, "packages/scene-query/source"), buildPath(repoRoot, "packages/editor-commands/source")])

    foreach (de; dirEntries(scanSourceRoot, "*.d", SpanMode.depth)) {
        const src = blankUnittestBodies(blankNonCode(readText(de.name)));
        auto mm = src.matchFirst(regex(`(?m)^\s*module\s+([A-Za-z0-9_.]+)\s*;`));
        const moduleName = mm.empty ? "<missing-module>" : mm[1];
        result.classes ~= classesIn(moduleName, src);

        const bool inHandles = de.name.canFind(buildPath("source", "handles"));
        if (inHandles) {
            result.legacyOverrides += occurrences(src, "override void draw(");
            result.drawImplOverrides +=
                occurrences(src, "protected override void drawImpl(");
        }
        result.directDrawImplCalls += occurrences(src, ".drawImpl(");

        const auto syms = enclosingSymbols(src);
        foreach (li, line; src.splitLines()) {
            if (line.canFind("g_fc.handleDraw("))
                result.handleDrawOwners ~= symbolAt(syms, li);
            if (moduleName != "perf_probe"
                && line.canFind("g_fc.noteHandleSubmission("))
                result.manualReceiptOwners ~= symbolAt(syms, li);
        }
    }
    const string[] sourceCarriersWave14_1 = [
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

import tests.unit.census_symbols : exists = wave15Exists;
    import std.path : buildPath;
    foreach (relative; [
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
        size_t occurrences;
        foreach (candidate; sourceCarriersWave14_1) if (candidate == relative) ++occurrences;
        assert(occurrences == 1, "Wave14 logical source input missing/duplicate: " ~ relative);

    }
    foreach (sourceCarrier; sourceCarriersWave14_1) {
        const sourceCarrierPath = buildPath(repoRoot, sourceCarrier);
        const src = blankUnittestBodies(blankNonCode(readText(sourceCarrierPath)));
        auto mm = src.matchFirst(regex(`(?m)^\s*module\s+([A-Za-z0-9_.]+)\s*;`));
        const moduleName = mm.empty ? "<missing-module>" : mm[1];
        result.classes ~= classesIn(moduleName, src);

        const bool inHandles = sourceCarrierPath.canFind(buildPath("source", "handles"));
        if (inHandles) {
            result.legacyOverrides += occurrences(src, "override void draw(");
            result.drawImplOverrides +=
                occurrences(src, "protected override void drawImpl(");
        }
        result.directDrawImplCalls += occurrences(src, ".drawImpl(");

        const auto syms = enclosingSymbols(src);
        foreach (li, line; src.splitLines()) {
            if (line.canFind("g_fc.handleDraw("))
                result.handleDrawOwners ~= symbolAt(syms, li);
            if (moduleName != "perf_probe"
                && line.canFind("g_fc.noteHandleSubmission("))
                result.manualReceiptOwners ~= symbolAt(syms, li);
        }

    }
    return result;
}

private struct Closure {
    string[] names;
    string[] modules;
}

private Closure handlerClosure(const ClassDecl[] classes) {
    string[] reached = ["Handler"];
    Closure result;
    bool changed;
    do {
        changed = false;
        foreach (d; classes) {
            if (reached.canFind(d.name)) continue;
            bool derived;
            foreach (base; d.bases)
                if (reached.canFind(base)) { derived = true; break; }
            if (!derived) continue;
            reached ~= d.name;
            result.names ~= d.name;
            if (!result.modules.canFind(d.moduleName))
                result.modules ~= d.moduleName;
            changed = true;
        }
    } while (changed);
    return result;
}

unittest {
    auto scan = scanTree();
    auto closure = handlerClosure(scan.classes);
    static immutable string[] expectedModules = [
        "handles.arbiter", "handles.shapes", "tools.transform.scale",
    ];

    assert(scan.legacyOverrides == 0,
           "G2 r1: source/handles regained "
           ~ scan.legacyOverrides.to!string ~ " `override void draw` declaration(s)");
    assert(sameSet(closure.names, kCensusHandlerNames)
           && sameSet(closure.modules, expectedModules),
           "G2 r2 closure: names missing ["
           ~ missingFrom(kCensusHandlerNames, closure.names)
           ~ "], names unrecorded ["
           ~ missingFrom(closure.names, kCensusHandlerNames)
           ~ "], modules missing ["
           ~ missingFrom(expectedModules, closure.modules)
           ~ "], modules unrecorded ["
           ~ missingFrom(closure.modules, expectedModules) ~ "]");
    assert(scan.handleDrawOwners ==
           ["Handler.draw", "CubicArrow.drawHeadOnly"],
           "G2 r3 handleDraw owners changed: expected Handler.draw and "
           ~ "CubicArrow.drawHeadOnly exactly once each, got ["
           ~ missingFrom(scan.handleDrawOwners, []) ~ "]");
    assert(scan.manualReceiptOwners == ["CenterDiskGizmo.drawImpl"],
           "G2 r4 manual receipt owners changed: got ["
           ~ missingFrom(scan.manualReceiptOwners, []) ~ "]");
    assert(scan.drawImplOverrides == 11,
           "G2 r5 expected 11 protected drawImpl overrides, got "
           ~ scan.drawImplOverrides.to!string);
    assert(scan.directDrawImplCalls == 0,
           "G2 r5 found a direct member drawImpl call outside Handler.draw");
}
