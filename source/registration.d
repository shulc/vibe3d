module registration;

import tool_activation_ownership : ToolTransition;

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
// pointer-backed locals: gpu/editMode/document) and Edit-class 2
// (`&promoteItemType` -> `promoteItemType`, the one address-taken hook).
//
// Phase 0 (this commit): skeleton only -- both functions are empty stubs,
// not called anywhere yet. `dub build` glob-compiles source/ regardless of
// import reachability (CLAUDE.md build note), so this file's own imports
// are already gated by the compiler even before app.d references it.
import editor_app : EditorApp, MeshDg, ViewDg;
version (web) {
} else {
    import editor_app : Ai3dModalState, Ai3dModalRefs;
}

import bindbc.sdl;
import std.string : toStringz;
import std.stdio : writeln, writefln, File, stderr;
import std.math : tan, sin, cos, sqrt, PI, abs;
import std.conv;
import std.json : JSONValue, JSONType;
import http_server;
import log : logInfo, logWarn, logError;
import prefs;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import imgui_impl_sdl2;
import imgui_impl_opengl3;
import math;
import mesh;
import eventlog;
import handler;
import pipe_gizmo_host : PipeGizmoHost;
import tool;
import editmode;
import seltype;
import toolpipe;
import operator         : VectorStack;
import toolpipe.packets : SubjectPacket;
import toolpipe.pipeline : g_pipeCtx;
import gizmo;
import view;
import shader;
import perf_probe : g_perf, Cat, g_frames, Phase, FrameRec, FrameStatsSnapshot;
import io.assimp_runtime : initAssimp, shutdownAssimp, isAssimpAvailable;
import bvh_pick : BvhPick;
import tools.create.box;
import tools.alignment.mirror;
import tools.alignment.radial_sweep_tool;
import tools.create.sphere;
import tools.create.cylinder;
import tools.create.cone;
import tools.create.capsule;
import tools.create.torus;
import tools.create.arc;
import tools.create.tube;
import tools.create.pen;
import tools.create.vertex_place : VertexTool;
import tools.edit.tack : TackTool;
import tools.edit.bridge_tool : BridgeTool;
import tools.edit.topology_pen : TopologyPenTool;
import file_io_registration : registerFileIoCommands;
import history_macro_registration : registerHistoryCommands;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import pipe_command_registration : registerPipeStageCommands;
import scene_file_lifecycle_registration : SceneLifecycleDoors,
    registerSceneFileLifecycleCommands;
import selection_command_registration : SelectionTypeDoors,
    registerSelectionCommands;
import tool_lifecycle_registration : registerToolLifecycleCommands;
import transform_tool_registration : TransformToolDeps,
    registerTransformToolCommands;
import create_tool_registration : CreateToolDeps, registerCreateToolCommands;
import edit_tool_registration : EditSessionFactories, EditToolDeps,
    registerEditToolCommands;
import item_command_registration : ItemLifecycleDoors, registerItemCommands;
import mesh_command_registration : MeshCommandDeps, registerMeshCommands;
version (web) {
} else {
    import ai3d_command_registration : registerAi3dCommands;
}
import commands.mesh.selection_edit : MeshSelectionEdit;
import commands.ui.layout_reset : UiLayoutResetCommand;
import scene_reset_effects : SceneResetEffects;
import snapshot : SelectionSnapshot;
import commands.layer.commands : LayerAttr;
import command;
import registry;
import shortcuts;
import buttonset;
import ai.debug_trace : latestHandleDebugTraceJson;
import ai.element_candidates : publishElementCandidates,
    collectElementCandidates, resolveElementCandidateDecision;
import ai.interaction : AiAdvisorDecision, AiCandidate, AiInteractionContext,
    AiInteractionPhase, AiIntent;
import ai.interaction_log : AiInteractionLogRecord, makeAiInteractionLogRecord;
import ai.interaction_log_writer : AiInteractionLogWriter, defaultLiveSource;
import ai.exploration : AiExplorationController, buildCandidateKey,
    defaultExploreSource, OptionalGrab, Resolution, ResolutionKind;
import ai.advisor    : AiAdvisor;
import ai.copilot_gate : kCopilotEnabled;
import ai.model_adapter : AiModelAdapter, AiModelAdapterConfig,
    AiModelAvailability, AiModelStatus, AiModelFallbackMode,
    aiModelAdapterMinConfidence;
import args_dialog    : ArgsDialog;
version (web) {
} else {
    import ai3d.job_controller       : Ai3dJobController, Ai3dClientJoinTimeoutMs;
    import ai3d.job_events           : Ai3dEvent, Ai3dEventKind;
    import ai3d.stage_artifact       : Ai3dDefaultRequestedFaces, Ai3dMaxGenerationDeadlineMs;
    import ai3d.scene_validator      : Ai3dMaxTotalFaces;
    import ai3d.worker_manager       : Ai3dWorkerManager, Ai3dWorkerState,
        Ai3dInstallState, ai3dDefaultInstallLocation;
    import remesh.remesh_job         : RemeshJob, RemeshParams,
        MAX_REMESH_TARGET_QUADS, MIN_REMESH_TARGET_QUADS;
}
import property_panel : PropertyPanel;
import forms_render;
import layer_params   : LayerPropsProvider;
import document       : Layer;
import snap           : ItemSnapFrame;
import viewport : LayoutPreset;
import ai_command_registration : registerAiToggleCommands;
import viewport_command_registration : registerViewportCommands;
import view_settings_registration : registerViewSettingsCommands;
version (WithAI) import copilot_command_registration : registerCopilotCommands;

// Locally-scoped in app.d's main() (not top-level there).
import document       : Document;
import viewport        : ViewportManager;

// These imports were already unused before this slice; follow-up card 6460
// owns their removal together with the wider dead-symbol inventory.
version (WithAI) import commands.ui.copilot_panel : g_copilotPanelShown;
version (WithAI) {
    import copilot_overlay : drawCopilotFindingOverlay;
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
            () => explore.enabled && logw.enabled));
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
        ItemLifecycleDoors(app.onActiveLayerChanged, app.promoteItemType));
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
                          app.dropActiveTool, app.resetAllPipeStages),
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
    version (web) {
    } else
    auto remeshModalState = app.remeshModalState;
    version (web)
    auto meshCommandDeps = MeshCommandDeps(meshRebuildDropDoor,
        &viewports.originSnapshot, null, null, promoteGeometryType);
    else
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
        import selftest_fault : SelfTestFaultCommand;
        with (app) {
            reg.registerCommand("selftest.fault", () => cast(Command)
                new SelfTestFaultCommand(&mesh(), cameraView, editMode));
        }
    }
}
