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

import mesh : Mesh, Surface;
// The JSON bodies and the escaper that assembles them (task 0720, D5). Public
// re-export: http_providers.d reaches `meshToJsonDetailed` through this module
// and did so before the split.
public import http_json : jsonEsc, meshToJsonDetailed;
import core.atomic;
import perf_probe : g_perf, g_frames, g_fc;

// For event player functionality
import bindbc.sdl;
import eventlog;
import argstring : parseArgstring, ParsedLine;
import log : logInfo, logWarn, logError;
import app_version : appVersion, appBuildConfig, appPlatform, appBuildDate,
                     appAboutLines;

// ---------------------------------------------------------------------------
// versionJson — the GET /api/version payload (task 0641).
//
// All compile-time constants, so this is safe to build on the HTTP thread
// without the main-thread bridge every state-reading endpoint needs.
//
// `lines` carries `appAboutLines` verbatim rather than re-deriving the block
// from the scalar fields: it is the array the About window draws and the
// array `--version` prints, and shipping it unchanged is what lets a test
// assert that all three surfaces read one source. Re-formatting it here would
// have created the second literal the whole task is about.
// ---------------------------------------------------------------------------
string versionJson() {
    JSONValue j;
    j["version"]  = JSONValue(appVersion);
    j["build"]    = JSONValue(appBuildConfig);
    j["platform"] = JSONValue(appPlatform);
    j["built"]    = JSONValue(appBuildDate);
    JSONValue[] lines;
    foreach (line; appAboutLines) lines ~= JSONValue(line);
    j["lines"] = JSONValue(lines);
    return j.toString();
}

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
// Command dispatch gets a longer leash than the 2500-iter default: a
// legitimate one-shot mesh command on a ~100K-face mesh (whole-mesh bevel,
// edge extrude) runs tens of seconds on the main thread, and a 5s cap
// turns the perf harness's measurement into a timeout error — and worse,
// wedges every FOLLOWING request while the main thread finishes the work
// the client already gave up on. 60000 iters ≈ 2 min.
enum int kCommandBridgeMaxIters = 60_000;

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
            if (++iters > maxIters) {
                // The main thread never drained this request. Callers emit
                // their own timeout body, but such a body reads like an
                // ordinary API error — and for the silent-timeout callers
                // (reset/undo/jump) there is no body at all. Say it once,
                // loudly, where whoever is driving the app will see it.
                try {
                    import std.format : format;
                    logWarn("http", format(
                        "main thread did not service a %s request within %d ms —"
                        ~ " the reply is a timeout, not a result",
                        Req.stringof, maxIters * 2));
                } catch (Exception) {}
                return false;
            }
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
    // WHY THIS IS `shared` AND WHY EVERY ACCESS GOES THROUGH core.atomic
    // (task 1710; the race was reported by the tsan lane on 2026-08-21).
    //
    // The flag is WRITTEN by the accept-loop thread (`start()`'s lambda, once
    // bind/listen have succeeded) and by the main thread (`stop()`), and it is
    // READ by both. Nothing synchronised any of that: it was a plain
    // non-shared bool, which in D means a racing access is undefined, not
    // merely unordered.
    //
    // What the HARDWARE is permitted to do: the load and the store are one
    // aligned byte, so nothing can tear — but on a weakly-ordered target
    // (aarch64; we ship macOS arm64) the accept thread's `isRunning = true`
    // carries NO happens-before edge for the `serverSocket = new TcpSocket()`
    // and `listen()` that precede it. A main thread that saw `true` was
    // entitled to see a stale `serverSocket`, and `stop()` — main thread —
    // dereferences exactly that field to close it.
    //
    // What the COMPILER is permitted to do: treat a non-shared field as
    // untouched by other threads, i.e. keep it in a register across a region
    // it can prove does no aliasing write, and fold `running()` (a trivial
    // `const` accessor, visible for inlining because dub compiles the package
    // as one unit) into the caller.
    //
    // Whether any caller DEPENDS on the answer — yes, both of them, which is
    // what makes this a defect and not a benign flag:
    //   * app.d's frame loop gates the whole HTTP drain on `running()`. A
    //     stale `false` there means requests are accepted and never answered,
    //     the exact failure the 0652 comment below calls the worst shape a
    //     harness can meet.
    //   * app.d's `scope(exit)` calls `stop()` only if `running()` is true,
    //     and `stop()` itself early-outs on the same flag. A stale `false` on
    //     either read means the accept loop is never asked to stop and never
    //     has its socket closed, so process teardown joins a thread parked in
    //     accept() — a hang, not a wrong pixel.
    // Sequentially-consistent order is the default and is kept: the store
    // happens twice in a process lifetime, so there is nothing to buy by
    // weakening it and a real cost to reasoning about it.
    private shared bool isRunning;
    private ushort port;
    private Thread serverThread;
    private alias DetailedModelDataProvider = string delegate();
    private DetailedModelDataProvider detailedModelDataProvider;
    private alias CameraDataProvider = string delegate(int);
    private CameraDataProvider cameraDataProvider;
    private alias SelectionDataProvider = string delegate();
    private SelectionDataProvider selectionDataProvider;
    // GET /api/tool/handles — the active tool's ToolHandles registry (part
    // id / hover-state / visibility / screen anchor per handle, plus the
    // shared hot/captured part), and GET /api/tool/state — its per-tool
    // transient dump (task 0234, doc/tool_handles_state_plan.md). Both are
    // read-only test-introspection endpoints, and neither MUTATES anything
    // (no g_pipeCtx cache write, unlike /api/toolpipe/eval or /api/snap).
    //
    // They no longer share a thread contract, and the difference is not
    // arbitrary — it follows the lifetime of what each one reads:
    //
    //   * /api/tool/handles is MARSHALED onto the main thread
    //     (toolHandlesBridge, task 0563). The handle registry is not resident
    //     state: it is destroyed and rebuilt on every interactive draw, so
    //     "read it with no lock between settles" is not a contract it can
    //     honour — there is no moment at which the list is both complete and
    //     guaranteed to describe the caller's most recent change. See the
    //     bridge declaration below.
    //   * /api/tool/state is still served straight from the HTTP thread. Its
    //     provider reads RESIDENT per-tool transient fields, which are not
    //     torn down per frame, so the original quiescence contract (tests
    //     probe between play-events settles, never mid-drag) still holds for
    //     it. Note it inherits the weaker half of the problem regardless: a
    //     read issued immediately after a mutating POST may still observe
    //     pre-change values, because nothing forces a main-loop pass in
    //     between. Marshal it too if that ever shows up as a flake.
    //
    // Do not serve a tool-state read from the HTTP thread if answering it
    // would require mutating shared state, or if what it reads is rebuilt
    // per frame — use a bridge.
    //
    // THIRD CLAUSE, and the only one that has actually killed the process:
    // do not serve it from the HTTP thread if answering it CONSTRUCTS
    // anything. There is no GL context on this thread, and a great many
    // constructors in this codebase allocate GL in their ctor body — every
    // Handler shape funnels into handles/gl_util.buildVao3f
    // (glGenVertexArrays), every *Shader compiles a program, and because a
    // Tool builds its gizmo banks in its own ctor, so does every Tool. So
    // "call a registry factory" and "touch GL" are the same act here, and
    // it is not a race: it faults, or silently no-ops, undefined either way.
    // /api/registry?params=1 died of exactly this (task 0579) by calling
    // every factory to read its Param schema; the fix was to answer from a
    // startup-built snapshot rather than to bridge, because a schema is a
    // property of the class and needs no live instance.
    //
    // The rule that follows from all three: a provider may READ resident
    // plain data. The moment it needs `new`, a factory, a per-frame
    // structure, or a write to shared state, it belongs on a bridge — or,
    // better, on a snapshot taken at startup on the main thread.
    private alias ToolHandlesDataProvider = string delegate();
    private ToolHandlesDataProvider toolHandlesDataProvider;
    private alias ToolStateDataProvider = string delegate();
    private ToolStateDataProvider toolStateDataProvider;
    // /api/layers (GET) — JSON layer list. /api/model?layer=N — a layer-aware
    // detailed provider (N=-1 → active layer).
    //
    // ~~Both marshal onto the main thread via the existing model epoch
    // handshake (tickModel).~~ CORRECTED (task 0612 Stage 3): that was never
    // true of `/api/layers`. `/api/model` is marshaled through `modelBridge`;
    // `/api/layers`'s route served it straight from the HTTP thread and said
    // so in a comment of its own, and the route was the one telling the
    // truth. The claim is now made true rather than merely deleted — the
    // route below marshals through `layersBridge`, because the provider gained
    // a nested `indexOf` walk (a link's target index) INSIDE the loop already
    // walking `layers`, while the main thread splices that same array at four
    // sites. A splice between the two reads makes the response name the wrong
    // layer, which is worse than an error because it looks like an answer.
    // (Task 0611's quarry exactly: not a write, but two reads of state that
    // can change between them.)
    private alias LayersDataProvider = string delegate();
    private LayersDataProvider layersDataProvider;
    private alias LayerModelProvider = string delegate(int layer);
    private LayerModelProvider layerModelProvider;
    private alias RecordedEventsProvider = string delegate();
    private RecordedEventsProvider recordedEventsProvider;
    // GET /api/registry — returns {"commands":[...],"tools":[...]} listing
    // every registered command and tool factory id. Read-only snapshot of
    // post-startup-immutable AAs; served directly from the HTTP thread.
    // (It used to cite toolpipeProvider as the precedent for that; do not
    // read it that way — toolpipeProvider is bridged. What makes THIS one
    // safe is that it copies out pre-built strings and calls nothing.)
    //
    // `?params=1` (task 0365 — param-bounds Phase 3) additionally requests
    // per-id Param schemas (`commandParams`/`toolParams`); the bool arg is
    // whether the caller asked for that mode. It is served from schemas
    // serialised ONCE at startup, on the main thread, beside
    // cacheSupportedModes(). It emphatically does NOT instantiate factories
    // per request any more: doing so ran tool constructors — and therefore
    // glGenVertexArrays — on this thread and killed the process (task 0579).
    // This is the enabler for the fuzz-smoke's static contract check
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
    // interactive Move drag through play-events.
    //
    // MARSHALED onto the main thread via snapQueryBridge (task 0587). Two of
    // the standing rule's three clauses applied, and each on its own would
    // have been enough:
    //
    //   * it MUTATES shared state — twice. g_pipeCtx.pipeline.evaluate()
    //     re-runs the pipe and writes the shared stage caches (the same
    //     hazard that bridged /api/toolpipe/eval), and the closure then
    //     wrote snap.d's __gshared g_itemSnapFrames via setItemSnapFrames().
    //   * what it reads is REBUILT PER FRAME — g_itemSnapFrames is installed
    //     unconditionally by every draw (ui/panels.d), so a read taken off
    //     the main thread has no moment at which the buffer is both complete
    //     and describes the caller's document.
    //
    // The third clause (constructs anything) did NOT apply: the walk is
    // GL-free, swept and measured in task 0584. That is why this was a race
    // and not a fault, and why it outlived the sweep that found it.
    //
    // The second write is now GONE rather than protected: once the read runs
    // on the main thread, the per-frame install is already correct and the
    // provider's just-in-time copy of it was pure duplication. See app.d.
    //
    // For the record, since it was cited as a precedent twice: this endpoint
    // was never "read-only, same convention as toolpipeEvalProvider" —
    // toolpipeEvalProvider was already bridged when that note was written.
    private alias SnapQueryProvider = string delegate(string requestBody);
    private SnapQueryProvider snapQueryProvider;
    // /api/constrain — POST. Body is {pos:[x,y,z], delta:[x,y,z]};
    // evaluates the pipeline to pull the live ConstrainPacket, snapshots
    // the background sources, and returns the projected point.
    //
    // MARSHALED onto the main thread via its own bridge (task 0587), on the
    // same two clauses as /api/snap:
    //
    //   * it MUTATES shared state — pipeline.evaluate() writes the shared
    //     stage caches, exactly as above. It does NOT write g_itemSnapFrames;
    //     that half was /api/snap's alone.
    //   * what it reads is REBUILT PER FRAME — backgroundSourcesSnapshot()
    //     copies g_snapSources, which every draw reinstalls unconditionally
    //     (ui/panels.d, beside the item frames). The grid mutex makes that
    //     copy untorn, which is not the same thing as current: it can still
    //     answer from the set the previous frame installed.
    //
    // The third clause (constructs anything) does not apply — GL-free, swept
    // in 0584. It genuinely does mirror /api/snap; as of 0587 that means
    // "also bridged", not "also direct", which is what this note used to say.
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
    // Task 1520 — the UI-policy adapter. Separate FIELD, not a flag on the
    // one above, because the two carry opposite refusal policies and
    // `/api/command?origin=ui` (--test only) exists to drive the UI one.
    private CommandHandler uiCommandHandler;
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

    // ----- /api/test/layer synchronous bridge -------------------------------
    // POST /api/test/layer {"kind":"empty","name":"...","index":N}
    // appends (or inserts) a layer of the given KIND directly into the live
    // document — task 0615 Stage 6/7. This is deliberately NOT a Command: it
    // is unreachable from `/api/command` by name, from `config/buttons.yaml`,
    // and from any UI affordance. The document format cannot yet persist a
    // non-mesh item (Stage 8/v8 is deferred to task 0616 by owner decision —
    // see doc/nonmesh_item_types_plan.md §Stage 6), so no path a real user
    // could reach — command argument, button, or menu — may create one in
    // this slice; a test driving this ONE dedicated endpoint is the sole
    // source. Mirrors `/api/load-mesh`'s main-thread bridge (the live
    // `Document` is touched from the main/GL thread only).
    private alias InjectLayerHandler = void delegate(JSONValue params);
    private InjectLayerHandler injectLayerHandler;

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

    // ----- GET /api/trace / POST /api/trace/reset ---------------------------
    // Non-destructive per-step capture (task: step-trace). traceProvider
    // returns the whole ring as a JSON array string — a snapshot-at-
    // request-time read (mirrors historyProvider), guarded on the app.d side
    // by StepTrace's own Mutex since appends can reallocate the backing
    // array. traceResetHandler clears the ring; also fired from the
    // /api/reset handler so a scene reset starts a fresh trace.
    private alias TraceProvider = string delegate();   // returns JSON array
    private TraceProvider traceProvider;
    private alias TraceResetHandler = void delegate();
    private TraceResetHandler traceResetHandler;

    // ----- GET /api/pick — A/B face-pick equivalence oracle (test-only) -----
    // Marshaled onto the main thread: GPU pick needs a GL context; BVH pick
    // reads mesh + GpuMesh state. engine=bvh|gpu is dispatched by the provider.
    private alias PickProvider = string delegate(int x, int y, string engine);
    private PickProvider pickProvider;

    // ----- GET /api/surface-raycast — background-surface raycast oracle -----
    // (topology-pen P0, test-only). Marshaled onto the main thread (mirrors
    // PickProvider) so the CONS stage's per-cursor raycast branch — gated on
    // SubjectPacket.cursorValid, only ever true on a main-thread path — can
    // run safely. Returns the resolved ConstrainHitPacket as JSON. `thresholdPx`
    // (P1, doc/topopen_p1_plan.md) is the resolveHoverTarget snap radius;
    // <= 0 means "use the tool's own default" (`topoPenPressPickPx(vp)`).
    private alias SurfaceRaycastProvider = string delegate(int x, int y, float thresholdPx);
    private SurfaceRaycastProvider surfaceRaycastProvider;

    // ----- GET /api/viewport/display — resolved draw-plan dump (test-only) --
    // Task 0559. Returns, per viewport cell, the cell's display STATE and the
    // resolved DRAW PLANS the renderer consumes for the active mesh and for a
    // background layer. It is a real assertion target precisely because the
    // renderer reads the same struct this dumps — a parallel re-derivation
    // could silently drift from what is actually drawn; this cannot.
    //
    // Task 1650 added `overlayOwner` (top level) and `overlayMode` per cell,
    // on the same terms: they come off `editor_app.resolveOverlayMode`, the
    // one function the N-cell render loop branches on. That is what lets a
    // test assert WHICH cells draw the tool gizmo — the question
    // /api/viewport/probe answers only in pixels, and only for cells that
    // rendered.
    // Marshaled onto the main thread: it reads live per-cell viewport state.
    private alias ViewportDisplayProvider = string delegate();
    private ViewportDisplayProvider viewportDisplayProvider;

    // ----- GET /api/viewport/probe — FBO pixel readback (test-only) --------
    // Task 0559. glReadPixels against one cell's colour attachment, so a test
    // can assert what GL actually produced rather than what the plan says it
    // should have. Needs the GL context, hence the main-thread bridge.
    //
    // ⚠ KNOWN LIMITATION, and it is a silent-pass trap: a probe aimed at a
    // cell that was not rendered reads a never-filled FBO, and any assertion
    // on it passes for the wrong reason. The response therefore carries a
    // `renders` flag per request; assert on it.
    //
    // Task 1650 NARROWED the limitation but did not remove it. `--test` used
    // to render the ACTIVE cell and nothing else; it now renders every cell
    // of a MULTI-cell layout as well (`viewport.testRendersCell`), because the
    // old rule made the `OverlayMode.Visual` replica path unreachable from the
    // test lane — a check on it could not come out differently. A SINGLE-cell
    // layout still renders one cell, which is every live cell there, so the
    // flag is the thing to assert either way. Cells that are not rendered are
    // still covered by /api/viewport/display state assertions, which need no
    // render.
    private alias ViewportProbeProvider =
        string delegate(int cell, string points, bool wantHash);
    private ViewportProbeProvider viewportProbeProvider;

    // ----- /api/images provider (task 0612 Stage 1) ------------------------
    // GET /api/images — the document's image-clip rows (stored + resolved
    // path, the derived header fields, `missing`) plus the pixel cache's
    // residency counters.
    //
    // MARSHALED, and the reason is 0611's exact shape rather than "writes are
    // dangerous": forming one response reads the layer array, each row's
    // payload, and the cache's counters — several pieces of state that must
    // agree with each other, while the main thread is free to splice the
    // layer array between two of the reads. A torn response here would name a
    // row's path beside another row's dimensions, which is worse than an
    // error because it looks like an answer.
    private alias ImagesDataProvider = string delegate();
    private ImagesDataProvider imagesDataProvider;

    // ----- /api/imageplane provider (task 0612 Stage 4) --------------------
    // GET /api/imageplane?index=N&cell=K — the resolved placement of plane
    // layer N in viewport cell K.
    //
    // KEYED ON THE CELL, NOT ON A PRESET, and that is the difference between
    // an assertion and a tautology: an earlier draft took `&view=front`, i.e.
    // handed the endpoint the very preset whose resolution the test wanted to
    // check. `cell=K` follows `/api/viewport/probe?cell=N`; the provider
    // resolves `(viewPreset, projKind)` from `vpm.views[K].camera` itself, so
    // "which cell shows which plane" is something the response can get wrong.
    //
    // MARSHALED (the /api/tool/handles precedent): forming one response reads
    // a `Layer`, its link, the link TARGET's image payload and a viewport
    // cell — four objects that must agree with each other, while the main
    // thread is free to splice the layer array between two of the reads.
    private alias ImagePlaneProvider = string delegate(int index, int cell);
    private ImagePlaneProvider imagePlaneProvider;

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
    // block on the history. The refire bracket is driven on the main thread
    // (EditSession); this endpoint exists for HTTP-driven tests.
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

    // POST /api/snap and POST /api/constrain — one bridge each, own epoch pair
    // (MUST NOT share pipeEval's or each other's, same rule as pathBridge).
    // Both providers run g_pipeCtx.pipeline.evaluate() to pull a fully-
    // populated SnapPacket/ConstrainPacket, which is the identical hazard that
    // put /api/toolpipe/eval on a bridge: evaluate() re-runs the pipe over the
    // live mesh + selection and mutates the shared stage caches in g_pipeCtx
    // concurrently with the main thread's own per-frame evaluate(). The
    // request payload is the raw POST body; the provider parses it, because
    // the parse is part of the answer (a malformed body is reported as a 200
    // with an {"error":...} object, not as a transport failure).
    struct SnapQReq  { string body_; }
    struct SnapQResp { string result; string error; }
    private MainThreadBridge!(SnapQReq, SnapQResp) snapQueryBridge;

    struct ConstrainQReq  { string body_; }
    struct ConstrainQResp { string result; string error; }
    private MainThreadBridge!(ConstrainQReq, ConstrainQResp) constrainQueryBridge;

    // `uiOrigin` (task 1520): dispatch this line through the UI adapter, whose
    // refusal is a notice rather than an exception. `--test` only.
    struct CmdReq  { string id; string params; bool interactive; bool uiOrigin; }
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

    struct InjectLayerReq  { JSONValue params; }
    struct InjectLayerResp { string error; }
    private MainThreadBridge!(InjectLayerReq, InjectLayerResp) injectLayerBridge;

    struct CamSetReq  { JSONValue params; }
    struct CamSetResp { string error; }
    private MainThreadBridge!(CamSetReq, CamSetResp) cameraSetBridge;

    struct GpuSurfReq  { }
    struct GpuSurfResp { string result; string error; }
    private MainThreadBridge!(GpuSurfReq, GpuSurfResp) gpuSurfaceBridge;

    struct PickReq  { int x; int y; string engine; }
    struct PickResp { string result; string error; }
    private MainThreadBridge!(PickReq, PickResp) pickBridge;

    // ----- /api/subpatch/preview + /api/subpatch/hold (task 1500) ---------
    // The ONE source of the async build's numbers: the test, the indicator
    // and the perf lane all read this route, so there is no second place for
    // them to disagree. Main-thread bridged (it reads live SubpatchPreview
    // state) and — this is the point of the barrier being narrow —
    // ANSWERABLE WHILE A BUILD IS IN FLIGHT, because `tickAll` is not gated.
    // An observation handle that goes silent exactly when there is something
    // to observe is not an observation handle.
    private alias SubpatchStateProvider = string delegate();
    private SubpatchStateProvider subpatchStateProvider;
    struct SubpStateReq  { }
    struct SubpStateResp { string result; string error; }
    private MainThreadBridge!(SubpStateReq, SubpStateResp) subpatchStateBridge;

    private alias SubpatchHoldHandler = string delegate(long ms, long ceilingMs);
    private SubpatchHoldHandler subpatchHoldHandler;
    struct SubpHoldReq  { long ms; long ceilingMs; }
    struct SubpHoldResp { string result; string error; }
    private MainThreadBridge!(SubpHoldReq, SubpHoldResp) subpatchHoldBridge;

    struct SurfaceRaycastReq  { int x; int y; float thresholdPx = -1.0f; }
    struct SurfaceRaycastResp { string result; string error; }
    private MainThreadBridge!(SurfaceRaycastReq, SurfaceRaycastResp) surfaceRaycastBridge;

    // Task 0559 — two endpoints, TWO bridges, each with its OWN epoch pair.
    // They must not share one (nor borrow another endpoint's): a concurrent
    // pair of requests on a shared epoch pair cross-trips each other's spin,
    // since either completed-bump satisfies both waiters and one of them
    // returns a torn or empty result. Same hard rule as pathBridge and
    // toolpipeBridge.
    struct VpDisplayReq  { }
    struct VpDisplayResp { string result; string error; }
    private MainThreadBridge!(VpDisplayReq, VpDisplayResp) vpDisplayBridge;

    struct VpProbeReq  { int cell = -1; string points; bool wantHash; }
    struct VpProbeResp { string result; string error; }
    private MainThreadBridge!(VpProbeReq, VpProbeResp) vpProbeBridge;

    // Task 0612 Stage 1 — /api/images. Its OWN bridge instance (never shared,
    // the same hard rule as pathBridge / toolpipeBridge): two endpoints
    // sharing one bridge interleave their epochs and one of them returns a
    // torn or empty result.
    struct ImagesReq  { }
    struct ImagesResp { string result; string error; }
    private MainThreadBridge!(ImagesReq, ImagesResp) imagesBridge;

    // Task 0612 Stage 3 — /api/layers, marshaled. Its OWN bridge instance,
    // same rule as every other one.
    struct LayersReq  { }
    struct LayersResp { string result; string error; }
    private MainThreadBridge!(LayersReq, LayersResp) layersBridge;

    // Task 0612 Stage 4 — /api/imageplane. Its OWN bridge instance, same rule
    // as every other one.
    struct PlaneReq  { int index; int cell; }
    struct PlaneResp { string result; string error; }
    private MainThreadBridge!(PlaneReq, PlaneResp) planeBridge;

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

    // GET /api/tool/handles — own bridge/epoch pair (MUST NOT share any other
    // bridge's, same rule as pathBridge/toolpipeBridge above). The
    // null-provider case is decided on the HTTP thread (200 {"handles":null}),
    // so this bridge's service only ever runs when the provider is set.
    //
    // WHY THIS IS MARSHALED AND NOT SERVED FROM THE HTTP THREAD — the handle
    // registry is not a resident structure that can be read at any time. It is
    // REBUILT FROM EMPTY on every interactive draw of the owner cell:
    // `ToolHandles.begin()` truncates the entry list and the register pass
    // immediately refills it (handles/arbiter.d, and the two call sites in
    // tools/transform/xfrm_transform.d). A lock-free read from the HTTP thread
    // therefore has two distinct failure modes, and both were live:
    //
    //   1. TORN — the read lands between `begin()` and the last `add()` and
    //      observes an empty or half-filled parts array for a tool that has
    //      handles.
    //   2. STALE — no interactive draw has happened yet SINCE the state the
    //      caller just changed. A test that POSTs `tool.set` and then GETs this
    //      endpoint is asking about a registry that does not exist until the
    //      next draw builds it, so it reads the previous tool's parts, or none.
    //
    // Mode 2 is the one that broke CI. It is invisible on a fast desktop, where
    // a frame lands inside the POST/GET round-trip, and reproducible on a
    // loaded software-GL host, where it does not. Marshaling fixes both at
    // once: the service body runs on the main thread, so nothing can be
    // observed mid-rebuild, and the epoch handshake cannot be satisfied until
    // the main loop has come round again — which, since a command POST is
    // drained by that same loop one pass earlier, guarantees the registry was
    // rebuilt by a draw that saw the caller's change.
    struct ToolHandlesReq  { }
    struct ToolHandlesResp { string result; string error; }
    private MainThreadBridge!(ToolHandlesReq, ToolHandlesResp) toolHandlesBridge;

    public this(ushort port = 8080) {
        this.port = port;
        atomicStore(this.isRunning, false);
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

        toolHandlesBridge = new MainThreadBridge!(ToolHandlesReq, ToolHandlesResp)(this,
            (ref ToolHandlesReq req, ref ToolHandlesResp resp) {
                try {
                    if (toolHandlesDataProvider !is null)
                        resp.result = toolHandlesDataProvider();
                    else
                        resp.error = "tool handles provider not set";
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

        snapQueryBridge = new MainThreadBridge!(SnapQReq, SnapQResp)(this,
            (ref SnapQReq req, ref SnapQResp resp) {
                try {
                    if (snapQueryProvider !is null)
                        resp.result = snapQueryProvider(req.body_);
                    else
                        resp.error = "snap query provider not set";
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            });

        constrainQueryBridge = new MainThreadBridge!(ConstrainQReq, ConstrainQResp)(this,
            (ref ConstrainQReq req, ref ConstrainQResp resp) {
                try {
                    if (constrainQueryProvider !is null)
                        resp.result = constrainQueryProvider(req.body_);
                    else
                        resp.error = "constrain query provider not set";
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
                        // Task 1520: pick the adapter. THIS LAMBDA CATCHES,
                        // which is precisely why no test here can observe the
                        // real failure mode (an exception escaping an ImGui
                        // draw). What it observes is the proxy "the UI adapter
                        // did not throw" — sound only because `uiCommandHandler`
                        // calls the app's `uiCommandDelegate` field itself.
                        if (req.uiOrigin && uiCommandHandler !is null)
                            uiCommandHandler(req.id, req.params);
                        else
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

        injectLayerBridge = new MainThreadBridge!(InjectLayerReq, InjectLayerResp)(this,
            (ref InjectLayerReq req, ref InjectLayerResp resp) {
                if (injectLayerHandler is null) {
                    resp.error = "inject-layer handler not set";
                } else {
                    try {
                        injectLayerHandler(req.params);
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

        subpatchStateBridge = new MainThreadBridge!(SubpStateReq, SubpStateResp)(this,
            (ref SubpStateReq req, ref SubpStateResp resp) {
                if (subpatchStateProvider is null) {
                    resp.error = "subpatch-state provider not set";
                } else {
                    try {
                        resp.result = subpatchStateProvider();
                        resp.error  = "";
                    } catch (Exception e) {
                        resp.error = e.msg;
                    }
                }
            });

        subpatchHoldBridge = new MainThreadBridge!(SubpHoldReq, SubpHoldResp)(this,
            (ref SubpHoldReq req, ref SubpHoldResp resp) {
                if (subpatchHoldHandler is null) {
                    resp.error = "subpatch-hold handler not set";
                } else {
                    try {
                        resp.result = subpatchHoldHandler(req.ms, req.ceilingMs);
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

        surfaceRaycastBridge = new MainThreadBridge!(SurfaceRaycastReq, SurfaceRaycastResp)(this,
            (ref SurfaceRaycastReq req, ref SurfaceRaycastResp resp) {
                if (surfaceRaycastProvider is null) {
                    resp.error = "surface-raycast provider not set";
                } else {
                    try {
                        resp.result = surfaceRaycastProvider(req.x, req.y, req.thresholdPx);
                        resp.error  = "";
                    } catch (Exception e) {
                        resp.error = e.msg;
                    }
                }
            });

        vpDisplayBridge = new MainThreadBridge!(VpDisplayReq, VpDisplayResp)(this,
            (ref VpDisplayReq req, ref VpDisplayResp resp) {
                if (viewportDisplayProvider is null) {
                    resp.error = "viewport-display provider not set";
                } else {
                    try {
                        resp.result = viewportDisplayProvider();
                        resp.error  = "";
                    } catch (Exception e) {
                        resp.error = e.msg;
                    }
                }
            });

        vpProbeBridge = new MainThreadBridge!(VpProbeReq, VpProbeResp)(this,
            (ref VpProbeReq req, ref VpProbeResp resp) {
                if (viewportProbeProvider is null) {
                    resp.error = "viewport-probe provider not set";
                } else {
                    try {
                        resp.result = viewportProbeProvider(req.cell, req.points, req.wantHash);
                        resp.error  = "";
                    } catch (Exception e) {
                        resp.error = e.msg;
                    }
                }
            });

        imagesBridge = new MainThreadBridge!(ImagesReq, ImagesResp)(this,
            (ref ImagesReq req, ref ImagesResp resp) {
                if (imagesDataProvider is null) {
                    resp.error = "images data provider not set";
                } else {
                    try {
                        resp.result = imagesDataProvider();
                        resp.error  = "";
                    } catch (Exception e) {
                        resp.error = e.msg;
                    }
                }
            });

        layersBridge = new MainThreadBridge!(LayersReq, LayersResp)(this,
            (ref LayersReq req, ref LayersResp resp) {
                if (layersDataProvider is null) {
                    resp.error = "Layers data provider not set";
                } else {
                    try {
                        resp.result = layersDataProvider();
                        resp.error  = "";
                    } catch (Exception e) {
                        resp.error = e.msg;
                    }
                }
            });

        planeBridge = new MainThreadBridge!(PlaneReq, PlaneResp)(this,
            (ref PlaneReq req, ref PlaneResp resp) {
                if (imagePlaneProvider is null) {
                    resp.error = "image-plane provider not set";
                } else {
                    try {
                        resp.result = imagePlaneProvider(req.index, req.cell);
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
     * Set the detailed model data provider callback
     */
    public void setDetailedModelDataProvider(DetailedModelDataProvider provider) {
        this.detailedModelDataProvider = provider;
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
    public void setSubpatchStateProvider(SubpatchStateProvider provider) {
        this.subpatchStateProvider = provider;
    }

    public void setSubpatchHoldHandler(SubpatchHoldHandler handler) {
        this.subpatchHoldHandler = handler;
    }

    public void setPickProvider(PickProvider provider) {
        this.pickProvider = provider;
    }

    /// GET /api/surface-raycast?x=&y=[&thresholdPx=] — background-surface
    /// raycast oracle (topology-pen P0/P1). Provider runs on the main
    /// thread so the CONS stage's raycast branch (gated on
    /// SubjectPacket.cursorValid) is safe to fire. `thresholdPx` (P1)
    /// overrides the hover snap-target resolution radius; omitted/<=0
    /// means "use the tool's own default".
    public void setSurfaceRaycastProvider(SurfaceRaycastProvider provider) {
        this.surfaceRaycastProvider = provider;
    }

    /// GET /api/viewport/display — per-cell display state + the resolved draw
    /// plans the renderer consumes (task 0559). Runs on the main thread.
    public void setViewportDisplayProvider(ViewportDisplayProvider provider) {
        this.viewportDisplayProvider = provider;
    }

    /// GET /api/viewport/probe?cell=N[&x=&y=][&points=x,y;x,y][&hash=1] —
    /// glReadPixels against a cell's FBO colour attachment (task 0559).
    /// Runs on the main thread (GL context). Coordinates are FBO pixels with
    /// the origin at the TOP-LEFT, matching screen/event coordinates; the
    /// provider flips to GL's bottom-up convention. See the provider alias
    /// for the --test single-rendered-cell trap.
    public void setViewportProbeProvider(ViewportProbeProvider provider) {
        this.viewportProbeProvider = provider;
    }

    /// GET /api/images — image-clip rows + pixel-cache residency counters
    /// (task 0612 Stage 1). Marshaled; see the provider alias for why.
    public void setImagesDataProvider(ImagesDataProvider provider) {
        this.imagesDataProvider = provider;
    }

    /// GET /api/imageplane?index=N&cell=K — the resolved placement of image
    /// plane N in cell K (task 0612 Stage 4). Marshaled; see the provider
    /// alias for why, and for why it is keyed on a CELL.
    public void setImagePlaneProvider(ImagePlaneProvider provider) {
        this.imagePlaneProvider = provider;
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

    /// Task 1520 — the UI-origin adapter, used only by
    /// `POST /api/command?origin=ui` (rejected outside `--test`). It must
    /// dispatch through the app's `uiCommandDelegate` FIELD, not through a
    /// second closure over the same body: the proxy every UI-policy test
    /// observes ("the UI adapter did not throw") is only meaningful if the
    /// route exercises the binding the 28 panel call sites use.
    public void setUiCommandHandler(CommandHandler handler) {
        this.uiCommandHandler = handler;
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
     * Set the test-only layer-injection handler (POST /api/test/layer). Same
     * synchronous main-thread dispatch as setLoadMeshHandler. See the
     * `injectLayerHandler` field doc comment for the full rationale.
     */
    public void setInjectLayerHandler(InjectLayerHandler handler) {
        this.injectLayerHandler = handler;
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
     * Set the GET /api/trace JSON-array provider (task: step-trace). Same
     * snapshot-at-request-time contract as setHistoryProvider.
     */
    public void setTraceProvider(TraceProvider provider) {
        this.traceProvider = provider;
    }

    /**
     * Set the POST /api/trace/reset handler — also invoked from the app's
     * /api/reset handler so a scene reset starts a fresh trace.
     */
    public void setTraceResetHandler(TraceResetHandler handler) {
        this.traceResetHandler = handler;
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
        if (atomicLoad(isRunning)) {
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
                atomicStore(isRunning, true);

                while (atomicLoad(isRunning)) {
                    try {
                        Socket clientSocket = serverSocket.accept();
                        handleClient(clientSocket);
                    } catch (Exception e) {
                        if (atomicLoad(isRunning)) {
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
        if (!atomicLoad(isRunning)) {
            logWarn("http", "Server is not running");
            return;
        }

        atomicStore(isRunning, false);
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

    // --- Per-connection I/O budget ----------------------------------------
    // The accept loop is SINGLE-THREADED and calls handleClient INLINE, so a
    // peer that connects and then never sends a complete request header used
    // to park the one server thread in recv() forever. Meanwhile listen()'s
    // backlog keeps completing TCP handshakes, so every LATER client still
    // connects successfully and then waits forever — the server "accepts and
    // never answers". That is the worst failure shape a harness can meet: a
    // readiness probe that only checks connectivity PASSES while nothing will
    // ever be served, and the timeout surfaces much later, blamed on whatever
    // was being measured (task 0652).
    //
    // Two bounds close it. clientIoTimeout caps a single blocking recv/send,
    // so an idle peer cannot park the loop; clientReadDeadline caps the whole
    // request read, so a peer dribbling one byte per timeout cannot either.
    // Both are enormous next to a real client, which sends its entire request
    // in one segment immediately. Hitting either is LOUD on stderr — closing a
    // connection without an answer must never be silent.
    //
    // Fields rather than manifest constants ONLY so an in-module unittest can
    // exercise the give-up paths in milliseconds instead of waiting the
    // production budget. Nothing in the app writes them.
    Duration clientIoTimeout    =  5.seconds;
    Duration clientReadDeadline = 15.seconds;

    /// True when the last socket call failed only because a signal arrived.
    /// The GC's stop-the-world signals every thread, so a blocking recv() on
    /// the HTTP thread is interrupted routinely and for no fault of the peer.
    /// Treating that as end-of-request drops a perfectly good in-flight
    /// request and closes the connection with no reply — the exact failure
    /// this file exists to make impossible — so callers must retry instead.
    /// Check this BEFORE wouldHaveBlocked(): both read `errno`.
    private static bool interruptedBySignal() nothrow @nogc {
        version (Posix) {
            import core.stdc.errno : errno, EINTR;
            return errno == EINTR;
        } else {
            return false;
        }
    }

    /// Report a connection we accepted and are closing WITHOUT a response.
    /// A separate `nothrow` helper because its caller is handleClient's
    /// `finally` block, where D forbids a `catch` statement outright.
    private static void reportAbandoned(string peer, MonoTime startedAt, string why) nothrow {
        try {
            import std.format : format;
            logWarn("http", format(
                "closed connection from %s after %.1fs WITHOUT a response: peer %s",
                peer, (MonoTime.currTime - startedAt).total!"msecs" / 1000.0, why));
        } catch (Exception) {}
    }

    /**
     * Handle a client connection
     */
    private void handleClient(Socket client) {
        import std.format : format;

        immutable startedAt = MonoTime.currTime;
        string peer = "<unknown peer>";
        // Non-empty means "closing this connection WITHOUT a response", which
        // is precisely the event that must never pass unreported.
        string abandoned;

        try {
            try { peer = client.remoteAddress().toString(); } catch (Exception) {}
            client.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, clientIoTimeout);
            client.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, clientIoTimeout);

            // Read until we have the full header block (ends with \r\n\r\n)
            ubyte[] raw;
            ubyte[4096] chunk;
            ptrdiff_t n;
            size_t headerEnd;
            while (true) {
                n = client.receive(chunk[]);
                if (n == 0) break;  // peer closed cleanly
                if (n < 0) {
                    if (interruptedBySignal()) {
                        if (MonoTime.currTime - startedAt <= clientReadDeadline) continue;
                        abandoned = format("request header still incomplete after %s",
                                           clientReadDeadline);
                        break;
                    }
                    abandoned = wouldHaveBlocked()
                        ? format("sent no request data for %s", clientIoTimeout)
                        : format("receive failed: %s", lastSocketError());
                    break;
                }
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
                if (MonoTime.currTime - startedAt > clientReadDeadline) {
                    abandoned = format("request header still incomplete after %s",
                                       clientReadDeadline);
                    break;
                }
            }

            if (abandoned.length) return;  // reported by the `finally` below
            // A peer that connects and closes without sending is an ordinary
            // liveness probe, not a fault — stay quiet about it.
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
                if (n == 0) break;  // peer closed cleanly; parse what arrived
                if (n < 0) {
                    if (interruptedBySignal()) {
                        if (MonoTime.currTime - startedAt <= clientReadDeadline) continue;
                        abandoned = format("body still incomplete (%d of %d bytes) after %s",
                                           bodyRaw.length, contentLength, clientReadDeadline);
                        break;
                    }
                    abandoned = wouldHaveBlocked()
                        ? format("stopped sending its body at %d of %d bytes (idle %s)",
                                 bodyRaw.length, contentLength, clientIoTimeout)
                        : format("receive failed reading body: %s", lastSocketError());
                    break;
                }
                bodyRaw ~= chunk[0 .. n];
                if (MonoTime.currTime - startedAt > clientReadDeadline) {
                    abandoned = format("body still incomplete (%d of %d bytes) after %s",
                                       bodyRaw.length, contentLength, clientReadDeadline);
                    break;
                }
            }
            if (abandoned.length) return;  // reported by the `finally` below

            HttpRequest httpRequest = parseRequest(headerPart, cast(string)bodyRaw.idup);
            HttpResponse response = handleRequest(httpRequest);

            string responseStr = formatResponse(response);
            auto sent = client.send(responseStr);
            if (sent < 0 || cast(size_t) sent != responseStr.length) {
                // A peer that stops reading stalls the send the same way a
                // silent peer stalled the receive — bounded by SNDTIMEO now,
                // but a half-delivered answer is still no answer, so say it.
                logWarn("http", format(
                    "peer %s took only %d of %d response bytes: %s",
                    peer, sent, responseStr.length,
                    sent < 0 ? lastSocketError() : "stopped reading"));
            }
        } catch (Exception e) {
            logWarn("http", "Error handling client: " ~ e.msg);
        } finally {
            // The whole point of task 0652: a connection we accepted and did
            // not answer is invisible to every caller (their probe connected
            // fine, their request just never came back), so it has to be
            // audible here or nowhere.
            if (abandoned.length) reportAbandoned(peer, startedAt, abandoned);
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
    /**
     * Handle an HTTP request and generate a response.
     *
     * The chain this used to be is now generated from `kRoutes` — same order,
     * same first-match-wins semantics, one registration point. See the table.
     */
    private HttpResponse handleRequest(HttpRequest request) {
        HttpResponse response = new HttpResponse();

        static foreach (r; kRoutes) {
            if ((r.method.length == 0 || request.method == r.method)
                && (r.match == Match.exact
                        ? request.path == r.path
                        : request.path.startsWith(r.path))) {
                __traits(getMember, this, r.handler)(request, response);
                return response;
            }
        }

        response.statusCode = 404;
        response.body = "<html><body><h1>404 Not Found</h1><p>The requested resource was not found.</p></body></html>";
        response.headers["Content-Type"] = "text/html";
        return response;
    }

    private void route_root(HttpRequest request, HttpResponse response) {
        response.statusCode = 200;
        response.body = "<html><body><h1>Welcome to Vibe3D HTTP Server</h1>" ~
                       "<p>Server is running successfully!</p>" ~
                       "<p>Available endpoints:</p>" ~
                       "<ul><li>/status - Get application status</li>" ~
                       "<li>/info - Get application information</li>" ~
                       "<li>/api/version - Version, build configuration, platform and build date (same block `vibe3d --version` prints)</li>" ~
                       "<li>/api/model - Get current model state</li>" ~
                       "<li>/api/command - Execute one command (JSON {\"id\":...\"params\":...} OR argstring \"name arg:val ...\")</li>" ~
                       "<li>/api/script - Execute multi-line script (line-by-line argstring)</li>" ~
                       "<li>tool.set &lt;toolId&gt; [off] [name:val ...] - activate/deactivate a tool</li>" ~
                       "<li>tool.attr &lt;toolId&gt; &lt;name&gt; &lt;value&gt; - set parameter on active tool</li>" ~
                       "<li>tool.doApply - apply active tool one-shot (snapshot-based undo)</li>" ~
                       "<li>tool.reset [&lt;toolId&gt;] - reset active tool's parameters</li>" ~
                       "<li>/api/history/replay - POST {\"index\":N} — re-execute undoStack[N] against current state</li>" ~
                       "<li>/api/trace - GET every discrete command since the last reset (command + args + selection in world positions + a full mesh snapshot); POST /api/trace/reset clears it</li></ul>" ~
                       "</body></html>";
        response.headers["Content-Type"] = "text/html";
    }

    private void route_status(HttpRequest request, HttpResponse response) {
        response.statusCode = 200;
        response.body = "{\"status\": \"running\", \"timestamp\": \"" ~
                       Clock.currTime.toISOExtString() ~ "\"}";
        response.headers["Content-Type"] = "application/json";
    }

    private void route_info(HttpRequest request, HttpResponse response) {
        // The "version": "1.0" this used to hardcode was never any release
        // this program shipped — it was written once and then outlived
        // every version that followed, which is the whole failure mode
        // task 0641 exists to close. It now reads app_version like every
        // other surface.
        response.statusCode = 200;
        response.body = "{\"name\": \"Vibe3D\", \"description\": "
                      ~ "\"A 3D polygon mesh editor written in D\", "
                      ~ "\"version\": \"" ~ appVersion ~ "\"}";
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiPing(HttpRequest request, HttpResponse response) {
        response.statusCode = 200;
        response.body = `{"status": "ok"}`;
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiVersion(HttpRequest request, HttpResponse response) {
        // What this binary is (task 0641). Served straight off the HTTP
        // thread with NO main-thread marshalling: every field is a
        // compile-time constant, so there is no live state to tear.
        //
        // `lines` is `app_version.appAboutLines` verbatim — the same array
        // the About window draws and `--version` prints. That is what makes
        // tests/test_app_version.d able to prove the terminal and the UI
        // read one source instead of two literals that agree today.
        response.statusCode = 200;
        response.body = versionJson();
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiModel(HttpRequest request, HttpResponse response) {
        bool haveProvider = (layerModelProvider !is null)
                         || (detailedModelDataProvider !is null);
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
            modelBridge.req.detailed = (detailedModelDataProvider !is null);
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
                               ~ jsonEsc(modelBridge.resp.error) ~ "\"}";
            }
        }
    }

    private void route_apiSelection(HttpRequest request, HttpResponse response) {
        // Task 0763 — `selectionDataProvider` (http_providers.d) walks
        // `document.layers` with `foreach (l; document.layers)` directly on
        // the HTTP thread, unguarded, while app.d splices that same array in
        // four places (layer.add/delete/reorder/select). This is the EXACT
        // argument task 0612 (Stage 3) used to marshal /api/layers onto the
        // main thread — 0700 §2 already noted /api/layers and /api/selection
        // walk `document.layers` as two independent, unsynchronized
        // providers with no shared source of truth. /api/selection is the
        // single most-called endpoint in the whole HTTP test surface, so
        // marshaling it needs the FULL suite to validate the added
        // submitAndWait() latency doesn't regress timing-sensitive tests —
        // out of scope for this follow-up's narrow lanes. Deferred with the
        // rest of this class to task 0950, not fixed here.
        if (selectionDataProvider !is null) {
            try {
                response.statusCode = 200;
                response.body = selectionDataProvider();
                response.headers["Content-Type"] = "application/json";
            } catch (Exception e) {
                response.statusCode = 500;
                response.body = "{\"error\": \"Failed to retrieve selection data\", \"message\": \"" ~
                               jsonEsc(e.msg) ~ "\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else {
            response.statusCode = 500;
            response.body = "{\"error\": \"Selection data provider not set\"}";
            response.headers["Content-Type"] = "application/json";
        }
    }

    private void route_apiToolHandles(HttpRequest request, HttpResponse response) {
        // Task 0234; marshaled onto the main thread by 0563. The registry
        // this serializes is rebuilt from empty on every interactive draw,
        // so it can be read neither concurrently nor before the draw that
        // builds it — see the toolHandlesBridge declaration for the two
        // failure modes that forced this.
        response.headers["Content-Type"] = "application/json";
        if (toolHandlesDataProvider is null) {
            // Preserve the pre-marshaling null-provider contract exactly:
            // 200 {"handles":null}, decided on the HTTP thread BEFORE ever
            // touching the bridge.
            response.statusCode = 200;
            response.body = `{"handles":null}`;
        } else {
            toolHandlesBridge.resp.result = "";
            toolHandlesBridge.resp.error  = "";
            if (!toolHandlesBridge.submitAndWait())
                toolHandlesBridge.resp.error = "timeout waiting for main thread";
            if (toolHandlesBridge.resp.error.length == 0) {
                response.statusCode = 200;
                response.body = toolHandlesBridge.resp.result;
            } else {
                response.statusCode = 500;
                response.body = "{\"error\": \"Failed to retrieve tool handles\", \"message\": \"" ~
                               jsonEsc(toolHandlesBridge.resp.error) ~ "\"}";
            }
        }
    }

    private void route_apiToolState(HttpRequest request, HttpResponse response) {
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
                               jsonEsc(e.msg) ~ "\"}";
            }
        }
    }

    private void route_apiUiPolicy(HttpRequest request, HttpResponse response) {
        // Task 1520/1521 — what the UI policy did with the last user-origin
        // command line: the guard verdict, whether the prompt was suppressed
        // (`--test`), whether the command refused, and the notice text the
        // user would have been shown.
        //
        // NOT marshaled: `ui/availability.d`'s shape — the main thread writes
        // one whole record under a lock, this reads it back under the same
        // lock. There is no live structure to walk on the wrong thread.
        response.headers["Content-Type"] = "application/json";
        try {
            import ui.discard_guard : uiPolicyJson;
            response.statusCode = 200;
            response.body = uiPolicyJson();
        } catch (Exception e) {
            response.statusCode = 500;
            response.body = "{\"error\":\"" ~ jsonEsc(e.msg) ~ "\"}";
        }
    }

    private void route_apiToolpropsIds(HttpRequest request, HttpResponse response) {
        // Task 0640 — the ImGui id namespace of the last Tool Properties
        // column drawn: one entry per section header and two per row (the
        // widget's id, and a probe of the row's id-stack seed).
        //
        // NOT marshaled, and it does not need to be: the panel publishes a
        // finished column under a lock in one assignment, and this reads it
        // back under the same lock. There is no live structure to walk on
        // the wrong thread — unlike /api/tool/handles, whose registry is
        // rebuilt from empty mid-draw.
        //
        // Empty `items` is the honest answer when the panel has not drawn
        // (hidden by default under --test until `ui.toolProperties show`),
        // when it is collapsed, or in a non-test run where nothing records.
        response.headers["Content-Type"] = "application/json";
        try {
            import property_panel : toolPropsIdsJson;
            response.statusCode = 200;
            response.body = toolPropsIdsJson();
        } catch (Exception e) {
            response.statusCode = 500;
            response.body = "{\"error\": \"Failed to retrieve tool props ids\", \"message\": \"" ~
                           jsonEsc(e.msg) ~ "\"}";
        }
    }

    private void route_apiButtonsAvailability(HttpRequest request, HttpResponse response) {
        // Task 0669 — every button the last complete frame drew, with the
        // `disabled` flag and the reason it was drawn WITH. This is the
        // rendered fact, not a re-computation: a test that asked the
        // availability resolver again would prove the resolver and say
        // nothing about whether the buttons still call it.
        //
        // NOT marshaled, on the same grounds as /api/toolprops/ids right
        // above: the draw publishes a finished frame under a lock in one
        // assignment (buttons AND the hasEditTarget they were drawn
        // against), and this reads it back under the same lock. Nothing
        // live is walked from this thread.
        //
        // Empty `buttons` is the honest answer before the first frame and
        // in a non-`--test` run, where nothing records.
        response.headers["Content-Type"] = "application/json";
        try {
            import ui.availability : buttonAvailabilityJson;
            response.statusCode = 200;
            response.body = buttonAvailabilityJson();
        } catch (Exception e) {
            response.statusCode = 500;
            response.body = "{\"error\": \"Failed to retrieve button availability\", \"message\": \"" ~
                           jsonEsc(e.msg) ~ "\"}";
        }
    }

    private void route_apiStats(HttpRequest request, HttpResponse response) {
        // Task 1100 — every row the last complete frame of the Statistics
        // panel DREW, with the cell text exactly as drawn. This is the
        // rendered fact, not a re-computation: a test that asked the row model
        // again would prove the row model and say nothing about whether the
        // panel drew it — which is the failure `ui/item_rows.d`'s header
        // records this codebase already shipping once.
        //
        // NOT marshaled, on the same grounds as /api/buttons/availability: the
        // draw publishes a finished frame under a lock in one assignment and
        // this reads it back under the same lock. Nothing live is walked from
        // this thread.
        //
        // Empty `rows` is the honest answer before the first frame, in a
        // non-`--test` run, and while the panel is closed.
        //
        // `charset=utf-8` is not decoration and this is the first endpoint that
        // needs it: the payload carries the em-dash placeholder (U+2014), and a
        // client that is told only "application/json" may decode the body as
        // Latin-1 — which is exactly what Phobos' curl does, turning the three
        // bytes of one glyph into three characters. JSON is UTF-8 by
        // specification; saying so is what makes the glyph survive the wire.
        response.headers["Content-Type"] = "application/json; charset=utf-8";
        try {
            import ui.stat_record : statRowsJson;
            response.statusCode = 200;
            response.body = statRowsJson();
        } catch (Exception e) {
            response.statusCode = 500;
            response.body = "{\"error\": \"Failed to retrieve stat rows\", \"message\": \"" ~
                           jsonEsc(e.msg) ~ "\"}";
        }
    }

    private void route_apiLayers(HttpRequest request, HttpResponse response) {
        // Layer list. MARSHALED (task 0612 Stage 3) — it used to be served
        // straight from the HTTP thread on the grounds that "tests are
        // quiescent when probing", which stopped being enough once the
        // response had to resolve a link's target index by walking the
        // same array the main thread splices. See the provider alias.
        response.headers["Content-Type"] = "application/json";
        if (layersDataProvider is null) {
            response.statusCode = 500;
            response.body = "{\"error\": \"Layers data provider not set\"}";
        } else {
            layersBridge.resp.result = "";
            layersBridge.resp.error  = "";
            if (!layersBridge.submitAndWait())
                layersBridge.resp.error = "timeout waiting for main thread";
            if (layersBridge.resp.error.length == 0) {
                response.statusCode = 200;
                response.body = layersBridge.resp.result;
            } else {
                response.statusCode = 500;
                response.body = "{\"error\": \"Failed to retrieve layers\", \"message\": \"" ~
                               jsonEsc(layersBridge.resp.error) ~ "\"}";
            }
        }
    }

    private void route_apiPerfReset(HttpRequest request, HttpResponse response) {
        // Zero all perf counters before a measured run. No-op in the
        // default build (g_perf.reset compiles away).
        //
        // Task 0763 — writes from the HTTP thread into state the main thread
        // concurrently reads/bumps every frame (`g_perf`'s per-category
        // timers). Decision, written rather than implied: tolerable. Worst
        // case is one straddling increment surviving the reset or one fresh
        // sample landing a moment before it — a single-sample wobble in a
        // diagnostic counter a caller is about to overwrite with a whole
        // measured run's worth of data anyway. Marshaling this onto the main
        // thread would add a frame of latency to the reset every perf-lane
        // run pays for before its FIRST measured sample — a worse trade than
        // the wobble it would remove.
        g_perf.reset();
        response.statusCode = 200;
        response.body = "{\"status\":\"ok\"}";
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiPerf(HttpRequest request, HttpResponse response) {
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
                           jsonEsc(e.msg) ~ "\"}";
            response.headers["Content-Type"] = "application/json";
        }
    }

    private void route_apiFramesCountsReset(HttpRequest request, HttpResponse response) {
        // Zero the always-on frame WORK counters. Unlike its two siblings
        // above this is NOT a no-op in the default build — see below.
        //
        // Task 0763 — same HTTP-thread-writes-into-main-thread-state shape as
        // /api/perf/reset and /api/frames/reset (its two siblings), decided
        // the same way and written here rather than left implied:
        // `FrameWorkProbe.reset()` zeroes four fields in sequence, not as one
        // assignment, so a reset landing mid-`endFrame()` could leave a
        // partially-zeroed record for one frame. Tolerable — every caller of
        // this endpoint immediately follows it with the measured run it
        // wants counted, and the always-on counters this drives
        // (`/api/frames/counts`, used by the default `modeling` build's own
        // test lane, not just the perf lane) have no invariant that a
        // one-frame wobble at reset time would violate. Not marshaled for the
        // same reason as its siblings: the round-trip cost lands on every
        // measured run's setup, not just this diagnostic's accuracy.
        g_fc.reset();
        response.statusCode = 200;
        response.body = "{\"status\":\"ok\"}";
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiFramesCounts(HttpRequest request, HttpResponse response) {
        // Per-frame WORK COUNTS: draw submissions and submitted vertices
        // per pass, cells considered/rendered, GPU uploads, pick-cache
        // rebuilds, pipeline + operator evaluations, and main-thread GC
        // bytes. Live in EVERY build configuration, including the default
        // `modeling` one that run_test.d builds — which is the whole
        // reason it exists next to /api/perf and /api/frames, both of
        // which return "{}" there and have done so for every test that
        // ever tried to ask this question.
        //
        // READ `lastScene`, NOT `last`. The N-cell render loop skips cells
        // whose dirty key is unchanged, so an arbitrary frame legitimately
        // draws nothing; `lastScene` is the last frame that rendered at
        // least one cell. (In --test the active cell renders every frame,
        // so the two coincide there — do not let that habit leak into an
        // interactive-mode assertion.)
        //
        // NOT A TIMING ENDPOINT. Nothing here is a duration. See the
        // FrameWorkProbe header in source/perf_probe.d for what these
        // numbers do and do not support.
        //
        // Same no-lock diagnostic-read contract as /api/perf and
        // /api/frames: single main-thread writer, whole-record publish.
        try {
            response.statusCode = 200;
            response.body = g_fc.toJson();
            response.headers["Content-Type"] = "application/json";
        } catch (Exception e) {
            response.statusCode = 500;
            response.body = "{\"error\":\"frame-count probe read failed\",\"message\":\"" ~
                           jsonEsc(e.msg) ~ "\"}";
            response.headers["Content-Type"] = "application/json";
        }
    }

    private void route_apiFramesReset(HttpRequest request, HttpResponse response) {
        // Zero the per-frame ring + counters before a measured run
        // (task 0195). No-op in the default build (g_frames.reset
        // compiles away).
        //
        // Task 0763 — see /api/perf/reset for the decision this shares:
        // tolerable HTTP-thread write into main-thread-owned state, not
        // marshaled because the latency would land on every perf run's
        // setup, not just this diagnostic's accuracy.
        g_frames.reset();
        response.statusCode = 200;
        response.body = "{\"status\":\"ok\"}";
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiFrames(HttpRequest request, HttpResponse response) {
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
                           jsonEsc(e.msg) ~ "\"}";
            response.headers["Content-Type"] = "application/json";
        }
    }

    private void route_apiChanges(HttpRequest request, HttpResponse response) {
        // Change-notification bus debug counters (Stage 1; test-only). Direct
        // read of the process-wide __gshared bus from the HTTP thread — the
        // counters are plain integers updated on the main thread at the
        // per-frame flush, so a diagnostic racy read needs no lock (same
        // contract as /api/perf). Tests read these counters as DELTAS across
        // a step (the runner resets app state, not the bus, between test
        // binaries — see the plan's reset caveat).
        //
        // Task 0763 — this used to read `changeBus.<field>` TWENTY times
        // live, one per key in the format() call. Nothing here asserts two of
        // those fields must agree the way /api/frames/counts's `frames` and
        // `totals.seq` do, so this was never observed producing a response
        // that contradicts ITSELF the way that endpoint did — but it is the
        // same shape of hazard (a flush landing mid-format mixes fields from
        // two different flushes into one JSON object), so it gets the same
        // fix on the same evidence-free-but-structurally-identical grounds:
        // one copy of the whole struct up front (cheap — every field here is
        // a scalar), then serialise from the copy.
        response.headers["Content-Type"] = "application/json";
        if (!testMode) {
            response.statusCode = 403;
            response.body = `{"error":"changes is only available in --test mode"}`;
        } else {
            import change_bus : changeBus;
            import seltype    : selTypeToken;
            import std.format : format;
            const snap = changeBus;
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
                `"missedPublishers":%d,` ~
                `"currentTypeChanged":%d,"lastCurrentType":"%s"}`,
                snap.flushCount, snap.lastFlushFlags,
                snap.lastSelDomains, snap.lastLayerKinds,
                snap.totalPosition, snap.totalPoints,
                snap.totalPolygons, snap.totalMarks,
                snap.totalMaterial,
                snap.totalSelVertex, snap.totalSelEdge,
                snap.totalSelFace,
                snap.totalSelItem,
                snap.totalLayerAdded, snap.totalLayerRemoved,
                snap.totalLayerReordered, snap.totalLayerRenamed,
                snap.totalLayerVisible,
                snap.totalLayerActive,
                snap.missedPublishers,
                snap.currentTypeChanged,
                selTypeToken(snap.lastCurrentType));
        }
    }

    private void route_apiToolpipeEval(HttpRequest request, HttpResponse response) {
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
                               ~ jsonEsc(pipeEvalBridge.resp.error) ~ "\"}";
            }
        }
    }

    private void route_apiPath(HttpRequest request, HttpResponse response) {
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
                               jsonEsc(pathBridge.resp.error) ~ `"}`;
            }
        }
    }

    private void route_apiToolpipe(HttpRequest request, HttpResponse response) {
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
                               ~ jsonEsc(toolpipeBridge.resp.error) ~ "\"}";
            }
        }
    }

    private void route_apiAiAnalyze(HttpRequest request, HttpResponse response) {
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
                               ~ jsonEsc(aiAnalyzeBridge.resp.error) ~ "\"}";
            }
        }
    }

    private void route_apiRegistry(HttpRequest request, HttpResponse response) {
        if (registryProvider !is null) {
            try {
                bool wantParams = parseQueryInt(request.path, "params", 0) != 0;
                response.statusCode = 200;
                response.body = registryProvider(wantParams);
                response.headers["Content-Type"] = "application/json";
            } catch (Exception e) {
                response.statusCode = 500;
                response.body = "{\"error\":\"registry provider failed\",\"message\":\"" ~
                               jsonEsc(e.msg) ~ "\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else {
            response.statusCode = 200;
            response.body = "{\"commands\":[],\"tools\":[]}";
            response.headers["Content-Type"] = "application/json";
        }
    }

    private void route_apiSnapLast(HttpRequest request, HttpResponse response) {
        if (snapLastProvider !is null) {
            try {
                response.statusCode = 200;
                response.body = snapLastProvider();
                response.headers["Content-Type"] = "application/json";
            } catch (Exception e) {
                response.statusCode = 500;
                response.body = "{\"error\":\"snap last provider failed\",\"message\":\"" ~
                               jsonEsc(e.msg) ~ "\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else {
            response.statusCode = 500;
            response.body = "{\"error\":\"snap last provider not set\"}";
            response.headers["Content-Type"] = "application/json";
        }
    }

    private void route_apiSnap(HttpRequest request, HttpResponse response) {
        response.headers["Content-Type"] = "application/json";
        // The null-provider verdict is decided HERE, on the HTTP thread,
        // before the bridge is touched — otherwise an unwired provider
        // would spin out the full submitAndWait timeout and report
        // "timeout" instead of the historical "provider not set".
        if (snapQueryProvider is null) {
            response.statusCode = 500;
            response.body = "{\"error\":\"snap query provider not set\"}";
        } else {
            // Marshal onto the main thread (task 0587). The provider runs
            // pipeline.evaluate() and reads the live mesh; see the
            // snapQueryBridge declaration for why that cannot be served
            // from this thread.
            snapQueryBridge.req.body_   = request.body;
            snapQueryBridge.resp.result = "";
            snapQueryBridge.resp.error  = "";
            if (!snapQueryBridge.submitAndWait())
                snapQueryBridge.resp.error = "timeout waiting for main thread";
            if (snapQueryBridge.resp.error.length == 0) {
                response.statusCode = 200;
                response.body = snapQueryBridge.resp.result;
            } else {
                response.statusCode = 500;
                response.body = "{\"error\":\"snap query failed\",\"message\":\"" ~
                               jsonEsc(snapQueryBridge.resp.error) ~ "\"}";
            }
        }
    }

    private void route_apiConstrain(HttpRequest request, HttpResponse response) {
        response.headers["Content-Type"] = "application/json";
        if (constrainQueryProvider is null) {
            response.statusCode = 500;
            response.body = "{\"error\":\"constrain query provider not set\"}";
        } else {
            // Marshal onto the main thread (task 0587) — same reason as
            // /api/snap above, minus the shared-buffer write.
            constrainQueryBridge.req.body_   = request.body;
            constrainQueryBridge.resp.result = "";
            constrainQueryBridge.resp.error  = "";
            if (!constrainQueryBridge.submitAndWait())
                constrainQueryBridge.resp.error = "timeout waiting for main thread";
            if (constrainQueryBridge.resp.error.length == 0) {
                response.statusCode = 200;
                response.body = constrainQueryBridge.resp.result;
            } else {
                response.statusCode = 500;
                response.body = "{\"error\":\"constrain query failed\",\"message\":\"" ~
                               jsonEsc(constrainQueryBridge.resp.error) ~ "\"}";
            }
        }
    }

    private void route_apiCameraPost(HttpRequest request, HttpResponse response) {
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
                                    ~ jsonEsc(cameraSetBridge.resp.error) ~ `"}`;
                }
            } catch (Exception e) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"`
                                ~ jsonEsc(e.msg) ~ `"}`;
            }
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiGpuFaceVbo(HttpRequest request, HttpResponse response) {
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
                                ~ jsonEsc(gpuSurfaceBridge.resp.error) ~ `"}`;
            }
            response.headers["Content-Type"] = "application/json";
        }
    }

    private void route_apiViewportDisplay(HttpRequest request, HttpResponse response) {
        // Task 0559 — dump every cell's display state + resolved draw
        // plans. Ordered BEFORE /api/viewport/probe is irrelevant (the
        // paths differ past the prefix), but both must sit before any
        // future bare "/api/viewport" prefix match.
        if (viewportDisplayProvider is null) {
            response.statusCode = 500;
            response.body = `{"error":"viewport-display provider not set"}`;
        } else {
            vpDisplayBridge.resp.result = "";
            vpDisplayBridge.resp.error  = "";
            if (!vpDisplayBridge.submitAndWait())
                vpDisplayBridge.resp.error = "timeout waiting for main thread";
            if (vpDisplayBridge.resp.error.length == 0) {
                response.statusCode = 200;
                response.body = vpDisplayBridge.resp.result;
            } else {
                response.statusCode = 500;
                response.body = `{"error":"`
                                ~ jsonEsc(vpDisplayBridge.resp.error) ~ `"}`;
            }
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiImages(HttpRequest request, HttpResponse response) {
        // Task 0612 Stage 1 — the image-clip rows and the pixel cache's
        // residency counters, gathered in one main-thread pass.
        if (imagesDataProvider is null) {
            response.statusCode = 500;
            response.body = `{"error":"images data provider not set"}`;
        } else {
            imagesBridge.resp.result = "";
            imagesBridge.resp.error  = "";
            if (!imagesBridge.submitAndWait())
                imagesBridge.resp.error = "timeout waiting for main thread";
            if (imagesBridge.resp.error.length == 0) {
                response.statusCode = 200;
                response.body = imagesBridge.resp.result;
            } else {
                response.statusCode = 500;
                response.body = `{"error":"`
                                ~ jsonEsc(imagesBridge.resp.error) ~ `"}`;
            }
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiImageplane(HttpRequest request, HttpResponse response) {
        // Task 0612 Stage 4 — one plane's resolved placement in one cell.
        // (No prefix collision with `/api/images` above: the two paths
        // differ at the tenth character, `p` vs `s`.)
        if (imagePlaneProvider is null) {
            response.statusCode = 500;
            response.body = `{"error":"image-plane provider not set"}`;
        } else {
            planeBridge.req.index  = parseQueryInt(request.path, "index", -1);
            planeBridge.req.cell   = parseQueryInt(request.path, "cell",  -1);
            planeBridge.resp.result = "";
            planeBridge.resp.error  = "";
            if (!planeBridge.submitAndWait())
                planeBridge.resp.error = "timeout waiting for main thread";
            if (planeBridge.resp.error.length == 0) {
                response.statusCode = 200;
                response.body = planeBridge.resp.result;
            } else {
                response.statusCode = 500;
                response.body = `{"error":"`
                                ~ jsonEsc(planeBridge.resp.error) ~ `"}`;
            }
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiViewportProbe(HttpRequest request, HttpResponse response) {
        // Task 0559 — FBO pixel readback. `points` is "x,y;x,y;..." in
        // TOP-LEFT-origin FBO pixels; `x`/`y` is sugar for a single
        // point. `hash=1` additionally digests the WHOLE colour buffer,
        // which is what makes "these two builds draw identical pixels" a
        // checkable claim rather than an assertion.
        if (viewportProbeProvider is null) {
            response.statusCode = 500;
            response.body = `{"error":"viewport-probe provider not set"}`;
        } else {
            vpProbeBridge.req.cell   = parseQueryInt(request.path, "cell", -1);
            string _pts = parseQueryString(request.path, "points", "");
            if (_pts.length == 0) {
                immutable int _px = parseQueryInt(request.path, "x", -1);
                immutable int _py = parseQueryInt(request.path, "y", -1);
                if (_px >= 0 && _py >= 0) {
                    import std.conv : to;
                    _pts = _px.to!string ~ "," ~ _py.to!string;
                }
            }
            vpProbeBridge.req.points   = _pts;
            vpProbeBridge.req.wantHash = parseQueryInt(request.path, "hash", 0) != 0;
            vpProbeBridge.resp.result  = "";
            vpProbeBridge.resp.error   = "";
            if (!vpProbeBridge.submitAndWait())
                vpProbeBridge.resp.error = "timeout waiting for main thread";
            if (vpProbeBridge.resp.error.length == 0) {
                response.statusCode = 200;
                response.body = vpProbeBridge.resp.result;
            } else {
                response.statusCode = 500;
                response.body = `{"error":"`
                                ~ jsonEsc(vpProbeBridge.resp.error) ~ `"}`;
            }
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiSubpatchPreview(HttpRequest request, HttpResponse response) {
        response.headers["Content-Type"] = "application/json";
        if (subpatchStateProvider is null) {
            response.statusCode = 500;
            response.body = `{"error":"subpatch-state provider not set"}`;
            return;
        }
        subpatchStateBridge.resp.result = "";
        subpatchStateBridge.resp.error  = "";
        if (!subpatchStateBridge.submitAndWait())
            subpatchStateBridge.resp.error = "timeout waiting for main thread";
        if (subpatchStateBridge.resp.error.length == 0) {
            response.statusCode = 200;
            response.body = subpatchStateBridge.resp.result;
        } else {
            response.statusCode = 500;
            response.body = `{"error":"`
                            ~ jsonEsc(subpatchStateBridge.resp.error) ~ `"}`;
        }
    }

    private void route_apiSubpatchHold(HttpRequest request, HttpResponse response) {
        response.headers["Content-Type"] = "application/json";
        // Test-only. The knob delays RECEPTION of a finished build, which is
        // the only way a test can hold the async window open long enough to
        // observe it — a real 4-second build needs a cage the suite has no
        // business carrying.
        if (!testMode) {
            response.statusCode = 403;
            response.body = `{"error":"subpatch hold is --test only"}`;
            return;
        }
        if (subpatchHoldHandler is null) {
            response.statusCode = 500;
            response.body = `{"error":"subpatch-hold handler not set"}`;
            return;
        }
        long ms = 0, ceilingMs = 0;
        try {
            import std.json : parseJSON, JSONType;
            auto j = parseJSON(request.body.length ? request.body : "{}");
            if (j.type == JSONType.object) {
                if (auto p = "ms"        in j) ms        = (*p).integer;
                if (auto p = "ceilingMs" in j) ceilingMs = (*p).integer;
            }
        } catch (Exception e) {
            response.statusCode = 400;
            response.body = `{"error":"` ~ jsonEsc(e.msg) ~ `"}`;
            return;
        }
        subpatchHoldBridge.req.ms        = ms;
        subpatchHoldBridge.req.ceilingMs = ceilingMs;
        subpatchHoldBridge.resp.result = "";
        subpatchHoldBridge.resp.error  = "";
        if (!subpatchHoldBridge.submitAndWait())
            subpatchHoldBridge.resp.error = "timeout waiting for main thread";
        if (subpatchHoldBridge.resp.error.length == 0) {
            response.statusCode = 200;
            response.body = subpatchHoldBridge.resp.result;
        } else {
            response.statusCode = 500;
            response.body = `{"error":"`
                            ~ jsonEsc(subpatchHoldBridge.resp.error) ~ `"}`;
        }
    }

    private void route_apiPick(HttpRequest request, HttpResponse response) {
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
                response.body = `{"error":"` ~ jsonEsc(pickBridge.resp.error) ~ `"}`;
            }
            response.headers["Content-Type"] = "application/json";
        }
    }

    private void route_apiSurfaceRaycast(HttpRequest request, HttpResponse response) {
        if (surfaceRaycastProvider is null) {
            response.statusCode = 500;
            response.body = `{"error":"surface-raycast provider not set"}`;
            response.headers["Content-Type"] = "application/json";
        } else {
            surfaceRaycastBridge.req.x = parseQueryInt(request.path, "x", 0);
            surfaceRaycastBridge.req.y = parseQueryInt(request.path, "y", 0);
            surfaceRaycastBridge.req.thresholdPx =
                parseQueryFloat(request.path, "thresholdPx", -1.0f);
            surfaceRaycastBridge.resp.result = "";
            surfaceRaycastBridge.resp.error  = "";
            if (!surfaceRaycastBridge.submitAndWait())
                surfaceRaycastBridge.resp.error = "timeout waiting for main thread";
            if (surfaceRaycastBridge.resp.error.length == 0) {
                response.statusCode = 200;
                response.body = surfaceRaycastBridge.resp.result;
            } else {
                response.statusCode = 500;
                response.body = `{"error":"` ~ jsonEsc(surfaceRaycastBridge.resp.error) ~ `"}`;
            }
            response.headers["Content-Type"] = "application/json";
        }
    }

    private void route_apiCameraGet(HttpRequest request, HttpResponse response) {
        if (cameraDataProvider !is null) {
            try {
                int _vpIdx = parseQueryInt(request.path, "viewport", -1);
                response.statusCode = 200;
                response.body = cameraDataProvider(_vpIdx);
                response.headers["Content-Type"] = "application/json";
            } catch (Exception e) {
                response.statusCode = 500;
                response.body = "{\"error\": \"Failed to retrieve camera data\", \"message\": \"" ~
                               jsonEsc(e.msg) ~ "\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else {
            response.statusCode = 500;
            response.body = "{\"error\": \"Camera data provider not set\"}";
            response.headers["Content-Type"] = "application/json";
        }
    }

    private void route_apiRecordedEvents(HttpRequest request, HttpResponse response) {
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
    }

    private void route_apiReset(HttpRequest request, HttpResponse response) {
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
    }

    private void route_apiPlayEventsStatus(HttpRequest request, HttpResponse response) {
        // Task 0763 — same defect shape FrameWorkProbe.toJson documents and
        // tools/local/frame_counts_seq_race.sh measured for /api/frames/counts
        // (89 self-contradictory responses / 40 000): this ran on the HTTP
        // thread and read `eventPlayer.active`, `.entries.length` and `.idx`
        // as THREE separate live reads, while the main thread's
        // `tickEventPlayer()` mutates all three every frame. A commit landing
        // between the reads did not just go stale by one — `remaining` is a
        // size_t subtraction, so a length/idx pair from two different frames
        // could underflow to a huge number instead of being off by one.
        //
        // Fix mirrors FrameWorkProbe.toJson exactly: one copy of each field up
        // front, then derive the whole body from the copies. This does not
        // make the read atomic (no lock here, same as /api/frames/counts) —
        // it makes the RESPONSE internally consistent with itself, which is
        // the actual property `finished`/`total`/`remaining` need to hold.
        import std.format : format;
        const bool   active  = eventPlayer.active;
        const size_t total   = eventPlayer.entries.length;
        const size_t idx     = eventPlayer.idx;
        const bool   done    = !active;
        response.statusCode = 200;
        response.body = format(`{"finished":%s,"total":%d,"remaining":%d}`,
            done ? "true" : "false",
            total,
            done ? 0 : total - idx);
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiTransform(HttpRequest request, HttpResponse response) {
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
                                    ~ jsonEsc(transformBridge.resp.error) ~ `"}`;
                }
            } catch (Exception e) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"`
                                ~ jsonEsc(e.msg) ~ `"}`;
            }
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiLoadMesh(HttpRequest request, HttpResponse response) {
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
                                    ~ jsonEsc(loadMeshBridge.resp.error) ~ `"}`;
                }
            } catch (Exception e) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"`
                                ~ jsonEsc(e.msg) ~ `"}`;
            }
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiTestLayer(HttpRequest request, HttpResponse response) {
        // Test-only layer injection (task 0615 Stage 6/7) — see the
        // `injectLayerHandler` field doc comment above for the full
        // rationale. Blocker (review round 2): unlike every sibling
        // test-only endpoint (`/api/changes`, `/api/play-events` above),
        // this route had NO test-mode gate — a release binary always
        // constructs the HttpServer and always wires this handler
        // (http_providers.d), and even `--http-port` without `--test`
        // turns the listener on without turning test mode on (app.d).
        // Gated here exactly like its siblings: 403 outside `--test`.
        if (!testMode) {
            response.statusCode = 403;
            response.body = `{"error":"test/layer is only available in --test mode"}`;
            response.headers["Content-Type"] = "application/json";
        } else if (injectLayerHandler is null) {
            response.statusCode = 200;
            response.body = `{"status":"error","message":"inject-layer handler not set"}`;
        } else {
            try {
                auto j = parseJSON(request.body);
                if (j.type != JSONType.object)
                    throw new Exception("body must be a JSON object");
                injectLayerBridge.req.params = j;
                injectLayerBridge.resp.error = "";
                if (!injectLayerBridge.submitAndWait())
                    injectLayerBridge.resp.error = "timeout waiting for main thread";
                if (injectLayerBridge.resp.error.length == 0) {
                    response.statusCode = 200;
                    response.body = `{"status":"ok"}`;
                } else {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                    ~ jsonEsc(injectLayerBridge.resp.error) ~ `"}`;
                }
            } catch (Exception e) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"`
                                ~ jsonEsc(e.msg) ~ `"}`;
            }
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiSelect(HttpRequest request, HttpResponse response) {
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
                                    ~ jsonEsc(selectionBridge.resp.error) ~ `"}`;
                }
            } catch (Exception e) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"`
                                ~ jsonEsc(e.msg) ~ `"}`;
            }
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiCommand(HttpRequest request, HttpResponse response) {
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
                // `?origin=ui` — TEST ONLY (same 403 shape as
                // /api/play-events). It routes the line through the UI policy
                // adapter, which is the only headless way to drive what a
                // panel button does. Precedent: `?interactive=true` on
                // /api/script.
                immutable bool wantUi =
                    (parseQueryString(request.path, "origin", "") == "ui");
                if (wantUi && !testMode) {
                    response.statusCode = 403;
                    response.body =
                        `{"status":"error","message":"origin=ui is only available in --test mode"}`;
                    response.headers["Content-Type"] = "application/json";
                    return;
                }
                commandBridge.req.uiOrigin = wantUi;
                if (!commandBridge.submitAndWait(kCommandBridgeMaxIters))
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
                                    ~ jsonEsc(commandBridge.resp.error) ~ `"}`;
                }
            } catch (Exception e) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"`
                                ~ jsonEsc(e.msg) ~ `"}`;
            }
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiScript(HttpRequest request, HttpResponse response) {
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

                    if (!commandBridge.submitAndWait(kCommandBridgeMaxIters))
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
                              jsonEsc(r.command),
                              r.ok ? "ok" : "error"));
                if (!r.ok && r.message.length > 0) {
                    sb.put(`,"message":"`);
                    sb.put(jsonEsc(r.message));
                    sb.put('"');
                }
                sb.put('}');
            }
            sb.put("]}");

            response.statusCode = 200;
            response.body = sb.data;
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiUndoRedo(HttpRequest request, HttpResponse response) {
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
    }

    private void route_apiRefire(HttpRequest request, HttpResponse response) {
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
                                    ~ jsonEsc(refireBridge.resp.error) ~ `"}`;
                }
            } catch (Exception e) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"`
                                ~ jsonEsc(e.msg) ~ `"}`;
            }
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiHistoryBlock(HttpRequest request, HttpResponse response) {
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
                                    ~ jsonEsc(blockBridge.resp.error) ~ `"}`;
                }
            } catch (Exception e) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"`
                                ~ jsonEsc(e.msg) ~ `"}`;
            }
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiUndoStatus(HttpRequest request, HttpResponse response) {
        // Read-only undo-service status: {state, lockout, canUndo, canRedo}.
        // Snapshot at request time on the HTTP thread (same safety contract
        // as /api/history GET — read-only access to the history service).
        //
        // Task 0763 — CHECKED, not benign by default: `CommandHistory`
        // (command_history.d) has no Mutex and no lock-free publish
        // discipline. `undoStatusProvider` (http_providers.d) makes FIVE
        // separate calls into it (`state()`, `lockedOut()`, `canUndo()`,
        // `canRedo()`, `undoDepthCounts()`), and the main thread pushes/pops
        // `undoStack`/`redoStack` on every command. Same hazard CLASS as
        // `document.layers` before task 0612 marshaled /api/layers — real,
        // not fixed here. Deferred rather than marshaled in this pass:
        // unlike /api/frames/counts (measured, isolated, one call site),
        // /api/selection and /api/history share the same unguarded
        // `history`/`document.layers` state and are two of the most-hit
        // endpoints in the whole test suite; marshaling one without the
        // others leaves the same object read from both threads by a
        // different door, and validating the change needs the FULL suite,
        // not the narrow lanes this follow-up ran. See task 0950
        // (doc/tasks/backlog/0950-*) for the grouped fix.
        if (undoStatusProvider is null) {
            response.statusCode = 200;
            response.body = `{"state":"invalid","lockout":false,`
                          ~ `"canUndo":false,"canRedo":false}`;
        } else {
            response.statusCode = 200;
            response.body = undoStatusProvider();
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiHistory(HttpRequest request, HttpResponse response) {
        // Task 0763 — see route_apiUndoStatus above: `historyProvider` walks
        // `history.undoEntriesVisible()` and `.redoEntriesVisible()`, two
        // separate reads of the same unguarded `CommandHistory` the main
        // thread mutates on every command. Same hazard, same deferral (task
        // 0950); not fixed here.
        if (historyProvider is null) {
            response.statusCode = 200;
            response.body = `{"undo":[],"redo":[]}`;
        } else {
            response.statusCode = 200;
            response.body = historyProvider();
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiTrace(HttpRequest request, HttpResponse response) {
        // Non-destructive per-step capture (task: step-trace). Returns
        // every discrete command recorded since the last reset — see
        // StepTrace / app.d's captureStepTrace for the entry shape.
        //
        // Task 0763 — one of 0611's two named HTTP-thread writers is this
        // route's sibling below (POST /api/trace/reset), racing against the
        // main thread's per-command append. CHECKED, not assumed: StepTrace
        // (source/step_trace.d) holds a real `core.sync.mutex.Mutex` and
        // append()/reset()/arm()/snapshotJson() all take it — this provider
        // (`traceProvider` → `stepTrace.snapshotJson()`) is already correctly
        // synchronized against the main thread's append(). No fix needed
        // here; recorded so this pair does not get re-flagged as an open
        // candidate by the next audit that only reads the route table.
        response.statusCode = 200;
        response.body = (traceProvider !is null) ? traceProvider() : "[]";
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiTraceReset(HttpRequest request, HttpResponse response) {
        // Task 0763 — see route_apiTrace above: this writer
        // (`traceResetHandler` → `stepTrace.arm()`) takes the same
        // StepTrace mutex as every other StepTrace access, so it is already
        // safe against the main thread's concurrent append(). Not a live
        // candidate.
        if (traceResetHandler !is null) traceResetHandler();
        response.statusCode = 200;
        response.body = `{"status":"ok"}`;
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiHistoryJump(HttpRequest request, HttpResponse response) {
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
                              ~ jsonEsc(e.msg) ~ `"}`;
            }
        }
        response.headers["Content-Type"] = "application/json";
    }

    private void route_apiHistoryReplay(HttpRequest request, HttpResponse response) {
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
                    if (!commandBridge.submitAndWait(kCommandBridgeMaxIters))
                        commandBridge.resp.error = "timeout waiting for main thread";
                    if (commandBridge.resp.error.length == 0) {
                        response.statusCode = 200;
                        response.body = `{"status":"ok","line":"`
                                      ~ jsonEsc(line)
                                      ~ `"}`;
                    } else {
                        response.statusCode = 200;
                        response.body = `{"status":"error","message":"`
                                      ~ jsonEsc(commandBridge.resp.error)
                                      ~ `"}`;
                    }
                }
            } catch (Exception e) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"`
                              ~ jsonEsc(e.msg) ~ `"}`;
            }
            response.headers["Content-Type"] = "application/json";
        }
    }

    private void route_apiPlayEvents(HttpRequest request, HttpResponse response) {
        // Task 0763 — the second of 0611's two named HTTP-thread writers.
        // `eventPlayer.load()` mutates `entries` in place
        // (`entries.length = 0` then repeated `~=`) directly on the HTTP
        // thread, unsynchronized, while the main thread's `tickEventPlayer()`
        // reads `entries[idx]` every frame. Unlike a scalar counter this is
        // a dynamic array: a torn read of the slice header (ptr+length) is
        // possible, not just a stale value, which is a sharper hazard than
        // /api/play-events/status's field-level race above.
        //
        // Not fixed here: the two callers never legitimately race in
        // practice — every test/tool driving this endpoint POSTs, then polls
        // /api/play-events/status for `finished:true` before POSTing again
        // (the documented protocol), so tick() only ever sees an `entries`
        // this call finished writing before the FIRST status poll returns.
        // The hazard is real if a caller violates that protocol (loads a new
        // log while a previous one is still ticking); grep of tests/ and
        // tools/ found no caller that does. Recorded rather than fixed
        // because the correct fix (marshal onto the main thread, like
        // /api/reset) changes this route's Answered column from httpThread
        // to mainThread — a route-table + wire-timing change needing the
        // full suite, not this follow-up's narrow lanes. Grouped with
        // /api/selection and /api/history under task 0950.
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
     * Every provider/handler slot this server owns that nothing has filled in.
     *
     * Task 0720 (audit №4, D5). `wireHttpProviders` installs 42 delegates in
     * one 2872-line function; a domain that stops being wired — a whole group
     * dropped by a bad merge, a `setXxxProvider` call lost while splitting the
     * function — used to be invisible until some test asked the endpoint and
     * got `{"error":"... provider not set"}`. There is no compile-time check
     * available for it (a delegate field is null-by-default and assigning it
     * is a runtime act), so this is the audit's other standing remedy: a
     * STARTUP THROW, driven by an enumeration the compiler produces rather
     * than a list a human maintains.
     *
     * `this.tupleof` is what makes it generic: it walks the FIELDS, so a new
     * `fooProvider` is covered the moment it is declared. (`allMembers` would
     * also have matched the `setFooProvider` METHODS, which are never null.)
     *
     * The inventory that produced this found one slot with no caller at all:
     * `setModelDataProvider`, whose arm of `/api/model`'s provider election
     * had been unreachable for as long as the layer-aware provider has
     * existed. That arm, its field, its setter and its serialiser are gone —
     * had they stayed, this check would have had to carry an exception list,
     * which is the very thing it exists to avoid.
     */
    public string[] unwiredEndpoints() {
        string[] missing;
        foreach (i, ref slot; this.tupleof) {
            enum n = __traits(identifier, HttpServer.tupleof[i]);
            static if ((n.length > 8 && n[$ - 8 .. $] == "Provider")
                    || (n.length > 7 && n[$ - 7 .. $] == "Handler")) {
                if (slot is null) missing ~= n;
            }
        }
        return missing;
    }

    /**
     * Check if the server is currently running
     */
    public bool running() const {
        return atomicLoad(isRunning);
    }

    /**
     * Get the port the server is running on
     */
    public ushort getPort() const {
        return port;
    }
}


// ===========================================================================
// The route table (task 0720, audit №4 D5).
//
// `handleRequest` used to be a 1354-line chain of 53 `else if`s, and the
// ORDER of that chain was load-bearing without ever saying so: a
// `startsWith` branch swallows every later path that begins with the same
// text, and the file guarded that by hand, in three separate comments, each
// reasoning about a neighbour it happened to remember. The table below is the
// single registration point, and the `static assert`s under it are the part
// that earns the change — they turn three classes of routing mistake from
// "silently unreachable code" into "does not build":
//
//   1. TWO ROUTES WITH THE SAME (method, path, match). Before: the second
//      `else if` was dead and nothing said so.
//   2. A ROUTE SWALLOWED BY AN EARLIER PREFIX. Before: the only guard was a
//      comment. `/api/images` sits three rows above `/api/imageplane` today
//      and is safe purely because the tenth character differs; add
//      `/api/images/counts` under it and the old chain would have answered
//      it from the `/api/images` handler with no diagnostic at all.
//   3. A HANDLER THAT NO ROUTE REACHES, or a route naming a handler that
//      does not exist. Both are structural integrity of THIS mechanism
//      rather than a pre-existing defect — before the split a handler body
//      could not exist apart from its condition — but they are what keeps
//      the table from drifting away from the methods it names.
//
// What the table does NOT check, said plainly so nobody reads more into it:
// the `Answered` column is DATA, not an assertion. The compiler cannot see
// whether a handler's body reaches a bridge, so a row that says `mainThread`
// is a claim by the author, exactly as the prose it replaces was. Its value
// is that task 0611's question ("which endpoints answer off the main
// thread?") now has an answer that is complete by construction — one row per
// route — instead of one that has to be re-derived by reading 1354 lines.
// ===========================================================================
enum Match : ubyte {
    exact,   // request.path == path
    prefix,  // request.path.startsWith(path) — swallows everything below it
}

// Where the bytes of the answer are produced. See task 0611 and the
// three-clause rule in the provider-field comments above: a provider may READ
// resident plain data from the HTTP thread; the moment it needs `new`, a
// factory, a per-frame structure, or a write to shared state, it belongs on a
// bridge.
enum Answered : ubyte {
    httpThread,  // built straight on the HTTP thread
    mainThread,  // marshaled through a MainThreadBridge
}

struct RouteSpec {
    string   path;
    string   method;    // "" = any method (five routes genuinely mean this)
    Match    match;
    Answered answered;
    string   handler;   // name of the HttpServer member that answers it
}

private enum RouteSpec[] kRoutes = [
    RouteSpec("/",                         "",     Match.exact,  Answered.httpThread, "route_root"),
    RouteSpec("/status",                   "",     Match.exact,  Answered.httpThread, "route_status"),
    RouteSpec("/info",                     "",     Match.exact,  Answered.httpThread, "route_info"),
    RouteSpec("/api/ping",                 "GET",  Match.exact,  Answered.httpThread, "route_apiPing"),
    RouteSpec("/api/version",              "GET",  Match.exact,  Answered.httpThread, "route_apiVersion"),
    RouteSpec("/api/model",                "",     Match.prefix, Answered.mainThread, "route_apiModel"),
    RouteSpec("/api/selection",            "",     Match.exact,  Answered.httpThread, "route_apiSelection"),
    RouteSpec("/api/tool/handles",         "GET",  Match.exact,  Answered.mainThread, "route_apiToolHandles"),
    RouteSpec("/api/tool/state",           "GET",  Match.exact,  Answered.httpThread, "route_apiToolState"),
    RouteSpec("/api/toolprops/ids",        "GET",  Match.exact,  Answered.httpThread, "route_apiToolpropsIds"),
    RouteSpec("/api/ui/policy",            "GET",  Match.exact,  Answered.httpThread, "route_apiUiPolicy"),
    RouteSpec("/api/buttons/availability", "GET",  Match.exact,  Answered.httpThread, "route_apiButtonsAvailability"),
    RouteSpec("/api/stats",                "GET",  Match.exact,  Answered.httpThread, "route_apiStats"),
    RouteSpec("/api/layers",               "GET",  Match.exact,  Answered.mainThread, "route_apiLayers"),
    RouteSpec("/api/perf/reset",           "POST", Match.exact,  Answered.httpThread, "route_apiPerfReset"),
    RouteSpec("/api/perf",                 "GET",  Match.exact,  Answered.httpThread, "route_apiPerf"),
    RouteSpec("/api/frames/counts/reset",  "POST", Match.exact,  Answered.httpThread, "route_apiFramesCountsReset"),
    RouteSpec("/api/frames/counts",        "GET",  Match.exact,  Answered.httpThread, "route_apiFramesCounts"),
    RouteSpec("/api/frames/reset",         "POST", Match.exact,  Answered.httpThread, "route_apiFramesReset"),
    RouteSpec("/api/frames",               "GET",  Match.exact,  Answered.httpThread, "route_apiFrames"),
    RouteSpec("/api/changes",              "GET",  Match.exact,  Answered.httpThread, "route_apiChanges"),
    RouteSpec("/api/toolpipe/eval",        "",     Match.exact,  Answered.mainThread, "route_apiToolpipeEval"),
    RouteSpec("/api/path",                 "",     Match.prefix, Answered.mainThread, "route_apiPath"),
    RouteSpec("/api/toolpipe",             "",     Match.exact,  Answered.mainThread, "route_apiToolpipe"),
    RouteSpec("/api/ai/analyze",           "GET",  Match.exact,  Answered.mainThread, "route_apiAiAnalyze"),
    RouteSpec("/api/registry",             "GET",  Match.prefix, Answered.httpThread, "route_apiRegistry"),
    RouteSpec("/api/snap/last",            "GET",  Match.exact,  Answered.httpThread, "route_apiSnapLast"),
    RouteSpec("/api/snap",                 "POST", Match.exact,  Answered.mainThread, "route_apiSnap"),
    RouteSpec("/api/constrain",            "POST", Match.exact,  Answered.mainThread, "route_apiConstrain"),
    RouteSpec("/api/camera",               "POST", Match.prefix, Answered.mainThread, "route_apiCameraPost"),
    RouteSpec("/api/gpu/face-vbo",         "GET",  Match.exact,  Answered.mainThread, "route_apiGpuFaceVbo"),
    RouteSpec("/api/viewport/display",     "GET",  Match.prefix, Answered.mainThread, "route_apiViewportDisplay"),
    RouteSpec("/api/images",               "GET",  Match.prefix, Answered.mainThread, "route_apiImages"),
    RouteSpec("/api/imageplane",           "GET",  Match.prefix, Answered.mainThread, "route_apiImageplane"),
    RouteSpec("/api/viewport/probe",       "GET",  Match.prefix, Answered.mainThread, "route_apiViewportProbe"),
    RouteSpec("/api/subpatch/preview",     "GET",  Match.exact,  Answered.mainThread, "route_apiSubpatchPreview"),
    RouteSpec("/api/subpatch/hold",        "POST", Match.exact,  Answered.mainThread, "route_apiSubpatchHold"),
    RouteSpec("/api/pick",                 "GET",  Match.prefix, Answered.mainThread, "route_apiPick"),
    RouteSpec("/api/surface-raycast",      "GET",  Match.prefix, Answered.mainThread, "route_apiSurfaceRaycast"),
    RouteSpec("/api/camera",               "GET",  Match.prefix, Answered.httpThread, "route_apiCameraGet"),
    RouteSpec("/api/recorded-events",      "GET",  Match.exact,  Answered.httpThread, "route_apiRecordedEvents"),
    RouteSpec("/api/reset",                "POST", Match.prefix, Answered.mainThread, "route_apiReset"),
    RouteSpec("/api/play-events/status",   "GET",  Match.exact,  Answered.httpThread, "route_apiPlayEventsStatus"),
    RouteSpec("/api/transform",            "POST", Match.exact,  Answered.mainThread, "route_apiTransform"),
    RouteSpec("/api/load-mesh",            "POST", Match.exact,  Answered.mainThread, "route_apiLoadMesh"),
    RouteSpec("/api/test/layer",           "POST", Match.exact,  Answered.mainThread, "route_apiTestLayer"),
    RouteSpec("/api/select",               "POST", Match.exact,  Answered.mainThread, "route_apiSelect"),
    // Match.prefix (task 1520): `?origin=ui` puts a query string on the path,
    // and Match.exact compares the whole path — the query would never match.
    // No other route is a prefix of this one.
    RouteSpec("/api/command",              "POST", Match.prefix, Answered.mainThread, "route_apiCommand"),
    RouteSpec("/api/script",               "POST", Match.prefix, Answered.mainThread, "route_apiScript"),
    RouteSpec("/api/undo",                 "POST", Match.exact,  Answered.mainThread, "route_apiUndoRedo"),
    RouteSpec("/api/redo",                 "POST", Match.exact,  Answered.mainThread, "route_apiUndoRedo"),
    RouteSpec("/api/refire",               "POST", Match.exact,  Answered.mainThread, "route_apiRefire"),
    RouteSpec("/api/history/block",        "POST", Match.exact,  Answered.mainThread, "route_apiHistoryBlock"),
    RouteSpec("/api/undo/status",          "GET",  Match.exact,  Answered.httpThread, "route_apiUndoStatus"),
    RouteSpec("/api/history",              "GET",  Match.exact,  Answered.httpThread, "route_apiHistory"),
    RouteSpec("/api/trace",                "GET",  Match.exact,  Answered.httpThread, "route_apiTrace"),
    RouteSpec("/api/trace/reset",          "POST", Match.exact,  Answered.httpThread, "route_apiTraceReset"),
    RouteSpec("/api/history/jump",         "POST", Match.exact,  Answered.mainThread, "route_apiHistoryJump"),
    RouteSpec("/api/history/replay",       "POST", Match.exact,  Answered.mainThread, "route_apiHistoryReplay"),
    RouteSpec("/api/play-events",          "POST", Match.exact,  Answered.httpThread, "route_apiPlayEvents"),
];

// ---------------------------------------------------------------------------
// The compile-time checks over kRoutes. Written as a CTFE function returning
// the PROBLEM (null = clean) rather than a bare bool, so the build error names
// the offending pair instead of pointing at the assert.
// ---------------------------------------------------------------------------
private bool methodsOverlap(string a, string b) {
    return a.length == 0 || b.length == 0 || a == b;
}

private string routeTableProblem(const RouteSpec[] rs) {
    foreach (i, a; rs) {
        if (a.method.length != 0 && a.method != "GET" && a.method != "POST")
            return "route " ~ a.path ~ ": method must be GET, POST, or \"\" (any)";
        foreach (b; rs[i + 1 .. $]) {
            if (!methodsOverlap(a.method, b.method)) continue;
            if (a.path == b.path && a.match == b.match)
                return "duplicate route: " ~ (a.method.length ? a.method : "ANY")
                     ~ " " ~ a.path ~ " is registered twice";
            if (a.match == Match.prefix && b.path.length >= a.path.length
                && b.path[0 .. a.path.length] == a.path)
                return "unreachable route: " ~ (b.method.length ? b.method : "ANY")
                     ~ " " ~ b.path ~ " can never be reached — the earlier prefix "
                     ~ "route " ~ a.path ~ " swallows it";
        }
    }
    return null;
}

static assert(routeTableProblem(kRoutes) is null, routeTableProblem(kRoutes));

// Every route names a member that exists, and every `route_` member is
// reachable from at least one route. This has to live at module scope:
// `__traits(allMembers, HttpServer)` cannot be asked about a type that is
// still being defined.
private string routeHandlerProblem() {
    foreach (r; kRoutes) {
        bool exists = false;
        static foreach (m; __traits(allMembers, HttpServer))
            if (m == r.handler) exists = true;
        if (!exists)
            return "route " ~ r.path ~ " names handler " ~ r.handler
                 ~ ", which HttpServer does not have";
    }
    static foreach (m; __traits(allMembers, HttpServer)) {{
        static if (m.length > 6 && m[0 .. 6] == "route_") {
            bool routed = false;
            foreach (r; kRoutes) if (r.handler == m) routed = true;
            if (!routed)
                return "handler " ~ m ~ " is in no route — it can never run";
        }
    }}
    return null;
}

static assert(routeHandlerProblem() is null, routeHandlerProblem());


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

// ---------------------------------------------------------------------------
// Task 0615 Stage 6/7 review round 2, BLOCKER 1: `/api/test/layer` must be
// gated on `testMode` exactly like its sibling test-only endpoints
// (`/api/changes`, `/api/play-events`) — a release binary always
// constructs the HttpServer and always wires the injector handler
// (http_providers.d), and even `--http-port` without `--test` turns the
// listener on without turning test mode on (app.d). Without the gate, a
// plain `dub build && ./vibe3d` (or a release binary re-opened with
// `--http-port`) would accept a POST that splices an un-undoable,
// unsaveable layer into a real user's document.
//
// Pinned directly against `handleRequest` — module-private, reachable from
// an in-module unittest — rather than a live socket: no listener/thread is
// started here, this is a pure in-process check of the routing branch.
// ---------------------------------------------------------------------------
unittest {
    auto srv = new HttpServer();                // testMode defaults false
    auto req = new HttpRequest("POST", "/api/test/layer", "HTTP/1.1");
    req.body = `{"kind":"empty"}`;

    auto resp = srv.handleRequest(req);
    assert(resp.statusCode == 403,
        "blocker 1: /api/test/layer must 403 outside --test mode, exactly "
        ~ "like /api/changes and /api/play-events (got "
        ~ to!string(resp.statusCode) ~ ")");

    // With testMode on, the gate must NOT block it — the request should
    // fall through to the (unset-handler) branch instead of another
    // refusal, proving this is a testMode gate and not an unconditional one.
    srv.setTestMode(true);
    auto resp2 = srv.handleRequest(req);
    assert(resp2.statusCode == 200,
        "with testMode on, /api/test/layer must pass the gate (got "
        ~ to!string(resp2.statusCode) ~ ")");
    assert(resp2.body.canFind("handler not set"),
        "with no handler installed this must reach the null-handler "
        ~ "branch, not another refusal: " ~ resp2.body);
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

// Parse `?key=N.N` (or `&key=N.N`) from a request path. Returns `def` when
// the key is missing or not parseable as a float (mirrors parseQueryInt).
private float parseQueryFloat(string path, string key, float def) {
    import std.conv : to, ConvException;
    auto qi = path.indexOf('?');
    if (qi < 0) return def;
    foreach (kv; path[qi + 1 .. $].split('&')) {
        auto eq = kv.indexOf('=');
        if (eq < 0) continue;
        if (kv[0 .. eq] == key) {
            try return kv[eq + 1 .. $].to!float;
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

// ---------------------------------------------------------------------------
// Task 0652: a connection we accept and never answer.
//
// The accept loop is single-threaded and runs handleClient INLINE, so before
// this was fixed a peer that connected and then sent nothing parked the only
// server thread in recv() forever. listen()'s backlog kept completing TCP
// handshakes throughout, so every later client still CONNECTED — and then
// waited forever. Observed as: the port answers a readiness probe, and every
// actual request times out.
//
// Two properties are pinned here, both against a real listening socket
// because the defect lives in the accept loop itself and not in any routing
// branch that `handleRequest` could be asked about directly:
//
//   1. a silent peer must not stop a well-behaved peer being ANSWERED. The
//      assertion is on the received status line AND body — never on the
//      connection being established, because connecting is precisely what
//      still worked while the defect was live;
//   2. giving up on the silent peer must be LOUD. A connection closed without
//      a response is invisible to its caller (whose connect() succeeded and
//      whose request simply never comes back), so it is audible here or
//      nowhere.
// ---------------------------------------------------------------------------
unittest {
    import core.time    : msecs, seconds;
    import core.thread  : Thread;
    import std.algorithm: canFind;
    import log          : snapshot, LogLevel;

    // Take a free port the way the OS offers one: bind ephemeral, read the
    // number back, release it.
    ushort freePort;
    {
        auto probe = new TcpSocket();
        probe.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
        freePort = (cast(InternetAddress) probe.localAddress).port;
        probe.close();
    }

    auto srv = new HttpServer(freePort);
    // Production budgets are 5 s / 15 s; shrink them so this costs ~0.5 s.
    srv.clientIoTimeout    = 500.msecs;
    srv.clientReadDeadline = 1500.msecs;
    srv.start();
    scope(exit) srv.stop();

    Socket connectOnce() {
        auto s = new TcpSocket();
        try { s.connect(new InternetAddress("127.0.0.1", freePort)); }
        catch (Exception) { s.close(); return null; }
        return s;
    }

    Socket silent;
    foreach (_; 0 .. 200) {
        silent = connectOnce();
        if (silent !is null) break;
        Thread.sleep(10.msecs);
    }
    assert(silent !is null, "0652: the test server never started listening");
    scope(exit) silent.close();
    // `silent` now holds an accepted connection and deliberately says nothing.

    auto client = connectOnce();
    assert(client !is null, "0652: the well-behaved peer could not connect");
    scope(exit) client.close();
    client.send("GET /api/ping HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    // Bound the read so a regression FAILS here rather than hanging the suite.
    client.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 10.seconds);

    string reply;
    ubyte[2048] buf;
    for (;;) {
        auto n = client.receive(buf[]);
        if (n <= 0) break;
        reply ~= cast(string) buf[0 .. n].idup;
    }

    assert(reply.canFind("HTTP/1.1 200 OK"),
        "0652: a silent peer must not stop a well-behaved peer being ANSWERED"
        ~ " — expected a 200 status line, got: "
        ~ (reply.length ? reply : "<no answer at all>"));
    assert(reply.canFind(`{"status": "ok"}`),
        "0652: the answer must carry the /api/ping body, got: " ~ reply);

    bool saidSoOutLoud = false;
    foreach (e; snapshot()) {
        if (e.level == LogLevel.Warn && e.subsystem == "http"
            && e.msg.canFind("WITHOUT a response")) { saidSoOutLoud = true; break; }
    }
    assert(saidSoOutLoud,
        "0652: closing an accepted connection without answering it must be"
        ~ " reported — an unreported give-up is invisible to the caller,"
        ~ " whose connect() succeeded and whose request never returns");
}

// ---------------------------------------------------------------------------
// Task 0652, a second defect found while fixing the first: a blocking recv()
// is interrupted by ANY signal, and the GC's stop-the-world signals every
// thread. EINTR therefore means "ask again", not "this peer is done" —
// classifying it as end-of-request drops a perfectly good in-flight request
// and closes the connection with no reply, which is the very failure the
// accept-loop budget above exists to prevent. Seen live before the retry was
// added: a peer that had sent nothing was reported closed after 1.1 s with
// "Interrupted system call", long before its idle budget was spent.
//
// The retry itself needs a signal to land mid-recv, which a test cannot
// schedule; what IS pinnable is the classification the retry hangs off, and
// in particular that it is not confused with the idle timeout.
// ---------------------------------------------------------------------------
version (Posix)
unittest {
    import core.stdc.errno : errno, EINTR, EAGAIN;

    immutable saved = errno;
    scope(exit) errno = saved;

    errno = EINTR;
    assert(HttpServer.interruptedBySignal(),
        "0652: EINTR must be classified as 'retry the receive' — treating it as"
        ~ " end-of-request drops an in-flight request and answers nothing");

    errno = EAGAIN;
    assert(!HttpServer.interruptedBySignal(),
        "0652: EAGAIN is the idle budget expiring, NOT a signal — classifying"
        ~ " it as EINTR would retry forever and re-park the accept loop");
}
