module registration;

import tool_activation_ownership : ToolTransition;

// Task 0415 (campaign 0407 §B.V1 step 1): registerTools/registerCommands
// host the command/tool factory registration previously inline in app.d's
// main() (~213 commandFactories + ~66 toolFactories assignments). Design +
// inventory + verification log: doc/tasks/done/0415-registration-app-decomp.md.
//
// Both functions take `EditorApp app` BY VALUE and open `with (app) { ... }`
// so the moved factory bodies read VERBATIM -- every bare identifier the
// original main()-body code used (mesh(), gpu, editMode, reg.*, history,
// vpm, the *EditFactory delegates, the hook delegates, ...) resolves to the
// matching EditorApp member instead of the main()-local of the same name.
// The only line-level edits versus the original app.d text are the
// documented Edit-class 1 (`&x` -> `&x()` on the four address-taken
// pointer-backed locals: gpu/editMode/document) and Edit-class 2
// (`&promoteItemType` -> `promoteItemType`, the one address-taken hook).
//
// Phase 0 (this commit): skeleton only -- both functions are empty stubs,
// not called anywhere yet. `dub build` glob-compiles source/ regardless of
// import reachability (CLAUDE.md build note), so this file's own imports
// are already gated by the compiler even before app.d references it.
import editor_app : EditorApp, Ai3dModalState, Ai3dModalRefs, MeshDg, ViewDg;

import bindbc.sdl;
import bindbc.opengl;
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
import nfde;
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
import symmetry_pick : symmetricSelectVertex, symmetricSelectEdge, symmetricSelectFace;
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
import tools.edit.drag_weld    : DragWeldTool;
import tools.edit.edge_extrude : EdgeExtrudeTool;
import tools.edit.edge_extend : EdgeExtendTool;
import tools.edit.poly_extrude : PolyExtrudeTool;
import tools.alignment.radial_array_tool : RadialArrayTool;
import tools.edit.poly_bevel : PolyBevelTool;
import tools.edit.poly_inset_tool : PolyInsetTool;
import tools.deform.smooth_shift_tool : SmoothShiftTool;
import tools.deform.magnet : MagnetTool;
import tools.edit.edge_bevel : EdgeBevelTool;
import tools.slice.loop_slice_tool : LoopSliceTool;
import tools.slice.slice_tool : SliceTool;
import tools.slice.edge_slice_tool : EdgeSliceTool;
import tools.edit.reduce : ReductionTool;
import tools.alignment.clone_tool : CloneTool;
import tools.alignment.array_tool : ArrayTool;
import tools.edit.tack : TackTool;
import tools.edit.bridge_tool : BridgeTool;
import tools.edit.vert_merge_tool : VertexMergeTool;
import tools.edit.vertex_bevel_tool : VertexBevelTool;
import tools.edit.vertex_extrude_tool : VertexExtrudeTool;
import tools.deform.stroke_extrude_tool : StrokeExtrudeTool;
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
import item_command_registration : ItemLifecycleDoors, registerItemCommands;
import mesh_command_registration : MeshCommandDeps, registerMeshCommands;
import ai3d_command_registration : registerAi3dCommands;
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
import ai3d.job_controller       : Ai3dJobController, Ai3dClientJoinTimeoutMs;
import ai3d.job_events           : Ai3dEvent, Ai3dEventKind;
import ai3d.stage_artifact       : Ai3dDefaultRequestedFaces, Ai3dMaxGenerationDeadlineMs;
import ai3d.scene_validator      : Ai3dMaxTotalFaces;
import ai3d.worker_manager       : Ai3dWorkerManager, Ai3dWorkerState,
    Ai3dInstallState, ai3dDefaultInstallLocation;
import remesh.remesh_job         : RemeshJob, RemeshParams,
    MAX_REMESH_TARGET_QUADS, MIN_REMESH_TARGET_QUADS;
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

/// Registers every `reg.toolFactories[id]` and the paired headless wrappers
/// (app.d's former Span A, ~2876-3364: move/rotate/scale through the
/// mesh.*Tool generator-preview family). Phase 1 (0415).
///
/// Body is a VERBATIM cut of former app.d text, wrapped in `with (app) { }`
/// so every bare identifier (mesh(), reg.*, history, litShader, the
/// *EditFactory delegates, ...) resolves through the ctx instead of a
/// main()-local of the same name. The only line-level edits versus the
/// original text are Edit-class 1 (`&x` -> `&x()`, 47 &gpu + 28 &editMode
/// sites -- see task doc for the exact count/rationale).
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
    registerTransformTools(app);
    return app.reg.toolFactories[key]();
}

/// The create registrar owns only explicit live roles and collaborators.
private void registerCreateTools(EditorApp app) {
    registerCreateToolCommands(app.reg(),
        LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
        CreateToolDeps(app.gpuPtr, app.litShader, app.history,
            app.bevelEditFactory, app.topoPenFactories));
}
/// Mesh edit, slice and duplication tools — one family of the registration table (task 0722, audit
/// §2C A9). Sliced out of `registerTools`'s former flat body CONTIGUOUSLY, so the order in
/// which keys are written is exactly what it was; and every key in the
/// table is written exactly once (checked before the split), so order is
/// not load-bearing between families either. The `with` chain is
/// reproduced verbatim rather than narrowed to what this family happens
/// to use: narrowing it could silently re-point a bare identifier at a
/// same-named EditorApp member.
private void registerEditTools(EditorApp app) {
    with (app) {

    // Drag Weld — drag a source vertex onto a target vertex to weld them.
    // LMB-down picks the source; LMB-up picks the target; one snapshot-undo
    // entry per completed gesture. Gated to Vertices mode.
    reg.toolFactories["mesh.dragWeld"] = typedToolFactory!DragWeldTool(() {
        auto t = new DragWeldTool(() => &mesh(), &gpu(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    });

    // Edge Extrude — interactive (drag → extrude/width) + headless
    // (tool.attr edge.extrude extrude/width; tool.doApply). Topology-creating
    // tool: own typed edit factory (MeshSessionEdit, not vxEditFactory),
    // wired via the prim.cube registration template. Gated to Edges mode by
    // EdgeExtrudeTool.supportedModes().
    reg.toolFactories["edge.extrude"] = typedToolFactory!EdgeExtrudeTool(() {
        auto t = new EdgeExtrudeTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setGestureBindings(history, edgeExtrudeEditFactory);
        return t;
    });

    // Face Extrude — interactive (drag → distance along region normal) + headless
    // (tool.attr poly.extrude distance <v>; tool.doApply). Topology-creating
    // tool: own typed edit factory (MeshSessionEdit, snapshot-only undo).
    // Gated to Polygons mode by PolyExtrudeTool.supportedModes().
    reg.toolFactories["poly.extrude"] = typedToolFactory!PolyExtrudeTool(() {
        auto t = new PolyExtrudeTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setGestureBindings(history, polyExtrudeEditFactory);
        return t;
    });

    // Radial Array — interactive (angle-cube haul → End Angle; axis-arrow haul
    // → Offset; off-handle click → reposition Center) + headless (tool.attr
    // mesh.radialArrayTool count/axis/center/angle/offset/weld; tool.doApply).
    // Reuses the shared Mesh.radialArrayFaces kernel (same-mesh clone
    // insertion, no new layers) already exercised by the one-shot
    // mesh.radial_array command. Topology-creating tool: own typed edit
    // factory (MeshSessionEdit, snapshot-only undo).
    reg.toolFactories["mesh.radialArrayTool"] = typedToolFactory!RadialArrayTool(() {
        auto t = new RadialArrayTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setGestureBindings(history, radialArrayEditFactory);
        return t;
    });

    // Stroke Extrude — interactive (click-drag draws a camera-raycast
    // world-space path, selected polygons extrude along it in bands) +
    // headless via the separate one-shot mesh.strokeExtrude command
    // (explicit path-point param — the interactive tool itself has NO
    // headless path, matching the captured reference finding). Task 0323,
    // basic/captured scope. Topology-creating tool: own typed edit factory
    // (MeshSessionEdit, snapshot-only undo). Gated to Polygons mode
    // by StrokeExtrudeTool.supportedModes().
    reg.toolFactories["tool.strokeExtrude"] = typedToolFactory!StrokeExtrudeTool(() {
        auto t = new StrokeExtrudeTool(() => &mesh(), &gpu(), litShader);
        t.setGestureBindings(history, strokeExtrudeEditFactory);
        return t;
    });

    // Edge Extend — interactive (drag → world-axis Offset via the embedded
    // transform gizmo's Move bank) + headless (tool.attr edge.extend offsetX...;
    // tool.doApply). Topology-creating tool: own typed edit factory
    // (MeshSessionEdit). Gated to Edges mode by EdgeExtendTool.supportedModes().
    reg.toolFactories["edge.extend"] = typedToolFactory!EdgeExtendTool(() {
        auto t = new EdgeExtendTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setGestureBindings(history, edgeExtendEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        return t;
    });

    // Poly Bevel — interactive + headless (inset, shift params). Topology-creating
    // tool: reuses bevelEditFactory (MeshSessionEdit snapshot undo). Gated to Polygons.
    reg.toolFactories["poly.bevel"] = typedToolFactory!PolyBevelTool(() {
        auto t = new PolyBevelTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    });
    // Polygon Inset — interactive (task 0359 promotion of the one-shot
    // mesh.poly_inset command). One attribute (inset), always per-polygon,
    // no drawn gizmo (toolcard-confirmed) — a generic viewport click+drag
    // hauls the value. Reuses the generic MeshSessionEdit/bevelEditFactory
    // before/after-snapshot undo path, same as mesh.mirrorTool/mesh.tack
    // above. Gated to Polygons.
    reg.toolFactories["mesh.polyInsetTool"] = typedToolFactory!PolyInsetTool(() {
        auto t = new PolyInsetTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    });

    // Smooth Shift + Thicken — interactive (2 handles: Offset, Scale) + headless
    // (tool.attr mesh.smoothShiftTool shift/scale/maxAngle/thicken/sharp <v>;
    // tool.doApply). Topology-creating tool: own typed edit factory
    // (MeshSessionEdit, snapshot-only undo). Gated to Polygons mode by
    // SmoothShiftTool.supportedModes(). The reference editor's Thicken toolbar
    // button is confirmed (task 0358) to be THIS SAME tool with thicken=1
    // forced, not a separate tool — see config/buttons.yaml.
    reg.toolFactories["mesh.smoothShiftTool"] = typedToolFactory!SmoothShiftTool(() {
        auto t = new SmoothShiftTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setGestureBindings(history, smoothShiftEditFactory);
        return t;
    });
    // TASK 1905 — `vxEditFactory` is spent at TEN sites in this file: FIVE
    // transform-zone `setUndoBindings` calls (the unified-transform helper plus
    // push, bend and the two align tools), and FIVE `setGestureBindings` calls
    // (the four command-wrapper tools plus xfrm.magnet). So one factory feeds
    // TWO binding interfaces at once. That is legal (the parameter types
    // differ, the overloads are distinct).
    //
    // THE G1 NOTE HERE SAID "FOURTEEN … the other thirteen", AND SAID THE
    // SPLIT WOULD BE RESOLVED WHEN THE APP-LEVEL CLOSURES COLLAPSED IN GROUP
    // G8. Both halves were wrong and group G8 re-measured them (2026-08-29).
    // The count was thirteen before phase B — twelve transform sites plus this
    // one. The unified-transform recipe collapsed four of those sites to one,
    // but changes nothing about which binder the transform tools DECLARE.
    //
    // WHAT G8 DID SETTLE. The temptation the note warned about was "unify the
    // factory alias", and what made it dangerous was that `VertexEditFactory`
    // named TWO different delegate types in this tree (`MeshSessionEdit
    // delegate()` in `vertex_place.d` / `drag_weld.d`, `MeshVertexEdit
    // delegate()` in `transform.d` / `xfrm_transform.d`), so a swap re-typed
    // two tools and both kept compiling. Phases B and C deleted both
    // `MeshSessionEdit` spellings along with the binders that used them: two
    // declarations remain and both name `MeshVertexEdit delegate()`. There is
    // nothing left to unify — and nothing in the compiler keeps it that way,
    // so member 4 of `tests/unit/tool_commit_seam_census_g8_test.d` does: a
    // third alias naming a different type reddens there by file and line.
    //
    // WHAT IS LEFT IS NOT THIS TASK'S. The five transform-zone calls stay on
    // `setUndoBindings` because that zone is OUT of task 1905's scope by
    // decision D1. Member 6 of the same census pins the ten-site five/five
    // split, and member 5 pins the surviving binder declarations, so neither
    // can grow in silence.
    reg.toolFactories["xfrm.magnet"] = typedToolFactory!MagnetTool(() {
        auto t = new MagnetTool(() => &mesh(), &gpu(), &editMode());
        t.setGestureBindings(history, vxEditFactory);
        return t;
    });

    // Edge Bevel — interactive + headless (width param). Topology-creating tool:
    // reuses bevelEditFactory (MeshSessionEdit snapshot undo). Gated to Edges mode.
    reg.toolFactories["edge.bevel"] = typedToolFactory!EdgeBevelTool(() {
        auto t = new EdgeBevelTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    });

    // Vertex Bevel — interactive (task 0360 promotion of the one-shot
    // mesh.vertexBevel command). Single-handle Inset, ACTR-anchored,
    // mirrors EdgeBevelTool one element type down. Reuses bevelEditFactory
    // (MeshSessionEdit snapshot undo) and the SAME id as the pre-existing
    // one-shot command (reg.commandFactories["mesh.vertexBevel"] below,
    // untouched) — separate registries, same precedent as poly.extrude/
    // mesh.mirrorTool elsewhere in this file. Gated to Vertices mode.
    reg.toolFactories["mesh.vertexBevel"] = typedToolFactory!VertexBevelTool(() {
        auto t = new VertexBevelTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    });

    // Vertex Extrude — interactive (task 0360 promotion of the one-shot
    // mesh.vertexExtrude command). Two independent handles (Extrude/shift,
    // Width) mirroring PolyBevelTool's Shift/Inset pair. Reuses
    // bevelEditFactory (MeshSessionEdit snapshot undo); same id as the
    // pre-existing one-shot command, separate registries (see
    // mesh.vertexBevel above). Gated to Vertices mode.
    reg.toolFactories["mesh.vertexExtrude"] = typedToolFactory!VertexExtrudeTool(() {
        auto t = new VertexExtrudeTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    });

    // Vertex Merge — interactive (task 0360 promotion of the one-shot
    // vert.merge command). No drawn handle — a generic viewport haul, same
    // family as mesh.polyInsetTool. Reuses bevelEditFactory (MeshSessionEdit
    // snapshot undo); same id as the pre-existing one-shot command (which
    // keeps its own range/keep/morph params, untouched — see
    // tools/vert_merge_tool.d's doc-comment). Gated to Vertices mode.
    reg.toolFactories["vert.merge"] = typedToolFactory!VertexMergeTool(() {
        auto t = new VertexMergeTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    });

    // Loop Slice — hover-seeded interactive edge-loop cut. Topology-creating
    // tool: reuses the SAME collectEdgeRing/insertEdgeLoops kernel as the
    // mesh.loopSlice/mesh.addLoop commands (untouched); mutate/revert preview,
    // one MeshSessionEdit undo entry PER committed cut. Gated to Edges mode.
    reg.toolFactories["mesh.loopSliceTool"] = typedToolFactory!LoopSliceTool(() {
        auto t = new LoopSliceTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setGestureBindings(history, loopSliceEditFactory);
        return t;
    });

    // Slice (plane/line) — interactive Start→End line cut with a plane
    // PERPENDICULAR to the work plane (mesh.sliceTool, task 0266 S0). Reuses
    // mesh_ops.cut.cutByPlane; one MeshSnapshot undo entry per committed slice
    // (reuses the generic bevelEditFactory snapshot command, labelled "Slice").
    // Distinct from the camera-plane one-shot mesh.screenSlice command.
    reg.toolFactories["mesh.sliceTool"] = typedToolFactory!SliceTool(() {
        auto t = new SliceTool(() => &mesh(), &gpu(), &editMode(), litShader);
        // TASK 1905 — `bevelEditFactory` is spent at TWENTY-FOUR sites in this
        // file and ALL twenty-four are on the base seam; ZERO are left on a
        // tool's own `setUndoBindings` overload (measured 2026-08-29 by group
        // G8). The G5 note here said "THIRTEEN … the rest still take their
        // tool's own overload, so one factory feeds TWO binding interfaces at
        // once until the app-level closures collapse in group G8" — the count
        // matched no state of this file, and the second half stopped being
        // true when phase C landed. It is deleted rather than carried, because
        // a parked promise nobody re-measures is how a comment becomes a lie.
        //
        // THE LOAD-BEARING HALF IS UNCHANGED: all twenty-four record under the
        // SAME wire name `mesh.bevel_edit`, so the two wire ids below are
        // indistinguishable in undo history and in a replay, which is why G5's
        // "exactly one cell reddens" mutations key on the plane dumps rather
        // than on `entryNames` for this pair. The count is pinned by member 6
        // of `tests/unit/tool_commit_seam_census_g8_test.d`.
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    });

    // Edge Slice — interactive two-edge strip cut (mesh.edgeSliceTool):
    // hover an edge -> click latches edge A + tA -> drag scrubs tA -> click a
    // second edge latches edge B + tB and previews the cut live -> commit on
    // Enter / tool-drop / a third click. Reuses the EXISTING
    // Mesh.edgeSlice(edgeA, edgeB, tA, tB, splitPolygons) kernel; one
    // MeshSessionEdit undo entry per committed cut (reuses the generic
    // bevelEditFactory snapshot command, labelled "Edge Slice"). The one-shot
    // mesh.edgeSlice command stays registered below for headless/scripting.
    // Gated to Edges mode.
    reg.toolFactories["mesh.edgeSliceTool"] = typedToolFactory!EdgeSliceTool(() {
        auto t = new EdgeSliceTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    });

    // Mesh Reduction — interactive + headless (ratio, preserveBoundary params).
    // Whole-mesh decimation via reduceToTarget; snapshot undo via MeshSessionEdit.
    // Gated to Polygons mode (whole-mesh op, but surfaced in polygon mode).
    reg.toolFactories["mesh.reduceTool"] = typedToolFactory!ReductionTool(() {
        auto t = new ReductionTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setGestureBindings(history, reduceEditFactory);
        return t;
    });

    // Clone — interactive drag-place a single copy of the selection (offset
    // by the drag delta on the most-facing screen plane).  Snapshot undo via
    // MeshSessionEdit; gated to Polygons mode.  Drag→offset feel is a
    // vibe3d-divergence (no reference tool-model; uses planeDragDelta).
    reg.toolFactories["mesh.clone"] = typedToolFactory!CloneTool(() {
        auto t = new CloneTool(() => &mesh(), &gpu(), &editMode());
        t.setGestureBindings(history, cloneEditFactory);
        return t;
    });

    // Array — interactive 3-axis grid array (task 0355), promoting the
    // one-shot mesh.array command's 1D line kernel to Mesh.arrayFacesGrid.
    // Snapshot undo via MeshSessionEdit; edit-mode-orthogonal (same face-
    // selection-or-whole-mesh convention as mesh.array/mesh.mirror).
    reg.toolFactories["mesh.arrayTool"] = typedToolFactory!ArrayTool(() {
        auto t = new ArrayTool(() => &mesh(), &gpu(), &editMode());
        t.setGestureBindings(history, arrayEditFactory);
        return t;
    });
    }
}


/// Registers the remaining `reg.commandFactories[id]` entries — tool.*,
/// ui.*, layer.*, ai3d.*, select.*, mesh.*, history.*, and macro.*.
///
/// Families that still need broad EditorApp state retain their local
/// `with (app)` bodies. Extracted families instead receive explicit live
/// roles and narrow collaborators at the calls below, so they do not resolve
/// those inputs through the residual nested `with` block.
void registerCommands(EditorApp app) {
    // The family functions and narrow registrars below are called in the flat
    // list's order. The task-0621 selection-type wrap
    // stays HERE and stays LAST -- it walks the FINISHED dictionary, so it
    // must run after every family. It also depends on app.d calling
    // registerTools BEFORE registerCommands, because ~13 tool-paired
    // commands are registered over there: the note below says "this
    // function", and that was already only half of where the keys come from.
    //
    // Item and AI-3D factories have separate narrow inputs. The composition
    // root retains the modal writer and passes AI registration one callback.
    registerToolLifecycleCommands(app.reg(), LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
        app.toolHostView);
    registerItemCommands(app.reg(), LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
        ItemLifecycleDoors(app.onActiveLayerChanged, app.promoteItemType));
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
            () => app.reg().commandFactories["mesh.select"]());
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
    app.reg().commandFactories["layout.reset"] = () => cast(Command)
        new UiLayoutResetCommand(&app.mesh(), app.cameraView(), app.editMode(),
                                 app.authorLayoutReset);
    // Preserve the live `EditorApp` and AI3D scopes used by the flat body;
    // Quad Remesh state now has one class owner rather than a leaf bundle.
    with (app) {
    with (ai3dRefs) {

    // -----------------------------------------------------------------------
    // Selection-type authority (task 0621) — wired onto EVERY command.
    // -----------------------------------------------------------------------
    // THE RULE lives on `Command.currentType()` (source/command.d): a command
    // asks the CURRENT selection type, never the derived `editMode`, because
    // under `SelType.Item` the latter retains the pre-switch geometry type and
    // the command then acts on a selection the user cannot see.
    //
    // This wraps every registered factory rather than adding the provider to
    // the ~200 construction sites above, and that is the point rather than a
    // shortcut: the seam this task closes exists BECAUSE the app layer and the
    // command layer read different authorities, and an opt-in-per-command
    // wiring would let the next command be added without one. Wrapping the
    // whole dictionary means a command cannot be registered without the
    // authority, so `currentType()`'s null fallback is unreachable in
    // production and only unit tests that construct a command directly ever
    // take it.
    //
    // Placement: LAST in this function, after every `commandFactories[...]`
    // assignment (including those in the nested `with`/scope blocks above), so
    // the walk sees the complete dictionary. Any factory registered after this
    // point would silently miss the provider — add new ones above.
    //
    // `reg.commandFactories.keys` snapshots the key set into a fresh array, so
    // re-assigning existing keys during the walk neither rehashes nor
    // invalidates the iteration. The wrapper is built by a named helper, not
    // by a lambda written inline in the loop body, so each closure captures
    // its OWN `inner` — the standard idiom in this file (cf. `makeFactory`).
    {
        auto selTypeSrc = () => currentSelType(selTypeOrder);
        static Command delegate() withSelType(Command delegate() inner,
                                              SelType delegate() src) {
            return () { auto c = inner(); c.setSelTypeProvider(src); return c; };
        }
        foreach (id; reg.commandFactories.keys)
            reg.commandFactories[id] = withSelType(reg.commandFactories[id],
                                                   selTypeSrc);
    }
    }
    }
}

/// The mesh-command registrar owns explicit live roles and five narrow
/// capabilities; this composition root is shared by production and the
/// unittest door. Task 6509.
private void registerMeshFamily(EditorApp app) {
    auto dropActiveTool = app.dropActiveTool;
    auto viewports = app.vpm;
    auto remeshModalState = app.remeshModalState;
    registerMeshCommands(app.reg(), LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),
        MeshCommandDeps(() => dropActiveTool(ToolTransition.meshRebuildDrop),
            &viewports.originSnapshot, app.remeshJob,
            &remeshModalState.requestOpen, app.promoteGeometryType));
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
/// It must be called BEFORE `registerCommands`'s selection-type wrap, like
/// every other family — the wrap walks the FINISHED dictionary and anything
/// registered after it silently misses the authority.
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
            reg.commandFactories["selftest.fault"] = () => cast(Command)
                new SelfTestFaultCommand(&mesh(), cameraView, editMode);
        }
    }
}
