module editor_app;

// Task 0415 (campaign 0407 §B.V1 step 1): the "зачаток EditorApp" context bag
// threaded through registerTools/registerCommands (source/registration.d),
// which host the ~213 commandFactories + ~66 toolFactories previously
// registered inline in app.d's main(). Full design + inventory +
// verification log: doc/tasks/done/0415-registration-app-decomp.md.
//
// Import surface: harvested from app.d's own top-level import block (the
// same ~234 statements, multi-line ones captured whole) plus three imports
// that were only function-locally scoped inside main() (Document,
// CommandHistory, ViewportManager -- EditorApp is a module-scope struct, so
// these need to be top-level here), plus the version(WithAI) copilot import
// group mirrored verbatim from app.d's own gating so a modeling-noai build
// compiles out the same symbols the same way.
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

// Locally-scoped in app.d's main() (not top-level there), but EditorApp is a
// module-scope struct so these three need to be top-level here (0415).
import document       : Document;
import command_history : CommandHistory;
import viewport        : ViewportManager;

// AI Modeling Copilot (task 0402): version(WithAI)-only, mirroring app.d's
// own gating at its import block (see app.d's doc comment there) so a
// modeling-noai build compiles out the same symbols the same way.
version (WithAI) import commands.ui.copilot_panel : UiCopilotPanelCommand, g_copilotPanelShown;
version (WithAI) {
    import commands.copilot.analyze        : CopilotAnalyzeCommand;
    import commands.copilot.select_finding : CopilotSelectFindingCommand;
    import commands.copilot.cycle_finding  : CopilotCycleFindingCommand;
    import copilot_panel : CopilotPanel;
    import copilot_overlay : drawCopilotFindingOverlay;
}

// ---------------------------------------------------------------------------
// Ai3dModalState -- relocated from main()'s local `static struct
// Ai3dModalState { ... }` (was declared just above the `ai3dModal` field,
// app.d ~line 2561). A `static struct` nested in a function has NO closure
// over the enclosing scope in D (that is what `static` on a nested aggregate
// means) -- it behaves exactly like a free-standing type, just name-scoped
// to the function. Relocating its verbatim field list to module scope here
// is therefore behavior-preserving: `EditorApp.Ai3dModalRefs.ai3dModal`
// needs a type nameable from THIS module, and a function-local type can't be
// named from outside that function. See task 0415 Log for the discovery
// (the opponent's Span-B sweep didn't need to catch this -- it surfaced
// during the writer's own type-availability check while building the ctx).
// ---------------------------------------------------------------------------
struct Ai3dModalState {
    bool   healthChecked;
    bool   healthOk;
    int    healthProtocol;
    string healthBackend;
    bool   healthObjCapable;
    string healthMessage;

    string jobId;
    string state;    // ""|"submitted"|"queued"|"running"|"succeeded"|"failed"|"cancelled"
    string stage;
    double progress = 0;
    string errorCode;
    string errorMessage;
}

// ---------------------------------------------------------------------------
// Nested-accessor delegate aliases (category "б" in the task plan): lazy,
// live-binding accessors. Assigned once via `&mesh` etc in main()'s ctx
// assembly; CALLED (mesh(), &mesh()) inside factory bodies at tool/command
// construction time, not at registration time -- scratch-proven late
// binding (withctx.d).
// ---------------------------------------------------------------------------
alias MeshDg        = ref Mesh delegate();
alias ViewDg         = ref View delegate();
alias VertexCacheDg = ref VertexCache delegate();
alias FaceCacheDg   = ref FaceBoundsCache delegate();
alias EdgeCacheDg   = ref EdgeCache delegate();

// ---------------------------------------------------------------------------
// AI3D generate-modal field cluster (task 0415 Phase 2 -- symmetric pairing
// with RemeshModalRefs below; the opponent's review caught this cluster
// missing from plan v1 exactly because a flat ~43-field mesh makes a missing
// symmetric sibling easy to overlook). Every leaf is individually
// pointer-backed to its OWN separate main()-local -- these five locals are
// NOT merged into one aggregate in main() itself, since that would ripple
// edits across every OTHER app.d site outside the two registration spans
// (the ai3d health-update callback, the modal-render code, etc, all still
// reference the flat main()-locals directly).
// ---------------------------------------------------------------------------
struct Ai3dModalRefs {
    private Ai3dModalState* ai3dModalPtr;
    @property ref Ai3dModalState ai3dModal() { return *ai3dModalPtr; }
    private bool* ai3dModalOpenPtr;
    @property ref bool ai3dModalOpen() { return *ai3dModalOpenPtr; }
    private bool* ai3dModalPendingOpenPtr;
    @property ref bool ai3dModalPendingOpen() { return *ai3dModalPendingOpenPtr; }
    private string* ai3dPickedImagePathPtr;
    @property ref string ai3dPickedImagePath() { return *ai3dPickedImagePathPtr; }
    private char[256]* ai3dWorkerUrlBufPtr;
    @property ref char[256] ai3dWorkerUrlBuf() { return *ai3dWorkerUrlBufPtr; }
}

/// Quad-remesh modal field cluster -- symmetric to Ai3dModalRefs above.
struct RemeshModalRefs {
    private bool* remeshModalOpenPtr;
    @property ref bool remeshModalOpen() { return *remeshModalOpenPtr; }
    private bool* remeshModalPendingOpenPtr;
    @property ref bool remeshModalPendingOpen() { return *remeshModalPendingOpenPtr; }
    private string* remeshLastErrorPtr;
    @property ref string remeshLastError() { return *remeshLastErrorPtr; }
    private string* remeshLastSummaryPtr;
    @property ref string remeshLastSummary() { return *remeshLastSummaryPtr; }
}

// ---------------------------------------------------------------------------
// EditorApp -- the context bag threaded through registerTools/
// registerCommands (the "зачаток EditorApp" of 0407 §B.V1 step 1). Assembled
// ONCE in main() right after `Registry reg;` and passed BY VALUE into both
// register* functions (the struct-of-pointers/delegates copy is safe --
// scratch-proven in withctx.d/withctx2.d/withctx3_nested.d: the closures
// built inside registerTools/registerCommands capture the copy, but every
// field either points at or IS one of main()'s own locals, which stay alive
// for the process lifetime).
//
// ROOT RULE (see task doc): every field defaults to a pointer-backed
// `@property ref T` (category "a"). A field is by-value (category "в") ONLY
// when it is a class-ref or delegate assigned EXACTLY ONCE in main() --
// grep-verified per field, not assumed from its being a class. Getting this
// wrong is SILENT: a by-value copy of a mutated value-type or a reassigned
// reference compiles cleanly and just stops seeing later writes.
// ---------------------------------------------------------------------------
struct EditorApp {
    // ---- (б) nested-accessor delegates: lazy, live-binding ----
    MeshDg        mesh;
    ViewDg        cameraView;
    VertexCacheDg vertexCache;
    FaceCacheDg   faceCache;
    EdgeCacheDg   edgeCache;

    // ---- (а) pointer-backed core locals: address-taken in the spans
    //      (Edit-class 1: &x -> &x() at the call site) ----
    private GpuMesh* gpuPtr;
    @property ref GpuMesh gpu() { return *gpuPtr; }
    private EditMode* editModePtr;
    @property ref EditMode editMode() { return *editModePtr; }
    private Document* documentPtr;
    @property ref Document document() { return *documentPtr; }
    private Registry* regPtr;
    @property ref Registry reg() { return *regPtr; }

    // ---- (а) pointer-backed critical locals: value-type mutated OR
    //      reassigned-reference read by Span B closures (silent-bug class
    //      #1/#2/#3/#4 the opponent caught -- see task doc) ----
    private SubpatchPreview* subpatchPreviewPtr;
    @property ref SubpatchPreview subpatchPreview() { return *subpatchPreviewPtr; }
    private Tool* activeToolPtr;
    @property ref Tool activeTool() { return *activeToolPtr; }
    private bool* runningPtr;
    @property ref bool running() { return *runningPtr; }
    private bool* showHistoryPanelPtr;
    @property ref bool showHistoryPanel() { return *showHistoryPanelPtr; }

    // ---- (а) pointer-backed, wired AFTER the ToolHost block in main()
    //      (Span A precedes ToolHost's declaration and never touches it) ----
    private ToolHost* toolHostPtr;
    @property ref ToolHost toolHost() { return *toolHostPtr; }

    // ---- modal clusters (grouped sub-structs, see above) ----
    Ai3dModalRefs   ai3dRefs;
    RemeshModalRefs remeshRefs;

    // ---- (в) by-value: class-ref/delegate locals assigned EXACTLY ONCE
    //      in main() (grep-verified `\bX\s*=[^=]` == 1 for every name below;
    //      a mutating method call on these, e.g. vpm.resetToDefault() or
    //      history.clear(), is safe by-value since the copy aliases the
    //      SAME heap object) ----
    CommandHistory     history;
    ViewportManager    vpm;
    LitShader          litShader;
    PipeGizmoHost      pipeGizmoHost;
    MacroRecorder      macroRecorder;
    Ai3dJobController  ai3dController;
    RemeshJob          remeshJob;
    EditorAiState      aiState;
    version (WithAI) CopilotPanel copilotPanel;
    AiExplorationController aiExplore;
    AiInteractionLogWriter  aiLogWriter;

    // ---- (в) by-value: the 12 typed MeshSessionEdit/MeshVertexEdit
    //      factories (app.d ~2785-2832), each assigned exactly once ----
    MeshVertexEdit  delegate() vxEditFactory;
    MeshSessionEdit delegate() bevelEditFactory;
    MeshSessionEdit delegate() loopSliceEditFactory;
    MeshSessionEdit delegate() reduceEditFactory;
    MeshSessionEdit delegate() cloneEditFactory;
    MeshSessionEdit delegate() arrayEditFactory;
    MeshSessionEdit delegate() edgeExtrudeEditFactory;
    MeshSessionEdit delegate() edgeExtendEditFactory;
    MeshSessionEdit delegate() polyExtrudeEditFactory;
    MeshSessionEdit delegate() radialArrayEditFactory;
    MeshSessionEdit delegate() smoothShiftEditFactory;
    MeshSessionEdit delegate() strokeExtrudeEditFactory;

    // ---- (г) hook delegates: nested functions in main(), captured via
    //      `&funcName`; called bare (verbatim) inside the spans except
    //      switchToItemType, which is address-taken once (Edit-class 2:
    //      &switchToItemType -> switchToItemType at the one call site) ----
    void delegate(Tool)         setActiveTool;
    void delegate()             switchToItemType;
    void delegate(EditMode)     promoteGeometryType;
    void delegate(EditMode)     switchGeometryType;
    void delegate(size_t, size_t) onActiveLayerChanged;
    void delegate()             resetAllPipeStages;
}
