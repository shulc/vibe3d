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

// =============================================================================
// Phase 3 -- drawViewportPropsPanel (cameraView/vpm/layout/formsPanel/
// formsInteractiveDispatch, plus the Б1 layout-cluster --
// g_layoutIniPathZ/g_forceLayoutReseed/g_pendingLayoutReloadPathZ/
// seedDefaultLayoutIfMissing -- already relocated to editor_app.d in
// Phase 1 and imported above; this phase is just the verbatim body move).
// =============================================================================

// -------------------------------------------------------------------------
// Viewport Properties panel
// -------------------------------------------------------------------------
// Dockable panel that reflects and drives the active cell's Independence
// flags (indCenter / indScale / indRotate) and Master selector.  Every
// interaction dispatches through commandHandlerDelegate (same path as
// /api/command) — the panel NEVER mutates vpm directly.  Also hosts the
// Reset Layout button.
//
// Visibility: always shown in interactive mode; hidden in --test by default
// (opt-in via `ui.viewportProps show` + g_viewportPropsShown) so synthetic
// viewport drags can never be captured by it.
void drawViewportPropsPanel(EditorApp app) {
    with (app) {
    import commands.ui.viewport_props : g_viewportPropsShown;
    import std.json : JSONValue;
    import std.conv : to;

    pushPanelChromeStyle();
    if (ImGui.Begin("Viewport Properties")) {
        auto v = vpm.views[vpm.activeId];

        // Layout switcher: Single / 2-split H / 2-split V / Quad.
        // Highlights the active preset; each button fires viewport.layout.
        ImGui.SeparatorText("Layout");
        {
            import viewport : LayoutPreset;
            static immutable string[4] lblNames = ["Single", "Split H", "Split V", "Quad"];
            static immutable string[4] lblIds   = ["Single", "SplitH", "SplitV", "Quad"];
            static immutable LayoutPreset[4] lblVals =
                [LayoutPreset.Single, LayoutPreset.SplitH,
                 LayoutPreset.SplitV, LayoutPreset.Quad];
            foreach (i; 0 .. 4) {
                if (i > 0) ImGui.SameLine();
                bool cur = (vpm.layout == lblVals[i]);
                if (cur) ImGui.PushStyleColor(ImGuiCol.Button,
                                              ImVec4(0.30f, 0.45f, 0.65f, 1.0f));
                if (ImGui.Button(lblNames[i]) && commandHandlerDelegate !is null)
                    commandHandlerDelegate("viewport.layout",
                        `{"_positional":["` ~ lblIds[i] ~ `"]}`);
                if (cur) ImGui.PopStyleColor(1);
            }
        }

        ImGui.Dummy(ImVec2(0, 2));
        ImGui.SeparatorText("Active Cell Independence");

        bool ic = v.indCenter;
        if (ImGui.Checkbox("Center", &ic) && commandHandlerDelegate !is null)
            commandHandlerDelegate("viewport.indCenter",
                                  ic ? `{"value":"yes"}` : `{"value":"no"}`);

        ImGui.SameLine();
        bool isc = v.indScale;
        if (ImGui.Checkbox("Scale", &isc) && commandHandlerDelegate !is null)
            commandHandlerDelegate("viewport.indScale",
                                  isc ? `{"value":"yes"}` : `{"value":"no"}`);

        ImGui.SameLine();
        bool ir = v.indRotate;
        if (ImGui.Checkbox("Rotate", &ir) && commandHandlerDelegate !is null)
            commandHandlerDelegate("viewport.indRotate",
                                  ir ? `{"value":"yes"}` : `{"value":"no"}`);

        // Master selector
        ImGui.Dummy(ImVec2(0, 2));
        ImGui.SeparatorText("Master");
        int mid = v.masterId;
        string masterLabel = mid < 0 ? "Group master" : "Cell " ~ to!string(mid);
        ImGui.SetNextItemWidth(-1.0f);
        if (ImGui.BeginCombo("##vpMaster", masterLabel)) {
            bool grpSel = (mid < 0);
            if (ImGui.Selectable("Group master", grpSel) && commandHandlerDelegate !is null)
                commandHandlerDelegate("viewport.master", `{"_positional":["-1"]}`);
            if (grpSel) ImGui.SetItemDefaultFocus();
            foreach (ci; 0 .. vpm.cellCount) {
                bool csel = (mid == ci);
                string clabel = "Cell " ~ to!string(ci);
                if (ImGui.Selectable(clabel, csel) && commandHandlerDelegate !is null)
                    commandHandlerDelegate("viewport.master",
                        `{"_positional":["` ~ to!string(ci) ~ `"]}`);
                if (csel) ImGui.SetItemDefaultFocus();
            }
            ImGui.EndCombo();
        }

        // Reset Layout button
        ImGui.Dummy(ImVec2(0, 2));
        ImGui.Separator();
        if (ImGui.Button("Reset Layout")) {
            // The shipped default ini is Single (only Viewport##0), so
            // mirror the persisted cell preset too — otherwise a Quad
            // user hitting Reset Layout would restore the shipped dock
            // arrangement but keep g_prefs.viewportLayout == Quad, and a
            // later clean-shutdown save would silently resurrect the
            // stale multi-cell preset on the next launch. Mirrors the
            // same assignment in the onViewportReset delegates (file.new
            // / scene.reset) below.
            g_prefs.viewportLayout = LayoutPreset.Single;
            // Remove the persisted ini, then immediately re-seed it from
            // the shipped default (config/default_layout.ini — the
            // user's confirmed arrangement) via the same first-run copy
            // helper. Without this, ImGui's ~5s autosave timer (or the
            // save-on-shutdown at DestroyContext) would overwrite the
            // freshly-copied file with the programmatic DockBuilder
            // rebuild below before the NEXT launch ever sees it — so we
            // pull the shipped bytes into the LIVE in-memory settings
            // now (deferred to just before the next NewFrame — see
            // g_pendingLayoutReloadPathZ) so this session's own eventual
            // autosave/shutdown-save also reflects the shipped default,
            // not the programmatic seed. The programmatic DockBuilder
            // reseed (g_forceLayoutReseed) becomes a FALLBACK, used only
            // when no shipped default could be re-copied (e.g. running
            // from a location where config/default_layout.ini isn't
            // found).
            bool restored = false;
            if (!command.g_testMode && g_layoutIniPathZ !is null) {
                import std.string : fromStringz;
                string p = cast(string) fromStringz(g_layoutIniPathZ);
                try {
                    import std.file : remove, exists;
                    if (exists(p)) remove(p);
                } catch (Exception) {}
                if (seedDefaultLayoutIfMissing(p)) {
                    // Defer the reload: this button handler runs
                    // mid-frame (between NewFrame/EndFrame), and
                    // ImGui.LoadIniSettingsFromDisk documents that as
                    // unsafe. g_pendingLayoutReloadPathZ is consumed
                    // once, right before the next NewFrame().
                    g_pendingLayoutReloadPathZ = g_layoutIniPathZ;
                    restored = true;
                }
            }
            // Fallback only: no shipped default was available to
            // re-copy, so fall back to the bare programmatic seed for
            // THIS session (still won't persist past the ini-autosave,
            // but there is no better default to persist).
            g_forceLayoutReseed = !restored;
        }
    }
    ImGui.End();
    popPanelChromeStyle();
    }
}

// =============================================================================
// Phase 4 -- drawLayerListPanel (document/layer/layerRenameIndex/
// layerRenameBuf/formsPanel/formsInteractiveDispatch/runCommand -- runCommand
// isn't actually read by this body, verbatim comment kept from the plan's own
// wording; the panel dispatches through commandHandlerDelegate only).
// =============================================================================

// -------------------------------------------------------------------------
// Layers panel (layers Stage 4)
// -------------------------------------------------------------------------
//
// Interactive layer manager. One row per `document.layers`:
//   - a primary/selected indicator + name selectable → `layer.select`
//     (plain click mode:set, ctrl-click mode:toggle)
//   - the layer name (double-click to rename in place → `layer.rename`)
//   - a "V" (visible) checkbox     → `layer.setVisible index:N value:b`
//   - an "F" (foreground) checkbox → `layer.select index:N mode:add/remove`
//     (foreground == selected; background is the derived complement)
// plus an "Add" button (`layer.add`) and a "Delete" button
// (`layer.delete index:N`, disabled when only one layer remains — the
// command refuses the last layer regardless, this just greys the affordance).
//
// EVERY interaction dispatches through commandHandlerDelegate — the same
// path /api/command uses — so undo/history/coalescing all work. The panel
// NEVER mutates `document` directly. It is pure UI: no toolpipe, no mesh.
//
// Visibility mirrors Tool Properties: always shown in a normal run; in
// --test it is HIDDEN by default (so it cannot capture viewport drags) and
// is only drawn when `ui.layerList show` set g_layerListShown.
void drawLayerListPanel(EditorApp app) {
    with (app) {
    import std.json : JSONValue;
    import std.conv : to;
    import std.string : fromStringz;

    pushPanelChromeStyle();
    // SetNextWindowPos/Size dropped — the dock slot controls position;
    // DockBuilderDockWindow("Layers", rightId) pre-assigns the window.
    if (ImGui.Begin("Layers")) {
        // ---- Add button ----
        if (ImGui.SmallButton("Add")) {
            if (commandHandlerDelegate !is null)
                commandHandlerDelegate("layer.add", "{}");
        }
        ImGui.SameLine();
        // ---- Delete button (disabled at one layer) ----
        bool lastLayer = document.layers.length <= 1;
        ImGui.BeginDisabled(lastLayer);
        if (ImGui.SmallButton("Delete")) {
            if (commandHandlerDelegate !is null)
                commandHandlerDelegate("layer.delete",
                    `{"index":` ~ to!string(document.activeIndex) ~ `}`);
        }
        ImGui.EndDisabled();

        ImGui.Separator();

        // ---- One row per layer ----
        foreach (i; 0 .. document.layers.length) {
            auto l = document.layers[i];
            int idx = cast(int)i;
            ImGui.PushID(idx);

            // Primary / selection indicator + exclusive-select handle
            // (Stage 4). The primary layer is the single edit target; the
            // `selected` layers form the foreground set. The marker shows
            // both states at a glance:
            //   ">"  primary (always selected + visible)
            //   "*"  selected (foreground) but not primary
            //   " "  deselected (derived background)
            // Clicking this handle is an EXCLUSIVE select (`mode:set`):
            // it makes this the sole selected layer AND the primary. The
            // command compares object identity, so re-clicking the primary
            // is a no-op switch; guard against re-dispatching every frame
            // the row is held. Multi-select lives on the name (ctrl-click).
            bool isPrimaryRow = document.isPrimary(l);
            immutable marker = isPrimaryRow ? ">" : (l.selected ? "*" : " ");
            if (ImGui.Selectable(marker, isPrimaryRow,
                                 ImGuiSelectableFlags.AllowItemOverlap,
                                 ImVec2(14, 0))) {
                if (!isPrimaryRow && commandHandlerDelegate !is null)
                    commandHandlerDelegate("layer.select",
                        `{"index":` ~ to!string(idx) ~ `,"mode":"set"}`);
            }
            ImGui.SameLine();

            // Name — double-click to rename in place.
            if (layerRenameIndex == idx) {
                // Inline edit: Enter (or focus loss) commits, Esc cancels.
                if (ImGui.IsWindowAppearing() || !ImGui.IsAnyItemActive())
                    ImGui.SetKeyboardFocusHere();
                ImGui.SetNextItemWidth(140);
                bool commit = ImGui.InputText("##rename", layerRenameBuf[],
                                  ImGuiInputTextFlags.EnterReturnsTrue);
                bool cancel = ImGui.IsKeyPressed(ImGuiKey.Escape);
                // Commit on Enter or when the field loses focus (click away).
                if (!commit && !cancel
                    && ImGui.IsItemDeactivatedAfterEdit())
                    commit = true;
                if (commit) {
                    string newName =
                        cast(string) fromStringz(layerRenameBuf.ptr).dup;
                    if (newName.length && commandHandlerDelegate !is null)
                        commandHandlerDelegate("layer.rename",
                            `{"index":` ~ to!string(idx) ~ `,"name":`
                            ~ JSONValue(newName).toString() ~ `}`);
                    layerRenameIndex = -1;
                } else if (cancel || ImGui.IsItemDeactivated()) {
                    layerRenameIndex = -1;
                }
            } else {
                // Plain label — also the multi-select target (Stage 4).
                // It is highlighted when the layer is in the foreground
                // (selected) set, so the panel reflects the whole set, not
                // just the primary. Click semantics:
                //   plain click → `layer.select mode:set`    (exclusive
                //                 select + make primary)
                //   ctrl-click  → `layer.select mode:toggle` (add/remove
                //                 this layer from the foreground set;
                //                 removing the primary promotes another)
                // Double-click still opens the inline rename editor; the
                // label is also the drag-to-reorder handle (below). Every
                // path dispatches a `layer.*` command — no direct document
                // mutation — so it is undoable + headless-identical.
                bool nameClicked =
                    ImGui.Selectable(l.name.length ? l.name : "(unnamed)",
                                     l.selected,
                                     ImGuiSelectableFlags.AllowDoubleClick,
                                     ImVec2(140, 0));
                bool dbl = ImGui.IsItemHovered()
                    && ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left);
                if (nameClicked && !dbl && commandHandlerDelegate !is null) {
                    // io.KeyCtrl is the frame's merged Ctrl-modifier state
                    // (matches every other modifier read in the app).
                    immutable mode = io.KeyCtrl ? `"toggle"` : `"set"`;
                    // Plain click on the already-primary row is a no-op
                    // switch; skip it so a single-select drag-press doesn't
                    // re-dispatch every frame. Ctrl-click always dispatches
                    // (it must be able to deselect the primary too).
                    if (io.KeyCtrl || !document.isPrimary(l))
                        commandHandlerDelegate("layer.select",
                            `{"index":` ~ to!string(idx) ~ `,"mode":`
                            ~ mode ~ `}`);
                }
                if (dbl) {
                    layerRenameIndex = idx;
                    layerRenameBuf[] = 0;
                    auto src = l.name;
                    size_t n = src.length < layerRenameBuf.length - 1
                             ? src.length : layerRenameBuf.length - 1;
                    layerRenameBuf[0 .. n] = src[0 .. n];
                }

                // ---- Drag-to-reorder ----
                // The label row is both a drag SOURCE (carries its own index)
                // and a drop TARGET (receives another row's index). Dropping
                // row `from` onto this row dispatches layer.reorder so the
                // dragged layer lands at THIS row's index — the others shift
                // to fill. The neutral payload type "VIBE3D_LAYER_ROW" (16
                // chars, under the 32-char d_imgui limit) tags the drag so
                // only layer rows accept it.
                //
                // `to`-index semantics: the layer.reorder command splices the
                // source layer OUT of the array, then splices it back IN at
                // index `to` of the POST-REMOVAL array. With `to = idx`, the
                // dragged row always lands at the target row's index for BOTH
                // up- and down-drags (verified against the splice path in
                // commands/layer/commands.d::moveLayer and the test_layers.d
                // reorder cases: from:2 to:0 on [A,B,C] -> [C,A,B];
                // from:0 to:2 -> [B,C,A]). No from<to adjustment is needed:
                // on a down-drag the source's removal already shifts the
                // target up by one, so inserting at `idx` lands the dragged
                // row exactly at the target's old visual slot.
                if (ImGui.BeginDragDropSource(ImGuiDragDropFlags.None)) {
                    int srcIdx = idx;
                    ImGui.SetDragDropPayload("VIBE3D_LAYER_ROW",
                                             &srcIdx, srcIdx.sizeof);
                    ImGui.Text(l.name.length ? l.name : "(unnamed)");
                    ImGui.EndDragDropSource();
                }
                if (ImGui.BeginDragDropTarget()) {
                    const(ImGuiPayload)* payload =
                        ImGui.AcceptDragDropPayload("VIBE3D_LAYER_ROW");
                    if (payload !is null
                        && payload.Data !is null
                        && payload.DataSize == cast(int)int.sizeof) {
                        int fromIdx = *cast(const(int)*) payload.Data;
                        if (fromIdx != idx && commandHandlerDelegate !is null)
                            commandHandlerDelegate("layer.reorder",
                                `{"from":` ~ to!string(fromIdx)
                                ~ `,"to":` ~ to!string(idx) ~ `}`);
                    }
                    ImGui.EndDragDropTarget();
                }
            }

            // Visible checkbox.
            ImGui.SameLine();
            bool vis = l.visible;
            if (ImGui.Checkbox("V", &vis)) {
                if (commandHandlerDelegate !is null)
                    commandHandlerDelegate("layer.setVisible",
                        `{"index":` ~ to!string(idx) ~ `,"value":`
                        ~ (vis ? "true" : "false") ~ `}`);
            }
            // Foreground indicator (Stage 2b). The old "B" (background)
            // checkbox collapsed into the derived selection model: a layer is
            // FOREGROUND iff it is selected. The checkbox shows foreground
            // membership and dispatches the item-selection mutator —
            // check ⇒ `layer.select mode:add` (select), uncheck ⇒
            // `mode:remove` (deselect ⇒ derived background). No more separate
            // background flag; `layer.setVisible` still owns visibility.
            ImGui.SameLine();
            bool fg = document.foreground(l);
            if (ImGui.Checkbox("F", &fg)) {
                if (commandHandlerDelegate !is null)
                    commandHandlerDelegate("layer.select",
                        `{"index":` ~ to!string(idx) ~ `,"mode":`
                        ~ (fg ? `"add"` : `"remove"`) ~ `}`);
            }

            ImGui.PopID();
        }

        // ---- Layer (item) properties form ----
        // Render the config-driven layer-props form for the ACTIVE
        // (primary) layer below the layer list — the same FormsPanel that
        // drives Tool Properties, fed a LayerPropsProvider wrapping the
        // primary layer. The form is looked up by its explicit id
        // ("layer.props"); guard cleanly if it is absent (config/forms not
        // present, or VIBE3D_FORMS=0 kill-switch).
        //
        // A value edit dispatches `layer.attr <idx> <attr> <v>` (UI-undo
        // class, coalesced); the row reads the provider's live value via
        // `layer.attr … ?`. The per-item transform is non-baked — applied
        // as a display matrix at the mesh draw sites — so the mesh is never
        // re-uploaded on an edit. The transform rows grey out while a
        // transform tool is active (a mid-gesture interlock).
        {
            import forms : g_formsPanelEnabled, formById;
            if (g_formsPanelEnabled && document.layers.length) {
                if (auto layerForm = formById("layer.props")) {
                    ImGui.Separator();
                    // Cache ONE provider and re-point it at the current
                    // primary each frame (allocation-free in steady state),
                    // instead of allocating a fresh LayerPropsProvider per
                    // frame. The provider's params() always alias the live
                    // bound layer, so the rebind keeps it correct.
                    static LayerPropsProvider layerProv;
                    if (layerProv is null)
                        layerProv = new LayerPropsProvider(document.primary);
                    else
                        layerProv.setLayer(document.primary);
                    // P4 primary-transform interlock: grey out the transform
                    // rows while a transform tool is active. The panel always
                    // binds the PRIMARY, so that is the only layer whose
                    // transform could desync the live gizmo (the transform is
                    // render-only; gizmo/drag run in the LOCAL frame). The
                    // guard is mid-gesture only — it clears when the tool
                    // drops; tool-free edits persist. (Same TransformTool
                    // cast the deferred-drag draw site uses.)
                    layerProv.setTransformGuard(
                        (cast(TransformTool)activeTool) !is null);
                    formsPanel.draw(*layerForm, layerProv,
                                    commandHandlerDelegate,
                                    formsInteractiveDispatch,
                                    /*activeToolId=*/"",
                                    /*stageId=*/"",
                                    /*layerIndex=*/to!string(
                                        document.activeIndex));
                }
            }
        }
    }
    ImGui.End();
    popPanelChromeStyle();
    }
}

// =============================================================================
// Phase 5 -- CTX popup-cluster + side/status, moved TOGETHER (they are
// mutually coupled: dispatchAction is called from renderFalloffStackItems/
// renderPopupItems/drawSidePanel's renderButton; renderPopupItems recurses
// into itself and is called from renderDynamicPopupItems + both
// drawSidePanel's and drawStatusBar's nested renderVariantPopup). The four
// CTX-helpers each become app-taking free functions; every cross-call between
// them (8 sites) gets an explicit `app,` argument -- bare-call syntax no
// longer resolves since these are no longer sibling nested functions sharing
// one enclosing scope.
// =============================================================================

void dispatchAction(EditorApp app, ref Action action) {
    with (app) {
    import argstring : parseArgstring;
    final switch (action.kind) {
        case ActionKind.tool:
            activateToolById(action.id);
            break;
        case ActionKind.command:
            if (!tryOpenArgsDialog(action.id))
                runCommand(reg.commandFactories[action.id]());
            break;
        case ActionKind.script:
            foreach (line; action.scriptLines) {
                auto parsed = parseArgstring(line);
                if (parsed.isEmpty) continue;
                if (commandHandlerDelegate !is null)
                    commandHandlerDelegate(parsed.commandId,
                                           parsed.params.toString());
            }
            break;
        case ActionKind.popup:
            // Nested popup not supported.
            break;
    }
    }
}

// popupItemChecked / popupActionNeedsAssimp relocated to
// source/ui/panels.d (task 0419 Phase 1 -- pure helpers). Both are used
// bare below (renderPopupItems, drawSidePanel's renderButton) and
// resolve via this import.
import ui.panels : popupItemChecked, popupActionNeedsAssimp;

// Live falloff-stack rows for the Falloff button's Alt popup. Lists
// every contributing FalloffStage instance; clicking one removes it
// from the queue. The primary ("falloff") is the compat anchor and
// can't be deleted — clicking it instead resets its type to none
// (the equivalent "drop from the active set"). Stacked extras
// ("falloff#N") dispatch falloff.remove <id>.
//
// Defined BEFORE renderPopupItems: these are nested functions, and
// D processes in-function declarations in order — renderPopupItems
// (the caller) must see this name already declared.
void renderFalloffStackItems(EditorApp app) {
    with (app) {
    if (g_pipeCtx is null) {
        ImGui.TextDisabled("(no pipeline)");
        return;
    }
    import toolpipe.stage          : TaskCode;
    import toolpipe.stages.falloff : FalloffStage;
    // Defer dispatch until after the loop — removing a stage mutates
    // the pipeline; collect the chosen command line and run it once
    // the menu walk is complete.
    string pending;
    int    shown = 0;
    foreach (s; g_pipeCtx.pipeline.findAllByTask(TaskCode.Wght)) {
        auto fo = cast(FalloffStage) s;
        if (fo is null) continue;
        bool primary = fo.isPrimary();
        // The anchor only counts as "active" when it carries a type;
        // a stacked extra always has one (add requires it) — list it
        // regardless so a degenerate none-typed extra is still
        // removable.
        if (primary && !fo.isActive()) continue;
        ++shown;
        string label = primary
                     ? fo.displayName()
                     : fo.displayName() ~ "  (" ~ fo.id() ~ ")";
        if (ImGui.MenuItem(label, "", /*selected=*/false)) {
            pending = primary
                    ? "tool.pipe.attr falloff type none"
                    : "falloff.remove " ~ fo.id();
        }
    }
    if (shown == 0)
        ImGui.TextDisabled("(no active falloff)");
    if (pending.length > 0) {
        Action a;
        a.kind        = ActionKind.script;
        a.scriptLines = [pending];
        dispatchAction(app, a);
    }
    }
}

// Expand a `kind: dynamic` popup item into runtime-generated rows.
// The config declares only the provider key (dynamicKind:); the
// actual rows depend on live state the YAML can't enumerate. New
// providers add a branch here. Unknown keys render a disabled hint
// rather than throwing mid-frame.
void renderDynamicPopupItems(EditorApp app, string kind) {
    with (app) {
    switch (kind) {
        case "falloffStack":
            renderFalloffStackItems(app);
            break;
        default:
            ImGui.TextDisabled("(unknown dynamic '%s')", kind);
            break;
    }
    }
}

// Render the body of a popup (between `BeginPopup` and `EndPopup`).
// Action items dispatch via `dispatchAction`; dividers/headers are
// non-interactive.
void renderPopupItems(EditorApp app, ref PopupItem[] items) {
    with (app) {
    foreach (ref it; items) {
        final switch (it.kind) {
            case PopupItemKind.divider:
                ImGui.Separator();
                break;
            case PopupItemKind.header:
                // Pass D string directly — d_imgui's varargs path
                // segfaults when %s + toStringz (immutable char*)
                // are combined; the rest of the codebase passes D
                // strings as %s args (see lines 3202 / 3218).
                ImGui.TextDisabled("%s", it.label);
                break;
            case PopupItemKind.action:
                bool checked = popupItemChecked(it.checked);
                // Availability gating (asset-I/O Phase 6): grey out
                // Import/Export items that route through assimp when the
                // dynamic libassimp isn't loaded. Native .v3d and LWO are
                // pure D and always enabled. The id encodes the target
                // ext (file.import.obj / file.export.gltf / ...).
                bool blocked = false;
                if (it.action.kind == ActionKind.command)
                    blocked = popupActionNeedsAssimp(it.action.id)
                              && !isAssimpAvailable();
                if (blocked) ImGui.BeginDisabled(true);
                if (ImGui.MenuItem(it.label, "", checked) && !blocked)
                    dispatchAction(app, it.action);
                if (blocked) {
                    ImGui.EndDisabled();
                    if (ImGui.IsItemHovered(ImGuiHoveredFlags.AllowWhenDisabled))
                        ImGui.SetTooltip("Requires libassimp — not loaded");
                }
                break;
            case PopupItemKind.submenu:
                if (ImGui.BeginMenu(it.label)) {
                    renderPopupItems(app, it.subItems);
                    ImGui.EndMenu();
                }
                break;
            case PopupItemKind.dynamic:
                renderDynamicPopupItems(app, it.dynamicKind);
                break;
        }
    }
    }
}

// firstCheckedLabel / pushPopupStyle / popPopupStyle / drawSectionHeader
// / pushPanelChromeStyle / popPanelChromeStyle / pushButtonBarStyle /
// popButtonBarStyle relocated to source/ui/panels.d (task 0419 Phase 1
// -- pure helpers, including the two cross-boundary style pairs). All
// are used bare below and in main-body code well past this point
// (chrome: 6 call sites; popup: 12 call sites; see the plan doc's Б3)
// -- resolve via this import instead of a sibling nested-function
// declaration.
import ui.panels : firstCheckedLabel, pushPopupStyle, popPopupStyle,
    drawSectionHeader, pushPanelChromeStyle, popPanelChromeStyle,
    pushButtonBarStyle, popButtonBarStyle;

void drawSidePanel(EditorApp app) {
    with (app) {
    pushPanelChromeStyle();
    // In --test: fixed rect + immovable flags reproduce today's exact
    // layout (picking rect unchanged → byte-identical).
    // Interactive: no fixed pos/size → floats/docks freely.
    if (testMode) {
        ImGui.SetNextWindowPos(layout.sidePos, ImGuiCond.Always);
        ImGui.SetNextWindowSize(layout.sideSize, ImGuiCond.Always);
    }
    int sidePanelFlags = ImGuiWindowFlags.NoCollapse;
    if (testMode) sidePanelFlags |= ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoResize | ImGuiWindowFlags.NoMove;
    if (ImGui.Begin("Mesh Info", null, sidePanelFlags))
    {
        pushButtonBarStyle();
        scope(exit) popButtonBarStyle();
        void renderButton(ref Button btn) {
            // Pick which (label, action) to show based on the live
            // modifier state. Priority: ctrl > alt > shift, single
            // modifier only (combinations not supported yet). Each
            // variant has its own popup ID so a popup opened via
            // alt-click survives the user releasing Alt — see the
            // BeginPopup loop at the end.
            SDL_Keymod mods = SDL_GetModState();
            string label   = btn.label;
            Action action  = btn.action;
            string variant = "";
            if      (btn.ctrl.present  && (mods & KMOD_CTRL))  {
                label = btn.ctrl.label;  action = btn.ctrl.action;
                variant = "_ctrl";
            }
            else if (btn.alt.present   && (mods & KMOD_ALT))   {
                label = btn.alt.label;   action = btn.alt.action;
                variant = "_alt";
            }
            else if (btn.shift.present && (mods & KMOD_SHIFT)) {
                label = btn.shift.label; action = btn.shift.action;
                variant = "_shift";
            }

            string sc;
            if (action.kind == ActionKind.tool) {
                if (auto sp = action.id in shortcuts.byToolId)
                    sc = sp.display();
            } else if (action.kind == ActionKind.command) {
                if (auto sp = action.id in shortcuts.byCommandId)
                    sc = sp.display();
            }
            // Visual "pressed" state. Button-level `checked:` wins
            // (works for any action kind — used by toggle buttons
            // like Snap whose state lives off in the pipeline).
            // Otherwise fall back to legacy logic: tool-id match,
            // or the popup action's own `checked:`.
            bool on;
            if (btn.checked.present)
                on = popupItemChecked(btn.checked);
            else
                on = (action.kind == ActionKind.tool &&
                      activeToolId == action.id)
                  || (action.kind == ActionKind.popup
                      && action.checked.present
                      && popupItemChecked(action.checked));
            // Scripts share the command's pale-blue palette (they're a
            // sequence of commands, not a sticky-tool activation).
            bool isCommand = (action.kind == ActionKind.command
                           || action.kind == ActionKind.script);
            // Auto-grey rows whose target action declares
            // restricted `supportedModes()` excluding the current
            // edit mode. `btn.disabled` (explicit YAML flag) wins
            // when set. Script / popup actions aren't checked —
            // their target isn't a single id.
            bool modeBlocked = false;
            if (action.kind == ActionKind.command)
                modeBlocked = reg.isModeBlocked("command", action.id, editMode);
            else if (action.kind == ActionKind.tool)
                modeBlocked = reg.isModeBlocked("tool", action.id, editMode);
            // "Generate 3D…" (ai3d.generate.open, task 0404 follow-up):
            // TRELLIS is Linux-only and requires WithAI — grey the entry
            // rather than hide it on every other build (see
            // kGenerateAiAvailable's doc comment near `main`).
            bool aiGateBlocked = action.kind == ActionKind.command
                && action.id == "ai3d.generate.open" && !kGenerateAiAvailable;
            bool effDisabled = btn.disabled || modeBlocked || aiGateBlocked;
            if (renderStyledButton(label, sc, on, isCommand,
                                   ImVec2(-1, 0), effDisabled)) {
                if (action.kind == ActionKind.popup)
                    ImGui.OpenPopup("##popup" ~ variant ~ "_" ~ btn.label);
                else
                    dispatchAction(app, action);
            }
            if (aiGateBlocked && ImGui.IsItemHovered())
                ImGui.SetTooltip("Not available in this build");
            // Render BeginPopup for EVERY popup variant the button
            // declares, regardless of which one is currently
            // active. Without this, a popup opened via alt-click
            // would close the moment the user releases Alt — the
            // BeginPopup branch below was previously gated on the
            // current variant's kind == popup, so on the first
            // post-release frame ImGui sees no BeginPopup for the
            // open ID and treats it as closed.
            void renderVariantPopup(string suf, ref Action a) {
                if (a.kind != ActionKind.popup) return;
                pushPopupStyle();
                scope(exit) popPopupStyle();
                if (ImGui.BeginPopup("##popup" ~ suf ~ "_" ~ btn.label)) {
                    renderPopupItems(app, a.popupItems);
                    ImGui.EndPopup();
                }
            }
            renderVariantPopup("",       btn.action);
            if (btn.ctrl.present)  renderVariantPopup("_ctrl",  btn.ctrl.action);
            if (btn.alt.present)   renderVariantPopup("_alt",   btn.alt.action);
            if (btn.shift.present) renderVariantPopup("_shift", btn.shift.action);
        }

        if (activePanelIdx >= 0 && activePanelIdx < cast(int)panels.length) {
            Panel* p = &panels[activePanelIdx];
            bool prevWasGroup = false;
            bool first        = true;
            foreach (ref item; p.items) {
                bool curIsGroup = item.isGroup;
                if (!first && (prevWasGroup || curIsGroup))
                    ImGui.Dummy(ImVec2(0, 10));  // LW inter-group gap = 10px
                if (curIsGroup) {
                    if (item.group.title.length > 0)
                        drawSectionHeader(item.group.title);
                    foreach (ref b; item.group.buttons)
                        renderButton(b);
                } else {
                    renderButton(item.button);
                }
                prevWasGroup = curIsGroup;
                first = false;
            }
        }

        ImGui.Separator();
        ImGui.Text("Info");
        // selectedN / totalN. The *SelectionOrderCounter fields
        // are MONOTONIC (incremented on each pick, never
        // decremented on deselect or selection-clear), so they
        // can't be used as a live "how many are selected right
        // now" readout. Walk the bool[] masks via countSelected.
        //
        // FUTURE perf note — countSelected is a linear walk
        // (1 byte per `bool` entry, likely auto-vectorised). At
        // typical mesh sizes the per-frame cost is:
        //     cube      :  ~26 bytes  → < 1 µs  (0.006 % frame)
        //     subdiv ×4 :  ~9 KB      → ~2 µs   (0.012 % frame)
        //     24 K cage :  ~96 KB     → ~25 µs  (0.18 %  frame)
        //     1 M poly  :  ~4 MB      → ~900 µs (5-6 %  frame)
        // So fine up to ~100 K elements; only worth optimising
        // when 1 M+ poly imports become a typical workflow. The
        // O(1) path is straightforward — add `int selectedXCount`
        // fields on `Mesh`, bump/decrement in `selectVertex /
        // deselectVertex / clearVertexSelection` (and the
        // matching edge / face variants), and read those here
        // directly. Risk is drift if a new selection mutator
        // forgets to maintain the counter; the linear walk is
        // the more robust default until perf demands otherwise.
        ImGui.LabelText("V", "%d/%d",
            mesh.countSelectedVertices(),
            cast(int) mesh.vertices.length);
        ImGui.LabelText("E", "%d/%d",
            mesh.countSelectedEdges(),
            cast(int) mesh.edges.length);
        ImGui.LabelText("F", "%d/%d",
            mesh.countSelectedFaces(),
            cast(int) mesh.faces.length);
    }
    ImGui.End();
    popPanelChromeStyle();
    }
}

void drawStatusBar(EditorApp app) {
    with (app) {
    pushPanelChromeStyle();
    if (testMode) {
        ImGui.SetNextWindowPos(layout.statusPos, ImGuiCond.Always);
        ImGui.SetNextWindowSize(layout.statusSize, ImGuiCond.Always);
    }
    int statusFlags = ImGuiWindowFlags.NoCollapse;
    if (testMode) statusFlags |= ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoResize | ImGuiWindowFlags.NoMove;
    if (ImGui.Begin("Status line", null, statusFlags))
    {
        pushButtonBarStyle();
        scope(exit) popButtonBarStyle();

        // Render the YAML-driven status row. Buttons live in groups
        // (`Group.title` is grouping-only — never rendered in the
        // status bar; an inter-group ImGui.Dummy gap visually
        // separates concerns). Each entry's first script line
        // determines (a) the keyboard shortcut hint via byEditMode
        // and (b) the "active" highlight, by parsing
        // `select.typeFrom <vertex|edge|polygon>` and matching
        // against the live editMode.
        import argstring : parseArgstring;
        enum float btnW         = 85.0f;
        enum float interGroupGap = 8.0f;
        bool firstButton = true;
        foreach (gi, ref grp; statusLineGroups) {
            if (gi > 0) {
                // Inter-group breathing room. Dummy + SameLine
                // sandwich keeps the next button on the same row.
                ImGui.SameLine();
                ImGui.Dummy(ImVec2(interGroupGap, 0));
            }
            foreach (bi, ref btn; grp.buttons) {
                if (!firstButton) ImGui.SameLine();
                firstButton = false;

                // ImGui derives widget IDs from label text, so when
                // modifier overrides give all three buttons the
                // same label (e.g. "Convert" while Alt is held) the
                // second and third would collapse onto the first's
                // ID and stop clicking. Use group-title + button
                // index as the PushID for stability across YAML
                // reorders.
                import std.format : format;
                ImGui.PushID(format("%s/%d", grp.title, bi));
                scope(exit) ImGui.PopID();

                // Variant select (ctrl/alt/shift) — same convention
                // as side-panel buttons. Each variant gets a unique
                // popup-id suffix so the popup outlives the user
                // releasing the modifier (see the BeginPopup loop
                // at the end of this block).
                SDL_Keymod mods = SDL_GetModState();
                string label   = btn.label;
                Action action  = btn.action;
                string variant = "";
                if      (btn.ctrl.present  && (mods & KMOD_CTRL))  {
                    label = btn.ctrl.label;  action = btn.ctrl.action;
                    variant = "_ctrl";
                }
                else if (btn.alt.present   && (mods & KMOD_ALT))   {
                    label = btn.alt.label;   action = btn.alt.action;
                    variant = "_alt";
                }
                else if (btn.shift.present && (mods & KMOD_SHIFT)) {
                    label = btn.shift.label; action = btn.shift.action;
                    variant = "_shift";
                }

                // "Popup face" behaviour. When a popup action sets
                // `dynamicLabel: true`, swap the
                // static button label for whichever item's `checked:`
                // currently resolves true. The swap only fires when
                // the BUTTON-level `checked:` resolves true — so e.g.
                // ACEN's button (checked.notEquals "none") shows the
                // active mode name when pressed and falls back to
                // "Action Center" when state == none.
                if (action.kind == ActionKind.popup && action.dynamicLabel) {
                    bool pressed = !action.checked.present
                                   || popupItemChecked(action.checked);
                    if (pressed) {
                        string s = firstCheckedLabel(action.popupItems);
                        if (s.length > 0) label = s;
                    }
                }
                // Button-level dynamicLabel — works for ANY action
                // kind (command/script/popup). Reads a state path
                // directly; if non-empty, replaces the static label.
                // No modifier-variant override (alt/ctrl/shift) —
                // those carry their own static labels that always win.
                if (btn.dynamicLabelPath.length > 0 && variant.length == 0) {
                    import popup_state : getStatePath;
                    string dyn = getStatePath(btn.dynamicLabelPath);
                    if (dyn.length > 0) label = dyn;
                }

                // Detect edit-mode actions for shortcut display +
                // on-highlight. New status-line buttons use dedicated
                // command ids; legacy script buttons are still supported
                // through select.typeFrom's first argstring line.
                string editModeId;
                if (action.kind == ActionKind.command) {
                    if      (action.id == "select.vertex")  editModeId = "vertices";
                    else if (action.id == "select.edge")    editModeId = "edges";
                    else if (action.id == "select.polygon") editModeId = "polygons";
                } else if (action.kind == ActionKind.script
                           && action.scriptLines.length > 0) {
                    auto parsed = parseArgstring(action.scriptLines[0]);
                    if (!parsed.isEmpty
                        && parsed.commandId == "select.typeFrom"
                        && "_positional" in parsed.params
                        && parsed.params["_positional"].type == JSONType.array
                        && parsed.params["_positional"].array.length > 0
                        && parsed.params["_positional"].array[0].type == JSONType.string)
                    {
                        string t = parsed.params["_positional"].array[0].str;
                        if      (t == "vertex")  editModeId = "vertices";
                        else if (t == "edge")    editModeId = "edges";
                        else if (t == "polygon") editModeId = "polygons";
                    }
                }
                string sc;
                if (editModeId.length > 0) {
                    if (auto sp = editModeId in shortcuts.byEditMode) sc = sp.display();
                }
                // Visual "pressed" state. Button-level `btn.checked`
                // wins (works for any action kind — used by toggle
                // buttons whose state lives in the pipeline, e.g.
                // Snap reflecting `snap/enabled`). Otherwise fall
                // back to: editmode match, or popup action's own
                // `checked:`.
                bool on;
                if (btn.checked.present) {
                    on = popupItemChecked(btn.checked);
                } else {
                    on = (editModeId == "vertices" && editMode == EditMode.Vertices)
                      || (editModeId == "edges"    && editMode == EditMode.Edges)
                      || (editModeId == "polygons" && editMode == EditMode.Polygons)
                      || (action.kind == ActionKind.popup
                          && action.checked.present
                          && popupItemChecked(action.checked));
                }

                string popupId = "##popup" ~ variant ~ "_" ~ btn.label;
                // Auto-grow the button when the (possibly dynamic)
                // label is wider than the default 85-px slot —
                // otherwise long ACEN modes like "Selection Center
                // Auto Axis" get clipped. CalcTextSize uses the
                // current font, plus 18 px for FramePadding (×2)
                // and a hair of slack so the text doesn't kiss the
                // border.
                float effW = btnW;
                {
                    ImVec2 ts = ImGui.CalcTextSize(label);
                    float need = ts.x + 18.0f;
                    if (need > effW) effW = need;
                }
                // "AI" master-switch button: greyed (not hidden) in
                // modeling-noai — see kAiToggleAvailable's doc comment
                // near `main`. Also greyed while the copilot is paused
                // (kCopilotEnabled=false, task 0422 — registration.d drops
                // the ai.toggle/enable/disable factories in that state, so
                // this reuses the same disabled-placeholder mechanism to
                // keep the button un-clickable rather than dispatching to a
                // now-unregistered command id). Every OTHER status-line
                // button stays as today (no other action id is gated here).
                bool aiGateBlocked = action.kind == ActionKind.command
                    && action.id == "ai.toggle"
                    && !(kAiToggleAvailable && kCopilotEnabled);
                if (renderStyledButton(label, sc, on, /*isCommand=*/true,
                                       ImVec2(effW, 0), aiGateBlocked)) {
                    final switch (action.kind) {
                        case ActionKind.tool:
                            activateToolById(action.id);
                            break;
                        case ActionKind.command:
                            if (!tryOpenArgsDialog(action.id))
                                runCommand(reg.commandFactories[action.id]());
                            if (editModeId.length > 0)
                                setActiveTool(null);
                            break;
                        case ActionKind.script:
                            // typeFrom doesn't go through the args
                            // dialog — dispatch each line via the
                            // same path as /api/command argstring
                            // bodies.
                            foreach (line; action.scriptLines) {
                                auto p2 = parseArgstring(line);
                                if (p2.isEmpty) continue;
                                if (commandHandlerDelegate !is null)
                                    commandHandlerDelegate(p2.commandId,
                                                            p2.params.toString());
                            }
                            // Activating an edit mode is conceptually
                            // a tool change — drop any sticky tool
                            // too.
                            if (editModeId.length > 0)
                                setActiveTool(null);
                            break;
                        case ActionKind.popup:
                            ImGui.OpenPopup(popupId);
                            break;
                    }
                }
                if (aiGateBlocked && ImGui.IsItemHovered())
                    ImGui.SetTooltip("Not available in this build");
                // Render BeginPopup for EVERY popup variant the
                // button declares, regardless of which is currently
                // active under the live modifier state. Without
                // this, an alt-opened popup vanishes the moment
                // the user releases Alt — BeginPopup wouldn't be
                // called for that variant on the first post-
                // release frame and ImGui closes the popup.
                void renderVariantPopup(string suf, ref Action a) {
                    if (a.kind != ActionKind.popup) return;
                    pushPopupStyle();
                    scope(exit) popPopupStyle();
                    if (ImGui.BeginPopup("##popup" ~ suf ~ "_" ~ btn.label)) {
                        renderPopupItems(app, a.popupItems);
                        ImGui.EndPopup();
                    }
                }
                renderVariantPopup("",       btn.action);
                if (btn.ctrl.present)  renderVariantPopup("_ctrl",  btn.ctrl.action);
                if (btn.alt.present)   renderVariantPopup("_alt",   btn.alt.action);
                if (btn.shift.present) renderVariantPopup("_shift", btn.shift.action);
            }
        }
    }
    ImGui.End();
    popPanelChromeStyle();
    }
}

// =============================================================================
// Phase 6 -- renderViewportSceneToFbo, the last panel entry point. Reads
// shader/checkerShader/gridShader/gridVao/gridOnlyVertCount/hover x3/
// faceSelEdgesCache+PrevSel/rebuildLoopHoverMask/litShader/gpu/mesh plus
// bgGpuByLayer [Б2] and edgeKey/countSelected/buildItemFrame [Б1] -- all
// relocated to editor_app.d in Phase 1 and imported at this module's header;
// this phase is a verbatim body move. Keeps its original 6 parameters,
// EditorApp app prepended as the first (per the plan's Phase 6 note).
// =============================================================================

// -------------------------------------------------------------------------
// Phase 2 — FBO scene render
// -------------------------------------------------------------------------
// Renders the active viewport's scene (mesh + grid + gizmos) into v.fbo.
// Called AFTER picking / hover-resolution (so hover state is current for
// this frame) and BEFORE ImGui.Render() (so the ImGui.Image draw command
// recorded inside the "Viewport" window samples the freshly-filled texture
// at RenderDrawData → same-frame content, zero latency).
//
// Captured from the outer scope: gpu, shader, litShader, checkerShader,
// gridShader, cameraView, mesh, document, activeTool, pipeGizmoHost,
// hoveredVertex/Edge/Face, faceSelEdgesCache/PrevSel, editMode, bgGpuByLayer,
// gridVao, gridOnlyVertCount, g_pipeCtx, etc.
void renderViewportSceneToFbo(EditorApp app, Viewport3D v, ref Viewport vp,
                               OverlayMode overlayMode,
                               bool showVertHover, bool showEdgeHover,
                               bool showFaceHover) {
    with (app) {
    import bindbc.opengl;

    // Bind FBO — scene draws go here instead of the default framebuffer.
    // Viewport covers the entire FBO (offsets zeroed: FBO origin IS the
    // viewport corner).
    glBindFramebuffer(GL_FRAMEBUFFER, v.fbo.fbo);
    glViewport(0, 0, v.fbo.w, v.fbo.h);
    // Per-cell thick-line screen size. g_thickLine.screenW/H is now a
    // per-cell scratch: each cell sets its own FBO size here before its
    // overlay gizmos draw, so the geometry-shader line extrusion is
    // always correct for the current cell (not the full window).
    setThickLineScreenSize(v.fbo.w, v.fbo.h);

    glClearColor(0.36f, 0.40f, 0.42f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    // Per-item (per-layer) transform — RENDER-ONLY (channels P4). Feed-site #1.
    float[16] itemMatrix = document.primary.xform.composedMatrix();
    float[16] meshModel  = itemMatrix;
    {
        TransformTool tt = cast(TransformTool)activeTool;
        if (tt !is null)
            meshModel = matMul4(itemMatrix, tt.gpuMatrix);
    }

    shader.useProgram(meshModel, vp);

    // Deliberately UNINSTRUMENTED in v1 (task 0196): the grid +
    // symmetry-plane draws below (tiny constant cost) and the
    // background-layer faces/edges loop further down (skipped entirely
    // when document.layers.length == 1) have no Cat timer — a choice,
    // not an omission. If wanted later, background faces fold into
    // Cat.drawMesh and background edges into Cat.drawEdges.
    // ---- Grid axis lines (alpha-blended, distance + edge fade) ----
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    float[16] gridModel = identityMatrix;
    if (auto wp = cast(WorkplaneStage)g_pipeCtx.pipeline.findByTask(TaskCode.Work)) {
        if (!wp.isAuto) {
            Vec3 n, a1, a2;
            wp.currentBasis(n, a1, a2);
            Vec3 c = wp.center;
            gridModel = [
                a1.x, a1.y, a1.z, 0,
                n.x,  n.y,  n.z,  0,
                a2.x, a2.y, a2.z, 0,
                c.x,  c.y,  c.z,  1,
            ];
        }
    }
    // Width/height in PIXELS = FBO dims; offsets zeroed (FBO origin = corner).
    gridShader.useProgram(gridModel, vp,
        v.camera.distance * 2.0f,
        cast(float)v.fbo.w, cast(float)v.fbo.h,
        0.0f, 0.0f);
    glBindVertexArray(gridVao);
    glUniform3f(gridShader.locColor, 0.5f, 0.5f, 0.5f);
    glDrawArrays(GL_LINES, 0, gridOnlyVertCount);
    glUniform3f(gridShader.locColor, 0.5f, 0.15f, 0.15f);
    glDrawArrays(GL_LINES, gridOnlyVertCount, 2);
    glUniform3f(gridShader.locColor, 0.15f, 0.15f, 0.5f);
    glDrawArrays(GL_LINES, gridOnlyVertCount + 2, 2);
    glBindVertexArray(0);

    // ---- Symmetry plane ----
    {
        import toolpipe.stages.symmetry : SymmetryStage;
        auto sym = cast(SymmetryStage)
                   g_pipeCtx.pipeline.findByTask(TaskCode.Symm);
        if (sym !is null && sym.enabled) {
            Vec3 n, a1, a2;
            Vec3 c;
            if (sym.useWorkplane) {
                if (auto wpst = cast(WorkplaneStage)
                                g_pipeCtx.pipeline.findByTask(TaskCode.Work)) {
                    wpst.currentBasis(n, a1, a2);
                    c = wpst.center;
                } else {
                    n = Vec3(0, 1, 0); a1 = Vec3(1, 0, 0); a2 = Vec3(0, 0, 1);
                }
            } else {
                final switch (sym.axisIndex) {
                    case 0:
                        n  = Vec3(1, 0, 0);
                        a1 = Vec3(0, 1, 0); a2 = Vec3(0, 0, 1);
                        c  = Vec3(sym.offset, 0, 0); break;
                    case 1:
                        n  = Vec3(0, 1, 0);
                        a1 = Vec3(1, 0, 0); a2 = Vec3(0, 0, 1);
                        c  = Vec3(0, sym.offset, 0); break;
                    case 2:
                        n  = Vec3(0, 0, 1);
                        a1 = Vec3(1, 0, 0); a2 = Vec3(0, 1, 0);
                        c  = Vec3(0, 0, sym.offset); break;
                }
            }
            float[16] symModel = [
                a1.x, a1.y, a1.z, 0,
                n.x,  n.y,  n.z,  0,
                a2.x, a2.y, a2.z, 0,
                c.x,  c.y,  c.z,  1,
            ];
            gridShader.useProgram(symModel, vp,
                v.camera.distance * 2.0f,
                cast(float)v.fbo.w, cast(float)v.fbo.h,
                0.0f, 0.0f);
            glBindVertexArray(gridVao);
            glUniform3f(gridShader.locColor, 0.85f, 0.5f, 0.15f);
            glDrawArrays(GL_LINES, 0, gridOnlyVertCount);
            glBindVertexArray(0);
        }
    }

    glDisable(GL_BLEND);

    // ---- Background layers ----
    if (document.layers.length > 1) {
        import std.math : isNaN;
        Layer[] toDrop;
        foreach (lyr, bg; bgGpuByLayer) {
            bool stillBg = false;
            foreach (ll; document.layers)
                if (ll is lyr && ll.visible && !document.isPrimary(ll)) {
                    stillBg = true;
                    break;
                }
            if (!stillBg) toDrop ~= lyr;
        }
        foreach (lyr; toDrop) {
            bgGpuByLayer[lyr].gpu.destroy();
            bgGpuByLayer.remove(lyr);
        }

        enum float kBgDim = 0.45f;
        foreach (i, lyr; document.layers) {
            if (document.isPrimary(lyr) || !lyr.visible) continue;
            float[16] bgModel = lyr.xform.composedMatrix();

            auto pp = lyr in bgGpuByLayer;
            BgGpu* bg;
            if (pp is null) {
                bg = new BgGpu;
                bg.gpu.init();
                bgGpuByLayer[lyr] = bg;
            } else {
                bg = *pp;
            }
            if (bg.uploadedVersion != lyr.mesh.mutationVersion) {
                bg.gpu.upload(lyr.mesh);
                bg.uploadedVersion = lyr.mesh.mutationVersion;
            }

            litShader.useProgram(bgModel, vp);
            litShader.setSurfaces(lyr.mesh.surfaces);
            litShader.setDim(kBgDim);
            bg.gpu.drawFaces(litShader);
            litShader.setDim(1.0f);

            shader.useProgram(bgModel, vp);
            shader.setDim(kBgDim);
            bg.gpu.drawEdges(shader.locColor, -1, []);
            shader.setDim(1.0f);
        }
    }

    // Install background snap sources (layers Stage 5).
    {
        import snap : setBackgroundSnapSources;
        import document : Document;
        const(Mesh)*[] snapSrc;
        if (document.layers.length > 1) {
            foreach (lyr; document.layers) {
                if (Document.background(lyr))
                    snapSrc ~= cast(const(Mesh)*)&lyr.mesh;
            }
        }
        setBackgroundSnapSources(snapSrc);
    }
    // Install item snap frames (Stage 3).
    {
        import snap : setItemSnapFrames, ItemSnapFrame;
        ItemSnapFrame[] itemFrames;
        foreach (lyr; document.layers) {
            if (!lyr.visible) continue;
            itemFrames ~= buildItemFrame(lyr);
        }
        setItemSnapFrames(itemFrames);
    }

    // ---- Faces (Blinn-Phong) ----
    {
        auto zMesh = g_perf.scope_(Cat.drawMesh);
        litShader.useProgram(meshModel, vp);
        litShader.setSurfaces(mesh.surfaces);
        bool toolFaceHover = activeTool !is null
                          && activeTool.wantsHoverForType(EditMode.Polygons)
                          && hoveredFace >= 0;
        if (editMode == EditMode.Polygons) {
            gpu.drawFacesHighlighted(litShader, hoveredFace, mesh.selectedFaces);
        } else if (toolFaceHover) {
            gpu.drawFacesHighlighted(litShader, hoveredFace, (bool[]).init);
        } else {
            gpu.drawFaces(litShader);
        }
    }

    // Checkerboard overlay for selected faces (Polygons mode).
    if (editMode == EditMode.Polygons) {
        if (mesh.hasAnySelectedFaces()) {
            auto zOv = g_perf.scope_(Cat.drawOverlays);
            checkerShader.useProgram(meshModel, vp, 1.0f, 0.5f, 0.1f);
            glDisable(GL_DEPTH_TEST);
            gpu.drawSelectedFacesOverlay(mesh.selectedFaces);
            glEnable(GL_DEPTH_TEST);
        }
    }

    shader.useProgram(meshModel, vp);

    // ---- Edges ----
    {
        auto zEdges = g_perf.scope_(Cat.drawEdges);
        if (editMode == EditMode.Edges) {
            // A tool can pre-highlight the WHOLE ring it will act on: Loop
            // Slice shows the ring its cut will land on (via wantsEdgeLoop-
            // Hover + rebuildLoopHoverMask). And while that tool DRAGS, the
            // per-frame edge picker is frozen (pickEdges early-returns on
            // isDragging), so `hoveredEdge` keeps a stale numeric index that
            // now aliases an unrelated edge once the tool's mutate/revert
            // preview rebuilds the edge array — highlighting it would light
            // a random edge far from the cursor (task 0231). Suppress the
            // single-edge hover then; the live cut geometry already shows
            // what will happen. Task 0232 widens this suppression to
            // ALSO cover an ARMED (but not currently dragging) Loop Slice
            // standing preview: `isDragging()` alone (== `scrubbing_`)
            // goes false the instant the mouse releases, but the
            // preview's edge array keeps getting rebuilt on every HUD/
            // panel scrub while armed — so the same frozen-numeric-index
            // aliasing risk applies for the WHOLE armed period, not just
            // the held-drag sub-window. `hasUncommittedEdit()` (==
            // `armed_` for this tool) is the generic, already-existing
            // Tool hook for exactly this "an uncommitted edit is live"
            // condition — every other tool defaults it to false, so this
            // is a no-op change for them.
            int          hovForDraw = hoveredEdge;
            const(bool)[] loopMask  = (bool[]).init;
            if (activeTool !is null) {
                if (activeTool.isDragging() || activeTool.hasUncommittedEdit())
                    hovForDraw = -1;
                else if (activeTool.wantsEdgeLoopHover()
                         && showEdgeHover && hoveredEdge >= 0)
                    loopMask = rebuildLoopHoverMask(hoveredEdge);
            }
            gpu.drawEdges(shader.locColor, hovForDraw, mesh.selectedEdges, loopMask);
        } else if (editMode == EditMode.Polygons) {
            if (faceSelEdgesPrevSel != mesh.selectedFaces) {
                faceSelEdgesPrevSel = mesh.selectedFaces.dup;
                if (faceSelEdgesCache.length != mesh.edges.length)
                    faceSelEdgesCache = new bool[](mesh.edges.length);
                faceSelEdgesCache[] = false;

                bool allSel = (countSelected(mesh.selectedFaces) == cast(int)mesh.selectedFaces.length);
                if (allSel) {
                    faceSelEdgesCache[] = true;
                } else {
                    if (mesh.hasAnySelectedFaces()) {
                        bool[ulong] edgeSet;
                        foreach (fi, face; mesh.faces) {
                            if (!mesh.isFaceSelected(fi)) continue;
                            foreach (e; mesh.faceEdges(cast(uint)fi))
                                edgeSet[edgeKey(e.a, e.b)] = true;
                        }
                        foreach (ei, edge; mesh.edges) {
                            if (edgeKey(edge[0], edge[1]) in edgeSet)
                                faceSelEdgesCache[ei] = true;
                        }
                    }
                }
            }
            gpu.drawEdges(shader.locColor, -1, faceSelEdgesCache);

            // Task 0399: Loop Slice ring-preview in Polygons mode. The
            // Edges-mode branch above previews the ring through
            // `hoveredEdge` (`wantsEdgeLoopHover` + `rebuildLoopHoverMask`),
            // but Polygons mode never sets a hovered EDGE — only
            // hovered/selected FACES — so that seed doesn't exist here.
            // Loop Slice's Polygons activation instead seeds from the
            // shared/interior edge(s) of the selected faces (task 0245:
            // `activationSeeds`/`interiorEdgesOfSelectedFaces`), so the
            // preview is built from THAT via the tool's own
            // `selectionRingPreviewMask()` helper (mirrors
            // `rebuildLoopHoverMask`'s sliceRing branch, but unioned over
            // every seed instead of a single hovered edge). Same
            // arm/drag suppression as the Edges branch —
            // `wantsEdgeLoopHover()` goes false while armed, and
            // `isDragging()`/`hasUncommittedEdit()` belt-and-suspenders
            // it — the live cut geometry already shows the result once
            // armed; a stale ring overlay would just be noise. Gated on
            // `hasAnySelectedFaces()` so an empty selection draws
            // nothing extra (no wasted redraw pass). Other Polygons-mode
            // tools are unaffected: `wantsEdgeLoopHover()` defaults false
            // on the `Tool` base, so this block is a no-op for them.
            if (activeTool !is null
                && activeTool.wantsEdgeLoopHover()
                && !(activeTool.isDragging() || activeTool.hasUncommittedEdit())
                && mesh.hasAnySelectedFaces()) {
                if (auto lst = cast(LoopSliceTool) activeTool) {
                    const(bool)[] loopSelMask = lst.selectionRingPreviewMask();
                    gpu.drawEdges(shader.locColor, -1, mesh.selectedEdges, loopSelMask);
                }
            }
        } else if (showEdgeHover && hoveredEdge >= 0) {
            const bool[] loopMask =
                (activeTool !is null && activeTool.wantsEdgeLoopHover())
                    ? rebuildLoopHoverMask(hoveredEdge)
                    : (bool[]).init;
            gpu.drawEdges(shader.locColor, hoveredEdge, [], loopMask);
        } else {
            gpu.drawEdges(shader.locColor, -1, []);
        }
    }

    // ---- Vertex dots ----
    if (editMode == EditMode.Vertices) {
        auto zOv = g_perf.scope_(Cat.drawOverlays);
        gpu.drawVertices(shader.locColor, hoveredVertex, mesh.selectedVertices);
    } else if (showVertHover && hoveredVertex >= 0) {
        auto zOv = g_perf.scope_(Cat.drawOverlays);
        gpu.drawVertices(shader.locColor, hoveredVertex, (bool[]).init);
    }

    // ---- Active tool / falloff gizmo draws ----
    // Task 0206 (Quad/Split multi-cell overlays): `overlayMode` decides
    // WHICH cells draw and HOW:
    //   - None:        nothing (no tool/falloff active for this cell's
    //                   call, or a non-eligible tool — see the N-cell
    //                   loop's `_multiCellEligible` gate).
    //   - Interactive: the overlay-owner (origin cell during a drag,
    //                   else the active cell) — today's exact path,
    //                   visualOnly=false. Pins cachedVp + runs the
    //                   arbiter cycle; this is the primary Step-B
    //                   freeze mechanism for multi-viewport drag
    //                   correctness.
    //   - Visual:      every OTHER live cell, when the active tool/
    //                   falloff is multi-cell-eligible (v1: XfrmTransformTool
    //                   + CommandWrapperTool + no-tool falloff — see
    //                   doc/quad_overlays_all_cells_plan.md). Draws the
    //                   SAME world-derived gizmo geometry reprojected
    //                   under THIS cell's vp with visualOnly=true — no
    //                   cachedVp / ToolHandles writes, so this cell's
    //                   draw cannot corrupt the owner cell's
    //                   interaction state (see Tool.draw's doc comment).
    // NOTE: activeTool.update() already ran ONCE in the main loop
    // (against the origin snapshot) before this function is called for
    // any cell this frame, so handle-hover state is current for all of
    // them.
    if (overlayMode != OverlayMode.None) {
        // Cat.drawOverlays (enum) — distinct from the OverlayMode param
        // gating this block; the `Cat.` qualifier disambiguates for the
        // human reader (compiler never confuses them).
        auto zOv = g_perf.scope_(Cat.drawOverlays);
        bool visualOnly = (overlayMode == OverlayMode.Visual);
        if (activeTool) {
            SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts);
            activeTool.draw(shader, vp, vts, visualOnly);
        } else if (anyFalloffActive()) {
            import toolpipe.packets : FalloffPacket;
            SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts);
            FalloffPacket fp;
            if (auto p = vts.get!FalloffPacket()) fp = *p;
            if (fp.enabled)
                pipeGizmoHost.draw(shader, vp, fp, pipeGizmoHost.ownPool(), visualOnly);
        }
    }

    // ---- AI Modeling Copilot: ghost highlight of the active finding
    // (task 0402 Phase 3, doc/ai_copilot_plan.md) ----
    // Passive-only: this draws, nothing else — see copilot_overlay.d's
    // doc comment. Gated on all three: the AI master switch, the
    // "AI Findings" panel actually being shown (same visibility
    // predicate as the panel's own draw call below — a hidden panel's
    // stale active index shouldn't paint a ghost nobody can see the
    // list for), and a valid `active()` index into the CURRENT findings
    // list (out-of-range/-1, e.g. right after copilot.analyze before
    // any row was clicked, draws nothing). AI-off (or modeling-noai,
    // where the master switch never turns on) ⇒ byte-identical to
    // before this phase — same discipline as every other AI-gated draw
    // in this codebase (doc/ai_model_adapter_live_wiring_plan.md).
    // version(WithAI)-only — the whole findings panel/overlay is
    // compiled out of modeling-noai (see import block doc comment).
    // static if kCopilotEnabled (task 0422): ghost overlay skipped while
    // the copilot is paused; flip the flag to restore.
    version (WithAI)
    static if (kCopilotEnabled)
    {
        immutable bool panelShown = !command.g_testMode || g_copilotPanelShown;
        if (aiState.enabled && panelShown) {
            immutable int activeIdx = copilotPanel.active();
            const findings = copilotPanel.findings();
            if (activeIdx >= 0 && activeIdx < cast(int) findings.length)
                drawCopilotFindingOverlay(mesh(), findings[activeIdx], vp, shader.program);
        }
    }

    // Restore default framebuffer.
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }
}
