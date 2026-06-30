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
import perf_probe : g_perf, Cat;
import io.assimp_runtime : initAssimp, shutdownAssimp, isAssimpAvailable;
import symmetry_pick : symmetricSelectVertex, symmetricSelectEdge, symmetricSelectFace;

import tools.transform;
import tools.move;
import tools.push;
import tools.bend;
import tools.scale;
import tools.rotate;
import tools.box;
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
import tools.poly_bevel : PolyBevelTool;
import tools.edge_bevel : EdgeBevelTool;
import tools.reduce : ReductionTool;
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
import commands.mesh.edge_extrude : MeshEdgeExtrude;
import commands.mesh.vertex_extrude : MeshVertexExtrude;
import commands.mesh.vertex_bevel   : MeshVertexBevel;
import commands.mesh.edge_extrude_edit : MeshEdgeExtrudeEdit;
import commands.mesh.poly_inset : MeshPolygonInset;
import commands.mesh.spikey : MeshSpikey;
import commands.mesh.bevel : MeshBevel;
import commands.mesh.face_extrude : MeshFaceExtrude;
import commands.mesh.face_extrude_edit : MeshFaceExtrudeEdit;
import commands.mesh.bridge : MeshBridge;
import commands.mesh.thicken : MeshThicken;
import commands.mesh.smooth_shift : MeshSmoothShift;
import commands.mesh.edge_extend : MeshEdgeExtend;
import commands.mesh.edge_extend_edit : MeshEdgeExtendEdit;
import commands.mesh.move_vertex;
import commands.mesh.vertex_new    : MeshVertexNew;
import commands.mesh.vertex_center : MeshCenterVertices;
import commands.mesh.vertex_set    : MeshSetPosition;
import commands.mesh.bevel_edit : MeshBevelEdit;
import commands.mesh.reduce_edit : MeshReduceEdit;
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
import commands.mesh.radial_array_ : MeshRadialArray;
import commands.mesh.sweep         : MeshSweep;
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
import commands.mesh.make_polygon  : MeshMakePolygon;
import commands.mesh.select;
import commands.mesh.selection_edit : MeshSelectionEdit;
import commands.mesh.transform;
import commands.mesh.quantize;
import commands.mesh.jitter;
import commands.mesh.smooth;
import commands.mesh.weightmap;
import commands.mesh.uv_transform;
import commands.mesh.uv_project  : UvProject;
import commands.mesh.uv_pack     : UvFit, UvPack;
import commands.mesh.uv_map_util;
import commands.mesh.uv_relax  : UvRelax;
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
import commands.ui.layer_list : UiLayerListCommand, g_layerListShown;
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
version (WithAI) import ai.onnx_backend : OnnxModelBackend;
import args_dialog    : ArgsDialog;
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

// ---------------------------------------------------------------------------
// Module-level helpers
// ---------------------------------------------------------------------------

private ulong edgeKey(uint a, uint b) {
    uint lo = a < b ? a : b, hi = a < b ? b : a;
    return (cast(ulong)lo << 32) | hi;
}

private int countSelected(bool[] sel) {
    int n = 0;
    foreach (s; sel) if (s) n++;
    return n;
}

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

/// Build the item-snap frame for one visible layer: world-space pivot +
/// world-space AABB derived from ALL mesh vertices (whole-item bounds,
/// independent of any active vertex sub-selection).  Called from both the
/// render-thread per-frame install and the HTTP-thread JIT install.
private ItemSnapFrame buildItemFrame(Layer lyr)
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
    // In --test mode, disable ImGui's on-disk layout persistence. The .ini
    // is written relative to the current working directory, and each parallel
    // test worker runs in its own scratch cwd — so without this every worker
    // would load a different (or fresh) panel layout, making synthetic mouse
    // drags over the viewport non-deterministic (a drag can cross a panel that
    // is present in one worker's layout and absent in another's, where ImGui
    // would capture it). Setting IniFilename = null before the first NewFrame
    // means windows always open at their programmatic default positions,
    // independent of cwd. Must run before any window is created/loaded.
    version (ReleaseBuild) {
        io.IniFilename = null;
    } else {
        if (command.g_testMode)
            io.IniFilename = null;
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

    // Camera
    View cameraView = new View(layout.vpX, layout.vpY, layout.vpW, layout.vpH);

    VertexCache vertexCache;
    vertexCache.resize(mesh.vertices.length);

    FaceBoundsCache faceCache;
    faceCache.resize(mesh.vertices.length, mesh.faces.length);

    EdgeCache edgeCache;
    edgeCache.resize(mesh.edges.length);

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
    {
        import change_bus : changeBus;
        changeBus.onMeshChanged((uint flags) { meshChangedFlags |= flags; });
        changeBus.onSelectionChanged((uint domains) { selChangedDomains |= domains; });
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

    // Layers Stage 5 — background-layer GPU buffers. A side map (NOT a field on
    // Layer: document.d stays GL-free and the render boundary stays clean)
    // keyed by the Layer object. Each entry caches the layer's last uploaded
    // `mesh.mutationVersion` so a visible-immutable background layer uploads at
    // most once until it actually changes. Entries for layers that are no
    // longer visible-background (hidden, made active/foreground, or deleted) are
    // destroyed + dropped each frame so GL handles never leak. In a single-layer
    // document this map is always empty ⇒ zero per-frame cost.
    import document : Layer;
    struct BgGpu { GpuMesh gpu; ulong uploadedVersion = ulong.max; }
    BgGpu*[Layer] bgGpuByLayer;
    scope(exit) {
        foreach (k, bg; bgGpuByLayer) bg.gpu.destroy();
    }

    // Offscreen ID-buffer picker shared by pickVertices / pickEdges /
    // pickFaces. Heuristic-visibility tests rejected elements the user
    // could clearly see; GPU per-pixel depth-test sidesteps that.
    // See source/gpu_select.d.
    import gpu_select : GpuSelectBuffer, SelectMode;
    auto gpuSelect = new GpuSelectBuffer();
    gpuSelect.init();
    scope(exit) gpuSelect.destroy();

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
        if (loopHoverPrevEdge == hovEdge
            && loopHoverPrevTopo == mesh.topologyVersion
            && loopHoverEdgesCache.length == mesh.edges.length)
            return loopHoverEdgesCache;   // cache hit — no walk

        loopHoverPrevEdge = hovEdge;
        loopHoverPrevTopo = mesh.topologyVersion;
        if (loopHoverEdgesCache.length != mesh.edges.length)
            loopHoverEdgesCache = new bool[](mesh.edges.length);
        loopHoverEdgesCache[] = false;

        if (hovEdge < 0 || hovEdge >= cast(int)mesh.edges.length)
            return loopHoverEdgesCache;

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
        import toolpipe.stages.actcenter     : ActionCenterStage;
        import toolpipe.stages.axis          : AxisStage;
        import toolpipe.stages.falloff       : FalloffStage;
        if (g_pipeCtx is null) return;
        foreach (s; g_pipeCtx.pipeline.allMut()) {
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
                case "falloff":
                    // A user-selected falloff (userLocked) survives a tool
                    // switch — reference parity (captured 2026-06-16). A
                    // preset-bundled / unlocked falloff still resets.
                    if (auto fo = cast(FalloffStage)s)
                        fo.resetTransient();
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
        import toolpipe.stage : stringifyParam;
        import params : Param;
        string[string] attrs;
        foreach (ref p; activeTool.params()) {
            // Array kinds don't round-trip through the string<->param path
            // (stringifyParam/parseInto return ""/false for them); read-only
            // params are derived display, not user settings. Skip both.
            if (p.kind == Param.Kind.IntArray || p.kind == Param.Kind.Vec3Array)
                continue;
            if (p.readonly_) continue;
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
    auto propertyPanel = new PropertyPanel();
    auto formsPanel    = new forms_render.FormsPanel();
    auto aiState       = new EditorAiState();
    auto aiAdvisor     = new AiAdvisor(() => aiState.enabled);
    setHandleAiAdvisor(aiAdvisor);

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
                        auto vpNow = cameraView.viewport();
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
    auto vxEditFactory = () => new MeshVertexEdit(&mesh(), cameraView, editMode,
                                                   &gpu, &vertexCache, &edgeCache, &faceCache);
    auto bevelEditFactory = () => new MeshBevelEdit(&mesh(), cameraView, editMode,
                                                     &gpu, &vertexCache, &edgeCache, &faceCache);
    auto reduceEditFactory = () => new MeshReduceEdit(&mesh(), cameraView, editMode,
                                                      &gpu, &vertexCache, &edgeCache, &faceCache);
    auto edgeExtrudeEditFactory = () => new MeshEdgeExtrudeEdit(&mesh(), cameraView, editMode,
                                                     &gpu, &vertexCache, &edgeCache, &faceCache);
    // Edge Extend's typed edit factory (Phase 4 interactive tool consumer). The
    // one-shot mesh.edge_extend command undoes via its own MeshSnapshot; this
    // factory exists now so the Phase-4 EdgeExtendTool can bind it, mirroring
    // edgeExtrudeEditFactory.
    auto edgeExtendEditFactory = () => new MeshEdgeExtendEdit(&mesh(), cameraView, editMode,
                                                     &gpu, &vertexCache, &edgeCache, &faceCache);
    auto polyExtrudeEditFactory = () => new MeshFaceExtrudeEdit(&mesh(), cameraView, editMode,
                                                     &gpu, &vertexCache, &edgeCache, &faceCache);

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
    // `move` / `rotate` / `scale` build XfrmTransformTool with the
    // matching T/R/S single-flag preset — they share one engine, like
    // the TransformMove / TransformRotate / TransformScale presets all
    // pointing at one `xfrm.transform` tool.
    // The legacy MoveTool / RotateTool / ScaleTool classes still
    // back the wrapper as sub-tools (composition) and will be
    // deleted in Step 6 once dependents (xfrm.softMove, xfrm.taper,
    // etc.) have moved off them.
    reg.toolFactories["move"]   = () {
        import tools.xfrm_transform : XfrmTransformTool;
        auto t = new XfrmTransformTool(() => &mesh(), &gpu, &editMode);
        t.flagT = true; t.flagR = false; t.flagS = false;
        t.handleFamily = 0;
        t.handlePresentation = "full";
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        if (aiExplore.enabled && aiLogWriter.enabled)
            t.setAiExploreSilentHover(true);
        return cast(Tool)t;
    };
    reg.toolFactories["rotate"] = () {
        import tools.xfrm_transform : XfrmTransformTool;
        auto t = new XfrmTransformTool(() => &mesh(), &gpu, &editMode);
        t.flagT = false; t.flagR = true; t.flagS = false;
        t.handleFamily = 1;
        t.handlePresentation = "full";
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        if (aiExplore.enabled && aiLogWriter.enabled)
            t.setAiExploreSilentHover(true);
        return cast(Tool)t;
    };
    reg.toolFactories["scale"]  = () {
        import tools.xfrm_transform : XfrmTransformTool;
        auto t = new XfrmTransformTool(() => &mesh(), &gpu, &editMode);
        t.flagT = false; t.flagR = false; t.flagS = true;
        t.handleFamily = 2;
        t.handlePresentation = "full";
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        if (aiExplore.enabled && aiLogWriter.enabled)
            t.setAiExploreSilentHover(true);
        return cast(Tool)t;
    };
    reg.toolFactories["xfrm.transform"] = () {
        import tools.xfrm_transform : XfrmTransformTool;
        auto t = new XfrmTransformTool(() => &mesh(), &gpu, &editMode);
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        if (aiExplore.enabled && aiLogWriter.enabled)
            t.setAiExploreSilentHover(true);
        return cast(Tool)t;
    };
    reg.toolFactories["xfrm.push"] = () {
        auto t = new PushTool(() => &mesh(), &gpu, &editMode);
        t.setUndoBindings(history, vxEditFactory);
        return cast(Tool)t;
    };
    reg.toolFactories["xfrm.bend"] = () {
        auto t = new BendTool(() => &mesh(), &gpu, &editMode);
        t.setUndoBindings(history, vxEditFactory);
        return cast(Tool)t;
    };
    // Convolve sub-tools (Deform → Smooth / Jitter / Quantize) —
    // exposed as tools so the side-panel buttons use the same
    // `tool.set xfrm.smooth on` activation shape. The
    // underlying math reuses MeshSmooth / MeshJitter / MeshQuantize
    // (one-shot, not brush-interactive). Brush interactivity is a
    // follow-up; the tool surface is the prerequisite.
    reg.toolFactories["xfrm.smooth"] = () {
        auto t = new XfrmSmoothTool(&mesh(), cameraView, editMode, &gpu,
                                    &vertexCache, &edgeCache, &faceCache);
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        return cast(Tool)t;
    };
    reg.toolFactories["xfrm.jitter"] = () {
        auto t = new XfrmJitterTool(&mesh(), cameraView, editMode, &gpu,
                                    &vertexCache, &edgeCache, &faceCache);
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        return cast(Tool)t;
    };
    reg.toolFactories["edge.slide"] = () {
        auto t = new EdgeSlideTool(&mesh(), cameraView, editMode, &gpu,
                                   &vertexCache, &edgeCache, &faceCache);
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        return cast(Tool)t;
    };
    reg.toolFactories["xfrm.quantize"] = () {
        auto t = new XfrmQuantizeTool(&mesh(), cameraView, editMode, &gpu,
                                      &vertexCache, &edgeCache, &faceCache);
        t.setUndoBindings(history, vxEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        return cast(Tool)t;
    };
    reg.toolFactories["prim.cube"] = () {
        auto t = new BoxTool(() => &mesh(), &gpu, litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.cube"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                &gpu, &vertexCache, &edgeCache, &faceCache,
                                "prim.cube", reg.toolFactories["prim.cube"]);

    reg.toolFactories["prim.sphere"] = () {
        auto t = new SphereTool(() => &mesh(), &gpu, litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.sphere"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                &gpu, &vertexCache, &edgeCache, &faceCache,
                                "prim.sphere", reg.toolFactories["prim.sphere"]);

    reg.toolFactories["prim.ellipsoid"] = () {
        auto t = new SphereTool(() => &mesh(), &gpu, litShader, /*ellipsoidMode=*/true);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.ellipsoid"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                &gpu, &vertexCache, &edgeCache, &faceCache,
                                "prim.ellipsoid", reg.toolFactories["prim.ellipsoid"]);

    reg.toolFactories["prim.cylinder"] = () {
        auto t = new CylinderTool(() => &mesh(), &gpu, litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.cylinder"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                &gpu, &vertexCache, &edgeCache, &faceCache,
                                "prim.cylinder", reg.toolFactories["prim.cylinder"]);

    reg.toolFactories["prim.tube"] = () {
        auto t = new TubeTool(() => &mesh(), &gpu, litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.tube"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                &gpu, &vertexCache, &edgeCache, &faceCache,
                                "prim.tube", reg.toolFactories["prim.tube"]);

    reg.toolFactories["prim.cone"] = () {
        auto t = new ConeTool(() => &mesh(), &gpu, litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.cone"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                &gpu, &vertexCache, &edgeCache, &faceCache,
                                "prim.cone", reg.toolFactories["prim.cone"]);

    reg.toolFactories["prim.capsule"] = () {
        auto t = new CapsuleTool(() => &mesh(), &gpu, litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.capsule"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                &gpu, &vertexCache, &edgeCache, &faceCache,
                                "prim.capsule", reg.toolFactories["prim.capsule"]);

    reg.toolFactories["prim.torus"] = () {
        auto t = new TorusTool(() => &mesh(), &gpu, litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.torus"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                &gpu, &vertexCache, &edgeCache, &faceCache,
                                "prim.torus", reg.toolFactories["prim.torus"]);

    reg.toolFactories["prim.arc"] = () {
        auto t = new ArcTool(() => &mesh(), &gpu, litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.commandFactories["prim.arc"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                &gpu, &vertexCache, &edgeCache, &faceCache,
                                "prim.arc", reg.toolFactories["prim.arc"]);

    // Pen has no headless path — interactive only. Tool factory
    // only; no commandFactories entry. See doc/pen_plan.md.
    reg.toolFactories["pen"] = () {
        auto t = new PenTool(() => &mesh(), &gpu, litShader,
                             &vertexCache, &edgeCache, &faceCache);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    // Vertex placement — interactive only; one click = one isolated vertex.
    // No commandFactories entry: headless geometry creation uses mesh.addVertex
    // (task 0131).
    reg.toolFactories["prim.vertex"] = () {
        auto t = new VertexTool(() => &mesh(), &gpu, litShader,
                                &vertexCache, &edgeCache, &faceCache);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    // Drag Weld — drag a source vertex onto a target vertex to weld them.
    // LMB-down picks the source; LMB-up picks the target; one snapshot-undo
    // entry per completed gesture. Gated to Vertices mode.
    reg.toolFactories["mesh.dragWeld"] = () {
        auto t = new DragWeldTool(() => &mesh(), &gpu, litShader,
                                  &vertexCache, &edgeCache, &faceCache);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    // Edge Extrude — interactive (drag → extrude/width) + headless
    // (tool.attr edge.extrude extrude/width; tool.doApply). Topology-creating
    // tool: own typed edit factory (MeshEdgeExtrudeEdit, not vxEditFactory),
    // wired via the prim.cube registration template. Gated to Edges mode by
    // EdgeExtrudeTool.supportedModes().
    reg.toolFactories["edge.extrude"] = () {
        auto t = new EdgeExtrudeTool(() => &mesh(), &gpu, &editMode, litShader,
                                     &vertexCache, &edgeCache, &faceCache);
        t.setUndoBindings(history, edgeExtrudeEditFactory);
        return cast(Tool)t;
    };

    // Face Extrude — interactive (drag → distance along region normal) + headless
    // (tool.attr poly.extrude distance <v>; tool.doApply). Topology-creating
    // tool: own typed edit factory (MeshFaceExtrudeEdit, snapshot-only undo).
    // Gated to Polygons mode by PolyExtrudeTool.supportedModes().
    reg.toolFactories["poly.extrude"] = () {
        auto t = new PolyExtrudeTool(() => &mesh(), &gpu, &editMode, litShader,
                                     &vertexCache, &edgeCache, &faceCache);
        t.setUndoBindings(history, polyExtrudeEditFactory);
        return cast(Tool)t;
    };

    // Edge Extend — interactive (drag → world-axis Offset via the embedded
    // transform gizmo's Move bank) + headless (tool.attr edge.extend offsetX...;
    // tool.doApply). Topology-creating tool: own typed edit factory
    // (MeshEdgeExtendEdit). Gated to Edges mode by EdgeExtendTool.supportedModes().
    reg.toolFactories["edge.extend"] = () {
        auto t = new EdgeExtendTool(() => &mesh(), &gpu, &editMode, litShader,
                                    &vertexCache, &edgeCache, &faceCache);
        t.setUndoBindings(history, edgeExtendEditFactory);
        t.setPipeGizmoHost(pipeGizmoHost);
        return cast(Tool)t;
    };

    // Poly Bevel — interactive + headless (inset, shift params). Topology-creating
    // tool: reuses bevelEditFactory (MeshBevelEdit snapshot undo). Gated to Polygons.
    reg.toolFactories["poly.bevel"] = () {
        auto t = new PolyBevelTool(() => &mesh(), &gpu, &editMode, litShader,
                                   &vertexCache, &edgeCache, &faceCache);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    // Edge Bevel — interactive + headless (width param). Topology-creating tool:
    // reuses bevelEditFactory (MeshBevelEdit snapshot undo). Gated to Edges mode.
    reg.toolFactories["edge.bevel"] = () {
        auto t = new EdgeBevelTool(() => &mesh(), &gpu, &editMode, litShader,
                                   &vertexCache, &edgeCache, &faceCache);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    // Mesh Reduction — interactive + headless (ratio, preserveBoundary params).
    // Whole-mesh decimation via reduceToTarget; snapshot undo via MeshReduceEdit.
    // Gated to Polygons mode (whole-mesh op, but surfaced in polygon mode).
    reg.toolFactories["mesh.reduceTool"] = () {
        auto t = new ReductionTool(() => &mesh(), &gpu, &editMode, litShader,
                                   &vertexCache, &edgeCache, &faceCache);
        t.setUndoBindings(history, reduceEditFactory);
        return cast(Tool)t;
    };

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
        auto t = (*factory)();
        setActiveTool(t);
        activeToolId = id;
    };
    toolHost.deactivate = () {
        setActiveTool(null);
        activeToolId = "";
    };

    reg.commandFactories["tool.set"] = () => cast(Command)
        new ToolSetCommand(&mesh(), cameraView, editMode, toolHost);
    reg.commandFactories["tool.attr"] = () => cast(Command)
        new ToolAttrCommand(&mesh(), cameraView, editMode, toolHost);
    reg.commandFactories["tool.doApply"] = () => cast(Command)
        new ToolDoApplyCommand(&mesh(), cameraView, editMode, toolHost,
                               &gpu, &vertexCache, &edgeCache, &faceCache,
                               history);
    reg.commandFactories["tool.reset"] = () => cast(Command)
        new ToolResetCommand(&mesh(), cameraView, editMode, toolHost);
    reg.commandFactories["tool.pipe.attr"] = () => cast(Command)
        new ToolPipeAttrCommand(&mesh(), cameraView, editMode, toolHost);
    // Test-only headless hooks (re-eval plan D5, Phase 3). Both reject
    // themselves unless g_testMode (set by --test); inert in a normal run.
    reg.commandFactories["tool.beginSession"] = () => cast(Command)
        new ToolBeginSessionCommand(&mesh(), cameraView, editMode, toolHost);
    reg.commandFactories["tool.panelEdit"] = () => cast(Command)
        new ToolPanelEditCommand(&mesh(), cameraView, editMode, toolHost);
    reg.commandFactories["ui.toolProperties"] = () => cast(Command)
        new UiToolPropertiesCommand(&mesh(), cameraView, editMode);
    reg.commandFactories["ui.layerList"] = () => cast(Command)
        new UiLayerListCommand(&mesh(), cameraView, editMode);

    // layer.* commands (layers Stage 2) — mutate the one Document; the
    // active-index movers (add/delete/select) fire onActiveLayerChanged.
    {
        import commands.layer.commands : LayerAdd, LayerDelete, LayerDuplicate,
                                          LayerSelect, LayerRename, LayerSetVisible,
                                          LayerReorder, LayerAttr, LayerParent;
        reg.commandFactories["layer.add"] = () => cast(Command)
            new LayerAdd(&mesh(), cameraView, editMode, &document, onActiveLayerChanged);
        reg.commandFactories["layer.duplicate"] = () => cast(Command)
            new LayerDuplicate(&mesh(), cameraView, editMode, &document, onActiveLayerChanged);
        reg.commandFactories["layer.delete"] = () => cast(Command)
            new LayerDelete(&mesh(), cameraView, editMode, &document, onActiveLayerChanged);
        reg.commandFactories["layer.reorder"] = () => cast(Command)
            new LayerReorder(&mesh(), cameraView, editMode, &document, onActiveLayerChanged);
        reg.commandFactories["layer.select"] = () => cast(Command)
            (new LayerSelect(&mesh(), cameraView, editMode, &document, onActiveLayerChanged))
                .setItemSelectHook(&switchToItemType);
        reg.commandFactories["layer.rename"] = () => cast(Command)
            new LayerRename(&mesh(), cameraView, editMode, &document, onActiveLayerChanged);
        reg.commandFactories["layer.setVisible"] = () => cast(Command)
            new LayerSetVisible(&mesh(), cameraView, editMode, &document, onActiveLayerChanged);
        // layer.attr — generic per-layer Param write/read (survey #3). Wired
        // with &document like the others; the active-switch hook is unused (a
        // property edit never moves the active layer) but passed for ctor
        // uniformity.
        reg.commandFactories["layer.attr"] = () => cast(Command)
            new LayerAttr(&mesh(), cameraView, editMode, &document, onActiveLayerChanged);
        // layer.parent — set/clear item-parent reference (task 0082).
        reg.commandFactories["layer.parent"] = () => cast(Command)
            new LayerParent(&mesh(), cameraView, editMode, &document, onActiveLayerChanged);
    }

    // workplane.* commands — target the WorkplaneStage (ordinal 0x30)
    // in the global tool pipe.
    reg.commandFactories["workplane.reset"] = () => cast(Command)
        new WorkplaneResetCommand(&mesh(), cameraView, editMode);
    reg.commandFactories["workplane.edit"] = () => cast(Command)
        new WorkplaneEditCommand(&mesh(), cameraView, editMode);
    reg.commandFactories["workplane.rotate"] = () => cast(Command)
        new WorkplaneRotateCommand(&mesh(), cameraView, editMode);
    reg.commandFactories["workplane.offset"] = () => cast(Command)
        new WorkplaneOffsetCommand(&mesh(), cameraView, editMode);
    reg.commandFactories["workplane.alignToSelection"] = () => cast(Command)
        new WorkplaneAlignToSelectionCommand(&mesh(), cameraView, editMode);

    // Phase 7.2f: actr.<mode> — combined presets that flip ACEN + AXIS
    // stages atomically. Granular tool.pipe.attr
    // forms remain available for mix-and-match. Mappings per
    // phase7_2_plan.md §"Canonical user commands".
    {
        import commands.actr : ActrPresetCommand;
        // (preset, acenMode, axisMode) tuples.
        static struct Preset { string name; string acen; string axis; }
        immutable Preset[] presets = [
            Preset("auto",       "auto",       "auto"),
            Preset("select",     "select",     "select"),
            Preset("selectauto", "selectauto", "selectauto"),
            Preset("element",    "element",    "element"),
            Preset("local",      "local",      "local"),
            Preset("origin",     "origin",     "world"),    // axis at origin = world
            Preset("screen",     "screen",     "screen"),
            Preset("border",     "border",     "select"),   // border edges + selection-aligned axis
            Preset("none",       "none",       "none"),     // "(none)" — drops both, world fallback
            Preset("pivot",      "pivot",      "pivot"),    // 0082: item pivot
            Preset("parent",     "parent",     "parent"),   // 0082: parent item frame
        ];
        // IIFE capture by value — the bare-foreach + lambda pattern
        // closes over the loop variable by reference in D, so without
        // this all 8 factories would end up calling with the LAST
        // iteration's mode strings.
        Command delegate() makeFactory(string nm, string a, string x) {
            return () => cast(Command)
                new ActrPresetCommand(&mesh(), cameraView, editMode, nm, a, x);
        }
        foreach (p; presets) {
            reg.commandFactories["actr." ~ p.name] =
                makeFactory(p.name, p.acen, p.axis);
        }
    }

    // Bare named falloff sub-tools: falloff.<type> sets the falloff (WGHT)
    // stage's `type` and keeps the active transform tool (NOT a tool that
    // replaces the active tool, NOT a transform bundle). Same write path as
    // the status-bar Falloff pulldown (`tool.pipe.attr falloff type <type>`),
    // so the on-switch auto-size + state-publish + live re-eval side-effects
    // are identical. The two BUNDLE presets falloff.element / falloff.selection
    // (base xfrm.transform + pipe.falloff.type) live in config/tool_presets.yaml
    // and stay separate.
    {
        import commands.falloff : FalloffPresetCommand,
                                   FalloffAddCommand, FalloffRemoveCommand,
                                   FalloffClearCommand,
                                   FalloffAutoSizeCommand, FalloffReverseCommand;
        // IIFE capture by value — same closure-over-loop-variable trap the
        // actr.* block above documents.
        Command delegate() makeFalloffFactory(string ty) {
            return () => cast(Command)
                new FalloffPresetCommand(&mesh(), cameraView, editMode, toolHost, ty);
        }
        static immutable string[] falloffTypes =
            ["linear", "radial", "cylinder", "screen", "lasso", "vertexMap"];
        foreach (ty; falloffTypes)
            reg.commandFactories["falloff." ~ ty] = makeFalloffFactory(ty);

        // Multi-falloff stacking verbs (Phase 4): add/remove/clear extra
        // falloff instances. `falloff.add <type>` / `falloff.remove <id>`
        // take a positional arg wired in injectToolCommandPositional below.
        reg.commandFactories["falloff.add"] = () => cast(Command)
            new FalloffAddCommand(&mesh(), cameraView, editMode, toolHost);
        reg.commandFactories["falloff.remove"] = () => cast(Command)
            new FalloffRemoveCommand(&mesh(), cameraView, editMode, toolHost);
        reg.commandFactories["falloff.clear"] = () => cast(Command)
            new FalloffClearCommand(&mesh(), cameraView, editMode, toolHost);

        // Falloff form action buttons: `falloff.autosize <axis>` (X/Y/Z fit) and
        // `falloff.reverse` (swap start/end). autosize's axis is wired in
        // injectToolCommandPositional below.
        reg.commandFactories["falloff.autosize"] = () => cast(Command)
            new FalloffAutoSizeCommand(&mesh(), cameraView, editMode, toolHost);
        reg.commandFactories["falloff.reverse"] = () => cast(Command)
            new FalloffReverseCommand(&mesh(), cameraView, editMode, toolHost);
    }

    reg.commandFactories["select.expand"]         = () => cast(Command) new SelectionExpand(&mesh(), cameraView, editMode);
    reg.commandFactories["select.contract"]       = () => cast(Command) new SelectionContract(&mesh(), cameraView, editMode);
    reg.commandFactories["select.more"]           = () => cast(Command) new SelectMore(&mesh(), cameraView, editMode);
    reg.commandFactories["select.less"]           = () => cast(Command) new SelectLess(&mesh(), cameraView, editMode);
    reg.commandFactories["select.loop"]           = () => cast(Command) new SelectLoop(&mesh(), cameraView, editMode);
    reg.commandFactories["select.ring"]           = () => cast(Command) new SelectRing(&mesh(), cameraView, editMode);
    reg.commandFactories["select.invert"]         = () => cast(Command) new SelectInvert(&mesh(), cameraView, editMode);
    reg.commandFactories["select.connect"]        = () => cast(Command) new SelectConnect(&mesh(), cameraView, editMode);
    reg.commandFactories["select.between"]        = () => cast(Command) new SelectBetween(&mesh(), cameraView, editMode);
    reg.commandFactories["select.typeFrom"]  = () => cast(Command)
        new SelectTypeFromCommand(&mesh(), cameraView, editMode, &editMode,
                                  (EditMode m) => switchGeometryType(m));
    reg.commandFactories["select.vertex"]    = () => cast(Command)
        new SelectTypeFromCommand(&mesh(), cameraView, editMode, &editMode, "vertex",
                                  (EditMode m) => switchGeometryType(m));
    reg.commandFactories["select.edge"]      = () => cast(Command)
        new SelectTypeFromCommand(&mesh(), cameraView, editMode, &editMode, "edge",
                                  (EditMode m) => switchGeometryType(m));
    reg.commandFactories["select.polygon"]   = () => cast(Command)
        new SelectTypeFromCommand(&mesh(), cameraView, editMode, &editMode, "polygon",
                                  (EditMode m) => switchGeometryType(m));
    reg.commandFactories["select.drop"]      = () => cast(Command)
        new SelectDropCommand(&mesh(), cameraView, editMode);
    reg.commandFactories["select.element"]   = () => cast(Command)
        new SelectElementCommand(&mesh(), cameraView, editMode);
    reg.commandFactories["select.convert"]   = () => cast(Command)
        (new SelectConvertCommand(&mesh(), cameraView, editMode, &editMode))
            .setPromoteHook((EditMode m) => promoteGeometryType(m));
    reg.commandFactories["viewport.fit"]          = () => cast(Command) new Fit(&mesh(), cameraView, editMode);
    reg.commandFactories["viewport.fit_selected"] = () => cast(Command) new FitSelected(&mesh(), cameraView, editMode);
    {
        import commands.snap.toggle : SnapToggleCommand;
        import commands.snap.mode   : SnapModeCommand;
        reg.commandFactories["snap.toggle"] = () => cast(Command)
            new SnapToggleCommand(&mesh(), cameraView, editMode);
        import commands.constrain.toggle : ConstrainToggleCommand;
        reg.commandFactories["constrain.toggle"] = () => cast(Command)
            new ConstrainToggleCommand(&mesh(), cameraView, editMode);
        reg.commandFactories["snap.toggleType"] = () => cast(Command)
            new SnapToggleTypeCommand(&mesh(), cameraView, editMode);
        reg.commandFactories["snap.mode"] = () => cast(Command)
            new SnapModeCommand(&mesh(), cameraView, editMode);
    }
    {
        reg.commandFactories["path.define"] = () => cast(Command)
            new PathDefineCommand(&mesh(), cameraView, editMode);
    }
    {
        Command delegate() makeAiFactory(AiToggleAction action) {
            return () => cast(Command)
                new AiToggleCommand(&mesh(), cameraView, editMode, aiState, action);
        }
        reg.commandFactories["ai.toggle"]  = makeAiFactory(AiToggleAction.toggle);
        reg.commandFactories["ai.enable"]  = makeAiFactory(AiToggleAction.enable);
        reg.commandFactories["ai.disable"] = makeAiFactory(AiToggleAction.disable);
    }
    {
        import commands.symmetry.toggle : SymmetryToggleCommand;
        reg.commandFactories["symmetry.toggle"] = () => cast(Command)
            new SymmetryToggleCommand(&mesh(), cameraView, editMode);
    }
    // File → Open (Ctrl+O): native-primary "All supported" dialog; a .v3d
    // load becomes the current document. `file.load` is also the id the
    // HTTP /api/command path drives via setPath(), so it must stay
    // registered with the open framing (setPath bypasses the dialog).
    reg.commandFactories["file.load"] = () {
        auto c = new FileLoad(&mesh(), cameraView, editMode, &document, &gpu, &vertexCache, &edgeCache, &faceCache);
        c.configure(FileLoadMode.open);
        return cast(Command) c;
    };
    reg.commandFactories["file.open"] = reg.commandFactories["file.load"];
    // File → Save (Ctrl+S): write to the remembered .v3d path, else prompt.
    reg.commandFactories["file.save"] = () {
        auto c = new FileSave(&mesh(), cameraView, editMode, &document);
        c.configure(FileSaveMode.save);
        return cast(Command) c;
    };
    // File → Save As (Ctrl+Shift+S): always prompt, native .v3d.
    reg.commandFactories["file.saveAs"] = () {
        auto c = new FileSave(&mesh(), cameraView, editMode, &document);
        c.configure(FileSaveMode.saveAs);
        return cast(Command) c;
    };
    // Import ▸ X — single-format open dialog -> FileLoad (importSingle mode
    // leaves the current document untitled). One id per interchange format.
    //
    // NOTE: a plain `foreach`-body closure would capture the loop variable by
    // REFERENCE — in D every delegate would share one storage slot and see the
    // LAST ext (.fbx), so every Import/Export item opened an FBX dialog. (The
    // `immutable ext = importExt;` idiom does NOT create a fresh per-iteration
    // binding in D.) Pass ext as a function parameter so each delegate closes
    // over its own copy.
    CommandFactory importFactory(string ext) {
        return () {
            auto c = new FileLoad(&mesh(), cameraView, editMode, &document, &gpu, &vertexCache, &edgeCache, &faceCache);
            c.configure(FileLoadMode.importSingle, ext);
            return cast(Command) c;
        };
    }
    foreach (importExt; [".lwo", ".obj", ".gltf", ".fbx"])
        reg.commandFactories["file.import" ~ importExt] = importFactory(importExt);
    // Export ▸ X — single-format save dialog -> FileSave (exportSingle mode
    // leaves the current document path untouched). FBX writes via assimp's
    // binary FBX exporter (unit-scale handled in io.scene_export). Same
    // per-ext closure-capture care as the import loop above.
    CommandFactory exportFactory(string ext) {
        return () {
            auto c = new FileSave(&mesh(), cameraView, editMode, &document);
            c.configure(FileSaveMode.exportSingle, ext);
            return cast(Command) c;
        };
    }
    foreach (exportExt; [".lwo", ".obj", ".gltf", ".fbx"])
        reg.commandFactories["file.export" ~ exportExt] = exportFactory(exportExt);
    // "File → New" = empty scene. Wraps SceneReset with the
    // already-supported `setEmpty(true)` mode; undo restores
    // whatever was open before.
    reg.commandFactories["file.new"] = () {
        auto c = new SceneReset(&mesh(), cameraView, editMode,
                                 &gpu, &vertexCache, &edgeCache, &faceCache,
                                 &editMode, &cameraView,
                                 () { setActiveTool(null); resetAllPipeStages(); });
        c.setDocument(&document);
        c.setEmpty(true);
        c.setPromoteHook((EditMode m) => promoteGeometryType(m));
        return cast(Command) c;
    };
    {
        import commands.file.quit : FileQuit;
        reg.commandFactories["file.quit"] = () => cast(Command)
            new FileQuit(&mesh(), cameraView, editMode, () { running = false; });
    }
    reg.commandFactories["mesh.subdivide"] = () => cast(Command)
        new Subdivide(&mesh(), cameraView, editMode,
                      &gpu, &vertexCache, &edgeCache, &faceCache,
                      () => setActiveTool(null));
    reg.commandFactories["mesh.subdivide_faceted"] = () => cast(Command)
        new SubdivideFaceted(&mesh(), cameraView, editMode,
                             &gpu, &vertexCache, &edgeCache, &faceCache,
                             () => setActiveTool(null));
    reg.commandFactories["mesh.triple"] = () => cast(Command)
        new MeshTriple(&mesh(), cameraView, editMode,
                       &gpu, &vertexCache, &edgeCache, &faceCache,
                       () => setActiveTool(null));
    reg.commandFactories["mesh.quadruple"] = () => cast(Command)
        new MeshQuadruple(&mesh(), cameraView, editMode,
                          &gpu, &vertexCache, &edgeCache, &faceCache,
                          () => setActiveTool(null));
    reg.commandFactories["mesh.detriangulate"] = () => cast(Command)
        new MeshDetriangulate(&mesh(), cameraView, editMode,
                              &gpu, &vertexCache, &edgeCache, &faceCache,
                              () => setActiveTool(null));
    reg.commandFactories["mesh.mergeFaces"] = () => cast(Command)
        new MeshMergeFaces(&mesh(), cameraView, editMode,
                           &gpu, &vertexCache, &edgeCache, &faceCache,
                           () => setActiveTool(null));
    reg.commandFactories["mesh.subpatch_toggle"] = () => cast(Command)
        new SubpatchToggle(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.setMaterial"] = () => cast(Command)
        new MeshSetMaterial(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.setPart"] = () => cast(Command)
        new MeshSetPart(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.split_edge"] = () => cast(Command)
        new MeshSplitEdge(&mesh(), cameraView, editMode, &gpu,
                          &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.addPoint"] = () => cast(Command)
        new MeshAddPoint(&mesh(), cameraView, editMode, &gpu,
                         &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.splitFace"] = () => cast(Command)
        new MeshSplitFace(&mesh(), cameraView, editMode, &gpu,
                          &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.edgeJoin"] = () => cast(Command)
        new MeshEdgeJoin(&mesh(), cameraView, editMode, &gpu,
                         &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.spinEdge"] = () => cast(Command)
        new MeshSpinEdge(&mesh(), cameraView, editMode, &gpu,
                         &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.addLoop"] = () => cast(Command)
        new MeshAddLoop(&mesh(), cameraView, editMode, &gpu,
                        &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.loopSlice"] = () => cast(Command)
        new MeshLoopSlice(&mesh(), cameraView, editMode, &gpu,
                          &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.edge_extrude"] = () => cast(Command)
        new MeshEdgeExtrude(&mesh(), cameraView, editMode, &gpu,
                            &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.vertexExtrude"] = () => cast(Command)
        new MeshVertexExtrude(&mesh(), cameraView, editMode, &gpu,
                              &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.vertexBevel"] = () => cast(Command)
        new MeshVertexBevel(&mesh(), cameraView, editMode, &gpu,
                            &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.poly_inset"] = () => cast(Command)
        new MeshPolygonInset(&mesh(), cameraView, editMode, &gpu,
                             &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.spikey"] = () => cast(Command)
        new MeshSpikey(&mesh(), cameraView, editMode, &gpu,
                       &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.bevel"] = () => cast(Command)
        new MeshBevel(&mesh(), cameraView, editMode, &gpu,
                      &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["poly.extrude"] = () => cast(Command)
        new MeshFaceExtrude(&mesh(), cameraView, editMode, &gpu,
                            &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.bridge"] = () => cast(Command)
        new MeshBridge(&mesh(), cameraView, editMode, &gpu,
                       &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.axisSlice"] = () => cast(Command)
        new MeshAxisSlice(&mesh(), cameraView, editMode, &gpu,
                          &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.julienne"] = () => cast(Command)
        new MeshJulienne(&mesh(), cameraView, editMode, &gpu,
                         &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.screenSlice"] = () => cast(Command)
        new MeshScreenSlice(&mesh(), cameraView, editMode, &gpu,
                            &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.edgeSlice"] = () => cast(Command)
        new MeshEdgeSlice(&mesh(), cameraView, editMode, &gpu,
                          &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.thicken"] = () => cast(Command)
        new MeshThicken(&mesh(), cameraView, editMode, &gpu,
                        &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.smooth_shift"] = () => cast(Command)
        new MeshSmoothShift(&mesh(), cameraView, editMode, &gpu,
                            &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.edge_extend"] = () => cast(Command)
        new MeshEdgeExtend(&mesh(), cameraView, editMode, &gpu,
                           &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.move_vertex"] = () => cast(Command)
        new MeshMoveVertex(&mesh(), cameraView, editMode, &gpu,
                           &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.addVertex"] = () => cast(Command)
        new MeshVertexNew(&mesh(), cameraView, editMode, &gpu,
                          &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.centerVertices"] = () => cast(Command)
        new MeshCenterVertices(&mesh(), cameraView, editMode, &gpu,
                               &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.setPosition"] = () => cast(Command)
        new MeshSetPosition(&mesh(), cameraView, editMode, &gpu,
                            &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.delete"] = () => cast(Command)
        new MeshDelete(&mesh(), cameraView, editMode, &gpu,
                       &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.remove"] = () => cast(Command)
        new MeshRemove(&mesh(), cameraView, editMode, &gpu,
                       &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.flip"] = () => cast(Command)
        new MeshFlip(&mesh(), cameraView, editMode, &gpu,
                     &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.duplicate"] = () => cast(Command)
        new MeshDuplicate(&mesh(), cameraView, editMode, &gpu,
                          &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.copy"] = () => cast(Command)
        new MeshCopy(&mesh(), cameraView, editMode, &gpu,
                     &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.paste"] = () => cast(Command)
        new MeshPaste(&mesh(), cameraView, editMode, &gpu,
                      &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.cut"] = () => cast(Command)
        new MeshCut(&mesh(), cameraView, editMode, &gpu,
                    &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.mirror"] = () => cast(Command)
        new MeshMirror(&mesh(), cameraView, editMode, &gpu,
                       &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.symmetrize"] = () => cast(Command)
        new MeshSymmetrize(&mesh(), cameraView, editMode, &gpu,
                           &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.array"] = () => cast(Command)
        new MeshArray(&mesh(), cameraView, editMode, &gpu,
                      &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.radial_array"] = () => cast(Command)
        new MeshRadialArray(&mesh(), cameraView, editMode, &gpu,
                            &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.sweep"] = () => cast(Command)
        new MeshSweep(&mesh(), cameraView, editMode, &gpu,
                      &vertexCache, &edgeCache, &faceCache);
    // Aliases — select.delete and select.remove delegate to the
    // same factory delegates as mesh.delete / mesh.remove respectively.
    reg.commandFactories["select.delete"] = reg.commandFactories["mesh.delete"];
    reg.commandFactories["select.remove"] = reg.commandFactories["mesh.remove"];
    reg.commandFactories["vert.merge"] = () => cast(Command)
        new MeshVertMerge(&mesh(), cameraView, editMode, &gpu,
                          &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.weldVertexPair"] = () => cast(Command)
        new MeshWeldVertexPair(&mesh(), cameraView, editMode, &gpu,
                               &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["poly.unify"] = () => cast(Command)
        new MeshUnify(&mesh(), cameraView, editMode, &gpu,
                      &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.cleanup"] = () => cast(Command)
        new MeshCleanup(&mesh(), cameraView, editMode, &gpu,
                        &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["vert.join"] = () => cast(Command)
        new MeshVertJoin(&mesh(), cameraView, editMode, &gpu,
                         &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.collapse"] = () => cast(Command)
        new MeshCollapse(&mesh(), cameraView, editMode, &gpu,
                         &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.vertexSplit"] = () => cast(Command)
        new MeshVertexSplit(&mesh(), cameraView, editMode, &gpu,
                            &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.reduce"] = () => cast(Command)
        new MeshReduce(&mesh(), cameraView, editMode, &gpu,
                       &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.makePolygon"] = () => cast(Command)
        new MeshMakePolygon(&mesh(), cameraView, editMode, &gpu,
                            &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.select"] = () => cast(Command)
        (new MeshSelect(&mesh(), cameraView, editMode, &editMode))
            .setPromoteHook((EditMode m) => promoteGeometryType(m));
    reg.commandFactories["mesh.transform"] = () => cast(Command)
        new MeshTransform(&mesh(), cameraView, editMode, &gpu,
                          &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.quantize"] = () => cast(Command)
        new MeshQuantize(&mesh(), cameraView, editMode, &gpu,
                         &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.jitter"] = () => cast(Command)
        new MeshJitter(&mesh(), cameraView, editMode, &gpu,
                       &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.weightmap.create"] = () => cast(Command)
        new WeightmapCreate(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.weightmap.remove"] = () => cast(Command)
        new WeightmapRemove(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.weightmap.rename"] = () => cast(Command)
        new WeightmapRename(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.weightmap.set"] = () => cast(Command)
        new WeightmapSet(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.flip"] = () => cast(Command)
        new UvFlip(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.mirror"] = () => cast(Command)
        new UvMirror(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.rotate"] = () => cast(Command)
        new UvRotate(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.project"] = () => cast(Command)
        new UvProject(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.fit"] = () => cast(Command)
        new UvFit(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.pack"] = () => cast(Command)
        new UvPack(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.delete"] = () => cast(Command)
        new UvDelete(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.rename"] = () => cast(Command)
        new UvRename(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.copy"] = () => cast(Command)
        new UvCopy(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.clear"] = () => cast(Command)
        new UvClear(&mesh(), cameraView, editMode);
    reg.commandFactories["uv.relax"] = () => cast(Command)
        new UvRelax(&mesh(), cameraView, editMode);
    reg.commandFactories["mesh.edge_slide"] = () => cast(Command)
        new MeshEdgeSlide(&mesh(), cameraView, editMode, &gpu,
                          &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.smooth"] = () => cast(Command)
        new MeshSmooth(&mesh(), cameraView, editMode, &gpu,
                       &vertexCache, &edgeCache, &faceCache);
    // Headless aliases for the Convolve tools — same shape
    // as prim.cube above: tool.set <id> on; tool.attr <id> ...;
    // tool.doApply. The command form bundles the activation pair so
    // headless callers don't have to manage the tool lifecycle.
    reg.commandFactories["xfrm.smooth"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                &gpu, &vertexCache, &edgeCache, &faceCache,
                                "xfrm.smooth", reg.toolFactories["xfrm.smooth"]);
    reg.commandFactories["xfrm.jitter"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                &gpu, &vertexCache, &edgeCache, &faceCache,
                                "xfrm.jitter", reg.toolFactories["xfrm.jitter"]);
    reg.commandFactories["xfrm.quantize"] = () => cast(Command)
        new ToolHeadlessCommand(&mesh(), cameraView, editMode,
                                &gpu, &vertexCache, &edgeCache, &faceCache,
                                "xfrm.quantize", reg.toolFactories["xfrm.quantize"]);
    reg.commandFactories["mesh.linear_align"] = () => cast(Command)
        new MeshLinearAlign(&mesh(), cameraView, editMode, &gpu,
                            &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.align"] = () => cast(Command)
        new MeshAlign(&mesh(), cameraView, editMode, &gpu,
                      &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.radial_align"] = () => cast(Command)
        new MeshRadialAlign(&mesh(), cameraView, editMode, &gpu,
                            &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.vertex_edit"] = () => cast(Command)
        new MeshVertexEdit(&mesh(), cameraView, editMode, &gpu,
                           &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.bevel_edit"] = () => cast(Command)
        new MeshBevelEdit(&mesh(), cameraView, editMode, &gpu,
                          &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["scene.reset"] = () {
        auto c = new SceneReset(&mesh(), cameraView, editMode, &gpu,
                       &vertexCache, &edgeCache, &faceCache,
                       &editMode, &cameraView,
                       () { setActiveTool(null); resetAllPipeStages(); });
        c.setDocument(&document);
        c.setPromoteHook((EditMode m) => promoteGeometryType(m));
        return cast(Command) c;
    };
    reg.commandFactories["scene.loadMesh"] = () => cast(Command)
        (new MeshLoadRaw(&mesh(), cameraView, editMode, &gpu,
                         &vertexCache, &edgeCache, &faceCache,
                         &editMode, &cameraView, () => setActiveTool(null)))
        .setPromoteHook((EditMode m) => promoteGeometryType(m));
    reg.commandFactories["history.undo"] = () => cast(Command)
        new HistoryUndo(&mesh(), cameraView, editMode, history);
    reg.commandFactories["history.redo"] = () => cast(Command)
        new HistoryRedo(&mesh(), cameraView, editMode, history);
    reg.commandFactories["history.show"] = () => cast(Command)
        new HistoryShow(&mesh(), cameraView, editMode,
                        () { showHistoryPanel = !showHistoryPanel; });
    // Phase 3 of the history-panel design doc — backing
    // commands for the panel's right-click context menu.
    reg.commandFactories["history.clear"] = () => cast(Command)
        new HistoryClear(&mesh(), cameraView, editMode,
                         () { history.clear(); });
    // Test-automation only: flip the interactive edge-extrude undo-tracker toggle
    // (VIBE3D_UNDO_TRACKER) at runtime so the parity-gate test can run the same
    // sequence under both the snapshot and the delta path in one instance.
    // Reuses HistoryClear's closure wrapper (SideEffect, unrecorded). Not in any
    // menu / UI; see doc/undo_change_tracker_plan.md Phase 2 §D.
    reg.commandFactories["undo.tracker.on"] = () => cast(Command)
        new HistoryClear(&mesh(), cameraView, editMode,
            () { import exTracker = tools.edge_extrude;
                 import enTracker = tools.edge_extend;
                 exTracker.setUndoTrackerEnabled(true);
                 enTracker.setUndoTrackerEnabled(true); });
    reg.commandFactories["undo.tracker.off"] = () => cast(Command)
        new HistoryClear(&mesh(), cameraView, editMode,
            () { import exTracker = tools.edge_extrude;
                 import enTracker = tools.edge_extend;
                 exTracker.setUndoTrackerEnabled(false);
                 enTracker.setUndoTrackerEnabled(false); });
    // Test-automation only: engage / release the history-service lockout (the
    // hard gate that freezes record/undo/redo/fire — distinct from Suspend) so
    // a test can assert that locked-out recording is a no-op and /api/undo/status
    // reports lockout:true. Reuses HistoryClear's closure wrapper (SideEffect,
    // unrecorded); not in any menu / UI. Mirrors the undo.tracker.* commands.
    reg.commandFactories["undo.lockout.on"] = () => cast(Command)
        new HistoryClear(&mesh(), cameraView, editMode,
            () { history.setLockout(true); });
    reg.commandFactories["undo.lockout.off"] = () => cast(Command)
        new HistoryClear(&mesh(), cameraView, editMode,
            () { history.setLockout(false); });
    // Test-automation only: explicit undoability-override probes. The first is a
    // Model command that opts OUT (UndoSuppress) → no undo entry; the second is a
    // SideEffect command that opts IN (UndoForce) → entry lands. Drives both
    // override branches of isUndoable() through the normal dispatch path.
    reg.commandFactories["undo.test.suppress"] = () => cast(Command)
        new UndoSuppressNoop(&mesh(), cameraView, editMode);
    reg.commandFactories["undo.test.force"] = () => cast(Command)
        new UndoForceNoop(&mesh(), cameraView, editMode);
    reg.commandFactories["history.saveAsScript"] = () => cast(Command)
        new HistorySaveAsScript(&mesh(), cameraView, editMode,
            () {
                string[] lines;
                // ToolLifecycle entries (tool.deactivate) are not registered as
                // command factories and cannot be replayed — exclude them so the
                // script contains only replayable lines.
                foreach (ref e; history.undoEntriesVisible()) {
                    string line = e.args.length > 0
                        ? (e.commandName ~ " " ~ e.args) : e.commandName;
                    lines ~= line;
                }
                return lines;
            });
    // Phase 7 of the history-panel design doc — macro
    // recorder commands backing the History panel's Rec/Stop/Save
    // strip. Both commands route through the existing argstring
    // dispatcher, so /api/command and the panel buttons share one
    // path.
    reg.commandFactories["macro.record"] = () => cast(Command)
        new MacroRecord(&mesh(), cameraView, editMode, macroRecorder);
    reg.commandFactories["macro.saveRecorded"] = () => cast(Command)
        new MacroSaveRecorded(&mesh(), cameraView, editMode, macroRecorder);

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
            setActiveTool(reg.toolFactories[id]());
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
        httpServer.setCameraDataProvider(() => cameraView.toJson());

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

        // POST /api/camera — set live View. Accepts azimuth, elevation,
        // distance (radians/world-units) and optional focus[x,y,z] +
        // width/height. Used by the cross-engine drag test to align
        // vibe3d's camera with a reference engine's before replaying.
        httpServer.setCameraSetHandler((JSONValue p) {
            import math : Vec3;
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
            if ("azimuth" in p)   cameraView.azimuth   = floatFrom("azimuth",   cameraView.azimuth);
            if ("elevation" in p) cameraView.elevation = floatFrom("elevation", cameraView.elevation);
            if ("distance" in p)  cameraView.distance  = floatFrom("distance",  cameraView.distance);
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
                cameraView.focus = Vec3(comp("x", cameraView.focus.x),
                                        comp("y", cameraView.focus.y),
                                        comp("z", cameraView.focus.z));
            }
            // Optional viewport resize.
            if ("width" in p && "height" in p) {
                cameraView.setSize(
                    cast(int)floatFrom("width",  cameraView.width),
                    cast(int)floatFrom("height", cameraView.height));
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
        httpServer.setRegistryProvider(() {
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
            buf.put(`]}`);
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
            subj.viewport         = cameraView.viewport();

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
            auto vp = cameraView.viewport();
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

            auto vp = cameraView.viewport();
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
            subj.viewport = cameraView.viewport();

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
                } else if (history.refireActive) {
                    if (!history.fire(cmd))
                        throw new Exception("command '" ~ id ~ "' did not apply");
                } else {
                    if (!cmd.apply())
                        throw new Exception("command '" ~ id ~ "' did not apply");
                    // Programmatic command-dispatch path: route through
                    // recordCoalescing() so consecutive COMPATIBLE delta edits
                    // (same targets, same edit label) collapse into a single
                    // undo entry. compareOp() defaults to Different for every
                    // command except the opted-in delta edit, so every other
                    // command appends exactly as record() would. Interactive
                    // tool commits stay on record() (one entry per gesture).
                    history.recordCoalescing(cmd);
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
            if (history.refireActive) {
                if (!history.fire(cmd))
                    throw new Exception("mesh.select did not apply");
            } else {
                if (!cmd.apply())
                    throw new Exception("mesh.select did not apply");
                history.record(cmd);
            }
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
            if (history.refireActive) {
                if (!history.fire(cmd))
                    throw new Exception("mesh.transform did not apply");
            } else {
                if (!cmd.apply())
                    throw new Exception("mesh.transform did not apply");
                history.record(cmd);
            }
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
            // The host now owns the no-tool falloff drag (step 3 of the
            // stage-gizmo refactor); a reset must drop any in-flight drag.
            pipeGizmoHost.cancelDrag();
            {
                import ai.debug_trace : clearLatestAiDebugTraces;
                clearLatestAiDebugTraces();
            }
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
        }
    }

    // Run a Command through the same dispatch the HTTP /api/command path
    // uses: refire-aware apply, history.record on success. Used by both
    // keyboard shortcut and UI-button click sites so they're uniformly
    // undoable. Silently no-ops on null / apply()-failure (e.g. file.load
    // when the user cancels the native dialog).
    void runCommand(Command cmd) {
        if (cmd is null) return;
        if (history.refireActive) {
            history.fire(cmd);
        } else {
            if (cmd.apply())
                history.record(cmd);
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
        subj.viewport         = cameraView.viewport();
        vts.put(&subj);
        if (g_pipeCtx !is null)
            g_pipeCtx.pipeline.evaluate(vts);
    }

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
    // drag. The cancel is gated to the UNDO direction: a redo never cancels an
    // open session (there is nothing to redo into one).
    // Returns true if anything happened (edit cancelled OR stack moved).
    bool navHistory(bool isUndo) {
        if (isUndo && activeTool !is null && activeTool.hasUncommittedEdit()) {
            activeTool.cancelUncommittedEdit();
            if (activeTool !is null && !activeTool.hasUncommittedEdit()) {
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
        if (!io.WantCaptureMouse)
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
                Viewport vp2 = cameraView.viewport();
                if (radialFalloffRMBDown(btn.x, btn.y, ctrl, vp2))
                    return;
                // Plane projection failed (camera aligned to plane);
                // fall through to lasso so the click isn't lost.
            }
            if (elementFalloffActive()) {
                Viewport vp2 = cameraView.viewport();
                if (elementFalloffRMBDown(btn.x, btn.y, vp2))
                    return;
                // Ray-parallel-to-camera-back is the only failure
                // mode (degenerate camera state); fall through.
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
            if (btn.button == SDL_BUTTON_LEFT && !io.WantCaptureMouse
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
            Viewport vpg = cameraView.viewport();
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
            if (rmbPath.length >= 3) {
                SDL_Keymod mods = SDL_GetModState();
                bool shift = (mods & KMOD_SHIFT) != 0;
                bool ctrl  = (mods & KMOD_CTRL)  != 0;
                Viewport vp2 = cameraView.viewport();
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
                            symmetricSelectFace(&mesh(), cameraView, editMode,
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
                                symmetricSelectFace(&mesh(), cameraView, editMode,
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
                                symmetricSelectVertex(&mesh(), cameraView, editMode,
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
                                symmetricSelectVertex(&mesh(), cameraView, editMode,
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
                            symmetricSelectEdge(&mesh(), cameraView, editMode,
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
                                symmetricSelectEdge(&mesh(), cameraView, editMode,
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
        cameraView.zoom(wheel.y * 10);
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
                Viewport vp2 = cameraView.viewport();
                radialFalloffRMBMotion(mot.x, mot.y, vp2);
                return;
            }
            if (elementFalloffRMBDragging()) {
                Viewport vp2 = cameraView.viewport();
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
            Viewport vpg = cameraView.viewport();
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

        if      (dragMode == DragMode.Orbit) cameraView.orbit(dx, dy);
        else if (dragMode == DragMode.Zoom)  cameraView.zoom(dx);
        else if (dragMode == DragMode.Pan)   cameraView.pan(dx, dy);

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
        if (io.WantCaptureMouse || doingCameraDrag) return;
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
            symmetricSelectVertex(&mesh(), cameraView, editMode,
                                  hoveredVertex, /*deselect=*/false);
        else if (dragMode == DragMode.SelectRemove)
            symmetricSelectVertex(&mesh(), cameraView, editMode,
                                  hoveredVertex, /*deselect=*/true);
    }

    void pickEdges(ref Viewport vp, bool doingCameraDrag) {
        if (activeTool !is null && activeTool.isDragging()) return;  // freeze hover mid-drag
        hoveredEdge = -1;
        if (io.WantCaptureMouse || doingCameraDrag) return;
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
            symmetricSelectEdge(&mesh(), cameraView, editMode,
                                hoveredEdge, /*deselect=*/false);
        else if (dragMode == DragMode.SelectRemove)
            symmetricSelectEdge(&mesh(), cameraView, editMode,
                                hoveredEdge, /*deselect=*/true);
    }

    void pickFaces(ref Viewport vp, bool doingCameraDrag) {
        if (activeTool !is null && activeTool.isDragging()) return;  // freeze hover mid-drag
        hoveredFace = -1;
        if (io.WantCaptureMouse || doingCameraDrag) return;
        if (activeTool is null) {
            if (editMode != EditMode.Polygons) return;
        } else {
            if (!activeTool.wantsHoverForType(EditMode.Polygons)) return;
        }

        int mx, my;
        queryMouse(mx, my);

        // Offscreen ID buffer: every triangle gets its source face index
        // as the rasterised colour, GPU picks the closest face per pixel
        // automatically. Single-pixel readback (r=0) — faces tile the
        // screen so any pixel inside a face's silhouette resolves to
        // that face. Subpatch translation via gpu.faceOriginGpu inside
        // GpuSelectBuffer.pick.
        int hit = gpuSelect.pick(SelectMode.Face, mx, my, /*r=*/0,
                                  mesh, gpu, vp);
        if (hit < 0) return;

        hoveredFace = hit;
        if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
            symmetricSelectFace(&mesh(), cameraView, editMode,
                                hoveredFace, /*deselect=*/false);
        else if (dragMode == DragMode.SelectRemove)
            symmetricSelectFace(&mesh(), cameraView, editMode,
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
        Viewport vp = cameraView.viewport();
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
        Viewport vp = cameraView.viewport();
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

    // 1-px black outline around the last ImGui item.
    // Right and bottom edges are drawn ON rmax so adjacent buttons' top/left
    // (drawn at their own rmin) land on the SAME pixel, producing a 1-pixel
    // shared border rather than two abutting lines.
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

    void drawSidePanel() {
        pushPanelChromeStyle();
        ImGui.SetNextWindowPos(layout.sidePos, ImGuiCond.Always);
        ImGui.SetNextWindowSize(layout.sideSize, ImGuiCond.Always);
        if (ImGui.Begin("Mesh Info", null,
                        ImGuiWindowFlags.NoTitleBar |
                        ImGuiWindowFlags.NoResize |
                        ImGuiWindowFlags.NoMove   |
                        ImGuiWindowFlags.NoCollapse))
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
                bool effDisabled = btn.disabled || modeBlocked;
                if (renderStyledButton(label, sc, on, isCommand,
                                       ImVec2(-1, 0), effDisabled)) {
                    if (action.kind == ActionKind.popup)
                        ImGui.OpenPopup("##popup" ~ variant ~ "_" ~ btn.label);
                    else
                        dispatchAction(action);
                }
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
        ImGui.SetNextWindowPos(layout.statusPos, ImGuiCond.Always);
        ImGui.SetNextWindowSize(layout.statusSize, ImGuiCond.Always);
        if (ImGui.Begin("Status line", null,
                        ImGuiWindowFlags.NoTitleBar |
                        ImGuiWindowFlags.NoResize |
                        ImGuiWindowFlags.NoMove   |
                        ImGuiWindowFlags.NoCollapse))
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
                    if (renderStyledButton(label, sc, on, /*isCommand=*/true,
                                           ImVec2(effW, 0))) {
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

    void drawTabPanel() {
        pushPanelChromeStyle();
        ImGui.SetNextWindowPos(layout.tabPos, ImGuiCond.Always);
        ImGui.SetNextWindowSize(layout.tabSize, ImGuiCond.Always);
        if (ImGui.Begin("Tab bar", null,
                        ImGuiWindowFlags.NoTitleBar |
                        ImGuiWindowFlags.NoResize   |
                        ImGuiWindowFlags.NoMove     |
                        ImGuiWindowFlags.NoCollapse))
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
        ImGui.SetNextWindowPos(ImVec2(layout.sideW + 10, 540),
                               ImGuiCond.FirstUseEver);
        ImGui.SetNextWindowSize(ImVec2(260, 240), ImGuiCond.FirstUseEver);
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

        if (!testMode && io.WantCaptureMouse &&
            (ev.type == SDL_MOUSEBUTTONDOWN ||
             ev.type == SDL_MOUSEBUTTONUP   ||
             ev.type == SDL_MOUSEMOTION      ||
             ev.type == SDL_MOUSEWHEEL))
            return true;

        if (io.WantTextInput &&
            (ev.type == SDL_KEYDOWN || ev.type == SDL_KEYUP))
            return true;

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
        // ---- Playback: push due events before polling ----
        if (playbackMode) evPlay.tick();
        // httpServer is always constructed now; only drain the request queues
        // when the listener is actually up (start() called). Skipped entirely
        // in a release/no-http run, where no thread ever posts requests.
        if (httpServer.running) {
            httpServer.tickEventPlayer();
            httpServer.tickReset();
            httpServer.tickModel();
            httpServer.tickPipeEval();
            httpServer.tickPath();
            httpServer.tickCommand();
            httpServer.tickSelection();
            httpServer.tickTransform();
            httpServer.tickLoadMesh();
            httpServer.tickCameraSet();
            httpServer.tickGpuSurface();
            httpServer.tickRefire();
            httpServer.tickBlock();
            httpServer.tickUndo();
            httpServer.tickJump();
        }

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


        cameraView.setSize(layout.vpW, layout.vpH);

        Viewport vp = cameraView.viewport();

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

        // ---- ImGui ----
        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplSDL2_NewFrame();
        ImGui.NewFrame();

        drawSidePanel();
        drawTabPanel();
        drawStatusBar();
        version (WithRender) drawIPRPanel(&mesh(), cameraView);

        // ---- Layers (floating) ----
        // Same imgui-determinism rule as Tool Properties below: in --test this
        // panel is hidden by default (a test opts in via `ui.layerList show`)
        // so synthetic viewport drags are never captured by it. In a normal run
        // it is always drawn (g_testMode false ⇒ guard passes).
        if (!command.g_testMode || g_layerListShown)
            drawLayerListPanel();

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


        // ---- Gizmo 3D (orientation indicator, bottom-right of 3D view) ----
        // Manual workplane: corner gizmo follows it (visual cue that the
        // local frame is set explicitly). Auto workplane: stay locked to
        // world XYZ — `pickMostFacingPlane` swaps every 45° of camera
        // rotation, which made the corner indicator's X/Y/Z labels jump
        // around as the user orbited. Tool handles still pick the most-
        // facing-camera basis via AxisStage; only the corner indicator
        // is pinned to world here.
        Vec3 gz_a1 = Vec3(1, 0, 0);
        Vec3 gz_n  = Vec3(0, 1, 0);
        Vec3 gz_a2 = Vec3(0, 0, 1);
        if (auto wp = cast(WorkplaneStage)g_pipeCtx.pipeline.findByTask(TaskCode.Work)) {
            if (!wp.isAuto) {
                wp.currentBasis(gz_n, gz_a1, gz_a2);
            }
        }
        // DrawGizmo uses window-space coords (ImGui foreground drawlist).
        // Anchor at the bottom-left of the 3D viewport: x = sideW + 32
        // (one-gizmo-radius in from the side-panel edge), y = vpY + vpH
        // − 32 (one radius up from the viewport's bottom edge, which
        // sits flush against the top of the status bar). The previous
        // formula `cameraView.height − statusH − 32` was missing the
        // vpY offset, leaving the gizmo `2·statusH` above the real
        // corner where it could collide with a Tool Properties window
        // parked low in the viewport.
        DrawGizmo(cast(float)(layout.vpX + 32),
                  cast(float)(layout.vpY + layout.vpH - 32),
                  cameraView.view, gz_a1, gz_n, gz_a2);

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
            for (size_t i = 1; i < rmbPath.length; i++)
                dl.AddLine(rmbPath[i - 1], rmbPath[i], IM_COL32(0, 255, 255, 220), 1.0f);
            // Closing line: start → end
            dl.AddLine(rmbPath[0], rmbPath[$ - 1], IM_COL32(0, 255, 255, 220), 1.0f);
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
                    }
                } else {
                    gpu.upload(mesh);
                    // Cage upload — invalidate the preview-topology
                    // marker so the next preview activation triggers a
                    // full upload.
                    gpuUploadedPreviewTopVersion = ulong.max;
                }
                gpuUploadedVersion = mesh.mutationVersion;
                gpuUploadedPreview = wantPreview;
            }
        }

        // ---- 3D render ----
        glClearColor(0.36f, 0.40f, 0.42f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        // Restrict rendering to the 3D viewport area (exclude panels).
        float scaleX = cast(float)fbW / winW;
        float scaleY = cast(float)fbH / winH;
        glViewport(cast(int)(layout.vpX   * scaleX),
                   cast(int)(layout.vpGlY * scaleY),
                   cast(int)(cameraView.width  * scaleX),
                   cast(int)(cameraView.height * scaleY));

        // Per-item (per-layer) transform — RENDER-ONLY (channels P4). The primary
        // layer's mesh is drawn through its composed item matrix; the mesh
        // vertices NEVER move (pick/snap/action-center/applyTRS all keep reading
        // `mesh.vertices[i]` as LOCAL points, so they stay self-consistent for
        // free — `layer.xform` is read at EXACTLY two draw feed-sites and NOWHERE
        // else). This is feed-site #1 of 2 (the active/primary layer).
        float[16] itemMatrix = document.primary.xform.composedMatrix();

        // When a tool defers GPU uploads (whole-mesh drag), it applies an
        // accumulated `gpuMatrix` as u_model so the mesh appears correctly without
        // re-uploading vertex data every frame. COMPOSE the item matrix with it
        // (item matrix LEFTMOST), do NOT clobber: the shader applies
        // `u_proj·u_view·u_model·aPos`, so `u_model = itemMatrix · gpuMatrix`
        // places the deferred-drag pose inside the layer's item frame. When no
        // tool override is present `gpuMatrix` is identity, so `meshModel` is just
        // the item matrix. `float[16]` has no `*` operator — use `matMul4`.
        float[16] meshModel = itemMatrix;
        {
            TransformTool tt = cast(TransformTool)activeTool;
            if (tt !is null)
                meshModel = matMul4(itemMatrix, tt.gpuMatrix);
        }

        shader.useProgram(meshModel, cameraView);

        // ---- Grid axis lines (alpha-blended, distance + edge fade) ----
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        // glDepthMask(GL_FALSE);

        // When the workplane is non-auto, draw the grid in its plane
        // (centre + axis1/normal/axis2 basis) instead of world XZ. The
        // grid mesh is built in the local XZ plane (Y=0); the model
        // matrix maps local (X,Y,Z) → workplane (axis1,normal,axis2)
        // so the grid lines lie ON the workplane.
        float[16] gridModel = identityMatrix;
        if (auto wp = cast(WorkplaneStage)g_pipeCtx.pipeline.findByTask(TaskCode.Work)) {
            if (!wp.isAuto) {
                Vec3 n, a1, a2;
                wp.currentBasis(n, a1, a2);
                Vec3 c = wp.center;
                // Column-major: each column is the image of a local axis.
                gridModel = [
                    a1.x, a1.y, a1.z, 0,
                    n.x,  n.y,  n.z,  0,
                    a2.x, a2.y, a2.z, 0,
                    c.x,  c.y,  c.z,  1,
                ];
            }
        }

        gridShader.useProgram(gridModel, cameraView,
            cameraView.distance * 2.0f,
            cast(float)cameraView.width * scaleX, cast(float)cameraView.height * scaleY,
            cast(float)layout.vpX * scaleX, cast(float)layout.vpGlY * scaleY);

        glBindVertexArray(gridVao);
        // Grid lines — gray
        glUniform3f(gridShader.locColor, 0.5f, 0.5f, 0.5f);
        glDrawArrays(GL_LINES, 0, gridOnlyVertCount);
        // X axis — pale red
        glUniform3f(gridShader.locColor, 0.5f, 0.15f, 0.15f);
        glDrawArrays(GL_LINES, gridOnlyVertCount, 2);
        // Z axis — pale blue
        glUniform3f(gridShader.locColor, 0.15f, 0.15f, 0.5f);
        glDrawArrays(GL_LINES, gridOnlyVertCount + 2, 2);
        glBindVertexArray(0);

        // Phase 7.6e: translucent gridded plane drawn at the symmetry
        // plane when SYMM is on. Same gridShader / VAO as the
        // workplane grid; only the model matrix changes, mapping the
        // local XZ plane onto whichever axis the SYMM stage published.
        // Pale orange as a "symmetry is on" cue, distinct from the
        // workplane grid's gray.
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
                gridShader.useProgram(symModel, cameraView,
                    cameraView.distance * 2.0f,
                    cast(float)cameraView.width * scaleX, cast(float)cameraView.height * scaleY,
                    cast(float)layout.vpX * scaleX, cast(float)layout.vpGlY * scaleY);
                glBindVertexArray(gridVao);
                // Pale orange accent.
                glUniform3f(gridShader.locColor, 0.85f, 0.5f, 0.15f);
                glDrawArrays(GL_LINES, 0, gridOnlyVertCount);
                glBindVertexArray(0);
            }
        }

        // glDepthMask(GL_TRUE);
        glDisable(GL_BLEND);

        // ---- Background layers (layers Stage 5) ----
        // Draw every VISIBLE, non-active layer dimmed (faces + edges only — no
        // vertex dots, no selection/hover overlays, per the behaviour table),
        // BEFORE the active pass so the active layer's depth/picking is never
        // disturbed (background depth is written first; the active mesh draws
        // over it with the normal full-bright pass). Lazy GPU upload keyed on
        // the layer's mutationVersion; map entries for layers that stopped being
        // visible-non-active are destroyed + dropped here so GL handles never
        // leak. With one layer the loop body never runs and `bgGpuByLayer` stays
        // empty ⇒ no per-frame cost.
        if (document.layers.length > 1) {
            import std.math : isNaN;
            // 1) Reap stale map entries (hidden / now-active / deleted layers).
            Layer[] toDrop;
            foreach (lyr, bg; bgGpuByLayer) {
                bool stillBg = false;
                // Stage 2b: a layer is a background-GPU candidate iff it is
                // visible and NOT the primary (the derived predicate). This MUST
                // match the dim-draw guard below exactly — if only one flips, a
                // primary != layers[activeIndex] situation would leak or
                // double-destroy BgGpu GL handles.
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

            // 2) Draw each visible non-active layer dimmed. The model matrix is
            //    the layer's composed ITEM transform (channels P4, RENDER-ONLY) —
            //    this is feed-site #2 of 2 for `layer.xform`. Background geometry
            //    is never the active tool's deferred-drag transform, so there is
            //    no gpuMatrix to compose here (clean site). Set per-layer below.
            enum float kBgDim = 0.45f;   // dim brightness for background layers
            foreach (i, lyr; document.layers) {
                // Stage 2b: dim every VISIBLE non-primary layer. Same derived
                // `!isPrimary` predicate as the reap loop above (they flip
                // TOGETHER — see the BgGpu handle-leak note).
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

                // Dimmed faces.
                litShader.useProgram(bgModel, cameraView);
                litShader.setSurfaces(lyr.mesh.surfaces);
                litShader.setDim(kBgDim);
                bg.gpu.drawFaces(litShader);
                litShader.setDim(1.0f);   // restore neutral for the active pass

                // Dimmed edges — no hover/selection (empty masks).
                shader.useProgram(bgModel, cameraView);
                shader.setDim(kBgDim);
                bg.gpu.drawEdges(shader.locColor, -1, []);
                shader.setDim(1.0f);
            }
        }

        // Install the background SNAP sources (layers Stage 5). Stage 2b: the
        // snap set is now the DERIVED `Document.background(l)` (== visible &&
        // !selected). DELIBERATE SEMANTICS FLIP: a *selected-but-non-primary*
        // (foreground) layer is NO LONGER a snap source, and a *deselected
        // visible* layer now IS one — the third "background" state collapsed into
        // selection. (A primary is selected ⇒ background()==false ⇒ excluded, so
        // the prior `i == activeIndex` skip is subsumed.) snapCursor walks these
        // after the active mesh; empty in the single-layer common case ⇒ no extra
        // snap work. Addresses are the Layer objects' stable interior pointers.
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

        // Install item snap frames (Stage 3, all visible layers INCLUDING
        // the active/primary — item snapping snaps to the active item's own
        // pivot/box). The setItemSnapFrames CALL is unconditional so a reset
        // to a one-layer document self-clears prior multi-layer frames.
        {
            import snap : setItemSnapFrames, ItemSnapFrame;
            ItemSnapFrame[] itemFrames;
            foreach (lyr; document.layers) {
                if (!lyr.visible) continue;
                itemFrames ~= buildItemFrame(lyr);
            }
            setItemSnapFrames(itemFrames);
        }

        // Draw faces with Blinn-Phong lighting.
        // Highlight branch in Polygons mode draws face selection +
        // face hover. Tool-driven branch (XfrmTransformTool with
        // falloff.element in Auto/Polygon modes) only kicks in when a face is
        // actually hovered, otherwise we fall through to plain
        // drawFaces — no point routing through drawFacesHighlighted
        // with an empty selection mask and no hover.
        {
            litShader.useProgram(meshModel, cameraView);
            // Material Groups (MG3): push the mesh's surface table into
            // the Materials UBO. Cheap (≤4 KB) and idempotent on
            // surfaces-unchanged frames; the alternative is a per-mesh
            // version counter, not worth the bookkeeping at this size.
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
                checkerShader.useProgram(meshModel, cameraView, 1.0f, 0.5f, 0.1f);  // orange
                glDisable(GL_DEPTH_TEST);
                gpu.drawSelectedFacesOverlay(mesh.selectedFaces);
                glEnable(GL_DEPTH_TEST);
            }
        }

        shader.useProgram(meshModel, cameraView);

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
        {
            import change_bus : MeshEditScope;
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
            } else if (meshChangedFlags & MeshEditScope.Position) {
                // Coords moved, counts unchanged — invalidate without resize.
                vertexCache.invalidate();
                edgeCache.invalidate();
                faceCache.invalidate();
                vertexCache.update(vp);
            } else if (!doingCameraDrag && vertexCache.needsUpdate(vp)) {
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
        // Per-type highlight gates: render the highlight when EITHER
        // the editMode covers that type natively OR an active tool
        // opted into hover for it (Stage 14.9).
        bool showVertHover = (editMode == EditMode.Vertices)
                          || (activeTool !is null
                              && activeTool.wantsHoverForType(EditMode.Vertices));
        bool showEdgeHover = (editMode == EditMode.Edges)
                          || (activeTool !is null
                              && activeTool.wantsHoverForType(EditMode.Edges));
        bool showFaceHover = (editMode == EditMode.Polygons)
                          || (activeTool !is null
                              && activeTool.wantsHoverForType(EditMode.Polygons));

        // ---- Draw edges (with highlights in Edges / Polygons mode) ----
        // Stage 14.9: edge-hover branch also fires when an active
        // tool opted in (showEdgeHover from the gates above) — edges
        // render with `hoveredEdge` highlight and an empty
        // selectedEdges mask so only the hover lights up.
        if (editMode == EditMode.Edges) {
            gpu.drawEdges(shader.locColor, hoveredEdge, mesh.selectedEdges);
        } else if (editMode == EditMode.Polygons) {
            // Build selected-edge mask — rebuild only when selectedFaces changes.
            if (faceSelEdgesPrevSel != mesh.selectedFaces) {
                faceSelEdgesPrevSel = mesh.selectedFaces.dup;
                if (faceSelEdgesCache.length != mesh.edges.length)
                    faceSelEdgesCache = new bool[](mesh.edges.length);
                faceSelEdgesCache[] = false;

                // Fast path: all faces selected → all edges selected.
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
        } else if (showEdgeHover && hoveredEdge >= 0) {
            // Tool wants edge hover but editMode isn't Edges/Polygons.
            // Empty selectedEdges mask → only `hoveredEdge` lights up.
            // Skip drawing entirely when NO edge is currently hovered:
            // falloff.element + Auto otherwise sprays every cage edge in
            // baseline colour over the viewport even when the cursor
            // is on a face (`gpu.drawEdges` renders all edges and
            // colours them per the highlight / selection masks).
            //
            // ElementMove + falloff EdgeLoops: pre-highlight the WHOLE loop
            // ring under the cursor (matches the apply, which expands a picked
            // edge to its loop). Compute the ring→edge-index mask and CACHE it,
            // recomputing only when the hovered edge or topology changes — the
            // loop walk must NOT run every frame.
            const bool[] loopMask =
                (activeTool !is null && activeTool.wantsEdgeLoopHover())
                    ? rebuildLoopHoverMask(hoveredEdge)
                    : (bool[]).init;
            gpu.drawEdges(shader.locColor, hoveredEdge, [], loopMask);
        } else {
            gpu.drawEdges(shader.locColor, -1, []);
        }

        // ---- Vertex dots ----
        // Native Vertices mode always shows the dots (selection state
        // matters even when no hover lands). Tool-driven hover only
        // draws when a vert is actually hovered — without this guard
        // falloff.element + Auto would scatter unrelated dots over the
        // whole mesh.
        if (editMode == EditMode.Vertices) {
            gpu.drawVertices(shader.locColor, hoveredVertex, mesh.selectedVertices);
        } else if (showVertHover && hoveredVertex >= 0) {
            gpu.drawVertices(shader.locColor, hoveredVertex, (bool[]).init);
        }

        // ---- Active tool ----
        if (activeTool) {
            // Step 4 of the stage-gizmo refactor: NO cancel-on-tool-activate
            // here. With one shared host emitter, a no-tool→tool transition
            // just CONTINUES the in-flight falloff drag — the now-active
            // XfrmTransformTool routes the same host through its own shared
            // arbiter cycle. Cancelling every frame would kill a legitimate
            // with-tool falloff drag.
            {
                SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts);
                activeTool.update(vts);
            }
            {
                SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts);
                activeTool.draw(shader, vp, vts);
            }
        } else if (anyFalloffActive()) {
            // No transform tool, but a user-locked falloff is active — route the
            // overlay + interactive handles through the persistent host, using
            // its own no-tool arbiter pool. The host folds in drawFalloffOverlay
            // and gates the gizmo on fp.enabled; the gizmo writes start/end /
            // center/size back to the FalloffStage via tool.pipe.attr, so the
            // next buildToolVts reflects the drag.
            import toolpipe.packets : FalloffPacket;
            SubjectPacket subj; VectorStack vts; buildToolVts(subj, vts);
            FalloffPacket fp;
            if (auto p = vts.get!FalloffPacket()) fp = *p;
            if (fp.enabled)
                pipeGizmoHost.draw(shader, vp, fp, pipeGizmoHost.ownPool());
        }

        // ---- ImGui draw ----
        // Render() must happen AFTER activeTool.draw() so any commands the
        // tool adds to the foreground draw list (snap overlay, falloff
        // overlay, etc.) are picked up by AddDrawListToDrawData — that
        // helper early-returns on an empty CmdBuffer, so adding commands
        // post-Render leaves them out of the ImDrawData snapshot.
        ImGui.Render();
        // Restore full viewport for ImGui rendering.
        glViewport(0, 0, fbW, fbH);
        ImGui_ImplOpenGL3_RenderDrawData(ImGui.GetDrawData());

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
