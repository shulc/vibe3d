module registration;

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
// (`&switchToItemType` -> `switchToItemType`, the one address-taken hook).
//
// Phase 0 (this commit): skeleton only -- both functions are empty stubs,
// not called anywhere yet. `dub build` glob-compiles source/ regardless of
// import reachability (CLAUDE.md build note), so this file's own imports
// are already gated by the compiler even before app.d references it.
import editor_app : EditorApp, Ai3dModalState, Ai3dModalRefs, RemeshModalRefs,
    MeshDg, ViewDg, VertexCacheDg, FaceCacheDg, EdgeCacheDg;

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
import d_imgui.imgui_demo;
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
import viewcache;
import perf_probe : g_perf, Cat, g_frames, Phase, FrameRec, FrameStatsSnapshot;
import io.assimp_runtime : initAssimp, shutdownAssimp, isAssimpAvailable;
import symmetry_pick : symmetricSelectVertex, symmetricSelectEdge, symmetricSelectFace;
import bvh_pick : BvhPick;
import tools.transform;
import tools.move;
import tools.push;
import tools.bend;
import tools.linear_align_tool;
import tools.radial_align_tool;
import tools.scale;
import tools.rotate;
import tools.box;
import tools.mirror;
import tools.radial_sweep_tool;
import tools.sphere;
import tools.cylinder;
import tools.cone;
import tools.capsule;
import tools.torus;
import tools.arc;
import tools.tube;
import tools.pen;
import tools.vertex_place : VertexTool;
import tools.drag_weld    : DragWeldTool;
import tools.edge_extrude : EdgeExtrudeTool;
import tools.edge_extend : EdgeExtendTool;
import tools.edge_slide : EdgeSlideTool;
import tools.poly_extrude : PolyExtrudeTool;
import tools.radial_array_tool : RadialArrayTool;
import tools.poly_bevel : PolyBevelTool;
import tools.poly_inset_tool : PolyInsetTool;
import tools.smooth_shift_tool : SmoothShiftTool;
import tools.magnet : MagnetTool;
import tools.edge_bevel : EdgeBevelTool;
import tools.loop_slice_tool : LoopSliceTool;
import tools.slice_tool : SliceTool;
import tools.edge_slice_tool : EdgeSliceTool;
import tools.reduce : ReductionTool;
import tools.clone_tool : CloneTool;
import tools.array_tool : ArrayTool;
import tools.tack : TackTool;
import tools.bridge_tool : BridgeTool, BridgeEditFactory;
import tools.vert_merge_tool : VertexMergeTool;
import tools.vertex_bevel_tool : VertexBevelTool;
import tools.vertex_extrude_tool : VertexExtrudeTool;
import tools.stroke_extrude_tool : StrokeExtrudeTool;
import tools.command_wrapper : XfrmSmoothTool, XfrmJitterTool, XfrmQuantizeTool;
import commands.select.connect;
import commands.select.expand;
import commands.select.contract;
import commands.select.loop;
import commands.select.ring;
import commands.select.invert;
import commands.select.more;
import commands.select.less;
import commands.select.between;
import commands.select.type_from : SelectTypeFromCommand;
import commands.select.drop     : SelectDropCommand;
import commands.select.element  : SelectElementCommand;
import commands.select.convert  : SelectConvertCommand;
import commands.select.fill     : SelectFillHoles, SelectFillInsideLoop;
import commands.viewport.fit_selected;
import commands.viewport.fit;
import commands.file.load;
import commands.file.save;
import commands.mesh.subdivide;
import commands.mesh.subdivide_faceted;
import commands.mesh.triple      : MeshTriple;
import commands.mesh.quadruple   : MeshQuadruple;
import commands.mesh.detriangulate : MeshDetriangulate;
import commands.mesh.merge         : MeshMergeFaces;
import commands.mesh.subpatch_toggle;
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
import commands.scene.reset;
import commands.scene.load_mesh;
import commands.history.undo : HistoryUndo;
import commands.history.redo : HistoryRedo;
import commands.history.show : HistoryShow;
import commands.history.clear : HistoryClear;
import commands.test_undo_flags : UndoSuppressNoop, UndoForceNoop;
import commands.history.save_as_script : HistorySaveAsScript;
import commands.macros.record : MacroRecord;
import commands.macros.save_recorded : MacroSaveRecorded;
import macro_recorder : MacroRecorder;
import snapshot : SelectionSnapshot;
import commands.tool.host     : ToolHost;
import commands.tool.set      : ToolSetCommand;
import commands.tool.attr     : ToolAttrCommand;
import commands.layer.commands : LayerAttr;
import commands.tool.do_apply : ToolDoApplyCommand;
import commands.tool.reset    : ToolResetCommand;
import commands.tool.pipe     : ToolPipeAttrCommand;
import commands.tool.begin_session : ToolBeginSessionCommand;
import commands.ui.tool_properties : UiToolPropertiesCommand, g_toolPropertiesShown;
import commands.ui.layer_list      : UiLayerListCommand, g_layerListShown;
import commands.ui.viewport_props  : UiViewportPropsCommand, g_viewportPropsShown;
import commands.tool.panel_edit    : ToolPanelEditCommand;
import commands.snap.toggle_type : SnapToggleTypeCommand;
import commands.snap.mode        : SnapModeCommand;
import commands.ai.toggle    : AiToggleCommand, AiToggleAction;
import commands.falloff        : FalloffAddCommand, FalloffRemoveCommand,
                                  FalloffAutoSizeCommand;
import commands.path.define    : PathDefineCommand;
import commands.workplane     : WorkplaneResetCommand, WorkplaneEditCommand,
                                WorkplaneRotateCommand, WorkplaneOffsetCommand,
                                WorkplaneAlignToSelectionCommand;
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
import ai.state      : EditorAiState;
import ai.advisor    : AiAdvisor;
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
import commands.ai3d.import_result : Ai3dImportResult;
import remesh.remesh_job         : RemeshJob, RemeshParams,
    MAX_REMESH_TARGET_QUADS, MIN_REMESH_TARGET_QUADS;
import commands.mesh.remesh      : Remesh, RemeshStart, RemeshOpen;
import property_panel : PropertyPanel;
import forms_render;
import layer_params   : LayerPropsProvider;
import document       : Layer;
import snap           : ItemSnapFrame;
import viewport : LayoutPreset;

// Locally-scoped in app.d's main() (not top-level there).
import document       : Document;
import command_history : CommandHistory;
import viewport        : ViewportManager;

// AI Modeling Copilot (task 0402): version(WithAI)-only, mirroring app.d's
// own gating (see editor_app.d's doc comment for the same block).
version (WithAI) import commands.ui.copilot_panel : UiCopilotPanelCommand, g_copilotPanelShown;
version (WithAI) {
    import commands.copilot.analyze        : CopilotAnalyzeCommand;
    import commands.copilot.select_finding : CopilotSelectFindingCommand;
    import commands.copilot.cycle_finding  : CopilotCycleFindingCommand;
    import copilot_panel : CopilotPanel;
    import copilot_overlay : drawCopilotFindingOverlay;
}

/// Registers every `reg.toolFactories[id]` and the tool-paired
/// `reg.commandFactories[id]` one-shot `ToolHeadlessCommand` wrappers
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
    with (app) {
    reg.toolFactories["move"]   = () {
        import tools.xfrm_transform : XfrmTransformTool;
        auto t = new XfrmTransformTool(() => &mesh(), &gpu(), &editMode());
        t.flagT = true; t.flagR = false; t.flagS = false;
        t.handleFamily = 0;
        t.handlePresentation = "full";
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        if (aiExplore.enabled && aiLogWriter.enabled)
            t.setAiExploreSilentHover(true);
        return cast(Tool)t;
    };
    reg.toolFactories["rotate"] = () {
        import tools.xfrm_transform : XfrmTransformTool;
        auto t = new XfrmTransformTool(() => &mesh(), &gpu(), &editMode());
        t.flagT = false; t.flagR = true; t.flagS = false;
        t.handleFamily = 1;
        t.handlePresentation = "full";
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        if (aiExplore.enabled && aiLogWriter.enabled)
            t.setAiExploreSilentHover(true);
        return cast(Tool)t;
    };
    reg.toolFactories["scale"]  = () {
        import tools.xfrm_transform : XfrmTransformTool;
        auto t = new XfrmTransformTool(() => &mesh(), &gpu(), &editMode());
        t.flagT = false; t.flagR = false; t.flagS = true;
        t.handleFamily = 2;
        t.handlePresentation = "full";
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        if (aiExplore.enabled && aiLogWriter.enabled)
            t.setAiExploreSilentHover(true);
        return cast(Tool)t;
    };
    reg.toolFactories["xfrm.transform"] = () {
        import tools.xfrm_transform : XfrmTransformTool;
        auto t = new XfrmTransformTool(() => &mesh(), &gpu(), &editMode());
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        if (aiExplore.enabled && aiLogWriter.enabled)
            t.setAiExploreSilentHover(true);
        return cast(Tool)t;
    };
    reg.toolFactories["xfrm.push"] = () {
        auto t = new PushTool(() => &mesh(), &gpu(), &editMode());
        t.setUndoBindings(history, vxEditFactory);
        return cast(Tool)t;
    };
    reg.toolFactories["xfrm.bend"] = () {
        auto t = new BendTool(() => &mesh(), &gpu(), &editMode());
        t.setUndoBindings(history, vxEditFactory);
        return cast(Tool)t;
    };
    // Align deform-tools batch (task 0361) — same headless-attr-driven
    // family as xfrm.push/xfrm.bend above (params()+applyHeadless() only,
    // no gizmo drag; driven via `tool.attr ... ; tool.doApply` from the
    // panel). Neutral tool ids per the task's public-repo naming rule.
    reg.toolFactories["xfrm.linearAlignTool"] = () {
        auto t = new LinearAlignTool(() => &mesh(), &gpu(), &editMode());
        t.setUndoBindings(history, vxEditFactory);
        return cast(Tool)t;
    };
    reg.toolFactories["xfrm.radialAlignTool"] = () {
        auto t = new RadialAlignTool(() => &mesh(), &gpu(), &editMode());
        t.setUndoBindings(history, vxEditFactory);
        return cast(Tool)t;
    };
    // Convolve sub-tools (Deform → Smooth / Jitter / Quantize) —
    // exposed as tools so the side-panel buttons use the same
    // `tool.set xfrm.smooth on` activation shape. The
    // underlying math reuses MeshSmooth / MeshJitter / MeshQuantize
    // (one-shot, not brush-interactive). Brush interactivity is a
    // follow-up; the tool surface is the prerequisite.
    reg.toolFactories["xfrm.smooth"] = () {
        auto t = new XfrmSmoothTool(&mesh(), cameraView, editMode, &gpu(),
                                    &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        return cast(Tool)t;
    };
    reg.toolFactories["xfrm.jitter"] = () {
        auto t = new XfrmJitterTool(&mesh(), cameraView, editMode, &gpu(),
                                    &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        return cast(Tool)t;
    };
    reg.toolFactories["edge.slide"] = () {
        auto t = new EdgeSlideTool(&mesh(), cameraView, editMode, &gpu(),
                                   &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        return cast(Tool)t;
    };
    reg.toolFactories["xfrm.quantize"] = () {
        auto t = new XfrmQuantizeTool(&mesh(), cameraView, editMode, &gpu(),
                                      &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        return cast(Tool)t;
    };
    reg.toolFactories["mesh.mirrorTool"] = () {
        auto t = new MirrorTool(() => &mesh(), &gpu(), litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["mesh.mirrorTool"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "mesh.mirrorTool", reg.toolFactories["mesh.mirrorTool"]);

    // Radial Sweep — interactive revolve/lathe (task 0326), promoting the
    // pre-existing `mesh.sweep` one-shot command to a drag/handle tool.
    // Generator-preview architecture identical to mesh.mirrorTool above
    // (own preview mesh, commits once at deactivate()); reuses the same
    // generic bevelEditFactory/MeshSessionEdit snapshot-diff undo path.
    // Named `mesh.radialSweepTool` (task 0326 review S2), NOT
    // `mesh.sweepTool` — that id is reserved for the task-0323 Sketch
    // Extrude port, the natural claimant of the bare "sweep" name since it
    // shares the same `Mesh.revolveProfile`/`revolveProfileEx` kernel.
    reg.toolFactories["mesh.radialSweepTool"] = () {
        auto t = new RadialSweepTool(() => &mesh(), &gpu(), &editMode(), litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["mesh.radialSweepTool"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "mesh.radialSweepTool", reg.toolFactories["mesh.radialSweepTool"]);

    // Tack (task 0126) — rigid polygon-to-polygon alignment. Mirrors the
    // mesh.mirrorTool block above: same generic MeshSessionEdit/bevelEditFactory
    // undo path, same ToolHeadlessCommand one-shot wiring.
    reg.toolFactories["mesh.tack"] = () {
        auto t = new TackTool(() => &mesh(), &gpu(), litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["mesh.tack"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "mesh.tack", reg.toolFactories["mesh.tack"]);

    // Bridge (task 0357) — interactive multi-span/twist bridge, promoted
    // from the one-shot mesh.bridge command. Same generic MeshSessionEdit/
    // bevelEditFactory undo path, same ToolHeadlessCommand one-shot wiring
    // as Mirror/Tack above.
    reg.toolFactories["mesh.bridgeTool"] = () {
        auto t = new BridgeTool(() => &mesh(), &gpu(), litShader, &editMode());
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["mesh.bridgeTool"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "mesh.bridgeTool", reg.toolFactories["mesh.bridgeTool"]);

    reg.toolFactories["prim.cube"] = () {
        auto t = new BoxTool(() => &mesh(), &gpu(), litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.cube"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "prim.cube", reg.toolFactories["prim.cube"]);

    reg.toolFactories["prim.sphere"] = () {
        auto t = new SphereTool(() => &mesh(), &gpu(), litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.sphere"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "prim.sphere", reg.toolFactories["prim.sphere"]);

    reg.toolFactories["prim.ellipsoid"] = () {
        auto t = new SphereTool(() => &mesh(), &gpu(), litShader, /*ellipsoidMode=*/true);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.ellipsoid"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "prim.ellipsoid", reg.toolFactories["prim.ellipsoid"]);

    reg.toolFactories["prim.cylinder"] = () {
        auto t = new CylinderTool(() => &mesh(), &gpu(), litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.cylinder"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "prim.cylinder", reg.toolFactories["prim.cylinder"]);

    reg.toolFactories["prim.tube"] = () {
        auto t = new TubeTool(() => &mesh(), &gpu(), litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.tube"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "prim.tube", reg.toolFactories["prim.tube"]);

    reg.toolFactories["prim.cone"] = () {
        auto t = new ConeTool(() => &mesh(), &gpu(), litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.cone"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "prim.cone", reg.toolFactories["prim.cone"]);

    reg.toolFactories["prim.capsule"] = () {
        auto t = new CapsuleTool(() => &mesh(), &gpu(), litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.capsule"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "prim.capsule", reg.toolFactories["prim.capsule"]);

    reg.toolFactories["prim.torus"] = () {
        auto t = new TorusTool(() => &mesh(), &gpu(), litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.torus"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "prim.torus", reg.toolFactories["prim.torus"]);

    reg.toolFactories["prim.arc"] = () {
        auto t = new ArcTool(() => &mesh(), &gpu(), litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.arc"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                "prim.arc", reg.toolFactories["prim.arc"]);

    // Pen has no headless path — interactive only. Tool factory
    // only; no commandFactories entry. See doc/pen_plan.md.
    reg.toolFactories["pen"] = () {
        auto t = new PenTool(() => &mesh(), &gpu(), litShader,
                             &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    // Vertex placement — interactive only; one click = one isolated vertex.
    // No commandFactories entry: headless geometry creation uses mesh.addVertex
    // (task 0131).
    reg.toolFactories["prim.vertex"] = () {
        auto t = new VertexTool(() => &mesh(), &gpu(), litShader,
                                &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    // Drag Weld — drag a source vertex onto a target vertex to weld them.
    // LMB-down picks the source; LMB-up picks the target; one snapshot-undo
    // entry per completed gesture. Gated to Vertices mode.
    reg.toolFactories["mesh.dragWeld"] = () {
        auto t = new DragWeldTool(() => &mesh(), &gpu(), litShader,
                                  &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    // Edge Extrude — interactive (drag → extrude/width) + headless
    // (tool.attr edge.extrude extrude/width; tool.doApply). Topology-creating
    // tool: own typed edit factory (MeshSessionEdit, not vxEditFactory),
    // wired via the prim.cube registration template. Gated to Edges mode by
    // EdgeExtrudeTool.supportedModes().
    reg.toolFactories["edge.extrude"] = () {
        auto t = new EdgeExtrudeTool(() => &mesh(), &gpu(), &editMode(), litShader,
                                     &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, edgeExtrudeEditFactory);
        return cast(Tool)t;
    };

    // Face Extrude — interactive (drag → distance along region normal) + headless
    // (tool.attr poly.extrude distance <v>; tool.doApply). Topology-creating
    // tool: own typed edit factory (MeshSessionEdit, snapshot-only undo).
    // Gated to Polygons mode by PolyExtrudeTool.supportedModes().
    reg.toolFactories["poly.extrude"] = () {
        auto t = new PolyExtrudeTool(() => &mesh(), &gpu(), &editMode(), litShader,
                                     &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, polyExtrudeEditFactory);
        return cast(Tool)t;
    };

    // Radial Array — interactive (angle-cube haul → End Angle; axis-arrow haul
    // → Offset; off-handle click → reposition Center) + headless (tool.attr
    // mesh.radialArrayTool count/axis/center/angle/offset/weld; tool.doApply).
    // Reuses the shared Mesh.radialArrayFaces kernel (same-mesh clone
    // insertion, no new layers) already exercised by the one-shot
    // mesh.radial_array command. Topology-creating tool: own typed edit
    // factory (MeshSessionEdit, snapshot-only undo).
    reg.toolFactories["mesh.radialArrayTool"] = () {
        auto t = new RadialArrayTool(() => &mesh(), &gpu(), &editMode(), litShader,
                                     &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, radialArrayEditFactory);
        return cast(Tool)t;
    };

    // Stroke Extrude — interactive (click-drag draws a camera-raycast
    // world-space path, selected polygons extrude along it in bands) +
    // headless via the separate one-shot mesh.strokeExtrude command
    // (explicit path-point param — the interactive tool itself has NO
    // headless path, matching the captured reference finding). Task 0323,
    // basic/captured scope. Topology-creating tool: own typed edit factory
    // (MeshSessionEdit, snapshot-only undo). Gated to Polygons mode
    // by StrokeExtrudeTool.supportedModes().
    reg.toolFactories["tool.strokeExtrude"] = () {
        auto t = new StrokeExtrudeTool(() => &mesh(), &gpu(), litShader,
                                       &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, strokeExtrudeEditFactory);
        return cast(Tool)t;
    };

    // Edge Extend — interactive (drag → world-axis Offset via the embedded
    // transform gizmo's Move bank) + headless (tool.attr edge.extend offsetX...;
    // tool.doApply). Topology-creating tool: own typed edit factory
    // (MeshSessionEdit). Gated to Edges mode by EdgeExtendTool.supportedModes().
    reg.toolFactories["edge.extend"] = () {
        auto t = new EdgeExtendTool(() => &mesh(), &gpu(), &editMode(), litShader,
                                    &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, edgeExtendEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        return cast(Tool)t;
    };

    // Poly Bevel — interactive + headless (inset, shift params). Topology-creating
    // tool: reuses bevelEditFactory (MeshSessionEdit snapshot undo). Gated to Polygons.
    reg.toolFactories["poly.bevel"] = () {
        auto t = new PolyBevelTool(() => &mesh(), &gpu(), &editMode(), litShader,
                                   &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    // Polygon Inset — interactive (task 0359 promotion of the one-shot
    // mesh.poly_inset command). One attribute (inset), always per-polygon,
    // no drawn gizmo (toolcard-confirmed) — a generic viewport click+drag
    // hauls the value. Reuses the generic MeshSessionEdit/bevelEditFactory
    // before/after-snapshot undo path, same as mesh.mirrorTool/mesh.tack
    // above. Gated to Polygons.
    reg.toolFactories["mesh.polyInsetTool"] = () {
        auto t = new PolyInsetTool(() => &mesh(), &gpu(), &editMode(), litShader,
                                   &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    // Smooth Shift + Thicken — interactive (2 handles: Offset, Scale) + headless
    // (tool.attr mesh.smoothShiftTool shift/scale/maxAngle/thicken/sharp <v>;
    // tool.doApply). Topology-creating tool: own typed edit factory
    // (MeshSessionEdit, snapshot-only undo). Gated to Polygons mode by
    // SmoothShiftTool.supportedModes(). The reference editor's Thicken toolbar
    // button is confirmed (task 0358) to be THIS SAME tool with thicken=1
    // forced, not a separate tool — see config/buttons.yaml.
    reg.toolFactories["mesh.smoothShiftTool"] = () {
        auto t = new SmoothShiftTool(() => &mesh(), &gpu(), &editMode(), litShader,
                                     &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, smoothShiftEditFactory);
        return cast(Tool)t;
    };
    reg.toolFactories["xfrm.magnet"] = () {
        auto t = new MagnetTool(() => &mesh(), &gpu(), &editMode(),
                                &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, vxEditFactory);
        return cast(Tool)t;
    };

    // Edge Bevel — interactive + headless (width param). Topology-creating tool:
    // reuses bevelEditFactory (MeshSessionEdit snapshot undo). Gated to Edges mode.
    reg.toolFactories["edge.bevel"] = () {
        auto t = new EdgeBevelTool(() => &mesh(), &gpu(), &editMode(), litShader,
                                   &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    // Vertex Bevel — interactive (task 0360 promotion of the one-shot
    // mesh.vertexBevel command). Single-handle Inset, ACTR-anchored,
    // mirrors EdgeBevelTool one element type down. Reuses bevelEditFactory
    // (MeshSessionEdit snapshot undo) and the SAME id as the pre-existing
    // one-shot command (reg.commandFactories["mesh.vertexBevel"] below,
    // untouched) — separate registries, same precedent as poly.extrude/
    // mesh.mirrorTool elsewhere in this file. Gated to Vertices mode.
    reg.toolFactories["mesh.vertexBevel"] = () {
        auto t = new VertexBevelTool(() => &mesh(), &gpu(), &editMode(), litShader,
                                     &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    // Vertex Extrude — interactive (task 0360 promotion of the one-shot
    // mesh.vertexExtrude command). Two independent handles (Extrude/shift,
    // Width) mirroring PolyBevelTool's Shift/Inset pair. Reuses
    // bevelEditFactory (MeshSessionEdit snapshot undo); same id as the
    // pre-existing one-shot command, separate registries (see
    // mesh.vertexBevel above). Gated to Vertices mode.
    reg.toolFactories["mesh.vertexExtrude"] = () {
        auto t = new VertexExtrudeTool(() => &mesh(), &gpu(), &editMode(), litShader,
                                       &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    // Vertex Merge — interactive (task 0360 promotion of the one-shot
    // vert.merge command). No drawn handle — a generic viewport haul, same
    // family as mesh.polyInsetTool. Reuses bevelEditFactory (MeshSessionEdit
    // snapshot undo); same id as the pre-existing one-shot command (which
    // keeps its own range/keep/morph params, untouched — see
    // tools/vert_merge_tool.d's doc-comment). Gated to Vertices mode.
    reg.toolFactories["vert.merge"] = () {
        auto t = new VertexMergeTool(() => &mesh(), &gpu(), &editMode(), litShader,
                                     &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    // Loop Slice — hover-seeded interactive edge-loop cut. Topology-creating
    // tool: reuses the SAME collectEdgeRing/insertEdgeLoops kernel as the
    // mesh.loopSlice/mesh.addLoop commands (untouched); mutate/revert preview,
    // one MeshSessionEdit undo entry PER committed cut. Gated to Edges mode.
    reg.toolFactories["mesh.loopSliceTool"] = () {
        auto t = new LoopSliceTool(() => &mesh(), &gpu(), &editMode(), litShader,
                                   &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, loopSliceEditFactory);
        return cast(Tool)t;
    };

    // Slice (plane/line) — interactive Start→End line cut with a plane
    // PERPENDICULAR to the work plane (mesh.sliceTool, task 0266 S0). Reuses
    // Mesh.cutByPlane; one MeshSnapshot undo entry per committed slice
    // (reuses the generic bevelEditFactory snapshot command, labelled "Slice").
    // Distinct from the camera-plane one-shot mesh.screenSlice command.
    reg.toolFactories["mesh.sliceTool"] = () {
        auto t = new SliceTool(() => &mesh(), &gpu(), &editMode(), litShader,
                               &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    // Edge Slice — interactive two-edge strip cut (mesh.edgeSliceTool):
    // hover an edge -> click latches edge A + tA -> drag scrubs tA -> click a
    // second edge latches edge B + tB and previews the cut live -> commit on
    // Enter / tool-drop / a third click. Reuses the EXISTING
    // Mesh.edgeSlice(edgeA, edgeB, tA, tB, splitPolygons) kernel; one
    // MeshSessionEdit undo entry per committed cut (reuses the generic
    // bevelEditFactory snapshot command, labelled "Edge Slice"). The one-shot
    // mesh.edgeSlice command stays registered below for headless/scripting.
    // Gated to Edges mode.
    reg.toolFactories["mesh.edgeSliceTool"] = () {
        auto t = new EdgeSliceTool(() => &mesh(), &gpu(), &editMode(), litShader,
                                   &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    // Mesh Reduction — interactive + headless (ratio, preserveBoundary params).
    // Whole-mesh decimation via reduceToTarget; snapshot undo via MeshSessionEdit.
    // Gated to Polygons mode (whole-mesh op, but surfaced in polygon mode).
    reg.toolFactories["mesh.reduceTool"] = () {
        auto t = new ReductionTool(() => &mesh(), &gpu(), &editMode(), litShader,
                                   &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, reduceEditFactory);
        return cast(Tool)t;
    };

    // Clone — interactive drag-place a single copy of the selection (offset
    // by the drag delta on the most-facing screen plane).  Snapshot undo via
    // MeshSessionEdit; gated to Polygons mode.  Drag→offset feel is a
    // vibe3d-divergence (no reference tool-model; uses planeDragDelta).
    reg.toolFactories["mesh.clone"] = () {
        auto t = new CloneTool(() => &mesh(), &gpu(), &editMode(),
                               &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, cloneEditFactory);
        return cast(Tool)t;
    };

    // Array — interactive 3-axis grid array (task 0355), promoting the
    // one-shot mesh.array command's 1D line kernel to Mesh.arrayFacesGrid.
    // Snapshot undo via MeshSessionEdit; edit-mode-orthogonal (same face-
    // selection-or-whole-mesh convention as mesh.array/mesh.mirror).
    reg.toolFactories["mesh.arrayTool"] = () {
        auto t = new ArrayTool(() => &mesh(), &gpu(), &editMode(),
                               &vertexCache(), &edgeCache(), &faceCache());
        t.setUndoBindings(history, arrayEditFactory);
        return cast(Tool)t;
    };
    }
}

/// Registers the remaining `reg.commandFactories[id]` entries — tool.*,
/// ui.*, layer.*, ai3d.*, workplane.*, actr.*, falloff.*, select.*, mesh.*,
/// history.*, macro.* (app.d's former Span B, ~3395-4132). Phase 2 (0415).
void registerCommands(EditorApp app) {
}
