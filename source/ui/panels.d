module ui.panels;

import tool_activation_ownership : ToolTransition;

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
// Task 0722 (audit §2C A3): eleven imports left with renderViewportSceneToFbo.
// Ten of them (math, mesh, handler, editmode, toolpipe, operator:VectorStack,
// perf_probe's profiler group, document, viewgrid, loop_slice_tool) were live
// before that function moved out and are dead after it -- measured by removing
// each import statement in turn and asking the compiler, before AND after the
// move, so what is dropped here is the DIFFERENCE and not a general cleanup.
// The eleventh is `bindbc.opengl`, and it is a correction to the audit, which
// named it as this move's headline casualty: it was ALREADY redundant, because
// the function carried its own function-local `import bindbc.opengl`. See the
// task log for the rest of that measurement.
import bindbc.sdl;
import std.string : toStringz;
import std.stdio : writeln, writefln, File, stderr;
import std.math : tan, sin, cos, sqrt, PI, abs;
import std.conv;
import std.json : JSONValue, JSONType;
import command_args : positionalPayload, firstPositionalString;
import http_server;
import log : logInfo, logWarn, logError;
import perf_probe : g_fc, DrawPass;  // always-on per-frame work counters
import prefs;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import imgui_flag_boundary : beginItemContextMenu, beginPanelContextMenu,
    inputTextSubmitOnEnter;
import imgui_impl_sdl2;
import imgui_impl_opengl3;
import nfde;
import eventlog;
import pipe_gizmo_host : PipeGizmoHost;
import tool;
import seltype;
import toolpipe.packets : SubjectPacket;
import toolpipe.pipeline : g_pipeCtx;
import gizmo;
import view;
import shader;
import io.assimp_runtime : initAssimp, shutdownAssimp, isAssimpAvailable;
// Task 0669 — "would this action refuse if pressed", and the per-frame record
// of what the bars actually drew. See source/ui/availability.d.
import ui.availability : actionRefusal, buttonUnavailable, recordDrawnButton;
import ui.mode_popup : dynamicModeCheckedLabel, dynamicModePopupItems;
import ui.history_panel : HistoryPanelState, HistoryPanelRead,
    HistoryPanelActions, HistoryPanelController, HistoryMacroStatus;
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
import ui.panel_chrome : pushPanelChromeStyle, popPanelChromeStyle, publishPanelZone;
import ui.button_face : kButtonBarPadding, styledButtonPalette,
    drawButtonOutlineRect, drawRaisedBevelRect, drawEngravedLabel;
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
import snap           : ItemSnapFrame;
import viewport       : LayoutPreset, ViewportManager, Viewport3D;
import ui.guard_modal_state : GuardModalState;
import ui.viewport_props_role : ViewportCommandDispatch,
    ViewportPropertiesReadRole;
import layout_reset_action : LayoutResetAction;
import guarded_action_controller : GuardedActionController;

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
import editor_app : EditorApp, Layout, OverlayMode,
    kAiToggleAvailable, kGenerateAiAvailable,
    buildItemFrame;

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
    drawButtonOutlineRect(dl, rmin, rmax);
}

// Raised bevel drawn as `thickness` concentric rings just
// inside the 1-pixel outline.
void drawRaisedBevel(uint light, uint dark, bool pressed = false,
                     int thickness = 2) {
    auto dl = ImGui.GetWindowDrawList();
    ImVec2 rmin = ImGui.GetItemRectMin();
    ImVec2 rmax = ImGui.GetItemRectMax();
    drawRaisedBevelRect(dl, rmin, rmax, light, dark, pressed, thickness);
}

// The editor's button chrome: beige palette for tools, pale blue for commands;
// renders as pure white when `on` (active) or `held` (mouse down).
// Returns true when the button is clicked this frame.
bool renderStyledButton(string label, string shortcut, bool on, bool isCommand,
                        ImVec2 size, bool disabled = false) {
    auto palette = styledButtonPalette(isCommand);

    ImVec4 white = ImVec4(1.0f, 1.0f, 1.0f, 1.0f);
    // Disabled buttons keep the normal bg / bevel but freeze hover
    // and active responses (disabled rows don't visually react to
    // the cursor at all).
    if (disabled) {
        ImGui.PushStyleColor(ImGuiCol.Button,        palette.bgNormal);
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, palette.bgNormal);
        ImGui.PushStyleColor(ImGuiCol.ButtonActive,  palette.bgNormal);
    } else {
        ImGui.PushStyleColor(ImGuiCol.Button,        on ? white : palette.bgNormal);
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, on ? white : palette.bgHover);
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
        drawRaisedBevel(hov ? palette.bevelLightH : palette.bevelLightN,
                        hov ? palette.bevelDarkH  : palette.bevelDarkN,
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
        drawEngravedLabel(ImGui.GetWindowDrawList(), tp, label);
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
            case PopupItemKind.dynamic:
                string s = dynamicModeCheckedLabel(it);
                if (s.length > 0) return s;
                break;
            case PopupItemKind.divider:
            case PopupItemKind.header:
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

// Packed-button-row layout (large FramePadding, zero ItemSpacing). Use inside
// Begin for button-only panels; skip for Tool Properties so inputs keep
// normal spacing. Pair with popButtonBarStyle().
void pushButtonBarStyle() {
    ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, kButtonBarPadding);
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

// ── THE PANEL PROLOGUE, FOR EVERY TOP-LEVEL PANEL IN THIS FILE ──────────────
//
// Task 0719 (audit 4, finding A6). This file used to spell the prologue two
// ways: seven panels pushed the chrome style and called `ImGui.End()` +
// `popPanelChromeStyle()` as plain statements at the bottom, two registered
// them as `scope(exit)`. All nine now do the latter, and the rule is written
// here once instead of nine times:
//
//     pushPanelChromeStyle();
//     scope(exit) popPanelChromeStyle();   // registered FIRST => runs LAST
//     ...anything that computes flags or sets the next window rect...
//     scope(exit) ImGui.End();             // registered adjacent to Begin
//     if (ImGui.Begin(...)) { ...body... }
//
// `End()` is unconditional by ImGui's own contract -- it is owed even when
// `Begin` returns false -- so it was never inside the `if`, and moving it to a
// `scope(exit)` changes nothing about a normal frame. What it changes is the
// abnormal one: ImGui keeps a window stack and a style stack, and a frame that
// left either one deep reports it on the NEXT frame, as an assertion inside
// ImGui with no link to the code that unwound.
// `ui.image_list_panel.drawImageListPanel` and
// `ui.channels_panel.drawChannelsPanel` (the two that already did this) carry
// the measured version of that argument, including the throwing calls that
// make it real rather than defensive; every panel here reaches similar ones
// through `uiCommandDelegate` / `applyOrRefire`.
//
// Registration ORDER is the behaviour: `popPanelChromeStyle` first and
// `ImGui.End` second means they unwind End-then-pop, which is the order the
// seven hand-written tails had. And the pop is registered immediately after
// its push, not next to `End`, so a throw from the flag/rect statements in
// between cannot strand the style stack either.
//
// NOT a helper, and the reason is a language fact rather than a preference:
// `scope(exit)` is a STATEMENT, so a `mixin template` -- which may only carry
// declarations -- cannot hold it. The only way to reduce this to one token is
// a string mixin, which would trade two greppable lines for a body no search
// can see. A named rule beats an invisible one.
// ────────────────────────────────────────────────────────────────────────────

void drawTabPanel(EditorApp app) {
    with (app) {
    pushPanelChromeStyle();
    scope(exit) popPanelChromeStyle();
    if (testMode) {
        ImGui.SetNextWindowPos(layout.tabPos, ImGuiCond.Always);
        ImGui.SetNextWindowSize(layout.tabSize, ImGuiCond.Always);
    }
    int tabFlags = ImGuiWindowFlags.NoCollapse;
    if (testMode) tabFlags |= ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoResize | ImGuiWindowFlags.NoMove;
    scope(exit) ImGui.End();
    if (ImGui.Begin("Tab bar", null, tabFlags))
    {
        publishPanelZone("tabPanel");
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
    }
}

// =============================================================================
// Phase 3 -- drawViewportPropsPanel (task 0419's original body move).
// =============================================================================

// -------------------------------------------------------------------------
// Viewport Properties panel
// -------------------------------------------------------------------------
// Dockable panel whose active-cell independence, display and master controls
// read a fresh projection each draw and dispatch changes through the application
// command path. Reset Layout likewise calls its application-owned action, so the
// drawer owns no viewport/prefs/ini mutation storage (task 5850; evidence:
// viewport_props_roles_test).
//
// Visibility: always shown in interactive mode; hidden in --test by default
// (opt-in via `ui.viewportProps show` + g_viewportPropsShown) so synthetic
// viewport drags can never be captured by it.
version (unittest) {
    struct ViewportPropsDrawSnapshot {
        int activeId;
        int displayStyle;
        ImVec2 centerMin;
        ImVec2 centerMax;
        ImVec2 masterMin;
        ImVec2 masterMax;
        ImVec2[5] masterOptionMin; // group + cells; valid while cellCount <= 4
        ImVec2[5] masterOptionMax;
        ImVec2 resetMin;
        ImVec2 resetMax;
    }

    // Test instrumentation only: mutable process-wide state intentionally
    // survives ImGui contexts; the fixed option arrays support cellCount <= 4.
    private __gshared ViewportPropsDrawSnapshot g_viewportPropsDrawSnapshot;

    ViewportPropsDrawSnapshot viewportPropsDrawSnapshot() {
        return g_viewportPropsDrawSnapshot;
    }

    void resetViewportPropsDrawSnapshot() {
        g_viewportPropsDrawSnapshot = ViewportPropsDrawSnapshot.init;
    }
    private void recordViewportPropsProjection(int activeId, int style) {
        g_viewportPropsDrawSnapshot.activeId = activeId;
        g_viewportPropsDrawSnapshot.displayStyle = style;
    }
    private void recordViewportPropsCenter() {
        g_viewportPropsDrawSnapshot.centerMin = ImGui.GetItemRectMin();
        g_viewportPropsDrawSnapshot.centerMax = ImGui.GetItemRectMax();
    }
    private void recordViewportPropsMaster() {
        g_viewportPropsDrawSnapshot.masterMin = ImGui.GetItemRectMin();
        g_viewportPropsDrawSnapshot.masterMax = ImGui.GetItemRectMax();
    }
    private void recordViewportPropsMasterOption(int index) {
        g_viewportPropsDrawSnapshot.masterOptionMin[index] = ImGui.GetItemRectMin();
        g_viewportPropsDrawSnapshot.masterOptionMax[index] = ImGui.GetItemRectMax();
    }
    private void recordViewportPropsReset() {
        g_viewportPropsDrawSnapshot.resetMin = ImGui.GetItemRectMin();
        g_viewportPropsDrawSnapshot.resetMax = ImGui.GetItemRectMax();
    }
} else {
    private void recordViewportPropsProjection(int, int) {}
    private void recordViewportPropsCenter() {}
    private void recordViewportPropsMaster() {}
    private void recordViewportPropsMasterOption(int) {}
    private void recordViewportPropsReset() {}
}

void drawViewportPropsPanel(ViewportPropertiesReadRole viewportRead,
                            ViewportCommandDispatch dispatch,
                            LayoutResetAction resetLayout) {
    assert(dispatch !is null,
        "viewport properties panel requires command dispatch");
    assert(resetLayout !is null,
        "viewport properties panel requires reset-layout action");
    import commands.ui.viewport_props : g_viewportPropsShown;
    import std.json : JSONValue;
    import std.conv : to;

    pushPanelChromeStyle();
    scope(exit) popPanelChromeStyle();
    scope(exit) ImGui.End();
    if (ImGui.Begin("Viewport Properties")) {
        auto v = viewportRead.project();
        recordViewportPropsProjection(v.activeId,
            cast(int)v.display.active.style);

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
                bool cur = (v.layout == lblVals[i]);
                if (cur) ImGui.PushStyleColor(ImGuiCol.Button,
                                              ImVec4(0.30f, 0.45f, 0.65f, 1.0f));
                if (ImGui.Button(lblNames[i]))
                    dispatch("viewport.layout",
                        positionalPayload([lblIds[i]]));
                if (cur) ImGui.PopStyleColor(1);
            }
        }

        ImGui.Dummy(ImVec2(0, 2));
        ImGui.SeparatorText("Active Cell Independence");

        bool ic = v.indCenter;
        const centerChanged = ImGui.Checkbox("Center", &ic);
        recordViewportPropsCenter();
        if (centerChanged)
            dispatch("viewport.indCenter",
                                  ic ? `{"value":"yes"}` : `{"value":"no"}`);

        ImGui.SameLine();
        bool isc = v.indScale;
        if (ImGui.Checkbox("Scale", &isc))
            dispatch("viewport.indScale",
                                  isc ? `{"value":"yes"}` : `{"value":"no"}`);

        ImGui.SameLine();
        bool ir = v.indRotate;
        if (ImGui.Checkbox("Rotate", &ir))
            dispatch("viewport.indRotate",
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
            import display_state : DisplayStyle, WireOverlay,
                                   kDisplayStyleOrder, displayStyleLabel,
                                   displayStyleId;
            import std.format : format;

            // Task 1090: the labels, the ids and the order come from
            // `display_state` now, not from three hand-kept `[3]` arrays here.
            // There were six such arrays across this file and app.d, and
            // adding a style meant remembering all six; the combo below grows
            // a new entry with no edit at all.
            int si = 0;
            foreach (i, sv; kDisplayStyleOrder)
                if (sv == v.display.active.style) si = cast(int)i;
            ImGui.Text("Style");
            ImGui.SameLine();
            ImGui.SetNextItemWidth(-1.0f);
            if (ImGui.BeginCombo("##vpDisplayStyle",
                                 displayStyleLabel(kDisplayStyleOrder[si]))) {
                foreach (i, sv; kDisplayStyleOrder) {
                    bool sel = (i == si);
                    if (ImGui.Selectable(displayStyleLabel(sv), sel))
                        dispatch("viewport.displayStyle",
                            positionalPayload([displayStyleId(sv)]));
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
                    if (ImGui.Selectable(wl, sel))
                        dispatch("viewport.wireOverlay",
                            positionalPayload([wireIds[i]]));
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
                dispatch("viewport.wireAlpha",
                    positionalPayload([format("%.6f", wa)]));
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
                    if (ImGui.Selectable(rungLabel(m), sel))
                        dispatch("viewport.gridSteps",
                            positionalPayload([format("%d", m)]));
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
        const masterOpen = ImGui.BeginCombo("##vpMaster", masterLabel);
        recordViewportPropsMaster();
        if (masterOpen) {
            bool grpSel = (mid < 0);
            const groupChanged = ImGui.Selectable("Group master", grpSel);
            recordViewportPropsMasterOption(0);
            if (groupChanged)
                dispatch("viewport.master", positionalPayload(["-1"]));
            if (grpSel) ImGui.SetItemDefaultFocus();
            foreach (ci; 0 .. v.cellCount) {
                bool csel = (mid == ci);
                string clabel = "Cell " ~ to!string(ci);
                const cellChanged = ImGui.Selectable(clabel, csel);
                recordViewportPropsMasterOption(ci + 1);
                if (cellChanged)
                    dispatch("viewport.master",
                        positionalPayload([to!string(ci)]));
                if (csel) ImGui.SetItemDefaultFocus();
            }
            ImGui.EndCombo();
        }

        // Reset Layout button
        ImGui.Dummy(ImVec2(0, 2));
        ImGui.Separator();
        const resetPressed = ImGui.Button("Reset Layout");
        recordViewportPropsReset();
        if (resetPressed) resetLayout.authorReset();
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
    scope(exit) popPanelChromeStyle();
    // AlwaysAutoResize: the window is exactly as big as the facts in it.
    scope(exit) ImGui.End();
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
            // TASK 4062 — THE THIRD FUNNEL, and the reason it was one at all.
            // This case built the command from its factory and ran it with NO
            // arguments: a panel row could name a command but never say
            // anything to it, and a command that acquired an argument later
            // silently kept its defaults here while the other two funnels bound
            // one. Routing the id through `uiCommandDelegate` — the same
            // application command binding the HTTP door also uses, under the
            // UI refusal policy — means all three funnels reach `bindArgs`,
            // and a panel row that grows an argument tomorrow needs no change
            // here.
            //
            // TWO THINGS DIFFER from the `runCommand` call it replaces, both
            // deliberate: the dispatch records the id it was asked for (a
            // `runCommand` caller has none to give, and the guard record said
            // so), and it records under `RecordMode.Coalescing` rather than
            // `Record` — which changes nothing for a command that does not
            // override `compareOp()`, and every command that does takes
            // arguments this case cannot supply.
            if (!tryOpenArgsDialog(action.id)) {
                if (uiCommandDelegate !is null)
                    uiCommandDelegate(action.id, "");
            }
            break;
        case ActionKind.script:
            foreach (line; action.scriptLines) {
                auto parsed = parseArgstring(line);
                if (parsed.isEmpty) continue;
                if (uiCommandDelegate !is null)
                    uiCommandDelegate(parsed.commandId,
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
void renderDynamicPopupItems(EditorApp app, ref PopupItem provider) {
    with (app) {
    switch (provider.dynamicKind) {
        case "falloffStack":
            renderFalloffStackItems(app);
            break;
        case "acenModes":
        case "acenStageModes":
        case "axisModes":
            PopupItem[] rows = dynamicModePopupItems(provider);
            if (rows.length == 0)
                ImGui.TextDisabled("(no modes configured)");
            else
                renderPopupItems(app, rows);
            break;
        default:
            ImGui.TextDisabled("(unknown dynamic '%s')", provider.dynamicKind);
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
                renderDynamicPopupItems(app, it);
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


void drawSidePanel(EditorApp app) {
    with (app) {
    pushPanelChromeStyle();
    scope(exit) popPanelChromeStyle();
    // In --test: fixed rect + immovable flags reproduce today's exact
    // layout (picking rect unchanged → byte-identical).
    // Interactive: no fixed pos/size → floats/docks freely.
    if (testMode) {
        ImGui.SetNextWindowPos(layout.sidePos, ImGuiCond.Always);
        ImGui.SetNextWindowSize(layout.sideSize, ImGuiCond.Always);
    }
    int sidePanelFlags = ImGuiWindowFlags.NoCollapse;
    if (testMode) sidePanelFlags |= ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoResize | ImGuiWindowFlags.NoMove;
    scope(exit) ImGui.End();
    if (ImGui.Begin("Mesh Info", null, sidePanelFlags))
    {
        publishPanelZone("sidePanel");
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
            auto unavailable = buttonUnavailable(reg, btn,
                document.hasEditTarget(), activeToolId, editMode,
                kGenerateAiAvailable);
            string unavailWhy = unavailable.why;
            bool effDisabled = unavailable.disabled;
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
        // now" readout. Walk the marks arrays via the mesh's own
        // countSelected* accessors.
        //
        // FUTURE perf note — countSelected* is a linear walk
        // (one `uint` mark per element). At
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
    }
}

void drawStatusBar(EditorApp app) {
    with (app) {
    pushPanelChromeStyle();
    scope(exit) popPanelChromeStyle();
    if (testMode) {
        ImGui.SetNextWindowPos(layout.statusPos, ImGuiCond.Always);
        ImGui.SetNextWindowSize(layout.statusSize, ImGuiCond.Always);
    }
    int statusFlags = ImGuiWindowFlags.NoCollapse;
    if (testMode) statusFlags |= ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoResize | ImGuiWindowFlags.NoMove;
    scope(exit) ImGui.End();
    if (ImGui.Begin("Status line", null, statusFlags))
    {
        publishPanelZone("statusBar");
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
                    if (!parsed.isEmpty && parsed.commandId == "select.typeFrom")
                    {
                        // The wire key is `command_args`'s to spell, not this
                        // panel's (task 4062) — a misspelt copy reads "" and
                        // silently drops the shortcut badge.
                        immutable t = firstPositionalString(parsed.params);
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
                            // Same funnel as `dispatchAction`'s command case
                            // (task 4062) — the status bar was the second copy
                            // of the no-argument factory call.
                            if (!tryOpenArgsDialog(action.id)) {
                                if (uiCommandDelegate !is null)
                                    uiCommandDelegate(action.id, "");
                            }
                            if (editModeId.length > 0)
                                dropActiveTool(ToolTransition.panelDrop);
                            break;
                        case ActionKind.script:
                            // typeFrom doesn't go through the args
                            // dialog — dispatch each line via the
                            // same path as /api/command argstring
                            // bodies.
                            foreach (line; action.scriptLines) {
                                auto p2 = parseArgstring(line);
                                if (p2.isEmpty) continue;
                                if (uiCommandDelegate !is null)
                                    uiCommandDelegate(p2.commandId,
                                                            p2.params.toString());
                            }
                            // Activating an edit mode is conceptually
                            // a tool change — drop any sticky tool
                            // too.
                            if (editModeId.length > 0)
                                dropActiveTool(ToolTransition.panelDrop);
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
    }
}

// =========================================================================
// app.d decomp phase B: the four inline ImGui panels of app.d's main loop:
//   drawAi3dModal            -- was app.d ~5650-5874 ("AI3D Generate modal")
//   drawRemeshModal          -- was app.d ~5876-5978 ("Quad Remesh modal")
//   drawQuitGuardModal       -- was app.d ~5980-6034 ("Unsaved-changes quit
//                               guard + confirmation modal")
//   drawCommandHistoryPanel  -- was app.d ~6304-6651 ("Command History")
// The first two retain the original EditorApp seam. Their only body edits
// vs the pre-move text are Edit-class-2 address-of sites (precedent:
// registration.d's &promoteItemType): ImGui's SliderInt/SliderFloat/Checkbox
// take a raw pointer, and `&prop` on a @property ref field yields the property
// FUNCTION's address, so these widget calls read the `namePtr` storage field:
//   &ai3dMaxFaces -> ai3dMaxFacesPtr, &remeshTargetQuads ->
//   remeshTargetQuadsPtr, &remeshAdaptivity -> remeshAdaptivityPtr,
//   &remeshSharpEdge -> remeshSharpEdgePtr. drawQuitGuardModal now receives
// only its per-application state, test-mode gate and existing guard controller.
// Command History now has an owned form state plus narrow read/action roles;
// its visible drawing remains an ImGui adapter around HistoryPanelController.
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

version (unittest) {
    struct GuardModalDrawSnapshot {
        size_t discardOpenCalls;
        ImVec2 saveMin;
        ImVec2 saveMax;
        ImVec2 discardMin;
        ImVec2 discardMax;
    }

    private __gshared GuardModalDrawSnapshot g_guardModalDrawSnapshot;

    GuardModalDrawSnapshot guardModalDrawSnapshot() {
        return g_guardModalDrawSnapshot;
    }

    void resetGuardModalDrawSnapshot() {
        g_guardModalDrawSnapshot = GuardModalDrawSnapshot.init;
    }
}

private void cancelGuardPopup(GuardModalState state,
                              GuardedActionController guardController) {
    guardController.answerCancel();
    state.closeDiscard();
}

void drawQuitGuardModal(GuardModalState state, bool testMode,
                        GuardedActionController guardController) {
    assert(state !is null, "quit guard modal requires panel state");
    assert(guardController !is null, "quit guard modal requires guard policy");
    with (state) {
        // ---- Unsaved-work prompt (task 0434's form, task 1521's scope) ----
        //
        // THE MODAL ENTRY THAT USED TO LIVE HERE IS GONE. Until task 1521 this
        // function ALSO decided whether to prompt — it drained `quitRequested`
        // and asked `docDirty()` itself. That made the guard a SECOND point
        // beside command dispatch, and the consequence was measured: removing
        // the dispatch guard reddened File → New and File → Open but NOT quit,
        // because quit was still guarded here. The decision now belongs to the
        // one GuardedActionController used by every UI command; this function
        // only owns the popup handshake, renders state and hands answers back.
        //
        // Three buttons, not two (owner-directed): "Yes/No" cannot tell
        // "throw the work away" from "I changed my mind".
        requestDiscardOpen(testMode, guardController.awaitingAnswer);
        if (discardConfirmOpen) {
            if (consumeDiscardOpen()) {
                ImGui.OpenPopup("Unsaved Changes");
                version (unittest) ++g_guardModalDrawSnapshot.discardOpenCalls;
            }
            bool popupOpen = discardConfirmOpen;
            if (ImGui.BeginPopupModal("Unsaved Changes", &popupOpen,
                                      ImGuiWindowFlags.AlwaysAutoResize)) {
                // TextUnformatted: the text carries a command LABEL, which can
                // contain a "%" (a file name), and this is the overload that
                // takes no format string.
                if (!popupOpen) {
                    cancelGuardPopup(state, guardController);
                    ImGui.CloseCurrentPopup();
                } else if (ImGui.IsKeyPressed(ImGuiKey.Escape)) {
                    cancelGuardPopup(state, guardController);
                    ImGui.CloseCurrentPopup();
                } else if (!guardController.awaitingAnswer) {
                    closeDiscard();
                    ImGui.CloseCurrentPopup();
                } else {
                    ImGui.TextUnformatted(guardController.promptText);
                    ImGui.Separator();
                    // Save leads: it is the destructive-safe default. The action is
                    // performed at the post-flush settle and ONLY if the save
                    // actually landed — a cancelled Save dialog leaves the document
                    // dirty and aborts the discard.
                    if (ImGui.Button("Save")) {
                        guardController.answerSave();
                        closeDiscard();
                        ImGui.CloseCurrentPopup();
                    }
                    version (unittest) {
                        g_guardModalDrawSnapshot.saveMin = ImGui.GetItemRectMin();
                        g_guardModalDrawSnapshot.saveMax = ImGui.GetItemRectMax();
                    }
                    ImGui.SameLine();
                    if (ImGui.Button("Discard")) {
                        guardController.answerDiscard();
                        closeDiscard();
                        ImGui.CloseCurrentPopup();
                    }
                    version (unittest) {
                        g_guardModalDrawSnapshot.discardMin = ImGui.GetItemRectMin();
                        g_guardModalDrawSnapshot.discardMax = ImGui.GetItemRectMax();
                    }
                    ImGui.SameLine();
                    if (ImGui.Button("Cancel")) {
                        cancelGuardPopup(state, guardController);
                        ImGui.CloseCurrentPopup();
                    }
                }
                ImGui.EndPopup();
            } else {
                // Closed via ESC / [X] — same semantics as Cancel: the held
                // action is DROPPED, never performed.
                cancelGuardPopup(state, guardController);
            }
        }

        // ---- Command-failure notice (task 0616 review B1) ----------------
        // THE ONLY PLACE A DECLINED COMMAND BECOMES VISIBLE. `log.d`'s single
        // sink is a stderr echo and no UI listens to it, so before this the
        // File → Open of a pre-v8 document simply did nothing on screen. The
        // text (and the decision that there is any) comes from
        // `ui.command_notice.commandNoticeText`, driven by `runCommand`.
        //
        // THE ARGUMENT FOR LEAVING THIS UNGATED IS DEAD (task 1520, R3). It
        // used to read: "--test never raises a notice, because it never runs a
        // UI-path command that declines with a reason". That was true only
        // while panels had no test-drivable route. `POST /api/command?origin=ui`
        // is exactly that route, so a `--test` run CAN now raise one, and an
        // unanswerable modal would wedge the harness on the first refusal.
        // The gate lives at the RAISE site (`app.d`'s `raiseNotice`), which
        // also writes the text to `GET /api/ui/policy` — so what a test can
        // read is the same string the user would have been shown.
        if (noticeOpen) {
            if (consumeNoticeOpen()) {
                ImGui.OpenPopup("Command Failed");
            }
            bool popupOpen = noticeOpen;
            if (ImGui.BeginPopupModal("Command Failed", &popupOpen,
                                      ImGuiWindowFlags.AlwaysAutoResize)) {
                // TextUnformatted, not TextDisabled/Text: the reason carries a
                // user-supplied FILE PATH, and this is the overload that takes
                // no format string at all.
                if (!popupOpen) {
                    closeNotice();
                    ImGui.CloseCurrentPopup();
                } else {
                    ImGui.TextUnformatted(noticeText);
                    ImGui.Separator();
                    if (ImGui.Button("OK")) {
                        closeNotice();
                        ImGui.CloseCurrentPopup();
                    }
                }
                ImGui.EndPopup();
            } else {
                closeNotice();   // closed via ESC / [X]
            }
        }
    }
}

version (unittest) {
    struct HistoryMacroStripSnapshot {
        HistoryMacroStatus status;
        bool saveEnabled;
        ImVec2 recMin;
        ImVec2 recMax;
    }

    struct HistoryPopupSnapshot {
        ImVec2 row0Min;
        ImVec2 row0Max;
        ImVec2 listMin;
        ImVec2 listMax;
        ImVec2 replMin;
        ImVec2 replMax;
        bool panelMenuOpen;
        size_t rowMenuIndex = size_t.max;
    }

    private __gshared HistoryMacroStripSnapshot g_historyMacroStripSnapshot;
    private __gshared HistoryPopupSnapshot g_historyPopupSnapshot;

    HistoryMacroStripSnapshot historyMacroStripSnapshot() {
        return g_historyMacroStripSnapshot;
    }

    HistoryPopupSnapshot historyPopupSnapshot() {
        return g_historyPopupSnapshot;
    }
}

void drawCommandHistoryPanel(HistoryPanelState state,
        HistoryPanelRead historyRead, HistoryPanelActions actions,
        float leftOffset) {
    auto controller = HistoryPanelController(state, actions);
    // ---- Command History (floating) ----
    // Toggled by the history.show command. Layout (history-panel
    // design doc Phase 1): single chronological list, OLDEST top →
    // NEWEST bottom, with a cursor row marking the current undo point.
    // Entries below the cursor are pending-redo and render dimmed. Per-undo
    // row keeps the `>` replay button.
    if (state.visible) {
        pushPanelChromeStyle();
        scope(exit) popPanelChromeStyle();
        ImGui.SetNextWindowPos(ImVec2(leftOffset, 130), ImGuiCond.FirstUseEver);
        ImGui.SetNextWindowSize(ImVec2(320, 380), ImGuiCond.FirstUseEver);
        bool open = state.visible;
        scope(exit) ImGui.End();
        if (ImGui.Begin("Command History", &open)) {
            publishPanelZone("history");
            import imgui_style : pushPopupStyle, popPopupStyle;
            auto undoArr = historyRead.undoEntries();
            auto redoArr = historyRead.redoEntries();
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
            auto macroStatus = controller.macroStatus();
            bool recActive = macroStatus.active;
            if (recActive)
                ImGui.PushStyleColor(ImGuiCol.Text,
                    ImVec4(0.95f, 0.3f, 0.3f, 1.0f));
            ImGui.BeginDisabled(recActive);
            if (ImGui.SmallButton("Rec")) {
                controller.dispatch("macro.record", `{"state":1}`);
            }
            version (unittest) {
                const macroRecMin = ImGui.GetItemRectMin();
                const macroRecMax = ImGui.GetItemRectMax();
                ImVec2 historyRow0Min;
                ImVec2 historyRow0Max;
            }
            size_t historyRowMenuIndex = size_t.max;
            ImGui.EndDisabled();
            if (recActive) ImGui.PopStyleColor();
            ImGui.SameLine();
            ImGui.BeginDisabled(!recActive);
            if (ImGui.SmallButton("Stop")) {
                controller.dispatch("macro.record", `{"state":0}`);
            }
            ImGui.EndDisabled();
            // Rec/Stop dispatch synchronously and may clear the macro buffer.
            // Save availability and the REC count must use that new state.
            macroStatus = controller.macroStatus();
            const macroSaveEnabled = macroStatus.length != 0;
            ImGui.SameLine();
            ImGui.BeginDisabled(!macroSaveEnabled);
            if (ImGui.SmallButton("Save..."))
                controller.openArgs("macro.saveRecorded");
            ImGui.EndDisabled();
            if (recActive) {
                ImGui.SameLine();
                ImGui.TextColored(
                    ImVec4(0.95f, 0.3f, 0.3f, 1.0f),
                    "REC %d", cast(int)macroStatus.length);
            }

            // Phase 4: inline filter row. Substring narrows the
            // list; "Args" toggle hides arg dimmed-text for a
            // compact view. Phase 6 adds a gear "..." popover
            // with display toggles (row numbers, timestamps,
            // command-id-vs-label).
            ImGui.SetNextItemWidth(-110);
            ImGui.InputTextWithHint("##hist-filter", "Filter...",
                state.filterBuffer);
            ImGui.SameLine();
            ImGui.Checkbox("Args", &state.showArgs);
            ImGui.SameLine();
            if (ImGui.SmallButton("..."))
                ImGui.OpenPopup("hist-display-opts");
            // Wrap popups in the status-bar popup palette so the
            // grey/beige look matches the menu chrome the rest of
            // the app uses (see source/imgui_style.d).
            pushPopupStyle();
            if (ImGui.BeginPopup("hist-display-opts")) {
                ImGui.Checkbox("Show row numbers",
                               &state.showRowNumbers);
                ImGui.Checkbox("Show timestamps",
                               &state.showTimestamps);
                ImGui.Checkbox("Show command IDs (internal names)",
                               &state.showCommandIds);
                ImGui.EndPopup();
            }
            popPopupStyle();

            // Read the filter buffer once per frame into a D
            // string for comparisons.
            const(char)[] filter = state.filterText;

            // Current behaviour: this outer-window menu opens on empty space
            // outside the child list. Empty space inside the list opens no
            // menu; whether the panel should own that area remains an owner
            // question rather than a rule for this flag boundary.
            pushPopupStyle();
            const bool panelMenuOpen =
                beginPanelContextMenu("hist-panel-ctx");
            if (panelMenuOpen) {
                if (ImGui.MenuItem("Save as Script..."))
                    controller.openArgs("history.saveAsScript");
                if (ImGui.MenuItem("Clear history"))
                    controller.clearHistory();
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
                    if (state.showRowNumbers)
                        head ~= format!"%3d "(rowIdx);
                    if (state.showTimestamps)
                        head ~= format!"+%5.1fs "
                            (cast(double)(e.timestampMs - t0) / 1000.0);
                    string body_ = state.showCommandIds
                        ? e.commandName : e.label;
                    if (state.showArgs && e.args.length > 0)
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
                    {
                        if (ImGui.SmallButton(">"))
                            controller.replay(i);
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
                        controller.rawJump(i + 1);
                    version (unittest) {
                        if (i == 0) {
                            historyRow0Min = ImGui.GetItemRectMin();
                            historyRow0Max = ImGui.GetItemRectMax();
                        }
                    }
                    if (ImGui.IsItemHovered()) {
                        pushPopupStyle();
                        ImGui.SetTooltip("Jump cursor here (undo back %d step(s))",
                            cast(int)(undoArr.length - (i + 1)));
                        popPopupStyle();
                    }
                    // Phase 3: right-click context menu per row.
                    pushPopupStyle();
                    if (beginItemContextMenu("hist-row-ctx")) {
                        historyRowMenuIndex = i;
                        if (ImGui.MenuItem("Re-run"))
                            controller.replay(i);
                        if (ImGui.MenuItem("Copy argstring")) {
                            string line = historyRead.undoEntryCommandLine(i);
                            ImGui.SetClipboardText(line);
                        }
                        ImGui.Separator();
                        if (ImGui.MenuItem("Clear history"))
                            controller.clearHistory();
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
                            if (!controller.navigate(false)) break;
                        ImGui.ResetMouseDragDelta(
                            ImGuiMouseButton.Left);
                    } else if (steps < 0) {
                        foreach (_; 0 .. -steps)
                            if (!controller.navigate(true)) break;
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
                        controller.rawJump(jumpTarget);
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
            const historyListMin = ImGui.GetItemRectMin();
            const historyListMax = ImGui.GetItemRectMax();

            // Phase 5: REPL bar — fixed at the bottom. Enter or
            // the Run button submits the input to the command
            // dispatcher (same path /api/command takes); the
            // command also lands in the history above as a new
            // entry (provided it's recordable). Parse errors
            // tint the input red until the user edits.
            if (state.replLastWasError)
                ImGui.PushStyleColor(ImGuiCol.FrameBg,
                    ImVec4(0.45f, 0.18f, 0.18f, 1.0f));
            ImGui.SetNextItemWidth(-60);  // leave room for "Run"
            bool submitted = inputTextSubmitOnEnter(
                "##hist-repl", state.replBuffer);
            if (state.replLastWasError)
                ImGui.PopStyleColor();
            version (unittest) {
                const historyReplMin = ImGui.GetItemRectMin();
                const historyReplMax = ImGui.GetItemRectMax();
                g_historyMacroStripSnapshot = HistoryMacroStripSnapshot(
                    macroStatus, macroSaveEnabled, macroRecMin, macroRecMax);
                g_historyPopupSnapshot = HistoryPopupSnapshot(
                    historyRow0Min, historyRow0Max,
                    historyListMin, historyListMax,
                    historyReplMin, historyReplMax,
                    panelMenuOpen, historyRowMenuIndex);
            }
            ImGui.SameLine();
            if (ImGui.SmallButton("Run")) submitted = true;
            if (submitted) controller.submitRepl();
        }
        // Honor the [x] close button on the window.
        if (!open) state.visible = false;
    }
}

// =============================================================================
// THE STATISTICS PANEL (task 1100)
//
// A three-level tree of element counts — section → category → leaf — with two
// numeric columns (`Num` = how many exist, `Sel` = how many of those are
// selected) and two clickable columns that add the row's elements to the
// selection or subtract them from it.
//
// -----------------------------------------------------------------------------
// WHY THE SIGNATURE IS NARROW AND NOT `EditorApp`
// -----------------------------------------------------------------------------
// Three properties follow from it, and all three are load-bearing:
//
//   1. `const(Document)*` extends the no-mutation proof through the DRAWER: it
//      cannot construct a mutating command over the document's mesh either, so
//      "count this row by running its own command and looking at the result"
//      does not compile here any more than it does in the kernel.
//      NARROWED (task 4061): read that as "no mutation the panel could
//      PERFORM", not as "the bytes of the document do not change across the
//      call". `Document.primary` now memoises the edit-target walk and writes
//      the memo through a logical-const cast, so a `const(Document)*` no
//      longer proves byte-stability — see `document_selection.d:primary`,
//      which also carries the main-thread-only constraint that comes with it.
//      Nothing here depends on byte-stability; the property this list needs is
//      that no mutating command is CONSTRUCTIBLE, and that is untouched.
//   2. The `run` delegate is the ONE place `const` stops, and it is necessary —
//      a clickable column has to be able to fire a command. That is exactly why
//      a mesh fingerprint is taken around a real draw frame in
//      `tests/unit/ui/stat_panel_widget_test.d`: it is the one hole the type
//      system cannot close.
//   3. It is CONSTRUCTIBLE IN A UNITTEST. An `EditorApp` parameter would make
//      this panel untestable below the HTTP layer.
//
// -----------------------------------------------------------------------------
// WHAT IS HAND-DRAWN, AND WHY
// -----------------------------------------------------------------------------
// The pinned `d_imgui` binding has no `BeginTable`, no `TreeNodeEx` and no
// `BeginTabBar` — the enums exist as types only. So the five columns and the
// three-level tree are hand-drawn with `Button`/`InvisibleButton` + `SameLine`
// + `Dummy`, exactly as the Items panel already does it. This is the single
// largest cost in the task and the reason the renderer is its own stage.
//
// ROW PITCH is exactly `GetFrameHeightWithSpacing()` and the two ACTION COLUMNS
// ARE NEVER INDENTED. Both are design constraints rather than accidents: the
// headless harness addresses rows by index off that pitch, and its x lands
// inside the first column — so a layout change that breaks either fails the
// click test loudly, at the right place.
//
// COLUMN WIDTHS are SEEDED from the decode and are not layout constants. The
// owner's two frames measured the same columns at different widths (one frame
// truncates the `Num` header, the other does not), so what was decoded is an
// initial value. They are recomputed here from the header and the widest cell.
//
// -----------------------------------------------------------------------------
// THREE THINGS REDUCE A ROW'S PROMINENCE AND THEY ARE NOT THE SAME THING
// -----------------------------------------------------------------------------
//   * `noAffordance` — the two action cells are EMPTY. No button, no
//     `BeginDisabled` wrapper, no tooltip. This is every CATEGORY row (a whole
//     level of the tree, measured across ten categories in two frames), plus
//     the count-only leaves.
//   * `BeginDisabled` — a button IS drawn, greyed, with the reason in a
//     tooltip. Ours, for `inertActions` / `structuralZero` / `unmeasured`.
//   * the DIMMED TONE — measured: exactly the rows whose selected count is
//     non-zero are drawn dim, the section header included, and the buttons dim
//     WITH the row. A dimmed row is FULLY CLICKABLE. Expressing it by wrapping
//     the row in `BeginDisabled` is the mistake this comment exists to prevent
//     — greying is already what that call does two lines further down.
// =============================================================================

import ui.stat_rows : StatCell, StatAvail, StatTone, StatExpand, StatAction,
                      StatSection, statSectionsInto, statNeedOf;
import document : Document;
import mesh : Mesh;

/// The two placeholder glyphs, which answer DIFFERENT questions and must never
/// be merged into one constant.
///
///   * `kGatedCell` — MEASURED. "There IS a number, but not for your current
///     selection type." One frame could not have decided this (the same glyph
///     is what a not-yet-computed cell shows in the reference); a second frame,
///     with polygons current, printed numbers in the polygon section and this
///     in the others, in a single draw.
///   * `kUnknownCell` — OURS (owner decision 1). "We do not know this number."
///     A `0` there would be a claim; this is the honest cell.
enum string kGatedCell   = "...";
enum string kUnknownCell = "—";

/// Column width SEEDS, not layout. See the header note.
private enum float kSeedActionW = 20.0f;
private enum float kSeedNumW    = 30.0f;

/// What a numeric cell reads. THREE outcomes, not two, and the third is the
/// one a placeholder-shaped `if` swallows:
///
///   * a number, when we know it;
///   * `kUnknownCell` when the row's predicate is unmeasured — we cannot
///     compute this at all;
///   * `kGatedCell` when there IS a number but not for the current selection
///     type;
///   * …and BLANK, which is not a placeholder at all: a CATEGORY row carries
///     no numbers, measured, for the whole level. Rendering the gate glyph
///     there would answer a question the row never asks.
private string cellText(StatCell c, StatAvail avail, bool blank) {
    import std.conv : to;
    if (blank) return "";
    if (c.known) return c.value.to!string;
    return avail == StatAvail.unmeasured ? kUnknownCell : kGatedCell;
}

private string availToken(StatAvail a) {
    final switch (a) {
        case StatAvail.live:           return "live";
        case StatAvail.inertActions:   return "inertActions";
        case StatAvail.noAffordance:   return "noAffordance";
        case StatAvail.structuralZero: return "structuralZero";
        case StatAvail.unmeasured:     return "unmeasured";
    }
}

void drawStatisticsPanel(const(Document)* doc, SelType current,
                         ref StatExpand exp,
                         void delegate(string cmdId, string argsJson) run) {
    pushPanelChromeStyle();
    scope(exit) popPanelChromeStyle();
    scope(exit) ImGui.End();
    if (!ImGui.Begin("Statistics")) return;
    drawStatisticsBody(doc, current, exp, run);
}

/// The panel WITHOUT its window — everything between `Begin` and `End`.
///
/// Split out for one reason, and it is not cosmetic: the headless widget
/// harness submits a panel BODY into its own window, so a function that opened
/// a window of its own could not be driven by it, and the click test that
/// proves a row's `+` reaches that row's action could not exist. This is the
/// SHIPPED code — `drawStatisticsPanel` above adds the chrome and nothing else,
/// so no test-only seam is introduced into what the app draws.
void drawStatisticsBody(const(Document)* doc, SelType current,
                        ref StatExpand exp,
                        void delegate(string cmdId, string argsJson) run) {
    import ui.stat_record : DrawnStatRow, DrawnStatFrame, beginStatFrame,
                            recordDrawnStatRow, recordDrawnStatFrame,
                            endStatFrame;
    import ui.item_glyphs : drawDisclosure, kGlyphCellRatio,
                            kGlyphRadiusRatio, kIndentRatio;
    import mesh_stats : StatContext, buildStatContext;

    // ---- The mesh, obtained EXACTLY ONCE, guarding `primary` --------------
    // `Document.primary` is nullable and the null state is live and asserted.
    // `Layer` is a class, so `doc.primary.meshOrNull()` on a null primary reads
    // a member of a null object and FAULTS — in a panel that draws every frame.
    // Guarding the RESULT for null guards the wrong pointer.
    //
    // And deliberately NOT `document.noEditTargetMesh()`, the read-only empty
    // stand-in the other per-frame read paths take: an empty mesh answers every
    // geometry row `0`, and `0` is a claim to know how many there are.
    const(Mesh)* m = (doc !is null && doc.hasEditTarget())
                   ? doc.primary.meshOrNull() : null;
    // Build ONLY what this expand state will read — the "compute what is on
    // screen" rule. `statNeedOf` lives beside the tree that decides it, and
    // the two are compared by value in `stat_rows_test.d`.
    StatContext ctx = (m is null) ? StatContext.init
                                  : buildStatContext(*m, statNeedOf(exp));

    static StatSection[] rowBuf;
    // Counted ALWAYS, in the default build, on the frame path — so "the panel
    // costs nothing while it is closed" is a number a test reads rather than a
    // claim, and so the refresh policy is decided against a measurement.
    g_fc.bumpStatRebuild();
    statSectionsInto(doc, current, ctx, exp, rowBuf);

    // ---- Metrics ----------------------------------------------------------
    // Derived from the row height, which already carries the UI scale and the
    // font swap between a normal run and --test.
    immutable float rowH    = ImGui.GetFrameHeightWithSpacing()
                            - ImGui.GetStyle().ItemSpacing.y;
    immutable float gRad    = rowH * kGlyphRadiusRatio;
    immutable float indentW = rowH * kIndentRatio;
    immutable float pad     = ImGui.CalcTextSize("0").x;

    // Widths: seeded, then widened to fit the header and the widest cell this
    // frame actually holds. The frames measured that these MOVE.
    float numW = kSeedNumW, selW = kSeedNumW;
    {
        float wNum = ImGui.CalcTextSize("Num").x;
        float wSel = ImGui.CalcTextSize("Sel").x;
        void widen(StatCell c, StatAvail a, ref float w) {
            immutable float t = ImGui.CalcTextSize(cellText(c, a, false)).x;
            if (t > w) w = t;
        }
        foreach (ref s; rowBuf) {
            widen(s.num, s.avail, wNum);  widen(s.sel, s.avail, wSel);
            foreach (ref c; s.categories)
                foreach (ref l; c.leaves) {
                    widen(l.num, l.avail, wNum);  widen(l.sel, l.avail, wSel);
                }
        }
        if (wNum + pad > numW) numW = wNum + pad;
        if (wSel + pad > selW) selW = wSel + pad;
    }
    float actionW = kSeedActionW;
    {
        immutable float wPlus = ImGui.CalcTextSize("+").x + pad;
        if (wPlus > actionW) actionW = wPlus;
    }

    immutable uint inkNormal = IM_COL32(0,  0,  0,  255);
    immutable uint inkDim    = IM_COL32(97, 97, 97, 255);
    immutable ImVec4 vecNormal = ImVec4(0.0f, 0.0f, 0.0f, 1.0f);
    immutable ImVec4 vecDim    = ImVec4(0.38f, 0.38f, 0.38f, 1.0f);

    auto dl = ImGui.GetWindowDrawList();
    beginStatFrame();
    scope(exit) endStatFrame();

    // ---- Column headers, ONE row of the same pitch ------------------------
    // No `Separator()` anywhere in this panel: a separator is its own line of
    // height, and the row pitch is what the click test addresses rows by.
    //
    // THE HEADER IS LAID OUT BY THE DATA ROWS' OWN RULE, not by a second one.
    // A data row ends its name column at `right - numW - selW` and then draws
    // each number right-aligned inside its slot; the header does exactly that,
    // with "Name"/"Num"/"Sel" in place of the cell text. The version before this
    // one advanced by `nameW` AFTER "Name" — i.e. by the width of the word MORE
    // than the column — and padded "Sel" by an arbitrary `numW * 0.25f`, so both
    // titles sat to the right of the column they name. The widths are recomputed
    // FROM these titles above, which is only meaningful if the titles are in the
    // columns.
    {
        // Bound to locals, not passed as literals: `ImDrawList.AddText` has both
        // a `string` and a `const(char)*` overload, and a string LITERAL matches
        // both. The data cells below pass locals for the same reason.
        immutable string hName = "Name";
        immutable string hNum  = "Num";
        immutable string hSel  = "Sel";
        // All three titles through the SAME ink as the cells they head. Mixing
        // `TextDisabled` (the style's colour) with `dl.AddText` (this panel's
        // own `inkDim`) would put two greys on one line.
        ImGui.Dummy(ImVec2(actionW * 2.0f, rowH));
        ImGui.SameLine(0.0f, 0.0f);
        immutable float nameW = ImGui.GetContentRegionAvail().x - numW - selW;
        DrawnStatFrame fr;
        fr.actionW = actionW;
        {   // the name column: LEFT-aligned, exactly as a row's label is
            immutable ImVec2 hp = ImGui.GetCursorScreenPos();
            ImGui.Dummy(ImVec2(nameW > 0 ? nameW : 0.0f, rowH));
            dl.AddText(hp, inkDim, hName);
            ImGui.SameLine(0.0f, 0.0f);
        }
        {   // …and the two numeric columns: RIGHT-aligned, exactly as a cell is
            immutable ImVec2 np = ImGui.GetCursorScreenPos();
            fr.numX = np.x;
            ImGui.Dummy(ImVec2(numW, rowH));
            dl.AddText(ImVec2(np.x + numW - ImGui.CalcTextSize(hNum).x, np.y),
                       inkDim, hNum);
            ImGui.SameLine(0.0f, 0.0f);
        }
        {
            immutable ImVec2 sp = ImGui.GetCursorScreenPos();
            fr.selX = sp.x;
            ImGui.Dummy(ImVec2(selW, rowH));
            dl.AddText(ImVec2(sp.x + selW - ImGui.CalcTextSize(hSel).x, sp.y),
                       inkDim, hSel);
        }
        recordDrawnStatFrame(fr);
    }

    // ---- One row -----------------------------------------------------------
    // `rowId` is the ImGui id scope; `keyForToggle` is the expand key ("" for a
    // leaf, which has nothing to toggle).
    int rowSeq = 0;
    void drawRow(string level, string label, int depth, StatCell num, StatCell sel,
                 StatAvail avail, StatTone tone, string reason,
                 StatAction add, StatAction remove,
                 bool hasDisclosure, bool expanded, void delegate() toggle) {
        ImGui.PushID(rowSeq++);
        scope(exit) ImGui.PopID();

        // A CATEGORY row carries no numbers — the whole LEVEL, measured, and
        // blank is not one of the two placeholders.
        immutable bool blankCells = (level == "category");
        immutable bool dim = (tone == StatTone.dimmed);
        immutable uint ink = dim ? inkDim : inkNormal;
        // THE TONE, applied to the whole row INCLUDING its buttons — and never
        // by disabling anything. A dimmed row is fully clickable.
        ImGui.PushStyleColor(ImGuiCol.Text, dim ? vecDim : vecNormal);
        scope(exit) ImGui.PopStyleColor(1);

        immutable bool showButtons = (avail != StatAvail.noAffordance);
        immutable bool enabled     = (avail == StatAvail.live);

        // ---- the two action columns, FIRST and NEVER indented ----
        //
        // THE DISABLED TOOLTIP IS QUERIED WITH `AllowWhenDisabled`. Without the
        // flag `IsItemHovered` returns false for any item carrying
        // `ImGuiItemFlags_Disabled`, so every unmeasured / structural-zero /
        // inert-actions row carried a reason string no user could ever read —
        // while `StatAvail` and this panel's header both promise "disabled,
        // reason in the tip". The form is `renderPopupItems`' (this file, the
        // `MenuItem` arm).
        //
        // WHICH HALF OF THAT IS LOAD-BEARING, MEASURED, because the obvious
        // reading is wrong: the flag is, and the position of the query relative
        // to `EndDisabled` is NOT. `IsItemHovered` reads `g.LastItemData`, which
        // is the flag state captured when the BUTTON was submitted, not the
        // current stack — so asking inside the bracket answers identically.
        // (Mutation: move `tipHere()` back inside. It comes back green.) The
        // query stays outside anyway, matching the one correct site this
        // repository already had; but do not believe the bracket is the fix.
        //
        // ONE QUERY PER BUTTON, because `IsItemHovered` speaks about the LAST
        // item: a single query, wherever it sits, can only ever describe the
        // `-` cell, and the `+` cell's reason would go unread. Mutation:
        // delete the first `tipHere()` — the `+` half of verification D
        // reddens. (The two brackets are a consequence of putting both queries
        // outside; they are not themselves load-bearing, per the note above.)
        bool tipShown = false;
        void tipHere() {
            if (!enabled && reason.length
                && ImGui.IsItemHovered(ImGuiHoveredFlags.AllowWhenDisabled)) {
                ImGui.SetTooltip(reason);
                tipShown = true;
            }
        }
        if (showButtons) {
            if (!enabled) ImGui.BeginDisabled(true);
            if (ImGui.Button("+", ImVec2(actionW, rowH)) && enabled
                && run !is null && !add.empty)
                run(add.commandId, add.argsJson);
            if (!enabled) ImGui.EndDisabled();
            tipHere();
            ImGui.SameLine(0.0f, 0.0f);
            if (!enabled) ImGui.BeginDisabled(true);
            if (ImGui.Button("-", ImVec2(actionW, rowH)) && enabled
                && run !is null && !remove.empty)
                run(remove.commandId, remove.argsJson);
            if (!enabled) ImGui.EndDisabled();
            tipHere();
        } else {
            // EMPTY cells — not a greyed button. A greyed button is still an
            // affordance; this row has none.
            ImGui.Dummy(ImVec2(actionW * 2.0f, rowH));
        }
        ImGui.SameLine(0.0f, 0.0f);

        // ---- indent (the NAME column only) ----
        if (depth > 0) {
            ImGui.Dummy(ImVec2(indentW * depth, rowH));
            ImGui.SameLine(0.0f, 0.0f);
        }

        // ---- disclosure ----
        {
            immutable ImVec2 dp = ImGui.GetCursorScreenPos();
            if (hasDisclosure) {
                if (ImGui.InvisibleButton("##disc", ImVec2(rowH, rowH)) && toggle !is null)
                    toggle();
                drawDisclosure(dl, ImVec2(dp.x + rowH * 0.5f, dp.y + rowH * 0.5f),
                               gRad, expanded, ink);
            } else {
                ImGui.Dummy(ImVec2(rowH, rowH));
            }
            ImGui.SameLine(0.0f, 0.0f);
        }

        // ---- name, then the two numeric cells, right-aligned in their slots --
        immutable string numTx = cellText(num, avail, blankCells);
        immutable string selTx = cellText(sel, avail, blankCells);
        immutable float availW = ImGui.GetContentRegionAvail().x;
        immutable float nameW  = availW - numW - selW;
        ImGui.TextUnformatted(label);
        ImGui.SameLine(0.0f, 0.0f);
        {
            immutable ImVec2 cp = ImGui.GetCursorScreenPos();
            immutable float lw = ImGui.CalcTextSize(label).x;
            immutable float gap = nameW - lw;
            ImGui.Dummy(ImVec2(gap > 0 ? gap : 0.0f, rowH));
            ImGui.SameLine(0.0f, 0.0f);
        }
        float numX = 0, selX = 0;
        {
            immutable ImVec2 np = ImGui.GetCursorScreenPos();
            numX = np.x;
            ImGui.Dummy(ImVec2(numW, rowH));
            dl.AddText(ImVec2(np.x + numW - ImGui.CalcTextSize(numTx).x, np.y), ink,
                       numTx);
            ImGui.SameLine(0.0f, 0.0f);
        }
        {
            immutable ImVec2 sp = ImGui.GetCursorScreenPos();
            selX = sp.x;
            ImGui.Dummy(ImVec2(selW, rowH));
            dl.AddText(ImVec2(sp.x + selW - ImGui.CalcTextSize(selTx).x, sp.y), ink,
                       selTx);
        }

        DrawnStatRow rec;
        rec.level          = level;
        rec.label          = label;
        rec.numText        = numTx;
        rec.selText        = selTx;
        rec.avail          = availToken(avail);
        rec.tone           = dim ? "dimmed" : "normal";
        rec.expanded       = expanded;
        rec.hasActions     = showButtons;
        rec.actionsEnabled = showButtons && enabled;
        rec.addCommand     = add.commandId;
        rec.addArgs        = add.argsJson;
        rec.removeArgs     = remove.argsJson;
        rec.reason         = reason;
        // NOT `reason.length > 0` — that is the MODEL's claim that a tip exists.
        // This is the DRAWER's answer that one was emitted.
        rec.tipShown       = tipShown;
        rec.numX           = numX;
        rec.selX           = selX;
        recordDrawnStatRow(rec);
    }

    foreach (si, ref s; rowBuf) {
        immutable size_t sIdx = cast(size_t) s.type;
        drawRow("section", s.label, 0, s.num, s.sel, s.avail, s.tone, s.reason,
                s.add, s.remove, /*hasDisclosure=*/true, s.expanded,
                () { exp.section[sIdx] = !exp.section[sIdx]; });
        foreach (ci, ref c; s.categories) {
            // A CATEGORY ROW IS A LABEL, A TRIANGLE AND NOTHING ELSE — blank
            // numbers and empty action cells, by LEVEL rather than by case.
            immutable string key = c.key;
            drawRow("category", c.label, 1, c.num, c.sel, c.avail, StatTone.normal,
                    "", c.add, c.remove, /*hasDisclosure=*/true, c.expanded,
                    () { exp.category[key] = !exp.categoryOpen(key); });
            foreach (li, ref l; c.leaves)
                drawRow("leaf", l.label, 2, l.num, l.sel, l.avail, l.tone,
                        l.reason, l.add, l.remove, /*hasDisclosure=*/false,
                        false, null);
        }
    }
}
