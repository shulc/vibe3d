import bindbc.sdl;
import bindbc.opengl;
import std.string : toStringz;
import std.stdio : writeln, writefln, File, stderr;
import std.math : tan, sin, cos, sqrt, PI, abs;
import std.conv;
import std.json : JSONValue, JSONType;

// HTTP server module
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
version (WithAI)
import commands.ui.copilot_panel   : UiCopilotPanelCommand, g_copilotPanelShown;
import commands.tool.panel_edit    : ToolPanelEditCommand;
import commands.snap.toggle_type : SnapToggleTypeCommand;
import commands.snap.mode        : SnapModeCommand;
import commands.ai.toggle    : AiToggleCommand, AiToggleAction;
// AI Modeling Copilot findings panel (task 0402): the whole feature —
// panel, overlay, and copilot.* commands — is version(WithAI)-only. The
// underlying modules (copilot_panel.d, ai/analysis.d, etc.) are plain D and
// COULD compile under modeling-noai too, but the owner wants the feature
// entirely absent from the Windows-7 (noai) build, not just inert. Gating
// every import + call site here (rather than touching the modules) means
// dub's `-i` never pulls them into the noai compile at all. See every
// `version (WithAI)` block below tagged "copilot" for the matching sites.
version (WithAI) {
    import commands.copilot.analyze        : CopilotAnalyzeCommand;
    import commands.copilot.select_finding : CopilotSelectFindingCommand;
    import commands.copilot.cycle_finding  : CopilotCycleFindingCommand;
    import copilot_panel : CopilotPanel;
    import copilot_overlay : drawCopilotFindingOverlay;
}
import commands.falloff        : FalloffAddCommand, FalloffRemoveCommand,
                                  FalloffAutoSizeCommand;
import commands.path.define    : PathDefineCommand;
import commands.workplane     : WorkplaneResetCommand, WorkplaneEditCommand,
                                WorkplaneRotateCommand, WorkplaneOffsetCommand,
                                WorkplaneAlignToSelectionCommand;

import command;
import registry;
// Task 0415 (campaign 0407 §B.V1 step 1): registerTools/registerCommands
// host the command/tool factory registration moved out of main() below,
// parameterized by the EditorApp ctx bag.
import editor_app;
import registration : registerTools, registerCommands;
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
version (WithAI) import ai.onnx_backend : OnnxModelBackend;
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

version (WithRender) import render.render_mvp   : initIPR, drawIPRPanel, shutdownIPR;
version (WithRender) import render.render_diff  : runRenderDiff;

version (OSX) {
    import core.attribute : selector;
    extern (Objective-C) interface NSApplicationClass {
        NSApplication sharedApplication() @selector("sharedApplication");
    }
    extern (Objective-C) interface NSApplication {
        void setActivationPolicy(int policy) @selector("setActivationPolicy:");
        void activateIgnoringOtherApps(bool flag) @selector("activateIgnoringOtherApps:");
    }
    extern (C) NSApplicationClass objc_getClass(const(char)* name) nothrow @nogc;
}


// Read depth buffer at window position (px, py),
// accounting for HiDPI framebuffer scale.
float readDepth(int winW, int winH, int fbW, int fbH, float px, float py) {
    int fbX = cast(int)(px * fbW / winW);
    int fbY = fbH - 1 - cast(int)(py * fbH / winH);  // OpenGL Y is bottom-up
    if (fbX < 0 || fbX >= fbW || fbY < 0 || fbY >= fbH) return 1.0f;
    float depth;
    glReadPixels(fbX, fbY, 1, 1, GL_DEPTH_COMPONENT, GL_FLOAT, &depth);
    return depth;
}


// ---------------------------------------------------------------------------
// Enums shared across tools and main
// ---------------------------------------------------------------------------

enum DragMode { None, Orbit, Zoom, Pan, Select, SelectAdd, SelectRemove }

// Task 0206 (Quad/Split multi-cell overlays) — overlay draw mode for a
// single viewport cell's renderViewportSceneToFbo() call. `OverlayMode`
// itself is now declared in editor_app.d (task 0419 cyclic-import fix --
// renderViewportSceneToFbo's own parameter type needs it nameable without a
// back-edge from editor_app.d to app.d; imported back below).
//   None        — no tool/falloff active; nothing to draw.
//   Visual      — a NON-owner cell's world-derived replica: activeTool.draw
//                 / pipeGizmoHost.draw run with visualOnly=true, so gizmo
//                 geometry still renders reprojected under THIS cell's vp,
//                 but no cachedVp / ToolHandles registration+hit-test state
//                 is written (would corrupt the owner cell's interaction —
//                 see Tool.draw's doc comment in source/tool.d).
//   Interactive — the overlay-owner (active/origin) cell: today's full path,
//                 visualOnly=false. Pins cachedVp + runs the arbiter cycle.
import editor_app : OverlayMode;

// ---------------------------------------------------------------------------
// Module-level helpers
// ---------------------------------------------------------------------------

// edgeKey/countSelected relocated to editor_app.d (task 0419 Б1 -- used by
// the UI-panel block now in source/ui/panels.d; imported back below since
// edgeKey also has a call site here, in the snap-frame JIT install path).
import editor_app : edgeKey, countSelected;

// A broken stage form degrades to the legacy drawProvider every frame; the
// log service's once-gate keeps the diagnostic to a single line per stage
// instead of per-frame spam.
private void warnStageFormOnce(string stageId, string msg) {
    import log : logWarnOnce;
    logWarnOnce("forms", stageId,
                "stage form for '" ~ stageId ~
                "' failed to draw; falling back to legacy panel: " ~ msg);
}


private string buildJsonArray(bool[] sel) {
    import std.array : appender;
    import std.format : format;
    auto buf = appender!string();
    buf ~= "[";
    bool first = true;
    foreach (i, s; sel) {
        if (!s) continue;
        if (!first) buf ~= ",";
        buf ~= format("%d", i);
        first = false;
    }
    buf ~= "]";
    return buf.data;
}


// ---------------------------------------------------------------------------
// Panel layout
// ---------------------------------------------------------------------------

// Layout relocated to editor_app.d (task 0419 cyclic-import fix -- see the
// OverlayMode comment above); imported back below since `layout` the LOCAL
// is still declared/used here (main-loop resize, ctx-wiring), just its TYPE
// moved.
import editor_app : Layout;

/// Belt-and-suspenders dynamic-loader path augmentation for release
/// builds. The render backends' rpath flags already include
/// `$ORIGIN/lib` / `$ORIGIN/rpr` (Linux) and `@executable_path/...`
/// (macOS), but a binary distributed as a zip is fragile: if the
/// zip is opened from a different working directory than the
/// executable lives in, or if some dlopen path bypasses the rpath
/// (e.g. plugin SDKs loaded by name), the runtime falls back to
/// `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH` / `PATH`. Prepending the
/// exe-local `lib/` and `rpr/` dirs here covers that fallback.
///
/// No-op when the directories don't exist — dev builds rely on
/// dub-cache absolute paths baked into the binary and need nothing
/// here.
version (WithRender) private void ensureRuntimeLibPath()
{
    import std.file    : thisExePath, exists;
    import std.path    : buildPath, dirName;
    import std.process : environment;
    import std.string  : indexOf;

    string exeDir;
    try exeDir = thisExePath().dirName;
    catch (Exception) return;

    const libDir = buildPath(exeDir, "lib");
    const rprDir = buildPath(exeDir, "rpr");

    version (linux)        enum string ldVar = "LD_LIBRARY_PATH";
    else version (OSX)     enum string ldVar = "DYLD_LIBRARY_PATH";
    else version (Windows) enum string ldVar = "PATH";
    else                   enum string ldVar = "LD_LIBRARY_PATH";

    version (Windows) enum string sep = ";";
    else              enum string sep = ":";

    string augment;
    if (exists(libDir)) augment = libDir;
    if (exists(rprDir)) augment = augment.length == 0 ? rprDir : augment ~ sep ~ rprDir;
    if (augment.length == 0) return;

    const existing = environment.get(ldVar, "");
    if (existing.length == 0) {
        environment[ldVar] = augment;
    } else if (existing.indexOf(augment) < 0) {
        environment[ldVar] = augment ~ sep ~ existing;
    }
}

version (OSX) private void useAppBundleResourceCwd()
{
    import std.file : chdir, exists, thisExePath;
    import std.path : baseName, buildNormalizedPath, buildPath, dirName;
    import std.string : endsWith;

    string exeDir;
    try exeDir = thisExePath().dirName;
    catch (Exception) return;

    if (baseName(exeDir) != "MacOS") return;
    const contentsDir = dirName(exeDir);
    const appDir = dirName(contentsDir);
    if (!baseName(appDir).endsWith(".app")) return;

    const resourcesDir = buildNormalizedPath(contentsDir, "Resources");
    if (!exists(buildPath(resourcesDir, "config"))) return;

    try chdir(resourcesDir);
    catch (Exception) {
        // Fall back to the launch cwd; dev runs and test harnesses keep working.
    }
}

/// Absolute path to the SDL2 dylib shipped inside a .app bundle
/// (`Contents/Frameworks/libSDL2-2.0.0.dylib`, staged by
/// tools/macos/build_app.sh), or null when not running from a bundle
/// or the dylib isn't present. bindbc loads SDL2 via a bare-name
/// `dlopen`, which on macOS searches only DYLD paths and the shared
/// cache — never `@executable_path` — so a copy next to the binary
/// is invisible unless we hand `loadSDL` the explicit path. Dev runs
/// (no bundle) fall through to the default search and the system SDL2.
version (OSX) private string bundledSDL2Path()
{
    import std.file : exists, thisExePath;
    import std.path : baseName, buildNormalizedPath, dirName;
    import std.string : endsWith;

    string exeDir;
    try exeDir = thisExePath().dirName;
    catch (Exception) return null;

    if (baseName(exeDir) != "MacOS") return null;
    const contentsDir = dirName(exeDir);
    if (!baseName(dirName(contentsDir)).endsWith(".app")) return null;

    const dylib = buildNormalizedPath(contentsDir, "Frameworks", "libSDL2-2.0.0.dylib");
    return exists(dylib) ? dylib : null;
}

/// Set the window/taskbar icon from the RGBA blob embedded at compile time
/// (assets/icon/icon_64.rgba: 8-byte LE width/height header + RGBA8 pixels;
/// regenerate with tools/icon/gen_icons.py). Covers X11 and Windows — on
/// Wayland the compositor takes the icon from the .desktop entry instead.
void setWindowIcon(SDL_Window* window) {
    static immutable ubyte[] blob = cast(immutable ubyte[]) import("icon_64.rgba");
    static assert(blob.length >= 8, "icon_64.rgba missing or truncated");
    const uint w = blob[0] | (blob[1] << 8) | (blob[2] << 16) | (blob[3] << 24);
    const uint h = blob[4] | (blob[5] << 8) | (blob[6] << 16) | (blob[7] << 24);
    if (blob.length < 8 + cast(size_t) w * h * 4) return;
    SDL_Surface* surf = SDL_CreateRGBSurfaceWithFormatFrom(
        cast(void*) (blob.ptr + 8), w, h, 32, w * 4, SDL_PIXELFORMAT_RGBA32);
    if (!surf) return;
    SDL_SetWindowIcon(window, surf); // SDL copies the pixels; surface can go
    SDL_FreeSurface(surf);
}

// buildItemFrame relocated to editor_app.d (task 0419 Б1 -- used by the
// UI-panel block now in source/ui/panels.d; imported back below since it
// also has a call site here, in the HTTP-thread JIT snap-frame install).
import editor_app : buildItemFrame;

// ---------------------------------------------------------------------------
// Module-level globals (interactive-session state; never read by --test)
// ---------------------------------------------------------------------------

// g_layoutIniPathZ/g_forceLayoutReseed relocated to editor_app.d (task 0419
// Б1 -- written/read by the UI-panel block now in source/ui/panels.d;
// imported back below since both also have call/use sites here, in the
// startup ImGui.IniFilename wiring and the Reset-Layout-consuming NewFrame
// preamble). Public `__gshared` there -- the panel writes them directly as
// globals, not through ctx.
import editor_app : g_layoutIniPathZ, g_forceLayoutReseed, g_pendingLayoutReloadPathZ;

/// Task 0211 seed-guard primary discriminator. Computed ONCE at startup
/// (before `io.IniFilename` is assigned — see the `!command.g_testMode`
/// branch below), true iff no layout ini exists yet at the current
/// `kLayoutIniVersion` path. `io.IniFilename` is set to that exact path, and
/// ImGui auto-restores a dock tree from it on the first `NewFrame` iff the
/// file exists — so `exists(userIniPath)` and "ImGui will restore a dock
/// tree this session" are the SAME condition by construction, independent of
/// in-frame DockBuilder node lifecycle. Stays false in `--test` (that branch
/// never touches this global; io.IniFilename is forced null there).
private __gshared bool g_seedFreshLayout = false;

// g_pendingLayoutReloadPathZ/seedDefaultLayoutIfMissing relocated to
// editor_app.d too (task 0419 Б1; g_pendingLayoutReloadPathZ is already
// imported above alongside its siblings). seedDefaultLayoutIfMissing also
// has a call site here, in the startup ImGui.IniFilename wiring.
import editor_app : seedDefaultLayoutIfMissing;

import viewport : LayoutPreset;

// ---------------------------------------------------------------------------
// Task 0211: scoped viewport-only layout switch — dock-node internals
// ---------------------------------------------------------------------------
// `ImGuiDockNode_SetLocalFlags` / `_IsCentralNode` / `_IsEmpty` are exported
// by cimgui (cimgui.h:5010/5015/5017, compiled into the already-linked
// static cimgui lib — the igDockBuilder* set proves it's present) but not
// bound in the D layer (source/d_imgui only forward-declares
// `struct ImGuiDockNode;` and binds the igDockBuilder* set). All are plain
// `extern(C)` functions, so we declare the prototypes ourselves rather than
// editing the D-ImGui binding.
private extern(C) @nogc nothrow {
    void ImGuiDockNode_SetLocalFlags(ImGuiDockNode* self, int flags);
    bool ImGuiDockNode_IsCentralNode(ImGuiDockNode* self);
    bool ImGuiDockNode_IsEmpty(ImGuiDockNode* self);
}

// Private imgui dock-node flag (imgui_internal.h:1993) — internal-only bit,
// not part of the public `ImGuiDockNodeFlags` enum bound in d_imgui/imgui_h.d,
// so declared locally. Value confirmed against the vendored cimgui.h copy in
// ~/Code/D-ImGui. (The sibling `kDockFlagDockSpace` bit — "a DockSpace() node",
// used to mark the nested `viewportDockId` root — is gone too: task 0223
// dropped that inner dockspace entirely, so nothing declares a nested
// DockSpace node anymore.)
private enum int kDockFlagCentralNode  = 1 << 11;

// Private imgui dock-node flag (imgui_internal.h:1995, `HiddenTabBar`).
// task 0211 Phase 4 deleted the OLD per-cell `kDockFlagHiddenTabBar` shim in
// favor of the public `AutoHideTabBar` SharedFlag alone — correct for every
// LATER transition (viewport.layout switches, a user later docking a 2nd
// window into a node, an ini-restored session) because `AutoHideTabBar`'s
// event-driven toggle (imgui.cpp's `DockNodeUpdateFlagsAndCollapse`,
// `WantHiddenTabBarUpdate`) fires correctly whenever `DockNodeAddWindow` runs
// AFTER the node's `SharedFlags` already carry `AutoHideTabBar`.
//
// But the VERY FIRST DockBuilder-seeded frame (no ini yet — this file's
// `!testMode` seed block below) violates that precondition every time: our
// per-frame `ImGui.DockSpace(dockspaceId, …, AutoHideTabBar)` call (which
// sets the ROOT's SharedFlags and cascades it to descendants) runs BEFORE
// `DockBuilderAddNode(dockspaceId, 0)` recreates the root with
// SharedFlags=0 and BEFORE `DockBuilderSplitNode` creates leftId/topId/
// botId/vpRegion — so those children are born with SharedFlags=0 (inherited
// from the just-reset root at split time), and no cascade pass ever revisits
// them again with `AutoHideTabBar` set while `WantHiddenTabBarUpdate` is
// simultaneously true (empirically confirmed via a fresh-launch Xvfb capture
// task 0404 follow-up: single-window nodes keep a visible one-tab strip for
// the ENTIRE session — hundreds of frames, not a one-frame flash — until the
// user manually re-docks a window or restarts from the now-saved ini, which
// takes the ini-restore path where children exist BEFORE the first
// DockSpace() cascade and so converge correctly on frame 1).
//
// Fix: directly bake `HiddenTabBar` onto each single-window leaf node right
// after seeding (see the `!testMode` DockBuilder block below) — this ONLY
// corrects the known-broken INITIAL state; `AutoHideTabBar` stays on the
// dockspace and remains the live mechanism for every subsequent layout
// change, so this does not reintroduce the old shim's re-application burden
// (task 0211 deleted the shim because it needed manual upkeep on every
// layout change, not because a one-time seed-time bake was wrong).
private enum int kDockFlagHiddenTabBar = 1 << 13;

/// Dock Viewport##0..3 into `parentNodeId`, split according to the layout
/// preset `p` (V5: the per-preset viewport-cell split existed twice —
/// identically — as the central-node rebuild and the no-central-node
/// fallback clone; this is the one body both call).  Only docks the
/// viewport-cell windows; chrome panels (Layers / Tool Properties / etc.)
/// are docked by the caller before/around this call.
///
/// Single-tab cells auto-hide their tab bar via the `AutoHideTabBar`
/// SharedFlag set on the owning DockSpace() call (task 0211 Phase 4) — no
/// per-cell flag-poking needed here anymore.
void dockSplitViewportCells(ImGuiID parentNodeId, LayoutPreset p) {
    final switch (p) {
        case LayoutPreset.Single:
            ImGui.DockBuilderDockWindow("Viewport##0", parentNodeId);
            break;
        case LayoutPreset.SplitH: {
            ImGuiID l2, r2;
            ImGui.DockBuilderSplitNode(parentNodeId, ImGuiDir.Left, 0.5f, &l2, &r2);
            ImGui.DockBuilderDockWindow("Viewport##0", l2);
            ImGui.DockBuilderDockWindow("Viewport##1", r2);
            break;
        }
        case LayoutPreset.SplitV: {
            ImGuiID t2, b2;
            ImGui.DockBuilderSplitNode(parentNodeId, ImGuiDir.Up, 0.5f, &t2, &b2);
            ImGui.DockBuilderDockWindow("Viewport##0", t2);
            ImGui.DockBuilderDockWindow("Viewport##1", b2);
            break;
        }
        case LayoutPreset.Quad: {
            ImGuiID t2, b2, tl, tr, bl, br;
            ImGui.DockBuilderSplitNode(parentNodeId, ImGuiDir.Up, 0.5f, &t2, &b2);
            ImGui.DockBuilderSplitNode(t2, ImGuiDir.Left, 0.5f, &tl, &tr);
            ImGui.DockBuilderSplitNode(b2, ImGuiDir.Left, 0.5f, &bl, &br);
            ImGui.DockBuilderDockWindow("Viewport##0", tl);
            ImGui.DockBuilderDockWindow("Viewport##1", tr);
            ImGui.DockBuilderDockWindow("Viewport##2", bl);
            ImGui.DockBuilderDockWindow("Viewport##3", br);
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// Perf HUD (task 0198) — perf-build-only ImGui overlay reading the
// FrameProbe ring (task 0195, source/perf_probe.d) directly. All state +
// the draw function live at module scope (not nested in main()) since
// nothing here needs main()'s locals — ImGui's own GetIO()/GetWindowDrawList
// are enough. See doc/perf_hud_plan.md for the design.
// ---------------------------------------------------------------------------

version (PerfProbe) {

    import core.time : MonoTime;

    /// One HUD-owned wall-clock sample, keyed on FrameProbe's monotonic
    /// `frameCount`. Lets the HUD bracket "the last second" for the
    /// worst-frame readout WITHOUT adding a timestamp field to `FrameRec`
    /// (a new-instrumentation change the plan forbids) — see §5.5.
    private struct HudTsEntry {
        long frameCount;
        MonoTime t;
    }

    /// Preallocated HUD state — every buffer is a fixed-size inline array,
    /// allocated once (the `__gshared` instance lives for the process
    /// lifetime), so the per-frame draw path never touches the GC. Mirrors
    /// `g_frames`'s `__gshared`, single-writer (main-loop-only) style.
    private struct PerfHudState {
        enum size_t RecCap = 256;  // tail window for the graph + stacked
                                    // columns; FrameProbe's own ring is 8192
                                    // deep, the HUD only ever looks at the
                                    // most recent slice of it.
        enum size_t TsCap  = 512;  // HUD-side wall-clock ring for the
                                    // last-second bracket (§5.5).

        FrameRec[RecCap]   recBuf;
        float[RecCap]      plotMs;
        HudTsEntry[TsCap]  tsRing;
        size_t             tsLen;
        size_t             tsPos;
    }

    private __gshared PerfHudState g_perfHud;

}

/// Draw the perf HUD overlay. Full body gated `version (PerfProbe)`; the
/// default build compiles this as an empty function (no-op), so the call
/// site below needs no additional `version` guard beyond the outer
/// `if (perfHud)` (which itself can only ever be true in a perf build —
/// see the flag-parse comment).
///
/// MUST be called from the panel-build region wrapped in
/// `g_frames.phase(Phase.ui)` (see the call site) — ImGui is immediate-mode,
/// so this window's commands must be issued before `ImGui.Render()`; there
/// is no "draw after endFrame" for the same frame. Charging the HUD's own
/// build cost to `uiNs` is the honest choice (the HUD *is* UI) and keeps it
/// out of every other measured phase and out of the `other` remainder. Note
/// this means `uiNs` is no longer purely "ImGui chrome render" once the HUD
/// is on — it also carries the HUD's own draw-list build cost. That is
/// intended, not a leak.
void drawPerfHud() {
    version (PerfProbe) {
        import core.stdc.stdio : snprintf;
        import core.time : seconds;

        size_t n = g_frames.copyRecent(g_perfHud.recBuf[]);
        if (n == 0) return;   // nothing recorded yet (first frame or two)

        foreach (i; 0 .. n)
            g_perfHud.plotMs[i] = cast(float)(g_perfHud.recBuf[i].totalNs * 1e-6);

        FrameStatsSnapshot st = g_frames.stats();

        // HUD-side wall-clock ring (§5.5) — push every draw so the
        // worst-of-last-second readout below can bracket a true ~1s window.
        g_perfHud.tsRing[g_perfHud.tsPos] = HudTsEntry(st.frameCount, MonoTime.currTime);
        g_perfHud.tsPos = (g_perfHud.tsPos + 1) % PerfHudState.TsCap;
        if (g_perfHud.tsLen < PerfHudState.TsCap) g_perfHud.tsLen++;

        // ---- overlay window: semi-transparent, top-right, click-through ----
        ImVec2 dsz = ImGui.GetIO().DisplaySize;
        enum float pad = 8.0f;
        ImGui.SetNextWindowPos(ImVec2(dsz.x - pad, pad), 0, ImVec2(1, 0));
        ImGui.SetNextWindowBgAlpha(0.35f);
        immutable int hudFlags =
            ImGuiWindowFlags.NoDecoration       |
            ImGuiWindowFlags.NoInputs           |   // click-through: never
                                                     // steals viewport orbit/drag
            ImGuiWindowFlags.NoNav              |
            ImGuiWindowFlags.NoFocusOnAppearing |
            ImGuiWindowFlags.AlwaysAutoResize;
        ImGui.Begin("##perfhud", null, hudFlags);

        char[128] buf;
        int blen;
        // snprintf returns the INTENDED length (may exceed buf.length-1 on
        // truncation, or be <0 on error); clamp before slicing buf so a large
        // formatted value can never over-read the stack buffer (drawPerfHud is
        // @system and the perf build runs without bounds checks). Called
        // directly (never stored) so no closure allocation.
        int clampBlen(int r) {
            if (r < 0) return 0;
            return r > cast(int) buf.length - 1 ? cast(int) buf.length - 1 : r;
        }
        const(FrameRec)* newest = &g_perfHud.recBuf[n - 1];

        // ---- scrolling totalNs graph + 16.6/33ms target lines ----
        // Fixed y-axis (scaleMin=0, scaleMax=50ms) so the target lines sit
        // at a meaningful, stable height frame to frame.
        enum float scaleMax = 50.0f;
        ImVec2 graphSize = ImVec2(240.0f, 60.0f);
        blen = snprintf(buf.ptr, buf.length, "%.2f ms".ptr, newest.totalNs * 1e-6);
        ImGui.PlotLines("##ft", g_perfHud.plotMs.ptr, cast(int) n, 0,
                        cast(string) buf[0 .. clampBlen(blen)], 0.0f, scaleMax, graphSize);

        // Target lines: map ms -> y using the plot's OWN item rect, queried
        // AFTER PlotLines (ImGui's "ask the item you just drew" idiom) — this
        // stays correct even if PlotLines' internal frame padding changes,
        // rather than us recomputing the rect from graphSize independently.
        {
            ImVec2 rMin = ImGui.GetItemRectMin();
            ImVec2 rMax = ImGui.GetItemRectMax();
            float h = rMax.y - rMin.y;
            auto dl = ImGui.GetWindowDrawList();
            float y166 = rMax.y - (16.6f / scaleMax) * h;
            float y33  = rMax.y - (33.0f  / scaleMax) * h;
            if (y166 >= rMin.y && y166 <= rMax.y)
                dl.AddLine(ImVec2(rMin.x, y166), ImVec2(rMax.x, y166), IM_COL32(80, 220, 80, 200));
            if (y33 >= rMin.y && y33 <= rMax.y)
                dl.AddLine(ImVec2(rMin.x, y33), ImVec2(rMax.x, y33), IM_COL32(230, 190, 60, 200));
        }
        ImGui.TextUnformatted("green=16.6ms  yellow=33ms");

        // ---- per-phase disjoint stacked columns ----
        // Disjoint set {eventNs, cacheNs, uploadNs, drawNs, uiNs, other};
        // other = totalNs - sum(those) (clamped >= 0), mirroring 0195's
        // caller-side remainder formula exactly. toolNs is a NESTED subset
        // of eventNs (0195's contract) and is shown as a standalone figure
        // below, never folded into this stack (would double-count).
        ImGui.Dummy(ImVec2(0, 4));
        ImGui.TextUnformatted("phase: blue=events cyan=cache purple=upload orange=draw green=ui grey=other");
        {
            enum float colW = 3.0f;
            enum float colH = 40.0f;
            static immutable ImU32[6] palette = [
                IM_COL32(70, 130, 220, 255),   // events
                IM_COL32(70, 210, 210, 255),   // cache
                IM_COL32(170, 100, 220, 255),  // upload
                IM_COL32(230, 150, 60, 255),   // draw
                IM_COL32(90, 200, 90, 255),    // ui
                IM_COL32(140, 140, 140, 255),  // other
            ];
            ImVec2 cursor = ImGui.GetCursorScreenPos();
            auto dl = ImGui.GetWindowDrawList();
            size_t take = n < 120 ? n : 120;
            size_t start = n - take;
            foreach (i; 0 .. take) {
                const(FrameRec)* r = &g_perfHud.recBuf[start + i];
                long other = r.totalNs - (r.eventNs + r.cacheNs + r.uploadNs + r.drawNs + r.uiNs);
                if (other < 0) other = 0;
                long[6] segs = [r.eventNs, r.cacheNs, r.uploadNs, r.drawNs, r.uiNs, other];
                float x0 = cursor.x + i * colW;
                float yBase = cursor.y + colH;
                float accumMs = 0.0f;
                foreach (s; 0 .. 6) {
                    float segMs = segs[s] * 1e-6f;
                    if (segMs <= 0.0f) continue;
                    float y0 = yBase - (accumMs + segMs) / scaleMax * colH;
                    float y1 = yBase - accumMs / scaleMax * colH;
                    if (y0 < cursor.y) y0 = cursor.y;
                    dl.AddRectFilled(ImVec2(x0, y0), ImVec2(x0 + colW - 1.0f, y1), palette[s]);
                    accumMs += segMs;
                }
            }
            ImGui.Dummy(ImVec2(cast(float)(take * colW), colH + 2));
        }

        blen = snprintf(buf.ptr, buf.length, "tool (in events): %.2f ms".ptr,
                        newest.toolNs * 1e-6);
        ImGui.TextUnformatted(cast(string) buf[0 .. clampBlen(blen)]);

        // ---- alloc/frame + GC ----
        ImGui.Dummy(ImVec2(0, 4));
        double avgAllocKb = st.frameCount > 0
            ? (cast(double) st.sumAllocBytes / cast(double) st.frameCount) / 1024.0 : 0.0;
        blen = snprintf(buf.ptr, buf.length,
                        "alloc: %.2f KB/frame avg (latest %.2f KB), gc collections: %.0f".ptr,
                        avgAllocKb, newest.gcAllocBytes / 1024.0, cast(double) st.sumCollections);
        ImGui.TextUnformatted(cast(string) buf[0 .. clampBlen(blen)]);

        // ---- worst-frame-of-last-second ----
        ImGui.Dummy(ImVec2(0, 4));
        {
            // Scan the HUD's own timestamp ring backward for the oldest
            // entry still within the last ~1s of wall time, then bracket
            // that many of the most recent FrameRecs and pick the max
            // totalNs among them.
            //
            // Bounded by RecCap (256): above ~256fps the true "last second"
            // window is wider than our recent-frame buffer, so this
            // self-correcting-ly falls back to "worst of the buffered tail"
            // instead — never reads outside recBuf, never a bug, just a
            // coarser window at very high frame rates.
            MonoTime now = MonoTime.currTime;
            long deltaCount = 0;
            if (g_perfHud.tsLen > 0) {
                size_t oldestIdx = 0;
                size_t scanned = 0;
                foreach (k; 0 .. g_perfHud.tsLen) {
                    size_t idx = (g_perfHud.tsPos + PerfHudState.TsCap - 1 - k) % PerfHudState.TsCap;
                    if (now - g_perfHud.tsRing[idx].t > 1.seconds) break;
                    oldestIdx = idx;
                    scanned++;
                }
                if (scanned > 0)
                    deltaCount = st.frameCount - g_perfHud.tsRing[oldestIdx].frameCount;
            }
            size_t windowN = (deltaCount > 0 && cast(size_t) deltaCount < n)
                ? cast(size_t) deltaCount : n;
            size_t wStart = n - windowN;
            size_t worstI = wStart;
            foreach (i; wStart .. n)
                if (g_perfHud.recBuf[i].totalNs > g_perfHud.recBuf[worstI].totalNs) worstI = i;
            const(FrameRec)* w = &g_perfHud.recBuf[worstI];
            const(char)* hitchTag = (w.totalNs > 33_000_000) ? " [HITCH>33ms]".ptr
                                   : (w.totalNs > 16_600_000) ? " [>16.6ms]".ptr
                                   : "".ptr;
            blen = snprintf(buf.ptr, buf.length,
                "worst/1s: %.2fms%s  ev=%.2f cache=%.2f up=%.2f draw=%.2f ui=%.2f".ptr,
                w.totalNs * 1e-6, hitchTag,
                w.eventNs * 1e-6, w.cacheNs * 1e-6, w.uploadNs * 1e-6,
                w.drawNs * 1e-6, w.uiNs * 1e-6);
            ImGui.TextUnformatted(cast(string) buf[0 .. clampBlen(blen)]);
        }

        ImGui.End();
    }
}

// ---------------------------------------------------------------------------
// AI entry-point availability (compile-time gates for two UI affordances)
// ---------------------------------------------------------------------------
// kAiToggleAvailable / kGenerateAiAvailable relocated to editor_app.d (task
// 0419 cyclic-import fix -- read ONLY by the UI-panel block, now in
// source/ui/panels.d, via `with(app)`; see editor_app.d for the full
// two-gates rationale). Imported back below for app.d's own remaining
// references until the panel block itself is fully relocated (later 0419
// phases) -- unused once that lands, at which point this import is dead
// weight to prune, not a correctness issue.
import editor_app : kAiToggleAvailable, kGenerateAiAvailable;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main(string[] args) {
    // Release-binary fallback (R2 of doc/render_distribution_plan.md):
    // augment the dynamic-loader search path with <exeDir>/lib BEFORE
    // any GL/Cycles/RPR module ctor can touch dlopen. D-Cycles' build-
    // time rpath bakes $ORIGIN/lib for the same purpose, but a stale
    // rpath (e.g. binary downloaded + chmod'd weird) or a forgotten
    // DT_NEEDED soname mismatch can still fall back to LD_LIBRARY_PATH
    // / DYLD_LIBRARY_PATH, so we set those too. Skipped silently when
    // <exeDir>/lib doesn't exist — dev builds rely on the link-time
    // dub-cache absolute paths and don't need this.
    version (WithRender) ensureRuntimeLibPath();
    version (OSX) useAppBundleResourceCwd();

    // Parse --playback <file> flag
    string playbackFile;
    version (ReleaseBuild)
        bool startHttpServer = false; // Release/default runs do not expose HTTP.
    else
        bool startHttpServer = true;
    bool testMode = false;
    // --visible: pair with --test to WATCH a driven session. Keeps all of
    // --test's HTTP/injection plumbing (play-events, mouseOverride, real-input
    // drop) but maps the window and presents real frames via SwapWindow
    // instead of the headless glFlush. Lets a human eyeball what a test gesture
    // does on screen; never used by the -j parallel runner (the hidden+no-swap
    // path exists precisely to avoid the multi-window compositor swap-park).
    bool visibleTest = false;
    // --perf: benchmark mode. Disables vsync (SDL_GL_SetSwapInterval(0)) and
    // fast-forwards event replay (ignores recorded timestamps, drains every
    // due event per tick) so the perf harness can churn its matrix in
    // seconds. Composes with --test (the runner launches `vibe3d --test
    // --perf`). PerfProbe timers inside the tool loop are independent of feed
    // rate, so fast-forward leaves the per-stage measurements correct.
    bool perfMode = false;
    // --perf-hud: perf-build-only ImGui overlay (task 0198) reading the
    // FrameProbe ring (task 0195) directly — scrolling totalNs graph,
    // per-phase colour breakdown, alloc/frame, worst-frame-of-last-second.
    // Always declared so a default build can parse the flag and print a
    // polite message; only ever set true under version(PerfProbe), so a
    // default build leaves it false and the (version-gated, stubbed)
    // drawPerfHud() call site never fires.
    bool perfHud = false;
    ushort httpPort = 8080;       // Default port
    int  cliWinW = 800, cliWinH = 600;   // overridable via --window WxH
                                          // (also via --viewport WxH which
                                          // sets the window to vp+chrome)
    bool cliSizeExplicit = false;        // true when --window/--viewport was
                                          // passed — suppresses DPI scaling of
                                          // the default window size so external
                                          // harnesses get exact pixel sizes

    // --render-diff <case.json> --render-backend cycles|rpr
    //     --render-output <out.ppm>
    // Headless mode: build a tiny scene from the JSON case, render N
    // samples through the chosen backend, write a PPM, exit. No SDL /
    // GL / ImGui — used by tools/render_diff/run.d for cross-backend
    // image parity. Requires --config=with-render.
    string renderDiffCase;
    string renderDiffBackend = "cycles";
    string renderDiffOutput;

    // --ai-log <path>: opt-in live interaction-log capture (task 0027). Thin
    // CLI alias for the VIBE3D_AI_LOG env var (CLI wins). OFF when both unset.
    string aiLogCliPath;

    // --ai-model <path>: opt-in model-backed handle decision provider (task
    // 0028). Thin CLI alias for the VIBE3D_AI_MODEL env var (CLI wins). OFF
    // when both unset — the default deterministic advisor stays the decision
    // source and behavior is unchanged.
    string aiModelCliPath;

    for (size_t i = 1; i < args.length; ++i) {
        if (args[i] == "--playback") {
            if (i + 1 >= args.length) {
                writeln("Error: --playback requires a file argument");
                import core.stdc.stdlib : exit;
                exit(1);
            }
            playbackFile = args[++i];
        } else if (args[i] == "--test") {
            testMode = true;
            startHttpServer = true;
            command.g_testMode = true;  // gate testMode-only commands (re-eval D5)
        } else if (args[i] == "--perf") {
            perfMode = true;
        } else if (args[i] == "--perf-hud") {
            version (PerfProbe) {
                perfHud = true;
            } else {
                writeln("--perf-hud requires a perf build " ~
                        "(dub build --build=perf); ignoring.");
            }
        } else if (args[i] == "--visible") {
            visibleTest = true;
        } else if (args[i] == "--no-http") {
            startHttpServer = false;
        } else if (args[i] == "--http-port") {
            startHttpServer = true;
            if (i + 1 >= args.length) {
                writeln("Error: --http-port requires a port number");
                import core.stdc.stdlib : exit;
                exit(1);
            }
            httpPort = cast(ushort)args[++i].to!int;
        } else if (args[i] == "--window") {
            // --window WxH (e.g. --window 1426x966) — initial SDL window
            // size. Useful to match an external engine's viewport for the
            // cross-engine drag test.
            if (i + 1 >= args.length) {
                writeln("Error: --window requires WxH (e.g. 1426x966)");
                import core.stdc.stdlib : exit;
                exit(1);
            }
            import std.string : split;
            auto parts = args[++i].split("x");
            if (parts.length != 2) {
                writeln("Error: --window arg must be WxH");
                import core.stdc.stdlib : exit;
                exit(1);
            }
            cliWinW = parts[0].to!int;
            cliWinH = parts[1].to!int;
            cliSizeExplicit = true;
        } else if (args[i] == "--viewport") {
            // --viewport WxH — request the CAMERA viewport (3D area)
            // be exactly WxH. Implementation: size the SDL window so
            // that, after Layout's side panel (sideW=150) and tab+
            // status bars (statusH=28 each), the central viewport is
            // WxH. Picks the same size everywhere — avoids the
            // mismatch between projection aspect (uses cameraView.
            // width/height) and mouse-event coords (window pixels)
            // that arises when these are independently configurable.
            //
            // Used by the cross-engine drag test to match a reference
            // engine's viewport (1426x966) so that screen-pixel drag
            // → world-delta math is identical between engines.
            if (i + 1 >= args.length) {
                writeln("Error: --viewport requires WxH (e.g. 1426x966)");
                import core.stdc.stdlib : exit;
                exit(1);
            }
            import std.string : split;
            auto parts = args[++i].split("x");
            if (parts.length != 2) {
                writeln("Error: --viewport arg must be WxH");
                import core.stdc.stdlib : exit;
                exit(1);
            }
            // Layout chrome: sideW (150) on left, statusH (28) on top
            // for the tab bar and bottom for the status bar. Match
            // the constants in struct Layout.resize.
            cliWinW = parts[0].to!int + 150;       // + sideW
            cliWinH = parts[1].to!int + 2 * 28;    // + 2 × statusH
            cliSizeExplicit = true;
        } else if (args[i] == "--render-diff") {
            if (i + 1 >= args.length) {
                writeln("Error: --render-diff requires a case.json path");
                import core.stdc.stdlib : exit;
                exit(1);
            }
            renderDiffCase = args[++i];
        } else if (args[i] == "--render-backend") {
            if (i + 1 >= args.length) {
                writeln("Error: --render-backend requires a name");
                import core.stdc.stdlib : exit;
                exit(1);
            }
            renderDiffBackend = args[++i];
        } else if (args[i] == "--render-output") {
            if (i + 1 >= args.length) {
                writeln("Error: --render-output requires a PPM path");
                import core.stdc.stdlib : exit;
                exit(1);
            }
            renderDiffOutput = args[++i];
        } else if (args[i] == "--ai-log") {
            if (i + 1 >= args.length) {
                writeln("Error: --ai-log requires a file path");
                import core.stdc.stdlib : exit;
                exit(1);
            }
            aiLogCliPath = args[++i];
        } else if (args[i] == "--ai-model") {
            if (i + 1 >= args.length) {
                writeln("Error: --ai-model requires a file path");
                import core.stdc.stdlib : exit;
                exit(1);
            }
            aiModelCliPath = args[++i];
        } else {
            writefln("Error: unknown argument '%s'", args[i]);
            import core.stdc.stdlib : exit;
            exit(1);
        }
    }

    // Headless render-diff path. Bypasses SDL + ImGui + main loop
    // entirely — both backends' CPU paths produce framebuffers without
    // needing a GL context.
    if (renderDiffCase.length > 0) {
        version (WithRender) {
            if (renderDiffOutput.length == 0) {
                writeln("Error: --render-diff requires --render-output");
                import core.stdc.stdlib : exit;
                exit(1);
            }
            import core.stdc.stdlib : exit;
            exit(runRenderDiff(renderDiffCase, renderDiffBackend, renderDiffOutput));
        } else {
            writeln("Error: --render-diff requires --config=with-render");
            import core.stdc.stdlib : exit;
            exit(1);
        }
    }

    // Load user preferences (window size, recent files, last dir, sticky tool
    // defaults). Gated OFF in --test so the suite stays deterministic and never
    // touches the user's real ~/.config — UNLESS VIBE3D_CONFIG_DIR is set
    // (tests / multi-instance debugging that opt into an explicit scratch dir).
    // imgui.ini follows the same precedent (IniFilename=null in --test).
    bool prefsActive;
    {
        import std.process : environment;
        prefsActive = !command.g_testMode
                      || environment.get("VIBE3D_CONFIG_DIR", "").length > 0;
    }
    if (prefsActive) loadPrefs();

    bool playbackMode = playbackFile.length > 0;

    // Prefer the SDL2 bundled in the .app (self-contained release); fall back
    // to the system/dev SDL2 otherwise. See bundledSDL2Path() for the why.
    version (OSX) {
        import std.string : toStringz;
        const sdlBundled = bundledSDL2Path();
        const sdlResult  = sdlBundled !is null ? loadSDL(sdlBundled.toStringz) : loadSDL();
        if (sdlResult != sdlSupport) { writeln("Failed to load SDL2"); return; }
    } else {
        if (loadSDL() != sdlSupport) { writeln("Failed to load SDL2"); return; }
    }
    // Declare per-monitor DPI awareness on Windows (no-op elsewhere and on
    // SDL < 2.24). Without it, a display scale above 100% makes DWM render
    // the window at 96 DPI and bitmap-stretch the result — the whole UI
    // (fonts included) comes out blurry. With the hint the window gets true
    // physical pixels; UI elements are smaller on scaled displays until a
    // DPI-scaled font/style pass is added on top.
    // (string literal: the SDL_HINT_WINDOWS_DPI_AWARENESS constant is only
    // exposed by bindbc-sdl at sdl2240+, but SDL_SetHint takes the name as
    // a plain string and pre-2.24 SDL runtimes just ignore unknown hints)
    SDL_SetHint("SDL_WINDOWS_DPI_AWARENESS", "permonitorv2");
    // On macOS an unfocused window may consume the first click only to focus
    // the app. Let SDL deliver that click as a normal mouse button event too.
    SDL_SetHint("SDL_MOUSE_FOCUS_CLICKTHROUGH", "1");
    if (SDL_Init(SDL_INIT_VIDEO) != 0) { writefln("SDL_Init: %s", SDL_GetError()); return; }

    // Cycles' Metal device holds a *process-global* ShaderCache singleton
    // (g_shaderCache in device/metal/kernel.mm) whose ~ShaderCache fires
    // from __cxa_finalize at process exit and calls metal_printf → glog.
    // By that point glog's own globals are already torn down, abort()s.
    // Cycles itself relies on the host to bypass C++ static destructors
    // at exit (TerminateProcess on Win, _exit on POSIX). Register this
    // scope(exit) FIRST so it runs LAST in LIFO
    // order — after shutdownIPR / SDL_Quit / ImGui teardown, then short-
    // circuit straight to OS. Side effect: skips D runtime _termRuntime
    // + GC term. Acceptable for an interactive editor at exit time; the
    // OS reclaims everything.
    version (WithRender) version (OSX) scope(exit) {
        import core.sys.posix.unistd : _exit;
        _exit(0);
    }
    scope(exit) SDL_Quit();

    // Load libassimp for OBJ/glTF/FBX (and LWO-via-assimp) interchange I/O.
    // Dynamic dlopen — a missing library is non-fatal: native .v3d and the
    // pure-D LWO writer still work. See doc/asset_io_plan.md Phase 0.
    initAssimp();
    scope(exit) shutdownAssimp();

    // Initialize HTTP server.
    //
    // The server object is ALWAYS constructed, even when the network
    // listener is disabled (release/default runs, --no-http). The ctor
    // binds no socket and spawns no thread — only start() opens the port.
    // Constructing unconditionally keeps the command-dispatch wiring below
    // (commandHandlerDelegate / formsInteractiveDispatch / replayUndoEntry,
    // all assigned inside the `if (httpServer !is null)` block) in place for
    // the UI: status-line `kind: script` actions dispatch through
    // commandHandlerDelegate, so it must be wired regardless of whether the
    // HTTP port is open. Without this, a release build (HTTP off by default)
    // left commandHandlerDelegate null and every `kind: script` status-line
    // action (falloff type, granular ACEN sub-modes, edit-mode convert, …)
    // silently no-op'd, while `kind: command` items kept working (they
    // dispatch via runCommand directly). start() stays gated on
    // startHttpServer, so no port is exposed when HTTP is off.
    HttpServer httpServer = new HttpServer(httpPort);
    if (startHttpServer) {
        if (testMode) {
            httpServer.setTestMode(true);
            mouseOverride();
        }
        // --perf: fast-forward the HTTP-driven replay too (the harness drives
        // drags through /api/play-events → tickEventPlayer).
        if (perfMode) httpServer.setPlayerFastForward(true);
        httpServer.start();
        logInfo("http", "HTTP server starting on port " ~ httpPort.to!string);
    }
    scope(exit) {
        if (httpServer !is null && httpServer.running) {
            httpServer.stop();
        }
    }

    // AI3D async job controller (task 0381, doc/ai3d_ui_plan.md). Owns the
    // dedicated worker thread(s) that run std.net.curl transfers
    // (ai3d.stage_artifact); constructed with NO Document/Mesh/GpuMesh/View/
    // ImGui/history reference (Risk 3) — it is structurally incapable of
    // mutating the scene. The only channel out is the immutable Ai3dEvent
    // queue, drained once per frame below (onAi3dEvent, near runCommand) and
    // is the SOLE path that ever dispatches a document mutation
    // (ai3d.importResult, via the ordinary undoable runCommand path).
    //
    // Shutdown (Phase 4, Risk 4c): request a stop, then join within budget
    // BEFORE falling into normal druntime teardown. `stageArtifact`'s
    // Ai3dOperationTimeoutMs (10s) backstop on every transfer means a
    // wedged perform() unwinds well inside Ai3dClientJoinTimeoutMs (35s) in
    // practice, so join() almost always succeeds here. On a join TIMEOUT,
    // take the abrupt exit path — NOT normal druntime shutdown, which
    // would try to join the core.thread worker still blocked inside
    // libcurl's perform() (hang) or run module dtors over a half-torn
    // transport (crash). The abrupt exit skips both: no cross-thread frees
    // (the worker owns and frees its own HTTP handle), no GC/module dtor
    // pass, no hang.
    auto ai3dController = new Ai3dJobController();
    scope(exit) {
        ai3dController.stop();
        if (!ai3dController.join(Ai3dClientJoinTimeoutMs)) {
            // core.stdc.stdlib._Exit (C99/C11, cross-platform) is the
            // abrupt exit this hardening calls for — druntime does not
            // bind POSIX's lowercase `_exit` on every platform, but
            // `_Exit` has the identical contract (immediate termination,
            // no atexit/module-dtor pass, no stdio flush) and is available
            // on both POSIX and Windows.
            import core.stdc.stdlib : _Exit;
            logWarn("ai3d", "controller join timed out at shutdown; forcing exit");
            _Exit(0);
        }
    }

    // AI3D worker LIFECYCLE manager (task 0403, source/ai3d/worker_manager.d)
    // — Install/Start/Stop for the optional TRELLIS worker subprocess, so
    // the end user never runs `python -m ... serve` by hand. Distinct from
    // ai3dController above: that owns the HTTP/curl transport to WHATEVER
    // worker URL is configured (manual or spawned); this owns the
    // subprocess itself (a plain OS process, no thread — same "crash-
    // isolated subprocess, non-blocking per-frame poll" shape as
    // remeshJob below). Shutdown kills only a worker/install step THIS
    // manager spawned — never a foreign process on the configured port.
    auto ai3dWorkerManager = new Ai3dWorkerManager();
    scope(exit) ai3dWorkerManager.shutdown();

    // Quad-remesh job (source/remesh/remesh_job.d) — a crash-isolated
    // SUBPROCESS (the external autoremesher_cli helper), polled once per
    // frame near the ai3d drain below; never a worker thread (the helper's
    // geogram backend can abort() on bad input, and only process isolation
    // survives that). Cancel any in-flight subprocess at shutdown so vibe3d
    // never leaves an orphaned helper running.
    auto remeshJob = new RemeshJob();
    scope(exit) remeshJob.cancel();

    EventLogger evLog;
    version (ReleaseBuild) {
        if (testMode && !playbackMode) {
            evLog.open("events.log");
        }
    } else {
        if (!playbackMode) {
            evLog.open("events.log");
        }
    }
    scope(exit) evLog.close();

    EventLogger recLog;   // F1/F2 recording for MCP tests
    scope(exit) recLog.close();

    EventPlayer evPlay;
    if (playbackMode && !evPlay.open(playbackFile)) return;
    if (playbackMode) mouseOverride();
    // --perf fast-forwards file playback too (the HTTP-driven player is set
    // separately, below, once httpServer exists).
    if (perfMode) evPlay.fastForward = true;

    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    // SDL's default depth size is 16 bits. Linux drivers tend to hand back a
    // 24-bit depth buffer anyway, but on Windows the pixel-format chooser
    // honours the 16-bit request literally — and with drawFaces' worth of
    // glPolygonOffset(1,1), the 256× coarser depth step pushes steep
    // (silhouette-adjacent) faces far enough back that backfaces poke
    // through along contour edges (black triangular notches). Ask for
    // 24-bit explicitly.
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);

    // UI scale from the primary display's DPI (96 = 100%). With the DPI
    // awareness hint above, a Windows display at 125% reports ddpi=120 and
    // the window is in true physical pixels — so the UI must compensate by
    // scaling fonts/style/window itself. Quantized to 0.25 steps so X11
    // hosts with slightly-off xrandr DPI (e.g. 95.4) stay at exactly 1.0.
    // macOS/Retina reports high physical DPI for an otherwise point-sized UI;
    // scaling the font again makes the interface visibly oversized there.
    // Pinned to 1.0 in --test mode: recorded event logs carry absolute
    // pixel coordinates, and a host-dependent scale would shift panel
    // layout under them.
    float uiScale = 1.0f;
    version (OSX) {
        // Keep the default 14px Inter font on macOS.
    } else if (!command.g_testMode) {
        float ddpi;
        if (SDL_GetDisplayDPI(0, &ddpi, null, null) == 0 && ddpi > 0) {
            import std.algorithm : clamp;
            import std.math : round;
            uiScale = clamp(round(ddpi / 96.0f * 4.0f) / 4.0f, 1.0f, 3.0f);
        }
    }

    int winW = cliWinW, winH = cliWinH;
    // Persisted window size (when prefs is active and the user didn't pass an
    // explicit --window/--viewport) takes precedence and is used as EXACT
    // physical pixels: the stored value is already post-uiScale (it was
    // captured from SDL_GetWindowSize last run), so the uiScale growth below
    // is SKIPPED — re-applying it would inflate the window on every run.
    // Explicit --window/--viewport always wins (external-harness contract).
    const bool usePrefsWindow = prefsActive && !cliSizeExplicit
                                && g_prefs.window.w > 0 && g_prefs.window.h > 0;
    if (usePrefsWindow) {
        winW = g_prefs.window.w;
        winH = g_prefs.window.h;
    } else if (!cliSizeExplicit && uiScale != 1.0f) {
        // Grow the default window with the UI scale so the app opens at the
        // same apparent size on a 125%/150% display. Explicit --window /
        // --viewport sizes are exact pixel requests (external-harness
        // contracts) and are never scaled.
        winW = cast(int)(winW * uiScale);
        winH = cast(int)(winH * uiScale);
    }
    // In --test mode create the window HIDDEN. The GL context, ImGui rendering,
    // ViewCache/picking (all projection-matrix driven) and recorded-event
    // playback (mouse pos is overridden) are visibility-independent, so nothing
    // the tests exercise needs a mapped window. Keeping it hidden takes the
    // instance off the compositor entirely: under -j8 the test runner spins up
    // 8 vsynced visible windows on one Wayland compositor, and the resulting
    // Mesa/EGL/compositor lock contention occasionally parks one instance's
    // main thread forever in SDL_GL_SwapWindow (HTTP thread alive, main loop
    // dead ⇒ the worker hangs). HIDDEN + vsync-off (below) removes that.
    // --visible overrides the headless hide so a driven --test session is
    // watchable; without it --test stays hidden (parallel-runner default).
    auto visFlag = (command.g_testMode && !visibleTest)
        ? SDL_WINDOW_HIDDEN : SDL_WINDOW_SHOWN;
    SDL_Window* window = SDL_CreateWindow(
        "Vibe3d",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, winW, winH,
        SDL_WINDOW_OPENGL | visFlag | SDL_WINDOW_RESIZABLE
    );
    if (!window) { writefln("SDL_CreateWindow: %s", SDL_GetError()); return; }
    scope(exit) SDL_DestroyWindow(window);
    // Persist preferences at clean shutdown. Registered AFTER the
    // SDL_DestroyWindow guard so LIFO runs this FIRST — the window is still
    // alive, so SDL_GetWindowSize returns the live size. Crash paths skip
    // scope(exit) entirely and simply don't save (clean-shutdown-only, like
    // imgui.ini). lastDir / recentFiles / toolDefaults are already in g_prefs.
    // Captures the live window size into g_prefs and writes the file. A try/
    // catch cannot sit lexically inside a scope(exit), so the body lives in
    // this nested function that the guard below merely calls.
    void persistPrefsOnExit() {
        int sw, sh;
        SDL_GetWindowSize(window, &sw, &sh);
        if (sw > 0 && sh > 0) { g_prefs.window.w = sw; g_prefs.window.h = sh; }
        try savePrefs();
        catch (Exception e) logWarn("prefs", "could not write prefs.json: " ~ e.msg);
    }
    if (prefsActive) scope(exit) persistPrefsOnExit();
    setWindowIcon(window);

    version (OSX) {
        // Make the app appear in the Dock and Command-Tab switcher when launched from terminal.
        // Use metaclass interface + objc_getClass instead of static interface methods:
        // LDC2 dispatches static ObjC interface calls to the Protocol object, not the class.
        NSApplication app = objc_getClass("NSApplication").sharedApplication();
        app.setActivationPolicy(0); // NSApplicationActivationPolicyRegular
        app.activateIgnoringOtherApps(true);
    }

    SDL_GLContext ctx = SDL_GL_CreateContext(window);
    if (!ctx) { writefln("SDL_GL_CreateContext: %s", SDL_GetError()); return; }
    scope(exit) SDL_GL_DeleteContext(ctx);

    if (loadOpenGL() < glSupport) { writeln("Failed to load OpenGL 3.3"); return; }
    writefln("OpenGL: %s", glGetString(GL_VERSION));

    // Framebuffer size (may differ on HiDPI / Retina)
    int fbW, fbH;
    SDL_GL_GetDrawableSize(window, &fbW, &fbH);

    // --perf disables vsync so the benchmark isn't capped at the display
    // refresh rate; --test disables it too so a hidden test window never blocks
    // in SwapWindow waiting on a compositor vblank it isn't even presenting to
    // (the -j8 swap-park hang). Normal runs keep vsync on to avoid tearing.
    // A --visible test session keeps vsync ON so the watched frames pace to the
    // display and the loop doesn't busy-spin; hidden --test stays vsync-off.
    SDL_GL_SetSwapInterval((perfMode || (command.g_testMode && !visibleTest)) ? 0 : 1);
    glEnable(GL_DEPTH_TEST);
    glViewport(0, 0, fbW, fbH);

    // ImGui
    IMGUI_CHECKVERSION();
    ImGui.CreateContext();
    ImGuiIO* io = &ImGui.GetIO();
    io.ConfigFlags |= ImGuiConfigFlags.NavEnableKeyboard;
    io.ConfigFlags |= ImGuiConfigFlags.DockingEnable;  // Phase 0b
    // In --test mode, disable ImGui's on-disk layout persistence. The .ini
    // is written relative to the current working directory, and each parallel
    // test worker runs in its own scratch cwd — so without this every worker
    // would load a different (or fresh) panel layout, making synthetic mouse
    // drags over the viewport non-deterministic (a drag can cross a panel that
    // is present in one worker's layout and absent in another's, where ImGui
    // would capture it). Setting IniFilename = null before the first NewFrame
    // means windows always open at their programmatic default positions,
    // independent of cwd. Must run before any window is created/loaded.
    // Layout ini: versioned file in the user config dir for interactive
    // sessions; strictly null in --test regardless of VIBE3D_CONFIG_DIR
    // (that env var gates prefs, but ini must stay null for byte-identity
    // across parallel workers). g_layoutIniPathZ keeps the char* alive for
    // the full lifetime of the ImGui context (ImGui stores the raw pointer).
    if (command.g_testMode) {
        io.IniFilename = null;
    } else {
        import prefs : prefsDir, layoutIniPath, kLayoutIniVersion;
        import std.string : toStringz;
        auto iniDir = prefsDir();
        bool iniDirOk = false;
        try { import std.file : mkdirRecurse; mkdirRecurse(iniDir); iniDirOk = true; }
        catch (Exception) {}
        if (iniDirOk) {
            string userIniPath = layoutIniPath(iniDir, kLayoutIniVersion);
            // Task 0211 seed-guard primary discriminator (see g_seedFreshLayout
            // doc comment): evaluated BEFORE io.IniFilename is assigned below,
            // so this reads whether ImGui is *about to* restore a tree this
            // session, not whether it already has.
            {
                import std.file : exists;
                g_seedFreshLayout = !exists(userIniPath);
            }
            // First-run seed: the user confirmed this arrangement
            // (config/default_layout.ini) as the shipped default, so a
            // fresh profile opens with it instead of ImGui's bare
            // programmatic seed. Non-destructive — only fires when the
            // user has no layout ini of their own yet at this path.
            seedDefaultLayoutIfMissing(userIniPath);
            g_layoutIniPathZ = userIniPath.toStringz;
            io.IniFilename   = g_layoutIniPathZ;
            // MINOR 4: sweep old-version ini files (best-effort, non-fatal).
            try {
                import std.file : dirEntries, SpanMode, remove;
                import std.path : baseName;
                string keepBase = baseName(layoutIniPath(iniDir, kLayoutIniVersion));
                foreach (e; dirEntries(iniDir, "imgui_layout_v*.ini", SpanMode.shallow))
                    if (baseName(e.name) != keepBase)
                        try { remove(e.name); } catch (Exception) {}
            } catch (Exception) {}
        } else {
            // No writable config dir → nothing will ever be restored this
            // session, same as a genuinely fresh start.
            g_seedFreshLayout = true;
            io.IniFilename = null;
        }
    }
    // UI font: Inter (embedded vector TTF, SIL OFL — see assets/fonts/) at
    // 14px × uiScale with Cyrillic coverage. Replaces ImGui's built-in 13px
    // bitmap font, which cannot scale fractionally without blurring.
    // --test keeps the built-in font and scale 1.0 so widget metrics (and
    // therefore recorded-event hit positions) stay identical across hosts.
    if (!command.g_testMode) {
        static immutable ubyte[] interTtf =
            cast(immutable ubyte[]) import("Inter-Regular.ttf");
        // FontDataOwnedByAtlas=false: the atlas memcpy's the TTF into its
        // own IM_ALLOC buffer and frees THAT. With the default (true) it
        // would IM_FREE (libc free) the slice we pass — a static array
        // here — corrupting the heap ("free(): invalid size").
        ImFontConfig fontCfg = ImFontConfig(false);
        fontCfg.FontDataOwnedByAtlas = false;
        version (OSX) {
            static immutable ImWchar[] macGlyphRanges = [
                0x0020, 0x00FF, // Basic Latin + Latin Supplement
                0x0400, 0x052F, // Cyrillic + Cyrillic Supplement
                0x2DE0, 0x2DFF, // Cyrillic Extended-A
                0xA640, 0xA69F, // Cyrillic Extended-B
                0x2018, 0x2026, // General Punctuation: smart quotes, • bullet, … ellipsis
                0x2039, 0x203A, // ‹ › single angle quotes (popup-button chevron)
                0x21E7, 0x21E7, // Shift: ⇧
                0x2303, 0x2303, // Control: ⌃
                0x2318, 0x2318, // Command: ⌘
                0x2325, 0x2325, // Option: ⌥
                0,
            ];
            const(ImWchar)* glyphRanges = macGlyphRanges.ptr;
        } else {
            // GetGlyphRangesCyrillic() covers only Latin + Cyrillic, so the
            // General-Punctuation glyphs the UI relies on (… ellipsis in
            // "Open…"/"LWO…" labels, › chevron in "Import ›"/"Export ›") never
            // got rasterized and showed blank. Spell out a custom range that
            // mirrors Cyrillic + the punctuation we actually use. Must persist
            // until the atlas is built — hence `static immutable`.
            static immutable ImWchar[] glyphRangesData = [
                0x0020, 0x00FF, // Basic Latin + Latin-1 Supplement (incl. »)
                0x0400, 0x044F, // Cyrillic
                0x0450, 0x045F, // Cyrillic Supplement (common subset)
                0x2DE0, 0x2DFF, // Cyrillic Extended-A
                0xA640, 0xA69F, // Cyrillic Extended-B
                0x2018, 0x2026, // General Punctuation: smart quotes, • bullet, … ellipsis
                0x2039, 0x203A, // ‹ › single angle quotes (popup-button chevron)
                0,
            ];
            const(ImWchar)* glyphRanges = glyphRangesData.ptr;
        }
        io.Fonts.AddFontFromMemoryTTF(cast(ubyte[]) interTtf, 14.0f * uiScale,
                                      &fontCfg, glyphRanges);
        ImGui.GetStyle().ScaleAllSizes(uiScale);
    }
    ImGui.StyleColorsDark();
    // Grey dock-node border/separator override. StyleColorsDark() ships a
    // translucent grey ImGuiCol.Border/Separator; chromed panels already push
    // their own black Border (pushPanelChromeStyle, popped on End), but the
    // DockSpace host and dock-node split handles are never chrome-wrapped, so
    // the dark-style grey shows through as an outline around panels / dock
    // separators. This binding's ImGuiStyle (d_imgui/imgui_h.d) exposes no
    // `Colors[]` array accessor (only ItemSpacing + ScaleAllSizes are bound),
    // so `style.Colors[ImGuiCol.Border] = ...` is not callable here — instead
    // push these colors once, right after StyleColorsDark(), and never pop:
    // an unmatched PushStyleColor simply remains the top of that color's
    // stack for the rest of the context's life, which is functionally a
    // permanent style override (DestroyContext discards the stack on exit).
    // Color-only ⇒ no effect on item rects/picking ⇒ --test-neutral.
    {
        ImVec4 black = ImVec4(0.0f, 0.0f, 0.0f, 1.0f);
        ImGui.PushStyleColor(ImGuiCol.Border,            black);
        // NB: BorderShadow is left at its transparent (alpha 0) default —
        // forcing it opaque black would ADD a window-outer shadow (cimgui
        // only draws the shadow when its alpha > 0), the opposite of intent.
        ImGui.PushStyleColor(ImGuiCol.Separator,         black);
        ImGui.PushStyleColor(ImGuiCol.SeparatorHovered,  black);
        ImGui.PushStyleColor(ImGuiCol.SeparatorActive,   black);
        ImGui.PushStyleColor(ImGuiCol.DockingEmptyBg,    black);
        // Dock-tab palette. The dock tab bar renders while the visible panel's
        // chrome push (pushPanelChromeStyle) is active, so tab LABELS inherit
        // that black Text — StyleColorsDark's near-black default tab fills then
        // give black-on-near-black, i.e. unreadable inactive labels. Black text
        // needs LIGHT fills, which also matches our panel scheme (medium-grey
        // panels + black text + beige buttons + a muted, desaturated accent —
        // not the stock saturated blue). So: inactive tabs = neutral mid-greys a
        // step below the panel bg (0.561); the active tab = a light muted
        // steel-blue accent, distinguished from the greys by HUE (not just
        // luminance) so active-vs-inactive is unambiguous while black labels
        // stay readable on every state. Dimmed = the panel-unfocused variants.
        ImVec4 tabInactive        = ImVec4(0.500f, 0.500f, 0.510f, 1.0f); // (128,128,130)
        ImVec4 tabInactiveDim     = ImVec4(0.455f, 0.455f, 0.465f, 1.0f); // (116,116,119)
        ImVec4 tabAccent          = ImVec4(0.510f, 0.635f, 0.804f, 1.0f); // (130,162,205)
        ImVec4 tabAccentDim       = ImVec4(0.439f, 0.549f, 0.698f, 1.0f); // (112,140,178)
        ImVec4 tabHover           = ImVec4(0.612f, 0.718f, 0.851f, 1.0f); // (156,183,217)
        ImVec4 tabOverline        = ImVec4(0.694f, 0.792f, 0.925f, 1.0f); // (177,202,236)
        ImVec4 tabOverlineDim     = ImVec4(0.545f, 0.545f, 0.557f, 1.0f); // (139,139,142)
        ImGui.PushStyleColor(ImGuiCol.Tab,                       tabInactive);
        ImGui.PushStyleColor(ImGuiCol.TabHovered,               tabHover);
        ImGui.PushStyleColor(ImGuiCol.TabSelected,              tabAccent);
        ImGui.PushStyleColor(ImGuiCol.TabSelectedOverline,      tabOverline);
        ImGui.PushStyleColor(ImGuiCol.TabDimmed,                tabInactiveDim);
        ImGui.PushStyleColor(ImGuiCol.TabDimmedSelected,        tabAccentDim);
        ImGui.PushStyleColor(ImGuiCol.TabDimmedSelectedOverline, tabOverlineDim);
    }
    ImGui_ImplSDL2_Init(window);
    ImGui_ImplOpenGL3_Init("#version 330 core");
    scope(exit) {
        ImGui_ImplOpenGL3_Shutdown();
        ImGui_ImplSDL2_Shutdown();
        ImGui.DestroyContext();
    }
    version (WithRender) initIPR();        // register IPR's change-bus subscriber (once)
    version (WithRender) scope(exit) shutdownIPR();

    Shader shader = new Shader();
    LitShader litShader = new LitShader();

    GLuint thickLineProgram = createProgramWithGeom(vertexShaderSrc, thickLineGeomSrc, fragmentShaderSrc);
    scope(exit) glDeleteProgram(thickLineProgram);
    initThickLineProgram(thickLineProgram, fbW, fbH);

    // Translucent-fill program (flat u_color at u_alpha) — backs
    // handler.drawWorldQuad, used by the Slice tool's cut-plane overlay. No
    // screen-size dependency, so it needs no per-resize re-init.
    GLuint fillProgram = createProgram(vertexShaderSrc, fillFragSrc);
    scope(exit) glDeleteProgram(fillProgram);
    initFillProgram(fillProgram);

    CheckerShader checkerShader = new CheckerShader();
    GridShader gridShader = new GridShader();

    // Stage 0b — the global mesh becomes the active layer of a Document.
    // `mesh` is now a nested accessor returning the active layer's mesh by
    // reference, so D's optional parens keep the ~359 `mesh.` uses compiling
    // unchanged while re-resolving to the active layer on every use. Every
    // `&mesh` capture became `&mesh()` (the address of the ref return, bound at
    // fire time) — see the seam conversions below. Exactly ONE layer ever
    // exists in 0b (no layer.* commands until Stage 2), so this is provably
    // byte-neutral with the prior global mesh.
    import document : Document;
    Document document = Document.bootstrap(makeCube());
    ref Mesh mesh() { return document.activeMeshRef(); }
    writefln("Mesh: %d verts, %d edges, %d faces",
             mesh.vertices.length, mesh.edges.length, mesh.faces.length);

    // Seam 2b — install the display-refresh resolver. Every mutating
    // command's apply()/revert() routes its GPU upload + cache refresh
    // through display_sync.refreshDisplay, which no-ops when the command's
    // target mesh is not the one on screen. In Stage 0a there is exactly one
    // mesh, so this resolver always matches the target ⇒ provably neutral.
    // Stage 0b: `&mesh()` resolves to the active layer's mesh — identical to
    // `document.activeMesh()` since the accessor returns `activeMeshRef()`.
    import display_sync : activeMeshResolver;
    activeMeshResolver = () => &mesh();

    // Bulk transition (change-notification bus, Stage 1): launching a recorded
    // session (`--playback <file>`) is a fresh-scene boundary — note All once so
    // the first frame's flush rebuilds every cache from the loaded state. (The
    // replayed events themselves emit their own per-op classes afterward.) The
    // HTTP /api/play-events test driver deliberately does NOT do this, so a
    // replayed drag there stays Position-only.
    if (playbackMode) {
        import change_bus : MeshChangeAll;
        mesh.noteChange(MeshChangeAll);
    }

    // Subpatch preview: cached subdivision of the cage mesh, rebuilt lazily
    // when mesh.mutationVersion or depth changes. Depth is user-adjustable;
    // 3 is the default. Consumed by rendering and picking in
    // subsequent steps.
    SubpatchPreview subpatchPreview;
    int             subpatchDepth = 3;

    // BVH face picker (Phase 7). One BVH per active mesh, keyed on
    // (gpu.uploadVersion, source-mesh-address) — the same tuple
    // gpu_select.d:31 uses. Default ON; VIBE3D_FACE_PICK=gpu falls back to
    // the GPU face re-render (oracle for A/B equivalence testing).
    BvhPick bvhPick = new BvhPick();
    bool useBvhFacePick;
    {
        import std.process : environment;
        // Read once at startup; runtime changes need a relaunch.
        useBvhFacePick = environment.get("VIBE3D_FACE_PICK", "bvh") != "gpu";
    }

    // Tracks what is currently uploaded to the GPU so the main loop can
    // re-upload when the preview toggles on/off or when the cage changes
    // while the preview is active.
    ulong gpuUploadedVersion = ulong.max;
    bool  gpuUploadedPreview;
    // Source topologyVersion of the last FULL preview upload. When this
    // matches the current preview's source topology, the preview mesh
    // layout (#faces, fan order, edge / vert filter mask) is identical
    // to what's already on the GPU — only positions changed, so we can
    // scatter-update via glMapBuffer instead of rebuilding the
    // ~50 MB faceData/edgeData/vertData arrays from scratch on every
    // drag frame. `ulong.max` ⇒ no preview uploaded yet, force full.
    ulong gpuUploadedPreviewTopVersion = ulong.max;

    Layout layout;
    layout.resize(winW, winH);

    // The editor uses a fixed fovY=45° everywhere (see source/view.d).
    enum float kFovY = 45.0f * 3.14159265358979f / 180.0f;

    // Now that the viewport is known, attach metadata to the always-on log
    // so it stays layout/aspect-independent on replay, and tell the player
    // what the current viewport looks like.
    if (evLog.active)
        evLog.writeViewportMeta(layout.vpX, layout.vpY, layout.vpW, layout.vpH, kFovY);
    setReplayCurrentViewport(layout.vpX, layout.vpY, layout.vpW, layout.vpH, kFovY);

    // Phase 1 — camera / ViewCache / picking go global → per-viewport via
    // ViewportManager (source/viewport.d).  Exactly ONE viewport in Phase 1;
    // behaviour is byte-identical to the prior globals.
    //
    // Nested ref-returning accessors keep all ~190 command-ctor injection sites,
    // camera-member uses, and cache-method calls textually unchanged.  The only
    // mandatory edits are the ~318 address-of sites (&x → &x()); see
    // doc/viewport_phase1_plan.md §A.  gpuSelect has 0 address-of sites (class
    // ref) and needs only the init/shutdown ownership edits below.
    import viewport : ViewportManager, Viewport3D, DirtyKey;
    auto vpm = new ViewportManager(layout.vpX, layout.vpY, layout.vpW, layout.vpH);
    vpm.views[0].vcache.resize(mesh.vertices.length);
    vpm.views[0].fcache.resize(mesh.vertices.length, mesh.faces.length);
    vpm.views[0].ecache.resize(mesh.edges.length);

    // Re-apply the persisted viewport-cell preset UNCONDITIONALLY (even when
    // it is the default Single) so per-cell state (cellCount, cameras, GPU
    // select buffers, independence) matches g_prefs.viewportLayout.
    // applyLayout() also raises layoutDirty=true (viewport.d) — that flag
    // drives the frame-1 DockSpace host (app.d, below) to do a FULL ROOT
    // DockBuilderRemoveNode rebuild, which would discard the dock tree ImGui
    // just restored from the layout ini, including every saved dock-node
    // flag (HiddenTabBar) and the user's panel arrangement. At startup there
    // is nothing to reconcile the dock tree against — the ini (or, if there
    // is none yet, the frame-1 seed guard) is the sole source of it — so
    // immediately clear the trigger and trust what was loaded. Runtime
    // callers of applyLayout (the viewport.layout command) still want the
    // rebuild and are unaffected: they raise layoutDirty AFTER this point in
    // the frame. Interactive-only: --test keeps io.IniFilename == null (no
    // ini to load) and skips this call entirely, so test-mode dock geometry
    // is untouched.
    if (!testMode) {
        vpm.applyLayout(g_prefs.viewportLayout);
        vpm.layoutDirty = false;
        // Task 0223: restore the persisted cross-splitter ratios. prefs.d's
        // loadPrefs() already clamped these to [0.05, 0.95], so no further
        // validation is needed here.
        vpm.hRatio = g_prefs.hRatio;
        vpm.vRatio = g_prefs.vRatio;
    }

    // Nested accessors — ref-returning so member-mutation, ref-param, and
    // address-of (&x()) all bind against the ACTIVE viewport's live fields.
    // `cameraView`/`vertexCache`/`faceCache`/`edgeCache` stay textually
    // unchanged at call sites (D optional-parens, same pattern as `mesh`).
    // `gpuSelect` returns the class handle (no ref needed for class types).
    // (V7: the `activeCamera`/`hoveredCamera`/`activeIsOrtho` wrappers that
    // used to live here were deleted — they duplicated `vpm.activeCamera()`/
    // `vpm.hoveredCamera()`/`vpm.originIsOrtho()` with no remaining callers
    // of their own; call the `ViewportManager` methods directly instead.)
    ref View cameraView() { return vpm.views[vpm.activeId].camera; }
    ref VertexCache vertexCache() { return vpm.views[vpm.activeId].vcache; }
    ref FaceBoundsCache faceCache() { return vpm.views[vpm.activeId].fcache; }
    ref EdgeCache edgeCache() { return vpm.views[vpm.activeId].ecache; }
    // gpuSelect: class reference — callers use it as gpuSelect.pick(...) etc.
    // (optional-parens applies; 0 address-of sites so no &gpuSelect() edits needed).
    auto gpuSelect() { return vpm.views[vpm.activeId].gpuSel; }

    // Phase 2 — input seam.  `g_viewportWindowHovered` is set each frame
    // by the "Viewport" ImGui window's IsWindowHovered() result.  The seam
    // function replaces the scattered `!io.WantCaptureMouse` reads so a
    // single flag controls whether 3D input reaches the picking / camera
    // orbit code.  In --test: byte-identical to the prior per-site checks.
    bool g_viewportWindowHovered = false;
    bool viewportInputAllowed() {
        if (testMode) return !io.WantCaptureMouse;
        return g_viewportWindowHovered;
    }

    // Change-notification bus, Stage 2 — pick-cache subscriber state.
    //
    // `meshChangedFlags` accumulates the change classes the bus delivers
    // THIS frame. The subscriber below (registered once at startup) ORs the
    // flushed flags into it; the per-frame pick-cache invalidation block (down
    // in the render loop, immediately after `changeBus.flush`) reads it, acts
    // on Position / Geometry, then zeroes it for the next frame. Because the
    // flush runs in the same frame just before that block (Design rule 2), the
    // flag reflects exactly this frame's mesh mutations — replacing the old
    // "invalidate every frame a tool is active" blanket sweep with precision.
    //
    // The subscriber is invalidate-only by the bus contract: it sets a flag
    // and touches NOTHING else (no mesh read/mutate, no cache call). All the
    // resize / invalidate / syncSelection work happens later on the main
    // thread in the flag-driven block, never inside delivery.
    uint meshChangedFlags = 0;
    // Change-notification bus, Stage 5 — selection subscriber state.
    //
    // `selChangedDomains` accumulates the selection domains (Vertex / Edge /
    // Face bits) the bus delivers THIS frame. The selection consumer below ORs
    // the flushed domains into it; the per-frame consume site (down in the
    // render loop, alongside the pick-cache block) reads it and zeroes it.
    //
    // Today the selection highlight is drawn live every frame straight from the
    // mesh marks (gpu.drawVertices/drawEdges read `mesh.selectedVertices` etc.
    // each frame), and the screen-space pick caches key off GEOMETRY, not
    // selection — so no concrete cache needs a selection-driven refresh right
    // now. The consumer is therefore wired but minimal: it parks the domains in
    // a frame-local flag, establishing the single selection-consumer seam the
    // future layer panel (the plan's named future consumer) plugs into without
    // inventing UI work now. The bus contract still holds (invalidate-only: the
    // delegate touches nothing but the flag).
    uint selChangedDomains = 0;
    // Phase 2 — persistent selection epoch for the FBO dirty-cache. Selection
    // is a Marks-class change that deliberately does NOT bump mesh.mutationVersion
    // (see mesh.d), and plain click-select / select-all / clear happen with NO
    // active tool and NO drag, so they escape the DirtyKey's meshMutVer + the
    // forceActive gate. Bumping a persistent counter here (never zeroed, unlike
    // selChangedDomains at the consume site) lets the dirty check detect any
    // selection change and re-render. Fires only on real selection flushes.
    ulong fboSelEpoch = 0;
    {
        import change_bus : changeBus;
        changeBus.onMeshChanged((uint flags) { meshChangedFlags |= flags; });
        changeBus.onSelectionChanged((uint domains) {
            selChangedDomains |= domains;
            ++fboSelEpoch;
        });
    }

    // VisibilityCache (`mesh.visibleVertices`) is no longer used — the
    // lasso path that consumed it switched to `gpuSelect.elementVisibility`
    // (see `doc/lasso_gpu_pick_buffer_fix.md`). The CPU
    // `Mesh.visibleVertices` implementation in `source/mesh.d` and the
    // `VisibilityCache` wrapper in `source/visibility_cache.d` stay
    // around — they're still useful for headless / non-GL test paths
    // and are tested directly by their inline unittests — but the live
    // lasso path no longer hits them.

    GpuMesh gpu;
    gpu.init();
    scope(exit) gpu.destroy();
    gpu.upload(mesh);

    // Seam 3 (task 0413, campaign 0407 §A.D4-b) — install the display-
    // TARGET resolver, the gpu/cache counterpart to the `activeMeshResolver`
    // installed above. Every migrated mesh-command's apply()/revert() calls
    // `display_sync.refreshDisplayActive(mesh)` instead of carrying its own
    // GpuMesh*/VertexCache*/EdgeCache*/FaceBoundsCache* fields; this
    // resolver is what supplies those targets, resolved fresh on every
    // call. Must be installed here (not alongside `activeMeshResolver`
    // above) because `gpu`/`vertexCache()`/`edgeCache()`/`faceCache()` don't
    // exist yet at that earlier point — `vertexCache()`/`edgeCache()`/
    // `faceCache()` resolve to `vpm.views[vpm.activeId].{vcache,ecache,fcache}`
    // (declared above), so re-evaluating them on every call — rather than
    // capturing `&vertexCache()` once the way the old per-command ctor
    // wiring did — is exactly the bonus-fix: an undo/redo delivered after
    // the user switches the active viewport cell now refreshes the cell
    // that is ACTUALLY active at refresh time, not the one that was active
    // when the command happened to be constructed.
    import display_sync : displayTargetsResolver, DisplayTargets;
    displayTargetsResolver = () => DisplayTargets(
        &gpu, &vertexCache(), &edgeCache(), &faceCache());

    // Layers Stage 5 — background-layer GPU buffers. A side map (NOT a field on
    // Layer: document.d stays GL-free and the render boundary stays clean)
    // keyed by the Layer object. Each entry caches the layer's last uploaded
    // `mesh.mutationVersion` so a visible-immutable background layer uploads at
    // most once until it actually changes. Entries for layers that are no
    // longer visible-background (hidden, made active/foreground, or deleted) are
    // destroyed + dropped each frame so GL handles never leak. In a single-layer
    // document this map is always empty ⇒ zero per-frame cost.
    import document : Layer;
    // BgGpu relocated to editor_app.d (task 0419 Б2 -- the UI-panel block's
    // renderViewportSceneToFbo, now in source/ui/panels.d, needs the type
    // nameable for a ctx field; see editor_app.d for the exact-analog-of-
    // Ai3dModalState rationale).
    import editor_app : BgGpu;
    BgGpu*[Layer] bgGpuByLayer;
    scope(exit) {
        foreach (k, bg; bgGpuByLayer) bg.gpu.destroy();
    }

    // Offscreen ID-buffer picker shared by pickVertices / pickEdges /
    // pickFaces. Heuristic-visibility tests rejected elements the user
    // could clearly see; GPU per-pixel depth-test sidesteps that.
    // See source/gpu_select.d.
    import gpu_select : GpuSelectBuffer, SelectMode;
    // Phase 1 — GL lifecycle for the per-viewport GPU-select picker is
    // managed by ViewportManager.  vpm.initGpu() replaces the old
    // `new GpuSelectBuffer(); .init()` pair; vpm.shutdown() replaces
    // `scope(exit) gpuSelect.destroy()`.
    vpm.initGpu();
    scope(exit) vpm.shutdown();

    // One-shot validation that the OSD GL evaluator works on this
    // host's GL driver. Production paths still drive subpatch through
    // the CPU evaluator (the GPU path is wired but not consumed yet —
    // see doc/osd_gpu_evaluator_phase3.md); this log line gives us a
    // canary that the Phase 2 plumbing is sound before we depend on
    // it.
    {
        import subpatch_osd : runGlEvaluatorSmokeTest, g_osdGpuEnabled;
        immutable float delta = runGlEvaluatorSmokeTest();
        // Sub-mm match against CPU eval → the GPU stencil kernel
        // works on this host's GL driver; enable it for production
        // subpatch refresh.
        if (delta >= 0.0f && delta < 1e-3f)
            g_osdGpuEnabled = true;
    }

    // Grid: lines on XZ plane + axis lines
    GLuint gridVao, gridVbo;
    int    gridOnlyVertCount; // vertex count of plain grid lines (before axes)
    glGenVertexArrays(1, &gridVao);
    glGenBuffers(1, &gridVbo);
    scope(exit) { glDeleteVertexArrays(1, &gridVao); glDeleteBuffers(1, &gridVbo); }
    {
        immutable int   N = 50;   // grid half-extent in cells
        immutable float F = cast(float)N;
        float[] verts;

        // Lines parallel to X axis (constant Z), skip Z=0 (that's the X axis)
        foreach (z; -N .. N + 1) {
            if (z == 0) continue;
            float fz = cast(float)z;
            verts ~= [-F, 0, fz,   F, 0, fz];
        }
        foreach (x; -N .. N + 1) {
        // Lines parallel to Z axis (constant X), skip X=0 (that's the Z axis)
            if (x == 0) continue;
            float fx = cast(float)x;
            verts ~= [fx, 0, -F,   fx, 0,  F];
        }
        gridOnlyVertCount = cast(int)(verts.length / 3);

        // Axis lines appended last so they draw on top
        verts ~= [-F, 0, 0,   F, 0, 0];   // X axis
        verts ~= [ 0, 0,-F,   0, 0,  F];  // Z axis

        glBindVertexArray(gridVao);
        glBindBuffer(GL_ARRAY_BUFFER, gridVbo);
        glBufferData(GL_ARRAY_BUFFER, verts.length * float.sizeof, verts.ptr, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3*float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);
        glBindVertexArray(0);
    }

    // Selection state
    int hoveredVertex = -1;
    int hoveredEdge   = -1;
    int hoveredFace   = -1;
    mesh.resetSelection();

    // Cache: face→edge mask for Polygons mode edge highlighting.
    // Rebuilt only when selectedFaces changes (comparison is a fast memcmp).
    bool[] faceSelEdgesCache;
    bool[] faceSelEdgesPrevSel;  // snapshot of selectedFaces at last rebuild

    // Cache: edge-loop hover mask for ElementMove + falloff EdgeLoops.
    // Hovering an edge pre-highlights the whole loop ring (mirrors the apply,
    // which expands a picked edge to its loop). The loop WALK (edgeLoopRing +
    // the ring→edge-index map) is expensive, so recompute ONLY when the hovered
    // edge or the mesh topology changes — never per frame.
    bool[] loopHoverEdgesCache;
    int    loopHoverPrevEdge = -2;        // hoveredEdge at last rebuild (-2 = never)
    ulong  loopHoverPrevTopo = ulong.max; // mesh.topologyVersion at last rebuild
    bool   loopHoverPrevSlice = false;    // ring KIND at last rebuild (slice vs edge-loop)

    DragMode dragMode = DragMode.None;
    // `editMode` is a MATERIALIZED VIEW of `selTypeOrder.mostRecentGeometry`.
    // It is written by exactly ONE path — `setEditModeFromOrder()` below —
    // called from the geometry-type funnel (`switchGeometryType` /
    // `promoteGeometryType`). No command or handler writes this field
    // independently of the order. A debug-only invariant on the `/api/selection`
    // read boundary asserts it equals `derivedEditMode()` as a regression guard.
    EditMode editMode = EditMode.Vertices;
    // Selection-types Stage 1: the most-recent-first ordering of selection types
    // is the "current type" authority. `editMode` stays the picking/draw
    // authority and mirrors the current GEOMETRY type (it persists under Item).
    // Item is never made current in Stage 1 — the ordering only ever holds a
    // geometry type at the front here.
    SelTypeOrder selTypeOrder;
    int activePanelIdx = 0;

    // RMB path trail
    bool    rmbDragging = false;
    ImVec2[] rmbPath;

    // Phase C.x: interactive selection edit session. handleMouseButtonDown
    // captures the selection-snapshot before any picking/lasso/clear happens;
    // handleMouseButtonUp captures after, builds a MeshSelectionEdit, and
    // records on history if anything actually changed.
    SelectionSnapshot pendingSelBefore;
    EditMode          pendingSelBeforeMode;
    bool              pendingSelOpen = false;

    // Gizmo size in screen pixels: 9 levels — clustered around the
    // default (90 px) and stretched upward for users who prefer a larger
    // hit area. Independent of viewport height.
    enum float[9] gizmoLevels = [50.0f, 70.0f, 90.0f, 120.0f, 160.0f,
                                  220.0f, 290.0f, 380.0f, 480.0f];
    int gizmoLevelIdx = 2;  // = 90 px default

    Tool   activeTool   = null;
    string activeToolId = "";

    scope(exit) {
        if (activeTool) { activeTool.deactivate(); activeTool.destroy(); }
    }
    // Reset toolpipe stages whose state is TOOL-DRIVEN: ACEN, AXIS,
    // WGHT. Each preset configures them on activation (preActivate
    // hook); without an explicit reset on deactivate / switch, the
    // previous preset's settings leak into the next tool. SNAP /
    // SYMM / WORK are USER-driven globals (controlled via status-
    // bar toolbars) and stay across tool changes.
    //
    // Called from setActiveTool(null) (Space, tool.set X off) and
    // from activateToolById BEFORE preActivate fires for the new
    // preset — so the new preset's pipe attrs land on freshly
    // reset stages.
    // True when at least one falloff (WGHT) stage is active (type != None, so
    // its params() are non-empty). Used to show the Falloff section in Tool
    // Properties AND draw the falloff overlay in the viewport even when NO
    // transform tool is selected — a user-locked falloff persists across tool
    // switches (resetTransient), so it should stay visible/editable on its own.
    bool anyFalloffActive() {
        import toolpipe.pipeline       : g_pipeCtx;
        import toolpipe.stage          : TaskCode;
        import toolpipe.stages.falloff : FalloffStage;
        if (g_pipeCtx is null) return false;
        foreach (s; g_pipeCtx.pipeline.findAllByTask(TaskCode.Wght))
            if (auto fo = cast(FalloffStage) s)
                if (fo.enabled && fo.isActive())   // type != None; alloc-free
                    return true;
        return false;
    }

    // ElementMove + falloff EdgeLoops: build the cage-edge mask for the whole
    // loop ring through the hovered edge, so the renderer can pre-highlight the
    // loop in the hover colour (matching the apply, which expands a picked edge
    // to its loop). CACHED: the loop walk (edgeLoopRing + ring→edge lookup)
    // only re-runs when `hoveredEdge` or the mesh topology changes — never per
    // frame. Returns a cage-indexed bool[] (length == mesh.edges.length); on a
    // valence-3 / boundary / non-quad edge `edgeLoopRing` falls back to the
    // seed edge, so the mask just lights the single hovered edge.
    const(bool)[] rebuildLoopHoverMask(int hovEdge) {
        // `sliceRing`: highlight the ring the loop-SLICE lands on (seed +
        // quad-ring exit rails) instead of the classic edge LOOP. Those run
        // perpendicular, so the Loop Slice tool needs this or the highlighted
        // ring won't match the cut (task 0231). Part of the cache key: two
        // tools can share hovEdge + topology yet want different rings.
        bool sliceRing = activeTool !is null && activeTool.edgeLoopHoverSliceRing();

        if (loopHoverPrevEdge == hovEdge
            && loopHoverPrevTopo == mesh.topologyVersion
            && loopHoverPrevSlice == sliceRing
            && loopHoverEdgesCache.length == mesh.edges.length)
            return loopHoverEdgesCache;   // cache hit — no walk

        loopHoverPrevEdge = hovEdge;
        loopHoverPrevTopo = mesh.topologyVersion;
        loopHoverPrevSlice = sliceRing;
        if (loopHoverEdgesCache.length != mesh.edges.length)
            loopHoverEdgesCache = new bool[](mesh.edges.length);
        loopHoverEdgesCache[] = false;

        if (hovEdge < 0 || hovEdge >= cast(int)mesh.edges.length)
            return loopHoverEdgesCache;

        if (sliceRing) {
            // The exact set of cage edges the cut splits — directly indexed.
            foreach (ei; mesh.loopSliceRingEdges(cast(uint)hovEdge))
                if (ei >= 0 && ei < cast(int)loopHoverEdgesCache.length)
                    loopHoverEdgesCache[ei] = true;
            return loopHoverEdgesCache;
        }

        auto seed = mesh.edges[hovEdge];
        uint[] ring = edgeLoopRing(mesh, seed[0], seed[1]);
        if (ring.length < 2) return loopHoverEdgesCache;

        // Map each consecutive ring vert pair (CLOSED: last→first too) back to
        // its cage edge index via the mesh's edgeIndexMap (keyed by edgeKey).
        // A 2-vert fallback ring closes onto itself → only the single edge.
        foreach (i; 0 .. ring.length) {
            uint a = ring[i];
            uint b = ring[(i + 1) % ring.length];
            if (a == b) continue;
            if (auto p = edgeKey(a, b) in mesh.edgeIndexMap) {
                uint ei = *p;
                if (ei < loopHoverEdgesCache.length)
                    loopHoverEdgesCache[ei] = true;
            }
        }
        return loopHoverEdgesCache;
    }

    void resetTransientPipeStages() {
        import toolpipe.pipeline             : g_pipeCtx;
        import toolpipe.stage                : TaskCode;
        import toolpipe.stages.actcenter     : ActionCenterStage;
        import toolpipe.stages.axis          : AxisStage;
        import toolpipe.stages.falloff       : FalloffStage;
        if (g_pipeCtx is null) return;
        foreach (s; g_pipeCtx.pipeline.allMut()) {
            // Every WGHT-task stage (the primary "falloff" AND any stacked
            // "falloff#N" extras) resets the same way: a user-selected
            // falloff (userLocked) survives a tool switch — reference parity
            // (captured 2026-06-16). Keyed by task, not by the literal id,
            // so stacked extras get the same treatment as the primary
            // instead of surviving by omission.
            if (s.taskCode() == TaskCode.Wght) {
                if (auto fo = cast(FalloffStage)s)
                    fo.resetTransient();
                else
                    s.reset();
                continue;
            }
            switch (s.id()) {
                case "actionCenter":
                    // Skip reset when the user explicitly set a mode via
                    // actr.* — userLocked survives tool switches.
                    if (auto ac = cast(ActionCenterStage)s)
                        ac.resetTransient();
                    else
                        s.reset();
                    break;
                case "axis":
                    if (auto ax = cast(AxisStage)s)
                        ax.resetTransient();
                    else
                        s.reset();
                    break;
                default: break;
            }
        }
    }

    // FULL pipe reset used only by a SCENE / DOCUMENT reset (/api/reset,
    // scene.reset, file.new). Unlike resetTransientPipeStages (which respects
    // userLocked so a user-set falloff / ACEN / AXIS survives a tool switch —
    // reference parity), this calls the unconditional reset() on EVERY stage,
    // clearing the userLocks too. A "Reset" UX promise is a clean slate, so a
    // prior session's locked falloff config must not bleed across the reset.
    // (SceneReset.apply already resets every stage before onResetTool fires;
    // this is the same guarantee made explicit at the onResetTool seam, so any
    // future reset path that only wires onResetTool still gets the clean slate.)
    void resetAllPipeStages() {
        import toolpipe.pipeline : g_pipeCtx;
        if (g_pipeCtx is null) return;
        foreach (s; g_pipeCtx.pipeline.allMut())
            s.reset();
    }

    // Sticky tool-option defaults: on a CLEAN tool drop (setActiveTool(null)
    // with a known preset id), snapshot the dropped tool's TOOL-LEVEL params
    // into g_prefs.toolDefaults[presetId], so the next activation of that
    // preset starts from the user's last-used settings (re-applied in the
    // preset factory, overriding the YAML). Captured here — before
    // deactivate()/destroy() invalidates the tool's param pointers — only at a
    // clean drop, never mid-gesture and never on crash (scope(exit)-free).
    // Pipe-stage attrs (falloff / acen) are session state and are NOT captured.
    void captureStickyToolDefaults() {
        if (!prefsActive) return;
        if (activeTool is null || activeToolId.length == 0) return;
        import params : stringifyParam, isStickyCapturable;
        string[string] attrs;
        foreach (ref p; activeTool.params()) {
            // Array kinds, read-only, and transient (gesture geometry /
            // momentary triggers) params are not remembered settings — see
            // `isStickyCapturable`.
            if (!isStickyCapturable(p)) continue;
            attrs[p.name] = stringifyParam(p);
        }
        if (attrs.length > 0) g_prefs.toolDefaults[activeToolId] = attrs;
    }

    // Falloff stage-gizmo refactor (steps 3-4): the single persistent
    // app-level owner of the toolpipe falloff gizmo + overlay (see
    // doc/falloff_stage_gizmo_refactor_plan.md). Constructed HERE, BEFORE
    // setActiveTool (so its one-shot cancelDrag below can reach it) and BEFORE
    // the XfrmTransformTool factory registrations further down (so each factory
    // closure can capture it and inject it via setPipeGizmoHost()). It also
    // stays in scope for the no-tool app.d event/draw closures and the
    // /api/reset handler (all later in main). GL is already valid (context +
    // shaders set up earlier in main), and the host's own GL alloc is lazy on
    // first draw() in any case. The scope(exit) tears down its GL handles at
    // shutdown — the context is still current at that point (this also fixes
    // the ef43dd9 standalone-gizmo leak).
    auto pipeGizmoHost = new PipeGizmoHost();
    scope(exit) pipeGizmoHost.destroyGL();

    // Delegate wired AFTER history + reg + activateToolById are defined below.
    // Called by setActiveTool() to emit a ToolDeactivationCommand on tool drop.
    // Null until wired; setActiveTool guards on non-null before calling.
    void delegate(string droppedId) lifecycleRecordHook;

    void setActiveTool(Tool t) {
        // One-shot falloff-drag cancel at the universal tool
        // activation/switch/drop chokepoint (BOTH activateToolById and
        // toolHost.activate route through here, as does every drop). Step 4
        // removed the per-frame cancel guard; without this, a no-tool-origin
        // falloff drag (LMB held on a falloff handle while activeTool is null)
        // would latch pipeGizmoHost.isDragging() forever if the incoming tool
        // can't route events into the host (a primitive/pen/box tool never
        // calls routeUp). A with-tool falloff drag can only BEGIN while a
        // routing tool is already active, so activation never lands mid-with-
        // tool-drag — the only live drag at this boundary is the no-tool one,
        // which must be dropped. This is a single cancel per activation, NOT a
        // per-frame guard.
        pipeGizmoHost.cancelDrag();
        if (t is null) captureStickyToolDefaults();
        if (activeTool) {
            // Capture the dropped tool id BEFORE destroying (emitsLifecycleUndo
            // gate ensures only transform tools emit; no SDK names in tracked source).
            string droppedId = (activeTool.emitsLifecycleUndo() && activeToolId.length > 0)
                ? activeToolId : "";
            activeTool.deactivate();
            activeTool.destroy();
            // Emit one ToolDeactivationCommand per tool drop, AFTER deactivate()
            // (so consolidate() has already merged the run into one geometry entry).
            // Guarded by _state != Active inside recordToolLifecycle, so re-entry
            // during a Suspend-wrapped revert/apply is a no-op.
            // lifecycleRevertHook / lifecycleApplyHook are wired after history +
            // reg + activateToolById are defined (forward-reference workaround).
            if (droppedId.length > 0 && lifecycleRecordHook !is null) {
                lifecycleRecordHook(droppedId);
            }
        }
        // Drop tool-driven pipe config (ACEN / AXIS / WGHT) so the
        // next tool starts from defaults. For tool switches via
        // activateToolById, this fires AGAIN below — harmless since
        // preActivate hasn't run yet, and the caller's reset already
        // wiped state.
        if (t is null) resetTransientPipeStages();
        activeTool   = t;
        activeToolId = "";
        if (activeTool) activeTool.activate();
        // deactivate() may have added geometry. We no longer resize / invalidate
        // / syncSelection the pick caches here (change-notification bus, Stage 2):
        // any geometry a tool appended on deactivate went through mesh primitives
        // that publish a Geometry change, so the per-frame bus flush drives the
        // resize + invalidate + syncSelection in the loop's pick-cache block on
        // the same frame (setActiveTool runs during event dispatch, before the
        // flush). One source of truth, no duplicated resize logic.
    }

    // -------------------------------------------------------------------------
    // Selection-types — single-writer derivation helpers.
    //
    // `editMode` is a materialized view of `selTypeOrder.mostRecentGeometry`.
    // `derivedEditMode()` computes it purely from the order; `setEditModeFromOrder()`
    // is the SOLE write site for the field — called from both funnel functions
    // AFTER the order has been touched, so mostRecentGeometry already equals the
    // intended mode. No other code path writes `editMode` on a live app path.

    // The geometry EditMode that the current recent-ordering implies.
    // `editMode` must always equal this value — the debug invariant on
    // `/api/selection` asserts it as a regression tripwire.
    EditMode derivedEditMode() const {
        return geometryEditMode(selTypeOrder.mostRecentGeometry());
    }

    // The sole writer: recomputes `editMode` from the order.
    // Always call AFTER `selTypeOrder.touch(t)` so mostRecentGeometry is current.
    void setEditModeFromOrder() {
        editMode = derivedEditMode();
    }

    // -------------------------------------------------------------------------
    // Selection-types Stage 1: the single funnel for a GEOMETRY-type switch
    // (keys 1/2/3 and the `select.typeFrom` command both route through here).
    //
    // Contract:
    //   * Promote the matching SelType to the front of the recent ordering
    //     (`touchSelType`). `editMode` is recomputed in LOCKSTEP via
    //     `setEditModeFromOrder()` — it stays the picking/draw authority and
    //     always mirrors the current geometry type.
    //   * A switch that FLIPS the front type DROPS the active tool (B2 — mirrors
    //     the documented tool-drop on a selection-mode change), routed through
    //     the same `setActiveTool(null)` path the active-layer switch hook uses.
    //   * A switch to the type that is ALREADY current does NOT flip the front,
    //     so it does NOT drop the tool and does NOT note a current-type change.
    //   * On a flip, note the current-type change on the bus
    //     (`noteCurrentType`) so the per-frame flush delivers the
    //     `currentTypeChanged` signal (delivered LAST, after mesh/sel/layer).
    void switchGeometryType(EditMode mode) {
        import change_bus : noteCurrentType;
        const t = geometrySelType(mode);
        const flipped = selTypeOrder.touch(t);
        // Recompute editMode from the order (idempotent when already that mode —
        // keeps the lockstep invariant even on a no-flip).
        setEditModeFromOrder();
        if (flipped) {
            setActiveTool(null);          // tool-drop on a front-flip (B2)
            noteCurrentType(t);           // current-type changed (bus, drained at flush)
        }
    }

    // Selection-types Stage 5 (audit c): a programmatic SELECTION command that
    // changes the active element type (`mesh.select` to a different mode,
    // `select.convert`) must keep editMode and SelType in LOCKSTEP — editMode is
    // never written independently of the recent-ordering. This is the same
    // promotion `switchGeometryType` does (touch the order + recompute editMode)
    // but WITHOUT the key-1/2/3 tool-drop: a selection command does not change
    // the *interaction* mode the way pressing a mode key does, so dropping the
    // active tool here would be a behavior change (and break select-then-edit
    // sequences). Installed as a hook into the two selection commands so they
    // stop writing `*editModePtr` directly.
    void promoteGeometryType(EditMode mode) {
        import change_bus : noteCurrentType;
        const t = geometrySelType(mode);
        const flipped = selTypeOrder.touch(t);
        setEditModeFromOrder();           // lockstep with the order
        if (flipped) noteCurrentType(t);  // current-type changed (no tool-drop)
    }

    // -------------------------------------------------------------------------
    // Selection-types Stage 2a: an ITEM (layer) selection makes `SelType.Item`
    // the current type. Mirrors switchGeometryType's front-flip contract but
    // for the item type. Routed through the app-installed `onItemSelect` hook
    // the layer.select command calls AFTER mutating the selection set, so the
    // app's authoritative `selTypeOrder` (the source `/api/selection` reads)
    // is promoted, not just the bus counter.
    //
    // Unlike the geometry-type switch, `editMode` is left UNCHANGED — it stays
    // the most-recent GEOMETRY type so viewport picking/drawing keeps a defined
    // mode under item selection (Design §1). A front-flip notes the current-type
    // change on the bus; tool-drop on a genuine primary change is handled by
    // onActiveLayerChanged (fired by the command's fireSwitchIfChanged), so this
    // hook does NOT drop the tool itself.
    void switchToItemType() {
        import change_bus : noteCurrentType;
        const flipped = selTypeOrder.touch(SelType.Item);
        if (flipped)
            noteCurrentType(SelType.Item);
    }

    // -------------------------------------------------------------------------
    // Registry + YAML config
    // -------------------------------------------------------------------------

    import command_history : CommandHistory;
    auto history = new CommandHistory();

    // Refire/apply-record dispatch helper (task 0183 C4). Folds the
    // `if (history.refireActive) fire else apply+record` dance that was
    // re-inlined at 4 call sites (generic command dispatch, selection
    // handler, transform handler, runCommand) into one place. Two axes are
    // load-bearing and stay fully parameterized — do NOT flatten them:
    //   - throwMsg is null  -> failures are silent (runCommand's case)
    //   - throwMsg not null -> failures throw new Exception(throwMsg)
    //   - mode selects record() vs recordCoalescing() on a successful apply
    // Equivalence per call site is documented at each call below.
    enum RecordMode { Record, Coalescing }
    void applyOrRefire(Command cmd, RecordMode mode, string throwMsg) {
        if (history.refireActive) {
            if (!history.fire(cmd) && throwMsg !is null)
                throw new Exception(throwMsg);
        } else if (cmd.apply()) {
            final switch (mode) {
                case RecordMode.Record:     history.record(cmd);           break;
                case RecordMode.Coalescing: history.recordCoalescing(cmd); break;
            }
        } else if (throwMsg !is null) {
            throw new Exception(throwMsg);
        }
    }

    // Phase 7: macro recorder captures successful command lines
    // (via history.onRecord delegate) when active. Survives undo /
    // redo / clear-history — saving a macro after several edits
    // produces a replayable script regardless of intervening undos.
    auto macroRecorder = new MacroRecorder();
    history.onRecord = &macroRecorder.onCommandRecorded;

    // -------------------------------------------------------------------------
    // Active-layer-switch hook (layers Stage 2). The single contract every
    // layer-active change funnels through — fired by the layer.add / .delete /
    // .select commands (and their undo/redo paths) whenever the active layer
    // OBJECT changes. Order matters (see the design doc):
    //   1. Drop the active tool FIRST — an edit scan is bound to a fixed
    //      foreground layer; a transform session / live preview must never
    //      straddle a switch.
    //   2. Break the coalescing boundary — a selection/delta edit recorded on
    //      the NEW layer must start a fresh history entry, never merge with the
    //      prior layer's top entry. The compareOp target-mesh term (Stage 0a)
    //      is the stateless half; this is the explicit barrier covering the
    //      undo-of-layer.select case where an older SAME-mesh entry resurfaces.
    //   3. Re-upload the new active mesh's GPU buffers (re-keys gpu_select via
    //      uploadVersion) + invalidate the global pick caches.
    //   4. Invalidate the version-keyed caches that could collide across layers
    //      (snap grids; symmetry/subpatch self-invalidate via their new
    //      mesh-address keys). Belt-and-braces beside the address keys.
    //   5. noteChange(MeshChangeAll) on the NEW active mesh so the per-frame
    //      bus flush invalidates every subscriber exactly as a file load does.
    void delegate(size_t, size_t) onActiveLayerChanged = (size_t prev, size_t next) {
        import change_bus : MeshChangeAll, noteLayerChange, LayerChange;
        import snap       : invalidateSnapGrids;
        // 0. Task 0232 fold #1(b): drop any Loop Slice standing preview
        //    BEFORE the tool-drop below. By the time this hook fires the
        //    primary has ALREADY switched (this command's
        //    fireSwitchIfChanged runs after the mutation), so `mesh` (via
        //    the tool's meshSrc_() delegate) already resolves to the NEW
        //    layer — a generic deactivate()-driven commit/restore would
        //    touch the WRONG mesh. dropArmedPreview() never touches mesh,
        //    so it's safe regardless of the swap having already happened;
        //    it just needs to run before step 1's setActiveTool(null).
        if (auto lst = cast(LoopSliceTool) activeTool) lst.dropArmedPreview();
        if (auto est = cast(EdgeSliceTool) activeTool) est.dropArmedPreview();
        // 1. tool-drop (same path as Esc / scene.reset's onResetTool).
        setActiveTool(null);
        // 2. explicit coalesce barrier on the history.
        history.breakCoalescing();
        // 3. GPU re-upload + pick-cache resize/invalidate against the NEW mesh.
        auto active = document.activeMesh();
        gpu.upload(*active);
        vertexCache.resize(active.vertices.length); vertexCache.invalidate();
        edgeCache.resize(active.edges.length);      edgeCache.invalidate();
        faceCache.resize(active.vertices.length, active.faces.length);
        faceCache.invalidate();
        // 4. blanket-invalidate the snap grids (address keys are the primary
        //    defense; symmetry + subpatch preview self-invalidate on address).
        invalidateSnapGrids();
        // 5. publish a bulk change on the new active mesh. (The required cache
        //    refresh stays MeshChangeAll — the on-screen geometry is a different
        //    mesh; the scope-down rider is deliberately NOT taken here.)
        active.noteChange(MeshChangeAll);
        // 6. publish the SEMANTIC layer event. This hook is the SINGLE funnel
        //    that fires iff the PRIMARY (active) Layer OBJECT genuinely changed
        //    (Stage 2a: `active()` == `primary`, so `fireSwitchIfChanged` keys on
        //    the primary identity — a multi-select add/remove that leaves the
        //    primary put does NOT fire this). It is the ONE place ActiveChanged
        //    is emitted — add/delete/select/reorder/setVisible-promote route
        //    their primary-change through here and must NOT emit it themselves
        //    (no double-count).
        noteLayerChange(LayerChange.ActiveChanged);
    };

    // Visibility of the floating Command-History panel (drawn in the main
    // render loop). Toggled by the history.show command, wired below.
    bool showHistoryPanel = false;
    // Phase 5: REPL state for the History panel's bottom-anchored
    // command bar. `historyReplInput` is the in-flight input buffer;
    // `historyReplLastWasError` highlights the input red after a
    // parse / dispatch failure until the user edits the next time.
    char[512] historyReplInput;  // null-terminated for ImGui.InputText
    historyReplInput[] = 0;
    bool historyReplLastWasError = false;

    // Layers panel (layers Stage 4): rename-in-place state. `layerRenameIndex`
    // is the layer index whose name is currently being edited inline (-1 = none,
    // i.e. all rows show a plain label); `layerRenameBuf` is the null-terminated
    // edit buffer fed to ImGui.InputText. Both reset when the edit commits or
    // is cancelled. The panel is pure UI — every control dispatches a `layer.*`
    // command through commandHandlerDelegate, never mutating `document` directly.
    int layerRenameIndex = -1;
    char[256] layerRenameBuf;
    layerRenameBuf[] = 0;

    // Task 0232: Loop Slice Slider HUD marker drag-anchor. Persists across
    // frames while the marker InvisibleButton is held — mirrors the cross-
    // splitter arm's anchor pattern (app.d ~10160): this binding's
    // GetMouseDragDelta is CUMULATIVE since the press began, not per-frame,
    // so the live fraction is re-derived each frame from the fraction
    // captured the instant the drag started, not accumulated incrementally.
    float lsHudDragAnchorFrac = 0.5f;
    bool  lsHudDragActive     = false;
    // Task 0239 (Loop Slice v2): which slice index the CURRENT marker drag
    // targets — decided once at drag-start (either the marker under the
    // press, or the tool's existing Current if the press landed on the bare
    // track), then held for the rest of the drag so a fast mouse motion
    // that momentarily crosses another marker's pixel column doesn't
    // reassign mid-gesture.
    int   lsHudDragMarker     = -1;
    // Phase 4: substring filter for the History panel list.
    // Type-to-narrow — both command name and args searched (case-
    // sensitive substring).
    char[256] historyFilter;
    historyFilter[] = 0;
    // Phase 4: show args toggle. When false, the row is just the
    // command's label (a compact "hide arguments" view).
    bool historyShowArgs = true;
    // Phase 6 display options (gear popover).
    bool historyShowRowNumbers = false;  // index column on the left
    bool historyShowTimestamps = false;  // "+12.3s" relative to first entry
    bool historyShowCommandIds = false;  // internal commandName vs label

    // ----- Per-command argument dialogs -----------------------------------
    // Universal schema-driven modal dialog. open(cmd) queues a popup;
    // draw(&runCommand) renders it each frame. Replaces per-command state
    // fields. Any Command whose params() returns non-empty automatically
    // gets a dialog — no further app.d changes needed for new commands.
    auto argsDialog    = new ArgsDialog();

    // AI3D (task 0381) modal snapshot — written ONLY by onAi3dEvent (below,
    // near runCommand) from drained immutable Ai3dEvent copies. The Phase 3
    // modal reads this to render health/progress/error without ever
    // touching the controller or its queue directly.
    // (task 0415: Ai3dModalState relocated to editor_app.d -- a `static
    // struct` nested in a function has no closure over enclosing state in D,
    // so this is behavior-preserving; the type needs to be nameable from
    // registration.d's EditorApp ctx bag. See editor_app.d's doc comment.)
    Ai3dModalState ai3dModal;
    // Modal open/popup-pending state (Phase 3) — mirrors ArgsDialog's
    // pendingOpen convention (source/args_dialog.d). Set by
    // ai3d.generate.open's onPicked callback (registered below, near the
    // other ai3d.* factories); drawn once per frame beside drawTabPanel().
    bool   ai3dModalOpen;
    bool   ai3dModalPendingOpen;
    string ai3dPickedImagePath;
    char[256] ai3dWorkerUrlBuf;
    ai3dWorkerUrlBuf[] = 0;
    ai3dWorkerUrlBuf[0 .. "http://127.0.0.1:47831".length] = "http://127.0.0.1:47831";
    // Requested face budget for the create-job body (task ai3d-maxfaces).
    // The widget cannot be trusted to clamp on its own (same lesson as the
    // negative-scale ImGui v_min gap) — clamped to [1000, Ai3dMaxTotalFaces]
    // right after the widget below, and `ai3dController.start()` threads it
    // to `stageArtifact`, whose `clampMaxFaces` is the real authority.
    int ai3dMaxFaces = Ai3dDefaultRequestedFaces;

    // AI worker lifecycle UI state (task 0403). ai3dWorkerStarting bridges
    // Start's "spawned the process" moment to the health probe confirming
    // it actually came up: while true, the modal re-triggers
    // ai3dController.probeHealth() at a throttled cadence (never every
    // frame — that would spawn a health-probe thread per frame) and reads
    // the result through the SAME ai3dModal.health* snapshot the manual
    // health line already uses. ai3dInstallConfirmOpen/PendingOpen mirror
    // ai3dModalOpen/ai3dModalPendingOpen's own nested-popup convention.
    import core.time : MonoTime;
    bool     ai3dWorkerStarting;
    MonoTime ai3dWorkerStartDeadline;
    MonoTime ai3dWorkerNextHealthProbe;
    bool     ai3dInstallConfirmOpen;
    bool     ai3dInstallConfirmPendingOpen;

    // Quad Remesh modal (source/remesh/remesh_job.d). No health-check /
    // event-queue snapshot needed like ai3dModal above — RemeshJob is polled
    // synchronously in this same thread, so the modal reads its
    // state()/message()/busy() directly every frame. Only the two things
    // that don't survive a post-success clear() (see tickRemeshJob) are
    // cached here for display.
    bool   remeshModalOpen;
    bool   remeshModalPendingOpen;
    bool   remeshModalPendingClose;  // set on a successful remesh -> auto-close
    int    remeshTargetQuads = 20_000;
    float  remeshAdaptivity  = 1.0f;
    float  remeshSharpEdge   = 90.0f;
    string remeshLastError;
    string remeshLastSummary;

    auto propertyPanel = new PropertyPanel();
    auto formsPanel    = new forms_render.FormsPanel();
    auto aiState       = new EditorAiState();
    auto aiAdvisor     = new AiAdvisor(() => aiState.enabled);
    setHandleAiAdvisor(aiAdvisor);

    // AI Modeling Copilot (task 0402 Phase 2): the passive findings-list
    // panel. Owns only its own display state (Finding[] + active row) —
    // the copilot.analyze / copilot.selectFinding commands below are the
    // only writers, see copilot_panel.d's doc comment.
    // version(WithAI)-only (compiled out of modeling-noai) — see the import
    // block's doc comment near the top of this file.
    version (WithAI)
    auto copilotPanel = new CopilotPanel();

    // Opt-in model-backed handle decision provider (task 0028). Enabled only
    // when a model path is configured (--ai-model wins, else VIBE3D_AI_MODEL);
    // OFF when both unset, in which case the adapter is NOT constructed and the
    // provider is NOT set — the handle path stays exactly the deterministic
    // advisor above (byte-identical to before).
    //
    // Never-crash contract: OnnxModelBackend's ctor never throws (a missing
    // onnx runtime or an unloadable model file reports `unavailable`), and the
    // adapter uses fallbackMode = keepDefault so a not-ready / low-confidence /
    // rejected prediction returns a no-op decision (no allocation, no always-on
    // advisor). The injected closure then falls through to the SAME aiState-
    // gated `aiAdvisor` instance ⇒ flag-on-but-model-unavailable is also
    // byte-identical to before. Only a confident, valid model prediction
    // influences the handle, and even then it is re-gated by the handler's
    // canApplyAdvisorDecision. The model prediction itself is independent of the
    // aiState panel switch — pointing at a model via env/CLI is the explicit
    // opt-in to use it.
    import std.process : environment;
    auto aiModelPath = aiModelCliPath.length
        ? aiModelCliPath
        : environment.get("VIBE3D_AI_MODEL", "");
    // version(WithAI) only — `modeling-noai` (Win7) compiles out the ONNX
    // backend entirely, so the model-backed provider is never installed and the
    // handle path stays the deterministic advisor.
    version (WithAI)
    if (aiModelPath.length) {
        auto aiBackend = new OnnxModelBackend(aiModelPath);  // never throws
        AiModelAdapterConfig aiModelCfg;
        aiModelCfg.availability = AiModelAvailability(AiModelStatus.ready);
        aiModelCfg.fallbackMode = AiModelFallbackMode.keepDefault;
        aiModelCfg.minConfidence = aiModelAdapterMinConfidence;
        auto aiModelAdapter = new AiModelAdapter(aiModelCfg, aiBackend);
        // Composing provider: try the model first, fall through to today's
        // exact advisor on keepDefault. The closure keeps the adapter (and the
        // backend it holds) GC-live for the program lifetime once stored.
        setHandleDecisionProvider(
            (const ref AiInteractionContext ctx, const(AiCandidate)[] cands) {
                auto d = aiModelAdapter.decide(ctx, cands);
                return d.keepDefault ? aiAdvisor.advise(ctx, cands) : d;
            });
    }

    // Opt-in live interaction-log capture (task 0027). Enabled only when a path
    // is configured (--ai-log wins, else VIBE3D_AI_LOG). Gated on the writer
    // being enabled, INDEPENDENT of the AI master switch (aiState) — with the
    // advisor OFF the applied winner is the DEFAULT winner, which is exactly the
    // element/handle the user applied, so AI-off capture is valid training data.
    // Disabled-path is fully inert (no file, append is a no-op).
    auto aiLogWriter = AiInteractionLogWriter.fromEnv(aiLogCliPath);
    immutable aiLogSource = defaultLiveSource();
    scope(exit) aiLogWriter.close();

    // ε-exploration controller (task 0033).  Reads VIBE3D_AI_EXPLORE + _SEED.
    // When disabled (ε=0 / flag absent), enabled()==false and EVERY exploration
    // path is a strict no-op — output is byte-identical to today.
    // Guards: ε forced to 0 under g_testMode AND playbackMode (independent).
    auto aiExplore = (command.g_testMode || playbackMode)
        ? new AiExplorationController(0.0f, 42u)
        : AiExplorationController.fromEnv();
    // Source tag — distinguishes exploration records in the corpus.
    immutable aiExploreSource = aiExplore.enabled
        ? defaultExploreSource()
        : "";
    // Per-frame re-grab event forwarded from the capture sink to step().
    // Set when a mouseDown fires while a pending is AwaitingRegrab; consumed
    // once per frame in the per-frame step() call above.
    OptionalGrab lastExploreGrab;
    // Wire exploration hooks when enabled + the writer is live.
    if (aiExplore.enabled && aiLogWriter.enabled) {
        setHandleExploreHook(
            (const(AiCandidate)[] candidates, int defaultIdx) {
                return aiExplore.sampleOverrideIndex(
                    candidates.length, cast(size_t)defaultIdx);
            });
        // Silent-hover is set per-ToolHandles instance below, after tool
        // construction, so each instance's flag is set at construction time.
    }

    // Maps the current EditMode enum to the schema's editModeId string for the
    // captured context (mirrors the per-mode labels used elsewhere).
    string aiEditModeId() {
        final switch (editMode) {
            case EditMode.Vertices: return "vertices";
            case EditMode.Edges:    return "edges";
            case EditMode.Polygons: return "polygons";
        }
    }

    // Handle apply hook: handler.d fires this on a genuine handle apply only
    // (mouse-DOWN, not a drag, a default part was hit — gated in
    // publishHandleTrace). The handler-supplied context lacks tool/edit-mode
    // ids, so enrich it here before appending. appliedIndex is the part the
    // user actually applied (= default unless an advisor decision overrode it,
    // or ε-exploration overrode it).
    //
    // When ε-exploration is enabled: instead of immediate append, stage the
    // record in the pending buffer and wait for the outcome.  When not
    // exploring, the path is byte-identical to the pre-exploration 0027 path.
    if (aiLogWriter.enabled) {
        setHandleApplyCaptureSink(
            (const ref AiInteractionContext ctx,
             const(AiCandidate)[] candidates,
             AiAdvisorDecision decision,
             int appliedIndex) {
                AiInteractionContext enriched = ctx;
                enriched.activeToolId = activeToolId;
                enriched.editModeId = aiEditModeId();
                auto record = makeAiInteractionLogRecord(
                    aiExplore.enabled ? aiExploreSource : aiLogSource,
                    "handles", enriched, candidates,
                    decision, appliedIndex);

                if (aiExplore.enabled) {
                    string key = buildCandidateKey(candidates);
                    if (aiExplore.hasPending()) {
                        // A pending record is already staged: this new grab is
                        // a potential re-grab.  Forward it to step() via
                        // lastExploreGrab so the state machine can resolve.
                        // Parse the part integer from the applied candidate id.
                        import ai.exploration : parseHandlePart;
                        string appliedId = (appliedIndex >= 0 &&
                                            appliedIndex < cast(int)candidates.length)
                            ? candidates[cast(size_t)appliedIndex].id
                            : "";
                        int partInt = parseHandlePart(appliedId);
                        lastExploreGrab.present   = (partInt >= 0);
                        lastExploreGrab.sortedKey = key;
                        lastExploreGrab.partInt   = partInt;
                    } else {
                        // No pending: stage this grab as the new pending record.
                        auto vpNow = vpm.activeSnapshot();
                        aiExplore.stagePending(record, key, appliedIndex,
                                               history.undoEpoch(),
                                               vpNow.view);
                    }
                } else {
                    // Non-exploration path: immediate append (unchanged).
                    aiLogWriter.append(record);
                }
            });
    }

    // Phase C.2: every transform tool gets the same undo plumbing — the
    // history stack + a factory that builds a MeshVertexEdit pre-wired to
    // the same gpu/caches the tool mutates. Tools call beginEdit() at drag
    // start and commitEdit() at drag end; one undo entry per drag.
    auto vxEditFactory = () => new MeshVertexEdit(&mesh(), cameraView, editMode);
    // The eleven `*EditFactory` closures below all build the same generic
    // MeshSessionEdit (task 0408 / campaign 0407 §A.D1) — a (pre, post)
    // MeshSnapshot-pair record command — differing only in wireName /
    // defaultLabel / editScope. wireName MUST stay byte-identical to each
    // class's former hardcoded name() string: undo history / event-log
    // replay / macros dispatch on it.
    import mesh_edit_delta : MeshEditScope;
    enum sessionGeomMarks = MeshEditScope.Geometry | MeshEditScope.Marks;
    auto bevelEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.bevel_edit", "Bevel");
    auto loopSliceEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                             "mesh.loop_slice_edit", "Loop Slice");
    auto reduceEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                      "mesh.reduce_edit", "Reduce");
    auto cloneEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                    "mesh.clone_edit", "Clone");
    auto arrayEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                    "mesh.array_edit", "Array");
    auto edgeExtrudeEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.edge_extrude_edit", "Edge Extrude", sessionGeomMarks);
    // Edge Extend's typed edit factory (Phase 4 interactive tool consumer). The
    // one-shot mesh.edge_extend command undoes via its own MeshSnapshot; this
    // factory exists now so the Phase-4 EdgeExtendTool can bind it, mirroring
    // edgeExtrudeEditFactory.
    auto edgeExtendEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.edge_extend_edit", "Edge Extend", sessionGeomMarks);
    auto polyExtrudeEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.face_extrude_edit", "Face Extrude", sessionGeomMarks);
    // Radial Array's typed edit factory (interactive-tool consumer). The
    // one-shot mesh.radial_array command undoes via its own MeshSnapshot;
    // this factory exists so RadialArrayTool can bind it, mirroring
    // polyExtrudeEditFactory / edgeExtendEditFactory.
    auto radialArrayEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.radial_array_edit", "Radial Array", sessionGeomMarks);
    // Smooth Shift + Thicken's typed edit factory (task 0358 interactive tool
    // consumer), mirroring polyExtrudeEditFactory. The one-shot mesh.smooth_shift
    // / mesh.thicken commands keep undoing via their own MeshSnapshot.
    auto smoothShiftEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.smooth_shift_edit", "Smooth Shift");
    // Stroke Extrude's typed edit factory (task 0323 interactive tool
    // consumer). The one-shot mesh.strokeExtrude command undoes via its
    // own MeshSnapshot; this factory exists so StrokeExtrudeTool can bind
    // it, mirroring radialArrayEditFactory / smoothShiftEditFactory. Wire
    // name is "mesh.strokeExtrude_edit" (camelCase, NOT snake_case like its
    // siblings) — a pre-existing irregularity, preserved byte-for-byte since
    // undo history / replay dispatch on it.
    auto strokeExtrudeEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.strokeExtrude_edit", "Stroke Extrude", sessionGeomMarks);

    // ----- Tool Pipe singleton (phase 7.0). Initialised here, exposed
    // globally via toolpipe.g_pipeCtx. Phase 7.1 registers the
    // WorkplaneStage (mode=auto by default) — tools that previously
    // called pickMostFacingPlane(vp) now route through the pipe via
    // pickWorkplane(vp), so the global "workplane mode" attr is honoured
    // (auto / worldX / worldY / worldZ).
    g_pipeCtx = new ToolPipeContext();
    g_pipeCtx.pipeline.add(new WorkplaneStage());
    {
        import toolpipe.stages.actcenter : ActionCenterStage;
        import toolpipe.stages.axis      : AxisStage;
        import toolpipe.stages.snap      : SnapStage;
        import toolpipe.stages.constrain : ConstrainStage;
        import toolpipe.stages.falloff   : FalloffStage;
        import toolpipe.stages.symmetry  : SymmetryStage;
        g_pipeCtx.pipeline.add(new SymmetryStage(() => &mesh(), &editMode));
        g_pipeCtx.pipeline.add(new SnapStage());
        g_pipeCtx.pipeline.add(new ConstrainStage());
        g_pipeCtx.pipeline.add(new ActionCenterStage(() => &mesh(), &editMode,
                                                       () => document.primary));
        g_pipeCtx.pipeline.add(new AxisStage(() => &mesh(), &editMode,
                                              () => document.primary));
        g_pipeCtx.pipeline.add(new FalloffStage(() => &mesh(), &editMode));
        import toolpipe.stages.path : PathStage;
        g_pipeCtx.pipeline.add(new PathStage(() => &mesh()));
    }

    // Main-loop flag — declared up here so command factories
    // (file.quit in particular) can capture it before the actual
    // loop runs below.
    bool running = true;

    Registry reg;

    // -------------------------------------------------------------------------
    // EditorApp ctx assembly (task 0415, campaign 0407 §B.V1 step 1) -- every
    // field below is wired from a main()-local declared above this point,
    // except `toolHostPtr` (ToolHost is declared further down; its wiring
    // sits right after the ToolHost block, before registerCommands(app) is
    // called). Passed BY VALUE into registerTools/registerCommands, which
    // open `with (app) { ... }` so the moved factory-registration text below
    // reads verbatim. Full inventory + categorization rationale:
    // doc/tasks/done/0415-registration-app-decomp.md.
    // -------------------------------------------------------------------------
    EditorApp app;
    // `meshDg`, not `mesh` -- task 0419 found the UI-panel block reads
    // `mesh.foo()` bare-dot (no explicit call parens); `mesh` in EditorApp
    // is now a `@property ref Mesh mesh()` method backed by this field
    // (same pattern as `cameraViewDg`/`cameraView` right below).
    app.meshDg      = cast(MeshDg)&mesh;
    app.cameraViewDg = cast(ViewDg)&cameraView;
    app.vertexCache = cast(VertexCacheDg)&vertexCache;
    app.faceCache   = cast(FaceCacheDg)&faceCache;
    app.edgeCache   = cast(EdgeCacheDg)&edgeCache;

    app.gpuPtr      = &gpu;
    app.editModePtr = &editMode;
    app.documentPtr = &document;
    app.regPtr      = &reg;

    app.subpatchPreviewPtr  = &subpatchPreview;
    app.activeToolPtr       = &activeTool;
    app.runningPtr          = &running;
    app.showHistoryPanelPtr = &showHistoryPanel;

    app.ai3dRefs.ai3dModalPtr            = &ai3dModal;
    app.ai3dRefs.ai3dModalOpenPtr        = &ai3dModalOpen;
    app.ai3dRefs.ai3dModalPendingOpenPtr = &ai3dModalPendingOpen;
    app.ai3dRefs.ai3dPickedImagePathPtr  = &ai3dPickedImagePath;
    app.ai3dRefs.ai3dWorkerUrlBufPtr     = &ai3dWorkerUrlBuf;

    app.remeshRefs.remeshModalOpenPtr        = &remeshModalOpen;
    app.remeshRefs.remeshModalPendingOpenPtr = &remeshModalPendingOpen;
    app.remeshRefs.remeshLastErrorPtr        = &remeshLastError;
    app.remeshRefs.remeshLastSummaryPtr      = &remeshLastSummary;

    app.history         = history;
    app.vpm             = vpm;
    app.litShader       = litShader;
    app.pipeGizmoHost   = pipeGizmoHost;
    app.macroRecorder   = macroRecorder;
    app.ai3dController  = ai3dController;
    app.remeshJob       = remeshJob;
    app.aiState         = aiState;
    version (WithAI) app.copilotPanel = copilotPanel;
    app.aiExplore       = aiExplore;
    app.aiLogWriter     = aiLogWriter;

    app.vxEditFactory            = vxEditFactory;
    app.bevelEditFactory         = bevelEditFactory;
    app.loopSliceEditFactory     = loopSliceEditFactory;
    app.reduceEditFactory        = reduceEditFactory;
    app.cloneEditFactory         = cloneEditFactory;
    app.arrayEditFactory         = arrayEditFactory;
    app.edgeExtrudeEditFactory   = edgeExtrudeEditFactory;
    app.edgeExtendEditFactory    = edgeExtendEditFactory;
    app.polyExtrudeEditFactory   = polyExtrudeEditFactory;
    app.radialArrayEditFactory   = radialArrayEditFactory;
    app.smoothShiftEditFactory   = smoothShiftEditFactory;
    app.strokeExtrudeEditFactory = strokeExtrudeEditFactory;

    app.setActiveTool        = cast(void delegate(Tool))&setActiveTool;
    app.switchToItemType     = cast(void delegate())&switchToItemType;
    app.promoteGeometryType  = cast(void delegate(EditMode))&promoteGeometryType;
    app.switchGeometryType   = cast(void delegate(EditMode))&switchGeometryType;
    app.onActiveLayerChanged = onActiveLayerChanged;
    app.resetAllPipeStages   = cast(void delegate())&resetAllPipeStages;

    // `move` / `rotate` / `scale` build XfrmTransformTool with the
    // matching T/R/S single-flag preset — they share one engine, like
    // the TransformMove / TransformRotate / TransformScale presets all
    // pointing at one `xfrm.transform` tool.
    // The legacy MoveTool / RotateTool / ScaleTool classes still
    // back the wrapper as sub-tools (composition) and will be
    // deleted in Step 6 once dependents (xfrm.softMove, xfrm.taper,
    // etc.) have moved off them.
    // Task 0415 Phase 1: former Span A (move/rotate/scale through the
    // mesh.*Tool generator-preview family + prim.* + their paired
    // ToolHeadlessCommand wrappers) now lives in registration.d.
    registerTools(app);

    // -------------------------------------------------------------------------
    // ToolHost — delegate bridge for tool.* commands
    // -------------------------------------------------------------------------

    ToolHost toolHost;
    toolHost.getActiveTool   = () => activeTool;
    toolHost.getActiveToolId = () => activeToolId;
    toolHost.activate = (string id) {
        auto factory = id in reg.toolFactories;
        if (factory is null)
            throw new Exception("unknown tool '" ~ id ~ "'");
        // Reset tool-driven pipe stages BEFORE preActivate runs —
        // same contract as activateToolById. Without this, switching
        // tools via tool.set leaks the previous preset's pipe config
        // into the next session.
        resetTransientPipeStages();
        // Per-id pre-activate hook — see activateToolById.
        if (auto hook = id in reg.preActivate) (*hook)();
        import tool_presets : applyStickyToolDefaults;
        auto t = (*factory)();
        applyStickyToolDefaults(t, id);
        setActiveTool(t);
        activeToolId = id;
    };
    toolHost.deactivate = () {
        setActiveTool(null);
        activeToolId = "";
    };
    // task 0415 Phase 1: wire the ctx's toolHostPtr now that `toolHost` is
    // fully assembled -- Span A (registerTools, above) never touches it;
    // Span B below (registerCommands, Phase 2) does.
    app.toolHostPtr = &toolHost;

    // Task 0415 Phase 2: former Span B (tool.*/ui.*/layer.*/ai3d.*/
    // workplane.*/actr.*/falloff.*/select.*/mesh.*/history.*/macro.*
    // command factories) now lives in registration.d.
    registerCommands(app);

    // Tool presets — declarative `base tool + pipe-stage attrs`
    // bundles loaded from `config/tool_presets.yaml`.
    // Each entry registers as a new `reg.toolFactories[id]` that
    // calls the named base factory and then applies `setAttr` per
    // pipe stage. Done AFTER all base factories are registered so
    // `registerToolPresets` can look up bases by id.
    {
        import tool_presets : loadToolPresets, registerToolPresets;
        auto presets = loadToolPresets("config/tool_presets.yaml");
        registerToolPresets(reg, presets);
    }

    // Snapshot every registered command/tool's `supportedModes()`
    // into the registry's cache so button rendering can auto-disable
    // rows whose target doesn't accept the current edit mode (e.g.
    // `mesh.subdivide` is polygon-only, `bevel` is edge-/polygon-only).
    // Done after every `reg.{command,tool}Factories[*]` assignment so
    // the cache covers every registered id.
    reg.cacheSupportedModes();

    // Config-driven Tool Properties forms (config/forms/*.yaml). Loaded AFTER
    // the pipeline (g_pipeCtx) AND every tool/command factory are in place so
    // the startup-strict validator can resolve each binding against the live
    // static universe: a tool's params() (via its registered factory — the same
    // instantiation cacheSupportedModes just did), a pipe stage's knownAttrs()
    // (off the live pipeline; there is no stage-factory map), and the command
    // registry. A YAML typo (unknown attr / stage / tool / command) throws here
    // and aborts startup, exactly like a stale tool preset does.
    {
        import forms : loadForms, validateForms, FormValidators, g_forms,
                       g_formsPanelEnabled;
        import toolpipe.pipeline : g_pipeCtx;

        // Phase-5 enablement: FormsPanel is the PRIMARY Tool Properties UI by
        // default — a tool with a matching loaded form renders through it, every
        // other tool keeps the legacy PropertyPanel / drawProperties() fallback.
        // VIBE3D_FORMS=0 is the kill-switch (legacy panel for ALL tools) for
        // debugging / A-B comparison.
        {
            import std.process : environment;
            g_formsPanelEnabled = environment.get("VIBE3D_FORMS", "1") != "0"; // read once at startup; runtime changes need a relaunch
        }
        import std.file : dirEntries, SpanMode, exists;
        import std.algorithm : sort;

        FormValidators fv;
        fv.toolAttrs = (string toolId) {
            auto factory = toolId in reg.toolFactories;
            if (factory is null) return null;
            string[] names;
            foreach (ref p; (*factory)().params())
                names ~= p.name;
            return names;
        };
        fv.stageAttrs = (string stageId) {
            if (g_pipeCtx is null) return null;
            auto stage = g_pipeCtx.pipeline.findById(stageId);
            if (stage is null) return null;
            return stage.knownAttrs();
        };
        fv.commandExists = (string cmdId) =>
            (cmdId in reg.commandFactories) !is null;

        if (exists("config/forms")) {
            string[] files;
            foreach (e; dirEntries("config/forms", "*.yaml", SpanMode.shallow))
                files ~= e.name;
            files.sort();   // deterministic load order across filesystems
            foreach (path; files) {
                auto loaded = loadForms(path);
                validateForms(loaded, fv, path);
                g_forms ~= loaded;
            }
        }
    }

    Panel[]       panels            = loadButtons("config/buttons.yaml");
    Group[]       statusLineGroups  = loadStatusLine("config/statusline.yaml");
    // AI-less build (config=modeling-noai, Win7): the ONNX ranker backend is
    // compiled out, so render the AI master-switch button as a disabled
    // placeholder (engraved, non-clickable) instead of a live toggle. Done
    // before the id-validation pass below, which skips disabled buttons — so
    // `ai.toggle` need not be a resolvable command in this build.
    version (WithAI) {} else {
        foreach (ref grp; statusLineGroups)
            foreach (ref btn; grp.buttons)
                if (btn.action.kind == ActionKind.command &&
                    btn.action.id.length >= 3 && btn.action.id[0 .. 3] == "ai.")
                    btn.disabled = true;
    }
    version (OSX) {
        string shortcutsPath = command.g_testMode
            ? "config/shortcuts.yaml"
            : "config/shortcuts_macos.yaml";
    } else {
        enum shortcutsPath = "config/shortcuts.yaml";
    }
    ShortcutTable shortcuts         = loadShortcuts(shortcutsPath);

    // Validate: every action id (including modifier variants) must exist in
    // the registry. For script actions, validate the first token of each
    // line — it must name a registered command.
    {
        import std.array : appender;
        import argstring : parseArgstring;
        auto missing = appender!string();
        void check(Action a) {
            final switch (a.kind) {
                case ActionKind.tool:
                    if ((a.id in reg.toolFactories) is null)
                        missing ~= " tool:" ~ a.id;
                    break;
                case ActionKind.command:
                    if ((a.id in reg.commandFactories) is null)
                        missing ~= " command:" ~ a.id;
                    break;
                case ActionKind.script:
                    foreach (line; a.scriptLines) {
                        try {
                            auto parsed = parseArgstring(line);
                            if (parsed.isEmpty) continue;
                            if ((parsed.commandId in reg.commandFactories) is null)
                                missing ~= " script-cmd:" ~ parsed.commandId;
                        } catch (Exception e) {
                            missing ~= " script-parse-err:[" ~ line ~ "]";
                        }
                    }
                    break;
                case ActionKind.popup:
                    foreach (ref pi; a.popupItems) {
                        if (pi.kind == PopupItemKind.action)
                            check(pi.action);
                    }
                    break;
            }
        }
        void checkButton(ref Button btn) {
            // Disabled placeholders are non-dispatching by construction
            // (renderStyledButton suppresses the click); their `action`
            // id may legitimately reference a not-yet-registered tool /
            // command. Skip the registry check so the YAML can document
            // future entries without blocking the build.
            if (btn.disabled) return;
            check(btn.action);
            if (btn.ctrl.present)  check(btn.ctrl.action);
            if (btn.alt.present)   check(btn.alt.action);
            if (btn.shift.present) check(btn.shift.action);
        }
        foreach (ref p; panels)
            foreach (ref btn; allButtons(p))
                checkButton(btn);
        foreach (ref grp; statusLineGroups)
            foreach (ref btn; grp.buttons)
                checkButton(btn);
        if (missing.data.length > 0)
            throw new Exception("buttons.yaml/statusline.yaml references unknown ids:"
                                ~ missing.data);
    }
    // Validate shortcut tool/command ids.
    {
        import std.array : appender;
        auto missing = appender!string();
        foreach (id, sc; shortcuts.byToolId)
            if ((id in reg.toolFactories) is null)
                missing ~= " tool:" ~ id;
        foreach (id, sc; shortcuts.byCommandId)
            if ((id in reg.commandFactories) is null)
                missing ~= " command:" ~ id;
        if (missing.data.length > 0)
            throw new Exception(shortcutsPath ~ " references unknown ids:" ~ missing.data);
    }

    void activateToolById(string id) {
        if (activeToolId == id) {
            setActiveTool(null);
            activeToolId = "";
        } else {
            // Switching tools: reset tool-driven pipe stages BEFORE
            // the new preset's preActivate writes its own settings.
            // Without this, residual config from the previous preset
            // (e.g. xfrm.elementMove leaving ACEN.mode=element)
            // bleeds into tools that don't re-pin it (e.g. plain
            // move). setActiveTool's own null-path reset doesn't run
            // here — `t` is non-null in the move-to-new branch.
            resetTransientPipeStages();
            // Run any per-id pre-activate hook (tool presets push their
            // pipe-stage attrs here — kept out of the factory so
            // `cacheSupportedModes` doesn't apply them at startup).
            if (auto hook = id in reg.preActivate) (*hook)();
            import tool_presets : applyStickyToolDefaults;
            auto t = reg.toolFactories[id]();
            applyStickyToolDefaults(t, id);
            setActiveTool(t);
            activeToolId = id;
        }
    }

    // Wire the lifecycle-record hook now that history, reg, and activateToolById
    // are all defined. Called by setActiveTool() on tool drop to emit a
    // ToolDeactivationCommand (lifecycle undo entry).
    lifecycleRecordHook = (string droppedId) {
        import commands.tool.lifecycle : ToolDeactivationCommand;
        auto lifecycleCmd = new ToolDeactivationCommand(
            &mesh(), cameraView, editMode, droppedId);
        lifecycleCmd.onRevert = (string id) {
            // Re-activate the dropped tool by id. Runs under Suspend in undo(),
            // so recordToolLifecycle inside setActiveTool will be a no-op.
            if ((id in reg.toolFactories) !is null) {
                activateToolById(id);
            }
        };
        lifecycleCmd.onApply = () {
            // Re-drop (redo): deactivate without emitting another entry.
            // setActiveTool(null) runs under Suspend, so no new entry is pushed.
            setActiveTool(null);
        };
        history.recordToolLifecycle(lifecycleCmd);
    };

    // Wire the real `tool.reset` (Ctrl+D) delegate now that history,
    // toolHost.activate, and reg are all in scope — same forward-reference
    // pattern as lifecycleRecordHook above. Reset = throw away the
    // in-progress edit and rebuild the named tool (default: the active one)
    // at its DECLARED defaults (constructor + preset-YAML, empty sticky) —
    // NOT commit the open edit. See doc/tool_settings_persist_plan.md Stage B.
    toolHost.resetActiveTool = (string optId) {
        string id = optId.length ? optId : activeToolId;
        if (id.length == 0 || (id in reg.toolFactories) is null) return false;
        // Discard any in-progress preview so reset THROWS the edit away
        // rather than committing it (touches no history — cancel bodies are
        // pure mesh restores). With `dirty` cleared, the rebuild's
        // deactivate()->commitNow() below is a no-op even if suspend alone
        // didn't also gate record().
        if (activeTool !is null && activeTool.hasUncommittedEdit())
            activeTool.cancelUncommittedEdit();
        g_prefs.toolDefaults.remove(id);   // clear sticky (B step 1)
        auto s = history.suspended();       // no spurious lifecycle/vertex-edit entry
        toolHost.activate(id);              // rebuild -> constructor + YAML defaults,
                                             // empty sticky = declared defaults (B step 2)
        return true;
    };

    // Declared at outer scope so the main-loop UI (status-line `kind: script`
    // actions, History panel replay button) can call them. They are assigned
    // inside the `if (httpServer !is null)` block below; httpServer is now
    // ALWAYS constructed (the listener is gated separately on start()), so the
    // block always runs and these are always wired — a release build with the
    // HTTP port closed still dispatches script actions through
    // commandHandlerDelegate.
    void delegate(string, string) commandHandlerDelegate;
    void delegate(size_t) replayUndoEntry;
    // FormsPanel write path: dispatches a `tool.attr` exactly like
    // commandHandlerDelegate but marks the built ToolAttrCommand `interactive`
    // (an in-process setInteractive(true)) so the universal reEvaluate() seam
    // opens the tool's live session on the first edit. Never sets the flag via
    // an argstring — see commands/tool/attr.d. Always wired now that
    // httpServer is always constructed (listener gated on start()).
    void delegate(string, string) formsInteractiveDispatch;
    // Closure-captured latch the command handler reads to decide whether a
    // `tool.attr` it is about to build should be marked interactive. Set ONLY
    // by formsInteractiveDispatch around a single dispatch; never touched by
    // the HTTP path, so raw `/api/command` writes stay non-interactive.
    bool formsInteractiveLatch = false;

    // Set up HTTP server model data provider
    if (httpServer !is null) {
        // Convert mesh vertices to flat float array for HTTP server
        float[] getMeshVertices() {
            float[] verts = new float[](mesh.vertices.length * 3);
            for (size_t i = 0; i < mesh.vertices.length; i++) {
                verts[i * 3] = mesh.vertices[i].x;
                verts[i * 3 + 1] = mesh.vertices[i].y;
                verts[i * 3 + 2] = mesh.vertices[i].z;
            }
            return verts;
        }

        // Serialize ANY mesh to the detailed /api/model JSON. Extracted so the
        // active-layer provider and the layer-aware ?layer=N provider share one
        // body (layers Stage 2).
        string meshToDetailedJson(ref Mesh m) {
            float[] verts = new float[](m.vertices.length * 3);
            for (size_t i = 0; i < m.vertices.length; i++) {
                verts[i * 3]     = m.vertices[i].x;
                verts[i * 3 + 1] = m.vertices[i].y;
                verts[i * 3 + 2] = m.vertices[i].z;
            }
            uint[2][] edgesCopy = new uint[2][](m.edges.length);
            for (size_t i = 0; i < m.edges.length; i++)
                edgesCopy[i] = m.edges[i];
            uint[][] facesCopy = new uint[][](m.faces.length);
            for (size_t i = 0; i < m.faces.length; i++)
                facesCopy[i] = m.faces[i].dup;
            auto subView = m.isSubpatch;
            bool[] subCopy = new bool[](m.faces.length);
            for (size_t i = 0; i < m.faces.length; i++)
                subCopy[i] = i < subView.length && subView[i];
            auto surfacesCopy = m.surfaces.dup;
            uint[] matCopy = new uint[](m.faces.length);
            for (size_t i = 0; i < m.faces.length; i++)
                matCopy[i] = i < m.faceMaterial.length ? m.faceMaterial[i] : 0u;
            uint[] partCopy = new uint[](m.faces.length);
            for (size_t i = 0; i < m.faces.length; i++)
                partCopy[i] = i < m.facePart.length ? m.facePart[i] : 0u;
            return meshToJsonDetailed(
                m.vertices.length, m.edges.length, m.faces.length,
                verts, edgesCopy, facesCopy, subCopy, surfacesCopy, matCopy, partCopy);
        }

        httpServer.setDetailedModelDataProvider(() => meshToDetailedJson(mesh));
        // /api/model?layer=N — N<0 (default) → active layer; otherwise clamp
        // into range. Same detailed JSON shape, just a different source layer.
        httpServer.setLayerModelProvider((int layer) {
            size_t idx = layer < 0 ? document.activeIndex : cast(size_t)layer;
            if (idx >= document.layers.length) idx = document.layers.length - 1;
            return meshToDetailedJson(document.layers[idx].mesh);
        });
        // GET /api/layers — index/name/visible/background/active + per-layer
        // vertex & face counts + the per-layer mutationVersion (a read-only
        // diagnostic the Stage-6 cross-layer-undo torture test reads to confirm
        // two identical layers genuinely share a version — the cache-key
        // collision precondition the address-augmented keys defend against).
        httpServer.setLayersDataProvider(() {
            import std.array  : appender;
            import std.format : format;
            import std.json   : JSONValue;
            import document   : Document;   // Document.background (derived, 2b)
            auto a = appender!string();
            a.put(format(`{"active":%d,"layers":[`, document.activeIndex));
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
                // INDEPENDENT hand formula. Pure JSON-shape addition (the data
                // provider already runs the snapshot on the main thread).
                const x = l.xform;
                float[16] m = x.composedMatrix();
                auto xb = appender!string();
                xb.put(format(
                    `{"pos":[%.6f,%.6f,%.6f],"rot":[%.6f,%.6f,%.6f],` ~
                    `"scl":[%.6f,%.6f,%.6f],"pivot":[%.6f,%.6f,%.6f],"matrix":[`,
                    x.pos.x, x.pos.y, x.pos.z, x.rot.x, x.rot.y, x.rot.z,
                    x.scl.x, x.scl.y, x.scl.z, x.pivot.x, x.pivot.y, x.pivot.z));
                foreach (mi; 0 .. 16) {
                    if (mi > 0) xb.put(",");
                    xb.put(format("%.6f", m[mi]));
                }
                xb.put("]}");
                // Task 0082: find the parent layer's index (-1 = no parent).
                int parentIdx = -1;
                if (l.parent !is null) {
                    foreach (pi, pl; document.layers)
                        if (pl is l.parent) { parentIdx = cast(int)pi; break; }
                }
                a.put(format(
                    `{"index":%d,"name":%s,"visible":%s,"background":%s,` ~
                    `"active":%s,"selected":%s,"primary":%s,` ~
                    `"vertexCount":%d,"faceCount":%d,` ~
                    `"mutationVersion":%d,"xform":%s,"parent":%d}`,
                    i, JSONValue(l.name).toString(),
                    l.visible ? "true" : "false",
                    Document.background(l) ? "true" : "false",
                    i == document.activeIndex ? "true" : "false",
                    l.selected ? "true" : "false",
                    document.isPrimary(l) ? "true" : "false",
                    l.mesh.vertices.length, l.mesh.faces.length,
                    cast(ulong)l.mesh.mutationVersion, xb.data, parentIdx));
            }
            a.put("]}");
            return a.data;
        });
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
                    mb.put(format("%.6f", meshModel[i]));
                }
                mb.put("]");
                modelStr = mb.data;
            }
            if (vertCount <= 0)
                return `{"faceVertCount":0,"positions":[],"model":` ~ modelStr ~ `}`;
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
                buf.put(format("[%.6f,%.6f,%.6f]",
                    data[i * 6 + 0], data[i * 6 + 1], data[i * 6 + 2]));
            }
            buf.put(`],"model":`);
            buf.put(modelStr);
            buf.put("}");
            return buf.data;
        });

        // GET /api/pick?x=&y=&engine=bvh|gpu — A/B face-pick oracle.
        // engine=gpu calls gpuSelect.pick DIRECTLY regardless of VIBE3D_FACE_PICK
        // so the oracle is always reachable even when BVH is the default.
        httpServer.setPickProvider((int x, int y, string engine) {
            import std.format : format;
            Viewport vp = vpm.activeSnapshot();
            int faceIdx;
            if (engine == "gpu") {
                faceIdx = gpuSelect.pick(SelectMode.Face, x, y, /*r=*/0,
                                          mesh, gpu, vp);
            } else {
                const(Mesh)* srcMesh = subpatchPreview.active
                    ? &subpatchPreview.mesh : &mesh();
                faceIdx = bvhPick.pickFace(x, y, vp, *srcMesh, gpu);
            }
            return format(`{"faceIndex":%d}`, faceIdx);
        });

        // POST /api/camera — set live View. Accepts azimuth, elevation,
        // distance (radians/world-units) and optional focus[x,y,z] +
        // width/height. Used by the cross-engine drag test to align
        // vibe3d's camera with a reference engine's before replaying.
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
            if ("azimuth" in p)   targetCam.azimuth   = floatFrom("azimuth",   targetCam.azimuth);
            if ("elevation" in p) targetCam.elevation = floatFrom("elevation", targetCam.elevation);
            if ("distance" in p)  targetCam.distance  = floatFrom("distance",  targetCam.distance);
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
        httpServer.setSelectionDataProvider(() {
            import std.format : format;
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
            // item (layer) selection view — one `{selected,primary}` entry per
            // layer, in layer order. These are the Stage 4 final shapes; the
            // geometry-selection arrays are unchanged.
            import std.array : appender;
            auto orderBuf = appender!string();
            orderBuf.put("[");
            foreach (oi, t; selTypeOrder.order) {
                if (oi > 0) orderBuf.put(",");
                orderBuf.put(`"` ~ selTypeToken(t) ~ `"`);
            }
            orderBuf.put("]");
            auto itemsBuf = appender!string();
            itemsBuf.put("[");
            foreach (li, l; document.layers) {
                if (li > 0) itemsBuf.put(",");
                itemsBuf.put(format(`{"selected":%s,"primary":%s}`,
                    l.selected ? "true" : "false",
                    document.isPrimary(l) ? "true" : "false"));
            }
            itemsBuf.put("]");
            return format(`{"mode":"%s","selType":"%s","selTypeOrder":%s,` ~
                `"items":%s,` ~
                `"selectedVertices":%s,"selectedEdges":%s,"selectedFaces":%s}`,
                modeName,
                selTypeToken(selTypeOrder.current()),
                orderBuf.data,
                itemsBuf.data,
                buildJsonArray(mesh.selectedVertices),
                buildJsonArray(mesh.selectedEdges),
                buildJsonArray(mesh.selectedFaces));
        });
        // Task 0234 — GET /api/tool/handles + GET /api/tool/state. Read-only
        // test-introspection over the active tool; null-guard mirrors every
        // other activeTool-reading provider in this file. See the
        // ToolHandlesDataProvider doc comment in http_server.d for the
        // thread-safety discriminator (no lock needed — the reads mutate
        // nothing, unlike the toolpipe/snap providers below which marshal to
        // the main thread).
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
                        s.enabled ? "true" : "false"));
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
        // JSON array of that id's live Param schema — {name, kind,
        // enforceBounds, value, min?, max?}. Built by instantiating the
        // factory (the same cold-construction `cacheSupportedModes()`
        // already proves safe for every registered id at startup) and
        // reading `.params()` exactly as `args_dialog.d`/`commands/tool/
        // set.d` do; `value` is boxed via `paramToJson` so the wire shape
        // matches the existing `tool.attr <id> <attr> ?` read-back
        // convention. This is the enabler for the fuzz-smoke's static
        // "born-clamped" contract check (tests/test_param_bounds.d) — a
        // generic reader instead of a hand-maintained per-tool table.
        httpServer.setRegistryProvider((bool includeParams) {
            import std.array     : appender;
            import std.format    : format;
            import std.algorithm : sort;
            auto cmds  = reg.commandFactories.keys.dup;
            auto tools = reg.toolFactories.keys.dup;
            cmds.sort();
            tools.sort();
            auto buf = appender!string;
            buf.put(`{"commands":[`);
            foreach (i, k; cmds) {
                if (i > 0) buf.put(",");
                buf.put(format(`"%s"`, k));
            }
            buf.put(`],"tools":[`);
            foreach (i, k; tools) {
                if (i > 0) buf.put(",");
                buf.put(format(`"%s"`, k));
            }
            buf.put(`],"commandNames":{`);
            bool firstName = true;
            foreach (k; cmds) {
                if (!firstName) buf.put(",");
                firstName = false;
                buf.put(format(`"%s":"%s"`, k, reg.commandNames.get(k, "")));
            }
            buf.put(`}`);

            if (includeParams) {
                import params : Param, paramToJson;

                // One param's schema as a JSON object literal. min/max
                // surface whichever hint family (float or int) the Param
                // declared — a Param only ever uses the family matching its
                // own Kind, so there is no ambiguity in practice.
                string paramJson(const ref Param p) {
                    auto v = appender!string;
                    v.put(format(`{"name":"%s","kind":"%s","enforceBounds":%s,"value":%s`,
                        p.name, p.kind, p.enforceBounds_ ? "true" : "false",
                        paramToJson(p).toString()));
                    if (p.hints.hasMinF)      v.put(format(`,"min":%s`, p.hints.minF));
                    else if (p.hints.hasMinI) v.put(format(`,"min":%d`, p.hints.minI));
                    if (p.hints.hasMaxF)      v.put(format(`,"max":%s`, p.hints.maxF));
                    else if (p.hints.hasMaxI) v.put(format(`,"max":%d`, p.hints.maxI));
                    v.put(`}`);
                    return v.data;
                }

                buf.put(`,"commandParams":{`);
                bool firstCmd = true;
                foreach (k; cmds) {
                    if (!firstCmd) buf.put(",");
                    firstCmd = false;
                    buf.put(format(`"%s":[`, k));
                    auto cmd = reg.commandFactories[k]();
                    bool firstP = true;
                    foreach (ref p; cmd.params()) {
                        if (!firstP) buf.put(",");
                        firstP = false;
                        buf.put(paramJson(p));
                    }
                    buf.put(`]`);
                }
                buf.put(`},"toolParams":{`);
                bool firstTool = true;
                foreach (k; tools) {
                    if (!firstTool) buf.put(",");
                    firstTool = false;
                    buf.put(format(`"%s":[`, k));
                    auto t = reg.toolFactories[k]();
                    bool firstP = true;
                    foreach (ref p; t.params()) {
                        if (!firstP) buf.put(",");
                        firstP = false;
                        buf.put(paramJson(p));
                    }
                    buf.put(`]`);
                }
                buf.put(`}`);
            }

            buf.put(`}`);
            return buf.data;
        });

        // Pipeline evaluation snapshot — runs pipeline.evaluate once with
        // the current mesh + selection + camera and returns the resulting
        // ActionCenterPacket / AxisPacket as JSON. The reference-diff
        // parity harness reads this to compare vibe3d's computed
        // pivot/axis to a reference engine's for the same case.
        //
        // Called from the HTTP thread; pipeline.evaluate touches View
        // state (cameraView.viewport() recomputes view/proj). Tests are
        // expected to be quiescent (no concurrent edits) when probing.
        httpServer.setToolPipeEvalProvider(() {
            import std.array       : appender;
            import std.format      : format;
            import toolpipe.pipeline : g_pipeCtx;
            import toolpipe.packets  : SubjectPacket;
            import math              : Vec3;

            auto buf = appender!string;
            if (g_pipeCtx is null) {
                buf.put(`{"error":"pipeline not initialised"}`);
                return buf.data;
            }
            SubjectPacket subj;
            subj.mesh             = &mesh();
            subj.editMode         = editMode;
            subj.viewport         = vpm.activeSnapshot();

            import operator             : VectorStack;
            import toolpipe.packets     : ActionCenterPacket, AxisPacket,
                                          SymmetryPacket, SnapPacket;
            VectorStack vts;
            vts.put(&subj);
            g_pipeCtx.pipeline.evaluate(vts);

            ActionCenterPacket acen;
            AxisPacket         axis;
            SymmetryPacket     symm;
            SnapPacket         snapPkt;   // P-C: surface live snap config for tests
            if (auto p = vts.get!ActionCenterPacket()) acen = *p;
            if (auto p = vts.get!AxisPacket())         axis = *p;
            if (auto p = vts.get!SymmetryPacket())     symm = *p;
            if (auto p = vts.get!SnapPacket())         snapPkt = *p;

            void putVec3(Vec3 v) {
                buf.put(format(`[%f,%f,%f]`, v.x, v.y, v.z));
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
                import tools.xfrm_transform : XfrmTransformTool;
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
                        foreach (i, v; subj.mesh.vertices) {
                            if (i) buf.put(",");
                            float w = evaluateFalloff(*fpp, v, cast(int) i, subj.viewport);
                            // Honor the block's documented [0,1] contract for
                            // EVERY falloff type: Screen/Lasso weights project
                            // through the viewport (perspective divide can go
                            // non-finite for a vert at/behind the camera) and
                            // custom cubic-Bezier shapes can overshoot [0,1].
                            // Guard so the emitter never produces nan/inf/out-of-
                            // range (invalid JSON / broken wire contract).
                            if (!isFinite(w)) w = 0.0f;
                            else if (w < 0.0f) w = 0.0f;
                            else if (w > 1.0f) w = 1.0f;
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

        // Phase 7.3a: /api/snap query bridge. Lets unit tests probe
        // the snap math directly with explicit cursor world pos +
        // screen pixel + excludeVerts, without driving an interactive
        // Move drag through play-events. Read-only — same quiescence
        // expectation as toolpipeEvalProvider above.
        httpServer.setSnapQueryProvider((string body_) {
            import std.array       : appender;
            import std.format      : format;
            import std.json        : parseJSON, JSONType, JSONValue;
            import std.conv        : to;
            import toolpipe.pipeline       : g_pipeCtx;
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
            if (g_pipeCtx !is null) {
                import operator        : VectorStack;
                SubjectPacket subj;
                subj.mesh             = &mesh();
                subj.editMode         = editMode;
                subj.viewport         = vp;
                VectorStack vts;
                vts.put(&subj);
                g_pipeCtx.pipeline.evaluate(vts);
                if (auto sp = vts.get!SnapPacket()) cfg = *sp;
            }

            // Stage 3 D6: just-in-time item-frame install so the HTTP thread
            // never races the render-thread's per-frame install. Build the same
            // frames the render loop would, but from the current document state.
            {
                import snap : setItemSnapFrames, ItemSnapFrame;
                ItemSnapFrame[] itemFrames;
                foreach (lyr; document.layers) {
                    if (!lyr.visible) continue;
                    itemFrames ~= buildItemFrame(lyr);
                }
                setItemSnapFrames(itemFrames);
            }

            SnapResult sr = snapCursor(cursor, sx, sy, vp, mesh, cfg, exclude);

            buf.put(format(
                `{"snapped":%s,"highlighted":%s,"targetType":%d,`
              ~ `"targetIndex":%d,"targetSource":%d,"constraintType":%d,`
              ~ `"worldPos":[%f,%f,%f],"highlightPos":[%f,%f,%f]}`,
                sr.snapped ? "true" : "false",
                sr.highlighted ? "true" : "false",
                cast(int)sr.targetType,
                sr.targetIndex,
                sr.targetSource,
                cast(int)sr.constraintType,
                sr.worldPos.x, sr.worldPos.y, sr.worldPos.z,
                sr.highlightPos.x, sr.highlightPos.y, sr.highlightPos.z));
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
              ~ `"targetIndex":%d,"targetSource":%d,"worldPos":[%f,%f,%f],`
              ~ `"highlightPos":[%f,%f,%f]}`,
                sr.snapped ? "true" : "false",
                sr.highlighted ? "true" : "false",
                cast(int)sr.targetType,
                sr.targetIndex,
                sr.targetSource,
                sr.worldPos.x, sr.worldPos.y, sr.worldPos.z,
                sr.highlightPos.x, sr.highlightPos.y, sr.highlightPos.z));
            return buf.data;
        });

        // /api/constrain — POST. Probe the constraint math directly with an
        // explicit `pos` world point. Evaluates the pipeline to pull the live
        // ConstrainPacket, snapshots the background sources, and returns the
        // projected point. Mirrors /api/snap; read-only (HTTP thread safe).
        httpServer.setConstrainQueryProvider((string body_) {
            import std.array       : appender;
            import std.format      : format;
            import std.json        : parseJSON, JSONType, JSONValue;
            import std.conv        : to;
            import toolpipe.pipeline   : g_pipeCtx;
            import toolpipe.packets    : ConstrainPacket, SubjectPacket;
            import snap                : backgroundSourcesSnapshot;
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
            if (g_pipeCtx !is null) {
                import operator : VectorStack;
                SubjectPacket subj;
                subj.mesh     = &mesh();
                subj.editMode = editMode;
                subj.viewport = vp;
                VectorStack vts;
                vts.put(&subj);
                g_pipeCtx.pipeline.evaluate(vts);
                if (auto cp = vts.get!ConstrainPacket()) cfg = *cp;
            }

            auto bgSrc = backgroundSourcesSnapshot();
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
                `{"projected":%s,"resultPos":[%f,%f,%f]}`,
                hit ? "true" : "false",
                result.x, result.y, result.z));
            return buf.data;
        });

        // /api/path — evaluate the PATH stage at a requested t and return
        // value/tangent/length as JSON. Marshaled onto the main thread via
        // tickPath() using a dedicated epoch pair (NOT the pipeEval pair).
        httpServer.setPathQueryProvider((float t) {
            import std.array         : appender;
            import std.format        : format;
            import toolpipe.pipeline : g_pipeCtx;
            import toolpipe.packets  : SubjectPacket, PathPacket;
            import operator          : VectorStack;
            import path              : pathValue, pathTangent, pathLength;

            if (g_pipeCtx is null)
                return `{"error":"pipeline not initialised"}`;

            SubjectPacket subj;
            subj.mesh     = &mesh();
            subj.editMode = editMode;
            subj.viewport = vpm.activeSnapshot();

            VectorStack vts;
            vts.put(&subj);
            g_pipeCtx.pipeline.evaluate(vts);

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
                `{"enabled":true,"value":[%f,%f,%f],"tangent":[%f,%f,%f],"length":%f}`,
                val.x, val.y, val.z,
                tan.x, tan.y, tan.z,
                len);
        });

        // Helper: inject _positional args from the argstring pipeline into
        // tool.* commands. Called from inside setCommandHandler after the
        // generic injectParamsInto pass. Extracted to keep the handler tidy.
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
                            else if (pos[0].type == JSONType.string)   { try { la.setIndex(pos[0].str.to!int); } catch (Exception) {} }
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
            } else if (auto uvp = cast(UiViewportPropsCommand)cmd) {
                // ui.viewportProps <show|hide> (test-only).
                if (auto pp = "_positional" in pj) {
                    if (pp.type == JSONType.array) {
                        auto pos = pp.array;
                        if (pos.length >= 1 && pos[0].type == JSONType.string)
                            uvp.setVisible(pos[0].str);
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

        // Assign the named delegate declared in outer scope so that the UI
        // replay button calls the same dispatch path as /api/command.
        commandHandlerDelegate = (string id, string paramsJson) {
            import std.json : parseJSON, JSONType;
            import commands.file.load : FileLoad;
            import commands.file.save : FileSave;
            import params : injectParamsInto;

            // viewport.view <preset> — camera-only preset switch, no undo entry.
            // Sets the active viewport's projection kind and axis preset.
            // Axis presets (Top/Bottom/Front/Back/Right/Left) → ProjKind.Ortho;
            // Perspective/Camera → ProjKind.Perspective.
            if (id == "viewport.view") {
                import view : ProjKind, ViewPreset;
                import viewport : applyCellViewPreset;
                string presetStr = "";
                if (paramsJson.length > 0) {
                    auto pjv = parseJSON(paramsJson);
                    if (pjv.type == JSONType.string) {
                        // Raw string param (e.g. from JSON {"command":"viewport.view","params":"Top"}).
                        presetStr = pjv.str;
                    } else if (pjv.type == JSONType.object) {
                        if (auto pp = "_positional" in pjv) {
                            if (pp.type == JSONType.array && pp.array.length >= 1
                                && pp.array[0].type == JSONType.string)
                                presetStr = pp.array[0].str;
                        }
                        if (presetStr.length == 0) {
                            if (auto pp = "preset" in pjv)
                                if (pp.type == JSONType.string) presetStr = pp.str;
                        }
                    }
                }
                // Map string → preset. projKind is derived from the preset
                // by the shared helper (Perspective/Camera → Perspective,
                // every axis preset → Ortho) — same mapping this switch used
                // to hardcode per-case.
                ViewPreset vp3preset = ViewPreset.Perspective;
                switch (presetStr) {
                    case "Top":         vp3preset = ViewPreset.Top;         break;
                    case "Bottom":      vp3preset = ViewPreset.Bottom;      break;
                    case "Front":       vp3preset = ViewPreset.Front;       break;
                    case "Back":        vp3preset = ViewPreset.Back;        break;
                    case "Right":       vp3preset = ViewPreset.Right;       break;
                    case "Left":        vp3preset = ViewPreset.Left;        break;
                    case "Camera":      vp3preset = ViewPreset.Camera;      break;
                    default:            vp3preset = ViewPreset.Perspective; break;
                }
                // Hardwired to the ACTIVE cell (viewport.view does not do
                // ?viewport=N resolution — that's the separate camera-set
                // handler registered via setCameraSetHandler; adding it here
                // would be scope creep for task 0215).
                applyCellViewPreset(vpm.views[vpm.activeId], vp3preset);
                return;
            }

            // viewport.layout <preset> — switch layout (Single/SplitH/SplitV/Quad).
            if (id == "viewport.layout") {
                import viewport : LayoutPreset;
                string presetStr = "";
                if (paramsJson.length > 0) {
                    auto pjv = parseJSON(paramsJson);
                    if (pjv.type == JSONType.string) {
                        presetStr = pjv.str;
                    } else if (pjv.type == JSONType.object) {
                        if (auto pp = "_positional" in pjv) {
                            if (pp.type == JSONType.array && pp.array.length >= 1
                                && pp.array[0].type == JSONType.string)
                                presetStr = pp.array[0].str;
                        }
                        if (presetStr.length == 0) {
                            if (auto pp = "preset" in pjv)
                                if (pp.type == JSONType.string) presetStr = pp.str;
                        }
                    }
                }
                LayoutPreset lp = LayoutPreset.Single;
                switch (presetStr) {
                    case "SplitH": lp = LayoutPreset.SplitH; break;
                    case "SplitV": lp = LayoutPreset.SplitV; break;
                    case "Quad":   lp = LayoutPreset.Quad;   break;
                    default:       lp = LayoutPreset.Single;  break;
                }
                vpm.applyLayout(lp);
                // Mirrors the recentFiles/lastDir/toolDefaults precedent: just
                // update g_prefs in-memory here, no per-command file write —
                // it flushes to disk once at clean shutdown (persistPrefsOnExit,
                // gated on prefsActive). Harmless no-op in --test (never saved).
                g_prefs.viewportLayout = lp;
                return;
            }

            // viewport.indCenter/indScale/indRotate <yes|no> — per-cell independence
            // flags, camera-only, no undo entry.
            if (id == "viewport.indCenter" || id == "viewport.indScale" || id == "viewport.indRotate") {
                bool val = true;
                if (paramsJson.length > 0) {
                    auto pjv = parseJSON(paramsJson);
                    string s = "";
                    if (pjv.type == JSONType.string) {
                        s = pjv.str;
                    } else if (pjv.type == JSONType.object) {
                        if (auto pp = "_positional" in pjv) {
                            if (pp.type == JSONType.array && pp.array.length >= 1
                                && pp.array[0].type == JSONType.string)
                                s = pp.array[0].str;
                        }
                        if (s.length == 0) {
                            if (auto pp = "value" in pjv)
                                if (pp.type == JSONType.string) s = pp.str;
                        }
                    }
                    // Tolerant parse: "no"/"false"/"0" → false; anything else → true
                    if (s == "no" || s == "false" || s == "0") val = false;
                }
                if (id == "viewport.indCenter")       vpm.views[vpm.activeId].indCenter = val;
                else if (id == "viewport.indScale")   vpm.views[vpm.activeId].indScale  = val;
                else                                  vpm.views[vpm.activeId].indRotate = val;
                vpm.views[vpm.activeId].dirty = true;
                return;
            }

            // viewport.master <id> — set per-cell master override, camera-only, no undo.
            if (id == "viewport.master") {
                int mid = -1;
                if (paramsJson.length > 0) {
                    auto pjv = parseJSON(paramsJson);
                    string s = "";
                    if (pjv.type == JSONType.integer)      { mid = cast(int)pjv.integer; }
                    else if (pjv.type == JSONType.uinteger){ mid = cast(int)pjv.uinteger; }
                    else if (pjv.type == JSONType.float_)  { mid = cast(int)pjv.floating; }
                    else if (pjv.type == JSONType.string)  { s = pjv.str; }
                    else if (pjv.type == JSONType.object) {
                        if (auto pp = "_positional" in pjv) {
                            if (pp.type == JSONType.array && pp.array.length >= 1) {
                                auto v0 = pp.array[0];
                                if (v0.type == JSONType.integer)      mid = cast(int)v0.integer;
                                else if (v0.type == JSONType.uinteger) mid = cast(int)v0.uinteger;
                                else if (v0.type == JSONType.float_)   mid = cast(int)v0.floating;
                                else if (v0.type == JSONType.string)   s = v0.str;
                            }
                        }
                    }
                    if (s.length > 0) {
                        import std.conv : to, ConvException;
                        try { mid = to!int(s); } catch (ConvException) { /* keep -1 */ }
                    }
                }
                // Out-of-range clamps to -1 (self via group master at resolve time).
                if (mid < -1 || mid >= vpm.cellCount) mid = -1;
                vpm.views[vpm.activeId].masterId = mid;
                vpm.views[vpm.activeId].dirty = true;
                return;
            }

            auto factory = id in reg.commandFactories;
            if (factory is null)
                throw new Exception("unknown command id '" ~ id ~ "'");
            auto cmd = (*factory)();

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
                        if (!taq.apply())
                            throw new Exception("command '" ~ id ~ "' did not apply");
                        if (httpServer !is null)
                            httpServer.setCmdResult(taq.queryResultJsonOrEmpty());
                        return;
                    }
                }
                if (auto tpaq = cast(ToolPipeAttrCommand)cmd) {
                    if (tpaq.isQuery()) {
                        if (!tpaq.apply())
                            throw new Exception("command '" ~ id ~ "' did not apply");
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
                        if (!laq.apply())
                            throw new Exception("command '" ~ id ~ "' did not apply");
                        if (httpServer !is null)
                            httpServer.setCmdResult(laq.queryResultJsonOrEmpty());
                        return;
                    }
                }
                // Refire (undo/redo migration P4): a panel-param-edit session on
                // an opted-in tool routes a tool.attr through the tool's own
                // buildRefireCommand() rather than firing the (non-undoable)
                // tool.attr command itself. Each tick reverts the previous live
                // command and applies the freshly-evaluated one, so refireEnd
                // lands ONE entry reflecting the LAST param value. The attr is
                // injected onto the tool first (with the tool marked refire-
                // driving so its internal preview stays inert), then the rebuilt
                // command is fired. Non-tool.attr commands inside a refire window
                // (and non-opted-in tools) keep the plain fire(cmd) path.
                if (history.refireActive
                    && id == "tool.attr"
                    && activeTool !is null
                    && activeTool.wantsRefire()) {
                    activeTool.setRefireDriving(true);
                    scope(exit) activeTool.setRefireDriving(false);
                    if (!cmd.apply())   // inject attr onto the tool's inner cmd
                        throw new Exception("command '" ~ id ~ "' did not apply");
                    auto refireCmd = activeTool.buildRefireCommand();
                    if (refireCmd !is null) {
                        if (!history.fire(refireCmd))
                            throw new Exception(
                                "refire command did not apply");
                    }
                } else {
                    // Programmatic command-dispatch path: route through
                    // recordCoalescing() so consecutive COMPATIBLE delta edits
                    // (same targets, same edit label) collapse into a single
                    // undo entry. compareOp() defaults to Different for every
                    // command except the opted-in delta edit, so every other
                    // command appends exactly as record() would. Interactive
                    // tool commits stay on record() (one entry per gesture).
                    applyOrRefire(cmd, RecordMode.Coalescing,
                                  "command '" ~ id ~ "' did not apply");
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
        };
        httpServer.setCommandHandler(commandHandlerDelegate);

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
        formsInteractiveDispatch = (string id, string paramsJson) {
            formsInteractiveLatch = true;
            scope(exit) formsInteractiveLatch = false;
            commandHandlerDelegate(id, paramsJson);
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
            try {
                commandHandlerDelegate(parsed.commandId, parsed.params.toString());
            } catch (Exception) {
                // Replay is best-effort; the panel has no error-reporting UI.
            }
        };

        httpServer.setUndoHandler(() {
            return history.undo();
        });
        httpServer.setRedoHandler(() {
            return history.redo();
        });
        // History panel Phase 2 — multi-step jump via /api/history/jump.
        httpServer.setJumpHandler((size_t target) {
            return history.jumpToVisible(target);
        });
        httpServer.setHistoryProvider(() {
            // JSON: { "undo": [{"label":..,"args":..,"command":..,"ui":bool,
            //                   "inSession":bool,"refire":bool,"runId":N}, ...],
            //         "redo":[..] }
            // "ui" is true when the entry is UI-undo class (selection / edit-mode
            // state) rather than Model-undo (geometry) — see HistoryFlags.UiUndo.
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
                redoArr ~= obj;
            }
            JSONValue payload = JSONValue.emptyObject;
            payload["undo"] = JSONValue(undoArr);
            payload["redo"] = JSONValue(redoArr);
            return payload.toString();
        });

        // Read-only undo-service status for automation: {state, lockout,
        // canUndo, canRedo, modelDepth, uiDepth, canUndoModel, canUndoUi}.
        // modelDepth/uiDepth — count of Model vs UI-class entries on the undo
        // stack; canUndoModel — whether a plain undo would step a Model entry
        // (false → B1 fallback to UI head). All are pure reads, safe on the
        // HTTP server thread.
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
            payload["canUndoUi"]          = JSONValue(history.canUndo() && !history.canUndoModel());
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
        // Tools call refireBegin/refireEnd directly; this endpoint exists
        // for HTTP-driven tests that want to verify the refire-coalescing
        // behavior without going through SDL.
        httpServer.setRefireHandler((string action) {
            if (action == "begin")     history.refireBegin();
            else if (action == "end") {
                history.refireEnd();
                // P4: if a refire session was driving an opted-in tool, tell it
                // the single entry has landed so its commit chokepoint
                // (deactivate/Apply) records nothing for the same edit.
                if (activeTool !is null && activeTool.wantsRefire())
                    activeTool.onRefireCommitted();
            }
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

        // Phase A.5: dispatch /api/select through the unified Command path
        // (MeshSelect) so selection changes land on the undo stack and
        // share the same snapshot/revert mechanism as everything else.
        httpServer.setSelectionHandler((string mode, int[] indices) {
            auto cmd = cast(MeshSelect)reg.commandFactories["mesh.select"]();
            cmd.setMode(mode);
            cmd.setIndices(indices);
            applyOrRefire(cmd, RecordMode.Record, "mesh.select did not apply");
        });

        // Phase A.5: dispatch /api/transform through MeshTransform command.
        httpServer.setTransformHandler((string kind, JSONValue params) {
            import math : Vec3;

            // Helper to read a 3-vector field with default value.
            Vec3 vec3From(string field, Vec3 def) {
                if (field !in params) return def;
                auto a = params[field].array;
                if (a.length != 3) throw new Exception("'" ~ field ~ "' must be [x,y,z]");
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
                if (field !in params) return def;
                auto n = params[field];
                switch (n.type) {
                    case JSONType.integer:  return cast(float)n.integer;
                    case JSONType.uinteger: return cast(float)n.uinteger;
                    case JSONType.float_:   return cast(float)n.floating;
                    default: throw new Exception("'" ~ field ~ "' must be a number");
                }
            }

            auto cmd = cast(MeshTransform)reg.commandFactories["mesh.transform"]();
            cmd.setKind(kind);
            cmd.setDelta (vec3From("delta",  Vec3(0, 0, 0)));
            cmd.setAxis  (vec3From("axis",   Vec3(0, 1, 0)));
            cmd.setAngle (floatFrom("angle", 0.0f));
            cmd.setFactor(vec3From("factor", Vec3(1, 1, 1)));
            cmd.setPivot (vec3From("pivot",  Vec3(0, 0, 0)));
            applyOrRefire(cmd, RecordMode.Record, "mesh.transform did not apply");
        });

        // Phase A.5: dispatch /api/reset through SceneReset command.
        // Note: scene.reset is undoable but since /api/reset is also used
        // by tests to bring vibe3d to a fresh state, we may want a way
        // to NOT push it onto the stack — handled via cmd.isUndoable in
        // future if needed.
        httpServer.setResetHandler((string primitiveType, bool empty, int param) {
            auto cmd = cast(SceneReset)reg.commandFactories["scene.reset"]();
            if (empty)
                cmd.setEmpty(true);
            else {
                cmd.setPrimitive(primitiveType);
                cmd.setPrimitiveParam(param);   // grid n / subdivcube levels
            }
            if (!cmd.apply())
                throw new Exception("scene.reset did not apply");
            // Viewport manager reset (layout / cellCount / activeId / per-cell
            // ortho preset / independence flags — nothing bleeds into the next
            // test on the shared --test instance) now happens INSIDE cmd.apply()
            // via the factory's onViewportReset delegate (V3: single reset
            // owner, same delegate file.new / bare scene.reset use) — no
            // second explicit call needed here.
            // The host now owns the no-tool falloff drag (step 3 of the
            // stage-gizmo refactor); a reset must drop any in-flight drag.
            pipeGizmoHost.cancelDrag();
            {
                import ai.debug_trace : clearLatestAiDebugTraces;
                clearLatestAiDebugTraces();
            }
            // A scene reset returns the editor to its known-good default state;
            // the AI master switch is off by default, so clear it too. Without
            // this, an earlier session (or an earlier test on the shared --test
            // instance) that enabled AI would leave `aiState.enabled` stuck on
            // across the reset (the test_ai_toggle "AI must default off" failure).
            aiState.setEnabled(false);
            // selTypeOrder is kept in lockstep with editMode by the
            // promoteGeometryType hook installed on the scene.reset factory — no
            // manual re-sync needed here (the old reverse-sync is deleted).
            history.record(cmd);
            // Discard any exploration pending on reset — the candidate set is
            // stale after a reset and any undo that follows belongs to the new
            // scene, not the pre-reset grab.
            aiExplore.discardPending();
        });

        // Test-only raw-mesh injection (POST /api/load-mesh). Parses the
        // JSON payload into Vec3 verts + uint[] faces, then dispatches the
        // MeshLoadRaw command on the main thread (GPU upload + cache refresh
        // need the GL/main thread). MeshLoadRaw re-validates degree / index
        // range before touching the live mesh.
        httpServer.setLoadMeshHandler((JSONValue params) {
            import math : Vec3;

            if ("vertices" !in params || params["vertices"].type != JSONType.array)
                throw new Exception("missing 'vertices' array field");
            if ("faces" !in params || params["faces"].type != JSONType.array)
                throw new Exception("missing 'faces' array field");

            double numFrom(JSONValue n) {
                switch (n.type) {
                    case JSONType.integer:  return cast(double)n.integer;
                    case JSONType.uinteger: return cast(double)n.uinteger;
                    case JSONType.float_:   return n.floating;
                    default: throw new Exception("vertex components must be numbers");
                }
            }

            auto vArr = params["vertices"].array;
            Vec3[] verts = new Vec3[](vArr.length);
            foreach (i, vj; vArr) {
                if (vj.type != JSONType.array || vj.array.length != 3)
                    throw new Exception("each vertex must be [x,y,z]");
                verts[i] = Vec3(cast(float)numFrom(vj.array[0]),
                                cast(float)numFrom(vj.array[1]),
                                cast(float)numFrom(vj.array[2]));
            }

            auto fArr = params["faces"].array;
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

            auto cmd = cast(MeshLoadRaw)reg.commandFactories["scene.loadMesh"]();
            cmd.setData(verts, faces);
            if (!cmd.apply())
                throw new Exception("scene.loadMesh did not apply");
            history.record(cmd);
        });
    }

    int lastMouseX, lastMouseY;

    // `running` is declared higher up so the file.quit factory
    // closure (registered earlier) can capture it.
    SDL_Event event;

    // -------------------------------------------------------------------------
    // Nested helpers — closures over main's locals
    // -------------------------------------------------------------------------

    void handleWindowEvent(ref SDL_WindowEvent we) {
        if (we.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
            if (playbackMode)
                SDL_SetWindowSize(window, we.data1, we.data2);
            SDL_GetWindowSize(window, &winW, &winH);
            SDL_GL_GetDrawableSize(window, &fbW, &fbH);
            layout.resize(winW, winH);
            glViewport(0, 0, fbW, fbH);
            initThickLineProgram(thickLineProgram, fbW, fbH);
            // Keep replay-time pixel remapping calibrated to the new layout.
            setReplayCurrentViewport(layout.vpX, layout.vpY,
                                     layout.vpW, layout.vpH, kFovY);

            // Single event-driven writer of the picking region (vpm.l*) and
            // reflow of the live cells' rects on a resize.  This is a near-
            // dead path in practice — the interactive ImGui window loop
            // re-stamps every cell's rect from GetContentRegionAvail/
            // GetCursorScreenPos on the very next frame, and --test never
            // resizes the window — but it keeps vpm.l* (read by
            // viewportUnderCursor/applyLayout) coherent for the narrow
            // window between this event and that next stamp.  Only rects are
            // touched (NOT a full applyLayout, which would also reset
            // independence/preset).
            vpm.lx = layout.vpX; vpm.ly = layout.vpY;
            vpm.lw = layout.vpW; vpm.lh = layout.vpH;
            int[4] _rxs, _rys, _rws, _rhs;
            ViewportManager.cellRectsFor(vpm.layout, vpm.lx, vpm.ly, vpm.lw, vpm.lh,
                                         _rxs, _rys, _rws, _rhs);
            foreach (k; 0 .. vpm.cellCount) {
                vpm.views[k].winX = _rxs[k]; vpm.views[k].winY = _rys[k];
                vpm.views[k].winW = _rws[k]; vpm.views[k].winH = _rhs[k];
            }
        }
    }

    // Run a Command through the same dispatch the HTTP /api/command path
    // uses: refire-aware apply, history.record on success. Used by both
    // keyboard shortcut and UI-button click sites so they're uniformly
    // undoable. Silently no-ops on null / apply()-failure (e.g. file.load
    // when the user cancels the native dialog).
    void runCommand(Command cmd) {
        if (cmd is null) return;
        applyOrRefire(cmd, RecordMode.Record, null);
    }

    // AI3D (task 0381) main-thread drain handler — the ONLY place the
    // controller's events touch app state. Reads immutable Ai3dEvent copies
    // (drained lock-free, ai3d.event_queue) and updates the modal snapshot;
    // the ONLY document mutation is the ai3d.importResult dispatch below,
    // run through the ordinary undoable runCommand path (one Model-undo
    // entry, layer identity preserved for undo/redo — commands/ai3d/
    // import_result.d). Never constructs/touches an HTTP/curl handle
    // itself — that only ever happens on the controller's worker thread.
    void onAi3dEvent(ref const Ai3dEvent ev) {
        final switch (ev.kind) {
            case Ai3dEventKind.health:
                ai3dModal.healthChecked   = true;
                ai3dModal.healthOk        = ev.healthOk;
                ai3dModal.healthProtocol  = ev.healthProtocol;
                ai3dModal.healthBackend   = ev.healthBackend;
                ai3dModal.healthObjCapable = ev.healthObjCapable;
                ai3dModal.healthMessage   = ev.message;
                break;
            case Ai3dEventKind.submitted:
                ai3dModal.jobId       = ev.jobId;
                ai3dModal.state       = "submitted";
                ai3dModal.stage       = "submitted";
                ai3dModal.progress    = 0.0;
                ai3dModal.errorCode    = null;
                ai3dModal.errorMessage = null;
                break;
            case Ai3dEventKind.status:
                ai3dModal.jobId    = ev.jobId;
                ai3dModal.state    = ev.state;
                ai3dModal.stage    = ev.stage;
                ai3dModal.progress = ev.progress;
                break;
            case Ai3dEventKind.downloaded:
                // A cancelled/late artifact is never imported: stageArtifact()
                // (ai3d.stage_artifact) only returns ok=true (which is the
                // sole condition job_controller.d posts `downloaded` under)
                // when cancellation was NEVER observed during the run — a
                // cancelled job instead terminates via the `terminal` case
                // below with state=="cancelled" and no `downloaded` event at
                // all (verified by test_ai3d_controller.d's cancel-while-
                // queued case: `!sawDownloaded`). No extra app-side guard
                // needed here.
                const prefixLen = ev.jobId.length < 8 ? ev.jobId.length : 8;
                auto imp = cast(Ai3dImportResult)
                    reg.commandFactories["ai3d.importResult"]();
                imp.setInput(ev.objPath, "AI 3D " ~ ev.jobId[0 .. prefixLen]);
                runCommand(imp);
                if (imp.succeeded()) {
                    ai3dModal.state        = "succeeded";
                    ai3dModal.errorCode    = null;
                    ai3dModal.errorMessage = null;
                } else {
                    // The worker job succeeded but the editor-side import did
                    // not (validation reject / unparseable file / empty mesh).
                    // Surface the REASON in the modal instead of the misleading
                    // "Done — imported as a new layer" — otherwise a silently
                    // rejected mesh (e.g. over the face-count budget) looks like
                    // success with no geometry.
                    ai3dModal.state        = "failed";
                    ai3dModal.errorCode    = imp.failureCode().length
                                             ? imp.failureCode() : "import_failed";
                    ai3dModal.errorMessage = imp.failureMessage().length
                                             ? imp.failureMessage()
                                             : "the generated model could not be imported";
                }
                break;
            case Ai3dEventKind.terminal:
                ai3dModal.state = ev.state;
                if (ev.code.length) {
                    ai3dModal.errorCode    = ev.code;
                    ai3dModal.errorMessage = ev.message;
                }
                break;
            case Ai3dEventKind.transportError:
                ai3dModal.state       = "failed";
                ai3dModal.errorCode    = ev.code;
                ai3dModal.errorMessage = ev.message;
                break;
        }
    }

    // Quad Remesh (source/remesh/remesh_job.d) per-frame tick. poll() is
    // non-blocking (a single tryWait() on the subprocess). On a
    // running->succeeded transition, fire the undoable `mesh.remesh` apply
    // through the ordinary runCommand path (one Model-undo entry —
    // commands/mesh/remesh.d) and clear the job; on running->failed,
    // capture the message for the modal and clear. Mirrors onAi3dEvent's
    // shape but simpler — no worker thread / event queue, since RemeshJob
    // is polled synchronously in this same thread.
    void tickRemeshJob() {
        remeshJob.poll();
        final switch (remeshJob.state()) {
            case RemeshJob.State.idle:
            case RemeshJob.State.running:
                break;
            case RemeshJob.State.succeeded:
                const nFaces = remeshJob.resultFaces().length;
                // Task 0386: on a region remesh, message() carries a non-fatal
                // "remeshed N of M region components (...)" note when some
                // components were too complex/degenerate to stitch (partial
                // success) — null on a fully clean run. Read it BEFORE
                // clear() below, which wipes it.
                const string partialNote = remeshJob.message();
                auto cmd = cast(Remesh) reg.commandFactories["mesh.remesh"]();
                runCommand(cmd);
                // runCommand can no-op: Remesh.evaluate rejects (returns false,
                // applied()==false) when every rebuilt face was dropped by the
                // out-of-range guard — the mesh is unchanged, so don't lie
                // "Done". Mirror onAi3dEvent's imp.succeeded() check.
                if (cmd.applied()) {
                    // The mesh changed (visible in the viewport) — the action
                    // happened, so auto-close the modal. A failed/no-op remesh
                    // (below) keeps it open so the error stays visible.
                    remeshLastError   = null;
                    remeshLastSummary = "Done -- " ~ nFaces.to!string ~ " faces"
                                      ~ (partialNote.length ? " (" ~ partialNote ~ ")" : "");
                    remeshModalPendingClose = true;
                } else {
                    remeshLastSummary = null;
                    remeshLastError   = "remesh produced no usable geometry";
                }
                remeshJob.clear();
                break;
            case RemeshJob.State.failed:
                remeshLastSummary = null;
                remeshLastError   = remeshJob.message();
                remeshJob.clear();
                break;
        }
    }

    // Intercept commands that surface an args dialog (the popup that
    // appears when invoking a command from a menu/button without
    // explicit arguments). Returns true if the dialog has been opened — the
    // caller then SKIPS its normal runCommand path. Returns false for all
    // other commands (no params, or id not found).
    bool tryOpenArgsDialog(string commandId) {
        auto factory = commandId in reg.commandFactories;
        if (factory is null) return false;
        auto cmd = (*factory)();
        if (cmd.params().length == 0) return false;
        argsDialog.open(cmd);
        return true;
    }

    // Run a command immediately with a baked argstring injected — used by
    // shortcut bindings that pin arguments (`mesh.subdivide: "D ccsds"`), so a
    // param-carrying command applies at once instead of popping the args dialog
    // (mirrors baking `poly.subdivide ccsds` into its keymap). Positional
    // args map onto params() in declaration order; `name:value` args match by
    // name. Injection writes through the same param pointers the dialog uses.
    // Returns false only if the id has no factory.
    bool runCommandWithArgs(string commandId, string argstr) {
        import std.json  : JSONValue, JSONType;
        import params    : injectParamsInto;
        import argstring : parseArgstring;
        auto factory = commandId in reg.commandFactories;
        if (factory is null) return false;
        auto cmd    = (*factory)();
        auto schema = cmd.params();
        if (argstr.length > 0 && schema.length > 0) {
            auto pj = parseArgstring(commandId ~ " " ~ argstr).params;
            if (pj.type == JSONType.object) {
                // Positional args → schema order (so "ccsds" fills `mode`).
                if (auto pos = "_positional" in pj)
                    if (pos.type == JSONType.array)
                        foreach (i, ref v; pos.array)
                            if (i < schema.length)
                                pj.object[schema[i].name] = v;
                injectParamsInto(schema, pj);
            }
        }
        runCommand(cmd);
        return true;
    }

    // Phase 7 of doc/operator_refactor_plan.md. Build a fresh
    // VectorStack for the current frame's tool dispatch — the engine
    // pre-evaluates `vts` once per input event and passes it down to
    // the tool's mouse/key handlers.
    // Stamps the SubjectPacket with mesh + selection + viewport, walks
    // the live toolpipe, and returns the populated stack. Callers
    // hold both the subject and the vts on their own stack so the
    // packet pointer stays valid for the duration of the dispatch.
    void buildToolVts(out SubjectPacket subj, ref VectorStack vts) {
        subj.mesh             = &mesh();
        subj.editMode         = editMode;
        subj.viewport         = vpm.inputSnapshot();
        vts.put(&subj);
        if (g_pipeCtx !is null)
            g_pipeCtx.pipeline.evaluate(vts);
    }

    // -------------------------------------------------------------------------
    // Task 0419 (campaign 0407 §V1.2) LATE ctx-wiring -- the 30 new EditorApp
    // members backing the UI-panel block (source/ui/panels.d). Placed HERE
    // (right after buildToolVts, the last of the six hook delegates to
    // become available) rather than in the 2873 ctx-assembly block:
    // activateToolById/runCommand/tryOpenArgsDialog/buildToolVts are nested
    // functions declared AFTER 2873, so wiring them there would capture
    // nothing. Everything below is safe to wire now: every pointer-backed
    // local is already declared, and every by-value (в) field's single
    // assignment (grep-verified -- see editor_app.d) already happened. The
    // main loop, well after this point, is the first panel call site, so it
    // always sees a fully-wired `app`. Full inventory:
    // doc/tasks/work/0419-app-decomp-panels.md.
    // -------------------------------------------------------------------------
    app.hoveredVertexPtr       = &hoveredVertex;
    app.hoveredEdgePtr         = &hoveredEdge;
    app.hoveredFacePtr         = &hoveredFace;
    app.activePanelIdxPtr      = &activePanelIdx;
    app.activeToolIdPtr        = &activeToolId;
    app.layerRenameIndexPtr    = &layerRenameIndex;
    app.layerRenameBufPtr      = &layerRenameBuf;
    app.faceSelEdgesCachePtr   = &faceSelEdgesCache;
    app.faceSelEdgesPrevSelPtr = &faceSelEdgesPrevSel;
    app.layoutPtr              = &layout;
    app.panelsPtr              = &panels;
    app.statusLineGroupsPtr    = &statusLineGroups;
    app.shortcutsPtr           = &shortcuts;
    app.gridVaoPtr             = &gridVao;
    app.gridOnlyVertCountPtr   = &gridOnlyVertCount;
    app.bgGpuByLayerPtr        = &bgGpuByLayer;

    app.shader                  = shader;
    app.checkerShader           = checkerShader;
    app.gridShader               = gridShader;
    app.formsPanel                = formsPanel;
    app.io                        = io;
    app.commandHandlerDelegate    = commandHandlerDelegate;
    app.formsInteractiveDispatch  = formsInteractiveDispatch;

    app.runCommand           = cast(void delegate(Command))&runCommand;
    app.tryOpenArgsDialog    = cast(bool delegate(string))&tryOpenArgsDialog;
    app.activateToolById     = cast(void delegate(string))&activateToolById;
    app.buildToolVts         = cast(void delegate(out SubjectPacket, ref VectorStack))&buildToolVts;
    app.anyFalloffActive     = cast(bool delegate())&anyFalloffActive;
    app.rebuildLoopHoverMask = cast(const(bool)[] delegate(int))&rebuildLoopHoverMask;

    // Interactive history-navigation chokepoint (undo/redo migration P0;
    // in-session record+consolidate Phase 1). MAIN-THREAD ONLY — never call
    // from the HTTP server thread (it touches activeTool).
    //
    // Gizmo gestures no longer hold an open session at idle: each Move drag
    // commits its own tagged in-session entry on mouse-up (record+consolidate
    // Phase 1), so an idle Move run leaves NOTHING to "cancel" — a Ctrl+Z just
    // pops the last in-session gesture entry via the plain history.undo() path
    // and resyncSession() re-baselines the still-live tool against the now-
    // current mesh. The residual cancel branch survives ONLY for an open PANEL
    // session (coalesce-until-drop value edits) and an open R/S gizmo session
    // (R/S per-gesture recording lands in a later phase) — both reported by
    // hasUncommittedEdit() ONLY when activeDrag is null, so a mid-gizmo-drag
    // Ctrl+Z still falls through to history.undo() and never aborts the live
    // drag. The UNDO direction always cancels an open edit ("a redo never
    // cancels an open session — there is nothing to redo into one" was the
    // original rule), but task 0232's Loop Slice standing preview (armed_)
    // needs a NARROW exception in the REDO direction: unlike the transient
    // panel/gizmo sessions this branch was written for, an armed preview can
    // sit on the mesh across an arbitrary number of frames, so a REDO reachable
    // while armed would otherwise apply on top of an uncommitted cut — and
    // resyncSession() would then re-baseline `before_` from that dirty mesh,
    // permanently baking the cut in. So the redo direction cancels ONLY when
    // the tool opts in via cancelsOnRedo() (LoopSliceTool ⇔ armed_); every
    // other tool — crucially the refire-based BoxTool live property edit, which
    // reports hasUncommittedEdit()==true yet MUST redo normally on Ctrl+Shift+Z
    // — keeps the pre-0232 "redo steps the stack" behavior. Cancelling first
    // has no history side effect (nothing was recorded while armed), so a
    // second press still reaches the real undo/redo.
    // Returns true if anything happened (edit cancelled OR stack moved).
    bool navHistory(bool isUndo) {
        // Mid-session per-step undo peel (task 0321) — checked BEFORE the
        // whole-edit cancel branch below, so a tool holding an internal
        // sequence of not-yet-committed steps (EdgeSliceTool's latched chain)
        // can peel exactly one step per Ctrl+Z instead of unwinding
        // everything. Default false on the base Tool ⇒ every other tool is
        // byte-identical.
        if (isUndo && activeTool !is null && activeTool.tryUndoStepInSession()) return true;
        if (activeTool !is null && activeTool.hasUncommittedEdit()
            && (isUndo || activeTool.cancelsOnRedo())) {
            activeTool.cancelUncommittedEdit();
            // Task 0400: a standing-preview tool (survivesEditCancel()==true —
            // LoopSliceTool/EdgeSliceTool) is never dropped by this cancel; the
            // reference editor's interactive undo never drops an active tool.
            // Every other tool keeps the pre-0400 cancel-then-drop behavior.
            if (activeTool !is null && !activeTool.hasUncommittedEdit()
                && !activeTool.survivesEditCancel()) {
                setActiveTool(null);
                activeToolId = "";
            }
            return true;
        }
        bool ok = isUndo ? history.undo() : history.redo();
        if (ok && activeTool !is null) activeTool.resyncSession();
        return ok;
    }

    void handleKeyDown(ref SDL_KeyboardEvent kev) {
        // Active tool gets first dibs on key events. Tools that handle keys
        // (e.g. PenTool's Enter/Backspace/Esc) return true to consume; tools
        // that don't override onKeyDown fall through to the default false
        // and the rest of the handler runs as before.
        SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts);
        if (activeTool && activeTool.onKeyDown(kev, vts)) return;

        // YAML-driven shortcut lookup (tool, command, editmode).
        string canon = canonFromEvent(kev.keysym.sym, cast(SDL_Keymod)kev.keysym.mod);
        if (canon.length > 0) {
            if (auto id = canon in shortcuts.toolIdByCanon) {
                activateToolById(*id);
                return;
            }
            if (auto id = canon in shortcuts.commandIdByCanon) {
                // Interactive history nav (Ctrl+Z / Ctrl+Shift+Z) goes through
                // the navHistory chokepoint so an active tool with an open live
                // edit gets a chance to cancel it (instead of popping a prior
                // committed step underneath the live preview). The command
                // FACTORIES stay raw — they are shared with macro/replay/
                // scripted history nav and must remain tool-agnostic.
                if (*id == "history.undo") { navHistory(true);  return; }
                if (*id == "history.redo") { navHistory(false); return; }
                // A binding that pinned arguments (baked "D ccsds") runs
                // immediately with them injected — no args dialog.
                if (auto argp = canon in shortcuts.argsByCanon) {
                    runCommandWithArgs(*id, *argp);
                    return;
                }
                if (!tryOpenArgsDialog(*id))
                    runCommand(reg.commandFactories[*id]());
                return;
            }
            if (auto id = canon in shortcuts.editModeByCanon) {
                // Route keys 1/2/3 through the selection-type funnel: it
                // promotes the SelType, sets editMode in lockstep, and drops the
                // active tool ONLY on a front-flip (pressing the key for the
                // mode you are already in does NOT drop the tool — Stage 1 B2).
                final switch (*id) {
                    case "vertices": switchGeometryType(EditMode.Vertices); break;
                    case "edges":    switchGeometryType(EditMode.Edges);    break;
                    case "polygons": switchGeometryType(EditMode.Polygons); break;
                }
                return;
            }
        }

        // Numpad view shortcuts (task 0215): 1/2/3 switch the hovered (else
        // active) viewport cell's view, toggling to the opposite face on a
        // repeat press of the same key; numpad `.` sets Perspective
        // (idempotent — repeat is a no-op). Read the SCANCODE (not keysym)
        // so this survives NumLock OFF — with NumLock off the keysym arrives
        // as SDLK_KP_END/KP_DOWN/…, but the scancode is always
        // SDL_SCANCODE_KP_1.. (bindbc-sdl scancode.d). Distinct from the
        // top-row Digit1..3 scancodes (30-32) driving edit-mode above — no
        // collision.
        //
        // Gate: this function has exactly ONE call site (the SDL_KEYDOWN
        // case below in processEvent), reached only AFTER that dispatcher's
        // own `if (io.WantTextInput && (KEYDOWN||KEYUP)) return true;` gate —
        // so io.WantTextInput is already guaranteed false by the time we get
        // here. io.WantCaptureKeyboard is NOT usable as an extra local guard
        // in this app: NavEnableKeyboard is enabled at boot (app.d ImGui
        // init), and per Dear ImGui's own doc comment WantCaptureKeyboard is
        // "also true ... when an imgui window is focused and navigation is
        // enabled" — i.e. true whenever ANY docked panel (incl. the Viewport
        // window itself) merely has nav focus, not just while a widget is
        // actively being edited. Verified empirically: it reads true for
        // EVERY keydown in --test (even a plain 'A' viewport.fit press,
        // which still fires normally because that path never checks it) —
        // gating on it here would make the numpad branch permanently dead
        // rather than test-mode-only, so it is intentionally NOT checked a
        // second time; the upstream WantTextInput gate is the real and
        // sufficient protection here, exactly as it already is for every
        // other shortcut this same function dispatches (tool activation,
        // commandIdByCanon, editModeByCanon — none of them re-check it
        // either).
        {
            import view : NumpadViewKey, nextViewForKey;
            import viewport : applyCellViewPreset;
            bool handled = true;
            NumpadViewKey nvKey;
            switch (kev.keysym.scancode) {
                case SDL_SCANCODE_KP_1:      nvKey = NumpadViewKey.One;    break;
                case SDL_SCANCODE_KP_2:      nvKey = NumpadViewKey.Two;    break;
                case SDL_SCANCODE_KP_3:      nvKey = NumpadViewKey.Three;  break;
                case SDL_SCANCODE_KP_PERIOD: nvKey = NumpadViewKey.Period; break;
                default: handled = false; break;
            }
            if (handled) {
                int cell = (vpm.hoveredId >= 0 && vpm.hoveredId < vpm.cellCount)
                    ? vpm.hoveredId : vpm.activeId;
                Viewport3D vcell = vpm.views[cell];
                applyCellViewPreset(vcell, nextViewForKey(vcell.camera.viewPreset, nvKey));
                return;
            }
        }

        // Ctrl+Z / Ctrl+Shift+Z are dispatched via shortcuts.yaml as the
        // history.undo / history.redo commands (registered in commandFactories
        // above) — see config/shortcuts.yaml.

        switch (kev.keysym.sym) {
            case SDLK_F1:
                recLog.close();
                recLog.open("recording.jsonl");
                recLog.writeViewportMeta(layout.vpX, layout.vpY,
                                         layout.vpW, layout.vpH, kFovY);
                logInfo("rec", "started → recording.jsonl");
                break;
            case SDLK_F2:
                recLog.close();
                logInfo("rec", "stopped");
                break;
            // Esc no longer quits — Ctrl+Q (file.quit) is the canonical
            // exit shortcut now. Leaving Esc unbound here means the key
            // falls through to the global / tool handlers (e.g. cancel
            // an in-progress lasso, deselect, …) instead of killing the
            // session by accident.
            case SDLK_SPACE:
                // Space drops an active tool; with no tool it cycles the
                // geometry mode. Route the cycle through the selection-type
                // funnel so selTypeOrder + the currentTypeChanged signal stay in
                // sync (the cycle always flips the front, hence always notes a
                // current-type change; the tool is already null so the in-funnel
                // tool-drop is a no-op).
                if (activeTool) setActiveTool(null);
                else switchGeometryType(
                    cast(EditMode)((cast(int)editMode + 1) % 3));
                break;
            case SDLK_TAB: {
                // Toggle subpatch flag on selected faces; if nothing is
                // selected, invert the flag globally. The preview rebuilds
                // next frame via mutationVersion bumped inside setSubpatch.
                mesh.syncSelection();
                bool any = mesh.hasAnySelectedFaces();
                foreach (fi; 0 .. mesh.faces.length) {
                    if (any && !mesh.isFaceSelected(fi))
                        continue;
                    mesh.setSubpatch(fi, !mesh.isFaceSubpatch(fi));
                }
                break;
            }
            case SDLK_MINUS:
                if (gizmoLevelIdx > 0) {
                    --gizmoLevelIdx;
                    setGizmoPixels(gizmoLevels[gizmoLevelIdx]);
                }
                break;
            case SDLK_EQUALS:
                if (gizmoLevelIdx < cast(int)gizmoLevels.length - 1) {
                    ++gizmoLevelIdx;
                    setGizmoPixels(gizmoLevels[gizmoLevelIdx]);
                }
                break;
            default: break;
        }
    }

    // Open an interactive selection edit session. Idempotent — repeated
    // calls before commitInteractiveSelEdit() are no-ops. Snapshot must be
    // captured BEFORE any pick/lasso/clear mutates the selection.
    void beginInteractiveSelEdit() {
        if (pendingSelOpen) return;
        mesh.syncSelection();
        pendingSelBefore     = SelectionSnapshot.capture(mesh);
        pendingSelBeforeMode = editMode;
        pendingSelOpen       = true;
    }

    // Close the session: capture post-state, build a MeshSelectionEdit and
    // record it if anything actually changed (selection arrays differ or
    // edit mode flipped). No-op when no session is open.
    void commitInteractiveSelEdit() {
        if (!pendingSelOpen) return;
        scope(exit) pendingSelOpen = false;

        mesh.syncSelection();
        auto after = SelectionSnapshot.capture(mesh);

        bool changed = (editMode != pendingSelBeforeMode)
                    || pendingSelBefore.selectedVertices != after.selectedVertices
                    || pendingSelBefore.selectedEdges    != after.selectedEdges
                    || pendingSelBefore.selectedFaces    != after.selectedFaces;
        if (!changed) return;

        auto cmd = (new MeshSelectionEdit(&mesh(), cameraView, editMode, &editMode))
            .setPromoteHook((EditMode m) => promoteGeometryType(m));
        cmd.setBefore(pendingSelBefore, pendingSelBeforeMode);
        cmd.setAfter (after,            editMode);
        // P5: coalesce consecutive interactive selects into one undo entry.
        // An intervening geometry/non-selection edit becomes the top entry, so
        // the next select's compareOp(top) = Different → new entry (automatic
        // gesture boundary). Selection-undo stays in its own UI-undo class.
        history.recordCoalescing(cmd);
    }

    // Forward-declared here (before the mouse handlers that capture it) and
    // assigned after pickVertices / pickEdges / pickFaces are defined further
    // down. handleMouseButtonDown / handleMouseMotion call it to pick at the
    // cursor immediately on press and on each drag motion; at call time the
    // delegate is bound.
    void delegate(int mx, int my) doSelectPickAt;

    // Last element triple resolved by doSelectPickAt, stashed so the mouse-DOWN
    // dispatch path can capture an interaction-log record (task 0027) WITHOUT
    // re-running the pick — and without the shared delegate body (also bound to
    // mouse-MOTION) emitting one record per motion event. Exactly one of these
    // is >= 0 per editMode (vertices/edges/polygons); all -1 = a background pick.
    int aiLastPickedVertex = -1;
    int aiLastPickedEdge   = -1;
    int aiLastPickedFace   = -1;

    // Forward-declared like doSelectPickAt (nested functions aren't visible
    // before their definition): bound below, near pickFaces. Re-runs the GPU
    // hover pick at a pixel so a mouse-DOWN element click-pick reads current
    // hover, not last frame's.
    void delegate(int mx, int my) refreshHoverPickAt;

    void handleMouseButtonDown(ref SDL_MouseButtonEvent btn) {
        // Viewport click → drop ImGui keyboard focus. The viewport is
        // raw OpenGL drawn under ImGui, so SDL clicks here don't reach
        // ImGui at all — without this, a previously-focused text input
        // (Filter, REPL, args dialog) keeps `io.WantTextInput` set
        // forever, and the event-loop guard at the top of
        // processSdlEvent() swallows EVERY subsequent KEYDOWN
        // (including Delete, Tab, 1/2/3 mode keys). User reported
        // "Delete doesn't work on selected polygons" — turned out the
        // History panel's Filter input was still focused after they
        // typed a search.
        if (viewportInputAllowed())
            ImGui.SetWindowFocus(null);
        if (btn.button == SDL_BUTTON_RIGHT) {
            import falloff_handles : screenFalloffActive, screenFalloffRMBDown,
                                     radialFalloffActive, radialFalloffRMBDown,
                                     elementFalloffActive, elementFalloffRMBDown;
            if (screenFalloffActive()) {
                screenFalloffRMBDown(btn.x, btn.y);
                return;
            }
            if (radialFalloffActive()) {
                SDL_Keymod mods = SDL_GetModState();
                bool ctrl = (mods & KMOD_CTRL) != 0;
                Viewport vp2 = vpm.originSnapshot();
                if (radialFalloffRMBDown(btn.x, btn.y, ctrl, vp2))
                    return;
                // Plane projection failed (camera aligned to plane);
                // fall through to lasso so the click isn't lost.
            }
            if (elementFalloffActive()) {
                Viewport vp2 = vpm.originSnapshot();
                if (elementFalloffRMBDown(btn.x, btn.y, vp2))
                    return;
                // Ray-parallel-to-camera-back is the only failure
                // mode (degenerate camera state); fall through.
            }
            // Give the ACTIVE tool first crack at RMB (task 0288). A tool may bind
            // RMB to its own gesture — Slice uses RMB as the gap-adjust drag
            // (dashed-circle + value HUD), and the live-edit tools cancel on RMB.
            // The falloff RMB handlers above kept their priority; if no tool
            // consumes the click, fall through to the RMB lasso select as before
            // (lasso runs with NO active tool, so it is unaffected).
            if (activeTool) {
                SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts);
                if (activeTool.onMouseButtonDown(btn, vts)) return;
            }
            rmbDragging = true;
            rmbPath = [ImVec2(cast(float)btn.x, cast(float)btn.y)];
            // RMB lasso mutates selection on mouseUp; snapshot now.
            beginInteractiveSelEdit();
            return;
        }
        if (activeTool) {
            // Refresh the hover pick at the click position BEFORE the tool sees
            // the event, so a tool that click-picks an element (XfrmTransformTool
            // under falloff.element) reads hover for THIS cursor, not the last
            // rendered frame's. Gated to a LEFT click on an element-hover tool —
            // the only case that reads g_hovered on mouse-down — so it never adds
            // a GPU readback to camera chords or non-picking tools. Ctrl is
            // ALLOWED (it's the axis-lock modifier the click-pick forwards as
            // ctrlMod): excluding it left the hover stale on a Ctrl+click, so the
            // first Ctrl element-move gesture failed to pick → no relocate, no
            // axis-lock (must mirror XfrmTransformTool's `pickAllowed` gate).
            // Alt stays excluded (Ctrl+Alt+LMB = camera zoom); Shift = sel-add.
            if (btn.button == SDL_BUTTON_LEFT && viewportInputAllowed()
                && refreshHoverPickAt !is null
                && !(SDL_GetModState() & (KMOD_ALT | KMOD_SHIFT))
                && (activeTool.wantsHoverForType(EditMode.Vertices)
                 || activeTool.wantsHoverForType(EditMode.Edges)
                 || activeTool.wantsHoverForType(EditMode.Polygons)))
                refreshHoverPickAt(btn.x, btn.y);
            SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts);
            if (activeTool.onMouseButtonDown(btn, vts)) return;
        }
        // No tool, but the host's falloff gizmo may own this click (drag an
        // endpoint). Must run BEFORE the bare-LMB selection-clear below so a
        // handle grab isn't treated as a deselect. Skip alt/ctrl chords (camera).
        if (activeTool is null && btn.button == SDL_BUTTON_LEFT
            && !(SDL_GetModState() & (KMOD_ALT | KMOD_CTRL))) {
            import toolpipe.packets : FalloffPacket;
            SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts);
            FalloffPacket fp;
            if (auto p = vts.get!FalloffPacket()) fp = *p;
            Viewport vpg = vpm.originSnapshot();
            if (pipeGizmoHost.tryClaimDown(btn, vpg, fp, pipeGizmoHost.ownPool()))
                return;
        }
        if (btn.button == SDL_BUTTON_LEFT && btn.clicks == 2 && activeTool is null) {
            // Double-click loop / connect — these mutate selection. Wrap as
            // an interactive edit so undo restores the prior selection.
            beginInteractiveSelEdit();
            if (editMode == EditMode.Edges)
                new SelectLoop(&mesh(), cameraView, editMode).apply();
            else
                new SelectConnect(&mesh(), cameraView, editMode).apply();
            commitInteractiveSelEdit();
            return;
        }
        if (btn.button == SDL_BUTTON_LEFT) {
            SDL_Keymod mods = SDL_GetModState();
            bool ctrl  = (mods & KMOD_CTRL)  != 0;
            bool alt   = (mods & KMOD_ALT)   != 0;
            bool shift = (mods & KMOD_SHIFT)  != 0;
            bool anyToolActive = activeTool !is null;

            // Capture pre-LMB selection snapshot now — BEFORE the bare-LMB
            // clear-selection branch below could mutate. If LMB ends up
            // being a camera drag (Alt / Ctrl+Alt / Alt+Shift), commit will
            // see no change and skip recording. Tool-driven LMB doesn't
            // need it (tools own their own undo plumbing).
            if (!anyToolActive && !alt)
                beginInteractiveSelEdit();

            if      (ctrl && alt)  dragMode = DragMode.Zoom;
            else if (alt && shift) dragMode = DragMode.Pan;
            else if (alt)          dragMode = DragMode.Orbit;
            else if (ctrl && !anyToolActive)  dragMode = DragMode.SelectRemove;
            else if (shift && !anyToolActive) dragMode = DragMode.SelectAdd;
            else if (!anyToolActive) {
                // No modifiers: clear selection for current mode
                if (editMode == EditMode.Vertices)
                    mesh.clearVertexSelection();
                else if (editMode == EditMode.Edges)
                    mesh.clearEdgeSelection();
                else if (editMode == EditMode.Polygons)
                    mesh.clearFaceSelection();
                dragMode = DragMode.Select;
            }
            lastMouseX = btn.x;
            lastMouseY = btn.y;

            // Pick immediately on press for select clicks. A stationary
            // click (button pressed and released with no intervening motion
            // event) otherwise relies on a render frame landing during the
            // brief hold to run the per-frame picker (pickEdges, line ~5597).
            // A CPU-starved host can skip that frame — under CI `-j $(nproc)`
            // the trailing shift+click in selection_edges_add.log occasionally
            // failed to add its edge ("expected 3 selected edges, got 2").
            // Drags already pick per motion event (see handleMouseMotion);
            // this makes the zero-motion case just as deterministic. selectEdge
            // / deselectEdge are idempotent, so a later hold-frame pick of the
            // same element is harmless.
            if ((dragMode == DragMode.Select
              || dragMode == DragMode.SelectAdd
              || dragMode == DragMode.SelectRemove)
                && doSelectPickAt !is null) {
                doSelectPickAt(btn.x, btn.y);

                // Element apply capture (task 0027). Gated to the mouse-DOWN
                // dispatch path ONLY — doSelectPickAt is also bound to
                // mouse-MOTION during a select-drag, so capturing inside its
                // body would emit one record per motion event. The triple was
                // stashed by the pick above; doSelectPickAt sets exactly one of
                // vertex/edge/face per editMode (others -1, or all -1 for a
                // background pick), so collectElementCandidates yields a single
                // real candidate at index 0 = the default winner = the element
                // the user actually applied. No advisor runs here, so
                // resolveElementCandidateDecision's appliedWinnerIndex == the
                // default winner.
                if (aiLogWriter.enabled) {
                    auto candidates = collectElementCandidates(
                        btn.x, btn.y,
                        aiLastPickedVertex, aiLastPickedEdge, aiLastPickedFace);
                    auto resolution = resolveElementCandidateDecision(candidates);
                    AiInteractionContext ctx;
                    ctx.phase = AiInteractionPhase.mouseDown;
                    ctx.defaultIntent = AiIntent.selectElement;
                    ctx.mouseX = btn.x;
                    ctx.mouseY = btn.y;
                    ctx.shift = shift;
                    ctx.ctrl = ctrl;
                    ctx.alt = alt;
                    ctx.activeToolId = activeToolId;
                    ctx.editModeId = aiEditModeId();
                    auto record = makeAiInteractionLogRecord(
                        aiLogSource, "elements", ctx, candidates,
                        resolution.advisor, resolution.appliedWinnerIndex);
                    aiLogWriter.append(record);
                }
            }
        }
    }

    void handleMouseButtonUp(ref SDL_MouseButtonEvent btn) {
        if (btn.button == SDL_BUTTON_RIGHT) {
            import falloff_handles : screenFalloffRMBUp, radialFalloffRMBUp,
                                     elementFalloffRMBUp;
            if (screenFalloffRMBUp())  return;
            if (radialFalloffRMBUp())  return;
            if (elementFalloffRMBUp()) return;
            // Active tool RMB gesture end (task 0288): if a tool owns this RMB
            // (it consumed the RMB-down, so no lasso is in flight — rmbDragging is
            // false), let it finish its gesture (Slice bakes the final gap here).
            if (activeTool && !rmbDragging) {
                SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts);
                if (activeTool.onMouseButtonUp(btn, vts)) return;
            }
            if (rmbPath.length >= 3) {
                SDL_Keymod mods = SDL_GetModState();
                bool shift = (mods & KMOD_SHIFT) != 0;
                bool ctrl  = (mods & KMOD_CTRL)  != 0;
                Viewport vp2 = vpm.originSnapshot();
                float[] pxs = new float[](rmbPath.length);
                float[] pys = new float[](rmbPath.length);
                foreach (i, p; rmbPath) { pxs[i] = p.x; pys[i] = p.y; }
                // GPU-pick-buffer-driven visibility for the lasso.
                // doc/lasso_gpu_pick_buffer_fix.md — replaces the old
                // CPU `Mesh.visibleVertices` occlusion test that was
                // O(V × F\_front) (multi-minute hang on heavy imports;
                // mitigated by a 4 K-vert threshold that disabled
                // occlusion entirely). The per-mode ID FBO that
                // `gpuSelect.pick(...)` already maintains for hover
                // selection bakes occlusion via its depth pre-pass;
                // reading it back gives per-VBO-entry visibility in
                // ~ms regardless of mesh size. We keep the strict
                // "all face verts inside polygon" / "both edge ends
                // inside" CPU lasso semantic (preserves the existing
                // test_lasso_select.d behaviour) — only the visibility
                // source changes.
                import gpu_select : SelectMode;
                SelectMode vbMode;
                final switch (editMode) {
                    case EditMode.Vertices: vbMode = SelectMode.Vertex; break;
                    case EditMode.Edges:    vbMode = SelectMode.Edge;   break;
                    case EditMode.Polygons: vbMode = SelectMode.Face;   break;
                }
                bool[] gpuVisible = gpuSelect.elementVisibility(
                    vbMode, mesh, gpu, vp2);

                bool preview = subpatchPreview.active;
                // Phase 3c — preview.mesh.vertices may be stale after
                // a fan-out-only drag; lasso needs fresh positions.
                if (preview && subpatchPreview.lastRefreshSkipNonFace) {
                    subpatchPreview.osdAccel.readLimitIntoPreview(
                        subpatchPreview.mesh);
                    subpatchPreview.lastRefreshSkipNonFace = false;
                }
                const pv = preview ? &subpatchPreview.mesh : null;

                if (editMode == EditMode.Polygons) {
                    if (!shift && !ctrl)
                        mesh.clearFaceSelection();
                    if (preview) {
                        // Per cage face: every preview child that is
                        // BOTH front-facing AND has at least one
                        // visible pixel (per GPU FBO) must have all
                        // its verts inside the lasso for the cage
                        // face to be selected.
                        bool[] cageAllInside = new bool[](mesh.faces.length);
                        bool[] cageVisited   = new bool[](mesh.faces.length);
                        cageAllInside[] = true;
                        foreach (fi; 0 .. pv.faces.length) {
                            uint cage = subpatchPreview.trace.faceOrigin[fi];
                            if (cage == uint.max || cage >= mesh.faces.length) continue;
                            auto face = pv.faces[fi];
                            if (face.length < 3) { cageAllInside[cage] = false; continue; }
                            Vec3 fn = pv.faceNormal(cast(uint)fi);
                            if (dot(fn, pv.vertices[face[0]] - vp2.eye) >= 0) continue;
                            // GPU visibility per PREVIEW face index.
                            // faceIdVbo writes preview-face indices,
                            // so `gpuVisible[fi]` is the right key.
                            if (gpuVisible !is null
                                && fi < gpuVisible.length
                                && !gpuVisible[fi]) continue;
                            cageVisited[cage] = true;
                            foreach (vi; face) {
                                float sx, sy, ndcZ;
                                if (!projectToWindow(pv.vertices[vi], vp2, sx, sy, ndcZ) ||
                                    !pointInPolygon2D(sx, sy, pxs, pys)) {
                                    cageAllInside[cage] = false;
                                    break;
                                }
                            }
                        }
                        foreach (fi; 0 .. mesh.faces.length) {
                            if (!cageVisited[fi] || !cageAllInside[fi]) continue;
                            symmetricSelectFace(&mesh(), vp2, editMode,
                                                cast(int)fi, /*deselect=*/ctrl);
                        }
                    } else {
                        // Cage mode — VBO entry IS cage face. faceIdVbo
                        // writes cage face indices; `gpuVisible[fi]`
                        // is direct.
                        foreach (fi; 0 .. mesh.faces.length) {
                            uint[] face = mesh.faces[fi];
                            if (face.length < 3) continue;
                            Vec3 fn = mesh.faceNormal(cast(uint)fi);
                            if (dot(fn, mesh.vertices[face[0]] - vp2.eye) >= 0) continue;
                            if (gpuVisible !is null
                                && fi < gpuVisible.length
                                && !gpuVisible[fi]) continue;
                            bool allInside = true;
                            foreach (vi; face) {
                                float sx, sy, ndcZ;
                                if (!projectToWindow(mesh.vertices[vi], vp2, sx, sy, ndcZ) ||
                                    !pointInPolygon2D(sx, sy, pxs, pys)) {
                                    allInside = false;
                                    break;
                                }
                            }
                            if (allInside) {
                                symmetricSelectFace(&mesh(), vp2, editMode,
                                                    cast(int)fi, /*deselect=*/ctrl);
                            }
                        }
                    }
                } else if (editMode == EditMode.Vertices) {
                    if (!shift && !ctrl)
                        mesh.clearVertexSelection();
                    // gpuVisible is indexed by VBO entry — in cage
                    // mode k == vertex idx; in subpatch mode k is
                    // the kept-preview-vert position. Walk pv (or
                    // mesh) vertices, count k as we go, gate on
                    // gpuVisible[k].
                    if (preview) {
                        size_t k = 0;
                        foreach (pi; 0 .. pv.vertices.length) {
                            uint cage = subpatchPreview.trace.vertOrigin[pi];
                            if (cage == uint.max) continue;
                            scope(exit) ++k;
                            if (gpuVisible !is null
                                && k < gpuVisible.length
                                && !gpuVisible[k]) continue;
                            float sx, sy, ndcZ;
                            if (!projectToWindow(pv.vertices[pi], vp2, sx, sy, ndcZ)) continue;
                            if (pointInPolygon2D(sx, sy, pxs, pys)) {
                                symmetricSelectVertex(&mesh(), vp2, editMode,
                                                      cast(int)cage, /*deselect=*/ctrl);
                            }
                        }
                    } else {
                        foreach (vi; 0 .. mesh.vertices.length) {
                            if (gpuVisible !is null
                                && vi < gpuVisible.length
                                && !gpuVisible[vi]) continue;
                            float sx, sy, ndcZ;
                            if (!projectToWindow(mesh.vertices[vi], vp2, sx, sy, ndcZ)) continue;
                            if (pointInPolygon2D(sx, sy, pxs, pys)) {
                                symmetricSelectVertex(&mesh(), vp2, editMode,
                                                      cast(int)vi, /*deselect=*/ctrl);
                            }
                        }
                    }
                } else if (editMode == EditMode.Edges) {
                    if (!shift && !ctrl)
                        mesh.clearEdgeSelection();
                    if (preview) {
                        // Per cage edge: every preview segment that
                        // is visible (GPU FBO) must have both
                        // endpoints inside lasso. VBO-segment-index
                        // matches `pei` after kept-edge filtering;
                        // walk pv.edges, count k as we go.
                        bool[] cageAllInside = new bool[](mesh.edges.length);
                        bool[] cageVisited   = new bool[](mesh.edges.length);
                        cageAllInside[] = true;
                        size_t k = 0;
                        foreach (pei; 0 .. pv.edges.length) {
                            uint cage = subpatchPreview.trace.edgeOrigin[pei];
                            if (cage == uint.max || cage >= mesh.edges.length) continue;
                            scope(exit) ++k;
                            if (gpuVisible !is null
                                && k < gpuVisible.length
                                && !gpuVisible[k]) continue;
                            uint a = pv.edges[pei][0], b = pv.edges[pei][1];
                            cageVisited[cage] = true;
                            float sxa, sya, ndcZa, sxb, syb, ndcZb;
                            if (!projectToWindow(pv.vertices[a], vp2, sxa, sya, ndcZa) ||
                                !projectToWindow(pv.vertices[b], vp2, sxb, syb, ndcZb) ||
                                !pointInPolygon2D(sxa, sya, pxs, pys) ||
                                !pointInPolygon2D(sxb, syb, pxs, pys)) {
                                cageAllInside[cage] = false;
                            } else {
                                // STRICT: both preview-segment endpoints must be
                                // un-occluded in the Edge ID-FBO. The probe is
                                // window-space / key-agnostic so no preview-to-cage
                                // vertex mapping is needed (we are asking "any
                                // surviving edge pixel near this window point").
                                import std.math : lround;
                                if (!gpuSelect.endpointVisibleEdgeFbo(
                                        cast(int)lround(sxa), cast(int)lround(sya),
                                        gpu, vp2) ||
                                    !gpuSelect.endpointVisibleEdgeFbo(
                                        cast(int)lround(sxb), cast(int)lround(syb),
                                        gpu, vp2)) {
                                    cageAllInside[cage] = false;
                                }
                            }
                        }
                        foreach (ei; 0 .. mesh.edges.length) {
                            if (!cageVisited[ei] || !cageAllInside[ei]) continue;
                            symmetricSelectEdge(&mesh(), vp2, editMode,
                                                cast(int)ei, /*deselect=*/ctrl);
                        }
                    } else {
                        foreach (ei; 0 .. mesh.edges.length) {
                            if (gpuVisible !is null
                                && ei < gpuVisible.length
                                && !gpuVisible[ei]) continue;
                            uint a = mesh.edges[ei][0], b = mesh.edges[ei][1];
                            float sxa, sya, ndcZa, sxb, syb, ndcZb;
                            if (!projectToWindow(mesh.vertices[a], vp2, sxa, sya, ndcZa)) continue;
                            if (!projectToWindow(mesh.vertices[b], vp2, sxb, syb, ndcZb)) continue;
                            if (pointInPolygon2D(sxa, sya, pxs, pys) &&
                                pointInPolygon2D(sxb, syb, pxs, pys)) {
                                // STRICT: both endpoints must be un-occluded in the
                                // Edge ID-FBO (depth-pre-pass baked). Probe a small
                                // window around each projected endpoint; reject the
                                // edge if either window has no surviving edge pixel.
                                // This is intentionally stricter than click (which
                                // only requires a surviving pixel near the cursor).
                                import std.math : lround;
                                if (!gpuSelect.endpointVisibleEdgeFbo(
                                        cast(int)lround(sxa), cast(int)lround(sya),
                                        gpu, vp2)) continue;
                                if (!gpuSelect.endpointVisibleEdgeFbo(
                                        cast(int)lround(sxb), cast(int)lround(syb),
                                        gpu, vp2)) continue;
                                symmetricSelectEdge(&mesh(), vp2, editMode,
                                                    cast(int)ei, /*deselect=*/ctrl);
                            }
                        }
                    }
                }
            }
            rmbDragging = false;
            rmbPath = null;
            // RMB lasso commit — close the selection edit session.
            commitInteractiveSelEdit();
            return;
        }
        if (activeTool) {
            SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts);
            activeTool.onMouseButtonUp(btn, vts);
        }
        // Release a host falloff-gizmo drag (no tool active). routeUp does NOT
        // bump the tweak generation — that bump is XfrmTransformTool-specific
        // and the no-tool path never bumped.
        if (activeTool is null && pipeGizmoHost.routeUp(btn))
            return;
        // When BoxTool commits a new face it appends geometry via mesh
        // primitives (addVertex / addFace), which publish a Geometry change on
        // the change-notification bus. The per-frame flush therefore delivers
        // Geometry on this same frame (event dispatch precedes the flush), and
        // the loop's pick-cache block does the resize + invalidate +
        // syncSelection. No explicit hand-off needed here any more (Stage 2).
        if (btn.button == SDL_BUTTON_LEFT) {
            dragMode = DragMode.None;
            // LMB up — close any open selection edit session. If the LMB
            // was a camera drag (no selection touched), commit is a no-op.
            commitInteractiveSelEdit();
        }
    }

    void handleMouseWheel(ref SDL_MouseWheelEvent wheel) {
        if (wheel.y == 0) return;
        // Coupled zoom (task 0217): a wheel zoom over a default follower
        // (e.g. an ortho Quad cell) writes the linkage owner's distance, not
        // the hovered cell's own (which resolvedSnapshot never reads unless
        // that cell has `viewport.indScale` on).
        int hid = vpm.hoveredId >= 0 ? vpm.hoveredId : vpm.activeId;
        vpm.scaleOwnerCamera(hid).zoom(wheel.y * 10);
    }

    void handleMouseMotion(ref SDL_MouseMotionEvent mot) {
        // Keep the queryMouse override in lockstep with the latest motion
        // event so picking in subsequent render frames reads the actual
        // cursor. Without this update, doSelectPickAt's setOverrideMouse
        // (only called during select-drag) latched stale coordinates on
        // the first drag, after which queryMouse forever returned that
        // position — so a later "clear-then-pick" click would re-select
        // the face under the old cursor instead of nothing.
        setOverrideMouse(mot.x, mot.y);
        {
            import falloff_handles : screenFalloffRMBDragging, screenFalloffRMBMotion,
                                     radialFalloffRMBDragging, radialFalloffRMBMotion,
                                     elementFalloffRMBDragging, elementFalloffRMBMotion;
            if (screenFalloffRMBDragging()) {
                screenFalloffRMBMotion(mot.x);
                return;
            }
            if (radialFalloffRMBDragging()) {
                Viewport vp2 = vpm.originSnapshot();
                radialFalloffRMBMotion(mot.x, mot.y, vp2);
                return;
            }
            if (elementFalloffRMBDragging()) {
                Viewport vp2 = vpm.originSnapshot();
                elementFalloffRMBMotion(mot.x, mot.y, vp2);
                return;
            }
        }
        if (rmbDragging)
            rmbPath ~= ImVec2(cast(float)mot.x, cast(float)mot.y);
        if (activeTool) {
            SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts);
            if (activeTool.onMouseMotion(mot, vts)) return;
        }
        // Host falloff-gizmo endpoint drag (no tool active). The gizmo writes
        // the new endpoint to the FalloffStage via tool.pipe.attr.
        if (activeTool is null && pipeGizmoHost.isDragging()) {
            Viewport vpg = vpm.originSnapshot();
            if (pipeGizmoHost.routeMotion(mot, vpg)) return;
        }
        if (dragMode == DragMode.None) return;

        SDL_Keymod mods = SDL_GetModState();
        bool ctrl  = (mods & KMOD_CTRL)  != 0;
        bool alt   = (mods & KMOD_ALT)   != 0;
        bool shift = (mods & KMOD_SHIFT)  != 0;

        bool modOk = (dragMode == DragMode.Zoom)      ? (ctrl && alt)
                   : (dragMode == DragMode.Pan)       ? (alt && shift)
                   : (dragMode == DragMode.Orbit)     ? (alt && !shift)
                   : (dragMode == DragMode.Select    ||
                      dragMode == DragMode.SelectAdd  ||
                      dragMode == DragMode.SelectRemove) ? true
                   : false;
        if (!modOk) { dragMode = DragMode.None; return; }

        int dx = mot.x - lastMouseX;
        int dy = mot.y - lastMouseY;

        // Coupled pan/zoom (task 0217): drag math (basis, screen-space delta)
        // always uses the ORIGIN cell's own camera (its ortho preset basis
        // for Pan; its own distance scale for Zoom), but the write target is
        // redirected to the linkage owner (scaleOwner/focusOwner) so a
        // default follower's drag moves the whole linked group instead of a
        // field `resolveFollow` never reads. A cell with `indScale`/
        // `indCenter` on (opt-in override) owns itself, so it zooms/pans
        // independently exactly as before.
        int originId = vpm.dragOriginId >= 0 ? vpm.dragOriginId : vpm.activeId;
        if      (dragMode == DragMode.Orbit && !vpm.originIsOrtho()) vpm.originCamera().orbit(dx, dy);
        else if (dragMode == DragMode.Zoom)  vpm.scaleOwnerCamera(originId).zoom(dx);
        else if (dragMode == DragMode.Pan ||
                 (dragMode == DragMode.Orbit && vpm.originIsOrtho())) {
            // Alt+LMB in an orthographic cell (task 0224): orbit is meaningless
            // in an axis-locked ortho view, so it pans instead — same coupled
            // focusOwner path as Alt+Shift+LMB (task 0217).
            Vec3 delta = vpm.originCamera().panDelta(dx, dy);
            vpm.focusOwnerCamera(originId).focus += delta;
        }

        // Select-drag: run the appropriate picker on EVERY motion event.
        // Without this, picks only happen once per render frame; in fast
        // event-playback scenarios (and any rapid drag) intermediate cursor
        // positions get skipped, missing verts/edges the cursor passed over.
        // The delegate is bound after the pickers are declared (see below).
        if ((dragMode == DragMode.Select
          || dragMode == DragMode.SelectAdd
          || dragMode == DragMode.SelectRemove)
            && doSelectPickAt !is null) {
            doSelectPickAt(mot.x, mot.y);
        }

        lastMouseX = mot.x;
        lastMouseY = mot.y;
    }

    void pickVertices(ref Viewport vp, bool doingCameraDrag) {
        // Freeze hover during an active tool drag (element-move haul): return
        // WITHOUT re-picking so the element picked at drag-start stays
        // highlighted instead of every vertex the moving cursor passes over.
        if (activeTool !is null && activeTool.isDragging()) return;
        hoveredVertex = -1;
        if (!viewportInputAllowed() || doingCameraDrag) return;
        // No active tool → only the current editMode picks. With an
        // active tool, defer to `wantsHoverForType` so tools like
        // XfrmTransformTool (with falloff.element wired) can opt in to multi-type hover regardless
        // of editMode (Stage 14.9).
        if (activeTool is null) {
            if (editMode != EditMode.Vertices) return;
        } else {
            if (!activeTool.wantsHoverForType(EditMode.Vertices)) return;
        }

        int mx, my;
        queryMouse(mx, my);

        // Offscreen ID buffer: GPU rasterises every cage vertex as a 1-px
        // point with `gl_VertexID + 1` as the ID, depth-tested against
        // the face surface so verts inside / behind opaque geometry
        // drop out. Subpatch mode maps VBO indices back to cage indices
        // via gpu.vertOriginGpu inside GpuSelectBuffer.pick.
        enum int PICK_RADIUS_PX = 4;
        int hit = gpuSelect.pick(SelectMode.Vertex, mx, my, PICK_RADIUS_PX,
                                  mesh, gpu, vp);
        if (hit < 0) return;

        hoveredVertex = hit;
        if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
            symmetricSelectVertex(&mesh(), vp, editMode,
                                  hoveredVertex, /*deselect=*/false);
        else if (dragMode == DragMode.SelectRemove)
            symmetricSelectVertex(&mesh(), vp, editMode,
                                  hoveredVertex, /*deselect=*/true);
    }

    void pickEdges(ref Viewport vp, bool doingCameraDrag) {
        if (activeTool !is null && activeTool.isDragging()) return;  // freeze hover mid-drag
        hoveredEdge = -1;
        if (!viewportInputAllowed() || doingCameraDrag) return;
        if (activeTool is null) {
            if (editMode != EditMode.Edges) return;
        } else {
            if (!activeTool.wantsHoverForType(EditMode.Edges)) return;
        }

        int mx, my;
        queryMouse(mx, my);

        // Offscreen ID buffer: GPU depth-tested per pixel, so the
        // returned ID is exactly the cage edge whose pixel sits closest
        // to the cursor among those NOT occluded by any face. The
        // picker handles its own cache + subpatch VBO→cage translation.
        enum int PICK_RADIUS_PX = 6;
        int hit = gpuSelect.pick(SelectMode.Edge, mx, my, PICK_RADIUS_PX,
                                  mesh, gpu, vp);

        if (hit < 0) return;
        hoveredEdge = hit;
        if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
            symmetricSelectEdge(&mesh(), vp, editMode,
                                hoveredEdge, /*deselect=*/false);
        else if (dragMode == DragMode.SelectRemove)
            symmetricSelectEdge(&mesh(), vp, editMode,
                                hoveredEdge, /*deselect=*/true);
    }

    void pickFaces(ref Viewport vp, bool doingCameraDrag) {
        if (activeTool !is null && activeTool.isDragging()) return;  // freeze hover mid-drag
        hoveredFace = -1;
        if (!viewportInputAllowed() || doingCameraDrag) return;
        if (activeTool is null) {
            if (editMode != EditMode.Polygons) return;
        } else {
            if (!activeTool.wantsHoverForType(EditMode.Polygons)) return;
        }

        int mx, my;
        queryMouse(mx, my);

        // BVH ray-cast (default) or GPU face re-render (VIBE3D_FACE_PICK=gpu).
        // BVH: O(log n) per pick, view-independent, no GL readback. Keyed on
        // (gpu.uploadVersion, source-mesh-address) — identical to gpu_select.d:31.
        // GPU path retained as oracle for A/B equivalence testing.
        int hit;
        if (useBvhFacePick) {
            const(Mesh)* srcMesh = subpatchPreview.active
                ? &subpatchPreview.mesh : &mesh();
            hit = bvhPick.pickFace(mx, my, vp, *srcMesh, gpu);
        } else {
            hit = gpuSelect.pick(SelectMode.Face, mx, my, /*r=*/0,
                                  mesh, gpu, vp);
        }
        if (hit < 0) return;

        hoveredFace = hit;
        if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
            symmetricSelectFace(&mesh(), vp, editMode,
                                hoveredFace, /*deselect=*/false);
        else if (dragMode == DragMode.SelectRemove)
            symmetricSelectFace(&mesh(), vp, editMode,
                                hoveredFace, /*deselect=*/true);
    }

    // Bind the picker delegate forward-declared at handleMouseMotion's
    // scope. queryMouse() pulls from the global override which the event
    // player updates in batch (per tickEventPlayer call); the override is
    // already at the LAST event's position by the time this delegate runs
    // for the FIRST event in the batch — so reset the override to (mx, my)
    // before each pick so the picker sees the right cursor.
    doSelectPickAt = (int mx, int my) {
        setOverrideMouse(mx, my);
        Viewport vp = vpm.activeSnapshot();
        int pickedVertex = -1;
        int pickedEdge = -1;
        int pickedFace = -1;
        if (editMode == EditMode.Vertices) {
            pickVertices(vp, false);
            pickedVertex = hoveredVertex;
        } else if (editMode == EditMode.Edges) {
            pickEdges(vp, false);
            pickedEdge = hoveredEdge;
        } else if (editMode == EditMode.Polygons) {
            pickFaces(vp, false);
            pickedFace = hoveredFace;
        }
        publishElementCandidates(mx, my, pickedVertex, pickedEdge, pickedFace);
        // Stash for the mouse-DOWN capture hook (cheap; the motion path runs
        // through here too but never reads these back, so it stays zero-cost).
        aiLastPickedVertex = pickedVertex;
        aiLastPickedEdge   = pickedEdge;
        aiLastPickedFace   = pickedFace;
    };

    // Synchronously re-run the GPU ID-buffer hover pick at (mx, my) and
    // publish g_hovered — the same vert>edge>face resolution + publish the
    // render loop does each frame (see the pick block in the frame body).
    // Called on mouse-DOWN, BEFORE the active tool's onMouseButtonDown, so a
    // tool's click-pick (XfrmTransformTool.tryPickElement under
    // falloff.element) reads hover for the CURRENT cursor rather than the
    // PREVIOUS frame's.
    //
    // Why it matters: g_hovered is otherwise refreshed only once per render
    // frame. On a fast click after a large cursor jump (e.g. pick element A,
    // then immediately click element B), the button-down is processed before
    // any frame re-picks B, so tryPickElement lands on the STALE element A.
    // The element-falloff drag then freezes A's anchor for the whole gesture
    // and only a later frame / the commit corrects it — the "falloff sits at
    // the previous click and the points snap to the new spot on release" bug.
    refreshHoverPickAt = (int mx, int my) {
        setOverrideMouse(mx, my);
        Viewport vp = vpm.activeSnapshot();
        pickVertices(vp, false);
        if (edgeCache.needsUpdate(vp)) { edgeCache.invalidate(); edgeCache.update(vp); }
        pickEdges(vp, false);
        if (faceCache.needsUpdate(vp)) { faceCache.invalidate(); faceCache.update(vp); }
        pickFaces(vp, false);
        int pickedVertex = hoveredVertex;
        int pickedEdge = hoveredEdge;
        int pickedFace = hoveredFace;
        // Tool-driven multi-type priority (vert first, then edge, then face),
        // mirroring the render-loop resolution so the published hover matches.
        if (activeTool !is null) {
            if (hoveredVertex >= 0) { hoveredEdge = -1; hoveredFace = -1; }
            else if (hoveredEdge >= 0) { hoveredFace = -1; }
        }
        publishElementCandidates(mx, my, pickedVertex, pickedEdge, pickedFace);
        import hover_state : g_hoveredVertex, g_hoveredEdge, g_hoveredFace;
        g_hoveredVertex = hoveredVertex;
        g_hoveredEdge   = hoveredEdge;
        g_hoveredFace   = hoveredFace;
    };

    // drawButtonOutline / drawRaisedBevel / renderStyledButton relocated to
    // source/ui/panels.d (task 0419 Phase 1 -- pure helpers, no EditorApp
    // dependency). `renderButton` below (nested in drawSidePanel, not yet
    // moved) still calls `renderStyledButton(...)` bare -- resolves via this
    // import instead of a sibling nested-function declaration.
    import ui.panels : drawButtonOutline, drawRaisedBevel, renderStyledButton;

    // Dispatch a single Action (used by `renderButton` and by popup-item
    // clicks). Tool/command/script branches mirror the inline logic in the
    // side-panel renderer; popup-as-an-action is a no-op (nested popups
    // are not currently supported — the outer popup would close before
    // an inner one could open).
    void dispatchAction(ref Action action) {
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
    void renderFalloffStackItems() {
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
            dispatchAction(a);
        }
    }

    // Expand a `kind: dynamic` popup item into runtime-generated rows.
    // The config declares only the provider key (dynamicKind:); the
    // actual rows depend on live state the YAML can't enumerate. New
    // providers add a branch here. Unknown keys render a disabled hint
    // rather than throwing mid-frame.
    void renderDynamicPopupItems(string kind) {
        switch (kind) {
            case "falloffStack":
                renderFalloffStackItems();
                break;
            default:
                ImGui.TextDisabled("(unknown dynamic '%s')", kind);
                break;
        }
    }

    // Render the body of a popup (between `BeginPopup` and `EndPopup`).
    // Action items dispatch via `dispatchAction`; dividers/headers are
    // non-interactive.
    void renderPopupItems(ref PopupItem[] items) {
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
                        dispatchAction(it.action);
                    if (blocked) {
                        ImGui.EndDisabled();
                        if (ImGui.IsItemHovered(ImGuiHoveredFlags.AllowWhenDisabled))
                            ImGui.SetTooltip("Requires libassimp — not loaded");
                    }
                    break;
                case PopupItemKind.submenu:
                    if (ImGui.BeginMenu(it.label)) {
                        renderPopupItems(it.subItems);
                        ImGui.EndMenu();
                    }
                    break;
                case PopupItemKind.dynamic:
                    renderDynamicPopupItems(it.dynamicKind);
                    break;
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

    void drawSidePanel() {
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
                        dispatchAction(action);
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
                        renderPopupItems(a.popupItems);
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

    void drawStatusBar() {
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
                    // near `main`. Every OTHER status-line button stays as
                    // today (no other action id is gated here).
                    bool aiGateBlocked = action.kind == ActionKind.command
                        && action.id == "ai.toggle" && !kAiToggleAvailable;
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
                            renderPopupItems(a.popupItems);
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

    // drawTabPanel relocated to source/ui/panels.d (task 0419 Phase 2 --
    // pilot CTX-panel; takes `EditorApp app`, called as `drawTabPanel(app)`
    // below).

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
    void drawLayerListPanel() {
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

    // drawViewportPropsPanel relocated to source/ui/panels.d (task 0419
    // Phase 3 -- takes `EditorApp app`, called as `drawViewportPropsPanel(app)`
    // below).

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
    void renderViewportSceneToFbo(Viewport3D v, ref Viewport vp,
                                   OverlayMode overlayMode,
                                   bool showVertHover, bool showEdgeHover,
                                   bool showFaceHover) {
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
        version (WithAI)
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

    // -------------------------------------------------------------------------
    // Main loop
    // -------------------------------------------------------------------------

    // Process one SDL event through the same path as the main loop's
    // SDL_PollEvent body. Used both:
    //   - inline by the main loop (one event per SDL_PollEvent), and
    //   - by EventPlayer for direct dispatch (skipping SDL_PushEvent and
    //     thus the X11 motion-event coalescing that drops most motion
    //     events when many are queued in a single PollEvent batch).
    // Returns true to keep the main loop running, false to quit.
    bool processEvent(SDL_Event* ev) {
        evLog.log(*ev);
        bool isF1orF2 = ev.type == SDL_KEYDOWN &&
            (ev.key.keysym.sym == SDLK_F1 || ev.key.keysym.sym == SDLK_F2);
        if (!isF1orF2) recLog.log(*ev);
        ImGui_ImplSDL2_ProcessEvent(ev);

        // Route through viewportInputAllowed() so mouse events over the docked
        // "Viewport" window still reach 3D picking/orbit (objection 1 fix).
        // In --test viewportInputAllowed()==!io.WantCaptureMouse → byte-identical.
        //
        // Drag-capture (task 0222): once a pointer gesture is ACTIVE
        // (`vpm.dragOriginId >= 0`, set on button-DOWN over a cell), the
        // remaining MOTION/UP events must reach the origin cell REGARDLESS of
        // where the cursor now is — over a panel, another Quad/Split cell, or
        // outside the window. Without this bypass an RMB-lasso (or LMB
        // box-select / camera drag) whose cursor left the origin cell had its
        // terminating UP swallowed by the gate → the gesture hung (lasso kept
        // drawing, selection never committed). The active-gesture guard lets
        // the UP through so handleMouseButtonUp always completes + clears it.
        // (SDL-level capture for the out-of-window case is already provided by
        // ImGui: the ##vpHit InvisibleButton becomes the active item on press,
        // and ImGui's SDL2 backend SDL_CaptureMouse()s while an item is active.)
        if (!testMode && !viewportInputAllowed() && vpm.dragOriginId < 0 &&
            (ev.type == SDL_MOUSEBUTTONDOWN ||
             ev.type == SDL_MOUSEBUTTONUP   ||
             ev.type == SDL_MOUSEMOTION      ||
             ev.type == SDL_MOUSEWHEEL))
            return true;

        if (io.WantTextInput &&
            (ev.type == SDL_KEYDOWN || ev.type == SDL_KEYUP))
            return true;

        // Phase 1c — input-router seam: compute hovered/active viewport per
        // mouse event.  With ONE viewport (Phase 1) viewportUnderCursor()
        // trivially returns 0 or −1, so activeId/hoveredId never leave 0 and
        // the block is a no-op that doesn't change behaviour.
        //
        // Phase 4 will (a) route camera-manip to hoveredCamera(), (b) gate
        // viewport input on hoveredId >= 0, (c) freeze the active Viewport3D
        // at gizmo-drag start — all in this block.
        {
            int _rtx = -1, _rty = -1;
            if (ev.type == SDL_MOUSEBUTTONDOWN || ev.type == SDL_MOUSEBUTTONUP) {
                _rtx = ev.button.x; _rty = ev.button.y;
            } else if (ev.type == SDL_MOUSEMOTION) {
                _rtx = ev.motion.x; _rty = ev.motion.y;
            } else if (ev.type == SDL_MOUSEWHEEL) {
                SDL_GetMouseState(&_rtx, &_rty);
            }
            if (_rtx >= 0) {
                vpm.hoveredId = vpm.viewportUnderCursor(_rtx, _rty);
                // Focus-follows-mouse: the active cell tracks the hovered one
                // on every positioned mouse event (motion/wheel/down/up), not
                // just on click — see ViewportManager.followHover() for the
                // dragOriginId pin + panel-hover fallback rationale.
                vpm.followHover();
                if (ev.type == SDL_MOUSEBUTTONDOWN && vpm.hoveredId >= 0) {
                    vpm.activeId     = vpm.hoveredId;
                    vpm.dragOriginId = vpm.hoveredId;
                }
                if (ev.type == SDL_MOUSEBUTTONUP)
                    vpm.dragOriginId = -1;
            }
        }

        switch (ev.type) {
            case SDL_QUIT:            return false;
            case SDL_WINDOWEVENT:     handleWindowEvent(ev.window);      break;
            case SDL_KEYDOWN:         handleKeyDown(ev.key);             break;
            case SDL_MOUSEBUTTONDOWN: handleMouseButtonDown(ev.button);  break;
            case SDL_MOUSEBUTTONUP:   handleMouseButtonUp(ev.button);    break;
            case SDL_MOUSEWHEEL:      handleMouseWheel(ev.wheel);        break;
            case SDL_MOUSEMOTION:     handleMouseMotion(ev.motion);      break;
            default: break;
        }
        return true;
    }

    // Register direct-dispatch delegate so EventPlayer.tick can deliver
    // events to the same code path without going through SDL's queue.
    setDirectEventDispatch((SDL_Event* ev) {
        if (!processEvent(ev)) running = false;
    });
    scope(exit) clearDirectEventDispatch();

    while (running) {
        // Perf (doc/frame_probe_scenarios_plan.md, task 0195): beginFrame is
        // the FIRST statement of the loop body; endFrame (below, before the
        // present/flush conditional) closes it. No-op in the default build.
        g_frames.beginFrame();

        // Perf: events phase — playback tick + HTTP event-player drain +
        // the SDL_PollEvent dispatch loop. `toolNs` (the live geometry apply
        // during a drag) nests INSIDE this region — see xfrm_transform.d's
        // applyFold site. Explicit block so the scope timer fires right
        // after the SDL_PollEvent loop, not at the end of the whole frame.
        // No-op in the default build.
        {
            auto zFramesEvents = g_frames.phase(Phase.events);
            // ---- Playback: push due events before polling ----
            if (playbackMode) evPlay.tick();
            // httpServer is always constructed now; only drain the request queues
            // when the listener is actually up (start() called). Skipped entirely
            // in a release/no-http run, where no thread ever posts requests.
            if (httpServer.running) {
                httpServer.tickEventPlayer();
                httpServer.tickAll();
            }

            // AI3D async controller drain (task 0381 Phase 2). Deliberately
            // OUTSIDE the `httpServer.running` guard above — the controller
            // (and the Phase 3 modal that drives it) must work in a normal
            // editor run with HTTP off, not only under --test/the HTTP
            // server. onAi3dEvent (near runCommand) is the only consumer;
            // drain() itself never blocks (copy-under-mutex, lock-free
            // delegate invoke — ai3d.event_queue).
            ai3dController.drain(&onAi3dEvent);

            // AI3D worker lifecycle (task 0403) per-frame poll — non-
            // blocking (tryWait() on whatever process this manager itself
            // spawned, if any). Same "always outside httpServer.running"
            // reasoning as the ai3d drain above.
            ai3dWorkerManager.pollWorker();
            ai3dWorkerManager.pollInstall();

            // Quad Remesh (source/remesh/remesh_job.d) per-frame poll —
            // same "always outside httpServer.running" reasoning as the
            // ai3d drain above: a normal editor run with HTTP off must still
            // be able to complete a remesh job. tickRemeshJob() never
            // blocks (a single non-blocking tryWait() on the subprocess).
            tickRemeshJob();

            // ---- Events ----
            while (SDL_PollEvent(&event)) {
                // In --test mode, drop real keyboard/mouse input from the
                // SDL queue so a stray click or keypress in the test window
                // can't mutate state and break a running test. The test
                // harness drives state via HTTP + EventPlayer's direct
                // dispatch, both of which bypass this queue. SDL_QUIT and
                // SDL_WINDOWEVENT stay routed so the window can still be
                // closed (X button / SIGINT).
                if (testMode &&
                    (event.type == SDL_KEYDOWN
                  || event.type == SDL_KEYUP
                  || event.type == SDL_TEXTINPUT
                  || event.type == SDL_MOUSEMOTION
                  || event.type == SDL_MOUSEBUTTONDOWN
                  || event.type == SDL_MOUSEBUTTONUP
                  || event.type == SDL_MOUSEWHEEL))
                    continue;
                if (!processEvent(&event)) {
                    running = false;
                    break;
                }
            }
        }

        // The per-frame force-feed that used to stamp the active camera with
        // the full 3D-area size (and the vpm.l* region write that went with
        // it) is gone — the cell rect has one owner now (Viewport3D.camera,
        // i.e. the cell's View; see viewport.d).  vpm.l* is written only by
        // the resize handler (handleWindowEvent), and the active cell's true
        // size is whatever the interactive window loop / cellRectsFor last
        // stamped onto its camera — no per-frame overwrite.
        Viewport vp = vpm.activeSnapshot();

        // ---- ε-exploration per-frame state machine (task 0033) ----
        // Tick the pending buffer with the current undo epoch + view matrix.
        // When not exploring (enabled()==false), step() returns None immediately
        // with no allocation — byte-identical to the pre-exploration path.
        // lastExploreGrab is set in the capture sink below when a grab arrives
        // while a pending is AwaitingRegrab; it is reset after each step().
        if (aiExplore.enabled && aiLogWriter.enabled && aiExplore.hasPending()) {
            // Re-grab detection: the capture sink sets lastExploreGrab when a
            // mouseDown fires while a pending is awaiting a re-grab.  The grab
            // is forwarded to step() and cleared afterward.
            auto res = aiExplore.step(history.undoEpoch(), vp.view,
                                       lastExploreGrab);
            lastExploreGrab = OptionalGrab();  // consume after step
            if (res.kind == ResolutionKind.Emit)
                aiLogWriter.append(res.record);
            // Discard and None both require no action (Discard already cleared
            // the pending buffer inside step()).
        }

        // Deferred layout-ini reload (Reset Layout button): pulls the
        // just-re-copied shipped default bytes into ImGui's LIVE in-memory
        // settings, so this session's own eventual autosave (or the
        // shutdown save at DestroyContext) reflects the shipped default
        // instead of re-persisting whatever dock arrangement was live
        // before the reset. Must run strictly BEFORE ImGui.NewFrame() —
        // LoadIniSettingsFromDisk is unsafe once a frame is in progress
        // (between NewFrame/EndFrame); the button handler itself runs
        // mid-frame, so it only sets the flag and this is where it's
        // actually consumed, exactly once.
        if (g_pendingLayoutReloadPathZ !is null) {
            import std.string : fromStringz;
            ImGui.LoadIniSettingsFromDisk(cast(string) fromStringz(g_pendingLayoutReloadPathZ));
            g_pendingLayoutReloadPathZ = null;
        }

        // ---- ImGui ----
        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplSDL2_NewFrame();
        ImGui.NewFrame();

        // ── Phase 0b: full-viewport DockSpace host ─────────────────────────
        // A transparent, no-chrome, no-input window that covers the entire
        // display and hosts the main dockspace with a PassthruCentralNode.
        //
        // PassthruCentralNode keeps the unoccupied centre mouse-transparent,
        // so the existing io.WantCaptureMouse guards pass through 3D input
        // exactly as before.  In --test mode IniFilename=null means the dock
        // layout is rebuilt from the DockBuilder script every launch; since
        // the Layers window is hidden in tests the whole dockspace becomes
        // the passthru central hole → test geometry is unchanged.
        //
        // ConfigViewportsEnable stays OFF throughout Phase 0 (no OS windows).
        {
            auto dsz = io.DisplaySize;
            ImGui.SetNextWindowPos(ImVec2(0, 0));
            ImGui.SetNextWindowSize(ImVec2(dsz.x, dsz.y));
            ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding,   0.0f);
            ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0.0f);
            ImGui.PushStyleColor(ImGuiCol.WindowBg, ImVec4(0, 0, 0, 0));
            immutable int dockHostFlags =
                ImGuiWindowFlags.NoDocking             |
                ImGuiWindowFlags.NoTitleBar            |
                ImGuiWindowFlags.NoCollapse            |
                ImGuiWindowFlags.NoResize              |
                ImGuiWindowFlags.NoMove                |
                ImGuiWindowFlags.NoBringToFrontOnFocus |
                ImGuiWindowFlags.NoNavFocus            |
                ImGuiWindowFlags.NoBackground;
            ImGui.Begin("##DockSpaceHost", null, dockHostFlags);
            ImGui.PopStyleColor(1);
            ImGui.PopStyleVar(2);

            ImGuiID dockspaceId = ImGui.GetID("MainDockSpace");
            // AutoHideTabBar (task 0211 Phase 4): a SharedFlag, inherited by
            // every descendant node — any single-window node in this tree
            // (chrome or, via the separate ViewportHost dockspace root, a
            // viewport cell) auto-hides its tab bar; nodes with 2+ tabs (the
            // Layers/Tool Properties/Viewport Properties trio) keep theirs.
            ImGui.DockSpace(dockspaceId, ImVec2(0, 0),
                            ImGuiDockNodeFlags.PassthruCentralNode
                          | ImGuiDockNodeFlags.AutoHideTabBar);

            // Seed guard (task 0211 Phase 1). `doSeed` is true iff ImGui
            // restored no usable dock tree this session:
            //  - `g_seedFreshLayout` (primary): computed ONCE at startup,
            //    before io.IniFilename was assigned (see the !g_testMode
            //    branch near the top of main()) — true iff no layout ini
            //    existed yet at the current kLayoutIniVersion path. Since
            //    io.IniFilename IS that path, this is the same condition as
            //    "ImGui will restore a dock tree from disk this session", by
            //    construction — no dependence on in-frame DockBuilder/ini
            //    load ordering. False in --test (that branch never touches
            //    the global; io.IniFilename is forced null there).
            //  - `restoredDockspaceIsEmpty` (secondary, belt-and-suspenders):
            //    even when a layout ini file EXISTS, it may be empty,
            //    truncated, or simply carry no data for this dockspace id
            //    (corrupt/foreign ini) — ImGui then restores nothing and the
            //    DockSpace() call just above leaves `dockspaceId` a bare
            //    childless node with zero docked windows. Left unguarded,
            //    that degenerates into the exact symptom this task kills:
            //    every panel floats. `IsEmpty()` (childless AND windowless)
            //    catches this without assuming anything about WHY the ini
            //    didn't restore. A real restored tree always has child
            //    splits (this seed always splits), so `IsEmpty()` is false
            //    for any genuinely-restored session — this term only ever
            //    ADDS a seed, it can never fire against a valid saved
            //    layout, so it does not reintroduce the in-frame-ordering
            //    fragility rejected for the "GetNode is null" discriminator.
            //  - `g_forceLayoutReseed`: explicit Reset Layout action,
            //    independent of the process-lifetime `dockLayoutDone` latch.
            static bool dockLayoutDone = false;
            bool restoredDockspaceIsEmpty = false;
            {
                auto rootNode = ImGui.DockBuilderGetNode(dockspaceId);
                restoredDockspaceIsEmpty = rootNode !is null && ImGuiDockNode_IsEmpty(rootNode);
            }
            bool doSeed = (!dockLayoutDone && g_seedFreshLayout)
                       || g_forceLayoutReseed
                       || restoredDockspaceIsEmpty;
            if (doSeed) {
                if (g_forceLayoutReseed) g_forceLayoutReseed = false;
                dockLayoutDone = true;
                ImGui.DockBuilderRemoveNode(dockspaceId);
                // AddNode(id, 0) creates the node; the per-frame DockSpace(id,…)
                // call above re-applies the DockSpace flag each frame (heal).
                ImGui.DockBuilderAddNode(dockspaceId, 0);
                ImGui.DockBuilderSetNodeSize(dockspaceId, ImVec2(dsz.x, dsz.y));

                if (!testMode) {
                    // Interactive: full chrome + viewport-host seed.
                    // Split order (task 0211 Phase 2 — sides off the root
                    // FIRST so the side panels span full window height, THEN
                    // tab bar/status line off the remaining center column):
                    // left (Mesh Info) → right (Layers/ToolProps/VPProps
                    // tabs) → top (Tab bar) → bottom (Status line) → central
                    // node ("ViewportHost", task 0211 — nests its own
                    // viewport-cell DockSpace, seeded separately below).
                    // Chrome DockBuilderDockWindow calls are !testMode only:
                    // in --test these windows keep fixed rects (no conflict).
                    ImGuiID leftId, rest;
                    ImGui.DockBuilderSplitNode(dockspaceId, ImGuiDir.Left, 0.12f,
                                               &leftId, &rest);
                    ImGuiID rightId, centerCol;
                    ImGui.DockBuilderSplitNode(rest, ImGuiDir.Right, 0.22f,
                                               &rightId, &centerCol);
                    ImGuiID topId, midCol;
                    ImGui.DockBuilderSplitNode(centerCol, ImGuiDir.Up, 0.04f,
                                               &topId, &midCol);
                    ImGuiID botId, vpRegion;
                    ImGui.DockBuilderSplitNode(midCol, ImGuiDir.Down, 0.05f,
                                               &botId, &vpRegion);
                    // vpRegion = last unsplit remainder = the dockspace's
                    // central node.

                    ImGui.DockBuilderDockWindow("Mesh Info",          leftId);
                    // Right panel: Layers + Tool Properties + Viewport Properties
                    // as tabs (multiple DockWindow on same nodeId → auto-tab-bar).
                    ImGui.DockBuilderDockWindow("Layers",             rightId);
                    ImGui.DockBuilderDockWindow("Tool Properties",    rightId);
                    ImGui.DockBuilderDockWindow("Viewport Properties",rightId);
                    ImGui.DockBuilderDockWindow("Tab bar",            topId);
                    ImGui.DockBuilderDockWindow("Status line",        botId);
                    // Central node: "ViewportHost" (task 0211; task 0223
                    // dropped its inner DockSpace) — a plain window whose
                    // ONLY job now is to read the host content rect (see the
                    // ViewportHost block just before the per-cell Viewport##k
                    // loop below). The actual Viewport##0..3 cells are
                    // top-level, non-docked, positioned windows computed from
                    // that rect + `vpm.hRatio/vRatio` every frame, so a
                    // runtime `viewport.layout` switch or a cross-splitter
                    // drag never touches this outer chrome tree.
                    // In --test this window is never created → PassthruCentralNode
                    // hole → picking rect unchanged (but we're in !testMode here).
                    ImGui.DockBuilderDockWindow("ViewportHost", vpRegion);
                    // Hardening: lock the node so chrome can't be dragged
                    // into the viewport region and "ViewportHost" itself
                    // can't be undocked/floated out from under its nested
                    // dockspace (which would reintroduce a mixed-tree
                    // hazard). CentralNode is re-ORed back since vpRegion
                    // (the last unsplit remainder above) is the dockspace's
                    // designated central node — re-query it here (not the
                    // stale `centerId` id from before the reorder) so the
                    // PassthruCentralNode hole lands on the actual viewport
                    // region.
                    {
                        auto vpRegionNode = ImGui.DockBuilderGetNode(vpRegion);
                        if (vpRegionNode !is null) {
                            int f = cast(int) ImGuiDockNodeFlags.NoUndocking
                                  | (ImGuiDockNode_IsCentralNode(vpRegionNode) ? kDockFlagCentralNode : 0)
                                  | kDockFlagHiddenTabBar;
                            ImGuiDockNode_SetLocalFlags(vpRegionNode, f);
                        }
                    }
                    // Bake HiddenTabBar directly onto the other three
                    // single-window leaf nodes too — see kDockFlagHiddenTabBar's
                    // doc comment for why AutoHideTabBar's own event-driven
                    // toggle never fires for THESE specific seed-time nodes.
                    // rightId (Layers/Tool Properties/Viewport Properties) is
                    // deliberately excluded — it's the one genuine multi-tab
                    // node and must keep its tab bar.
                    foreach (id; [leftId, topId, botId]) {
                        auto n = ImGui.DockBuilderGetNode(id);
                        if (n !is null)
                            ImGuiDockNode_SetLocalFlags(n, kDockFlagHiddenTabBar);
                    }
                } else {
                    // --test: minimal seed (Layers + Viewport##0 only, both
                    // uncreated in test → harmless). Chrome panels keep their
                    // fixed-rect paths. Central node stays the PassthruCentralNode
                    // hole → layout.vp* picking rect unchanged → 324/324.
                    ImGuiID rightId, centerId;
                    ImGui.DockBuilderSplitNode(dockspaceId, ImGuiDir.Right, 0.22f,
                                               &rightId, &centerId);
                    ImGui.DockBuilderDockWindow("Layers",     rightId);
                    ImGui.DockBuilderDockWindow("Viewport##0", centerId);
                }
                ImGui.DockBuilderFinish(dockspaceId);
            }

            // Layout-rebuild path (outside the one-shot seed guard) triggered
            // by viewport.layout commands.
            //
            // History (task 0204 hotfix): a scoped rebuild — clear only the
            // viewport-cell subtree via
            // DockBuilderRemoveNodeChildNodes(centralNodeId(...)), re-split,
            // re-dock — hit a genuine ImGui docking-internals hazard on any
            // shrink transition (SplitH/Quad -> Single): the central node
            // (`centerId`) was NESTED inside this same `dockspaceId` tree, so
            // DockBuilderDockWindow'ing a still-live window away from a node
            // whose *sibling* consequently empties out made ImGui
            // synchronously self-delete that now-empty non-central sibling
            // and merge the split pair back into their parent
            // (DockNodeRemoveWindow -> DockContextRemoveNode ->
            // DockNodeTreeMerge in imgui.cpp) — dangling DockId / a
            // re-queried CentralNode pointer into a just-freed node. 0204's
            // fix was to fall back to a FULL rebuild of `dockspaceId`
            // (resetting chrome too) to sidestep the hazard entirely.
            //
            // Task 0211 superseded that FOR INTERACTIVE SESSIONS by moving the
            // viewport cells into their own nested dockspace; task 0223 (quad
            // cross splitter) goes further and drops docking for the cells
            // entirely — they are now top-level, non-docked, procedurally
            // positioned windows (`SetNextWindowPos/Size` from
            // `cellRectsForRatios`, computed in the "ViewportHost" block just
            // before the per-cell Viewport##k loop). There is no dock
            // subtree left to rebuild for `!testMode` at all: `vpm.layoutDirty`
            // is cleared unconditionally in that ViewportHost block every
            // frame (viewport.d's `applyLayout` is its only setter, and a
            // layout switch just changes `vpm.cellCount` / camera presets —
            // the next frame's ratio-rect computation already reflects the
            // new preset with no rebuild step needed). This outer
            // `dockspaceId` tree (all of chrome: Tab bar / Status line / Mesh
            // Info / Layers / Tool Properties / Viewport Properties, plus the
            // "ViewportHost" window itself) is never touched by a layout
            // switch.
            //
            // `--test` keeps the ORIGINAL 0204 full-rebuild behavior
            // unconditionally (byte-neutrality — task 0211 Phase 4): no real
            // Viewport##k windows exist in test mode (the per-cell loop below
            // is `!testMode`-gated), so this path never risks the 0204 hazard
            // there in the first place, and rewriting it risks the HTTP
            // suite's `layout.vp*` picking-rect contract for no benefit.
            if (vpm.layoutDirty && testMode) {
                vpm.layoutDirty = false;

                ImGui.DockBuilderRemoveNode(dockspaceId);
                ImGui.DockBuilderAddNode(dockspaceId, 0);
                ImGui.DockBuilderSetNodeSize(dockspaceId, ImVec2(dsz.x, dsz.y));

                // --test: minimal chrome (Layers + viewport cells only),
                // matching the seed path's --test branch above.
                ImGuiID rightId, centerId;
                ImGui.DockBuilderSplitNode(dockspaceId, ImGuiDir.Right, 0.22f,
                                           &rightId, &centerId);
                ImGui.DockBuilderDockWindow("Layers", rightId);
                dockSplitViewportCells(centerId, vpm.layout);
                ImGui.DockBuilderFinish(dockspaceId);
            }

            ImGui.End();
        }
        // ── end DockSpace host ─────────────────────────────────────────────

        drawSidePanel();
        import ui.panels : drawTabPanel;
        drawTabPanel(app);

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
                ImGui.SliderInt("Max faces", &ai3dMaxFaces, 1_000, cast(int) Ai3dMaxTotalFaces);
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
                            workerUrl.length ? workerUrl : "http://127.0.0.1:47831",
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
                ImGui.SliderInt("Target Quads", &remeshTargetQuads,
                                 MIN_REMESH_TARGET_QUADS, cast(int) MAX_REMESH_TARGET_QUADS);
                // SliderInt's vMin/vMax only bound the drag/click gesture — its
                // text-entry mode (Ctrl+click) can still land an out-of-range
                // value, so clamp right after (same convention as ai3dMaxFaces
                // above; the REAL authority is RemeshJob.start()'s kernel clamp).
                if (remeshTargetQuads < MIN_REMESH_TARGET_QUADS) remeshTargetQuads = MIN_REMESH_TARGET_QUADS;
                if (remeshTargetQuads > cast(int) MAX_REMESH_TARGET_QUADS) remeshTargetQuads = cast(int) MAX_REMESH_TARGET_QUADS;

                ImGui.SetNextItemWidth(280);
                ImGui.SliderFloat("Adaptivity", &remeshAdaptivity, 0.0f, 10.0f);
                if (remeshAdaptivity < 0.0f) remeshAdaptivity = 0.0f;
                if (remeshAdaptivity > 10.0f) remeshAdaptivity = 10.0f;

                ImGui.SetNextItemWidth(280);
                ImGui.SliderFloat("Sharp Edge (deg)", &remeshSharpEdge, 0.0f, 180.0f);
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

        drawStatusBar();
        version (WithRender) drawIPRPanel(&mesh(), cameraView);

        // ---- Layers (floating) ----
        // Same imgui-determinism rule as Tool Properties below: in --test this
        // panel is hidden by default (a test opts in via `ui.layerList show`)
        // so synthetic viewport drags are never captured by it. In a normal run
        // it is always drawn (g_testMode false ⇒ guard passes).
        if (!command.g_testMode || g_layerListShown)
            drawLayerListPanel();

        // ---- Viewport Properties (floating) ----
        // Hidden in --test by default; opt-in via `ui.viewportProps show`.
        if (!command.g_testMode || g_viewportPropsShown) {
            import ui.panels : drawViewportPropsPanel;
            drawViewportPropsPanel(app);
        }

        // ---- AI Findings (floating; task 0402 Phase 2) ----
        // Same imgui-determinism idiom as Layers/Viewport Properties above:
        // hidden by default in --test, opt-in via `ui.copilotPanel show:true`.
        // The panel is a passive list (copilot_panel.d) — every interaction
        // dispatches through commandHandlerDelegate, never touching mesh /
        // document / selection state directly.
        // version(WithAI)-only — compiled out of modeling-noai entirely
        // (see import block doc comment near the top of this file).
        version (WithAI)
        if (!command.g_testMode || g_copilotPanelShown) {
            pushPanelChromeStyle();
            copilotPanel.draw(aiState.enabled, commandHandlerDelegate);
            popPanelChromeStyle();
        }

        // ---- Perf HUD (task 0198, perf build only) ----
        // Built HERE (in the panel-build region, before ImGui.Render()) and
        // NOT after endFrame() — ImGui is immediate-mode, so there is no
        // "draw after endFrame" for the same frame (see drawPerfHud's doc
        // comment). Wrapped in Phase.ui so the HUD's own build cost is
        // charged to uiNs, never leaking into any other measured phase or
        // into the `other` remainder. No-op in the default build (perfHud
        // is unconditionally false there, and drawPerfHud()'s body is
        // entirely version(PerfProbe)-gated).
        version (PerfProbe) if (perfHud) {
            auto zFramesHud = g_frames.phase(Phase.ui);
            drawPerfHud();
        }

        // ---- Tool Properties (floating) ----
        // In --test mode this window is hidden by default so synthetic mouse
        // drags over the viewport are never captured by it; a test enables it
        // explicitly via `ui.toolProperties show`. In a normal run it is always
        // rendered while a tool is active (g_testMode false ⇒ guard passes).
        // Open the panel when a tool is active OR a falloff is active on its own
        // (a user-locked falloff persists with no transform tool — its Falloff
        // section must still be reachable to read/edit Start/End etc.).
        if ((activeTool !is null || anyFalloffActive())
            && (!command.g_testMode || g_toolPropertiesShown)) {
            pushPanelChromeStyle();
            ImGui.SetNextWindowPos(ImVec2(layout.sideW + 10, 10), ImGuiCond.FirstUseEver);
            // Default tall enough to show a typical tool form (e.g. the box's
            // Position/Size/Segments/Radius groups) plus the per-stage sections
            // (Falloff, Snap, ...) without manual resizing. FirstUseEver keeps
            // the user's own resize sticky in a normal run.
            ImGui.SetNextWindowSize(ImVec2(260, 520), ImGuiCond.FirstUseEver);
            if (ImGui.Begin("Tool Properties")) {
                // Config-driven forms (Phase 4/5): when the forms panel is
                // enabled (default; disable with VIBE3D_FORMS=0) AND a loaded form matches the active
                // tool, render it through FormsPanel — which queries the live
                // params() per frame and dispatches writes through the same
                // command path the HTTP API uses (value rows marked interactive
                // so the reEvaluate() seam opens a coalesced undo session).
                // Otherwise fall back to the unchanged PropertyPanel +
                // drawProperties() path for every un-migrated tool.
                // Tool-level form / properties only when a tool is active. When
                // the panel is open ONLY because a falloff is active (no tool),
                // skip straight to the per-stage sections below.
                if (activeTool !is null) {
                import forms : g_formsPanelEnabled, formsForTool;
                auto matchingForms = g_formsPanelEnabled
                                   ? formsForTool(activeToolId) : null;
                if (matchingForms.length) {
                    // Pass activeToolId so FormsPanel rebinds a tool-namespace
                    // write (the form line carries the canonical family id
                    // `xfrm.transform`) to whichever XfrmTransformTool activation
                    // id is live — move / rotate / scale / a transform preset —
                    // satisfying ToolAttrCommand's active-id guard.
                    foreach (ref fm; matchingForms)
                        formsPanel.draw(fm, activeTool,
                                        commandHandlerDelegate,
                                        formsInteractiveDispatch,
                                        activeToolId);

                    // The transform form now owns ALL the TRS value rows —
                    // Position (TX/TY/TZ), Rotate (RX/RY/RZ) and Scale (SX/SY/SZ),
                    // all driven through the reEvaluate() seam. The legacy
                    // moveSub/rotateSub/scaleSub sliders would duplicate every row
                    // (and fight the form's live widgets), so suppress them while
                    // the form rendered. For any other formed tool the latch is
                    // harmless (it only gates the transform tool's TRS sliders); we
                    // still call drawProperties() so a formed tool's custom non-row
                    // UI (if any) renders. The schema panel is NOT drawn: the
                    // transform tool sets renderParamsAsPanel()==false
                    // (PropertyPanel.draw early-returns), and formed tools render
                    // values via the form.
                    import tools.xfrm_transform : XfrmTransformTool;
                    if (auto xf = cast(XfrmTransformTool) activeTool) {
                        xf.suppressTRSProperties = true;
                        scope(exit) xf.suppressTRSProperties = false;
                        xf.drawProperties();
                    }
                } else {
                    propertyPanel.draw(activeTool);   // schema-driven params first
                    activeTool.drawProperties();      // tool-specific custom UI after
                }
                } // if (activeTool !is null)

                // Phase 7.9: each enabled tool-pipe stage with a params()
                // schema gets its own collapsible section below the
                // active tool's properties — data-driven composition
                // where the same Tool Properties window
                // surfaces both the active tool AND the stages that
                // modulate it (Workplane, ACEN, AXIS, Snap, Falloff).
                // Stages without a schema (e.g. NopStage placeholders,
                // or older stages that haven't been migrated yet)
                // collapse to nothing.
                if (g_pipeCtx !is null) {
                    import toolpipe.stage : Stage;
                    import forms : g_formsPanelEnabled, formByStage;
                    foreach (s; g_pipeCtx.pipeline.all()) {
                        if (!s.enabled) continue;
                        auto stage = cast(Stage)s;
                        if (stage is null) continue;
                        if (stage.params().length == 0) continue;
                        // Default-open so the extra stage sections (Action
                        // Center, Falloff, Snap, ...) are expanded without a
                        // click; the user can still collapse any of them.
                        if (ImGui.CollapsingHeader(stage.displayName(),
                                                   ImGuiTreeNodeFlags.DefaultOpen)) {
                            // Phase 6: prefer a config-driven stage form (bound
                            // to the stage via whenStage:, looked up by the
                            // stage's id()) over the legacy drawProvider path —
                            // same gating + kill switch as the tool-level form
                            // integration above. The stage IS a ParamProvider,
                            // so FormsPanel queries its live (type-filtered)
                            // params() per frame and hides rows whose attr the
                            // active type doesn't expose. Stages without a
                            // matching form fall back to the unchanged
                            // drawProvider. stage.drawProperties() still runs in
                            // both cases (shape popup / auto-size buttons aren't
                            // form rows).
                            // Look the form up by the stage FAMILY id (not the
                            // unique id), so stacked falloff instances
                            // ("falloff#1", …) all resolve the one "falloff"
                            // form; FormsPanel filters its rows against this
                            // instance's params() and the stage.id() passed
                            // below rebinds the write to the right instance.
                            auto stageForm = g_formsPanelEnabled
                                           ? formByStage(stage.formFamilyId()) : null;
                            if (stageForm !is null) {
                                // A malformed row must degrade to the legacy
                                // panel, NOT throw mid-ImGui-frame (an escaping
                                // exception would leave ImGui's stack unbalanced
                                // and abort the frame). Fall back to drawProvider
                                // on any failure; warn ONCE per stage so a broken
                                // form doesn't spam stderr every frame.
                                try {
                                    formsPanel.draw(*stageForm, stage,
                                                    commandHandlerDelegate,
                                                    formsInteractiveDispatch,
                                                    /*activeToolId=*/"",
                                                    /*stageId=*/stage.id());
                                } catch (Exception e) {
                                    warnStageFormOnce(stage.id(), e.msg);
                                    propertyPanel.drawProvider(stage);
                                }
                            } else
                                propertyPanel.drawProvider(stage);
                            stage.drawProperties();
                        }
                    }
                }
            }
            ImGui.End();
            popPanelChromeStyle();
        }

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
                ImGui.Checkbox("Args", &historyShowArgs);
                ImGui.SameLine();
                if (ImGui.SmallButton("..."))
                    ImGui.OpenPopup("hist-display-opts");
                // Wrap popups in the status-bar popup palette so the
                // grey/beige look matches the menu chrome the rest of
                // the app uses (see source/imgui_style.d).
                pushPopupStyle();
                if (ImGui.BeginPopup("hist-display-opts")) {
                    ImGui.Checkbox("Show row numbers",
                                   &historyShowRowNumbers);
                    ImGui.Checkbox("Show timestamps",
                                   &historyShowTimestamps);
                    ImGui.Checkbox("Show command IDs (internal names)",
                                   &historyShowCommandIds);
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

        // ---- Universal args dialog ----
        // Any command whose params() returns non-empty gets a modal dialog
        // rendered here. tryOpenArgsDialog() queues the command; draw()
        // renders the popup and runs the command on OK.
        argsDialog.draw(&runCommand);

        // ShowDemoWindow();


        // ---- Playback cursor overlay ----
        {
            int cursorX, cursorY;
            bool cursorDown;
            bool showCursor = false;
            if (playbackMode) {
                cursorX = evPlay.mouseX; cursorY = evPlay.mouseY;
                cursorDown = evPlay.mouseDown;
                showCursor = true;
            } else if (testMode && httpServer !is null) {
                cursorX = httpServer.playerMouseX();
                cursorY = httpServer.playerMouseY();
                cursorDown = httpServer.playerMouseDown();
                showCursor = true;
            }
            if (showCursor) {
                ImDrawList* dl = ImGui.GetForegroundDrawList();
                ImVec2 pos = ImVec2(cast(float)cursorX, cast(float)cursorY);
                dl.AddCircle(pos, 12.0f, IM_COL32(255, 220, 0, 220), 24, 2.0f);
                uint dotColor = cursorDown
                    ? IM_COL32(255, 80, 80, 255)
                    : IM_COL32(255, 255, 255, 200);
                dl.AddCircleFilled(pos, 3.0f, dotColor, 12);
            }
        }

        // ---- RMB path trail ----
        if (rmbPath.length >= 2) {
            ImDrawList* dl = ImGui.GetForegroundDrawList();
            // Task 0222: the lasso belongs to ONE gesture in ONE cell, but
            // rmbPath is stored in absolute screen coords and drawn on the
            // shared foreground draw list — so in Quad/Split it painted across
            // EVERY cell as the cursor swept over them. Clip it to the origin
            // cell (where the gesture began) so it renders only there. In
            // --test cellCount==1 → the clip rect is the whole viewport, a
            // visual no-op (and the trail is never presented anyway).
            int _oc = vpm.dragOriginId >= 0 ? vpm.dragOriginId : vpm.activeId;
            bool _clipCell = (_oc >= 0 && _oc < vpm.cellCount);
            if (_clipCell) {
                auto _ocv = vpm.views[_oc];
                dl.PushClipRect(
                    ImVec2(cast(float)_ocv.winX, cast(float)_ocv.winY),
                    ImVec2(cast(float)(_ocv.winX + _ocv.winW),
                           cast(float)(_ocv.winY + _ocv.winH)),
                    true);
            }
            for (size_t i = 1; i < rmbPath.length; i++)
                dl.AddLine(rmbPath[i - 1], rmbPath[i], IM_COL32(0, 255, 255, 220), 1.0f);
            // Closing line: start → end
            dl.AddLine(rmbPath[0], rmbPath[$ - 1], IM_COL32(0, 255, 255, 220), 1.0f);
            if (_clipCell) dl.PopClipRect();
        }

        // Change-notification bus flush (doc/change_notification_bus_plan.md,
        // Design rule 2): exactly ONE flush per frame, here — AFTER event
        // dispatch, HTTP tickCommand, toolpipe evaluate, the ImGui panel pass
        // (sliders / command buttons mutate the mesh during drawSidePanel /
        // drawTabPanel / Tool Properties, all above), and any undo/redo for the
        // frame; BEFORE the first bus consumer (subpatch preview, just below),
        // the GPU upload, picking, and the pick-cache invalidation block. Drain
        // the active mesh's accumulated change flags + selection domains into the
        // bus and zero them.
        //
        // Ordering (Stage 3): the flush MUST precede the subpatch-preview gate
        // below so that gate reads THIS frame's flags. The subpatch poll runs
        // earlier in the loop body than the pick-cache block, so a single flush
        // placed here feeds BOTH consumers the same frame's flags via the
        // startup subscriber's `meshChangedFlags`, which is consumed (zeroed)
        // only after the pick-cache block far below. Nothing between here and
        // that block mutates the mesh (render + GPU upload are read-only / use
        // mutationVersion directly), so one flush at this point is exact.
        {
            import change_bus : changeBus;

            // Stage 0b — aggregate pending flags across ALL document layers,
            // then flush once. Each layer's mesh accumulates its own
            // `pendingChanges_`/`pendingSelDomains_` independently; we OR them
            // into the frame's flags and zero each layer's pending set. With the
            // single layer that exists in 0b this is byte-equivalent to draining
            // the one global mesh: the active layer's flags ARE the frame's
            // flags, and no other layer is ever mutated.
            uint meshFlags  = 0;
            uint selDomains = 0;

            // Shadow cross-check (Stage 1, debug builds only; retired in Stage
            // 6). The bus trades blanket per-frame invalidation for precision, so
            // a MISSED publisher (a mutation that bumped mutationVersion but
            // forgot to noteChange/commitChange) would silently leave a stale
            // cache. Going per-layer: a missed publisher on a BACKGROUND mesh
            // must still trip it, so the stamp is per-Layer (a `ulong[Layer]`
            // map) rather than one function-local. The stamp SEEDS LAZILY — the
            // first time the flush sees a layer it records the current
            // mutationVersion WITHOUT comparing, so a freshly built layer
            // (layered load / import / future layer.add) whose mutationVersion
            // is already non-zero does not false-positive on its first flush.
            debug {
                import core.stdc.stdio : fprintf, stderr;
                import document : Layer;
                static ulong[Layer] lastSeenMutVer;
                static bool  warnedMissedPublisher = false;

                foreach (layer; document.layers) {
                    const lf = layer.mesh.pendingChanges_;
                    auto seen = layer in lastSeenMutVer;
                    if (seen is null) {
                        // First observation of this layer — seed, do not compare.
                        lastSeenMutVer[layer] = layer.mesh.mutationVersion;
                    } else if (layer.mesh.mutationVersion != *seen && lf == 0) {
                        if (!warnedMissedPublisher) {
                            fprintf(stderr,
                                "change_bus: MISSED PUBLISHER — mutationVersion " ~
                                "advanced (%llu) with no pending change flags; a " ~
                                "mutation site bumped the version but did not " ~
                                "noteChange/commitChange.\n",
                                cast(ulong)layer.mesh.mutationVersion);
                            warnedMissedPublisher = true;
                        }
                        lastSeenMutVer[layer] = layer.mesh.mutationVersion;
                    } else {
                        lastSeenMutVer[layer] = layer.mesh.mutationVersion;
                    }
                }
            }

            foreach (layer; document.layers) {
                meshFlags  |= layer.mesh.pendingChanges_;
                selDomains |= layer.mesh.pendingSelDomains_;
                layer.mesh.pendingChanges_    = 0;
                layer.mesh.pendingSelDomains_ = 0;
            }

            // Layer-structural changes are DOCUMENT-level, not per-mesh, so they
            // accumulate in a module-level word (change_bus.pendingLayerChanges)
            // rather than on any Mesh. Drain read-and-zero here, in the same
            // single flush site, and deliver it as flush's third arg (delivered
            // LAST, after meshChanged + selectionChanged). The next frame drains
            // it again, so it survives /api/reset without stranding.
            import change_bus : pendingLayerChanges;
            uint layerKinds = pendingLayerChanges;
            pendingLayerChanges = 0;

            // Item (layer) selection is a DOCUMENT-level selection domain (no
            // owning Mesh), so it accumulates in a module-level word like the
            // layer kinds and is OR-ed into the SELECTION word here, drained
            // read-and-zero. Survives /api/reset like pendingLayerChanges.
            import change_bus : pendingItemSelDomain;
            selDomains |= pendingItemSelDomain;
            pendingItemSelDomain = 0;

            // Current-type flips are session-level (the SelType recent-ordering
            // lives in app scene state, not on any Mesh), so they accumulate in
            // module-level globals beside the bus and drain read-and-zero here,
            // at the same single flush site — delivered LAST (after mesh/sel/
            // layer). Survives /api/reset like pendingLayerChanges.
            import change_bus : pendingCurrentType, pendingCurrentTypeSet;
            bool    typeChanged = pendingCurrentTypeSet;
            SelType newType     = pendingCurrentType;
            pendingCurrentTypeSet = false;

            changeBus.flush(meshFlags, selDomains, layerKinds,
                            typeChanged, newType);
        }

        // Refresh subpatch preview if the cage or depth changed since last
        // frame. Bundle vibe3d's face / edge / vert VBOs so the fast
        // path can try OSD GPU fan-outs for each — when all three
        // succeed (Phase 3c), preview.vertices stays untouched and
        // the entire per-frame CPU position-upload pipeline is
        // skipped. When only the face fan-out works we still write
        // edges + verts CPU-side (Phase 3b fallback).
        //
        // Change-notification bus, Stage 3: gate the per-frame call on this
        // frame's mesh-change flags instead of calling unconditionally. The
        // preview must rebuild on Position (drag moved cage verts), Geometry
        // (cage topology changed) AND Marks — Tab toggling the subpatch bit
        // changes marks, not geometry, yet must rebuild the preview. The
        // internal `sourceVersion` / `sourceTopologyVersion` early-outs inside
        // rebuildIfStale stay as a correctness backstop during burn-in, so a
        // missed flag degrades to "preview rebuilds a frame late at worst",
        // never to a wrong preview.
        {
            import change_bus : MeshEditScope;
            enum uint kSubpatchTriggers = MeshEditScope.Position
                                        | MeshEditScope.Geometry
                                        | MeshEditScope.Marks;
            if (meshChangedFlags & kSubpatchTriggers) {
                import subpatch_osd : GpuFanOutTargets;
                GpuFanOutTargets targets = {
                    faceVbo:        gpu.faceVbo,
                    faceVertCount:  gpu.faceVertCount,
                    edgeVbo:        gpu.edgeVbo,
                    edgeSegCount:   gpu.edgeVertCount,
                    vertVbo:        gpu.vertVbo,
                    vertCount:      gpu.vertCount,
                };
                subpatchPreview.rebuildIfStale(mesh, subpatchDepth, &targets,
                    (meshChangedFlags & MeshEditScope.Position) != 0);
            }
        }

        // Re-upload GPU buffers when transitioning between cage/preview view
        // or when the cage changed during an active preview. While the
        // preview is active, tool-side gpu.upload calls are redirected to
        // bump mutationVersion (see GpuMesh.suppressCageUpload) so this main
        // loop owns the actual upload.
        {
            // Perf: time the per-frame GPU vertex upload (cage refresh or
            // full re-upload after a drag mutates the mesh). No-op in the
            // default build. Single coarse site, per the plan.
            auto zGpu = g_perf.scope_(Cat.gpuUpload);
            auto zFramesUpload = g_frames.phase(Phase.upload);
            bool wantPreview = subpatchPreview.active;
            gpu.suppressCageUpload = wantPreview;
            bool versionChanged = gpuUploadedVersion != mesh.mutationVersion;
            bool stateChanged   = gpuUploadedPreview != wantPreview;
            if ((wantPreview && (versionChanged || stateChanged)) ||
                (!wantPreview && stateChanged))
            {
                if (wantPreview) {
                    // Position-only fast path: if the previously-uploaded
                    // preview was built against the same source topology,
                    // the preview's face/edge/vert layout is identical and
                    // we can scatter-update positions through
                    // glMapBuffer. Only fall through to the full upload
                    // when topology actually changed (Tab toggle on a new
                    // face selection, edge added, snapshot restore, etc.)
                    // or when transitioning preview off/on.
                    bool topoSame = !stateChanged
                        && gpuUploadedPreviewTopVersion
                           == subpatchPreview.sourceTopologyVersion;
                    if (topoSame) {
                        // Phase 3c: when face + edge + vert VBOs were
                        // ALL written via GPU fan-out (the common
                        // case once g_osdGpuEnabled flips true), skip
                        // the CPU position upload entirely — every
                        // VBO is already current on GPU.
                        //
                        // Phase 3b fallback: face on GPU only →
                        // refreshNonFacePositions for edges + verts.
                        //
                        // Otherwise: full CPU refresh.
                        if (subpatchPreview.lastRefreshSkipNonFace) {
                            // No-op — all VBOs already fresh.
                        } else if (subpatchPreview.lastRefreshFannedOut) {
                            gpu.refreshNonFacePositions(
                                subpatchPreview.mesh,
                                subpatchPreview.trace.edgeOrigin,
                                subpatchPreview.trace.vertOrigin);
                        } else {
                            gpu.refreshPositions(subpatchPreview.mesh,
                                subpatchPreview.trace.edgeOrigin,
                                subpatchPreview.trace.vertOrigin);
                        }
                    } else {
                        gpu.upload(subpatchPreview.mesh,
                                   subpatchPreview.trace.edgeOrigin,
                                   subpatchPreview.trace.vertOrigin,
                                   subpatchPreview.trace.faceOrigin);
                        gpuUploadedPreviewTopVersion =
                            subpatchPreview.sourceTopologyVersion;
                        // F-I1: a full mesh-work GPU upload fired this frame.
                        g_frames.bumpMeshCacheRebuild();
                    }
                } else {
                    gpu.upload(mesh);
                    // Cage upload — invalidate the preview-topology
                    // marker so the next preview activation triggers a
                    // full upload.
                    gpuUploadedPreviewTopVersion = ulong.max;
                    // F-I1: a full mesh-work GPU upload fired this frame.
                    g_frames.bumpMeshCacheRebuild();
                }
                gpuUploadedVersion = mesh.mutationVersion;
                gpuUploadedPreview = wantPreview;
            }
        }

        // ---- 3D render (moved to renderViewportSceneToFbo) ----
        // Scene draw now happens AFTER picking/hover-resolution and
        // BEFORE ImGui.Render() via renderViewportSceneToFbo().  See
        // the Phase-2 FBO section below (after hover resolution).

        bool doingCameraDrag = (dragMode == DragMode.Orbit ||
                                dragMode == DragMode.Zoom  ||
                                dragMode == DragMode.Pan);

        // Invalidate the screen-space pick caches when the MESH actually
        // changed this frame (change-notification bus, Stage 2). The bus
        // flush just above OR-ed this frame's change classes into
        // `meshChangedFlags` via the startup subscriber, so we now know
        // precisely whether geometry moved — replacing the old blanket
        // "invalidate every frame a tool is active" sweep (which racked up one
        // `Cat.cacheInvalidate` sample per rendered frame of a drag even on
        // frames where nothing moved).
        //
        //   • Geometry (Points|Polygons) → vertex/edge/face COUNTS changed:
        //     resize the caches to the new mesh dimensions, re-sync the
        //     selection arrays, invalidate, refresh the vertex cache. This
        //     subsumes the two former synchronous resize sites — the
        //     post-tool-deactivate blob in setActiveTool and the
        //     BoxTool.meshChanged hand-off in handleMouseButtonUp — both of
        //     which mutate via mesh primitives that publish Geometry, so the
        //     flush delivers the flag on the SAME frame (event dispatch runs
        //     before this block) and the resize lands here instead.
        //   • Position only → coords moved, counts unchanged: just invalidate
        //     + refresh; no resize / syncSelection needed.
        //   • Camera-only frames keep their existing `needsUpdate(vp)`
        //     16-float compare path (camera is not mesh state).
        //
        // Perf (doc/perf_harness_plan.md): `cacheInvalidate` counts PER-FRAME
        // invalidations; this is the structurally-correct place to measure
        // them. No-op in the default build.
        //
        // Perf (doc/frame_probe_scenarios_plan.md, task 0195): the FrameProbe
        // `cache` phase wraps this whole block AND extends through
        // `pickFaces(vp, ...)` below (NOT just the inner `{}` block, which
        // stops before the per-frame vertex/edge/face picks) — otherwise the
        // hover-sweep scenario's per-frame face pick would land in "other".
        // Explicit outer block so the scope timer fires right after
        // pickFaces, not at the end of the whole frame.
        {
            auto zFramesCache = g_frames.phase(Phase.cache);
        {
            import change_bus : MeshEditScope;
            // NB: Cat.viewcacheRebuild (inside each vertex/edge/faceCache
            // .invalidate() body) nests inside this Cat.cacheInvalidate block
            // ON PURPOSE — two granularities (whole per-frame block vs the
            // per-call bool-clear). Distinct JSON keys, so no within-category
            // double-count; only a naive cross-category SUM would count the
            // bool-clear twice. Do not "flatten" one into the other.
            auto zCache = g_perf.scope_(Cat.cacheInvalidate);
            if (meshChangedFlags & MeshEditScope.Geometry) {
                // Counts may have changed — match cache sizes to the mesh and
                // re-sync selection before invalidating.
                mesh.syncSelection();
                if (vertexCache.valid.length != mesh.vertices.length) {
                    vertexCache.resize(mesh.vertices.length);
                    faceCache.resize(mesh.vertices.length, mesh.faces.length);
                }
                if (edgeCache.valid.length != mesh.edges.length)
                    edgeCache.resize(mesh.edges.length);
                vertexCache.invalidate();
                edgeCache.invalidate();
                faceCache.invalidate();
                vertexCache.update(vp);
                // F-I1: mesh-driven cache rebuild (topology/counts changed).
                g_frames.bumpMeshCacheRebuild();
            } else if (meshChangedFlags & MeshEditScope.Position) {
                // Coords moved, counts unchanged — invalidate without resize.
                vertexCache.invalidate();
                edgeCache.invalidate();
                faceCache.invalidate();
                vertexCache.update(vp);
                // F-I1: mesh-driven cache rebuild (positions changed).
                g_frames.bumpMeshCacheRebuild();
            } else if (!doingCameraDrag && vertexCache.needsUpdate(vp)) {
                // Camera-reprojection branch — GATED on !doingCameraDrag, so
                // it is SKIPPED entirely during an orbit drag (this is WHY
                // F-I1 == 0 on orbit-dense: this branch never fires while
                // dragMode is Orbit/Zoom/Pan). Deliberately NOT counted as a
                // mesh-cache rebuild — camera reprojection is not mesh work.
                vertexCache.invalidate();
                vertexCache.update(vp);
            }

            // Change-notification bus, Stage 3 — gpu_select proactive
            // invalidation. The GPU select buffer's per-mode slot key
            // (mode, gpu.uploadVersion, view, proj, FBO size) is UNCHANGED:
            // `uploadVersion` fingerprints exactly what is in the VBO and backs
            // the mid-event-batch stale-VBO safety net (gpu_select.d:240-254).
            // The bus only replaces the *trigger* side — until now the slots
            // aged out lazily on the next pick when the key no longer matched.
            // Clear them proactively the instant geometry/positions change this
            // frame so the next pick never reads a slot rendered against a
            // superseded VBO; the key remains the correctness backstop.
            if (meshChangedFlags & (MeshEditScope.Position | MeshEditScope.Geometry))
                gpuSelect.invalidate();

            // Change-notification bus, Stage 3 addendum (task 0401) —
            // symmetry pairing + snap candidate-grid proactive invalidation.
            // Both cache on (address, mutationVersion, ...), same as the
            // subpatch preview above and gpu_select just above. An
            // interactive gizmo Move/Rotate/Scale is deliberately
            // version-silent on Position — mutationVersion never bumps for
            // a drag or its commit (see the warning above
            // SubpatchPreview.deactivate() in mesh.d) — so those raw-
            // mutationVersion keys alone would keep serving the pre-edit
            // mirror pairing / snap candidates forever. Force both stale
            // the instant a Position edit lands this frame; the version
            // keys remain the correctness backstop for every other change
            // class (topology, marks, layer switch).
            if (meshChangedFlags & MeshEditScope.Position) {
                import toolpipe.pipeline        : g_pipeCtx;
                import toolpipe.stage           : TaskCode;
                import toolpipe.stages.symmetry : SymmetryStage;
                import snap                     : invalidateSnapGrids;
                if (g_pipeCtx !is null)
                    if (auto sym = cast(SymmetryStage)
                                   g_pipeCtx.pipeline.findByTask(TaskCode.Symm))
                        sym.invalidatePairingCache();
                invalidateSnapGrids();
            }
        }
        // Consume this frame's mesh-change flags. Stage 2 subscriber = the
        // screen-space pick caches; Stage 3 adds gpu_select (above) and gates
        // the subpatch-preview rebuild earlier in the loop body. Both Stage 3
        // consumers keep their internal version keys as backstops; the bus only
        // drives the trigger. (render-dirty / IPR is converted in Stage 4.)
        meshChangedFlags = 0;

        // Consume this frame's selection-change domains (Stage 5). No live
        // consumer acts on them yet (highlight reads marks directly; pick caches
        // key off geometry), so this just clears the frame-local accumulator so
        // it never carries stale domains into the next frame. The seam exists
        // for the future layer panel.
        selChangedDomains = 0;

        pickVertices(vp, doingCameraDrag);

        // Check if edge cache needs update due to camera movement
        if (!doingCameraDrag && edgeCache.needsUpdate(vp)) {
            edgeCache.invalidate();
            edgeCache.update(vp);
        }

        pickEdges(vp, doingCameraDrag);

        // Check if face cache needs update due to camera movement
        if (!doingCameraDrag && faceCache.needsUpdate(vp)) {
            faceCache.invalidate();
            faceCache.update(vp);
        }

        pickFaces(vp, doingCameraDrag);
        }
        int pickedVertex = hoveredVertex;
        int pickedEdge = hoveredEdge;
        int pickedFace = hoveredFace;

        // Tool-driven multi-type hover priority resolution: when an
        // active tool (e.g. XfrmTransformTool with falloff.element
        // in Auto mode) picks across vert/edge/face
        // simultaneously, only ONE of
        // them should highlight per cursor position — vert first,
        // then edge, then face. Without this the cursor over a
        // corner would light up both the vertex dot AND the face
        // checker, which mis-represents what click-to-pick will hit.
        if (activeTool !is null) {
            if (hoveredVertex >= 0) {
                hoveredEdge = -1;
                hoveredFace = -1;
            } else if (hoveredEdge >= 0) {
                hoveredFace = -1;
            }
        }
        int elementTraceMouseX, elementTraceMouseY;
        queryMouse(elementTraceMouseX, elementTraceMouseY);
        publishElementCandidates(elementTraceMouseX, elementTraceMouseY,
                                 pickedVertex, pickedEdge, pickedFace);
        // Publish the resolved hover state for cross-module consumers
        // (XfrmTransformTool.tryPickElement reads these when
        // falloff.element is active so click-pick lands on the same
        // element the user sees highlighted — the GPU ID-buffer path
        // here is the source of truth; a parallel CPU-centroid pick
        // would pick back-facing / hidden polygons that happened to
        // project to the cursor).
        import hover_state : g_hoveredVertex, g_hoveredEdge, g_hoveredFace;
        g_hoveredVertex = hoveredVertex;
        g_hoveredEdge   = hoveredEdge;
        g_hoveredFace   = hoveredFace;
        // Per-type highlight gates (for the FBO draw pass).
        bool showVertHover = (editMode == EditMode.Vertices)
                          || (activeTool !is null
                              && activeTool.wantsHoverForType(EditMode.Vertices));
        bool showEdgeHover = (editMode == EditMode.Edges)
                          || (activeTool !is null
                              && activeTool.wantsHoverForType(EditMode.Edges));
        bool showFaceHover = (editMode == EditMode.Polygons)
                          || (activeTool !is null
                              && activeTool.wantsHoverForType(EditMode.Polygons));

        // Tool logic update (handle-hover state) — runs in main loop so it
        // is current before renderViewportSceneToFbo() draws the handles.
        if (activeTool) {
            SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts);
            activeTool.update(vts);
        }

        // ── Task 0223: ratio-driven cell layout host ("ViewportHost") ────────
        //
        // "ViewportHost" is the plain window docked into the outer
        // dockspace's central node (see the seed above). Through task 0222 it
        // nested its OWN inner DockSpace (`viewportDockId`) that bound the
        // cells via ImGui docking; task 0223 (quad cross splitter) DROPS that
        // inner dockspace — a docked window ignores `SetNextWindowPos/Size`,
        // and the custom cross-splitter widget (built on top of caller-
        // supplied ratios, see the per-cell loop + widget below) needs to
        // position each cell itself. "ViewportHost" now serves ONE purpose:
        // read the host content rect (the region the outer chrome dockspace
        // grants the viewport area), so the ratio-cell math below tracks
        // outer-panel resizes exactly like the old dockspace-fed rect did.
        //
        // Must run BEFORE the per-cell Viewport##k window loop just below, in
        // the same frame, so `_cellXs/Ys/Ws/Hs` are ready when those windows
        // position themselves.
        //
        // `!testMode` only: in `--test` no "ViewportHost"/"Viewport##k"
        // windows are ever created (see the per-cell loop's `!testMode` gate
        // below) — this whole block is skipped, so the outer central node
        // stays the PassthruCentralNode hole exactly as before (byte-
        // identical HTTP suite geometry). The `--test` rect authority remains
        // the unchanged `cellRectsFor` via `applyLayout` / the SDL resize
        // handler (task 0223 plan §6).
        int[4] _cellXs, _cellYs, _cellWs, _cellHs;
        if (!testMode) {
            // Task 0223: "ViewportHost" no longer draws any content of its
            // own (it used to host the inner DockSpace) — it exists purely
            // to read the host content rect. NoBackground is REQUIRED: the
            // per-cell `Viewport##k` windows below are now plain top-level
            // (non-docked) windows rather than docked children, so they are
            // NOT automatically brought in front of "ViewportHost" the way a
            // docked child would be — without NoBackground here,
            // "ViewportHost"'s own opaque WindowBg fully occludes them
            // (reproduced live: solid black quad, camera rects correct but
            // nothing drawn). With NoBackground there is nothing to occlude
            // regardless of the two windows' relative z-order.
            //
            // NoMouseInputs: "ViewportHost" occupies the EXACT same screen
            // rect as the Viewport##k cells stacked on top of it. Belt-and-
            // suspenders with the cell flags below (this task's live-Xvfb
            // pass found the REAL culprit was `NoBringToFrontOnFocus` on the
            // cells themselves — see vpWinFlags' doc comment — but leaving
            // "ViewportHost" mouse-transparent too means the cells' hover
            // resolution never has to compete with it regardless of z-order
            // details, and it has no interactive purpose of its own).
            immutable int hostFlags =
                ImGuiWindowFlags.NoScrollbar |
                ImGuiWindowFlags.NoScrollWithMouse |
                ImGuiWindowFlags.NoBackground |
                ImGuiWindowFlags.NoMouseInputs;
            ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding,    ImVec2(0, 0));
            ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0.0f);
            if (ImGui.Begin("ViewportHost", null, hostFlags)) {
                ImVec2 hostPos   = ImGui.GetCursorScreenPos();
                ImVec2 hostAvail = ImGui.GetContentRegionAvail();

                // This is now the interactive single-writer of vpm.l* (the
                // picking region) — it tracks the REAL host content rect every
                // frame, strictly more correct than the old hardcoded
                // layout.vp* the SDL resize handler stamps (that handler's
                // write remains a pre-first-frame / --test fallback only; see
                // its comment at handleWindowEvent, ~app.d:5537-5548, and the
                // per-cell-loop comment below, updated to match).
                vpm.lx = cast(int)hostPos.x;   vpm.ly = cast(int)hostPos.y;
                vpm.lw = cast(int)hostAvail.x; vpm.lh = cast(int)hostAvail.y;

                // layoutDirty's only interactive consumer (the old inner-
                // dockspace rebuild) is gone; clear it here so a pending
                // viewport.layout switch doesn't leave the flag stuck set
                // (applyLayout() is the sole setter — see viewport.d).
                vpm.layoutDirty = false;

                ViewportManager.cellRectsForRatios(vpm.layout, vpm.lx, vpm.ly,
                                                    vpm.lw, vpm.lh,
                                                    vpm.hRatio, vpm.vRatio,
                                                    _cellXs, _cellYs, _cellWs, _cellHs);
            }
            ImGui.End();
            ImGui.PopStyleVar(2);
        }
        // ── end ViewportHost ────────────────────────────────────────────────

        // ── Phase 2 FBO render ──────────────────────────────────────────────
        //
        // Ordering invariant (same-frame content, zero latency):
        //   1. ImGui.Image(colorTex) records the texture HANDLE inside the
        //      "Viewport" window below (sampled later at RenderDrawData).
        //   2. renderViewportSceneToFbo() fills that texture THIS frame.
        //   3. ImGui.Render() → RenderDrawData samples the freshly-filled tex.
        // All three happen in this frame, in that order.
        //
        // "Viewport" window — interactive only.  NOT created in --test so the
        // central node stays the PassthruCentralNode hole, keeping
        // WantCaptureMouse false over the 3D area → 320/320 byte-identical.
        g_viewportWindowHovered = false;
        if (!testMode) {
            import std.conv : to;
            import toolpipe.packets : FalloffPacket;
            import falloff_render : drawFalloffOverlay;
            // Task 0223: cells are plain top-level windows, procedurally
            // positioned every frame from `_cellXs/Ys/Ws/Hs` (see the
            // ViewportHost block above) rather than docked. NoDocking is
            // mandatory — the outer chrome dockspace still exists, and a
            // floating window without it could dock itself into the chrome.
            // NoSavedSettings keeps these procedurally-positioned cells out
            // of the layout ini entirely (so a stale saved DockId from a
            // pre-0223 ini is simply never read for them).
            //
            // NoBringToFrontOnFocus is deliberately NOT set here: in this
            // binding a NoBringToFrontOnFocus window is pinned to the BACKGROUND
            // z-band (behind normal windows), so flagging the cells demoted
            // them below the (normal) "ViewportHost" window and the whole quad
            // rendered dimmed (reproduced live). The cross-splitter arm overlay
            // windows are created AFTER the cells each frame, so they start
            // above them; the splitter's own hit-test tolerates a
            // freshly-clicked cell transiently rising over an arm (see the
            // widget block after this loop).
            immutable int vpWinFlags =
                ImGuiWindowFlags.NoScrollbar |
                ImGuiWindowFlags.NoScrollWithMouse |
                ImGuiWindowFlags.NoTitleBar |
                ImGuiWindowFlags.NoResize |
                ImGuiWindowFlags.NoMove |
                ImGuiWindowFlags.NoCollapse |
                ImGuiWindowFlags.NoDocking |
                ImGuiWindowFlags.NoSavedSettings;

            // Task 0213: falloff ring/sphere overlay packet, built ONCE
            // before the per-cell loop (view-independent — same world-
            // space rings/sphere for every cell, mirrors the toolMat/
            // _ovl* reuse in the FBO loop below) and reprojected per
            // cell under that cell's own resolved Viewport. Emitted on
            // each cell's OWN window draw list (GetWindowDrawList,
            // recorded AFTER that cell's ImGui.Image below) so it paints
            // above the opaque cell image instead of being occluded by
            // it (task 0170 regression — see doc/falloff_sphere_rings_plan.md).
            FalloffPacket _wlFp;
            if (activeTool !is null || anyFalloffActive()) {
                SubjectPacket _wlSubj; VectorStack _wlVts; buildToolVts(_wlSubj, _wlVts);
                if (auto p = _wlVts.get!FalloffPacket()) _wlFp = *p;
            }

            // Task 0218: corner axes/orientation-gizmo basis, built ONCE
            // before the per-cell loop (the active workplane is one
            // document-wide state, not per-cell — mirrors the _wlFp reuse
            // above). Manual workplane: corner gizmo follows it (visual
            // cue that the local frame is set explicitly). Auto workplane:
            // stay locked to world XYZ — `pickMostFacingPlane` swaps every
            // 45° of camera rotation, which made the corner indicator's
            // X/Y/Z labels jump around as the user orbited. Tool handles
            // still pick the most-facing-camera basis via AxisStage; only
            // the corner indicator is pinned to world here.
            Vec3 gz_a1 = Vec3(1, 0, 0);
            Vec3 gz_n  = Vec3(0, 1, 0);
            Vec3 gz_a2 = Vec3(0, 0, 1);
            if (auto wp = cast(WorkplaneStage)g_pipeCtx.pipeline.findByTask(TaskCode.Work)) {
                if (!wp.isAuto) {
                    wp.currentBasis(gz_n, gz_a1, gz_a2);
                }
            }

            foreach (k; 0 .. vpm.cellCount) {
                Viewport3D _vcell = vpm.views[k];
                // Zero padding + FBO-clear-colored WindowBg: the un-chromed
                // Viewport##k window otherwise inherits the dark-style WindowBg
                // (~black) and default 8px padding, which shows as a dark ring/
                // letterbox frame around the 3D image. Match the FBO clear
                // color (renderViewportSceneToFbo, glClearColor 0.36/0.40/0.42)
                // so any letterbox bar blends with the rendered scene bg.
                // Task 0223: position this cell BEFORE Begin — a plain
                // (non-docked) window honors SetNextWindowPos/Size every
                // frame. With WindowPadding=0 and WindowBorderSize=0 (pushed
                // above / at ViewportHost), the content rect below equals
                // this computed rect exactly, so the live stamp two lines
                // down self-corrects to the same numbers — see that comment.
                ImGui.SetNextWindowPos (ImVec2(_cellXs[k], _cellYs[k]));
                ImGui.SetNextWindowSize(ImVec2(_cellWs[k], _cellHs[k]));
                ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, ImVec2(0, 0));
                ImGui.PushStyleColor(ImGuiCol.WindowBg, ImVec4(0.36f, 0.40f, 0.42f, 1.0f));
                if (ImGui.Begin("Viewport##" ~ to!string(k), null, vpWinFlags)) {
                    ImVec2 avail = ImGui.GetContentRegionAvail();
                    ImVec2 pos   = ImGui.GetCursorScreenPos();

                    // Stamp this cell's window rect for FBO loop and viewportUnderCursor.
                    // setPos is REQUIRED: the pick delegates read
                    // cameraView.viewport() (== active cell's camera) during
                    // SDL event processing, so each cell's window origin must
                    // live on the persistent View — otherwise picking
                    // subtracts the stale construction-time layout origin and
                    // every hover/click is offset by (window-pos − origin).
                    // In --test this loop never runs (no Viewport##k windows), so
                    // the cameras keep layout.vp* → byte-identical.
                    // winX/Y/W/H are forwarding properties onto these same
                    // camera fields (the cell rect's single owner, V1) — this
                    // IS the interactive rect authority. Re-stamping from the
                    // REAL content rect here (rather than trusting
                    // `_cellXs/Ys/Ws/Hs` directly) keeps this self-correcting
                    // if ImGui ever nudges anything (e.g. a min-size clamp).
                    _vcell.camera.setSize(cast(int)avail.x, cast(int)avail.y);
                    _vcell.camera.setPos(cast(int)pos.x, cast(int)pos.y);

                    // Centered letterbox: fit FBO logical size into avail,
                    // preserving the FBO aspect. Kills one-frame stretch when
                    // avail changes before the FBO is resized.
                    // Cell window rect (winX/Y/W/H) is stamped from the full
                    // avail above — picking uses the whole cell, not the sub-rect.
                    {
                        ImVec2 imgCursor = pos;
                        ImVec2 drawSize  = avail;
                        if (_vcell.fbo.colorTex != 0 && _vcell.fbo.w > 0 && _vcell.fbo.h > 0) {
                            float texW   = cast(float)_vcell.fbo.w;
                            float texH   = cast(float)_vcell.fbo.h;
                            float scaleX = avail.x / texW;
                            float scaleY = avail.y / texH;
                            float scale  = scaleX < scaleY ? scaleX : scaleY;
                            drawSize  = ImVec2(texW * scale, texH * scale);
                            imgCursor = ImVec2(pos.x + (avail.x - drawSize.x) * 0.5f,
                                               pos.y + (avail.y - drawSize.y) * 0.5f);
                        }
                        ImGui.SetCursorScreenPos(imgCursor);
                        if (_vcell.fbo.colorTex != 0)
                            ImGui.Image(cast(int)_vcell.fbo.colorTex, drawSize,
                                        ImVec2(0.0f, 1.0f), ImVec2(1.0f, 0.0f));
                        else {
                            ImGui.SetCursorScreenPos(pos);
                            ImGui.Dummy(avail);
                        }
                    }

                    // Task 0213: falloff ring/sphere overlay for THIS cell,
                    // recorded on the cell window's OWN draw list — AFTER
                    // the ImGui.Image call above, so it paints on top of
                    // the (opaque) cell image instead of being occluded by
                    // it, and still BELOW any other panel drawn later
                    // (falloff_render.d's panel-occlusion intent is
                    // preserved: this is a WINDOW draw list, not the
                    // foreground one). Runs every frame for every cell
                    // (not `needRender`-gated like the FBO content below),
                    // which is required — ImGui is immediate-mode, so an
                    // overlay not re-emitted this frame simply disappears
                    // this frame; the FBO loop skips unchanged cells but
                    // this call must not. `resolvedSnapshot(k)` reads this
                    // cell's camera live, already stamped with this
                    // frame's pos/size a few lines up, so no separate
                    // rect construction is needed.
                    if (_wlFp.enabled) {
                        Viewport _wlVp = vpm.resolvedSnapshot(k);
                        drawFalloffOverlay(ImGui.GetWindowDrawList(), _wlFp, _wlVp);
                    }

                    // Task 0218: corner axes/orientation gizmo for THIS
                    // cell — same window draw list, same z-order rationale
                    // as the falloff overlay just above (paints on top of
                    // this cell's opaque image, still below any panel
                    // window drawn later this frame — see gizmo.d's header
                    // comment). Anchored at THIS cell's bottom-left corner
                    // (resolvedSnapshot(k).x/y/height, already stamped with
                    // this frame's pos/size above) using THIS cell's own
                    // resolved camera basis (`.view`), so each Quad/Split
                    // cell shows its own view's axes (top/front/side/
                    // persp) rather than one master camera's. Display-only
                    // (no hit-testing exists on DrawGizmo's screen rect —
                    // grepped, none found), so no per-cell interaction to
                    // restore.
                    {
                        Viewport _gzVp = vpm.resolvedSnapshot(k);
                        DrawGizmo(ImGui.GetWindowDrawList(),
                                  cast(float)(_gzVp.x + 32),
                                  cast(float)(_gzVp.y + _gzVp.height - 32),
                                  _gzVp.view, gz_a1, gz_n, gz_a2);
                    }

                    // Task 0232: Loop Slice Slider HUD — a top-left, purple
                    // track + yellow start marker + one triangle marker PER
                    // slice + "%" label for Current, drawn on THIS cell's own
                    // window draw list (same z-order rationale as the
                    // falloff overlay / gizmo just above: paints over the
                    // opaque cell image, stays below any panel drawn later
                    // this frame). Active cell + active Loop Slice tool only
                    // — Position is a single global tool param, so only one
                    // HUD (and its markers) may exist at a time.
                    //
                    // Task 0239 (Loop Slice v2) generalises this from a
                    // single Count==1-gated marker to N markers (one per
                    // `positionsArray()[k]`), Current highlighted in cyan,
                    // the rest dimmed grey — and UN-GATES it for Count>1 (the
                    // pre-0239 gate existed only because v1's Count>1 law had
                    // no per-slice addressing to draw a meaningful marker
                    // for).
                    if (k == vpm.activeId) {
                        if (auto lst = cast(LoopSliceTool) activeTool) {
                            int lsN = lst.count();
                            if (lsN > 0) {
                                Viewport _lsVp = vpm.resolvedSnapshot(k);
                                auto dl = ImGui.GetWindowDrawList();
                                immutable ImU32 kTrackCol  = IM_COL32(160, 90, 220, 255);
                                immutable ImU32 kStartCol  = IM_COL32(230, 180, 40, 255);
                                immutable ImU32 kCurCol    = IM_COL32(60, 210, 220, 255);
                                immutable ImU32 kOtherCol  = IM_COL32(140, 140, 150, 255);
                                immutable ImU32 kLabelCol  = IM_COL32(230, 230, 230, 255);
                                float trackY    = _lsVp.y + lst.sliderY();
                                float trackLeft = _lsVp.x + lst.sliderX();
                                float lenPx     = cast(float)lst.length_px();
                                float trackRight = trackLeft + lenPx;
                                dl.AddLine(ImVec2(trackLeft, trackY), ImVec2(trackRight, trackY),
                                           kTrackCol, 2.0f);
                                enum float kTriHalf = 5.0f;
                                // Fixed start marker (the 0% anchor), left end.
                                dl.AddTriangleFilled(
                                    ImVec2(trackLeft, trackY - kTriHalf * 2),
                                    ImVec2(trackLeft - kTriHalf, trackY - kTriHalf * 2 - kTriHalf),
                                    ImVec2(trackLeft + kTriHalf, trackY - kTriHalf * 2 - kTriHalf),
                                    kStartCol);
                                // One marker per slice; Current highlighted.
                                auto lsPositions = lst.positionsArray();
                                int  lsCurrent    = lst.current();
                                foreach (lsIdx; 0 .. lsN) {
                                    float curX = trackLeft + lsPositions[lsIdx] * lenPx;
                                    ImU32 col = (cast(int)lsIdx == lsCurrent) ? kCurCol : kOtherCol;
                                    dl.AddTriangleFilled(
                                        ImVec2(curX, trackY - kTriHalf * 2),
                                        ImVec2(curX - kTriHalf, trackY - kTriHalf * 2 - kTriHalf),
                                        ImVec2(curX + kTriHalf, trackY - kTriHalf * 2 - kTriHalf),
                                        col);
                                }
                                import tools.loop_slice_tool : loopSliceHudLabel;
                                // Position is a 0..1 fraction internally; the
                                // slider readout is a true PERCENT (0.13 ->
                                // "13.00 %") — see loopSliceHudLabel (pure +
                                // unit-tested). The pre-0246 inline draw printed
                                // the bare fraction next to a "%" ("0.13 %"),
                                // which reads as ~0%; the live reference slider
                                // shows the scaled percent (task 0246 capture).
                                dl.AddText(ImVec2(trackLeft, trackY + 4),
                                           kLabelCol, loopSliceHudLabel(lst.position()));
                            }
                        }
                    }

                    // Active cell only: update outer vp used by picks.  vp.x/y
                    // already equal camera.x/y (the cell rect's single owner,
                    // V1) via resolvedSnapshot — no patch needed.  vpm.l* (the
                    // picking region) is now written every frame by the
                    // ViewportHost block above (task 0223 — the interactive
                    // single writer moved there, off the real host content
                    // rect); the SDL resize handler's write is a pre-first-
                    // frame / --test fallback only.  Patching it here from a
                    // live per-cell rect would corrupt it into a non-full-
                    // area value.
                    if (k == vpm.activeId) {
                        vp = vpm.resolvedSnapshot(k);
                    }

                    // Tracks whether the mouse is over ANY interactive widget
                    // drawn inside this cell (the view-selector combo, and any
                    // widget added here later). The full-cell ##vpHit hit-surface
                    // below covers the ENTIRE cell — including the pixels under
                    // these widgets — so on its own it would report hovered even
                    // over a widget and leak the click into scene picking. We OR
                    // each widget's own hover-rect into this flag and then require
                    // it to be FALSE before ##vpHit is allowed to mark the
                    // viewport hovered. New per-cell widgets must OR themselves in
                    // here the same way.
                    bool _cellWidgetHovered = false;

                    // Per-cell view-selector dropdown.
                    {
                        import view : ProjKind, ViewPreset;
                        import viewport : applyCellViewPreset;
                        immutable string[8] presetNames = [
                            "Perspective", "Top", "Bottom", "Front",
                            "Back", "Right", "Left", "Camera"
                        ];
                        immutable ViewPreset[8] presetVals = [
                            ViewPreset.Perspective, ViewPreset.Top, ViewPreset.Bottom,
                            ViewPreset.Front, ViewPreset.Back, ViewPreset.Right,
                            ViewPreset.Left, ViewPreset.Camera
                        ];
                        int curIdx = 0;
                        foreach (i, pv; presetVals) {
                            if (pv == _vcell.camera.viewPreset) { curIdx = cast(int)i; break; }
                        }
                        ImGui.SetCursorPos(ImVec2(4, 4));
                        ImGui.SetNextItemWidth(120.0f);
                        bool _comboOpen = ImGui.BeginCombo("##vpPreset" ~ to!string(k), presetNames[curIdx]);
                        // Capture the combo preview-button's hover-rect NOW, while
                        // LastItemData is the combo button (before the popup body
                        // is submitted). The relax flags make this report hovered
                        // whenever the cursor is geometrically over the combo,
                        // even while the combo is the active item / has an open
                        // popup — so the exclusion below holds for the whole combo
                        // interaction, not just the closed-combo frame.
                        if (ImGui.IsItemHovered(
                                ImGuiHoveredFlags.AllowWhenBlockedByActiveItem |
                                ImGuiHoveredFlags.AllowWhenBlockedByPopup))
                            _cellWidgetHovered = true;
                        if (_comboOpen) {
                            foreach (i, pn; presetNames) {
                                bool sel = (i == curIdx);
                                if (ImGui.Selectable(pn, sel))
                                    applyCellViewPreset(_vcell, presetVals[i]);
                                if (sel) ImGui.SetItemDefaultFocus();
                            }
                            ImGui.EndCombo();
                        }
                    }

                    // Task 0232/0239: Loop Slice Slider HUD hit-test. Fold #2
                    // (opponent objection, load-bearing): submitted BEFORE
                    // ##vpHit — exactly like the view combo above — and its
                    // hover ORed into `_cellWidgetHovered` with the SAME
                    // relaxed flags as the combo, so a press on the HUD never
                    // leaks into ##vpHit → viewportInputAllowed() → the
                    // tool's SDL onMouseButtonDown (which would mis-arm/mis-
                    // scrub a ring under the cursor instead of interacting
                    // with the HUD).
                    //
                    // Task 0239 generalises the single Count==1 marker
                    // button to ONE invisible button spanning the WHOLE
                    // track (bare track + every marker's pixel column) —
                    // avoids N overlapping InvisibleButtons (ImGui doesn't
                    // arbitrate overlapping siblings well) — then resolves
                    // marker-vs-bare-track by NEAREST-marker distance at the
                    // live mouse position. Edit governs what a hit does:
                    // Move drags whichever marker is nearest (or Current, if
                    // the nearest marker is farther than the hit radius —
                    // dragging the bare track still scrubs Current); Add
                    // inserts a new slice at the click fraction, but ONLY
                    // when the click did NOT land on an existing marker
                    // (avoids an accidental duplicate); Remove drops the
                    // clicked marker (a bare-track click does nothing).
                    if (k == vpm.activeId) {
                        if (auto lst = cast(LoopSliceTool) activeTool) {
                            int lsN = lst.count();
                            if (lsN > 0) {
                                Viewport _lsVp2   = vpm.resolvedSnapshot(k);
                                float trackLeft2  = _lsVp2.x + lst.sliderX();
                                float trackY2     = _lsVp2.y + lst.sliderY();
                                float lenPx2       = cast(float)lst.length_px();
                                enum float kHitHalf = 8.0f;
                                ImGui.SetCursorScreenPos(ImVec2(trackLeft2 - kHitHalf, trackY2 - kHitHalf * 3));
                                ImGui.InvisibleButton("##loopSliceHud" ~ to!string(k),
                                                      ImVec2(lenPx2 + kHitHalf * 2, kHitHalf * 4),
                                                      ImGuiButtonFlags.MouseButtonLeft);
                                if (ImGui.IsItemHovered(
                                        ImGuiHoveredFlags.AllowWhenBlockedByActiveItem |
                                        ImGuiHoveredFlags.AllowWhenBlockedByPopup))
                                    _cellWidgetHovered = true;

                                // D-ImGui's trimmed binding has no
                                // GetMousePos()/io.MousePos accessor — read
                                // the live cursor position straight from SDL
                                // (same window-pixel space `resolvedSnapshot`
                                // and the marker's own screen-space X already
                                // use), exactly like the resize-cursor code
                                // elsewhere in this file (app.d ~10324).
                                int lsMouseX, lsMouseY;
                                SDL_GetMouseState(&lsMouseX, &lsMouseY);
                                auto lsPositions = lst.positionsArray();
                                int   lsNearest   = -1;
                                float lsNearestPx = float.max;
                                foreach (lsIdx; 0 .. lsN) {
                                    float px = trackLeft2 + lsPositions[lsIdx] * lenPx2;
                                    float d  = px - cast(float)lsMouseX; if (d < 0.0f) d = -d;
                                    if (d < lsNearestPx) { lsNearestPx = d; lsNearest = cast(int)lsIdx; }
                                }
                                bool lsOnMarker = lsNearest >= 0 && lsNearestPx <= kHitHalf;
                                float lsClickFrac = lenPx2 > 0.0f
                                    ? (cast(float)lsMouseX - trackLeft2) / lenPx2 : 0.0f;

                                if (ImGui.IsItemActive()) {
                                    if (lst.edit() == LoopSliceTool.Edit.Move) {
                                        if (!lsHudDragActive) {
                                            lsHudDragActive = true;
                                            lsHudDragMarker = lsOnMarker ? lsNearest : lst.current();
                                            lst.setCurrent(lsHudDragMarker);
                                            lsHudDragAnchorFrac =
                                                (lsHudDragMarker >= 0 && lsHudDragMarker < cast(int)lsPositions.length)
                                                ? lsPositions[lsHudDragMarker] : lst.position();
                                        }
                                        ImVec2 d = ImGui.GetMouseDragDelta(ImGuiMouseButton.Left, 0.0f);
                                        float frac = lenPx2 > 0.0f
                                            ? lsHudDragAnchorFrac + d.x / lenPx2
                                            : lsHudDragAnchorFrac;
                                        lst.scrubPosition(frac);
                                    }
                                } else {
                                    lsHudDragActive = false;
                                }

                                // D-ImGui has no IsItemClicked() wrapper —
                                // IsItemDeactivated() (release-after-active
                                // on THIS item) is an adequate substitute
                                // here: Add/Remove don't have a drag
                                // behaviour of their own to distinguish from
                                // a plain click (only Move does, handled
                                // entirely by the IsItemActive() branch
                                // above).
                                if (ImGui.IsItemDeactivated()) {
                                    final switch (lst.edit()) {
                                        case LoopSliceTool.Edit.Move:
                                            break;   // handled by the drag path above
                                        case LoopSliceTool.Edit.Add:
                                            if (!lsOnMarker) lst.addSlice(lsClickFrac);
                                            break;
                                        case LoopSliceTool.Edit.Remove:
                                            if (lsOnMarker) {
                                                lst.setCurrent(lsNearest);
                                                lst.removeSlice();
                                            }
                                            break;
                                    }
                                }
                            }
                        }
                    }

                    // Full-avail invisible hover surface: drives
                    // g_viewportWindowHovered so letterbox bars remain input-live.
                    // Submitted AFTER the projection combo. Re-anchor to the
                    // content origin: the cursor is no longer at `pos` after the
                    // combo/letterbox blocks above. Guard zero-size avail:
                    // InvisibleButton asserts size != 0 (a collapsed/degenerate
                    // cell). Nothing to hover then.
                    //
                    // Deliberately NOT AllowWhenBlockedByPopup (task 0214):
                    // that flag used to make ##vpHit report hovered even while
                    // the view-preset combo's dropdown popup floats on top of
                    // the cell, so g_viewportWindowHovered stayed true and a
                    // click on a popup Selectable leaked through
                    // viewportInputAllowed() into scene picking / the active
                    // tool (selection reset, ACEN/gizmo relocate to the click
                    // point). Dropping it makes ##vpHit report NOT-hovered
                    // while ANY popup blocks it, so viewport input is
                    // suppressed for as long as a popup is open — the click
                    // that operates the popup no longer also acts on the
                    // scene. AllowWhenBlockedByActiveItem is kept (unrelated:
                    // letterbox bars stay input-live while an item is active,
                    // e.g. mid-drag).
                    //
                    // ##vpHit covers the WHOLE cell — including the pixels under
                    // the view combo — and, submitted after the combo, it reports
                    // IsItemHovered()==true even while the cursor is over the
                    // combo (both the combo and this full-cell button claim their
                    // overlapping rect). That is the OPEN-menu leak (task 0216):
                    // the click that opens the combo also set
                    // g_viewportWindowHovered=true → passed viewportInputAllowed()
                    // → picking moved the handle. Fix: require _cellWidgetHovered
                    // to be FALSE (cursor NOT over any in-cell widget) before this
                    // surface marks the viewport hovered. A normal viewport click
                    // (cursor over bare ##vpHit, no widget) keeps working; a click
                    // on the combo (or any future in-cell widget) is gated for ALL
                    // tools. This is stricter than — and layered on top of — the
                    // popup gate above, and the letterbox bars (part of ##vpHit,
                    // never a widget rect) stay input-live.
                    if (avail.x > 0.0f && avail.y > 0.0f) {
                        ImGui.SetCursorScreenPos(pos);
                        ImGui.InvisibleButton("##vpHit" ~ to!string(k), avail,
                                              ImGuiButtonFlags.MouseButtonLeft |
                                              ImGuiButtonFlags.MouseButtonRight);
                        if (!_cellWidgetHovered &&
                            ImGui.IsItemHovered(
                                ImGuiHoveredFlags.AllowWhenBlockedByActiveItem))
                            g_viewportWindowHovered = true;
                    }
                }
                ImGui.End();
                ImGui.PopStyleColor(1);
                ImGui.PopStyleVar(1);
            }

            // ── Task 0223: cross-splitter widget (drives hRatio/vRatio) ──────
            //
            // Each arm of the cross (vertical / horizontal / center) is a
            // dedicated thin, borderless, NoBackground ImGui WINDOW submitted
            // AFTER the per-cell Viewport##k loop, each holding one
            // InvisibleButton that fills it. This construction fixes the two
            // popup-layer bugs by design:
            //
            //   1. DRAW-ORDER — the arms/knob are drawn on the arm window's
            //      own GetWindowDrawList(), NOT GetForegroundDrawList().
            //      A foreground draw list composites above EVERYTHING incl.
            //      popups (so the old code painted the divider over an open
            //      `mesh.subdivide` dialog); a normal window's draw list
            //      renders BELOW the popup layer but ABOVE the cell images
            //      (these windows are created after the cells, so they sit
            //      above them in window order).
            //   2. HOVER/GRAB — hit-testing is `InvisibleButton` +
            //      `IsItemHovered()` with DEFAULT flags (NO
            //      AllowWhenBlockedByPopup — exactly like the per-cell
            //      ##vpHit gate above). ImGui returns hovered==false wherever
            //      a popup (or any higher-priority window) covers the point,
            //      so the divider cannot be hovered/grabbed UNDER a popup —
            //      the popup owns that hover. This is per-pixel: the parts of
            //      the arm the popup does NOT cover stay grabbable.
            //
            // Binding note (D-ImGui): this binding exposes InvisibleButton /
            // IsItemHovered / IsItemActive / GetMouseDragDelta / SetMouseCursor
            // / GetWindowDrawList but NOT the io.MousePos/MouseDown FIELDS
            // (nor GetMousePos/IsMouseDown functions) — so the drag is driven
            // by IsItemActive() + cumulative GetMouseDragDelta() off a
            // per-gesture ratio anchor (vpm.crossStart*Ratio), not a raw SDL
            // poll. Only the arms relevant to the CURRENT preset exist — see
            // the naming-trap table in cellRectsForRatios' doc comment:
            // SplitH/Quad get the vertical (hRatio) arm; SplitV/Quad get the
            // horizontal (vRatio) arm; Quad alone gets the center handle.
            {
                enum int kGrab    = 5;   // px, half-width of the hit strip
                enum int kMinCell = 40;  // px, minimum cell extent when dragging

                bool hasV      = (vpm.layout == LayoutPreset.SplitH || vpm.layout == LayoutPreset.Quad);
                bool hasH      = (vpm.layout == LayoutPreset.SplitV || vpm.layout == LayoutPreset.Quad);
                bool hasCenter = (vpm.layout == LayoutPreset.Quad);

                int hx = vpm.lx, hy = vpm.ly, hw = vpm.lw, hh = vpm.lh;
                int vx  = hx + cast(int)(hw * vpm.hRatio);   // vertical arm x
                int hyv = hy + cast(int)(hh * vpm.vRatio);   // horizontal arm y

                // Engage only when idle: no cell-scoped gesture
                // (dragOriginId), no camera/select drag (dragMode), no
                // in-flight tool/gizmo drag. A lasso or tool-drag already in
                // progress that happens to cross the divider strip must never
                // be hijacked (task 0223 plan §3 / §9 risk register). Note an
                // InvisibleButton only ACTIVATES on a fresh press begun while
                // hovered, so an in-flight gesture (mouse already held over a
                // cell) can't grab an arm anyway — this guard is defence in
                // depth.
                bool anyGestureActive = vpm.dragOriginId >= 0
                                     || dragMode != DragMode.None
                                     || (activeTool !is null && activeTool.isDragging())
                                     || pipeGizmoHost.isDragging();

                immutable ImU32 kLineCol = IM_COL32(160, 160, 160, 180);
                immutable ImU32 kHotCol  = IM_COL32(255, 255, 255, 230);

                // Mouse position for CENTER-ZONE CLASSIFICATION only (1D arm vs
                // 2D center) and for the resize-cursor. SDL_GetMouseState
                // returns window-client coords, which equal ImGui's main-
                // viewport coords used for vx/hyv (verified: the original
                // widget hit-tested vx against this and worked). This does NOT
                // gate engagement — that goes through the InvisibleButton's
                // IsItemActive below, so popups still block a grab per-pixel.
                int smx, smy; SDL_GetMouseState(&smx, &smy);
                bool inCenterZone = hasCenter
                                 && smx >= vx - kGrab && smx <= vx + kGrab
                                 && smy >= hyv - kGrab && smy <= hyv + kGrab;

                // Thin overlay-window flags. WindowMinSize is pushed to (1,1):
                // the default (32,32) would clamp an ~10px arm strip up to
                // 32px and block cell picking in a fat band around the
                // divider. NoBackground keeps the window invisible except for
                // our own draw-list strokes. These are PLAIN windows (NO
                // NoBringToFrontOnFocus — that flag pins a window to the
                // background z-band BEHIND the opaque cells, which occludes
                // the arm's line and makes its InvisibleButton unhittable).
                // Created after the cells each frame → above them ON FIRST
                // CREATION.
                //
                // Z-ORDER ACROSS A LAYOUT SWITCH (task 0223 regression fix):
                // "created after the cells" only guarantees front-most on the
                // FIRST Quad frame. On any layout switch the hidden cells that
                // become live again REAPPEAR, and a reappearing window with no
                // NoFocusOnAppearing calls FocusWindow (ImGui Begin sets
                // want_focus when window_just_activated_by_user), jumping ABOVE
                // any arm that didn't itself reappear (e.g. the vertical arm
                // stays visible across SplitH↔Quad and so never re-fronts). The
                // reappeared cells then steal the arm's InvisibleButton hover
                // and the splitter silently stops resizing. NoFocusOnAppearing
                // on the arms only stops THEM stealing focus; it does not keep
                // them on top. The reliable fix is to explicitly re-front both
                // arms on the frame after a layout change — see the
                // `refocusArms` handling below (driven by
                // ViewportManager.crossNeedsRefocus, set in applyLayout). The
                // arms are submitted AFTER the cells, so the explicit
                // SetWindowFocus runs after the cells' reappear-focus and wins.
                immutable int armBaseFlags =
                    ImGuiWindowFlags.NoTitleBar        | ImGuiWindowFlags.NoResize |
                    ImGuiWindowFlags.NoMove            | ImGuiWindowFlags.NoCollapse |
                    ImGuiWindowFlags.NoScrollbar       | ImGuiWindowFlags.NoScrollWithMouse |
                    ImGuiWindowFlags.NoDocking         | ImGuiWindowFlags.NoSavedSettings |
                    ImGuiWindowFlags.NoBackground      | ImGuiWindowFlags.NoNav |
                    ImGuiWindowFlags.NoFocusOnAppearing;

                // Consume the "layout just changed" flag: on this frame we must
                // explicitly raise both arms above the (possibly just-
                // reappeared, focus-stealing) cells. One-shot — cleared here so
                // steady-state Quad has zero focus churn (and never steals
                // focus from an open popup or a chrome text input).
                bool refocusArms = vpm.crossNeedsRefocus;
                vpm.crossNeedsRefocus = false;

                ImGui.PushStyleVar(ImGuiStyleVar.WindowMinSize,    ImVec2(1, 1));
                ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding,    ImVec2(0, 0));
                ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0.0f);

                // Whether the intersection knob should render hot: set by
                // whichever arm is hovered while the cursor is in the center
                // zone (there is NO separate center window — the two arm strips
                // overlap at the intersection and one of them owns the hover
                // there; a dedicated center window could not stay above an arm
                // the user just focus-raised by dragging it).
                bool centerHovered = false;

                // One arm. `arm` = 0 V (vertical/hRatio), 1 H (horizontal/
                // vRatio). A press begun inside the center zone promotes the
                // drag to mode 2 (both axes). Returns whether it is hot
                // (hovered or dragging) so the caller can suppress the scene-
                // input gate. Draws its line — and, for the H arm, the center
                // knob — on its own window's draw list (below popups, above
                // the cells).
                bool runArm(int arm, string title, int wx, int wy, int ww, int wh) {
                    if (ww <= 0 || wh <= 0) return false;
                    ImGui.SetNextWindowPos (ImVec2(cast(float)wx, cast(float)wy));
                    ImGui.SetNextWindowSize(ImVec2(cast(float)ww, cast(float)wh));
                    bool hot = false;
                    if (ImGui.Begin(title, null, armBaseFlags)) {
                        // On the frame after a layout switch, force this arm to
                        // the front so a just-reappeared cell can't sit over it
                        // and swallow the hover (task 0223). V is submitted
                        // before H, so H's SetWindowFocus runs last → the H arm
                        // (which paints the knob) ends topmost at the crossing.
                        if (refocusArms) ImGui.SetWindowFocus();
                        ImGui.SetCursorScreenPos(ImVec2(cast(float)wx, cast(float)wy));
                        ImGui.InvisibleButton(title ~ "##b",
                                              ImVec2(cast(float)ww, cast(float)wh),
                                              ImGuiButtonFlags.MouseButtonLeft);
                        // DEFAULT IsItemHovered() → false while a popup blocks
                        // this point (fixes bug 2).
                        bool hovered = ImGui.IsItemHovered();
                        bool active  = ImGui.IsItemActive();
                        hot = hovered || active;
                        if (hovered && inCenterZone) centerHovered = true;

                        if (active) {
                            if (vpm.crossDrag < 0 && !anyGestureActive) {
                                // Own the gesture; a press in the center zone
                                // drives BOTH axes from this one arm.
                                vpm.crossDrag        = arm;
                                vpm.crossBothAxes    = inCenterZone;
                                vpm.crossStartHRatio = vpm.hRatio;
                                vpm.crossStartVRatio = vpm.vRatio;
                            }
                            if (vpm.crossDrag == arm) {
                                ImVec2 d = ImGui.GetMouseDragDelta(ImGuiMouseButton.Left, 0.0f);
                                if ((arm == 0 || vpm.crossBothAxes) && hw > 0)
                                    vpm.hRatio = vpm.crossStartHRatio + d.x / cast(float)hw;
                                if ((arm == 1 || vpm.crossBothAxes) && hh > 0)
                                    vpm.vRatio = vpm.crossStartVRatio + d.y / cast(float)hh;
                                if (hw > 2 * kMinCell) {
                                    float lo = kMinCell / cast(float)hw, hi = 1.0f - lo;
                                    if (vpm.hRatio < lo) vpm.hRatio = lo;
                                    if (vpm.hRatio > hi) vpm.hRatio = hi;
                                }
                                if (hh > 2 * kMinCell) {
                                    float lo = kMinCell / cast(float)hh, hi = 1.0f - lo;
                                    if (vpm.vRatio < lo) vpm.vRatio = lo;
                                    if (vpm.vRatio > hi) vpm.vRatio = hi;
                                }
                            }
                        } else if (vpm.crossDrag == arm) {
                            // Released (or focus lost) — persist once per
                            // gesture. savePrefs() throws only on filesystem
                            // failure (mirrors the window-resize save site
                            // ~1302); a failed save here is non-fatal.
                            vpm.crossDrag     = -1;
                            vpm.crossBothAxes = false;
                            g_prefs.hRatio = vpm.hRatio;
                            g_prefs.vRatio = vpm.vRatio;
                            try savePrefs(); catch (Exception) {}
                        }

                        // A center drag (crossBothAxes) is owned by exactly one
                        // arm, so highlight/cursor must react to it in BOTH.
                        bool centerDrag = vpm.crossDrag >= 0 && vpm.crossBothAxes;
                        if (hot) {
                            bool centerCursor = centerDrag
                                             || (vpm.crossDrag < 0 && inCenterZone);
                            ImGui.SetMouseCursor(
                                centerCursor ? ImGuiMouseCursor.ResizeAll :
                                arm == 0     ? ImGuiMouseCursor.ResizeEW :
                                               ImGuiMouseCursor.ResizeNS);
                        }

                        // Draw on THIS window's draw list. Highlight while this
                        // arm — or a center drag that moves it — is active, or
                        // on hover.
                        auto dl = ImGui.GetWindowDrawList();
                        bool draggingHere = vpm.crossDrag == arm || centerDrag;
                        ImU32 col = (draggingHere || hovered) ? kHotCol : kLineCol;
                        if (arm == 0)
                            dl.AddLine(ImVec2(cast(float)vx, cast(float)hy),
                                       ImVec2(cast(float)vx, cast(float)(hy + hh)),
                                       col, 1.0f);
                        else
                            dl.AddLine(ImVec2(cast(float)hx, cast(float)hyv),
                                       ImVec2(cast(float)(hx + hw), cast(float)hyv),
                                       col, 1.0f);
                        // The H arm (submitted last, so its knob sits atop the
                        // V line at the crossing) also paints the center knob.
                        if (arm == 1 && hasCenter) {
                            bool knobHot = centerDrag || centerHovered;
                            dl.AddCircleFilled(ImVec2(cast(float)vx, cast(float)hyv),
                                               3.5f, knobHot ? kHotCol : kLineCol);
                        }
                    }
                    ImGui.End();
                    return hot;
                }

                bool crossHot = false;
                // Submit V then H (H last → its knob draws atop the crossing).
                if (hasV)
                    crossHot |= runArm(0, "##vsplitV", vx - kGrab, hy, 2 * kGrab, hh);
                if (hasH)
                    crossHot |= runArm(1, "##vsplitH", hx, hyv - kGrab, hw, 2 * kGrab);

                ImGui.PopStyleVar(3);

                // Belt-and-suspenders: when the cursor is over the splitter,
                // force the scene-input gate false so the drag never leaks to
                // picking / the active tool on the next frame's SDL events
                // (viewportInputAllowed(), 1-frame lag by design). The arm
                // window is normally ImGui's resolved hovered window over the
                // strip, so the cells' ##vpHit would not have set this true
                // there anyway — this just guarantees it.
                if (crossHot)
                    g_viewportWindowHovered = false;
            }
            // ── end cross-splitter widget ─────────────────────────────────────
        }

        // ── Phase 4 N-cell FBO render loop ───────────────────────────────────
        //
        // For each live cell: ensure FBO storage, compute a per-cell dirty key,
        // and call renderViewportSceneToFbo with that cell's camera snapshot.
        //
        // Task 0206 (Quad/Split multi-cell overlays): the tool/falloff gizmo
        // now draws in EVERY live cell, each reprojected under its own
        // camera — the overlay-OWNER cell (origin cell during a drag, else
        // the active cell) draws INTERACTIVELY (visualOnly=false: pins
        // cachedVp + runs the arbiter/hit-test cycle, exactly as before);
        // every other MULTI-CELL-ELIGIBLE cell draws a VISUAL replica
        // (visualOnly=true: world-derived geometry only, no interaction-
        // state writes — see Tool.draw's doc comment in source/tool.d). The
        // owner cell is visited LAST (`overlayDrawOrder`) so its Interactive
        // draw is the one whose cachedVp / ToolHandles registration survives
        // into the NEXT frame's event handling, regardless of how many
        // Visual replicas ran first this frame.
        //
        // "Multi-cell-eligible" (v1 scope — see
        // doc/quad_overlays_all_cells_plan.md): XfrmTransformTool (the
        // transform gizmo) and CommandWrapperTool (Smooth/Jitter/Quantize —
        // falloff-only, no gizmo bank) both got their `visualOnly` seam
        // wired this task; so did the no-tool falloff-only path. Any OTHER
        // active tool (edge/poly extrude, bevel, cone, bend, edge-extend,
        // primitives, pen, …) keeps the pre-0206 single-cell-only behaviour
        // (Visual is never assigned to them, so their draw() only ever runs
        // in the owner cell) — deferred to v2, since each owns its own
        // cachedVp / ToolHandles pair that hasn't been made visualOnly-safe.
        //
        // --test: renders ONLY the active cell (Single layout ⇒ cell 0 = ph2);
        // cellCount == 1 ⇒ overlayDrawOrder returns [activeId], so the
        // Visual branch below is NEVER taken — byte-identical to
        // pre-task-0206 behaviour.
        {
            import viewport : DirtyKey, overlayDrawOrder;
            import tools.xfrm_transform : XfrmTransformTool;
            import tools.command_wrapper : CommandWrapperTool;

            // Task 0209 (Quad/Split any-cell input), Phase 4: current rollover
            // ("hot") part on whichever arbiter owns this frame's interaction —
            // mirrors the multiCellEligible dispatch below. The arbiter lives
            // on a DIFFERENT object per case (XfrmTransformTool.toolHandles vs
            // the shared pipeGizmoHost.ownPool(), used by both the wrapper-
            // primitive and no-tool-falloff cases), so app.d scope has no
            // single field to read directly — this small dispatcher is the
            // seam. `hot` is a public int (handler.d:1565).
            int currentHotPart() {
                if (auto xf = cast(XfrmTransformTool) activeTool) return xf.hotPart();
                if (auto cw = cast(CommandWrapperTool) activeTool) return pipeGizmoHost.ownPool().hot;
                if (activeTool is null && anyFalloffActive())      return pipeGizmoHost.ownPool().hot;
                return -1;
            }

            auto _dsz = io.DisplaySize;
            float dpiX = (_dsz.x > 0.0f) ? cast(float)fbW / _dsz.x : 1.0f;
            float dpiY = (_dsz.y > 0.0f) ? cast(float)fbH / _dsz.y : 1.0f;

            bool forceActive = (activeTool !is null)
                            || (dragMode != DragMode.None)
                            || anyFalloffActive();

            // Overlay-owner cell: origin cell during a drag, else the HOVERED
            // cell (task 0209 — the arbiter/Test pass now runs where the
            // cursor is, so hover/hit-test/click work in any Quad/Split
            // cell), else the active cell. `cellCount > 1` guard makes the
            // hovered branch inert in `--test` (Single layout invariant), so
            // this stays IDENTICAL to the pre-0209 `_drawOverlays` gate
            // there — same single cell (activeId), now also the LAST one
            // visited.
            int overlayOwner = (vpm.dragOriginId >= 0) ? vpm.dragOriginId
                             : (vpm.cellCount > 1 && vpm.hoveredId >= 0) ? vpm.hoveredId
                             : vpm.activeId;

            bool multiCellEligible =
                   (cast(XfrmTransformTool)  activeTool !is null)
                || (cast(CommandWrapperTool) activeTool !is null)
                || (activeTool is null && anyFalloffActive());

            // Phase 1 (task 0206): overlay-state stamp for DirtyKey, computed
            // ONCE per frame — the gizmo's WORLD state is view-independent,
            // so the SAME value is copied into every cell's key below
            // (mirrors how `toolMat` is computed once and reused per cell).
            // Only feeds the interactive dirty-key compare; skipped in
            // --test (which never reaches that compare).
            int   _ovlKind   = 0;
            Vec3  _ovlCenter = Vec3(0, 0, 0);
            Vec3  _flCenter  = Vec3(0, 0, 0);
            float _flRadius  = 0.0f;
            // Task 0209 Phase 4: shared hot-part stamp — see currentHotPart()
            // doc above. Computed unconditionally (cheap int field read); the
            // testMode guard below only gates the packet-evaluating stamps.
            int _ovlHot = currentHotPart();
            if (!testMode && (activeTool !is null || anyFalloffActive())) {
                import toolpipe.packets : ActionCenterPacket, FalloffPacket, FalloffType;
                SubjectPacket _osubj; VectorStack _ovts; buildToolVts(_osubj, _ovts);
                if (activeTool !is null) {
                    _ovlKind |= 1;
                    if (auto p = _ovts.get!ActionCenterPacket()) _ovlCenter = p.center;
                }
                FalloffPacket _fp;
                if (auto p = _ovts.get!FalloffPacket()) _fp = *p;
                if (_fp.enabled) {
                    _ovlKind |= 2;
                    if (_fp.type == FalloffType.Element) {
                        _flCenter = _fp.pickedCenter;
                        _flRadius = _fp.pickedRadius;
                    } else {
                        _flCenter = _fp.center;
                        _flRadius = _fp.size.x + _fp.size.y + _fp.size.z;
                    }
                }
            }

            foreach (k; overlayDrawOrder(vpm.cellCount, overlayOwner)) {
                Viewport3D _cv = vpm.views[k];

                // Per-cell overlay mode: Interactive for the owner cell,
                // Visual for every other multi-cell-eligible cell, None
                // otherwise (a v2 tool, or nothing active — matches the
                // pre-0206 no-op when neither branch inside
                // renderViewportSceneToFbo's overlay block would fire).
                OverlayMode _ovMode;
                if (k == overlayOwner)
                    _ovMode = (activeTool !is null || anyFalloffActive())
                            ? OverlayMode.Interactive : OverlayMode.None;
                else
                    _ovMode = multiCellEligible ? OverlayMode.Visual : OverlayMode.None;

                // Per-cell camera snapshot.  x/y is the actual screen
                // position so tool overlay math (cachedVp screen→world) uses
                // the correct viewport origin — resolvedSnapshot bakes it
                // straight from camera.x/y (the cell rect's single owner, V1),
                // no patch needed.  In --test: camera.x/y = layout.vpX/Y =
                // construction args.  Interactive: camera.x/y is stamped by
                // the Viewport##k window loop from GetCursorScreenPos().
                Viewport vpk = vpm.resolvedSnapshot(k);

                // Per-cell FBO size (hi-DPI scaled from logical window size).
                _cv.fbo.ensure(cast(int)(_cv.camera.width  * dpiX),
                               cast(int)(_cv.camera.height * dpiY));

                // --test: only render the active cell.
                bool needRender;
                if (testMode) {
                    needRender = (k == vpm.activeId);
                } else {
                    // Interactive: dirty-key compare (skip if nothing changed).
                    bool _hovK = (k == vpm.hoveredId);
                    if (forceActive && k == overlayOwner) {
                        needRender = true;
                    } else {
                        DirtyKey _newKey;
                        _newKey.view       = vpk.view;
                        _newKey.proj       = vpk.proj;
                        _newKey.meshMutVer = mesh.mutationVersion;
                        _newKey.selEpoch   = fboSelEpoch;
                        _newKey.editMode_k = cast(int)editMode;
                        // Hover state only matters in the hovered cell.
                        _newKey.hovV       = _hovK ? hoveredVertex : -1;
                        _newKey.hovE       = _hovK ? hoveredEdge   : -1;
                        _newKey.hovF       = _hovK ? hoveredFace   : -1;
                        _newKey.fboW       = _cv.fbo.w;
                        _newKey.fboH       = _cv.fbo.h;
                        // Live tool matrix (see DirtyKey.toolMat doc): keeps
                        // inactive Quad/Split cells re-rendering during a drag
                        // instead of freezing at the pre-drag mesh state.
                        {
                            TransformTool tt = cast(TransformTool)activeTool;
                            _newKey.toolMat = (tt !is null) ? tt.gpuMatrix : identityMatrix;
                        }
                        // Task 0206 Phase 1: overlay-state term (see
                        // DirtyKey.overlayKind doc) — catches an idle
                        // gizmo/falloff appearing, moving, or resizing with
                        // no live drag in progress (meshMutVer/selEpoch/
                        // toolMat all unchanged in that case).
                        _newKey.overlayKind   = _ovlKind;
                        _newKey.overlayCenter = [_ovlCenter.x, _ovlCenter.y, _ovlCenter.z];
                        _newKey.falloffCenter = [_flCenter.x, _flCenter.y, _flCenter.z];
                        _newKey.falloffRadius = _flRadius;
                        // Task 0210: shared GPU vertex-buffer epoch —
                        // refreshes inactive Quad/Split cells during a soft
                        // (falloff) drag, where the VBO is re-uploaded each
                        // frame but meshMutVer/toolMat/overlay* do not move.
                        _newKey.gpuUploadVer = gpu.uploadVersion;
                        // Task 0209 Phase 4: shared rollover ("hot") part —
                        // the arbiter now runs in the HOVERED cell each
                        // frame, and every eligible cell draws the SAME
                        // shared `hot` state, so a non-hovered cell must
                        // re-render when `hot` flips even though its own
                        // view/proj/mesh are unchanged (see DirtyKey.overlayHot doc).
                        _newKey.overlayHot = _ovlHot;
                        if (_newKey != _cv.lastKey) {
                            needRender      = true;
                            _cv.lastKey     = _newKey;
                        }
                    }
                }

                if (needRender) {
                    bool _hovK = (k == vpm.hoveredId);
                    // Perf: draw is a TOP-LEVEL, DISJOINT phase — it runs
                    // sequentially BEFORE the ImGui section (a blit block
                    // sits between them), NOT nested inside `ui`. Scoped
                    // per-call so it accumulates across every rendered cell
                    // this frame. No-op in the default build.
                    auto zFramesDraw = g_frames.phase(Phase.draw);
                    renderViewportSceneToFbo(_cv, vpk, _ovMode,
                        showVertHover && _hovK,
                        showEdgeHover && _hovK,
                        showFaceHover && _hovK);
                }
            }

            // Keep the outer `vp` in sync with the active cell's snapshot
            // (so the --visible blit and any post-render code that reads vp
            // see the correct dimensions for the active cell).  activeSnapshot
            // already bakes camera.x/y (the cell rect's single owner) — no patch.
            vp = vpm.activeSnapshot();
        }
        // ── end N-cell FBO render loop ────────────────────────────────────

        // --visible: blit the viewport FBO into the default FB at the layout
        // viewport rect so the scene is visible during event-log replay.
        // Uses glBlitFramebuffer (pure GL) — the D-ImGui binding does not
        // expose DrawList::AddImage.
        {
            // --visible: blit the ACTIVE cell's FBO into the default FB at the
            // layout viewport rect so the scene is visible during event-log replay.
            Viewport3D _av = vpm.views[vpm.activeId];
            if (testMode && visibleTest && _av.fbo.fbo != 0) {
                int _fw = _av.fbo.w, _fh = _av.fbo.h;
                // Destination in GL bottom-up coords (flip screen-space Y).
                int _dX0 = layout.vpX;
                int _dX1 = layout.vpX + layout.vpW;
                int _dY0 = fbH - (layout.vpY + layout.vpH);
                int _dY1 = fbH - layout.vpY;
                glBindFramebuffer(GL_READ_FRAMEBUFFER, _av.fbo.fbo);
                glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
                glBlitFramebuffer(0, 0, _fw, _fh,
                                  _dX0, _dY0, _dX1, _dY1,
                                  GL_COLOR_BUFFER_BIT, GL_LINEAR);
                glBindFramebuffer(GL_FRAMEBUFFER, 0);
            }
        }

        // ---- ImGui draw ----
        // Render() must happen AFTER activeTool.draw() so any commands the
        // tool adds to the foreground draw list (snap overlay, falloff
        // overlay, etc.) are picked up by AddDrawListToDrawData — that
        // helper early-returns on an empty CmdBuffer, so adding commands
        // post-Render leaves them out of the ImDrawData snapshot.
        //
        // Phase 2: clear the default framebuffer here.  The scene glClear
        // moved into renderViewportSceneToFbo() (FBO path), so the default
        // FB is otherwise untouched this frame and would show stale pixels
        // behind the transparent DockSpace host window.
        glClearColor(0.36f, 0.40f, 0.42f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        {
            // Perf: ui phase — ImGui's own GPU submission (window-*build*
            // time earlier in the frame is unattributed "other"). No-op in
            // the default build.
            auto zFramesUi = g_frames.phase(Phase.ui);
            ImGui.Render();
            // Restore full viewport for ImGui rendering.
            glViewport(0, 0, fbW, fbH);
            ImGui_ImplOpenGL3_RenderDrawData(ImGui.GetDrawData());
        }

        // Perf (doc/frame_probe_scenarios_plan.md, task 0195): endFrame MUST
        // be placed BEFORE the present/flush conditional below. In the
        // harness's `--test --perf` mode the conditional is TRUE (perfMode
        // makes `!perfMode` false) so SDL_GL_SwapWindow (present) runs; in
        // plain `--test` it is FALSE so glFlush + SDL_Delay(4) run instead.
        // Placing endFrame here excludes present/vsync/the test delay from
        // `totalNs` in BOTH run modes, keeping it pure CPU submission cost.
        // No-op in the default build.
        g_frames.endFrame();

        // In --test mode the window is HIDDEN and nothing reads back a
        // presented frame (picking / ViewCache are projection-matrix math;
        // ImGui still renders into the GL backbuffer for any test that probes
        // draw state — it just never reaches the compositor). SwapWindow is the
        // LAST entry point into the Mesa/EGL/compositor swap path, and under
        // -j8 that path's process-/driver-global locks occasionally park one
        // instance's main thread forever in futex_do_wait (HTTP thread alive,
        // main loop dead ⇒ the worker hangs; the race-free /api/model read
        // spins on a completedEpoch the dead loop never bumps). HIDDEN +
        // vsync-off only REDUCED the rate — a hidden Wayland surface still
        // drives Mesa's swap/buffer-management locks. Skipping the swap removes
        // the contention point entirely. --perf still presents (it benchmarks
        // the real frame path on a single, non-contended instance).
        if (!(testMode && !perfMode && !visibleTest))
            SDL_GL_SwapWindow(window);
        else
            // No present, but still flush this frame's GL commands to the
            // driver so the command buffer doesn't grow unbounded across the
            // uncapped test loop. glFlush is a local driver call — it does NOT
            // touch the compositor/swap locks that SwapWindow does.
            glFlush();

        // --test runs with vsync off and no swap, so the main loop would
        // otherwise spin at uncapped FPS and burn a full core. Under -j8 that is
        // 8 cores pinned on busy-render. A 4ms floor caps the test loop at
        // ~250 FPS — far faster than any event-replay or HTTP poll needs, while
        // leaving the CPU free for the sibling workers. --perf stays uncapped.
        if (testMode && !perfMode && !visibleTest) SDL_Delay(4);
    }
}
