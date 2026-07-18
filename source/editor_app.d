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
import tools.edit.bridge_tool : BridgeTool, BridgeEditFactory;
import tools.edit.vert_merge_tool : VertexMergeTool;
import tools.edit.vertex_bevel_tool : VertexBevelTool;
import tools.edit.vertex_extrude_tool : VertexExtrudeTool;
import tools.deform.stroke_extrude_tool : StrokeExtrudeTool;
import tools.common.command_wrapper : XfrmSmoothTool, XfrmJitterTool, XfrmQuantizeTool;
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
// Task 0419 (campaign 0407 §V1.2, UI-panel decomposition) relocations --
// these five items were module-scope (or main()-local) in app.d and are
// moved here VERBATIM for the same reason Ai3dModalState was in 0415: the
// UI-panel block moving to source/ui/panels.d references them, and a
// `private` module-scoped symbol or a main()-local type isn't nameable from
// another module. app.d imports all of them back (`import editor_app : ...`)
// since several also have call sites OUTSIDE the panel block. Full
// inventory/rationale: doc/tasks/work/0419-app-decomp-panels.md ("Б1"/"Б2"/
// cyclic-import").
// ---------------------------------------------------------------------------

/// Per-cell overlay-draw mode for the N-cell viewport loop (task 0206 quad/
/// split overlays). Was a plain top-level `enum` in app.d (cyclic-import:
/// renderViewportSceneToFbo's own parameter type + its main-body call site
/// both need this nameable without importing app.d back into editor_app.d).
enum OverlayMode { None, Visual, Interactive }

/// Panel layout geometry (side/tab/status window rects, viewport rect).
/// Was a plain top-level `struct` in app.d -- relocated verbatim (leaf
/// int/ImVec2 fields, no app.d dependencies) so it can back a ctx field's
/// type (`layout`) without a back-edge to app.
struct Layout {
    int sideW   = 150;
    int statusH = 28;

    ImVec2 sidePos;
    ImVec2 sideSize;
    ImVec2 tabPos;
    ImVec2 tabSize;
    ImVec2 statusPos;
    ImVec2 statusSize;

    int vpX, vpY, vpGlY, vpW, vpH;

    void resize(int winW, int winH) {
        sidePos    = ImVec2(0, 0);
        sideSize   = ImVec2(sideW, winH);
        tabPos     = ImVec2(sideW, 0);
        tabSize    = ImVec2(winW - sideW, statusH);
        statusPos  = ImVec2(sideW, winH - statusH);
        statusSize = ImVec2(winW - sideW, statusH);

        vpX   = sideW;
        vpY   = statusH;  // screen-space top edge (Y down), below tab bar
        vpGlY = statusH;  // OpenGL bottom edge (Y up), above status bar
        vpW   = winW - sideW;
        vpH   = winH - 2 * statusH;
    }
}

// AI entry-point availability (compile-time gates for two UI affordances) --
// see app.d's original doc comment (preserved in the task doc's Log) for the
// full rationale; verbatim version-gating, only the enclosing module moved.
version (OSX) {
    enum bool kGenerateAiAvailable = false;
} else version (WithAI) {
    enum bool kGenerateAiAvailable = true;
} else {
    enum bool kGenerateAiAvailable = false;
}
version (WithAI) enum bool kAiToggleAvailable = true;
else              enum bool kAiToggleAvailable = false;

/// Per-background-layer GPU mesh cache (layers Stage 5 -- background faces/
/// edges draw). Was a struct declared LOCALLY inside main() (`struct BgGpu
/// { ... }` right above the `bgGpuByLayer` local) -- exact analog of
/// Ai3dModalState: relocated verbatim so `BgGpu*[Layer]` is nameable as a
/// ctx field's type from ui.panels.
struct BgGpu { GpuMesh gpu; ulong uploadedVersion = ulong.max; }

ulong edgeKey(uint a, uint b) {
    uint lo = a < b ? a : b, hi = a < b ? b : a;
    return (cast(ulong)lo << 32) | hi;
}

int countSelected(bool[] sel) {
    int n = 0;
    foreach (s; sel) if (s) n++;
    return n;
}

/// Build the item-snap frame for one visible layer: world-space pivot +
/// world-space AABB derived from ALL mesh vertices (whole-item bounds,
/// independent of any active vertex sub-selection). Called from both the
/// render-thread per-frame install and the HTTP-thread JIT install.
ItemSnapFrame buildItemFrame(Layer lyr)
{
    ItemSnapFrame fr;
    fr.pivot = lyr.xform.pos + lyr.xform.pivot;
    Vec3 mn = Vec3( float.infinity,  float.infinity,  float.infinity);
    Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
    bool seen = false;
    foreach (v; lyr.mesh.vertices) {
        if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
        if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
        if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
        seen = true;
    }
    if (seen) {
        float[16] M = lyr.xform.composedMatrix();
        Vec3[8] corners = [
            Vec3(mn.x,mn.y,mn.z), Vec3(mx.x,mn.y,mn.z),
            Vec3(mn.x,mx.y,mn.z), Vec3(mx.x,mx.y,mn.z),
            Vec3(mn.x,mn.y,mx.z), Vec3(mx.x,mn.y,mx.z),
            Vec3(mn.x,mx.y,mx.z), Vec3(mx.x,mx.y,mx.z),
        ];
        Vec3 wmn = transformPoint(M, corners[0]);
        Vec3 wmx = wmn;
        foreach (c; corners[1..$]) {
            Vec3 w = transformPoint(M, c);
            if (w.x < wmn.x) wmn.x = w.x; if (w.x > wmx.x) wmx.x = w.x;
            if (w.y < wmn.y) wmn.y = w.y; if (w.y > wmx.y) wmx.y = w.y;
            if (w.z < wmn.z) wmn.z = w.z; if (w.z > wmx.z) wmx.z = w.z;
        }
        fr.bboxMin = wmn;
        fr.bboxMax = wmx;
        fr.hasBBox = true;
    }
    return fr;
}

/// Backing storage for the versioned imgui.ini path. ImGui stores the raw
/// char* without copying, so the string must outlive the context. Set once
/// before the first NewFrame; null in --test (byte-identity contract).
public __gshared const(char)* g_layoutIniPathZ = null;

/// Set true by the Reset Layout button to force a full dock-tree reseed on
/// the next frame, independently of the process-lifetime dockLayoutDone flag.
/// Fallback-only: the button sets this iff the shipped default could NOT be
/// re-copied (see seedDefaultLayoutIfMissing), so the programmatic
/// DockBuilder rebuild is the last resort rather than the default reset path.
public __gshared bool g_forceLayoutReseed = false;

/// Set by the Reset Layout button after a successful re-copy of the shipped
/// default ini. Consumed once, right before the next `ImGui.NewFrame()`, via
/// `ImGui.LoadIniSettingsFromDisk` -- NOT called inline from the button
/// handler because that runs mid-frame (between NewFrame/EndFrame), which the
/// ini loader documents as unsafe.
public __gshared const(char)* g_pendingLayoutReloadPathZ = null;

/// Thin app-layer wrapper over `prefs.seedLayoutIniIfMissing` (the tested
/// unit -- see its unittests in prefs.d) that fixes the source path to the
/// shipped default panel layout, `config/default_layout.ini` (the user's
/// confirmed arrangement). NEVER overwrites an existing user ini. Returns
/// true iff a copy actually happened (i.e. the shipped default is now the
/// content at `userIniPath`).
/// Interactive-session only -- callers gate on !testMode.
bool seedDefaultLayoutIfMissing(string userIniPath) {
    import std.file : exists;
    string defaultPath = "config/default_layout.ini";
    if (!exists(defaultPath)) {
        // cwd-relative shipped default not found -- e.g. a system install
        // (/usr/bin/vibe3d) launched from an arbitrary cwd. Fall back to
        // resolving alongside the executable itself. (The macOS .app bundle
        // case is unaffected: useAppBundleResourceCwd() already chdirs into
        // Resources/ at startup, so the cwd-relative path above resolves
        // there directly and this fallback never triggers.)
        try {
            import std.file : thisExePath;
            import std.path : buildPath, dirName;
            string exeRelative = buildPath(thisExePath().dirName, "config", "default_layout.ini");
            if (exists(exeRelative)) defaultPath = exeRelative;
        } catch (Exception) {}
    }
    return prefs.seedLayoutIniIfMissing(defaultPath, userIniPath);
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
    Ai3dModalState* ai3dModalPtr;
    @property ref Ai3dModalState ai3dModal() { return *ai3dModalPtr; }
    bool* ai3dModalOpenPtr;
    @property ref bool ai3dModalOpen() { return *ai3dModalOpenPtr; }
    bool* ai3dModalPendingOpenPtr;
    @property ref bool ai3dModalPendingOpen() { return *ai3dModalPendingOpenPtr; }
    string* ai3dPickedImagePathPtr;
    @property ref string ai3dPickedImagePath() { return *ai3dPickedImagePathPtr; }
    char[256]* ai3dWorkerUrlBufPtr;
    @property ref char[256] ai3dWorkerUrlBuf() { return *ai3dWorkerUrlBufPtr; }
}

/// Quad-remesh modal field cluster -- symmetric to Ai3dModalRefs above.
struct RemeshModalRefs {
    bool* remeshModalOpenPtr;
    @property ref bool remeshModalOpen() { return *remeshModalOpenPtr; }
    bool* remeshModalPendingOpenPtr;
    @property ref bool remeshModalPendingOpen() { return *remeshModalPendingOpenPtr; }
    string* remeshLastErrorPtr;
    @property ref string remeshLastError() { return *remeshLastErrorPtr; }
    string* remeshLastSummaryPtr;
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
    // `vertexCache`/`faceCache`/`edgeCache` are ALWAYS called with an
    // explicit `()` at their app.d call sites (&vertexCache(), ...) so a
    // plain delegate-typed field is verbatim: bare `vertexCache` never
    // appears as a value-expression in Span A/B or the task-0419 panel
    // block (grep-verified).
    VertexCacheDg vertexCache;
    FaceCacheDg   faceCache;
    EdgeCacheDg   edgeCache;

    // `mesh` is DIFFERENT (task 0419 finding -- same class of gotcha 0415
    // found for `cameraView`, not caught by 0415 itself because Span A/B
    // never used the bare-dot form): in app.d it is a nested FUNCTION, and
    // the task-0419 UI-panel block reads it as `mesh.countSelectedVertices()`
    // / `mesh.selectedFaces` / ... 28 TIMES with no explicit call parens
    // (vs. exactly ONE explicit `mesh()` call, in the AI-copilot overlay
    // draw). A plain delegate FIELD does not get D's auto-invoke treatment
    // on a bare reference the way a nested FUNCTION does -- `field.foo()`
    // would try to resolve `.foo` on the delegate type itself and fail to
    // compile. Backing it with a `@property ref Mesh mesh()` method (exactly
    // the cameraView pattern) restores auto-invoke for the panel block's
    // bare-dot reads with zero span-text edits, while every EXISTING
    // explicit `mesh()` / `&mesh()` call site in registration.d keeps
    // working unchanged (a property method supports explicit-call syntax
    // too).
    MeshDg meshDg;
    @property ref Mesh mesh() { return meshDg(); }

    // `cameraView` is the SAME class of gotcha as `mesh` above (task 0419
    // later found `mesh` needed the identical treatment -- see its comment):
    // in app.d it was a nested FUNCTION (`ref View cameraView() { ... }`),
    // and D auto-invokes a bare (parenthesis-less) reference to a no-arg
    // function in a value context -- so app.d's original code passes it bare
    // hundreds of times (`new Xxx(&mesh(), cameraView, editMode, ...)`). A
    // plain delegate FIELD does NOT get that auto-invoke treatment (a bare
    // field reference yields the delegate value itself, not its result).
    // Backing it with a `@property ref View cameraView()` method instead
    // (same pattern as gpu/editMode/document/reg below) restores the
    // original auto-invoke semantics for every existing bare usage with
    // ZERO span-text edits (caught by `dub build`, not by the plan's own
    // scratch probes -- see task doc Log).
    ViewDg cameraViewDg;
    @property ref View cameraView() { return cameraViewDg(); }

    // ---- (а) pointer-backed core locals: address-taken in the spans
    //      (Edit-class 1: &x -> &x() at the call site) ----
    GpuMesh* gpuPtr;
    @property ref GpuMesh gpu() { return *gpuPtr; }
    EditMode* editModePtr;
    @property ref EditMode editMode() { return *editModePtr; }
    Document* documentPtr;
    @property ref Document document() { return *documentPtr; }
    Registry* regPtr;
    @property ref Registry reg() { return *regPtr; }

    // ---- (а) pointer-backed critical locals: value-type mutated OR
    //      reassigned-reference read by Span B closures (silent-bug class
    //      #1/#2/#3/#4 the opponent caught -- see task doc) ----
    SubpatchPreview* subpatchPreviewPtr;
    @property ref SubpatchPreview subpatchPreview() { return *subpatchPreviewPtr; }
    Tool* activeToolPtr;
    @property ref Tool activeTool() { return *activeToolPtr; }
    bool* runningPtr;
    @property ref bool running() { return *runningPtr; }
    // Close-requested flag (task 0434): the file.quit factory sets this instead
    // of clearing `running` directly, so the main loop can route the close
    // through the unsaved-changes guard (window title / quit-confirm modal).
    bool* quitRequestedPtr;
    @property ref bool quitRequested() { return *quitRequestedPtr; }
    bool* showHistoryPanelPtr;
    @property ref bool showHistoryPanel() { return *showHistoryPanelPtr; }

    // ---- (а) pointer-backed, wired AFTER the ToolHost block in main()
    //      (Span A precedes ToolHost's declaration and never touches it) ----
    ToolHost* toolHostPtr;
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

    // =========================================================================
    // Task 0419 (campaign 0407 §V1.2): 30 new members backing the UI-panel
    // block (source/ui/panels.d) -- drawSidePanel/drawStatusBar/drawTabPanel/
    // drawLayerListPanel/drawViewportPropsPanel/renderViewportSceneToFbo and
    // their nested draw-helpers. Same ROOT RULE as above: default
    // pointer-backed `@property ref T`; by-value only for a class-ref/
    // delegate assigned exactly once before the LATE-wiring point (app.d,
    // right after `buildToolVts`'s closing brace, ~line 5405). Wired in that
    // LATE block, not the 2873 ctx-assembly block -- several of these
    // (hook delegates) are nested functions not declared until AFTER 2873.
    // Full inventory + per-field proof: doc/tasks/work/0419-app-decomp-panels.md.
    // =========================================================================

    // ---- (a) pointer-backed: value-types mutated/reassigned by the panel
    //      block, or address-taken (activePanelIdx via &panels[activePanelIdx]) ----
    int* hoveredVertexPtr;
    @property ref int hoveredVertex() { return *hoveredVertexPtr; }
    int* hoveredEdgePtr;
    @property ref int hoveredEdge() { return *hoveredEdgePtr; }
    int* hoveredFacePtr;
    @property ref int hoveredFace() { return *hoveredFacePtr; }
    int* activePanelIdxPtr;
    @property ref int activePanelIdx() { return *activePanelIdxPtr; }
    string* activeToolIdPtr;
    @property ref string activeToolId() { return *activeToolIdPtr; }
    int* layerRenameIndexPtr;
    @property ref int layerRenameIndex() { return *layerRenameIndexPtr; }
    char[256]* layerRenameBufPtr;
    @property ref char[256] layerRenameBuf() { return *layerRenameBufPtr; }
    bool[]* faceSelEdgesCachePtr;
    @property ref bool[] faceSelEdgesCache() { return *faceSelEdgesCachePtr; }
    bool[]* faceSelEdgesPrevSelPtr;
    @property ref bool[] faceSelEdgesPrevSel() { return *faceSelEdgesPrevSelPtr; }
    Layout* layoutPtr;
    @property ref Layout layout() { return *layoutPtr; }
    // `&panels[activePanelIdx]` (address-of-ELEMENT, not address-of-field) --
    // a `@property ref Panel[] panels()` auto-invokes under `&panels[i]`
    // (scratch-verified by the plan), so the call site needs zero edits.
    Panel[]* panelsPtr;
    @property ref Panel[] panels() { return *panelsPtr; }
    Group[]* statusLineGroupsPtr;
    @property ref Group[] statusLineGroups() { return *statusLineGroupsPtr; }
    ShortcutTable* shortcutsPtr;
    @property ref ShortcutTable shortcuts() { return *shortcutsPtr; }
    GLuint* gridVaoPtr;
    @property ref GLuint gridVao() { return *gridVaoPtr; }
    int* gridOnlyVertCountPtr;
    @property ref int gridOnlyVertCount() { return *gridOnlyVertCountPtr; }
    // [Б2] Reassigned-ref (`bgGpuByLayer[lyr] = bg` writes into the AA) --
    // a by-value copy would leak the GL object every frame (the copy sees
    // its own insert; main()'s real AA never gets it; scope(exit) in main()
    // forever cleans up an empty map). BgGpu type relocated above (Б2).
    BgGpu*[Layer]* bgGpuByLayerPtr;
    @property ref BgGpu*[Layer] bgGpuByLayer() { return *bgGpuByLayerPtr; }

    // ---- testMode: computed, NOT a pointer field or a global wrapper.
    //      main()'s local `testMode` and `command.g_testMode` are ALWAYS
    //      assigned together (app.d ~1075/1077, never diverge) -- reading
    //      through `command.g_testMode` directly removes a LATE-wiring step
    //      and matches the panel block's own qualified read at
    //      `!command.g_testMode` (drawViewportPropsPanel's Reset Layout). ----
    @property ref bool testMode() { return command.g_testMode; }

    // ---- (в) by-value: class-ref/pointer/delegate locals assigned EXACTLY
    //      ONCE in main(), all before the LATE-wiring point (grep-verified) ----
    Shader        shader;
    CheckerShader checkerShader;
    GridShader    gridShader;
    FormsPanel    formsPanel;
    ImGuiIO*      io;
    void delegate(string, string) commandHandlerDelegate;
    void delegate(string, string) formsInteractiveDispatch;

    // ---- (г) hook delegates: nested functions in main(), captured via
    //      `&funcName`; ALWAYS called with explicit args/parens in the panel
    //      block (unlike `mesh`/`cameraView` above, none of these six are
    //      ever read bare) ----
    void delegate(Command)      runCommand;
    bool delegate(string)       tryOpenArgsDialog;
    void delegate(string)       activateToolById;
    void delegate(out SubjectPacket, ref VectorStack) buildToolVts;
    bool delegate()              anyFalloffActive;
    const(bool)[] delegate(int) rebuildLoopHoverMask;
}
