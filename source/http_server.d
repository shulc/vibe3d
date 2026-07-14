module http_server;

import std.socket;
import std.stdio;
import std.string;
import std.conv;
import std.algorithm;
import std.array;
import std.datetime;
import std.json;
import core.thread;

import mesh : Surface;
import core.atomic;
import perf_probe : g_perf, g_frames;

// For event player functionality
import bindbc.sdl;
import eventlog;
import argstring : parseArgstring, ParsedLine;
import log : logInfo, logWarn, logError;

// ============================================================================
// Generic HTTP-thread <-> main-thread request/response bridge (task 0183 C3).
//
// Every marshaled endpoint used to hand-roll the same atomic-epoch spin/tick
// pair (submit epoch bumped by the HTTP thread, drained by a per-endpoint
// tickX() on the main thread, completed epoch bumped last). That duplication
// is collapsed into one generic primitive here: MainThreadBridge!(Req,Resp)
// holds the epoch pair + a typed request/response payload + a per-bridge
// "service" delegate; each bridge self-registers into HttpServer.bridges at
// construction, so tickAll() can drain every bridge without a hand-maintained
// call list (a bridge that is constructed can never be "forgotten").
//
// Memory ordering (load-bearing — mirrors the old per-endpoint code exactly):
// the HTTP thread writes `req` BEFORE bumping the submitted epoch; the main
// thread's tick() reads `req`/runs `service` and writes `resp` BEFORE storing
// the completed epoch (the LAST statement in tick()); the HTTP thread reads
// `resp` only AFTER submitAndWait() observes the completed epoch catch up.
// Same seq-cst atomicOp/atomicLoad/atomicStore as before, same 2500-iter /
// 2ms sleep timeout. Do not weaken any of this.
//
// Timeout is per-bridge, NOT uniform: submitAndWait() returns a plain bool
// and never synthesizes a timeout body — each call site keeps its own
// bespoke timeout response (silent-ok for reset, noop-false for undo/jump,
// an explicit "timeout waiting for main thread" error string for the rest).
interface IMainThreadBridge {
    void tick();
}

final class MainThreadBridge(Req, Resp) : IMainThreadBridge {
    private shared long submitted;
    private shared long completed;
    Req  req;
    Resp resp;
    private void delegate(ref Req, ref Resp) service;

    this(HttpServer owner, void delegate(ref Req, ref Resp) service) {
        this.service = service;
        owner.bridges ~= this;
    }

    /// HTTP thread: bump the submit epoch and spin until the main thread's
    /// tick() drains it, or maxIters*2ms elapses. Returns false on timeout —
    /// the CALLER decides what timeout body to emit (see file header).
    bool submitAndWait(int maxIters = 2500) {
        immutable long my = atomicOp!"+="(submitted, 1);
        int iters = 0;
        while (atomicLoad(completed) < my) {
            if (++iters > maxIters) return false;
            Thread.sleep(2.msecs);
        }
        return true;
    }

    /// Main thread (called once per frame via HttpServer.tickAll()): runs
    /// the pending request's service body, if any, then publishes it.
    void tick() {
        immutable long sub = atomicLoad(submitted);
        if (sub <= atomicLoad(completed)) return;
        service(req, resp);
        atomicStore(completed, sub);
    }
}

/**
 * Simple HTTP server implementation for D applications
 */
class HttpServer {
    private Socket serverSocket;
    private bool isRunning;
    private ushort port;
    private Thread serverThread;
    private alias ModelDataProvider = string delegate();
    private ModelDataProvider modelDataProvider;
    private alias DetailedModelDataProvider = string delegate();
    private DetailedModelDataProvider detailedModelDataProvider;
    private bool useDetailedProvider = false;
    private alias CameraDataProvider = string delegate(int);
    private CameraDataProvider cameraDataProvider;
    private alias SelectionDataProvider = string delegate();
    private SelectionDataProvider selectionDataProvider;
    // GET /api/tool/handles — the active tool's ToolHandles registry (part
    // id / hover-state / visibility / screen anchor per handle, plus the
    // shared hot/captured part), and GET /api/tool/state — its per-tool
    // transient dump (task 0234, doc/tool_handles_state_plan.md). Both are
    // read-only test-introspection endpoints served straight from the HTTP
    // thread — same quiescence contract as /api/selection: the provider
    // reads live tool state (registered handles, cached viewport, transient
    // fields) with no lock, which is safe because tests only probe between
    // play-events settles, never mid-drag, and the reads MUTATE nothing (no
    // g_pipeCtx cache write, unlike /api/toolpipe/eval or /api/snap, which
    // ARE marshaled to the main thread because their read evaluates the
    // pipeline). Do not extend this no-lock pattern to a tool-state read
    // that would need to mutate shared state to answer.
    private alias ToolHandlesDataProvider = string delegate();
    private ToolHandlesDataProvider toolHandlesDataProvider;
    private alias ToolStateDataProvider = string delegate();
    private ToolStateDataProvider toolStateDataProvider;
    // /api/layers (GET) — JSON layer list. /api/model?layer=N — a layer-aware
    // detailed provider (N=-1 → active layer). Both marshal onto the main
    // thread via the existing model epoch handshake (tickModel).
    private alias LayersDataProvider = string delegate();
    private LayersDataProvider layersDataProvider;
    private alias LayerModelProvider = string delegate(int layer);
    private LayerModelProvider layerModelProvider;
    private alias RecordedEventsProvider = string delegate();
    private RecordedEventsProvider recordedEventsProvider;
    // GET /api/registry — returns {"commands":[...],"tools":[...]} listing
    // every registered command and tool factory id. Read-only snapshot of
    // post-startup-immutable AAs; served directly from the HTTP thread
    // (same thread-safety posture as toolpipeProvider).
    //
    // `?params=1` (task 0365 — param-bounds Phase 3) additionally requests
    // per-id Param schemas (`commandParams`/`toolParams`): the bool arg is
    // whether the caller asked for that mode, so the provider can skip
    // instantiating every factory on the common (registry-listing-only)
    // path. This is the enabler for the fuzz-smoke's static contract check
    // (tests/test_param_bounds.d) — a generic reader of every count-like
    // Param's `.min()/.max()/.enforceBounds()` state without a hand-
    // maintained per-tool table.
    private alias RegistryProvider = string delegate(bool includeParams);
    private RegistryProvider registryProvider;
    private alias ToolPipeProvider = string delegate();
    private ToolPipeProvider toolpipeProvider;
    // /api/toolpipe/eval — runs pipeline.evaluate once and returns the
    // resulting ActionCenterPacket + AxisPacket as JSON. Used by the
    // reference-diff parity harness to read vibe3d's pipe state directly
    // for a given selection without needing to drive the actual tool.
    private alias ToolPipeEvalProvider = string delegate();
    private ToolPipeEvalProvider toolpipeEvalProvider;
    // GET /api/ai/analyze — AI Modeling Copilot Phase 1 (task 0402): runs
    // `ai.analysis.analyzeMesh` over the live mesh and returns the resulting
    // `Finding[]` as JSON. Read-only, no side effects, available regardless
    // of the AI master toggle (this is a raw analysis read; the toggle only
    // gates the later UI phases). Marshaled onto the main thread via
    // analyzeBridge — same hazard as /api/model (risk #4, ai_copilot_plan.md):
    // a raw HTTP-thread provider would read the live Mesh while the main
    // thread mutates it, so this follows the toolpipeEvalProvider bridge
    // pattern, NOT the direct-read snapLastProvider one.
    private alias AiAnalyzeProvider = string delegate();
    private AiAnalyzeProvider aiAnalyzeProvider;
    // /api/snap — POST. Body is the snap-query JSON ({cursor, sx, sy,
    // excludeVerts}); response is the SnapResult JSON. Used by the
    // 7.3 unit tests to probe snap math directly without driving an
    // interactive Move drag through play-events. Read-only, so served
    // straight from the HTTP thread (same convention as
    // toolpipeEvalProvider) — tests are quiescent during probing.
    private alias SnapQueryProvider = string delegate(string requestBody);
    private SnapQueryProvider snapQueryProvider;
    // /api/constrain — POST. Body is {pos:[x,y,z], delta:[x,y,z]};
    // evaluates the pipeline to pull the live ConstrainPacket, snapshots
    // the background sources, and returns the projected point. Mirrors
    // the /api/snap bridge — read-only, served from the HTTP thread.
    private alias ConstrainQueryProvider = string delegate(string requestBody);
    private ConstrainQueryProvider constrainQueryProvider;
    // /api/snap/last — GET. Returns the most recent SnapResult any
    // tool published via snap_render.publishLastSnap (7.3d). Lets
    // headless tests verify the visual-feedback wiring without a
    // screenshot diff.
    private alias SnapLastProvider = string delegate();
    private SnapLastProvider snapLastProvider;
    // /api/path — POST {"t":<float>} or GET ?t=. Evaluates the PATH stage
    // at the requested t and returns value/tangent/length. Marshaled onto
    // the main thread via tickPath() — mirrors the toolpipeEvalProvider
    // pattern (NOT snapLastProvider's direct-read pattern) since path
    // evaluation touches live mesh vertices.
    private alias PathQueryProvider = string delegate(float t);
    private PathQueryProvider pathQueryProvider;
    private alias ResetHandler = void delegate(string primitiveType, bool empty, int param);
    private ResetHandler resetHandler;
    // POST /api/camera — sync bridge to set the live View. Used by
    // the cross-engine drag test to align vibe3d's camera with a
    // reference engine's before replaying a drag through /api/play-events.
    private alias CameraSetHandler = void delegate(JSONValue params);
    private CameraSetHandler cameraSetHandler;
    private bool testMode = false;

    // ----- GET /api/gpu/face-vbo synchronous bridge ------------------------
    // Reads back the live face VBO contents on the GL/main thread. Used by
    // test_subpatch_move to verify that the subpatch surface actually
    // updated after a /api/transform — necessary because the cage-side
    // mesh.vertices snapshot exposed via /api/model can stay in sync even
    // when the GPU fan-out path is silently writing garbage to gpu.faceVbo.
    private alias GpuSurfaceProvider = string delegate();
    private GpuSurfaceProvider gpuSurfaceProvider;

    // ----- /api/model synchronous read bridge ------------------------------
    // The model provider walks mesh.vertices / edges / faces to serialise the
    // current geometry. If it runs on the HTTP thread while the main thread is
    // mutating the mesh (a reset rebuild, an applyTRS write, an undo restore),
    // the walk sees a TORN read — half-updated vertex positions — which surfaces
    // as a flaky "wrong geometry" assertion in tests that read /api/model right
    // after a mutating command (e.g. test_reevaluate under heavy -j parallelism,
    // where CPU contention widens the race window). Marshal the read onto the
    // main thread via the same epoch handshake the mutating endpoints use, so
    // the provider runs at a frame-tick point where the mesh is consistent.

    // ----- /api/toolpipe/eval synchronous read bridge ----------------------
    // Same hazard as /api/model, one level deeper: the eval provider RUNS
    // g_pipeCtx.pipeline.evaluate over the live mesh + selection on the HTTP
    // thread. That both reads mesh/selection mid-mutation AND re-runs the pipe
    // (mutating shared cluster caches in g_pipeCtx) concurrently with the main
    // thread's own per-frame evaluate() — surfacing as a flaky cluster count
    // (e.g. test_acen_local_rotate_parity "expected 2 clusters, got 3" under
    // heavy -j). Marshal it onto the main thread via the same epoch handshake.
    // /api/path is marshaled via its own bridge instance — MUST NOT share
    // pipeEval's epoch pair. A concurrent /api/path + /api/toolpipe/eval
    // would cross-trip each other's spin if they shared epochs (each
    // completed-bump would satisfy the other's spin, returning torn/empty
    // results).

    // ----- /api/command synchronous bridge ---------------------------------
    // The HTTP thread fills req.id/req.params, bumps the bridge's submit
    // epoch, and spins for the main thread's tick() to drain it via
    // commandHandler.
    private alias CommandHandler = void delegate(string id, string paramsJson);
    private CommandHandler commandHandler;
    // Test-automation only: when true, the command bridge's service raises
    // the app's formsInteractiveLatch (via interactiveLatchHook) around the
    // dispatch, so a sequence of tool.pipe.attr writes SHARES one tweak
    // generation — exactly a continuous falloff-handle / slider scrub, which
    // the per-/api-command generation bump otherwise turns into discrete
    // steps. Set per-line by the /api/script?interactive=true handler;
    // consumed + the hook restores the latch in the service body. The
    // interactive end-of-scrub generation bump is the caller's responsibility
    // (a following non-interactive tool.pipe.attr or an explicit /api/script
    // line bumps it), mirroring the forms panel's end-of-scrub hook.
    //
    // req.interactive is a PERSISTENT field on the shared command bridge
    // (constructed once, reused across all 3 command endpoints — argstring,
    // script batch, history-replay). argstring sets it false (discrete);
    // script batch sets it to the request's ?interactive= flag;
    // history-replay does NOT touch it at all — it inherits whatever the
    // previous dispatch left, exactly as before this refactor.
    //
    // Hook the app registers to raise/lower formsInteractiveLatch from the main
    // thread. Null in builds that never wire it (the latch then stays inert and
    // ?interactive=true is a no-op — faithful: a raw command path is discrete).
    private alias InteractiveLatchHook = void delegate(bool raised);
    private InteractiveLatchHook interactiveLatchHook;
    // Forms-engine query (read-back) result. The command handler runs on the
    // main thread inside the command bridge's service and, for a `?`-query
    // command, stashes the boxed JSON value into commandBridge.resp.result
    // via setCmdResult() BEFORE the bridge's tick() stores the completed
    // epoch. The blocked HTTP thread reads it once that catches up and emits
    // it as the response body. The service clears it at entry, so write
    // commands leave it empty (fully backward-compatible).
    //
    // Single-flight precondition: like resp.error, this is a plain unguarded
    // field protected only by the same happens-before the epoch handshake
    // establishes (written before the completed-epoch store, read after the
    // spin observes it) AND by /api/command requests being serialized — each
    // request's spin-wait blocks its connection until the epoch catches up.
    // Concurrent /api/command queries would race this single slot; any future
    // parallel-request work must revisit (per-epoch slot or a lock).

    // ----- /api/select synchronous bridge ----------------------------------
    private alias SelectionHandler = void delegate(string mode, int[] indices);
    private SelectionHandler selectionHandler;

    // ----- /api/transform synchronous bridge -------------------------------
    private alias TransformHandler = void delegate(string kind, JSONValue params);
    private TransformHandler transformHandler;

    // ----- /api/load-mesh synchronous bridge -------------------------------
    // POST /api/load-mesh {"vertices":[[x,y,z],...],"faces":[[i,j,k,...],...]}
    // replaces the live mesh with caller-supplied raw geometry. Test-only
    // injection path (mirrors /api/reset's main-thread bridge): the handler
    // builds a fresh Mesh, rebuilds derived data and refreshes GPU + caches
    // on the main thread, leaving the same consistent post-load state.
    private alias LoadMeshHandler = void delegate(JSONValue params);
    private LoadMeshHandler loadMeshHandler;

    // ----- /api/undo + /api/redo synchronous bridge ------------------------
    // The handler returns true on success (an entry was undone/redone) or
    // false on stack-empty / revert-failure. /api/history is a read-only
    // provider that can be served from the HTTP thread directly (no
    // main-thread sync) since the labels list is a snapshot at request
    // time and any race just yields slightly stale labels.
    private alias UndoRedoHandler = bool delegate();
    private UndoRedoHandler undoHandler;
    private UndoRedoHandler redoHandler;

    // ----- /api/history/jump (multi-step) ----------------------------------
    // CommandHistory.jumpTo(target) called on the main thread via the same
    // sync pattern as /api/undo. `target` is the desired length of undoStack
    // after the jump — 0 = everything undone, undo.length = current, larger
    // walks into the redo stack.
    private alias JumpHandler = bool delegate(size_t target);
    private JumpHandler jumpHandler;

    private alias HistoryProvider = string delegate();   // returns JSON
    private HistoryProvider historyProvider;

    // ----- GET /api/pick — A/B face-pick equivalence oracle (test-only) -----
    // Marshaled onto the main thread: GPU pick needs a GL context; BVH pick
    // reads mesh + GpuMesh state. engine=bvh|gpu is dispatched by the provider.
    private alias PickProvider = string delegate(int x, int y, string engine);
    private PickProvider pickProvider;

    // ----- /api/undo/status provider ---------------------------------------
    // Returns JSON {state, lockout, canUndo, canRedo}. Read-only snapshot of
    // the history service — runs on the HTTP thread like historyProvider.
    private alias UndoStatusProvider = string delegate();
    private UndoStatusProvider undoStatusProvider;

    // ----- /api/history/replay provider ------------------------------------
    // Returns the canonical argstring line for undoStack[index], or "" when
    // the index is out of range. Runs on the HTTP thread (read-only snapshot).
    private alias ReplayProvider = string delegate(size_t index);
    private ReplayProvider replayProvider;

    // ----- /api/refire synchronous bridge ----------------------------------
    // POST /api/refire {"action":"begin"|"end"} opens or closes a refire
    // block on the history. Tools call refireBegin/refireEnd directly on
    // the main thread; this endpoint exists for HTTP-driven tests.
    private alias RefireHandler = void delegate(string action);
    private RefireHandler refireHandler;

    // ----- /api/history/block synchronous bridge ---------------------------
    // POST /api/history/block {"action":"begin","label":"..."} opens a command
    // block; {"action":"end"} closes it. While open, every recorded command is
    // folded into the block and lands as ONE undo entry at end. Same
    // main-thread sync pattern as /api/refire — block state lives on the
    // CommandHistory, which is only safe to touch from the main thread.
    private alias BlockHandler = void delegate(string action, string label);
    private BlockHandler blockHandler;

    // Event player for handling event playback via HTTP
    private EventPlayer eventPlayer;

    // ========================================================================
    // MainThreadBridge instances (task 0183 C3) — one per marshaled endpoint,
    // constructed (and self-registered into `bridges`) in the HttpServer
    // constructor, IN THE SAME ORDER the old hand-written app.d tick list used
    // (reset, model, pipeEval, path, command, selection, transform, loadMesh,
    // cameraSet, gpuSurface, pick, refire, block, undo, jump). Each bridge's
    // `service` delegate closes over `this` (reading the handler/provider
    // fields above AT TICK TIME, so it works even though app.d wires those
    // fields after HttpServer is constructed).
    private IMainThreadBridge[] bridges;

    struct ResetReq  { string type; bool empty; int param; }
    struct ResetResp { }   // errors are thrown by the handler itself (no catch — matches pre-refactor tickReset)
    private MainThreadBridge!(ResetReq, ResetResp) resetBridge;

    struct ModelReq  { int layer = -1; bool detailed; }
    struct ModelResp { string result; string error; }
    private MainThreadBridge!(ModelReq, ModelResp) modelBridge;

    struct PipeEvalReq  { }
    struct PipeEvalResp { string result; string error; }
    private MainThreadBridge!(PipeEvalReq, PipeEvalResp) pipeEvalBridge;

    struct PathReq  { float t; }
    struct PathResp { string result; string error; }
    private MainThreadBridge!(PathReq, PathResp) pathBridge;

    struct CmdReq  { string id; string params; bool interactive; }
    struct CmdResp { string error; string result; }
    private MainThreadBridge!(CmdReq, CmdResp) commandBridge;

    struct SelReq  { string mode; int[] indices; }
    struct SelResp { string error; }
    private MainThreadBridge!(SelReq, SelResp) selectionBridge;

    struct XfReq  { string kind; JSONValue params; }
    struct XfResp { string error; }
    private MainThreadBridge!(XfReq, XfResp) transformBridge;

    struct LoadMeshReq  { JSONValue params; }
    struct LoadMeshResp { string error; }
    private MainThreadBridge!(LoadMeshReq, LoadMeshResp) loadMeshBridge;

    struct CamSetReq  { JSONValue params; }
    struct CamSetResp { string error; }
    private MainThreadBridge!(CamSetReq, CamSetResp) cameraSetBridge;

    struct GpuSurfReq  { }
    struct GpuSurfResp { string result; string error; }
    private MainThreadBridge!(GpuSurfReq, GpuSurfResp) gpuSurfaceBridge;

    struct PickReq  { int x; int y; string engine; }
    struct PickResp { string result; string error; }
    private MainThreadBridge!(PickReq, PickResp) pickBridge;

    struct RefireReq  { string action; }
    struct RefireResp { string error; }
    private MainThreadBridge!(RefireReq, RefireResp) refireBridge;

    struct BlockReq  { string action; string label; }
    struct BlockResp { string error; }
    private MainThreadBridge!(BlockReq, BlockResp) blockBridge;

    struct UndoReq  { bool isRedo; }
    struct UndoResp { bool result; }
    private MainThreadBridge!(UndoReq, UndoResp) undoBridge;

    struct JumpReq  { size_t target; }
    struct JumpResp { bool result; }
    private MainThreadBridge!(JumpReq, JumpResp) jumpBridge;

    // GET /api/toolpipe — own bridge, own epoch pair (MUST NOT share
    // pipeEvalBridge's — same rule as pathBridge, see the header note above).
    // The null-provider case is handled entirely on the HTTP thread (200
    // {"stages":[]}), so this bridge's service only ever runs when
    // toolpipeProvider is set.
    struct ToolPipeReq  { }
    struct ToolPipeResp { string result; string error; }
    private MainThreadBridge!(ToolPipeReq, ToolPipeResp) toolpipeBridge;

    // GET /api/ai/analyze — own bridge/epoch pair (MUST NOT share
    // pipeEvalBridge's or toolpipeBridge's, same rule as pathBridge/
    // toolpipeBridge above). No request payload (whole-mesh analysis takes
    // no parameters in Phase 1).
    struct AiAnalyzeReq  { }
    struct AiAnalyzeResp { string result; string error; }
    private MainThreadBridge!(AiAnalyzeReq, AiAnalyzeResp) aiAnalyzeBridge;

    public this(ushort port = 8080) {
        this.port = port;
        this.isRunning = false;
        this.modelDataProvider = null;
        this.eventPlayer = EventPlayer();

        resetBridge = new MainThreadBridge!(ResetReq, ResetResp)(this,
            (ref ResetReq req, ref ResetResp resp) {
                if (resetHandler !is null)
                    resetHandler(req.type, req.empty, req.param);
            });

        modelBridge = new MainThreadBridge!(ModelReq, ModelResp)(this,
            (ref ModelReq req, ref ModelResp resp) {
                try {
                    // Layer-aware provider wins when set (layers Stage 2): it
                    // serves ?layer=N, defaulting to the active layer for a
                    // bare /api/model.
                    if (layerModelProvider !is null)
                        resp.result = layerModelProvider(req.layer);
                    else if (req.detailed && detailedModelDataProvider !is null)
                        resp.result = detailedModelDataProvider();
                    else if (modelDataProvider !is null)
                        resp.result = modelDataProvider();
                    else
                        resp.error = "model data provider not set";
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            });

        pipeEvalBridge = new MainThreadBridge!(PipeEvalReq, PipeEvalResp)(this,
            (ref PipeEvalReq req, ref PipeEvalResp resp) {
                try {
                    if (toolpipeEvalProvider !is null)
                        resp.result = toolpipeEvalProvider();
                    else
                        resp.error = "toolpipe eval provider not set";
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            });

        toolpipeBridge = new MainThreadBridge!(ToolPipeReq, ToolPipeResp)(this,
            (ref ToolPipeReq req, ref ToolPipeResp resp) {
                try {
                    if (toolpipeProvider !is null)
                        resp.result = toolpipeProvider();
                    else
                        resp.error = "toolpipe provider not set";
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            });

        aiAnalyzeBridge = new MainThreadBridge!(AiAnalyzeReq, AiAnalyzeResp)(this,
            (ref AiAnalyzeReq req, ref AiAnalyzeResp resp) {
                try {
                    if (aiAnalyzeProvider !is null)
                        resp.result = aiAnalyzeProvider();
                    else
                        resp.error = "ai analyze provider not set";
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            });

        pathBridge = new MainThreadBridge!(PathReq, PathResp)(this,
            (ref PathReq req, ref PathResp resp) {
                try {
                    if (pathQueryProvider !is null)
                        resp.result = pathQueryProvider(req.t);
                    else
                        resp.error = "path query provider not set";
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            });

        commandBridge = new MainThreadBridge!(CmdReq, CmdResp)(this,
            (ref CmdReq req, ref CmdResp resp) {
                // Clear the query-result slot at entry: a write command
                // leaves it empty so the HTTP thread emits the plain
                // {"status":"ok"} body. A query command's handler calls
                // setCmdResult() to repopulate it.
                resp.result = "";
                if (commandHandler is null) {
                    resp.error = "command handler not set";
                } else {
                    // Continuous-scrub simulation (test only): raise the app
                    // latch so this tool.pipe.attr shares the live tweak
                    // generation (REPLACE-coalesce) instead of bumping a new
                    // one. Restored after dispatch.
                    immutable bool interactive =
                        req.interactive && interactiveLatchHook !is null;
                    if (interactive) interactiveLatchHook(true);
                    scope(exit) if (interactive) interactiveLatchHook(false);
                    try {
                        commandHandler(req.id, req.params);
                        resp.error = "";
                    } catch (Exception e) {
                        resp.error = e.msg;
                    }
                }
            });

        selectionBridge = new MainThreadBridge!(SelReq, SelResp)(this,
            (ref SelReq req, ref SelResp resp) {
                if (selectionHandler is null) {
                    resp.error = "selection handler not set";
                } else {
                    try {
                        selectionHandler(req.mode, req.indices);
                        resp.error = "";
                    } catch (Exception e) {
                        resp.error = e.msg;
                    }
                }
            });

        transformBridge = new MainThreadBridge!(XfReq, XfResp)(this,
            (ref XfReq req, ref XfResp resp) {
                if (transformHandler is null) {
                    resp.error = "transform handler not set";
                } else {
                    try {
                        transformHandler(req.kind, req.params);
                        resp.error = "";
                    } catch (Exception e) {
                        resp.error = e.msg;
                    }
                }
            });

        loadMeshBridge = new MainThreadBridge!(LoadMeshReq, LoadMeshResp)(this,
            (ref LoadMeshReq req, ref LoadMeshResp resp) {
                if (loadMeshHandler is null) {
                    resp.error = "load-mesh handler not set";
                } else {
                    try {
                        loadMeshHandler(req.params);
                        resp.error = "";
                    } catch (Exception e) {
                        resp.error = e.msg;
                    }
                }
            });

        cameraSetBridge = new MainThreadBridge!(CamSetReq, CamSetResp)(this,
            (ref CamSetReq req, ref CamSetResp resp) {
                if (cameraSetHandler is null) {
                    resp.error = "camera-set handler not set";
                } else {
                    try {
                        cameraSetHandler(req.params);
                        resp.error = "";
                    } catch (Exception e) {
                        resp.error = e.msg;
                    }
                }
            });

        gpuSurfaceBridge = new MainThreadBridge!(GpuSurfReq, GpuSurfResp)(this,
            (ref GpuSurfReq req, ref GpuSurfResp resp) {
                if (gpuSurfaceProvider is null) {
                    resp.error = "gpu-surface provider not set";
                } else {
                    try {
                        resp.result = gpuSurfaceProvider();
                        resp.error  = "";
                    } catch (Exception e) {
                        resp.error = e.msg;
                    }
                }
            });

        pickBridge = new MainThreadBridge!(PickReq, PickResp)(this,
            (ref PickReq req, ref PickResp resp) {
                if (pickProvider is null) {
                    resp.error = "pick provider not set";
                } else {
                    try {
                        resp.result = pickProvider(req.x, req.y, req.engine);
                        resp.error  = "";
                    } catch (Exception e) {
                        resp.error = e.msg;
                    }
                }
            });

        refireBridge = new MainThreadBridge!(RefireReq, RefireResp)(this,
            (ref RefireReq req, ref RefireResp resp) {
                if (refireHandler is null) {
                    resp.error = "refire handler not set";
                } else {
                    try {
                        refireHandler(req.action);
                        resp.error = "";
                    } catch (Exception e) {
                        resp.error = e.msg;
                    }
                }
            });

        blockBridge = new MainThreadBridge!(BlockReq, BlockResp)(this,
            (ref BlockReq req, ref BlockResp resp) {
                if (blockHandler is null) {
                    resp.error = "block handler not set";
                } else {
                    try {
                        blockHandler(req.action, req.label);
                        resp.error = "";
                    } catch (Exception e) {
                        resp.error = e.msg;
                    }
                }
            });

        undoBridge = new MainThreadBridge!(UndoReq, UndoResp)(this,
            (ref UndoReq req, ref UndoResp resp) {
                auto h = req.isRedo ? redoHandler : undoHandler;
                if (h is null) {
                    resp.result = false;
                } else {
                    try {
                        resp.result = h();
                    } catch (Exception) {
                        resp.result = false;
                    }
                }
            });

        jumpBridge = new MainThreadBridge!(JumpReq, JumpResp)(this,
            (ref JumpReq req, ref JumpResp resp) {
                if (jumpHandler is null) {
                    resp.result = false;
                } else {
                    try {
                        resp.result = jumpHandler(req.target);
                    } catch (Exception) {
                        resp.result = false;
                    }
                }
            });
    }

    /**
     * Set the model data provider callback
     */
    public void setModelDataProvider(ModelDataProvider provider) {
        this.modelDataProvider = provider;
        this.useDetailedProvider = false;
    }

    /**
     * Set the detailed model data provider callback
     */
    public void setDetailedModelDataProvider(DetailedModelDataProvider provider) {
        this.detailedModelDataProvider = provider;
        this.useDetailedProvider = true;
    }

    /**
     * Set the camera data provider callback
     */
    public void setCameraDataProvider(CameraDataProvider provider) {
        this.cameraDataProvider = provider;
    }

    public void setSelectionDataProvider(SelectionDataProvider provider) {
        this.selectionDataProvider = provider;
    }

    /// GET /api/tool/handles — see the ToolHandlesDataProvider doc comment above.
    public void setToolHandlesDataProvider(ToolHandlesDataProvider provider) {
        this.toolHandlesDataProvider = provider;
    }

    /// GET /api/tool/state — see the ToolStateDataProvider doc comment above.
    public void setToolStateDataProvider(ToolStateDataProvider provider) {
        this.toolStateDataProvider = provider;
    }

    /// GET /api/layers — JSON layer list (layers Stage 2).
    public void setLayersDataProvider(LayersDataProvider provider) {
        this.layersDataProvider = provider;
    }

    /// Layer-aware detailed model provider for /api/model?layer=N. When set, it
    /// takes precedence for /api/model and receives the requested layer index
    /// (-1 → active). Marshalled onto the main thread (tickModel).
    public void setLayerModelProvider(LayerModelProvider provider) {
        this.layerModelProvider = provider;
    }

    public void setRecordedEventsProvider(RecordedEventsProvider provider) {
        this.recordedEventsProvider = provider;
    }

    /// GET /api/registry — command and tool factory id arrays. Used by the
    /// button-action resolver test to assert every button id resolves
    /// without relying solely on the startup validator.
    public void setRegistryProvider(RegistryProvider provider) {
        this.registryProvider = provider;
    }

    /// Phase 7.0 — Tool Pipe inspection endpoint. The provider returns a
    /// JSON snapshot of the active pipeline (registered stages + their
    /// task codes / ordinals / enabled flags).
    public void setToolPipeProvider(ToolPipeProvider provider) {
        this.toolpipeProvider = provider;
    }

    /// JSON snapshot of pipeline evaluation results — center, axis basis,
    /// and per-cluster pivots/axes when ACEN/AXIS are in cluster mode.
    public void setToolPipeEvalProvider(ToolPipeEvalProvider provider) {
        this.toolpipeEvalProvider = provider;
    }

    /// PATH stage evaluation endpoint provider. Marshaled onto the main
    /// thread via tickPath() (same epoch-handshake shape as
    /// toolpipeEvalProvider — NOT the direct-read snapLastProvider).
    public void setPathQueryProvider(PathQueryProvider provider) {
        this.pathQueryProvider = provider;
    }

    /// GET /api/ai/analyze — AI Modeling Copilot Phase 1 (task 0402). Marshaled
    /// onto the main thread via aiAnalyzeBridge (same epoch-handshake shape as
    /// toolpipeEvalProvider) so `ai.analysis.analyzeMesh` always sees a
    /// consistent mesh snapshot, never a torn concurrent-edit read.
    public void setAiAnalyzeProvider(AiAnalyzeProvider provider) {
        this.aiAnalyzeProvider = provider;
    }

    /// Phase 7.3 — `/api/snap` query endpoint. Provider takes the raw
    /// request body (JSON) and returns the SnapResult JSON.
    public void setSnapQueryProvider(SnapQueryProvider provider) {
        this.snapQueryProvider = provider;
    }

    /// `/api/constrain` POST — set the constraint query provider.
    public void setConstrainQueryProvider(ConstrainQueryProvider provider) {
        this.constrainQueryProvider = provider;
    }

    /// Phase 7.3d — `/api/snap/last` GET. Returns the last SnapResult
    /// published by an interactive tool's drag (yellow-circle overlay
    /// state).
    public void setSnapLastProvider(SnapLastProvider provider) {
        this.snapLastProvider = provider;
    }

    /// GET /api/pick?x=&y=&engine=bvh|gpu — A/B face-pick equivalence oracle.
    /// Provider runs on the main thread (GL context + consistent mesh state).
    /// engine=gpu calls gpuSelect.pick directly; engine=bvh calls bvhPick.
    public void setPickProvider(PickProvider provider) {
        this.pickProvider = provider;
    }

    public void setTestMode(bool enabled) { testMode = enabled; }

    /// Enable fast-forward replay on the HTTP-driven event player (--perf
    /// mode). EventPlayer.load() preserves this flag across /api/play-events
    /// requests, so it only needs setting once at startup.
    public void setPlayerFastForward(bool enabled) {
        eventPlayer.fastForward = enabled;
    }

    public int  playerMouseX()    const { return eventPlayer.mouseX; }
    public int  playerMouseY()    const { return eventPlayer.mouseY; }
    public bool playerMouseDown() const { return eventPlayer.mouseDown; }
    public bool playerFinished()  const { return !eventPlayer.active; }

    /**
     * Set the reset handler callback
     */
    public void setResetHandler(ResetHandler handler) {
        this.resetHandler = handler;
    }

    /// Set the POST /api/camera handler. Called on the main thread with
    /// the parsed JSON body — sets View azimuth/elevation/distance/focus
    /// to the requested values.
    public void setCameraSetHandler(CameraSetHandler handler) {
        this.cameraSetHandler = handler;
    }

    /// Set the /api/gpu/face-vbo provider. Runs on the main thread (GL
    /// context required) and returns a JSON string describing the current
    /// face-VBO state.
    public void setGpuSurfaceProvider(GpuSurfaceProvider provider) {
        this.gpuSurfaceProvider = provider;
    }

    /**
     * Set the command handler callback. The handler runs on the main thread,
     * synchronously with respect to the HTTP request: see tickCommand().
     * The handler should throw on failure; the message is forwarded to the client.
     */
    public void setCommandHandler(CommandHandler handler) {
        this.commandHandler = handler;
    }

    /// Register the main-thread hook that raises/lowers the app's
    /// formsInteractiveLatch around an interactive (continuous-scrub) command
    /// dispatch. Test-automation seam for /api/script?interactive=true.
    public void setInteractiveLatchHook(InteractiveLatchHook hook) {
        this.interactiveLatchHook = hook;
    }

    /**
     * Stash a forms-engine query (`?` read-back) result. Called by the command
     * handler — which runs on the main thread inside the command bridge's
     * service — when the dispatched command was a query. The blocked HTTP
     * thread reads it back via the same epoch handshake once the bridge's
     * completed epoch catches up. Has the same single-flight precondition
     * documented on the CmdResp.result field above.
     */
    public void setCmdResult(string json) {
        commandBridge.resp.result = json;
    }

    /**
     * Set the selection handler callback. Same synchronous main-thread
     * dispatch as setCommandHandler — see tickSelection().
     */
    public void setSelectionHandler(SelectionHandler handler) {
        this.selectionHandler = handler;
    }

    /**
     * Set the transform handler callback. Same synchronous main-thread
     * dispatch as the others — see tickTransform().
     */
    public void setTransformHandler(TransformHandler handler) {
        this.transformHandler = handler;
    }

    /**
     * Set the load-mesh handler callback (POST /api/load-mesh). Same
     * synchronous main-thread dispatch as setTransformHandler — see
     * tickLoadMesh(). Test-only raw-mesh injection.
     */
    public void setLoadMeshHandler(LoadMeshHandler handler) {
        this.loadMeshHandler = handler;
    }

    /**
     * Set the undo/redo callbacks. Same main-thread sync as the others.
     * Returns true if a stack entry was applied, false on stack-empty or
     * revert failure.
     */
    public void setUndoHandler(UndoRedoHandler handler) { this.undoHandler = handler; }
    public void setRedoHandler(UndoRedoHandler handler) { this.redoHandler = handler; }

    /// /api/history/jump (Phase 2 of the history-panel design doc)
    /// — multi-step jump. `target` is the desired undoStack length after
    /// the walk. Runs on main thread via the same sync bridge as undo/redo.
    public void setJumpHandler(JumpHandler handler) { this.jumpHandler = handler; }

    /**
     * Set the /api/history JSON provider. Snapshot-at-request-time; runs
     * on the HTTP thread — provider must be safe to call concurrently with
     * apply/revert (or the caller must own a quick mutex).
     */
    public void setHistoryProvider(HistoryProvider provider) {
        this.historyProvider = provider;
    }

    /**
     * Set the /api/undo/status JSON provider. Read-only snapshot of the
     * history service ({state, lockout, canUndo, canRedo}); runs on the HTTP
     * thread like the history provider.
     */
    public void setUndoStatusProvider(UndoStatusProvider provider) {
        this.undoStatusProvider = provider;
    }

    /**
     * Set the replay provider — returns the canonical argstring line for
     * undoStack[index], or "" when the index is out of range. The provider
     * runs on the HTTP thread and must be safe to call concurrently with the
     * main thread (reading a snapshot is sufficient).
     */
    public void setReplayProvider(ReplayProvider provider) {
        this.replayProvider = provider;
    }

    /**
     * Set the refire handler — main-thread callback that opens/closes a
     * refire block on the command history. action is "begin" or "end".
     */
    public void setRefireHandler(RefireHandler handler) {
        this.refireHandler = handler;
    }

    /**
     * Set the command-block handler — main-thread callback that opens/closes a
     * command block on the history. action is "begin" (with a label) or "end".
     */
    public void setBlockHandler(BlockHandler handler) {
        this.blockHandler = handler;
    }

    /**
     * Start the HTTP server in a separate thread
     */
    public void start() {
        if (isRunning) {
            logWarn("http", "Server is already running");
            return;
        }

        serverThread = new Thread({
            import std.format : format;
            try {
                serverSocket = new TcpSocket();
                serverSocket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
                serverSocket.bind(new InternetAddress(port));
                serverSocket.listen(10);

                logInfo("http", format("HTTP server started on port %d", port));
                isRunning = true;

                while (isRunning) {
                    try {
                        Socket clientSocket = serverSocket.accept();
                        handleClient(clientSocket);
                    } catch (Exception e) {
                        if (isRunning) {
                            logWarn("http", "Error accepting client: " ~ e.msg);
                        }
                    }
                }
            } catch (Exception e) {
                logError("http", "Error starting server: " ~ e.msg);
            }
        });

        serverThread.start();
    }

    /**
     * Stop the HTTP server
     */
    public void stop() {
        if (!isRunning) {
            logWarn("http", "Server is not running");
            return;
        }

        isRunning = false;
        if (serverSocket !is null) {
            // Connect to ourselves to unblock the accept() call in serverThread
            try {
                Socket unblockSocket = new TcpSocket();
                unblockSocket.connect(new InternetAddress("127.0.0.1", port));
                unblockSocket.close();
            } catch (Exception e) {
                // Ignore connection errors during shutdown
            }
            
            serverSocket.close();
            serverSocket = null;
        }

        if (serverThread !is null && serverThread.isRunning) {
            serverThread.join();
        }

        logInfo("http", "HTTP server stopped");
    }

    /**
     * Handle a client connection
     */
    private void handleClient(Socket client) {
        try {
            // Read until we have the full header block (ends with \r\n\r\n)
            ubyte[] raw;
            ubyte[4096] chunk;
            ptrdiff_t n;
            size_t headerEnd;
            while (true) {
                n = client.receive(chunk[]);
                if (n <= 0) break;
                raw ~= chunk[0 .. n];
                // Search entire buffer for end-of-headers marker
                size_t searchFrom = raw.length > n + 3 ? raw.length - n - 3 : 0;
                for (size_t i = searchFrom; i + 3 < raw.length; ++i) {
                    if (raw[i] == '\r' && raw[i+1] == '\n' && raw[i+2] == '\r' && raw[i+3] == '\n') {
                        headerEnd = i + 4;
                        break;
                    }
                }
                if (headerEnd > 0) break;
            }

            if (raw.length == 0) return;

            string headerPart = cast(string)raw[0 .. headerEnd].idup;
            logInfo("http", "Received request: " ~ headerPart.split("\n")[0]);

            // Parse Content-Length from headers
            size_t contentLength = 0;
            foreach (line; headerPart.split("\n")) {
                string s = line.strip();
                if (s.length > 16 && s[0..16].toLower() == "content-length: ") {
                    try { contentLength = to!size_t(s[16..$].strip()); } catch (Exception) {}
                    break;
                }
            }
            // Read remaining body bytes
            ubyte[] bodyRaw = raw[headerEnd .. $];
            while (bodyRaw.length < contentLength) {
                n = client.receive(chunk[]);
                if (n <= 0) break;
                bodyRaw ~= chunk[0 .. n];
            }

            HttpRequest httpRequest = parseRequest(headerPart, cast(string)bodyRaw.idup);
            HttpResponse response = handleRequest(httpRequest);

            string responseStr = formatResponse(response);
            client.send(responseStr);
        } catch (Exception e) {
            logWarn("http", "Error handling client: " ~ e.msg);
        } finally {
            client.close();
        }
    }

    /**
     * Parse an HTTP request from separate header and body strings.
     */
    private HttpRequest parseRequest(string headers, string body) {
        auto lines = headers.split("\n");
        if (lines.length == 0)
            return new HttpRequest("GET", "/", "HTTP/1.1");

        auto parts = lines[0].strip().split(' ');
        string method      = parts.length >= 1 ? parts[0] : "GET";
        string path        = parts.length >= 2 ? parts[1] : "/";
        string httpVersion = parts.length >= 3 ? parts[2] : "HTTP/1.1";

        auto httpRequest = new HttpRequest(method, path, httpVersion);

        foreach (line; lines[1 .. $]) {
            string s = line.strip();
            auto colonPos = s.indexOf(":");
            if (colonPos > 0) {
                httpRequest.headers[s[0 .. colonPos].strip()] = s[colonPos + 1 .. $].strip();
            }
        }

        httpRequest.body = body;
        return httpRequest;
    }

    /**
     * Handle an HTTP request and generate a response
     */
    private HttpResponse handleRequest(HttpRequest request) {
        HttpResponse response = new HttpResponse();

        // Simple routing
        if (request.path == "/") {
            response.statusCode = 200;
            response.body = "<html><body><h1>Welcome to Vibe3D HTTP Server</h1>" ~
                           "<p>Server is running successfully!</p>" ~
                           "<p>Available endpoints:</p>" ~
                           "<ul><li>/status - Get application status</li>" ~
                           "<li>/info - Get application information</li>" ~
                           "<li>/api/model - Get current model state</li>" ~
                           "<li>/api/command - Execute one command (JSON {\"id\":...\"params\":...} OR argstring \"name arg:val ...\")</li>" ~
                           "<li>/api/script - Execute multi-line script (line-by-line argstring)</li>" ~
                           "<li>tool.set &lt;toolId&gt; [off] [name:val ...] - activate/deactivate a tool</li>" ~
                           "<li>tool.attr &lt;toolId&gt; &lt;name&gt; &lt;value&gt; - set parameter on active tool</li>" ~
                           "<li>tool.doApply - apply active tool one-shot (snapshot-based undo)</li>" ~
                           "<li>tool.reset [&lt;toolId&gt;] - reset active tool's parameters</li>" ~
                           "<li>/api/history/replay - POST {\"index\":N} — re-execute undoStack[N] against current state</li></ul>" ~
                           "</body></html>";
            response.headers["Content-Type"] = "text/html";
        } else if (request.path == "/status") {
            response.statusCode = 200;
            response.body = "{\"status\": \"running\", \"timestamp\": \"" ~
                           Clock.currTime.toISOExtString() ~ "\"}";
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/info") {
            response.statusCode = 200;
            response.body = "{\"name\": \"Vibe3D\", \"description\": \"A 3D polygon mesh editor written in D\", \"version\": \"1.0\"}";
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/ping" && request.method == "GET") {
            response.statusCode = 200;
            response.body = `{"status": "ok"}`;
            response.headers["Content-Type"] = "application/json";
        } else if (request.path.startsWith("/api/model")) {
            bool haveProvider = (layerModelProvider !is null)
                             || (useDetailedProvider && detailedModelDataProvider !is null)
                             || (modelDataProvider !is null);
            response.headers["Content-Type"] = "application/json";
            if (!haveProvider) {
                response.statusCode = 500;
                response.body = "{\"error\": \"Model data provider not set\"}";
            } else {
                // ?layer=N selects a layer (default -1 → active). The
                // layer-aware provider (when set) handles it on the main thread.
                modelBridge.req.layer    = parseQueryInt(request.path, "layer", -1);
                // Marshal the serialisation onto the main thread (via the
                // bridge's tick) so the provider never walks the mesh
                // mid-mutation (torn read).
                modelBridge.req.detailed = useDetailedProvider;
                modelBridge.resp.result  = "";
                modelBridge.resp.error   = "";
                if (!modelBridge.submitAndWait())
                    modelBridge.resp.error = "timeout waiting for main thread";
                if (modelBridge.resp.error.length == 0) {
                    response.statusCode = 200;
                    response.body = modelBridge.resp.result;
                } else {
                    response.statusCode = 500;
                    response.body = "{\"error\": \"Failed to retrieve model data\", \"message\": \""
                                   ~ modelBridge.resp.error.replace("\"", "\\\"") ~ "\"}";
                }
            }
        } else if (request.path == "/api/selection") {
            if (selectionDataProvider !is null) {
                try {
                    response.statusCode = 200;
                    response.body = selectionDataProvider();
                    response.headers["Content-Type"] = "application/json";
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\": \"Failed to retrieve selection data\", \"message\": \"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                    response.headers["Content-Type"] = "application/json";
                }
            } else {
                response.statusCode = 500;
                response.body = "{\"error\": \"Selection data provider not set\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path == "/api/tool/handles" && request.method == "GET") {
            // Task 0234. Read-only; served straight from the HTTP thread —
            // see the ToolHandlesDataProvider doc comment (above, near its
            // field declaration) for the thread-safety discriminator.
            response.headers["Content-Type"] = "application/json";
            if (toolHandlesDataProvider is null) {
                response.statusCode = 200;
                response.body = `{"handles":null}`;
            } else {
                try {
                    response.statusCode = 200;
                    response.body = toolHandlesDataProvider();
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\": \"Failed to retrieve tool handles\", \"message\": \"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                }
            }
        } else if (request.path == "/api/tool/state" && request.method == "GET") {
            // Task 0234. Same read-only / no-lock contract as /api/tool/handles.
            response.headers["Content-Type"] = "application/json";
            if (toolStateDataProvider is null) {
                response.statusCode = 200;
                response.body = `{}`;
            } else {
                try {
                    response.statusCode = 200;
                    response.body = toolStateDataProvider();
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\": \"Failed to retrieve tool state\", \"message\": \"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                }
            }
        } else if (request.path == "/api/layers" && request.method == "GET") {
            // Layer list (layers Stage 2). Read-only; served straight from the
            // HTTP thread like /api/selection — tests are quiescent when probing.
            response.headers["Content-Type"] = "application/json";
            if (layersDataProvider !is null) {
                try {
                    response.statusCode = 200;
                    response.body = layersDataProvider();
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\": \"Failed to retrieve layers\", \"message\": \"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                }
            } else {
                response.statusCode = 500;
                response.body = "{\"error\": \"Layers data provider not set\"}";
            }
        } else if (request.path == "/api/perf/reset" && request.method == "POST") {
            // Zero all perf counters before a measured run. No-op in the
            // default build (g_perf.reset compiles away).
            g_perf.reset();
            response.statusCode = 200;
            response.body = "{\"status\":\"ok\"}";
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/perf" && request.method == "GET") {
            // Per-category timing + counter breakdown. Direct read of the
            // process-wide probe from the HTTP thread — plain counters, no
            // lock needed for this diagnostic. Returns "{}" in the default
            // (non-PerfProbe) build. Mesh vertex/face counts are available
            // via /api/model, so they're intentionally not duplicated here.
            try {
                response.statusCode = 200;
                response.body = g_perf.toJson();
                response.headers["Content-Type"] = "application/json";
            } catch (Exception e) {
                response.statusCode = 500;
                response.body = "{\"error\":\"perf probe read failed\",\"message\":\"" ~
                               e.msg.replace("\"", "\\\"") ~ "\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path == "/api/frames/reset" && request.method == "POST") {
            // Zero the per-frame ring + counters before a measured run
            // (task 0195). No-op in the default build (g_frames.reset
            // compiles away).
            g_frames.reset();
            response.statusCode = 200;
            response.body = "{\"status\":\"ok\"}";
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/frames" && request.method == "GET") {
            // Per-frame phase-timing + GC-delta breakdown (task 0195,
            // doc/frame_probe_scenarios_plan.md). Direct read of the
            // process-wide FrameProbe from the HTTP thread — same
            // no-lock diagnostic contract as /api/perf above (single-writer
            // main-loop, write-then-advance ring discipline makes a racy
            // read tear-free at frame granularity). Returns "{}" in the
            // default (non-PerfProbe) build.
            try {
                response.statusCode = 200;
                response.body = g_frames.toJson();
                response.headers["Content-Type"] = "application/json";
            } catch (Exception e) {
                response.statusCode = 500;
                response.body = "{\"error\":\"frame probe read failed\",\"message\":\"" ~
                               e.msg.replace("\"", "\\\"") ~ "\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path == "/api/changes" && request.method == "GET") {
            // Change-notification bus debug counters (Stage 1; test-only). Direct
            // read of the process-wide __gshared bus from the HTTP thread — the
            // counters are plain integers updated on the main thread at the
            // per-frame flush, so a diagnostic racy read needs no lock (same
            // contract as /api/perf). Tests read these counters as DELTAS across
            // a step (the runner resets app state, not the bus, between test
            // binaries — see the plan's reset caveat).
            response.headers["Content-Type"] = "application/json";
            if (!testMode) {
                response.statusCode = 403;
                response.body = `{"error":"changes is only available in --test mode"}`;
            } else {
                import change_bus : changeBus;
                import seltype    : selTypeToken;
                import std.format : format;
                response.statusCode = 200;
                response.body = format(
                    `{"flushCount":%d,"lastFlushFlags":%d,"lastSelDomains":%d,` ~
                    `"lastLayerKinds":%d,` ~
                    `"totalPosition":%d,"totalPoints":%d,"totalPolygons":%d,` ~
                    `"totalMarks":%d,"totalMaterial":%d,` ~
                    `"totalSelVertex":%d,"totalSelEdge":%d,"totalSelFace":%d,` ~
                    `"totalSelItem":%d,` ~
                    `"totalLayerAdded":%d,"totalLayerRemoved":%d,` ~
                    `"totalLayerReordered":%d,"totalLayerRenamed":%d,` ~
                    `"totalLayerVisible":%d,` ~
                    `"totalLayerActive":%d,` ~
                    `"currentTypeChanged":%d,"lastCurrentType":"%s"}`,
                    changeBus.flushCount, changeBus.lastFlushFlags,
                    changeBus.lastSelDomains, changeBus.lastLayerKinds,
                    changeBus.totalPosition, changeBus.totalPoints,
                    changeBus.totalPolygons, changeBus.totalMarks,
                    changeBus.totalMaterial,
                    changeBus.totalSelVertex, changeBus.totalSelEdge,
                    changeBus.totalSelFace,
                    changeBus.totalSelItem,
                    changeBus.totalLayerAdded, changeBus.totalLayerRemoved,
                    changeBus.totalLayerReordered, changeBus.totalLayerRenamed,
                    changeBus.totalLayerVisible,
                    changeBus.totalLayerActive,
                    changeBus.currentTypeChanged,
                    selTypeToken(changeBus.lastCurrentType));
            }
        } else if (request.path == "/api/toolpipe/eval") {
            response.headers["Content-Type"] = "application/json";
            if (toolpipeEvalProvider is null) {
                response.statusCode = 500;
                response.body = "{\"error\":\"toolpipe eval provider not set\"}";
            } else {
                // Marshal the pipe evaluation onto the main thread (via the
                // bridge's tick) so it never races the main thread's own
                // evaluate().
                pipeEvalBridge.resp.result = "";
                pipeEvalBridge.resp.error  = "";
                if (!pipeEvalBridge.submitAndWait())
                    pipeEvalBridge.resp.error = "timeout waiting for main thread";
                if (pipeEvalBridge.resp.error.length == 0) {
                    response.statusCode = 200;
                    response.body = pipeEvalBridge.resp.result;
                } else {
                    response.statusCode = 500;
                    response.body = "{\"error\":\"toolpipe eval provider failed\",\"message\":\""
                                   ~ pipeEvalBridge.resp.error.replace("\"", "\\\"") ~ "\"}";
                }
            }
        } else if (request.path.startsWith("/api/path")) {
            response.headers["Content-Type"] = "application/json";
            if (pathQueryProvider is null) {
                response.statusCode = 500;
                response.body = `{"error":"path query provider not set"}`;
            } else {
                // Parse t from POST body or GET query string.
                float t = 0.5f;
                try {
                    if (request.method == "POST" && request.body.length > 0) {
                        auto bj = parseJSON(request.body);
                        if (auto tp = "t" in bj.object) {
                            if      (tp.type == JSONType.float_)   t = cast(float)tp.floating;
                            else if (tp.type == JSONType.integer)  t = cast(float)tp.integer;
                            else if (tp.type == JSONType.uinteger) t = cast(float)tp.uinteger;
                        }
                    } else {
                        string ts = parseQueryString(request.path, "t", "");
                        if (ts.length > 0) {
                            import std.conv : to;
                            t = ts.to!float;
                        }
                    }
                } catch (Exception) {}
                // Marshal onto the main thread via the dedicated bridge — MUST
                // NOT share pipeEval's epoch pair (see the bridge decl above).
                pathBridge.req.t      = t;
                pathBridge.resp.result = "";
                pathBridge.resp.error  = "";
                if (!pathBridge.submitAndWait())
                    pathBridge.resp.error = "timeout waiting for main thread";
                if (pathBridge.resp.error.length == 0) {
                    response.statusCode = 200;
                    response.body = pathBridge.resp.result;
                } else {
                    response.statusCode = 500;
                    response.body = `{"error":"path query failed","message":"` ~
                                   pathBridge.resp.error.replace("\"", "\\\"") ~ `"}`;
                }
            }
        } else if (request.path == "/api/toolpipe") {
            response.headers["Content-Type"] = "application/json";
            if (toolpipeProvider is null) {
                // Preserve the pre-marshaling null-provider contract exactly:
                // 200 {"stages":[]}, decided on the HTTP thread BEFORE ever
                // touching the bridge (do NOT copy /api/toolpipe/eval's 500
                // branch here).
                response.statusCode = 200;
                response.body = "{\"stages\":[]}";
            } else {
                // Marshal onto the main thread via its own bridge/epoch pair
                // (see toolpipeBridge decl) so the display path never races
                // the main thread's own evaluate() over the ACEN cluster cache.
                toolpipeBridge.resp.result = "";
                toolpipeBridge.resp.error  = "";
                if (!toolpipeBridge.submitAndWait())
                    toolpipeBridge.resp.error = "timeout waiting for main thread";
                if (toolpipeBridge.resp.error.length == 0) {
                    response.statusCode = 200;
                    response.body = toolpipeBridge.resp.result;
                } else {
                    response.statusCode = 500;
                    response.body = "{\"error\":\"toolpipe provider failed\",\"message\":\""
                                   ~ toolpipeBridge.resp.error.replace("\"", "\\\"") ~ "\"}";
                }
            }
        } else if (request.path == "/api/ai/analyze" && request.method == "GET") {
            response.headers["Content-Type"] = "application/json";
            if (aiAnalyzeProvider is null) {
                response.statusCode = 500;
                response.body = `{"error":"ai analyze provider not set"}`;
            } else {
                // Marshal onto the main thread via its own bridge/epoch pair
                // (see aiAnalyzeBridge decl) so this read-only analysis never
                // races the main thread's own mesh mutations (risk #4,
                // ai_copilot_plan.md Phase 1).
                aiAnalyzeBridge.resp.result = "";
                aiAnalyzeBridge.resp.error  = "";
                if (!aiAnalyzeBridge.submitAndWait())
                    aiAnalyzeBridge.resp.error = "timeout waiting for main thread";
                if (aiAnalyzeBridge.resp.error.length == 0) {
                    response.statusCode = 200;
                    response.body = aiAnalyzeBridge.resp.result;
                } else {
                    response.statusCode = 500;
                    response.body = "{\"error\":\"ai analyze provider failed\",\"message\":\""
                                   ~ aiAnalyzeBridge.resp.error.replace("\"", "\\\"") ~ "\"}";
                }
            }
        } else if (request.path.startsWith("/api/registry") && request.method == "GET") {
            if (registryProvider !is null) {
                try {
                    bool wantParams = parseQueryInt(request.path, "params", 0) != 0;
                    response.statusCode = 200;
                    response.body = registryProvider(wantParams);
                    response.headers["Content-Type"] = "application/json";
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\":\"registry provider failed\",\"message\":\"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                    response.headers["Content-Type"] = "application/json";
                }
            } else {
                response.statusCode = 200;
                response.body = "{\"commands\":[],\"tools\":[]}";
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path == "/api/snap/last" && request.method == "GET") {
            if (snapLastProvider !is null) {
                try {
                    response.statusCode = 200;
                    response.body = snapLastProvider();
                    response.headers["Content-Type"] = "application/json";
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\":\"snap last provider failed\",\"message\":\"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                    response.headers["Content-Type"] = "application/json";
                }
            } else {
                response.statusCode = 500;
                response.body = "{\"error\":\"snap last provider not set\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path == "/api/snap" && request.method == "POST") {
            if (snapQueryProvider !is null) {
                try {
                    response.statusCode = 200;
                    response.body = snapQueryProvider(request.body);
                    response.headers["Content-Type"] = "application/json";
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\":\"snap query failed\",\"message\":\"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                    response.headers["Content-Type"] = "application/json";
                }
            } else {
                response.statusCode = 500;
                response.body = "{\"error\":\"snap query provider not set\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path == "/api/constrain" && request.method == "POST") {
            if (constrainQueryProvider !is null) {
                try {
                    response.statusCode = 200;
                    response.body = constrainQueryProvider(request.body);
                    response.headers["Content-Type"] = "application/json";
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\":\"constrain query failed\",\"message\":\"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                    response.headers["Content-Type"] = "application/json";
                }
            } else {
                response.statusCode = 500;
                response.body = "{\"error\":\"constrain query provider not set\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path.startsWith("/api/camera") && request.method == "POST") {
            if (cameraSetHandler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"camera-set handler not set"}`;
            } else {
                try {
                    cameraSetBridge.req.params = parseJSON(request.body);
                    // Inject ?viewport=N from query string into the JSON body
                    // so the main-thread handler can target the correct cell.
                    if (cameraSetBridge.req.params.type == JSONType.object)
                        cameraSetBridge.req.params["_viewport"] = parseQueryInt(request.path, "viewport", -1);
                    cameraSetBridge.resp.error = "";
                    if (!cameraSetBridge.submitAndWait())
                        cameraSetBridge.resp.error = "timeout waiting for main thread";
                    if (cameraSetBridge.resp.error.length == 0) {
                        response.statusCode = 200;
                        response.body = `{"status":"ok"}`;
                    } else {
                        response.statusCode = 200;
                        response.body = `{"status":"error","message":"`
                                        ~ cameraSetBridge.resp.error.replace("\"", "\\\"") ~ `"}`;
                    }
                } catch (Exception e) {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                    ~ e.msg.replace("\"", "\\\"") ~ `"}`;
                }
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/gpu/face-vbo" && request.method == "GET") {
            if (gpuSurfaceProvider is null) {
                response.statusCode = 500;
                response.body = `{"error":"gpu-surface provider not set"}`;
                response.headers["Content-Type"] = "application/json";
            } else {
                gpuSurfaceBridge.resp.error = "";
                if (!gpuSurfaceBridge.submitAndWait())
                    gpuSurfaceBridge.resp.error = "timeout waiting for main thread";
                if (gpuSurfaceBridge.resp.error.length == 0) {
                    response.statusCode = 200;
                    response.body = gpuSurfaceBridge.resp.result;
                } else {
                    response.statusCode = 500;
                    response.body = `{"error":"`
                                    ~ gpuSurfaceBridge.resp.error.replace("\"", "\\\"") ~ `"}`;
                }
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path.startsWith("/api/pick") && request.method == "GET") {
            if (pickProvider is null) {
                response.statusCode = 500;
                response.body = `{"error":"pick provider not set"}`;
                response.headers["Content-Type"] = "application/json";
            } else {
                pickBridge.req.x      = parseQueryInt(request.path, "x", 0);
                pickBridge.req.y      = parseQueryInt(request.path, "y", 0);
                pickBridge.req.engine = parseQueryString(request.path, "engine", "bvh");
                pickBridge.resp.result = "";
                pickBridge.resp.error  = "";
                if (!pickBridge.submitAndWait())
                    pickBridge.resp.error = "timeout waiting for main thread";
                if (pickBridge.resp.error.length == 0) {
                    response.statusCode = 200;
                    response.body = pickBridge.resp.result;
                } else {
                    response.statusCode = 500;
                    response.body = `{"error":"` ~ pickBridge.resp.error.replace("\"", "\\\"") ~ `"}`;
                }
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path.startsWith("/api/camera") && request.method == "GET") {
            if (cameraDataProvider !is null) {
                try {
                    int _vpIdx = parseQueryInt(request.path, "viewport", -1);
                    response.statusCode = 200;
                    response.body = cameraDataProvider(_vpIdx);
                    response.headers["Content-Type"] = "application/json";
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\": \"Failed to retrieve camera data\", \"message\": \"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                    response.headers["Content-Type"] = "application/json";
                }
            } else {
                response.statusCode = 500;
                response.body = "{\"error\": \"Camera data provider not set\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path == "/api/recorded-events" && request.method == "GET") {
            if (recordedEventsProvider !is null) {
                string data = recordedEventsProvider();
                if (data is null) {
                    response.statusCode = 404;
                    response.body = `{"error":"no recording available — press F1 to start, F2 to stop"}`;
                } else {
                    response.statusCode = 200;
                    response.body = data;
                    response.headers["Content-Type"] = "text/plain";
                }
            } else {
                response.statusCode = 500;
                response.body = `{"error":"recorded events provider not set"}`;
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path.startsWith("/api/reset") && request.method == "POST") {
            if (resetHandler !is null) {
                resetBridge.req.type  = parseQueryString(request.path, "type", "");
                string emptyParam = parseQueryString(request.path, "empty", "");
                resetBridge.req.empty = (emptyParam == "true" || emptyParam == "1");
                // Dense perf meshes take an int: grid → ?n=<int>,
                // subdivcube → ?levels=<int>. -1 means "use the factory
                // default" (n=316 / levels=7). Accept either key; n wins if
                // both are somehow present.
                int nParam = parseQueryInt(request.path, "n", -1);
                int lvlParam = parseQueryInt(request.path, "levels", -1);
                resetBridge.req.param = (nParam >= 0) ? nParam : lvlParam;
                resetBridge.submitAndWait();  // timeout is silent-ok — no error body
                response.statusCode = 200;
                response.body = `{"status":"ok"}`;
            } else {
                response.statusCode = 500;
                response.body = `{"error":"Reset handler not set"}`;
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/play-events/status" && request.method == "GET") {
            import std.format : format;
            bool done = !eventPlayer.active;
            response.statusCode = 200;
            response.body = format(`{"finished":%s,"total":%d,"remaining":%d}`,
                done ? "true" : "false",
                eventPlayer.entries.length,
                done ? 0 : eventPlayer.entries.length - eventPlayer.idx);
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/transform" && request.method == "POST") {
            if (transformHandler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"transform handler not set"}`;
            } else {
                try {
                    auto j = parseJSON(request.body);
                    if ("kind" !in j || j["kind"].type != JSONType.string)
                        throw new Exception("missing 'kind' string field");
                    transformBridge.req.kind   = j["kind"].str;
                    transformBridge.req.params = j;  // pass full request body for handler
                    transformBridge.resp.error = "";
                    if (!transformBridge.submitAndWait())
                        transformBridge.resp.error = "timeout waiting for main thread";
                    if (transformBridge.resp.error.length == 0) {
                        response.statusCode = 200;
                        response.body = `{"status":"ok"}`;
                    } else {
                        response.statusCode = 200;
                        response.body = `{"status":"error","message":"`
                                        ~ transformBridge.resp.error.replace("\"", "\\\"") ~ `"}`;
                    }
                } catch (Exception e) {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                    ~ e.msg.replace("\"", "\\\"") ~ `"}`;
                }
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/load-mesh" && request.method == "POST") {
            // Test-only raw-mesh injection. Validate the JSON shape on the
            // HTTP thread (so we can report counts), then dispatch to the
            // main thread via the same epoch bridge as /api/transform. The
            // main-thread handler re-validates index range / degree before
            // touching the live mesh and throws on bad input.
            if (loadMeshHandler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"load-mesh handler not set"}`;
            } else {
                try {
                    auto j = parseJSON(request.body);
                    if (j.type != JSONType.object)
                        throw new Exception("body must be a JSON object");
                    if ("vertices" !in j || j["vertices"].type != JSONType.array)
                        throw new Exception("missing 'vertices' array field");
                    if ("faces" !in j || j["faces"].type != JSONType.array)
                        throw new Exception("missing 'faces' array field");
                    long vCount = cast(long)j["vertices"].array.length;
                    long fCount = cast(long)j["faces"].array.length;

                    loadMeshBridge.req.params = j;
                    loadMeshBridge.resp.error = "";
                    if (!loadMeshBridge.submitAndWait())
                        loadMeshBridge.resp.error = "timeout waiting for main thread";
                    if (loadMeshBridge.resp.error.length == 0) {
                        import std.format : format;
                        response.statusCode = 200;
                        response.body = format(
                            `{"status":"ok","vertexCount":%d,"faceCount":%d}`,
                            vCount, fCount);
                    } else {
                        response.statusCode = 200;
                        response.body = `{"status":"error","message":"`
                                        ~ loadMeshBridge.resp.error.replace("\"", "\\\"") ~ `"}`;
                    }
                } catch (Exception e) {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                    ~ e.msg.replace("\"", "\\\"") ~ `"}`;
                }
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/select" && request.method == "POST") {
            if (selectionHandler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"selection handler not set"}`;
            } else {
                try {
                    auto j = parseJSON(request.body);
                    if ("mode" !in j || j["mode"].type != JSONType.string)
                        throw new Exception("missing 'mode' string field");
                    if ("indices" !in j || j["indices"].type != JSONType.array)
                        throw new Exception("missing 'indices' array field");
                    selectionBridge.req.mode = j["mode"].str;
                    int[] idx;
                    foreach (n; j["indices"].array) {
                        if (n.type != JSONType.integer && n.type != JSONType.uinteger)
                            throw new Exception("indices must be integers");
                        idx ~= cast(int)n.integer;
                    }
                    selectionBridge.req.indices = idx;
                    selectionBridge.resp.error  = "";
                    if (!selectionBridge.submitAndWait())
                        selectionBridge.resp.error = "timeout waiting for main thread";
                    if (selectionBridge.resp.error.length == 0) {
                        response.statusCode = 200;
                        response.body = `{"status":"ok"}`;
                    } else {
                        response.statusCode = 200;
                        response.body = `{"status":"error","message":"`
                                        ~ selectionBridge.resp.error.replace("\"", "\\\"") ~ `"}`;
                    }
                } catch (Exception e) {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                    ~ e.msg.replace("\"", "\\\"") ~ `"}`;
                }
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/command" && request.method == "POST") {
            if (commandHandler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"command handler not set"}`;
            } else {
                try {
                    string body_ = request.body;
                    // Detect JSON vs argstring by first non-whitespace character.
                    size_t bi = 0;
                    while (bi < body_.length &&
                           (body_[bi] == ' '  || body_[bi] == '\t' ||
                            body_[bi] == '\n'  || body_[bi] == '\r')) bi++;
                    if (bi >= body_.length)
                        throw new Exception("empty body");
                    bool isJson = (body_[bi] == '{');

                    if (isJson) {
                        auto j = parseJSON(body_);
                        if ("id" !in j || j["id"].type != JSONType.string)
                            throw new Exception("missing 'id' string field");
                        commandBridge.req.id     = j["id"].str;
                        // When the body has a nested "params" object, use it.
                        // Otherwise treat the whole body as the param dict (flat
                        // params style, matching the argstring convention).  The
                        // "id" field is just ignored by injectParamsInto.
                        commandBridge.req.params = ("params" in j) ? j["params"].toString : body_;
                    } else {
                        auto parsed = parseArgstring(body_);
                        if (parsed.isEmpty)
                            throw new Exception("empty argstring");
                        commandBridge.req.id     = parsed.commandId;
                        commandBridge.req.params = parsed.params.toString();
                    }

                    commandBridge.resp.error   = "";
                    commandBridge.req.interactive = false;   // plain command = discrete
                    if (!commandBridge.submitAndWait())
                        commandBridge.resp.error = "timeout waiting for main thread";
                    if (commandBridge.resp.error.length == 0) {
                        response.statusCode = 200;
                        // Forms-engine `?` query: when the handler stashed a
                        // read-back value, surface it under "value"; otherwise
                        // the plain ok body (byte-compatible with every
                        // existing write test, which never sets the slot).
                        if (commandBridge.resp.result.length > 0)
                            response.body = `{"status":"ok","value":`
                                            ~ commandBridge.resp.result ~ `}`;
                        else
                            response.body = `{"status":"ok"}`;
                    } else {
                        response.statusCode = 200;
                        response.body = `{"status":"error","message":"`
                                        ~ commandBridge.resp.error.replace("\"", "\\\"") ~ `"}`;
                    }
                } catch (Exception e) {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                    ~ e.msg.replace("\"", "\\\"") ~ `"}`;
                }
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path.startsWith("/api/script") && request.method == "POST") {
            // Multi-line argstring script: execute each non-empty/non-comment
            // line through the same main-thread bridge as /api/command.
            // ?continue=true keeps running after errors; default stops on first.
            bool continueOnError =
                (parseQueryString(request.path, "continue", "") == "true");
            // Test-only: ?interactive=true marks every line a continuous-scrub
            // dispatch (shared tweak generation → REPLACE-coalesce), simulating a
            // held falloff-handle / slider drag that /api/command's per-command
            // generation bump otherwise splits into discrete steps.
            immutable bool interactiveScript =
                (parseQueryString(request.path, "interactive", "") == "true");

            if (commandHandler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"command handler not set"}`;
            } else {
                import std.array  : Appender;
                import std.format : format;

                struct LineResult {
                    int    lineNo;
                    string command;
                    bool   ok;
                    string message; // non-empty on error
                }

                LineResult[] results;
                bool anyError = false;

                auto lines_ = request.body.split('\n');
                int lineNo  = 0;

                outer: foreach (rawLine; lines_) {
                    ++lineNo;
                    try {
                        auto parsed = parseArgstring(rawLine);
                        if (parsed.isEmpty) continue; // blank / comment

                        commandBridge.req.id          = parsed.commandId;
                        commandBridge.req.params      = parsed.params.toString();
                        commandBridge.resp.error      = "";
                        commandBridge.req.interactive = interactiveScript;

                        if (!commandBridge.submitAndWait())
                            commandBridge.resp.error = "timeout waiting for main thread";

                        if (commandBridge.resp.error.length == 0) {
                            results ~= LineResult(lineNo, parsed.commandId, true, "");
                        } else {
                            anyError = true;
                            results ~= LineResult(lineNo, parsed.commandId, false,
                                                  commandBridge.resp.error);
                            if (!continueOnError) break outer;
                        }
                    } catch (Exception e) {
                        anyError = true;
                        results ~= LineResult(lineNo, "", false, e.msg);
                        if (!continueOnError) break outer;
                    }
                }

                // Build JSON response
                Appender!string sb;
                sb.put(`{"status":"`);
                sb.put(anyError ? "error" : "ok");
                sb.put(`","results":[`);
                foreach (i, r; results) {
                    if (i > 0) sb.put(',');
                    sb.put(format(`{"line":%d,"command":"%s","status":"%s"`,
                                  r.lineNo,
                                  r.command.replace("\"", "\\\""),
                                  r.ok ? "ok" : "error"));
                    if (!r.ok && r.message.length > 0) {
                        sb.put(`,"message":"`);
                        sb.put(r.message.replace("\\", "\\\\").replace("\"", "\\\""));
                        sb.put('"');
                    }
                    sb.put('}');
                }
                sb.put("]}");

                response.statusCode = 200;
                response.body = sb.data;
            }
            response.headers["Content-Type"] = "application/json";
        } else if ((request.path == "/api/undo" || request.path == "/api/redo")
                   && request.method == "POST") {
            // Same main-thread sync pattern as /api/command, via the undo
            // bridge. tickAll() drains it on the main thread, invoking the
            // handler and writing resp.result.
            bool isRedo = (request.path == "/api/redo");
            auto handler = isRedo ? redoHandler : undoHandler;
            if (handler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"`
                                ~ (isRedo ? "redo" : "undo")
                                ~ ` handler not set"}`;
            } else {
                undoBridge.req.isRedo = isRedo;
                undoBridge.resp.result = false;
                undoBridge.submitAndWait();  // timeout is noop-false — no error body
                response.statusCode = 200;
                response.body = undoBridge.resp.result
                    ? `{"status":"ok"}`
                    : `{"status":"noop","message":"stack empty or revert failed"}`;
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/refire" && request.method == "POST") {
            if (refireHandler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"refire handler not set"}`;
            } else {
                try {
                    auto j = parseJSON(request.body);
                    if ("action" !in j || j["action"].type != JSONType.string)
                        throw new Exception("missing 'action' string field");
                    string action = j["action"].str;
                    if (action != "begin" && action != "end")
                        throw new Exception("'action' must be 'begin' or 'end'");
                    refireBridge.req.action = action;
                    refireBridge.resp.error = "";
                    if (!refireBridge.submitAndWait())
                        refireBridge.resp.error = "timeout waiting for main thread";
                    if (refireBridge.resp.error.length == 0) {
                        response.statusCode = 200;
                        response.body = `{"status":"ok"}`;
                    } else {
                        response.statusCode = 200;
                        response.body = `{"status":"error","message":"`
                                        ~ refireBridge.resp.error.replace("\"", "\\\"") ~ `"}`;
                    }
                } catch (Exception e) {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                    ~ e.msg.replace("\"", "\\\"") ~ `"}`;
                }
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/history/block" && request.method == "POST") {
            // Command-block grouping: {"action":"begin","label":"..."} opens a
            // block, {"action":"end"} closes it. N undoable commands recorded
            // between begin and end collapse into ONE undo entry. Same
            // main-thread bridge as /api/refire.
            if (blockHandler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"block handler not set"}`;
            } else {
                try {
                    auto j = parseJSON(request.body);
                    if ("action" !in j || j["action"].type != JSONType.string)
                        throw new Exception("missing 'action' string field");
                    string action = j["action"].str;
                    if (action != "begin" && action != "end")
                        throw new Exception("'action' must be 'begin' or 'end'");
                    string label = "";
                    if ("label" in j && j["label"].type == JSONType.string)
                        label = j["label"].str;
                    blockBridge.req.action = action;
                    blockBridge.req.label  = label;
                    blockBridge.resp.error = "";
                    if (!blockBridge.submitAndWait())
                        blockBridge.resp.error = "timeout waiting for main thread";
                    if (blockBridge.resp.error.length == 0) {
                        response.statusCode = 200;
                        response.body = `{"status":"ok"}`;
                    } else {
                        response.statusCode = 200;
                        response.body = `{"status":"error","message":"`
                                        ~ blockBridge.resp.error.replace("\"", "\\\"") ~ `"}`;
                    }
                } catch (Exception e) {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                    ~ e.msg.replace("\"", "\\\"") ~ `"}`;
                }
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/undo/status" && request.method == "GET") {
            // Read-only undo-service status: {state, lockout, canUndo, canRedo}.
            // Snapshot at request time on the HTTP thread (same safety contract
            // as /api/history GET — read-only access to the history service).
            if (undoStatusProvider is null) {
                response.statusCode = 200;
                response.body = `{"state":"invalid","lockout":false,`
                              ~ `"canUndo":false,"canRedo":false}`;
            } else {
                response.statusCode = 200;
                response.body = undoStatusProvider();
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/history" && request.method == "GET") {
            if (historyProvider is null) {
                response.statusCode = 200;
                response.body = `{"undo":[],"redo":[]}`;
            } else {
                response.statusCode = 200;
                response.body = historyProvider();
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/history/jump" && request.method == "POST") {
            // Multi-step jump (Phase 2). Body: {"target":N}. N is the
            // DESIRED length of undoStack after the walk — 0 to
            // undo.length+redo.length. Drives CommandHistory.jumpTo
            // via the same main-thread sync bridge as /api/undo.
            if (jumpHandler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"jump handler not set"}`;
            } else {
                try {
                    auto j = parseJSON(request.body);
                    if ("target" !in j ||
                        (j["target"].type != JSONType.integer &&
                         j["target"].type != JSONType.uinteger))
                        throw new Exception("missing 'target' integer field");
                    long t = (j["target"].type == JSONType.integer)
                             ? j["target"].integer
                             : cast(long)j["target"].uinteger;
                    if (t < 0) throw new Exception("'target' must be non-negative");
                    jumpBridge.req.target = cast(size_t)t;
                    jumpBridge.resp.result = false;
                    jumpBridge.submitAndWait();  // timeout is noop-false — no error body
                    response.statusCode = 200;
                    response.body = jumpBridge.resp.result
                        ? `{"status":"ok"}`
                        : `{"status":"noop","message":"jump aborted or out of range"}`;
                } catch (Exception e) {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                  ~ e.msg.replace("\"", "\\\"") ~ `"}`;
                }
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/history/replay" && request.method == "POST") {
            // Re-execute the argstring of undoStack[index] against the current
            // mesh state. Reuses the same main-thread bridge as /api/command —
            // the result is a brand-new history entry; the original is untouched.
            //
            // Caveats (by design, not bugs):
            //  - Replay executes against the CURRENT mesh/selection state, not
            //    the state at the time the original command ran. If the original
            //    bevel targeted edge 5 but the selection has since changed, the
            //    replay hits the current selection.
            //  - Selection state is not stored per entry; if the replayed command
            //    depends on selection (e.g. vert.merge), the caller must re-select
            //    before calling this endpoint.
            if (replayProvider is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"replay provider not set"}`;
                response.headers["Content-Type"] = "application/json";
            } else {
                try {
                    auto j = parseJSON(request.body);
                    if ("index" !in j ||
                        (j["index"].type != JSONType.integer &&
                         j["index"].type != JSONType.uinteger))
                        throw new Exception("missing 'index' integer field");

                    long idx = (j["index"].type == JSONType.integer)
                               ? j["index"].integer
                               : cast(long)j["index"].uinteger;
                    if (idx < 0) throw new Exception("'index' must be non-negative");

                    string line = replayProvider(cast(size_t)idx);
                    if (line.length == 0) {
                        response.statusCode = 200;
                        response.body = `{"status":"error","message":"no entry at given index"}`;
                    } else {
                        // Parse the line and dispatch through the existing
                        // main-thread bridge — identical path to argstring /api/command.
                        auto parsed = parseArgstring(line);
                        if (parsed.isEmpty)
                            throw new Exception("entry parsed as empty");
                        // NOTE: req.interactive is deliberately left untouched
                        // here — the shared command bridge's req is a
                        // PERSISTENT field, and history-replay inherits
                        // whatever the previous dispatch left it at (exactly
                        // as before this refactor).
                        commandBridge.req.id     = parsed.commandId;
                        commandBridge.req.params = parsed.params.toString();
                        commandBridge.resp.error = "";
                        if (!commandBridge.submitAndWait())
                            commandBridge.resp.error = "timeout waiting for main thread";
                        if (commandBridge.resp.error.length == 0) {
                            response.statusCode = 200;
                            response.body = `{"status":"ok","line":"`
                                          ~ line.replace("\\", "\\\\").replace("\"", "\\\"")
                                          ~ `"}`;
                        } else {
                            response.statusCode = 200;
                            response.body = `{"status":"error","message":"`
                                          ~ commandBridge.resp.error.replace("\\", "\\\\").replace("\"", "\\\"")
                                          ~ `"}`;
                        }
                    }
                } catch (Exception e) {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                  ~ e.msg.replace("\\", "\\\\").replace("\"", "\\\"") ~ `"}`;
                }
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path == "/api/play-events" && request.method == "POST") {
            if (!testMode) {
                response.statusCode = 403;
                response.body = `{"error":"play-events is only available in --test mode"}`;
                response.headers["Content-Type"] = "application/json";
            } else if (eventPlayer.load(request.body) && eventPlayer.entries.length > 0) {
                response.statusCode = 200;
                response.body = `{"status": "success", "message": "Events loaded successfully"}`;
                response.headers["Content-Type"] = "application/json";
            } else {
                response.statusCode = 400;
                response.body = `{"status": "error", "message": "Failed to parse events"}`;
                response.headers["Content-Type"] = "application/json";
            }
        } else {
            response.statusCode = 404;
            response.body = "<html><body><h1>404 Not Found</h1><p>The requested resource was not found.</p></body></html>";
            response.headers["Content-Type"] = "text/html";
        }

        return response;
    }

    /**
     * Format an HTTP response
     */
    private string formatResponse(HttpResponse response) {
        string statusLine;
        switch (response.statusCode) {
            case 200: statusLine = "HTTP/1.1 200 OK"; break;
            case 400: statusLine = "HTTP/1.1 400 Bad Request"; break;
            case 404: statusLine = "HTTP/1.1 404 Not Found"; break;
            case 500: statusLine = "HTTP/1.1 500 Internal Server Error"; break;
            default: statusLine = "HTTP/1.1 " ~ to!string(response.statusCode) ~ " Unknown";
        }

        string headers = "";
        foreach (key, value; response.headers) {
            headers ~= key ~ ": " ~ value ~ "\r\n";
        }
        headers ~= "Content-Length: " ~ to!string(response.body.length) ~ "\r\n";
        headers ~= "\r\n";

        return statusLine ~ "\r\n" ~ headers ~ response.body;
    }

    /**
     * Tick the event player — call once per frame from the main loop
     * for time-based playback of a previously loaded event log.
     */
    public bool tickEventPlayer() {
        return eventPlayer.tick();
    }

    /**
     * Tick every registered main-thread bridge — call once per frame from the
     * main loop. Replaces the old hand-maintained tickReset()..tickJump()
     * call list: each bridge self-registered into `bridges` at construction
     * (see the HttpServer ctor), so a new marshaled endpoint cannot forget
     * to be ticked — forgetting to CONSTRUCT it is the only way to miss a
     * tick, which surfaces loudly (null-deref on first use) rather than as
     * a silent 5s production timeout.
     */
    public void tickAll() {
        foreach (b; bridges) b.tick();
    }

    /**
     * Check if the server is currently running
     */
    public bool running() const {
        return isRunning;
    }

    /**
     * Get the port the server is running on
     */
    public ushort getPort() const {
        return port;
    }
}

/**
 * Simple HTTP request representation
 */
class HttpRequest {
    public string method;
    public string path;
    public string httpVersion;
    public string[string] headers;
    public string body;

    public this(string method, string path, string httpVersion) {
        this.method = method;
        this.path = path;
        this.httpVersion = httpVersion;
        this.headers = new string[string];
    }
}

/**
 * Simple HTTP response representation
 */
class HttpResponse {
    public int statusCode;
    public string[string] headers;
    public string body;

    public this() {
        this.statusCode = 200;
        this.headers = new string[string];
        this.headers["Server"] = "Vibe3D-HTTP-Server/1.0";
        this.headers["Connection"] = "close";
        this.body = "";
    }
}

// Parse `?key=N` (or `&key=N`) from a request path. Returns `def` when the
// key is missing or not parseable as int.
private int parseQueryInt(string path, string key, int def) {
    import std.conv : to, ConvException;
    auto qi = path.indexOf('?');
    if (qi < 0) return def;
    foreach (kv; path[qi + 1 .. $].split('&')) {
        auto eq = kv.indexOf('=');
        if (eq < 0) continue;
        if (kv[0 .. eq] == key) {
            try return kv[eq + 1 .. $].to!int;
            catch (ConvException) return def;
        }
    }
    return def;
}

// Parse `?key=str` (or `&key=str`) from a request path. Returns `def` when
// the key is missing.
private string parseQueryString(string path, string key, string def) {
    auto qi = path.indexOf('?');
    if (qi < 0) return def;
    foreach (kv; path[qi + 1 .. $].split('&')) {
        auto eq = kv.indexOf('=');
        if (eq < 0) continue;
        if (kv[0 .. eq] == key) return kv[eq + 1 .. $].idup;
    }
    return def;
}

/**
 * Convert mesh data to JSON string
 */
string meshToJson(size_t vertexCount, size_t edgeCount, size_t faceCount) {
    import std.format : format;
    string res = format("{\"vertexCount\": %d, \"edgeCount\": %d, \"faceCount\": %d, \"timestamp\": \"%s\"}",
                  vertexCount, edgeCount, faceCount, Clock.currTime.toISOExtString());
    return res;
}

/**
 * Convert detailed mesh data to JSON string
 */
string meshToJsonDetailed(size_t vertexCount, size_t edgeCount, size_t faceCount,
                          float[] vertices, uint[2][] edges,
                          uint[][] faces, bool[] isSubpatch,
                          Surface[] surfaces, uint[] faceMaterial,
                          uint[] facePart = null) {
    import std.format : format;
    import std.array : appender;
    import std.string : join;

    auto json = appender!string();
    json ~= "{";
    json ~= format("\"vertexCount\": %d, ", vertexCount);
    json ~= format("\"edgeCount\": %d, ", edgeCount);
    json ~= format("\"faceCount\": %d, ", faceCount);
    json ~= format("\"timestamp\": \"%s\", ", Clock.currTime.toISOExtString());

    // Add vertices array
    json ~= "\"vertices\": [";
    for (size_t i = 0; i < vertices.length; i += 3) {
        if (i > 0) json ~= ", ";
        json ~= format("[%f, %f, %f]", vertices[i], vertices[i+1], vertices[i+2]);
    }
    json ~= "], ";

    // Add edges array (each edge as a 2-element [a, b] vertex-index pair)
    json ~= "\"edges\": [";
    for (size_t i = 0; i < edges.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= format("[%d, %d]", edges[i][0], edges[i][1]);
    }
    json ~= "], ";

    // Add faces array
    json ~= "\"faces\": [";
    for (size_t i = 0; i < faces.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= "[";
        for (size_t j = 0; j < faces[i].length; ++j) {
            if (j > 0) json ~= ", ";
            json ~= format("%d", faces[i][j]);
        }
        json ~= "]";
    }
    json ~= "], ";

    // Add per-face subpatch flags (parallel to faces[]).
    json ~= "\"isSubpatch\": [";
    for (size_t i = 0; i < isSubpatch.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= isSubpatch[i] ? "true" : "false";
    }
    json ~= "], ";

    // Material Groups (MG2): the per-mesh surface registry and per-face
    // material indices into it. Exposed so render_diff and the LWO
    // surface-loader tests can verify what the parser produced.
    json ~= "\"surfaces\": [";
    for (size_t i = 0; i < surfaces.length; ++i) {
        if (i > 0) json ~= ", ";
        const s = surfaces[i];
        json ~= format(
            "{\"name\":\"%s\",\"baseColor\":[%f,%f,%f],\"diffuseAmount\":%f," ~
            "\"specularAmount\":%f,\"glossiness\":%f,\"opacity\":%f}",
            s.name.replace("\"", "\\\""),
            s.baseColor.x, s.baseColor.y, s.baseColor.z,
            s.diffuseAmount, s.specularAmount, s.glossiness, s.opacity);
    }
    json ~= "], ";
    json ~= "\"faceMaterial\": [";
    for (size_t i = 0; i < faceMaterial.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= format("%d", faceMaterial[i]);
    }
    json ~= "], ";
    json ~= "\"facePart\": [";
    for (size_t i = 0; i < facePart.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= format("%d", facePart[i]);
    }
    json ~= "]";
    json ~= "}";

    return json.data;
}