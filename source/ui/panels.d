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
import perf_probe : g_fc, DrawPass;  // always-on per-frame work counters
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
import viewgrid : g_viewGrid, viewGridSizeFor, viewGridFadeRadius;
import shader;
import viewcache;
import perf_probe : g_perf, Cat, g_frames, Phase, FrameRec, FrameStatsSnapshot;
import io.assimp_runtime : initAssimp, shutdownAssimp, isAssimpAvailable;
// Task 0669 — "would this action refuse if pressed", and the per-frame record
// of what the bars actually drew. See source/ui/availability.d.
import ui.availability : actionRefusal, recordDrawnButton;
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
import commands.layer.commands : LayerAttr, layerDeleteButtonState;
import ui.image_rows : ImageRow, imageRowsInto, imageRemoveTarget,
                       imageRemoveConfirmText, elidedPathText, kNoImagesText;
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
    Ai3dInstallState, ai3dDefaultInstallLocation, ai3dDefaultWorkerUrl;
import core.time : MonoTime;  // phase-B drawAi3dModal: MonoTime.currTime health-poll throttle
import commands.ai3d.import_result : Ai3dImportResult;
import remesh.remesh_job         : RemeshJob, RemeshParams,
    MAX_REMESH_TARGET_QUADS, MIN_REMESH_TARGET_QUADS;
import commands.mesh.remesh      : Remesh, RemeshStart, RemeshOpen;
import property_panel : PropertyPanel;
import forms_render;
import layer_params   : LayerPropsProvider, itemPropsTarget;
import document       : Layer, Document, kindInfo, tokenOf;
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

        // Display: surface style + wireframe overlay, for the ACTIVE cell.
        //
        // Task 0559. This panel is the home for it rather than a widget
        // inside the viewport cell itself, and that is a deliberate hold, not
        // an oversight: the cell already hosts a view-preset combo at its top
        // left, and adding a second permanent dropdown beside it changes what
        // every 3D viewport LOOKS LIKE for everyone. That is the owner's call
        // to make, so it is written up rather than shipped. This panel is
        // already the place viewport settings live, it is opt-in under
        // --test, and it adds no viewport chrome at all.
        //
        // Only the values a render pass actually consumes are offered. The
        // enums are wider; the commands refuse the rest by name.
        ImGui.Dummy(ImVec2(0, 2));
        ImGui.SeparatorText("Active Cell Display");
        {
            import display_state : DisplayStyle, WireOverlay;
            import std.format : format;

            static immutable string[3] styleLabels = ["Shaded", "Solid", "Wireframe"];
            static immutable string[3] styleIds    = ["shaded", "solid", "wireframe"];
            static immutable DisplayStyle[3] styleVals =
                [DisplayStyle.Shaded, DisplayStyle.Solid, DisplayStyle.Wireframe];

            int si = 0;
            foreach (i, sv; styleVals) if (sv == v.display.active.style) si = cast(int)i;
            ImGui.Text("Style");
            ImGui.SameLine();
            ImGui.SetNextItemWidth(-1.0f);
            if (ImGui.BeginCombo("##vpDisplayStyle", styleLabels[si])) {
                foreach (i, sl; styleLabels) {
                    bool sel = (i == si);
                    if (ImGui.Selectable(sl, sel) && commandHandlerDelegate !is null)
                        commandHandlerDelegate("viewport.displayStyle",
                            `{"_positional":["` ~ styleIds[i] ~ `"]}`);
                    if (sel) ImGui.SetItemDefaultFocus();
                }
                ImGui.EndCombo();
            }

            static immutable string[2] wireLabels = ["Uniform", "None"];
            static immutable string[2] wireIds    = ["uniform", "none"];
            static immutable WireOverlay[2] wireVals =
                [WireOverlay.Uniform, WireOverlay.None];

            int wi = 0;
            foreach (i, wv; wireVals) if (wv == v.display.active.wire) wi = cast(int)i;
            ImGui.Text("Wire");
            ImGui.SameLine();
            ImGui.SetNextItemWidth(-1.0f);
            if (ImGui.BeginCombo("##vpWireOverlay", wireLabels[wi])) {
                foreach (i, wl; wireLabels) {
                    bool sel = (i == wi);
                    if (ImGui.Selectable(wl, sel) && commandHandlerDelegate !is null)
                        commandHandlerDelegate("viewport.wireOverlay",
                            `{"_positional":["` ~ wireIds[i] ~ `"]}`);
                    if (sel) ImGui.SetItemDefaultFocus();
                }
                ImGui.EndCombo();
            }

            float wa = v.display.active.wireAlpha;
            ImGui.SetNextItemWidth(-1.0f);
            if (ImGui.SliderFloat("##vpWireAlpha", &wa, 0.0f, 1.0f, "Opacity %.2f")) {
                // Clamped HERE, not trusted from the widget: a slider's
                // ctrl-click text entry can return a value outside its own
                // range, and the command rejects out-of-range input (it does
                // not clamp) — so an unclamped write would surface as a
                // thrown command from a drag of a UI slider.
                if (wa < 0.0f) wa = 0.0f;
                if (wa > 1.0f) wa = 1.0f;
                if (commandHandlerDelegate !is null)
                    commandHandlerDelegate("viewport.wireAlpha",
                        `{"_positional":[` ~ format("%.6f", wa) ~ `]}`);
            }
        }

        // Grid: the mantissa ladder the zoom-derived step may land on.
        //
        // Task 0570. APPLICATION-WIDE, unlike everything above it in this
        // panel — the grid step is derived from each cell's own zoom, so the
        // only thing there is to configure is which rungs it may land on.
        // Housed here rather than in a new Preferences window because this
        // panel is already where viewport settings live and this is the only
        // grid setting there is.
        ImGui.Dummy(ImVec2(0, 2));
        ImGui.SeparatorText("Grid Steps");
        {
            import viewgrid : g_viewGrid, gridRungs, kGridMaskMin, kGridMaskMax;
            import std.format : format;

            // Labelled by the SET, not by the mask number: "1, 2, 5, 10" is
            // what the user sees on screen; "5" is an implementation detail
            // that happens to be the persisted form.
            static string rungLabel(int mask) {
                string s;
                foreach (v; gridRungs(mask)) {
                    if (s.length) s ~= ", ";
                    s ~= (v == cast(double)cast(long)v)
                         ? format("%d", cast(long)v) : format("%.1f", v);
                }
                return s;
            }

            ImGui.SetNextItemWidth(-1.0f);
            if (ImGui.BeginCombo("##vpGridSteps", rungLabel(g_viewGrid.rungMask))) {
                foreach (m; kGridMaskMin .. kGridMaskMax + 1) {
                    bool sel = (m == g_viewGrid.rungMask);
                    if (ImGui.Selectable(rungLabel(m), sel)
                        && commandHandlerDelegate !is null)
                        commandHandlerDelegate("viewport.gridSteps",
                            `{"_positional":[` ~ format("%d", m) ~ `]}`);
                    if (sel) ImGui.SetItemDefaultFocus();
                }
                ImGui.EndCombo();
            }
        }

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
// drawAboutPanel -- what this binary is (task 0641)
//
// Deliberately NOT a splash: no logo, no credits, no modal. It is the four
// facts a bug report needs — version, build configuration, platform, build
// date — plus a Copy button so they reach the report as text instead of being
// retyped from a screenshot.
//
// The rows come from `app_version.appAboutLines` and nothing else. This
// function formats no version string of its own, because a second string is
// exactly how a UI starts telling a different story from `--version`: it does
// not drift on the day it is written, it drifts on the day one of the two is
// bumped. The same array is what `--version` prints and what `/api/version`
// serves, and tests/test_app_version.d compares the terminal against the
// served copy to keep that true.
//
// On-demand: hidden until `ui.about show` (File → About…). The window's own
// close box writes straight back through `&g_aboutShown`.
// =============================================================================
void drawAboutPanel(EditorApp app) {
    with (app) {
    import app_version : appAboutLines;
    import commands.ui.about : g_aboutShown;

    pushPanelChromeStyle();
    // AlwaysAutoResize: the window is exactly as big as the facts in it.
    if (ImGui.Begin("About", &g_aboutShown, ImGuiWindowFlags.AlwaysAutoResize)) {
        // TextUnformatted, never Text-as-format — these rows are data, and a
        // stray `%` in a future one must not be read as a conversion.
        foreach (line; appAboutLines)
            ImGui.TextUnformatted(line);

        ImGui.Dummy(ImVec2(0, 4));
        if (ImGui.Button("Copy")) {
            import std.array : join;
            ImGui.SetClipboardText(appAboutLines.join("\n"));
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
// Interactive item manager: a scene ROOT row naming the document, then one
// indented row per `document.layers` that `kindInfo(kind).isSceneItem` (task
// 0616 Stage 2) — a document RESOURCE kind (e.g. an image) is skipped here;
// it lives only in its own panel.
//
// WHAT IS DRAWN HERE AND WHAT IS DECIDED ELSEWHERE (task 0639). Every
// assertable thing about this list — which rows exist, in what order, at what
// indent depth, what each row is named, which glyph it draws, its role in the
// item selection, whether it is greyed, and the `Document.layers` index each
// row dispatches against — is `ui/item_rows.d`'s `itemRowsInto`, behind
// in-module tests. This body is layout and dispatch only, following
// `ui/image_rows.d`'s split exactly, and for the reason that module states: an
// ImGui panel body cannot be driven headlessly, so an assertion written
// against it can only ever say "the function ran".
//
// Per row:
//   - an EYE cell            → `layer.setVisible index:N value:b`
//   - a ROLE cell            → `layer.select index:N mode:set|toggle`
//     (filled diamond = mesh edit target, hollow = item-selection focus,
//     dot = plain foreground membership, empty = derived background)
//   - a TYPE glyph + the name selectable → `layer.select` / rename / reorder
// plus an "Add Item" drop-down (`layer.add` / `imagePlane.add`, from
// `kAddItemChoices`) and a "Delete" button (`layer.delete index:N`, targeting
// the item-selection FOCUS — see `layerDeleteButtonState` — disabled when
// deleting it would leave no layer able to be the mesh edit target; the
// command refuses that regardless, this just greys the affordance).
//
// WHAT THE REFERENCE SHAPE HAS THAT THIS DOES NOT, and why (task 0639):
//   * a THIRD narrow column. We hold two per-row states a cell can toggle —
//     visibility and selection role — and nothing behind a third. A narrow
//     empty column is decoration, and this panel is explicitly not allowed to
//     draw one.
//   * "Select" and "Filter" buttons. The screenshot shows that they exist and
//     not what they do; a button whose behaviour is unknown ships as a dead
//     affordance.
//   * the TAB STRIP along the top. Those are sibling dockable panels, and
//     ImGui makes co-docked windows into tabs by itself — this app already
//     docks its viewports. Nothing to build, and emphatically NOT the
//     hand-rolled `Selectable`+`SameLine` strip app.d uses for tool
//     properties (this binding exposes no `BeginTabBar`): docking tabs are a
//     different mechanism from the tab-bar widget.
//   * per-ITEM collapse. Only the root collapses, because that is the only
//     expansion state the row model holds; a triangle on a parent item would
//     be a control with nothing behind it.
//
// EVERY interaction dispatches through commandHandlerDelegate — the same
// path /api/command uses — so undo/history/coalescing all work. The panel
// NEVER mutates `document` directly. It is pure UI: no toolpipe, no mesh.
//
// ~~Task 0615 Stage 6: the panel renders correctly WHEN a non-mesh item is
// present (row marker, kind badge, delete-guard) — but there is still no
// button/menu/command-argument through which a user can CREATE one in this
// slice (the `.v3d` format cannot yet persist it; see
// doc/nonmesh_item_types_plan.md §Stage 6). Only a test can put one in the
// live document (the `/api/test/layer` injector, http_providers.d).~~
//
// SUPERSEDED (task 0612 Stage 7). The "+Plane" button below is the first
// user-reachable creation route for a non-mesh kind, and the ban's stated
// premise — that the format could not persist one — is gone: v8 writes and
// reads a non-mesh item's type token, name, visibility, transform and links.
// ~~The premise is gone for the ENVELOPE only … the reader constructs a
// payload object for `hasMesh` and `hasImage` and for no other capability, so
// a reloaded plane's own ten channels come back at their defaults.~~
//
// CLOSED (task 0612 Stage 9). That was true when Stage 7 wrote it and is the
// defect Stage 9 was for: the reader's payload block also constructs the
// object the channel injection binds into, and it grew its `hasImagePlane`
// arm. The round-trip is complete — envelope AND channels AND the clip link,
// pinned by `tests/test_v3d_image_plane.d`, with `kV3dFormatVersion` still 8.
//
// Empty-kind items are still uncreatable, and deliberately: `ItemKind.Empty`
// has no channels, no payload and nothing to draw, so a button for it would
// add a row a user can do nothing with.
//
// Visibility mirrors Tool Properties: always shown in a normal run; in
// --test it is HIDDEN by default (so it cannot capture viewport drags) and
// is only drawn when `ui.layerList show` set g_layerListShown.
void drawLayerListPanel(EditorApp app) {
    with (app) {
    import std.json : JSONValue;
    import std.conv : to;
    import std.string : fromStringz;
    import ui.item_rows   : ItemRow, ItemGlyph, RowRole, RowColor, itemRowsInto,
                            kAddItemChoices;
    import ui.item_glyphs : drawItemGlyph, drawEyeGlyph, drawRoleGlyph,
                            drawDisclosure, kGlyphCellRatio,
                            kGlyphRadiusRatio, kIndentRatio;
    import io.doc_state   : currentDocPath, docDirty;

    pushPanelChromeStyle();
    // SetNextWindowPos/Size dropped — the dock slot controls position;
    // DockBuilderDockWindow("Layers", rightId) pre-assigns the window.
    //
    // "Items###Layers" (task 0639): everything before "###" is the TITLE ImGui
    // draws on the tab, everything after it is the ID ImGui hashes. The dock
    // ini and app.d's three `DockBuilderDockWindow("Layers", …)` calls key off
    // that id, so the visible name can change without orphaning a single
    // user's saved layout — which a plain rename to `Begin("Items")` would do,
    // silently, to everyone.
    if (ImGui.Begin("Items###Layers")) {
        // ---- Metrics -----------------------------------------------------
        // Derived from the ROW HEIGHT rather than written as pixel constants:
        // that height already carries the UI scale and the font swap between
        // a normal run and --test, so the cells track both for free.
        // `GetFontSize()` IS ImGui's text line height (`GetTextLineHeight`
        // returns exactly that, and this binding does not expose the latter).
        // Using it keeps every cell the same height as the name text, so the
        // glyphs sit on the text's own baseline band rather than near it.
        immutable float rowH    = ImGui.GetFontSize();
        immutable float cellW   = rowH * kGlyphCellRatio;
        immutable float gRad    = rowH * kGlyphRadiusRatio;
        immutable float indentW = rowH * kIndentRatio;

        // The panel runs on a LIGHT grey background (143,143,143) with
        // ImGuiCol.Text pushed to black (pushPanelChromeStyle), so these are
        // dark-on-light literals — ImGui's own semi-transparent greys read as
        // washed out here, which is the same reason the old row marker used a
        // literal shade. Packed by hand because this binding exposes no
        // `GetColorU32`.
        immutable uint inkCol  = IM_COL32(0,  0,  0,  255);  // ordinary row
        immutable uint hintCol = IM_COL32(77, 77, 77, 255);  // column header
        immutable uint offCol  = IM_COL32(97, 97, 97, 255);  // hidden / greyed

        // The ROW colours are not decided here (task 0672). `ItemRow.look`
        // carries them, because a colour chosen inside this function has no
        // headless observable — the same argument that put the row CONTENT in
        // `ui/item_rows.d`. This packs, and packing is all it does.
        static uint packed(RowColor c) {
            return IM_COL32(c.r, c.g, c.b, c.a);
        }

        // ---- "Add Item" (one drop-down) + Delete -------------------------
        // ONE button with a list, not one button per kind. With the plane
        // creation route there were already two, and a button per future kind
        // turns this row into a wall; the drop-down names each outcome in
        // words instead.
        {
            immutable float availW  = ImGui.GetContentRegionAvail().x;
            immutable float spacing = ImGui.GetStyle().ItemSpacing.x;
            // The frame height, exactly: this binding has no `GetFrameHeight`,
            // but `GetFrameHeightWithSpacing` is that plus ItemSpacing.y and
            // both terms are reachable.
            immutable float frameH  = ImGui.GetFrameHeightWithSpacing()
                                    - ImGui.GetStyle().ItemSpacing.y;
            immutable float arrowW  = frameH;                 // a square button
            // Deliberately an OVER-estimate of the Delete button's own width:
            // `ImGuiStyle` exposes only ItemSpacing here, so FramePadding.x
            // cannot be read, and one frame height is comfortably more than
            // the two paddings it stands in for. Over-estimating only makes
            // "Add Item" a few pixels narrower; under-estimating would wrap
            // the row.
            immutable float delW = ImGui.CalcTextSize("Delete").x + frameH;
            float addW = availW - arrowW - delW - spacing * 2.0f;
            immutable float addMin = rowH * 3.0f;
            if (addW < addMin) addW = addMin;   // never collapse to nothing

            // Both halves open the same menu: the label is not a separate
            // "add the default kind" action, because there is no default kind
            // — a button whose click did something different from its own
            // arrow is exactly the ambiguity the single menu removes.
            //
            // The arrow is a bare button with a triangle drawn over its rect:
            // this binding has no `ArrowButton`, and drawing it ourselves also
            // keeps it the same triangle the root row's disclosure uses.
            bool openMenu = false;
            if (ImGui.Button("Add Item", ImVec2(addW, 0.0f))) openMenu = true;
            ImGui.SameLine(0.0f, 0.0f);
            if (ImGui.Button("##additem_open", ImVec2(arrowW, 0.0f)))
                openMenu = true;
            {
                immutable ImVec2 amin = ImGui.GetItemRectMin();
                immutable ImVec2 amax = ImGui.GetItemRectMax();
                drawDisclosure(ImGui.GetWindowDrawList(),
                    ImVec2((amin.x + amax.x) * 0.5f, (amin.y + amax.y) * 0.5f),
                    gRad, /*expanded=*/true, inkCol);
            }
            if (openMenu) ImGui.OpenPopup("##additem_menu");

            ImGui.SameLine();
            // ---- Delete button ----
            // Targets `document.focusedItem` — the item-selection FOCUS, i.e.
            // the row the panel highlights as current — NOT
            // `document.activeIndex`/`primary`. Task 0615 Stage 6 review round
            // 2, BLOCKER 2: a non-mesh row can be the focus without ever
            // becoming primary (§L2), and the old code always dispatched
            // against the primary regardless of which row was highlighted — so
            // clicking a highlighted non-mesh row and pressing Delete silently
            // deleted the (different, unhighlighted) primary instead.
            // `layerDeleteButtonState` (commands/layer/commands.d) is the SAME
            // function driving both the enabled/disabled guard AND the
            // dispatched index, so the two can never disagree the way the
            // primary-vs-focus split did.
            auto delState = layerDeleteButtonState(&document());
            ImGui.BeginDisabled(!delState.enabled);
            if (ImGui.Button("Delete")) {
                if (delState.enabled && commandHandlerDelegate !is null)
                    commandHandlerDelegate("layer.delete",
                        `{"index":` ~ to!string(delState.index) ~ `}`);
            }
            ImGui.EndDisabled();

            // The entries, their labels and above all the command ids they
            // dispatch are `ui/item_rows.d`'s `kAddItemChoices`, whose tests
            // compare each id against the command class's own `name()` — a
            // typo in a dispatch string is otherwise a button that silently
            // does nothing.
            if (ImGui.BeginPopup("##additem_menu")) {
                foreach (ci, c; kAddItemChoices) {
                    ImGui.PushID(cast(int) ci);
                    if (ImGui.Selectable(c.label)) {
                        if (commandHandlerDelegate !is null)
                            commandHandlerDelegate(c.command, c.args);
                    }
                    // `SetTooltip(string)` in this binding formats through
                    // "%.*s", so a runtime string is safe here — it is not
                    // being passed as a format.
                    if (c.tooltip.length && ImGui.IsItemHovered())
                        ImGui.SetTooltip(c.tooltip);
                    ImGui.PopID();
                }
                ImGui.EndPopup();
            }
        }

        ImGui.Separator();

        // ---- Column headers ----------------------------------------------
        // TWO icon columns and a Name, because two is how many per-row states
        // this panel actually holds a control for. The reference shape has a
        // third; we have nothing behind it, and a narrow empty column is
        // decoration. Each header draws the SAME glyph its column does, so the
        // header says what the column means rather than abbreviating it.
        {
            auto hdl = ImGui.GetWindowDrawList();
            immutable ImVec2 hp = ImGui.GetCursorScreenPos();
            drawEyeGlyph(hdl, ImVec2(hp.x + cellW * 0.5f, hp.y + rowH * 0.5f),
                         gRad, /*visible=*/true, hintCol);
            drawRoleGlyph(hdl, ImVec2(hp.x + cellW * 1.5f, hp.y + rowH * 0.5f),
                          gRad, RowRole.SelectedFirst, hintCol);
            ImGui.Dummy(ImVec2(cellW * 2.0f, rowH));
            ImGui.SameLine(0.0f, 0.0f);
            ImGui.TextDisabled("Name");
        }
        ImGui.Separator();

        // ---- Rows ---------------------------------------------------------
        // WHAT is listed, in WHAT order, at WHAT depth and under WHAT name is
        // `itemRowsInto` — see this function's header comment. Below is
        // placement and dispatch only.
        //
        // One static buffer, refilled in place each frame (the
        // `Document.selectedItemsInto` idiom), so a per-frame draw does not
        // churn an array.
        static ItemRow[] rowBuf;
        static bool rootExpanded = true;
        itemRowsInto(&document(), currentDocPath(), docDirty(),
                     rootExpanded, rowBuf);

        immutable float contentW = ImGui.GetContentRegionAvail().x;
        auto dl = ImGui.GetWindowDrawList();

        foreach (ri, ref r; rowBuf) {
            ImGui.PushID(cast(int) ri);
            immutable ImVec2 rowP0 = ImGui.GetCursorScreenPos();
            immutable ImVec2 rowP1 = ImVec2(rowP0.x + contentW, rowP0.y + rowH);

            // ---- Row background ----
            // The WHOLE row, drawn into the window list before any cell, so
            // the highlight spans the icon columns too rather than starting at
            // the name. Two shades for two facts about the SELECTION: being in
            // it, and heading it. An `a` of zero is "no fill" — an unselected
            // row keeps the panel's own backdrop, and after task 0672 that
            // includes an unselected mesh that is still the edit target.
            if (r.look.background.a != 0)
                dl.AddRectFilled(rowP0, rowP1, packed(r.look.background));

            // ---- Row ink ----
            // A selected row is drawn in an ACCENT colour as well as on a
            // highlight — which is the half of "selected" the old plain
            // `Selectable` did not carry. A greyed row (selected, but the item
            // gizmo will not move it) keeps saying so THROUGH the accent
            // rather than losing one of the two facts.
            immutable uint txtCol = packed(r.look.ink);

            // ---- Eye cell ----
            // Absent, not disabled, where there is nothing to toggle (the
            // root): a control that cannot be clicked is the dead ornament
            // this panel is not allowed to draw.
            if (r.canToggleVisible) {
                if (ImGui.InvisibleButton("##vis", ImVec2(cellW, rowH))) {
                    if (commandHandlerDelegate !is null)
                        commandHandlerDelegate("layer.setVisible",
                            `{"index":` ~ to!string(r.index) ~ `,"value":`
                            ~ (r.visible ? "false" : "true") ~ `}`);
                }
                drawEyeGlyph(dl,
                    ImVec2(rowP0.x + cellW * 0.5f, rowP0.y + rowH * 0.5f),
                    gRad, r.visible, r.visible ? txtCol : offCol);
            } else {
                ImGui.Dummy(ImVec2(cellW, rowH));
            }
            ImGui.SameLine(0.0f, 0.0f);

            // ---- Role cell ----
            // Replaces BOTH the old ">"/"@"/"*" text marker AND the "F"
            // checkbox beside it, and NOTHING a user could read is lost.
            //
            // "F" reported `Document.foreground(l)`, i.e. `visible &&
            // selected` — one checkbox CONFLATING two independent facts, so a
            // cleared box could mean "not selected" or "hidden" and the user
            // could not tell which. The two facts now have a column each: the
            // eye is `visible`, this cell is `selected` (with which KIND of
            // selected as a bonus the checkbox never carried), and
            // "foreground" is their conjunction, read straight off the row.
            //
            // Both dispatches survive too — plain click is the exclusive
            // select the marker was, ctrl-click is `mode:toggle`, whose two
            // outcomes are exactly the checkbox's `mode:add` / `mode:remove`.
            //
            // An exclusive click on a row that is ALREADY the whole selection
            // changes nothing, so it is not dispatched. `r.isSoleSelection`,
            // not "is this the current row": task 0672 — a latched edit target
            // is not the selection, and asking about the target here swallowed
            // the click that would have selected it back. Ctrl-click always
            // dispatches (it must be able to deselect the sole row too).
            if (!r.isRoot) {
                if (ImGui.InvisibleButton("##role", ImVec2(cellW, rowH))) {
                    if (commandHandlerDelegate !is null
                        && (io.KeyCtrl || !r.isSoleSelection))
                        commandHandlerDelegate("layer.select",
                            `{"index":` ~ to!string(r.index) ~ `,"mode":`
                            ~ (io.KeyCtrl ? `"toggle"` : `"set"`) ~ `}`);
                }
                drawRoleGlyph(dl,
                    ImVec2(rowP0.x + cellW * 1.5f, rowP0.y + rowH * 0.5f),
                    gRad, r.role, txtCol);
            } else {
                ImGui.Dummy(ImVec2(cellW, rowH));
            }
            ImGui.SameLine(0.0f, 0.0f);

            // ---- Indent ----
            if (r.depth > 0) {
                ImGui.Dummy(ImVec2(indentW * r.depth, rowH));
                ImGui.SameLine(0.0f, 0.0f);
            }

            // ---- Disclosure slot ----
            // Always RESERVED, drawn only on the root. Reserved because the
            // type glyphs are what the eye follows down the list, and letting
            // a childless row reclaim the triangle's width would leave the
            // glyph column ragged.
            {
                immutable ImVec2 dp = ImGui.GetCursorScreenPos();
                if (r.isRoot) {
                    if (ImGui.InvisibleButton("##disc", ImVec2(cellW, rowH)))
                        rootExpanded = !rootExpanded;
                    drawDisclosure(dl,
                        ImVec2(dp.x + cellW * 0.5f, dp.y + rowH * 0.5f),
                        gRad, rootExpanded, txtCol);
                } else {
                    ImGui.Dummy(ImVec2(cellW, rowH));
                }
                ImGui.SameLine(0.0f, 0.0f);
            }

            // ---- Type glyph ----
            {
                immutable ImVec2 gp = ImGui.GetCursorScreenPos();
                ImGui.Dummy(ImVec2(cellW, rowH));
                drawItemGlyph(dl,
                    ImVec2(gp.x + cellW * 0.5f, gp.y + rowH * 0.5f),
                    gRad, r.glyph, txtCol);
                ImGui.SameLine(0.0f, 0.0f);
            }

            // ---- Name ----
            immutable bool renaming = !r.isRoot && layerRenameIndex >= 0
                && cast(size_t) layerRenameIndex == r.index;
            // The accent is for a row being READ; a row being EDITED reverts to
            // ink. The rename field sits on the pale beige FrameBg this chrome
            // pushes, and the accent orange on that is barely legible — the
            // colour that says "this is the current row" would be paid for by
            // not being able to see what you are typing.
            ImGui.PushStyleColor(ImGuiCol.Text, renaming ? inkCol : txtCol);
            if (r.isRoot) {
                // Not a Selectable: the root names the FILE, and there is no
                // scene item behind it to select, rename or reorder. Clicking
                // it does nothing, which is honest; the triangle beside it is
                // what the row is for.
                ImGui.TextUnformatted(r.name);
            } else if (renaming) {
                // Inline edit: Enter (or focus loss) commits, Esc cancels.
                if (ImGui.IsWindowAppearing() || !ImGui.IsAnyItemActive())
                    ImGui.SetKeyboardFocusHere();
                ImGui.SetNextItemWidth(140);
                bool commit = ImGui.InputText("##rename", layerRenameBuf[],
                                  ImGuiInputTextFlags.EnterReturnsTrue);
                bool cancel = ImGui.IsKeyPressed(ImGuiKey.Escape);
                // Commit on Enter or when the field loses focus (click away).
                if (!commit && !cancel && ImGui.IsItemDeactivatedAfterEdit())
                    commit = true;
                if (commit) {
                    string newName =
                        cast(string) fromStringz(layerRenameBuf.ptr).dup;
                    if (newName.length && commandHandlerDelegate !is null)
                        commandHandlerDelegate("layer.rename",
                            `{"index":` ~ to!string(r.index) ~ `,"name":`
                            ~ JSONValue(newName).toString() ~ `}`);
                    layerRenameIndex = -1;
                } else if (cancel || ImGui.IsItemDeactivated()) {
                    layerRenameIndex = -1;
                }
            } else {
                // The name is the multi-select target, the rename opener and
                // the drag-to-reorder handle. `selected` is passed FALSE: the
                // row background above already carries selection, and letting
                // the Selectable draw its own Header colour on top would paint
                // a second, differently-sized highlight inside the first. What
                // it still contributes is HOVER feedback.
                //   plain click → `layer.select mode:set`    (exclusive
                //                 select + make primary)
                //   ctrl-click  → `layer.select mode:toggle` (add/remove this
                //                 layer from the foreground set; removing the
                //                 primary promotes another)
                bool nameClicked =
                    ImGui.Selectable(r.name, false,
                                     ImGuiSelectableFlags.AllowDoubleClick,
                                     ImVec2(0, rowH));
                bool dbl = ImGui.IsItemHovered()
                    && ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left);
                if (nameClicked && !dbl && commandHandlerDelegate !is null) {
                    // io.KeyCtrl is the frame's merged Ctrl-modifier state
                    // (matches every other modifier read in the app).
                    immutable mode = io.KeyCtrl ? `"toggle"` : `"set"`;
                    // Plain click on a row that is already the WHOLE selection
                    // is a no-op switch; skip it so a single-select drag-press
                    // doesn't re-dispatch every frame. Task 0672: this asked
                    // `document.isPrimary(r.layer)` — the edit target, which
                    // after task 0671 need not be selected at all, so clicking
                    // the latched mesh's name to select it back did nothing.
                    // It is the same defect 0671 fixed in app.d's viewport
                    // click guard, and the same fix: ask about the SELECTION.
                    if (io.KeyCtrl || !r.isSoleSelection)
                        commandHandlerDelegate("layer.select",
                            `{"index":` ~ to!string(r.index) ~ `,"mode":`
                            ~ mode ~ `}`);
                }
                if (dbl) {
                    layerRenameIndex = cast(int) r.index;
                    layerRenameBuf[] = 0;
                    // The RAW name, never the displayed one: seeding the
                    // editor with the "(unnamed)" placeholder means Enter
                    // renames the item to that literal, after which "no name"
                    // cannot be recovered (see `ItemRow.renameSeed`).
                    auto src = r.renameSeed;
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
                // only item rows accept it.
                //
                // Addressed by `r.index`, the DOCUMENT index, which is why the
                // row model carries it: the list hides resource items and
                // prepends a root, so a row's ordinal is not its layer.
                //
                // `to`-index semantics: the layer.reorder command splices the
                // source layer OUT of the array, then splices it back IN at
                // index `to` of the POST-REMOVAL array. With `to = r.index`,
                // the dragged row always lands at the target row's index for
                // BOTH up- and down-drags (verified against the splice path in
                // commands/layer/commands.d::moveLayer and the test_layers.d
                // reorder cases: from:2 to:0 on [A,B,C] -> [C,A,B];
                // from:0 to:2 -> [B,C,A]). No from<to adjustment is needed:
                // on a down-drag the source's removal already shifts the
                // target up by one, so inserting at `r.index` lands the
                // dragged row exactly at the target's old slot.
                if (ImGui.BeginDragDropSource(ImGuiDragDropFlags.None)) {
                    int srcIdx = cast(int) r.index;
                    ImGui.SetDragDropPayload("VIBE3D_LAYER_ROW",
                                             &srcIdx, srcIdx.sizeof);
                    ImGui.Text(r.name);
                    ImGui.EndDragDropSource();
                }
                if (ImGui.BeginDragDropTarget()) {
                    const(ImGuiPayload)* payload =
                        ImGui.AcceptDragDropPayload("VIBE3D_LAYER_ROW");
                    if (payload !is null
                        && payload.Data !is null
                        && payload.DataSize == cast(int)int.sizeof) {
                        int fromIdx = *cast(const(int)*) payload.Data;
                        if (fromIdx != cast(int) r.index
                            && commandHandlerDelegate !is null)
                            commandHandlerDelegate("layer.reorder",
                                `{"from":` ~ to!string(fromIdx)
                                ~ `,"to":` ~ to!string(r.index) ~ `}`);
                    }
                    ImGui.EndDragDropTarget();
                }
            }
            ImGui.PopStyleColor();

            ImGui.PopID();
        }

        // ---- Layer (item) properties form ----
        // Render the config-driven layer-props form for the FOCUSED item
        // below the layer list — the same FormsPanel that drives Tool
        // Properties, fed a LayerPropsProvider wrapping it. Task 0616 Ph4
        // moved the binding from `primary` to `itemPropsTarget(&document())`
        // (the item-selection focus): `primary` is by invariant a mesh, so
        // bound to it this form could never show a non-mesh item's channels
        // at all — an image row selected in the Images panel had its
        // `colorspace` / `useAlpha` declared as `Param`s (Stage 3) with no
        // surface that could reach them. On an all-mesh document focus and primary
        // always coincide, so nothing there changes. The form is looked up by
        // its explicit id
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
                    auto propsTarget = itemPropsTarget(&document());
                    // TASK 0654 — the properties form shows NOTHING when no
                    // item is selected. The `propsTarget = document.primary`
                    // fallback this replaces was written when a null target was
                    // unreachable; with an empty selection the primary is null
                    // too, so it repaired nothing and only hid the case.
                    //
                    // Drawing a disabled line rather than nothing at all: the
                    // panel is a docked tab with a header, and an empty body
                    // reads as a rendering fault. The label states the reason,
                    // which is the same answer every other consumer gives.
                    if (propsTarget is null) {
                        ImGui.TextDisabled("No item selected");
                    } else {
                    if (layerProv is null)
                        layerProv = new LayerPropsProvider(propsTarget);
                    else
                        layerProv.setLayer(propsTarget);
                    // P4 primary-transform interlock: grey out the transform
                    // rows while a transform tool is active. The panel always
                    // binds the PRIMARY, so that is the only layer whose
                    // transform could desync the live gizmo (the transform is
                    // render-only; gizmo/drag run in the LOCAL frame). The
                    // guard is mid-gesture only — it clears when the tool
                    // drops; tool-free edits persist. (Same TransformTool
                    // cast the deferred-drag draw site uses.)
                    //
                    // Task 0614 Phase 5: the CURRENT selection type goes with
                    // it. Under `SelType.Item` the transform tool's only write
                    // target is `Layer.xform` — these very rows — so there is
                    // no second writer to desync from and the interlock must
                    // not arm. Read live from the authority rather than cached
                    // (seltype.d: `currentSelType` is THE answer to "what kind
                    // of thing is selected"), so a mode flip is reflected on
                    // the next frame with no invalidation step.
                    layerProv.setTransformGuard(
                        (cast(TransformTool)activeTool) !is null,
                        currentSelType(selTypeOrder));
                    formsPanel.draw(*layerForm, layerProv,
                                    commandHandlerDelegate,
                                    formsInteractiveDispatch,
                                    /*activeToolId=*/"",
                                    /*stageId=*/"",
                                    // The dispatched `layer.attr <idx>` must
                                    // address the layer the form is BOUND to,
                                    // not the primary — those are the same
                                    // index on an all-mesh document and a
                                    // different one the moment a non-mesh row
                                    // takes the focus.
                                    /*layerIndex=*/to!string(
                                        document.indexOf(propsTarget)));
                    }   // task 0654: end of the has-a-target arm
                }
            }
        }

        // ---- Image-plane clip picker (task 0612 Stage 7) ----
        //
        // OUTSIDE the forms block on purpose, and computing its own bound
        // item: the link is the one piece of a plane's state that cannot ride
        // the generic form (a `Param` is a typed pointer to a scalar; a link
        // names a `Layer` OBJECT), so gating it on `g_formsPanelEnabled` /
        // `formById("layer.props")` would make the only way to give a plane
        // an image disappear with the config file.
        //
        // WHAT IS DRAWN here and what is DECIDED elsewhere: every assertable
        // thing about this picker — which rows it offers, what each row is
        // labelled, which row is marked, and above all the `Document.layers`
        // index each row dispatches — is `image_plane.d`'s
        // `planeImageChoices`, behind in-module tests. An ImGui body cannot
        // be driven headlessly, so what is left here is the loop and the
        // dispatch, following `ui/image_rows.d`'s split exactly.
        {
            import image_plane : planeImageChoices, imagePlaneSource,
                                 ImagePlaneSource;
            auto planeTarget = itemPropsTarget(&document());
            if (planeTarget !is null && planeTarget.hasImagePlane) {
                ImGui.Separator();
                auto choices = planeImageChoices(document(), planeTarget);
                string preview = "(none)";
                foreach (ref e; choices) if (e.current) preview = e.label;
                immutable planeIdx = document.indexOf(planeTarget);
                ImGui.SetNextItemWidth(160);
                if (ImGui.BeginCombo("Image", preview)) {
                    foreach (ref e; choices) {
                        // PushID on the LAYER INDEX, not the loop counter: two
                        // clips may legitimately share a display name (the
                        // list renames the row, never the file), and two
                        // identically-labelled Selectables in one combo share
                        // an ImGui id — clicking either would activate the
                        // first.
                        ImGui.PushID(e.layerIndex);
                        if (ImGui.Selectable(e.label, e.current) && !e.current
                            && commandHandlerDelegate !is null)
                            commandHandlerDelegate("imagePlane.setImage",
                                `{"index":` ~ to!string(planeIdx)
                                ~ `,"image":` ~ to!string(e.layerIndex) ~ `}`);
                        if (e.current) ImGui.SetItemDefaultFocus();
                        ImGui.PopID();
                    }
                    ImGui.EndCombo();
                }
                // The source state in words. A plane whose link is broken
                // draws NOTHING in the viewport (a declared divergence — we
                // have no item glyph), so without this line the user's only
                // evidence is an empty viewport, which reads the same for
                // "wrong projection", "hidden" and "the file is gone".
                immutable src = imagePlaneSource(document(), planeTarget);
                final switch (src) {
                    case ImagePlaneSource.Unbound:
                        ImGui.TextDisabled("%s", "no image"); break;
                    case ImagePlaneSource.Dangling:
                        ImGui.TextDisabled("%s", "image removed"); break;
                    case ImagePlaneSource.Missing:
                        ImGui.TextDisabled("%s", "file not found"); break;
                    case ImagePlaneSource.Ready:
                        if (!planeTarget.visible)
                            ImGui.TextDisabled("%s", "hidden");
                        break;
                }
            }
        }
    }
    ImGui.End();
    popPanelChromeStyle();
    }
}

// -------------------------------------------------------------------------
// Images panel (task 0616 Ph4)
// -------------------------------------------------------------------------
//
// The document's loaded images, one row each. Its own panel, not rows in the
// Layers panel: the Layers panel stays about geometry, and the two lists are
// exact complements (`isSceneItem` there, `hasImage` here), so no item can
// fall between them and none can appear twice.
//
// WHAT IS DRAWN is decided entirely by `ui/image_rows.d` — this body only
// places it. That split is deliberate: an ImGui body cannot be asserted
// headlessly, so everything assertable (which rows, which layer index, the two
// path forms, the dimensions and format cells, the elision direction, the
// selection/focus flags, the Remove target, the confirm sentence) lives in
// that module behind in-module tests, and what is left here is geometry on
// screen and nothing else.
//
// The measured shape (doc/tasks/0616-evidence/clip_panel_shape.md):
//   - a TWO-LINE name cell: display name on line 1, the file path on line 2,
//     dimmer and elided from the right;
//   - pixel dimensions and pixel format as their own columns;
//   - multi-select (ctrl-click), and selection is undoable — which it is,
//     because the click dispatches `layer.select`, a `CmdFlags.UiState`
//     command, i.e. this codebase's UI-undo class. Selection is view state,
//     not document content, and that is exactly the separate undo class the
//     reference gives it;
//   - no sorting and no filter box (settled absences, not omissions);
//   - editable per-item properties are NOT here — they are `Param`s on the
//     item, shown in the shared item-properties form, which now follows the
//     item-selection focus (`itemPropsTarget`, layer_params.d) so a selected
//     image row's `colorspace` / `useAlpha` are reachable there. The list and
//     the properties do not overlap.
//
// NOT taken, each for the reason the measurement itself gives: the visibility
// column (declared but unbound, and absent from the shipped screenshot —
// vestigial), the leading marker column (purpose not settled), and the four
// size-responsive presentations (a separate concern). No thumbnail either —
// nothing in this build decodes pixels, only headers (see `ui/image_rows.d`).
//
// EVERY interaction dispatches through commandHandlerDelegate, exactly as the
// Layers panel does; the panel never mutates `document` directly.
//
// Visibility mirrors the Layers panel: always drawn in a normal run; in
// --test HIDDEN by default (so it cannot swallow a synthetic viewport drag)
// until `ui.imageList show`.
void drawImageListPanel(EditorApp app) {
    with (app) {
    import std.json : JSONValue;
    import std.conv : to;
    import std.string : fromStringz;
    import io.doc_state : currentDocPath;

    // Confirm-before-remove state. Function-local statics rather than
    // EditorApp fields: nothing outside this body reads them, and the panel is
    // main-thread-only (same convention as the modal flags above, which are
    // app fields only because they are shared with the side panel's menu).
    static bool   removeConfirmOpen;
    static bool   removeConfirmPendingOpen;
    static string removeConfirmText;
    static size_t removeConfirmIndex;

    // BALANCED ON EVERY EXIT, INCLUDING A THROWN ONE (review S3). `ImGui.End`
    // and the style pop are not optional cleanup — ImGui keeps a window stack
    // and a style stack, and an unwound frame that skipped either leaves both
    // one deep. The symptom then appears on the NEXT frame, as an assertion
    // inside ImGui with no connection to the code that threw.
    //
    // There ARE throwing calls on this path, which is what makes this real
    // rather than defensive: every `commandHandlerDelegate` call below routes
    // through `applyOrRefire` with a non-null `throwMsg`, so a refused
    // `image.remove` / `layer.rename` / `image.load` throws from inside the
    // draw; and the row model touches user-supplied paths (see `elideEnd`).
    // `scope(exit)` runs on all three of return, fall-through and unwind.
    pushPanelChromeStyle();
    scope(exit) popPanelChromeStyle();
    scope(exit) ImGui.End();
    if (ImGui.Begin("Images")) {
        // ---- Load button ----
        // No `path` argument: `image.load` with none opens the file dialog,
        // which is the only route the reference offers either (its load
        // command takes no arguments at all — measured). The by-path form
        // exists for tests and scripts and is reached through /api/command.
        if (ImGui.SmallButton("Load...")) {
            if (commandHandlerDelegate !is null)
                commandHandlerDelegate("image.load", "{}");
        }
        ImGui.SameLine();

        // ---- Remove button ----
        // Target + enabled state come from ONE function (`imageRemoveTarget`),
        // in the `layerDeleteButtonState` shape, so the greying and the
        // dispatched index cannot disagree — the bug that shape exists to
        // prevent.
        auto rem = imageRemoveTarget(&document());
        // Braced so the `scope(exit)` ends the disabled state HERE and not at
        // the end of the whole panel. Same balance-on-unwind rule as the
        // window itself: the dispatch below throws on a refusal, and the
        // disabled stack must not be left one deep for the rest of the frame.
        {
            ImGui.BeginDisabled(!rem.enabled);
            scope(exit) ImGui.EndDisabled();
            if (ImGui.SmallButton("Remove")) {
                if (rem.enabled) {
                    // CLICK TIME is the only place the reverse referrer sweep
                    // may run: `Document.referrersOf` explicitly forbids a
                    // draw-path call, and this is the delete-time query it was
                    // written for.
                    removeConfirmText  = imageRemoveConfirmText(&document(),
                                                                rem.layer);
                    removeConfirmIndex = rem.index;
                    if (removeConfirmText.length) {
                        removeConfirmOpen        = true;
                        removeConfirmPendingOpen = true;
                    } else if (commandHandlerDelegate !is null) {
                        // Nothing references it — nothing to warn about.
                        commandHandlerDelegate("image.remove",
                            `{"index":` ~ to!string(rem.index) ~ `}`);
                    }
                }
            }
        }

        // ---- In-use confirmation ----
        // Same pendingOpen convention as the AI3D modals below.
        if (removeConfirmOpen) {
            if (removeConfirmPendingOpen) {
                ImGui.OpenPopup("Remove Image?");
                removeConfirmPendingOpen = false;
            }
            if (ImGui.BeginPopupModal("Remove Image?", null,
                                      ImGuiWindowFlags.AlwaysAutoResize)) {
                // Balanced on unwind: the Remove button below dispatches a
                // command that throws when it refuses.
                scope(exit) ImGui.EndPopup();
                ImGui.TextUnformatted(removeConfirmText);
                ImGui.TextUnformatted("Remove it anyway?");
                if (ImGui.Button("Remove")) {
                    if (commandHandlerDelegate !is null)
                        commandHandlerDelegate("image.remove",
                            `{"index":` ~ to!string(removeConfirmIndex) ~ `}`);
                    ImGui.CloseCurrentPopup();
                    removeConfirmOpen = false;
                }
                ImGui.SameLine();
                if (ImGui.Button("Cancel")) {
                    ImGui.CloseCurrentPopup();
                    removeConfirmOpen = false;
                }
            } else {
                removeConfirmOpen = false;   // closed via ESC
            }
        }

        ImGui.Separator();

        // ---- Rows ----
        // ONE buffer, refilled in place each frame (the `referrersOf` /
        // `selectedItemsInto` idiom) rather than a fresh array per frame.
        static ImageRow[] rows;
        imageRowsInto(&document(), currentDocPath(), rows);

        if (rows.length == 0) {
            // The measured list has its own empty text rather than an empty
            // rectangle.
            ImGui.TextDisabled(kNoImagesText);
        }

        foreach (ref r; rows) {
            immutable int idx = cast(int) r.index;
            ImGui.PushID(idx);
            // Per-ITERATION (a `scope(exit)` in a loop body runs at the end of
            // each pass), and balanced on unwind for the same reason as the
            // window above: this body dispatches commands that throw.
            scope(exit) ImGui.PopID();

            // ---- line 1: focus marker + name + dimensions + format ----
            // The marker is the same three-state glyph the Layers panel uses
            // ("@" focus, "*" in the selection set, " " neither); ">" cannot
            // occur here because an image item is never the mesh edit target.
            immutable marker = r.focused ? "@" : r.selected ? "*" : " ";
            if (ImGui.Selectable(marker, r.focused,
                                 ImGuiSelectableFlags.AllowItemOverlap,
                                 ImVec2(14, 0))) {
                if (!r.focused && commandHandlerDelegate !is null)
                    commandHandlerDelegate("layer.select",
                        `{"index":` ~ to!string(idx) ~ `,"mode":"set"}`);
            }
            ImGui.SameLine();

            if (layerRenameIndex == idx) {
                // Inline rename — `layer.rename`, which writes the item's
                // display name and NOTHING on disk. There is deliberately no
                // `image.rename`: a second command would be a second way to
                // get this wrong, and the reference's own list renames the
                // reference and never the file either.
                if (ImGui.IsWindowAppearing() || !ImGui.IsAnyItemActive())
                    ImGui.SetKeyboardFocusHere();
                ImGui.SetNextItemWidth(140);
                bool commit = ImGui.InputText("##rename", layerRenameBuf[],
                                  ImGuiInputTextFlags.EnterReturnsTrue);
                bool cancel = ImGui.IsKeyPressed(ImGuiKey.Escape);
                if (!commit && !cancel && ImGui.IsItemDeactivatedAfterEdit())
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
                // Multi-select: plain click replaces the selection
                // (`mode:set`), ctrl-click adds/removes (`mode:toggle`).
                // Double-click opens the rename editor.
                bool nameClicked =
                    ImGui.Selectable(r.name, r.selected,
                                     ImGuiSelectableFlags.AllowDoubleClick,
                                     ImVec2(180, 0));
                bool dbl = ImGui.IsItemHovered()
                    && ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left);
                if (nameClicked && !dbl && commandHandlerDelegate !is null) {
                    immutable mode = io.KeyCtrl ? `"toggle"` : `"set"`;
                    if (io.KeyCtrl || !r.focused)
                        commandHandlerDelegate("layer.select",
                            `{"index":` ~ to!string(idx) ~ `,"mode":`
                            ~ mode ~ `}`);
                }
                if (dbl) {
                    layerRenameIndex = idx;
                    layerRenameBuf[] = 0;
                    // `renameSeed`, not `name` (review S5). `name` is what the
                    // row DRAWS, and for an unnamed item that is the literal
                    // "(unnamed)" placeholder — seeding the editor with it
                    // means pressing Enter renames the layer TO the
                    // placeholder, and the Layers panel (which reads the raw
                    // field) then shows an item genuinely called "(unnamed)".
                    // The two fields exist separately so a test can see the
                    // difference; see `ui/image_rows.d`.
                    auto src = r.renameSeed;
                    size_t n = src.length < layerRenameBuf.length - 1
                             ? src.length : layerRenameBuf.length - 1;
                    layerRenameBuf[0 .. n] = src[0 .. n];
                }
            }

            // Pixel dimensions, then pixel format — each its own column, both
            // read-only labels, drawn through `TextUnformatted`, which takes
            // no format string at all (see the note on the path line below for
            // what "the single-string overload" means in THIS binding).
            //
            // The two offsets are wide enough for the widest cell either
            // column can hold: `MAX_IMAGE_DIM` is 16384, so "16384 x 16384"
            // (13 characters) is the dimensions column's worst case, and the
            // format column must start clear of it. Measured on screen at the
            // first cut with 200/280, where "1024 x 1024" ran straight into
            // "RGB".
            ImGui.SameLine(210);
            ImGui.TextUnformatted(r.dimensions.length ? r.dimensions : "-");
            ImGui.SameLine(330);
            ImGui.TextUnformatted(r.pixelFormat.length ? r.pixelFormat : "-");

            // ---- line 2: the path, dimmer, elided from the RIGHT ----
            // The budget is in code points, derived from the width actually
            // available, so the head of the path survives a narrow panel.
            // (`Dummy` + `SameLine` rather than `Indent`: this build's ImGui
            // binding exposes no Indent/Unindent wrapper.)
            ImGui.Dummy(ImVec2(18, 0));
            ImGui.SameLine();
            {
                immutable float avail = ImGui.GetContentRegionAvail().x;
                immutable float chW   = ImGui.CalcTextSize("m").x;
                size_t budget = 16;
                if (chW > 0.0f && avail > 0.0f) {
                    immutable long b = cast(long)(avail / chW);
                    budget = b < 8 ? 8 : cast(size_t) b;
                }
                // WHY A USER'S PATH IS SAFE TO PASS DIRECTLY HERE — stated
                // precisely, because "TextDisabled is printf-style" is true of
                // the upstream C++ API and NOT of the binding this build links
                // (review B2 was raised against the wrong package).
                //
                // `dub.selections.json` resolves `d_imgui` to the cimgui shim,
                // whose `source/d_imgui/package.d` declares:
                //
                //     void TextDisabled(string s)  { igTextDisabled("%.*s", cast(int) s.length, s.ptr); }
                //     void SetTooltip(string s)    { igSetTooltip  ("%.*s", cast(int) s.length, s.ptr); }
                //
                // — non-template, exactly one string parameter, and the format
                // string is the binding's own literal. `elidedPathText(...)`
                // and `pathTooltip` are ARGUMENTS to `%.*s`, never the format,
                // so a path holding `%20i` or `%s` (a browser download, a shell
                // artefact) is drawn literally. The printf-style overloads in
                // this binding all take an explicit format PLUS typed args
                // (`(string fmt, string)`, `(string fmt, int)`, `(string fmt,
                // int, int)`) and cannot be selected by a single argument.
                //
                // If the binding is ever swapped for one whose only overload is
                // a variadic `(string fmt, A...)`, these two calls become the
                // crash — so the swap must re-check this block. That is also
                // why the columns above use `TextUnformatted`, which has no
                // format-string form to regress into under any binding.
                //
                // `elidedPathText`, not `elideEnd`: the cut is memoised on the
                // item, keyed on (this row's text, this budget). It is a cache
                // in front of `elideEnd` and returns exactly what it returns —
                // the only difference is that a frame in which neither the
                // path nor the panel's width moved does not allocate. The
                // budget above is the second key; it changes on a RESIZE and
                // at no other time, which is what makes the memo worth having
                // (task 0635 — and see that function for why the earlier "this
                // costs nothing" measurement was reading a call nobody made).
                if (r.pathText.length)
                    ImGui.TextDisabled(elidedPathText(r, budget));
                else
                    ImGui.TextDisabled("(no file)");
                // The tooltip is always the ABSOLUTE path — measured: relative
                // in the row, absolute on hover.
                if (ImGui.IsItemHovered() && r.pathTooltip.length)
                    ImGui.SetTooltip(r.pathTooltip);
                if (r.missing) {
                    ImGui.SameLine();
                    ImGui.TextDisabled("(not found)");
                }
            }
        }
    }
    // `ImGui.End()` + `popPanelChromeStyle()` are the two `scope(exit)`s
    // registered at the top of this function — see the note there for why they
    // are not plain statements here.
    }
}

// ---------------------------------------------------------------------------
// Channels (task 0637) — EVERY channel of the focused item, uncurated.
//
// The second editing surface. The properties form beside it is CURATED: it
// draws the rows `config/forms/layer_props.yaml` names, and that is the right
// shape for a form somebody designed. It is only allowed to be curated because
// this panel exists — without a generic surface, every per-kind section would
// have to carry every channel or the channel would be reachable from nowhere,
// which is precisely what happened to the ten image-plane channels task 0612
// declared (`ui/channel_rows.d`'s intro tells that story in full).
//
// WHAT IS DRAWN here and what is DECIDED elsewhere: every assertable thing —
// which rows exist, what each is labelled, which item each row's `layer.attr`
// addresses, which rows are greyed — is `ui/channel_rows.d`, behind in-module
// tests. An ImGui body cannot be driven headlessly, so what is left here is the
// header, the memo and one `formsPanel.draw` call. Same split as
// `ui/image_rows.d` and the image-plane clip picker above.
//
// NO TAB STRIP IS BUILT. Docking gives it for free: several windows docked into
// one node grow an ImGui tab bar by themselves (app.d already docks Layers +
// Images + Tool Properties + Viewport Properties into one node for exactly
// that), so Properties-beside-Channels is the user's layout choice, persisted
// through the same versioned layout ini every other panel uses. That also
// keeps this clear of the fact that this build's ImGui binding exposes no
// `BeginTabBar` (app.d's tool-properties strip is hand-built for that reason) —
// docking tabs are a different mechanism and this build plainly has them.
//
// DELIBERATELY NOT GATED on `g_formsPanelEnabled` / a `formById` lookup. The
// form here is SYNTHESISED from the live `params()`, not loaded from
// config/forms, so gating it on the YAML kill-switch would make the only
// exhaustive surface disappear together with the config file — the same
// argument the clip picker above makes for sitting outside that block.
//
// Every write dispatches `layer.attr <index> <attr> <value>` through the SAME
// interactive dispatch the properties form uses, so undo class, coalescing and
// the change-bus publication are the command's, not this panel's. The panel
// never mutates `document` directly.
//
// Visibility mirrors Layers / Images: always drawn in a normal run; in --test
// HIDDEN by default (so it cannot swallow a synthetic viewport drag) until
// `ui.channels show`.
void drawChannelsPanel(EditorApp app) {
    with (app) {
    import ui.channel_rows : ChannelsKey, ChannelsModel, ChannelsProvider,
                             channelsModel, kNoItemText;
    import layer_params    : itemPropsTarget;

    // Cached across frames: the provider (so its blocked set is not rebuilt per
    // frame) and the built rows (so 24 command strings are not rebuilt per
    // frame). Function-local statics rather than EditorApp fields — nothing
    // outside this body reads them and the panel is main-thread-only, the same
    // convention the Images panel's confirm state uses.
    static ChannelsProvider prov;
    static ChannelsModel    model;

    // BALANCED ON EVERY EXIT, INCLUDING A THROWN ONE: `commandHandlerDelegate`
    // and the interactive dispatch below both route through `applyOrRefire`,
    // and a refused `layer.attr` (a readonly attr, an out-of-domain value)
    // throws from inside the draw. `scope(exit)` keeps ImGui's window and style
    // stacks from being left one deep, whose symptom would otherwise surface a
    // frame later with no connection to the throw.
    pushPanelChromeStyle();
    scope(exit) popPanelChromeStyle();
    scope(exit) ImGui.End();
    if (ImGui.Begin("Channels")) {
        // Binds the item-selection FOCUS, never `document.primary` — an image
        // plane can never BE the primary, so a primary-bound panel would show
        // none of the channels this one exists for. Reached through the shared
        // `itemPropsTarget` so this surface and the properties form can never
        // disagree about which item is being edited.
        auto item = itemPropsTarget(&document());
        if (item is null) {
            ImGui.TextDisabled("%s", kNoItemText);
        } else {
            // Rebuild only on a key change (see `ChannelsModel.key`). A focus
            // move rebinds from scratch; otherwise the one per-frame `params()`
            // — the same allocation the renderer's own snapshot makes — catches
            // an index shift or a payload appearing on an item that had none.
            if (prov is null || model.key.item !is item) {
                prov  = new ChannelsProvider(item);
                model = channelsModel(&document());
            } else {
                auto k = ChannelsKey(item, document.indexOf(item),
                                     prov.params().length);
                if (k != model.key) {
                    prov.rebind(item);
                    model = channelsModel(&document());
                }
            }

            // Header: whose channels these are. `%s` rather than passing the
            // name as the format string — it is user text (same reason the
            // Layers panel's kind badge does).
            ImGui.TextUnformatted(model.title);
            ImGui.SameLine();
            ImGui.TextDisabled("%s", model.kindText);
            ImGui.Separator();

            // The base provider's own mid-gesture transform interlock, driven
            // exactly as the Layers panel drives it: while a transform tool is
            // up over a GEOMETRY selection, the item transform is a second,
            // invisible writer and its rows grey out. Under `SelType.Item` the
            // gizmo's only write target IS these rows, so it must not arm —
            // the narrowing lives in `setTransformGuard`, read live from the
            // authority rather than cached.
            prov.base.setTransformGuard(
                (cast(TransformTool)activeTool) !is null,
                currentSelType(selTypeOrder));

            // The SAME renderer the properties form uses, so a row here is
            // resolved, drawn and written back by exactly one implementation.
            // `layerIndex` is empty on purpose: these lines were synthesised
            // with the live index already in them, so there is nothing for
            // `rebindBindingTarget` to overwrite.
            formsPanel.draw(model.form, prov,
                            commandHandlerDelegate,
                            formsInteractiveDispatch,
                            /*activeToolId=*/"",
                            /*stageId=*/"",
                            /*layerIndex=*/"");
        }
    }
    // `ImGui.End()` + `popPanelChromeStyle()` are the two `scope(exit)`s
    // registered above.
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
                // TASK 0669 — the popup rows follow the same rule as the
                // buttons: a row that would refuse is greyed, and says why.
                // The MENU itself always opens (`actionRefusal` answers ""
                // for a popup action) — a menu whose rows are unavailable
                // still has to be readable.
                string rowWhy = blocked
                    ? "Requires libassimp — not loaded"
                    : actionRefusal(reg, it.action, document.hasEditTarget(), activeToolId);
                bool rowBlocked = blocked || rowWhy.length > 0;
                recordDrawnButton("popup", it.label, it.action.kind, it.action.id,
                                  rowBlocked, blocked ? "" : rowWhy);
                if (rowBlocked) ImGui.BeginDisabled(true);
                if (ImGui.MenuItem(it.label, "", checked) && !rowBlocked)
                    dispatchAction(app, it.action);
                if (rowBlocked) {
                    ImGui.EndDisabled();
                    if (ImGui.IsItemHovered(ImGuiHoveredFlags.AllowWhenDisabled))
                        ImGui.SetTooltip(rowWhy);
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

// Pick the variant a button currently represents.
//
// A HELD modifier wins — that is the preview while you hold Ctrl/Alt/Shift.
// Otherwise, if a variant's action is a tool AND that tool is the active one,
// the button represents THAT variant: it keeps the variant's label and, because
// the caller derives the pressed state from the returned `action`, it stays lit
// after the modifier is released.
//
// Without the second rule a sticky tool reached through a modifier can never
// show as active: the moment you let go of Ctrl the button falls back to its
// primary action, compares the active tool against the WRONG id, goes dark, and
// re-labels itself as the primary tool — so it reads as "the button did
// nothing" while the tool is in fact running. (Found on the Pen button's Ctrl
// variant, which activates the topology pen.) One-shot variants — command or
// script — have no active state to latch and are unaffected.
private void selectButtonVariant(ref Button btn, SDL_Keymod mods, string activeToolId,
                                 out string label, out Action action, out string variant) {
    label = btn.label;
    action = btn.action;
    variant = "";

    static bool isActiveTool(ref Action a, string activeToolId) {
        return a.kind == ActionKind.tool && a.id == activeToolId
            && activeToolId.length > 0;
    }

    // macOS: a `ctrl:` variant answers to ⌘ and DELIBERATELY NOT to Control.
    //
    // Control+click is reserved by macOS itself as the secondary click — the OS
    // delivers it as a RIGHT button, our ImGui backend maps right → button 1,
    // and `ImGui.Button` only fires on button 0. So a Control+click on a panel
    // button can never land, no matter what this function returns. Reported
    // exactly that way: "with Ctrl I see the changed buttons, but I can't press
    // them" — every ctrl: variant, not just the pen.
    //
    // Reacting to Control here would keep that trap alive: the label would
    // promise a variant the click cannot reach. So on macOS Control selects
    // nothing and ⌘ — a plain left click carrying a modifier — selects the
    // variant. shortcuts.d is untouched; it keeps `ctrl+` and `cmd+` as
    // distinct SHORTCUT spellings, which is a separate concern from clicks.
    // Elsewhere the mask is plain KMOD_CTRL, so Linux/Windows are unchanged.
    version (OSX) enum ctrlMask = KMOD_GUI;
    else          enum ctrlMask = KMOD_CTRL;

    if      (btn.ctrl.present  && (mods & ctrlMask))   { label = btn.ctrl.label;  action = btn.ctrl.action;  variant = "_ctrl";  }
    else if (btn.alt.present   && (mods & KMOD_ALT))   { label = btn.alt.label;   action = btn.alt.action;   variant = "_alt";   }
    else if (btn.shift.present && (mods & KMOD_SHIFT)) { label = btn.shift.label; action = btn.shift.action; variant = "_shift"; }
    // No modifier held: let an ACTIVE variant tool claim the button. The
    // primary action is checked by the caller's own pressed-state logic, so
    // only variants need claiming here.
    else if (btn.ctrl.present  && isActiveTool(btn.ctrl.action,  activeToolId)) { label = btn.ctrl.label;  action = btn.ctrl.action;  variant = "_ctrl";  }
    else if (btn.alt.present   && isActiveTool(btn.alt.action,   activeToolId)) { label = btn.alt.label;   action = btn.alt.action;   variant = "_alt";   }
    else if (btn.shift.present && isActiveTool(btn.shift.action, activeToolId)) { label = btn.shift.label; action = btn.shift.action; variant = "_shift"; }
}

unittest {
    // Regression: a sticky tool reached through a modifier variant must keep
    // the button lit and labelled after the modifier is released. Before the
    // active-variant rule the button fell back to its primary action, compared
    // the active tool against the wrong id, and read as "the button did
    // nothing" while the tool was running.
    static Button penButton() {
        Button b;
        b.label  = "Pen";
        b.action = Action(ActionKind.tool, "pen");
        b.ctrl.present = true;
        b.ctrl.label   = "Topology Pen";
        b.ctrl.action  = Action(ActionKind.tool, "mesh.topoPen");
        return b;
    }
    string label; Action action; string variant;
    auto btn = penButton();

    // 1. Ctrl HELD — the variant previews regardless of what is active.
    selectButtonVariant(btn, KMOD_CTRL, "", label, action, variant);
    assert(action.id == "mesh.topoPen" && label == "Topology Pen" && variant == "_ctrl");

    // 2. Ctrl RELEASED while the variant's tool is active — the button still
    //    represents the variant. This is the bug this rule fixes.
    selectButtonVariant(btn, KMOD_NONE, "mesh.topoPen", label, action, variant);
    assert(action.id == "mesh.topoPen", "released modifier must not drop an active variant tool");
    assert(label == "Topology Pen", "an active variant must keep its own label");

    // 3. Primary tool active — primary wins, no variant claim.
    selectButtonVariant(btn, KMOD_NONE, "pen", label, action, variant);
    assert(action.id == "pen" && label == "Pen" && variant == "");

    // 4. Nothing active — primary, unlit.
    selectButtonVariant(btn, KMOD_NONE, "", label, action, variant);
    assert(action.id == "pen" && variant == "");

    // 5. Which physical modifier reaches a `ctrl:` variant is platform-split,
    //    and only one half compiles per build — so pin BOTH rather than leave
    //    it to whichever platform happens to run the suite.
    version (OSX) {
        // ⌘ selects it: a plain left click carrying a modifier.
        selectButtonVariant(btn, KMOD_GUI, "", label, action, variant);
        assert(action.id == "mesh.topoPen",
               "macOS: Cmd must reach a ctrl: variant");
        // Control must NOT — macOS turns Control+click into a right click, so
        // the label would advertise a variant the click can never activate.
        selectButtonVariant(btn, KMOD_CTRL, "", label, action, variant);
        assert(action.id == "pen" && label == "Pen",
               "macOS: Control must not preview a variant it cannot click");
    } else {
        selectButtonVariant(btn, KMOD_GUI, "", label, action, variant);
        assert(action.id == "pen",
               "non-macOS: Super/Cmd must NOT alias Ctrl");
        selectButtonVariant(btn, KMOD_CTRL, "", label, action, variant);
        assert(action.id == "mesh.topoPen",
               "non-macOS: Control selects the ctrl: variant");
    }

    // 6. A held modifier still beats an active variant of a DIFFERENT kind:
    //    one-shot variants have no active state, so they must never claim the
    //    button when unheld.
    Button cmdBtn;
    cmdBtn.label  = "Arc";
    cmdBtn.action = Action(ActionKind.tool, "prim.arc");
    cmdBtn.ctrl.present = true;
    cmdBtn.ctrl.label   = "Unit Arc";
    cmdBtn.ctrl.action  = Action(ActionKind.command, "prim.arc.unit");
    selectButtonVariant(cmdBtn, KMOD_NONE, "prim.arc", label, action, variant);
    assert(action.id == "prim.arc" && variant == "",
           "a command variant must not claim the button");
}

// ---------------------------------------------------------------------------
// The hidden-geometry readout (task 0613 S4, doc/hide_geometry_plan.md R9)
// ---------------------------------------------------------------------------
//
// Hidden geometry is invisible by construction, and that is precisely what
// makes it dangerous: isolate-on-selection only ever SETS hide bits, so
// isolating onto something that was already hidden empties the viewport, and a
// delete-all after a hide-unselected destroys work the user cannot see. That
// behaviour is the reference's and is deliberately not guarded against — this
// readout IS the whole mitigation, which is why it is a shared function called
// from two places rather than two hand-rolled format strings.
//
// Returns "" when nothing is hidden, so a caller renders NOTHING at all in the
// overwhelmingly common case (no row, no gap, no reserved space) — the empty
// string is the signal, not a value to print.
//
// All three planes are reported because the user's selection type decides
// which one they will notice going missing: hiding three polygons around a
// corner in vertex mode makes ONE VERTEX disappear, and "3 poly" alone does
// not explain that. Zero planes are omitted rather than printed as "0 vert",
// so the line stays short in the usual polygon-only case.
string hiddenReadout(int hiddenVerts, int hiddenEdges, int hiddenFaces) {
    import std.format : format;
    if (hiddenVerts <= 0 && hiddenEdges <= 0 && hiddenFaces <= 0) return "";
    string s = "Hidden:";
    string sep = " ";
    void part(int n, string what) {
        if (n <= 0) return;
        s ~= format("%s%d %s", sep, n, what);
        sep = ", ";
    }
    part(hiddenVerts, "vert");
    part(hiddenEdges, "edge");
    part(hiddenFaces, "poly");
    return s;
}

/// The same fact for a NARROW column: "8/12/6 hidden", or "" when nothing is.
///
/// Two spellings rather than one because the two homes have different widths,
/// and that was measured, not assumed: the prose form clipped mid-word at
/// "Hidden: 8 vert, 12 ed" in the ~145 px side panel — in exactly the state
/// (everything hidden) where losing the text matters most. Here the numbers
/// need no words: the line sits directly under three rows already labelled V,
/// E and F, in that order.
///
/// Both spellings agree on WHEN there is something to say, because the caller
/// gates on `hiddenReadout` either way and this one repeats the same test.
string hiddenReadoutCompact(int hiddenVerts, int hiddenEdges, int hiddenFaces) {
    import std.format : format;
    if (hiddenVerts <= 0 && hiddenEdges <= 0 && hiddenFaces <= 0) return "";
    return format("%d/%d/%d hidden", hiddenVerts, hiddenEdges, hiddenFaces);
}

unittest {
    // Each row picks numbers a wrong-but-plausible implementation reads
    // DIFFERENTLY, not merely a case where it produces nothing.
    //
    // 1. Nothing hidden ⇒ the empty signal. An implementation that always
    //    builds the line reads "Hidden:" here and the callers reserve a row
    //    for a mesh with nothing hidden.
    assert(hiddenReadout(0, 0, 0) == "",
        "nothing hidden must produce NO line at all, not an empty-valued one");

    // 2. Three DIFFERENT non-zero counts. This is the row that separates the
    //    plausible wrong implementations from each other: one that reads the
    //    FACE plane for all three reads "3 vert, 3 edge, 3 poly"; one that
    //    SUMS the planes reads "10 poly"; one that swaps vert/poly (the easy
    //    transposition, since faces are the stored plane and vertices the
    //    derived one) reads "3 vert, 5 edge, 2 poly". All three differ from
    //    the answer below, which is why the counts must be distinct AND the
    //    order asserted — equal counts would let the transposition through.
    assert(hiddenReadout(2, 5, 3) == "Hidden: 2 vert, 5 edge, 3 poly",
        "got: " ~ hiddenReadout(2, 5, 3));

    // 3. Only the face plane — the ordinary polygon-mode hide. An
    //    implementation that emits every plane unconditionally reads
    //    "Hidden: 0 vert, 0 edge, 3 poly".
    assert(hiddenReadout(0, 0, 3) == "Hidden: 3 poly",
        "got: " ~ hiddenReadout(0, 0, 3));

    // 4. Only the LEADING plane — pins the separator state machine. An
    //    implementation that joins with a leading ", " reads "Hidden: , 1 vert"
    //    and one that appends a trailing comma reads "Hidden: 1 vert,".
    assert(hiddenReadout(1, 0, 0) == "Hidden: 1 vert",
        "got: " ~ hiddenReadout(1, 0, 0));

    // 5. A gap in the middle — the separator must attach to the SECOND
    //    printed part, not to the second PLANE.
    assert(hiddenReadout(4, 0, 6) == "Hidden: 4 vert, 6 poly",
        "got: " ~ hiddenReadout(4, 0, 6));

    // 6. The compact spelling. Same "nothing hidden ⇒ no line" contract, and
    //    the same distinct-counts discriminator: a wrong wiring that fed it
    //    the face count three times reads "3/3/3" and a vert/poly
    //    transposition reads "3/5/2".
    assert(hiddenReadoutCompact(0, 0, 0) == "",
        "compact: nothing hidden must produce no line either");
    assert(hiddenReadoutCompact(2, 5, 3) == "2/5/3 hidden",
        "got: " ~ hiddenReadoutCompact(2, 5, 3));
    // 7. The compact form keeps the ZERO planes, unlike the prose form —
    //    deliberately, because its whole legibility rests on the reader
    //    matching the three slots to the V/E/F rows above it. Dropping a zero
    //    would slide "6" from the F slot into the V slot.
    assert(hiddenReadoutCompact(0, 0, 6) == "0/0/6 hidden",
        "got: " ~ hiddenReadoutCompact(0, 0, 6));

    // 8. The two spellings must never disagree about WHETHER to draw — that
    //    is the one property the side panel and the status bar share.
    foreach (v; 0 .. 2) foreach (e; 0 .. 2) foreach (f; 0 .. 2)
        assert((hiddenReadout(v, e, f).length > 0)
            == (hiddenReadoutCompact(v, e, f).length > 0),
            "the two readouts disagreed on emptiness");
}

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
            string label; Action action; string variant;
            selectButtonVariant(btn, mods, activeToolId, label, action, variant);

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
            // TASK 0669 — a row whose action would REFUSE if pressed is drawn
            // unavailable now, instead of the press being the only way to
            // learn. The reason comes from `ui.availability.actionRefusal`,
            // which reads what the command/tool itself declared — the same
            // answer `activateToolById` and `Command.apply()` refuse on. No
            // list of ids is consulted anywhere on this path.
            string unavailWhy = actionRefusal(reg, action,
                                              document.hasEditTarget(), activeToolId);
            bool effDisabled = btn.disabled || modeBlocked || aiGateBlocked
                            || unavailWhy.length > 0;
            recordDrawnButton("side", label, action.kind, action.id,
                              effDisabled, unavailWhy);
            if (renderStyledButton(label, sc, on, isCommand,
                                   ImVec2(-1, 0), effDisabled)) {
                if (action.kind == ActionKind.popup)
                    ImGui.OpenPopup("##popup" ~ variant ~ "_" ~ btn.label);
                else
                    dispatchAction(app, action);
            }
            if (aiGateBlocked && ImGui.IsItemHovered())
                ImGui.SetTooltip("Not available in this build");
            // "Why is this grey" answered where it is asked. The reason string
            // already exists (it is the sentence the dispatch funnel would have
            // thrown), so surfacing it costs one call. `renderStyledButton`
            // draws its own disabled look rather than wrapping the widget in
            // BeginDisabled, so the item is still hoverable and plain
            // IsItemHovered() is the right query here.
            else if (unavailWhy.length > 0 && ImGui.IsItemHovered())
                ImGui.SetTooltip(unavailWhy);
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
        // R9 — the hidden-state readout, next to the counts it qualifies. A
        // "6/6" face count on a viewport showing three faces is not a
        // contradiction the user can resolve without this line. Same linear
        // walk as the counts above (no cached counter exists anywhere, by
        // design — R13).
        //
        // COMPACT here, prose in the status bar — see `hiddenReadoutCompact`
        // for the measurement behind the split.
        {
            const string hid = hiddenReadoutCompact(mesh.countHiddenVertices(),
                                                    mesh.countHiddenEdges(),
                                                    mesh.countHiddenFaces());
            if (hid.length > 0) ImGui.TextUnformatted(hid);
        }
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
                string label; Action action; string variant;
                selectButtonVariant(btn, mods, activeToolId, label, action, variant);

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
                    else if (action.id == "select.item")    editModeId = "items";
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
                        else if (t == "item")    editModeId = "items";
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
                // Task 0642: the pressed state of a selection-type button asks
                // the CURRENT SELECTION TYPE, not the derived `editMode`. The
                // two answer differently exactly when it matters: under
                // `SelType.Item` the geometry view RETAINS the most-recent
                // geometry type (seltype.d), so an editMode-based highlight
                // would light Polygons AND Items at once and there would be no
                // on-screen difference between "in item mode" and "in polygon
                // mode". The reference's own type-query command is specified
                // the same way — it reports 1 iff the queried type is the
                // CURRENT one, with the rest of the list only tested for
                // recency — which is precisely `selTypeOrder`.
                bool on;
                if (btn.checked.present) {
                    on = popupItemChecked(btn.checked);
                } else {
                    import seltype : currentSelType, SelType;
                    const curType = currentSelType(selTypeOrder);
                    on = (editModeId == "vertices" && curType == SelType.Vertex)
                      || (editModeId == "edges"    && curType == SelType.Edge)
                      || (editModeId == "polygons" && curType == SelType.Polygon)
                      || (editModeId == "items"    && curType == SelType.Item)
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
                // TASK 0669 — same rule as the side panel: an action that
                // would refuse is drawn unavailable before the press. Same
                // resolver, so the two bars cannot disagree with each other
                // either.
                string unavailWhy = actionRefusal(reg, action,
                                                  document.hasEditTarget(), activeToolId);
                bool effDisabled = aiGateBlocked || unavailWhy.length > 0;
                recordDrawnButton("status", label, action.kind, action.id,
                                  effDisabled, unavailWhy);
                if (renderStyledButton(label, sc, on, /*isCommand=*/true,
                                       ImVec2(effW, 0), effDisabled)) {
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
                else if (unavailWhy.length > 0 && ImGui.IsItemHovered())
                    ImGui.SetTooltip(unavailWhy);
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
        // R9 — the same readout, on the always-visible row. The side panel's
        // copy sits beside the selection counts, which is where a user who is
        // ALREADY asking "how much is selected" will find it; this one is for
        // the user who is not asking anything yet and is about to delete what
        // they cannot see. It renders only when something is hidden, so the
        // button row is untouched — byte-for-byte the same widgets in the same
        // order — on every mesh with nothing hidden.
        {
            const string hid = hiddenReadout(mesh.countHiddenVertices(),
                                             mesh.countHiddenEdges(),
                                             mesh.countHiddenFaces());
            if (hid.length > 0) {
                ImGui.SameLine();
                ImGui.Dummy(ImVec2(interGroupGap, 0));
                ImGui.SameLine();
                ImGui.TextUnformatted(hid);
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
    import display_state : DrawPlan, resolveDrawPlan;

    // The value `LitShader`'s constructor seeds `u_fillColor` to. Restoring to
    // it (rather than to whichever plan just drew) keeps the program in the
    // state every non-plan caller — create-tool previews, gizmo draws — was
    // built expecting. Taken from a default-constructed plan so there is one
    // source of truth for it and not two.
    static immutable float[3] kDefaultFill = DrawPlan.init.fillColor;

    // ---- Resolve this cell's display state into what each pass may draw ----
    //
    // Task 0559 Phase 1 (doc/viewport_display_modes_plan.md). Before this,
    // every mesh pass below was unconditional: faces always, edges always,
    // background layers always the same two passes dimmed. That left no way
    // to observe — let alone test — what the renderer decided to draw.
    //
    // Now the passes read a resolved plan and nothing else, so the renderer
    // is structurally unable to draw what the plan does not describe. The
    // display endpoint dumps these same two structs, which is what makes a
    // plan dump a real assertion about drawing rather than a re-derivation
    // that can drift.
    //
    // The plan is resolved FROM THE CELL (`v.display`), not from a frame
    // value — display style is the first genuinely per-cell render input, and
    // the cell's dirty key is stamped from these same two calls.
    //
    // Phase-1 neutrality: `v.display` defaults to today's behaviour and
    // nothing writes it yet, so both plans resolve to exactly the set of
    // passes that ran before — faces lit, wireframe on, no forced vertex
    // dots, backdrop dimmed by the same factor that used to be a local
    // constant here.
    immutable DrawPlan activePlan   = resolveDrawPlan(v.display, false);
    immutable DrawPlan backdropPlan = resolveDrawPlan(v.display, true);

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

    // ---- Reference-image planes (task 0612) ------------------------------
    //
    // FIRST, immediately after the clear and BEFORE the grid below: the grid,
    // the symmetry plane, the background layers and the primary all draw over
    // it, which is what "behind the geometry" means.
    //
    // The draw contains NO placement logic. `resolvePlacement` is a pure
    // function of the plane's channels, the linked clip's pixel dimensions and
    // the item transform, and it also answers whether THIS cell shows THIS
    // plane — so this loop is a lookup and a submission, and the geometry is
    // asserted as numbers in `image_plane.d` rather than as pixels here.
    //
    // The cache is only ever LOOKED UP here. It cannot decode from a draw, by
    // construction (`lookup` has no load path), which is what stops the
    // per-cell dirty skip from turning into a decode-per-frame loop. A `Ready`
    // placement whose path is somehow not resident draws nothing this frame —
    // a state the once-per-frame `reconcile` in `app.d` makes unreachable, and
    // which must be treated as "skip", never as "decode now".
    //
    // Ordered far-to-near by view-space depth of the centre, so several planes
    // in one perspective cell composite in the right order under
    // `transparency`. With the depth test off, submission order IS the
    // ordering, so this is not optional the moment there is more than one.
    {
        import image_plane : resolvePlacementFor, ImagePlanePlacement;
        import image_cache : imagePixelCache;
        import handles.gl_util : drawImagePlane;
        import view : ProjKind;
        import std.algorithm : sort;

        static struct Drawable { float depth; ImagePlanePlacement pl; }
        Drawable[] drawables;
        foreach (lyr; document.layers) {
            if (lyr is null || !lyr.hasImagePlane) continue;
            // The clip lookup + the pure law, in one call (task 0643's
            // extraction): the item ray asks the identical question, and two
            // spellings of it could hit-test a quad this pass never drew.
            auto pl = resolvePlacementFor(document, lyr,
                                          v.camera.viewPreset,
                                          v.camera.projKind == ProjKind.Ortho);
            if (!pl.drawn) continue;
            // View-space Z of the centre; more negative = further away under
            // the GL convention, so ascending sort is far-to-near.
            immutable Vec3 c = pl.center;
            immutable float z = vp.view[2]*c.x + vp.view[6]*c.y
                              + vp.view[10]*c.z + vp.view[14];
            drawables ~= Drawable(z, pl);
        }
        if (drawables.length > 1)
            drawables.sort!((a, b) => a.depth < b.depth);
        foreach (d; drawables) {
            immutable uint tex = imagePixelCache().lookup(d.pl.sourcePath);
            drawImagePlane(d.pl.center, d.pl.halfU, d.pl.halfV,
                           d.pl.flipU, d.pl.invert, d.pl.smooth,
                           d.pl.brightness, d.pl.contrast, d.pl.transparency,
                           // restore to NO program: the very next statement
                           // below is `shader.useProgram(...)`, which binds
                           // the one this pass would otherwise have to guess.
                           tex, vp, 0);
        }
    }

    // Per-item (per-layer) transform — RENDER-ONLY (channels P4). Feed-site #1.
    // NOTE (task 0617): `document.primaryModelSpace()`, the ModelSpace picking
    // resolves against, folds ONLY `itemMatrix` — not the `tt.gpuMatrix` fold
    // below. Currently fine because picking isn't exercised mid-drag; see
    // `primaryModelSpace()`'s doc comment in document.d if that ever changes.
    // Task 0654 — with an empty item selection there is no primary and no
    // foreground geometry: `app.mesh` resolves to the empty stand-in, so the
    // pass below submits zero triangles and the matrix only has to be
    // well-formed. IDENTITY, never layer 0's transform — borrowing an
    // unrelated item's frame here would place the (empty) foreground somewhere
    // arbitrary the moment anything is selected again mid-frame.
    float[16] itemMatrix = document.hasEditTarget()
        ? document.primary.xform.composedMatrix() : identityMatrix;
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

    // ---- The grid step (task 0570) ----
    //
    // The lattice in `gridVao` is a UNIT lattice; the step it is drawn at is
    // this cell's own, derived from this cell's own zoom. So the model matrix
    // carries a uniform scale of `gridStep` and the buffer is never rebuilt.
    //
    // `gridStep` is always a LADDER RUNG, so the drawn spacing moves in
    // visible steps as the camera zooms rather than gliding — that difference
    // is the feature, not a rounding of it.
    //
    // A zero step means the view has no usable scale (a degenerate camera);
    // fall back to the unit lattice rather than collapsing the grid to a
    // point.
    float gridStep = viewGridSizeFor(vp, g_viewGrid);
    if (!(gridStep > 0)) gridStep = 1.0f;

    float[16] gridModel = [
        gridStep, 0, 0, 0,
        0, gridStep, 0, 0,
        0, 0, gridStep, 0,
        0, 0, 0,        1,
    ];
    if (auto wp = cast(WorkplaneStage)g_pipeCtx.pipeline.findByTask(TaskCode.Work)) {
        if (!wp.isAuto) {
            Vec3 n, a1, a2;
            wp.currentBasis(n, a1, a2);
            Vec3 c = wp.center;
            // Same scale, applied to the work plane's own basis. The
            // translation column is NOT scaled: the plane's origin is a
            // world point, not a lattice coordinate.
            gridModel = [
                a1.x * gridStep, a1.y * gridStep, a1.z * gridStep, 0,
                n.x  * gridStep, n.y  * gridStep, n.z  * gridStep, 0,
                a2.x * gridStep, a2.y * gridStep, a2.z * gridStep, 0,
                c.x,             c.y,             c.z,             1,
            ];
        }
    }
    // The distance fade radius is the grid's OWN half-extent, not a multiple
    // of the camera distance.
    //
    // It used to be `camera.distance * 2`, which happened to sit inside the
    // fixed 50-unit lattice at ordinary zooms and outside it when you pulled
    // far back — a latent hard square edge nobody hit often. With a
    // screen-anchored step the coincidence is gone in the other direction:
    // the lattice's half-extent becomes `50 * step`, which at the bottom of a
    // rung is ~1250 screen pixels while `2 * distance` is ~3 * the pane
    // height, so on a tall pane the fade would reach PAST the lattice and the
    // square boundary would be visible at every zoom. Tying the fade to the
    // extent removes that class of defect at every zoom and every pane size:
    // the grid always fades to nothing exactly where it ends.
    immutable float gridFade = viewGridFadeRadius(gridStep);

    // Width/height in PIXELS = FBO dims; offsets zeroed (FBO origin = corner).
    gridShader.useProgram(gridModel, vp,
        gridFade,
        cast(float)v.fbo.w, cast(float)v.fbo.h,
        0.0f, 0.0f);
    glBindVertexArray(gridVao);
    // Perf: the ground grid is three fixed submissions whose vertex count
    // tracks the lattice size, so it is a CONSTANT floor under every scene
    // frame. Counting it separately from the mesh passes is what lets a
    // reader say "the model costs N draws" without the grid in the number.
    glUniform3f(gridShader.locColor, 0.5f, 0.5f, 0.5f);
    glDrawArrays(GL_LINES, 0, gridOnlyVertCount);
    g_fc.draw(DrawPass.grid, gridOnlyVertCount);
    glUniform3f(gridShader.locColor, 0.5f, 0.15f, 0.15f);
    glDrawArrays(GL_LINES, gridOnlyVertCount, 2);
    g_fc.draw(DrawPass.grid, 2);
    glUniform3f(gridShader.locColor, 0.15f, 0.15f, 0.5f);
    glDrawArrays(GL_LINES, gridOnlyVertCount + 2, 2);
    g_fc.draw(DrawPass.grid, 2);
    glBindVertexArray(0);

    // ---- Symmetry plane ----
    //
    // DELIBERATELY NOT scaled by the grid step (task 0570), even though it
    // borrows the same lattice buffer. This is a plane INDICATOR — it exists
    // to show where the mirror is — not a measuring grid, and the read that
    // makes the ground grid a screen length says nothing about it. Tying its
    // size to zoom would be a second appearance change smuggled in on the
    // first one's evidence. It keeps its unit lattice and its
    // camera-distance fade until someone decides otherwise on purpose.
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
            g_fc.draw(DrawPass.symmetry, gridOnlyVertCount);
            glBindVertexArray(0);
        }
    }

    glDisable(GL_BLEND);

    // ---- Background layers ----
    //
    // TASK 0654 — the `> 1` fast path is now `> 1 || no edit target`, and that
    // second clause is the difference between "everything is background" and
    // "everything went dark". Background is DERIVED (`visible && !selected`),
    // so an empty selection makes every visible layer background; the per-layer
    // `isPrimary` skip below already lets them all through. But on a
    // SINGLE-layer document the old gate short-circuited before the loop, and
    // that one layer would then have been drawn by neither pass — the
    // foreground pass skips it (it is not the primary; there is no primary) and
    // this pass never ran. The user clicks empty space and their model
    // vanishes. It must dim, not disappear.
    if (document.layers.length > 1 || !document.hasEditTarget()) {
        import std.math : isNaN;
        Layer[] toDrop;
        foreach (lyr, bg; bgGpuByLayer) {
            bool stillBg = false;
            foreach (ll; document.layers)
                // Task 0615 (tier-2, §Tier-2 :2083-2090): a non-mesh layer must
                // never be "still bg" — it never gets a BgGpu entry to begin
                // with, so any prior entry for it (impossible today, but the
                // guard is the eviction side of the drawsGeometry gate below)
                // must be dropped.
                if (ll is lyr && ll.visible && !document.isPrimary(ll)
                    && kindInfo(ll.kind).drawsGeometry) {
                    stillBg = true;
                    break;
                }
            if (!stillBg) toDrop ~= lyr;
        }
        foreach (lyr; toDrop) {
            bgGpuByLayer[lyr].gpu.destroy();
            bgGpuByLayer.remove(lyr);
        }

        // The dim factor moved into the display model (it is now an output of
        // plan resolution, `backdropPlan.dim`) — it is the ONE thing that
        // distinguishes a background layer today, and the backdrop axis is
        // what will eventually replace it with a genuinely different
        // representation. Cache upkeep below stays UNCONDITIONAL on purpose:
        // a display change must never invalidate or skip a `bgGpuByLayer`
        // upload, only the DRAWS are gated.
        foreach (i, lyr; document.layers) {
            if (document.isPrimary(lyr) || !lyr.visible) continue;
            // Task 0615 Stage 4 (§Tier-2 :2102): a non-mesh layer participates
            // in neither the bg draw nor the GPU upload — skip BEFORE the
            // `BgGpu` allocation below, not after (mirrors the eviction guard
            // just above).
            if (!kindInfo(lyr.kind).drawsGeometry) continue;
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
            if (bg.uploadedVersion != lyr.meshRef().mutationVersion) {
                bg.gpu.upload(lyr.meshRef());
                bg.uploadedVersion = lyr.meshRef().mutationVersion;
            }

            // Perf: attribute this layer's submissions to the BACKDROP slots.
            // The two draws below are the same GpuMesh entry points the
            // primary uses, so without the redirect a four-layer scene's
            // backdrop would be indistinguishable from an expensive model —
            // and the fixes for those two are not the same fix.
            auto zBackdrop = g_fc.backdrop();
            if (backdropPlan.drawFaces) {
                litShader.useProgram(bgModel, vp);
                litShader.setSurfaces(lyr.meshRef().surfaces);
                litShader.setDim(backdropPlan.dim);
                litShader.setLit(backdropPlan.facesLit);
                litShader.setFillColor(backdropPlan.fillColor);
                bg.gpu.drawFaces(litShader);
                litShader.setLit(true);
                litShader.setFillColor(kDefaultFill);
                litShader.setDim(1.0f);
            }

            if (backdropPlan.drawWire) {
                shader.useProgram(bgModel, vp);
                shader.setDim(backdropPlan.dim);
                // Background layers carry no selection or hover state, so the
                // base pass is all there is here — and it reads the BACKDROP
                // side of the activity axis, never the active side.
                bg.gpu.drawEdges(shader.locColor, -1, [], [],
                    BaseWire(true, shader.locAlpha, backdropPlan.wireAlpha));
                shader.setDim(1.0f);
            }
        }
    }

    // Install background snap sources (layers Stage 5). The parallel
    // `snapSrcLayerIdx` (topology-pen P0 NIT-3) records each source's
    // Document-layer index (this loop's `i`) so the CONS stage's
    // background-surface raycast can publish a real Document-layer index
    // in `ConstrainHitPacket.layer` instead of the bgSrc-order slot.
    {
        import snap : setBackgroundSnapSources;
        import document : Document;
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
                    // loop above (`lyr.xform.composedMatrix()`) — a background
                    // layer now snaps where it is DRAWN, not at its identity
                    // pose.
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
        import snap : setItemSnapFrames, ItemSnapFrame;
        import document : kindInfo;
        ItemSnapFrame[] itemFrames;
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
            itemFrames ~= buildItemFrame(lyr);
        }
        setItemSnapFrames(itemFrames);
    }

    // ---- Which selection type this cell draws FEEDBACK for (task 0655) -----
    //
    // The SAME query the viewport pick asks — the ordering with the
    // item-inclusive candidate set — and it is the same query on purpose:
    // "which elements can this click select" and "which elements does this
    // frame show as selected" are one question, and the two answers drifting
    // apart is exactly the state that was measured as a divergence.
    //
    // NOT `editMode`, which the three gates below used to read. `editMode` is
    // that query asked WITHOUT `Item`, so under the item type it still names a
    // geometry type — and the passes kept painting orange vertex dots, the
    // checker overlay and selected-edge colour for a geometry selection the
    // click could no longer reach. Measured against the reference: under the
    // item type a standing geometry selection is KEPT (it is still in
    // `/api/selection`) and NOT DRAWN. Keeping it is the mesh's business and
    // nothing here touches it; not drawing it is this line.
    //
    // The item-highlight pass further down asks `currentSelType` directly.
    // That is the same answer by construction — with all four types always in
    // the ordering, the item-inclusive resolve IS the front — and it is left
    // spelled its own way because it is asking a different question ("is the
    // item type current"), not gating an element pass.
    immutable SelType selFeedbackType = viewportPickType(selTypeOrder);

    // ---- Faces (Blinn-Phong, or a flat fill) ----
    // Gated on the plan's SHADING group. `drawFaces == false` means no face
    // pass AT ALL — not a depth-only one: a lines-only style has to be
    // see-through, so back-side edges stay visible.
    //
    // `facesLit == false` is the Solid style (0589, corrected in 0592): the
    // SAME face pass, the same geometry, the same highlight branches — but
    // neither the lighting term NOR the material. The fill's base becomes
    // `activePlan.fillColor` (the viewport colour scheme's), which is why the
    // two uniforms are set together below: "unlit" and "not from the material"
    // are one decision, and a call site that set only the first would draw a
    // black surface.
    //
    // Still deliberately not a separate pass or a separate program. The
    // reference does register Solid as its own style, and its style record is
    // genuinely a different shape — no light setup, one draw sub-pass instead
    // of three. But everything that differs is expressible here: the light
    // term is behind a uniform branch, the missing background sub-pass is a
    // resolved `drawFaces`, and we have no transparency sub-pass to omit. What
    // a second draw path would buy is a second place for hover tint, selection
    // highlight and per-surface colour to quietly diverge, which is the actual
    // risk this axis carries.
    {
        auto zMesh = g_perf.scope_(Cat.drawMesh);
        if (activePlan.drawFaces) {
            litShader.useProgram(meshModel, vp);
            litShader.setSurfaces(mesh.surfaces);
            litShader.setLit(activePlan.facesLit);
            litShader.setFillColor(activePlan.fillColor);
            bool toolFaceHover = activeTool !is null
                              && activeTool.wantsHoverForType(EditMode.Polygons)
                              && hoveredFace >= 0;
            if (selFeedbackType == SelType.Polygon) {
                gpu.drawFacesHighlighted(litShader, hoveredFace, mesh.selectedFaces);
            } else if (toolFaceHover) {
                gpu.drawFacesHighlighted(litShader, hoveredFace, (bool[]).init);
            } else {
                gpu.drawFaces(litShader);
            }
            // Restore, same discipline as the backdrop pass's setDim: the
            // program is shared with every preview/gizmo draw downstream.
            litShader.setLit(true);
            litShader.setFillColor(kDefaultFill);
        }
    }

    // Checkerboard overlay for selected faces (Polygons mode).
    if (selFeedbackType == SelType.Polygon) {
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
    // The plan's OVERLAY group reaches every branch of the chain below, not
    // just the bare-wireframe one, and it reaches them through `BaseWire` —
    // which addresses the base (unselected, unhovered) line pass INSIDE
    // drawEdges and leaves the selection and hover passes alone. That is the
    // whole point: switching the overlay off must not take selection feedback
    // with it. Gating the chain itself, or early-returning from drawEdges,
    // would do exactly that, and is the named wrong implementation.
    immutable BaseWire baseWire = BaseWire(
        activePlan.drawWire, shader.locAlpha, activePlan.wireAlpha);
    {
        auto zEdges = g_perf.scope_(Cat.drawEdges);
        if (selFeedbackType == SelType.Edge) {
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
            gpu.drawEdges(shader.locColor, hovForDraw, mesh.selectedEdges, loopMask,
                          baseWire);
        } else if (selFeedbackType == SelType.Polygon) {
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
            gpu.drawEdges(shader.locColor, -1, faceSelEdgesCache, [], baseWire);

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
                    gpu.drawEdges(shader.locColor, -1, mesh.selectedEdges,
                                  loopSelMask, baseWire);
                }
            }
        } else if (showEdgeHover && hoveredEdge >= 0) {
            const bool[] loopMask =
                (activeTool !is null && activeTool.wantsEdgeLoopHover())
                    ? rebuildLoopHoverMask(hoveredEdge)
                    : (bool[]).init;
            gpu.drawEdges(shader.locColor, hoveredEdge, [], loopMask, baseWire);
        } else if (activePlan.drawWire) {
            // The bare-overlay branch: no selection set, no hover index, so
            // `baseWire` is the ONLY thing it would draw. Kept as an explicit
            // early-out rather than a `BaseWire(false, ...)` call so that an
            // overlay of "none" with nothing selected issues no GL at all —
            // not a VAO bind and a loop over zero batches.
            gpu.drawEdges(shader.locColor, -1, [], [], baseWire);
        }
    }

    // ---- Item highlight (task 0647) ----
    //
    // Under the Item selection type the unit of both selection and hover is the
    // WHOLE item, so the feedback changes scale with it: the item under the
    // cursor has its entire wireframe repainted, and so does every selected
    // item. All of it MEASURED (doc fixture `tests/fixtures/
    // item_hover_highlight.json`) — and the parts that were measured are the
    // parts a plausible wrong implementation gets wrong:
    //
    //   * the UNIT is the item, not the polygon under the cursor. A second
    //     probe on a different polygon of the same item painted the identical
    //     pixel set.
    //   * what is painted is EDGES. A probe 1x1 m deep inside a face changed
    //     0 of 1600 pixels, so this is not a surface tint; interior edges DID
    //     paint (307 px of 956), so it is not a silhouette either.
    //   * the COLOUR is a three-state function of (selected, hovered), and the
    //     hover colour is NOT the selection colour — that was the question the
    //     capture existed to answer. `itemHighlightColor` owns the law.
    //
    // WHY HERE, after the edges pass and before the vertex dots: this pass
    // paints OVER the base wireframe, which must already be down, and under
    // the gizmo, which must stay on top. Every layer is drawn in this one
    // place rather than each in its own pass — a background layer highlighted
    // back in the backdrop loop would be painted over by the primary's own
    // depth-writing face pass, which runs after it.
    //
    // The gate is `currentSelType`, not `editMode`: `editMode` still reads
    // whatever geometry type was last used (that is what makes 1/2/3 restore
    // it), so an implementation gated on it would light items in Vertices mode.
    {
        import seltype          : currentSelType, SelType;
        import document         : kindInfo;
        import viewport_scheme  : itemHighlight, itemHighlightColor, ItemHighlight;
        import hover_state      : g_hoveredItem;
        import image_plane      : resolvePlacementFor;
        import handles.gl_util  : drawWorldSegment;
        import view             : ProjKind;

        if (currentSelType(selTypeOrder) == SelType.Item) {
            auto zItem = g_perf.scope_(Cat.drawOverlays);
            foreach (li, lyr; document.layers) {
                if (lyr is null || !lyr.visible) continue;

                // One colour law for every kind of item — computed before the
                // kind branch precisely so the two cannot drift into two rules.
                immutable ItemHighlight state =
                    itemHighlight(lyr.selected, cast(int)li == g_hoveredItem);
                if (state == ItemHighlight.none) continue;

                // An IMAGE PLANE is highlighted by its BORDER, because it has
                // no wireframe to repaint — measured (`doc/tasks/0647-evidence/`):
                // the reference paints a plane's rectangular border, 2 px wide,
                // in the same three colours as a mesh's edges, and never tints
                // the image itself. Handled before the `drawsGeometry` gate
                // below, which a plane fails by construction: task 0643 made
                // planes pickable, so leaving them out here would produce an
                // item that can be hovered and selected with no cue at all.
                if (lyr.hasImagePlane) {
                    auto pl = resolvePlacementFor(document, lyr,
                                                  v.camera.viewPreset,
                                                  v.camera.projKind == ProjKind.Ortho);
                    if (!pl.drawn) continue;   // same gate the plane draw used
                    immutable Vec3 pc = itemHighlightColor(state);
                    // A FIXED-SIZE array, so the corner pairs live on the stack:
                    // a `[[a,b], …]` slice literal here would allocate on the GC
                    // every frame a backdrop is lit.
                    immutable Vec3[2][4] segs = [
                        [pl.center - pl.halfU - pl.halfV, pl.center + pl.halfU - pl.halfV],
                        [pl.center + pl.halfU - pl.halfV, pl.center + pl.halfU + pl.halfV],
                        [pl.center + pl.halfU + pl.halfV, pl.center - pl.halfU + pl.halfV],
                        [pl.center - pl.halfU + pl.halfV, pl.center - pl.halfU - pl.halfV],
                    ];
                    // `smooth = false`: this colour is READ BACK as an exact
                    // value by the item tests, and an anti-aliased edge carries
                    // a blend of it rather than it.
                    foreach (seg; segs)
                        drawWorldSegment(seg[0], seg[1], vp, pc, 2.0f,
                                         shader.program, 1.0f, /*smooth=*/false);
                    continue;
                }

                // Same capability bit the item ray picks against
                // (`item_pick.d`), so nothing can be hovered that cannot be
                // painted, or painted that cannot be hovered.
                if (!kindInfo(lyr.kind).drawsGeometry) continue;

                immutable Vec3 c = itemHighlightColor(state);

                // The primary draws through the SAME GpuMesh and the SAME
                // model matrix the passes above used — `meshModel`, which
                // folds a live tool matrix, so a highlighted item being
                // dragged stays on its geometry instead of trailing it.
                // Background layers use the buffers the backdrop loop
                // uploaded; a visible non-primary geometry layer always has an
                // entry there (its gate is the same three conditions as this
                // loop's, minus selection), so a missing one means the two
                // gates have drifted and skipping is the safe read.
                if (document.isPrimary(lyr)) {
                    shader.useProgram(meshModel, vp);
                    gpu.drawItemHighlight(shader.locColor, c.x, c.y, c.z);
                } else if (auto bg = lyr in bgGpuByLayer) {
                    // Named, not inlined: `useProgram` takes the matrix by
                    // `ref const`, so the composed rvalue needs a home.
                    float[16] itemModel = lyr.xform.composedMatrix();
                    shader.useProgram(itemModel, vp);
                    (*bg).gpu.drawItemHighlight(shader.locColor, c.x, c.y, c.z);
                }
            }
            // Leave the program bound to the primary's matrix: everything
            // downstream (vertex dots, tool overlays) was written expecting it.
            shader.useProgram(meshModel, vp);
        }
    }

    // ---- Vertex dots ----
    // `drawVerts` is a FORCING term from the surface style (a lines-only
    // style draws vertices as well as edges). The selection-type gate beside
    // it is a separate, unmodelled axis; the two are OR-ed. Today no style
    // forces it, so this reads as it always did — except under the item type,
    // where the dots (and with them the orange SELECTED dots) now go away.
    // That is the pass the reference's per-vertex colour census measured as
    // absent, and it is the visible half of "kept but not drawn".
    if (activePlan.drawVerts || selFeedbackType == SelType.Vertex) {
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

// =========================================================================
// app.d decomp phase B: the four inline ImGui panels of app.d's main loop,
// moved VERBATIM (same `with (app)` seam as the 0419 panels above):
//   drawAi3dModal            -- was app.d ~5650-5874 ("AI3D Generate modal")
//   drawRemeshModal          -- was app.d ~5876-5978 ("Quad Remesh modal")
//   drawQuitGuardModal       -- was app.d ~5980-6034 ("Unsaved-changes quit
//                               guard + confirmation modal")
//   drawCommandHistoryPanel  -- was app.d ~6304-6651 ("Command History")
// The ONLY body edits vs the pre-move text are Edit-class-2 address-of
// sites (precedent: registration.d's &promoteItemType): ImGui's
// SliderInt/SliderFloat/Checkbox take a raw pointer, and `&prop` on a
// @property ref field yields the property FUNCTION's address, so the 8
// widget calls read the `namePtr` storage field directly:
//   &ai3dMaxFaces -> ai3dMaxFacesPtr, &remeshTargetQuads ->
//   remeshTargetQuadsPtr, &remeshAdaptivity -> remeshAdaptivityPtr,
//   &remeshSharpEdge -> remeshSharpEdgePtr, &historyShowArgs ->
//   historyShowArgsPtr, &historyShowRowNumbers -> historyShowRowNumbersPtr,
//   &historyShowTimestamps -> historyShowTimestampsPtr,
//   &historyShowCommandIds -> historyShowCommandIdsPtr.
// =========================================================================

void drawAi3dModal(EditorApp app) {
    with (app) {
        // ---- AI3D Generate modal (task 0381 Phase 3) -----------------------
        // Same BeginPopupModal convention as ArgsDialog (args_dialog.d:48):
        // pendingOpen → OpenPopup once, then cleared; BeginPopupModal
        // returns true while open, false after ESC/[X]/CloseCurrentPopup.
        // Reads ONLY the immutable ai3dModal snapshot (written by
        // onAi3dEvent, near runCommand) plus the controller's busy()/
        // start()/requestCancel() surface — it never touches the queue or
        // any Document/Mesh state directly.
        if (ai3dModalOpen) {
            import std.format : format;
            import std.string : fromStringz;

            if (ai3dModalPendingOpen) {
                ImGui.OpenPopup("Generate 3D");
                ai3dModalPendingOpen = false;
            }

            if (ImGui.BeginPopupModal("Generate 3D", null, ImGuiWindowFlags.AlwaysAutoResize)) {
                // Auto-close once the generated mesh has landed as a new layer:
                // the action happened, so the modal dismisses itself. A failure
                // (state != "succeeded") keeps it open so the error stays visible.
                if (ai3dModal.state == "succeeded") {
                    ImGui.CloseCurrentPopup();
                    ai3dModalOpen = false;
                }

                // ---- AI worker lifecycle (task 0403) ---------------------------
                // Ai3dWorkerManager tracks ONLY the subprocess the editor itself
                // spawned (worker_manager.d's module doc) — Start/Stop here can
                // never touch a worker some other process started. The manual
                // "Worker URL" field below stays live for advanced users who
                // point the editor at an externally-managed worker instead; a
                // successful Start overwrites it with the spawned worker's URL.
                {
                    import core.time : seconds;

                    final switch (ai3dWorkerManager.state()) {
                        case Ai3dWorkerState.notInstalled:
                            ImGui.Text("AI worker: not installed");
                            if (ai3dWorkerManager.installBusy()) {
                                ImGui.Text(ai3dWorkerManager.installState() == Ai3dInstallState.runningInstall
                                    ? "Installing runtime..." : "Downloading model...");
                                ImGui.BeginChild("ai3dInstallLog", ImVec2(360, 90), true);
                                ImGui.TextUnformatted(ai3dWorkerManager.installLogTail(2000));
                                ImGui.SetScrollHereY(1.0f);
                                ImGui.EndChild();
                                if (ImGui.Button("Cancel Install")) ai3dWorkerManager.cancelInstall();
                            } else {
                                if (ai3dWorkerManager.installState() == Ai3dInstallState.failed)
                                    ImGui.TextUnformatted("Install failed: " ~ ai3dWorkerManager.installMessage());
                                if (ImGui.Button("Install")) {
                                    ai3dWorkerManager.clearInstall();
                                    ai3dInstallConfirmOpen        = true;
                                    ai3dInstallConfirmPendingOpen = true;
                                }
                            }
                            break;
                        case Ai3dWorkerState.installedStopped:
                            ImGui.Text(ai3dWorkerManager.modelPresent()
                                ? "AI worker: installed, not running"
                                : "AI worker: installed (model not downloaded yet), not running");
                            if (ImGui.Button("Start")) {
                                if (ai3dWorkerManager.startWorker()) {
                                    ai3dWorkerStarting        = true;
                                    ai3dWorkerStartDeadline   = MonoTime.currTime + 90.seconds;
                                    ai3dWorkerNextHealthProbe = MonoTime.currTime;
                                    const spawnedUrl = ai3dWorkerManager.workerUrl();
                                    ai3dWorkerUrlBuf[] = 0;
                                    ai3dWorkerUrlBuf[0 .. spawnedUrl.length] = spawnedUrl;
                                }
                            }
                            break;
                        case Ai3dWorkerState.running:
                            ImGui.Text("AI worker: running (" ~ ai3dWorkerManager.workerUrl() ~ ")");
                            if (ImGui.Button("Stop")) {
                                ai3dWorkerManager.stopWorker();
                                ai3dWorkerStarting = false;
                            }
                            break;
                    }

                    // Post-Start health poll: throttled to ~1/s (never
                    // per-frame — probeHealth() spawns a short-lived thread
                    // per call) against the SAME ai3dModal.health* snapshot
                    // the manual health line below reads.
                    if (ai3dWorkerStarting) {
                        ImGui.Text("Waiting for the worker to become ready...");
                        if (MonoTime.currTime >= ai3dWorkerNextHealthProbe) {
                            ai3dController.probeHealth(ai3dWorkerManager.workerUrl());
                            ai3dWorkerNextHealthProbe = MonoTime.currTime + 1.seconds;
                        }
                        if (ai3dModal.healthChecked && ai3dModal.healthOk) {
                            ai3dWorkerStarting = false;
                        } else if (MonoTime.currTime >= ai3dWorkerStartDeadline) {
                            ai3dWorkerStarting     = false;
                            ai3dModal.errorCode    = "worker_start_timeout";
                            ai3dModal.errorMessage = "AI worker did not become ready in time";
                        }
                    }
                }

                // Install confirmation — nested popup, same pendingOpen
                // convention as the Generate 3D modal itself (ai3dModalOpen /
                // ai3dModalPendingOpen above).
                if (ai3dInstallConfirmOpen) {
                    if (ai3dInstallConfirmPendingOpen) {
                        ImGui.OpenPopup("Install AI Worker?");
                        ai3dInstallConfirmPendingOpen = false;
                    }
                    if (ImGui.BeginPopupModal("Install AI Worker?", null, ImGuiWindowFlags.AlwaysAutoResize)) {
                        ImGui.TextUnformatted(format(
                            "Installs the AI generation runtime to\n%s (~6-8 GB)\n"
                            ~ "and downloads the ~4 GB model afterwards. Continue?",
                            ai3dDefaultInstallLocation()));
                        if (ImGui.Button("Install")) {
                            ai3dWorkerManager.runInstall();
                            ImGui.CloseCurrentPopup();
                            ai3dInstallConfirmOpen = false;
                        }
                        ImGui.SameLine();
                        if (ImGui.Button("Cancel")) {
                            ImGui.CloseCurrentPopup();
                            ai3dInstallConfirmOpen = false;
                        }
                        ImGui.EndPopup();
                    } else {
                        ai3dInstallConfirmOpen = false; // closed via ESC
                    }
                }

                ImGui.Separator();

                ImGui.Text("Image: " ~ ai3dPickedImagePath);

                ImGui.SetNextItemWidth(280);
                ImGui.InputText("Worker URL", ai3dWorkerUrlBuf[]);

                ImGui.SetNextItemWidth(280);
                ImGui.SliderInt("Max faces", ai3dMaxFacesPtr, 1_000, cast(int) Ai3dMaxTotalFaces);
                // SliderInt's vMin/vMax only bound the drag/click gesture —
                // its text-entry mode (Ctrl+click) can still land an
                // out-of-range value, so clamp right after, same as every
                // other numeric-from-widget value in this codebase.
                if (ai3dMaxFaces < 1_000) ai3dMaxFaces = 1_000;
                if (ai3dMaxFaces > cast(int) Ai3dMaxTotalFaces) ai3dMaxFaces = cast(int) Ai3dMaxTotalFaces;

                const bool ai3dJobRunning = ai3dController.busy();

                if (!ai3dModal.healthChecked) {
                    ImGui.Text("Checking worker health…");
                } else if (!ai3dModal.healthOk) {
                    ImGui.Text("Worker not ready: "
                        ~ (ai3dModal.healthMessage.length ? ai3dModal.healthMessage : ai3dModal.errorCode));
                } else {
                    ImGui.Text(format("Worker ready (backend=%s, protocol=%d)",
                                       ai3dModal.healthBackend, ai3dModal.healthProtocol));
                }

                // Health-gated (Phase 0/3): Generate only enables once a
                // standalone probeHealth() round trip reports a compatible
                // protocol and OBJ capability. The backend id (triposr,
                // trellis, fake, …) is informational only — any conformant
                // worker that speaks protocol 1 and emits OBJ is accepted, so
                // we deliberately do NOT pin a specific backend name here.
                const bool healthy = ai3dModal.healthChecked && ai3dModal.healthOk
                    && ai3dModal.healthProtocol == 1
                    && ai3dModal.healthObjCapable;

                ImGui.Separator();

                // Cancel is the single close affordance (no separate Dismiss):
                // idle -> just closes; running -> aborts the job AND closes so a
                // job can't complete and silently import a layer after the modal
                // is gone. A successful generate auto-closes above.
                void closeAi3dModal() {
                    if (ai3dController.busy()) ai3dController.requestCancel();
                    ImGui.CloseCurrentPopup();
                    ai3dModalOpen = false;
                }

                if (!ai3dJobRunning) {
                    if (!healthy) ImGui.BeginDisabled();
                    if (ImGui.Button("Generate")) {
                        ai3dModal.state       = "";
                        ai3dModal.stage       = "";
                        ai3dModal.progress    = 0;
                        ai3dModal.errorCode    = null;
                        ai3dModal.errorMessage = null;
                        const workerUrl = cast(string) fromStringz(ai3dWorkerUrlBuf.ptr).dup;
                        // Cold-start budget: the first generation after a worker
                        // launch loads the ~5 GB model AND JIT-compiles the spconv /
                        // flexicubes CUDA kernels, which can run several minutes — a
                        // 2-min cap cut that off client-side (BrokenPipe) even though
                        // the worker finished the mesh. Warm jobs still return in
                        // ~15-35 s, so the 10-min ceiling costs steady-state nothing.
                        ai3dController.start(ai3dPickedImagePath,
                            workerUrl.length ? workerUrl : ai3dDefaultWorkerUrl,
                            Ai3dMaxGenerationDeadlineMs, ai3dMaxFaces);
                    }
                    if (!healthy) ImGui.EndDisabled();
                    ImGui.SameLine();
                    if (ImGui.Button("Cancel")) closeAi3dModal();
                } else {
                    ImGui.Text(format("%s: %s (%.0f%%)",
                        ai3dModal.state.length ? ai3dModal.state : "running",
                        ai3dModal.stage, ai3dModal.progress * 100.0));
                    ImGui.SameLine();
                    if (ImGui.Button("Cancel")) closeAi3dModal();
                }

                // Only the error survives on screen (a success auto-closes).
                // TextUnformatted (not printf-style Text): an error message can
                // carry a "%" that Text would read as a conversion off an empty
                // va_list.
                if (ai3dModal.errorCode.length)
                    ImGui.TextUnformatted("Error: " ~ ai3dModal.errorCode
                                          ~ " — " ~ ai3dModal.errorMessage);
                ImGui.EndPopup();
            } else {
                // Closed via ESC — same semantics as the Cancel button: abort
                // any in-flight job so it can't land after the modal is gone.
                if (ai3dController.busy()) ai3dController.requestCancel();
                ai3dModalOpen = false;
            }
        }
    }
}

void drawRemeshModal(EditorApp app) {
    with (app) {
        // ---- Quad Remesh modal (source/remesh/remesh_job.d) -----------------
        // Same BeginPopupModal convention as the AI3D modal above. Opened by
        // `mesh.remesh.open` (registered below, near the other mesh.remesh.*
        // factories). Unlike ai3dModal, this reads remeshJob.state()/busy()/
        // message() DIRECTLY every frame — RemeshJob is polled synchronously
        // in this same thread (no worker thread / event queue to snapshot).
        if (remeshModalOpen) {
            if (remeshModalPendingOpen) {
                ImGui.OpenPopup("Remesh (Quad)");
                remeshModalPendingOpen = false;
            }

            if (ImGui.BeginPopupModal("Remesh (Quad)", null, ImGuiWindowFlags.AlwaysAutoResize)) {
                // Auto-close once a remesh has actually landed (set by
                // tickRemeshJob on a successful apply): the action happened, so
                // the window dismisses itself — no manual close needed.
                if (remeshModalPendingClose) {
                    remeshModalPendingClose = false;
                    ImGui.CloseCurrentPopup();
                    remeshModalOpen = false;
                }

                ImGui.SetNextItemWidth(280);
                ImGui.SliderInt("Target Quads", remeshTargetQuadsPtr,
                                 MIN_REMESH_TARGET_QUADS, cast(int) MAX_REMESH_TARGET_QUADS);
                // SliderInt's vMin/vMax only bound the drag/click gesture — its
                // text-entry mode (Ctrl+click) can still land an out-of-range
                // value, so clamp right after (same convention as ai3dMaxFaces
                // above; the REAL authority is RemeshJob.start()'s kernel clamp).
                if (remeshTargetQuads < MIN_REMESH_TARGET_QUADS) remeshTargetQuads = MIN_REMESH_TARGET_QUADS;
                if (remeshTargetQuads > cast(int) MAX_REMESH_TARGET_QUADS) remeshTargetQuads = cast(int) MAX_REMESH_TARGET_QUADS;

                ImGui.SetNextItemWidth(280);
                ImGui.SliderFloat("Adaptivity", remeshAdaptivityPtr, 0.0f, 10.0f);
                if (remeshAdaptivity < 0.0f) remeshAdaptivity = 0.0f;
                if (remeshAdaptivity > 10.0f) remeshAdaptivity = 10.0f;

                ImGui.SetNextItemWidth(280);
                ImGui.SliderFloat("Sharp Edge (deg)", remeshSharpEdgePtr, 0.0f, 180.0f);
                if (remeshSharpEdge < 0.0f) remeshSharpEdge = 0.0f;
                if (remeshSharpEdge > 180.0f) remeshSharpEdge = 180.0f;

                ImGui.Separator();

                // Cancel is the single close affordance (no separate Dismiss):
                // idle -> just closes the window; running -> aborts the job AND
                // closes. A successful remesh auto-closes above, so the only
                // time you click Cancel after starting is to abandon a run.
                void closeRemeshModal() {
                    if (remeshJob.busy()) remeshJob.cancel();
                    ImGui.CloseCurrentPopup();
                    remeshModalOpen = false;
                }

                const bool remeshBusy = remeshJob.busy();
                if (!remeshBusy) {
                    if (ImGui.Button("Remesh")) {
                        remeshLastError   = null;
                        remeshLastSummary = null;
                        RemeshParams p;
                        p.targetQuads = remeshTargetQuads;
                        p.adaptivity  = remeshAdaptivity;
                        p.sharpEdge   = remeshSharpEdge;
                        // Task 0385: a non-empty face selection remeshes just
                        // that region and stitches it back in (see
                        // commands.mesh.remesh.RemeshStart, which mirrors this
                        // same selection -> region-mask translation for the
                        // headless/HTTP `mesh.remesh.start` path).
                        const(bool)[] regionMask =
                            mesh().hasAnySelectedFaces() ? mesh().selectedFaces : null;
                        remeshJob.start(mesh(), p, regionMask);
                        if (remeshJob.state() == RemeshJob.State.failed)
                            remeshLastError = remeshJob.message();
                    }
                    ImGui.SameLine();
                    if (ImGui.Button("Cancel")) closeRemeshModal();
                } else {
                    ImGui.TextUnformatted("Remeshing...");
                    ImGui.SameLine();
                    if (ImGui.Button("Cancel")) closeRemeshModal();
                }

                // The error survives on screen across the modal staying open
                // (a full success auto-closes it). A PARTIAL success (task
                // 0386: some region components skipped) still auto-closes —
                // remeshLastSummary shows for the one frame before that
                // happens, same as a plain "Done" summary always has.
                // TextUnformatted (not Text): either message can carry the
                // helper's raw stderr tail with stray "%", which the printf-
                // style ImGui.Text would read as a conversion off an empty
                // va_list.
                if (remeshLastError.length)
                    ImGui.TextUnformatted("Error: " ~ remeshLastError);
                else if (remeshLastSummary.length)
                    ImGui.TextUnformatted(remeshLastSummary);
                ImGui.EndPopup();
            } else {
                // Closed via ESC — same semantics as the Cancel button: abort
                // any in-flight job so it can't land after the modal is gone.
                if (remeshJob.busy()) remeshJob.cancel();
                remeshModalOpen = false;
            }
        }
    }
}

void drawQuitGuardModal(EditorApp app) {
    with (app) {
        // ---- Unsaved-changes quit guard + confirmation modal (task 0434) ----
        // Drain the close request once per frame. Placed inside the ImGui frame
        // (after the menu bar and the other modals are drawn) so a same-frame
        // File→Quit, a Ctrl+Q from the event phase, and an SDL_QUIT all land
        // here. A dirty document opens the confirm modal; a clean one — or any
        // --test session (the harness closes the window and must not block on a
        // dialog) — exits immediately.
        if (quitRequested) {
            import io.doc_state : docDirty;
            quitRequested = false;
            if (docDirty() && !command.g_testMode) {
                quitConfirmOpen    = true;
                quitConfirmPending = true;
            } else {
                running = false;
            }
        }
        if (quitConfirmOpen) {
            if (quitConfirmPending) {
                ImGui.OpenPopup("Unsaved Changes");
                quitConfirmPending = false;
            }
            if (ImGui.BeginPopupModal("Unsaved Changes", null,
                                      ImGuiWindowFlags.AlwaysAutoResize)) {
                ImGui.TextUnformatted(
                    "You have unsaved changes. Do you really want to exit?");
                ImGui.Separator();
                // Save: write via the ordinary file.save command (prompts if the
                // document is untitled). The exit is DEFERRED to the post-flush
                // settle (quitAfterSave) so a cancelled Save dialog — which
                // leaves the document dirty — aborts the quit instead of losing
                // work. Save→exit is the destructive-safe default, so it leads.
                if (ImGui.Button("Save")) {
                    runCommand(reg.commandFactories["file.save"]());
                    quitAfterSave   = true;
                    quitConfirmOpen = false;
                    ImGui.CloseCurrentPopup();
                }
                ImGui.SameLine();
                if (ImGui.Button("Yes")) {          // discard changes and exit
                    running         = false;
                    quitConfirmOpen = false;
                    ImGui.CloseCurrentPopup();
                }
                ImGui.SameLine();
                if (ImGui.Button("No")) {           // cancel the quit
                    quitConfirmOpen = false;
                    ImGui.CloseCurrentPopup();
                }
                ImGui.EndPopup();
            } else {
                // Closed via ESC / [X] — same semantics as No: cancel the quit.
                quitConfirmOpen = false;
            }
        }

        // ---- Command-failure notice (task 0616 review B1) ----------------
        // THE ONLY PLACE A DECLINED COMMAND BECOMES VISIBLE. `log.d`'s single
        // sink is a stderr echo and no UI listens to it, so before this the
        // File → Open of a pre-v8 document simply did nothing on screen. The
        // text (and the decision that there is any) comes from
        // `ui.command_notice.commandNoticeText`, driven by `runCommand`.
        //
        // NOT gated on `g_testMode`, unlike the quit guard above: that one is
        // gated because it would BLOCK the harness's window close, whereas
        // this one is only ever raised by a command that declined WITH a
        // reason through the keyboard/UI path — which `--test` does not do
        // (a pathless `file.load` in test mode returns early and sets no
        // reason). Leaving it live keeps the surface real in the same binary
        // the tests run.
        if (noticeOpen) {
            if (noticePending) {
                ImGui.OpenPopup("Command Failed");
                noticePending = false;
            }
            if (ImGui.BeginPopupModal("Command Failed", null,
                                      ImGuiWindowFlags.AlwaysAutoResize)) {
                // TextUnformatted, not TextDisabled/Text: the reason carries a
                // user-supplied FILE PATH, and this is the overload that takes
                // no format string at all.
                ImGui.TextUnformatted(noticeText);
                ImGui.Separator();
                if (ImGui.Button("OK")) {
                    noticeOpen = false;
                    ImGui.CloseCurrentPopup();
                }
                ImGui.EndPopup();
            } else {
                noticeOpen = false;   // closed via ESC / [X]
            }
        }
    }
}

void drawCommandHistoryPanel(EditorApp app) {
    with (app) {
        // ---- Command History (floating) ----
        // Toggled by the history.show command. Layout (history-panel
        // design doc Phase 1): single chronological list, OLDEST top →
        // NEWEST bottom, with a
        // cursor row marking the current undo point. Entries below
        // the cursor are pending-redo and render dimmed. Per-undo
        // row keeps the `>` replay button.
        if (showHistoryPanel) {
            pushPanelChromeStyle();
            ImGui.SetNextWindowPos(ImVec2(layout.sideW + 10, 130), ImGuiCond.FirstUseEver);
            ImGui.SetNextWindowSize(ImVec2(320, 380), ImGuiCond.FirstUseEver);
            bool open = showHistoryPanel;
            if (ImGui.Begin("Command History", &open)) {
                import imgui_style : pushPopupStyle, popPopupStyle;
                auto undoArr = history.undoEntries();
                auto redoArr = history.redoEntries();
                size_t total = undoArr.length + redoArr.length;

                // Panel-chrome text is BLACK on grey(143). The
                // default TextDisabled (semi-transparent gray) reads
                // washed out — drop to the popup palette's "disabled"
                // shade (60,60,60) which has the same readability as
                // a status-bar menu item.
                ImGui.PushStyleColor(ImGuiCol.Text,
                    ImVec4(0.235f, 0.235f, 0.235f, 1.0f));
                ImGui.Text("%d / %d",
                    cast(int)undoArr.length, cast(int)total);
                ImGui.PopStyleColor();

                // Phase 7: macro recorder strip. Three small buttons
                // route through the same `macro.*` command path that
                // /api/command uses, so headless tests and UI clicks
                // exercise one code path. Buttons grey-out based on
                // recorder state to keep affordances obvious.
                ImGui.SameLine();
                bool recActive = macroRecorder.active;
                if (recActive)
                    ImGui.PushStyleColor(ImGuiCol.Text,
                        ImVec4(0.95f, 0.3f, 0.3f, 1.0f));
                ImGui.BeginDisabled(recActive);
                if (ImGui.SmallButton("Rec")) {
                    if (commandHandlerDelegate !is null)
                        commandHandlerDelegate("macro.record",
                            `{"state":1}`);
                }
                ImGui.EndDisabled();
                if (recActive) ImGui.PopStyleColor();
                ImGui.SameLine();
                ImGui.BeginDisabled(!recActive);
                if (ImGui.SmallButton("Stop")) {
                    if (commandHandlerDelegate !is null)
                        commandHandlerDelegate("macro.record",
                            `{"state":0}`);
                }
                ImGui.EndDisabled();
                ImGui.SameLine();
                ImGui.BeginDisabled(macroRecorder.length == 0);
                if (ImGui.SmallButton("Save..."))
                    tryOpenArgsDialog("macro.saveRecorded");
                ImGui.EndDisabled();
                if (recActive) {
                    ImGui.SameLine();
                    ImGui.TextColored(
                        ImVec4(0.95f, 0.3f, 0.3f, 1.0f),
                        "REC %d", cast(int)macroRecorder.length);
                }

                // Phase 4: inline filter row. Substring narrows the
                // list; "Args" toggle hides arg dimmed-text for a
                // compact view. Phase 6 adds a gear "..." popover
                // with display toggles (row numbers, timestamps,
                // command-id-vs-label).
                ImGui.SetNextItemWidth(-110);
                ImGui.InputTextWithHint("##hist-filter", "Filter...",
                    historyFilter[]);
                ImGui.SameLine();
                ImGui.Checkbox("Args", historyShowArgsPtr);
                ImGui.SameLine();
                if (ImGui.SmallButton("..."))
                    ImGui.OpenPopup("hist-display-opts");
                // Wrap popups in the status-bar popup palette so the
                // grey/beige look matches the menu chrome the rest of
                // the app uses (see source/imgui_style.d).
                pushPopupStyle();
                if (ImGui.BeginPopup("hist-display-opts")) {
                    ImGui.Checkbox("Show row numbers",
                                   historyShowRowNumbersPtr);
                    ImGui.Checkbox("Show timestamps",
                                   historyShowTimestampsPtr);
                    ImGui.Checkbox("Show command IDs (internal names)",
                                   historyShowCommandIdsPtr);
                    ImGui.EndPopup();
                }
                popPopupStyle();

                // Read the filter buffer once per frame into a D
                // string for comparisons.
                import std.string : fromStringz;
                string filter = cast(string) fromStringz(historyFilter.ptr);

                // Phase 3: panel-level right-click menu — fires when
                // the user right-clicks empty space within the list.
                // Per-row menu (defined inside the row loop below)
                // gets priority via ImGui's hit-test ordering.
                pushPopupStyle();
                if (ImGui.BeginPopupContextWindow("hist-panel-ctx",
                        ImGuiPopupFlags.MouseButtonRight
                      | ImGuiPopupFlags.NoOpenOverItems)) {
                    if (ImGui.MenuItem("Save as Script..."))
                        tryOpenArgsDialog("history.saveAsScript");
                    if (ImGui.MenuItem("Clear history"))
                        history.clear();
                    ImGui.EndPopup();
                }
                popPopupStyle();

                // Single scrolling region — keeps the cursor row in
                // view as the stack grows (we explicitly SetScrollHere
                // at the cursor below). Each row is a Selectable so
                // clicking jumps the cursor there (Phase 2 multi-step
                // jump). Target index = "desired undoStack length
                // AFTER the walk".
                //
                // Reserve the last row of the window for the Phase 5
                // REPL bar — negative Y leaves N px at the bottom.
                float replHeight = ImGui.GetFrameHeightWithSpacing();
                if (ImGui.BeginChild("hist-list", ImVec2(0, -replHeight))) {
                    import std.algorithm : canFind;
                    import std.format : format;
                    import command_history : HistoryEntry, HistoryFlags;
                    // Phase 6: timestamps are formatted relative to
                    // the first entry's timestamp so a single line
                    // can show "+1.2s" without showing wall-clock.
                    long t0 = undoArr.length > 0
                        ? undoArr[0].timestampMs
                        : (redoArr.length > 0 ? redoArr[0].timestampMs : 0);
                    // Phase 7: per-row status badge mapped from
                    // HistoryFlags. Anything that landed on the stack
                    // is Succeeded today; the Failed/Quiet/SideEffect
                    // bits are reserved for the dispatcher widening
                    // that captures non-undoable and failed commands.
                    // Badges chosen from the Basic-Latin range so the
                    // default ImGui font (ProggyClean, ASCII-only)
                    // renders them — Unicode glyphs like ✓ / ✗ / ⋯
                    // come out as `?` until we ship a richer font.
                    string flagBadge(uint f) {
                        if (f & HistoryFlags.Failed)     return "! ";
                        if (f & HistoryFlags.Quiet)      return ". ";
                        if (f & HistoryFlags.SideEffect) return "~ ";
                        // Succeeded is the common case — blank keeps
                        // the row visually clean instead of stamping
                        // every line with a tick.
                        return "  ";
                    }
                    string fmtRow(size_t rowIdx, ref const HistoryEntry e) {
                        // Phase 6+7 composition: badge + optional row
                        // number + optional timestamp + label-or-id +
                        // optional args.
                        string head = flagBadge(e.flags);
                        if (historyShowRowNumbers)
                            head ~= format!"%3d "(rowIdx);
                        if (historyShowTimestamps)
                            head ~= format!"+%5.1fs "
                                (cast(double)(e.timestampMs - t0) / 1000.0);
                        string body_ = historyShowCommandIds
                            ? e.commandName : e.label;
                        if (historyShowArgs && e.args.length > 0)
                            return head ~ body_ ~ "  " ~ e.args;
                        return head ~ body_;
                    }
                    foreach (i, ref e; undoArr) {
                        // Phase 4: filter — skip rows that don't
                        // match the substring (case-sensitive). Empty
                        // filter = show all.
                        if (filter.length > 0
                            && !e.label.canFind(filter)
                            && !e.args.canFind(filter)
                            && !e.commandName.canFind(filter))
                            continue;
                        ImGui.PushID(cast(int)i);
                        if (replayUndoEntry !is null) {
                            if (ImGui.SmallButton(">"))
                                replayUndoEntry(i);
                            if (ImGui.IsItemHovered()) {
                                pushPopupStyle();
                                ImGui.SetTooltip("Re-run this entry against current state");
                                popPopupStyle();
                            }
                            ImGui.SameLine();
                        }
                        string rowText = fmtRow(i, e);
                        // Clicking an undo row means "I want history
                        // to be at state after this row's command";
                        // target = i + 1 leaves undoStack[0..=i]
                        // applied.
                        if (ImGui.Selectable(rowText, false))
                            history.jumpTo(i + 1);
                        if (ImGui.IsItemHovered()) {
                            pushPopupStyle();
                            ImGui.SetTooltip("Jump cursor here (undo back %d step(s))",
                                cast(int)(undoArr.length - (i + 1)));
                            popPopupStyle();
                        }
                        // Phase 3: right-click context menu per row.
                        pushPopupStyle();
                        if (ImGui.BeginPopupContextItem("hist-row-ctx")) {
                            if (ImGui.MenuItem("Re-run") && replayUndoEntry !is null)
                                replayUndoEntry(i);
                            if (ImGui.MenuItem("Copy argstring")) {
                                string line = history.undoEntryCommandLine(i);
                                ImGui.SetClipboardText(line);
                            }
                            ImGui.Separator();
                            if (ImGui.MenuItem("Clear history"))
                                history.clear();
                            ImGui.EndPopup();
                        }
                        popPopupStyle();
                        ImGui.PopID();
                    }

                    // Cursor row — "you are here". The user can grab
                    // this row and drag it up/down to
                    // walk through history. Each row-height worth of
                    // vertical drag fires one undo() (drag UP, walks
                    // backward) or one redo() (drag DOWN, walks
                    // forward). The cursor visually follows the
                    // mouse because every undo/redo shifts the list
                    // by exactly one row.
                    ImGui.PushStyleColor(ImGuiCol.Text,
                        ImVec4(0.95f, 0.7f, 0.2f, 1.0f));
                    ImGui.Selectable("=== cursor (drag to undo/redo) ===",
                                     false);
                    ImGui.PopStyleColor();
                    if (ImGui.IsItemHovered() || ImGui.IsItemActive())
                        ImGui.SetMouseCursor(ImGuiMouseCursor.ResizeNS);
                    if (ImGui.IsItemActive()) {
                        ImVec2 dd = ImGui.GetMouseDragDelta(
                            ImGuiMouseButton.Left, 0.0f);
                        float rowH = ImGui.GetTextLineHeightWithSpacing();
                        // Whole-row steps; sub-row deltas accumulate
                        // across frames via the drag-delta state.
                        int steps = cast(int)(dd.y / rowH);
                        if (steps > 0) {
                            foreach (_; 0 .. steps)
                                if (!navHistory(false)) break;
                            ImGui.ResetMouseDragDelta(
                                ImGuiMouseButton.Left);
                        } else if (steps < 0) {
                            foreach (_; 0 .. -steps)
                                if (!navHistory(true)) break;
                            ImGui.ResetMouseDragDelta(
                                ImGuiMouseButton.Left);
                        }
                    }
                    if (cast(int)total > 12)
                        ImGui.SetScrollHereY(0.5f);

                    // Redo entries — dimmed, in chronological order
                    // continuing past the cursor. redoStack stores
                    // most-recent-first; iterate reversed so timeline
                    // reads top-down. Click jumps forward through
                    // pending commands: redo idx (redoArr.length-1-k)
                    // → target = undoArr.length + k + 1.
                    foreach_reverse (i, ref e; redoArr) {
                        if (filter.length > 0
                            && !e.label.canFind(filter)
                            && !e.args.canFind(filter)
                            && !e.commandName.canFind(filter))
                            continue;
                        ImGui.PushID(cast(int)(undoArr.length + 1 + i));
                        // Redo rows: dark grey on the panel's light
                        // grey background. Matches the popup
                        // "disabled" shade in source/imgui_style.d
                        // (60,60,60) — readable but visually
                        // subordinate to active undo rows (black).
                        ImGui.PushStyleColor(ImGuiCol.Text,
                            ImVec4(0.235f, 0.235f, 0.235f, 1.0f));
                        // Redo row index in the chronological view =
                        // undoArr.length + (number of redo entries
                        // already past in this loop).
                        size_t redoRowIdx = undoArr.length
                                          + (redoArr.length - 1 - i);
                        string rowText = fmtRow(redoRowIdx, e);
                        // Steps forward from current = (redoArr.length - i).
                        size_t k = redoArr.length - 1 - i;
                        size_t jumpTarget = undoArr.length + k + 1;
                        if (ImGui.Selectable(rowText, false))
                            history.jumpTo(jumpTarget);
                        if (ImGui.IsItemHovered()) {
                            pushPopupStyle();
                            ImGui.SetTooltip("Jump cursor here (redo %d step(s))",
                                cast(int)(k + 1));
                            popPopupStyle();
                        }
                        ImGui.PopStyleColor();
                        ImGui.PopID();
                    }
                }
                ImGui.EndChild();

                // Phase 5: REPL bar — fixed at the bottom. Enter or
                // the Run button submits the input to the command
                // dispatcher (same path /api/command takes); the
                // command also lands in the history above as a new
                // entry (provided it's recordable). Parse errors
                // tint the input red until the user edits.
                if (historyReplLastWasError)
                    ImGui.PushStyleColor(ImGuiCol.FrameBg,
                        ImVec4(0.45f, 0.18f, 0.18f, 1.0f));
                ImGui.SetNextItemWidth(-60);  // leave room for "Run"
                bool submitted = ImGui.InputText("##hist-repl",
                    historyReplInput[], ImGuiInputTextFlags.EnterReturnsTrue);
                if (historyReplLastWasError)
                    ImGui.PopStyleColor();
                ImGui.SameLine();
                if (ImGui.SmallButton("Run")) submitted = true;
                if (submitted) {
                    import std.string : fromStringz;
                    import argstring : parseArgstring;
                    string line = cast(string) fromStringz(historyReplInput.ptr).dup;
                    if (line.length > 0) {
                        bool ok = false;
                        try {
                            auto parsed = parseArgstring(line);
                            if (!parsed.isEmpty
                                && commandHandlerDelegate !is null) {
                                commandHandlerDelegate(parsed.commandId,
                                    parsed.params.toString());
                                ok = true;
                            }
                        } catch (Exception) {
                            // Parse failure — keep input + red tint.
                        }
                        if (ok) {
                            historyReplInput[] = 0;
                            historyReplLastWasError = false;
                        } else {
                            historyReplLastWasError = true;
                        }
                    }
                }
            }
            ImGui.End();
            // Honor the [x] close button on the window.
            if (!open) showHistoryPanel = false;
            popPanelChromeStyle();
        }
    }
}
