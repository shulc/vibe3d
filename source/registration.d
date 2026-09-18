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
import editor_app : EditorApp, Ai3dModalState, Ai3dModalRefs, RemeshModalRefs,
    MeshDg, ViewDg;

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
import tools.transform.transform;
import tools.transform.move;
import tools.deform.push;
import tools.deform.bend;
import tools.alignment.linear_align_tool;
import tools.alignment.radial_align_tool;
import tools.transform.scale;
import tools.transform.rotate;
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
import tools.slice.edge_slide : EdgeSlideTool;
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
import tools.common.command_wrapper : XfrmSmoothTool, XfrmJitterTool, XfrmQuantizeTool;
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
import item_command_registration : ItemLifecycleDoors, registerItemCommands;
import ai3d_command_registration : registerAi3dCommands;
import commands.mesh.subdivide;
import commands.mesh.subdivide_faceted;
import commands.mesh.triple      : MeshTriple;
import commands.mesh.quadruple   : MeshQuadruple;
import commands.mesh.detriangulate : MeshDetriangulate;
import commands.mesh.merge         : MeshMergeFaces;
import commands.mesh.subpatch_toggle;
import commands.mesh.hide;
import commands.mesh.set_material;
import commands.mesh.set_part;
import commands.tool.headless : ToolHeadlessCommand;
import commands.mesh.split_edge;
import commands.mesh.add_point : MeshAddPoint;
import commands.mesh.split_face  : MeshSplitFace;
import commands.mesh.edge_join : MeshEdgeJoin;
import commands.mesh.spin_edge;
import commands.mesh.loop_slice : MeshAddLoop, MeshLoopSlice;
import commands.mesh.session_edit : MeshSessionEdit;
import commands.mesh.edge_extrude : MeshEdgeExtrude;
import commands.mesh.vertex_extrude : MeshVertexExtrude;
import commands.mesh.vertex_bevel   : MeshVertexBevel;
import commands.mesh.poly_inset : MeshPolygonInset;
import commands.mesh.spikey : MeshSpikey;
import commands.mesh.bevel : MeshBevel;
import commands.mesh.face_extrude : MeshFaceExtrude;
import commands.mesh.bridge : MeshBridge;
import commands.mesh.thicken : MeshThicken;
import commands.mesh.smooth_shift : MeshSmoothShift;
import commands.mesh.edge_extend : MeshEdgeExtend;
import commands.mesh.move_vertex;
import commands.mesh.vertex_new    : MeshVertexNew;
import commands.mesh.vertex_center : MeshCenterVertices;
import commands.mesh.vertex_set    : MeshSetPosition;
import commands.mesh.delete_ : MeshDelete;
import commands.mesh.remove_ : MeshRemove;
import commands.mesh.flip    : MeshFlip;
import commands.mesh.duplicate_ : MeshDuplicate;
import commands.mesh.copy_      : MeshCopy;
import commands.mesh.paste_     : MeshPaste;
import commands.mesh.cut_       : MeshCut;
import commands.mesh.mirror_      : MeshMirror;
import commands.mesh.symmetrize   : MeshSymmetrize;
import commands.mesh.array_       : MeshArray;
import commands.mesh.clone_       : MeshClone;
import commands.mesh.radial_array_ : MeshRadialArray;
import commands.mesh.sweep         : MeshSweep;
import commands.mesh.stroke_extrude      : MeshStrokeExtrude;
import commands.mesh.vert_merge        : MeshVertMerge;
import commands.mesh.weld_vertex_pair  : MeshWeldVertexPair;
import commands.mesh.vert_join         : MeshVertJoin;
import commands.mesh.axis_slice    : MeshAxisSlice, MeshJulienne;
import commands.mesh.screen_slice  : MeshScreenSlice;
import commands.mesh.edge_slice    : MeshEdgeSlice;
import commands.mesh.collapse      : MeshCollapse;
import commands.mesh.vertex_split  : MeshVertexSplit;
import commands.mesh.reduce        : MeshReduce;
import commands.mesh.unify         : MeshUnify;
import commands.mesh.cleanup       : MeshCleanup;
import commands.mesh.fix_orientation : MeshFixOrientation;
import commands.mesh.make_polygon  : MeshMakePolygon;
import commands.mesh.select;
import commands.mesh.selection_edit : MeshSelectionEdit;
import commands.mesh.transform;
import commands.mesh.quantize;
import commands.mesh.jitter;
import commands.mesh.magnet : MeshMagnet;
import commands.mesh.smooth;
import commands.mesh.weightmap;
import commands.mesh.morph;
import commands.mesh.edge_crease;
import commands.mesh.uv_transform;
import commands.mesh.uv_project  : UvProject;
import commands.mesh.uv_pack     : UvFit, UvPack;
import commands.mesh.uv_map_util;
import commands.mesh.uv_relax  : UvRelax;
import commands.mesh.uv_unwrap : UvUnwrap;
import commands.mesh.edge_slide;
import commands.mesh.linear_align;
import commands.mesh.polygon_align;
import commands.mesh.radial_align;
import commands.mesh.vertex_edit;
import commands.ui.layout_reset : UiLayoutResetCommand;
import scene_reset_effects : SceneResetEffects;
import snapshot : SelectionSnapshot;
import commands.layer.commands : LayerAttr;
import command;
import registry;
import tools.transform.xfrm_transform : XfrmTransformTool;
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
import commands.mesh.remesh      : Remesh, RemeshStart, RemeshOpen;
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
    registerGeneratorTools(app);
    registerPrimitiveTools(app);
    registerEditTools(app);
}

/// The four unified-transform ids share this construction recipe; each row
/// supplies only T/R/S and the handle family/presentation. Collaborators come
/// from the registration-time EditorApp copy, while mesh, subject and item
/// targets remain live callbacks read on every use. The `transform` row equals
/// the XfrmTransformTool constructor defaults by contract. Task 6351; pinned by
/// tests/unit/unified_transform_recipe_test.d.
private struct TransformFactoryDefaults {
    bool flagT, flagR, flagS;
    int handleFamily;
    string handlePresentation;

    enum move      = TransformFactoryDefaults(true,  false, false, 0, "full");
    enum rotate    = TransformFactoryDefaults(false, true,  false, 1, "full");
    enum scale     = TransformFactoryDefaults(false, false, true,  2, "full");
    // Equal to the XfrmTransformTool constructor defaults by contract, not by
    // omission: presets on this base that set no handle fields inherit it.
    enum transform = TransformFactoryDefaults(true,  true,  true,  0, "compact");
}

private XfrmTransformTool buildUnifiedTransform(EditorApp app,
                                                TransformFactoryDefaults defaults) {
    auto t = new XfrmTransformTool(() => &app.mesh(), &app.gpu(), &app.editMode(),
        () => currentSelType(app.selTypeOrder),
        // The moving target-narrowed set, not only the primary layer.
        (ref Layer[] buf) => app.document().itemTransformTargets(buf));
    t.flagT = defaults.flagT;
    t.flagR = defaults.flagR;
    t.flagS = defaults.flagS;
    t.handleFamily = defaults.handleFamily;
    t.handlePresentation = defaults.handlePresentation;
    t.setUndoBindings(app.history, app.vxEditFactory, app.morphEditFactory);
    t.setItemUndoFactory(app.layerXformEditFactory);
    t.setPipeGizmoHost(app.pipeGizmoHost);
    if (app.aiExplore.enabled && app.aiLogWriter.enabled)
        t.setAiExploreSilentHover(true);
    return t;
}

/// Transform, deform, align and convolve tools — one family of the registration table (task 0722, audit
/// §2C A9). Sliced out of `registerTools`'s former flat body CONTIGUOUSLY, so the order in
/// which keys are written is exactly what it was; and every key in the
/// table is written exactly once (checked before the split), so order is
/// not load-bearing between families either. The `with` chain is
/// reproduced verbatim rather than narrowed to what this family happens
/// to use: narrowing it could silently re-point a bare identifier at a
/// same-named EditorApp member.
private void registerTransformTools(EditorApp app) {
    with (app) {
    reg.toolFactories["move"] = typedToolFactory!XfrmTransformTool(
        () => buildUnifiedTransform(app, TransformFactoryDefaults.move));
    reg.toolFactories["rotate"] = typedToolFactory!XfrmTransformTool(
        () => buildUnifiedTransform(app, TransformFactoryDefaults.rotate));
    reg.toolFactories["scale"] = typedToolFactory!XfrmTransformTool(
        () => buildUnifiedTransform(app, TransformFactoryDefaults.scale));
    reg.toolFactories["xfrm.transform"] = typedToolFactory!XfrmTransformTool(
        () => buildUnifiedTransform(app, TransformFactoryDefaults.transform));
    reg.toolFactories["xfrm.push"] = typedToolFactory!PushTool(() {
        auto t = new PushTool(() => &mesh(), &gpu(), &editMode());
        t.setUndoBindings(history, vxEditFactory);
        return t;
    });
    reg.toolFactories["xfrm.bend"] = typedToolFactory!BendTool(() {
        auto t = new BendTool(() => &mesh(), &gpu(), &editMode());
        t.setUndoBindings(history, vxEditFactory);
        return t;
    });
    // Align deform-tools batch (task 0361) — same headless-attr-driven
    // family as xfrm.push/xfrm.bend above (params()+applyHeadless() only,
    // no gizmo drag; driven via `tool.attr ... ; tool.doApply` from the
    // panel). Neutral tool ids per the task's public-repo naming rule.
    reg.toolFactories["xfrm.linearAlignTool"] = typedToolFactory!LinearAlignTool(() {
        auto t = new LinearAlignTool(() => &mesh(), &gpu(), &editMode());
        t.setUndoBindings(history, vxEditFactory);
        return t;
    });
    reg.toolFactories["xfrm.radialAlignTool"] = typedToolFactory!RadialAlignTool(() {
        auto t = new RadialAlignTool(() => &mesh(), &gpu(), &editMode());
        t.setUndoBindings(history, vxEditFactory);
        return t;
    });
    // Convolve sub-tools (Deform → Smooth / Jitter / Quantize) —
    // exposed as tools so the side-panel buttons use the same
    // `tool.set xfrm.smooth on` activation shape. The
    // underlying math reuses MeshSmooth / MeshJitter / MeshQuantize
    // (one-shot, not brush-interactive). Brush interactivity is a
    // follow-up; the tool surface is the prerequisite.
    reg.toolFactories["xfrm.smooth"] = typedToolFactory!XfrmSmoothTool(() {
        auto t = new XfrmSmoothTool(&mesh(), cameraView, editMode, &gpu());
        t.setGestureBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        return t;
    });
    reg.toolFactories["xfrm.jitter"] = typedToolFactory!XfrmJitterTool(() {
        auto t = new XfrmJitterTool(&mesh(), cameraView, editMode, &gpu());
        t.setGestureBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        return t;
    });
    reg.toolFactories["edge.slide"] = typedToolFactory!EdgeSlideTool(() {
        auto t = new EdgeSlideTool(&mesh(), cameraView, editMode, &gpu());
        t.setGestureBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        return t;
    });
    reg.toolFactories["xfrm.quantize"] = typedToolFactory!XfrmQuantizeTool(() {
        auto t = new XfrmQuantizeTool(&mesh(), cameraView, editMode, &gpu());
        t.setGestureBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        return t;
    });
    }
}

version (unittest)
Tool buildRegisteredXfrmTransformForOwnershipTest(EditorApp app, string key) {
    registerTransformTools(app);
    return app.reg.toolFactories[key]();
}

/// One typed registration owns both entries, so a paired id is written once.
/// The command deliberately resolves the registry slot when it is created,
/// preserving replacement of a tool factory after registration. This helper
/// stays in this module because the prepared-writer census copies its body.
/// Task 6353; evidence: tests/unit/headless_tool_pairing_test.d.
private void registerHeadlessTool(T : Tool)(ref Registry reg, string id,
        T delegate() factory, LiveSessionRole owner, LiveViewModeRole live) {
    auto regPtr = &reg;
    reg.toolFactories[id] = typedToolFactory!T(factory);
    reg.commandFactories[id] = () => cast(Command)
        new ToolHeadlessCommand(&owner.activeMesh(), live.view(), live.mode(),
                                id, regPtr.toolFactories[id]);
}

/// Generator-preview and topology tools — one family of the registration table (task 0722, audit
/// §2C A9). Sliced out of `registerTools`'s former flat body CONTIGUOUSLY, so the order in
/// which keys are written is exactly what it was; and every key in the
/// table is written exactly once (checked before the split), so order is
/// not load-bearing between families either. The `with` chain is
/// reproduced verbatim rather than narrowed to what this family happens
/// to use: narrowing it could silently re-point a bare identifier at a
/// same-named EditorApp member.
private void registerGeneratorTools(EditorApp app) {
    with (app) {
    auto headlessOwner = LiveSessionRole(sessionOwner);
    auto headlessLive = LiveViewModeRole(cameraViewDg, sessionOwner.editModePtr());

    registerHeadlessTool!MirrorTool(reg, "mesh.mirrorTool", () {
        auto t = new MirrorTool(() => &mesh(), &gpu(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    }, headlessOwner, headlessLive);

    // Radial Sweep — interactive revolve/lathe (task 0326), promoting the
    // pre-existing `mesh.sweep` one-shot command to a drag/handle tool.
    // Generator-preview architecture identical to mesh.mirrorTool above
    // (own preview mesh, commits once at deactivate()); reuses the same
    // generic bevelEditFactory/MeshSessionEdit snapshot-diff undo path.
    // Named `mesh.radialSweepTool` (task 0326 review S2), NOT
    // `mesh.sweepTool` — that id is reserved for the task-0323 Sketch
    // Extrude port, the natural claimant of the bare "sweep" name since it
    // shares the same `revolveProfile`/`revolveProfileEx` kernel
    // (source/mesh_ops/revolve.d — free functions since task 1903 Stage E2).
    registerHeadlessTool!RadialSweepTool(reg, "mesh.radialSweepTool", () {
        auto t = new RadialSweepTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    }, headlessOwner, headlessLive);

    // Tack (task 0126) — rigid polygon-to-polygon alignment. Mirrors the
    // mesh.mirrorTool block above: same generic MeshSessionEdit/bevelEditFactory
    // undo path, registered with the paired headless helper.
    registerHeadlessTool!TackTool(reg, "mesh.tack", () {
        auto t = new TackTool(() => &mesh(), &gpu(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    }, headlessOwner, headlessLive);

    // Topology Pen is not registered through registerHeadlessTool. TWO
    // binders, and neither is optional: `setGestureBindings` carries history
    // plus the placement gesture's per-click `MeshVertexNew`; `setPenFactories`
    // carries the other gestures' thirteen factories as ONE named
    // `TopoPenFactories` value built in app.d (task 6352), so no argument
    // position can re-pair a gesture with a sibling's wire name. Member 5 of
    // tests/unit/tool_commit_seam_census_g7_test.d requires one call of each.
    reg.toolFactories["mesh.topoPen"] = typedToolFactory!TopologyPenTool(() {
        auto t = new TopologyPenTool(() => &mesh(), &gpu());
        t.setGestureBindings(history, () => new MeshVertexNew(&mesh(), cameraView, editMode));
        t.setPenFactories(topoPenFactories);
        return t;
    });

    // Bridge (task 0357) — interactive multi-span/twist bridge, promoted
    // from the one-shot mesh.bridge command. Same generic MeshSessionEdit/
    // bevelEditFactory undo path and paired headless wiring as Mirror/Tack.
    registerHeadlessTool!BridgeTool(reg, "mesh.bridgeTool", () {
        auto t = new BridgeTool(() => &mesh(), &gpu(), litShader, &editMode());
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    }, headlessOwner, headlessLive);
    }
}

/// Primitive create tools, the pen and vertex place — one family of the registration table (task 0722, audit
/// §2C A9). Sliced out of `registerTools`'s former flat body CONTIGUOUSLY, so the order in
/// which keys are written is exactly what it was; and every key in the
/// table is written exactly once (checked before the split), so order is
/// not load-bearing between families either. The `with` chain is
/// reproduced verbatim rather than narrowed to what this family happens
/// to use: narrowing it could silently re-point a bare identifier at a
/// same-named EditorApp member.
private void registerPrimitiveTools(EditorApp app) {
    with (app) {
    auto headlessOwner = LiveSessionRole(sessionOwner);
    auto headlessLive = LiveViewModeRole(cameraViewDg, sessionOwner.editModePtr());

    registerHeadlessTool!BoxTool(reg, "prim.cube", () {
        auto t = new BoxTool(() => &mesh(), &gpu(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    }, headlessOwner, headlessLive);

    registerHeadlessTool!SphereTool(reg, "prim.sphere", () {
        auto t = new SphereTool(() => &mesh(), &gpu(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    }, headlessOwner, headlessLive);

    registerHeadlessTool!SphereTool(reg, "prim.ellipsoid", () {
        auto t = new SphereTool(() => &mesh(), &gpu(), litShader, /*ellipsoidMode=*/true);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    }, headlessOwner, headlessLive);

    registerHeadlessTool!CylinderTool(reg, "prim.cylinder", () {
        auto t = new CylinderTool(() => &mesh(), &gpu(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    }, headlessOwner, headlessLive);

    registerHeadlessTool!TubeTool(reg, "prim.tube", () {
        auto t = new TubeTool(() => &mesh(), &gpu(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    }, headlessOwner, headlessLive);

    registerHeadlessTool!ConeTool(reg, "prim.cone", () {
        auto t = new ConeTool(() => &mesh(), &gpu(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    }, headlessOwner, headlessLive);

    registerHeadlessTool!CapsuleTool(reg, "prim.capsule", () {
        auto t = new CapsuleTool(() => &mesh(), &gpu(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    }, headlessOwner, headlessLive);

    registerHeadlessTool!TorusTool(reg, "prim.torus", () {
        auto t = new TorusTool(() => &mesh(), &gpu(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    }, headlessOwner, headlessLive);

    registerHeadlessTool!ArcTool(reg, "prim.arc", () {
        auto t = new ArcTool(() => &mesh(), &gpu(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    }, headlessOwner, headlessLive);

    // Pen is interactive only and is not registered through registerHeadlessTool.
    reg.toolFactories["pen"] = typedToolFactory!PenTool(() {
        auto t = new PenTool(() => &mesh(), &gpu(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    });

    // Vertex placement is not registered through registerHeadlessTool; headless
    // geometry creation uses mesh.addVertex
    // (task 0131).
    reg.toolFactories["prim.vertex"] = typedToolFactory!VertexTool(() {
        auto t = new VertexTool(() => &mesh(), &gpu(), litShader);
        t.setGestureBindings(history, bevelEditFactory);
        return t;
    });
    }
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
                            () => app.dropActiveTool(
                                ToolTransition.sceneResetDrop)));
    registerMeshCommands(app);
    registerHistoryCommands(app.reg(), LiveSessionRole(app.sessionOwner),
        LiveViewModeRole(app.cameraViewDg,
                         app.sessionOwner.editModePtr()),
        app.history, app.historyPanelState, app.macroRecorder);
    registerSelfTestCommands(app);
    app.reg().commandFactories["layout.reset"] = () => cast(Command)
        new UiLayoutResetCommand(&app.mesh(), app.cameraView(), app.editMode(),
                                 app.authorLayoutReset);
    // The same three-deep `with` the flat body had, for the same reason the
    // family functions keep it: identical name resolution, not a narrower one.
    with (app) {
    with (ai3dRefs) {
    with (remeshRefs) {

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
}

/// Mesh, polygon, vertex and UV operations — one family of the registration table (task 0722, audit
/// §2C A9). Sliced out of `registerCommands`'s former flat body CONTIGUOUSLY, so the order in
/// which keys are written is exactly what it was; and every key in the
/// table is written exactly once (checked before the split), so order is
/// not load-bearing between families either. The `with` chain is
/// reproduced verbatim rather than narrowed to what this family happens
/// to use: narrowing it could silently re-point a bare identifier at a
/// same-named EditorApp member.
private void registerMeshCommands(EditorApp app) {
    with (app) {
    with (ai3dRefs) {
    with (remeshRefs) {
    reg.commandFactories["mesh.subdivide"] = () => cast(Command)
        new Subdivide(&mesh(), cameraView, editMode,
                      () => dropActiveTool(ToolTransition.meshRebuildDrop));
    // Quad Remesh (source/remesh/remesh_job.d): `mesh.remesh.start` kicks off
    // the async subprocess (HTTP/menu-triggerable — see remeshJob.poll() near
    // the ai3d drain for how the result lands); `mesh.remesh` is the
    // undoable apply that a successful job's result is fired through.
    reg.commandFactories["mesh.remesh.start"] = () => cast(Command)
        new RemeshStart(&mesh(), cameraView, editMode, remeshJob);
    reg.commandFactories["mesh.remesh"] = () => cast(Command)
        new Remesh(&mesh(), cameraView, editMode,
                   () => dropActiveTool(ToolTransition.meshRebuildDrop), remeshJob);
    reg.commandFactories["mesh.remesh.open"] = () => cast(Command)
        new RemeshOpen(&mesh(), cameraView, editMode, () {
            remeshModalOpen        = true;
            remeshModalPendingOpen = true;
            remeshLastError        = null;
            remeshLastSummary      = null;
        });
    reg.commandFactories["mesh.subdivide_faceted"] = () => cast(Command)
        new SubdivideFaceted(&mesh(), cameraView, editMode,
                             () => dropActiveTool(ToolTransition.meshRebuildDrop));
    reg.commandFactories["mesh.triple"] = () => cast(Command)
        new MeshTriple(&mesh(), cameraView, editMode,
                       () => dropActiveTool(ToolTransition.meshRebuildDrop));
    reg.commandFactories["mesh.quadruple"] = () => cast(Command)
        new MeshQuadruple(&mesh(), cameraView, editMode,
                          () => dropActiveTool(ToolTransition.meshRebuildDrop));
    reg.commandFactories["mesh.detriangulate"] = () => cast(Command)
        new MeshDetriangulate(&mesh(), cameraView, editMode,
                              () => dropActiveTool(ToolTransition.meshRebuildDrop));
    reg.commandFactories["mesh.mergeFaces"] = () => cast(Command)
        new MeshMergeFaces(&mesh(), cameraView, editMode,
                           () => dropActiveTool(ToolTransition.meshRebuildDrop));
    reg.commandFactories["mesh.subpatch_toggle"] = () => cast(Command)
        new SubpatchToggle(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.hide"] = () => cast(Command)
        new MeshHide(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.hideUnselected"] = () => cast(Command)
        new MeshHideUnselected(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.hideInvert"] = () => cast(Command)
        new MeshHideInvert(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.unhideAll"] = () => cast(Command)
        new MeshUnhideAll(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.setMaterial"] = () => cast(Command)
        new MeshSetMaterial(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.setPart"] = () => cast(Command)
        new MeshSetPart(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.split_edge"] = () => cast(Command)
        new MeshSplitEdge(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.addPoint"] = () => cast(Command)
        new MeshAddPoint(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.splitFace"] = () => cast(Command)
        new MeshSplitFace(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.edgeJoin"] = () => cast(Command)
        new MeshEdgeJoin(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.spinEdge"] = () => cast(Command)
        new MeshSpinEdge(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.addLoop"] = () => cast(Command)
        new MeshAddLoop(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.loopSlice"] = () => cast(Command)
        new MeshLoopSlice(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.edge_extrude"] = () => cast(Command)
        new MeshEdgeExtrude(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.vertexExtrude"] = () => cast(Command)
        new MeshVertexExtrude(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.vertexBevel"] = () => cast(Command)
        new MeshVertexBevel(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.poly_inset"] = () => cast(Command)
        new MeshPolygonInset(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.spikey"] = () => cast(Command)
        new MeshSpikey(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.bevel"] = () => cast(Command)
        new MeshBevel(&mesh(), cameraView, editMode);
    reg.commandFactories["poly.extrude"] = () => cast(Command)
        new MeshFaceExtrude(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.bridge"] = () => cast(Command)
        new MeshBridge(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.axisSlice"] = () => cast(Command)
        new MeshAxisSlice(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.julienne"] = () => cast(Command)
        new MeshJulienne(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.screenSlice"] = () {
        auto c = new MeshScreenSlice(&mesh(), cameraView, editMode);
        // Viewport camera single-source (0181): resolve the camera-plane cut
        // through the follow-aware snapshot instead of the cell's raw own
        // transform — see command.d's effectiveViewport() for the fallback
        // hazard note.
        c.setResolvedVpProvider(() => vpm.originSnapshot());
        return cast(Command) c;
    };
    reg.commandFactories["mesh.edgeSlice"] = () => cast(Command)
        new MeshEdgeSlice(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.thicken"] = () => cast(Command)
        new MeshThicken(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.smooth_shift"] = () => cast(Command)
        new MeshSmoothShift(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.edge_extend"] = () => cast(Command)
        new MeshEdgeExtend(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.move_vertex"] = () => cast(Command)
        new MeshMoveVertex(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.addVertex"] = () => cast(Command)
        new MeshVertexNew(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.centerVertices"] = () => cast(Command)
        new MeshCenterVertices(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.setPosition"] = () => cast(Command)
        new MeshSetPosition(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.delete"] = () => cast(Command)
        new MeshDelete(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.remove"] = () => cast(Command)
        new MeshRemove(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.flip"] = () => cast(Command)
        new MeshFlip(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.duplicate"] = () => cast(Command)
        new MeshDuplicate(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.copy"] = () => cast(Command)
        new MeshCopy(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.paste"] = () => cast(Command)
        new MeshPaste(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.cut"] = () => cast(Command)
        new MeshCut(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.mirror"] = () => cast(Command)
        new MeshMirror(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.symmetrize"] = () => cast(Command)
        new MeshSymmetrize(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.array"] = () => cast(Command)
        new MeshArray(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.clone"] = () => cast(Command)
        new MeshClone(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.radial_array"] = () => cast(Command)
        new MeshRadialArray(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.sweep"] = () => cast(Command)
        new MeshSweep(&mesh(), cameraView, editMode);
    // One-shot, headlessly-testable path-follow extrude (task 0323 —
    // explicit world-space path-point param; see MeshStrokeExtrude's doc
    // comment). The interactive tool.strokeExtrude drives its own commit
    // through the separate record-flavor MeshSessionEdit instead of
    // this factory.
    reg.commandFactories["mesh.strokeExtrude"] = () => cast(Command)
        new MeshStrokeExtrude(&mesh(), cameraView, editMode);
    // Aliases — select.delete and select.remove delegate to the
    // same factory delegates as mesh.delete / mesh.remove respectively.
    reg.commandFactories["select.delete"] = reg.commandFactories["mesh.delete"];
    reg.commandFactories["select.remove"] = reg.commandFactories["mesh.remove"];
    reg.commandFactories["vert.merge"] = () => cast(Command)
        new MeshVertMerge(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.weldVertexPair"] = () => cast(Command)
        new MeshWeldVertexPair(&mesh(), cameraView, editMode);
    reg.commandFactories["poly.unify"] = () => cast(Command)
        new MeshUnify(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.cleanup"] = () => cast(Command)
        new MeshCleanup(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.fixOrientation"] = () => cast(Command)
        new MeshFixOrientation(&mesh(), cameraView, editMode);
    reg.commandFactories["vert.join"] = () => cast(Command)
        new MeshVertJoin(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.collapse"] = () => cast(Command)
        new MeshCollapse(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.vertexSplit"] = () => cast(Command)
        new MeshVertexSplit(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.reduce"] = () => cast(Command)
        new MeshReduce(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.makePolygon"] = () {
        auto c = new MeshMakePolygon(&mesh(), cameraView, editMode);
        // Task 1180: the new face is the command's PRODUCT and re-pointing at
        // it changes the element type — route that through the geometry-type
        // funnel (promote, no tool-drop), same hook mesh.select takes.
        c.setPromoteHook((EditMode m) => promoteGeometryType(m));
        return cast(Command) c;
    };
    reg.commandFactories["mesh.select"] = () {
        auto c = new MeshSelect(&mesh(), cameraView, editMode, &editMode());
        c.setPromoteHook((EditMode m) => promoteGeometryType(m));
        // Viewport camera single-source (0181): see mesh.screenSlice above.
        c.setResolvedVpProvider(() => vpm.originSnapshot());
        return cast(Command) c;
    };
    reg.commandFactories["mesh.transform"] = () {
        auto c = new MeshTransform(&mesh(), cameraView, editMode);
        // Viewport camera single-source (0181): see mesh.screenSlice above.
        c.setResolvedVpProvider(() => vpm.originSnapshot());
        return cast(Command) c;
    };
    reg.commandFactories["mesh.quantize"] = () => cast(Command)
        new MeshQuantize(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.jitter"] = () => cast(Command)
        new MeshJitter(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.magnet"] = () => cast(Command)
        new MeshMagnet(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.weightmap.create"] = () => cast(Command)
        new WeightmapCreate(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.weightmap.remove"] = () => cast(Command)
        new WeightmapRemove(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.weightmap.rename"] = () => cast(Command)
        new WeightmapRename(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.weightmap.set"] = () => cast(Command)
        new WeightmapSet(&mesh(), cameraView, editMode);
    // Task 1090. The odd sibling of the four above: it writes the SESSION's
    // current-map name, not the mesh, so it is `CmdFlags.UI` and records no
    // undo entry. Registered here anyway — the map selection belongs to the
    // weight-map family, not to the viewport family, because it is global
    // state about a MESH channel and only its consumer is per-cell.
    reg.commandFactories["mesh.weightmap.select"] = () => cast(Command)
        new WeightmapSelect(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.morph.create"] = () => cast(Command)
        new MorphCreate(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.morph.remove"] = () => cast(Command)
        new MorphRemove(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.morph.rename"] = () => cast(Command)
        new MorphRename(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.morph.select"] = () => cast(Command)
        new MorphSelect(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.morph.set"] = () => cast(Command)
        new MorphSet(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.morph.clear"] = () => cast(Command)
        new MorphClear(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.morph.apply"] = () => cast(Command)
        new MorphApplyCmd(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.edgeCrease.set"] = () => cast(Command)
        new EdgeCreaseSet(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.edgeCrease.clear"] = () => cast(Command)
        new EdgeCreaseClear(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.flip"] = () => cast(Command)
        new UvFlip(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.mirror"] = () => cast(Command)
        new UvMirror(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.rotate"] = () => cast(Command)
        new UvRotate(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.project"] = () => cast(Command)
        new UvProject(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.fit"] = () => cast(Command)
        new UvFit(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.pack"] = () => cast(Command)
        new UvPack(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.delete"] = () => cast(Command)
        new UvDelete(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.rename"] = () => cast(Command)
        new UvRename(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.copy"] = () => cast(Command)
        new UvCopy(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.clear"] = () => cast(Command)
        new UvClear(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.relax"] = () => cast(Command)
        new UvRelax(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.unwrap"] = () => cast(Command)
        new UvUnwrap(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.edge_slide"] = () => cast(Command)
        new MeshEdgeSlide(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.smooth"] = () => cast(Command)
        new MeshSmooth(&mesh(), cameraView, editMode);
    // Headless aliases for the Convolve tools — same shape
    // as prim.cube above: tool.set <id> on; tool.attr <id> ...;
    // tool.doApply. The command form bundles the activation pair so
    // headless callers don't have to manage the tool lifecycle.
    reg.commandFactories["xfrm.smooth"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "xfrm.smooth", reg.toolFactories["xfrm.smooth"]);
    reg.commandFactories["xfrm.jitter"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "xfrm.jitter", reg.toolFactories["xfrm.jitter"]);
    reg.commandFactories["xfrm.quantize"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "xfrm.quantize", reg.toolFactories["xfrm.quantize"]);
    reg.commandFactories["mesh.linear_align"] = () => cast(Command)
        new MeshLinearAlign(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.align"] = () => cast(Command)
        new MeshAlign(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.radial_align"] = () => cast(Command)
        new MeshRadialAlign(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.vertex_edit"] = () => cast(Command)
        new MeshVertexEdit(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.bevel_edit"] = () => cast(Command)
        new MeshSessionEdit(&mesh(), cameraView, editMode,
                          "mesh.bevel_edit", "Bevel");
    }
    }
    }
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
