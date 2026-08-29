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
import ui.discard_guard : UiRunOutcome, GuardSettle;
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
import mesh_dirty : MeshDirtyKey;   // task 1906 stage 2a — BgGpu's upload key
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
import commands.mesh.morph;
import commands.mesh.morph_edit : MeshMorphEdit;
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
import commands.layer.xform_edit : LayerXformEdit;
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
import core.time : MonoTime;  // phase-B panel ctx fields (ai3dWorker*Deadline/Probe)
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

// app.d decomp phase B (source/http_providers.d): types of the new ctx
// fields below (see the phase-B section at the bottom of EditorApp).
import step_trace  : StepTrace;
import edit_session : EditSession;
import gpu_select   : GpuSelectBuffer;

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

/// The per-cell overlay-draw decision for the N-cell FBO loop, in ONE place
/// (task 1650). Both the render loop in app.d and `/api/viewport/display`'s
/// dump call this, so what a test asserts is what was drawn — there is no
/// second derivation that could drift.
///
/// `anyOverlay` is "there is something to draw at all"
/// (`activeTool !is null || anyFalloffActive()`), which is exactly the pair of
/// branches inside `renderViewportSceneToFbo`'s overlay block. The owner cell
/// gets `Interactive`; EVERY other live cell gets `Visual`.
///
/// **There is deliberately no tool-type term here.** Until task 1650 the
/// non-owner branch was gated on a hand-written list of concrete tool classes
/// (`XfrmTransformTool` / `CommandWrapperTool` / no-tool-falloff), so a tool
/// that COMPOSES a transform wrapper instead of inheriting one — `EdgeExtendTool`,
/// `EdgeBevelTool` — failed both casts and its cells were told to draw nothing.
/// The user-visible defect was that in a Quad layout those gizmos appeared only
/// in the cell under the cursor.
///
/// What makes dropping the list safe is NOT that every tool honours
/// `Tool.draw`'s `visualOnly` contract — measured, most do not: of the 38
/// `Tool.draw` overrides only 10 read the flag in their body, and 21 of the
/// remaining 28 write `cachedVp` and/or run a `ToolHandles` register/hit-test
/// cycle unconditionally. It is `viewport.overlayDrawOrder`, which visits every
/// non-owner cell FIRST and the owner LAST: every one of those writes is
/// overwritten by the owner's own `Interactive` draw before the frame ends, and
/// no event handling interleaves inside a draw pass. (The same audit found no
/// `draw` body that mutates the mesh or fires a command, so nothing ACCUMULATES
/// across the extra per-cell calls either — that, not the flag, is the property
/// the ordering cannot rescue.) `visualOnly` remains the right contract and the
/// cheaper path; it is simply not what this gate rests on.
OverlayMode resolveOverlayMode(int cellId, int ownerId, bool anyOverlay) {
    if (!anyOverlay) return OverlayMode.None;
    return (cellId == ownerId) ? OverlayMode.Interactive : OverlayMode.Visual;
}

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
/// TASK 1906 STAGE 2a (row 17) — `ulong uploadedVersion` compared against
/// `mesh.mutationVersion` became a `MeshDirtyKey`: the mesh ADDRESS plus the
/// display-class bus epoch. The address term is not redundant with the AA's
/// `Layer` key — a layer whose mesh is replaced wholesale (`*mesh = ...`,
/// ~15 sites) keeps its `Layer` identity while its `Mesh` moves, and it is the
/// address that says so.
struct BgGpu { GpuMesh gpu; MeshDirtyKey uploaded; }

ulong edgeKey(uint a, uint b) {
    uint lo = a < b ? a : b, hi = a < b ? b : a;
    return (cast(ulong)lo << 32) | hi;
}

/// Relocated verbatim from app.d's main() (app.d decomp phase B): was a
/// main()-local enum (declared right above applyOrRefire), moved to module
/// scope so EditorApp's applyOrRefire hook-delegate field can name the type
/// -- exact analog of the BgGpu relocation above.
enum RecordMode { Record, Coalescing }

/// Build the item-snap frame for one visible layer: world-space pivot, plus —
/// only when `wantBBox` — the world-space AABB derived from ALL mesh vertices
/// (whole-item bounds, independent of any active vertex sub-selection).
///
/// `wantBBox` IS THE COST OF THIS FUNCTION. The pivot half is two vector adds.
/// The box half walks every vertex of the layer and then transforms eight
/// corners: 7.9% of a falloff-drag frame, measured on a 316x316 grid (100 489
/// vertices), and it was being paid on every frame of every drag. Exactly one
/// reader consumes the box — `snapCursor`'s `SnapType.Box` branch in snap.d,
/// which is the only code anywhere that reads `hasBBox`/`bboxMin`/`bboxMax` —
/// so the caller hands in that bit and the walk does not happen while box
/// snapping is off. Off is the default: `SnapPacket.enabledTypes` starts at
/// `SnapType.Vertex` alone.
///
/// WHAT BREAKS IT. Frames are installed by the DRAW and read by a snap query
/// in a LATER frame, so passing `false` on a frame whose query then wants a box
/// costs that query its Box targets SILENTLY — `hasBBox == false` is
/// indistinguishable at the reader from "this item has no geometry". The bit
/// must therefore be re-asked on a frame boundary a box-enable cannot slip
/// through, which is why the only caller is `installSnapState` and why that
/// runs once per frame from the frame loop rather than from the per-cell scene
/// pass; see its own comment for what the per-cell site could not guarantee.
ItemSnapFrame buildItemFrame(Layer lyr, bool wantBBox)
{
    ItemSnapFrame fr;
    fr.pivot = lyr.xform.pos + lyr.xform.pivot;
    Vec3 mn = Vec3( float.infinity,  float.infinity,  float.infinity);
    Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
    bool seen = false;
    // Task 0615 Stage 4: a non-mesh item has no vertices to bound — `meshOrNull`
    // is null and the loop below simply never runs, so `seen` stays false and
    // `hasBBox` comes out false while `pivot` (set above) is still meaningful.
    // Task 1780 gives `!wantBBox` that same exit deliberately: a suppressed box
    // and an absent one are the same frame, because the reader has no third
    // state to tell them apart with.
    if (wantBBox) if (auto mp = lyr.meshOrNull) foreach (v; mp.vertices) {
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

/// Install the snap service's per-frame view of the document: the background
/// snap SOURCES and the item snap FRAMES. Both blocks are verbatim from
/// `ui/viewport_render.d`'s `renderViewportSceneToFbo`, where they stood until
/// task 1780 hoisted them out of it.
///
/// WHY THEY DO NOT BELONG IN A SCENE PASS. Neither block reads a camera, a
/// viewport or a GL object — only `document`. Sitting inside the per-cell pass
/// they therefore ran once per LIVE CELL, four times a frame under a Quad
/// layout, each time installing byte-identical arrays over the previous one,
/// and each time re-walking every vertex of every visible layer.
///
/// AND WHY THE MOVE IS A CORRECTNESS FIX, NOT ONLY A COST ONE. The per-cell
/// pass is gated on that cell's DIRTY KEY (`app.d`, Phase 4). The key carries
/// view/proj, mesh mutation version, selection epoch, edit mode, hover, the
/// resolved draw plan, image planes and the weight map — it does not carry
/// snap configuration, and it should not: snap config does not change what a
/// cell draws. So interactively, a frame in which nothing visible changed
/// installed NOTHING, and any decision taken here from snap state — which is
/// exactly what `buildItemFrame`'s `wantBBox` now is — would have stayed
/// frozen at whatever the last redraw happened to decide, for as long as the
/// scene sat still. Ticking box snapping on and getting no box targets until
/// something else moved the camera is the shape that would have taken.
///
/// THE `--test` BUILD CANNOT EXHIBIT ANY OF THAT, so do not read a green suite
/// as evidence about it: under `--test`, `needRender` is `testRendersCell(...)`
/// — unconditional for the active cell — so the install ran every frame
/// whatever the dirty key said. The hazard is interactive-only.
///
/// Called once per frame from the frame loop, immediately before the cell
/// loop. That is a superset of the old schedule (0..N calls per frame becomes
/// exactly 1) and keeps the same position in the frame: after all event and
/// command processing, before anything draws.
void installSnapState(EditorApp app)
{
    with (app) {
    // Install background snap sources (layers Stage 5). The parallel
    // `snapSrcLayerIdx` (topology-pen P0 NIT-3) records each source's
    // Document-layer index (this loop's `i`) so the CONS stage's
    // background-surface raycast can publish a real Document-layer index
    // in `ConstrainHitPacket.layer` instead of the bgSrc-order slot.
    {
        import snap : setBackgroundSnapSources;
        const(Mesh)*[] snapSrc;
        ModelSpace[]   snapSrcSpaces;
        int[] snapSrcLayerIdx;
        if (document.layers.length > 1) {
            foreach (i, lyr; document.layers) {
                // Task 0615 Stage 4 (§Tier-2 :2162): a non-mesh layer is not a
                // snap source.
                if (document.background(lyr) && lyr.hasMesh) {
                    snapSrc ~= cast(const(Mesh)*)&lyr.meshRef();
                    // Task 0617 Stage 4: same source as `bgModel` in the draw
                    // loop (`lyr.xform.composedMatrix()`) — a background layer
                    // now snaps where it is DRAWN, not at its identity pose.
                    //
                    // The three arrays are appended together under ONE guard so
                    // they stay index-aligned: a layer that is not a snap source
                    // contributes to none of them. Splitting the guard is how
                    // they would silently drift apart.
                    snapSrcSpaces ~= lyr.xform.modelSpace();
                    snapSrcLayerIdx ~= cast(int)i;
                }
            }
        }
        setBackgroundSnapSources(snapSrc, snapSrcSpaces, snapSrcLayerIdx);
    }
    // Install item snap frames (Stage 3).
    {
        import snap             : setItemSnapFrames;
        import toolpipe.packets : SnapType;
        import toolpipe.stage   : TaskCode;
        import toolpipe.stages.snap : SnapStage;
        import document         : kindInfo;

        // Does anything downstream read the BOX half of these frames this
        // frame? Only `snapCursor`'s `SnapType.Box` branch does, so the bit is
        // asked of the SNAP stage's own `enabledTypes` — the single authority,
        // not a mirror of one: the packet that branch reads is `pkt.config =
        // config`, a verbatim copy of the field read here.
        //
        // Asked WITHOUT the `typeEligible(Box, snapScope)` half of the reader's
        // condition, on purpose. A superset is the safe direction (it can only
        // build a box nobody reads, never withhold one somebody does), and the
        // scope law has one home in `snap.typeEligible`; restating it here
        // would give it two that must be kept in step by hand.
        //
        // No pipeline, or no SNAP stage in it, means the bit cannot be READ —
        // so pay the walk rather than assume it is clear. That is the headless
        // and unittest shape, where the meshes are small and the walk is free.
        bool wantBBox = true;
        if (g_pipeCtx !is null)
            if (auto ss = cast(SnapStage) g_pipeCtx.pipeline.findByTask(TaskCode.Snap))
                wantBBox = (ss.enabledTypes & SnapType.Box) != 0;

        // Reused across frames rather than freshly appended each one:
        // `setItemSnapFrames` COPIES element-by-element into its own buffer
        // under the grid mutex, so nothing here outlives the call and no reader
        // can hold a slice of this block. Bytes are not the point — one small
        // array per frame is — the per-frame GC MARK SET is.
        g_itemFrameScratch.length = 0;
        g_itemFrameScratch.assumeSafeAppend();
        foreach (lyr; document.layers) {
            if (!lyr.visible) continue;
            // Task 0616 Stage 2 (Bend #1): a kind with no transform
            // capability (e.g. an image — a document RESOURCE, not a thing
            // positioned in space) has no pivot to snap to. Without this
            // gate `buildItemFrame` would read `Layer.xform`'s inert default
            // identity and offer (0,0,0) as a snap target for every such
            // item — meaningless, since nothing ever authors that field for
            // a kind `layer_params.d` does not expose it on.
            if (!kindInfo(lyr.kind).hasXform) continue;
            g_itemFrameScratch ~= buildItemFrame(lyr, wantBBox);
        }
        setItemSnapFrames(g_itemFrameScratch);
    }
    }
}

/// Scratch for `installSnapState`'s item-frame loop. Main-thread only (the
/// frame loop is its sole caller) and never escapes: see the note at its use.
private ItemSnapFrame[] g_itemFrameScratch;

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
    // (Task 1930 removed `vertexCache`/`faceCache`/`edgeCache` from here
    // along with `viewcache.d`; they were write-only fields feeding a
    // payload nothing read.)

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
    // Task 1500 — what the GPU buffers currently hold (cage vs preview).
    // Pointer-backed for the same reason as the rest of this block: it is a
    // main() local that a moved span has to READ, and `/api/pick` is the
    // second of M-INV's two consumers.
    bool* gpuUploadedPreviewPtr;
    @property ref bool gpuUploadedPreview() { return *gpuUploadedPreviewPtr; }
    Tool* activeToolPtr;
    @property ref Tool activeTool() { return *activeToolPtr; }
    bool* runningPtr;
    @property ref bool running() { return *runningPtr; }
    // Close-requested flag (task 0434): the file.quit factory sets this instead
    // of clearing `running` directly, so the main loop can route the close
    // through the unsaved-changes guard (window title / quit-confirm modal).

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

    // ---- (в) by-value: the 13 typed MeshSessionEdit/MeshVertexEdit
    //      factories (app.d ~2785-2832), each assigned exactly once ----
    MeshVertexEdit  delegate() vxEditFactory;
    // Task 1069 — routed-gesture undo factory, injected into every
    // XfrmTransformTool via setUndoBindings' third argument.
    MeshMorphEdit   delegate() morphEditFactory;
    // Task 0614 Phase 4 — item-transform gizmo-drag undo factory, the
    // LayerXformEdit analogue of vxEditFactory. Injected into every
    // XfrmTransformTool instance (registration.d) via setItemUndoFactory().
    LayerXformEdit  delegate() layerXformEditFactory;
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
    // Task 0477 (topology-pen P3): the drag-build gesture's own generic
    // session-edit factory, wireName "mesh.topoPen_build" — kept distinct
    // from `bevelEditFactory` (unlike most interactive tools above, which
    // reuse it under its "mesh.bevel_edit" wire name) so undo history /
    // event-log replay dispatch on a name that actually describes this op.
    MeshSessionEdit delegate() topoPenBuildEditFactory;
    // Task 0477 (topology-pen P4, OBJ-3 FOLDED): the Move gesture's own
    // generic session-edit factory, wireName "mesh.topoPen_move" — kept
    // distinct from `topoPenBuildEditFactory` since a re-snap move never
    // adds/removes geometry (Position-only editScope, not Geometry|Marks).
    MeshSessionEdit delegate() topoPenMoveEditFactory;
    // Task 0477 (topology-pen P5, doc/topopen_p5_remove_plan.md, opponent
    // KILLER-1): the Remove gesture's own generic session-edit factory,
    // wireName "mesh.topoPen_remove" — kept distinct from BOTH
    // `topoPenBuildEditFactory` and `topoPenMoveEditFactory` (a single-face
    // delete IS a topology change, Geometry editScope, not Position-only).
    MeshSessionEdit delegate() topoPenRemoveEditFactory;
    // Task 0477 (topology-pen P6, doc/topopen_p6_addloop_plan.md, REV1
    // factory precedent): the Add Loop gesture's own generic session-edit
    // factory, wireName "mesh.topoPen_addloop" — kept distinct from EVERY
    // sibling factory above (a loop cut is its own topology op, not a
    // build/move/remove).
    MeshSessionEdit delegate() topoPenAddLoopEditFactory;
    // Task 0477 (topology-pen P7, doc/topopen_p7_slide_plan.md, REV1): the
    // Slide gesture's own generic session-edit factory, wireName
    // "mesh.topoPen_slide" — kept distinct from EVERY sibling factory above
    // (a constrained-edge slide is Position-only, like Move, but must never
    // bake Move's/any other gesture's wire name onto its own undo entries).
    MeshSessionEdit delegate() topoPenSlideEditFactory;
    // Task 0477 (topology-pen P8, doc/topopen_p8_smooth_plan.md): the
    // Smooth gesture's own generic session-edit factory, wireName
    // "mesh.topoPen_smooth" — kept distinct from EVERY sibling factory above
    // (a relax+re-snap pass is Position-only, like Move/Slide, but a
    // multi-pass smooth gesture must never bake either sibling's wire name
    // onto its own coalesced undo entry).
    MeshSessionEdit delegate() topoPenSmoothEditFactory;
    // Task 0477 (topology-pen P9, doc/topopen_p9_split_plan.md): the Split
    // gesture's own generic session-edit factory, wireName
    // "mesh.topoPen_split" — kept distinct from EVERY sibling factory above
    // (a vertex-to-vertex polygon split is its own topology op — Geometry
    // editScope, like Remove — never Move's/Slide's/Smooth's Position-only
    // scope or Remove's/Add Loop's own wire name).
    MeshSessionEdit delegate() topoPenSplitEditFactory;
    // Task 0477 (topology-pen P10, doc/topopen_p10_moveloop_plan.md): the
    // Move Loop gesture's own generic session-edit factory, wireName
    // "mesh.topoPen_moveloop" — kept distinct from EVERY sibling factory
    // above (a per-vertex loop re-snap is Position-only, like Move/Slide/
    // Smooth, but must never bake any of their wire names onto its own
    // atomic undo entry).
    MeshSessionEdit delegate() topoPenMoveLoopEditFactory;
    // Task 0477 (topology-pen P11, doc/topopen_p11_duploop_plan.md): the
    // Dup Loop gesture's own generic session-edit factory, wireName
    // "mesh.topoPen_duploop" — kept distinct from EVERY sibling factory
    // above (duplicating an edge loop into a new bridge ring IS a topology
    // change, Geometry|Marks editScope like Add Loop, but must never bake
    // any sibling's wire name onto its own atomic undo entry).
    MeshSessionEdit delegate() topoPenDupLoopEditFactory;
    // Task 0477 (topology-pen P12, doc/topopen_p12_smoothloop_plan.md): the
    // Smooth+Loop gesture's own generic session-edit factory, wireName
    // "mesh.topoPen_smoothloop" — kept distinct from EVERY sibling factory
    // above (a 1-D loop-restricted relax+re-snap is Position-only, like
    // Move/Slide/Smooth/Move Loop, but must never bake any of their wire
    // names onto its own coalesced undo entry).
    MeshSessionEdit delegate() topoPenSmoothLoopEditFactory;
    // Task 0477 continuation (Fill mode V1, doc/topopen_fill_plan.md): the
    // Fill gesture's own generic session-edit factory, wireName
    // "mesh.topoPen_fill" — kept distinct from EVERY sibling factory above
    // (capping a gap cell with one quad IS a topology change, Geometry
    // editScope like Split/Remove, but must never bake any sibling's wire
    // name onto its own atomic undo entry).
    MeshSessionEdit delegate() topoPenFillEditFactory;
    // Task 0494 (Remove's OTHER two primitives): Remove is one gesture with
    // three mesh operations, chosen by the class of the element the press
    // latched, so it carries three factories. wireName
    // "mesh.topoPen_removeedge" / "mesh.topoPen_removevertex" — kept distinct
    // from `topoPenRemoveEditFactory` (and from every sibling above) because
    // all three are the same Geometry scope and differ ONLY by wire name, so
    // reusing one would label a dissolve as a face removal in the undo
    // history / event-log replay / any macro built on it.
    MeshSessionEdit delegate() topoPenRemoveEdgeEditFactory;
    MeshSessionEdit delegate() topoPenRemoveVertexEditFactory;

    // ---- (г) hook delegates: nested functions in main(), captured via
    //      `&funcName`; called bare (verbatim) inside the spans except
    //      promoteItemType, which is address-taken once (Edit-class 2:
    //      &promoteItemType -> promoteItemType at the one call site) ----
    void delegate(Tool)         setActiveTool;
    void delegate()             promoteItemType;
    // Task 0642 — the deliberate item-mode door (`select.typeFrom item`, the
    // Items status-line button, the Items key). Distinct from promoteItemType
    // above: this one drops the active tool on a front-flip.
    void delegate()             switchItemType;
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
    // Marks-shaped (task 0585) — see the declarations in app.d.
    uint[]* faceSelEdgesCachePtr;
    @property ref uint[] faceSelEdgesCache() { return *faceSelEdgesCachePtr; }
    uint[]* faceSelEdgesPrevSelPtr;
    @property ref uint[] faceSelEdgesPrevSel() { return *faceSelEdgesPrevSelPtr; }
    MeshStructKey* faceSelEdgesKeyPtr;
    @property ref MeshStructKey faceSelEdgesKey() { return *faceSelEdgesKeyPtr; }
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
    // Task 0722 (audit §2C A2): the ONLY main() local the Tool Properties
    // block closed over that was not already a field here. Same category as
    // `formsPanel` right above -- a class reference assigned exactly once in
    // main() (`new PropertyPanel()`), well before the LATE-wiring point, and
    // never reassigned. main() itself has no other reader: the declaration
    // and all six reads were inside the block that moved to ui/panels.d.
    PropertyPanel propertyPanel;
    ImGuiIO*      io;
    void delegate(string, string) uiCommandDelegate;
    void delegate(string, string) formsInteractiveDispatch;

    // ---- (г) hook delegates: nested functions in main(), captured via
    //      `&funcName`; ALWAYS called with explicit args/parens in the panel
    //      block (unlike `mesh`/`cameraView` above, none of these six are
    //      ever read bare) ----
    void delegate(Command)      runCommand;
    /// Task 1520/1521 — the single guarded UI entry, and the notice raiser the
    /// UI dispatch adapter shares with `runCommand`.
    UiRunOutcome delegate(Command, RecordMode, string) runUiCommand;
    void delegate(Command)      raiseCommandNotice;
    void delegate(string)       raiseNotice;
    bool delegate(string)       tryOpenArgsDialog;
    void delegate(string)       activateToolById;
    void delegate(out SubjectPacket, ref VectorStack) buildToolVts;
    bool delegate()              anyFalloffActive;
    /// Task 1691 — the RESOLVED `viewportInputAllowed()`, bound to main()'s own
    /// nested forwarder so `/api/viewport/display` reports the value the mouse
    /// handlers actually branched on rather than a second copy of its formula.
    /// A re-derivation here would repeat exactly the defect task 1650 measured:
    /// a dump that recomputes a call-site decision keeps answering after the
    /// call site has stopped asking, and the test then asserts about the dump.
    bool delegate()              viewportInputAllowedDg;
    const(bool)[] delegate(int) rebuildLoopHoverMask;

    // =========================================================================
    // app.d decomp phase B (source/http_providers.d): members backing
    // wireHttpProviders's moved /api endpoint-wiring block. Same ROOT RULE
    // as above: pointer-backed for a mutated value-type; by-value only for
    // class refs assigned exactly once before the call site (app.d, right
    // before `wireHttpProviders(httpServer, app);`); hook delegates for
    // main()'s nested functions; a computed @property for the nested-func
    // `gpuSelect()` shape (the moved block reads it bare, `gpuSelect.pick`,
    // so a property preserves every call site verbatim).
    // =========================================================================

    // ---- (a) pointer-backed: struct mutated via .touch()/.order writes in
    //      both main() and the moved block. formsInteractiveLatch: bool
    //      latch assigned by the moved block's formsInteractiveDispatch and
    //      read by its command handler -- closure-frame shared state, so it
    //      must alias main()'s local, not copy it. ----
    SelTypeOrder* selTypeOrderPtr;
    @property ref SelTypeOrder selTypeOrder() { return *selTypeOrderPtr; }
    bool* formsInteractiveLatchPtr;
    @property ref bool formsInteractiveLatch() { return *formsInteractiveLatchPtr; }

    // ---- (б) by-value class refs, each assigned exactly once in main()
    //      before the wireHttpProviders call (grep-verified: bvhPick app.d
    //      ~1618, stepTrace ~2647, session ~3350). The moved block only
    //      READS stepTrace (null-guarded) and calls methods on session.
    //      replayUndoEntry is the reverse direction: ASSIGNED by the moved
    //      block (like uiCommandDelegate/formsInteractiveDispatch
    //      above) and synced back into main()'s local after the call. ----
    BvhPick     bvhPick;
    StepTrace   stepTrace;
    EditSession session;
    void delegate(size_t) replayUndoEntry;

    // ---- computed: mirrors main()'s nested `auto gpuSelect() { return
    //      vpm.views[vpm.activeId].gpuSel; }` verbatim ----
    @property GpuSelectBuffer gpuSelect() { return vpm.views[vpm.activeId].gpuSel; }

    // ---- (г) hook delegates: nested functions in main(), captured via
    //      cast+&funcName; always called with explicit parens in the moved
    //      block. derivedEditMode is `const` in main() -- hence the cast at
    //      the wiring site (same precedent as runCommand above). ----
    void delegate()     ensureDisplayCurrent;
    EditMode delegate() derivedEditMode;
    // applyOrRefire: main()'s command-apply funnel (nested func, declared
    // right after the RecordMode enum that now lives at this module's top
    // level); called with explicit args/parens in the moved block.
    // Task 1520 (Phase 1b): the BOUND reference the moved HTTP block uses is
    // the NON-throwing shape. The throwing one is a separate field, and no
    // file under `source/ui/**` may name it — gated by
    // `tests/test_ui_no_throwing_dispatch.d`.
    //
    // The narrowing is a REAL reduction of bound references, not a compiler
    // guarantee: `applyOrRefire` is public and `RecordMode` is module-level
    // here, so a panel COULD still name `applyOrRefireThrowing`. That is why
    // the claim is "no bound reference carries the script policy" and why the
    // gate exists in addition.
    bool delegate(Command, RecordMode) applyOrRefire;
    bool delegate(Command, RecordMode, string) applyOrRefireThrowing;

    // =========================================================================
    // app.d decomp phase B (source/ui/panels.d main-loop panels): members
    // backing drawAi3dModal / drawRemeshModal / drawQuitGuardModal /
    // drawCommandHistoryPanel. Pointer-backed throughout: every value-type
    // here is either mutated or address-taken (ImGui SliderInt/SliderFloat/
    // Checkbox/InputText all take `&field` / `field[]`) by the moved blocks.
    // ai3dWorkerManager is a class ref assigned exactly once (app.d ~1179);
    // navHistory is a main() nested function captured as a hook delegate
    // (always called with explicit args/parens in the moved block).
    // =========================================================================

    // ---- forwards into ai3dRefs/remeshRefs (the 0415 clusters above): the
    //      moved main-loop panel bodies read these bare under `with (app)`,
    //      so EditorApp re-exposes the cluster leaves at its own top level.
    //      (No new storage -- these forward to the same pointers the 0415
    //      ctx block wires.) ----
    @property ref Ai3dModalState ai3dModal() { return ai3dRefs.ai3dModal; }
    @property ref bool ai3dModalOpen() { return ai3dRefs.ai3dModalOpen; }
    @property ref bool ai3dModalPendingOpen() { return ai3dRefs.ai3dModalPendingOpen; }
    @property ref string ai3dPickedImagePath() { return ai3dRefs.ai3dPickedImagePath; }
    @property ref char[256] ai3dWorkerUrlBuf() { return ai3dRefs.ai3dWorkerUrlBuf; }
    @property ref bool remeshModalOpen() { return remeshRefs.remeshModalOpen; }
    @property ref bool remeshModalPendingOpen() { return remeshRefs.remeshModalPendingOpen; }
    @property ref string remeshLastError() { return remeshRefs.remeshLastError; }
    @property ref string remeshLastSummary() { return remeshRefs.remeshLastSummary; }

    // ---- AI3D Generate modal ----
    bool* ai3dWorkerStartingPtr;
    @property ref bool ai3dWorkerStarting() { return *ai3dWorkerStartingPtr; }
    MonoTime* ai3dWorkerStartDeadlinePtr;
    @property ref MonoTime ai3dWorkerStartDeadline() { return *ai3dWorkerStartDeadlinePtr; }
    MonoTime* ai3dWorkerNextHealthProbePtr;
    @property ref MonoTime ai3dWorkerNextHealthProbe() { return *ai3dWorkerNextHealthProbePtr; }
    bool* ai3dInstallConfirmOpenPtr;
    @property ref bool ai3dInstallConfirmOpen() { return *ai3dInstallConfirmOpenPtr; }
    bool* ai3dInstallConfirmPendingOpenPtr;
    @property ref bool ai3dInstallConfirmPendingOpen() { return *ai3dInstallConfirmPendingOpenPtr; }
    int* ai3dMaxFacesPtr;
    @property ref int ai3dMaxFaces() { return *ai3dMaxFacesPtr; }
    Ai3dWorkerManager ai3dWorkerManager;

    // ---- Quad Remesh modal ----
    bool* remeshModalPendingClosePtr;
    @property ref bool remeshModalPendingClose() { return *remeshModalPendingClosePtr; }
    int* remeshTargetQuadsPtr;
    @property ref int remeshTargetQuads() { return *remeshTargetQuadsPtr; }
    float* remeshAdaptivityPtr;
    @property ref float remeshAdaptivity() { return *remeshAdaptivityPtr; }
    float* remeshSharpEdgePtr;
    @property ref float remeshSharpEdge() { return *remeshSharpEdgePtr; }

    // ---- quit guard + confirmation modal ----
    // Task 1521 — the generic unsaved-work prompt (was 0434's quit-only pair).
    bool* discardConfirmOpenPtr;
    @property ref bool discardConfirmOpen() { return *discardConfirmOpenPtr; }
    bool* discardConfirmPendingPtr;
    @property ref bool discardConfirmPending() { return *discardConfirmPendingPtr; }
    string* guardPromptTextPtr;
    @property ref string guardPromptText() { return *guardPromptTextPtr; }
    /// The three answers, each a main()-nested function: they arm the settle,
    /// they never perform the action from inside the draw.
    void delegate() guardAnswerSave;
    void delegate() guardAnswerDiscard;
    void delegate() guardAnswerCancel;
    /// Forget a held guarded action without performing it (`/api/reset`).
    void delegate() dropPendingGuard;

    // ---- command-failure notice (task 0616 review B1) ----
    // The text a declining command asked to be shown, and the same
    // pendingOpen → OpenPopup latch every other modal here uses. Empty text
    // means no notice; see `ui/command_notice.d` for why a reasonless decline
    // is deliberately silent.
    string* noticeTextPtr;
    @property ref string noticeText() { return *noticeTextPtr; }
    bool* noticeOpenPtr;
    @property ref bool noticeOpen() { return *noticeOpenPtr; }
    bool* noticePendingPtr;
    @property ref bool noticePending() { return *noticePendingPtr; }

    // ---- Command History panel ----
    char[256]* historyFilterPtr;
    @property ref char[256] historyFilter() { return *historyFilterPtr; }
    bool* historyShowArgsPtr;
    @property ref bool historyShowArgs() { return *historyShowArgsPtr; }
    bool* historyShowRowNumbersPtr;
    @property ref bool historyShowRowNumbers() { return *historyShowRowNumbersPtr; }
    bool* historyShowTimestampsPtr;
    @property ref bool historyShowTimestamps() { return *historyShowTimestampsPtr; }
    bool* historyShowCommandIdsPtr;
    @property ref bool historyShowCommandIds() { return *historyShowCommandIdsPtr; }
    bool* historyReplLastWasErrorPtr;
    @property ref bool historyReplLastWasError() { return *historyReplLastWasErrorPtr; }
    char[512]* historyReplInputPtr;
    @property ref char[512] historyReplInput() { return *historyReplInputPtr; }
    bool delegate(bool) navHistory;
}
