// Task 6020: the shared reset effects, the two registered reset doors that bind
// them, and the production text that builds the capability. R2 drives the real
// registration families and both defensive slice casts through the real command
// binding; R3 pins the inline production construction that R2 cannot observe.
module tests.unit.commands.scene.scene_reset_effects_test;

import application_command_binding : CommandInvocationContext,
    CommandInvocationOutcome;
import command : CommandOrigin;
import core.exception : AssertError;
import editmode : EditMode;
import editor_app : EditorApp;
import mesh : MapKind, Mesh, SubpatchTrace, makeCube;
import mesh_gpu : GpuMesh;
import morph_target : morphTargetName, setMorphTarget, clearMorphTarget;
import prefs : Prefs;
import registration : registerSceneResetFamiliesForTest;
import scene_reset_effects : SceneResetEffects;
import shader : LitShader;
import std.algorithm : count;
import std.array : join;
import std.conv : to;
import std.exception : assertThrown;
import std.file : exists, readText;
import std.path : buildNormalizedPath, dirName;
import std.string : indexOf, split;
import subpatch_preview : SubpatchPreview;
import tests.unit.census_symbols : blankNonCode;
import tests.unit.live_registration_rig : LiveRegistrationRig;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import tools.slice.edge_slice_tool : EdgeSliceTool;
import tools.slice.loop_slice_tool : LoopSliceTool;
import viewport : LayoutPreset, ViewportManager;

private string repoFile(string relative) {
    const path = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..", "..", "..", relative);
    assert(exists(path), "6020 production census cannot find " ~ relative);
    return readText(path);
}

private string collapseWhitespace(string text) {
    return text.split().join(" ");
}

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

private struct PhaseSnapshot {
    long cells;
    LayoutPreset prefsLayout;
    size_t drops;
    size_t pipes;
    bool previewActive;
    EditMode mode;
    string morph;
    bool loopSlice;
    bool edgeSlice;
    bool sliceDragging;
}

unittest { // R2: both production doors and both slice casts through the real families
    scope(exit) clearMorphTarget();
    auto rig = new LiveRegistrationRig;
    auto viewports = new ViewportManager(0, 0, 800, 600);
    SubpatchPreview preview;
    Prefs prefs;
    PhaseSnapshot[] atPromote;
    PhaseSnapshot[] atDrop;
    size_t drops, pipes;

    PhaseSnapshot snap() {
        auto loop = cast(LoopSliceTool) rig.activeTool;
        auto edge = cast(EdgeSliceTool) rig.activeTool;
        const dragging = loop !is null ? loop.isDragging()
            : edge !is null ? edge.isDragging() : false;
        return PhaseSnapshot(viewports.cellCount, prefs.viewportLayout, drops, pipes,
                             preview.active, rig.session.editMode,
                             morphTargetName().idup, loop !is null, edge !is null,
                             dragging);
    }

    ref Mesh liveMesh() nothrow @nogc { return rig.session.editMesh(); }
    EditorApp app;
    app.meshDg = cast(typeof(app.meshDg)) &liveMesh;
    app.sessionOwner = rig.session;
    app.regPtr = &rig.registry;
    app.cameraViewDg = &rig.liveView;
    app.activeToolPtr = &rig.activeTool;
    app.subpatchPreviewPtr = &preview;
    app.vpm = viewports;
    app.dropActiveTool = (ToolTransition t) {
        atDrop ~= snap();
        ++drops;
        rig.activeTool = null;
    };
    app.resetAllPipeStages = () { ++pipes; };
    app.promoteGeometryType = (EditMode m) {
        atPromote ~= snap();
        rig.session.promoteGeometryType(m);
    };
    registerSceneResetFamiliesForTest(app, SceneResetEffects(app.vpm,
        app.subpatchPreviewPtr, &prefs, app.dropActiveTool, app.resetAllPipeStages));
    assert("file.new" in rig.registry.commandFactories
        && "scene.reset" in rig.registry.commandFactories,
        "6020 R2 floor: the production families did not register both doors");

    size_t doorsChecked, loopCastsChecked, edgeCastsChecked;
    foreach (door; ["file.new", "scene.reset"]) {
        foreach (sliceKind; ["loop", "edge"]) {
            atPromote = null; atDrop = null; drops = 0; pipes = 0;
            rig.session.switchGeometryType(EditMode.Polygons);
            viewports.applyLayout(LayoutPreset.Quad);
            prefs.viewportLayout = LayoutPreset.Quad;
            primeTopologyCache(preview);
            setMorphTarget("probe", MapKind.morphRelative);

            Mesh sliceMesh = makeCube();
            GpuMesh sliceGpu;
            EditMode sliceMode = EditMode.Edges;
            Mesh* sliceMeshSource() nothrow @nogc { return &sliceMesh; }
            Tool sliceTool;
            if (sliceKind == "loop") {
                auto loop = new LoopSliceTool(&sliceMeshSource, &sliceGpu,
                    &sliceMode, LitShader.init);
                loop.seedPreparedActivationForTest();
                sliceTool = loop;
            } else {
                auto edge = new EdgeSliceTool(&sliceMeshSource, &sliceGpu,
                    &sliceMode, LitShader.init);
                edge.seedPreparedActivationForTest(sliceMesh);
                sliceTool = edge;
            }
            rig.activeTool = sliceTool;
            assert(rig.session.editMode == EditMode.Polygons && viewports.cellCount == 4
                    && preview.active && morphTargetName() == "probe"
                    && rig.activeTool !is null && rig.activeTool.isDragging(),
                "6020 R2 floor: " ~ door ~ "/" ~ sliceKind
                ~ " must start from distinguishable old and armed-slice state");

            auto result = rig.binding.invokeLine(door, "",
                CommandInvocationContext(CommandOrigin.script, false));
            assert(result.outcome == CommandInvocationOutcome.applied,
                "6020 R2 " ~ door ~ "/" ~ sliceKind
                ~ " did not apply through the production binding");
            assert(atPromote.length == 1 && atDrop.length == 1 && pipes == 1,
                "6020 R2 " ~ door ~ "/" ~ sliceKind ~ " phase population: promote "
                ~ atPromote.length.to!string ~ ", drop " ~ atDrop.length.to!string
                ~ ", pipes " ~ pipes.to!string);
            assert(atPromote[0].drops == 0 && atPromote[0].previewActive,
                "6020 R2 " ~ door ~ "/" ~ sliceKind
                ~ " tool effects ran in the viewport phase");
            assert(atPromote[0].cells == 1,
                "6020 R2 " ~ door ~ "/" ~ sliceKind
                ~ " viewport effect did not run before the mode reset");
            assert(atPromote[0].prefsLayout == LayoutPreset.Single,
                "6020 R2 " ~ door ~ "/" ~ sliceKind
                ~ " preferences were not mirrored in the viewport phase");
            assert(atDrop[0].mode == EditMode.Vertices && atDrop[0].morph.length == 0,
                "6020 R2 " ~ door ~ "/" ~ sliceKind
                ~ " tool effects ran before the mode and morph resets");
            assert(atDrop[0].previewActive && atDrop[0].pipes == 0,
                "6020 R2 " ~ door ~ "/" ~ sliceKind
                ~ " tool effects are out of order at the drop");
            const expectedLoop = sliceKind == "loop";
            assert(atDrop[0].loopSlice == expectedLoop
                    && atDrop[0].edgeSlice == !expectedLoop,
                "6020 R2 " ~ door ~ "/" ~ sliceKind
                ~ " did not reach its own slice cast at the drop probe");
            const expectedDragging = door == "scene.reset";
            assert(atDrop[0].sliceDragging == expectedDragging,
                "6020 R2 " ~ door ~ "/" ~ sliceKind
                ~ " defensive slice prelude did not run before the shared tool effects");
            assert(!preview.active && !preview.osdAccel.valid,
                "6020 R2 " ~ door ~ "/" ~ sliceKind
                ~ " left the preview or its topology cache live");
            const vertices = rig.session.editMesh().vertices.length;
            assert(door == "file.new" ? vertices == 0 : vertices == 8,
                "6020 R2 " ~ door ~ "/" ~ sliceKind
                ~ " empty mode is wrong: " ~ vertices.to!string ~ " vertices");
            ++doorsChecked;
            expectedLoop ? ++loopCastsChecked : ++edgeCastsChecked;
        }
    }
    assert(doorsChecked == 4 && loopCastsChecked == 2 && edgeCastsChecked == 2,
        "6020 R2 both doors and both slice casts must be checked");
}

unittest { // R3: production text the behaviour cells cannot reach
    const registrationRaw = repoFile("source/registration.d");
    const effectsRaw = repoFile("source/scene_reset_effects.d");
    const appRaw = repoFile("source/app.d");
    assert(registrationRaw.length > 50_000 && effectsRaw.length > 1_000
        && appRaw.length > 100_000,
        "6020 R3 source population floor: a production file is implausibly small");
    const registration = blankNonCode(registrationRaw);
    const effects = blankNonCode(effectsRaw);
    const app = blankNonCode(appRaw);
    const registrationFlat = collapseWhitespace(registration);

    enum fileCall = "registerFileCommands(app, SceneResetEffects(app.vpm, "
        ~ "app.subpatchPreviewPtr, &g_prefs, app.dropActiveTool, "
        ~ "app.resetAllPipeStages));";
    enum sceneCall = "registerSceneLifecycleCommands(app, SceneResetEffects(app.vpm, "
        ~ "app.subpatchPreviewPtr, &g_prefs, app.dropActiveTool, "
        ~ "app.resetAllPipeStages));";
    assert(registrationFlat.count(fileCall) == 1
            && registrationFlat.count(sceneCall) == 1,
        "6020 R3 production calls no longer build the capability inline from the app's own inputs");
    assert(registration.count("SceneResetEffects(") == 2,
        "6020 R3 the capability must be constructed exactly at the two family calls");
    const wrapperAt = registrationFlat.indexOf(
        "auto selTypeSrc = () => currentSelType(selTypeOrder);");
    assert(wrapperAt > registrationFlat.indexOf(fileCall)
        && wrapperAt > registrationFlat.indexOf(sceneCall),
        "6020 R3 reset registration moved after the selection-type wrapper");

    enum sceneSlots = "auto c = new SceneReset(&mesh(), cameraView, editMode, "
        ~ "&editMode(), () => resetEffects.resetToolEffects(), "
        ~ "() => resetEffects.resetViewport());";
    assert(registrationFlat.count(sceneSlots) == 1,
        "6020 R3 scene.reset no longer binds tool then viewport effects to their own slots");
    enum fileSlots = "if (auto lst = cast(LoopSliceTool) activeTool) "
        ~ "lst.dropArmedPreview(); if (auto est = cast(EdgeSliceTool) activeTool) "
        ~ "est.dropArmedPreview(); resetEffects.resetToolEffects(); }, "
        ~ "() => resetEffects.resetViewport());";
    assert(registrationFlat.count(fileSlots) == 1,
        "6020 R3 file.new lost its slice fallback before the shared tool effects, "
        ~ "or its slot binding");
    foreach (retired; ["vpm.resetToDefault()", "subpatchPreview.deactivate()",
                       "subpatchPreview.dropTopologyCache()", "resetAllPipeStages()",
                       "g_prefs.viewportLayout"])
        assert(registration.count(retired) == 0,
            "6020 R3 registration.d regained a private copy of a shared reset effect: " ~ retired);
    // Ids are string literals, which blankNonCode blanks in place, so they are
    // located in the raw text; offsets are shared because blanking keeps length.
    const fileNewAt = registrationRaw.indexOf(`reg.commandFactories["file.new"]`);
    const quitAt = registrationRaw.indexOf(`reg.commandFactories["file.quit"]`);
    const emptyAt = registration.indexOf("c.setEmpty(true);");
    assert(registration.count("c.setEmpty(true);") == 1 && fileNewAt >= 0
        && emptyAt > fileNewAt && emptyAt < quitAt,
        "6020 R3 empty mode must stay on file.new alone");

    foreach (forbidden; ["EditorApp", "editor_app", "with ("])
        assert(effects.count(forbidden) == 0,
            "6020 R3 the capability module reached application state: " ~ forbidden);

    const registerAt = app.indexOf("registerCommands(app);");
    assert(app.count("registerCommands(app);") == 1 && registerAt > 0,
        "6020 R3 app.d registration population floor");
    foreach (assignment; ["app.subpatchPreviewPtr  = &subpatchPreview;",
                          "app.vpm             = vpm;",
                          "app.dropActiveTool       = cast(void delegate(ToolTransition))&dropActiveTool;",
                          "app.resetAllPipeStages   = cast(void delegate())&resetAllPipeStages;"]) {
        const at = app.indexOf(assignment);
        assert(app.count(assignment) == 1 && at >= 0 && at < registerAt,
            "6020 R3 capability input is not assigned once before registerCommands: " ~ assignment);
    }
}
