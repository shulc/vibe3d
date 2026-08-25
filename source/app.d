import bindbc.sdl;
import bindbc.opengl;
import std.string : toStringz;
import std.stdio : writeln, writefln, File, stderr;
import std.math : tan;
import std.conv;
import std.json : JSONValue, JSONType;

// HTTP server module
import http_server;
import ui.discard_guard : UiRunOutcome, GuardSettle;
import gl_thread_guard : markMainThread;
import log : logInfo, logWarn;
import prefs;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import d_imgui.imgui_demo;
import imgui_impl_sdl2;
import imgui_event_gate : feedImGui, keyBelongsToEditor;
import imgui_impl_opengl3;
import nfde;

import app_version      : appAboutLines;
import math;
import mesh;
// Task 1906 stage 2 — the bus-driven per-mesh-address dirty epochs the display
// and cage/preview upload families key on (see mesh_dirty.d's header).
import mesh_dirty       : MeshDirtyKey, g_displayEpochs, g_geomEpochs;
import eventlog;
import handler;
import pipe_gizmo_host : PipeGizmoHost;
import tool;
import editmode;
import seltype;
import toolpipe;
import operator         : VectorStack;
import toolpipe.packets : SubjectPacket, GesturePacket, GestureTrack;
import toolpipe.pipeline : g_pipeCtx;
import gizmo;
import view;
import shader;
import viewcache;
import perf_probe : g_perf, Cat, g_frames, Phase, FrameRec, FrameStatsSnapshot, g_fc;
import io.assimp_runtime : initAssimp, shutdownAssimp;
import symmetry_pick : symmetricSelectVertex, symmetricSelectEdge, symmetricSelectFace;
import bvh_pick : BvhPick;
import item_pick : ItemHit;   // ItemRayPicker: constructed by InputFrameState now (task 0781)
import viewgrid : g_viewGrid, viewGridSize, viewGridSubStep, viewWorldPerPixel,
                  kGridMaskMin, kGridMaskMax, kGridHalfCells, gridRungs,
                  viewGridFadeRadius;

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
import tools.edit.edge_extend : EdgeExtendTool;
import tools.alignment.radial_array_tool : RadialArrayTool;
import tools.slice.loop_slice_tool : LoopSliceTool;
import tools.slice.edge_slice_tool : EdgeSliceTool;
import tools.deform.stroke_extrude_tool : StrokeExtrudeTool;

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
import commands.viewport.fit_selected;
import commands.viewport.fit;
import commands.file.load;
import commands.file.save;
import commands.mesh.subdivide;
import commands.mesh.subdivide_faceted;
import commands.mesh.subpatch_toggle;
import commands.mesh.set_material;
import commands.mesh.set_part;
import commands.tool.headless : ToolHeadlessCommand;
import commands.mesh.split_edge;
import commands.mesh.spin_edge;
import commands.mesh.session_edit : MeshSessionEdit;
import commands.mesh.move_vertex;
import commands.mesh.select;
import commands.mesh.selection_edit : MeshSelectionEdit;
import commands.mesh.transform;
import commands.mesh.quantize;
import commands.mesh.jitter;
import commands.mesh.smooth;
import commands.mesh.weightmap;
import commands.mesh.morph;
import commands.mesh.edge_crease;
import commands.mesh.uv_transform;
import commands.mesh.uv_map_util;
import commands.mesh.edge_slide;
import commands.mesh.linear_align;
import commands.mesh.polygon_align;
import commands.mesh.radial_align;
import commands.mesh.vertex_edit;
import commands.scene.reset;
import commands.scene.load_mesh;
import macro_recorder : MacroRecorder;
import step_trace : StepTrace;
import snapshot : SelectionSnapshot;

import commands.tool.host     : ToolHost;
import commands.tool.set      : ToolSetCommand;
import commands.tool.attr     : ToolAttrCommand;
import commands.layer.commands : LayerAttr;
import commands.tool.do_apply : ToolDoApplyCommand;
import commands.tool.reset    : ToolResetCommand;
import commands.tool.pipe     : ToolPipeAttrCommand;
import commands.ui.tool_properties : UiToolPropertiesCommand, g_toolPropertiesShown;

import commands.ui.layer_list      : UiLayerListCommand, g_layerListShown;
import commands.ui.image_list      : UiImageListCommand, g_imageListShown;
import commands.ui.channels        : UiChannelsCommand, g_channelsShown;
import commands.ui.statistics      : UiStatisticsCommand, g_statisticsShown;
import commands.ui.about           : g_aboutShown;
import commands.ui.viewport_props  : UiViewportPropsCommand, g_viewportPropsShown;
version (WithAI)
import commands.ui.copilot_panel : g_copilotPanelShown;
import commands.tool.panel_edit    : ToolPanelEditCommand;
import commands.snap.toggle_type : SnapToggleTypeCommand;
import commands.snap.mode        : SnapModeCommand;
import commands.prefs.coord_rounding : CoordRoundingCommand;
import commands.prefs.trackball : TrackballPrefCommand;

/// Render one scalar argstring positional as text.
///
/// The argstring parser types its positionals: `1.0` becomes a JSON number and
// scalarArgToString: moved VERBATIM to source/http_providers.d (app.d decomp
// phase B) -- its only call sites left with the moved HTTP block.
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
import commands.workplane : WorkplaneEditCommand, WorkplaneRotateCommand, WorkplaneOffsetCommand;

import command;
import registry;
// Task 0415 (campaign 0407 §B.V1 step 1): registerTools/registerCommands
// host the command/tool factory registration moved out of main() below,
// parameterized by the EditorApp ctx bag.
import editor_app;
// Task 0781 (campaign 0407 §V1 4.3): the input-router cluster. Holds
// handleWindowEvent + handleMouseWheel (step 1's shape probe) and, since
// step 2a, the two keyboard handlers; see source/input_router.d's module doc
// comment for why the remaining three stay in main() for now.
import input_router : InputRouter;
// Task 1040 (chain 0678 §2C A10 / 0722 / 0781 "ВАРИАНТ Г"): the input/frame
// shared-state cluster -- the home for the five names 0781 found neither
// the router nor the not-yet-extracted frame body owns outright (dragMode/
// rmbPath/anySpinning/buildToolVts/viewportInputAllowed). See
// source/input_frame_state.d's module doc comment.
import input_frame_state : InputFrameState, DragMode;
import registration : registerTools, registerCommands;
import http_providers : wireHttpProviders;
import shortcuts;
import buttonset;
// Pie menus (task 1800): state + aim live in their own module so the command,
// the event pump and the drawer all read one place.
import pie_state : g_pie, openPie, closePie, aimPie, armPie;
import ai.debug_trace : latestHandleDebugTraceJson;
import ai.element_candidates : publishElementCandidates,
    collectElementCandidates, resolveElementCandidateDecision;
import ai.interaction : AiAdvisorDecision, AiCandidate, AiInteractionContext,
    AiInteractionPhase, AiIntent;
import ai.interaction_log : makeAiInteractionLogRecord;
import ai.interaction_log_writer : AiInteractionLogWriter, defaultLiveSource;
import ai.exploration : AiExplorationController, buildCandidateKey, defaultExploreSource, OptionalGrab, ResolutionKind;
import ai.state      : EditorAiState;
import ai.advisor    : AiAdvisor;
import ai.copilot_gate : kCopilotEnabled;
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
    Ai3dInstallState, ai3dDefaultInstallLocation, ai3dDefaultWorkerUrl;
import commands.ai3d.import_result : Ai3dImportResult;
import remesh.remesh_job         : RemeshJob, RemeshParams,
    MAX_REMESH_TARGET_QUADS, MIN_REMESH_TARGET_QUADS;
import commands.mesh.remesh : Remesh, RemeshStart;
import property_panel : PropertyPanel;
import forms_render;
import document       : Layer;

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

// Task 1040 -- `DragMode` now declared in input_frame_state.d (the input/
// frame shared-state cluster; `dragMode` itself, the sole field it types,
// moved there too). Imported back here for the same reason `OverlayMode`
// below already is: app.d still spells `DragMode.Xxx` at every one of
// `dragMode`'s own read/write sites.
import input_frame_state : DragMode;

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

// Task 1650 — the per-cell overlay-mode decision, in editor_app.d so that
// `/api/viewport/display` answers off the SAME code the render loop branches
// on rather than a second copy of it.
import editor_app : resolveOverlayMode;

// ---------------------------------------------------------------------------
// Module-level helpers
// ---------------------------------------------------------------------------

// edgeKey relocated to editor_app.d (task 0419 Б1 -- used by
// the UI-panel block now fully relocated to source/ui/panels.d). edgeKey
// also has a call site here, in the snap-frame JIT install path, so it is
// imported back. (`countSelected(bool[])` used to live beside it; task 0585
// removed it — its last caller was the Polygons-mode draw path, which now
// asks `mesh.countSelectedFaces()` and never materializes a `bool[]`.)
import editor_app : edgeKey;


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

// Task 1780: app.d's own call site for `buildItemFrame` was the HTTP-thread
// just-in-time snap-frame install, and task 0587 deleted that. What it imports
// from editor_app now is `installSnapState` — the once-per-frame install that
// `buildItemFrame`'s single remaining caller lives in — called from the frame
// loop just above the N-cell FBO render loop.
import editor_app : installSnapState;

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
// 0419 cyclic-import fix -- read ONLY by the UI-panel block, now fully
// relocated to source/ui/panels.d, via `with(app)`; see editor_app.d for
// the full two-gates rationale). No app.d-side references remain (Phase 7
// cleanup), so no import-back is needed here.

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main(string[] args) {
    // FIRST, before any subsystem can build a shader or a handle: record which
    // thread owns the GL context, so the two constructor funnels can name a
    // violator instead of faulting in a driver dispatch slot (task 0579's
    // death, task 0584's sweep). Inert until this line runs.
    markMainThread();

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
        } else if (args[i] == "--version") {
            // Name this build and leave. Handled INSIDE the arg loop, which
            // runs before loadSDL/SDL_Init/prefs/GL — so `--version` answers on
            // a machine with no display, no X11, no Wayland and no GPU. That is
            // not a nicety: the bug reports this flag exists for come from
            // headless installs and from users whose editor will not start.
            // Same shape as the --render-diff early exit further down.
            // (task 0641)
            import std.stdio : stdout;
            foreach (line; appAboutLines) writeln(line);
            stdout.flush();
            import core.stdc.stdlib : exit;
            exit(0);
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
    // Seed the live Coordinate Rounding setting from the loaded prefs (task
    // 0562). Done unconditionally, not only when `prefsActive`: with prefs
    // off `g_prefs` still holds the struct defaults, and this is also what
    // publishes the state path the snapping popover ticks.
    {
        import coord_rounding : setCoordRounding, setCoordRoundingFixedIncrement;
        setCoordRounding(g_prefs.coordRounding);
        setCoordRoundingFixedIncrement(g_prefs.coordRoundingFixedIncrement);
    }

    // Same, for the trackball navigation setting (task 0573).
    {
        import trackball : setTrackballGlobal, setTrackballGlobalOverride,
                           setTrackballMouseSpeed, setTrackballTabletSpeed,
                           setTrackballSwing;
        setTrackballGlobal(g_prefs.trackball);
        setTrackballGlobalOverride(g_prefs.trackballGlobalOverride);
        setTrackballMouseSpeed(g_prefs.trackballSpeed);
        setTrackballTabletSpeed(g_prefs.trackballTabletSpeed);
        setTrackballSwing(g_prefs.trackballSwing);
    }

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
    // (uiCommandDelegate / formsInteractiveDispatch / replayUndoEntry,
    // all assigned inside the `if (httpServer !is null)` block) in place for
    // the UI: status-line `kind: script` actions dispatch through
    // uiCommandDelegate, so it must be wired regardless of whether the
    // HTTP port is open. Without this, a release build (HTTP off by default)
    // left uiCommandDelegate null and every `kind: script` status-line
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

    // Task 0781 step 1a (doc/input_state_cluster_plan.md §2.1, §3 step 1a):
    // the input/frame shared-state cluster's instance. Declared here,
    // ahead of every one of its members' own forwarder declarations below
    // (the earliest of them, now that `fbW`/`fbH` joined the cluster too),
    // because a nested function/closure in D cannot forward-reference a
    // not-yet-declared sibling or local -- every forwarder below needs
    // `ifs` already in scope. A class now (this step flipped it from a
    // struct -- see input_frame_state.d's own module comment for why), so
    // this `new` is the one and only allocation for the whole run;
    // `ifs.app` is wired later, once `EditorApp app` itself is fully
    // assembled, at the same point `InputRouter.app` already is; nothing
    // calls through `ifs` before then.
    auto ifs = new InputFrameState();

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
        // Capture the live Coordinate Rounding setting back (task 0562): it
        // is changed through the popover / the command, which write the live
        // value, not `g_prefs`.
        {
            import coord_rounding : coordRounding, coordRoundingFixedIncrement;
            g_prefs.coordRounding               = coordRounding();
            g_prefs.coordRoundingFixedIncrement = coordRoundingFixedIncrement();
        }
        {
            import trackball : trackballGlobal, trackballGlobalOverride,
                               trackballMouseSpeed, trackballTabletSpeed,
                               trackballSwing;
            g_prefs.trackball            = trackballGlobal();
            g_prefs.trackballGlobalOverride       = trackballGlobalOverride();
            g_prefs.trackballSpeed       = trackballMouseSpeed();
            g_prefs.trackballTabletSpeed = trackballTabletSpeed();
            g_prefs.trackballSwing   = trackballSwing();
        }
        try savePrefs();
        catch (Exception e) logWarn("prefs", "could not write prefs.json: " ~ e.msg);
    }
    // NB: `scope(exit) if (...)`, NOT `if (...) scope(exit)`. In the latter the
    // guard binds to the `if`'s controlled-statement scope, which closes
    // IMMEDIATELY — so it would fire here at startup (persisting the just-loaded
    // prefs) and never at real shutdown, silently dropping every in-session
    // change (viewport layout, window size, recent files, tool defaults). The
    // form below registers one unconditional guard in main()'s scope that runs
    // at return and re-checks prefsActive then.
    scope(exit) if (prefsActive) persistPrefsOnExit();
    setWindowIcon(window);

    version (OSX) {
        // Make the app appear in the Dock and Command-Tab switcher when launched from terminal.
        // Use metaclass interface + objc_getClass instead of static interface methods:
        // LDC2 dispatches static ObjC interface calls to the Protocol object, not the class.
        NSApplication nsapp = objc_getClass("NSApplication").sharedApplication();
        nsapp.setActivationPolicy(0); // NSApplicationActivationPolicyRegular
        nsapp.activateIgnoringOtherApps(true);
    }

    SDL_GLContext ctx = SDL_GL_CreateContext(window);
    if (!ctx) { writefln("SDL_GL_CreateContext: %s", SDL_GetError()); return; }
    scope(exit) SDL_GL_DeleteContext(ctx);

    if (loadOpenGL() < glSupport) { writeln("Failed to load OpenGL 3.3"); return; }
    writefln("OpenGL: %s", glGetString(GL_VERSION));

    // Framebuffer size (may differ on HiDPI / Retina). Task 0781 step 1a
    // moved the storage into the input/frame cluster (`ifs.fbW`/`ifs.fbH`)
    // behind two same-name `@property ref` forwarders, so every bare site
    // stayed textually unchanged; STEP 3 DELETED THEM. Every read here is
    // now `ifs.fbW`/`ifs.fbH`, and the address-of below takes the stored
    // int's address directly -- which is also the end of step 1a's one
    // wart, the `&fbW()` spelling that existed only because `&fbW` would
    // have taken the FORWARDER's address instead of the field's.
    //
    // Not to be confused with `readDepth`'s `fbW`/`fbH` PARAMETERS at the
    // top of this module: same names, a different variable, and they are
    // deliberately untouched.
    SDL_GL_GetDrawableSize(window, &ifs.fbW, &ifs.fbH);

    // --perf disables vsync so the benchmark isn't capped at the display
    // refresh rate; --test disables it too so a hidden test window never blocks
    // in SwapWindow waiting on a compositor vblank it isn't even presenting to
    // (the -j8 swap-park hang). Normal runs keep vsync on to avoid tearing.
    // A --visible test session keeps vsync ON so the watched frames pace to the
    // display and the loop doesn't busy-spin; hidden --test stays vsync-off.
    SDL_GL_SetSwapInterval((perfMode || (command.g_testMode && !visibleTest)) ? 0 : 1);
    glEnable(GL_DEPTH_TEST);
    glViewport(0, 0, ifs.fbW, ifs.fbH);

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

    // `thickLineFragSrc`, not `fragmentShaderSrc`: the line path antialiases
    // analytically and needs the geometry stage's coverage varying, which the
    // regular fragment source cannot declare (it has no geometry stage to
    // supply it). Same uniform contract, so `initThickLineProgram`'s
    // `seedSharedFragUniforms` still covers it.
    GLuint thickLineProgram = createProgramWithGeom(vertexShaderSrc, thickLineGeomSrc, thickLineFragSrc);
    scope(exit) glDeleteProgram(thickLineProgram);
    initThickLineProgram(thickLineProgram, ifs.fbW, ifs.fbH);

    // Translucent-fill program (flat u_color at u_alpha) — backs
    // handler.drawWorldQuad, used by the Slice tool's cut-plane overlay. No
    // screen-size dependency, so it needs no per-resize re-init.
    GLuint fillProgram = createProgram(vertexShaderSrc, fillFragSrc);
    scope(exit) glDeleteProgram(fillProgram);
    initFillProgram(fillProgram);

    // Reference-image plane program (task 0612) — the first `sampler2D` in the
    // build. Its own vertex source too: it needs a texture-coordinate
    // attribute no other pass has. Deliberately NOT seeded through
    // `seedSharedFragUniforms`: it is not built from `fragmentShaderSrc`, and
    // every uniform it has is written on every draw.
    GLuint imagePlaneProgram = createProgram(imagePlaneVertSrc, imagePlaneFragSrc);
    scope(exit) glDeleteProgram(imagePlaneProgram);
    initImagePlaneProgram(imagePlaneProgram);

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
    import document : Document, primaryModelSpaceResolver, primaryModelSpace,
                      noEditTargetMesh;
    Document document = Document.bootstrap(makeCube());
    // Task 0654 — the empty item selection is legal, and then there is NO edit
    // target. `Document.activeMeshRef()` refuses by throwing, which is right for
    // a caller that requires one; this accessor is read by the frame draw and
    // the per-frame caches, which must produce a frame instead. So it resolves
    // to the empty read-only stand-in, whose zero vertices/edges/faces are the
    // truth of the state: with nothing selected there is no foreground geometry.
    //
    // This is NOT a substitute edit target — no write is supposed to arrive
    // here. `Command.apply()`'s Operator branch (via `g_editTargetResolver`,
    // installed below) and tool activation both refuse first, and
    // `test_empty_item_selection.d` asserts the stand-in stays empty afterwards.
    ref Mesh mesh() {
        // ONE walk, not three (task 1760). `hasEditTarget()` is
        // `primary !is null` and `activeMeshRef()` used to name `primary`
        // twice more, so this three-line accessor ran the derived
        // edit-target scan THREE times — and it is the accessor essentially
        // every `mesh.` in this file goes through, including the ones inside
        // per-vertex and per-element loops.
        //
        // Measured on `move/baseline`, n=316, one drag window: 1 213 372
        // derivations for 20 kernel applies. The comment that licenses
        // deriving rather than storing budgets "~100 times a frame"
        // (document_selection.d) — that premise is what this repairs, without
        // touching the decision it rests on: no pointer is stored, the walk is
        // simply not run three times for one answer.
        //
        // Behaviour is identical, branch for branch: today `hasEditTarget()`
        // true implies `primary !is null`, so `activeMeshRef()`'s throw is
        // unreachable from here and the false arm is `noEditTargetMesh()`.
        auto p = document.primary;
        return p !is null ? p.meshRef() : noEditTargetMesh();
    }
    // The command layer's half of the same rule. `command.d` cannot import
    // `document.d` (it is imported by headless tests that hold a bare `Mesh`),
    // so the question is asked through a resolver, as with the two below.
    {
        import command : g_editTargetResolver;
        g_editTargetResolver = () => document.hasEditTarget();
    }
    // TASK 1906 review B1 — the same shape, one layer down: "is this `Mesh` a
    // mesh the document owns?". `Mesh.deliverPending` consults it before a
    // synchronous change delivery reaches any listener, so a scratch instance —
    // the bevel preview's private `cage_`, a `makeCube()` under construction, a
    // kernel's half-built output — cannot drive the live document's caches
    // through this hub. `mesh.d` cannot import `document.d` for the same reason
    // `command.d` cannot, hence the resolver. Uninstalled means DELIVER (see
    // the declaration): headless unit tests have no `Document`.
    //
    // IT CANNOT BE INSTALLED EARLIER, and that is fine. The lambda closes over
    // `document`, which is `Document.bootstrap(makeCube())` above — so the six
    // `addFace` commits inside that `makeCube()` run with the resolver still
    // null and are therefore DELIVERED unfiltered. Harmless, and not by luck:
    // `changeBus.meshSubs` is empty until the hub registers far below, so those
    // six deliveries reach nobody. They do advance `changeBus.deliveryCount`,
    // which is why every test on this counter reads a DELTA.
    {
        import mesh : g_isDocumentMesh;
        g_isDocumentMesh = (const(Mesh)* m) => document.ownsMesh(m);
    }
    // Task 0617 — install the primary-layer ModelSpace resolver (mirrors
    // `activeMeshResolver` right below): every picking entry point that
    // needs "the current primary layer's transform" but has no `Document`
    // of its own (http_providers.d's HTTP-bridged closures,
    // tools/edit/topology_pen/tool.d's TopologyPenTool) resolves it through
    // `primaryModelSpace()` rather than a duplicated formula. app.d's own
    // call sites below use the same free function — one accessor, not two.
    // Task 0654 — with an empty item selection there is no primary and so no
    // item transform to resolve against. WORLD (identity) is the answer, not a
    // crash and not layer 0's frame: picking is a READ, its 66 call sites take
    // a `ModelSpace` by value with nothing to null-check, and with no
    // foreground geometry there is nothing for a non-identity space to map.
    // It is also exactly what `primaryModelSpace()` already answers when the
    // resolver is uninstalled, so the two no-target paths agree.
    primaryModelSpaceResolver = () => document.hasEditTarget()
        ? document.primary.xform.modelSpace() : ModelSpace.world();
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
        // TASK 1906 STAGE 2 — this one STAYS a `noteChange`, and the reason is
        // ordering, not taste: the mesh-channel subscriber below (the hub that
        // feeds `meshChangedFlags` AND `mesh_dirty`) is registered several
        // hundred lines further down, so a `publishChange` here would deliver
        // to an empty listener list and consume the undelivered word for
        // nothing. `pendingChanges_` survives that either way and the first
        // frame's per-layer feed at the flush site is what actually seeds the
        // epochs — which is exactly what this line is for.
        mesh.noteChange(MeshChangeAll);
    }

    // Subpatch preview: cached subdivision of the cage mesh, rebuilt lazily
    // when mesh.mutationVersion or depth changes. Depth is user-adjustable;
    // 3 is the default. Consumed by rendering and picking in
    // subsequent steps.
    SubpatchPreview subpatchPreview;
    int             subpatchDepth = 3;

    // Task 1500 — the preview build runs on this thread, not on the frame
    // loop. The editor is the ONLY user of the async path: module unittests
    // and the IPR preview (source/render/render_mvp.d) keep the synchronous
    // one, because they read `preview.mesh` on the line after the call and
    // have no frame loop to run a receiver in. This is arranged for every
    // editor run INCLUDING --test, so the async window is what the tests and
    // the perf lane actually measure.
    {
        import subpatch_worker : SubpatchWorker;
        subpatchPreview.enableAsync(new SubpatchWorker());
    }
    scope(exit) {
        // Ordered before the GL teardown scope(exit)s declared above (they
        // run in reverse): nothing may free a handle the builder is reading.
        if (subpatchPreview.worker !is null) {
            subpatchPreview.joinInFlight();
            subpatchPreview.worker.shutdown();
        }
    }

    // BVH face picker (Phase 7). One BVH per active mesh, keyed on
    // (gpu.uploadVersion, source-mesh-address) — the same tuple
    // gpu_select.d:31 uses. Default ON; VIBE3D_FACE_PICK=gpu falls back to
    // the GPU face re-render (oracle for A/B equivalence testing).
    BvhPick bvhPick = new BvhPick();
    // Task 0781 step 1c -- the item-level ray picker (task 0647) and the face
    // engine switch moved into the input/frame cluster with their only
    // readers, `pickItemUnderCursor` and `pickFaces`. Both are constructed
    // next to `ifs.app` further down (see the wiring block there for why that
    // point and not this one).

    // Tracks what is currently uploaded to the GPU so the main loop can
    // re-upload when the preview toggles on/off or when the cage changes
    // while the preview is active.
    // TASK 1906 STAGE 2a (row 3) — was `ulong gpuUploadedVersion` compared
    // against `mesh.mutationVersion`. That key could not see a version-silent
    // gizmo drag at all; it only worked here because the flush-site upload
    // above republishes on the suppressed-cage path. The key is now
    // (mesh address, geometry-class bus epoch): the address term is the one
    // `mutationVersion` never carried, and the epoch moves on exactly the
    // class this upload cares about.
    MeshDirtyKey gpuUploadedKey_;
    bool  gpuUploadedPreview;
    // TASK 1730 — the window in which the VBOs hold a limit surface whose
    // index space no longer matches the cage.
    //
    // `dispatchBuild` drops `active` and says why: "INDEX SPACE CHANGES NOW.
    // The stale trace does not outlive its cage by a single frame, so
    // `faceOrigin` can never run past `mesh.faces.length` — by construction,
    // not by a bounds check." Leaving the stale surface DRAWN (which is the
    // whole of 1730 — otherwise the cage is uploaded and uploaded back, and
    // the viewport flickers between polygonal and subdivided) makes the trace
    // outlive its cage on purpose. The construction that stood in for a bounds
    // check is therefore gone, and this predicate is what replaces it.
    //
    // NOT the same as the `uploaded && !active` pair the M-INV comment at the
    // lasso site calls legitimate. That one lives ONE frame, between a
    // mid-`tickAll` `deactivate()` and the upload block, and across it THE
    // CAGE HAS NOT CHANGED — which is exactly why `*OriginGpu` still maps into
    // it. Here the cage is what changed. Same pair of bits, different fact.
    //
    // Everything that reads `gpu.*OriginGpu` must refuse while this is true:
    // the three hover pickers and the lasso's `elementVisibility`. They are
    // the readers, and a stale map does not crash — it answers with SOMEONE
    // ELSE'S ELEMENT, which is the failure this project pays most for.
    // BOUNDED BY THE SAME CEILING as the recorded-input barrier, and that is
    // not symmetry for its own sake — an unbounded freeze wedges the viewport
    // on a build that never finishes, which is exactly what
    // `test_subpatch_async_preview` M-CEIL refuses. Past the ceiling this goes
    // false, the upload block swaps the cage in, and drawn and picked agree
    // again: a wedged build degrades to the pre-1730 flicker rather than to a
    // viewport that has stopped answering.
    // Task 0781 step 1a: body relocated to
    // InputFrameState.previewIndexSpaceStale. Step 1a kept a same-name
    // forwarder here; STEP 3 DELETED IT -- the pick family and the mouse
    // handlers left main() in steps 1c/2, and the frame body's one call
    // now reads `ifs.previewIndexSpaceStale()` explicitly.
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
    // Task 0559: the N-cell FBO loop resolves each cell's draw plan for its
    // DirtyKey term (and the HTTP display endpoint dumps the same call).
    import display_state : ViewportDisplay, DisplayState, DisplayStyle,
                           WireOverlay, BackdropStyle, DrawPlan, resolveDrawPlan;
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
        // Task 0559: restore each cell's display state. loadPrefs() already
        // rejected anything no pass draws and clamped the opacity, so what
        // arrives here is always renderable.
        //
        // Applied to ALL FOUR views, not just the ones the current layout
        // shows: `views` is a fixed array that is never reallocated, so a
        // setting made in Quad has to still be there after a session spent in
        // Single. Gated with the layout restore for the same reason it is —
        // --test must start from the shipped defaults every run, or a test
        // asserting default behaviour would pass or fail depending on
        // whichever profile happened to be on the machine.
        //
        // Task 0594 — PRECEDENCE. This loop runs AFTER applyLayout above, and
        // that ordering is the whole mechanism: applyLayout seeds each cell
        // from the shipped layout template (ortho cells lines-only), and a
        // saved choice then overwrites it. A persisted style therefore always
        // beats the new default, which is the stated requirement.
        //
        // A cell the user never configured is SKIPPED rather than applied.
        // `styleUserSet` is false only for a profile this version wrote while
        // nobody touched that cell's display; its three values are then a
        // stale echo of the old one-size default, and applying them would
        // silently undo the template on the second run of the app — the
        // shutdown flush persists whatever was loaded, so the echo is
        // guaranteed to be there. A file predating the key reads back as
        // `true` (see `ViewportCellDisplay.styleUserSet`), so an existing
        // profile keeps its appearance exactly.
        foreach (k, ref cd; g_prefs.viewportDisplay) {
            if (k >= vpm.views.length) break;
            if (!cd.styleUserSet) continue;
            vpm.views[k].display.active.style     = cd.style;
            vpm.views[k].display.active.wire      = cd.wire;
            vpm.views[k].display.active.wireAlpha = cd.wireAlpha;
            // Carry the provenance onto the cell, so a later layout switch in
            // this session re-seeds every OTHER cell but leaves this one.
            vpm.views[k].displayUserSet = true;
        }
        // Task 0570: seed the LIVE grid ladder from the persisted mask.
        // Inside the same !testMode gate as everything above, for the same
        // reason: --test must draw the shipped ladder every run regardless of
        // whichever profile is on the machine. loadPrefs() already rejected
        // an out-of-range mask, so this needs no validation.
        g_viewGrid.rungMask = g_prefs.gridStepMask;
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
    //
    // Task 0781 step 1a moved the flag into the input/frame cluster as
    // `ifs.viewportWindowHovered`, behind a same-name `@property ref`
    // forwarder so the frame body's three writes stayed textually
    // unchanged. STEP 3 DELETED THAT FORWARDER: those three writes now
    // spell `ifs.viewportWindowHovered = true/false` directly, so the
    // `g_` prefix -- which only ever meant "a main() local pretending to
    // be a global" -- is gone from app.d with it.
    // Body relocated to InputFrameState.viewportInputAllowed (task 1040).
    // Task 1040 kept a same-name forwarder here for the mouse handlers'
    // bare call sites; those handlers left main() in task 0781 step 2, and
    // STEP 3 DELETED THE FORWARDER. The one main()-side site left is the
    // `app.viewportInputAllowedDg` binding further down, which now takes
    // `&ifs.viewportInputAllowed` explicitly.

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
    // mesh marks (gpu.drawVertices/drawEdges read the marks through a borrowed
    // `MarkView` each frame — task 0585; before that they read the allocating
    // `mesh.selectedVertices` & co.), and the screen-space pick caches key off
    // GEOMETRY, not selection — so no concrete cache needs a selection-driven
    // refresh right now. The consumer is therefore wired but minimal: it
    // parks the domains in a frame-local flag, establishing the single
    // selection-consumer seam the future layer panel (the plan's named future
    // consumer) plugs into without inventing UI work now. The bus contract
    // still holds (invalidate-only: the delegate touches nothing but the flag).
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
        // Task 1906 stage 0 — the mesh channel carries the subject's address
        // as well as the flags. This hub is the per-frame AGGREGATOR: it ORs
        // every delivery (synchronous ones at the edit boundary, plus the
        // frame flush's own) into one frame-local word its six readers consume
        // below, at exactly the same place and in exactly the same order as
        // before. Per-frame aggregation is not lost; it moved out of the bus
        // into the one consumer that wants it.
        //
        // TASK 1906 STAGE 2 — and now the hub is also where `subjectAddr`
        // stops being ignored. (A delivery from `ChangeBus.flush` carries
        // subject 0 and `mesh_dirty` ignores it; the frame drain feeds the
        // same flags per layer at the flush site, where the subject is known.) `mesh_dirty.noteMeshChange` is the second half
        // of this listener: it advances a per-mesh-address EPOCH for the
        // display classes and for the geometry classes, and the consumers that
        // used to poll `mesh.pendingChanges_` or a version counter
        // (`ensureDisplayCurrent`, the flush-site upload, the cage/preview
        // upload, `BgGpu`, the surface BVH) compare against those epochs at
        // their own lazy recompute instead. ONE registration for all of them,
        // deliberately: if this subscription were ever lost, `meshChangedFlags`
        // would go with it and the viewport would stop updating loudly, rather
        // than one cache going quietly stale.
        //
        // Still dirty-bit-only per §1.5 — two ORs and a counter bump, no mesh
        // read, no allocation, no GL. `noteMeshChange` is `nothrow @nogc`.
        //
        // THE CLASSES ARE LOAD-BEARING AND THAT IS PINNED AS A PAIR by
        // `tests/test_bus_epoch_position_class.d`: strip `Position` here AND
        // at the per-layer feed in the flush block and the cage vertex VBO
        // stops following an interactive transform. Stripping it here ALONE
        // stays green (measured, task 1906 review round 2): the per-layer feed
        // re-supplies the class at the top of the same flush block that then
        // runs the upload, and no reader samples the epoch between the two
        // writers until stage 3 retires the drain. It took a purpose-built
        // cell — six existing tests, `test_bus_position_pixel` and
        // `test_bus_surface_raycast_after_drag` among them, all stay green
        // under that mutation, because every one of their rigs also publishes
        // a bulk `MeshChangeAll` (a layer promotion, a reset) whose
        // `Points|Polygons` advance the same epochs on their own.
        changeBus.onMeshChanged((size_t subjectAddr, uint flags) {
            meshChangedFlags |= flags;
            import mesh_dirty : noteMeshChange;
            noteMeshChange(subjectAddr, flags);
        });
        changeBus.onSelectionChanged((uint domains) {
            selChangedDomains |= domains;
            ++fboSelEpoch;
        });
    }

    // `Mesh.visibleVertices` is not used from this loop — the lasso path
    // that consumed it switched to `gpuSelect.elementVisibility` (see
    // `doc/lasso_gpu_pick_buffer_fix.md`). It stays in `source/mesh.d`
    // regardless: `snap.d`'s walkSource and the picking-vs-snap facing
    // predicate (see CLAUDE.md's Picking Strategy section) are live callers,
    // and it carries its own tests.
    //
    // TASK 0861 — the `VisibilityCache` wrapper that used to sit here
    // (`source/visibility_cache.d`) is gone. It had no caller of its own —
    // "useful for headless / non-GL test paths" was never true, just an
    // untested claim — and its per-mesh-address cache-key term (the one that
    // stops two same-version layers aliasing) went unexercised the whole time
    // it sat callerless (task 0833 found this and added the coverage the
    // deletion has since taken with it).

    GpuMesh gpu;
    gpu.init();
    scope(exit) gpu.destroy();
    gpu.upload(mesh);

    // Mid-batch display pull-guard (campaign 0407 §D4-в, phase 2).
    //
    // With the display upload bus-driven (the capture-and-upload at the top
    // of the flush block in the main loop), a VBO reader that runs BEFORE
    // this frame's flush — the pickers during event dispatch (same-batch
    // undo→click in an event replay), the lasso visibility readback, and the
    // two MainThreadBridge-serviced HTTP providers — could read a VBO that
    // predates a mutation applied earlier in the SAME batch. Each such
    // reader calls this guard first: when the active mesh has un-flushed
    // display-relevant changes, run the full display refresh (GPU upload +
    // pick-cache resize/invalidate) NOW.
    //
    // TASK 1906 STAGE 2a — the dedup is now ONE (address, epoch) stamp, and
    // the two-word `displayEnsured_` / `displayEnsuredMesh_` shadow it
    // replaces is gone along with its transfer-back block at the flush site.
    //
    // What the shadow was for: the guard consumed bits out of
    // `pendingChanges_`, so the frame drain had to be told which bits had
    // already been serviced and by whom, and hand them back to the flush
    // subscribers afterwards. With the display family keyed on the bus epoch
    // instead, `pendingChanges_` is never touched here at all — every other
    // subscriber keeps receiving full flags with no transfer-back, and the
    // dedup is simply "have I already serviced THIS mesh at THIS epoch".
    //
    // Multi-layer: this stamp carries the mesh ADDRESS, so a layer switch
    // mismatches it and re-services, and a background layer's dirt is no
    // longer silently dropped by the frame drain — it sits in that address's
    // epoch until the layer becomes active. (`refreshDisplay`'s own
    // active-mesh gate still keeps a background owner from being uploaded.)
    MeshDirtyKey displayServiced_;
    // A5 (post-gate fix): while the transform family drags, the VBO is
    // tool-owned (baseline + live u_model) — re-uploading LIVE verts would
    // double-apply the drag delta for any reader that renders with the tool
    // matrix. Late-bound predicate (lifecycleRecordHook pattern: null until
    // wired after `activeTool` is declared below); when it fires, readers
    // keep the pre-bus mid-drag semantics (VBO as the tool left it) and the
    // flags stay pending for the frame drain.
    bool delegate() displayVboOwnedByTool_ = null;
    void ensureDisplayCurrent() {
        import display_sync : refreshDisplay;
        import mesh_dirty   : g_displayEpochs;
        if (displayVboOwnedByTool_ !is null && displayVboOwnedByTool_()) return;
        Mesh* am = &mesh();
        const size_t a = cast(size_t)am;
        if (displayServiced_.matches(a, g_displayEpochs.epochFor(a))) return;
        refreshDisplay(am, &gpu, &vertexCache(), &edgeCache(), &faceCache());
        // STAMP WITH THE EPOCH READ **AFTER** THE REFRESH, and this is not
        // tidiness — it is what stops a self-sustaining upload loop. Under an
        // active subpatch preview `GpuMesh.upload` does not upload: it calls
        // `commitChange(MeshEditScope.Position)` on the cage (mesh_gpu.d's
        // `suppressCageUpload` arm), which DELIVERS, which advances this very
        // epoch. Stamping a value read before the call would leave the stamp
        // permanently one behind its own side effect, and every frame would
        // "refresh" again for ever.
        displayServiced_.stamp(a, g_displayEpochs.epochFor(a));
    }

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
        // Built as a UNIT lattice and scaled by the grid step at draw time
        // (task 0570), so this buffer is uploaded once and never touched
        // again no matter how the zoom moves the step.
        immutable int   N = kGridHalfCells;   // grid half-extent in cells
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

    // Selection state.
    //
    // Task 0781 step 1b: the three hover indices were plain main() locals
    // here; their storage moved into the input/frame cluster
    // (`ifs.hoveredVertex`/`hoveredEdge`/`hoveredFace`), the same pattern
    // `dragMode` / `fbW` already follow. Step 1b kept same-name forwarders
    // here so every bare read/write site stayed untouched; STEP 3 DELETED
    // THEM. The pick* family that writes the triple left main() in step 1c
    // (`pickHover`'s `alias hovered = hoveredVertex;` went with it and now
    // aliases the cluster's own field); what remains in app.d is the frame
    // body's hover-priority block, the two hover-publish lines and the
    // toolpipe display key, all of which now spell `ifs.hovered*`.
    //
    // A reader outside app.d never sees these: `ui/viewport_render.d` goes
    // through `EditorApp.hoveredVertex`/`Edge`/`Face`, whose backing
    // pointers are repointed at the cluster's fields (see the wiring block
    // beside `app.hoveredVertexPtr`). Same storage, one owner.
    mesh.resetSelection();

    // Cache: face→edge mask for Polygons mode edge highlighting.
    // Rebuilt when the face selection changes, when the mesh's connectivity
    // does, or when the primary layer is switched — see the trigger in
    // `ui/viewport_render.d` for why all three terms are needed.
    //
    // Both arrays are MARKS-shaped (`uint`, `Mesh.Marks` bits), not `bool[]`
    // (task 0585). The cache is handed to `drawEdges` as a `MarkView` over
    // itself, so it uses the one mask representation the draw path has rather
    // than a second one that could drift from it; and the snapshot is a copy
    // of `mesh.faceMarks` itself, so detecting a change needs no materialized
    // `bool[]` of the current selection to compare against — that comparison
    // used to allocate a `bool[F]` on the RIGHT-HAND SIDE of its own cache
    // check, every frame, which cost more than the cache saved.
    uint[] faceSelEdgesCache;    // per EDGE:  0 or Mesh.Marks.Select
    uint[] faceSelEdgesPrevSel;  // per FACE:  copy of faceMarks at last rebuild
    // WHICH MESH the two arrays above were built from, and at what topology.
    // The cache is a function of the face SELECTION *and* of `faces`/`edges`,
    // but the detector beside it can only see the selection — so without this
    // key a primary-layer switch between two layers whose face marks happen to
    // agree (same face count, same faces selected) leaves the previous layer's
    // edge mask painting the new layer's edges. That is exactly the hazard
    // `MeshCacheKey`'s doc comment describes, and this is the same
    // address-keyed convention `snap.d` / `bvh_pick.d` already use.
    //
    // `MeshStructKey`, NOT `MeshCacheKey`: the mask depends on connectivity
    // only, and `mutationVersion` moves once per vertex per motion event, so
    // the `MeshCacheKey` spelling would rebuild this on every frame of a drag
    // — putting a selection-sized allocation back on the per-frame path, which
    // is what task 0585 exists to take off it.
    MeshStructKey faceSelEdgesKey;

    // Cache: edge-loop hover mask for ElementMove + falloff EdgeLoops.
    // Hovering an edge pre-highlights the whole loop ring (mirrors the apply,
    // which expands a picked edge to its loop). The loop WALK (edgeLoopRing +
    // the ring→edge-index map) is expensive, so recompute ONLY when the hovered
    // edge or the mesh topology changes — never per frame.
    bool[] loopHoverEdgesCache;
    int    loopHoverPrevEdge = -2;        // hoveredEdge at last rebuild (-2 = never)
    ulong  loopHoverPrevTopo = ulong.max; // mesh.topologyVersion at last rebuild
    bool   loopHoverPrevSlice = false;    // ring KIND at last rebuild (slice vs edge-loop)

    // Task 1040: state relocated to InputFrameState.dragMode, behind a
    // same-name forwarder that kept all ~46 bare read/write sites
    // untouched. The mouse handlers and the pick* family left main() in
    // task 0781 steps 1c/2, and STEP 3 DELETED THE FORWARDER: the frame
    // body's six remaining reads -- the `doingCameraDrag` term and the two
    // "is a drag in flight" guards -- now spell `ifs.dragMode`.
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
    // Task 0781 step 2c: `rmbDragging` relocated to InputRouter alongside
    // handleMouseMotion -- router-exclusive state by 0781's own
    // classification, so it MOVES rather than joining the cluster the way
    // its trail `rmbPath` did. Its same-name forwarder died in step 2d with
    // the press/release handlers, its last main()-side readers.
    // Task 1040: state relocated to InputFrameState.rmbPath, behind a
    // same-name forwarder that kept its ~13 bare read/write sites
    // untouched. The mouse handlers left main() in task 0781 step 2d, and
    // STEP 3 DELETED THE FORWARDER: what remains is the frame body's lasso
    // overlay, which now reads `ifs.rmbPath`.
    //
    // THAT OVERLAY IS THE ONE CONSUMER IN THIS TASK WITH NO ORACLE, named
    // rather than assumed (plan section 6.3). It draws through an ImGui
    // foreground `DrawList`, and `/api/viewport/probe` reads the FBO, so no
    // suite test can see those four lines at all. The array's STATE is
    // covered -- the same `ifs.rmbPath` drives the lasso selection in the
    // moved `handleMouseButtonUp`, asserted by selected-id count in
    // `tests/test_lasso_select.d` -- but the DRAW is not. Step 3 therefore
    // renamed the reference in that block and changed nothing else in it.

    // Phase C.x: interactive selection edit session. Task 0781 step 2d moved
    // the three fields AND the `beginInteractiveSelEdit` /
    // `commitInteractiveSelEdit` pair that is their only reader to InputRouter,
    // with the two mouse handlers that were the pair's only callers. No
    // forwarder: nothing in main() names any of them any more.

    // Gizmo size: the `-` / `+` ladder lives in handles/gl_util.d as
    // `stepGizmoHandleScale`, which walks the handle-size preference by +-0.5
    // over [0.5, 5.0] — ten linear steps, 60..600 px of arm, default 120.
    //
    // Task 0597 replaced the nine geometric levels (50..480) that used to sit
    // here. The reference's steps are NOT a free choice: four ornament sizes
    // stop growing at a knee near 1.2-1.25, so a ladder that skips past the
    // knee differently changes what the user sees change. Keeping the state in
    // gl_util.d beside the sizes it feeds is also what lets a plain unittest
    // walk the ladder without standing up the app.

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
    //
    // Reachable from other modules as `EditorApp.anyFalloffActive` (the
    // delegate bound below) — that is how ui/viewport_render.d and, since
    // task 1650, `/api/viewport/display`'s provider call it, so the overlay
    // gate and the endpoint that reports it share one predicate.
    bool anyFalloffActive() {
        import toolpipe.pipeline       : g_pipeCtx;
        import toolpipe.stage          : TaskCode;
        import toolpipe.stages.falloff : FalloffStage;
        if (g_pipeCtx is null) return false;
        foreach (s; g_pipeCtx.pipeline.findAllByTask(TaskCode.Wght))
            if (auto fo = cast(FalloffStage) s)
                if (fo.pipeEnabled && fo.isActive())   // type != None; alloc-free
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
        // Settled-mesh precondition (debug-only, stripped from release builds
        // — task 0724 / audit-4 M6). Both arms below read structVersion-
        // derived state off the LIVE mesh: `loopSliceRingEdges` /
        // `edgeLoopRing` walk the loops family, and the ring→edge-index
        // mapping goes through edgeIndexMap. This runs once per frame at
        // hover, i.e. AFTER whatever command last touched topology has
        // returned, so every mutator's terminal buildLoops() has landed.
        //
        // TASK 0833 — NOT demonstrable HERE, by construction: this function is
        // nested inside `main()` (it is handed to `EditorApp` as a delegate),
        // so no unit test can call it and no amount of fixture work would
        // change that. What is demonstrated instead is the SAME pair over the
        // SAME reads at the deliberate copy of this code,
        // `LoopSliceTool.toolStateJson` — a stale-loops mesh makes it throw,
        // and deleting its `assertLoopsValid()` turns
        // tests/unit/tools/slice/loop_slice_tool_test.d red. The precondition
        // travels with the copy precisely so the two spellings cannot disagree
        // about when it is legal to run; that is also what makes the copy a
        // fair stand-in for this one.
        //
        // The `assertEdgeMapValid()` below cannot be the sole failure on this
        // tree, and since task 0790 deleted `buildLoops`'s
        // `rebuildEdgeIndexMap` parameter (the one arm that could produce
        // "loops valid, map stale") that is now true BY CONSTRUCTION, not
        // just unobserved — see the note at commands/select/loop.d and case 7
        // of the stamp trace table in tests/unit/mesh_test.d. Kept anyway as
        // the guard that starts discriminating the day some future primitive
        // reintroduces a producer.
        mesh.assertLoopsValid();
        mesh.assertEdgeMapValid();
        // `sliceRing`: highlight the ring the loop-SLICE lands on (seed +
        // quad-ring exit rails) instead of the classic edge LOOP. Those run
        // perpendicular, so the Loop Slice tool needs this or the highlighted
        // ring won't match the cut (task 0231). Part of the cache key: two
        // tools can share hovEdge + topology yet want different rings.
        bool sliceRing = activeTool !is null && activeTool.edgeLoopHoverSliceRing();

        // recorded remainder (1906 §3.6): `topologyVersion` owns this compare
        // and keeps it — the ring walk is a function of connectivity alone, and
        // that counter is exactly `Points|Polygons`. Nothing here is
        // position-dependent, so the 0401 class this task is about cannot
        // reach it. Plan §3.4 row 20.
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

    // Reset every pipe stage that opts into "clear on tool switch unless
    // the user explicitly locked it" — ActionCenter / Axis / Constrain /
    // Falloff today (userLocked survives; reference parity captured
    // 2026-06-16). Snap / Symmetry / Workplane / Path deliberately do NOT
    // opt in: their state is a user SETTING, not a tool session, and
    // survives a tool switch. The dispatch itself lives in
    // toolpipe.pipeline.resetToolSwitchTransientStages (task 0980 / audit-4
    // P7) — a generic walk keyed on the `ToolSwitchTransient` interface,
    // replacing a hand-written `switch (s.id())` that silently skipped any
    // stage whose id/taskCode it didn't happen to name (see that
    // function's doc for what this fixes).
    void resetTransientPipeStages() {
        import toolpipe.pipeline : g_pipeCtx, resetToolSwitchTransientStages;
        if (g_pipeCtx is null) return;
        resetToolSwitchTransientStages(g_pipeCtx.pipeline);
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

    // EditSession — the single driver of the Tool session protocol (task
    // 0428). DECLARED here so the nested setActiveTool below can reference it
    // lexically; CONSTRUCTED at the ToolHost block further down (`history`
    // exists only from there). Null until wired — same pattern as
    // lifecycleRecordHook above; users that can run pre-wiring guard on
    // non-null.
    import edit_session : EditSession;
    EditSession session;

    // -------------------------------------------------------------------------
    // Task 1670 — POSE THE FRESH TOOL AT ARM TIME.
    //
    // Every `tool.set` builds a NEW tool (the drop above destroys the old
    // one), and `activate()` poses nothing. The tool's resident pose — for
    // `xfrm.transform` that is `moveSub.handler.center`, written only by
    // `setSharedGizmoPose` at the top of `update()`/`draw()` — therefore held
    // its CONSTRUCTOR value, `Vec3(0,0,0)`, from the moment `setActiveTool`
    // returned until the frame loop reached `activeTool.update(vts)`.
    //
    // That is observable and it was observed. `/api/tool/state` is answered
    // STRAIGHT OFF THE HTTP THREAD from those resident fields (deliberately —
    // see http_server.d's route-contract comment), so a read served after the
    // command bridge drained `tool.set` inside `httpServer.tickAll()` and
    // before that same frame reached the tool tick reports the un-ticked
    // default. It surfaced as one `(0,0,0)` gizmo centre in 689 tests on the
    // nightly sanitizer lane, where software GL stretches the frame far
    // enough to hit a window that is sub-millisecond on hardware GL.
    //
    // MARSHALLING THE ROUTE WOULD NOT HAVE CLOSED IT, which is why the fix is
    // here and not in http_server.d (whose own comment suggests marshalling
    // for this family of hazard). The bridges drain at the TOP of the frame,
    // `foreach (b; bridges) b.tick()`; a read arriving right after the command
    // reply can be picked up by a LATER bridge in the SAME `tickAll` pass and
    // answered ahead of `update()` regardless. Posing at arm time closes the
    // window for EVERY consumer of the tool's resident state — the route, the
    // panels, anything that reads a freshly armed tool — instead of for one
    // route on the frames where the draw order happens to help.
    //
    // Declared HERE and wired further down (next to `ifs.app`), because
    // `buildToolVts` is a nested function declared much later in `main()`:
    // the same null-until-wired hook pattern `lifecycleRecordHook` above uses.
    // A `setActiveTool` that runs before the wiring behaves exactly as it did
    // before this task.
    void delegate() armedToolPoseHook;

    // Task 1670 — the instrument that makes the window above a DETERMINISTIC
    // cell instead of a lottery. Repetition is not an instrument here: 40 idle
    // runs and 30 under six-way load produced zero failures on this host.
    // Edge-triggered by an arm below, consumed at the seam in the frame loop,
    // and inert unless VIBE3D_STALL_PRE_TOOL_TICK_MS is set — source/
    // frame_stall.d carries the reasoning and the unittests that assert that
    // inertness by wall clock.
    import frame_stall : FrameStall;
    auto preToolTickStall =
        FrameStall.fromEnvironment("VIBE3D_STALL_PRE_TOOL_TICK_MS");

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
            // Capture the dropped tool id BEFORE destroying (the session's
            // LifecycleUndoEmitter gate ensures only transform tools emit).
            // `session` null-guard: this nested function is declared before
            // the session is constructed at the ToolHost block — pre-wiring
            // drops see no emit, equivalent, since no transform tool can be
            // active before wiring completes.
            string droppedId = (session !is null && session.activeToolEmitsLifecycle()
                                && activeToolId.length > 0)
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
        if (activeTool) {
            activeTool.activate();
            // Task 1670 — tick the fresh tool ONCE, right here, with the same
            // (SubjectPacket, VectorStack) pair the frame loop builds for its
            // own `activeTool.update(vts)`. Only the MOMENT differs: the pose
            // and `cachedSubjType_` are now valid the instant `tool.set`
            // returns. See `armedToolPoseHook`'s declaration above for the
            // window this closes and why the route was the wrong place.
            //
            // Not re-entrant by inspection: no tool's `update()` reaches
            // `setActiveTool` (nothing under source/tools/ touches
            // `resetActiveTool` or a tool drop), so this cannot recurse.
            if (armedToolPoseHook !is null) armedToolPoseHook();
            // …and tell the stall a tool was armed, so a test run with
            // VIBE3D_STALL_PRE_TOOL_TICK_MS set widens EXACTLY this window
            // once, rather than pausing every frame of the run.
            preToolTickStall.arm();
        }
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
    //
    // Task 0642 renamed this to `promoteItemType` (it was `switchToItemType`) so it
    // pairs with `promoteGeometryType` above: BOTH are the "a selection
    // command changed the type as a side effect" path, and neither drops the
    // tool. The deliberate DOOR into item mode is `switchItemType` below —
    // the `switchGeometryType` analogue. Two verbs, one distinction, spelled
    // the same way on both sides of the geometry/item line.
    void promoteItemType() {
        import change_bus : noteCurrentType;
        const flipped = selTypeOrder.touch(SelType.Item);
        if (flipped)
            noteCurrentType(SelType.Item);
    }

    // -------------------------------------------------------------------------
    // Task 0642: the DELIBERATE door into item mode — the item analogue of
    // `switchGeometryType`, driven by the status-line Items button, the Items
    // key, and `select.typeFrom item`. `SelType.Item` was already reachable,
    // but only as a SIDE EFFECT of selecting a layer; this is the way in that
    // does not require touching the item selection at all.
    //
    // Same front-flip contract as switchGeometryType, with one difference that
    // is structural rather than a choice:
    //   * `editMode` is NOT written. `EditMode` has three values and is the
    //     geometry VIEW; under `SelType.Item` it deliberately retains the
    //     most-recent geometry type so picking/drawing keep a defined mode
    //     (seltype.d; asserted on the /api/selection boundary). Switching to
    //     Items must therefore leave it exactly where it was — that is also
    //     what makes 1/2/3 afterwards restore the SAME geometry type rather
    //     than an arbitrary one, since the recent-ordering still remembers it.
    //   * A flip DOES drop the active tool, matching switchGeometryType's B2
    //     rule: pressing a MODE key/button is an interaction-mode change. (The
    //     promote path above deliberately does not — a selection is not a mode
    //     change. Unmeasured against the reference: its input map spells this
    //     door as the same command family as 1/2/3, so we make the door behave
    //     like the other doors rather than inventing a third rule.)
    void switchItemType() {
        import change_bus : noteCurrentType;
        const flipped = selTypeOrder.touch(SelType.Item);
        if (flipped) {
            setActiveTool(null);          // tool-drop on a front-flip (B2)
            noteCurrentType(SelType.Item);
        }
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
    // RecordMode: relocated verbatim to editor_app.d's module level (app.d
    // decomp phase B) so EditorApp's applyOrRefire field can name the type;
    // resolves here via `import editor_app;`.
    // Returns TRUE iff the command actually landed (applied, or fired inside
    // an open refire bracket). Task 1520 needs the answer: the UI adapter must
    // tell "refused" from "applied" WITHOUT a throw, because the throw is what
    // killed the editor from inside an ImGui draw.
    bool applyOrRefire(Command cmd, RecordMode mode, string throwMsg) {
        // Post-mode finalize (task 0463, SDK-derived — the reference's
        // MODEL command class + its command-system post-mode listener; see
        // toolcards/_framework/shift_apply_rearm.md "Command-fired post-mode
        // finalize"). A Model (scene-mutating) command executed while an
        // interactive tool is armed DROPS the tool FIRST — committing any
        // pending live edit via deactivate() — then runs. In the reference
        // editor a MODEL-class command triggers the armed post-mode session's
        // registered end-callback, which for an interactive mesh tool tears the
        // toolpipe down (a hard DROP, not the Shift+click commit-and-rearm); it
        // fires regardless of whether the command's target relates to the
        // tool's own geometry (measured — deleting an unrelated face still
        // drops the armed bevel). Without this, Delete-while-bevelling ran on
        // the live-preview mesh, leaving the tool's session desynced.
        //
        // The single chokepoint: both runCommand (keyboard / UI) and the HTTP
        // /api/command dispatch funnel here. This targets INCREMENTAL mesh-edit
        // commands (delete / subdivide / bevel / extrude …) that build on the
        // current mesh. Excluded families keep the tool (or manage it
        // themselves):
        //   * tool.* — the tool's OWN commands (tool.attr / tool.set are
        //     SideEffect anyway; tool.doApply is Model but is the tool applying
        //     itself). They CONTINUE the session, never end it.
        //   * scene.* / file.* — scene-REPLACE / lifecycle commands
        //     (scene.reset = file.new, file.load, scene.loadMesh). They DISCARD
        //     the armed edit via their own dropArmedPreview()+setActiveTool(null)
        //     teardown; a commit-and-drop here would land a bogus edit entry
        //     ahead of the reset (test_scene_reset_armed_tool).
        //   * selection / edit-mode commands are UiState (not Model), already
        //     skipped by the flag.
        //   * layer.attr, and ONLY layer.attr, of the `layer.*` family (task
        //     0614 Phase 5 review, B1). It writes one property of one EXISTING
        //     layer through the same param path the item transform tool itself
        //     writes, so it CONTINUES the session for the same reason `tool.*`
        //     does. Concretely: under SelType.Item the Layers panel's transform
        //     rows dispatch `layer.attr` (config/forms/layer_props.yaml) and
        //     Phase 5 deliberately un-greyed those rows while a transform tool
        //     is armed — so without this exclusion the FIRST numeric edit in a
        //     freshly-enabled row would drop the tool and take the gizmo with
        //     it, making the phase's own goal unreachable through exactly the
        //     rows it enabled.
        //
        //     A blanket `layer.` prefix would be WRONG. Of the Model-class
        //     `layer.*` commands — add, duplicate, reorder, delete, rename,
        //     setVisible, attr, parent (`layer.select` is UiState and already
        //     skipped) — `layer.attr` is the only one that can change neither
        //     the layer SET nor WHICH layer is primary. add / duplicate make a
        //     NEW layer primary, delete can remove the tool's own target, and
        //     setVisible can promote a different layer when the primary is
        //     hidden: for those the drop is correct, and each additionally
        //     routes a primary change through `onActiveLayerChanged` (which
        //     drops the tool itself). reorder / rename / parent leave the
        //     primary put but are not session CONTINUATIONS either, so they
        //     keep the status-quo drop.
        // Never fires during a refire bracket (those carry only SideEffect
        // tool.attr); after the drop activeTool is null so the tool's own
        // lifecycle-undo emit cannot re-enter this branch.
        if (activeTool !is null && (cmd.cmdFlags() & CmdFlags.Model)) {
            import std.string : startsWith;
            string cn = cmd.name();
            if (!cn.startsWith("tool.")
                && !cn.startsWith("scene.")
                && !cn.startsWith("file.")
                && cn != "layer.attr") {
                setActiveTool(null);
                activeToolId = "";
            }
        }
        // Task 0616 Ph5 review (S3): a command that knows WHY it declined gets
        // to say so. `Command.refusalReason()` is "" for everything that has
        // not opted in, in which case the thrown text is byte-identical to
        // what it always was; a command that refuses for several different
        // reasons (a bad index vs. an unreadable path vs. a row of the wrong
        // kind) can name the one it hit, and the caller — a script, an HTTP
        // client, the panel that surfaced the error — reads it instead of
        // "did not apply".
        string failMsg() {
            auto why = cmd.refusalReason();
            return why.length > 0 ? throwMsg ~ ": " ~ why : throwMsg;
        }
        if (history.refireActive) {
            if (history.fire(cmd)) return true;
            if (throwMsg !is null) throw new Exception(failMsg());
            return false;
        }
        if (cmd.apply()) {
            final switch (mode) {
                case RecordMode.Record:     history.record(cmd);           break;
                case RecordMode.Coalescing: history.recordCoalescing(cmd); break;
            }
            return true;
        }
        if (throwMsg !is null) throw new Exception(failMsg());
        return false;
    }

    // Phase 7: macro recorder captures successful command lines
    // (via history.onRecord delegate) when active. Survives undo /
    // redo / clear-history — saving a macro after several edits
    // produces a replayable script regardless of intervening undos.
    auto macroRecorder = new MacroRecorder();

    // GET /api/trace — non-destructive per-step capture. Every discrete
    // recorded command appends one entry (command + args + the resulting
    // selection in WORLD POSITIONS + a full mesh snapshot) to `stepTrace`, so
    // an external observer can reconstruct every intermediate editing step
    // (mesh + selection) without the destructive /api/history/jump path
    // (jump actually rewinds/replays the live undo stack; this is a
    // read-only side log). See captureStepTrace() below for the coalescing
    // guard that keeps interactive-drag gesture steps out of the ring.
    //
    // Null-decl here, constructed ONLY when startHttpServer (see below) —
    // the trace is readable exclusively over HTTP, and a release/default run
    // has HTTP off, so a release build must not pay for the ring buffer's
    // memory at all. Every consumer (captureStepTrace, the HTTP providers,
    // the /api/reset handler) null-guards against the unconstructed case.
    StepTrace stepTrace;

    // COALESCING GUARD: recordInSession()/replaceInSessionTail() fire
    // onRecord once per gesture STEP of an open interactive-tool run
    // (HistoryFlags.InSession; a falloff re-grade of that run's last gesture
    // additionally carries Refire — see command_history.d). Capturing every
    // one of those would spam the trace with a full-mesh snapshot per drag
    // frame. Only entries that reach the plain record()/recordCoalescing()
    // path — a discrete, committed command (subdivide, delete, select, or a
    // transform once its run has consolidated into ONE entry) — are
    // captured here; InSession/Refire entries early-return.
    void captureStepTrace(string line, uint flags) {
        import command_history : HistoryFlags;
        import std.string : indexOf;
        // Defensive only: this is wired into history.onRecord exclusively
        // from the `if (startHttpServer)` branch below, where stepTrace is
        // freshly constructed non-null — so this can't fire in practice, but
        // guard it anyway rather than rely on that invariant silently.
        if (stepTrace is null) return;
        // Unarmed ⇒ nothing to build. This check is FIRST because everything
        // below serializes the whole mesh (task 0680): on a 100 000-face mesh
        // one entry measured 75-160 ms, dwarfing the command it describes.
        // POST /api/trace/reset arms; see StepTrace's own comment.
        if (!stepTrace.armed) return;
        if (flags & (HistoryFlags.InSession | HistoryFlags.Refire)) return;
        // ToolLifecycle entries are recorded from INSIDE setActiveTool's drop,
        // i.e. after the outgoing tool's deactivate() has already released its
        // session state — so the invariant the `entry["tool"]` capture below
        // documents and relies on ("the tool that produced this step is still
        // activeTool, with its params untouched") does NOT hold here, and
        // reading toolStateJson() off the half-torn-down tool segfaults. Task
        // 0678 D9-a wired recordToolLifecycle into onRecord so the MACRO
        // RECORDER stops missing tool drops; that consumer only wants the
        // command line and is unaffected. A tool drop is not a model step,
        // so the trace loses nothing by skipping it.
        if (flags & HistoryFlags.ToolLifecycle) return;

        string command = line;
        string args    = "";
        auto sp = line.indexOf(' ');
        if (sp >= 0) {
            command = line[0 .. sp];
            args    = line[sp + 1 .. $];
        }

        JSONValue vecJson(Vec3 v) {
            return JSONValue([JSONValue(cast(double)v.x),
                               JSONValue(cast(double)v.y),
                               JSONValue(cast(double)v.z)]);
        }

        SelType st = selTypeOrder.current();

        // Selection payload in WORLD POSITIONS — shape mirrors what
        // geometry-diff tooling already consumes elsewhere in the project.
        JSONValue selection = JSONValue.emptyObject;
        selection["selType"] = JSONValue(selTypeToken(st));
        final switch (st) {
            case SelType.Polygon: {
                JSONValue[] faceArr;
                auto sel = mesh.selectedFaces;
                foreach (fi; 0 .. mesh.faces.length) {
                    if (fi >= sel.length || !sel[fi]) continue;
                    JSONValue[] vp;
                    foreach (vi; mesh.faces[fi]) vp ~= vecJson(mesh.vertices[vi]);
                    faceArr ~= JSONValue(vp);
                }
                if (faceArr.length > 0) selection["faces"] = JSONValue(faceArr);
                break;
            }
            case SelType.Edge: {
                JSONValue[] edgeArr;
                auto sel = mesh.selectedEdges;
                foreach (ei; 0 .. mesh.edges.length) {
                    if (ei >= sel.length || !sel[ei]) continue;
                    JSONValue eo = JSONValue.emptyObject;
                    eo["v0"] = vecJson(mesh.vertices[mesh.edges[ei][0]]);
                    eo["v1"] = vecJson(mesh.vertices[mesh.edges[ei][1]]);
                    edgeArr ~= eo;
                }
                if (edgeArr.length > 0) selection["edges"] = JSONValue(edgeArr);
                break;
            }
            case SelType.Vertex: {
                JSONValue[] vertArr;
                auto sel = mesh.selectedVertices;
                foreach (vi; 0 .. mesh.vertices.length) {
                    if (vi >= sel.length || !sel[vi]) continue;
                    vertArr ~= vecJson(mesh.vertices[vi]);
                }
                if (vertArr.length > 0) selection["verts"] = JSONValue(vertArr);
                break;
            }
            case SelType.Item:
                // Layer/item selection carries no vertex/edge/face geometry —
                // "selType":"item" is the whole signal.
                break;
        }

        // Full mesh snapshot — same core shape as /api/model
        // (vertexCount/edgeCount/faceCount/vertices/faces). Built inline
        // rather than calling the httpServer block's meshToDetailedJson():
        // that helper is declared later AND one scope deeper (inside
        // `if (httpServer !is null)`), out of reach from this nested
        // function (app.d's nested functions can only see locals/functions
        // declared lexically above them).
        JSONValue[] vertsJson;
        foreach (vi; 0 .. mesh.vertices.length)
            vertsJson ~= vecJson(mesh.vertices[vi]);
        JSONValue[] facesJson;
        foreach (fi; 0 .. mesh.faces.length) {
            JSONValue[] fv;
            foreach (vi; mesh.faces[fi]) fv ~= JSONValue(vi);
            facesJson ~= JSONValue(fv);
        }
        // Per-face subpatch flags, parallel to faces[] — same shape /api/model
        // emits (`"isSubpatch": [false,false,...]`). Defensive length guard
        // mirrors the padding rule in meshToJsonDetailed (http_server.d):
        // isSubpatch lazy-resizes on write, so a face index can outrun it
        // between a face-add and the next selection touch.
        JSONValue[] subpatchJson;
        auto subView = mesh.isSubpatch;
        foreach (fi; 0 .. mesh.faces.length)
            subpatchJson ~= JSONValue(fi < subView.length && subView[fi]);
        // Per-face hide flag, same mirrored shape as isSubpatch above (task
        // 0613 Stage 2) — non-allocating scalar accessor, bounds-checked
        // internally, so no defensive length guard is needed here.
        JSONValue[] hiddenJson;
        foreach (fi; 0 .. mesh.faces.length)
            hiddenJson ~= JSONValue(mesh.isFaceHidden(fi));
        JSONValue meshJson = JSONValue.emptyObject;
        meshJson["vertexCount"] = JSONValue(mesh.vertices.length);
        meshJson["edgeCount"]   = JSONValue(mesh.edges.length);
        meshJson["faceCount"]   = JSONValue(mesh.faces.length);
        meshJson["vertices"]    = JSONValue(vertsJson);
        meshJson["faces"]       = JSONValue(facesJson);
        meshJson["isSubpatch"]  = JSONValue(subpatchJson);
        meshJson["faceHidden"]  = JSONValue(hiddenJson);

        JSONValue entry = JSONValue.emptyObject;
        entry["seq"]       = JSONValue(stepTrace.nextSeq());
        entry["command"]   = JSONValue(command);
        entry["args"]      = JSONValue(args);
        entry["flags"]     = JSONValue(cast(long)flags);
        entry["selType"]   = JSONValue(selTypeToken(st));
        entry["selection"] = selection;
        entry["mesh"]      = meshJson;

        // Active tool's live params, for parametric edits (poly bevel
        // inset/shift/group/segments/square, loop slice, edge bevel width,
        // …) whose params live on the TOOL rather than the command's own
        // args — mesh.bevel_edit/mesh.loop_slice_edit (MeshSessionEdit,
        // interactive-drag commit) and the headless one-shot tool.doApply
        // path both apply while the tool stays armed.
        //
        // Ordering (confirmed by reading applyOrRefire's post-mode-finalize
        // guard above, and empirically via /api/tool/state immediately after
        // a headless tool.doApply): a Model command from the tool's OWN
        // family ("tool." prefix — tool.doApply included) is explicitly
        // EXEMPTED from the auto-drop-before-record that fires for foreign
        // Model commands, and neither ToolDoApplyCommand.apply() nor
        // Tool.applyHeadless() deactivate the tool themselves. So at this
        // point — inside history.record(), reached from onRecord — the tool
        // that just produced this step (if any) is still `activeTool`, with
        // its params untouched. toolStateJson() already returns a JSONValue
        // (see tool.d), so it nests directly with no string round-trip.
        // Omitted entirely when no tool is active, so plain subdivide/
        // delete/select steps stay noise-free.
        if (activeTool !is null) entry["tool"] = activeTool.toolStateJson();

        stepTrace.append(entry.toString());
    }

    if (startHttpServer) {
        // Only construct the ring buffer (and chain the capture closure in)
        // when HTTP is actually reachable — /api/trace is the only consumer
        // and a release/default run never starts the listener.
        stepTrace = new StepTrace();
        history.onRecord = (string line, uint flags) {
            macroRecorder.onCommandRecorded(line, flags);
            captureStepTrace(line, flags);
        };
    } else {
        history.onRecord = &macroRecorder.onCommandRecorded;
    }

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
    // Task 1521, R4: a deferred guarded action holds a Command built against
    // the primary of the moment (its `Mesh*` was bound at fire time). If the
    // primary changes while the prompt is up, DROP it — a dropped action is
    // safer than one that lands in the wrong layer. Forward hook because the
    // guard state is declared further down in main().
    void delegate() dropPendingGuardHook;

    void delegate(size_t, size_t) onActiveLayerChanged = (size_t prev, size_t next) {
        import change_bus : MeshChangeAll, noteLayerChange, LayerChange;
        import snap       : invalidateSnapGrids;
        if (dropPendingGuardHook !is null) dropPendingGuardHook();
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
        // 0b. Drop the morph ROUTING TARGET (task 1073, review B2). It is a
        //     NAME resolved per use, so carrying it across a primary change
        //     silently routes the next edit into a same-named map on the new
        //     layer — and a DUPLICATED layer carries the same map names by
        //     construction, so that is the common case rather than the exotic
        //     one. `morph_target`'s own header has claimed this since task
        //     1069; nothing implemented it. Must run BEFORE step 3's
        //     `gpu.upload`, which reads the drawn positions through the
        //     binding: clearing after it would upload the new layer morphed
        //     by the old layer's target and leave that on screen.
        {
            import morph_target : clearMorphTarget;
            clearMorphTarget();
        }
        // 1. tool-drop (same path as Esc / scene.reset's onResetTool).
        setActiveTool(null);
        // 2. explicit coalesce barrier on the history.
        history.breakCoalescing();
        // 3. GPU re-upload + pick-cache resize/invalidate against the NEW mesh.
        //    Task 0654: "the new mesh" can be NO mesh — this hook also fires on
        //    the transition INTO an empty item selection, where the primary
        //    went away rather than moved. The stand-in is empty, so uploading
        //    it clears the GPU buffers and sizes every pick cache to zero,
        //    which is what the frame after an emptying select must draw. It is
        //    a READ of the stand-in, so the no-write rule is intact.
        Mesh* active = document.activeMesh();
        if (active is null) active = &mesh();
        gpu.upload(*active);
        vertexCache.resize(active.vertices.length); vertexCache.invalidate();
        edgeCache.resize(active.edges.length);      edgeCache.invalidate();
        faceCache.resize(active.vertices.length, active.faces.length);
        faceCache.invalidate();
        // 4. blanket-invalidate the snap grids. Since task 1906 stage 2c this
        //    is the ONLY production caller of `invalidateSnapGrids()`, and it
        //    is here because a layer switch is not a mesh change: nothing was
        //    edited, so no change class describes it and no bus epoch moves.
        //    The grids' address key is the primary defense (a grid built over
        //    the prior layer's mesh mismatches on address); this blanket drop
        //    is the belt-and-braces one, and it also covers a slot table whose
        //    SOURCE ORDER changed under it. Symmetry + the subpatch preview
        //    self-invalidate on their own address terms.
        invalidateSnapGrids();
        // 5. publish a bulk change on the new active mesh. (The required cache
        //    refresh stays MeshChangeAll — the on-screen geometry is a different
        //    mesh; the scope-down rider is deliberately NOT taken here.)
        //    TASK 1906 STAGE 2 — a `noteChange` here is NOT the blind case the
        //    command tails were, and it is worth saying why rather than
        //    converting it reflexively. Two independent things already cover
        //    this hook: step 3 above uploads the new active mesh and invalidates
        //    the pick caches ITSELF, and `displayServiced_` (the bus-epoch key
        //    the display guard stamps) carries the mesh ADDRESS — which by
        //    definition just changed, so the guard mismatches and re-services
        //    even with the epoch standing still. What this line is for is the
        //    per-frame drain's subscribers, and they read `pendingChanges_`.
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
    // command through uiCommandDelegate, never mutating `document` directly.
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
    // Unsaved-changes quit confirmation (task 0434). Same pendingOpen→OpenPopup
    // convention as the AI3D / Remesh modals. quitAfterSave defers the exit
    // decision until the frame's Save has flushed (a cancelled Save dialog
    // leaves the document dirty ⇒ the quit is aborted). lastWindowTitle caches
    // the last string handed to SDL so the title is only re-set when it changes.
    // Task 1521 folded 0434's bespoke quit pair into ONE deferred-action
    // slot: the guard now covers file.new / file.open / file.import.* / quit
    // through the single `runUiCommand` point, and a second modal entry would
    // have asked twice AND kept the guard at two places.
    //   * `pendingGuardedCmd` — the action held while the prompt is up. While
    //     it is non-null a SECOND guarded dispatch is refused, not queued and
    //     not overwritten (task 1521, B9).
    //   * `guardSettle` — answered in the draw, PERFORMED in the post-flush
    //     settle, so nothing mutates the document from inside an ImGui frame.
    bool   discardConfirmOpen;
    bool   discardConfirmPending;
    string guardPromptText;
    Command    pendingGuardedCmd;
    RecordMode pendingGuardedMode;
    GuardSettle guardSettle;
    // Command-failure notice (task 0616 review B1). Same pendingOpen→OpenPopup
    // convention. `noticeText` is built by ui.command_notice.commandNoticeText,
    // which is also what decides whether there IS a notice — a command that
    // declined without a reason (a cancelled file dialog) stays silent.
    string noticeText;
    bool   noticeOpen;
    bool   noticePending;
    string lastWindowTitle;
    string ai3dPickedImagePath;
    char[256] ai3dWorkerUrlBuf;
    ai3dWorkerUrlBuf[] = 0;
    ai3dWorkerUrlBuf[0 .. ai3dDefaultWorkerUrl.length] = ai3dDefaultWorkerUrl;
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
    // Copilot deterministic handle-advisor hook (task 0402/0386). Gated off
    // under kCopilotEnabled (task 0422 — owner pausing the copilot; ONNX
    // path untouched). The `aiAdvisor` OBJECT above stays constructed
    // regardless: the model-backed decision provider below (~line 2555)
    // holds its own direct closure reference to it as its keepDefault
    // fallback, bypassing this global hook entirely. Skipping this call
    // just means handler.d's handleAiAdvisor() lazily falls back to a bare
    // `new AiAdvisor()` (permanently inert — see ai/advisor.d's own default-
    // ctor unittest), so ordinary handle picking gets zero advisor
    // influence, byte-identical to AI never having existed. Flip
    // kCopilotEnabled back to `true` to restore.
    static if (kCopilotEnabled)
    setHandleAiAdvisor(aiAdvisor);

    // AI Modeling Copilot (task 0402 Phase 2): the passive findings-list
    // panel. Owns only its own display state (Finding[] + active row) —
    // the copilot.analyze / copilot.selectFinding commands below are the
    // only writers, see copilot_panel.d's doc comment.
    // version(WithAI)-only (compiled out of modeling-noai) — see the import
    // block's doc comment near the top of this file. static if kCopilotEnabled
    // (task 0422) on top: not constructed at all while the copilot is paused.
    version (WithAI)
    static if (kCopilotEnabled)
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
    // Task 1069 — the ROUTED-gesture undo factory (MeshMorphEdit's analogue
    // of vxEditFactory). Same live context; the command writes the bound
    // morph map rather than mesh.vertices.
    import commands.mesh.morph_edit : MeshMorphEdit;
    auto morphEditFactory = () => new MeshMorphEdit(&mesh(), cameraView, editMode);
    // Task 0614 Phase 4 — the item-transform gizmo-drag undo factory
    // (LayerXformEdit's analogue of vxEditFactory above). `mesh`/`cameraView`/
    // `editMode` are unused by LayerXformEdit's own apply()/revert() (it
    // writes Layer.xform, not mesh.vertices) but the base Command ctor still
    // requires them, so the same live context is passed through for
    // consistency with every other *EditFactory closure here.
    import commands.layer.xform_edit : LayerXformEdit;
    auto layerXformEditFactory = () => new LayerXformEdit(&mesh(), cameraView, editMode);
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
    // Topology Pen P3's drag-build gesture (task 0477, doc/topopen_p3_plan.md):
    // its own typed edit factory, distinct wire name so undo history / replay
    // dispatch describes the op rather than reusing bevelEditFactory's
    // "mesh.bevel_edit" the way most of the tools above do.
    auto topoPenBuildEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.topoPen_build", "Topology Build", sessionGeomMarks);
    // Topology Pen P4's Move gesture (task 0477, doc/topopen_p4_plan.md,
    // OBJ-3 FOLDED): its OWN typed edit factory, distinct from
    // `topoPenBuildEditFactory` — a grab-and-re-snap move never adds/removes
    // geometry, so its wire name is "mesh.topoPen_move" and its editScope is
    // Position-only, not Geometry|Marks.
    auto topoPenMoveEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.topoPen_move", "Topology Move", MeshEditScope.Position);
    // Topology Pen P5's Remove gesture (task 0477, doc/topopen_p5_remove_plan.md,
    // opponent KILLER-1): its OWN typed edit factory, distinct from BOTH
    // `topoPenBuildEditFactory` and `topoPenMoveEditFactory` — a single-face
    // delete IS a topology change (wire name "mesh.topoPen_remove", editScope
    // Geometry), so reusing either sibling factory would corrupt undo
    // history / event-log replay / macros with the wrong wire name.
    auto topoPenRemoveEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.topoPen_remove", "Topology Remove", MeshEditScope.Geometry);
    // Topology Pen P6's Add Loop gesture (task 0477, doc/topopen_p6_addloop_plan.md,
    // REV1 factory precedent): its OWN typed edit factory, distinct from
    // `topoPenBuildEditFactory`/`topoPenMoveEditFactory`/`topoPenRemoveEditFactory`
    // — a loop cut IS a topology change (wire name "mesh.topoPen_addloop",
    // editScope Geometry|Marks — the cut resizes selection arrays, same
    // scope as `topoPenBuildEditFactory`), so reusing any sibling factory
    // would corrupt undo history / event-log replay / macros with the
    // wrong wire name.
    auto topoPenAddLoopEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.topoPen_addloop", "Topology Add Loop", sessionGeomMarks);
    // Topology Pen P7's Slide gesture (task 0477, doc/topopen_p7_slide_plan.md,
    // REV1): its OWN typed edit factory, distinct from EVERY sibling above —
    // a constrained-edge slide never adds/removes geometry (Position-only
    // editScope, same as `topoPenMoveEditFactory`), but reusing that factory
    // would bake the wrong wire name ("mesh.topoPen_move" on a slide),
    // corrupting undo history / event-log replay / macros.
    auto topoPenSlideEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.topoPen_slide", "Topology Slide", MeshEditScope.Position);
    // Topology Pen P8's Smooth gesture (task 0477, doc/topopen_p8_smooth_plan.md):
    // its OWN typed edit factory, distinct from EVERY sibling above — a
    // relax+re-snap pass never adds/removes geometry (Position-only
    // editScope, same as `topoPenMoveEditFactory`/`topoPenSlideEditFactory`),
    // but reusing either would bake the wrong wire name ("mesh.topoPen_move"/
    // "mesh.topoPen_slide" on a multi-pass smooth), corrupting undo history /
    // event-log replay / macros.
    auto topoPenSmoothEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.topoPen_smooth", "Topology Smooth", MeshEditScope.Position);
    // Topology Pen P9's Split gesture (task 0477, doc/topopen_p9_split_plan.md):
    // its OWN typed edit factory, distinct from EVERY sibling above — a
    // vertex-to-vertex polygon split IS a topology change (wire name
    // "mesh.topoPen_split", editScope Geometry, same scope as
    // `topoPenRemoveEditFactory`), so reusing any sibling factory would
    // corrupt undo history / event-log replay / macros with the wrong wire
    // name.
    auto topoPenSplitEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.topoPen_split", "Topology Split", MeshEditScope.Geometry);
    // Topology Pen P10's Move Loop gesture (task 0477, doc/topopen_p10_moveloop_plan.md):
    // its OWN typed edit factory, distinct from EVERY sibling above — a
    // per-vertex loop re-snap never adds/removes geometry (wire name
    // "mesh.topoPen_moveloop", editScope Position-only, same scope as
    // `topoPenMoveEditFactory`/`topoPenSlideEditFactory`/
    // `topoPenSmoothEditFactory`), but reusing any of them would bake the
    // wrong wire name on a loop drag, corrupting undo history / event-log
    // replay / macros.
    auto topoPenMoveLoopEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.topoPen_moveloop", "Topology Move Loop", MeshEditScope.Position);
    // Topology Pen P11's Dup Loop gesture (task 0477, doc/topopen_p11_duploop_plan.md):
    // its OWN typed edit factory, distinct from EVERY sibling above —
    // duplicating an edge loop into a new bridge ring IS a topology change
    // (wire name "mesh.topoPen_duploop", editScope Geometry|Marks — the
    // extrude resizes selection arrays, same scope as
    // `topoPenAddLoopEditFactory`), so reusing any sibling factory would
    // corrupt undo history / event-log replay / macros with the wrong wire
    // name.
    auto topoPenDupLoopEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.topoPen_duploop", "Topology Duplicate Loop", sessionGeomMarks);
    // Topology Pen P12's Smooth+Loop gesture (task 0477, doc/topopen_p12_smoothloop_plan.md):
    // its OWN typed edit factory, distinct from EVERY sibling above — a 1-D
    // loop-restricted relax+re-snap never adds/removes geometry (wire name
    // "mesh.topoPen_smoothloop", editScope Position-only, same scope as
    // `topoPenMoveLoopEditFactory`/`topoPenMoveEditFactory`/
    // `topoPenSlideEditFactory`/`topoPenSmoothEditFactory`), but reusing any
    // of them would bake the wrong wire name on a loop smooth, corrupting
    // undo history / event-log replay / macros.
    auto topoPenSmoothLoopEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.topoPen_smoothloop", "Topology Smooth Loop", MeshEditScope.Position);
    // Topology Pen Fill mode V1 (task 0477 continuation, doc/topopen_fill_plan.md):
    // its OWN typed edit factory, distinct from EVERY sibling above —
    // capping a gap cell with one quad IS a topology change (wire name
    // "mesh.topoPen_fill", editScope Geometry, same scope as
    // `topoPenSplitEditFactory`), so reusing any sibling factory would
    // corrupt undo history / event-log replay / macros with the wrong wire
    // name.
    auto topoPenFillEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.topoPen_fill", "Topology Fill", MeshEditScope.Geometry);
    // Topology Pen Remove's OTHER two primitives (task 0494): Remove picks its
    // mesh operation from the CLASS of the element the press latched, and an
    // edge-latched press dissolves (merging the two incident polygons) while a
    // vertex-latched press merges the whole incident fan and drops the vertex —
    // neither of which removes a face. Same Geometry editScope as
    // `topoPenRemoveEditFactory`, so the wire name is the ONLY thing keeping
    // the three apart in undo history / event-log replay / macros; that is
    // exactly why each gets its own.
    auto topoPenRemoveEdgeEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.topoPen_removeedge", "Topology Remove Edge", MeshEditScope.Geometry);
    auto topoPenRemoveVertexEditFactory = () => new MeshSessionEdit(&mesh(), cameraView, editMode,
                                                     "mesh.topoPen_removevertex", "Topology Remove Vertex", MeshEditScope.Geometry);

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
        // Blocker 2 (0614 review): a live `SelType delegate()`, queried fresh
        // on every call (not cached — see each stage's own doc comment),
        // for external/non-evaluate() readers of the item-mode redirect
        // (currentCenter()/currentBasis() → listAttrs(), falloff_handles.d,
        // mid-drag reads from transform.d/xfrm_transform.d). The SAME
        // authority buildToolVts uses below for the per-frame SubjectPacket.
        // Task 0612 Stage 8 (§7.1): the gizmo centre and the item basis bind
        // the ITEM TRANSFORM TARGET, not `document.primary`. On an all-mesh
        // document the two are the same object (proof on
        // `Document.itemTransformTarget`), so every measured L2 centre is
        // preserved bit-for-bit; they differ only once a mesh-less item holds
        // the focus, which is the state that did not exist when L2 was
        // measured. The SET (`registration.d`'s `itemTransformTargets`) reads
        // the same funnel — narrowing one without the other would centre the
        // gizmo on a layer it refuses to move (§7.2 consequence 1).
        g_pipeCtx.pipeline.add(new ActionCenterStage(() => &mesh(), &editMode,
                                                       () => document.itemTransformTarget(),
                                                       () => currentSelType(selTypeOrder)));
        g_pipeCtx.pipeline.add(new AxisStage(() => &mesh(), &editMode,
                                              () => document.itemTransformTarget(),
                                              () => currentSelType(selTypeOrder)));
        g_pipeCtx.pipeline.add(new FalloffStage(() => &mesh(), &editMode));
        import toolpipe.stages.path : PathStage;
        g_pipeCtx.pipeline.add(new PathStage(() => &mesh()));
    }

    // Main-loop flag — declared up here so command factories
    // (file.quit in particular) can capture it before the actual
    // loop runs below.
    bool running = true;
    // Task 1521: the 0434 `quitRequested` latch is GONE. `SDL_QUIT` now builds
    // a `file.quit` command (with `fromWindowClose`) and runs it through
    // `runUiCommand`, so the window [X] and Ctrl+Q are literally one path —
    // which is what makes "remove the guard call from runUiCommand" redden all
    // three guarded routes instead of two.

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
    // Blocker 1 (0614 review): wired HERE, not at the later "Phase-B ctx
    // wiring" block (~selTypeOrderPtr's other assignment, further down) —
    // this earlier block is copied BY VALUE into registerTools(app) below,
    // so a tool factory built there (XfrmTransformTool's `() =>
    // currentSelType(selTypeOrder)`) needs the pointer live before that
    // copy is taken, or it captures a null. The later assignment stays;
    // re-assigning the same address twice is harmless (idempotent) and
    // serves wireHttpProviders' separate `ref EditorApp app`.
    app.selTypeOrderPtr = &selTypeOrder;

    app.subpatchPreviewPtr  = &subpatchPreview;
    app.gpuUploadedPreviewPtr = &gpuUploadedPreview;
    app.activeToolPtr       = &activeTool;
    // A5: wire the guard's tool-owns-VBO predicate now that `activeTool`
    // is lexically visible (the guard itself is declared far earlier).
    displayVboOwnedByTool_  = () => activeTool !is null && activeTool.isDragging();
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

    // Phase-B panel wiring (source/ui/panels.d main-loop panels --
    // drawAi3dModal/drawRemeshModal/drawQuitGuardModal/
    // drawCommandHistoryPanel). All pointer-backed locals are declared
    // above (~2710-2823); ai3dWorkerManager is assigned exactly once
    // (~1179). navHistory is a nested function declared far below
    // (~4051), wired separately right after its declaration.
    app.ai3dWorkerStartingPtr         = &ai3dWorkerStarting;
    app.ai3dWorkerStartDeadlinePtr    = &ai3dWorkerStartDeadline;
    app.ai3dWorkerNextHealthProbePtr  = &ai3dWorkerNextHealthProbe;
    app.ai3dInstallConfirmOpenPtr        = &ai3dInstallConfirmOpen;
    app.ai3dInstallConfirmPendingOpenPtr = &ai3dInstallConfirmPendingOpen;
    app.ai3dMaxFacesPtr               = &ai3dMaxFaces;
    app.ai3dWorkerManager             = ai3dWorkerManager;
    app.remeshModalPendingClosePtr    = &remeshModalPendingClose;
    app.remeshTargetQuadsPtr          = &remeshTargetQuads;
    app.remeshAdaptivityPtr           = &remeshAdaptivity;
    app.remeshSharpEdgePtr            = &remeshSharpEdge;
    app.discardConfirmOpenPtr         = &discardConfirmOpen;
    app.discardConfirmPendingPtr      = &discardConfirmPending;
    app.guardPromptTextPtr            = &guardPromptText;
    app.noticeTextPtr                 = &noticeText;
    app.noticeOpenPtr                 = &noticeOpen;
    app.noticePendingPtr              = &noticePending;
    app.historyFilterPtr              = &historyFilter;
    app.historyShowArgsPtr            = &historyShowArgs;
    app.historyShowRowNumbersPtr      = &historyShowRowNumbers;
    app.historyShowTimestampsPtr      = &historyShowTimestamps;
    app.historyShowCommandIdsPtr      = &historyShowCommandIds;
    app.historyReplLastWasErrorPtr    = &historyReplLastWasError;
    app.historyReplInputPtr           = &historyReplInput;

    app.history         = history;
    app.vpm             = vpm;
    app.litShader       = litShader;
    app.pipeGizmoHost   = pipeGizmoHost;
    app.macroRecorder   = macroRecorder;
    app.ai3dController  = ai3dController;
    app.remeshJob       = remeshJob;
    app.aiState         = aiState;
    version (WithAI) static if (kCopilotEnabled) app.copilotPanel = copilotPanel;
    app.aiExplore       = aiExplore;
    app.aiLogWriter     = aiLogWriter;

    app.vxEditFactory            = vxEditFactory;
    app.morphEditFactory         = morphEditFactory;
    app.layerXformEditFactory    = layerXformEditFactory;
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
    app.topoPenBuildEditFactory  = topoPenBuildEditFactory;
    app.topoPenMoveEditFactory   = topoPenMoveEditFactory;
    app.topoPenRemoveEditFactory = topoPenRemoveEditFactory;
    app.topoPenAddLoopEditFactory = topoPenAddLoopEditFactory;
    app.topoPenSlideEditFactory   = topoPenSlideEditFactory;
    app.topoPenSmoothEditFactory  = topoPenSmoothEditFactory;
    app.topoPenSplitEditFactory   = topoPenSplitEditFactory;
    app.topoPenMoveLoopEditFactory = topoPenMoveLoopEditFactory;
    app.topoPenDupLoopEditFactory  = topoPenDupLoopEditFactory;
    app.topoPenSmoothLoopEditFactory = topoPenSmoothLoopEditFactory;
    app.topoPenFillEditFactory       = topoPenFillEditFactory;
    app.topoPenRemoveEdgeEditFactory   = topoPenRemoveEdgeEditFactory;
    app.topoPenRemoveVertexEditFactory = topoPenRemoveVertexEditFactory;

    app.setActiveTool        = cast(void delegate(Tool))&setActiveTool;
    app.promoteItemType      = cast(void delegate())&promoteItemType;
    app.switchItemType       = cast(void delegate())&switchItemType;
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
    // EditSession wiring (task 0428): construct the session-protocol driver
    // now that history + setActiveTool + toolHost are all in scope (the
    // variable itself is declared next to setActiveTool above so the nested
    // function can see it). Commands reach the session through the ToolHost
    // bridge — the same delegate pattern as getActiveTool — assigned BEFORE
    // toolHostPtr / registerCommands below so every ToolHost copy taken later
    // carries the accessor.
    session = new EditSession(
        () => activeTool,
        history,
        () { setActiveTool(null); activeToolId = ""; });
    toolHost.session = () => session;
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
        import layer_params : layerAttrUniverse;
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
        // The layer (item) namespace's universe is the UNION over every item
        // kind, because ONE form serves them all: its per-kind section binds
        // channels only a plane's provider returns, and those rows are hidden
        // — not erroneous — for a mesh. Without this delegate a misspelt
        // channel is invisible rather than loud: it resolves absent on every
        // snapshot, so the row is simply never drawn and looks identical to a
        // channel nobody wrote a row for.
        fv.layerAttrs = () => layerAttrUniverse();

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
    // Pie menus (task 1800). Same button schema, third surface — so they join
    // the id-validation pass below rather than getting a check of their own.
    {
        import buttonset : loadPies;
        import pie_menus : setPieMenus;
        setPieMenus(loadPies("config/pies.yaml"));
    }
    // The AI master-switch (ai.toggle/enable/disable) status-line buttons are
    // live only when those commands are actually registered — i.e. a WithAI
    // build (ONNX ranker compiled in) AND the copilot enabled (kCopilotEnabled,
    // task 0422). In any other state the factories are absent, so render the
    // buttons as disabled placeholders (engraved, non-clickable). Done BEFORE
    // the id-validation pass below, which skips disabled buttons — so `ai.toggle`
    // need not be a resolvable command in those states (modeling-noai, or
    // copilot-off in a WithAI build).
    bool aiSwitchLive = false;
    version (WithAI) { static if (kCopilotEnabled) aiSwitchLive = true; }
    if (!aiSwitchLive) {
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
    // Freeze the resolved input map for `/api/input/context` (task 1810). The
    // table never changes after load, and `resolveBinding` is pure, so the
    // HTTP thread can answer "which binding would win" without touching
    // anything live — and without a second implementation that could drift
    // from the one the keyboard actually runs.
    {
        import input_context : setBindingSnapshot;
        setBindingSnapshot(shortcuts.bindings);
    }

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
        {
            import pie_menus : pieMenus;
            foreach (ref pm; pieMenus())
                foreach (ref btn; pm.items)
                    checkButton(btn);
        }
        if (missing.data.length > 0)
            throw new Exception("buttons.yaml/statusline.yaml/pies.yaml references unknown ids:"
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
        } else if (reg.actionRefusal("tool", id, document.hasEditTarget(),
                                     activeToolId).length > 0) {
            // TASK 0654 — the interactive half of `tool.set`'s refusal (see
            // `commands/tool/set.d` for the reasoning). Every tool factory
            // below binds `Mesh*` off the edit target, and with an empty item
            // selection there is none. Dropping a tool stays possible (the
            // same-id arm above ran first); only ARMING one refuses.
            //
            // TASK 0669 — the condition is `Registry.actionRefusal`, which is
            // the SAME call the button-draw makes to decide whether to grey
            // the row. That is the whole point: the grey and the refusal are
            // one computation, so they cannot drift into disagreement, and a
            // tool that some day declares `needsEditTarget() == false` becomes
            // both armable and un-greyed in one edit.
            logWarn("tool", "'" ~ id ~ "' not armed: "
                    ~ reg.actionRefusal("tool", id, document.hasEditTarget(),
                                        activeToolId));
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
        // rather than committing it (EditSession.discardOpenEdit — touches no
        // history; cancel bodies are pure mesh restores). With `dirty`
        // cleared, the rebuild's deactivate()->commitNow() below is a no-op
        // even if suspend alone didn't also gate record().
        session.discardOpenEdit();
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
    // uiCommandDelegate.
    void delegate(string, string) uiCommandDelegate;
    void delegate(size_t) replayUndoEntry;
    // FormsPanel write path: dispatches a `tool.attr` exactly like
    // uiCommandDelegate but marks the built ToolAttrCommand `interactive`
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
    // ---------------------------------------------------------------------
    // HTTP endpoint wiring (all /api providers + handlers, ~2410 lines) --
    // moved VERBATIM to source/http_providers.d's wireHttpProviders (app.d
    // decomp, phase B; same `with (app)` seam as 0415's registration.d and
    // 0419's ui/panels.d). The CALL sits right after the task-0419 LATE
    // ctx-wiring below, so every EditorApp field the moved block reads is
    // already wired when the closures are built.
    // ---------------------------------------------------------------------

    // Task 0781 step 2c: `lastMouseX`/`lastMouseY` relocated to InputRouter
    // alongside handleMouseMotion (the drag deltas' origin). Their same-name
    // forwarders died in step 2d with the press handler, their last
    // main()-side reader.

    // ---- Trackball momentum spin (task 0582) -------------------------------
    // Task 0781 step 2d: `tbSpinCam` relocated to InputRouter alongside the
    // press/release handlers that were its only two readers, and its full note
    // (why the release cannot re-derive the camera) travelled with it. No
    // forwarder: nothing in main() names it any more.
    // Is ANY camera momentum spin? The per-frame tick's whole guard: false for
    // every frame of every session that never uses the gesture, so the cost of
    // this feature to everyone else is one bool test per frame — no clock read,
    // no walk over the cells. It is self-correcting rather than a counter that
    // must be kept balanced: the sweep below recomputes it from the cameras it
    // just ticked, so the worst a stale `true` can cost is one extra sweep.
    //
    // Task 1040: state relocated to InputFrameState.anySpinning, behind a
    // same-name forwarder that kept its ~6 bare read/write sites untouched.
    // The button-up handler that ORs a fresh spin in left main() in task
    // 0781 step 2b, and STEP 3 DELETED THE FORWARDER: the frame body's
    // tick -- the `if`, the clear and the recompute -- reads
    // `ifs.anySpinning`.

    // The cooked 2D event, and the bookkeeping behind it. Task 0781 step 2c:
    // `gestureTrack` relocated to InputRouter alongside handleMouseMotion,
    // and its full note (why the per-handler placement is load-bearing, and
    // that nothing reads the packet yet) travelled with it. Its same-name
    // forwarder — and the `static assert` that kept the forwarder `ref`, so
    // `.event()` could not advance a temporary copy — died in step 2d with the
    // press/release handlers, its last two main()-side sites.
    //
    // `gestureSlot` itself (task 1040: the storage buildToolVts publishes
    // from — it must live out here rather than as a local inside
    // buildToolVts because VectorStack stores POINTERS and the stack it
    // fills outlives the call) moved into InputFrameState alongside
    // buildToolVts's own body; see that struct's doc comment.

    // `running` is declared higher up so the file.quit factory
    // closure (registered earlier) can capture it.
    SDL_Event event;

    // -------------------------------------------------------------------------
    // Nested helpers — closures over main's locals
    // -------------------------------------------------------------------------

    // Task 0781: handleWindowEvent moved to InputRouter (source/input_router.d),
    // constructed as `router` below after EditorApp's own LATE ctx-wiring
    // finishes (it needs app.layout, wired there). processEvent's
    // SDL_WINDOWEVENT case now calls router.handleWindowEvent.

    // ---- The command-failure notice ------------------------------------
    //
    // `Command.refusalReason()` is "" for every command that does not override
    // it and is reset at the top of every overrider's apply(), so a non-empty
    // value here means exactly "the call I just made declined, and here is the
    // sentence to show". A decline WITHOUT a reason is still silent, which is
    // what keeps a cancelled file dialog quiet — see ui/command_notice.d.
    //
    // Task 1520 moved this out of `runCommand` so the panel/HTTP-UI adapter
    // raises the SAME notice from the SAME body; before that, the menu path
    // showed a notice while the panel path threw out of the ImGui draw.
    void raiseNotice(string text) {
        import ui.discard_guard : recordUiNotice;
        if (text.length == 0) return;
        // ALWAYS recorded, so a headless test can read what the user would
        // have been shown (`GET /api/ui/policy`).
        recordUiNotice(text);
        // The MODAL is suppressed under --test (task 1520, R3). Before this
        // change no UI-origin refusal could reach a `--test` run at all, so
        // leaving the popup live cost nothing; now `?origin=ui` drives exactly
        // that path, and an unanswerable modal would wedge the harness.
        if (command.g_testMode) return;
        noticeText    = text;
        noticeOpen    = true;
        noticePending = true;
    }

    void raiseCommandNotice(Command cmd) {
        import ui.command_notice : commandNoticeText;
        if (cmd is null) return;
        raiseNotice(commandNoticeText(cmd.label(), cmd.refusalReason()));
    }

    // The guard-free half: apply + record, refusal is silent here (the caller
    // owns the notice). `throwMsg` is null — a user gesture has no caller to
    // throw at, and a throw from inside an ImGui draw kills the process.
    bool runUiCommandForced(Command cmd, RecordMode mode) {
        if (cmd is null) return false;
        return applyOrRefire(cmd, mode, null);
    }

    // ---- THE single user-command entry point (tasks 1520 + 1521) ---------
    //
    // Every user-driven command line lands here: the menu / keyboard
    // (`runCommand`), every panel button and status-line script action (the
    // UI dispatch adapter in http_providers.d), and — since task 1521 — the
    // window close. Three inputs, ONE guard, which is the whole point: with
    // the quit guard left at its own modal entry, the mutation "remove the
    // guard call from here" reddened two of the three paths instead of three.
    //
    // `dispatchedId` is the id the CALLER asked for and is NOT derivable from
    // the command: `file.new`'s factory builds a `SceneReset` whose `name()`
    // is `"scene.reset"`, the same string `/api/reset` uses. `runCommand`
    // has no id to give and passes "", and the record shows that honestly.
    UiRunOutcome runUiCommand(Command cmd, RecordMode mode, string dispatchedId = "") {
        import io.doc_state    : docDirty;
        import ui.discard_guard;
        if (cmd is null) return UiRunOutcome.refused;

        const discards = cmd.discardsUnsavedWork();
        const dirty    = docDirty();
        const verdict  = guardVerdict(discards, dirty);

        GuardRecord rec;
        rec.id       = dispatchedId;
        rec.name     = cmd.name();
        rec.discards = discards;
        rec.dirty    = dirty;
        rec.verdict  = verdict == GuardVerdict.prompt ? "prompt" : "proceed";
        rec.answer   = "none";

        if (verdict == GuardVerdict.prompt) {
            // BUSY RULE (task 1521, opponent blocker B9). ImGui modals do not
            // raise `WantTextInput`, and `WantCaptureKeyboard` is explicitly
            // unusable as a gate in this app (see the keyboard router), so a
            // Ctrl+N pressed while the prompt is up DOES reach here. Silently
            // overwriting the held action would throw away a decision the user
            // is in the middle of making, so the second one is refused and the
            // modal stays on the first.
            if (pendingGuardedCmd !is null) {
                rec.suppressed = command.g_testMode;
                rec.dropped    = "guard already pending";
                rec.outcome    = "deferred";
                recordGuardRequest(rec);
                return UiRunOutcome.deferred;
            }
            rec.suppressed = command.g_testMode;
            rec.outcome    = "deferred";
            recordGuardRequest(rec);
            // WHAT `--test` SUPPRESSES IS THE MODAL, NOT THE DEFERRAL. The
            // action is held either way — "asked, not yet answered" is the
            // honest state and it is what makes the busy rule observable
            // headlessly. `/api/reset` drops the held action so one case
            // cannot leak into the next on the shared --test instance.
            pendingGuardedCmd  = cmd;
            pendingGuardedMode = mode;
            guardPromptText    =
                "You have unsaved changes.\n\nSave them before "
                ~ (cmd.label().length ? cmd.label() : cmd.name()) ~ "?";
            setGuardPending(true);
            if (!command.g_testMode) {
                discardConfirmOpen    = true;
                discardConfirmPending = true;
            }
            return UiRunOutcome.deferred;
        }

        const applied = runUiCommandForced(cmd, mode);
        rec.outcome = applied ? "applied" : "refused";
        rec.refused = !applied;
        recordGuardRequest(rec);
        if (!applied) raiseCommandNotice(cmd);
        return applied ? UiRunOutcome.applied : UiRunOutcome.refused;
    }

    // The menu / keyboard / UI-button entry. Unchanged shape for its 8
    // callers; the body is now the single guarded point above.
    void runCommand(Command cmd) {
        runUiCommand(cmd, RecordMode.Record, "");
    }

    // ---- The three answers to the unsaved-work prompt (task 1521) --------
    // Each ARMS the settle; none performs the action. Doing it here would run
    // a document replacement from inside the ImGui frame that is drawing the
    // modal — the shape task 0434 already avoided for the quit, kept.
    void guardAnswerSave() {
        import ui.discard_guard : recordGuardAnswer, GuardAnswer;
        // The ordinary `file.save` — which prompts when the document is
        // untitled, and whose CANCELLATION leaves the document dirty. That is
        // exactly why the perform is conditional at settle: a cancelled Save
        // must abort the discard, not complete it.
        runUiCommandForced(reg.commandFactories["file.save"](), RecordMode.Record);
        guardSettle           = GuardSettle.afterSave;
        discardConfirmOpen    = false;
        recordGuardAnswer(GuardAnswer.save, false);
    }
    void guardAnswerDiscard() {
        import ui.discard_guard : recordGuardAnswer, GuardAnswer;
        guardSettle        = GuardSettle.perform;
        discardConfirmOpen = false;
        recordGuardAnswer(GuardAnswer.discard, false);
    }
    // Forget the held action without performing it. Used by Cancel, by
    // `/api/reset` (so one test's deferred action cannot leak into the next on
    // the shared --test instance) and by a primary change (R4).
    void dropPendingGuard() {
        import ui.discard_guard : setGuardPending;
        pendingGuardedCmd     = null;
        guardSettle           = GuardSettle.none;
        discardConfirmOpen    = false;
        discardConfirmPending = false;
        setGuardPending(false);
    }
    void guardAnswerCancel() {
        import ui.discard_guard : recordGuardAnswer, GuardAnswer;
        // CANCEL CANCELS. The held action is dropped, never queued.
        dropPendingGuard();
        recordGuardAnswer(GuardAnswer.cancel, false);
    }

    // Post-flush settle for the deferred action. Called once per frame from
    // the same block that pushes the document revision, so `docDirty()` here
    // already counts this frame's Save.
    void settleGuardedAction() {
        import ui.discard_guard : GuardSettle, recordGuardAnswer, GuardAnswer,
                                  setGuardPending, settlePerforms;
        import io.doc_state : docDirty;
        if (guardSettle == GuardSettle.none) return;
        auto cmd  = pendingGuardedCmd;
        auto mode = pendingGuardedMode;
        const settle       = guardSettle;
        const wasAfterSave = (settle == GuardSettle.afterSave);
        pendingGuardedCmd = null;
        guardSettle       = GuardSettle.none;
        setGuardPending(false);
        if (cmd is null) return;
        // A Save that did not land (cancelled dialog, unwritable path) leaves
        // the document dirty ⇒ DROP the action. The rule itself is the pure
        // `settlePerforms` so it can be asserted without an app.
        if (!settlePerforms(settle, docDirty())) return;
        const ok = runUiCommandForced(cmd, mode);
        recordGuardAnswer(wasAfterSave ? GuardAnswer.save : GuardAnswer.discard, ok);
        if (!ok) raiseCommandNotice(cmd);
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

    // Task 0781 step 2d: `runCommandWithArgs` moved to InputRouter
    // (source/input_router.d) as a real METHOD, replacing the delegate field
    // step 2a parked it behind. Plan §4/Q2's deciding grep still held at the
    // move -- the declaration plus exactly three calls, `handleKeyDown` (router
    // -side since 2a) and `doItemSelectPickAt` twice -- so the plan's "move it"
    // branch applies rather than its keep-a-delegate fallback. The body is
    // verbatim; only `reg` and `runCommand` gained their `app.` prefix, since
    // the moved method is not inside a `with (app)` block.

    // Phase 7 of doc/operator_refactor_plan.md. Build a fresh
    // VectorStack for the current frame's tool dispatch — the engine
    // pre-evaluates `vts` once per input event and passes it down to
    // the tool's mouse/key handlers.
    // Stamps the SubjectPacket with mesh + selection + viewport, walks
    // the live toolpipe, and returns the populated stack. Callers
    // hold both the subject and the vts on their own stack so the
    // packet pointer stays valid for the duration of the dispatch.
    //
    // `curX`/`curY`/`curValid` (topology-pen P0, REV-1 of
    // doc/topopen_p0_plan.md): the CURRENT mouse-event's cursor pixel,
    // stamped onto `subj.cursorX/Y/cursorValid` for the CONS stage's
    // background-surface raycast branch. ONLY the mouse-EVENT dispatch
    // call sites (inside handleMouseButtonDown/Up and handleMouseMotion,
    // passing that event's own `btn.x/y`/`mot.x/y`) pass `curValid=true` —
    // NOT `lastMouseX/Y` (those are updated at the BOTTOM of those
    // handlers, AFTER buildToolVts runs, so they would read one event
    // stale). EVERY OTHER caller — the per-frame render-loop's
    // `activeTool.update(vts)` / overlay-packet calls, and any
    // HTTP-thread subject builder — leaves `curValid` at its default
    // `false`, so the raycast branch runs only once per real input
    // event, on the main thread, never off it and never every frame.
    //
    // `gest`: the cooked 2D event for THIS dispatch, on exactly the same
    // terms as the cursor params above — the mouse-event call sites hand in
    // the packet their handler cooked once at the top (GestureTrack.event),
    // and every other caller takes the default `GesturePacket.init`, whose
    // `valid` is false. So the seven mouse-event sites publish a valid
    // gesture and nobody else does, mirroring `curValid` one for one. It is
    // published into the stack BEFORE pipeline.evaluate so a stage could
    // read it; none does, and that is the neutrality argument for the
    // commit that introduced it.
    // Body relocated to InputFrameState.buildToolVts (task 1040), full six-
    // parameter form preserved exactly (same defaults), behind a same-name
    // forwarder that kept all ~25 call sites -- the bare 2-arg and the
    // 4-trailing-arg forms alike -- untouched. The mouse and key handlers
    // that used the 6-arg form left main() in task 0781 step 2, and STEP 3
    // DELETED THE FORWARDER: every remaining site here spells
    // `ifs.buildToolVts(...)`.
    //
    // WHICH `buildToolVts` IS WHICH, because there are two and they are not
    // the same thing. `ifs.buildToolVts` is the real SIX-parameter method on
    // the cluster. `EditorApp.buildToolVts` is a TWO-parameter DELEGATE
    // FIELD, bound below by a genuine 2-parameter closure whose body now
    // calls `ifs.buildToolVts(s, v)`. That closure is not ceremony: binding
    // the 6-arg function to the 2-arg field directly compiles but is an ABI
    // lie -- the trailing three parameters read stack garbage, a
    // reproducible segfault (see the note at the binding site). The field
    // stays 2-arg; do not "simplify" it to match the method.

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
    // Task 0781 step 1b: these three now point INTO the input/frame cluster
    // (their storage moved there), not at main() locals -- `&ifs.hoveredX`,
    // not `&hoveredX`, because after the move `hoveredX` is a `@property`
    // and `&`-ing it would take the address of the FORWARDER FUNCTION (the
    // R3 rule the `fbW`/`fbH` wiring below already carries). `EditorApp`
    // itself is unchanged: same three pointer fields, same three
    // properties, new target. `ifs` is a `final class`, so this address is
    // stable for the whole run.
    //
    // Placement is the ordinary one -- with the rest of the pointer wiring,
    // above `wireHttpProviders` -- and NOT a hard ordering requirement, which
    // is what an earlier revision of this comment claimed. It said
    // `wireHttpProviders` "captures `app` by value"; it does not, it takes
    // `ref EditorApp app` (http_providers.d), and a D closure over a `ref`
    // parameter reaches the CALLER's variable, so a provider closure sees a
    // field assigned after the call too (standalone probe, task 0781 step 1c;
    // the sync-back below is the same fact from the other direction -- the
    // moved block ASSIGNS main()'s `app` through that `ref`). The wiring that
    // genuinely must come first is `registerTools(app)`'s, a few blocks above,
    // which copies `app` BY VALUE.
    app.hoveredVertexPtr       = &ifs.hoveredVertex;
    app.hoveredEdgePtr         = &ifs.hoveredEdge;
    app.hoveredFacePtr         = &ifs.hoveredFace;
    app.activePanelIdxPtr      = &activePanelIdx;
    app.activeToolIdPtr        = &activeToolId;
    app.layerRenameIndexPtr    = &layerRenameIndex;
    app.layerRenameBufPtr      = &layerRenameBuf;
    app.faceSelEdgesCachePtr   = &faceSelEdgesCache;
    app.faceSelEdgesPrevSelPtr = &faceSelEdgesPrevSel;
    app.faceSelEdgesKeyPtr     = &faceSelEdgesKey;
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
    app.propertyPanel             = propertyPanel;   // task 0722 (A2)
    app.io                        = io;
    // app.uiCommandDelegate / app.formsInteractiveDispatch are NOT
    // wired here anymore (their pre-move `= uiCommandDelegate;` lines
    // copied a still-null local): the moved HTTP block ASSIGNS both through
    // wireHttpProviders's `ref EditorApp app` parameter, and the call site
    // below syncs main()'s same-named locals back from `app`.

    app.runCommand           = cast(void delegate(Command))&runCommand;
    // Task 1520/1521 — the single guarded UI entry + the shared notice raiser.
    // Real closures, not same-arity casts: `runUiCommand` has a defaulted
    // third parameter and a cast would reinterpret the ABI (see buildToolVts
    // below for the crash that shape produced once already).
    app.runUiCommand = (Command c, RecordMode m, string id) => runUiCommand(c, m, id);
    app.raiseCommandNotice = cast(void delegate(Command))&raiseCommandNotice;
    app.raiseNotice        = cast(void delegate(string))&raiseNotice;
    app.guardAnswerSave    = cast(void delegate())&guardAnswerSave;
    app.guardAnswerDiscard = cast(void delegate())&guardAnswerDiscard;
    app.guardAnswerCancel  = cast(void delegate())&guardAnswerCancel;
    app.dropPendingGuard   = cast(void delegate())&dropPendingGuard;
    dropPendingGuardHook   = cast(void delegate())&dropPendingGuard;
    app.tryOpenArgsDialog    = cast(bool delegate(string))&tryOpenArgsDialog;
    app.activateToolById     = cast(void delegate(string))&activateToolById;
    // NOT a bare same-arity cast like its neighbours above: buildToolVts
    // grew 3 trailing-default cursor params (topology-pen P0, REV-1) and
    // later a 4th for the cooked 2D event, but EditorApp.buildToolVts's
    // field type (editor_app.d) is still the
    // original 2-parameter delegate — every existing caller through that
    // field (ui/viewport_render.d's renderViewportSceneToFbo, a per-frame render-
    // loop call) is exactly a "leave cursorValid=false" site anyway. A raw
    // `cast(void delegate(out SubjectPacket, ref VectorStack))&buildToolVts`
    // would silently reinterpret the pointer as a 2-arg ABI while the
    // compiled callee still reads all 6 argument slots — the caller's 2 real
    // arguments land correctly but curX/curY/curValid read whatever
    // garbage was in the unpassed slots (a real, reproducible crash: a
    // segfault inside SubjectPacket's construction with curValid/curX/curY
    // holding stack garbage). Wrap in a genuine 2-parameter closure instead
    // so the trailing 3 args are filled in by buildToolVts's OWN defaults
    // at a real call site, not by ABI coincidence.
    app.buildToolVts = (out SubjectPacket s, ref VectorStack v) { ifs.buildToolVts(s, v); };
    app.anyFalloffActive     = cast(bool delegate())&anyFalloffActive;
    // Task 1691 — bound to THIS forwarder, the same one every mouse handler
    // below calls, so the diagnostic in `/api/viewport/display` cannot drift
    // from the branch it describes. Assigned before `wireHttpProviders` (just
    // below) for the same reason every other field in these blocks is: the
    // moved provider closures read `app` through the `ref` parameter.
    app.viewportInputAllowedDg = &ifs.viewportInputAllowed;
    app.rebuildLoopHoverMask = cast(const(bool)[] delegate(int))&rebuildLoopHoverMask;

    // Phase-B ctx wiring (source/http_providers.d): same rules as the blocks
    // above. Pointer-backed selTypeOrder (mutated via .touch() on both
    // sides); by-value class refs bvhPick/stepTrace/session (each assigned
    // exactly once, all before this point); hook delegates for main()'s
    // nested functions. app.replayUndoEntry is NOT wired here -- the moved
    // block ASSIGNS it through the `ref EditorApp app` parameter (synced
    // back below, next to uiCommandDelegate).
    app.selTypeOrderPtr      = &selTypeOrder;
    app.bvhPick              = bvhPick;
    app.stepTrace            = stepTrace;
    app.session              = session;
    app.ensureDisplayCurrent = cast(void delegate())&ensureDisplayCurrent;
    app.derivedEditMode      = cast(EditMode delegate())&derivedEditMode;
    app.formsInteractiveLatchPtr = &formsInteractiveLatch;
    // Phase 1b (task 1520): the BOUND reference is the non-throwing shape.
    app.applyOrRefire         = (Command c, RecordMode m) => applyOrRefire(c, m, null);
    app.applyOrRefireThrowing = (Command c, RecordMode m, string t) => applyOrRefire(c, m, t);

    // Phase-B HTTP wiring call (was the inline `if (httpServer !is null) {
    // ... }` block that sat right after this main()'s outer-scope delegate
    // declarations, app.d ~3633-6044 pre-move). httpServer is ALWAYS
    // constructed (the listener is gated separately on start()), so this
    // runs unconditionally exactly like the block it replaces. Placed HERE,
    // after the 0419 LATE wiring, because the moved block reads fields from
    // BOTH wiring blocks (0415's at ~2873 and 0419's above).
    wireHttpProviders(httpServer, app);
    // Sync-back: the moved block assigns these three delegates through the
    // `ref EditorApp app` parameter; main()'s later read sites (copilot
    // draw, script-action status line, History panel replay button) keep
    // their original local names, so mirror the values back once.
    uiCommandDelegate   = app.uiCommandDelegate;
    formsInteractiveDispatch = app.formsInteractiveDispatch;
    replayUndoEntry          = app.replayUndoEntry;

    // Interactive history-navigation chokepoint (undo/redo migration P0;
    // in-session record+consolidate Phase 1). MAIN-THREAD ONLY — never call
    // from the HTTP server thread (it touches the active tool). The body —
    // branch order, comments and all (peel → whole-edit cancel →
    // drop-or-survive → stack step → resync) — moved verbatim to
    // EditSession.navigate (task 0428); this forward stays so the four
    // keyboard/script callers keep their name. NOTE: /api/undo and /api/redo
    // deliberately BYPASS this chokepoint (straight history.undo()/redo(),
    // no cancel, no resync) — a frozen contract the edge-slice tests
    // document; do not "unify" them through navigate().
    // Returns true if anything happened (edit cancelled OR stack moved).
    bool navHistory(bool isUndo) {
        return session.navigate(isUndo);
    }
    // Phase-B panel wiring: the moved Command History panel
    // (ui/panels.d's drawCommandHistoryPanel) drags its cursor row through
    // this chokepoint; declared HERE because navHistory only exists now.
    app.navHistory = &navHistory;

    // Task 0781 — the input-router cluster's first slice
    // (source/input_router.d): handleWindowEvent + handleMouseWheel.
    // Constructed HERE, not earlier: `router.app = app` needs EditorApp's
    // own LATE ctx-wiring finished first (app.layoutPtr, assigned above at
    // the 0419 LATE block, is what handleWindowEvent reads through
    // `app.layout`). `window`/`playbackMode`/`thickLineProgram` are
    // assigned exactly once in main(), well before this point, so the
    // by-value copies below are stable for the rest of the run;
    // `winW`/`winH` are pointer-backed into main()'s own locals because
    // handleWindowEvent mutates them via `&winW` etc. `fbW`/`fbH` point
    // straight into the input/frame cluster's own fields instead (task
    // 0781 step 1a moved their storage there) -- `&ifs.fbW`/`&ifs.fbH`,
    // not `&fbW()`/`&fbH()` (the latter would take the FORWARDER
    // function's address, not the stored int's).
    InputRouter router;
    router.app              = app;
    router.window           = window;
    router.playbackMode     = playbackMode;
    router.thickLineProgram = thickLineProgram;
    router.winWPtr          = &winW;
    router.winHPtr          = &winH;
    router.fbWPtr           = &ifs.fbW;
    router.fbHPtr           = &ifs.fbH;
    // Task 0781 step 2a -- what the two keyboard handlers brought with them.
    // `ifs` is the class REFERENCE, not a copy: the router and main() must see
    // the same cluster (that is what step 1a's struct->final class flip is
    // for). `recLogPtr` is address-of a main() local whose lifetime main()
    // still owns. `runCommandWithArgs` is NO LONGER wired here: step 2d moved
    // its second caller's spelling router-side and turned the step-2a delegate
    // field into a real InputRouter method (plan §4/Q2).
    router.ifs                = ifs;
    // Task 0781 step 2e -- both SDL-event logs, pointer-backed. `recLogPtr`
    // arrived in 2a for the F1/F2 recording branch; `evLogPtr` arrives now with
    // `processEvent`, whose first two lines are `evLog.log(*ev)` and (unless the
    // key is F1/F2) `recLog.log(*ev)`. Neither instance MOVES, and that is the
    // plan's `winW`/`winH` exception rather than a shortcut past its "state that
    // moves is state that MOVES" rule: main() opens `evLog` from the CLI flags,
    // writes its viewport header once the layout is known, and registers
    // `scope(exit) evLog.close()` / `scope(exit) recLog.close()` AT the
    // declarations ~3,580 lines above this line. Re-registering those two here
    // would reorder them against the ~20 `scope(exit)`s in between -- both logs
    // close LAST today and would close mid-GL-teardown instead -- and 0781's
    // whole contract is byte-identical behaviour.
    router.evLogPtr           = &evLog;
    router.recLogPtr          = &recLog;

    // Task 0781 step 2d -- the AI interaction-log pair the press handler reads,
    // and the only two names in this whole step that do NOT move outright.
    // Both have a second main()-side reader that is not going router-side (the
    // handle-apply hook at the AI wiring block ~1,400 lines above), and that
    // reader is lexically BEFORE `router` exists, so it could not name the
    // router even if we wanted it to. So: `aiLogSource` by VALUE -- assigned
    // exactly once, never mutated, the same (в) class as `window`/
    // `playbackMode` above, not a pointer back into main() -- and
    // `aiEditModeId` as a delegate onto the nested function, which is what
    // keeps the moved call site (`ctx.editModeId = aiEditModeId();`) textually
    // unchanged.
    router.aiLogSource        = aiLogSource;
    router.aiEditModeId       = &aiEditModeId;

    // Task 0781 step 2e -- the three `aiLastPicked*` forwarders 2d left here
    // are GONE, exactly as that step predicted: their last main()-side sites
    // were the writes inside `doSelectPickAt`'s body, and that body is now an
    // InputRouter method writing the fields bare. The compiler was the census,
    // as it was for step 2c's four.

    // Task 1040 — the input/frame shared-state cluster (source/
    // input_frame_state.d). Wired HERE, same reasoning as `router.app`
    // just above: `ifs.app = app` needs the SAME LATE ctx-wiring finished
    // (buildToolVts's body reads app.mesh/.editMode/.selTypeOrder/.vpm,
    // all wired well before this point; viewportInputAllowed reads app.io/
    // .testMode, wired by the 0419 LATE block, also before this point).
    // No `viewportHoveredPtr` wiring any more (task 0781 step 1a): the
    // flag itself moved into the cluster, and the not-yet-extracted frame
    // body's three writes now go through the `g_viewportWindowHovered`
    // forwarder straight into `ifs.viewportWindowHovered`.
    ifs.app = app;
    // Task 0781 step 1c -- the pick family's ENGINE SWITCH, still read here
    // and not in the cluster, because the environment read is a main()
    // responsibility: read once at startup, runtime changes need a relaunch.
    // Its companion `itemPicker` is NOT wired here any more (step 2's review
    // finding): `new ItemRayPicker()` moved into InputFrameState's own
    // constructor, so the object exists from the `new InputFrameState()` at
    // the top of main() instead of from this block ~3,570 lines later. The
    // cluster also DEFAULTS `useBvhFacePick` to true (the same value "bvh"
    // yields below), so the only thing the line below still does is honour a
    // `VIBE3D_FACE_PICK=gpu` override -- a direct construction in a unit test
    // no longer silently gets the GPU engine.
    {
        import std.process : environment;
        ifs.useBvhFacePick = environment.get("VIBE3D_FACE_PICK", "bvh") != "gpu";
    }

    // Task 1670 — wire the arm-time pose hook declared next to
    // `setActiveTool`. HERE, and not at `buildToolVts`'s own declaration a
    // little above it, because the body below runs `buildToolVts`, whose
    // forwarder needs `ifs.app` — the very line above. This is the earliest
    // point at which the hook could fire correctly, and everything before it
    // still sees the null hook and behaves exactly as it did before.
    //
    // The body is a verbatim copy of the frame loop's tool-tick site (search
    // `activeTool.update(vts)`): build this frame's subject packet, publish
    // it, tick. Kept as a copy rather than a shared helper because the frame
    // loop's site is inside the not-yet-extracted loop body and hoisting it
    // would be a refactor of that, not of this.
    armedToolPoseHook = () {
        if (activeTool is null) return;
        SubjectPacket subj; VectorStack vts; ifs.buildToolVts(subj, vts);
        activeTool.update(vts);
    };

    // Task 0781 step 2a -- `pieArmIfOpened`, `handleKeyDown` and
    // `handleKeyUp` (237 lines together) moved to InputRouter
    // (source/input_router.d), bodies verbatim, for the same reason
    // `handleWindowEvent`/`handleMouseWheel` already live there.
    // `processEvent`'s SDL_KEYDOWN / SDL_KEYUP cases below now call
    // `router.handleKeyDown` / `router.handleKeyUp`, and those are their only
    // call sites (grep-verified before the move).
    //
    // What they reached that EditorApp does not carry travels as router
    // members, wired in the `InputRouter router;` block above: `recLog`
    // POINTER-backed (the EventLogger instance stays a main() local -- main()
    // still owns its `scope(exit) close()`; step 2e gave it a second router-side
    // reader, `processEvent`'s own `recLog.log`, and `evLog` the same
    // treatment), `runCommandWithArgs` as a DELEGATE onto the nested
    // function above (its second caller, `doItemSelectPickAt`, is still here
    // and moves in step 2d, at which point the body moves too -- plan §4/Q2),
    // `kFovY` as a struct-level enum, and `ifs` as the class reference to this
    // main()'s own cluster instance. Everything else they read was already an
    // EditorApp field and is reached bare under that type's `with (app)`
    // block -- with ONE deliberate exception, `ifs.buildToolVts`, spelled out
    // at both moved call sites because EditorApp carries a narrower member of
    // that same name; see the block comment at the moved handlers.

    // Task 0781 step 2d -- `handleMouseButtonDown` (299 lines) and
    // `handleMouseButtonUp` (467) moved to InputRouter (source/
    // input_router.d), bodies verbatim modulo the `app.` / `ifs.` bindings
    // this seam always costs, for the same producer/consumer reason every
    // handler before them moved. `processEvent`'s SDL_MOUSEBUTTONDOWN /
    // SDL_MOUSEBUTTONUP cases below now call `router.handleMouseButtonDown` /
    // `router.handleMouseButtonUp`, and those are their only call sites
    // (grep-verified before the move).
    //
    // WHAT TRAVELLED WITH THEM, and the one thing that did not:
    //
    //   * `beginInteractiveSelEdit` / `commitInteractiveSelEdit` and the three
    //     `pendingSel*` fields behind them -- the two handlers were their ONLY
    //     callers (six sites, all inside this pair), so the session is now
    //     wholly the router's;
    //   * `tbSpinCam` (the trackball-spin camera captured on the press and
    //     armed on the release) -- same, both readers moved;
    //   * `doItemSelectPickAt` and `refreshHoverPickAt` -- DELEGATE fields on
    //     the router at that step, exactly as `doSelectPickAt` became in 2c,
    //     because their BODIES were still closures over main()'s frame. Step 2e
    //     moved the bodies and the three became plain methods, so nothing binds
    //     them any more;
    //   * `aiLastPickedVertex` / `Edge` / `Face` -- storage moved in 2d with the
    //     reader, and step 2e brought the writer (`doSelectPickAt`'s body), so
    //     the three same-name forwarders 2d parked in the router-wiring block
    //     are gone;
    //   * `runCommandWithArgs` -- a real InputRouter METHOD now, not the step-2a
    //     delegate field. Plan §4/Q2's deciding grep held at the move (the
    //     declaration plus three calls, nothing else), and 2d brought its second
    //     caller's spelling with it: `doItemSelectPickAt`'s body below names
    //     `router.runCommandWithArgs` at its two sites;
    //   * `aiLogSource` is a BY-VALUE copy on the router (assigned once at
    //     wiring, never mutated -- the same (в) class as `window`/`playbackMode`)
    //     and `aiEditModeId` a delegate onto the nested function above, because
    //     both have a second main()-side reader that is NOT going router-side
    //     (the handle-apply hook at the AI wiring block, declared long before
    //     `router` exists, so it could not name it).
    //
    // `doSelectPickAt` itself (step 2c) had exactly ONE main()-side site left
    // after 2d, the `router.doSelectPickAt = ...` binding; step 2e deleted it
    // with the body. The press handler's null-guard went with the field.

    // Task 0781: handleMouseWheel moved to InputRouter too (see the note
    // above handleWindowEvent's removal site).

    // Task 0781 step 2c: handleMouseMotion moved to InputRouter too
    // (source/input_router.d). The body is verbatim -- the only edits are
    // the `app.` / `ifs.` bindings this seam always costs (see that
    // module's own note above the moved handler for why they are spelled
    // out instead of inferred from a `with (app)` block).
    // processEvent's SDL_MOUSEMOTION case now calls router.handleMouseMotion.

    // Task 0781 step 1c -- THE PICK FAMILY MOVED. `pickHover` (and its
    // `pickVertices`/`pickEdges` instantiations), `pickFaces`,
    // `pickItemUnderCursor` and `pickItems` are now methods of the input/
    // frame shared-state cluster (source/input_frame_state.d), for the same
    // producer/consumer reason as every member before them: the frame body
    // calls them directly, the three picker delegates below call them too.
    // Step 1c left five same-name forwarders here so no call site had to
    // change; STEP 3 DELETED THEM, and the frame body's four calls now read
    // `ifs.pickVertices` / `ifs.pickEdges` / `ifs.pickFaces` /
    // `ifs.pickItems` explicitly. `pickHover` never needed a forwarder:
    // nothing outside the family ever named it.
    //
    // `itemPicker` and `useBvhFacePick` travelled with them (their only
    // readers were `pickItemUnderCursor` and `pickFaces`); both are wired
    // next to `ifs.app` further down, where the VIBE3D_FACE_PICK read now
    // lives.

    // Task 0781 step 2e -- THE THREE PICKER BODIES MOVED. `doSelectPickAt`,
    // `doItemSelectPickAt` and `refreshHoverPickAt` are now real METHODS of
    // InputRouter (source/input_router.d), not delegate fields bound here: with
    // the six handlers that call them already router-side, the closures had no
    // main() frame left to close over. Bodies are verbatim modulo the
    // `app.`/`ifs.` bindings this seam always costs; the three
    // `router.doXxx = ...` assignments and the `!is null` guard at each call
    // site are gone with them (a bare method name in a boolean context does not
    // compile, so that removal is compiler-checked, not eyeballed).
    //
    // `pickItemUnderCursor`'s same-name forwarder went too: its ONLY caller was
    // `doItemSelectPickAt`, which now spells `ifs.pickItemUnderCursor`. The
    // other four forwarders above stay -- the frame body still calls
    // `pickVertices`/`pickEdges`/`pickFaces`/`pickItems` by their bare names,
    // and step 3 is what deletes those.

    // The entire former UI-panel block (app.d main()'s 23 nested functions)
    // is now relocated to source/ui/panels.d across task 0419's phases:
    // drawButtonOutline/drawRaisedBevel/renderStyledButton (Phase 1, pure
    // helpers) + drawTabPanel (Phase 2) + drawViewportPropsPanel (Phase 3)
    // + drawLayerListPanel (Phase 4) + dispatchAction/
    // renderFalloffStackItems/renderDynamicPopupItems/renderPopupItems/
    // drawSidePanel/drawStatusBar (Phase 5, moved together -- dispatchAction
    // is called from renderFalloffStackItems/renderPopupItems/
    // drawSidePanel's nested renderButton; renderPopupItems recurses into
    // itself and is called from both drawSidePanel's and drawStatusBar's
    // nested renderVariantPopup) + renderViewportSceneToFbo (Phase 6, keeps
    // its original 6 params with `EditorApp app` prepended). All six
    // CTX-panel entry points take `EditorApp app` and are called
    // `xxxPanel(app, ...)` below. Only the symbols app.d's OWN remaining
    // code actually references are imported here (Phase 7 cleanup) --
    // drawButtonOutline/drawRaisedBevel/renderStyledButton/dispatchAction/
    // renderFalloffStackItems/renderDynamicPopupItems/renderPopupItems/
    // firstCheckedLabel/drawSectionHeader/pushButtonBarStyle/
    // popButtonBarStyle are now purely internal to ui.panels (only called
    // from within the panel bodies themselves, never from app.d directly).
    // drawLayerListPanel/drawViewportPropsPanel keep their own separate
    // local imports at their call sites, below.
    import ui.panels : drawSidePanel, drawStatusBar, drawTabPanel,
        pushPopupStyle, popPopupStyle, pushPanelChromeStyle,
        popPanelChromeStyle,
        drawAi3dModal, drawRemeshModal, drawQuitGuardModal,
        drawCommandHistoryPanel;
    // Task 0722 (audit §2C A3): the FBO scene pass is not a panel and no
    // longer lives with them -- 871 lines of GL with zero ImGui in it.
    import ui.viewport_render : renderViewportSceneToFbo;
    // Task 0669 — the per-frame button-availability record (see ui/availability.d).
    import ui.availability : beginButtonAvailabilityFrame,
                             endButtonAvailabilityFrame;

    // -------------------------------------------------------------------------
    // Main loop
    // -------------------------------------------------------------------------

    // Task 0781 step 2e -- THE DISPATCHER MOVED. `processEvent` (the SDL-event
    // switch), `pieFireHovered` and `pieChordModifier` (its two pie-menu
    // helpers, called from nowhere else) are now InputRouter methods
    // (source/input_router.d). That closes step 2: all seven handlers plus the
    // dispatcher are one object's, and main() reaches the input path through
    // exactly two call sites, both spelled `router.processEvent(...)` -- the
    // direct-dispatch delegate just below and the SDL_PollEvent body in the
    // frame loop.
    //
    // `evLog` and `recLog` did NOT move with it. They are the plan's
    // `winW`/`winH` exception class, not new router state: main() opens them
    // from the CLI flags and registers `scope(exit) <log>.close()` AT the
    // declarations ~3,580 lines above, so moving the storage would mean
    // re-registering those two `scope(exit)`s here, in the middle of the GL
    // teardown chain instead of after it. The router reads them through
    // `evLogPtr`/`recLogPtr`; the reasoning is written out at those fields.

    // Register direct-dispatch delegate so EventPlayer.tick can deliver
    // events to the same code path without going through SDL's queue.
    setDirectEventDispatch((SDL_Event* ev) {
        if (!router.processEvent(ev)) running = false;
    });
    scope(exit) clearDirectEventDispatch();

    while (running) {
        // Perf (doc/frame_probe_scenarios_plan.md, task 0195): beginFrame is
        // the FIRST statement of the loop body; endFrame (below, before the
        // present/flush conditional) closes it. No-op in the default build.
        g_frames.beginFrame();
        // Always-on work counters (perf_probe.d FrameWorkProbe). Paired with
        // g_frames deliberately: same frame boundary, so a `perf`-build
        // timing and a default-build count describe the SAME frame and can be
        // put side by side without an alignment argument.
        g_fc.beginFrame();

        // Perf: events phase — playback tick + HTTP event-player drain +
        // the SDL_PollEvent dispatch loop. `toolNs` (the live geometry apply
        // during a drag) nests INSIDE this region — see xfrm_transform.d's
        // applyFold site. Explicit block so the scope timer fires right
        // after the SDL_PollEvent loop, not at the end of the whole frame.
        // No-op in the default build.
        {
            auto zFramesEvents = g_frames.phase(Phase.events);
            // ---- Task 1500: the barrier, and EXACTLY what it covers ----
            // RECORDED INPUT ONLY. A subpatch preview build is now
            // asynchronous, and the preview participates in SELECTION (it
            // carries element provenance), so delivering a recorded event
            // while a build is in flight would make the answer depend on
            // whether the background thread had finished — measured, not
            // feared: task 1500's phase 0 turned
            // tests/test_hide_geometry_pick.d's edge-lasso row from the
            // preview's 12 edges into the cage's 16.
            //
            // `httpServer.tickAll()` is DELIBERATELY OUTSIDE the gate. It
            // drains every registered main-thread bridge by construction
            // (http_server.d, the bridges self-register), so gating it would
            // take `/api/reset` — the harness's only recovery lever — and
            // `/api/subpatch/preview`, which has to be able to answer
            // `pending:true`, down with it, and would run ~30 routes into
            // the 5 s `submitAndWait` ceiling on any build longer than that.
            //
            // The gate is BOUNDED (see `scriptedInputHeld`): past its
            // ceiling the input is delivered against the cage, with a
            // warning. Observationally this changes nothing about today's
            // behaviour, because `EventPlayer.tick` is already wall-clock
            // gated (eventlog.d) — a 4 s build inside one frame already made
            // the overdue events fire in a burst right after it.
            immutable bool scriptedInputHeld = subpatchPreview.scriptedInputHeld();
            // ---- Playback: push due events before polling ----
            if (!scriptedInputHeld) { if (playbackMode) evPlay.tick(); }
            // httpServer is always constructed now; only drain the request queues
            // when the listener is actually up (start() called). Skipped entirely
            // in a release/no-http run, where no thread ever posts requests.
            if (httpServer.running) {
                if (!scriptedInputHeld) httpServer.tickEventPlayer();
                httpServer.tickAll();
            }

            // Task 1670 — THE DIAGNOSED SEAM, and the only place this stall
            // is consumed. The command bridge has just drained: if that batch
            // held a `tool.set`, a tool is armed and its reply is already on
            // the wire, while this frame has NOT yet reached
            // `activeTool.update(vts)` far below. That gap is where a
            // `/api/tool/state` read used to see an un-posed tool.
            //
            // Inert unless VIBE3D_STALL_PRE_TOOL_TICK_MS is set (asserted in
            // source/frame_stall.d), and when set it fires ONCE per arm — a
            // keyboard-armed tool arms it too and simply consumes the pause
            // one frame later, harmlessly, since the instrument is aimed at
            // the HTTP path.
            preToolTickStall.waitAtSeam();

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
                if (!router.processEvent(&event)) {
                    running = false;
                    break;
                }
            }
        }

        // ---- Trackball momentum spin (task 0582): the per-frame camera tick
        //
        // Placed here, immediately after the event phase and before anything
        // reads a camera, so a spin and a drag cannot both write the same
        // orientation within one frame in an order that depends on where the
        // reader sits: the events for this frame are in, the spin advances
        // once, and every consumer below — snapshots, caches, picking, the
        // draw — sees one settled camera.
        //
        // `anySpinning` is the whole cost for a user who never uses the
        // gesture: one bool test per frame, no clock read, no walk. When it IS
        // set, the sweep ticks every cell (a spin belongs to a CELL, and a
        // background cell must keep coasting while you work in another) and
        // recomputes the flag from what is still running, so the tick switches
        // itself off one frame after the last spin ends.
        if (ifs.anySpinning) {
            immutable uint nowMs = SDL_GetTicks();
            ifs.anySpinning = false;
            foreach (cell; vpm.views) {
                if (cell is null || cell.camera is null) continue;
                cell.camera.spinTick(nowMs);
                ifs.anySpinning = ifs.anySpinning || cell.camera.spinning();
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
                    // Task 0616 Ph4: the Images list is a sibling TAB of
                    // Layers, not rows inside it — the two lists are exact
                    // complements of `document.layers` and the Layers panel
                    // stays about geometry.
                    ImGui.DockBuilderDockWindow("Images",             rightId);
                    ImGui.DockBuilderDockWindow("Tool Properties",    rightId);
                    // Task 0637: Channels is a sibling TAB of Tool Properties,
                    // and that IS the tab strip — several windows in one dock
                    // node grow an ImGui tab bar by themselves, so nothing is
                    // hand-built (this build's binding has no `BeginTabBar`;
                    // see the tool-properties strip below). Which of the two
                    // sits in front, and whether the user splits them apart
                    // instead, is then their layout, persisted by the same
                    // versioned ini as every other panel. Docked AFTER Tool
                    // Properties so a fresh profile opens on the curated form
                    // and finds the exhaustive list one tab over.
                    //
                    // `kLayoutIniVersion` deliberately NOT bumped: an existing
                    // ini has no entry for this window, so it opens floating
                    // there until docked by hand — the same trade the Images
                    // panel took, and cheaper than resetting everyone's layout
                    // for one window.
                    ImGui.DockBuilderDockWindow("Channels",           rightId);
                    // Task 1100. `kLayoutIniVersion` deliberately NOT bumped,
                    // for the reason stated above: an existing ini has no entry
                    // for this window and opens it floating, which is cheaper
                    // than resetting everyone's layout for one window.
                    ImGui.DockBuilderDockWindow("Statistics",         rightId);
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

        // TASK 0669 — bracket every button bar of this frame so
        // `/api/buttons/availability` reads back what was actually drawn
        // (disabled flag + reason), not what a resolver would answer if asked
        // again. `--test` only; a no-op branch otherwise.
        // The modifiers go in with the frame: the side panel picks a row's
        // label and action from the LIVE modifier state (`ctrl:` / `alt:` /
        // `shift:` variants), so a record without them cannot tell "that button
        // was not drawn" from "that button is currently called something else".
        beginButtonAvailabilityFrame(document.hasEditTarget(), activeToolId,
                                     cast(uint)SDL_GetModState());

        // ---- Zone frame (task 1810) ---------------------------------------
        // The viewport CELLS are published straight from the layout, not from
        // a draw call: `vpm.views[k]`'s rect is already the authoritative one
        // and is identical under `--test`, where no "Viewport" ImGui window
        // exists to be hovered at all. Published FIRST so that any panel
        // overlapping a cell wins the last-published rule below it.
        {
            import input_zones : beginZoneFrame, publishZone;
            beginZoneFrame();
            foreach (k; 0 .. vpm.cellCount) {
                auto vv = vpm.views[k];
                publishZone("viewport3d", cast(float) vv.winX, cast(float) vv.winY,
                            cast(float) vv.winW, cast(float) vv.winH);
            }
        }
        drawSidePanel(app);
        drawTabPanel(app);

        // ---- AI3D Generate modal (task 0381 Phase 3) -----------------------
        // Moved VERBATIM to ui/panels.d's drawAi3dModal (app.d decomp,
        // phase B; same `with (app)` seam as the 0419 panels).
        drawAi3dModal(app);

        // ---- Quad Remesh modal (source/remesh/remesh_job.d) -----------------
        // Moved VERBATIM to ui/panels.d's drawRemeshModal (app.d decomp,
        // phase B; same `with (app)` seam as the 0419 panels).
        drawRemeshModal(app);

        // ---- Unsaved-changes quit guard + confirmation modal (task 0434) ----
        // Moved VERBATIM to ui/panels.d's drawQuitGuardModal (app.d decomp,
        // phase B; same `with (app)` seam as the 0419 panels).
        drawQuitGuardModal(app);

        drawStatusBar(app);

        // ---- Pie menu (task 1800) ------------------------------------------
        // Inside the availability bracket, so a wedge shows up in
        // `/api/buttons/availability` under source "pie" exactly as a side
        // panel row does under "side" — same record, same disabled reason, and
        // the only headless read there is of what the ring actually offered.
        // Drawn LAST of the button surfaces because it sits over all of them.
        {
            import ui.pie_render   : drawPieMenu;
            import ui.availability : actionRefusal, recordDrawnButton;
            drawPieMenu((ref Button b) {
                string why = b.disabled
                    ? ""
                    : actionRefusal(reg, b.action, document.hasEditTarget(),
                                    activeToolId);
                recordDrawnButton("pie", b.label, b.action.kind, b.action.id,
                                  b.disabled || why.length > 0, why);
                return why;
            });
        }

        endButtonAvailabilityFrame();
        version (WithRender) drawIPRPanel(&mesh(), cameraView);

        // ---- Layers (floating) ----
        // Same imgui-determinism rule as Tool Properties below: in --test this
        // panel is hidden by default (a test opts in via `ui.layerList show`)
        // so synthetic viewport drags are never captured by it. In a normal run
        // it is always drawn (g_testMode false ⇒ guard passes).
        if (!command.g_testMode || g_layerListShown) {
            import ui.panels : drawLayerListPanel;
            drawLayerListPanel(app);
        }

        // ---- Images (floating; task 0616 Ph4) ----
        // The document's loaded images. Same imgui-determinism rule as the
        // Layers panel above — hidden by default in --test, opt-in via
        // `ui.imageList show` — so a second floating window cannot start
        // swallowing the synthetic viewport drags every existing test drives.
        if (!command.g_testMode || g_imageListShown) {
            import ui.panels : drawImageListPanel;
            drawImageListPanel(app);
        }

        // ---- Channels (dockable; task 0637) ----
        // Every channel of the focused item, uncurated — the surface that lets
        // the properties form stay curated without a channel becoming
        // unreachable. Same imgui-determinism rule as the two panels above:
        // hidden by default in --test, opt-in via `ui.channels show`, so a
        // third window cannot start swallowing the synthetic viewport drags
        // every existing test drives.
        if (!command.g_testMode || g_channelsShown) {
            import ui.panels : drawChannelsPanel;
            drawChannelsPanel(app);
        }

        // ---- Statistics (dockable; task 1100) ----
        // The element-count tree with its two selection columns. Same
        // imgui-determinism rule as the panels above: hidden by default in
        // --test, opt-in via `ui.statistics show`.
        //
        // The parameters are NARROW on purpose — a `const(Document)*`, the
        // current selection type, the expand bits and one dispatch delegate —
        // which is what makes the panel constructible in a unittest and what
        // extends the panel's own no-mutation proof to the drawer. See
        // `ui/panels.d`'s header for the drawer.
        if (!command.g_testMode || g_statisticsShown) {
            import ui.panels : drawStatisticsPanel;
            import commands.ui.statistics : g_statExpand;
            import seltype : currentSelType;
            drawStatisticsPanel(&app.document(), currentSelType(app.selTypeOrder),
                                g_statExpand, app.uiCommandDelegate);
        }

        // ---- Viewport Properties (floating) ----
        // Hidden in --test by default; opt-in via `ui.viewportProps show`.
        if (!command.g_testMode || g_viewportPropsShown) {
            import ui.panels : drawViewportPropsPanel;
            drawViewportPropsPanel(app);
        }

        // ---- About (floating; task 0641) ----
        // Unlike the panels above, the gate is NOT `--test`-conditional: About
        // is an on-demand window in every mode, opened by File → About… (which
        // dispatches `ui.about show`). Starting hidden also means it can never
        // swallow a synthetic viewport drag, so the imgui-determinism rule the
        // three panels above concede to is satisfied for free here.
        if (g_aboutShown) {
            import ui.panels : drawAboutPanel;
            drawAboutPanel(app);
        }

        // ---- AI Findings (floating; task 0402 Phase 2) ----
        // Same imgui-determinism idiom as Layers/Viewport Properties above:
        // hidden by default in --test, opt-in via `ui.copilotPanel show:true`.
        // The panel is a passive list (copilot_panel.d) — every interaction
        // dispatches through uiCommandDelegate, never touching mesh /
        // document / selection state directly.
        // version(WithAI)-only — compiled out of modeling-noai entirely
        // (see import block doc comment near the top of this file).
        // static if kCopilotEnabled (task 0422): panel draw skipped while
        // the copilot is paused; flip the flag to restore.
        version (WithAI)
        static if (kCopilotEnabled)
        if (!command.g_testMode || g_copilotPanelShown) {
            pushPanelChromeStyle();
            copilotPanel.draw(aiState.enabled, uiCommandDelegate);
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
            // Body moved to ui/panels.d (task 0722, audit §2C A2) -- the
            // last panel entry point that was still a 253-line inline block
            // in main(), joining the six that moved in 0419. The GUARD stays
            // here, matching Layers / Images / Channels / Viewport Properties
            // above: what decides whether a panel is drawn is main-loop
            // business, what it draws is the panel module's.
            import ui.panels : drawToolPropertiesPanel;
            drawToolPropertiesPanel(app);
        }

        // ---- Command History (floating) ----
        // Moved VERBATIM to ui/panels.d's drawCommandHistoryPanel (app.d
        // decomp, phase B; same `with (app)` seam as the 0419 panels).
        drawCommandHistoryPanel(app);

        // ---- Close the zone frame (task 1810) ------------------------------
        // HERE, and not next to `endButtonAvailabilityFrame` above, which is
        // where it first went: the availability bracket closes after the status
        // bar, but Layers / Tool Properties / Command History are all drawn
        // AFTER it. A zone frame closed there records only the docked panels,
        // and every floating one is silently missing — which reads exactly like
        // "the cursor is over nothing", so a binding scoped to `layerList`
        // would never match and nothing would look broken. Caught by probing
        // the live endpoint before writing the test, not by the test.
        //
        // The last PANEL is the boundary, deliberately: what follows is modals
        // and viewport overlays, and neither is a place a chord is aimed at.
        {
            import input_zones   : endZoneFrame, publishedZones;
            import input_context : publishInputContext;
            import seltype       : selTypeToken;
            import eventlog      : queryMouse;
            endZoneFrame();
            int _cx, _cy;
            queryMouse(_cx, _cy);
            publishInputContext(publishedZones(),
                                selTypeToken(currentSelType(selTypeOrder)),
                                activeToolId, _cx, _cy);
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

        // ---- Task 1500: "building subpatch preview" overlay ----
        // What is on screen while a build runs is THE CAGE, and for a first
        // Tab that means the picture does not change at all for seconds.
        // This is the thing that keeps that from reading as a dead key.
        {
            const ind = subpatchPreview.buildIndicatorText();
            if (ind.length) {
                ImDrawList* dl = ImGui.GetForegroundDrawList();
                immutable float bx = 14.0f, by = 14.0f;
                auto sz = ImGui.CalcTextSize(ind);
                dl.AddRectFilled(ImVec2(bx - 6, by - 4),
                                 ImVec2(bx + sz.x + 6, by + sz.y + 4),
                                 IM_COL32(0, 0, 0, 170), 4.0f);
                dl.AddText(ImVec2(bx, by), IM_COL32(255, 210, 90, 235), ind);
            }
        }

        // ---- RMB path trail ----
        if (ifs.rmbPath.length >= 2) {
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
            for (size_t i = 1; i < ifs.rmbPath.length; i++)
                dl.AddLine(ifs.rmbPath[i - 1], ifs.rmbPath[i], IM_COL32(0, 255, 255, 220), 1.0f);
            // Closing line: start → end
            dl.AddLine(ifs.rmbPath[0], ifs.rmbPath[$ - 1], IM_COL32(0, 255, 255, 220), 1.0f);
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

            // Display upload is bus-driven (campaign 0407 §D4-в): mutating
            // commands no longer refresh the display themselves — this flush
            // site uploads the ACTIVE mesh's GPU buffers whenever the frame's
            // pending change classes intersect DisplayRefreshMask. Capture +
            // upload at the TOP of the flush block, BEFORE the debug shadow
            // check and the drain below, for two reasons:
            //   • Under an active subpatch preview `gpu.upload` redirects to
            //     a mutationVersion bump (GpuMesh.suppressCageUpload) instead
            //     of uploading. Done after the drain, that bump would land in
            //     a zero-flag window and the NEXT frame's shadow check would
            //     latch a spurious MISSED-PUBLISHER warning; here the bump is
            //     observed in the same frame with the triggering flags still
            //     pending, so the diagnostic stays quiet. The bump is also
            //     what makes the preview block's `versionChanged` (further
            //     down) fire for noteChange-only commands — so the upload is
            //     deliberately NOT skipped while the preview is active.
            //   • The one hard ordering constraint: the upload MUST precede
            //     the subpatch gate below, whose GPU fan-out reads the cage
            //     VBO contents. Ordering vs `changeBus.flush` itself is free
            //     (subscribers are invalidate-only and never read the VBO).
            // No cache resize/invalidate here — the flag-driven block after
            // the flush already services vc/ec/fc from meshChangedFlags.
            // Active-layer flags only (not the cross-layer aggregate): an
            // undo landing on a background layer must not re-upload the
            // active one — same gate the command-side refresh had.
            // TASK 1906 STAGE 2a — THE SECOND FEED, and it is here rather
            // than inside the bus for a reason worth stating.
            //
            // Until stage 3 a mesh change reaches a consumer by TWO paths: the
            // synchronous delivery at the edit boundary (which names its
            // subject) and this per-frame drain of `pendingChanges_` (whose
            // `changeBus.flush` names NO subject — it hands out the union over
            // every layer). `mesh_dirty` refuses that subject-less aggregate,
            // because acting on it would mark every mesh address it does not
            // track as changed once per changed frame — and the address it
            // does not track is precisely the static background mesh whose
            // surface BVH the Topology Pen leans on.
            //
            // Here the subject IS known: each layer owns its own pending word.
            // So the drain's information is fed per layer, from this loop, and
            // BEFORE the upload site below so a publisher that only
            // `noteChange`d still refreshes the display in the SAME frame it
            // did before stage 2a. Read-only — the zeroing stays in the drain.
            {
                import mesh_dirty : noteMeshChange;
                foreach (layer; document.layers) {
                    if (!layer.hasMesh) continue;
                    // ONE `meshRef()` per layer, not two: the accessor carries
                    // a debug assert, and this loop runs over every layer of
                    // every frame.
                    auto m = &layer.meshRef();
                    noteMeshChange(cast(size_t)m, m.pendingChanges_);
                }
            }

            {
                // TASK 1906 STAGE 2a — the trigger is the bus epoch for THIS
                // mesh address, not a pull on `mesh.pendingChanges_`. Same
                // place, same gate, same dedup against the mid-batch guard
                // (both stamp `displayServiced_`).
                const size_t ma = cast(size_t)&mesh();
                // A5 (post-gate fix): mid-gesture the transform family owns
                // the VBO — baseline verts with the live drag delta applied
                // via u_model on top (per-frame edits publish Position while
                // the tool draws matrix-composed). A full upload here would
                // bake LIVE verts under a LIVE matrix and double-apply the
                // delta (gpu_fold_parity / far_pivot_fold / chained_drag).
                // Skip while dragging: only XfrmTransformTool overrides
                // isDragging, and its mouseUp bake + commit publish resync
                // the VBO at gesture end. Flags still reach every subscriber.
                const bool toolOwnsVbo =
                    activeTool !is null && activeTool.isDragging();
                if (!toolOwnsVbo
                    && !displayServiced_.matches(ma, g_displayEpochs.epochFor(ma)))
                {
                    gpu.upload(mesh);
                    // Epoch re-read AFTER the upload — the suppressed-cage arm
                    // of `GpuMesh.upload` publishes `Position` itself. See
                    // `ensureDisplayCurrent` for the loop this prevents.
                    displayServiced_.stamp(ma, g_displayEpochs.epochFor(ma));
                }
            }

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
                import change_bus : changeBus;
                static ulong[Layer] lastSeenMutVer;
                static bool  warnedMissedPublisher = false;

                foreach (layer; document.layers) {
                    // Task 0615 Stage 4 (R7): a non-mesh layer never advances
                    // a mutationVersion, so it must never get a
                    // `lastSeenMutVer` entry — skip BEFORE the first read/seed,
                    // not after.
                    if (!layer.hasMesh) continue;
                    // Task 1906 stage 2a: the `displayEnsured_` shadow term
                    // this used to OR in is gone with the shadow itself — the
                    // display guard no longer consumes bits out of
                    // `pendingChanges_`, so what the drain sees IS what the
                    // publishers wrote.
                    const lf = layer.meshRef().pendingChanges_;
                    // recorded remainder (1906 §3.6): `mutationVersion` owns
                    // the compare below and CANNOT be migrated — this is the
                    // shadow check that catches a version bump made WITHOUT a
                    // publish (`changeBus.missedPublishers`, read at
                    // /api/changes, asserted to stay 0). A bus epoch is the
                    // very signal a missed publisher fails to produce, so
                    // keying this on one would make it agree by construction:
                    // the check would be green exactly when it should be red.
                    auto seen = layer in lastSeenMutVer;
                    if (seen is null) {
                        // First observation of this layer — seed, do not compare.
                        lastSeenMutVer[layer] = layer.meshRef().mutationVersion;
                    } else if (layer.meshRef().mutationVersion != *seen && lf == 0) {
                        // Test-introspectable count (via /api/changes) — always
                        // ticks, even after the one-shot stderr line latches, so
                        // a regression test can assert it stays 0 (task 0462).
                        changeBus.missedPublishers++;
                        if (!warnedMissedPublisher) {
                            fprintf(stderr,
                                "change_bus: MISSED PUBLISHER — mutationVersion " ~
                                "advanced (%llu) with no pending change flags; a " ~
                                "mutation site bumped the version but did not " ~
                                "noteChange/commitChange.\n",
                                cast(ulong)layer.meshRef().mutationVersion);
                            warnedMissedPublisher = true;
                        }
                        lastSeenMutVer[layer] = layer.meshRef().mutationVersion;
                    } else {
                        lastSeenMutVer[layer] = layer.meshRef().mutationVersion;
                    }
                }
            }

            foreach (layer; document.layers) {
                // Task 0615 Stage 4 (R7): same skip as the debug loop above —
                // a non-mesh layer has no pending flags to aggregate.
                if (!layer.hasMesh) continue;
                meshFlags  |= layer.meshRef().pendingChanges_;
                selDomains |= layer.meshRef().pendingSelDomains_;
                layer.meshRef().pendingChanges_    = 0;
                layer.meshRef().pendingSelDomains_ = 0;
            }

            // (Task 1906 stage 2a deleted the transfer-back that stood here:
            // `ensureDisplayCurrent` no longer moves bits out of
            // `pendingChanges_`, so there is nothing to give back.)

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

        // ---- Unsaved-changes tracking + window title (task 0434) -----------
        // Push the change-bus document revision AFTER the flush so this frame's
        // mesh/layer mutations are already counted, then reflect the resulting
        // dirty state in the title and settle any Save-and-exit armed this
        // frame by the quit-confirm modal.
        {
            import change_bus  : changeBus;
            import io.doc_state : syncDocRevision, docDirty, currentDocPath;
            import std.path     : baseName;
            import std.string   : toStringz;

            syncDocRevision(changeBus.docRevision());

            // Task 1521: ONE settle for every deferred guarded action (New /
            // Open / Import / Quit), replacing 0434's quit-only `quitAfterSave`.
            settleGuardedAction();

            // Title: "<file> - Vibe3d", leading "*" while dirty, "untitled"
            // when no native document is open. Only touch SDL on change.
            const p     = currentDocPath();
            const fname = p.length ? baseName(p) : "untitled";
            string title = (docDirty() ? "*" : "") ~ fname ~ " - Vibe3d";
            // Task 1500 phase 4 — the second half of the indicator. The
            // viewport overlay (below, with the RMB trail) is the one the
            // user looks at; the title is what survives the window being
            // partially covered.
            {
                const ind = subpatchPreview.buildIndicatorText();
                if (ind.length) title = title ~ "  [" ~ ind ~ "]";
            }
            if (title != lastWindowTitle) {
                SDL_SetWindowTitle(window, toStringz(title));
                lastWindowTitle = title;
            }
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
        // ---- Task 1500: RECEIVE a finished background preview build ----
        // Its OWN statement, not folded into the `meshChangedFlags` gate
        // below: a build lands whenever it lands, and most of those frames
        // have no mesh change flagged at all.
        //
        // POSITION IN THE FRAME IS LOAD-BEARING, and it is here rather than
        // at the top of the events phase for a reason that is measurable
        // rather than stylistic — see `SubpatchPreview.pumpAsyncBuild`'s
        // header. The single preview upload is the block immediately below;
        // receiving any earlier leaves picks running against a live preview
        // trace while the VBOs still hold the cage. M-INV asserts the
        // one-sided invariant at the two consumers.
        bool previewInstalledThisFrame =
            subpatchPreview.pumpAsyncBuild(mesh, subpatchDepth);
        if (previewInstalledThisFrame) {
            // The preview's TOPOLOGY is new, so the position-only scatter
            // path below must not be taken. Without this a rebuild that
            // changed no `mutationVersion` (the version-silent path) would
            // scatter positions into a VBO laid out for the OLD preview.
            gpuUploadedPreviewTopVersion = ulong.max;
        }
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
                // TASK 1906 STAGE 2d (plan §3.4 row 10, §5 row `2d`) — the
                // `positionsDirty` argument is GONE, not merely defaulted.
                // `rebuildIfStale` reads `mesh_dirty.g_geomEpochs` for this
                // mesh's address at its own early-out, which is both
                // subject-keyed (the flags word below is a document-wide OR)
                // and able to see the version-silent gizmo path
                // `mutationVersion` cannot. It keeps `mutationVersion` as a
                // second required term, for the classes the geometry mask
                // drops (Tab writes `Marks`, a crease weight writes
                // `Material`) — an ANY-class epoch in place of the pair would
                // re-evaluate the preview on every selection click, measured
                // at 6 extra evaluations over 6 version-silent selectVertex
                // calls. Deleting the epoch read is §5's named mutation for
                // this row and reddens `tests/test_bus_position_pixel.d` ARM A.
                subpatchPreview.rebuildIfStale(mesh, subpatchDepth, &targets);
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
            // Task 1730 — FREEZE the buffers while a rebuild is in flight.
            //
            // Without this, `dispatchBuild`'s `active = false` reaches here as
            // `wantPreview == false` with `stateChanged == true`, so the CAGE
            // is uploaded; when the build lands the preview is uploaded back.
            // Two full VBO uploads that accomplish nothing between them, and
            // the flicker the owner reported in dogfood is the frames in
            // between. Holding `wantPreview` true keeps the stale limit
            // surface on screen AND keeps `suppressCageUpload` on, so a
            // tool-side upload cannot write cage data into the preview
            // buffers and reintroduce the flicker by another door.
            immutable bool staleOnScreen = ifs.previewIndexSpaceStale();
            bool wantPreview = subpatchPreview.active || staleOnScreen;
            gpu.suppressCageUpload = wantPreview;
            const size_t cageAddr = cast(size_t)&mesh();
            bool versionChanged =
                !gpuUploadedKey_.matches(cageAddr, g_geomEpochs.epochFor(cageAddr));
            bool stateChanged   = gpuUploadedPreview != wantPreview;
            // Task 1500 — the third trigger. For the FIRST Tab `stateChanged`
            // is true and the upload was guaranteed; for a REBUILD (`active`
            // already true) it is false, and `versionChanged` can be false
            // too on the version-silent path — so a freshly received preview
            // would never reach the GPU.
            // `staleOnScreen` short-circuits BEFORE the condition rather
            // than being folded into it, and deliberately: with the freeze
            // active `versionChanged` is TRUE (the topology edit bumped
            // mutationVersion — that is why a rebuild was dispatched at all),
            // so folding it in would take the `wantPreview` branch and upload
            // `subpatchPreview.mesh` through a `trace` built against the
            // PREVIOUS cage. The buffers already hold exactly what we want
            // drawn; the correct action is none.
            //
            // `gpuUploadedKey_` is deliberately NOT advanced here either,
            // so the install frame still sees `versionChanged` and uploads.
            if (staleOnScreen) {
                // Nothing. See above.
            } else if ((wantPreview && (versionChanged || stateChanged
                                 || previewInstalledThisFrame)) ||
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
                    // RECORDED REMAINDER (1906 §3.6, stage 4 census): this
                    // term stays a VERSION compare, and deliberately.
                    // `topologyVersion` is not a freshness signal about the
                    // cage here — it is the INDEX SPACE identity of the
                    // preview already on the GPU, i.e. "is the buffer laid out
                    // for this same source topology, so positions can be
                    // scattered instead of rebuilt". A change class cannot
                    // answer that; only the identity of the layout can.
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
                // Re-read the epoch: this block's own `gpu.upload` can
                // publish (the suppressed-cage arm), same fixpoint hazard as
                // the flush-site upload above.
                gpuUploadedKey_.stamp(cageAddr, g_geomEpochs.epochFor(cageAddr));
                gpuUploadedPreview = wantPreview;
            }
        }

        // ---- 3D render (moved to renderViewportSceneToFbo) ----
        // Scene draw now happens AFTER picking/hover-resolution and
        // BEFORE ImGui.Render() via renderViewportSceneToFbo().  See
        // the Phase-2 FBO section below (after hover resolution).

        bool doingCameraDrag = (ifs.dragMode == DragMode.Orbit ||
                                ifs.dragMode == DragMode.Zoom  ||
                                ifs.dragMode == DragMode.Pan   ||
                                ifs.dragMode == DragMode.Roll);

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

            // TASK 1906 STAGE 2b (§3.2 row 5) — THE PROACTIVE `gpuSelect
            // .invalidate()` THAT STOOD HERE IS DELETED, and this is the one
            // place in stage 2 where the answer is "remove the bus term", not
            // "remove the version term".
            //
            // The rule that decides it: key on the artifact you READ.
            // `gpu_select` rasterises element IDs FROM THE VBO, and its slot
            // key already carries `gpu.uploadVersion`, which fingerprints
            // exactly what is in that buffer. A mesh-change trigger on top is
            // not a second opinion, it is a WORSE one: the mesh can change
            // without the VBO having been re-uploaded yet, and clearing a slot
            // that still matches the buffer the next pick will actually
            // rasterise only throws away a valid render. `uploadVersion`
            // strictly dominates it.
            // COVERAGE, MEASURED RATHER THAN CLAIMED (2026-08-25). The
            // plan's mutation for this row — delete `Slot.uploadVer` from
            // `gpu_select.d :: ensureSlot`'s predicate, expecting "an existing
            // gpu-select pick test after a subdivide" to redden — reddened
            // NOTHING in `test_lasso_select`, `test_falloff_lasso_paint`,
            // `test_element_pick_fresh_hover`, `test_wireframe_select_through`.
            // Deleting one half of a two-key cache on prose while the OTHER
            // half is pinned by nothing is not a trade, so the gap was closed
            // rather than recorded: `tests/test_gpu_select_slot_upload_key.d`.
            //
            // WHY EVERY PICK-SHAPED CANDIDATE MISSED, since it is the part
            // that costs an afternoon to rediscover: `ensureSlot` invalidates
            // EVERY OTHER MODE's slot after a re-render, and in Vertices mode
            // the per-frame hover pass runs `ensureSlot(SelectMode.Vertex)`
            // continuously — so a Face slot never survives to the next pick and
            // a face route cannot observe a stale slot at all. The observable
            // is ONE MODE HELD CONTINUOUSLY ACROSS A GEOMETRY CHANGE: park a
            // vertex hover, `/api/transform` the cube by its own width, read
            // `/api/toolpipe/eval`'s `hover.vertex` again. Dropping the
            // `uploadVer` term then leaves the hover on the OLD vertex (6)
            // while the new geometry puts vertex 7 at 1.3 px from the cursor.

            // TASK 1906 STAGE 2c (§3.3 rows 8, 9, 30) — THE PROACTIVE
            // `invalidateSnapGrids()` + `sym.invalidatePairingCache()` PAIR
            // THAT STOOD HERE IS DELETED. Both caches keyed on
            // (address, mutationVersion); a gizmo drag is version-silent on
            // Position, so neither key could see it and this block was the
            // patch: on any Position frame, reach into two modules and drop
            // their caches wholesale.
            //
            // What replaced it is the same move stages 2a/2b made — the caches
            // carry `mesh_dirty`'s per-address GEOMETRY EPOCH instead of a
            // version counter, and compare it at their own lazy recompute
            // (`snap.queryCandidateGrid`, `SymmetryStage.evaluate`). Three
            // things that were wrong here are right there:
            //
            //   * IT HAS A SUBJECT. This block dropped EVERY source slot's
            //     grid because SOME layer changed. A background layer whose
            //     mesh nobody touched now keeps its grid while the primary is
            //     edited — the same property `mesh_dirty`'s header defends for
            //     the Topology Pen's static background.
            //   * IT NEEDS NO CALLER. A new publisher does not have to
            //     remember this block exists; a delivered class advances the
            //     epoch at the edit boundary.
            //   * IT IS NARROWER. `commitChange` bumps `mutationVersion` for
            //     every class, so a selection click used to invalidate the
            //     pair table; the epoch watches Position|Points|Polygons,
            //     which is exactly what the mirror search and the bucket
            //     projections read.
            //
            // Pinned by `tests/test_bus_snap_grid_after_drag.d` and
            // `tests/test_bus_symmetry_pairing_after_drag.d`, each with a
            // scripted-`/api/transform` control arm that stays green when the
            // version term is restored.
            //
            // `snap.invalidateSnapGrids()` still exists and still has ONE
            // production caller — the active-layer-switch hook above. That is
            // not a mesh change: no mesh was edited, the snap SOURCE was
            // re-pointed, and no epoch moves for it. Do not re-add a caller
            // here.
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

        ifs.pickVertices(vp, doingCameraDrag);

        // Check if edge cache needs update due to camera movement
        if (!doingCameraDrag && edgeCache.needsUpdate(vp)) {
            edgeCache.invalidate();
            edgeCache.update(vp);
        }

        ifs.pickEdges(vp, doingCameraDrag);

        // Check if face cache needs update due to camera movement
        if (!doingCameraDrag && faceCache.needsUpdate(vp)) {
            faceCache.invalidate();
            faceCache.update(vp);
        }

        ifs.pickFaces(vp, doingCameraDrag);

        // Item hover (task 0647). Last of the four, and outside every
        // editMode branch above: the item ray is asked on EVERY frame under
        // the Item selection type, whatever the remembered geometry type is.
        ifs.pickItems(vp, doingCameraDrag);
        }
        int pickedVertex = ifs.hoveredVertex;
        int pickedEdge = ifs.hoveredEdge;
        int pickedFace = ifs.hoveredFace;

        // Tool-driven multi-type hover priority resolution: when an
        // active tool (e.g. XfrmTransformTool with falloff.element
        // in Auto mode) picks across vert/edge/face
        // simultaneously, only ONE of
        // them should highlight per cursor position — vert first,
        // then edge, then face. Without this the cursor over a
        // corner would light up both the vertex dot AND the face
        // checker, which mis-represents what click-to-pick will hit.
        if (activeTool !is null) {
            if (ifs.hoveredVertex >= 0) {
                ifs.hoveredEdge = -1;
                ifs.hoveredFace = -1;
            } else if (ifs.hoveredEdge >= 0) {
                ifs.hoveredFace = -1;
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
        g_hoveredVertex = ifs.hoveredVertex;
        g_hoveredEdge   = ifs.hoveredEdge;
        g_hoveredFace   = ifs.hoveredFace;
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
            SubjectPacket subj; VectorStack vts; ifs.buildToolVts(subj, vts);
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
        ifs.viewportWindowHovered = false;
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
                SubjectPacket _wlSubj; VectorStack _wlVts; ifs.buildToolVts(_wlSubj, _wlVts);
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
                                import tools.slice.loop_slice_tool : loopSliceHudLabel;
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

                    // Per-cell display-style dropdown (task 0594).
                    //
                    // PERMANENT NEW CHROME, and that is why it took an owner
                    // decision rather than arriving as a side effect of adding
                    // a control. The reference puts this selector in the cell,
                    // so it goes in the cell. It sits beside the view-preset
                    // combo, which is already the cell's one piece of chrome
                    // and already establishes every convention this follows.
                    //
                    // HIDDEN UNDER --test BY PLACEMENT, not by its own flag:
                    // the whole per-cell window loop lives inside main's
                    // `if (!testMode)` block, so no "Viewport##k" window — and
                    // therefore no combo — exists in test mode at all. That is
                    // what makes recorded event logs replay unchanged: the
                    // pixels this widget occupies are not claimed by anything
                    // in the mode the HTTP suite and playback tests run in.
                    //
                    // ROUTED THROUGH THE COMMAND, unlike the view combo above
                    // which writes the camera directly. There are now two ways
                    // to reach this value — here and the Viewport Properties
                    // panel — and two routes to one value are only safe while
                    // both land on one implementation. `viewport.displayStyle`
                    // is that implementation: it validates the name, refuses
                    // what no pass can draw, marks the cell's style as chosen
                    // (so the shipped ortho default stops re-seeding it), and
                    // mirrors into the preferences. A direct field write here
                    // would skip all four.
                    {
                        import display_state : DisplayStyle,
                                               kDisplayStyleOrder,
                                               displayStyleLabel,
                                               displayStyleId;
                        import std.format : format;
                        // Task 1090: was three hand-kept `[3]` arrays here and
                        // three more in ui/panels.d. They are one table in
                        // display_state.d now — see `kDisplayStyleOrder` for
                        // why a `final switch` was not already the gate people
                        // thought it was.
                        int dsIdx = 0;
                        foreach (i, dv; kDisplayStyleOrder)
                            if (dv == _vcell.display.active.style) dsIdx = cast(int)i;

                        // Beside the view combo: its origin is (4,4) and it is
                        // 120 wide, so this starts at 128 with the same 4px
                        // gutter. Narrower than the panel's full-width combo —
                        // this is chrome sitting on top of the user's scene,
                        // and the three labels it must show are short.
                        ImGui.SetCursorPos(ImVec2(4 + 120 + 4, 4));
                        ImGui.SetNextItemWidth(100.0f);
                        bool _dsOpen = ImGui.BeginCombo(
                            "##vpStyle" ~ to!string(k),
                            displayStyleLabel(kDisplayStyleOrder[dsIdx]));
                        // Captured while LastItemData is still the combo
                        // BUTTON, before the popup body is submitted, and with
                        // the same two relax flags the view combo uses — so the
                        // exclusion holds across the whole interaction and not
                        // merely on the closed-combo frame. A new per-cell
                        // widget that forgets this leaks its clicks into
                        // ##vpHit and thence into scene picking.
                        if (ImGui.IsItemHovered(
                                ImGuiHoveredFlags.AllowWhenBlockedByActiveItem |
                                ImGuiHoveredFlags.AllowWhenBlockedByPopup))
                            _cellWidgetHovered = true;
                        if (_dsOpen) {
                            foreach (i, dv; kDisplayStyleOrder) {
                                bool sel = (i == dsIdx);
                                if (ImGui.Selectable(displayStyleLabel(dv), sel)
                                    && uiCommandDelegate !is null)
                                    uiCommandDelegate("viewport.displayStyle",
                                        format(`{"_positional":["%s"],"viewport":%d}`,
                                               displayStyleId(dv), k));
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
                            ifs.viewportWindowHovered = true;
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
                                     || ifs.dragMode != DragMode.None
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
                    ifs.viewportWindowHovered = false;
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
        // WHICH CELLS DRAW THE OVERLAY: every live one. The owner cell gets
        // `Interactive`, all the others a world-derived `Visual` replica.
        //
        // Task 0206 shipped this with a v1 ALLOWLIST — `XfrmTransformTool`,
        // `CommandWrapperTool`, and the no-tool falloff path, the three whose
        // `visualOnly` seam had been wired — and deferred every other tool to
        // a v2 that never came. Task 1650 removed the list: it was an
        // enumeration standing in for a capability, and it was wrong about
        // `EdgeExtendTool` / `EdgeBevelTool`, which COMPOSE a transform
        // wrapper rather than inheriting one. Both casts missed, so in a Quad
        // layout their gizmos appeared only in the cell under the cursor —
        // the owner's dogfood report.
        //
        // The allowlist's premise (that only wired tools are safe) does not
        // survive measurement either: of the 38 `Tool.draw` overrides only 10
        // read `visualOnly`, and 21 of the other 28 write `cachedVp` and/or
        // run a `ToolHandles` cycle unconditionally — including the two that
        // WERE eligible via `CommandWrapperTool`'s subclasses. What actually
        // makes a replica harmless is `overlayDrawOrder` visiting the owner
        // LAST, so its own draw re-pins every one of those writes before the
        // frame ends. See `resolveOverlayMode` in editor_app.d.
        //
        // --test: Single layout ⇒ cellCount == 1 ⇒ overlayDrawOrder returns
        // [activeId] and the Visual branch is never taken, byte-identical to
        // pre-task-0206 behaviour. A test that switches to Quad opts into the
        // multi-cell path, and into rendering every cell (testRendersCell).
        {
            import viewport : DirtyKey, overlayDrawOrder, testRendersCell;
            import image_cache : imagePixelCache;
            import image_plane : collectLivePlanePaths, imagePlaneDigest;
            import tools.transform.xfrm_transform : XfrmTransformTool;
            import tools.common.command_wrapper : CommandWrapperTool;

            // Task 0209 (Quad/Split any-cell input), Phase 4: current rollover
            // ("hot") part on whichever arbiter owns this frame's interaction —
            // mirrors the multiCellEligible dispatch below. The arbiter lives
            // on a DIFFERENT object per case (XfrmTransformTool.toolHandles vs
            // the shared pipeGizmoHost.ownPool(), used by both the wrapper-
            // primitive and no-tool-falloff cases), so app.d scope has no
            // single field to read directly — this small dispatcher is the
            // seam. `hot` is a public int on `ToolHandles` (handles/arbiter.d).
            int currentHotPart() {
                if (auto xf = cast(XfrmTransformTool) activeTool) return xf.hotPart();
                if (auto cw = cast(CommandWrapperTool) activeTool) return pipeGizmoHost.ownPool().hot;
                if (activeTool is null && anyFalloffActive())      return pipeGizmoHost.ownPool().hot;
                return -1;
            }

            auto _dsz = io.DisplaySize;
            float dpiX = (_dsz.x > 0.0f) ? cast(float)ifs.fbW / _dsz.x : 1.0f;
            float dpiY = (_dsz.y > 0.0f) ? cast(float)ifs.fbH / _dsz.y : 1.0f;

            bool forceActive = (activeTool !is null)
                            || (ifs.dragMode != DragMode.None)
                            || anyFalloffActive();

            // Overlay-owner cell: origin cell during a drag, else the HOVERED
            // cell (task 0209 — the arbiter/Test pass now runs where the
            // cursor is, so hover/hit-test/click work in any Quad/Split
            // cell), else the active cell. Task 1650 folded the formula into
            // `ViewportManager.overlayOwnerId` — `inputSnapshot()` held a
            // second copy of it, and the input owner and the overlay owner are
            // the same cell by design. The `--test` answer is unchanged
            // (`activeId`, and also the LAST cell visited).
            int overlayOwner = vpm.overlayOwnerId();

            // Is there an overlay to draw AT ALL? Exactly the pair of branches
            // inside renderViewportSceneToFbo's overlay block, and the only
            // term `resolveOverlayMode` needs besides the owner id.
            //
            // Task 1650 removed the tool-TYPE list that used to gate the
            // non-owner (`Visual`) cells here. See `resolveOverlayMode`'s doc
            // comment in editor_app.d for the defect it caused, and for why
            // `overlayDrawOrder`'s owner-last visitation — not per-tool
            // `visualOnly` discipline — is what makes dropping it safe.
            bool anyOverlay = (activeTool !is null) || anyFalloffActive();

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
                SubjectPacket _osubj; VectorStack _ovts; ifs.buildToolVts(_osubj, _ovts);
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

            // Task 0612 — pixel-cache residency, ONCE per frame, BEFORE the
            // cell loop.
            //
            // Not inside the loop, and above all not inside the draw: the
            // per-cell dirty skip below means a clean frame runs no draw at
            // all, so residency driven from the draw would free a texture on
            // the first still frame and re-decode it from disk on the next
            // camera move — a stb decode per frame during an orbit, while
            // reporting a perfectly healthy residency count. Reconciling
            // against the DOCUMENT's live link set instead makes residency a
            // function of what the document names, which no render decision
            // can perturb. `cache.lookup` in the draw cannot load, by
            // construction.
            //
            // The digest is computed here for the same reason `toolMat` and
            // the overlay stamps are: it is view-independent, so every cell's
            // key gets the same value, and computing it per cell would be
            // three redundant walks of `layers`.
            imagePixelCache().reconcile(collectLivePlanePaths(document));
            // The digest feeds ONLY the interactive dirty-key compare, which
            // `--test` never reaches (Single layout, and `needRender` is
            // `k == activeId` there) — so it is skipped in that build, exactly
            // like the packet-evaluating overlay stamps above. The reconcile
            // above is NOT skipped: residency is real state a test asserts on.
            immutable ulong _planeKey = testMode ? 0
                : imagePlaneDigest(document, imagePixelCache().decodeCount());

            // Snap's per-frame view of the document (task 1780). ONE call,
            // here rather than inside the per-cell pass it was hoisted out of:
            // it reads `document` and nothing else, so a per-cell site did it
            // once per live cell — and only for cells whose DIRTY KEY moved,
            // which no snap-config change ever does. `installSnapState`'s
            // comment has the rest; the placement rule is simply "before
            // anything can draw or pick from these frames, after every event
            // and command this frame has already run".
            installSnapState(app);

            foreach (k; overlayDrawOrder(vpm.cellCount, overlayOwner)) {
                Viewport3D _cv = vpm.views[k];
                // Perf (always-on): the cell-level render decision. The
                // `considered` vs `rendered` PAIR is the point — the dirty-key
                // gate below means a frame with zero draws is normal, not a
                // broken measurement, and only these two counters distinguish
                // "nothing changed" from "the scene stopped drawing".
                g_fc.bumpCellConsidered();

                // Per-cell overlay mode: Interactive for the owner cell,
                // Visual for every other live cell, None when nothing is
                // active (matches the pre-0206 no-op when neither branch
                // inside renderViewportSceneToFbo's overlay block would
                // fire). One implementation, shared with the
                // `/api/viewport/display` dump — see resolveOverlayMode.
                OverlayMode _ovMode = resolveOverlayMode(k, overlayOwner, anyOverlay);
                // Stamp what was DECIDED, for /api/viewport/display to report.
                // Here, not at the resolver: the gate this replaced lived at
                // this call site, so a dump that called the resolver itself
                // would not see a term reintroduced here (measured — see
                // Viewport3D.lastOverlayMode). Before the dirty-key skip: the
                // decision is made whether or not the cell then renders.
                _cv.lastOverlayMode = cast(int)_ovMode;

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

                // --test: the active cell, plus every cell of a MULTI-cell
                // layout. See `viewport.testRendersCell` for why the rule is
                // not just `k == activeId` any more — under the Single layout
                // invariant the two are the same answer, and a test only gets
                // the wider one by switching layout itself.
                bool needRender;
                if (testMode) {
                    needRender = testRendersCell(k, vpm.activeId, vpm.cellCount);
                } else {
                    // Interactive: dirty-key compare (skip if nothing changed).
                    bool _hovK = (k == vpm.hoveredId);
                    if (forceActive && k == overlayOwner) {
                        needRender = true;
                    } else {
                        DirtyKey _newKey;
                        _newKey.view       = vpk.view;
                        _newKey.proj       = vpk.proj;
                        // recorded remainder (1906 §3.5 row 24, §3.6):
                        // `mutationVersion` owns `meshMutVer` and
                        // `GpuMesh.uploadVersion` owns `gpuUploadVer` below.
                        // `DirtyKey` is COMPARED whole (`_newKey != _key`), not
                        // reacted to, so every term has to be a VALUE that can
                        // sit in a struct — which is exactly the shape
                        // `fboSelEpoch` beside it already has: a subscription
                        // materialised into a counter. Note `mesh_dirty`'s own
                        // header cites this key as the precedent for its epochs.
                        // Migrating these two terms would swap one comparable
                        // number for another and buy nothing; what a Position
                        // publish must reach here it already reaches through
                        // `gpuUploadVer` (the VBO is re-uploaded) and `toolMat`.
                        _newKey.meshMutVer = mesh.mutationVersion;
                        _newKey.selEpoch   = fboSelEpoch;
                        _newKey.editMode_k = cast(int)editMode;
                        // Hover state only matters in the hovered cell.
                        _newKey.hovV       = _hovK ? ifs.hoveredVertex : -1;
                        _newKey.hovE       = _hovK ? ifs.hoveredEdge   : -1;
                        _newKey.hovF       = _hovK ? ifs.hoveredFace   : -1;
                        // Task 0647 — see DirtyKey.itemHighlightKey for why
                        // none of the three fields above can carry this. NOT
                        // gated on `_hovK`: the item under the pointer is lit
                        // in EVERY cell, not only the one the pointer is in,
                        // so a cell that gated this term would freeze with a
                        // stale highlight the moment the pointer left it.
                        {
                            import hover_state : g_hoveredItem;
                            import document    : kindInfo;
                            ulong _ih = 0xcbf2_9ce4_8422_2325UL;
                            void _fold(ulong v) {
                                _ih ^= v;
                                _ih *= 0x0000_0100_0000_01b3UL;
                            }
                            _fold(cast(ulong)currentSelType(selTypeOrder));
                            // +1 so the "nothing hovered" -1 folds a value
                            // rather than every bit of a sign-extended ulong.
                            _fold(cast(ulong)(g_hoveredItem + 1));
                            foreach (_lyr; document.layers) {
                                if (_lyr is null) { _fold(0xFFUL); continue; }
                                _fold((_lyr.visible  ? 1UL : 0UL)
                                    | (_lyr.selected ? 2UL : 0UL)
                                    | (kindInfo(_lyr.kind).drawsGeometry ? 4UL : 0UL));
                            }
                            _newKey.itemHighlightKey = _ih;
                        }
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
                        // Task 0559: the display term. Note it is stamped
                        // from `_cv` — THIS cell — not from a frame-level
                        // value like every other term above. Display style is
                        // the first genuinely per-cell render input; sourcing
                        // it from anywhere but the loop variable would make
                        // all four cells share one mode while looking like a
                        // working implementation. It is the RESOLVED plan,
                        // i.e. exactly what renderViewportSceneToFbo consumes
                        // a few lines below, so the key cannot go stale
                        // against a resolution change (see DirtyKey doc).
                        _newKey.planActive   = resolveDrawPlan(_cv.display, false);
                        _newKey.planBackdrop = resolveDrawPlan(_cv.display, true);
                        // Task 0612: the reference-image term. Shared, like
                        // `toolMat` and the overlay stamps — plane state is
                        // view-independent, and WHICH cell shows a plane is a
                        // function of that cell's preset, which moves its
                        // camera and is therefore already carried by
                        // view/proj above.
                        _newKey.imagePlaneKey = _planeKey;
                        // Task 1090: the current-weight-map term. Shared, and
                        // read through the SAME accessor the render pass
                        // calls, so the key cannot key on a different name
                        // than the one that was drawn. See
                        // DirtyKey.weightMapKey for why nothing above carries
                        // it and for what this term cannot be tested against.
                        {
                            import weightmap_view : currentWeightMapKey;
                            _newKey.weightMapKey = currentWeightMapKey();
                        }
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
                    g_fc.bumpCellRendered();
                    renderViewportSceneToFbo(app, _cv, vpk, _ovMode,
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
                int _dY0 = ifs.fbH - (layout.vpY + layout.vpH);
                int _dY1 = ifs.fbH - layout.vpY;
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
            glViewport(0, 0, ifs.fbW, ifs.fbH);
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
        g_fc.endFrame();

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
