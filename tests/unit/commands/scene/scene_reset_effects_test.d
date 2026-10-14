// Task 6020: the reset-effects capability and the order of its effects. The
// lifecycle registrar and its production wiring are covered separately by
// scene_file_lifecycle_registration_test (task 6480).
module tests.unit.commands.scene.scene_reset_effects_test;

import tests.unit.census_symbols : wave15InputStart, wave15InputsIntact;



import tests.unit.census_symbols : exists = wave15Exists;

import core.exception : AssertError;
import mesh : MapKind, Mesh, SubpatchTrace, makeCube;
import prefs : Prefs;
import scene_reset_effects : SceneResetEffects;
import std.conv : to;
import std.exception : assertThrown;
import subpatch_preview : SubpatchPreview;
import tool_activation_ownership : ToolTransition;
import viewport : LayoutPreset, ViewportManager;

/// Fill the topology cache for real, so dropping it has something to retire.
private long primeTopologyCache(ref SubpatchPreview preview) {
    Mesh cage = makeCube();
    cage.resizeSubpatch();
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);
    Mesh built;
    SubpatchTrace trace;
    assert(preview.osdAccel.buildPreview(cage, 2, built, trace),
        "6020 floor: headless subdivision build failed");
    preview.active = true;
    preview.reusablePreviewReady = true;
    preview.reusablePreviewKey = 42;
    return cast(long) (preview.osdAccel.topologiesCreated - preview.osdAccel.topologiesRetired);
}

unittest { // R1: the capability's effects and their order, one method at a time
    auto viewports = new ViewportManager(0, 0, 800, 600);
    viewports.applyLayout(LayoutPreset.Quad);
    SubpatchPreview preview;
    const live = primeTopologyCache(preview);
    const retiredBefore = preview.osdAccel.topologiesRetired;
    Prefs prefs;
    prefs.viewportLayout = LayoutPreset.Quad;
    string[] log;
    auto drop = (ToolTransition t) {
        log ~= "drop:" ~ t.to!string ~ (preview.active ? ":preview-live" : ":preview-off");
    };
    assert(viewports.cellCount == 4 && live >= 1 && preview.osdAccel.valid,
        "6020 R1 floor: four cells and one cached topology before the reset");

    auto effects = SceneResetEffects(viewports, &preview, &prefs, drop);
    effects.resetViewport();
    assert(viewports.cellCount == 1 && viewports.activeId == 0,
        "6020 R1 viewport effect did not restore the single default cell");
    assert(prefs.viewportLayout == LayoutPreset.Single,
        "6020 R1 viewport effect did not mirror Single into preferences");
    assert(log.length == 0 && preview.active,
        "6020 R1 viewport effect reached a tool effect");

    effects.resetToolEffects();
    assert(log == ["drop:sceneResetDrop:preview-live"],
        "6020 R1 tool effects order: " ~ log.to!string);
    assert(!preview.active && !preview.reusablePreviewReady && preview.reusablePreviewKey == 0,
        "6020 R1 tool effects left the subpatch preview live");
    assert(!preview.osdAccel.valid
            && preview.osdAccel.topologiesRetired - retiredBefore == live,
        "6020 R1 tool effects did not retire every cached topology");

    void delegate(ToolTransition) noDrop;
    size_t refusals;
    assertThrown!AssertError(SceneResetEffects(null, &preview, &prefs, drop)); ++refusals;
    assertThrown!AssertError(SceneResetEffects(viewports, null, &prefs, drop)); ++refusals;
    assertThrown!AssertError(SceneResetEffects(viewports, &preview, null, drop)); ++refusals;
    assertThrown!AssertError(SceneResetEffects(viewports, &preview, &prefs, noDrop)); ++refusals;
    assert(refusals == 4, "6020 R1 every capability input must be required");
}

/// Every `.reset()` a loop over `pipeline.allMut` makes: the loop body (a
/// braced block, or the single statement up to its `;`) after each whole
/// identifier `allMut`, called with or without `()`.
private string[] fullPipeResetSites(string code, string file, ref size_t loops) {
    import std.format : format;
    import std.string : indexOf;
    import tests.unit.census_symbols : balancedSpan, isIdentChar, lineOf;
    string[] sites;
    enum needle = "allMut";
    for (ptrdiff_t at = code.indexOf(needle); at >= 0;
            at = code.indexOf(needle, at + needle.length)) {
        size_t p = at + needle.length;
        if ((at > 0 && isIdentChar(code[at - 1]))
                || (p < code.length && isIdentChar(code[p]))) continue;
        ++loops;
        void skipSpace() {
            while (p < code.length && (code[p] == ' ' || code[p] == '\n')) ++p;
        }
        skipSpace();
        if (p + 1 < code.length && code[p .. p + 2] == "()") p += 2;
        skipSpace();
        if (p < code.length && code[p] == ')') ++p;   // the foreach header
        skipSpace();
        string body;
        if (p < code.length && code[p] == '{') body = balancedSpan(code, p, '{', '}');
        else {
            const semi = code.indexOf(';', p);
            body = semi < 0 ? "" : code[p .. semi + 1];
        }
        if (body.indexOf(".reset()") >= 0)
            sites ~= format("%s:%d", file, lineOf(code, at));
    }
    return sites;
}

unittest { // 9465: ONE full pipe-stage reset per scene reset, and it is SceneReset's
    auto wave15Inputs = wave15InputStart();
    import std.algorithm : endsWith;
    import std.file : SpanMode;
import tests.unit.census_symbols : dirEntries = wave15DirEntries, readText = wave15ReadText;
    import std.meta : AliasSeq;
    import std.path : buildNormalizedPath, dirName, relativePath;
    import std.string : indexOf;
    import std.traits : Parameters;
    import tests.unit.census_symbols : blankNonCode, countIdent;

    // Fence: the capability holds the tool drop and nothing that resets the
    // pipe, and its tool effects take no keep-pipe flag (SceneReset's
    // `keepsToolPipe` is the one reader).
    static assert(is(typeof(SceneResetEffects.tupleof) == AliasSeq!(
        ViewportManager, SubpatchPreview*, Prefs*, void delegate(ToolTransition))));
    static assert(Parameters!(SceneResetEffects.resetToolEffects).length == 0);

    // Positive control: the retired delegate's shape is a site.
    size_t ctlLoops;
    const ctl = fullPipeResetSites(
        "void f() {\n    foreach (s; g_pipeCtx.pipeline.allMut())\n        s.reset();\n}\n"
        ~ "void g() { foreach (s; p.allMut()) { int y; if (x) s.reset(); } }\n"
        ~ "void h() { foreach (s; p.allMut()) s.resetCounter(); }\n"
        ~ "void i() { foreach (s; p.allMut) s.reset(); allMutable(); }\n", "ctl", ctlLoops);
    assert(ctlLoops == 4 && ctl == ["ctl:2", "ctl:5", "ctl:7"],
        "9465 control: the scanner must see both loop shapes: " ~ ctl.to!string);

    const root = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..", "..", "..");
    size_t loops, retiredIdent;
    string[] sites, scanFiles;
    foreach (scanSourceRoot; [buildNormalizedPath(root, "source"), buildNormalizedPath(root, "packages/command-runtime/source"), buildNormalizedPath(root, "packages/application-core/source"), buildNormalizedPath(root, "packages/camera-model/source"), buildNormalizedPath(root, "packages/document-channels/source"), buildNormalizedPath(root, "packages/image-codec/source"), buildNormalizedPath(root, "packages/document-io/source"), buildNormalizedPath(root, "packages/document-model/source"), buildNormalizedPath(root, "packages/param-schema/source"), buildNormalizedPath(root, "packages/pipe-runtime/source"), buildNormalizedPath(root, "packages/mesh-ops/source"), buildNormalizedPath(root, "packages/interchange/source"), buildNormalizedPath(root, "packages/interaction-query/source"), buildNormalizedPath(root, "packages/pipe-evaluation/source"), buildNormalizedPath(root, "packages/tool-state/source"), buildNormalizedPath(root, "packages/transform-ops/source"), buildNormalizedPath(root, "packages/creation-ops/source"), buildNormalizedPath(root, "packages/alignment-ops/source"), buildNormalizedPath(root, "packages/input-events/source"), buildNormalizedPath(root, "packages/display-policy/source"), buildNormalizedPath(root, "packages/viewport-gpu/source"), buildNormalizedPath(root, "packages/subpatch-preview/source"), buildNormalizedPath(root, "packages/edit-contracts/source"), buildNormalizedPath(root, "packages/mesh-change/source"), buildNormalizedPath(root, "packages/mesh-contracts/source"), buildNormalizedPath(root, "packages/mesh-edit-log/source"), buildNormalizedPath(root, "packages/mesh-edit-replay/source"), buildNormalizedPath(root, "packages/mesh-snapshot/source"), buildNormalizedPath(root, "packages/mesh-topology/source"), buildNormalizedPath(root, "packages/mesh/source"), buildNormalizedPath(root, "packages/profiling/source"), buildNormalizedPath(root, "packages/spatial/source"), buildNormalizedPath(root, "util/log/source"), buildNormalizedPath(root, "util/math/source"), buildNormalizedPath(root, "util/parallel/source"), buildNormalizedPath(root, "util/plane-bytes/source"), buildNormalizedPath(root, "util/screen-buckets/source"), "packages/selection-model/source", "packages/scene-query/source", "packages/editor-commands/source"])

    foreach (de; dirEntries(scanSourceRoot, "*.d", SpanMode.depth)) {
        if (de.name.endsWith("_test.d")) continue;
        scanFiles ~= de.name;
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
    foreach (sourceCarrier; sourceCarriersWave14_1)
        scanFiles ~= buildNormalizedPath(root, sourceCarrier);
    // The original scanner also read this carrier's in-module public bodies.
    scanFiles ~= buildNormalizedPath(root,
        "packages/pipe-runtime/tests/source/tests/unit/toolpipe/pipeline_registration_test.d");
    foreach (sourceFile; scanFiles) {
        const code = blankNonCode(readText(sourceFile));
        retiredIdent += countIdent(code, "resetAllPipeStages");
        sites ~= fullPipeResetSites(code, relativePath(sourceFile, root), loops);
    }
    // Floor, then the needle, then the pin (measured 2026-10-05: `grep -rnow
    // allMut source --include=*.d | wc -l` = 10: nine uses plus the declaration
    // in toolpipe/pipeline.d).
    assert(loops >= 10, "9465 floor: allMut sites scanned " ~ loops.to!string);
    assert((retiredIdent == 0) && wave15InputsIntact(wave15Inputs),
        "9465: resetAllPipeStages returned — the second stage reset per scene reset");
    assert(sites.length == 1 && sites[0].indexOf("source/commands/scene/reset.d:") == 0,
        "9465: a full pipe-stage reset loop outside SceneReset.apply: " ~ sites.to!string);
    assert(loops == 10, "9465 pin: allMut sites changed to " ~ loops.to!string
        ~ "; read each new site (a stage loop through a local is not seen by the"
        ~ " needle) and update the measured count");
}
