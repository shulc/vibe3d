// Task 6480: one narrow registrar owns file.new/file.quit and
// scene.reset/scene.loadMesh. Behaviour cells precede the source census so
// lifecycle mutations report their behavioural red before textual fallout.
module tests.unit.commands.scene.scene_file_lifecycle_registration_test;

import application_command_binding : CommandInvocationContext,
    CommandInvocationOutcome;
import command : Command, CommandOrigin;
static import command;
import core.exception : AssertError;
import document : Layer;
import editmode : EditMode;
import mesh : MapKind, Mesh, SubpatchTrace, makeCube, makeOctahedron;
import mesh_gpu : GpuMesh;
import morph_target : clearMorphTarget, morphTargetName, setMorphTarget;
import prefs : Prefs;
import scene_file_lifecycle_registration : SceneLifecycleDoors,
    registerSceneFileLifecycleCommands;
import scene_reset_effects : SceneResetEffects;
import seltype : SelType;
import shader : LitShader;
import std.algorithm : count;
import std.array : join;
import std.conv : to;
import std.file : exists, readText;
import std.path : buildNormalizedPath, dirName;
import std.string : indexOf, split;
import subpatch_preview : SubpatchPreview;
import tests.unit.census_symbols : blankNonCode;
import tests.unit.live_registration_rig : LiveRegistrationRig;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import tool_disarm : DisarmMode, DisarmOutcome, g_disarmActiveTool,
    g_lastDisarm, kMaxDisarmSteps;
import tools.slice.edge_slice_tool : EdgeSliceTool;
import tools.slice.loop_slice_tool : LoopSliceTool;
import viewport : LayoutPreset, ViewportManager;

private string repoFile(string relative) {
    const path = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..",
                                     "..", "..", relative);
    assert(exists(path), "6480 production census cannot find " ~ relative);
    return readText(path);
}

private string collapseWhitespace(string text) {
    return text.split().join(" ");
}

/// Fill the real topology cache so a full reset and a narrow drop differ.
private long primeTopologyCache(ref SubpatchPreview preview) {
    Mesh cage = makeCube();
    cage.resizeSubpatch();
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);
    Mesh built;
    SubpatchTrace trace;
    assert(preview.osdAccel.buildPreview(cage, 2, built, trace),
        "6480 floor: headless subdivision build failed");
    preview.active = true;
    preview.reusablePreviewReady = true;
    preview.reusablePreviewKey = 42;
    return cast(long) (preview.osdAccel.topologiesCreated
                     - preview.osdAccel.topologiesRetired);
}

private struct PhaseSnapshot {
    long cells;
    LayoutPreset prefsLayout;
    size_t drops;
    size_t pipes;
    size_t vertices;
    bool previewActive;
    EditMode mode;
    string morph;
    bool loopSlice;
    bool edgeSlice;
    bool sliceDragging;
}

unittest { // R2: both reset doors cross the production-shaped disarm phase first
    scope(exit) clearMorphTarget();
    auto rig = new LiveRegistrationRig;
    auto viewports = new ViewportManager(0, 0, 800, 600);
    SubpatchPreview preview;
    Prefs prefs;
    PhaseSnapshot[] atPromote;
    PhaseSnapshot[] atDrop;
    ToolTransition[] dropTransitions;
    size_t drops, pipes;

    PhaseSnapshot snap() {
        auto loop = cast(LoopSliceTool) rig.activeTool;
        auto edge = cast(EdgeSliceTool) rig.activeTool;
        const dragging = loop !is null ? loop.isDragging()
            : edge !is null ? edge.isDragging() : false;
        return PhaseSnapshot(viewports.cellCount, prefs.viewportLayout, drops,
                             pipes, rig.session.editMesh().vertices.length,
                             preview.active, rig.session.editMode,
                             morphTargetName().idup, loop !is null,
                             edge !is null, dragging);
    }

    auto drop = (ToolTransition transition) {
        atDrop ~= snap();
        dropTransitions ~= transition;
        ++drops;
        rig.activeTool = null;
    };
    auto resetPipes = () { ++pipes; };
    auto promote = (EditMode mode) {
        atPromote ~= snap();
        rig.session.promoteGeometryType(mode);
    };
    registerSceneFileLifecycleCommands(rig.registry, rig.liveSession(),
        rig.liveViewMode(), SceneResetEffects(viewports, &preview, &prefs,
            drop, resetPipes), SceneLifecycleDoors(promote, () {},
            () => drop(ToolTransition.sceneResetDrop)));
    assert(rig.registry.commandFactories.length == 4
            && "file.new" in rig.registry.commandFactories
            && "file.quit" in rig.registry.commandFactories
            && "scene.reset" in rig.registry.commandFactories
            && "scene.loadMesh" in rig.registry.commandFactories,
        "6480 R2 population: the registrar must own exactly four lifecycle ids");

    // This is intentionally the same algorithmic body as app.d's seam. The
    // live suite mutation M1, not this copy, closes production wiring drift.
    g_disarmActiveTool = (DisarmMode mode) {
        DisarmOutcome outcome;
        if (rig.activeTool is null) return outcome;
        outcome.hadTool = true;
        if (mode == DisarmMode.cancelAndDrop) {
            while (rig.activeTool.hasUncommittedEdit()
                   && outcome.cancelSteps < kMaxDisarmSteps) {
                rig.activeTool.cancelUncommittedEdit();
                ++outcome.cancelSteps;
            }
        }
        outcome.stillArmed = rig.activeTool.hasUncommittedEdit();
        drop(ToolTransition.documentReplaceDisarm);
        return outcome;
    };
    scope(exit) g_disarmActiveTool = null;

    size_t doorsChecked, loopKindsChecked, edgeKindsChecked;
    foreach (door; ["file.new", "scene.reset"]) {
        foreach (sliceKind; ["loop", "edge"]) {
            atPromote = null;
            atDrop = null;
            dropTransitions = null;
            drops = 0;
            pipes = 0;
            rig.session.editMesh() = makeCube();
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
            const verticesBefore = rig.session.editMesh().vertices.length;
            assert(verticesBefore == 8
                    && rig.session.editMode == EditMode.Polygons
                    && viewports.cellCount == 4 && preview.active
                    && morphTargetName() == "probe"
                    && rig.activeTool !is null && rig.activeTool.isDragging(),
                "6480 R2 floor: " ~ door ~ "/" ~ sliceKind
                ~ " lacks old geometry, layout, preview, morph or slice state");

            auto result = rig.binding.invokeLine(door, "",
                CommandInvocationContext(CommandOrigin.script, false));
            assert(result.outcome == CommandInvocationOutcome.applied,
                "6480 R2 " ~ door ~ "/" ~ sliceKind
                ~ " did not apply through the production binding");
            assert(atPromote.length == 1 && atDrop.length == 2
                    && dropTransitions.length == 2 && pipes == 1,
                "6480 R2 " ~ door ~ "/" ~ sliceKind
                ~ " phase population: promote " ~ atPromote.length.to!string
                ~ ", drop " ~ atDrop.length.to!string ~ ", transitions "
                ~ dropTransitions.length.to!string ~ ", pipes " ~ pipes.to!string);
            assert(atDrop[0].vertices == verticesBefore
                    && atDrop[0].mode == EditMode.Polygons
                    && atDrop[0].morph == "probe" && atDrop[0].pipes == 0
                    && atDrop[0].previewActive
                    && dropTransitions[0] == ToolTransition.documentReplaceDisarm,
                "6480 R2 " ~ door ~ "/" ~ sliceKind
                ~ " disarm phase did not precede geometry and reset effects");
            const expectedLoop = sliceKind == "loop";
            assert(atDrop[0].loopSlice == expectedLoop
                    && atDrop[0].edgeSlice == !expectedLoop
                    && atDrop[0].sliceDragging,
                "6480 R2 " ~ door ~ "/" ~ sliceKind
                ~ " disarm phase did not observe the seeded slice kind");
            assert(atPromote[0].drops == 1 && atPromote[0].cells == 1
                    && atPromote[0].prefsLayout == LayoutPreset.Single
                    && atPromote[0].previewActive,
                "6480 R2 " ~ door ~ "/" ~ sliceKind
                ~ " promotion must follow disarm and viewport reset");
            assert(atDrop[1].mode == EditMode.Vertices
                    && atDrop[1].morph.length == 0
                    && !atDrop[1].loopSlice && !atDrop[1].edgeSlice
                    && !atDrop[1].sliceDragging && atDrop[1].pipes == 0
                    && atDrop[1].previewActive
                    && dropTransitions[1] == ToolTransition.sceneResetDrop,
                "6480 R2 " ~ door ~ "/" ~ sliceKind
                ~ " reset-effects drop ran in the wrong phase");
            assert(g_lastDisarm.hadTool && g_lastDisarm.cancelSteps == 0
                    && !g_lastDisarm.stillArmed
                    && g_lastDisarm.mode == DisarmMode.cancelAndDrop,
                "6480 R2 " ~ door ~ "/" ~ sliceKind
                ~ " disarm outcome is not the measured 0-step fresh-slice path");
            assert(!preview.active && !preview.osdAccel.valid,
                "6480 R2 " ~ door ~ "/" ~ sliceKind
                ~ " left the preview or topology cache live");
            const verticesAfter = rig.session.editMesh().vertices.length;
            assert(door == "file.new" ? verticesAfter == 0 : verticesAfter == 8,
                "6480 R2 " ~ door ~ "/" ~ sliceKind
                ~ " empty mode is wrong: " ~ verticesAfter.to!string ~ " vertices");
            ++doorsChecked;
            expectedLoop ? ++loopKindsChecked : ++edgeKindsChecked;
        }
    }
    assert(doorsChecked == 4 && loopKindsChecked == 2 && edgeKindsChecked == 2,
        "6480 R2 both doors and both slice kinds must be checked");
}

unittest { // R4: scene.loadMesh receives the narrow drop, not full reset effects
    auto rig = new LiveRegistrationRig;
    auto viewports = new ViewportManager(0, 0, 800, 600);
    SubpatchPreview preview;
    Prefs prefs;
    size_t drops, pipes;
    ToolTransition[] transitions;
    auto drop = (ToolTransition transition) {
        ++drops;
        transitions ~= transition;
        rig.activeTool = null;
    };
    registerSceneFileLifecycleCommands(rig.registry, rig.liveSession(),
        rig.liveViewMode(), SceneResetEffects(viewports, &preview, &prefs,
            drop, () { ++pipes; }),
        SceneLifecycleDoors((EditMode mode) {
            rig.session.promoteGeometryType(mode);
        }, () {}, () => drop(ToolTransition.sceneResetDrop)));

    Mesh sliceMesh = makeCube();
    GpuMesh sliceGpu;
    EditMode sliceMode = EditMode.Edges;
    Mesh* sliceMeshSource() nothrow @nogc { return &sliceMesh; }
    auto loop = new LoopSliceTool(&sliceMeshSource, &sliceGpu,
                                  &sliceMode, LitShader.init);
    loop.seedPreparedActivationForTest();
    rig.activeTool = loop;
    rig.session.switchGeometryType(EditMode.Polygons);
    viewports.applyLayout(LayoutPreset.Quad);
    prefs.viewportLayout = LayoutPreset.Quad;
    const cached = primeTopologyCache(preview);
    assert("scene.loadMesh" in rig.registry.commandFactories && cached >= 1
            && preview.active && preview.reusablePreviewReady
            && preview.osdAccel.valid && viewports.cellCount == 4
            && prefs.viewportLayout == LayoutPreset.Quad
            && rig.session.selTypeOrder.current == SelType.Polygon
            && rig.activeTool !is null && pipes == 0 && drops == 0,
        "6480 R4 floor: loadMesh lacks a tool, cache, preview or Quad layout");

    enum meshJson = `{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],`
                  ~ `"faces":[[0,1,2,3]]}`;
    auto result = rig.binding.invokeLine("scene.loadMesh", meshJson,
        CommandInvocationContext(CommandOrigin.script, false));
    assert(result.outcome == CommandInvocationOutcome.applied
            && rig.session.editMesh().vertices.length == 4
            && rig.session.editMesh().faces.length == 1
            && rig.session.editMode == EditMode.Vertices
            && rig.session.selTypeOrder.current == SelType.Vertex,
        "6480 R4 loadMesh did not replace geometry through the real factory");
    assert(drops == 1 && transitions.length == 1
            && transitions[0] == ToolTransition.sceneResetDrop
            && rig.activeTool is null,
        "6480 R4 narrow load drop: expected one sceneResetDrop, got "
        ~ drops.to!string);
    assert(pipes == 0,
        "6480 R4 narrow load drop reset pipe stages: " ~ pipes.to!string);
    assert(preview.active && preview.reusablePreviewReady
            && preview.osdAccel.valid && viewports.cellCount == 4
            && prefs.viewportLayout == LayoutPreset.Quad,
        "6480 R4 narrow load drop reset preview, cache or viewport state");
}

unittest { // R5: factories resolve live roles/document and every door is required
    auto rig = new LiveRegistrationRig;
    auto viewports = new ViewportManager(0, 0, 800, 600);
    SubpatchPreview preview;
    Prefs prefs;
    size_t quitRequests;
    registerSceneFileLifecycleCommands(rig.registry, rig.liveSession(),
        rig.liveViewMode(), SceneResetEffects(viewports, &preview, &prefs,
            (ToolTransition transition) { rig.activeTool = null; }, () {}),
        SceneLifecycleDoors((EditMode mode) {
            rig.session.promoteGeometryType(mode);
        }, () { ++quitRequests; }, () { rig.activeTool = null; }));
    assert(rig.registry.commandFactories.length == 4,
        "6480 R5 population: expected four live factories");

    auto meshA = &rig.layerA.meshRef();
    auto viewA = rig.liveView();
    size_t controls;
    foreach (id; ["file.new", "file.quit", "scene.reset", "scene.loadMesh"]) {
        auto built = rig.registry.commandFactories[id]();
        assert(built.meshPtr() is meshA && built.viewRef() is viewA
                && built.editModeVal() == EditMode.Vertices,
            "6480 R5 control did not resolve layer A/cell 0/Vertices: " ~ id);
        ++controls;
    }
    assert(controls == 4, "6480 R5 control visited fewer than four factories");

    rig.activeCell = 1;
    rig.session.switchGeometryType(EditMode.Polygons);
    assert(rig.liveView() is rig.cells[1] && rig.liveView() !is viewA,
        "6480 R5 live-view floor did not switch to cell 1");
    size_t targets;
    foreach (id; ["file.new", "file.quit", "scene.reset", "scene.loadMesh"]) {
        auto built = rig.registry.commandFactories[id]();
        assert(built.viewRef() is rig.cells[1]
                && built.editModeVal() == EditMode.Polygons,
            "6480 R5 live View/Mode retained registration-time state: " ~ id);
        ++targets;
    }
    assert(targets == 4, "6480 R5 target visited fewer than four factories");

    const oldTestMode = command.g_testMode;
    scope(exit) command.g_testMode = oldTestMode;
    command.g_testMode = false;
    auto quit = rig.registry.commandFactories["file.quit"]();
    assert(quit.apply() && quitRequests == 1,
        "6480 R5 requestQuit door did not fire exactly once");

    rig.session.document.setPrimary(rig.layerB);
    assert(rig.session.document.layers.length == 2
            && &rig.session.editMesh() is &rig.layerB.meshRef()
            && rig.layerB.meshRef().vertices.length == 6,
        "6480 R5 file.new floor: second live mesh is not primary");
    auto fileNew = rig.binding.invokeLine("file.new", "",
        CommandInvocationContext(CommandOrigin.script, false));
    assert(fileNew.outcome == CommandInvocationOutcome.applied,
        "6480 R5 file.new refused");
    assert(rig.session.document.layers.length == 1
            && rig.session.document.layers[0] is rig.layerB
            && rig.layerB.meshRef().vertices.length == 0
            && rig.layerA.meshRef().vertices.length == 8,
        "6480 R5 file.new did not collapse the live Document and empty its primary");

    auto resetLayer = new Layer;
    resetLayer.name = "reset target";
    resetLayer.meshRef() = makeOctahedron();
    rig.session.document.layers ~= resetLayer;
    rig.session.document.setPrimary(resetLayer);
    assert(rig.session.document.layers.length == 2
            && &rig.session.editMesh() is &resetLayer.meshRef()
            && resetLayer.meshRef().vertices.length == 6,
        "6480 R5 scene.reset floor: second layer was not re-seeded");
    auto sceneReset = rig.binding.invokeLine("scene.reset", "",
        CommandInvocationContext(CommandOrigin.script, false));
    assert(sceneReset.outcome == CommandInvocationOutcome.applied,
        "6480 R5 scene.reset refused");
    assert(rig.session.document.layers.length == 1
            && rig.session.document.layers[0] is resetLayer
            && resetLayer.meshRef().vertices.length == 8,
        "6480 R5 scene.reset did not collapse the re-seeded live Document");

    void delegate(EditMode) promote;
    void delegate() door;
    size_t refusals;
    void countRefusal(SceneLifecycleDoors delegate() make) {
        try {
            auto ignored = make();
        } catch (AssertError) {
            ++refusals;
        }
    }
    countRefusal(() => SceneLifecycleDoors(promote, () {}, () {}));
    countRefusal(() => SceneLifecycleDoors((EditMode mode) {}, door, () {}));
    countRefusal(() => SceneLifecycleDoors((EditMode mode) {}, () {}, door));
    assert(refusals == 3,
        "6480 R5 all three lifecycle doors must be constructor-required");
}

unittest { // R3: production wiring and the retired paths, deliberately last
    const registrationRaw = repoFile("source/registration.d");
    const lifecycleRaw = repoFile("source/scene_file_lifecycle_registration.d");
    const effectsRaw = repoFile("source/scene_reset_effects.d");
    const appRaw = repoFile("source/app.d");
    assert(registrationRaw.length > 50_000 && lifecycleRaw.length > 2_500
            && effectsRaw.length > 1_000 && appRaw.length > 100_000,
        "6480 R3 source population floor: a production file is implausibly small");
    const registration = blankNonCode(registrationRaw);
    const lifecycle = blankNonCode(lifecycleRaw);
    const effects = blankNonCode(effectsRaw);
    const app = blankNonCode(appRaw);
    const registrationFlat = collapseWhitespace(registration);
    const lifecycleFlat = collapseWhitespace(lifecycle);

    enum productionCall = "registerSceneFileLifecycleCommands(app.reg(), "
        ~ "LiveSessionRole(app.sessionOwner), LiveViewModeRole(app.cameraViewDg, "
        ~ "app.sessionOwner.editModePtr()), SceneResetEffects(app.vpm, "
        ~ "app.subpatchPreviewPtr, &g_prefs, app.dropActiveTool, "
        ~ "app.resetAllPipeStages), SceneLifecycleDoors(app.promoteGeometryType, "
        ~ "() { app.running = false; }, () => app.dropActiveTool( "
        ~ "ToolTransition.sceneResetDrop)));";
    assert(registrationFlat.count(productionCall) == 1,
        "6480 R3 production call no longer binds the four lifecycle ids once");
    assert(registration.count("SceneResetEffects(") == 1,
        "6480 R3 reset effects must be constructed exactly once");
    const callAt = registrationFlat.indexOf(productionCall);
    const wrapperAt = registrationFlat.indexOf(
        "auto selTypeSrc = () => currentSelType(selTypeOrder);");
    assert(callAt >= 0 && wrapperAt > callAt,
        "6480 R3 lifecycle registration moved after the selection-type wrapper");

    enum recipe = "auto c = new SceneReset(&owner.activeMesh(), live.view(), "
        ~ "live.mode, live.modeCell(), () => effects.resetToolEffects(), "
        ~ "() => effects.resetViewport());";
    assert(lifecycleFlat.count(recipe) == 1
            && lifecycle.count("c.setDocument(owner.document());") == 1
            && lifecycle.count("c.setEmpty(empty);") == 1
            && lifecycle.count("c.setPromoteHook(doors.promoteGeometry());") == 1,
        "6480 R3 the named reset recipe changed or was duplicated");
    assert(lifecycleFlat.count(
            "sceneResetFactory(owner, live, resetEffects, doors, true);") == 1
            && lifecycleFlat.count(
            "sceneResetFactory(owner, live, resetEffects, doors, false);") == 1,
        "6480 R3 file.new/scene.reset lost their true/false recipe bindings");
    const fileNewAt = lifecycleRaw.indexOf(`reg.commandFactories["file.new"]`);
    const trueAt = lifecycle.indexOf(
        "sceneResetFactory(owner, live, resetEffects, doors, true);");
    const sceneResetAt = lifecycleRaw.indexOf(
        `reg.commandFactories["scene.reset"]`);
    assert(fileNewAt >= 0 && trueAt > fileNewAt
            && sceneResetAt > trueAt,
        "6480 R3 empty=true is not bound to file.new before scene.reset");

    enum loadSlots = "(new MeshLoadRaw(&owner.activeMesh(), live.view(), "
        ~ "live.mode, live.modeCell(), &live.view(), "
        ~ "doors.dropForSceneLoad())) .setPromoteHook(doors.promoteGeometry());";
    enum quitSlots = "new FileQuit(&owner.activeMesh(), live.view(), live.mode, "
        ~ "doors.requestQuit());";
    assert(lifecycleFlat.count(loadSlots) == 1
            && lifecycleFlat.count(quitSlots) == 1,
        "6480 R3 load/quit factories lost their narrow lifecycle doors");
    assert(lifecycle.count("effects.resetToolEffects()") == 1
            && lifecycle.count("doors.dropForSceneLoad()") == 1,
        "6480 R3 reset and load drop capabilities are no longer separated");

    foreach (forbidden; ["EditorApp", "editor_app", "Ai3dModalRefs",
                         "RemeshModalRefs", "with (", "with(", "activeTool",
                         "LoopSliceTool", "EdgeSliceTool", "dropArmedPreview",
                         "ToolTransition", "editModePtr"])
        assert(lifecycleRaw.count(forbidden) == 0,
            "6480 R3 narrow registrar names forbidden token: " ~ forbidden);
    assert(registrationRaw.count("dropArmedPreview") == 0
            && registrationRaw.count("LoopSliceTool") == 3
            && registrationRaw.count("EdgeSliceTool") == 3,
        "6480 R3 dead slice prelude remains or required tool imports/factories moved");

    foreach (retired; ["vpm.resetToDefault()", "subpatchPreview.deactivate()",
                       "subpatchPreview.dropTopologyCache()",
                       "resetAllPipeStages()", "g_prefs.viewportLayout"])
        assert(registration.count(retired) == 0
                && lifecycle.count(retired) == 0,
            "6480 R3 registrar regained a private reset effect: " ~ retired);

    const registerAt = app.indexOf("registerCommands(app);");
    assert(app.count("registerCommands(app);") == 1 && registerAt > 0,
        "6480 R3 app registration population floor");
    foreach (assignment; ["app.subpatchPreviewPtr  = &subpatchPreview;",
                          "app.runningPtr          = &running;",
                          "app.vpm             = vpm;",
                          "app.dropActiveTool       = cast(void delegate(ToolTransition))&dropActiveTool;",
                          "app.promoteGeometryType  = cast(void delegate(EditMode))&promoteGeometryType;",
                          "app.resetAllPipeStages   = cast(void delegate())&resetAllPipeStages;"]) {
        const at = app.indexOf(assignment);
        assert(app.count(assignment) == 1 && at >= 0 && at < registerAt,
            "6480 R3 input is not assigned once before registerCommands: "
            ~ assignment);
    }
}
