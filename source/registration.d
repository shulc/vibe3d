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
///
/// Body is a VERBATIM cut of former app.d text, wrapped in `with (app) {
/// with (ai3dRefs) { with (remeshRefs) { } } }` so every bare identifier
/// (mesh(), reg.*, history, vpm, toolHost, the ai3d/remesh modal fields,
/// subpatchPreview, activeTool, running, showHistoryPanel,
/// resetAllPipeStages, the hook delegates, ...) resolves through the ctx
/// instead of a main()-local of the same name. The only line-level edits
/// versus the original text are Edit-class 1 (`&x` -> `&x()`, 19 &document
/// + 10 &editMode sites) and Edit-class 2 (`&switchToItemType` ->
/// `switchToItemType`, the one address-taken hook -- see task doc).
void registerCommands(EditorApp app) {
    with (app) {
    with (ai3dRefs) {
    with (remeshRefs) {
    reg.commandFactories["tool.set"] = () => cast(Command)
        new ToolSetCommand(&mesh(), cameraView, editMode, toolHost);
    reg.commandFactories["tool.attr"] = () => cast(Command)
        new ToolAttrCommand(&mesh(), cameraView, editMode, toolHost);
    reg.commandFactories["tool.doApply"] = () => cast(Command)
        new ToolDoApplyCommand(&mesh(), cameraView, editMode, toolHost,
                               history);
    reg.commandFactories["tool.reset"] = () => cast(Command)
        new ToolResetCommand(&mesh(), cameraView, editMode, toolHost);
    reg.commandFactories["tool.pipe.attr"] = () => cast(Command)
        new ToolPipeAttrCommand(&mesh(), cameraView, editMode, toolHost);
    // Test-only headless hooks (re-eval plan D5, Phase 3). Both reject
    // themselves unless g_testMode (set by --test); inert in a normal run.
    reg.commandFactories["tool.beginSession"] = () => cast(Command)
        new ToolBeginSessionCommand(&mesh(), cameraView, editMode, toolHost);
    reg.commandFactories["tool.panelEdit"] = () => cast(Command)
        new ToolPanelEditCommand(&mesh(), cameraView, editMode, toolHost);
    reg.commandFactories["ui.toolProperties"] = () => cast(Command)
        new UiToolPropertiesCommand(&mesh(), cameraView, editMode);
    reg.commandFactories["ui.layerList"] = () => cast(Command)
        new UiLayerListCommand(&mesh(), cameraView, editMode);
    reg.commandFactories["ui.viewportProps"] = () => cast(Command)
        new UiViewportPropsCommand(&mesh(), cameraView, editMode);

    // layer.* commands (layers Stage 2) — mutate the one Document; the
    // active-index movers (add/delete/select) fire onActiveLayerChanged.
    {
        import commands.layer.commands : LayerAdd, LayerDelete, LayerDuplicate,
                                          LayerSelect, LayerRename, LayerSetVisible,
                                          LayerReorder, LayerAttr, LayerParent;
        import commands.ai3d.import_result : Ai3dImportResult;
        import commands.ai3d.generate : Ai3dGenerate;
        reg.commandFactories["layer.add"] = () => cast(Command)
            new LayerAdd(&mesh(), cameraView, editMode, &document(), onActiveLayerChanged);
        reg.commandFactories["layer.duplicate"] = () => cast(Command)
            new LayerDuplicate(&mesh(), cameraView, editMode, &document(), onActiveLayerChanged);
        reg.commandFactories["layer.delete"] = () => cast(Command)
            new LayerDelete(&mesh(), cameraView, editMode, &document(), onActiveLayerChanged);
        reg.commandFactories["layer.reorder"] = () => cast(Command)
            new LayerReorder(&mesh(), cameraView, editMode, &document(), onActiveLayerChanged);
        reg.commandFactories["layer.select"] = () => cast(Command)
            (new LayerSelect(&mesh(), cameraView, editMode, &document(), onActiveLayerChanged))
                .setItemSelectHook(switchToItemType);
        reg.commandFactories["layer.rename"] = () => cast(Command)
            new LayerRename(&mesh(), cameraView, editMode, &document(), onActiveLayerChanged);
        reg.commandFactories["layer.setVisible"] = () => cast(Command)
            new LayerSetVisible(&mesh(), cameraView, editMode, &document(), onActiveLayerChanged);
        // layer.attr — generic per-layer Param write/read (survey #3). Wired
        // with &document() like the others; the active-switch hook is unused (a
        // property edit never moves the active layer) but passed for ctor
        // uniformity.
        reg.commandFactories["layer.attr"] = () => cast(Command)
            new LayerAttr(&mesh(), cameraView, editMode, &document(), onActiveLayerChanged);
        // layer.parent — set/clear item-parent reference (task 0082).
        reg.commandFactories["layer.parent"] = () => cast(Command)
            new LayerParent(&mesh(), cameraView, editMode, &document(), onActiveLayerChanged);

        // ai3d.importResult — editor-side landing command for the optional
        // external AI3D worker. It consumes a staged OBJ path, validates the
        // ImportedScene through the AI3D gate, then adds one undoable layer.
        reg.commandFactories["ai3d.importResult"] = () => cast(Command)
            new Ai3dImportResult(&mesh(), cameraView, editMode, &document(),
                                 onActiveLayerChanged);
        // Explicit/scripted vertical-slice command. It is intentionally inert
        // unless the caller supplies an image path; normal editor startup makes
        // no worker request. The async UI/controller will replace this path.
        reg.commandFactories["ai3d.generate"] = () => cast(Command)
            new Ai3dGenerate(&mesh(), cameraView, editMode, &document(),
                             onActiveLayerChanged);

        // ai3d.generate.start / ai3d.generate.cancel — test-only hooks
        // (task 0381 Phase 2, mirrors tool.beginSession/tool.panelEdit)
        // that drive the app-owned Ai3dJobController directly. There is no
        // production HTTP path to the async controller until the Phase 3
        // modal exists (a live UI picker + Generate/Cancel button click),
        // so automated tests need a bare starter/canceller to exercise the
        // per-frame drain + ai3d.importResult wiring end-to-end against the
        // real vibe3d --test process. Gated on g_testMode; unreachable in a
        // normal build/run.
        import commands.ai3d.generate_test_hooks : Ai3dGenerateStartTestCommand,
            Ai3dGenerateCancelTestCommand;
        reg.commandFactories["ai3d.generate.start"] = () => cast(Command)
            new Ai3dGenerateStartTestCommand(&mesh(), cameraView, editMode, ai3dController);
        reg.commandFactories["ai3d.generate.cancel"] = () => cast(Command)
            new Ai3dGenerateCancelTestCommand(&mesh(), cameraView, editMode, ai3dController);

        // ai3d.generate.open — `File > Generate 3D…` (task 0381 Phase 3).
        // Zero params, so dispatchAction's tryOpenArgsDialog (app.d, near
        // line 7288) never pops the generic args dialog for it — the click
        // runs apply() directly. On a picked image, stash the path, reset
        // the modal snapshot, open the popup, and kick off a health probe
        // so the modal's health line + Generate gate populate before the
        // user commits.
        import commands.ai3d.generate_open : Ai3dGenerateOpen;
        reg.commandFactories["ai3d.generate.open"] = () => cast(Command)
            new Ai3dGenerateOpen(&mesh(), cameraView, editMode, (string path) {
                import std.string : fromStringz;
                ai3dPickedImagePath  = path;
                ai3dModal            = Ai3dModalState.init;
                ai3dModalOpen        = true;
                ai3dModalPendingOpen = true;
                const workerUrl = cast(string) fromStringz(ai3dWorkerUrlBuf.ptr).dup;
                ai3dController.probeHealth(
                    workerUrl.length ? workerUrl : "http://127.0.0.1:47831");
            });
    }

    // workplane.* commands — target the WorkplaneStage (ordinal 0x30)
    // in the global tool pipe.
    reg.commandFactories["workplane.reset"] = () => cast(Command)
        new WorkplaneResetCommand(&mesh(), cameraView, editMode);
    reg.commandFactories["workplane.edit"] = () => cast(Command)
        new WorkplaneEditCommand(&mesh(), cameraView, editMode);
    reg.commandFactories["workplane.rotate"] = () => cast(Command)
        new WorkplaneRotateCommand(&mesh(), cameraView, editMode);
    reg.commandFactories["workplane.offset"] = () => cast(Command)
        new WorkplaneOffsetCommand(&mesh(), cameraView, editMode);
    reg.commandFactories["workplane.alignToSelection"] = () => cast(Command)
        new WorkplaneAlignToSelectionCommand(&mesh(), cameraView, editMode);

    // Phase 7.2f: actr.<mode> — combined presets that flip ACEN + AXIS
    // stages atomically. Granular tool.pipe.attr
    // forms remain available for mix-and-match. Mappings per
    // phase7_2_plan.md §"Canonical user commands".
    {
        import commands.actr : ActrPresetCommand;
        // (preset, acenMode, axisMode) tuples.
        static struct Preset { string name; string acen; string axis; }
        immutable Preset[] presets = [
            Preset("auto",       "auto",       "auto"),
            Preset("select",     "select",     "select"),
            Preset("selectauto", "selectauto", "selectauto"),
            Preset("element",    "element",    "element"),
            Preset("local",      "local",      "local"),
            Preset("origin",     "origin",     "world"),    // axis at origin = world
            Preset("screen",     "screen",     "screen"),
            Preset("border",     "border",     "select"),   // border edges + selection-aligned axis
            Preset("none",       "none",       "none"),     // "(none)" — drops both, world fallback
            Preset("pivot",      "pivot",      "pivot"),    // 0082: item pivot
            Preset("parent",     "parent",     "parent"),   // 0082: parent item frame
        ];
        // IIFE capture by value — the bare-foreach + lambda pattern
        // closes over the loop variable by reference in D, so without
        // this all 8 factories would end up calling with the LAST
        // iteration's mode strings.
        Command delegate() makeFactory(string nm, string a, string x) {
            return () => cast(Command)
                new ActrPresetCommand(&mesh(), cameraView, editMode, nm, a, x);
        }
        foreach (p; presets) {
            reg.commandFactories["actr." ~ p.name] =
                makeFactory(p.name, p.acen, p.axis);
        }
    }

    // Bare named falloff sub-tools: falloff.<type> sets the falloff (WGHT)
    // stage's `type` and keeps the active transform tool (NOT a tool that
    // replaces the active tool, NOT a transform bundle). Same write path as
    // the status-bar Falloff pulldown (`tool.pipe.attr falloff type <type>`),
    // so the on-switch auto-size + state-publish + live re-eval side-effects
    // are identical. The two BUNDLE presets falloff.element / falloff.selection
    // (base xfrm.transform + pipe.falloff.type) live in config/tool_presets.yaml
    // and stay separate.
    {
        import commands.falloff : FalloffPresetCommand,
                                   FalloffAddCommand, FalloffRemoveCommand,
                                   FalloffClearCommand,
                                   FalloffAutoSizeCommand, FalloffReverseCommand;
        // IIFE capture by value — same closure-over-loop-variable trap the
        // actr.* block above documents.
        Command delegate() makeFalloffFactory(string ty) {
            return () => cast(Command)
                new FalloffPresetCommand(&mesh(), cameraView, editMode, toolHost, ty);
        }
        static immutable string[] falloffTypes =
            ["linear", "radial", "cylinder", "screen", "lasso", "vertexMap"];
        foreach (ty; falloffTypes)
            reg.commandFactories["falloff." ~ ty] = makeFalloffFactory(ty);

        // Multi-falloff stacking verbs (Phase 4): add/remove/clear extra
        // falloff instances. `falloff.add <type>` / `falloff.remove <id>`
        // take a positional arg wired in injectToolCommandPositional below.
        reg.commandFactories["falloff.add"] = () => cast(Command)
            new FalloffAddCommand(&mesh(), cameraView, editMode, toolHost);
        reg.commandFactories["falloff.remove"] = () => cast(Command)
            new FalloffRemoveCommand(&mesh(), cameraView, editMode, toolHost);
        reg.commandFactories["falloff.clear"] = () => cast(Command)
            new FalloffClearCommand(&mesh(), cameraView, editMode, toolHost);

        // Falloff form action buttons: `falloff.autosize <axis>` (X/Y/Z fit) and
        // `falloff.reverse` (swap start/end). autosize's axis is wired in
        // injectToolCommandPositional below.
        reg.commandFactories["falloff.autosize"] = () => cast(Command)
            new FalloffAutoSizeCommand(&mesh(), cameraView, editMode, toolHost);
        reg.commandFactories["falloff.reverse"] = () => cast(Command)
            new FalloffReverseCommand(&mesh(), cameraView, editMode, toolHost);
    }

    reg.commandFactories["select.expand"]         = () => cast(Command) new SelectionExpand(&mesh(), cameraView, editMode);
    reg.commandFactories["select.contract"]       = () => cast(Command) new SelectionContract(&mesh(), cameraView, editMode);
    reg.commandFactories["select.more"]           = () => cast(Command) new SelectMore(&mesh(), cameraView, editMode);
    reg.commandFactories["select.less"]           = () => cast(Command) new SelectLess(&mesh(), cameraView, editMode);
    reg.commandFactories["select.loop"]           = () => cast(Command) new SelectLoop(&mesh(), cameraView, editMode);
    reg.commandFactories["select.ring"]           = () => cast(Command) new SelectRing(&mesh(), cameraView, editMode);
    reg.commandFactories["select.invert"]         = () => cast(Command) new SelectInvert(&mesh(), cameraView, editMode);
    reg.commandFactories["select.connect"]        = () => cast(Command) new SelectConnect(&mesh(), cameraView, editMode);
    reg.commandFactories["select.between"]        = () => cast(Command) new SelectBetween(&mesh(), cameraView, editMode);
    reg.commandFactories["select.fill.holes"]      = () => cast(Command)
        new SelectFillHoles(&mesh(), cameraView, editMode);
    reg.commandFactories["select.fill.insideLoop"] = () => cast(Command)
        (new SelectFillInsideLoop(&mesh(), cameraView, editMode, &editMode()))
            .setPromoteHook((EditMode m) => promoteGeometryType(m));
    reg.commandFactories["select.typeFrom"]  = () => cast(Command)
        new SelectTypeFromCommand(&mesh(), cameraView, editMode, &editMode(),
                                  (EditMode m) => switchGeometryType(m));
    reg.commandFactories["select.vertex"]    = () => cast(Command)
        new SelectTypeFromCommand(&mesh(), cameraView, editMode, &editMode(), "vertex",
                                  (EditMode m) => switchGeometryType(m));
    reg.commandFactories["select.edge"]      = () => cast(Command)
        new SelectTypeFromCommand(&mesh(), cameraView, editMode, &editMode(), "edge",
                                  (EditMode m) => switchGeometryType(m));
    reg.commandFactories["select.polygon"]   = () => cast(Command)
        new SelectTypeFromCommand(&mesh(), cameraView, editMode, &editMode(), "polygon",
                                  (EditMode m) => switchGeometryType(m));
    reg.commandFactories["select.drop"]      = () => cast(Command)
        new SelectDropCommand(&mesh(), cameraView, editMode);
    reg.commandFactories["select.element"]   = () => cast(Command)
        new SelectElementCommand(&mesh(), cameraView, editMode);
    reg.commandFactories["select.convert"]   = () => cast(Command)
        (new SelectConvertCommand(&mesh(), cameraView, editMode, &editMode()))
            .setPromoteHook((EditMode m) => promoteGeometryType(m));
    // Fit routes through the focus/scale OWNER cameras of the active (=
    // hovered, per 0220) cell — not the cell's own (possibly follower)
    // camera. For a default Quad follower both owners are the group master,
    // so A/Shift+A reframe the whole linked group (visible in every cell);
    // an indCenter/indScale cell owns itself and fits independently. Same
    // owner redirect 0217 uses for pan/zoom. Single view: owners = self →
    // byte-neutral under --test.
    reg.commandFactories["viewport.fit"]          = () => cast(Command) new Fit(&mesh(),
        vpm.focusOwnerCamera(vpm.activeId), vpm.scaleOwnerCamera(vpm.activeId), editMode);
    reg.commandFactories["viewport.fit_selected"] = () => cast(Command) new FitSelected(&mesh(),
        vpm.focusOwnerCamera(vpm.activeId), vpm.scaleOwnerCamera(vpm.activeId), editMode);
    {
        import commands.snap.toggle : SnapToggleCommand;
        import commands.snap.mode   : SnapModeCommand;
        reg.commandFactories["snap.toggle"] = () => cast(Command)
            new SnapToggleCommand(&mesh(), cameraView, editMode);
        import commands.constrain.toggle : ConstrainToggleCommand;
        reg.commandFactories["constrain.toggle"] = () => cast(Command)
            new ConstrainToggleCommand(&mesh(), cameraView, editMode);
        reg.commandFactories["snap.toggleType"] = () => cast(Command)
            new SnapToggleTypeCommand(&mesh(), cameraView, editMode);
        reg.commandFactories["snap.mode"] = () => cast(Command)
            new SnapModeCommand(&mesh(), cameraView, editMode);
    }
    {
        reg.commandFactories["path.define"] = () => cast(Command)
            new PathDefineCommand(&mesh(), cameraView, editMode);
    }
    {
        Command delegate() makeAiFactory(AiToggleAction action) {
            return () => cast(Command)
                new AiToggleCommand(&mesh(), cameraView, editMode, aiState, action);
        }
        reg.commandFactories["ai.toggle"]  = makeAiFactory(AiToggleAction.toggle);
        reg.commandFactories["ai.enable"]  = makeAiFactory(AiToggleAction.enable);
        reg.commandFactories["ai.disable"] = makeAiFactory(AiToggleAction.disable);
    }
    // AI Modeling Copilot findings-panel commands: version(WithAI)-only,
    // compiled out of modeling-noai entirely (see import block doc comment).
    version (WithAI)
    {
        // AI Modeling Copilot (task 0402 Phase 2): copilot.analyze is a pure
        // read (repopulates copilotPanel's findings list); copilot.selectFinding
        // is the ONLY act-on and wraps the SAME "mesh.select" factory app.d
        // registers below (lazy lookup — evaluated when the wrapper's own
        // apply() runs, well after every factory is registered, so
        // registration order here does not matter) so it inherits that
        // factory's promoteGeometryType hook + resolved-viewport provider.
        // See commands/copilot/*.d doc comments.
        reg.commandFactories["copilot.analyze"] = () => cast(Command)
            new CopilotAnalyzeCommand(&mesh(), cameraView, editMode, copilotPanel);
        reg.commandFactories["copilot.selectFinding"] = () => cast(Command)
            new CopilotSelectFindingCommand(&mesh(), cameraView, editMode,
                copilotPanel, aiState,
                () => reg.commandFactories["mesh.select"]());
        // copilot.cycleFinding (task 0402 Phase 3): panel Prev/Next + Up/Down
        // both dispatch this. It computes only the new index and delegates
        // the actual select-only act-on to a CopilotSelectFindingCommand it
        // builds internally (see cycle_finding.d) — same meshSelectFactory
        // lazy lookup as copilot.selectFinding above.
        reg.commandFactories["copilot.cycleFinding"] = () => cast(Command)
            new CopilotCycleFindingCommand(&mesh(), cameraView, editMode,
                copilotPanel, aiState,
                () => reg.commandFactories["mesh.select"]());
        // Test-only visibility flip (idiom: commands.ui.layer_list /
        // g_layerListShown) — see commands/ui/copilot_panel.d.
        reg.commandFactories["ui.copilotPanel"] = () => cast(Command)
            new UiCopilotPanelCommand(&mesh(), cameraView, editMode);
    }
    {
        import commands.symmetry.toggle : SymmetryToggleCommand;
        reg.commandFactories["symmetry.toggle"] = () => cast(Command)
            new SymmetryToggleCommand(&mesh(), cameraView, editMode);
    }
    // File → Open (Ctrl+O): native-primary "All supported" dialog; a .v3d
    // load becomes the current document. `file.load` is also the id the
    // HTTP /api/command path drives via setPath(), so it must stay
    // registered with the open framing (setPath bypasses the dialog).
    reg.commandFactories["file.load"] = () {
        auto c = new FileLoad(&mesh(), cameraView, editMode, &document());
        c.configure(FileLoadMode.open);
        return cast(Command) c;
    };
    reg.commandFactories["file.open"] = reg.commandFactories["file.load"];
    // File → Save (Ctrl+S): write to the remembered .v3d path, else prompt.
    reg.commandFactories["file.save"] = () {
        auto c = new FileSave(&mesh(), cameraView, editMode, &document());
        c.configure(FileSaveMode.save);
        return cast(Command) c;
    };
    // File → Save As (Ctrl+Shift+S): always prompt, native .v3d.
    reg.commandFactories["file.saveAs"] = () {
        auto c = new FileSave(&mesh(), cameraView, editMode, &document());
        c.configure(FileSaveMode.saveAs);
        return cast(Command) c;
    };
    // Import ▸ X — single-format open dialog -> FileLoad (importSingle mode
    // leaves the current document untitled). One id per interchange format.
    //
    // NOTE: a plain `foreach`-body closure would capture the loop variable by
    // REFERENCE — in D every delegate would share one storage slot and see the
    // LAST ext (.fbx), so every Import/Export item opened an FBX dialog. (The
    // `immutable ext = importExt;` idiom does NOT create a fresh per-iteration
    // binding in D.) Pass ext as a function parameter so each delegate closes
    // over its own copy.
    CommandFactory importFactory(string ext) {
        return () {
            auto c = new FileLoad(&mesh(), cameraView, editMode, &document());
            c.configure(FileLoadMode.importSingle, ext);
            return cast(Command) c;
        };
    }
    foreach (importExt; [".lwo", ".obj", ".gltf", ".fbx"])
        reg.commandFactories["file.import" ~ importExt] = importFactory(importExt);
    // Export ▸ X — single-format save dialog -> FileSave (exportSingle mode
    // leaves the current document path untouched). FBX writes via assimp's
    // binary FBX exporter (unit-scale handled in io.scene_export). Same
    // per-ext closure-capture care as the import loop above.
    CommandFactory exportFactory(string ext) {
        return () {
            auto c = new FileSave(&mesh(), cameraView, editMode, &document());
            c.configure(FileSaveMode.exportSingle, ext);
            return cast(Command) c;
        };
    }
    foreach (exportExt; [".lwo", ".obj", ".gltf", ".fbx"])
        reg.commandFactories["file.export" ~ exportExt] = exportFactory(exportExt);
    // "File → New" = empty scene. Wraps SceneReset with the
    // already-supported `setEmpty(true)` mode; undo restores
    // whatever was open before.
    reg.commandFactories["file.new"] = () {
        auto c = new SceneReset(&mesh(), cameraView, editMode,
                                 &editMode(),
                                 () {
                                     // Task 0232 fold #1(a): a Loop Slice
                                     // standing preview must be dropped BEFORE
                                     // the generic tool-drop below —
                                     // deactivate()'s normal commit/cancel path
                                     // would otherwise fire against the mesh
                                     // this reset already overwrote in place
                                     // (`*mesh = ...` runs earlier in
                                     // SceneReset.apply(), before onResetTool).
                                     // dropArmedPreview() never touches the
                                     // mesh or history, so its ordering
                                     // relative to that swap doesn't matter
                                     // for correctness — it only matters that
                                     // it runs BEFORE setActiveTool(null).
                                     if (auto lst = cast(LoopSliceTool) activeTool)
                                         lst.dropArmedPreview();
                                     if (auto est = cast(EdgeSliceTool) activeTool)
                                         est.dropArmedPreview();
                                     setActiveTool(null);
                                     resetAllPipeStages();
                                     // A reset is a clean slate: force the
                                     // subpatch preview OFF so a leftover
                                     // `active` preview cannot carry into the
                                     // fresh scene and turn tool-side cage
                                     // uploads into stray mutationVersion bumps
                                     // (see SubpatchPreview.deactivate).
                                     subpatchPreview.deactivate();
                                 },
                                 () {
                                     vpm.resetToDefault();
                                     // Mirror the live reset (always Single)
                                     // into prefs so a clean-shutdown save
                                     // doesn't persist a stale multi-cell
                                     // preset from before this reset.
                                     g_prefs.viewportLayout = LayoutPreset.Single;
                                 });
        c.setDocument(&document());
        c.setEmpty(true);
        c.setPromoteHook((EditMode m) => promoteGeometryType(m));
        return cast(Command) c;
    };
    {
        import commands.file.quit : FileQuit;
        reg.commandFactories["file.quit"] = () => cast(Command)
            new FileQuit(&mesh(), cameraView, editMode, () { running = false; });
    }
    reg.commandFactories["mesh.subdivide"] = () => cast(Command)
        new Subdivide(&mesh(), cameraView, editMode,
                      () => setActiveTool(null));
    // Quad Remesh (source/remesh/remesh_job.d): `mesh.remesh.start` kicks off
    // the async subprocess (HTTP/menu-triggerable — see remeshJob.poll() near
    // the ai3d drain for how the result lands); `mesh.remesh` is the
    // undoable apply that a successful job's result is fired through.
    reg.commandFactories["mesh.remesh.start"] = () => cast(Command)
        new RemeshStart(&mesh(), cameraView, editMode, remeshJob);
    reg.commandFactories["mesh.remesh"] = () => cast(Command)
        new Remesh(&mesh(), cameraView, editMode,
                   () => setActiveTool(null), remeshJob);
    reg.commandFactories["mesh.remesh.open"] = () => cast(Command)
        new RemeshOpen(&mesh(), cameraView, editMode, () {
            remeshModalOpen        = true;
            remeshModalPendingOpen = true;
            remeshLastError        = null;
            remeshLastSummary      = null;
        });
    reg.commandFactories["mesh.subdivide_faceted"] = () => cast(Command)
        new SubdivideFaceted(&mesh(), cameraView, editMode,
                             () => setActiveTool(null));
    reg.commandFactories["mesh.triple"] = () => cast(Command)
        new MeshTriple(&mesh(), cameraView, editMode,
                       () => setActiveTool(null));
    reg.commandFactories["mesh.quadruple"] = () => cast(Command)
        new MeshQuadruple(&mesh(), cameraView, editMode,
                          () => setActiveTool(null));
    reg.commandFactories["mesh.detriangulate"] = () => cast(Command)
        new MeshDetriangulate(&mesh(), cameraView, editMode,
                              () => setActiveTool(null));
    reg.commandFactories["mesh.mergeFaces"] = () => cast(Command)
        new MeshMergeFaces(&mesh(), cameraView, editMode,
                           () => setActiveTool(null));
    reg.commandFactories["mesh.subpatch_toggle"] = () => cast(Command)
        new SubpatchToggle(&mesh(), cameraView, editMode);
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
    reg.commandFactories["mesh.makePolygon"] = () => cast(Command)
        new MeshMakePolygon(&mesh(), cameraView, editMode);
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
    reg.commandFactories["scene.reset"] = () {
        auto c = new SceneReset(&mesh(), cameraView, editMode,
                       &editMode(),
                       () {
                           setActiveTool(null);
                           resetAllPipeStages();
                           // Clean slate: force the subpatch preview OFF (see
                           // SubpatchPreview.deactivate / the scene.reset hook).
                           subpatchPreview.deactivate();
                       },
                       () {
                           vpm.resetToDefault();
                           // Mirror the live reset (always Single) into
                           // prefs so a clean-shutdown save doesn't persist
                           // a stale multi-cell preset from before this
                           // reset.
                           g_prefs.viewportLayout = LayoutPreset.Single;
                       });
        c.setDocument(&document());
        c.setPromoteHook((EditMode m) => promoteGeometryType(m));
        return cast(Command) c;
    };
    reg.commandFactories["scene.loadMesh"] = () => cast(Command)
        (new MeshLoadRaw(&mesh(), cameraView, editMode,
                         &editMode(), &cameraView(), () => setActiveTool(null)))
        .setPromoteHook((EditMode m) => promoteGeometryType(m));
    reg.commandFactories["history.undo"] = () => cast(Command)
        new HistoryUndo(&mesh(), cameraView, editMode, history);
    reg.commandFactories["history.redo"] = () => cast(Command)
        new HistoryRedo(&mesh(), cameraView, editMode, history);
    reg.commandFactories["history.show"] = () => cast(Command)
        new HistoryShow(&mesh(), cameraView, editMode,
                        () { showHistoryPanel = !showHistoryPanel; });
    // Phase 3 of the history-panel design doc — backing
    // commands for the panel's right-click context menu.
    reg.commandFactories["history.clear"] = () => cast(Command)
        new HistoryClear(&mesh(), cameraView, editMode,
                         () { history.clear(); });
    // Test-automation only: flip the shared undo-tracker toggle
    // (VIBE3D_UNDO_TRACKER) at runtime so the parity-gate test can run the same
    // sequence under both the snapshot and the delta path in one instance.
    // Reuses HistoryClear's closure wrapper (SideEffect, unrecorded). Not in any
    // menu / UI; see doc/undo_change_tracker_plan.md Phase 2 §D.
    reg.commandFactories["undo.tracker.on"] = () => cast(Command)
        new HistoryClear(&mesh(), cameraView, editMode,
            () { import mesh_edit_delta : setUndoTrackerEnabled;
                 setUndoTrackerEnabled(true); });
    reg.commandFactories["undo.tracker.off"] = () => cast(Command)
        new HistoryClear(&mesh(), cameraView, editMode,
            () { import mesh_edit_delta : setUndoTrackerEnabled;
                 setUndoTrackerEnabled(false); });
    // Test-automation only: engage / release the history-service lockout (the
    // hard gate that freezes record/undo/redo/fire — distinct from Suspend) so
    // a test can assert that locked-out recording is a no-op and /api/undo/status
    // reports lockout:true. Reuses HistoryClear's closure wrapper (SideEffect,
    // unrecorded); not in any menu / UI. Mirrors the undo.tracker.* commands.
    reg.commandFactories["undo.lockout.on"] = () => cast(Command)
        new HistoryClear(&mesh(), cameraView, editMode,
            () { history.setLockout(true); });
    reg.commandFactories["undo.lockout.off"] = () => cast(Command)
        new HistoryClear(&mesh(), cameraView, editMode,
            () { history.setLockout(false); });
    // Test-automation only: explicit undoability-override probes. The first is a
    // Model command that opts OUT (UndoSuppress) → no undo entry; the second is a
    // SideEffect command that opts IN (UndoForce) → entry lands. Drives both
    // override branches of isUndoable() through the normal dispatch path.
    reg.commandFactories["undo.test.suppress"] = () => cast(Command)
        new UndoSuppressNoop(&mesh(), cameraView, editMode);
    reg.commandFactories["undo.test.force"] = () => cast(Command)
        new UndoForceNoop(&mesh(), cameraView, editMode);
    reg.commandFactories["history.saveAsScript"] = () => cast(Command)
        new HistorySaveAsScript(&mesh(), cameraView, editMode,
            () {
                string[] lines;
                // ToolLifecycle entries (tool.deactivate) are not registered as
                // command factories and cannot be replayed — exclude them so the
                // script contains only replayable lines.
                foreach (ref e; history.undoEntriesVisible()) {
                    string line = e.args.length > 0
                        ? (e.commandName ~ " " ~ e.args) : e.commandName;
                    lines ~= line;
                }
                return lines;
            });
    // Phase 7 of the history-panel design doc — macro
    // recorder commands backing the History panel's Rec/Stop/Save
    // strip. Both commands route through the existing argstring
    // dispatcher, so /api/command and the panel buttons share one
    // path.
    reg.commandFactories["macro.record"] = () => cast(Command)
        new MacroRecord(&mesh(), cameraView, editMode, macroRecorder);
    reg.commandFactories["macro.saveRecorded"] = () => cast(Command)
        new MacroSaveRecorded(&mesh(), cameraView, editMode, macroRecorder);
    }
    }
    }
}
