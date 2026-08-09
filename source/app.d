import bindbc.sdl;
import bindbc.opengl;
import std.string : toStringz;
import std.stdio : writeln, writefln, File, stderr;
import std.math : tan;
import std.conv;
import std.json : JSONValue, JSONType;

// HTTP server module
import http_server;
import gl_thread_guard : markMainThread;
import log : logInfo, logWarn;
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

// Which page of the Tool Properties panel is showing. 0 = "Main" (the active
// tool's properties plus every pipe stage's collapsible section, exactly the
// single column this panel has always been); 1 = "Snapping". Module scope
// because the panel is rebuilt from scratch every frame and the choice has to
// outlive the frame that made it.
private enum int kToolPropsTabMain      = 0;
private enum int kToolPropsTabSnapping  = 1;
private __gshared int g_toolPropsTab = kToolPropsTabMain;
import commands.ui.layer_list      : UiLayerListCommand, g_layerListShown;
import commands.ui.image_list      : UiImageListCommand, g_imageListShown;
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
import registration : registerTools, registerCommands;
import http_providers : wireHttpProviders;
import shortcuts;
import buttonset;
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

enum DragMode { None, Orbit, Zoom, Pan, Roll, Select, SelectAdd, SelectRemove }

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
// the UI-panel block now fully relocated to source/ui/panels.d). edgeKey
// also has a call site here, in the snap-frame JIT install path, so it is
// imported back; countSelected has no app.d-side reference (Phase 7 cleanup).
import editor_app : edgeKey;

// A broken stage form degrades to the legacy drawProvider every frame; the
// log service's once-gate keeps the diagnostic to a single line per stage
// instead of per-frame spam.
private void warnStageFormOnce(string stageId, string msg) {
    import log : logWarnOnce;
    logWarnOnce("forms", stageId,
                "stage form for '" ~ stageId ~
                "' failed to draw; falling back to legacy panel: " ~ msg);
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

    // `thickLineFragSrc`, not `fragmentShaderSrc`: the line path antialiases
    // analytically and needs the geometry stage's coverage varying, which the
    // regular fragment source cannot declare (it has no geometry stage to
    // supply it). Same uniform contract, so `initThickLineProgram`'s
    // `seedSharedFragUniforms` still covers it.
    GLuint thickLineProgram = createProgramWithGeom(vertexShaderSrc, thickLineGeomSrc, thickLineFragSrc);
    scope(exit) glDeleteProgram(thickLineProgram);
    initThickLineProgram(thickLineProgram, fbW, fbH);

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
    import document : Document, primaryModelSpaceResolver, primaryModelSpace;
    Document document = Document.bootstrap(makeCube());
    ref Mesh mesh() { return document.activeMeshRef(); }
    // Task 0617 — install the primary-layer ModelSpace resolver (mirrors
    // `activeMeshResolver` right below): every picking entry point that
    // needs "the current primary layer's transform" but has no `Document`
    // of its own (http_providers.d's HTTP-bridged closures,
    // tools/edit/topology_pen.d's TopologyPenTool) resolves it through
    // `primaryModelSpace()` rather than a duplicated formula. app.d's own
    // call sites below use the same free function — one accessor, not two.
    primaryModelSpaceResolver = () => document.primary.xform.modelSpace();
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
    // Bit-transfer dedup: serviced bits move OUT of `pendingChanges_` into
    // the `displayEnsured_` shadow word (owner-tagged by mesh address), so
    //   • N readers after one mutation refresh ONCE, not N times (a replayed
    //     batch of motion events after an undo would otherwise re-upload +
    //     reproject per event), and
    //   • the flush-site upload skips bits the guard already serviced — no
    //     double upload on command+pick frames.
    // The frame drain ORs the shadow back into the aggregated `meshFlags`
    // (then zeroes it), so the flush subscribers (subpatch gate, pick-cache
    // block, gpu_select, symmetry/snap) still receive FULL flags; the debug
    // MISSED-PUBLISHER check counts the shadow as pending for its owner.
    //
    // Multi-layer: the guard only ever services the ACTIVE mesh (`mesh()`),
    // so the shadow word is single-owner by construction. If the active
    // layer switches mid-frame while bits are parked (a layer.select between
    // two HTTP requests serviced in one tick), the parked bits are returned
    // to their owner's `pendingChanges_` first — the drain aggregates across
    // ALL layers, so nothing is lost; only the once-per-mutation dedup
    // restarts (and `refreshDisplay`'s own active-mesh gate keeps a
    // now-background owner from ever being re-uploaded).
    uint  displayEnsured_     = 0;
    Mesh* displayEnsuredMesh_ = null;
    // A5 (post-gate fix): while the transform family drags, the VBO is
    // tool-owned (baseline + live u_model) — re-uploading LIVE verts would
    // double-apply the drag delta for any reader that renders with the tool
    // matrix. Late-bound predicate (lifecycleRecordHook pattern: null until
    // wired after `activeTool` is declared below); when it fires, readers
    // keep the pre-bus mid-drag semantics (VBO as the tool left it) and the
    // flags stay pending for the frame drain.
    bool delegate() displayVboOwnedByTool_ = null;
    void ensureDisplayCurrent() {
        import display_sync : refreshDisplay, DisplayRefreshMask;
        if (displayVboOwnedByTool_ !is null && displayVboOwnedByTool_()) return;
        Mesh* am = &mesh();
        if (displayEnsuredMesh_ !is am && displayEnsured_ != 0) {
            displayEnsuredMesh_.pendingChanges_ |= displayEnsured_;
            displayEnsured_ = 0;
        }
        const uint f = am.pendingChanges_ & DisplayRefreshMask;
        if (f) {
            refreshDisplay(am, &gpu, &vertexCache(), &edgeCache(), &faceCache());
            displayEnsured_    |= f;
            displayEnsuredMesh_ = am;
            am.pendingChanges_ &= ~f;
        }
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
        import toolpipe.stages.constrain     : ConstrainStage;
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
                case "constrain":
                    // Topology-pen P0 (REV-2): a tool that composes CONS
                    // transiently (TopologyPenTool enabling CONS+Point on
                    // activate() without locking it) cleanly reverts on tool
                    // switch; an explicit user `tool.pipe.attr constrain ...`
                    // lock (userLocked) survives, same funnel as actionCenter/axis.
                    if (auto cs = cast(ConstrainStage)s)
                        cs.resetTransient();
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

    // EditSession — the single driver of the Tool session protocol (task
    // 0428). DECLARED here so the nested setActiveTool below can reference it
    // lexically; CONSTRUCTED at the ToolHost block further down (`history`
    // exists only from there). Null until wired — same pattern as
    // lifecycleRecordHook above; users that can run pre-wiring guard on
    // non-null.
    import edit_session : EditSession;
    EditSession session;

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
    // RecordMode: relocated verbatim to editor_app.d's module level (app.d
    // decomp phase B) so EditorApp's applyOrRefire field can name the type;
    // resolves here via `import editor_app;`.
    void applyOrRefire(Command cmd, RecordMode mode, string throwMsg) {
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
            if (!history.fire(cmd) && throwMsg !is null)
                throw new Exception(failMsg());
        } else if (cmd.apply()) {
            final switch (mode) {
                case RecordMode.Record:     history.record(cmd);           break;
                case RecordMode.Coalescing: history.recordCoalescing(cmd); break;
            }
        } else if (throwMsg !is null) {
            throw new Exception(failMsg());
        }
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
        if (flags & (HistoryFlags.InSession | HistoryFlags.Refire)) return;

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
    // Unsaved-changes quit confirmation (task 0434). Same pendingOpen→OpenPopup
    // convention as the AI3D / Remesh modals. quitAfterSave defers the exit
    // decision until the frame's Save has flushed (a cancelled Save dialog
    // leaves the document dirty ⇒ the quit is aborted). lastWindowTitle caches
    // the last string handed to SDL so the title is only re-set when it changes.
    bool   quitConfirmOpen;
    bool   quitConfirmPending;
    bool   quitAfterSave;
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
    // Close-requested flag (task 0434). Set by SDL_QUIT (window [X]) and by the
    // file.quit command (Ctrl+Q / File→Quit); drained once per frame by the
    // quit-guard, which either prompts (unsaved changes) or clears `running`.
    bool quitRequested = false;

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
    app.activeToolPtr       = &activeTool;
    // A5: wire the guard's tool-owns-VBO predicate now that `activeTool`
    // is lexically visible (the guard itself is declared far earlier).
    displayVboOwnedByTool_  = () => activeTool !is null && activeTool.isDragging();
    app.runningPtr          = &running;
    app.quitRequestedPtr    = &quitRequested;
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
    app.quitConfirmOpenPtr            = &quitConfirmOpen;
    app.quitConfirmPendingPtr         = &quitConfirmPending;
    app.quitAfterSavePtr              = &quitAfterSave;
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
    // ---------------------------------------------------------------------
    // HTTP endpoint wiring (all /api providers + handlers, ~2410 lines) --
    // moved VERBATIM to source/http_providers.d's wireHttpProviders (app.d
    // decomp, phase B; same `with (app)` seam as 0415's registration.d and
    // 0419's ui/panels.d). The CALL sits right after the task-0419 LATE
    // ctx-wiring below, so every EditorApp field the moved block reads is
    // already wired when the closures are built.
    // ---------------------------------------------------------------------

    int lastMouseX, lastMouseY;

    // ---- Trackball momentum spin (task 0582) -------------------------------
    // The camera whose trackball drag is in flight, captured on the press.
    // Held rather than re-derived because the release CANNOT re-derive it:
    // `vpm.dragOriginId` is cleared in the event router BEFORE the button-up
    // reaches its handler, so `originCamera()` there is whichever cell is
    // active — the same trap `View.trackballCancel`'s doc records. Null
    // whenever no trackball drag is in flight, which is always for a user who
    // has not switched the gesture on.
    View tbSpinCam = null;
    // Is ANY camera momentum spin? The per-frame tick's whole guard: false for
    // every frame of every session that never uses the gesture, so the cost of
    // this feature to everyone else is one bool test per frame — no clock read,
    // no walk over the cells. It is self-correcting rather than a counter that
    // must be kept balanced: the sweep below recomputes it from the cameras it
    // just ticked, so the worst a stale `true` can cost is one extra sweep.
    bool anySpinning = false;

    // The cooked 2D event, and the bookkeeping behind it. `gestureTrack` is
    // advanced once per SDL mouse event at the TOP of each of the three
    // mouse handlers (see GestureTrack.event's doc for why the placement is
    // load-bearing); `gestureSlot` is the storage buildToolVts publishes
    // from, and it lives out here — not as a local inside buildToolVts —
    // because VectorStack stores POINTERS and the stack it fills outlives
    // the call (every caller holds its own `vts` across the dispatch that
    // follows). main()'s frame lives for the whole run, exactly like the
    // other bookkeeping above it.
    //
    // NOTHING READS THE PACKET. It is published so the shape exists at the
    // one place a gesture's pixel state is known; migrating the tools that
    // keep their own last-pixel bookkeeping onto it is a separate step, one
    // tool per commit, each under its own drag test.
    GestureTrack  gestureTrack;
    GesturePacket gestureSlot;

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
    // undoable.
    //
    // `throwMsg` stays null here (a UI click has no caller to throw at), so a
    // command that declines still no-ops — but NOT SILENTLY when it said why
    // (task 0616 review B1). `Command.refusalReason()` is "" for every command
    // that does not override it and is reset at the top of every overrider's
    // apply(), so a non-empty value here means exactly "the call I just made
    // declined, and here is the sentence to show". A decline WITHOUT a reason
    // is still silent, which is what keeps a cancelled file dialog quiet —
    // see ui/command_notice.d.
    void runCommand(Command cmd) {
        import ui.command_notice : commandNoticeText;
        if (cmd is null) return;
        applyOrRefire(cmd, RecordMode.Record, null);
        auto notice = commandNoticeText(cmd.label(), cmd.refusalReason());
        if (notice.length) {
            noticeText    = notice;
            noticeOpen    = true;
            noticePending = true;
        }
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
    void buildToolVts(out SubjectPacket subj, ref VectorStack vts,
                      int curX = -1, int curY = -1, bool curValid = false,
                      GesturePacket gest = GesturePacket.init) {
        subj.mesh             = &mesh();
        subj.editMode         = editMode;
        subj.selType          = currentSelType(selTypeOrder);
        subj.viewport         = vpm.inputSnapshot();
        subj.cursorX          = curX;
        subj.cursorY          = curY;
        subj.cursorValid      = curValid;
        vts.put(&subj);
        gestureSlot = gest;
        vts.put(&gestureSlot);
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
    // app.commandHandlerDelegate / app.formsInteractiveDispatch are NOT
    // wired here anymore (their pre-move `= commandHandlerDelegate;` lines
    // copied a still-null local): the moved HTTP block ASSIGNS both through
    // wireHttpProviders's `ref EditorApp app` parameter, and the call site
    // below syncs main()'s same-named locals back from `app`.

    app.runCommand           = cast(void delegate(Command))&runCommand;
    app.tryOpenArgsDialog    = cast(bool delegate(string))&tryOpenArgsDialog;
    app.activateToolById     = cast(void delegate(string))&activateToolById;
    // NOT a bare same-arity cast like its neighbours above: buildToolVts
    // grew 3 trailing-default cursor params (topology-pen P0, REV-1) and
    // later a 4th for the cooked 2D event, but EditorApp.buildToolVts's
    // field type (editor_app.d) is still the
    // original 2-parameter delegate — every existing caller through that
    // field (ui/panels.d's renderViewportSceneToFbo, a per-frame render-
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
    app.buildToolVts = (out SubjectPacket s, ref VectorStack v) { buildToolVts(s, v); };
    app.anyFalloffActive     = cast(bool delegate())&anyFalloffActive;
    app.rebuildLoopHoverMask = cast(const(bool)[] delegate(int))&rebuildLoopHoverMask;

    // Phase-B ctx wiring (source/http_providers.d): same rules as the blocks
    // above. Pointer-backed selTypeOrder (mutated via .touch() on both
    // sides); by-value class refs bvhPick/stepTrace/session (each assigned
    // exactly once, all before this point); hook delegates for main()'s
    // nested functions. app.replayUndoEntry is NOT wired here -- the moved
    // block ASSIGNS it through the `ref EditorApp app` parameter (synced
    // back below, next to commandHandlerDelegate).
    app.selTypeOrderPtr      = &selTypeOrder;
    app.bvhPick              = bvhPick;
    app.stepTrace            = stepTrace;
    app.session              = session;
    app.ensureDisplayCurrent = cast(void delegate())&ensureDisplayCurrent;
    app.derivedEditMode      = cast(EditMode delegate())&derivedEditMode;
    app.formsInteractiveLatchPtr = &formsInteractiveLatch;
    app.applyOrRefire        = &applyOrRefire;

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
    commandHandlerDelegate   = app.commandHandlerDelegate;
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
                // Toggle subpatch flag. Scope is MODE-AWARE (parity): the face
                // selection is honored ONLY while Polygon is the current
                // selection type — in edge/vertex/item modes a persisted face
                // selection is ignored and the toggle applies to the WHOLE
                // model (matches the reference editor, which drops the polygon
                // selection's authority outside polygon mode). Whole-model when
                // nothing is face-selected in polygon mode too. The preview
                // rebuilds next frame via mutationVersion bumped inside
                // setSubpatch.
                mesh.syncSelection();
                bool scoped = currentSelType(selTypeOrder) == SelType.Polygon
                              && mesh.hasAnySelectedFaces();
                foreach (fi; 0 .. mesh.faces.length) {
                    if (scoped && !mesh.isFaceSelected(fi))
                        continue;
                    mesh.setSubpatch(fi, !mesh.isFaceSubpatch(fi));
                }
                break;
            }
            case SDLK_MINUS:
                stepGizmoHandleScale(-1);
                break;
            case SDLK_EQUALS:
                stepGizmoHandleScale(+1);
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
        // Cook this event ONCE, before any dispatch: this handler reaches
        // buildToolVts from four different branches (RMB-to-tool, the
        // apply-and-continue re-arm, LMB-to-tool, the no-tool gizmo claim)
        // and they must not disagree about what the event was. A press also
        // re-anchors the gesture, which has to happen before the first
        // branch that could consume the event and return.
        GesturePacket gest = gestureTrack.event(GesturePacket.Phase.Down, btn.x, btn.y);
        // A PRESS CANCELS A RUNNING MOMENTUM SPIN (task 0582), before anything
        // else can consume this event and return. The reference re-arms the
        // spin with a rate of zero on its navigation press, which is the same
        // observable; widening it from that one chord to any press over
        // the cell is a port decision, and it can only ever stop the spin
        // SOONER — a camera that kept coasting through a click would be a bug
        // report, not parity. Cheap enough to be unconditional: `spinCancel`
        // on a camera that is not spinning writes three fields nobody reads.
        vpm.originCamera().spinCancel();
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
                SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts, btn.x, btn.y, true, gest);
                if (activeTool.onMouseButtonDown(btn, vts)) return;
            }
            rmbDragging = true;
            rmbPath = [ImVec2(cast(float)btn.x, cast(float)btn.y)];
            // RMB lasso mutates selection on mouseUp; snapshot now.
            beginInteractiveSelEdit();
            return;
        }
        if (activeTool) {
            // Framework "apply and continue" (the reference editor's apply-
            // and-continue gesture, task 0461): a Shift+LMB while the active
            // tool holds an uncommitted edit commits it as its own undo entry
            // and re-arms the SAME tool session in place (no drop — ACEN/AXIS/
            // pipe state persist): commit-into-history then re-arm-in-place.
            //
            // COMBINED GESTURE: after the commit+rearm, THIS same Shift+LMB is
            // forwarded to the re-armed tool as a fresh gesture-start, so a
            // Shift+click+drag applies the old edit AND immediately hauls the
            // new one in one motion — no lift between operations (a "series of
            // bevels"). Shift is masked for the forwarded down because the
            // opted-in tools reject a raw Shift+LMB (reserving it for sel-add);
            // masking makes them treat it as a plain gesture-start. The forward
            // reads the live modifier state, so the mask must go through the
            // real SDL modstate (restored immediately after via scope(exit)).
            //
            // When the active tool has NO open edit, or opts out of in-place
            // commit (transform tools already commit per gesture),
            // applyAndContinue() returns false and this Shift+LMB falls through
            // unchanged to the selection-add path below — no edit is ever lost.
            // Alt/Ctrl chords stay excluded (camera / axis-lock).
            if (btn.button == SDL_BUTTON_LEFT && viewportInputAllowed()
                && (SDL_GetModState() & KMOD_SHIFT)
                && !(SDL_GetModState() & (KMOD_ALT | KMOD_CTRL))
                && session.applyAndContinue()) {
                SDL_Keymod savedMods = SDL_GetModState();
                SDL_SetModState(cast(SDL_Keymod)(savedMods & ~KMOD_SHIFT));
                scope(exit) SDL_SetModState(savedMods);
                SubjectPacket subjR; VectorStack vtsR; buildToolVts(subjR, vtsR, btn.x, btn.y, true, gest);
                activeTool.onMouseButtonDown(btn, vtsR);
                return;
            }
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
            SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts, btn.x, btn.y, true, gest);
            if (activeTool.onMouseButtonDown(btn, vts)) return;
        }
        // No tool, but the host's falloff gizmo may own this click (drag an
        // endpoint). Must run BEFORE the bare-LMB selection-clear below so a
        // handle grab isn't treated as a deselect. Skip alt/ctrl chords (camera).
        if (activeTool is null && btn.button == SDL_BUTTON_LEFT
            && !(SDL_GetModState() & (KMOD_ALT | KMOD_CTRL))) {
            import toolpipe.packets : FalloffPacket;
            SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts, btn.x, btn.y, true, gest);
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
        // Alt+MMB — camera BANK, the reference's own dedicated roll chord.
        // Placed AFTER the active-tool dispatch above so a tool that owns
        // the middle button (Slice) keeps first refusal, exactly as the
        // Alt+LMB camera chords do. Bare MMB is untouched.
        if (btn.button == SDL_BUTTON_MIDDLE) {
            SDL_Keymod mmods = SDL_GetModState();
            if ((mmods & KMOD_ALT) && !(mmods & KMOD_SHIFT) && !(mmods & KMOD_CTRL)) {
                dragMode   = DragMode.Roll;
                lastMouseX = btn.x;
                lastMouseY = btn.y;
            }
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

            // Trackball arming (task 0573). The trackball's rotation depends on
            // WHERE the press landed in the pane, not only on how far the
            // cursor has since travelled, so the absolute press pixel has to be
            // captured here on the DOWN — the motion path only ever sees a
            // delta. Armed only when the gesture would actually run it, which
            // is off by default: a user who has not switched the trackball on
            // reaches exactly the code they reached before.
            if (dragMode == DragMode.Orbit && !vpm.originIsOrtho()
                && vpm.originCamera().trackballActive()) {
                vpm.originCamera().trackballDown(btn.x, btn.y);
                // Remember WHICH camera, for the release that arms the spin.
                tbSpinCam = vpm.originCamera();
            }

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
        // Cooked once, before dispatch — see handleMouseButtonDown. A
        // release does NOT re-anchor: the press pixel this packet carries is
        // still the one the gesture started from, which is the whole point
        // of the cumulative form.
        GesturePacket gest = gestureTrack.event(GesturePacket.Phase.Up, btn.x, btn.y);
        // Arm the settling spin (task 0582), FIRST — this handler returns early
        // from half a dozen branches below (the three falloff RMB paths, a
        // tool's own gesture end, the host gizmo's), and a release that took
        // one of them is still a release. `tbSpinCam` is non-null only when
        // this press armed a trackball drag, so the whole block is skipped on
        // every other button-up in the editor.
        if (btn.button == SDL_BUTTON_LEFT && tbSpinCam !is null) {
            tbSpinCam.trackballRelease(SDL_GetTicks());
            anySpinning = anySpinning || tbSpinCam.spinning();
            tbSpinCam = null;
        }
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
                SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts, btn.x, btn.y, true, gest);
                if (activeTool.onMouseButtonUp(btn, vts)) return;
            }
            if (rmbPath.length >= 3) {
                // ---------------------------------------------------------
                // Task 0617 Stage 3 (doc/picking_item_transform_plan.md):
                // this block used to project RAW LOCAL vertices while Stage 1
                // made the GPU occlusion probes below (`elementVisibility`,
                // `endpointVisibleEdgeFbo`) render at the layer's DRAWN pose
                // — a split-brain that made edge/vertex/face lasso select
                // NOTHING on a primary with a non-identity `ItemXform` (the
                // two tests agreed only at identity). Fixed by composing the
                // item transform into exactly ONE local-space viewport
                // (`vpLocal`, below) and routing every geometry test in this
                // block through it. The occlusion probes and the
                // `symmetricSelect*` calls keep seeing the WORLD viewport
                // (`vpWorld`) unmodified: they compose `ms` internally, or
                // anchor on local mesh coordinates themselves, so handing
                // them `vpLocal` would apply the item transform twice (R10).
                // ---------------------------------------------------------
                SDL_Keymod mods = SDL_GetModState();
                bool shift = (mods & KMOD_SHIFT) != 0;
                bool ctrl  = (mods & KMOD_CTRL)  != 0;
                const ModelSpace ms      = primaryModelSpace();
                Viewport         vpWorld = vpm.originSnapshot();
                const Viewport   vpLocal = projectionSpace(vpWorld, ms);
                float[] pxs = new float[](rmbPath.length);
                float[] pys = new float[](rmbPath.length);
                foreach (i, p; rmbPath) { pxs[i] = p.x; pys[i] = p.y; }
                // The only two projectors and the only front-facing test
                // permitted in this block — every local-space geometry test
                // below must go through one of these three, never a bare
                // `projectToWindow`/`dot(...)` against vpLocal directly.
                bool insideLasso(Vec3 vLocal) {
                    float sx, sy, ndcZ;
                    if (!projectToWindow(vLocal, vpLocal, sx, sy, ndcZ)) return false;
                    return pointInPolygon2D(sx, sy, pxs, pys);
                }
                bool projLocal(Vec3 vLocal, out float sx, out float sy) {
                    float ndcZ;
                    return projectToWindow(vLocal, vpLocal, sx, sy, ndcZ);
                }
                bool frontFacing(Vec3 nLocal, Vec3 p0Local) {
                    // No `ms.mirrored` correction here (task 0617 follow-up:
                    // the flip that used to live on this line was WRONG and
                    // has been removed — see math.d's `ModelSpace.mirrored`
                    // doc comment for the identity that replaces §3.7/§3.8).
                    // `vpLocal.eye` is already `M⁻¹·eyeWorld`
                    // (`projectionSpace`), so `dot(nLocal, p0Local -
                    // vpLocal.eye)` already answers "is the eye on the
                    // outward side" correctly for ANY invertible `M`,
                    // mirrored or not — XOR-ing `ms.mirrored` on top flipped
                    // a right answer wrong under a mirror.
                    bool backFacing = dot(nLocal, p0Local - vpLocal.eye) >= 0;
                    return !backFacing;
                }
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
                ensureDisplayCurrent(); // mid-batch pull-guard: FBO readback below renders from the VBO
                // vpWorld + ms — gpuSelect composes `ms` internally (R10).
                bool[] gpuVisible = gpuSelect.elementVisibility(
                    vbMode, mesh, gpu, vpWorld, ms);

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
                            // Hide, branch 1/6 (task 0613 S4). It goes HERE,
                            // beside the identity the branch already resolved
                            // — the three closures above (`insideLasso`,
                            // `projLocal`, `frontFacing`) take a POINT, not an
                            // element, so they cannot know what is hidden.
                            // FACES keep their VBO slot (faceTriCount == 0,
                            // R3), so `gpuVisible[fi]` below stays correctly
                            // keyed and only this guard is needed.
                            if (mesh.isFaceHidden(cage)) continue;
                            auto face = pv.faces[fi];
                            if (face.length < 3) { cageAllInside[cage] = false; continue; }
                            Vec3 fn = pv.faceNormal(cast(uint)fi);
                            if (!frontFacing(fn, pv.vertices[face[0]])) continue;
                            // GPU visibility per PREVIEW face index.
                            // faceIdVbo writes preview-face indices,
                            // so `gpuVisible[fi]` is the right key.
                            if (gpuVisible !is null
                                && fi < gpuVisible.length
                                && !gpuVisible[fi]) continue;
                            cageVisited[cage] = true;
                            foreach (vi; face) {
                                if (!insideLasso(pv.vertices[vi])) {
                                    cageAllInside[cage] = false;
                                    break;
                                }
                            }
                        }
                        foreach (fi; 0 .. mesh.faces.length) {
                            if (!cageVisited[fi] || !cageAllInside[fi]) continue;
                            symmetricSelectFace(&mesh(), vpWorld, editMode,
                                                cast(int)fi, /*deselect=*/ctrl);
                        }
                    } else {
                        // Cage mode — VBO entry IS cage face. faceIdVbo
                        // writes cage face indices; `gpuVisible[fi]`
                        // is direct.
                        foreach (fi; 0 .. mesh.faces.length) {
                            uint[] face = mesh.faces[fi];
                            if (face.length < 3) continue;
                            // Hide, branch 2/6. Same reasoning as the preview
                            // branch above, and the same key: a hidden face
                            // keeps its slot, so `fi` still indexes
                            // `gpuVisible` correctly here.
                            if (mesh.isFaceHidden(fi)) continue;
                            Vec3 fn = mesh.faceNormal(cast(uint)fi);
                            if (!frontFacing(fn, mesh.vertices[face[0]])) continue;
                            if (gpuVisible !is null
                                && fi < gpuVisible.length
                                && !gpuVisible[fi]) continue;
                            bool allInside = true;
                            foreach (vi; face) {
                                if (!insideLasso(mesh.vertices[vi])) {
                                    allInside = false;
                                    break;
                                }
                            }
                            if (allInside) {
                                symmetricSelectFace(&mesh(), vpWorld, editMode,
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
                            // Hide, branch 3/6 — and note it sits BEFORE the
                            // `++k`, not after. `k` is a VBO-slot counter and
                            // `GpuMesh.upload` skips hidden vertices when it
                            // fills that buffer (S3), so a guard placed after
                            // the increment would leave `k` counting slots
                            // that do not exist and shift every `gpuVisible`
                            // lookup past the first hidden vertex. The
                            // predicate is the PREVIEW mesh's, byte-for-byte
                            // the one `upload` used (subpatch_osd stamps the
                            // preview's Hide planes from the cage), because
                            // matching the buffer is what keeps `k` honest.
                            if (pv.isVertexHidden(pi)) continue;
                            scope(exit) ++k;
                            if (gpuVisible !is null
                                && k < gpuVisible.length
                                && !gpuVisible[k]) continue;
                            if (insideLasso(pv.vertices[pi])) {
                                symmetricSelectVertex(&mesh(), vpWorld, editMode,
                                                      cast(int)cage, /*deselect=*/ctrl);
                            }
                        }
                    } else {
                        // Hide, branch 4/6, and it is NOT just a `continue`:
                        // this branch used to key `gpuVisible` by CAGE index,
                        // which was right only while VBO slot == cage vertex.
                        // S3 broke that identity — `upload` skips hidden
                        // vertices — so the mask needs a SLOT key. `k` counts
                        // kept vertices in the same order and by the same
                        // predicate `upload` uses, which is exactly the shape
                        // the preview branch above already had (R11 part 2).
                        // Hiding vertex 0 is what tells the two apart: with the
                        // cage key every later lookup reads its neighbour's
                        // visibility, which selects a set of the RIGHT SIZE and
                        // the WRONG MEMBERS.
                        size_t k = 0;
                        foreach (vi; 0 .. mesh.vertices.length) {
                            if (mesh.isVertexHidden(vi)) continue;
                            scope(exit) ++k;
                            if (gpuVisible !is null
                                && k < gpuVisible.length
                                && !gpuVisible[k]) continue;
                            if (insideLasso(mesh.vertices[vi])) {
                                symmetricSelectVertex(&mesh(), vpWorld, editMode,
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
                            // Hide, branch 5/6 — before the `++k`, for the
                            // reason spelled out in the vertex/preview branch
                            // above: `k` is a VBO segment index and `upload`
                            // skips hidden edges when it fills that buffer.
                            if (pv.isEdgeHidden(pei)) continue;
                            scope(exit) ++k;
                            if (gpuVisible !is null
                                && k < gpuVisible.length
                                && !gpuVisible[k]) continue;
                            uint a = pv.edges[pei][0], b = pv.edges[pei][1];
                            cageVisited[cage] = true;
                            float sxa, sya, sxb, syb;
                            if (!projLocal(pv.vertices[a], sxa, sya) ||
                                !projLocal(pv.vertices[b], sxb, syb) ||
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
                                // vpWorld + ms — see the elementVisibility call above (R10).
                                if (!gpuSelect.endpointVisibleEdgeFbo(
                                        cast(int)lround(sxa), cast(int)lround(sya),
                                        gpu, vpWorld, ms) ||
                                    !gpuSelect.endpointVisibleEdgeFbo(
                                        cast(int)lround(sxb), cast(int)lround(syb),
                                        gpu, vpWorld, ms)) {
                                    cageAllInside[cage] = false;
                                }
                            }
                        }
                        foreach (ei; 0 .. mesh.edges.length) {
                            if (!cageVisited[ei] || !cageAllInside[ei]) continue;
                            symmetricSelectEdge(&mesh(), vpWorld, editMode,
                                                cast(int)ei, /*deselect=*/ctrl);
                        }
                    } else {
                        // Hide, branch 6/6 — the edge twin of branch 4: skip
                        // hidden edges AND re-key `gpuVisible` from the cage
                        // index to the VBO segment index, which stopped being
                        // the same number when `upload` started dropping
                        // hidden edges (R11 part 2).
                        size_t k = 0;
                        foreach (ei; 0 .. mesh.edges.length) {
                            if (mesh.isEdgeHidden(ei)) continue;
                            scope(exit) ++k;
                            if (gpuVisible !is null
                                && k < gpuVisible.length
                                && !gpuVisible[k]) continue;
                            uint a = mesh.edges[ei][0], b = mesh.edges[ei][1];
                            float sxa, sya, sxb, syb;
                            if (!projLocal(mesh.vertices[a], sxa, sya)) continue;
                            if (!projLocal(mesh.vertices[b], sxb, syb)) continue;
                            if (pointInPolygon2D(sxa, sya, pxs, pys) &&
                                pointInPolygon2D(sxb, syb, pxs, pys)) {
                                // STRICT: both endpoints must be un-occluded in the
                                // Edge ID-FBO (depth-pre-pass baked). Probe a small
                                // window around each projected endpoint; reject the
                                // edge if either window has no surviving edge pixel.
                                // This is intentionally stricter than click (which
                                // only requires a surviving pixel near the cursor).
                                import std.math : lround;
                                // vpWorld + ms — see the elementVisibility call above (R10).
                                if (!gpuSelect.endpointVisibleEdgeFbo(
                                        cast(int)lround(sxa), cast(int)lround(sya),
                                        gpu, vpWorld, ms)) continue;
                                if (!gpuSelect.endpointVisibleEdgeFbo(
                                        cast(int)lround(sxb), cast(int)lround(syb),
                                        gpu, vpWorld, ms)) continue;
                                symmetricSelectEdge(&mesh(), vpWorld, editMode,
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
            SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts, btn.x, btn.y, true, gest);
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
        // MMB up ends a bank drag. Guarded on the mode so a tool's own
        // middle-button gesture (which never arms Roll) is not disturbed.
        if (btn.button == SDL_BUTTON_MIDDLE && dragMode == DragMode.Roll)
            dragMode = DragMode.None;
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
        // Cooked once, before dispatch — see handleMouseButtonDown. This
        // handler returns early from half a dozen branches (the three
        // falloff RMB drags, a tool that consumed the motion, the gizmo
        // drag, `dragMode == None`), so cooking here is also what keeps the
        // previous-event pixel advancing on every event rather than only on
        // the ones that reach the bottom.
        GesturePacket gest = gestureTrack.event(GesturePacket.Phase.Move, mot.x, mot.y);
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
            SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts, mot.x, mot.y, true, gest);
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
                   : (dragMode == DragMode.Roll)      ? (alt && !shift && !ctrl)
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
        if      (dragMode == DragMode.Orbit && !vpm.originIsOrtho()) {
            // Two implementations of one drag, chosen by a preference. The
            // trackball reads the ABSOLUTE cursor (its arc is the angle between
            // where the press and the cursor sit on a virtual ball, so the same
            // delta rotates differently depending on where in the pane it
            // happens); the two-axis orbit reads the delta. With the option off
            // — the shipped default — this is the identical `orbit(dx, dy)`
            // call this line has always made, reached past one bool read.
            // The clock is the EVENT's, not the frame's, and the difference
            // is the whole reason this is a parameter. It is used for one
            // thing — dividing the last step's arc into a release rate — and
            // the honest divisor is the interval between the two MOTIONS, which
            // is what SDL stamps on the event when it arrives. Reading a clock
            // here instead would divide by the interval between the FRAMES that
            // happened to process them: identical for live input, and for a
            // replay a measurement of how loaded the machine is. A replayed
            // event carries the stamp its log gave it (0 unless the log says
            // otherwise), and two events sharing a stamp leave no spin — so a
            // log that never recorded when things happened reports, correctly,
            // that it does not know. See `EventPlayer`'s `ts` field.
            if (vpm.originCamera().trackballActive())
                vpm.originCamera().trackballMove(mot.x, mot.y, mot.timestamp);
            else
                vpm.originCamera().orbit(dx, dy);
        }
        // Bank writes the ORIGIN cell's own camera, mirroring orbit exactly
        // (orbit does not redirect through a rotate-owner either). Whatever
        // coupling orbit grows, bank inherits by construction.
        else if (dragMode == DragMode.Roll)  vpm.originCamera().rollBy(dx);
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

    // pickVertices / pickEdges share one body — they differ only in the
    // SelectMode/EditMode pair, the symmetricSelect* function, the pick
    // radius (4 px for verts, 6 px for edges) and the hovered* slot written.
    void pickHover(SelectMode sm, EditMode em, alias symSel, int radius)(
            ref Viewport vp, bool doingCameraDrag) {
        static if (em == EditMode.Vertices)
            alias hovered = hoveredVertex;
        else
            alias hovered = hoveredEdge;
        ensureDisplayCurrent(); // mid-batch pull-guard: VBO reader below
        // Freeze hover during an active tool drag (element-move haul): return
        // WITHOUT re-picking so the element picked at drag-start stays
        // highlighted instead of every element the moving cursor passes over.
        if (activeTool !is null && activeTool.isDragging()) return;
        hovered = -1;
        if (!viewportInputAllowed() || doingCameraDrag) return;
        // No active tool → only the current editMode picks. With an
        // active tool, defer to `wantsHoverForType` so tools like
        // XfrmTransformTool (with falloff.element wired) can opt in to multi-type hover regardless
        // of editMode (Stage 14.9).
        if (activeTool is null) {
            if (editMode != em) return;
        } else {
            if (!activeTool.wantsHoverForType(em)) return;
        }

        int mx, my;
        queryMouse(mx, my);

        // Offscreen ID buffer: GPU rasterises every cage element as an
        // ID-tagged primitive, depth-tested against the face surface so
        // elements inside / behind opaque geometry drop out. Subpatch mode
        // maps VBO indices back to cage indices inside GpuSelectBuffer.pick
        // (the picker handles its own cache + VBO→cage translation).
        // Task 0617: `mesh`/`vp` here are the PRIMARY layer's — pair with
        // primaryModelSpace() so a transformed primary is picked where it's
        // drawn, not at its identity pose.
        int hit = gpuSelect.pick(sm, mx, my, radius, mesh, gpu, vp, primaryModelSpace());
        if (hit < 0) return;

        hovered = hit;
        if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
            symSel(&mesh(), vp, editMode, hovered, /*deselect=*/false);
        else if (dragMode == DragMode.SelectRemove)
            symSel(&mesh(), vp, editMode, hovered, /*deselect=*/true);
    }
    alias pickVertices = pickHover!(SelectMode.Vertex, EditMode.Vertices,
                                    symmetricSelectVertex, 4);
    alias pickEdges    = pickHover!(SelectMode.Edge,   EditMode.Edges,
                                    symmetricSelectEdge,   6);

    void pickFaces(ref Viewport vp, bool doingCameraDrag) {
        // Mid-batch pull-guard — covers BOTH engines: the GPU path reads the
        // ID-FBO rendered from the VBO, and the BVH path is keyed on
        // gpu.uploadVersion, so the guard's upload is what triggers its
        // rebuild against the post-mutation mesh.
        ensureDisplayCurrent();
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
        // Task 0617: both engines pick against the PRIMARY layer here —
        // primaryModelSpace() for both, so the BVH/GPU A/B stays apples-to-apples.
        int hit;
        if (useBvhFacePick) {
            const(Mesh)* srcMesh = subpatchPreview.active
                ? &subpatchPreview.mesh : &mesh();
            hit = bvhPick.pickFace(mx, my, vp, *srcMesh, gpu, primaryModelSpace());
        } else {
            hit = gpuSelect.pick(SelectMode.Face, mx, my, /*r=*/0,
                                  mesh, gpu, vp, primaryModelSpace());
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
        popPanelChromeStyle, renderViewportSceneToFbo,
        drawAi3dModal, drawRemeshModal, drawQuitGuardModal,
        drawCommandHistoryPanel;

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
            // Window [X] / SIGINT: request a close rather than quitting
            // outright (task 0434). The per-frame quit-guard prompts on
            // unsaved changes; keep processing this frame (return true).
            case SDL_QUIT:            quitRequested = true;               break;
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
        if (anySpinning) {
            immutable uint nowMs = SDL_GetTicks();
            anySpinning = false;
            foreach (cell; vpm.views) {
                if (cell is null || cell.camera is null) continue;
                cell.camera.spinTick(nowMs);
                anySpinning = anySpinning || cell.camera.spinning();
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
        // static if kCopilotEnabled (task 0422): panel draw skipped while
        // the copilot is paused; flip the flag to restore.
        version (WithAI)
        static if (kCopilotEnabled)
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
            import toolpipe.stage : Stage, TaskCode;
            // The BODY of a pipe stage's Tool Properties section: the
            // config-driven form when one is registered for the stage family,
            // the legacy provider panel otherwise, then the stage's own custom
            // block. Extracted (task 0544) so the per-stage collapsing headers
            // and the Snapping tab below render through ONE path and cannot
            // drift into two behaviours for the same rows.
            //
            // Phase 6: prefer a config-driven stage form (bound to the stage
            // via whenStage:, looked up by the stage's id()) over the legacy
            // drawProvider path — same gating + kill switch as the tool-level
            // form integration below. The stage IS a ParamProvider, so
            // FormsPanel queries its live (type-filtered) params() per frame
            // and hides rows whose attr the active type doesn't expose. Stages
            // without a matching form fall back to the unchanged drawProvider.
            // stage.drawProperties() still runs in both cases (shape popup /
            // auto-size buttons aren't form rows).
            // Look the form up by the stage FAMILY id (not the unique id), so
            // stacked falloff instances ("falloff#1", …) all resolve the one
            // "falloff" form; FormsPanel filters its rows against this
            // instance's params() and the stage.id() passed below rebinds the
            // write to the right instance.
            void drawStageBody(Stage stage) {
                import forms : g_formsPanelEnabled, formByStage;
                auto stageForm = g_formsPanelEnabled
                               ? formByStage(stage.formFamilyId()) : null;
                if (stageForm !is null) {
                    // A malformed row must degrade to the legacy panel, NOT
                    // throw mid-ImGui-frame (an escaping exception would leave
                    // ImGui's stack unbalanced and abort the frame). Fall back
                    // to drawProvider on any failure; warn ONCE per stage so a
                    // broken form doesn't spam stderr every frame.
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
            pushPanelChromeStyle();
            ImGui.SetNextWindowPos(ImVec2(layout.sideW + 10, 10), ImGuiCond.FirstUseEver);
            // Default tall enough to show a typical tool form (e.g. the box's
            // Position/Size/Segments/Radius groups) plus the per-stage sections
            // (Falloff, ACEN, ...) without manual resizing. FirstUseEver keeps
            // the user's own resize sticky in a normal run.
            ImGui.SetNextWindowSize(ImVec2(260, 520), ImGuiCond.FirstUseEver);
            if (ImGui.Begin("Tool Properties")) {
                // ---- Tabs (task 0544) ------------------------------------
                // The panel had none: the active tool's properties and every
                // pipe stage's section shared one column, and snapping was not
                // even in that column — SnapStage shipped without a params()
                // schema, so the per-stage loop below skipped it in silence and
                // the master toggle, the type set and the two pixel ranges that
                // decide whether a drag sticks had no panel at all.
                //
                // It has a schema now, and it gets a TAB rather than one more
                // collapsing header, because two independent sources say the
                // same thing. The owner reports snapping as its own tab from
                // using the reference; the reference's own layout config says
                // it structurally — `toolprops:general` is four PEER container
                // sheets, labelled "Tool Properties (Main)" / "(Action
                // Centres)" / "(Falloffs)" / "(Snapping)", and snapping is one
                // of the four, not a member of the first.
                //
                // We ship two of those four. Everything that was in the column
                // stays in the column, in its old order, under "Main" —
                // promoting the action-centre and falloff sections to peers of
                // their own is a change to a surface that already works, and
                // this is not that change. The only thing that moves is the
                // thing that had nowhere to be.
                //
                // Built from Selectable + SameLine rather than a tab-bar
                // widget: the ImGui binding this build links exposes no
                // BeginTabBar/BeginTabItem. Same behaviour — a strip of
                // mutually exclusive pages, one visible at a time — and no
                // Begin/End pairing to leave unbalanced if a page throws.
                {
                    static immutable string[] kTabs = ["Main", "Snapping"];
                    foreach (i, name; kTabs) {
                        if (i) ImGui.SameLine();
                        immutable float w = ImGui.CalcTextSize(name).x + 16.0f;
                        if (ImGui.Selectable(name,
                                             g_toolPropsTab == cast(int)i,
                                             0, ImVec2(w, 0)))
                            g_toolPropsTab = cast(int)i;
                    }
                    ImGui.Separator();
                }
                immutable bool inMain = g_toolPropsTab != kToolPropsTabSnapping;
                if (inMain) {
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
                        import tools.transform.xfrm_transform : XfrmTransformTool;
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
                    // modulate it (Workplane, ACEN, AXIS, Falloff — Snap is a
                    // tab of its own, skipped below).
                    // Stages without a schema (e.g. NopStage placeholders,
                    // or older stages that haven't been migrated yet)
                    // collapse to nothing.
                    if (g_pipeCtx !is null) {
                        foreach (s; g_pipeCtx.pipeline.all()) {
                            if (!s.enabled) continue;
                            auto stage = cast(Stage)s;
                            if (stage is null) continue;
                            if (stage.params().length == 0) continue;
                            // Snapping renders on its own tab (see below), not as
                            // one more header in this column — so it is skipped
                            // here rather than appearing in both places.
                            if (stage.taskCode() == TaskCode.Snap)
                                continue;
                            // Default-open so the extra stage sections (Action
                            // Center, Falloff, ...) are expanded without a
                            // click; the user can still collapse any of them.
                            if (ImGui.CollapsingHeader(stage.displayName(),
                                                       ImGuiTreeNodeFlags.DefaultOpen)) {
                                drawStageBody(stage);
                            }
                        }
                    }
                } // if (inMain)

                // ---- Snapping ---------------------------------------------
                // Drawn through `drawStageBody`, the same path the per-stage
                // sections take, so the rows, their write path and their HTTP
                // twins are the section's — only the location differs.
                //
                // Drawn whether or not the SNAP stage's master toggle is on:
                // that toggle is the FIRST row, and a page that emptied itself
                // when you switched snapping off would leave no way to switch
                // it back on. (The loop above gates on `Stage.enabled`, the
                // pipe REGISTRATION flag, which SnapStage's own `enabled`
                // field shadows rather than replaces — two different booleans
                // that have to stay told apart.)
                if (!inMain && g_pipeCtx !is null) {
                    foreach (s; g_pipeCtx.pipeline.all()) {
                        if (!s.enabled) continue;
                        auto stage = cast(Stage)s;
                        if (stage is null) continue;
                        if (stage.taskCode() != TaskCode.Snap) continue;
                        drawStageBody(stage);
                    }
                }
            }
            ImGui.End();
            popPanelChromeStyle();
        }

        // ---- Command History (floating) ----
        // Moved VERBATIM to ui/panels.d's drawCommandHistoryPanel (app.d
        // decomp, phase B; same `with (app)` seam as the 0419 panels).
        drawCommandHistoryPanel(app);

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
            {
                import display_sync : DisplayRefreshMask;
                const uint activeFlags = mesh.pendingChanges_;
                // A5 (post-gate fix): mid-gesture the transform family owns
                // the VBO — baseline verts with the live drag delta applied
                // via u_model on top (per-frame edits publish Position while
                // the tool draws matrix-composed). A full upload here would
                // bake LIVE verts under a LIVE matrix and double-apply the
                // delta (gpu_fold_parity / far_pivot_fold / chained_drag).
                // Skip while dragging: only XfrmTransformTool overrides
                // isDragging, and its mouseUp bake + commit publish resync
                // the VBO at gesture end. Flags still drain to subscribers.
                const bool toolOwnsVbo =
                    activeTool !is null && activeTool.isDragging();
                if ((activeFlags & DisplayRefreshMask) && !toolOwnsVbo)
                    gpu.upload(mesh);
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
                    // Guard-serviced bits count as pending for their owner —
                    // without this, a mutation whose flags ensureDisplayCurrent
                    // transferred into the shadow word would read as "version
                    // advanced, zero flags" and latch a spurious warning.
                    const lf = layer.meshRef().pendingChanges_
                        | ((&layer.meshRef()) is displayEnsuredMesh_
                               ? displayEnsured_ : 0u);
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

            // Transfer-back (phase-2 dedup): bits `ensureDisplayCurrent`
            // moved out of `pendingChanges_` (display already serviced
            // mid-batch) still belong to THIS frame's flags for every flush
            // subscriber — return them to the aggregate and reset the shadow.
            meshFlags |= displayEnsured_;
            displayEnsured_     = 0;
            displayEnsuredMesh_ = null;

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

            if (quitAfterSave) {
                quitAfterSave = false;
                // Exit only if the Save actually landed; a cancelled Save
                // dialog leaves the document dirty ⇒ the quit is aborted.
                if (!docDirty()) running = false;
            }

            // Title: "<file> - Vibe3d", leading "*" while dirty, "untitled"
            // when no native document is open. Only touch SDL on change.
            const p     = currentDocPath();
            const fname = p.length ? baseName(p) : "untitled";
            string title = (docDirty() ? "*" : "") ~ fname ~ " - Vibe3d";
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
                                dragMode == DragMode.Pan   ||
                                dragMode == DragMode.Roll);

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
                        import display_state : DisplayStyle;
                        import std.format : format;
                        static immutable string[3] dsLabels =
                            ["Shaded", "Solid", "Wireframe"];
                        static immutable string[3] dsIds =
                            ["shaded", "solid", "wireframe"];
                        static immutable DisplayStyle[3] dsVals = [
                            DisplayStyle.Shaded, DisplayStyle.Solid,
                            DisplayStyle.Wireframe
                        ];
                        int dsIdx = 0;
                        foreach (i, dv; dsVals)
                            if (dv == _vcell.display.active.style) dsIdx = cast(int)i;

                        // Beside the view combo: its origin is (4,4) and it is
                        // 120 wide, so this starts at 128 with the same 4px
                        // gutter. Narrower than the panel's full-width combo —
                        // this is chrome sitting on top of the user's scene,
                        // and the three labels it must show are short.
                        ImGui.SetCursorPos(ImVec2(4 + 120 + 4, 4));
                        ImGui.SetNextItemWidth(100.0f);
                        bool _dsOpen = ImGui.BeginCombo(
                            "##vpStyle" ~ to!string(k), dsLabels[dsIdx]);
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
                            foreach (i, dl2; dsLabels) {
                                bool sel = (i == dsIdx);
                                if (ImGui.Selectable(dl2, sel)
                                    && commandHandlerDelegate !is null)
                                    commandHandlerDelegate("viewport.displayStyle",
                                        format(`{"_positional":["%s"],"viewport":%d}`,
                                               dsIds[i], k));
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

            foreach (k; overlayDrawOrder(vpm.cellCount, overlayOwner)) {
                Viewport3D _cv = vpm.views[k];
                // Perf (always-on): the cell-level render decision. The
                // `considered` vs `rendered` PAIR is the point — the dirty-key
                // gate below means a frame with zero draws is normal, not a
                // broken measurement, and only these two counters distinguish
                // "nothing changed" from "the scene stopped drawing".
                g_fc.bumpCellConsidered();

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
