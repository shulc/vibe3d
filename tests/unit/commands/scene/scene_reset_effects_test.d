// Task 6020: the reset-effects capability and the order of its effects. The
// lifecycle registrar and its production wiring are covered separately by
// scene_file_lifecycle_registration_test (task 6480).
module tests.unit.commands.scene.scene_reset_effects_test;

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

/// Every `.reset()` a loop over `pipeline.allMut()` makes: the loop body (a
/// braced block, or the single statement up to its `;`) after each `allMut()`.
private string[] fullPipeResetSites(string code, string file, ref size_t loops) {
    import std.format : format;
    import std.string : indexOf;
    import tests.unit.census_symbols : balancedSpan, lineOf;
    string[] sites;
    enum needle = "allMut()";
    for (ptrdiff_t at = code.indexOf(needle); at >= 0;
            at = code.indexOf(needle, at + needle.length)) {
        ++loops;
        size_t p = at + needle.length;
        while (p < code.length && (code[p] == ' ' || code[p] == '\n')) ++p;
        if (p < code.length && code[p] == ')') ++p;   // the foreach header
        while (p < code.length && (code[p] == ' ' || code[p] == '\n')) ++p;
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
    import std.algorithm : endsWith;
    import std.file : dirEntries, readText, SpanMode;
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
        ~ "void h() { foreach (s; p.allMut()) s.resetCounter(); }\n", "ctl", ctlLoops);
    assert(ctlLoops == 3 && ctl == ["ctl:2", "ctl:5"],
        "9465 control: the scanner must see both loop shapes: " ~ ctl.to!string);

    const root = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..", "..", "..");
    size_t loops, retiredIdent;
    string[] sites;
    foreach (de; dirEntries(buildNormalizedPath(root, "source"), "*.d", SpanMode.depth)) {
        if (de.name.endsWith("_test.d")) continue;
        const code = blankNonCode(readText(de.name));
        retiredIdent += countIdent(code, "resetAllPipeStages");
        sites ~= fullPipeResetSites(code, relativePath(de.name, root), loops);
    }
    // Floor (measured 2026-10-05: `grep -rno "allMut()" source --include=*.d
    // | wc -l` = 10: nine call sites plus the declaration in toolpipe/pipeline.d).
    assert(loops >= 10,
        "9465 floor: allMut() sites scanned " ~ loops.to!string);
    assert(retiredIdent == 0,
        "9465: resetAllPipeStages returned — the second stage reset per scene reset");
    assert(sites.length == 1 && sites[0].indexOf("source/commands/scene/reset.d:") == 0,
        "9465: a full pipe-stage reset loop outside SceneReset.apply: " ~ sites.to!string);
}
