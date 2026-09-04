module http_providers;

// app.d decomp, phase B (HTTP-provider span): wireHttpProviders hosts the
// entire `/api` endpoint-wiring block previously inline in app.d's main()
// (the `if (httpServer !is null) { ... }` span, ~2410 lines: every
// setXxxProvider/setXxxHandler registration, meshToDetailedJson, and the
// uiCommandDelegate/formsInteractiveDispatch/replayUndoEntry delegate
// assignments). Same seam as 0415's registration.d and 0419's ui/panels.d:
// the body is a VERBATIM cut wrapped in `with (app) { }`, so every bare
// identifier resolves to the matching EditorApp member.
//
// DIFFERENCE from the 0415/0419 precedents: `app` is a `ref` parameter, not
// by-value. The moved block ASSIGNS delegates that main() reads afterwards
// (uiCommandDelegate / formsInteractiveDispatch / replayUndoEntry) and
// mutates a shared latch (formsInteractiveLatch) -- with a by-value copy
// those writes would die inside this function's frame. All closures created
// here capture the single `ref`, so they share main()'s `app` storage.
//
// Call site: app.d, right after the task-0419 LATE ctx-wiring (the moved
// block reads fields from both the 0415 and 0419 wiring blocks, so it must
// run after both), followed by a 3-line sync-back of the assigned delegates
// into main()'s same-named locals.
//
// Import surface: mirrored verbatim from editor_app.d (itself harvested
// from app.d's top-level import block for task 0415), plus step_trace for
// the StepTrace-typed ctx field.
import editor_app : EditorApp, RecordMode;
// Task 1650 — `/api/viewport/display` reports the per-cell overlay decision
// the N-cell render loop STAMPED (`Viewport3D.lastOverlayMode`), so only the
// enum's name is needed here, not the resolver.
import editor_app : OverlayMode;
import viewport   : testRendersCell;
import step_trace : StepTrace;
import bindbc.sdl;
import bindbc.opengl;
import std.string : toStringz;
import std.stdio : writeln, writefln, File, stderr;
import std.math : tan, sin, cos, sqrt, PI, abs;
import std.conv;
import std.json : JSONValue, JSONType;
import http_server;
import json_num : jsonNum;
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
import commands.layer.commands : LayerAdd, LayerAttr;
import commands.tool.do_apply : ToolDoApplyCommand;
import commands.tool.reset    : ToolResetCommand;
import commands.tool.pipe     : ToolPipeAttrCommand;
import commands.tool.begin_session : ToolBeginSessionCommand;
import commands.ui.tool_properties : UiToolPropertiesCommand, g_toolPropertiesShown;
import commands.ui.layer_list      : UiLayerListCommand, g_layerListShown;
import commands.ui.image_list      : UiImageListCommand;
import commands.ui.channels        : UiChannelsCommand;
import commands.ui.statistics      : UiStatisticsCommand, UiStatisticsExpandCommand;
import commands.ui.about           : UiAboutCommand;
import commands.ui.pie             : UiPieCommand;
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
// Phase-B additions beyond editor_app.d's mirrored surface: the moved block
// also reads these module-level symbols (app.d imports them at its own top
// level / locally in main()).
import viewgrid : g_viewGrid, viewGridSize, viewGridSubStep, viewWorldPerPixel,
    viewGridFadeRadius, kGridMaskMin, kGridMaskMax, gridRungs;
import display_state : DisplayState, DisplayStyle, DrawPlan, WireOverlay,
    resolveDrawPlan;
import gpu_select : SelectMode;
import commands.prefs.coord_rounding : CoordRoundingCommand;
import commands.prefs.trackball     : TrackballPrefCommand;

// Locally-scoped in app.d's main() (not top-level there), but EditorApp is a
// module-scope struct so these three need to be top-level here (0415).
import document       : Document;
import command_history : CommandHistory;
import viewport        : ViewportManager, Viewport3D;
// Task 0617 — this module has no `Document` of its own (it operates on
// `EditorApp app`'s pointer-backed properties via `with(app)`); the primary
// layer's ModelSpace is resolved through the same global app.d's main()
// installs for every other cross-module picking call site.
import document       : primaryModelSpace;

/// Moved VERBATIM from app.d's top level (app.d decomp phase B): private
/// there, and its only call sites left app.d with the moved HTTP block.
/// `true` a JSON bool, so a command whose argument is "a value, whatever kind"
/// cannot read `.str` and hope. `%.9g` rather than `%g` on the float lane so a
/// value the user typed survives the trip in full precision — `%g`'s six
/// significant digits would quietly round a speed multiplier.
private string scalarArgToString(JSONValue v) {
    import std.format : format;
    import std.conv   : to;
    switch (v.type) {
        case JSONType.string:   return v.str;
        // json-num-exempt: builds an argstring, not a JSON body
        case JSONType.float_:   return format("%.9g", v.floating);
        case JSONType.integer:  return to!string(v.integer);
        case JSONType.uinteger: return to!string(v.uinteger);
        case JSONType.true_:    return "true";
        case JSONType.false_:   return "false";
        default:                return "";
    }
}

// ---------------------------------------------------------------------------
// oneStringArg — the single string argument of a `viewport.*` command, in
// whichever spelling the caller used: a bare JSON string body, the first
// `_positional` entry of an argstring parse, or a named key.
//
// Task 0720 (audit №4, D6). D6 reported this parsing "copied 3×". Measured,
// the viewport block has SIX positional readers following THREE different
// laws: this one (three arms — `viewport.view`, `viewport.layout` and the
// three independence toggles), a scalar-of-any-type reader that searches an
// ALIAS LIST of named keys (`displayStyle`/`wireOverlay`/`wireAlpha`,
// `gridSteps`), and an int-or-string reader (`viewport.master`). Only the
// first is one law written out repeatedly, so only the first is folded here;
// folding the other three sites into this would have changed what they accept.
//
// Throws exactly where the inline copies threw: `parseJSON` on a malformed
// body, which the command handler's own catch turns into
// `{"status":"error"}`.
// ---------------------------------------------------------------------------
private string oneStringArg(string paramsJson, string namedKey) {
    import std.json : parseJSON, JSONType;
    string outv = "";
    if (paramsJson.length > 0) {
        auto pjv = parseJSON(paramsJson);
        if (pjv.type == JSONType.string) {
            outv = pjv.str;
        } else if (pjv.type == JSONType.object) {
            if (auto pp = "_positional" in pjv) {
                if (pp.type == JSONType.array && pp.array.length >= 1
                    && pp.array[0].type == JSONType.string)
                    outv = pp.array[0].str;
            }
            if (outv.length == 0) {
                if (auto pp = namedKey in pjv)
                    if (pp.type == JSONType.string) outv = pp.str;
            }
        }
    }
    return outv;
}

unittest {
    // The three spellings the three folded arms accepted, and the two
    // non-answers. A positional entry WINS over the named key — that is the
    // order the inline copies had, and swapping it would silently change
    // which argument an argstring line with both actually applies.
    assert(oneStringArg(`"Top"`, "preset") == "Top");
    assert(oneStringArg(`{"_positional":["Top"]}`, "preset") == "Top");
    assert(oneStringArg(`{"preset":"Top"}`, "preset") == "Top");
    assert(oneStringArg(`{"_positional":["Top"],"preset":"Front"}`, "preset") == "Top");
    assert(oneStringArg("", "preset") == "");
    assert(oneStringArg(`{"other":"Top"}`, "preset") == "");
    // Non-string positional entries are not coerced (the arms fall back to
    // their own default rather than accept a number as a preset name).
    assert(oneStringArg(`{"_positional":[7]}`, "preset") == "");
    assert(oneStringArg(`{"preset":7}`, "preset") == "");
}

// ---------------------------------------------------------------------------
// injectViewportCommandPositional — argument extraction for the ten
// `viewport.*` commands (task 0761), called from `uiCommandDelegate`
// (`wireCommandProviders`, below) right after construction, before apply().
//
// Extraction, not command logic: every `switch`/range-check/throw a caller
// can observe still lives on the command class itself
// (`commands/viewport/*.d`) — this function's job is only to reproduce the
// THREE argument-reading laws the original interception used, verbatim, and
// hand each command the already-typed value(s) it asks for. Operates on the
// RAW `paramsJson` string (does its own `parseJSON`), not the pre-parsed
// object the tool.*/select.* injectors receive, because Law 1
// (`oneStringArg`) accepts a bare JSON string body — a shape those two
// injectors never see (they only run when `pj.type == JSONType.object`).
// ---------------------------------------------------------------------------
private void injectViewportCommandPositional(Command cmd, string paramsJson) {
    import std.json   : parseJSON, JSONType;
    import std.string : toLower, strip;
    import std.conv   : to, ConvException;
    import commands.viewport.view_preset  : ViewportViewPreset;
    import commands.viewport.layout_preset : ViewportLayoutPreset;
    import commands.viewport.independence : ViewportIndependence;
    import commands.viewport.display      : ViewportDisplayStyle, ViewportWireOverlay,
                                             ViewportWireAlpha;
    import commands.viewport.grid_steps   : ViewportGridSteps;
    import commands.viewport.master       : ViewportMaster;

    // Law 1 — oneStringArg: viewport.view / viewport.layout / the three
    // independence toggles.
    if (auto vv = cast(ViewportViewPreset)cmd) {
        vv.setPreset(oneStringArg(paramsJson, "preset"));
        return;
    }
    if (auto vl = cast(ViewportLayoutPreset)cmd) {
        vl.setPreset(oneStringArg(paramsJson, "preset"));
        return;
    }
    if (auto vi = cast(ViewportIndependence)cmd) {
        // Tolerant parse: "no"/"false"/"0" → false; anything else → true.
        string s = oneStringArg(paramsJson, "value");
        vi.setValue(!(s == "no" || s == "false" || s == "0"));
        return;
    }

    // Law 2 — scalar of ANY type, found by scanning an alias list of named
    // keys (or the first `_positional` entry, or a bare scalar body):
    // displayStyle/wireOverlay/wireAlpha share one alias list plus a
    // `viewport` cell key; gridSteps has its own, separate alias list and no
    // cell key (application-wide).
    bool isCellDisplay = (cast(ViewportDisplayStyle)cmd !is null)
                       || (cast(ViewportWireOverlay)cmd !is null)
                       || (cast(ViewportWireAlpha)cmd !is null);
    if (isCellDisplay) {
        string sval = "";
        int    cell = -1;
        bool   haveNum = false;
        double nval = 0;
        if (paramsJson.length > 0) {
            auto pjv = parseJSON(paramsJson);
            void takeScalar(JSONValue v) {
                switch (v.type) {
                    case JSONType.string:   sval = v.str; break;
                    case JSONType.float_:   nval = v.floating;             haveNum = true; break;
                    case JSONType.integer:  nval = cast(double)v.integer;  haveNum = true; break;
                    case JSONType.uinteger: nval = cast(double)v.uinteger; haveNum = true; break;
                    default: break;
                }
            }
            if (pjv.type != JSONType.object) {
                takeScalar(pjv);
            } else {
                if (auto pp = "_positional" in pjv)
                    if (pp.type == JSONType.array && pp.array.length >= 1)
                        takeScalar(pp.array[0]);
                if (sval.length == 0 && !haveNum) {
                    // Named forms: the generic "value", plus a per-command
                    // alias so a caller can be explicit.
                    foreach (key; ["value", "style", "wire", "overlay", "alpha"]) {
                        if (auto pp = key in pjv) { takeScalar(*pp); break; }
                    }
                }
                if (auto pp = "viewport" in pjv) {
                    if (pp.type == JSONType.integer)       cell = cast(int)pp.integer;
                    else if (pp.type == JSONType.uinteger) cell = cast(int)pp.uinteger;
                    else if (pp.type == JSONType.float_)   cell = cast(int)pp.floating;
                    else if (pp.type == JSONType.string) {
                        try { cell = to!int(pp.str.strip); }
                        catch (ConvException) { /* keep -1 = active */ }
                    }
                }
            }
        }
        if (auto ds = cast(ViewportDisplayStyle)cmd)  { ds.setRaw(sval, cell); return; }
        if (auto wo = cast(ViewportWireOverlay)cmd)   { wo.setRaw(sval, cell); return; }
        if (auto wa = cast(ViewportWireAlpha)cmd)     { wa.setRaw(sval, cell, haveNum, nval); return; }
    }

    if (auto gs = cast(ViewportGridSteps)cmd) {
        string sval = "";
        long   mval = long.min;
        if (paramsJson.length > 0) {
            auto pjv = parseJSON(paramsJson);
            void takeScalar(JSONValue v) {
                switch (v.type) {
                    case JSONType.string:   sval = v.str;                  break;
                    case JSONType.integer:  mval = v.integer;              break;
                    case JSONType.uinteger: mval = cast(long)v.uinteger;   break;
                    case JSONType.float_:   mval = cast(long)v.floating;   break;
                    default: break;
                }
            }
            if (pjv.type != JSONType.object) takeScalar(pjv);
            else {
                if (auto pp = "_positional" in pjv)
                    if (pp.type == JSONType.array && pp.array.length >= 1)
                        takeScalar(pp.array[0]);
                if (sval.length == 0 && mval == long.min)
                    foreach (key; ["value", "mask", "steps", "rungs"])
                        if (auto pp = key in pjv) { takeScalar(*pp); break; }
            }
        }
        gs.setRaw(sval, mval);
        return;
    }

    // Law 3 — int-or-string: viewport.master.
    if (auto vm = cast(ViewportMaster)cmd) {
        int mid = -1;
        if (paramsJson.length > 0) {
            auto pjv = parseJSON(paramsJson);
            string s = "";
            if (pjv.type == JSONType.integer)       { mid = cast(int)pjv.integer; }
            else if (pjv.type == JSONType.uinteger) { mid = cast(int)pjv.uinteger; }
            else if (pjv.type == JSONType.float_)   { mid = cast(int)pjv.floating; }
            else if (pjv.type == JSONType.string)   { s = pjv.str; }
            else if (pjv.type == JSONType.object) {
                if (auto pp = "_positional" in pjv) {
                    if (pp.type == JSONType.array && pp.array.length >= 1) {
                        auto v0 = pp.array[0];
                        if (v0.type == JSONType.integer)       mid = cast(int)v0.integer;
                        else if (v0.type == JSONType.uinteger) mid = cast(int)v0.uinteger;
                        else if (v0.type == JSONType.float_)   mid = cast(int)v0.floating;
                        else if (v0.type == JSONType.string)   s = v0.str;
                    }
                }
            }
            if (s.length > 0) {
                try { mid = to!int(s); } catch (ConvException) { /* keep -1 */ }
            }
        }
        vm.setRaw(mid);
        return;
    }
}

void wireHttpProviders(HttpServer httpServer, ref EditorApp app) {
    // Slots this build legitimately leaves empty. Appended BESIDE the
    // condition that decides each one, never collected in a list at the
    // bottom — a list at the bottom is how such a list rots away from the
    // condition it is supposed to describe. See the wiring check at the end.
    string[] optionalSlots;
    // Seven domains, one call each (task 0720, audit №4 D5). This used to be
    // a single 2872-line function body; the bodies below are unchanged, they
    // are merely reachable by name now. `optionalSlots` is threaded through
    // because two of the seven declare an exemption for the wiring check —
    // see the end of this function.
    wireModelProviders(httpServer, app, optionalSlots);
    wireViewportProviders(httpServer, app, optionalSlots);
    wireSelectionProviders(httpServer, app, optionalSlots);
    wireToolpipeProviders(httpServer, app, optionalSlots);
    wireCommandProviders(httpServer, app, optionalSlots);
    wireHistoryProviders(httpServer, app, optionalSlots);
    wireMutationHandlers(httpServer, app, optionalSlots);

    // Every slot filled? Task 0720. This function installs 42 delegates and
    // is the only thing that installs any of them, so a domain that stops
    // being wired is a domain whose endpoints answer "provider not set" — at
    // whatever later moment somebody happens to ask. Say it here instead,
    // where the cause is one frame away, and enumerate the slots with
    // `HttpServer.tupleof` rather than a list kept in step by hand.
    //
    // TWO slots are conditional, and both were found by running the binary
    // rather than by reading: `aiAnalyzeProvider` does not exist in
    // `modeling-noai`, and `injectLayerHandler` is deliberately not installed
    // outside `--test` (belt-and-braces beside the route's own 403). A check
    // that ignored them would have refused to start every non-test run — it
    // did, once, which is why both exemptions are declared at their own
    // `version`/`if` above instead of here.
    import std.algorithm : canFind, filter;
    import std.array     : array, join;
    auto unwired = httpServer.unwiredEndpoints()
                             .filter!(n => !optionalSlots.canFind(n)).array;
    if (unwired.length)
        throw new Exception(
            "HTTP endpoint wiring is incomplete — nothing installed: "
            ~ unwired.join(", "));

    // Task 1740 — the wiring is complete, so say so ONCE, here, and nowhere
    // else. Placed AFTER the completeness check above rather than before it
    // so the two cannot disagree: if a domain stopped being wired, this line
    // is unreachable and the server keeps answering 503 instead of claiming
    // readiness it does not have. The other half of the predicate (the main
    // loop has drained the bridges at least once) is set by `tickAll`; until
    // both hold, every `/api/*` route answers 503.
    httpServer.markProvidersWired();
}


// wireModelProviders — `/api/model`, `/api/layers`, `/api/images`, `/api/imageplane` — the
// document's geometry and its image clips.
private void wireModelProviders(HttpServer httpServer, ref EditorApp app,
                           ref string[] optionalSlots) {
    with (app) {
        // Serialize ANY mesh to the detailed /api/model JSON. Extracted so the
        // active-layer provider and the layer-aware ?layer=N provider share one
        // body (layers Stage 2).
        //
        // This used to build SEVEN temporaries and hand them all to
        // `meshToJsonDetailed`. Four were pure copies of data the serialiser
        // only reads (a Vec3→float[] reformat, a copy of `edges`, a `.dup` PER
        // FACE, a `.dup` of `surfaces`); the serialiser now reads the mesh, so
        // they are gone. The other three were PADDING, not copies — they
        // extended a possibly-shorter `isSubpatch`/`faceMaterial`/`facePart` up
        // to `faces.length` — and that is behaviour, so it moved INTO
        // `meshToJsonDetailed` unchanged rather than being dropped.
        //
        // Reading the live mesh with nothing copied in between is only safe
        // because `/api/model` is marshaled onto the main thread by
        // `modelBridge` — both providers below are invoked from that bridge's
        // service body during `tickAll()`, never on the HTTP thread.
        string meshToDetailedJson(ref Mesh m) {
            return meshToJsonDetailed(m);
        }

        httpServer.setDetailedModelDataProvider(() => meshToDetailedJson(mesh));
        // /api/model?layer=N — N<0 (default) → active layer; otherwise clamp
        // into range. Same detailed JSON shape, just a different source layer.
        httpServer.setLayerModelProvider((int layer) {
            import document : tokenOf, kNoEditTargetReason;
            // Task 0654: `layer=-1` (the default) means "the active layer",
            // and with an empty item selection there is none. REFUSE by name.
            // The clamp below is for an explicit out-of-range index and must
            // not be allowed to answer this one: clamping the absent-sentinel
            // would return layer 0's geometry under the name "the active
            // layer", which is indistinguishable from success to a caller —
            // and is precisely the silent substitution this state exists to
            // make impossible.
            if (layer < 0 && !document.hasEditTarget())
                return `{"error":"` ~ kNoEditTargetReason ~ `"}`;
            size_t idx = layer < 0 ? document.activeIndex : cast(size_t)layer;
            if (idx >= document.layers.length) idx = document.layers.length - 1;
            auto lyr = document.layers[idx];
            // Task 0615 Stage 7: a non-mesh layer has no `meshRef()` to hand
            // out — calling it unconditionally would trip its `debug` assert
            // (a live mixed document is now reachable via the Stage 6/7 test
            // injector, so this is a real crash the sweep hit, not a
            // hypothetical). Report the kind explicitly instead of a silent
            // empty mesh — the fuller Stage 9 HTTP-surface shape (a `"type"`
            // on every /api/layers row, etc.) is out of scope for this
            // slice; this is the minimal guard needed so a mixed-document
            // test does not crash the app.
            if (!lyr.hasMesh)
                return `{"error":"layer ` ~ idx.to!string
                     ~ ` has no mesh (kind ` ~ tokenOf(lyr.kind) ~ `)"}`;
            return meshToDetailedJson(lyr.meshRef());
        });
        // GET /api/mesh/planes — the plane-complete readback (task 1903 Stage B,
        // plan §6.3). It answers off the SAME live active mesh `/api/model`
        // does and for the same reason it is safe here: the bridge invokes this
        // during `tickAll()` on the main thread, never on the HTTP thread.
        //
        // Deliberately NOT layer-aware. The parity fixtures this feeds are
        // captured against the EDIT TARGET — the mesh the command family under
        // migration actually writes — and a `?layer=N` here would let a capture
        // silently name a mesh no command touched.
        httpServer.setMeshPlanesProvider((string producedBy, string path,
                                          string family, string stand) {
            PlaneDumpMeta meta;
            meta.producedBy = producedBy;
            meta.path       = path;
            meta.family     = family;
            meta.stand      = stand;
            return meshPlanesJson(mesh, meta);
        });
        // GET /api/layers — index/name/type/visible/background/active + per-layer
        // vertex & face counts + the per-layer mutationVersion (a read-only
        // diagnostic the Stage-6 cross-layer-undo torture test reads to confirm
        // two identical layers genuinely share a version — the cache-key
        // collision precondition the address-augmented keys defend against).
        // Task 0615 Stage 9: "type" (the wire token, e.g. "mesh"/"empty") and
        // "focused" (item-selection focus, distinct from "primary" — the mesh
        // edit target — once a non-mesh item is selected) close the gap that
        // forced every test in this task to reach for an in-module unittest
        // instead of the HTTP surface. "vertexCount"/"faceCount"/
        // "mutationVersion" are JSON `null` exactly when "type" is not
        // "mesh" — never `0`, which is a legal empty MESH and must stay
        // distinguishable from "no mesh at all" to an HTTP-only caller.
        //
        // NAMING ASYMMETRY (intentional, review round): this read surface —
        // and /api/selection's `items[]`, same shape — reports the kind as
        // "type". The test-only write route, POST /api/test/layer (below,
        // testMode-gated), takes it as "kind" instead. The two are not
        // meant to be copy-pasted between; a client author reading only one
        // of them should not assume the other's field name.
        httpServer.setLayersDataProvider(() {
            import std.array  : appender;
            import std.format : format;
            import std.json   : JSONValue;
            import document   : Document, tokenOf, LinkState;  // Document.background (derived, 2b)
            import image_plane : imagePlaneSource, sourceToken;
            import hover_state : g_hoveredItem;
            auto a = appender!string();
            // `hoveredItem` (task 0647) — the item under the cursor, or -1.
            // Exposed HERE, beside `active`, because it is an index into this
            // same `layers` array and reading it anywhere else would make a
            // caller pair two responses that the main thread can splice
            // between. It is the one observable that separates "the ray found
            // the wrong item" from "the ray was right and the paint is wrong",
            // which no pixel can answer on its own.
            // Task 0654: `active` is -1 when the item selection is empty. Not
            // `layers.length` (the in-process absent-sentinel) — over the wire
            // the field sits beside `hoveredItem`, which already spells
            // "nothing" as -1, and a reader that treats an index it does not
            // recognise as valid is likelier to index with `layers.length`
            // than with -1.
            a.put(format(`{"active":%d,"hoveredItem":%d,"layers":[`,
                         document.hasEditTarget() ? cast(long) document.activeIndex : -1L,
                         g_hoveredItem));
            foreach (i, l; document.layers) {
                if (i > 0) a.put(",");
                // `background` is now DERIVED (Stage 2b): visible && !selected —
                // the stored bool is gone. `selected` + `primary` are the #4
                // item-selection surface: `selected` is the per-layer foreground
                // membership, `primary` marks the single edit target (== active).
                // A test reads these to verify the multi-select set + which member
                // is primary; `background` is the derived third-state collapse.
                // Channels P4: expose the per-layer item transform so tests can
                // assert the NON-BAKED transform without it ever moving vertices.
                // The authored components (pos/rot/scl/pivot) let a test assert a
                // round-trip; the composed `matrix` (column-major float[16]) lets
                // the analytic golden fixture assert the composed result against an
                // INDEPENDENT hand formula. Pure JSON-shape addition ~~(the data
                // provider already runs the snapshot on the main thread)~~.
                //
                // That parenthetical was FALSE when it was written and is TRUE
                // now, which is the worst order for a justification to be read
                // in (task 0612 Stage 6, the stale-comment sweep). `/api/model`
                // was the marshalled one; this provider was served straight
                // from the HTTP thread until Stage 3 gave it `layersBridge` —
                // for a different reason (the `links[].target` resolve is a
                // nested `indexOf` walk over an array the main thread splices).
                // So: the claim holds, but it is Stage 3 that makes it hold,
                // not the P4 addition it was attached to.
                const x = l.xform;
                float[16] m = x.composedMatrix();
                auto xb = appender!string();
                xb.put(format(
                    `{"pos":[%s,%s,%s],"rot":[%s,%s,%s],` ~
                    `"scl":[%s,%s,%s],"pivot":[%s,%s,%s],"matrix":[`,
                    jsonNum(x.pos.x, "%.6f"), jsonNum(x.pos.y, "%.6f"),
                    jsonNum(x.pos.z, "%.6f"), jsonNum(x.rot.x, "%.6f"),
                    jsonNum(x.rot.y, "%.6f"), jsonNum(x.rot.z, "%.6f"),
                    jsonNum(x.scl.x, "%.6f"), jsonNum(x.scl.y, "%.6f"),
                    jsonNum(x.scl.z, "%.6f"), jsonNum(x.pivot.x, "%.6f"),
                    jsonNum(x.pivot.y, "%.6f"), jsonNum(x.pivot.z, "%.6f")));
                foreach (mi; 0 .. 16) {
                    if (mi > 0) xb.put(",");
                    xb.put(jsonNum(m[mi], "%.6f"));
                }
                xb.put("]}");
                // Task 0082: find the parent layer's index (-1 = no parent).
                int parentIdx = -1;
                if (l.parent !is null) {
                    foreach (pi, pl; document.layers)
                        if (pl is l.parent) { parentIdx = cast(int)pi; break; }
                }
                // Task 0615 Stage 7 fixed the crash (a non-mesh layer has no
                // `meshRef()` to dereference unconditionally — it trips the
                // `debug` assert in `meshRef()`). Stage 9 fixes the SHAPE:
                // the three counters are JSON `null` for a non-mesh layer,
                // not `0` — `0` is a legal empty mesh and the two must stay
                // distinguishable to a caller that only has this response.
                // recorded remainder (1906 §3.5 row 28, §3.6): `mutationVersion`
                // owns `mvJson` and there is nothing to migrate — this is an
                // OUTPUT VALUE on the wire, not a cache key. It is the only wire
                // view of a version stamp in the API (`/api/changes` carries bus
                // COUNTERS, which are a different thing), so tests that need to
                // see an edit stamp read it here. Answered.mainThread, so the
                // read is bridged; it is NOT one of §1.8's HTTP-thread readers.
                string vcJson = "null", fcJson = "null", mvJson = "null";
                if (l.hasMesh) {
                    vcJson = l.meshRef().vertices.length.to!string;
                    fcJson = l.meshRef().faces.length.to!string;
                    mvJson = (cast(ulong) l.meshRef().mutationVersion).to!string;
                }
                // Task 0612 Stage 3 — the first HTTP view of the link model.
                // `target` is the TARGET'S LAYER INDEX, resolved here and
                // only here: a link identifies its target by OBJECT, and the
                // index is a wire encoding of that identity, valid exactly as
                // long as the array it indexes is the one this response
                // describes. That is why this provider is marshaled — the
                // nested `indexOf` walk below runs inside the loop already
                // walking `layers`, and a splice between the two would make
                // the response name the wrong layer. `parent` a few lines up
                // has the same shape and was the precedent.
                //
                // `target` is -1 for a link that does not resolve, and
                // `state` is what says WHY: "unset" and "dangling" are
                // different facts (never set, versus the target was deleted)
                // and a reader that only had the index could not tell them
                // apart.
                auto lb = appender!string();
                lb.put("[");
                foreach (si, ref slot; l.linkSlots()) {
                    if (si > 0) lb.put(",");
                    int tgt = -1;
                    if (auto t = slot.link.resolve(document)) {
                        foreach (ti, tl; document.layers)
                            if (tl is t) { tgt = cast(int) ti; break; }
                    }
                    string stateTok;
                    final switch (slot.link.state(document)) {
                        case LinkState.Unset:    stateTok = "unset";    break;
                        case LinkState.Live:     stateTok = "live";     break;
                        case LinkState.Dangling: stateTok = "dangling"; break;
                    }
                    lb.put(format(`{"slot":%s,"target":%d,"state":%s}`,
                        JSONValue(slot.name).toString(), tgt,
                        JSONValue(stateTok).toString()));
                }
                lb.put("]");
                // The plane's four-state source verdict, JSON `null` for
                // every other kind — the `vertexCount` convention, and for
                // the same reason: "not an image plane" and "an image plane
                // with no image" must stay distinguishable to a caller that
                // only has this response.
                string srcJson = "null";
                if (l.hasImagePlane)
                    srcJson = JSONValue(sourceToken(imagePlaneSource(document, l))).toString();
                // Task 0612 Stage 8 (§7.2 consequence 2) — DERIVED, no stored
                // state: is this layer in the item-transform moving set?
                //
                // It exists because the narrowing is otherwise INVISIBLE. The
                // Layers panel keeps rendering the mesh as selected (it IS
                // selected — the document invariant forces it), while a Move
                // gesture no longer touches it. `selected` alone can no longer
                // answer "will the gizmo move this", so the answer is reported
                // rather than left to be inferred from a diff.
                immutable bool isXTarget = document.isTransformTarget(l);
                a.put(format(
                    `{"index":%d,"birthId":%s,"name":%s,"type":%s,"visible":%s,"background":%s,` ~
                    `"foreground":%s,` ~
                    `"active":%s,"selected":%s,"primary":%s,"focused":%s,` ~
                    `"transformTarget":%s,` ~
                    `"vertexCount":%s,"faceCount":%s,` ~
                    `"mutationVersion":%s,"xform":%s,"parent":%d,` ~
                    `"links":%s,"imageSource":%s}`,
                    i, l.birthId.to!string, JSONValue(l.name).toString(),
                    JSONValue(tokenOf(l.kind)).toString(),
                    l.visible ? "true" : "false",
                    document.background(l) ? "true" : "false",
                    // Task 0671: `foreground` is NOT `!background` and is not
                    // `visible && selected` either. It is the other arm of the
                    // same three-way classifier, and a hidden or non-scene item
                    // is neither — so a caller that wants "is this an active
                    // layer" has to read this rather than negate the line
                    // above. It is also the only way an HTTP test can see the
                    // LATCH: a deselected mesh that is still being edited
                    // reports selected:false, background:false, foreground:true.
                    document.foreground(l) ? "true" : "false",
                    // Task 0654: false for EVERY row when nothing is selected
                    // — `activeIndex` is then `layers.length`, which matches no
                    // `i`, so this already reads correctly; spelled through
                    // `hasEditTarget` so it stays correct if the sentinel moves.
                    (document.hasEditTarget() && i == document.activeIndex)
                        ? "true" : "false",
                    l.selected ? "true" : "false",
                    document.isPrimary(l) ? "true" : "false",
                    document.isFocused(l) ? "true" : "false",
                    isXTarget ? "true" : "false",
                    vcJson, fcJson, mvJson, xb.data, parentIdx,
                    lb.data, srcJson));
            }
            a.put("]}");
            return a.data;
        });
        // GET /api/images — the document's image-clip rows plus the pixel
        // cache's residency counters (task 0612 Stage 1, plan §8).
        //
        // The two halves are here TOGETHER on purpose: "which files does the
        // document name" and "which files are resident" is one question asked
        // from two sides, and a test that reads them from two endpoints
        // cannot know they were true at the same instant. This provider runs
        // on the main thread (`imagesBridge`), so the pair is consistent.
        //
        // SYNCHRONISATION (task 0612 Stage 5, plan §8). A `POST /api/command`
        // returns once the command has run on the main thread, but `reconcile`
        // runs in the FRAME loop, which may not have ticked before the
        // following `GET /api/images` is served — so a residency assertion
        // written the obvious way races the renderer and fails intermittently
        // in whichever direction the scheduler picks. Marshalling alone does
        // not fix it (the bridge ticks in the event phase), so this handler
        // runs `reconcile` ITSELF before reading the counters. It is
        // idempotent, main-thread, and it is the only such JIT recompute left
        // in a provider. The precedent this used to cite — `buildItemFrame`
        // being called from "the render-thread per-frame install and the
        // HTTP-thread JIT install" — died with task 0587, which deleted the
        // JIT half; the doc comment that named it was corrected by task 1780.
        // The argument above stands on its own and never rested on that.
        httpServer.setImagesDataProvider(() {
            import std.array  : appender;
            import std.format : format;
            import std.json   : JSONValue;
            import io.image_path : resolveStoredPath;
            import io.doc_state  : currentDocPath;
            import image_cache   : imagePixelCache;
            import image_plane   : collectLivePlanePaths;

            imagePixelCache().reconcile(collectLivePlanePaths(document));

            auto a = appender!string();
            a.put(`{"images":[`);
            bool first = true;
            foreach (i, l; document.layers) {
                auto img = l.imageOrNull();
                if (img is null) continue;   // capability-gated: not an image item
                if (!first) a.put(",");
                first = false;
                const abs = resolveStoredPath(img.storedPath, currentDocPath());
                a.put(format(
                    `{"index":%d,"name":%s,"storedPath":%s,"absPath":%s,` ~
                    `"width":%d,"height":%d,"channels":%d,"missing":%s}`,
                    i, JSONValue(l.name).toString(),
                    JSONValue(img.storedPath).toString(),
                    JSONValue(abs).toString(),
                    img.width, img.height, img.channels,
                    img.missing ? "true" : "false"));
            }
            a.put(format(`],"cache":{"residentEntries":%d,"residentBytes":%d,"decodes":%d}}`,
                imagePixelCache().residentEntries(),
                imagePixelCache().residentBytes(),
                imagePixelCache().decodeCount()));
            return a.data;
        });
        // GET /api/imageplane?index=N&cell=K — the resolved placement of one
        // image plane in one viewport cell (task 0612 Stage 4, plan §8).
        //
        // WHY THE CELL IS AN INDEX AND NOT A PRESET. The interesting question
        // this endpoint answers is "which cell draws which plane", and you
        // cannot detect which preset a cell resolves to through an endpoint
        // you HAND the preset to. So the caller names a cell and the two
        // camera facts are read HERE, from `views[K].camera` — which is the
        // correct source follow or no follow: `resolveFollow` resolves only
        // focus / distance / orientation, never `projKind` / `viewPreset`.
        //
        // `cellPreset` / `cellOrtho` are echoed back for the same reason a
        // test asserts its own fixture: a viewport-match assertion against a
        // cell that is not configured the way the test believes is inert, and
        // these two fields are how it finds out.
        httpServer.setImagePlaneProvider((int index, int cell) {
            import std.array  : appender;
            import std.format : format;
            import std.json   : JSONValue;
            import std.conv   : to;
            import image_plane : resolvePlacementFor, imagePlaneSource,
                                 sourceToken, kImageLinkSlot, ImagePlaneSource;
            import view : ProjKind;

            if (index < 0 || index >= cast(int) document.layers.length)
                return `{"error":"no layer ` ~ index.to!string ~ `"}`;
            auto lyr = document.layers[index];
            // A typed refusal, not an empty placement: "layer 3 is a mesh" and
            // "layer 3 is a plane showing nothing" are different answers, and a
            // caller with only this response could not tell them apart if both
            // came back as zeros.
            if (!lyr.hasImagePlane) {
                import document : tokenOf;
                return `{"error":"layer ` ~ index.to!string
                     ~ ` is not an image plane (kind ` ~ tokenOf(lyr.kind) ~ `)"}`;
            }
            if (cell < 0 || cell >= vpm.cellCount)
                return `{"error":"no viewport cell ` ~ cell.to!string ~ `"}`;

            // The clip's pixel dimensions come from the LINKED clip's payload
            // — the one place the disk's answer lives. They stay 0 unless the
            // source is Ready, which is what makes a broken plane's extent
            // empty without a second rule saying so. That walk now lives in
            // `resolvePlacementFor` (task 0643), shared with the draw pass and
            // the item ray; the two dimensions are still reported below, read
            // back from the same clip so the response says which numbers the
            // law was given.
            const src = imagePlaneSource(document, lyr);
            int cw = 0, ch = 0;
            if (src == ImagePlaneSource.Ready) {
                auto clip = lyr.link(kImageLinkSlot).resolve(document);
                auto img  = clip.imageOrNull();
                cw  = img.width;
                ch  = img.height;
            }

            auto camera   = vpm.views[cell].camera;
            const preset  = camera.viewPreset;
            const isOrtho = camera.projKind == ProjKind.Ortho;
            auto pl = resolvePlacementFor(document, lyr, preset, isOrtho);

            string vec(Vec3 v) {
                return format("[%s,%s,%s]", jsonNum(v.x, "%.6f"),
                              jsonNum(v.y, "%.6f"), jsonNum(v.z, "%.6f"));
            }
            return format(
                `{"index":%d,"cell":%d,"cellPreset":%s,"cellOrtho":%s,`
                ~ `"drawn":%s,"source":%s,"clipWidth":%d,"clipHeight":%d,`
                ~ `"center":%s,"halfU":%s,"halfV":%s,`
                ~ `"flipU":%s,"invert":%s,"smooth":%s,`
                ~ `"brightness":%s,"contrast":%s,"transparency":%s,`
                ~ `"sourcePath":%s}`,
                index, cell, JSONValue(preset.to!string).toString(),
                isOrtho ? "true" : "false",
                pl.drawn ? "true" : "false",
                JSONValue(sourceToken(pl.source)).toString(), cw, ch,
                vec(pl.center), vec(pl.halfU), vec(pl.halfV),
                pl.flipU  ? "true" : "false",
                pl.invert ? "true" : "false",
                pl.smooth ? "true" : "false",
                jsonNum(pl.brightness, "%.6f"), jsonNum(pl.contrast, "%.6f"),
                jsonNum(pl.transparency, "%.6f"),
                JSONValue(pl.sourcePath).toString());
        });
    }
}

// wireViewportProviders — `/api/camera` (both verbs), `/api/gpu/face-vbo`,
// `/api/viewport/display`, `/api/viewport/probe`, `/api/pick`,
// `/api/surface-raycast` — everything that answers about a CELL.
private void wireViewportProviders(HttpServer httpServer, ref EditorApp app,
                              ref string[] optionalSlots) {
    with (app) {
        httpServer.setCameraDataProvider((int vpIdx) {
            int _idx = (vpIdx >= 0 && vpIdx < vpm.cellCount) ? vpIdx : vpm.activeId;
            string base = vpm.resolvedCameraJson(_idx);
            // Additive, read-only fields for numpad-view-shortcut assertions
            // (task 0215): splice viewPreset/projKind into the existing JSON
            // body without touching View.toJsonWith, which other call sites
            // and its own unittests already pin to the base shape.
            string presetName = to!string(vpm.views[_idx].camera.viewPreset);
            string projName   = to!string(vpm.views[_idx].camera.projKind);
            return base[0 .. $ - 1] ~ `,"viewPreset":"` ~ presetName ~
                `","projKind":"` ~ projName ~ `"}`;
        });

        // GET /api/gpu/face-vbo — read back gpu.faceVbo on the main
        // (GL) thread and return the position triples as JSON. Used by
        // test_subpatch_move to verify the subpatch surface actually
        // updates after a /api/transform; the /api/model snapshot
        // alone can't catch a broken fan-out shader since it only
        // reflects the cage.
        httpServer.setGpuSurfaceProvider(() {
            import std.array : appender;
            import std.format : format;
            import bindbc.opengl;
            // Mid-batch pull-guard: this provider is MainThreadBridge-serviced
            // during httpServer.tickAll(), i.e. BEFORE this frame's flush — a
            // command earlier in the same tick may have mutated the mesh
            // without the (bus-driven) upload having run yet.
            //
            // recorded remainder (1906 §3.5 row 29): this endpoint polls no
            // counter at all — it delegates its whole freshness question to the
            // family-1 display guard, which IS bus-keyed (`g_displayEpochs`, via
            // `displayServiced_`). That indirection is the migration; there is
            // nothing left here to key.
            ensureDisplayCurrent();
            // Faces use stride-6 (pos+normal). Read the live VBO.
            int vertCount = gpu.faceVertCount;
            // Also expose the model matrix the renderer applies to the
            // VBO (transform tools' gpuMatrix) so tests can detect a
            // gpuMatrix-vs-mesh mismatch mid-drag — the actual on-screen
            // pose is `gpuMatrix · gpu.faceVbo`.
            float[16] meshModel = identityMatrix;
            {
                TransformTool tt = cast(TransformTool)activeTool;
                if (tt !is null) meshModel = tt.gpuMatrix;
            }
            string modelStr;
            {
                auto mb = appender!string();
                mb.put("[");
                foreach (i; 0 .. 16) {
                    if (i > 0) mb.put(",");
                    mb.put(jsonNum(meshModel[i], "%.6f"));
                }
                mb.put("]");
                modelStr = mb.data;
            }
            // Task 0613 S3 — the EDGE and VERTEX VBOs, read back the same way.
            // Until this task the only VBO readback in the whole HTTP surface
            // was the face one, so "did hiding actually remove this vertex
            // from the buffer, and did the drag refresh keep the same layout"
            // (plan T-S3b / T-R11 / T-S3d) had no observable at all and the
            // tests could not be written. Tight-packed triples, one buffer
            // each, plus the two counts and `edgeOriginLen` — the last is the
            // R11/R12 sentinel itself (`edgeOriginGpu.length`), whose being 0
            // when nothing is hidden is exactly what keeps the draw path
            // byte-identical.
            string tailStr;
            {
                auto tb = appender!string();
                tb.put(`,"vertCount":`);
                tb.put(format("%d", gpu.vertCount));
                tb.put(`,"edgeVertCount":`);
                tb.put(format("%d", gpu.edgeVertCount));
                tb.put(`,"edgeOriginLen":`);
                tb.put(format("%d", gpu.edgeOriginGpu.length));
                static void putTriples(A)(ref A sink, string key,
                                          uint vbo, int count) {
                    sink.put(`,"` ~ key ~ `":[`);
                    if (count > 0 && vbo != 0) {
                        float[] d = new float[](count * 3);
                        glBindBuffer(GL_ARRAY_BUFFER, vbo);
                        glGetBufferSubData(GL_ARRAY_BUFFER, 0,
                            cast(GLsizeiptr)(d.length * float.sizeof), d.ptr);
                        glBindBuffer(GL_ARRAY_BUFFER, 0);
                        foreach (i; 0 .. count) {
                            if (i > 0) sink.put(",");
                            sink.put(format("[%s,%s,%s]",
                                jsonNum(d[i*3 + 0], "%.6f"),
                                jsonNum(d[i*3 + 1], "%.6f"),
                                jsonNum(d[i*3 + 2], "%.6f")));
                        }
                    }
                    sink.put("]");
                }
                putTriples(tb, "vertPositions", gpu.vertVbo,     gpu.vertCount);
                putTriples(tb, "edgePositions", gpu.edgeVbo,     gpu.edgeVertCount);
                tailStr = tb.data;
            }
            if (vertCount <= 0)
                return `{"faceVertCount":0,"positions":[],"model":` ~ modelStr
                     ~ tailStr ~ `}`;
            float[] data = new float[](vertCount * 6);
            glBindBuffer(GL_ARRAY_BUFFER, gpu.faceVbo);
            glGetBufferSubData(GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(data.length * float.sizeof),
                data.ptr);
            glBindBuffer(GL_ARRAY_BUFFER, 0);
            auto buf = appender!string();
            buf.put(`{"faceVertCount":`);
            buf.put(format("%d", vertCount));
            buf.put(`,"positions":[`);
            foreach (i; 0 .. vertCount) {
                if (i > 0) buf.put(",");
                buf.put(format("[%s,%s,%s]",
                    jsonNum(data[i * 6 + 0], "%.6f"),
                    jsonNum(data[i * 6 + 1], "%.6f"),
                    jsonNum(data[i * 6 + 2], "%.6f")));
            }
            buf.put(`],"model":`);
            buf.put(modelStr);
            buf.put(tailStr);
            buf.put("}");
            return buf.data;
        });

        // GET /api/viewport/display — task 0559 (viewport display modes).
        // Dumps, per cell, the display STATE and the resolved DRAW PLANS.
        // These are the same `resolveDrawPlan` calls the render loop and the
        // cell's dirty key make, so asserting the dump is asserting drawing —
        // there is no second derivation that could drift.
        //
        // `renders` reports whether this cell is actually being re-rendered
        // under the current mode; in --test only the active cell is, and a
        // pixel probe aimed at any other cell would read a never-filled FBO
        // and pass for the wrong reason. State assertions do not need it.
        httpServer.setViewportDisplayProvider(() {
            import std.array  : appender;
            import std.format : format;
            import std.conv   : to;

            static string planJson(in DrawPlan p) {
                // `facesLit` is KEPT alongside `shading` (task 1090). It is
                // asserted by the existing suite and it now reads off the
                // derived accessor, so it cannot disagree with `shading`; but
                // it can no longer SEPARATE the two unlit styles, which is
                // exactly why `shading` joins it rather than replaces it.
                return format(
                    `{"drawFaces":%s,"facesLit":%s,"shading":"%s","dim":%s,` ~
                    `"fillColor":[%s,%s,%s],` ~
                    `"drawWire":%s,"wireAlpha":%s,` ~
                    `"wireColor":[%s,%s,%s],"drawVerts":%s}`,
                    p.drawFaces ? "true" : "false",
                    p.facesLit  ? "true" : "false",
                    p.shading.to!string,
                    jsonNum(p.dim, "%.6f"),
                    jsonNum(p.fillColor[0], "%.6f"),
                    jsonNum(p.fillColor[1], "%.6f"),
                    jsonNum(p.fillColor[2], "%.6f"),
                    p.drawWire  ? "true" : "false",
                    jsonNum(p.wireAlpha, "%.6f"),
                    jsonNum(p.wireColor[0], "%.6f"),
                    jsonNum(p.wireColor[1], "%.6f"),
                    jsonNum(p.wireColor[2], "%.6f"),
                    p.drawVerts ? "true" : "false");
            }
            static string stateJson(in DisplayState s) {
                return format(`{"style":"%s","wire":"%s","wireAlpha":%s}`,
                    s.style.to!string, s.wire.to!string,
                    jsonNum(s.wireAlpha, "%.6f"));
            }

            // Task 0570: the grid terms, per cell, straight from the
            // renderer's own inputs. Reported at %.9g rather than a fixed
            // number of decimals because a rung spans nine decades (1e-4 to
            // 1e5 are all reachable zooms) and a %.6f would print the fine
            // end as 0.000000 — an assertion about a step it cannot see.
            static string gridJson(const ref Viewport gv) {
                immutable float px = viewWorldPerPixel(gv);
                immutable float gs = viewGridSize(px, g_viewGrid);
                immutable float ss = viewGridSubStep(px, gs, g_viewGrid);
                // `fadeRadius` is read through the same function the draw
                // site calls, not recomputed here — a reporter with its own
                // copy of a formula is how a dump starts lying.
                return format(
                    `{"mask":%d,"pixelSize":%s,"size":%s,"subStep":%s,` ~
                    `"cellPixels":%s,"fadeRadius":%s}`,
                    g_viewGrid.rungMask,
                    jsonNum(px, "%.9g"), jsonNum(gs, "%.9g"),
                    jsonNum(ss, "%.9g"),
                    jsonNum(px > 0 ? gs / px : 0.0f, "%.9g"),
                    jsonNum(viewGridFadeRadius(gs > 0 ? gs : 1.0f), "%.9g"));
            }

            // Task 1090: WHICH weight map is current, and whether it resolves.
            //
            // Here rather than on /api/selection because this endpoint's
            // stated contract (above) is "the render inputs this cell's
            // passes consume, off the same call the renderer makes" — and
            // that is exactly what these two are: the same accessor and the
            // same resolver, against the PRIMARY mesh.
            //
            // `weightMapResolved` is the discriminator the delete / rename /
            // wrong-layer cases need. Those states render IDENTICALLY to "no
            // map selected" by design (D7), so a pixel probe alone cannot
            // separate "nothing selected" from "selected but dangling"; this
            // field can.
            string wmName;
            bool   wmResolved;
            {
                import weightmap_view : currentWeightMapName, resolveWeightMap;
                wmName = currentWeightMapName();
                Mesh* pm = document.activeMesh();
                wmResolved = wmName.length > 0 && pm !is null
                    && resolveWeightMap(*pm, wmName) !is null;
            }

            // Task 1650 — the per-cell OVERLAY decision. NOT re-derived here:
            // reported from the stamp the N-cell render loop wrote when it
            // made the decision (`Viewport3D.lastOverlayMode`).
            //
            // The difference is not pedantry, it was measured. The defect
            // task 1650 fixed was a tool-type gate at the loop's CALL SITE,
            // and a first version of this dump called the shared resolver
            // itself. With the pre-fix gate restored, that dump still reported
            // `Visual` for all three non-owner cells while the loop drew
            // nothing in them — the endpoint the test asserts on had stopped
            // describing the thing the test was about. `overlayOwner` is read
            // live because it is an input the loop does not consume
            // destructively.
            immutable int _ovlOwner = vpm.overlayOwnerId();

            // Task 1691 — the one term of the viewport-input guard that had
            // no observable at all. `app.d`'s item-pick branch, the lasso, the
            // camera drags and the tool dispatch all sit behind
            // `viewportInputAllowed()`, which in `--test` is exactly
            // `!io.WantCaptureMouse`; when ImGui holds the mouse every click
            // in the instance is swallowed silently, and from outside that is
            // indistinguishable from a pick that resolved to nothing.
            //
            // WHY HERE. This route is already test-only and already answered
            // on the MAIN thread (http_server.d's RouteSpec table,
            // `Answered.mainThread`), which is the only place `app.io` may be
            // touched — `WantCaptureMouse` is recomputed inside NewFrame and
            // an HTTP-thread read would race it. Nothing new is opened, and
            // the fields cost two bool reads.
            //
            // `viewportInputAllowed` comes from the app's OWN forwarder
            // (`EditorApp.viewportInputAllowedDg`), not from a second copy of
            // its formula written here — see `overlayOwner` above for the
            // defect that shape produced when this file last re-derived a
            // call-site decision.
            //
            // `modals` names WHICH latch is up, because "ImGui held the mouse"
            // does not say what did. A `BeginPopupModal` captures the mouse
            // globally and survives `/api/reset`, so one left open by a blind
            // command sweep swallows every later click in the worker's shared
            // instance. These are the app's own latches, read live; the popup
            // stack itself is not reachable through the binding.
            string inputJson;
            {
                auto ib = appender!string();
                immutable bool wantMouse = (io !is null) && io.WantCaptureMouse;
                immutable bool allowed   = viewportInputAllowedDg !is null
                                         ? viewportInputAllowedDg() : true;
                ib.put(format(`{"wantCaptureMouse":%s,"viewportInputAllowed":%s,`
                              ~ `"modals":[`,
                              wantMouse ? "true" : "false",
                              allowed   ? "true" : "false"));
                size_t nModal = 0;
                void modal(string id, bool open) {
                    if (!open) return;
                    if (nModal++ > 0) ib.put(",");
                    ib.put(JSONValue(id).toString());
                }
                modal("ai3d.generate",  ai3dModalOpen);
                modal("ai3d.install",   ai3dInstallConfirmOpen);
                modal("mesh.remesh",    remeshModalOpen);
                modal("discard.confirm", discardConfirmOpen);
                modal("command.notice", noticeOpen);
                ib.put("]}");
                inputJson = ib.data;
            }

            auto buf = appender!string();
            buf.put(format(`{"activeId":%d,"cellCount":%d,"overlayOwner":%d,` ~
                           `"weightMap":%s,"weightMapResolved":%s,"input":%s,` ~
                           `"cells":[`,
                           vpm.activeId, vpm.cellCount, _ovlOwner,
                           JSONValue(wmName).toString(),
                           wmResolved ? "true" : "false",
                           inputJson));
            foreach (k; 0 .. vpm.cellCount) {
                if (k > 0) buf.put(",");
                Viewport3D cv = vpm.views[k];
                // Same predicate the render loop uses, not a second copy of
                // it — see viewport.testRendersCell.
                immutable bool renders =
                    testMode ? testRendersCell(k, vpm.activeId, vpm.cellCount) : true;
                // The SAME snapshot the render loop feeds
                // renderViewportSceneToFbo, so the reported grid cannot
                // disagree with the drawn one by construction.
                Viewport gvp = vpm.resolvedSnapshot(k);
                // Task 1830 — the selection-visibility policy this cell's
                // display style resolves to.
                //
                // The SAME resolver the picker calls, not a second copy of it
                // — `vpm.pickVisibility()` is `vpm.visibilityFor(activeId)`.
                // A local `resolveSelectVisibility(...)` here — or a
                // literal `kSelectVisibilityDefault` in the `policy` field
                // below — would keep answering from the shipped default on
                // the day a writer appears (a stored value, a per-document
                // preference, backdrop handling), and
                // `tests/test_viewport_display.d` pins both, so they would
                // stay green over the lie.
                //
                // STILL NOT EVIDENCE THAT THE PICKER ASKS. One resolver
                // guarantees the two agree on the POLICY; it says nothing
                // about the term reaching `gpuSelect`. If someone stopped
                // passing it, this field would go on reporting a healthy
                // `occlusion:false` while every pick still occluded — exactly
                // the `lastOverlayMode` failure this file's own history
                // records. The proof that the term is WIRED is
                // `tests/test_wireframe_select_through.d`, which drives real
                // picks and reads what came back.
                //
                // Reported for EVERY cell, while the picker only ever runs in
                // the active one, so for k != activeId this is "what the
                // policy would be if a gesture landed here".
                immutable svTerms = vpm.visibilityFor(k);
                buf.put(format(
                    `{"id":%d,"renders":%s,"overlayMode":"%s","selEpoch":%d,` ~
                    `"ortho":%s,"userSet":%s,` ~
                    `"selectVisibility":{"policy":"%s","facing":%s,"occlusion":%s},` ~
                    `"state":{"active":%s,"backdrop":%s,"backdropStyle":"%s"},` ~
                    `"plan":{"active":%s,"backdrop":%s},"grid":%s}`,
                    k,
                    renders ? "true" : "false",
                    (cast(OverlayMode)cv.lastOverlayMode).to!string,
                    // Task 1931 — Viewport3D.lastSelEpoch, the per-cell copy
                    // of the change bus's selection-channel epoch. Same
                    // reasoning as `overlayMode` just above: a suite test has
                    // no other way to see `fboSelEpoch` move.
                    cv.lastSelEpoch,
                    // Task 0594. `ortho` is what the shipped display default
                    // is a function of, and `userSet` is what outranks it —
                    // reporting both is what lets a test assert the DEFAULT
                    // and its PRECEDENCE against the cell's own inputs,
                    // instead of inferring them from a cell index that the
                    // layout is free to reassign.
                    cv.isOrtho() ? "true" : "false",
                    cv.displayUserSet ? "true" : "false",
                    vpm.visibilityPolicyFor(k).to!string,
                    svTerms.facingTerm    ? "true" : "false",
                    svTerms.occlusionTerm ? "true" : "false",
                    stateJson(cv.display.active),
                    stateJson(cv.display.backdrop),
                    cv.display.backdropStyle.to!string,
                    planJson(resolveDrawPlan(cv.display, false)),
                    planJson(resolveDrawPlan(cv.display, true)),
                    gridJson(gvp)));
            }
            buf.put("]}");
            return buf.data;
        });

        // GET /api/viewport/probe?cell=N[&x=&y=][&points=][&hash=1] —
        // task 0559. glReadPixels against one cell's FBO colour attachment:
        // the only tier of this feature's testing that proves GL actually
        // did something, as opposed to that the plan said it should.
        //
        // Coordinates are FBO pixels, origin TOP-LEFT (screen convention, the
        // one every event log and every other endpoint uses); the flip to
        // GL's bottom-up origin happens here so no caller has to know.
        //
        // `hash=1` digests the WHOLE colour buffer. That is what turns "this
        // refactor changed no pixels" from an assertion into a measurement.
        //
        // Serviced during tickAll(), which runs BEFORE this frame's scene
        // render — so a probe reads the last COMPLETED frame, which is what
        // you want. Callers that just changed something must let a frame pass.
        httpServer.setViewportProbeProvider((int cell, string points, bool wantHash) {
            import bindbc.opengl;
            import std.array  : appender, split;
            import std.conv   : to;
            import std.format : format;
            import std.string : strip;

            if (cell < 0) cell = vpm.activeId;
            if (cell < 0 || cell >= cast(int)vpm.views.length)
                return format(`{"error":"cell %d out of range"}`, cell);

            Viewport3D cv = vpm.views[cell];
            // Same predicate the render loop and /api/viewport/display use —
            // one implementation, so the flag cannot claim a cell rendered
            // when the loop skipped it (see viewport.testRendersCell).
            immutable bool renders =
                testMode ? testRendersCell(cell, vpm.activeId, vpm.cellCount) : true;
            immutable int W = cv.fbo.w;
            immutable int H = cv.fbo.h;
            immutable string head = format(
                `{"cell":%d,"renders":%s,"w":%d,"h":%d`,
                cell, renders ? "true" : "false", W, H);

            if (cv.fbo.fbo == 0 || W <= 0 || H <= 0)
                return head ~ `,"points":[],"error":"cell has no framebuffer yet"}`;

            GLint prevRead = 0;
            glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevRead);
            glBindFramebuffer(GL_READ_FRAMEBUFFER, cv.fbo.fbo);
            glReadBuffer(GL_COLOR_ATTACHMENT0);
            scope(exit) glBindFramebuffer(GL_READ_FRAMEBUFFER, cast(GLuint)prevRead);

            auto buf = appender!string();
            buf.put(head);
            buf.put(`,"points":[`);
            bool first = true;
            foreach (spec; points.split(";")) {
                auto s = spec.strip();
                if (s.length == 0) continue;
                auto xy = s.split(",");
                if (xy.length != 2) continue;
                int px, py;
                try {
                    px = xy[0].strip.to!int;
                    py = xy[1].strip.to!int;
                } catch (Exception) {
                    continue;
                }
                if (!first) buf.put(",");
                first = false;
                if (px < 0 || py < 0 || px >= W || py >= H) {
                    buf.put(format(`{"x":%d,"y":%d,"error":"outside the cell"}`, px, py));
                    continue;
                }
                ubyte[4] rgba;
                // Flip Y: caller passes top-left origin, GL reads bottom-up.
                glReadPixels(px, H - 1 - py, 1, 1,
                             GL_RGBA, GL_UNSIGNED_BYTE, rgba.ptr);
                buf.put(format(`{"x":%d,"y":%d,"r":%d,"g":%d,"b":%d,"a":%d}`,
                               px, py, rgba[0], rgba[1], rgba[2], rgba[3]));
            }
            buf.put("]");

            if (wantHash) {
                // FNV-1a over the whole RGBA8 buffer. Cheap, stable, and a
                // mismatch is a real difference — not a tolerance question.
                auto all = new ubyte[](cast(size_t)W * cast(size_t)H * 4);
                glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, all.ptr);
                ulong h = 0xcbf2_9ce4_8422_2325UL;
                foreach (b; all) {
                    h ^= b;
                    h *= 0x0000_0100_0000_01b3UL;
                }
                buf.put(format(`,"hash":"%016x"`, h));
            }

            buf.put("}");
            return buf.data;
        });

        // ---- GET /api/subpatch/preview (task 1500) ----------------------
        // The SINGLE source of the async build's numbers. Deliberately not
        // in `g_frames`: `FrameProbe` is a no-op stub in the default build
        // (perf_probe.d), so a counter parked there would be identically
        // zero in the test lane and every assertion on it would be vacuous.
        // These are ordinary struct fields on SubpatchPreview, live in every
        // configuration.
        httpServer.setSubpatchStateProvider(() {
            import std.format : format;
            return format(
                `{"active":%s,"pending":%s,"abandoned":%s,"generation":%d,`
              ~ `"builds":%d,"discarded":%d,"chosenLevel":%d,`
              ~ `"workerBuildNs":%d,"workerAllocBytes":%d,`
              ~ `"workerBuildNsTotal":%d,"workerAllocBytesTotal":%d,`
              ~ `"pendingFrames":%d,"topologiesCreated":%d,`
              ~ `"topologiesRetired":%d,"previewFaces":%d,"previewEdges":%d,`
              ~ `"estimatedMsRemaining":%d,"indicator":"%s"}`,
                subpatchPreview.active         ? "true" : "false",
                subpatchPreview.buildPending   ? "true" : "false",
                subpatchPreview.buildAbandoned ? "true" : "false",
                subpatchPreview.buildGeneration,
                subpatchPreview.buildsCompleted,
                subpatchPreview.buildsDiscarded,
                subpatchPreview.chosenLevel,
                subpatchPreview.workerBuildNs,
                subpatchPreview.workerAllocBytes,
                subpatchPreview.workerBuildNsTotal,
                subpatchPreview.workerAllocBytesTotal,
                subpatchPreview.pendingFrames,
                subpatchPreview.osdAccel.topologiesCreated,
                subpatchPreview.osdAccel.topologiesRetired,
                subpatchPreview.mesh.faces.length,
                subpatchPreview.mesh.edges.length,
                subpatchPreview.estimatedBuildMsRemaining(),
                subpatchPreview.buildIndicatorText());
        });

        // ---- POST /api/subpatch/hold {"ms":N,"ceilingMs":M} --------------
        // Holds RECEPTION of a finished build, not the worker: the build
        // completes normally, so the bounded join inside `OsdAccel.clear()`
        // never waits under a hold and `/api/reset` stays instant even
        // mid-hold — which is what lets the ceiling test clean up after
        // itself. `ms:-1` = hold until released, `ms:0` = release.
        // `ceilingMs` configures the input barrier's own ceiling; without
        // that knob the ceiling would be a branch no test could ever see
        // taken.
        httpServer.setSubpatchHoldHandler((long ms, long ceilingMs) {
            import std.format : format;
            // Clamped at BOTH ends even though the route is `--test` only:
            // an unbounded `ceilingMs` would turn the input barrier back into
            // the thing it exists not to be, and a typo is a likelier source
            // of one than malice. `holdMs` scales no allocation and no loop
            // bound (it is compared against wall time), so it needs no
            // ceiling of its own — only its `-1` sentinel is special.
            enum long kMaxCeilingMs = 600_000;
            subpatchPreview.holdMs = ms;
            if (ceilingMs > 0)
                subpatchPreview.ceilingMs =
                    ceilingMs > kMaxCeilingMs ? kMaxCeilingMs : ceilingMs;
            return format(`{"status":"ok","ms":%d,"ceilingMs":%d}`,
                          subpatchPreview.holdMs, subpatchPreview.ceilingMs);
        });

        // GET /api/pick?x=&y=&engine=bvh|gpu — A/B face-pick oracle.
        // engine=gpu calls gpuSelect.pick DIRECTLY regardless of VIBE3D_FACE_PICK
        // so the oracle is always reachable even when BVH is the default.
        httpServer.setPickProvider((int x, int y, string engine) {
            import std.format : format;
            // Mid-batch pull-guard: serviced during tickAll, before the flush
            // (see the surface provider above) — both engines read
            // upload-derived state (ID-FBO / BVH keyed on gpu.uploadVersion).
            //
            // recorded remainder (1906 §3.5 row 29): same as the surface
            // provider — no counter is polled here; the freshness question is
            // delegated to the bus-keyed display guard, and the two engines'
            // own `uploadVersion` keys are rows 5 and 6, argued at their sites.
            ensureDisplayCurrent();
            Viewport vp = vpm.activeSnapshot();
            int faceIdx;
            // Task 0617: both engines pick the PRIMARY layer here.
            if (engine == "gpu") {
                // The selection-visibility term is INERT for the face path
                // by construction — `renderMode` never runs the depth
                // pre-pass for `SelectMode.Face` — so this oracle answers the
                // same face index under every display style. That is the
                // declared shape of the face gap, not an oversight; passing
                // the resolved term rather than a literal keeps this call
                // site from becoming the one place with a policy of its own.
                faceIdx = gpuSelect.pick(SelectMode.Face, x, y, /*r=*/0,
                                          mesh, gpu, vp, primaryModelSpace(),
                                          vpm.pickVisibility().occlusionTerm);
            } else {
                // ---- M-INV (task 1500), CONSUMER 2 of 2 ----------------
                // Same one-sided invariant as the RMB-lasso site in app.d:
                // if the CPU side has switched to preview index space, the
                // buffers the BVH was built from must have switched too.
                // See that site for why the converse is legal and why this
                // is a plain `assert` rather than a `debug` block.
                if (subpatchPreview.active) assert(gpuUploadedPreview,
                    "pick: preview trace is live but the VBOs still hold the cage");
                const(Mesh)* srcMesh = subpatchPreview.active
                    ? &subpatchPreview.mesh : &mesh();
                faceIdx = bvhPick.pickFace(x, y, vp, *srcMesh, gpu, primaryModelSpace());
            }
            return format(`{"faceIndex":%d}`, faceIdx);
        });

        // GET /api/surface-raycast?x=&y=[&thresholdPx=] — background-surface
        // raycast oracle (topology-pen P0/P1, doc/topopen_p0_plan.md,
        // doc/topopen_p1_plan.md). Main-thread bridge (mirrors /api/pick
        // above): builds a SubjectPacket with cursorValid=true at the
        // requested pixel, evaluates the live toolpipe (the CONS stage's
        // raycast branch fires because cursorValid is true here), and
        // reports the resulting ConstrainHitPacket PLUS (P1) the resolved
        // hover snap-target (targetKind/targetVert/targetEdge), computed by
        // the SAME `resolveHoverTarget` (constraint.d) that
        // TopologyPenTool calls — this endpoint and the tool always agree.
        // GL-free — the CONS raycast reads snap.backgroundSourcesSnapshot()
        // (CPU-side Mesh pointers) via BvhPick, no GPU state involved, so
        // this needs no ensureDisplayCurrent().
        //
        // NIT-5 (multi-viewport caveat, deferred): this uses
        // `vpm.activeSnapshot()` (the currently-ACTIVE viewport cell), while
        // the real mouse-event dispatch path (buildToolVts, further down)
        // uses `vpm.inputSnapshot()` (the cell the event itself landed in).
        // The two coincide for P0's single-viewport test scenes, so `x`/`y`
        // here are unambiguous; a multi-viewport caller wanting the
        // raycast scoped to a NON-active cell would need this endpoint to
        // accept an explicit viewport id, same as `/api/camera`'s
        // `_viewport` override — not needed until a later phase actually
        // exercises multi-viewport topology-pen.
        httpServer.setSurfaceRaycastProvider((int x, int y, float thresholdPx) {
            import std.format        : format;
            import toolpipe.packets  : ConstrainHitPacket, HoverTargetKind;
            import toolpipe.subject  : SubjectSource, evaluateSubject;
            import constraint        : resolveHoverTarget, topoPenPressPickPx;

            auto src = SubjectSource(&mesh(), editMode,
                                      currentSelType(selTypeOrder),
                                      vpm.activeSnapshot());
            src.cursorX     = x;
            src.cursorY     = y;
            src.cursorValid = true;

            SubjectPacket subj;
            VectorStack vts;
            evaluateSubject(subj, vts, src);

            auto hp = vts.get!ConstrainHitPacket();
            if (hp is null)
                return `{"hit":false,"targetKind":"none","targetVert":-1,"targetEdge":-1}`;

            float th = (thresholdPx > 0.0f) ? thresholdPx : topoPenPressPickPx(subj.viewport);
            auto tgt = resolveHoverTarget(*hp, subj.viewport, th);
            string kindToken;
            final switch (tgt.kind) {
                case HoverTargetKind.None:   kindToken = "none";   break;
                case HoverTargetKind.Vertex: kindToken = "vertex"; break;
                case HoverTargetKind.Edge:   kindToken = "edge";   break;
                case HoverTargetKind.Face:   kindToken = "face";   break;
            }

            return format(
                `{"hit":%s,"point":[%s,%s,%s],"normal":[%s,%s,%s],`
              ~ `"layer":%d,"face":%d,"nearestVert":%d,"nearestEdge":%d,`
              ~ `"targetKind":"%s","targetVert":%d,"targetEdge":%d}`,
                hp.hit ? "true" : "false",
                jsonNum(hp.point.x, "%.6f"), jsonNum(hp.point.y, "%.6f"),
                jsonNum(hp.point.z, "%.6f"),
                jsonNum(hp.normal.x, "%.6f"), jsonNum(hp.normal.y, "%.6f"),
                jsonNum(hp.normal.z, "%.6f"),
                hp.layer, hp.face, hp.nearestVert, hp.nearestEdge,
                kindToken, tgt.vert, tgt.edge);
        });

        // POST /api/camera — set live View. Accepts azimuth, elevation,
        // distance, roll (radians/world-units) and optional focus[x,y,z] +
        // width/height. Used by the cross-engine drag test to align
        // vibe3d's camera with a reference engine's before replaying —
        // `roll` is the third rotational term such a reference publishes for
        // its own view and which, until it existed here, could not be
        // transferred at all.
        httpServer.setCameraSetHandler((JSONValue p) {
            import math : Vec3;
            // Resolve target cell: _viewport injected by http_server.d from ?viewport=N
            int _vidx = vpm.activeId;
            if ("_viewport" in p) {
                auto _vn = p["_viewport"];
                int _v = -1;
                if (_vn.type == JSONType.integer)        _v = cast(int)_vn.integer;
                else if (_vn.type == JSONType.uinteger)  _v = cast(int)_vn.uinteger;
                else if (_vn.type == JSONType.float_)    _v = cast(int)_vn.floating;
                if (_v >= 0 && _v < vpm.cellCount) _vidx = _v;
            }
            ref View targetCam = vpm.views[_vidx].camera;
            float floatFrom(string field, float def) {
                if (field !in p) return def;
                auto n = p[field];
                switch (n.type) {
                    case JSONType.integer:  return cast(float)n.integer;
                    case JSONType.uinteger: return cast(float)n.uinteger;
                    case JSONType.float_:   return cast(float)n.floating;
                    default: throw new Exception(
                        "'" ~ field ~ "' must be a number");
                }
            }
            // The whole ROTATION, as the nine floats the camera actually
            // stores. This is the only key that can express an arbitrary
            // orientation — one reached by composing rotations about
            // different axes, or carrying a bank at a pole — and it is
            // LOSSLESS both ways (`%.9g` out, parsed back to the same
            // floats). The three angle keys below remain, but they are a
            // chart: they cannot name every rotation and they lose precision
            // at `%f`.
            //
            // Applied FIRST so a body may set the rotation wholesale and then
            // adjust one angle of it, and rejected as a unit — a malformed
            // value leaves the camera alone rather than aiming it somewhere
            // arbitrary. `setOrientation` re-orthonormalises, so a caller may
            // post a matrix measured off another engine without cleaning it.
            if ("orientation" in p) {
                Orientation o;
                if (!orientationFromJson(p["orientation"], o))
                    throw new Exception(
                        "'orientation' must be an array of 9 numbers");
                targetCam.setOrientation(o);
            }
            if ("azimuth" in p)   targetCam.azimuth   = floatFrom("azimuth",   targetCam.azimuth);
            if ("elevation" in p) targetCam.elevation = floatFrom("elevation", targetCam.elevation);
            if ("distance" in p)  targetCam.distance  = floatFrom("distance",  targetCam.distance);
            // Bank, radians. Absent key leaves the current bank alone, so
            // every existing camera-set body is unaffected.
            if ("roll" in p)      targetCam.roll      = floatFrom("roll",      targetCam.roll);
            if ("focus" in p) {
                auto f = p["focus"];
                float comp(string k, float def) {
                    if (k !in f.object) return def;
                    auto n = f[k];
                    switch (n.type) {
                        case JSONType.integer:  return cast(float)n.integer;
                        case JSONType.uinteger: return cast(float)n.uinteger;
                        case JSONType.float_:   return cast(float)n.floating;
                        default: throw new Exception(
                            "focus." ~ k ~ " must be a number");
                    }
                }
                targetCam.focus = Vec3(comp("x", targetCam.focus.x),
                                       comp("y", targetCam.focus.y),
                                       comp("z", targetCam.focus.z));
            }
            // Optional viewport resize.
            if ("width" in p && "height" in p) {
                targetCam.setSize(
                    cast(int)floatFrom("width",  targetCam.width),
                    cast(int)floatFrom("height", targetCam.height));
            }
        });
    }
}

// wireSelectionProviders — `/api/selection`, `/api/tool/handles`, `/api/tool/state`,
// `/api/recorded-events` — read-only introspection of what is selected
// and what the active tool is doing.
private void wireSelectionProviders(HttpServer httpServer, ref EditorApp app,
                               ref string[] optionalSlots) {
    with (app) {
        httpServer.setSelectionDataProvider(() {
            // recorded remainder (1906 §3.5 row 26, §1.8): this provider polls
            // no counter and MUST NOT subscribe or read `mesh_dirty.g_*Epochs`.
            // `/api/selection` is `Answered.httpThread` — it runs on the HTTP
            // thread, and both the change bus and the epoch tables are
            // main-thread-only and unsynchronised by design (delivery is
            // main-thread by construction, since every mutating endpoint reaches
            // the mesh through `MainThreadBridge`). It re-reads live state
            // instead, which is race-tolerant for a read-only introspection
            // endpoint in the way an epoch compare would not be. The task 0950
            // hole is untouched by 1906.
            // Derivation invariant: editMode is a materialized view of
            // selTypeOrder.mostRecentGeometry. Any bypassing writer (raw
            // *editModePtr write without going through the funnel) surfaces
            // here as a hard failure in a debug build — every selection test
            // already reads /api/selection, so regressions are caught immediately.
            debug assert(editMode == derivedEditMode(),
                "editMode drifted from selTypeOrder — a writer bypassed the funnel");
            string modeName;
            final switch (editMode) {
                case EditMode.Vertices: modeName = "vertices"; break;
                case EditMode.Edges:    modeName = "edges";    break;
                case EditMode.Polygons: modeName = "polygons"; break;
            }
            // selType (Stage 1): the CURRENT selection type from the recent
            // ordering — lowercase singular token (vertex/edge/polygon/item),
            // matching the geometry payload's vocabulary. `selTypeOrder` is the
            // full most-recent-first ordering (front == current); `items` is the
            // item (layer) selection view — one `{selected,primary,type,focused}`
            // entry per layer, in layer order. These are the Stage 4 final
            // shapes plus the Stage 9 `type`/`focused` additions; the
            // geometry-selection arrays are unchanged.
            import std.json : JSONValue;
            import document : tokenOf;
            JSONValue[] orderArr;
            foreach (t; selTypeOrder.order)
                orderArr ~= JSONValue(selTypeToken(t));
            JSONValue[] itemsArr;
            foreach (l; document.layers) {
                auto item = JSONValue.emptyObject;
                item["selected"] = JSONValue(l.selected);
                item["primary"]  = JSONValue(document.isPrimary(l));
                item["type"]     = JSONValue(tokenOf(l.kind));
                item["focused"]  = JSONValue(document.isFocused(l));
                itemsArr ~= item;
            }
            JSONValue selectedIndices(bool[] sel) {
                JSONValue[] arr;
                foreach (i, s; sel)
                    if (s) arr ~= JSONValue(i);
                return JSONValue(arr);
            }
            auto root = JSONValue.emptyObject;
            root["mode"]             = JSONValue(modeName);
            root["selType"]          = JSONValue(selTypeToken(selTypeOrder.current()));
            root["selTypeOrder"]     = JSONValue(orderArr);
            root["items"]            = JSONValue(itemsArr);
            root["selectedVertices"] = selectedIndices(mesh.selectedVertices);
            root["selectedEdges"]    = selectedIndices(mesh.selectedEdges);
            root["selectedFaces"]    = selectedIndices(mesh.selectedFaces);
            return root.toString();
        });
        // Task 0234 — GET /api/tool/handles + GET /api/tool/state. Read-only
        // test-introspection over the active tool; null-guard mirrors every
        // other activeTool-reading provider in this file. See the
        // ToolHandlesDataProvider doc comment in http_server.d for the
        // thread-safety discriminator. That comment used to say these two
        // need no lock "unlike the toolpipe/snap providers below which
        // marshal to the main thread"; both halves have since gone stale.
        // /api/tool/handles is itself MARSHALED now (toolHandlesBridge,
        // task 0563 — the handle registry is rebuilt every draw), and the
        // snap/constrain providers do NOT marshal: they run on the HTTP
        // thread and call pipeline.evaluate() there. Only /api/tool/state
        // is still a direct read, and only because it reads resident
        // per-tool fields.
        httpServer.setToolHandlesDataProvider(() {
            import std.json : JSONValue;
            JSONValue root = JSONValue.emptyObject;
            root["handles"] = activeTool is null ? JSONValue(null) : activeTool.toolHandlesJson();
            return root.toString();
        });
        httpServer.setToolStateDataProvider(() {
            return activeTool is null ? "{}" : activeTool.toolStateJson().toString();
        });
        httpServer.setRecordedEventsProvider(() {
            import std.file : exists, readText;
            if (!exists("recording.jsonl")) return null;
            return readText("recording.jsonl");
        });
        // Phase 7.0 — Tool Pipe inspection. Returns JSON listing the
        // stages currently registered with the global pipe (task FOURCC,
        // id, ordinal, enabled flag, plus per-stage attrs from
        // listAttrs).
    }
}

// wireToolpipeProviders — `/api/toolpipe`, `/api/toolpipe/eval`, `/api/registry`,
// `/api/ai/analyze`, `/api/snap`, `/api/snap/last`, `/api/constrain`,
// `/api/path` — the tool pipeline and everything it elects.
private void wireToolpipeProviders(HttpServer httpServer, ref EditorApp app,
                              ref string[] optionalSlots) {
    with (app) {
        httpServer.setToolPipeProvider(() {
            import std.array  : appender;
            import std.format : format;
            auto buf = appender!string;
            buf.put(`{"stages":[`);
            bool first = true;
            if (g_pipeCtx !is null) {
                foreach (s; g_pipeCtx.pipeline.all()) {
                    if (!first) buf.put(",");
                    first = false;
                    uint code = cast(uint)s.taskCode();
                    char[4] taskStr = [
                        cast(char)((code >> 24) & 0xFF),
                        cast(char)((code >> 16) & 0xFF),
                        cast(char)((code >>  8) & 0xFF),
                        cast(char)( code        & 0xFF),
                    ];
                    buf.put(format(
                        `{"task":"%s","id":"%s","ordinal":%d,"enabled":%s,"attrs":{`,
                        taskStr.idup, s.id(), s.ordinal(),
                        s.pipeEnabled ? "true" : "false"));
                    bool firstAttr = true;
                    foreach (kv; s.listAttrs()) {
                        if (!firstAttr) buf.put(",");
                        firstAttr = false;
                        buf.put(format(`"%s":"%s"`, kv[0], kv[1]));
                    }
                    buf.put(`}}`);
                }
            }
            buf.put(`]}`);
            return buf.data;
        });

        // GET /api/registry — returns every registered command and tool
        // factory id as JSON arrays. Read-only snapshot of post-startup-
        // immutable AAs; served directly from the HTTP thread.
        //
        // `?params=1` (task 0365, param-bounds Phase 3): additionally emits
        // `commandParams`/`toolParams`, one entry per registered id, each a
        // JSON array of that id's Param schema — {name, kind, enforceBounds,
        // value, min?, max?}. `value` is boxed via `paramToJson` so the wire
        // shape matches the existing `tool.attr <id> <attr> ?` read-back
        // convention. This is the enabler for the fuzz-smoke's static
        // "born-clamped" contract check (tests/test_param_bounds.d) — a
        // generic reader instead of a hand-maintained per-tool table.
        //
        // The schema text is CACHED (reg.commandParamsJson / toolParamsJson,
        // filled by cacheSupportedModes() at startup) and the body is built
        // by `Registry.registryJson`, which is a pure read of those caches.
        // This closure used to instantiate every factory inline — on the HTTP
        // thread, which is where a tool constructor's glGenVertexArrays ran
        // with no current GL context and killed the process. The builder
        // lives in registry.d so the "answers without calling a factory"
        // invariant is unit-testable; keep it there.
        httpServer.setRegistryProvider(
            (bool includeParams) => reg.registryJson(includeParams));

        // Pipeline evaluation snapshot — runs pipeline.evaluate once with
        // the current mesh + selection + camera and returns the resulting
        // ActionCenterPacket / AxisPacket as JSON. The reference-diff
        // parity harness reads this to compare vibe3d's computed
        // pivot/axis to a reference engine's for the same case.
        //
        // NOT called from the HTTP thread, despite what this comment said
        // for a long time: /api/toolpipe/eval is marshaled onto the main
        // thread through pipeEvalBridge, precisely because
        // pipeline.evaluate touches View state (cameraView.viewport()
        // recomputes view/proj) and writes g_pipeCtx's caches. The service
        // body below therefore runs inside tickAll(), on the main thread.
        // All five pipeline-evaluating providers (this one, /api/snap,
        // /api/constrain, /api/path, /api/surface-raycast) are main-thread-
        // bridged (their own bridge, own epoch pair — http_server.d) —
        // there is no off-thread pipeline read left to cite.
        httpServer.setToolPipeEvalProvider(() {
            import std.array       : appender;
            import std.format      : format;
            import toolpipe.pipeline : g_pipeCtx;
            import toolpipe.subject  : SubjectSource, evaluateSubject;
            import toolpipe.packets  : SubjectPacket;
            import math              : Vec3;

            auto buf = appender!string;
            // N1 (task 1904): the null check stays BEFORE the subject is
            // built, byte-for-byte with the pre-migration order -- so that
            // &mesh() / currentSelType(...) / vpm.activeSnapshot() are never
            // evaluated when the pipe is not registered.
            if (g_pipeCtx is null) {
                buf.put(`{"error":"pipeline not initialised"}`);
                return buf.data;
            }
            auto src = SubjectSource(&mesh(), editMode,
                                      currentSelType(selTypeOrder),
                                      vpm.activeSnapshot());

            import operator             : VectorStack;
            import toolpipe.packets     : ActionCenterPacket, AxisPacket,
                                          SymmetryPacket, SnapPacket;
            SubjectPacket subj;
            VectorStack vts;
            evaluateSubject(subj, vts, src);   // g_pipeCtx confirmed above

            ActionCenterPacket acen;
            AxisPacket         axis;
            SymmetryPacket     symm;
            SnapPacket         snapPkt;   // P-C: surface live snap config for tests
            if (auto p = vts.get!ActionCenterPacket()) acen = *p;
            if (auto p = vts.get!AxisPacket())         axis = *p;
            if (auto p = vts.get!SymmetryPacket())     symm = *p;
            if (auto p = vts.get!SnapPacket())         snapPkt = *p;

            void putVec3(Vec3 v) {
                buf.put(format(`[%s,%s,%s]`, jsonNum(v.x, "%f"),
                               jsonNum(v.y, "%f"), jsonNum(v.z, "%f")));
            }
            void putVec3List(Vec3[] list) {
                buf.put("[");
                foreach (i, v; list) {
                    if (i) buf.put(",");
                    putVec3(v);
                }
                buf.put("]");
            }

            // Soft/user-placed pin introspection — read straight off the ACEN
            // stage (the evaluated ActionCenterPacket does not carry the pin
            // flags). Lets the soft-pin undo/relocate tests witness that an
            // explicit relocate clears the display soft pin (userPlaced wins).
            bool acIsUserPlaced = false;
            bool acIsSoftPlaced = false;
            {
                import toolpipe.stage            : TaskCode;
                import toolpipe.stages.actcenter : ActionCenterStage;
                if (auto acs = cast(ActionCenterStage)
                               g_pipeCtx.pipeline.findByTask(TaskCode.Acen)) {
                    acIsUserPlaced = acs.isUserPlaced();
                    acIsSoftPlaced = acs.isSoftPlaced();
                }
            }

            buf.put(`{"actionCenter":{"center":`);
            putVec3(acen.center);
            buf.put(format(`,"isUserPlaced":%s,"isSoftPlaced":%s`,
                           acIsUserPlaced ? "true" : "false",
                           acIsSoftPlaced ? "true" : "false"));
            buf.put(format(`,"isAuto":%s,"type":%d,"clusterCenters":`,
                           acen.isAuto ? "true" : "false",
                           acen.type));
            putVec3List(acen.clusterCenters);
            buf.put(`,"clusterOf":[`);
            foreach (i, c; acen.clusterOf) {
                if (i) buf.put(",");
                buf.put(format(`%d`, c));
            }
            buf.put(`]},"axis":{"right":`);
            putVec3(axis.right);
            buf.put(`,"up":`);
            putVec3(axis.up);
            buf.put(`,"fwd":`);
            putVec3(axis.fwd);
            buf.put(format(`,"axIndex":%d,"type":%d,"isAuto":%s`,
                           axis.axIndex, axis.type,
                           axis.isAuto ? "true" : "false"));
            buf.put(`,"clusterRight":`);  putVec3List(axis.clusterRight);
            buf.put(`,"clusterUp":`);     putVec3List(axis.clusterUp);
            buf.put(`,"clusterFwd":`);    putVec3List(axis.clusterFwd);
            buf.put(`},"symmetry":{"enabled":`);
            buf.put(symm.enabled ? "true" : "false");
            buf.put(format(`,"axisIndex":%d,"useWorkplane":%s,"topology":%s,"baseSide":%d`,
                           symm.axisIndex,
                           symm.useWorkplane ? "true" : "false",
                           symm.topology     ? "true" : "false",
                           symm.baseSide));
            buf.put(`,"planePoint":`);  putVec3(symm.planePoint);
            buf.put(`,"planeNormal":`); putVec3(symm.planeNormal);
            buf.put(`,"pairOf":[`);
            foreach (i, m; symm.pairOf) {
                if (i) buf.put(",");
                buf.put(format(`%d`, m));
            }
            buf.put(`],"onPlane":[`);
            foreach (i, op; symm.onPlane) {
                if (i) buf.put(",");
                buf.put(op ? "true" : "false");
            }
            buf.put(`],"vertSign":[`);
            foreach (i, s; symm.vertSign) {
                if (i) buf.put(",");
                buf.put(format(`%d`, s));
            }
            // P-C: snap config block — lets tests witness the snap config-restore
            // (snap is a cursor-time op with no geometry signal at idle, so its
            // undo/redo restore is observed via this published enabled/types).
            buf.put(format(`]},"snap":{"enabled":%s,"types":%d}`,
                           snapPkt.enabled ? "true" : "false",
                           snapPkt.enabledTypes));

            // P-F: published transform attrs (TX..SZ). Read straight off the active
            // XfrmTransformTool's introspection seam so the run-absolute panel-
            // display contract can be asserted without poking the panel struct.
            // Absent block ⇒ no transform tool active; tests gate on its presence.
            // (Phase 1 adds the frozen run-frame fields to this same block.)
            {
                import tools.transform.xfrm_transform : XfrmTransformTool;
                if (auto xf = cast(XfrmTransformTool) activeTool) {
                    buf.put(`,"transform":{"translate":`); putVec3(xf.publishedTranslate());
                    buf.put(`,"rotate":`);  putVec3(xf.publishedRotate());
                    buf.put(`,"scale":`);   putVec3(xf.publishedScale());
                    // Live Move-bank gizmo center (handler.center) — the
                    // VISUAL gizmo position during a drag (the wrapper draws
                    // the gizmo from this, NOT from actionCenter.center while a
                    // drag is active). Lets tests witness the during-drag gizmo
                    // (element-move: the gizmo must jump onto the picked element
                    // at drag start, not move off its old center).
                    buf.put(`,"gizmoCenter":`); putVec3(xf.moveGizmoCenter());
                    buf.put(format(`,"moveDragAxis":%d`, xf.moveDragAxisPublic()));
                    buf.put(format(`,"constraintLockedAxis":%d`, xf.constraintLockedAxis()));
                    // P-F Phase 1 — the frozen per-run gizmo frame.
                    bool rfValid; Vec3 rfO, rfR, rfU, rfF;
                    xf.publishedRunFrame(rfValid, rfO, rfR, rfU, rfF);
                    buf.put(format(`,"runFrameValid":%s,"runFrameOrigin":`,
                                   rfValid ? "true" : "false"));
                    putVec3(rfO);
                    buf.put(`,"runFrameRight":`); putVec3(rfR);
                    buf.put(`,"runFrameUp":`);    putVec3(rfU);
                    buf.put(`,"runFrameFwd":`);   putVec3(rfF);
                    // flex_border_handles_plan.md Phase 4 step 1 — the LIVE
                    // rendered per-bank gizmo pose (Risk 7: read handler.axis*,
                    // NOT the frozen runFrame*). Lets tests witness the rendered
                    // orientation follow/freeze during a drag (bugs 2/3).
                    Vec3 mrR, mrU, mrF, rrR, rrU, rrF, srR, srU, srF, ringR, ringU, ringF;
                    xf.moveRenderFrame(mrR, mrU, mrF);
                    xf.rotateRenderFrame(rrR, rrU, rrF);
                    xf.scaleRenderFrame(srR, srU, srF);
                    xf.rotateRingFrame(ringR, ringU, ringF);
                    buf.put(`,"moveRenderFrame":{"right":`);   putVec3(mrR);
                    buf.put(`,"up":`); putVec3(mrU); buf.put(`,"fwd":`); putVec3(mrF); buf.put(`}`);
                    buf.put(`,"rotateRenderFrame":{"right":`); putVec3(rrR);
                    buf.put(`,"up":`); putVec3(rrU); buf.put(`,"fwd":`); putVec3(rrF); buf.put(`}`);
                    buf.put(`,"scaleRenderFrame":{"right":`);  putVec3(srR);
                    buf.put(`,"up":`); putVec3(srU); buf.put(`,"fwd":`); putVec3(srF); buf.put(`}`);
                    buf.put(`,"rotateRingFrame":{"right":`);   putVec3(ringR);
                    buf.put(`,"up":`); putVec3(ringU); buf.put(`,"fwd":`); putVec3(ringF); buf.put(`}`);
                    buf.put(`}`);
                }
            }
            // task 0342 Phase 1 (stage-conformance fixtures): per-vertex
            // falloff weights, mesh vertex-index order. Sibling optional
            // block to "transform" above — emitted ONLY when a falloff is
            // active (mirrors the "absent block ⇒ tests gate on its
            // presence" convention). Read-only: `evaluateFalloff` is a pure
            // function (source/falloff.d) and `vts.get!FalloffPacket()`
            // just retrieves the packet `pipeline.evaluate` above already
            // published — no additional cache mutation. Wire contract
            // (locked, see doc/tasks/work/0342-stage-conformance-fixtures.md):
            // key = "falloffWeights", one weight per vertex in mesh
            // vertex-index order, values in [0, 1].
            {
                import toolpipe.packets : FalloffPacket;
                import falloff          : evaluateFalloff;
                import std.math         : isFinite;
                if (auto fpp = vts.get!FalloffPacket()) {
                    if (fpp.enabled) {
                        buf.put(`,"falloffWeights":[`);
                        // Task 0619: `subj.mesh.vertices` are LOCAL, so the
                        // projection a Screen/Lasso weight does must carry the
                        // primary layer's transform. Unlike the batch mesh
                        // commands this block reads whatever packet the live
                        // stage published, which CAN be a pixel type — so it
                        // needs a real aim space, composed once for the whole
                        // vertex loop rather than per vertex.
                        const auto aim = aimSpace(subj.viewport, primaryModelSpace());
                        foreach (i, v; subj.mesh.vertices) {
                            if (i) buf.put(",");
                            float w = evaluateFalloff(*fpp, v, cast(int) i, aim);
                            // Honor the block's documented [0,1] contract for
                            // EVERY falloff type: Screen/Lasso weights project
                            // through the viewport (perspective divide can go
                            // non-finite for a vert at/behind the camera) and
                            // custom cubic-Bezier shapes can overshoot [0,1].
                            // Guard so the emitter never produces nan/inf/out-of-
                            // range (invalid JSON / broken wire contract).
                            // Task 1550 looked at replacing this with the
                            // tree's new `jsonNum` (non-finite -> `null`) and
                            // DECIDED AGAINST IT, so the divergence is a
                            // decision and not an oversight. A falloff weight
                            // has a DEFINED range, [0,1], in which 0 means "no
                            // influence" — and the same guard clamps the
                            // out-of-range overshoot right below. A COORDINATE
                            // has no such range, which is why 0 is a lie
                            // there and `null` is the answer for the
                            // serialisers 1550 did convert. The [0,1] contract
                            // is frozen by task 0342's fixtures; changing it
                            // is not in 1550's scope.
                            if (!isFinite(w)) w = 0.0f;
                            else if (w < 0.0f) w = 0.0f;
                            else if (w > 1.0f) w = 1.0f;
                            // json-num-exempt: clamped to the [0,1] weight contract above, task 1550 decision 4.1
                            buf.put(format(`%f`, w));
                        }
                        buf.put(`]`);
                    }
                }
            }
            // Published hover state (vert/edge/face index, -1 = none). Lets
            // tests witness the during-drag hover FREEZE: while a tool drag is
            // active the hover must stay on the element picked at drag-start,
            // not follow the cursor onto other elements.
            {
                import hover_state : g_hoveredVertex, g_hoveredEdge, g_hoveredFace;
                buf.put(format(`,"hover":{"vertex":%d,"edge":%d,"face":%d}`,
                               g_hoveredVertex, g_hoveredEdge, g_hoveredFace));
            }
            {
                buf.put(`,"ai":`);
                buf.put(latestHandleDebugTraceJson(aiState.enabled));
            }
            buf.put(`}`);
            return buf.data;
        });

        // AI Modeling Copilot Phase 1 (task 0402, doc/ai_copilot_plan.md):
        // GET /api/ai/analyze runs the whole-mesh analysis engine over the
        // live mesh and returns the resulting Finding[] as JSON. Read-only,
        // no side effects, available regardless of aiState.enabled (the
        // toggle gates later UI phases, not this raw analysis read).
        // Marshaled onto the main thread via aiAnalyzeBridge (see
        // http_server.d) so it never races the main thread's own mesh edits.
        // version(WithAI)-only — modeling-noai never sets the provider, so
        // http_server.d's existing `aiAnalyzeProvider is null` guard serves
        // the 404/unavailable response (see http_server.d:1417).
        version (WithAI)
        httpServer.setAiAnalyzeProvider(() {
            import ai.analysis : analyzeMesh, findingsToJson;
            return findingsToJson(analyzeMesh(mesh()));
        });
        else
            optionalSlots ~= "aiAnalyzeProvider";

        // Phase 7.3a: /api/snap query bridge. Lets unit tests probe
        // the snap math directly with explicit cursor world pos +
        // screen pixel + excludeVerts, without driving an interactive
        // Move drag through play-events.
        //
        // Body runs on the MAIN THREAD inside tickAll(), via
        // snapQueryBridge (task 0587) — it is not read-only and never was:
        // it runs pipeline.evaluate() over the live mesh and selection. See
        // the bridge declaration in http_server.d for which clauses of the
        // standing rule applied.
        httpServer.setSnapQueryProvider((string body_) {
            import std.array       : appender;
            import std.format      : format;
            import std.json        : parseJSON, JSONType, JSONValue;
            import std.conv        : to;
            import toolpipe.packets        : SnapPacket, SubjectPacket;
            import snap                    : snapCursor, SnapResult;
            import math                    : Vec3;

            auto buf = appender!string;
            JSONValue req;
            try req = parseJSON(body_);
            catch (Exception e) {
                buf.put(`{"error":"invalid JSON","message":"`
                        ~ e.msg ~ `"}`);
                return buf.data;
            }

            // Required: cursor (Vec3 array), sx, sy.
            if ("cursor" !in req || "sx" !in req || "sy" !in req) {
                buf.put(`{"error":"missing fields cursor/sx/sy"}`);
                return buf.data;
            }
            auto cur = req["cursor"].array;
            if (cur.length != 3) {
                buf.put(`{"error":"cursor must be [x,y,z]"}`);
                return buf.data;
            }
            float toF(JSONValue v) {
                if (v.type == JSONType.integer) return cast(float)v.integer;
                if (v.type == JSONType.uinteger) return cast(float)v.uinteger;
                return cast(float)v.floating;
            }
            int toI(JSONValue v) {
                if (v.type == JSONType.integer) return cast(int)v.integer;
                if (v.type == JSONType.uinteger) return cast(int)v.uinteger;
                return cast(int)v.floating;
            }
            Vec3 cursor = Vec3(toF(cur[0]), toF(cur[1]), toF(cur[2]));
            int  sx     = toI(req["sx"]);
            int  sy     = toI(req["sy"]);
            uint[] exclude;
            if ("excludeVerts" in req) {
                foreach (e; req["excludeVerts"].array)
                    exclude ~= cast(uint)toI(e);
            }

            // Pull a fully-evaluated SnapPacket from the pipeline so
            // SNAP's workplane snapshot + grid step are populated
            // (they depend on the upstream WORK stage having run).
            auto vp = vpm.activeSnapshot();
            SnapPacket cfg;
            {
                import toolpipe.subject : SubjectSource, evaluateSubject;
                import operator        : VectorStack;
                auto src = SubjectSource(&mesh(), editMode,
                                          currentSelType(selTypeOrder), vp);
                SubjectPacket subj;
                VectorStack vts;
                if (evaluateSubject(subj, vts, src))
                    if (auto sp = vts.get!SnapPacket()) cfg = *sp;
            }

            // The just-in-time item-frame install that used to sit here is
            // GONE (task 0587), not moved. It existed for one reason: this
            // closure ran on the HTTP thread, where it could race the draw's
            // own per-frame setItemSnapFrames(). Now that the closure runs on
            // the main thread there is no second writer to race, and the
            // install it duplicated — ui/panels.d, unconditional every draw —
            // has already run. Deleting it also makes this probe answer from
            // the SAME frames an interactive tool sees mid-drag, which the
            // just-in-time rebuild specifically did not.
            // primaryModelSpace() — the SAME resolver the pick providers use
            // (task 0617 Stage 4), so a transformed primary snaps where it's
            // actually drawn.
            SnapResult sr = snapCursor(cursor, sx, sy, vp, mesh, primaryModelSpace(), cfg, exclude);

            buf.put(format(
                `{"snapped":%s,"highlighted":%s,"targetType":%d,`
              ~ `"targetIndex":%d,"targetSource":%d,"constraintType":%d,`
              ~ `"worldPos":[%s,%s,%s],"highlightPos":[%s,%s,%s]}`,
                sr.snapped ? "true" : "false",
                sr.highlighted ? "true" : "false",
                cast(int)sr.targetType,
                sr.targetIndex,
                sr.targetSource,
                cast(int)sr.constraintType,
                jsonNum(sr.worldPos.x, "%f"), jsonNum(sr.worldPos.y, "%f"),
                jsonNum(sr.worldPos.z, "%f"),
                jsonNum(sr.highlightPos.x, "%f"),
                jsonNum(sr.highlightPos.y, "%f"),
                jsonNum(sr.highlightPos.z, "%f")));
            return buf.data;
        });

        // Phase 7.3d: /api/snap/last — read-only snapshot of the
        // most recent snap result any tool published via
        // snap_render.publishLastSnap. Lets headless tests verify the
        // visual-feedback wiring without a screenshot diff.
        httpServer.setSnapLastProvider(() {
            import std.array  : appender;
            import std.format : format;
            import snap_render : g_lastSnap;
            auto buf = appender!string;
            auto sr = g_lastSnap;
            buf.put(format(
                `{"snapped":%s,"highlighted":%s,"targetType":%d,`
              ~ `"targetIndex":%d,"targetSource":%d,"worldPos":[%s,%s,%s],`
              ~ `"highlightPos":[%s,%s,%s]}`,
                sr.snapped ? "true" : "false",
                sr.highlighted ? "true" : "false",
                cast(int)sr.targetType,
                sr.targetIndex,
                sr.targetSource,
                jsonNum(sr.worldPos.x, "%f"), jsonNum(sr.worldPos.y, "%f"),
                jsonNum(sr.worldPos.z, "%f"),
                jsonNum(sr.highlightPos.x, "%f"),
                jsonNum(sr.highlightPos.y, "%f"),
                jsonNum(sr.highlightPos.z, "%f")));
            return buf.data;
        });

        // /api/constrain — POST. Probe the constraint math directly with an
        // explicit `pos` world point. Evaluates the pipeline to pull the live
        // ConstrainPacket, snapshots the background sources, and returns the
        // projected point. Mirrors /api/snap — including the thread contract:
        // this body runs on the MAIN THREAD inside tickAll() via
        // constrainQueryBridge (task 0587). It is not "read-only (HTTP thread
        // safe)", as this note used to claim; pipeline.evaluate() writes the
        // shared stage caches.
        httpServer.setConstrainQueryProvider((string body_) {
            import std.array       : appender;
            import std.format      : format;
            import std.json        : parseJSON, JSONType, JSONValue;
            import std.conv        : to;
            import toolpipe.packets    : ConstrainPacket, SubjectPacket;
            import snap                : backgroundSourcesFull;
            import constraint          : constrainPoint;
            import math                : Vec3;

            auto buf = appender!string;
            JSONValue req;
            try req = parseJSON(body_);
            catch (Exception e) {
                buf.put(`{"error":"invalid JSON","message":"`
                        ~ e.msg ~ `"}`);
                return buf.data;
            }

            if ("pos" !in req) {
                buf.put(`{"error":"missing field pos"}`);
                return buf.data;
            }
            auto pa = req["pos"].array;
            if (pa.length != 3) {
                buf.put(`{"error":"pos must be [x,y,z]"}`);
                return buf.data;
            }
            float toF(JSONValue v) {
                if (v.type == JSONType.integer)  return cast(float)v.integer;
                if (v.type == JSONType.uinteger) return cast(float)v.uinteger;
                return cast(float)v.floating;
            }
            Vec3 pos = Vec3(toF(pa[0]), toF(pa[1]), toF(pa[2]));
            Vec3 delta = Vec3(0, 0, 0);
            if ("delta" in req) {
                auto da = req["delta"].array;
                if (da.length == 3)
                    delta = Vec3(toF(da[0]), toF(da[1]), toF(da[2]));
            }

            auto vp = vpm.activeSnapshot();
            ConstrainPacket cfg;
            {
                import toolpipe.subject : SubjectSource, evaluateSubject;
                import operator : VectorStack;
                auto src = SubjectSource(&mesh(), editMode,
                                          currentSelType(selTypeOrder), vp);
                SubjectPacket subj;
                VectorStack vts;
                if (evaluateSubject(subj, vts, src))
                    if (auto cp = vts.get!ConstrainPacket()) cfg = *cp;
            }

            auto bgSrc = backgroundSourcesFull();
            Vec3 result = constrainPoint(pos, delta, vp, bgSrc, cfg);
            // `projected` reflects whether constrainPoint actually moved
            // the position. Identity cases (disabled / geometry=off /
            // no-sources / vector-screen no-op) return the input unchanged,
            // so a displacement magnitude check is the correct test.
            float dx = result.x - pos.x;
            float dy = result.y - pos.y;
            float dz = result.z - pos.z;
            bool hit = (dx*dx + dy*dy + dz*dz) > 1e-12f;

            buf.put(format(
                `{"projected":%s,"resultPos":[%s,%s,%s]}`,
                hit ? "true" : "false",
                jsonNum(result.x, "%f"), jsonNum(result.y, "%f"),
                jsonNum(result.z, "%f")));
            return buf.data;
        });

        // /api/path — evaluate the PATH stage at a requested t and return
        // value/tangent/length as JSON. Marshaled onto the main thread via
        // tickPath() using a dedicated epoch pair (NOT the pipeEval pair).
        httpServer.setPathQueryProvider((float t) {
            import std.array         : appender;
            import std.format        : format;
            import toolpipe.pipeline : g_pipeCtx;
            import toolpipe.subject  : SubjectSource, evaluateSubject;
            import toolpipe.packets  : SubjectPacket, PathPacket;
            import operator          : VectorStack;
            import path              : pathValue, pathTangent, pathLength;

            // N1 (task 1904): null check stays BEFORE the subject is built,
            // byte-for-byte with the pre-migration order.
            if (g_pipeCtx is null)
                return `{"error":"pipeline not initialised"}`;
            auto src = SubjectSource(&mesh(), editMode,
                                      currentSelType(selTypeOrder),
                                      vpm.activeSnapshot());

            SubjectPacket subj;
            VectorStack vts;
            evaluateSubject(subj, vts, src);   // g_pipeCtx confirmed above

            auto pp = vts.get!PathPacket();
            if (pp is null || !pp.enabled)
                return `{"enabled":false}`;

            import math : Vec3;
            Vec3  val = pathValue  (pp.knots, pp.closed, t);
            Vec3  tan = pathTangent(pp.knots, pp.closed, t);
            float len = pathLength (pp.knots, pp.closed, 0.0f, t);

            // Use %f for all floats to ensure decimal points are always
            // present in the JSON output (prevents integer-type parse on
            // values like 0.0, 1.0, 2.0 where %g would strip the point).
            return format(
                `{"enabled":true,"value":[%s,%s,%s],"tangent":[%s,%s,%s],"length":%s}`,
                jsonNum(val.x, "%f"), jsonNum(val.y, "%f"),
                jsonNum(val.z, "%f"),
                jsonNum(tan.x, "%f"), jsonNum(tan.y, "%f"),
                jsonNum(tan.z, "%f"),
                jsonNum(len, "%f"));
        });

        // Helper: inject _positional args from the argstring pipeline into
        // tool.* commands. Called from inside setCommandHandler after the
        // generic injectParamsInto pass. Extracted to keep the handler tidy.
    }
}

// wireCommandProviders — `/api/command` and `/api/script`, plus the two delegates main()
// reads back afterwards (`uiCommandDelegate`,
// `formsInteractiveDispatch`) and the forms tweak-end hook. This is the
// largest domain by a wide margin and the one D6 is about — ten
// `viewport.*` ids are still intercepted inside the delegate, ahead of
// the registry (task 0761).
private void wireCommandProviders(HttpServer httpServer, ref EditorApp app,
                             ref string[] optionalSlots) {
    with (app) {
        void injectToolCommandPositional(Command cmd, ref JSONValue pj)
        {
            import std.json : JSONType;
            if (auto ts = cast(ToolSetCommand)cmd) {
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            ts.setToolId(pos[0].str);
                        if (pos.length >= 2 && pos[1].type == JSONType.string
                            && pos[1].str == "off")
                            ts.setTurnOff(true);
                    }
                }
                // Collect named args (everything except _positional key).
                import std.json : JSONValue;
                JSONValue named = JSONValue(cast(JSONValue[string]) null);
                if (pj.type == JSONType.object) {
                    foreach (string k, ref v; pj.object) {
                        if (k != "_positional") named[k] = v;
                    }
                }
                ts.setNamedArgs(named);
            } else if (auto ta = cast(ToolAttrCommand)cmd) {
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            ta.setToolId(pos[0].str);
                        if (pos.length >= 2 && pos[1].type == JSONType.string)
                            ta.setAttrName(pos[1].str);
                        if (pos.length >= 3) {
                            // Forms-engine query idiom: a literal "?" in the
                            // value slot flips the command into read-back mode
                            // (resolve + box the live value, mutate nothing)
                            // instead of writing. Any other value writes as
                            // before — backward-compatible.
                            if (pos[2].type == JSONType.string && pos[2].str == "?")
                                ta.setQuery(true);
                            else
                                ta.setAttrValue(pos[2]);
                        }
                    }
                }
            } else if (auto tr = cast(ToolResetCommand)cmd) {
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            tr.setToolId(pos[0].str);
                    }
                }
            } else if (auto tpa = cast(ToolPipeAttrCommand)cmd) {
                // tool.pipe.attr <stageId> <name> <value>
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            tpa.setStageId(pos[0].str);
                        if (pos.length >= 2 && pos[1].type == JSONType.string)
                            tpa.setAttrName(pos[1].str);
                        if (pos.length >= 3 && pos[2].type == JSONType.string
                            && pos[2].str == "?") {
                            // Forms-engine query idiom (stage namespace).
                            tpa.setQuery(true);
                        } else if (pos.length >= 3) {
                            // Value is whatever scalar form was passed —
                            // stringify so the stage's setAttr can parse it.
                            import std.conv : to;
                            string sval;
                            if      (pos[2].type == JSONType.string)   sval = pos[2].str;
                            else if (pos[2].type == JSONType.integer)  sval = pos[2].integer.to!string;
                            else if (pos[2].type == JSONType.uinteger) sval = pos[2].uinteger.to!string;
                            else if (pos[2].type == JSONType.float_)   sval = pos[2].floating.to!string;
                            else if (pos[2].type == JSONType.true_)    sval = "true";
                            else if (pos[2].type == JSONType.false_)   sval = "false";
                            tpa.setAttrValue(sval);
                        }
                    }
                }
            } else if (auto la = cast(LayerAttr)cmd) {
                // layer.attr <index> <attr> <value|?>
                //   positional[0] = layer index (int; -1 → active)
                //   positional[1] = attr name (e.g. "pos.x", "name")
                //   positional[2] = value, or the literal "?" for read-back
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1) {
                            if      (pos[0].type == JSONType.integer)  la.setIndex(cast(int)pos[0].integer);
                            else if (pos[0].type == JSONType.uinteger) la.setIndex(cast(int)pos[0].uinteger);
                            else if (pos[0].type == JSONType.string) {
                                // TASK 1880 — the target slot takes a LIST
                                // ("0,3,4") as well as a single index. The
                                // comma is the discriminator, and it has to be
                                // checked BEFORE `to!int`: that parse throws on
                                // a list and the catch below swallows it, which
                                // would leave `indexArg` at -1 and land a gang
                                // write silently on the active layer alone.
                                import std.algorithm : canFind;
                                if (pos[0].str.canFind(','))
                                    la.setIndexList(pos[0].str);
                                else { try { la.setIndex(pos[0].str.to!int); } catch (Exception) {} }
                            }
                        }
                        if (pos.length >= 2 && pos[1].type == JSONType.string)
                            la.setAttrName(pos[1].str);
                        if (pos.length >= 3) {
                            // Forms-engine query idiom: a literal "?" in the
                            // value slot flips the command into read-back mode.
                            if (pos[2].type == JSONType.string && pos[2].str == "?")
                                la.setQuery(true);
                            else
                                la.setAttrValue(pos[2]);
                        }
                    }
                }
            } else if (auto tpe = cast(ToolPanelEditCommand)cmd) {
                // tool.panelEdit <dx> <dy> <dz> (test-only). Accept int / float
                // / string scalar forms for each component.
                import math : Vec3;
                float comp(JSONValue v) {
                    if      (v.type == JSONType.integer)  return cast(float)v.integer;
                    else if (v.type == JSONType.uinteger) return cast(float)v.uinteger;
                    else if (v.type == JSONType.float_)   return cast(float)v.floating;
                    else if (v.type == JSONType.string)   { try { return v.str.to!float; } catch (Exception) {} }
                    return 0.0f;
                }
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        float dx = pos.length >= 1 ? comp(pos[0]) : 0.0f;
                        float dy = pos.length >= 2 ? comp(pos[1]) : 0.0f;
                        float dz = pos.length >= 3 ? comp(pos[2]) : 0.0f;
                        tpe.setDelta(Vec3(dx, dy, dz));
                    }
                }
            } else if (auto stt = cast(SnapToggleTypeCommand)cmd) {
                // snap.toggleType <typeName>
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            stt.setTypeName(pos[0].str);
                    }
                }
            } else if (auto snm = cast(SnapModeCommand)cmd) {
                // snap.mode <global|component|item>
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            snm.setModeName(pos[0].str);
                    }
                }
            } else if (auto crc = cast(CoordRoundingCommand)cmd) {
                // pref.coordRounding <none|normal|fine|fixed|forcedFixed>
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            crc.setModeName(pos[0].str);
                    }
                }
            } else if (auto tbp = cast(TrackballPrefCommand)cmd) {
                // pref.trackball <global|override|viewport|speed|tabletSpeed> <value>
                //
                // The VALUE is stringified from whatever scalar the argstring
                // parser produced, not read as a string only: `speed 1.0`
                // arrives as a JSON number and `global true` as a JSON bool, so
                // a string-only read silently dropped both and the command then
                // reported "value required" for an argument that was right
                // there. The command owns the parsing of the resulting text.
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            tbp.setSubject(pos[0].str);
                        if (pos.length >= 2)
                            tbp.setValue(scalarArgToString(pos[1]));
                    }
                }
            } else if (auto utp = cast(UiToolPropertiesCommand)cmd) {
                // ui.toolProperties <show|hide> (test-only).
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            utp.setVisible(pos[0].str);
                    }
                }
            } else if (auto ull = cast(UiLayerListCommand)cmd) {
                // ui.layerList <show|hide> (test-only).
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            ull.setVisible(pos[0].str);
                    }
                }
            } else if (auto uil = cast(UiImageListCommand)cmd) {
                // ui.imageList <show|hide> (test-only; task 0616 Ph4).
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            uil.setVisible(pos[0].str);
                    }
                }
            } else if (auto uch = cast(UiChannelsCommand)cmd) {
                // ui.channels <show|hide> (test-only; task 0637).
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            uch.setVisible(pos[0].str);
                    }
                }
            } else if (auto ust = cast(UiStatisticsCommand)cmd) {
                // ui.statistics <show|hide> (test-only; task 1100).
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            ust.setVisible(pos[0].str);
                    }
                }
            } else if (auto use = cast(UiStatisticsExpandCommand)cmd) {
                // ui.statistics.expand <target> [open|close] (test-only).
                // `target` is a section label or a "<Section>/<Category>" key —
                // the same key the row model publishes.
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        string tgt = (pos.length >= 1 && pos[0].type == JSONType.string)
                                   ? pos[0].str : "";
                        string st  = (pos.length >= 2 && pos[1].type == JSONType.string)
                                   ? pos[1].str : "open";
                        use.setArgs(tgt, st);
                    }
                }
            } else if (auto uvp = cast(UiViewportPropsCommand)cmd) {
                // ui.viewportProps <show|hide> (test-only).
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            uvp.setVisible(pos[0].str);
                    }
                }
            } else if (auto uab = cast(UiAboutCommand)cmd) {
                // ui.about <show|hide|toggle> (task 0641). Not test-only —
                // this is the command the File → About… menu item dispatches.
                // A bare `ui.about` keeps the command's own default (show).
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            uab.setVisible(pos[0].str);
                    }
                }
            } else if (auto upie = cast(UiPieCommand)cmd) {
                // ui.pie <menuId|close> (task 1800). The menu id also rides
                // the keyboard binding as a baked argstring
                // (`ui.pie: "Ctrl+Space viewport"` in config/shortcuts.yaml),
                // which funnels through this same positional slot.
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            upie.setMenu(pos[0].str);
                    }
                }
            } else if (auto fad = cast(FalloffAddCommand)cmd) {
                // falloff.add <type>
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            fad.setTypeName(pos[0].str);
                    }
                }
            } else if (auto frm = cast(FalloffRemoveCommand)cmd) {
                // falloff.remove <id>
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            frm.setTargetId(pos[0].str);
                    }
                }
            } else if (auto fas = cast(FalloffAutoSizeCommand)cmd) {
                // falloff.autosize <axis>  (x / y / z)
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            fas.setAxis(pos[0].str);
                    }
                }
            } else if (auto pdc = cast(PathDefineCommand)cmd) {
                // path.define <csv-verts> [closed]
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            pdc.setVertsCsv(pos[0].str);
                        if (pos.length >= 2 && pos[1].type == JSONType.string)
                            pdc.setClosed(pos[1].str == "true");
                    }
                }
            }
            // tool.doApply has no params.

            // workplane.* commands: read named args (cenX/Y/Z, rotX/Y/Z,
            // axis, angle, dist). All argstring keys; we
            // accept JSON scalar types for the value and stringify /
            // floatify as needed.
            import std.math : isNaN;
            bool isNaNFloat(float f) { return isNaN(f); }
            float readFloat(string key) {
                if (auto p = key in pj) {
                    if      (p.type == JSONType.integer)  return cast(float)p.integer;
                    else if (p.type == JSONType.uinteger) return cast(float)p.uinteger;
                    else if (p.type == JSONType.float_)   return cast(float)p.floating;
                    else if (p.type == JSONType.string)   {
                        try { return p.str.to!float; } catch (Exception) {}
                    }
                }
                return float.nan;
            }
            string readString(string key) {
                if (auto p = key in pj)
                    if (p.type == JSONType.string) return p.str;
                return "";
            }
            if (auto we = cast(WorkplaneEditCommand)cmd) {
                float cx = readFloat("cenX");
                float cy = readFloat("cenY");
                float cz = readFloat("cenZ");
                float rx = readFloat("rotX");
                float ry = readFloat("rotY");
                float rz = readFloat("rotZ");
                we.setCenX(cx); we.setCenY(cy); we.setCenZ(cz);
                we.setRotX(rx); we.setRotY(ry); we.setRotZ(rz);
            } else if (auto wr = cast(WorkplaneRotateCommand)cmd) {
                wr.setAxis(readString("axis"));
                float a = readFloat("angle");
                if (!isNaNFloat(a)) wr.setAngle(a);
            } else if (auto wo = cast(WorkplaneOffsetCommand)cmd) {
                wo.setAxis(readString("axis"));
                float d = readFloat("dist");
                if (!isNaNFloat(d)) wo.setDist(d);
            }
        }

        // Helper: inject _positional args for select.* commands.
        // Called from setCommandHandler after injectToolCommandPositional.
        void injectSelectCommandPositional(Command cmd, ref JSONValue pj)
        {
            import std.json : JSONType;
            if (auto stf = cast(SelectTypeFromCommand)cmd) {
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            stf.setTargetType(pos[0].str);
                    }
                }
            } else if (auto sd = cast(SelectDropCommand)cmd) {
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            sd.setTargetType(pos[0].str);
                    }
                }
            } else if (auto se = cast(SelectElementCommand)cmd) {
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            se.setTargetType(pos[0].str);
                        if (pos.length >= 2 && pos[1].type == JSONType.string)
                            se.setAction(pos[1].str);
                        int[] idx;
                        foreach (pi; 2 .. pos.length) {
                            if (pos[pi].type == JSONType.integer)
                                idx ~= cast(int)pos[pi].integer;
                            else if (pos[pi].type == JSONType.uinteger)
                                idx ~= cast(int)pos[pi].uinteger;
                        }
                        se.setIndices(idx);
                    }
                }
            } else if (auto sc = cast(SelectConvertCommand)cmd) {
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            sc.setTargetType(pos[0].str);
                    }
                }
            }
        }

        // Retired HTTP wrapper arguments. These commands predate Param-backed
        // JSON injection, so their former route validation/configuration now
        // lives at the one generic command-dispatch point.
        void injectRetiredWrapperArgs(Command cmd, ref JSONValue pj) {
            import math : Vec3;

            if (auto select = cast(MeshSelect)cmd) {
                if ("mode" !in pj || pj["mode"].type != JSONType.string)
                    throw new Exception("missing 'mode' string field");
                if ("indices" !in pj || pj["indices"].type != JSONType.array)
                    throw new Exception("missing 'indices' array field");
                int[] indices;
                foreach (n; pj["indices"].array) {
                    if (n.type != JSONType.integer && n.type != JSONType.uinteger)
                        throw new Exception("indices must be integers");
                    indices ~= cast(int)n.integer;
                }
                select.setMode(pj["mode"].str);
                select.setIndices(indices);
            } else if (auto transform = cast(MeshTransform)cmd) {
                Vec3 vec3From(string field, Vec3 def) {
                    if (field !in pj) return def;
                    auto a = pj[field].array;
                    if (a.length != 3)
                        throw new Exception("'" ~ field ~ "' must be [x,y,z]");
                    Vec3 r;
                    foreach (i, n; a) {
                        double v;
                        switch (n.type) {
                            case JSONType.integer:  v = cast(double)n.integer;  break;
                            case JSONType.uinteger: v = cast(double)n.uinteger; break;
                            case JSONType.float_:   v = n.floating;             break;
                            default: throw new Exception("'" ~ field ~ "' components must be numbers");
                        }
                        if (i == 0) r.x = cast(float)v;
                        if (i == 1) r.y = cast(float)v;
                        if (i == 2) r.z = cast(float)v;
                    }
                    return r;
                }
                float floatFrom(string field, float def) {
                    if (field !in pj) return def;
                    auto n = pj[field];
                    switch (n.type) {
                        case JSONType.integer:  return cast(float)n.integer;
                        case JSONType.uinteger: return cast(float)n.uinteger;
                        case JSONType.float_:   return cast(float)n.floating;
                        default: throw new Exception("'" ~ field ~ "' must be a number");
                    }
                }

                if ("kind" !in pj || pj["kind"].type != JSONType.string)
                    throw new Exception("missing 'kind' string field");
                transform.setKind(pj["kind"].str);
                transform.setDelta (vec3From("delta",  Vec3(0, 0, 0)));
                transform.setAxis  (vec3From("axis",   Vec3(0, 1, 0)));
                transform.setAngle (floatFrom("angle", 0.0f));
                transform.setFactor(vec3From("factor", Vec3(1, 1, 1)));
                transform.setPivot (vec3From("pivot",  Vec3(0, 0, 0)));
            } else if (auto loadMesh = cast(MeshLoadRaw)cmd) {
                if ("vertices" !in pj || pj["vertices"].type != JSONType.array)
                    throw new Exception("missing 'vertices' array field");
                if ("faces" !in pj || pj["faces"].type != JSONType.array)
                    throw new Exception("missing 'faces' array field");

                double numFrom(JSONValue n) {
                    switch (n.type) {
                        case JSONType.integer:  return cast(double)n.integer;
                        case JSONType.uinteger: return cast(double)n.uinteger;
                        case JSONType.float_:   return n.floating;
                        default: throw new Exception("vertex components must be numbers");
                    }
                }

                auto vArr = pj["vertices"].array;
                Vec3[] verts = new Vec3[](vArr.length);
                foreach (i, vj; vArr) {
                    if (vj.type != JSONType.array || vj.array.length != 3)
                        throw new Exception("each vertex must be [x,y,z]");
                    verts[i] = Vec3(cast(float)numFrom(vj.array[0]),
                                    cast(float)numFrom(vj.array[1]),
                                    cast(float)numFrom(vj.array[2]));
                }

                auto fArr = pj["faces"].array;
                uint[][] faces = new uint[][](fArr.length);
                foreach (i, fj; fArr) {
                    if (fj.type != JSONType.array)
                        throw new Exception("each face must be an array of vertex indices");
                    auto idxArr = fj.array;
                    uint[] face = new uint[](idxArr.length);
                    foreach (k, ij; idxArr) {
                        if (ij.type != JSONType.integer && ij.type != JSONType.uinteger)
                            throw new Exception("face indices must be integers");
                        long v = ij.integer;
                        if (v < 0)
                            throw new Exception("face index must be non-negative");
                        face[k] = cast(uint)v;
                    }
                    faces[i] = face;
                }
                loadMesh.setData(verts, faces);
            } else if (auto reset = cast(SceneReset)cmd) {
                bool empty;
                if (auto p = "empty" in pj) {
                    if (p.type != JSONType.true_ && p.type != JSONType.false_)
                        throw new Exception("'empty' must be a boolean");
                    empty = p.type == JSONType.true_;
                }
                if (empty) {
                    reset.setEmpty(true);
                } else {
                    string primitiveType;
                    if (auto p = "type" in pj) {
                        if (p.type != JSONType.string)
                            throw new Exception("'type' must be a string");
                        primitiveType = p.str;
                    }
                    int primitiveParam = -1;
                    foreach (key; ["n", "levels"]) {
                        if (auto p = key in pj) {
                            if (p.type != JSONType.integer && p.type != JSONType.uinteger)
                                throw new Exception("'" ~ key ~ "' must be an integer");
                            primitiveParam = cast(int)p.integer;
                            break;
                        }
                    }
                    reset.setPrimitive(primitiveType);
                    reset.setPrimitiveParam(primitiveParam);
                }
            }
        }

        // ------------------------------------------------------------------
        // ONE dispatcher BODY, TWO refusal policies (task 1520).
        //
        // Before this the body below was an anonymous lambda assigned to a
        // single `commandHandlerDelegate` field that BOTH `/api/command` and
        // the 28 `ui/panels.d` call sites shared. Its refusal policy was the
        // script one — `applyOrRefire(..., throwMsg)` — so a legitimately
        // refusing command dispatched from a panel button threw out of the
        // ImGui draw, through `_Dmain`, and killed the editor. Measured, twice,
        // on a build with no code change (task card §Лог): cancelling the
        // Images panel's "Load…" and refusing `layer.setVisible` from the
        // Layers panel eye BOTH died with the same four-frame trace.
        //
        // The fix does not average the two policies (a `try/catch` round the
        // draw would have swallowed the HTTP errors the throw exists FOR);
        // it names the caller. `origin` is read at exactly one place —
        // `refused()` below.
        // ------------------------------------------------------------------

        /// THE refusal policy, and the only place `origin` is consulted.
        ///
        /// The UI branch reuses `app.d`'s `raiseCommandNotice` — the SAME body
        /// the menu/keyboard path (`runCommand`) has always used, which is WHY
        /// File → Open of a cancelled dialog never crashed while the Images
        /// panel's "Load…" did.
        void refused(Command cmd, string id, CommandOrigin origin) {
            if (origin == CommandOrigin.script)
                throw new Exception("command '" ~ id ~ "' did not apply"
                    ~ (cmd.refusalReason().length ? ": " ~ cmd.refusalReason() : ""));
            raiseCommandNotice(cmd);
        }

        // The dispatcher body itself. Named (not a lambda) so both adapters
        // below can name it; the body is otherwise unchanged from the lambda
        // it replaces except at the four policy points marked `refused(...)`.
        void dispatchCommandLine(string id, string paramsJson, CommandOrigin origin) {
            import std.json : parseJSON, JSONType;
            import commands.file.load : FileLoad;
            import commands.file.save : FileSave;
            import params : injectParamsInto;

            // The ten `viewport.*` commands used to be intercepted here,
            // ahead of `reg.commandFactories` below. Moved into the registry
            // (task 0761) — see `commands/viewport/{view_preset,layout_preset,
            // independence,display,grid_steps,master}.d` for the command
            // classes and `injectViewportCommandPositional` below for the
            // argument-parsing law each one preserves verbatim.

            auto factory = id in reg.commandFactories;
            if (factory is null)
                throw new Exception("unknown command id '" ~ id ~ "'");
            auto cmd = (*factory)();
            immutable bool resetForAutomation =
                command.g_testMode && cast(SceneReset)cmd !is null;

            if (resetForAutomation) {
                import ui.discard_guard : resetUiPolicyRecord;
                resetUiPolicyRecord();
                if (dropPendingGuard !is null) dropPendingGuard();
            }

            // viewport.* commands (task 0761): argument extraction ahead of
            // apply(), same position in the dispatch flow the old
            // interception ran at. Operates on the RAW `paramsJson` string
            // (not the `pj` object parsed below) because one of the three
            // argument laws — `oneStringArg`'s — accepts a bare JSON string
            // body, a shape `injectToolCommandPositional`/
            // `injectSelectCommandPositional` below never see (they only run
            // inside the `pj.type == JSONType.object` branch).
            injectViewportCommandPositional(cmd, paramsJson);

            // FormsPanel interactive write: mark a `tool.attr` interactive so
            // the reEvaluate() seam opens the tool's live session on the first
            // edit. The latch is set ONLY by formsInteractiveDispatch around one
            // dispatch — the raw HTTP path never sets it, so wire `tool.attr`
            // stays inert (faithful). Programmatic-only, never an argstring arg.
            if (formsInteractiveLatch)
                if (auto ta = cast(ToolAttrCommand)cmd)
                    ta.setInteractive(true);

            if (paramsJson.length > 0) {
                auto pj = parseJSON(paramsJson);
                if (pj.type == JSONType.object) {
                    // Path special-case for file.load/file.save (OS-native
                    // dialog quirk — schema-based migration deferred to phase 4).
                    if ("path" in pj && pj["path"].type == JSONType.string) {
                        string path = pj["path"].str;
                        if (auto fl = cast(FileLoad)cmd) fl.setPath(path);
                        else if (auto fs = cast(FileSave)cmd) fs.setPath(path);
                    }

                    // Schema-driven injection — works for any command with a
                    // non-empty params() schema (currently vert.merge,
                    // vert.join, mesh.move_vertex).
                    if (cmd.params().length > 0)
                        injectParamsInto(cmd.params(), pj);

                    // tool.* commands: inject _positional args and named args.
                    injectToolCommandPositional(cmd, pj);

                    // select.* commands: inject positional args.
                    injectSelectCommandPositional(cmd, pj);

                    // Commands formerly reached through dedicated HTTP
                    // wrappers: preserve their payload shapes while applying
                    // them through this single refusal-aware dispatcher.
                    injectRetiredWrapperArgs(cmd, pj);

                    // Falloff side-channel — mesh.smooth / mesh.jitter /
                    // mesh.quantize accept a `falloff` JSON object that
                    // doesn't fit Param[]'s typed-pointer schema (it's
                    // a multi-field FalloffPacket). Push it into the
                    // command via the IFalloffAware interface — single
                    // cast replaces the per-Command cast-chain that
                    // existed before Phase 4. Reference-diff cases use
                    // this to drive cross-engine linear-falloff parity
                    // for the convolve tools.
                    if (auto fj = "falloff" in pj.object) {
                        if (fj.type == JSONType.object) {
                            import falloff : parseFalloffJson, IFalloffAware;
                            if (auto fa = cast(IFalloffAware)cmd) {
                                auto fp = parseFalloffJson(*fj);
                                fa.setFalloff(fp);
                            }
                        }
                    }
                }
            }

            // Phase C: while a refire block is open, fire() reverts the
            // previous live command before applying the new one — net stack
            // effect = 1 entry per drag/edit cycle. Outside refire, fire()
            // falls through to plain apply()+record(), preserving Phase A
            // semantics.
            {
                auto zCmd = g_perf.scope_(Cat.commandApply);
                // Forms-engine query (`?` read-back) short-circuit. A query
                // command resolves + boxes the live value WITHOUT mutating;
                // it records no history and bypasses the refire/coalesce path
                // entirely (a pure read). The boxed JSON is stashed for the
                // HTTP thread via setCmdResult(); the in-process renderer reads
                // queryResult() directly. A non-query (write) tool.attr /
                // tool.pipe.attr falls through to the normal paths below.
                if (auto taq = cast(ToolAttrCommand)cmd) {
                    if (taq.isQuery()) {
                        if (!taq.apply()) { refused(cmd, id, origin); return; }
                        if (httpServer !is null)
                            httpServer.setCmdResult(taq.queryResultJsonOrEmpty());
                        return;
                    }
                }
                if (auto tpaq = cast(ToolPipeAttrCommand)cmd) {
                    if (tpaq.isQuery()) {
                        if (!tpaq.apply()) { refused(cmd, id, origin); return; }
                        if (httpServer !is null)
                            httpServer.setCmdResult(tpaq.queryResultJsonOrEmpty());
                        return;
                    }
                }
                // layer.attr query (`?`): same pure-read short-circuit as the
                // tool/stage attr queries — resolve + box the live layer Param
                // value, record no history, return the boxed JSON.
                if (auto laq = cast(LayerAttr)cmd) {
                    if (laq.isQuery()) {
                        if (!laq.apply()) { refused(cmd, id, origin); return; }
                        if (httpServer !is null)
                            httpServer.setCmdResult(laq.queryResultJsonOrEmpty());
                        return;
                    }
                }
                // Refire (undo/redo migration P4) — the dispatch decision +
                // driver bracket live in EditSession.tryRefireDispatch (task
                // 0428): a tool.attr inside an open refire window on an
                // opted-in tool fires the tool's rebuilt command instead of
                // the plain path below. Non-tool.attr commands inside a
                // refire window (and non-opted-in tools) keep the plain
                // fire(cmd) path.
                if (!session.tryRefireDispatch(cmd, id)) {
                    // Command-dispatch path: route through recordCoalescing()
                    // so consecutive COMPATIBLE delta edits (same targets, same
                    // edit label) collapse into a single undo entry.
                    // compareOp() defaults to Different for every command
                    // except the opted-in delta edit, so every other command
                    // appends exactly as record() would. Interactive tool
                    // commits stay on record() (one entry per gesture).
                    //
                    // THE POLICY SPLIT (task 1520). A UI-origin line goes
                    // through `runUiCommand` — the unsaved-work guard's single
                    // point (task 1521) — and a refusal becomes a notice.
                    // A script-origin line applies directly and a refusal
                    // throws, which is the contract `/api/command` clients
                    // read.
                    if (origin == CommandOrigin.ui) {
                        // `runUiCommand` OWNS both the guard and the notice —
                        // and it must, because "refused" and "deferred by the
                        // unsaved-work prompt" are different answers and only
                        // the first one is a notice.
                        runUiCommand(cmd, RecordMode.Coalescing, id);
                    } else if (!applyOrRefire(cmd, RecordMode.Coalescing)) {
                        refused(cmd, id, origin);
                    }
                }

                if (resetForAutomation) {
                    pipeGizmoHost.cancelDrag();
                    import ai.debug_trace : clearLatestAiDebugTraces;
                    clearLatestAiDebugTraces();
                    aiState.setEnabled(false);
                    import eventlog : parkOverrideMouse;
                    parkOverrideMouse();
                    import pie_state : closePie;
                    closePie();
                    aiExplore.discardPending();
                    if (stepTrace !is null) stepTrace.reset();
                }

                // P-E: a DISCRETE pipe-config tweak opens a NEW tweak
                // generation, so the re-grade it triggers (recorded later, on the
                // next XfrmTransformTool.update() tick) APPENDS as its OWN
                // in-session undo step rather than REPLACING the prior re-grade
                // (reference fact G2: each separate setAttr command is one step).
                // Gate: a tool.pipe.attr WRITE (not a `?` query) that is NOT part
                // of a held interactive interaction. The forms-panel slider scrub
                // raises formsInteractiveLatch and fires MANY tool.pipe.attr
                // writes as the mouse drags one slider — those must SHARE one
                // generation (REPLACE into one step), so the latch suppresses the
                // per-setAttr bump; the slider's end-of-scrub deactivate bumps the
                // generation instead (forms_render.d). A raw /api/command or
                // /api/script tool.pipe.attr (latch down) is a discrete tweak and
                // bumps here. A falloff-handle drag bypasses this dispatcher
                // entirely (it setAttrs the stage directly) and bumps on
                // mouse-up (xfrm_transform.d). bumpTweakGeneration() is a no-op on
                // history state otherwise — it only advances the token a future
                // re-grade reads.
                if (id == "tool.pipe.attr" && !formsInteractiveLatch) {
                    bool isQuery = false;
                    if (auto tpa = cast(ToolPipeAttrCommand)cmd) isQuery = tpa.isQuery();
                    if (!isQuery) history.bumpTweakGeneration();
                }
            }
        }

        // ---- The two adapters (task 1520) --------------------------------
        //
        // The UI adapter is the EditorApp field: every panel button, the
        // status-line script actions, the forms panel and the History panel's
        // Re-run reach the dispatcher through it, and a refusal on that route
        // becomes a notice.
        uiCommandDelegate = (string id, string paramsJson) {
            dispatchCommandLine(id, paramsJson, CommandOrigin.ui);
        };
        // The THROWING adapter is deliberately a LOCAL, not a field on
        // `EditorApp`: nothing in `source/ui/**` can reach it even by
        // accident, because there is no bound reference to reach. (It is
        // reachable by NAME — `applyOrRefire` is still a public field and
        // `RecordMode` is module-level, so "it cannot be compiled from a
        // panel" would be false; Phase 1b narrows that surface separately and
        // `tests/test_ui_no_throwing_dispatch.d` gates it.)
        void delegate(string, string) httpCommandDelegate =
            (string id, string paramsJson) {
                dispatchCommandLine(id, paramsJson, CommandOrigin.script);
            };
        httpServer.setCommandHandler(httpCommandDelegate);
        // `POST /api/command?origin=ui` (--test only) drives the UI policy from
        // a test. It MUST go through the `app.uiCommandDelegate` FIELD, not
        // through a second closure over the same body: the whole proxy the
        // tests observe ("the UI adapter did not throw") is only worth
        // anything if the route exercises the binding the panels use. Nulling
        // the field after this point is the mutation that proves it, and it
        // reddens because of the explicit null check here.
        httpServer.setUiCommandHandler((string id, string paramsJson) {
            if (uiCommandDelegate is null)
                throw new Exception("ui command delegate is not wired");
            uiCommandDelegate(id, paramsJson);
        });

        // Test-automation seam: let /api/script?interactive=true raise the same
        // formsInteractiveLatch the forms-panel scrub uses, so a sequence of
        // tool.pipe.attr writes shares ONE tweak generation (REPLACE-coalesce
        // into one in-session re-grade step) — the headless analogue of a held
        // falloff-handle drag. Runs on the main thread inside tickCommand, the
        // same thread that reads the latch, so no synchronisation is needed.
        httpServer.setInteractiveLatchHook((bool raised) {
            formsInteractiveLatch = raised;
        });

        // FormsPanel value writes go through here: raise the latch, dispatch the
        // ordinary `tool.attr` via the same handler, lower the latch. The handler
        // marks the built ToolAttrCommand interactive while the latch is up, so
        // the first forms edit opens the tool's live session (reEvaluate seam).
        // UI ORIGIN (task 1520): every caller is a draw — `ui/panels.d`'s
        // forms rows and the Tool Properties panel. HTTP's
        // `/api/script?interactive=true` does NOT come through here (it raises
        // the latch via setInteractiveLatchHook and dispatches through the
        // command bridge), so it keeps the script policy.
        formsInteractiveDispatch = (string id, string paramsJson) {
            formsInteractiveLatch = true;
            scope(exit) formsInteractiveLatch = false;
            dispatchCommandLine(id, paramsJson, CommandOrigin.ui);
        };

        // P-E: wire the forms panel's tweak-boundary hook to the history's
        // generation counter. A panel slider/drag deactivate (end of a continuous
        // scrub) or a combo selection (a single discrete pick) bumps the
        // generation so the NEXT pipe tweak APPENDS as its own in-session undo
        // step rather than REPLACING the just-finished one (reference fact G2).
        // The per-frame setAttrs DURING a scrub do NOT bump (the interactive
        // latch suppresses the app.d per-command bump), so the scrub coalesces
        // into ONE step; this end-of-scrub hook closes that window.
        formsPanel.setTweakEndHook(() { history.bumpTweakGeneration(); });

        // Phase 5.6: assign the outer-scope replayUndoEntry delegate so the
        // History panel replay button can call it from the main-loop render.
        replayUndoEntry = (size_t index) {
            import argstring : parseArgstring;
            string line = history.undoEntryCommandLine(index);
            if (line.length == 0) return;
            auto parsed = parseArgstring(line);
            if (parsed.isEmpty) return;
            // THE `try/catch` STAYS (task 1520, opponent blocker B3). Phase 1
            // removes only the REFUSAL throw; three classes still fly out of
            // the dispatcher body and `origin` does not touch any of them —
            // an unknown command id, a `parseJSON` failure, and the commands
            // that throw ON PURPOSE (`commands/mesh/morph.d`,
            // `commands/mesh/edge_crease.d`). Their stated premise, "the only
            // caller is /api/command", is FALSE: this replay runs an arbitrary
            // line from the history, and its callers are the History panel's
            // Re-run button and its context menu — both INSIDE the draw.
            // Deleting this catch would put back exactly the crash 1520
            // removes.
            //
            // What DID change: the message is no longer swallowed. The panel
            // has no error surface of its own, so it goes to the same notice
            // every other UI-origin failure uses.
            try {
                dispatchCommandLine(parsed.commandId, parsed.params.toString(),
                                    CommandOrigin.ui);
            } catch (Exception e) {
                raiseNotice(e.msg);
            }
        };
    }
}

// wireHistoryProviders — `/api/history*`, `/api/trace*`,
// `/api/refire` — the undo service and its observables.
private void wireHistoryProviders(HttpServer httpServer, ref EditorApp app,
                             ref string[] optionalSlots) {
    with (app) {
        // History panel Phase 2 — multi-step jump via /api/history/jump.
        httpServer.setJumpHandler((size_t target) {
            return history.jumpToVisible(target);
        });
        httpServer.setHistoryProvider(() {
            // JSON: { "undo": [{"label":..,"args":..,"command":..,"ui":bool,
            //                   "inSession":bool,"refire":bool,"runId":N,
            //                   "opInverse":bool}, ...],
            //         "redo":[..] }
            // "ui" is true for UI-undo state (selection / edit mode). False
            // rows may be Model or surfaced ToolLifecycle steps; `flags`
            // carries the full classification.
            // "inSession" is true when the entry is one step of an open tool RUN
            // (a per-gesture in-session entry, tagged HistoryFlags.InSession);
            // "refire" is true when an in-session entry is a falloff RE-GRADE of
            // the run's last gesture (HistoryFlags.Refire — always implies
            // inSession); "runId" groups the gestures of one run. All surface the
            // record+consolidate structure for a future command-history panel.
            import std.json : JSONValue;
            import command_history : HistoryFlags;
            JSONValue[] undoArr;
            foreach (ref e; history.undoEntriesVisible()) {
                auto obj = JSONValue.emptyObject;
                obj["label"]     = JSONValue(e.label);
                obj["args"]      = JSONValue(e.args);
                obj["command"]   = JSONValue(e.commandName);
                obj["flags"]     = JSONValue(cast(long)e.flags);
                obj["ui"]        = JSONValue((e.flags & HistoryFlags.UiUndo) != 0);
                obj["inSession"] = JSONValue((e.flags & HistoryFlags.InSession) != 0);
                obj["refire"]    = JSONValue((e.flags & HistoryFlags.Refire) != 0);
                obj["runId"]     = JSONValue(cast(long)e.runId);
                // P-E: pipe-tweak generation token (load-bearing on Refire
                // entries — see HistoryEntry.tweakGeneration). Surfaced so a test
                // can assert two discrete tweaks carry DIFFERENT generations.
                obj["tweakGen"]  = JSONValue(cast(long)e.tweakGeneration);
                // "opInverse" (task 1903 §6.4) — does this entry undo itself by
                // an INVERSE OPERATION (an op-log delta) rather than by
                // restoring a whole-mesh snapshot? `Command.isOperationInverse`
                // had zero readers anywhere in source/ or tests/ until this
                // line; the migration needs an observable that is not the
                // geometry, and this is the cheapest one.
                //
                // IT IS A SELF-REPORT, AND THAT BOUNDS WHAT IT CAN WITNESS. The
                // bit is `useDelta_`, which the command sets ABOUT ITSELF: a
                // class that sets it true while its delta is empty or
                // degenerate reports true and is still broken. So this row is a
                // cheap TELL, run alongside the two things that can actually
                // see the failure — the counted MeshSnapshot-holder census
                // (which reddens on a revert with no cooperation from the class
                // under test) and the per-family plane-dump parity fixture
                // (which is what catches a degenerate delta). Never let a green
                // `opInverse` stand in for either.
                obj["opInverse"] = JSONValue(e.cmd !is null && e.cmd.isOperationInverse());
                undoArr ~= obj;
            }
            JSONValue[] redoArr;
            foreach (ref e; history.redoEntriesVisible()) {
                auto obj = JSONValue.emptyObject;
                obj["label"]     = JSONValue(e.label);
                obj["args"]      = JSONValue(e.args);
                obj["command"]   = JSONValue(e.commandName);
                obj["flags"]     = JSONValue(cast(long)e.flags);
                obj["ui"]        = JSONValue((e.flags & HistoryFlags.UiUndo) != 0);
                obj["inSession"] = JSONValue((e.flags & HistoryFlags.InSession) != 0);
                obj["refire"]    = JSONValue((e.flags & HistoryFlags.Refire) != 0);
                obj["runId"]     = JSONValue(cast(long)e.runId);
                obj["tweakGen"]  = JSONValue(cast(long)e.tweakGeneration);
                // See the undo arm above for what this bit is and is not.
                obj["opInverse"] = JSONValue(e.cmd !is null && e.cmd.isOperationInverse());
                redoArr ~= obj;
            }
            JSONValue payload = JSONValue.emptyObject;
            payload["undo"] = JSONValue(undoArr);
            payload["redo"] = JSONValue(redoArr);
            return payload.toString();
        });

        // GET /api/trace / POST /api/trace/reset — non-destructive per-step
        // capture (task: step-trace). stepTrace is appended to by
        // captureStepTrace() (installed on history.onRecord above); the
        // provider here is just a snapshot-at-request-time read guarded by
        // StepTrace's own Mutex. This provider-wiring block runs even when
        // startHttpServer is false (httpServer is always constructed — see
        // the comment at its declaration — only .start() is gated), so
        // stepTrace can still be null here; null-guard so a stray call
        // returns an empty trace instead of a null-dereference crash.
        httpServer.setTraceProvider(() =>
            stepTrace !is null ? stepTrace.snapshotJson() : "[]");
        httpServer.setTraceResetHandler(() {
            if (stepTrace !is null) stepTrace.arm();
        });

        // Read-only undo-service status for automation: {state, lockout,
        // canUndo, canRedo, modelDepth, uiDepth, canUndoModel, canUndoUi}.
        // modelDepth/uiDepth — count of Model vs UI-class entries on the undo
        // stack; canUndoModel/canUndoUi — the class of the next strict-LIFO
        // undo step. A lifecycle tail makes both class predicates false.
        // All are pure reads, safe on the HTTP server thread.
        httpServer.setUndoStatusProvider(() {
            import std.json : JSONValue;
            import command_history : UndoState;
            string stateStr;
            final switch (history.state()) {
                case UndoState.Active:  stateStr = "active";  break;
                case UndoState.Suspend: stateStr = "suspend"; break;
                case UndoState.Invalid: stateStr = "invalid"; break;
            }
            size_t modelDepth, uiDepth;
            history.undoDepthCounts(modelDepth, uiDepth);
            JSONValue payload = JSONValue.emptyObject;
            payload["state"]        = JSONValue(stateStr);
            payload["lockout"]      = JSONValue(history.lockedOut());
            payload["canUndo"]      = JSONValue(history.canUndo());
            payload["canRedo"]      = JSONValue(history.canRedo());
            payload["modelDepth"]   = JSONValue(cast(long)modelDepth);
            payload["uiDepth"]      = JSONValue(cast(long)uiDepth);
            payload["canUndoModel"]       = JSONValue(history.canUndoModel());
            payload["canUndoUi"]          = JSONValue(history.canUndoUi());
            payload["toolLifecycleCount"] = JSONValue(cast(long)history.toolLifecycleCount());
            payload["canUndoLifecycle"]   = JSONValue(history.canUndoLifecycle());
            return payload.toString();
        });

        // Phase 5.5: re-execute the argstring of any undo stack entry against
        // the current mesh state.  The original entry is not modified; a new
        // history entry is created by the normal apply()+record() path.
        httpServer.setReplayProvider((size_t i) {
            return history.undoEntryCommandLine(i);
        });

        // Phase C: /api/refire opens/closes a refire block on the history.
        // The bracket is driven by EditSession on the main thread; this
        // endpoint exists for HTTP-driven tests that want to verify the
        // refire-coalescing behavior without going through SDL. refireEnded()
        // carries the P4 opted-in-tool commit notification.
        httpServer.setRefireHandler((string action) {
            if (action == "begin")     session.refireBegin();
            else if (action == "end")  session.refireEnded();
            else throw new Exception("invalid refire action '" ~ action ~ "'");
        });

        // /api/history/block opens/closes a command block on the history.
        // N undoable commands recorded between begin and end collapse into a
        // single CompositeCommand undo entry. Exists for HTTP-driven tests and
        // any future macro/replay consumer that wants to group sub-commands.
        httpServer.setBlockHandler((string action, string label) {
            if (action == "begin")     history.blockBegin(label);
            else if (action == "end")  history.blockEnd();
            else throw new Exception("invalid block action '" ~ action ~ "'");
        });

    }
}

// wireMutationHandlers — POST routes that retain dedicated test scaffolding.
private void wireMutationHandlers(HttpServer httpServer, ref EditorApp app,
                             ref string[] optionalSlots) {
    with (app) {
        // Test-only layer injection (POST /api/test/layer) — task 0615.
        // The special construction shape (non-mesh kind, optional insertion,
        // no selection/focus change) is configured on the registered
        // `layer.add` command, then applied and recorded normally. The route
        // remains scaffolding, but no longer writes the document outside the
        // command/undo model.
        //
        // Blocker fix (review round 2): the ROUTE is gated on `testMode` in
        // http_server.d (mirroring /api/changes / /api/play-events), which
        // is the load-bearing fix — but the handler itself is also only
        // INSTALLED under `--test` here, belt-and-suspenders, so a release
        // build never even wires a delegate capable of splicing an
        // undo-invisible layer into the live document.
        if (!command.g_testMode) optionalSlots ~= "injectLayerHandler";
        if (command.g_testMode) {
        httpServer.setInjectLayerHandler((JSONValue params) {
            import document : ItemKind, kindFromToken;
            import std.conv : to;

            if ("kind" !in params || params["kind"].type != JSONType.string)
                throw new Exception("missing 'kind' string field");
            ItemKind k;
            if (!kindFromToken(params["kind"].str, k))
                throw new Exception("unknown layer kind '" ~ params["kind"].str ~ "'");

            string name = ("name" in params && params["name"].type == JSONType.string)
                ? params["name"].str
                : ("Layer " ~ to!string(document.layers.length + 1));

            // NIT (task 0615 review round 2): a malformed 'index' used to be
            // silently downgraded to an append (out-of-range value, wrong
            // JSON type, negative — all fell through unchanged), while
            // 'kind' errors properly above. Reject the same way 'kind' does:
            // a test that typo'd its index gets a loud failure, not a
            // layer landing somewhere it didn't ask for.
            size_t insertAt = document.layers.length;
            if (auto ip = "index" in params) {
                if (ip.type != JSONType.integer && ip.type != JSONType.uinteger)
                    throw new Exception("'index' must be an integer");
                long raw = ip.type == JSONType.integer
                    ? ip.integer : cast(long)ip.uinteger;
                if (raw < 0 || cast(size_t)raw > document.layers.length)
                    throw new Exception("'index' out of range");
                insertAt = cast(size_t)raw;
            }
            auto factory = "layer.add" in reg.commandFactories;
            if (factory is null)
                throw new Exception("unknown command id 'layer.add'");
            auto cmd = cast(LayerAdd)(*factory)();
            if (cmd is null)
                throw new Exception("command 'layer.add' has the wrong type");
            cmd.configureInjection(k, insertAt, name);
            if (!cmd.apply())
                throw new Exception("command 'layer.add' did not apply"
                    ~ (cmd.refusalReason().length
                        ? ": " ~ cmd.refusalReason() : ""));
            history.record(cmd);
        });
        }
    }
}
