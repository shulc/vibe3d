module vibe3d.apps.desktop.registration;

import vibe3d.editing.commands.runtime.tool_activation_ownership : ToolTransition;

// Task 0415 (campaign 0407 §B.V1 step 1): registerTools/registerCommands
// host the command/tool factory registration previously inline in app.d's
// main() (~213 command + ~66 tool registrations). Design +
// inventory + verification log: doc/tasks/done/0415-registration-app-decomp.md.
//
// Remaining broad family functions take `EditorApp app` BY VALUE and open
// `with (app) { ... }`. Extracted family composition roots instead pass live
// roles and narrow dependency packages explicitly.
// The only line-level edits versus the original app.d text are the
// documented Edit-class 1 (`&x` -> `&x()` on the four address-taken
// pointer-backed locals: gpu/editMode/document).
//
// Phase 0 (this commit): skeleton only -- both functions are empty stubs,
// not called anywhere yet. `dub build` glob-compiles source/ regardless of
// import reachability (CLAUDE.md build note), so this file's own imports
// are already gated by the compiler even before app.d references it.
import vibe3d.apps.desktop.editor_app : EditorApp, MeshDg, ViewDg;
version (web) {
} else {
    import vibe3d.apps.desktop.editor_app : Ai3dModalState, Ai3dModalRefs;
}

import bindbc.sdl;
import std.string : toStringz;
import std.stdio : writeln, writefln, File, stderr;
import std.math : tan, sin, cos, sqrt, PI, abs;
import std.conv;
import std.json : JSONValue, JSONType;
import vibe3d.runtime.http.http_server;
import vibe3d.util.log.log : logInfo, logWarn, logError;
import vibe3d.apps.desktop.prefs;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import imgui_impl_sdl2;
import imgui_impl_opengl3;
import vibe3d.util.math.math;
import vibe3d.mesh.core.mesh;
import vibe3d.platform.input.eventlog;
import vibe3d.editing.tools.interactive.handler;
import vibe3d.editing.tools.interactive.pipe_gizmo_host : PipeGizmoHost;
import vibe3d.editing.tools.interactive.tool;
import vibe3d.editing.contracts.editmode;
import vibe3d.editing.contracts.seltype;
import vibe3d.editing.pipeline.evaluation.toolpipe;
import vibe3d.editing.pipeline.contracts.operator         : VectorStack;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : SubjectPacket;
import vibe3d.editing.pipeline.runtime.toolpipe.pipeline : g_pipeCtx;
import vibe3d.editing.tools.interactive.gizmo;
import vibe3d.viewport.camera.view;
import vibe3d.viewport.gpu.shader;
import vibe3d.util.profiling.perf_probe : g_perf, Cat, g_frames, Phase, FrameRec, FrameStatsSnapshot;
import vibe3d.documents.interchange.io.assimp_runtime : initAssimp, shutdownAssimp, isAssimpAvailable;
import vibe3d.editing.selection.scene_query.bvh_pick : BvhPick;
import vibe3d.editing.tools.interactive.tools.create.box;
import vibe3d.editing.tools.interactive.tools.alignment.mirror;
import vibe3d.editing.tools.interactive.tools.alignment.radial_sweep_tool;
import vibe3d.editing.tools.interactive.tools.create.sphere;
import vibe3d.editing.tools.interactive.tools.create.cylinder;
import vibe3d.editing.tools.interactive.tools.create.cone;
import vibe3d.editing.tools.interactive.tools.create.capsule;
import vibe3d.editing.tools.interactive.tools.create.torus;
import vibe3d.editing.tools.interactive.tools.create.arc;
import vibe3d.editing.tools.interactive.tools.create.tube;
import vibe3d.editing.tools.interactive.tools.create.pen;
import vibe3d.editing.tools.interactive.tools.create.vertex_place : VertexTool;
import vibe3d.editing.tools.interactive.tools.edit.tack : TackTool;
import vibe3d.editing.tools.interactive.tools.edit.bridge_tool : BridgeTool;
import vibe3d.editing.tools.interactive.tools.edit.topology_pen : TopologyPenTool;
import vibe3d.apps.desktop.file_io_registration : registerFileIoCommands;
import vibe3d.apps.desktop.history_macro_registration : registerHistoryCommands;
import vibe3d.runtime.application_core.live_registration_roles : LiveSessionRole, LiveViewModeRole;
import vibe3d.apps.desktop.pipe_command_registration : registerPipeStageCommands;
import vibe3d.apps.desktop.scene_file_lifecycle_registration : SceneLifecycleDoors,
    registerSceneFileLifecycleCommands;
import vibe3d.apps.desktop.selection_command_registration : SelectionTypeDoors,
    registerSelectionCommands;
import vibe3d.apps.desktop.tool_lifecycle_registration : registerToolLifecycleCommands;
import vibe3d.apps.desktop.transform_tool_registration : TransformToolDeps,
    registerTransformToolCommands;
import vibe3d.apps.desktop.create_tool_registration : CreateToolDeps, registerCreateToolCommands;
import vibe3d.apps.desktop.edit_tool_registration : EditSessionFactories, EditToolDeps,
    registerEditToolCommands;
import vibe3d.apps.desktop.item_command_registration : ItemLifecycleDoors, registerItemCommands;
import vibe3d.apps.desktop.mesh_command_registration : MeshCommandDeps, registerMeshCommands;
version (web) {
} else {
    import vibe3d.apps.desktop.ai3d_command_registration : registerAi3dCommands;
}
import vibe3d.editing.commands.editor.commands.mesh.selection_edit : MeshSelectionEdit;
import vibe3d.apps.desktop.commands.ui.layout_reset : UiLayoutResetCommand;
import vibe3d.apps.desktop.scene_reset_effects : SceneResetEffects;
import vibe3d.mesh.snapshot.snapshot : SelectionSnapshot;
import vibe3d.runtime.document_actions.commands.layer.commands : LayerAttr;
import vibe3d.editing.commands.runtime.command;
import vibe3d.editing.tools.interactive.registry;
import vibe3d.platform.input.shortcuts;
import vibe3d.ui.editor.buttonset;
import vibe3d.editing.interaction.data.ai.debug_trace : latestHandleDebugTraceJson;
import vibe3d.runtime.ai_advisor.ai.element_candidates : publishElementCandidates,
    collectElementCandidates, resolveElementCandidateDecision;
import vibe3d.editing.interaction.data.ai.interaction : AiAdvisorDecision, AiCandidate, AiInteractionContext,
    AiInteractionPhase, AiIntent;
import vibe3d.runtime.ai_advisor.ai.interaction_log : AiInteractionLogRecord, makeAiInteractionLogRecord;
import vibe3d.runtime.ai_advisor.ai.interaction_log_writer : AiInteractionLogWriter, defaultLiveSource;
import vibe3d.runtime.ai_advisor.ai.exploration : AiExplorationController, buildCandidateKey,
    defaultExploreSource, OptionalGrab, Resolution, ResolutionKind;
import vibe3d.editing.interaction.data.ai.advisor    : AiAdvisor;
import vibe3d.runtime.ai_advisor.ai.copilot_gate : kCopilotEnabled;
import vibe3d.runtime.ai_advisor.ai.model_adapter : AiModelAdapter, AiModelAdapterConfig,
    AiModelAvailability, AiModelStatus, AiModelFallbackMode,
    aiModelAdapterMinConfidence;
import vibe3d.ui.editor.args_dialog    : ArgsDialog;
version (web) {
} else {
    import vibe3d.runtime.ai3d.ai3d.job_controller       : Ai3dJobController, Ai3dClientJoinTimeoutMs;
    import vibe3d.runtime.ai3d.ai3d.job_events           : Ai3dEvent, Ai3dEventKind;
    import vibe3d.runtime.ai3d.ai3d.stage_artifact       : Ai3dDefaultRequestedFaces, Ai3dMaxGenerationDeadlineMs;
    import vibe3d.runtime.ai3d.ai3d.scene_validator      : Ai3dMaxTotalFaces;
    import vibe3d.runtime.ai3d.ai3d.worker_manager       : Ai3dWorkerManager, Ai3dWorkerState,
        Ai3dInstallState, ai3dDefaultInstallLocation;
}
import vibe3d.runtime.remesh.remesh.remesh_job : RemeshJob, RemeshParams,
    MAX_REMESH_TARGET_QUADS, MIN_REMESH_TARGET_QUADS;
import vibe3d.editing.tools.interactive.property_panel : PropertyPanel;
import vibe3d.ui.editor.forms_render;
import vibe3d.documents.channels.layer_params   : LayerPropsProvider;
import vibe3d.documents.model.document       : Layer;
import vibe3d.editing.selection.query.snap           : ItemSnapFrame;
import vibe3d.viewport.host.viewport : LayoutPreset;
import vibe3d.apps.desktop.ai_command_registration : registerAiToggleCommands;
import vibe3d.apps.desktop.viewport_command_registration : registerViewportCommands;
import vibe3d.apps.desktop.view_settings_registration : registerViewSettingsCommands;
version (WithAI) import vibe3d.apps.desktop.copilot_command_registration : registerCopilotCommands;

// Locally-scoped in app.d's main() (not top-level there).
import vibe3d.documents.model.document       : Document;
import vibe3d.viewport.host.viewport        : ViewportManager;

// These imports were already unused before this slice; follow-up card 6460
// owns their removal together with the wider dead-symbol inventory.
version (WithAI) import vibe3d.apps.desktop.commands.ui.copilot_panel : g_copilotPanelShown;
version (WithAI) {
    import vibe3d.ui.editor.copilot_overlay : drawCopilotFindingOverlay;
}

/// Registers every tool through `registerTool` and the paired headless wrappers
/// (app.d's former Span A, ~2876-3364: move/rotate/scale through the
/// mesh.*Tool generator-preview family). Phase 1 (0415).
///
/// Family composition roots preserve the former registration order while
/// extracted registrars receive explicit live roles and collaborators.
void registerTools(EditorApp app) {
    // Task 0722 (audit §2C A9): the 600-line flat body is four family
    // functions below, called in the order the flat list wrote them in.
    registerTransformTools(app);
    registerCreateTools(app);
    registerEditTools(app);
}

/// The transform registrar owns only explicit live roles and collaborators;
/// this composition root is shared by production and the unittest door.
private void registerTransformTools(EditorApp app) {
    auto explore = app.aiExplore;
    auto logw = app.aiLogWriter;
    registerTransformToolCommands(app.reg(),
        LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
        TransformToolDeps(app.gpuPtr, app.history, app.vxEditFactory,
            app.morphEditFactory, app.layerXformEditFactory, app.pipeGizmoHost,
            () => explore.enabled && logw.enabled),
        () => app.uiCommandDelegate("tool.doApply", ""));
}

version (unittest)
/// Build any transform-family product through the production composition root.
Tool buildRegisteredXfrmTransformForOwnershipTest(EditorApp app, string key) {
    Registry staged;
    auto stagedApp = app;
    stagedApp.regPtr = &staged;
    registerTransformTools(stagedApp);
    app.reg = staged;
    return app.reg.toolFactory(key)();
}

/// The create registrar owns only explicit live roles and collaborators.
private void registerCreateTools(EditorApp app) {
    registerCreateToolCommands(app.reg(),
        LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
        CreateToolDeps(app.gpuPtr, app.litShader, app.history,
            app.bevelEditFactory, app.topoPenFactories));
}
/// The edit registrar owns only explicit live roles and collaborators;
/// this composition root is shared by production and the unittest door
/// (task 6670).
private void registerEditTools(EditorApp app) {
    registerEditToolCommands(app.reg(),
        LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
        EditToolDeps(app.gpuPtr, app.litShader, app.history, app.pipeGizmoHost,
            app.vxEditFactory,
            EditSessionFactories(
                bevelEditFactory:         app.bevelEditFactory,
                loopSliceEditFactory:     app.loopSliceEditFactory,
                reduceEditFactory:        app.reduceEditFactory,
                cloneEditFactory:         app.cloneEditFactory,
                arrayEditFactory:         app.arrayEditFactory,
                edgeExtrudeEditFactory:   app.edgeExtrudeEditFactory,
                edgeExtendEditFactory:    app.edgeExtendEditFactory,
                polyExtrudeEditFactory:   app.polyExtrudeEditFactory,
                radialArrayEditFactory:   app.radialArrayEditFactory,
                smoothShiftEditFactory:   app.smoothShiftEditFactory,
                strokeExtrudeEditFactory: app.strokeExtrudeEditFactory)));
}

/// Registers the remaining command entries — tool.*,
/// ui.*, layer.*, ai3d.*, select.*, mesh.*, history.*, and macro.*.
///
/// Families that still need broad EditorApp state retain their local
/// `with (app)` bodies. Extracted families instead receive explicit live
/// roles and narrow collaborators at the calls below, so they do not resolve
/// those inputs through the residual nested `with` block.
void registerCommands(EditorApp app) {
    app.reg().bindSelTypeAuthority(LiveSessionRole(app.sessionOwner));
    // Registry construction owns selection-type attachment (task 0621).
    // Binding is first so every command built by any family receives the live
    // authority; the registry latch rejects construction before this point.
    // Registrar ordering is no longer part of that invariant.
    //
    // Item and AI-3D factories have separate narrow inputs. The composition
    // root retains the modal writer and passes AI registration one callback.
    registerToolLifecycleCommands(app.reg(), LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
        app.toolHostView);
    registerItemCommands(app.reg(), LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
        ItemLifecycleDoors(app.onActiveLayerChanged));
    version (web) {
    } else {
        registerAi3dCommands(app.reg(), LiveSessionRole(app.sessionOwner),
            LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
            app.onActiveLayerChanged, app.ai3dController,
            (string path) {
                import std.string : fromStringz;
                app.ai3dRefs.ai3dPickedImagePath  = path;
                app.ai3dRefs.ai3dModal            = Ai3dModalState.init;
                app.ai3dRefs.ai3dModalOpen        = true;
                app.ai3dRefs.ai3dModalPendingOpen = true;
                const workerUrl = cast(string)
                    fromStringz(app.ai3dRefs.ai3dWorkerUrlBuf.ptr).dup;
                app.ai3dController.probeHealth(
                    workerUrl.length ? workerUrl : "http://127.0.0.1:47831");
            });
    }
    registerPipeStageCommands(app.reg(), LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
        app.toolHostView);
    registerSelectionCommands(app.reg(), LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
        SelectionTypeDoors(app.sessionOwner.editModePtr(),
                           app.promoteGeometryType, app.switchGeometryType,
                           app.switchItemType));
    registerViewportCommands(app.reg(), LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
        app.vpm);
    registerViewSettingsCommands(app.reg(), LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()));
    // The copilot pause (task 0422) gates registration at the composition root while
    // leaving both registrar bodies under semantic analysis.
    static if (kCopilotEnabled) {
        registerAiToggleCommands(app.reg(), LiveSessionRole(app.sessionOwner),
            LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
            app.aiState);
    }
    version (WithAI)
    static if (kCopilotEnabled) {
        registerCopilotCommands(app.reg(), LiveSessionRole(app.sessionOwner),
            LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
            app.aiState, app.copilotPanel,
            () => app.reg().makeCommand("mesh.select"));
    }
    registerFileIoCommands(app.reg(), LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg,
                         app.sessionOwner.editModePtr()));
    registerSceneFileLifecycleCommands(app.reg(),
        LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
        SceneResetEffects(app.vpm, app.subpatchPreviewPtr, &g_prefs,
                          app.dropActiveTool),
        SceneLifecycleDoors(app.promoteGeometryType,
                            () { app.running = false; },
                            () => app.dropActiveTool(ToolTransition.sceneResetDrop)));
    registerMeshFamily(app);
    registerHistoryCommands(app.reg(), LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg,
                         app.sessionOwner.editModePtr()),
        app.history, app.historyPanelState, app.macroRecorder);
    registerSelfTestCommands(app);
    app.reg().registerCommand("layout.reset", () => cast(Command)
        new UiLayoutResetCommand(&app.mesh(), app.cameraView(), app.editMode(),
                                 app.authorLayoutReset));
}

/// The mesh-command registrar owns explicit live roles and five narrow
/// capabilities; this composition root is shared by production and the
/// unittest door. Task 6509.
private void registerMeshFamily(EditorApp app) {
    auto dropActiveTool = app.dropActiveTool;
    auto viewports = app.vpm;
    auto meshRebuildDropDoor =
        () => dropActiveTool(ToolTransition.meshRebuildDrop);
    auto promoteGeometryType = app.promoteGeometryType;
    auto remeshModalState = app.remeshModalState;
    auto meshCommandDeps = MeshCommandDeps(meshRebuildDropDoor,
        &viewports.originSnapshot, app.remeshJob,
        &remeshModalState.requestOpen, promoteGeometryType);
    registerMeshCommands(app.reg(), LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
        meshCommandDeps);
}

version (unittest)
/// Register the mesh family through the production composition root.
void registerMeshCommandsForOwnershipTest(EditorApp app) {
    registerMeshFamily(app);
}

/// TASK 1410 — the deliberate-defect injector, registered ONLY in the four
/// instrumented buildTypes (`check`, `check-unit`, `check-release`,
/// `sanitize`), which are the only ones that declare `SanitizerSelfTest`.
///
/// `--build=release` declares no such version, so the whole
/// `selftest_fault` module compiles to nothing, this function's body is
/// empty, and `selftest.fault` is not a key — the id answers
/// `status:error, unknown command id` there. The nightly preflight asserts
/// that twice (a `dub describe` read of `targets[].buildSettings`, and a
/// `strings` scan of the release binary for the literal `selftest.fault`,
/// which is the strictly stronger check).
///
/// Modelled on the `version (WithAI)` copilot block above: version-gated
/// import, version-gated registration, no other file aware of either.
///
/// Construction attaches the selection-type authority inside Registry, so
/// this version-gated family has the same path as every other command.
///
/// The key registered here and `SelfTestFaultCommand.name()` are the SAME
/// string on purpose and not by coincidence: `Registry.cacheSupportedModes()`
/// constructs every factory at startup and THROWS if a command's `name()` is
/// not itself a registered key, so a typo here does not produce a broken
/// command — it produces an editor that will not start, and a night in which
/// every HTTP test fails at once for a reason that looks nothing like its
/// cause.
void registerSelfTestCommands(EditorApp app) {
    version (SanitizerSelfTest) {
        import vibe3d.apps.desktop.selftest_fault : SelfTestFaultCommand;
        with (app) {
            reg.registerCommand("selftest.fault", () => cast(Command)
                new SelfTestFaultCommand(&mesh(), cameraView, editMode));
        }
    }
}
