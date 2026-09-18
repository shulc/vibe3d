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
    auto pipes = () {
        log ~= "pipes" ~ (preview.active ? ":preview-live" : ":preview-off");
    };
    assert(viewports.cellCount == 4 && live >= 1 && preview.osdAccel.valid,
        "6020 R1 floor: four cells and one cached topology before the reset");

    auto effects = SceneResetEffects(viewports, &preview, &prefs, drop, pipes);
    effects.resetViewport();
    assert(viewports.cellCount == 1 && viewports.activeId == 0,
        "6020 R1 viewport effect did not restore the single default cell");
    assert(prefs.viewportLayout == LayoutPreset.Single,
        "6020 R1 viewport effect did not mirror Single into preferences");
    assert(log.length == 0 && preview.active,
        "6020 R1 viewport effect reached a tool effect");

    effects.resetToolEffects();
    assert(log == ["drop:sceneResetDrop:preview-live", "pipes:preview-live"],
        "6020 R1 tool effects order: " ~ log.to!string);
    assert(!preview.active && !preview.reusablePreviewReady && preview.reusablePreviewKey == 0,
        "6020 R1 tool effects left the subpatch preview live");
    assert(!preview.osdAccel.valid
            && preview.osdAccel.topologiesRetired - retiredBefore == live,
        "6020 R1 tool effects did not retire every cached topology");

    void delegate(ToolTransition) noDrop;
    void delegate() noPipes;
    size_t refusals;
    assertThrown!AssertError(SceneResetEffects(null, &preview, &prefs, drop, pipes)); ++refusals;
    assertThrown!AssertError(SceneResetEffects(viewports, null, &prefs, drop, pipes)); ++refusals;
    assertThrown!AssertError(SceneResetEffects(viewports, &preview, null, drop, pipes)); ++refusals;
    assertThrown!AssertError(SceneResetEffects(viewports, &preview, &prefs, noDrop, pipes)); ++refusals;
    assertThrown!AssertError(SceneResetEffects(viewports, &preview, &prefs, drop, noPipes)); ++refusals;
    assert(refusals == 5, "6020 R1 every capability input must be required");
}
