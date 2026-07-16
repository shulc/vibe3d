module ui.panels;

// Task 0419 (campaign 0407 §V1.2, continuation of 0415): the UI-panel block
// that used to live as 23 nested functions inside app.d's main()
// (drawSidePanel/drawStatusBar/drawTabPanel/drawLayerListPanel/
// drawViewportPropsPanel/renderViewportSceneToFbo and their draw-helpers),
// moved here VERBATIM through the same `EditorApp`/`with(app)` seam 0415
// established for registerTools/registerCommands. Full design + inventory +
// per-field proof + phase log: doc/tasks/work/0419-app-decomp-panels.md.
//
// Phase 1 (this commit): only the CTX-FREE pure helpers move (11 named +
// the two cross-boundary push/pop style pairs -- 13 free functions total,
// param-less, no `EditorApp app` / `with(app)`). The four CTX-taking popup
// helpers (dispatchAction/renderFalloffStackItems/renderDynamicPopupItems/
// renderPopupItems) and all six panel entry points stay in app.d for now
// (later 0419 phases) -- `dispatchAction` in particular is called from
// inside `drawSidePanel`'s still-nested `renderButton`, so moving it before
// its caller would just add an early cross-module `app,` edit for no
// benefit at this phase boundary.
//
// Import surface: harvested from editor_app.d's own import block (itself a
// harvest of app.d's top-level imports, per 0415) plus `Viewport3D` (needed
// by renderViewportSceneToFbo's own parameter type in a LATER phase; added
// now so the whole harvest is copy-paste stable across phases) plus the
// editor_app.d task-0419 relocations (EditorApp itself, plus the types/
// constants/functions/globals relocated there to keep editor_app.d free of
// a back-edge to app -- see editor_app.d's own "Task 0419" doc comment).
// Deliberately NO `import app` -- that is what keeps this module and app.d
// from forming an import cycle (app.d imports ui.panels' free functions
// instead).
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
import document       : Layer, Document;
import snap           : ItemSnapFrame;
import viewport       : LayoutPreset, ViewportManager, Viewport3D;

version (WithAI) import commands.ui.copilot_panel : UiCopilotPanelCommand, g_copilotPanelShown;
version (WithAI) {
    import commands.copilot.analyze        : CopilotAnalyzeCommand;
    import commands.copilot.select_finding : CopilotSelectFindingCommand;
    import commands.copilot.cycle_finding  : CopilotCycleFindingCommand;
    import copilot_panel : CopilotPanel;
    import copilot_overlay : drawCopilotFindingOverlay;
}

// Task-0419 relocations out of app.d (editor_app.d is the shared foundation
// -- see its own "Task 0419" doc comment for the full rationale on each).
import editor_app : EditorApp, BgGpu, Layout, OverlayMode,
    kAiToggleAvailable, kGenerateAiAvailable,
    edgeKey, countSelected, buildItemFrame, seedDefaultLayoutIfMissing,
    g_layoutIniPathZ, g_forceLayoutReseed, g_pendingLayoutReloadPathZ;

// =============================================================================
// Phase 1 -- pure helpers (no EditorApp / no `with(app)`; param-less or
// taking only plain value args). Includes the two cross-boundary style
// pairs (pushPanelChromeStyle/popPanelChromeStyle, pushPopupStyle/
// popPopupStyle) that app.d's still-nested main-body code (chrome: 6 call
// sites; popup: 12 call sites) also calls directly -- those sites keep
// their bare `pushXStyle()` / `popXStyle()` call syntax unchanged; app.d
// now imports these instead of resolving them as sibling nested functions.
// =============================================================================

void drawButtonOutline() {
    auto dl = ImGui.GetWindowDrawList();
    ImVec2 rmin = ImGui.GetItemRectMin();
    ImVec2 rmax = ImGui.GetItemRectMax();
    uint c = IM_COL32(0, 0, 0, 255);
    dl.AddLine(ImVec2(rmin.x, rmin.y), ImVec2(rmax.x, rmin.y), c);  // top
    dl.AddLine(ImVec2(rmin.x, rmin.y), ImVec2(rmin.x, rmax.y), c);  // left
    dl.AddLine(ImVec2(rmin.x, rmax.y), ImVec2(rmax.x, rmax.y), c);  // bottom
    dl.AddLine(ImVec2(rmax.x, rmin.y), ImVec2(rmax.x, rmax.y), c);  // right
}

// Raised bevel drawn as `thickness` concentric rings just
// inside the 1-pixel outline.
void drawRaisedBevel(uint light, uint dark, bool pressed = false,
                     int thickness = 2) {
    auto dl = ImGui.GetWindowDrawList();
    ImVec2 rmin = ImGui.GetItemRectMin();
    ImVec2 rmax = ImGui.GetItemRectMax();
    uint tl = pressed ? dark  : light;
    uint br = pressed ? light : dark;
    foreach (i; 0 .. thickness) {
        float x0 = rmin.x + 1.0f + i, y0 = rmin.y + 1.0f + i;
        float x1 = rmax.x - 2.0f - i, y1 = rmax.y - 2.0f - i;
        dl.AddLine(ImVec2(x0, y0), ImVec2(x1, y0), tl);
        dl.AddLine(ImVec2(x0, y0), ImVec2(x0, y1), tl);
        dl.AddLine(ImVec2(x0, y1), ImVec2(x1, y1), br);
        dl.AddLine(ImVec2(x1, y0), ImVec2(x1, y1), br);
    }
}

// The editor's button chrome: beige palette for tools, pale blue for commands;
// renders as pure white when `on` (active) or `held` (mouse down).
// Returns true when the button is clicked this frame.
bool renderStyledButton(string label, string shortcut, bool on, bool isCommand,
                        ImVec2 size, bool disabled = false) {
    ImVec4 bgNormal, bgHover;
    uint   bevelLightN, bevelDarkN, bevelLightH, bevelDarkH;
    if (isCommand) {
        bgNormal    = ImVec4(0.635f, 0.686f, 0.749f, 1.0f);  // (162,175,191)
        bgHover     = ImVec4(0.698f, 0.749f, 0.812f, 1.0f);  // (178,191,207)
        bevelLightN = IM_COL32(206, 219, 235, 255);
        bevelDarkN  = IM_COL32(143, 156, 172, 255);
        bevelLightH = IM_COL32(222, 235, 251, 255);
        bevelDarkH  = IM_COL32(159, 172, 188, 255);
    } else {
        bgNormal    = ImVec4(0.710f, 0.710f, 0.655f, 1.0f);  // (181,181,167)
        bgHover     = ImVec4(0.773f, 0.773f, 0.718f, 1.0f);  // (197,197,183)
        bevelLightN = IM_COL32(225, 225, 211, 255);
        bevelDarkN  = IM_COL32(162, 162, 148, 255);
        bevelLightH = IM_COL32(241, 241, 227, 255);
        bevelDarkH  = IM_COL32(178, 178, 164, 255);
    }

    ImVec4 white = ImVec4(1.0f, 1.0f, 1.0f, 1.0f);
    // Disabled buttons keep the normal bg / bevel but freeze hover
    // and active responses (disabled rows don't visually react to
    // the cursor at all).
    if (disabled) {
        ImGui.PushStyleColor(ImGuiCol.Button,        bgNormal);
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, bgNormal);
        ImGui.PushStyleColor(ImGuiCol.ButtonActive,  bgNormal);
    } else {
        ImGui.PushStyleColor(ImGuiCol.Button,        on ? white : bgNormal);
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, on ? white : bgHover);
        ImGui.PushStyleColor(ImGuiCol.ButtonActive,  white);
    }
    ImGui.PushStyleVar(ImGuiStyleVar.ButtonTextAlign, ImVec2(0.0f, 0.5f));
    // Suppress ImGui's built-in text rendering for disabled rows —
    // we draw the engraved label ourselves after the bevel pass.
    // Visible text empty (everything before "##"), ID derived from
    // the original label so ImGui's per-window ItemAdd doesn't
    // collide when multiple disabled rows are stacked (empty ID
    // at window root → assert).
    string btnLabel = disabled ? ("##" ~ label) : label;
    bool rawClicked = ImGui.Button(btnLabel, size);
    bool clicked    = rawClicked && !disabled;
    ImGui.PopStyleVar();
    ImGui.PopStyleColor(3);

    bool held = !disabled && ImGui.IsItemActive();
    drawButtonOutline();
    if (!on && !held) {
        bool hov = !disabled && ImGui.IsItemHovered();
        drawRaisedBevel(hov ? bevelLightH : bevelLightN,
                        hov ? bevelDarkH  : bevelDarkN,
                        false);
    }

    // Disabled-engrave: dark text body + 1-px (+1, +1) highlight
    // shadow. A side-panel greyed-but-readable look — bg/bevel
    // unchanged, only the
    // label rendering differs.
    if (disabled) {
        ImVec2 rmin = ImGui.GetItemRectMin();
        ImVec2 rmax = ImGui.GetItemRectMax();
        ImVec2 ts   = ImGui.CalcTextSize(label);
        ImVec2 tp   = ImVec2(rmin.x + 6.0f,
                             rmin.y + (rmax.y - rmin.y - ts.y) * 0.5f);
        uint shadowCol = IM_COL32(245, 245, 231, 200);
        uint textCol   = IM_COL32( 95,  90,  78, 255);
        ImGui.GetWindowDrawList().AddText(ImVec2(tp.x + 1, tp.y + 1),
                                          shadowCol, label);
        ImGui.GetWindowDrawList().AddText(tp, textCol, label);
    }

    if (shortcut.length > 0) {
        ImVec2 rmin = ImGui.GetItemRectMin();
        ImVec2 rmax = ImGui.GetItemRectMax();
        ImVec2 ts   = ImGui.CalcTextSize(shortcut);
        ImVec2 tp   = ImVec2(rmax.x - ts.x - 6.0f,
                             rmin.y + (rmax.y - rmin.y - ts.y) * 0.5f);
        uint scCol = (on || held) ? IM_COL32(0, 0, 0, 255)
                                  : IM_COL32(245, 245, 231, 255);
        ImGui.GetWindowDrawList().AddText(tp, scCol, shortcut);
    }
    return clicked;
}

// Resolve a popup item's `checked:` block via the popup_state
// registry. Producers publish via setStatePath; this is the only
// consumer site.
bool popupItemChecked(ref Checked chk) {
    import popup_state : resolveChecked;
    return resolveChecked(chk);
}

// True when a File-menu Import/Export command id targets a format that
// routes through assimp (so it must be greyed out when libassimp is
// unavailable). Ids look like "file.import.obj" / "file.export.gltf";
// the trailing token is the extension consulted in the format registry.
static bool popupActionNeedsAssimp(string commandId) {
    import std.algorithm.searching : startsWith, findSplitAfter;
    import io.formats : formatNeedsAssimp;
    if (!commandId.startsWith("file.import.") &&
        !commandId.startsWith("file.export."))
        return false;
    // last dot-separated token = bare ext ("obj", "gltf", ...)
    auto split = commandId.findSplitAfter("file.import.");
    string ext = split[1].length ? split[1]
                                 : commandId.findSplitAfter("file.export.")[1];
    return formatNeedsAssimp(ext);
}

// Walk popup items (recursing into submenus) and return the label
// of the first one whose `checked:` resolves true. Powers
// `Action.dynamicLabel` — a "popup face" that reflects the active
// option. Returns "" when nothing matches.
string firstCheckedLabel(ref PopupItem[] items) {
    foreach (ref it; items) {
        final switch (it.kind) {
            case PopupItemKind.action:
                if (it.checked.present && popupItemChecked(it.checked))
                    return it.label;
                break;
            case PopupItemKind.submenu:
                string s = firstCheckedLabel(it.subItems);
                if (s.length > 0) return s;
                break;
            case PopupItemKind.divider:
            case PopupItemKind.header:
            case PopupItemKind.dynamic:
                break;
        }
    }
    return "";
}

// The editor's popup chrome — extracted to source/imgui_style.d
// so non-app code (toolpipe stages' drawProperties) can re-use the
// same look. Thin wrappers retained for the existing App-side call
// sites; same Push/Pop balance contract as before.
void pushPopupStyle() {
    import imgui_style : pushPopupStyle;
    pushPopupStyle();
}

void popPopupStyle() {
    import imgui_style : popPopupStyle;
    popPopupStyle();
}

// Section header: dark slate-blue band with centered white
// text, framed by a 1-pixel black outline matching button edges.
void drawSectionHeader(string title) {
    auto dl = ImGui.GetWindowDrawList();
    ImVec2 pos = ImGui.GetCursorScreenPos();
    // Match full-width buttons rendered with ImVec2(-1, 0) — ImGui resolves
    // that to avail.x - 1, so subtract one here to keep right edges flush.
    float  w   = ImGui.GetContentRegionAvail().x - 1.0f;
    ImVec2 ts  = ImGui.CalcTextSize(title);
    float  h   = ts.y + 4.0f;
    ImVec2 rmax = ImVec2(pos.x + w, pos.y + h);
    dl.AddRectFilled(pos, rmax, IM_COL32(84, 84, 94, 255));
    uint c = IM_COL32(0, 0, 0, 255);
    dl.AddLine(ImVec2(pos.x, pos.y),  ImVec2(rmax.x, pos.y),  c);  // top
    dl.AddLine(ImVec2(pos.x, pos.y),  ImVec2(pos.x, rmax.y),  c);  // left
    dl.AddLine(ImVec2(pos.x, rmax.y), ImVec2(rmax.x, rmax.y), c);  // bottom
    dl.AddLine(ImVec2(rmax.x, pos.y), ImVec2(rmax.x, rmax.y), c);  // right
    float tx = pos.x + (w - ts.x) * 0.5f;
    float ty = pos.y + 2.0f;
    dl.AddText(ImVec2(tx, ty), IM_COL32(255, 255, 255, 255), title);
    ImGui.Dummy(ImVec2(w, h));
}

// The editor's panel chrome: grey bg, black border, beige/blue button
// palette, black text, flat frames. Call BEFORE `ImGui.Begin` and pair with
// popPanelChromeStyle() AFTER `ImGui.End`.
void pushPanelChromeStyle() {
    ImVec4 winBg   = ImVec4(0.561f, 0.561f, 0.561f, 1.0f);   // (143,143,143)
    ImVec4 border  = ImVec4(0.0f,   0.0f,   0.0f,   1.0f);
    ImVec4 btnBg   = ImVec4(0.710f, 0.710f, 0.655f, 1.0f);   // tool beige
    ImVec4 btnHov  = ImVec4(0.773f, 0.773f, 0.718f, 1.0f);
    ImVec4 btnAct  = ImVec4(1.0f,   1.0f,   1.0f,   1.0f);
    ImVec4 black   = ImVec4(0.0f,   0.0f,   0.0f,   1.0f);
    ImVec4 grabLo  = ImVec4(0.45f,  0.45f,  0.45f,  1.0f);
    ImVec4 grabHi  = ImVec4(0.20f,  0.20f,  0.20f,  1.0f);

    ImGui.PushStyleColor(ImGuiCol.WindowBg,         winBg);
    ImGui.PushStyleColor(ImGuiCol.Border,           border);
    ImGui.PushStyleColor(ImGuiCol.TitleBg,          winBg);
    ImGui.PushStyleColor(ImGuiCol.TitleBgActive,    winBg);
    ImGui.PushStyleColor(ImGuiCol.TitleBgCollapsed, winBg);
    ImGui.PushStyleColor(ImGuiCol.Text,             black);
    ImGui.PushStyleColor(ImGuiCol.Button,           btnBg);
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered,    btnHov);
    ImGui.PushStyleColor(ImGuiCol.ButtonActive,     btnAct);
    ImGui.PushStyleColor(ImGuiCol.FrameBg,          btnBg);
    ImGui.PushStyleColor(ImGuiCol.FrameBgHovered,   btnHov);
    ImGui.PushStyleColor(ImGuiCol.FrameBgActive,    btnAct);
    ImGui.PushStyleColor(ImGuiCol.SliderGrab,       grabLo);
    ImGui.PushStyleColor(ImGuiCol.SliderGrabActive, grabHi);
    ImGui.PushStyleColor(ImGuiCol.CheckMark,        black);
    // Dropdown / combo popups open INSIDE this chrome inherit its black Text,
    // but PopupBg defaults to the dark StyleColorsDark value → black-on-dark,
    // unreadable. Match PopupBg to the field background (btnBg) so an open
    // combo reads the same as its closed state. Only popup WINDOWS use
    // PopupBg, so CollapsingHeader section styling is unaffected.
    ImGui.PushStyleColor(ImGuiCol.PopupBg,          btnBg);

    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding,    ImVec2(3, 3));
    ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 1.0f);
    ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding,    0.0f);
}

void popPanelChromeStyle() {
    ImGui.PopStyleVar(3);
    ImGui.PopStyleColor(16);
}

// Packed-button-row layout (large FramePadding, zero ItemSpacing). Use inside
// Begin for button-only panels; skip for Tool Properties so inputs keep
// normal spacing. Pair with popButtonBarStyle().
void pushButtonBarStyle() {
    ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, ImVec2(6, 5));
    ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing,  ImVec2(0, 0));
}

void popButtonBarStyle() {
    ImGui.PopStyleVar(2);
}

// =============================================================================
// Phase 2 -- pilot: drawTabPanel, the smallest CTX-panel (reads testMode,
// layout.tabPos/tabSize, panels/activePanelIdx; calls the pure
// renderStyledButton + pushPanelChromeStyle/popPanelChromeStyle/
// pushButtonBarStyle/popButtonBarStyle from Phase 1). No CTX-helper
// cross-calls at this phase. Body verbatim from app.d's former nested
// function, wrapped in `with (app) { ... }` per the 0415 seam.
// =============================================================================

void drawTabPanel(EditorApp app) {
    with (app) {
    pushPanelChromeStyle();
    if (testMode) {
        ImGui.SetNextWindowPos(layout.tabPos, ImGuiCond.Always);
        ImGui.SetNextWindowSize(layout.tabSize, ImGuiCond.Always);
    }
    int tabFlags = ImGuiWindowFlags.NoCollapse;
    if (testMode) tabFlags |= ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoResize | ImGuiWindowFlags.NoMove;
    if (ImGui.Begin("Tab bar", null, tabFlags))
    {
        pushButtonBarStyle();
        scope(exit) popButtonBarStyle();

        enum float btnW = 90.0f;
        foreach (i, ref p; panels) {
            bool on = (cast(int)i == activePanelIdx);
            if (renderStyledButton(p.title, "", on, /*isCommand=*/true,
                                   ImVec2(btnW, 0)))
                activePanelIdx = cast(int)i;
            if (i + 1 < panels.length)
                ImGui.SameLine();
        }
    }
    ImGui.End();
    popPanelChromeStyle();
    }
}
