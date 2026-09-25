module http_server;

import std.stdio;
import std.string;
import std.conv;
import std.algorithm;
import std.array;
import std.datetime : Clock;
import std.exception : enforce;
import std.json;
import core.time : Duration, MonoTime, msecs, seconds;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;

import mesh : Mesh, Surface;
// The JSON bodies and the escaper that assembles them (task 0720, D5).
// Ordinary import: this module is their consumer, not their public facade.
import http_json : jsonEsc, meshToJsonDetailed, meshPlanesJson,
    PlaneDumpMeta, versionJson;
import http_transport : HttpServerTransport, httpTransportSleep,
    httpTransportThreadIdentity;
import core.atomic;
import perf_probe : g_perf, g_commandGc, FrameProbe, FrameProbeSnapshot,
                    FrameWorkProbe, FrameWorkSnapshot, toJson;

import eventlog : ImmediateEventSink;
import playback_controller : PlaybackController, PlaybackStatus,
    encodePlaybackStatus;
import argstring : parseArgstring, ParsedLine;
import log : logInfo, logWarn, logError;
import app_version : appVersion;

// ============================================================================
// Generic HTTP-thread <-> main-thread request/response bridge (task 0183 C3).
//
// Every marshaled endpoint used to hand-roll the same atomic-epoch spin/tick
// pair. MainThreadBridge!(Req,Resp) keeps that legacy surface temporarily and
// also self-registers into HttpServer.bridges, so tickAll() drains every
// constructed bridge without a named call list.
//
// Command dispatch gets a longer leash than the 2500-iter default: a
// legitimate one-shot mesh command on a ~100K-face mesh (whole-mesh bevel,
// edge extrude) runs tens of seconds on the main thread, and a 5s cap
// turns the perf harness's measurement into a timeout error — and worse,
// wedges every FOLLOWING request while the main thread finishes the work
// the client already gave up on. 60000 iters ≈ 2 min.
enum int kCommandBridgeMaxIters = 60_000;

// Timeout is per-call-site, NOT uniform. The legacy submitAndWait() returns a
// bool; migrated callers pass explicit initial/timeout/stopping results to the
// owned surface. The two surfaces coexist only for the narrow migration: a
// bridge instance is used through one or the other, never both concurrently.
interface IMainThreadBridge {
    void tick();
    void notifyStarted();
    void notifyStopping();
}

enum BridgeResultKind : ubyte {
    submitted,
    timedOut,
    ownerUnavailable,
    completed,
    stopping,
    failed,
}

enum OwnedClaim : ubyte { pending, claimed, completed, failed, expired, stopping }
enum ClaimProbePoint : ubyte { enqueued, extracted, claimed, pendingWait, claimedWait }

// An in-process browser channel has no second thread that can spin here while
// a frame drains the bridge. The transport scopes this TLS marker around one
// synchronous dispatch. Inline service still requires the server's recorded
// tickAll thread: an in-process caller on any other thread must take the same
// queue as a socket request. Evidence: tests.unit.http_server_test.
private size_t singleThreadedChannelDepth;

private bool inSingleThreadedChannel() nothrow {
    return singleThreadedChannelDepth != 0;
}

final class MainThreadBridge(Req, Resp) : IMainThreadBridge {
    private HttpServer owner_;
    private shared long submitted = 0;
    private shared long completed = 0;
    Req  req = Req.init;
    Resp resp = Resp.init;
    private void delegate(ref Req, ref Resp) service;
    private bool claimedServiceReady;

    private final class OwnedCall {
        Req request = Req.init;
        Resp result = Resp.init;
        MonoTime deadline = MonoTime.init;
        long requestIdentity = 0;
        long serviceResultIdentity = 0;
        shared int finished = 0;
        OwnedClaim claim = OwnedClaim.pending;

        this(Req request, Resp initialResult, MonoTime deadline,
             long requestIdentity, long serviceResultIdentity) {
            this.request = request;
            this.result = initialResult;
            this.deadline = deadline;
            this.requestIdentity = requestIdentity;
            this.serviceResultIdentity = serviceResultIdentity;
            atomicStore(this.finished, 0);
        }
    }

    struct OwnedResult {
        Resp result = Resp.init;
        long requestIdentity = 0;
        long resultIdentity = 0;
        BridgeResultKind kind = BridgeResultKind.completed;
    }

    private OwnedCall[] ownedPending = null;
    private OwnedCall[] claimPending = null;
    private shared long nextOwnedIdentity = 0;
    private shared bool ownedStopping = false;
    private Mutex ownedWaitMutex;
    private Condition ownedWaitCondition;
    private string ownedRoute;

    version(unittest) {
        struct OwnedTraceEntry {
            BridgeResultKind kind = BridgeResultKind.submitted;
            long requestIdentity = 0;
            long resultIdentity = 0;
            size_t stateIdentity = 0;
            Resp result = Resp.init;
        }
        private OwnedTraceEntry[] ownedTrace = null;
        private shared bool holdOwnedWaitForTest_ = false;
        private shared bool ownedWaitReachedForTest_ = false;
        private shared long ownedConditionWaitsForTest_ = 0;
        private shared long ownedConditionReturnsForTest_ = 0;
        private shared bool suppressOwnedCompletionNotifyForTest_ = false;
        private shared bool holdClaimEnqueuedForTest_ = false;
        private shared bool claimEnqueuedReachedForTest_ = false;
        private shared bool holdClaimExtractedForTest_ = false;
        private shared bool claimExtractedReachedForTest_ = false;
        private shared bool holdClaimedForTest_ = false;
        private shared bool claimedReachedForTest_ = false;
        private shared long pendingWaitsForTest_ = 0;
        private shared long claimedWaitsPastDeadlineForTest_ = 0;
        private shared long claimedWaitsWhileStoppingForTest_ = 0;
    }

    this(HttpServer owner, void delegate(ref Req, ref Resp) service,
         string ownedRoute = "") {
        owner_ = owner;
        this.service = service;
        this.ownedRoute = ownedRoute;
        ownedWaitMutex = new Mutex;
        ownedWaitCondition = new Condition(ownedWaitMutex);
        owner.bridges ~= this;
    }

    // Legacy surface memory ordering (load-bearing — mirrors the old
    // per-endpoint code exactly): the HTTP thread writes `req` BEFORE bumping
    // the submitted epoch; the main thread's tick() reads `req`/runs `service`
    // and writes `resp` BEFORE storing the completed epoch (the LAST statement
    // in tick()); the HTTP thread reads `resp` only AFTER submitAndWait()
    // observes the completed epoch catch up. Same seq-cst
    // atomicOp/atomicLoad/atomicStore as before, same 2500-iter / 2ms sleep
    // timeout. Do not weaken any of this.
    /// HTTP thread: bump the submit epoch and spin until the main thread's
    /// tick() drains it, or maxIters*2ms elapses. Returns false on timeout —
    /// the CALLER decides what timeout body to emit (see file header).
    bool submitAndWait(int maxIters = 2500) {
        if (inSingleThreadedChannel() && owner_.calledFromTickThread()) {
            service(req, resp);
            return true;
        }
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
            httpTransportSleep(2.msecs);
        }
        return true;
    }

    // Tasks 5730/5780 invariant: one waiter mutex covers the finished check,
    // wait, finished publication and notify around the submit-time deadline.
    // Lock order is waiter mutex -> this monitor, never the reverse: synthetic
    // results trace under `this`, so tick releases `this` before publication.
    // On macOS druntime's timed Condition uses wall time; acceptable for this
    // opt-in HTTP surface because MonoTime is rechecked after every return,
    // though a backward clock step may extend one wait. Controlled evidence is
    // request_result_ownership_test.d; no SDL/frame wake is implied.
    OwnedResult submitOwned(Req request, Resp initialResult,
                            Resp timeoutResult, Resp stoppingResult,
                            Duration budget) {
        immutable submittedAt = MonoTime.currTime;
        immutable requestIdentity = nextIdentity();
        auto call = new OwnedCall(request, initialResult,
                                  submittedAt + budget,
                                  requestIdentity, nextIdentity());
        if (inSingleThreadedChannel() && owner_.calledFromTickThread()) {
            bool stopping;
            synchronized (this) {
                traceOwned(BridgeResultKind.submitted, call,
                           call.serviceResultIdentity, initialResult);
                stopping = atomicLoad(ownedStopping);
            }
            if (stopping)
                return syntheticOwnedResult(call, stoppingResult,
                                            BridgeResultKind.stopping);
            service(call.request, call.result);
            synchronized (this) {
                traceOwned(BridgeResultKind.completed, call,
                           call.serviceResultIdentity, call.result);
            }
            OwnedResult result;
            result.result = call.result;
            result.requestIdentity = call.requestIdentity;
            result.resultIdentity = call.serviceResultIdentity;
            result.kind = BridgeResultKind.completed;
            return result;
        }
        bool queued = false;
        synchronized (this) {
            traceOwned(BridgeResultKind.submitted, call,
                       call.serviceResultIdentity, initialResult);
            if (!atomicLoad(ownedStopping)) {
                ownedPending ~= call;
                queued = true;
            }
        }
        if (!queued)
            return syntheticOwnedResult(call, stoppingResult,
                                        BridgeResultKind.stopping);

        for (;;) {
            version(unittest) {
                atomicStore(ownedWaitReachedForTest_, true);
                while (atomicLoad(holdOwnedWaitForTest_))
                    httpTransportSleep(1.msecs);
            }
            synchronized (ownedWaitMutex) {
                if (atomicLoad(call.finished) != 0) {
                    OwnedResult result;
                    result.result = call.result;
                    result.requestIdentity = call.requestIdentity;
                    result.resultIdentity = call.serviceResultIdentity;
                    result.kind = BridgeResultKind.completed;
                    return result;
                }
                if (atomicLoad(ownedStopping))
                    return syntheticOwnedResult(call, stoppingResult,
                                                BridgeResultKind.stopping);
                immutable now = MonoTime.currTime;
                if (now >= call.deadline)
                    return syntheticOwnedResult(call, timeoutResult,
                                                BridgeResultKind.timedOut);
                version(unittest)
                    atomicOp!"+="(ownedConditionWaitsForTest_, 1);
                ownedWaitCondition.wait(call.deadline - now);
                version(unittest)
                    atomicOp!"+="(ownedConditionReturnsForTest_, 1);
            }
        }
    }

    override void notifyStarted() {
        atomicStore(ownedStopping, false);
    }

    override void notifyStopping() {
        synchronized (ownedWaitMutex) {
            atomicStore(ownedStopping, true);
            ownedWaitCondition.notifyAll();
        }
        synchronized (this) {
            ownedPending = null;
            claimPending = null;
            claimedServiceReady = false;
        }
    }

    private long nextIdentity() {
        return atomicOp!"+="(nextOwnedIdentity, 1);
    }

    private OwnedResult syntheticOwnedResult(OwnedCall call, Resp value,
                                             BridgeResultKind kind) {
        // Task 5800 observability invariant: every synthetic owned failure is
        // named once at its shared source by route and kind. Behavioral bridge
        // evidence remains in request_result_ownership_test.d; the log sink is
        // intentionally not captured by that rig.
        try {
            import std.format : format;
            logWarn("http", format("%s submitOwned synthesized %s result",
                ownedRoute.length ? ownedRoute : Req.stringof, kind));
        } catch (Exception) {}
        OwnedResult result;
        result.result = value;
        result.requestIdentity = call.requestIdentity;
        result.resultIdentity = nextIdentity();
        result.kind = kind;
        synchronized (this) {
            traceOwned(kind, call, result.resultIdentity, value);
        }
        return result;
    }

    private void traceOwned(BridgeResultKind kind, OwnedCall call,
                            long resultIdentity, Resp result) {
        version(unittest) {
            OwnedTraceEntry entry;
            entry.kind = kind;
            entry.requestIdentity = call.requestIdentity;
            entry.resultIdentity = resultIdentity;
            entry.stateIdentity = cast(size_t) cast(void*) call;
            entry.result = result;
            ownedTrace ~= entry;
        }
    }

    version(unittest) {
        OwnedTraceEntry[] ownedTraceForTest() {
            synchronized (this) return ownedTrace.dup;
        }

        size_t ownedPendingForTest() {
            synchronized (this) return ownedPending.length;
        }

        void holdOwnedWaitForTest(bool held) {
            if (held) atomicStore(ownedWaitReachedForTest_, false);
            atomicStore(holdOwnedWaitForTest_, held);
        }

        bool ownedWaitReachedForTest() {
            return atomicLoad(ownedWaitReachedForTest_);
        }

        MonoTime ownedDeadlineForTest() {
            synchronized (this) {
                assert(ownedPending.length == 1);
                return ownedPending[0].deadline;
            }
        }

        long ownedConditionWaitsForTest() {
            return atomicLoad(ownedConditionWaitsForTest_);
        }

        long ownedConditionReturnsForTest() {
            return atomicLoad(ownedConditionReturnsForTest_);
        }

        void wakeOwnedWaiterForTest() {
            synchronized (ownedWaitMutex) ownedWaitCondition.notifyAll();
        }

        void suppressOwnedCompletionNotifyForTest(bool suppress) {
            atomicStore(suppressOwnedCompletionNotifyForTest_, suppress);
        }

        bool legacyPendingForTest() {
            return atomicLoad(submitted) > atomicLoad(completed);
        }

        size_t claimPendingForTest() {
            synchronized (this) return claimPending.length;
        }

        void holdClaimForTest(ClaimProbePoint point, bool held) {
            final switch (point) {
            case ClaimProbePoint.enqueued:
                if (held) atomicStore(claimEnqueuedReachedForTest_, false);
                atomicStore(holdClaimEnqueuedForTest_, held);
                break;
            case ClaimProbePoint.extracted:
                if (held) atomicStore(claimExtractedReachedForTest_, false);
                atomicStore(holdClaimExtractedForTest_, held);
                break;
            case ClaimProbePoint.claimed:
                if (held) atomicStore(claimedReachedForTest_, false);
                atomicStore(holdClaimedForTest_, held);
                break;
            case ClaimProbePoint.pendingWait:
            case ClaimProbePoint.claimedWait:
                assert(false, "wait probe points cannot be held");
            }
        }

        bool claimReachedForTest(ClaimProbePoint point) {
            final switch (point) {
            case ClaimProbePoint.enqueued:
                return atomicLoad(claimEnqueuedReachedForTest_);
            case ClaimProbePoint.extracted:
                return atomicLoad(claimExtractedReachedForTest_);
            case ClaimProbePoint.claimed:
                return atomicLoad(claimedReachedForTest_);
            case ClaimProbePoint.pendingWait:
                return atomicLoad(pendingWaitsForTest_) != 0;
            case ClaimProbePoint.claimedWait:
                return atomicLoad(claimedWaitsPastDeadlineForTest_) != 0
                    || atomicLoad(claimedWaitsWhileStoppingForTest_) != 0;
            }
        }

        long pendingWaitsForTest() {
            return atomicLoad(pendingWaitsForTest_);
        }

        long claimedWaitsPastDeadlineForTest() {
            return atomicLoad(claimedWaitsPastDeadlineForTest_);
        }

        long claimedWaitsWhileStoppingForTest() {
            return atomicLoad(claimedWaitsWhileStoppingForTest_);
        }

        void withClaimedServiceReadyForTest(scope void delegate() action) {
            synchronized (this) claimedServiceReady = true;
            scope(exit) synchronized (this) claimedServiceReady = false;
            action();
        }

        private void claimProbe(ClaimProbePoint point, OwnedCall call) {
            final switch (point) {
            case ClaimProbePoint.enqueued:
                atomicStore(claimEnqueuedReachedForTest_, true);
                while (atomicLoad(holdClaimEnqueuedForTest_)) httpTransportSleep(1.msecs);
                break;
            case ClaimProbePoint.extracted:
                atomicStore(claimExtractedReachedForTest_, true);
                while (atomicLoad(holdClaimExtractedForTest_)) httpTransportSleep(1.msecs);
                break;
            case ClaimProbePoint.claimed:
                atomicStore(claimedReachedForTest_, true);
                while (atomicLoad(holdClaimedForTest_)) httpTransportSleep(1.msecs);
                break;
            case ClaimProbePoint.pendingWait:
                atomicOp!"+="(pendingWaitsForTest_, 1);
                break;
            case ClaimProbePoint.claimedWait:
                if (MonoTime.currTime >= call.deadline)
                    atomicOp!"+="(claimedWaitsPastDeadlineForTest_, 1);
                if (atomicLoad(ownedStopping))
                    atomicOp!"+="(claimedWaitsWhileStoppingForTest_, 1);
                break;
            }
        }
    } else {
        pragma(inline, true)
        private void claimProbe(ClaimProbePoint, OwnedCall) {}
    }

    /// Main thread (called once per frame via HttpServer.tickAll()): runs
    /// the pending request's service body, if any, then publishes it.
    void tick() {
        OwnedCall owned;
        synchronized (this) {
            if (ownedPending.length != 0) {
                owned = ownedPending[0];
                ownedPending[0] = null;
                ownedPending = ownedPending[1 .. $];
                if (ownedPending.length == 0) ownedPending = null;
            }
        }
        if (owned !is null) {
            service(owned.request, owned.result);
            synchronized (this) {
                traceOwned(BridgeResultKind.completed, owned,
                           owned.serviceResultIdentity, owned.result);
            }
            // Owned publish contract (tasks 5730/5780): service/trace writes
            // the result first; under the waiter mutex the seq-cst finished
            // store then precedes notifyAll, so completion-before-wait and a
            // concurrent waiter cannot lose the signal. Evidence:
            // request_result_ownership_test.d.
            synchronized (ownedWaitMutex) {
                atomicStore(owned.finished, 1);
                bool suppress = false;
                version(unittest)
                    suppress = atomicLoad(
                        suppressOwnedCompletionNotifyForTest_);
                if (!suppress)
                    ownedWaitCondition.notifyAll();
            }
        }

        immutable long sub = atomicLoad(submitted);
        if (sub <= atomicLoad(completed)) return;
        service(req, resp);
        atomicStore(completed, sub);
    }

    // Task 6357: this opt-in queue is served only by tickClaimed. Every state
    // transition is under ownedWaitMutex: pending -> claimed -> completed or
    // failed, or pending -> expired or stopping. A claimed call waits for its
    // actual outcome; Throwable publication is explicit because cleanup around
    // a nothrow delegate is not reliable for Error. Evidence: the task plan.
    OwnedResult submitClaimed(Req request, Duration budget) {
        auto call = new OwnedCall(request, Resp.init, MonoTime.currTime + budget,
                                  nextIdentity(), nextIdentity());
        if (inSingleThreadedChannel() && owner_.calledFromTickThread()) {
            bool directReady;
            synchronized (this) {
                traceOwned(BridgeResultKind.submitted, call,
                           call.serviceResultIdentity, Resp.init);
                directReady = claimedServiceReady;
            }
            if (!directReady)
                return syntheticOwnedResult(call, Resp.init,
                                            BridgeResultKind.ownerUnavailable);
            try {
                service(call.request, call.result);
            } catch (Exception) {
                synchronized (this) {
                    traceOwned(BridgeResultKind.failed, call,
                               call.serviceResultIdentity, call.result);
                }
                OwnedResult failed;
                failed.result = call.result;
                failed.requestIdentity = call.requestIdentity;
                failed.resultIdentity = call.serviceResultIdentity;
                failed.kind = BridgeResultKind.failed;
                return failed;
            }
            assert(0, "claimed bridge owner fence returned");
        }
        bool queued = false;
        synchronized (this) {
            traceOwned(BridgeResultKind.submitted, call,
                       call.serviceResultIdentity, Resp.init);
            if (!atomicLoad(ownedStopping)) {
                claimPending ~= call;
                queued = true;
            }
        }
        claimProbe(ClaimProbePoint.enqueued, call);
        synchronized (ownedWaitMutex) {
            if (!queued) call.claim = OwnedClaim.stopping;
            for (;;) {
                final switch (call.claim) {
                case OwnedClaim.completed:
                case OwnedClaim.failed:
                    OwnedResult result;
                    result.result = call.result;
                    result.requestIdentity = call.requestIdentity;
                    result.resultIdentity = call.serviceResultIdentity;
                    result.kind = call.claim == OwnedClaim.failed
                        ? BridgeResultKind.failed : BridgeResultKind.completed;
                    return result;
                case OwnedClaim.expired:
                    return syntheticOwnedResult(call, Resp.init,
                                                BridgeResultKind.timedOut);
                case OwnedClaim.stopping:
                    return syntheticOwnedResult(call, Resp.init,
                                                BridgeResultKind.stopping);
                case OwnedClaim.claimed:
                    claimProbe(ClaimProbePoint.claimedWait, call);
                    immutable now = MonoTime.currTime;
                    if (now < call.deadline)
                        ownedWaitCondition.wait(call.deadline - now);
                    else
                        ownedWaitCondition.wait();
                    break;
                case OwnedClaim.pending:
                    if (atomicLoad(ownedStopping)) {
                        call.claim = OwnedClaim.stopping;
                        continue;
                    }
                    immutable now = MonoTime.currTime;
                    if (now >= call.deadline) {
                        call.claim = OwnedClaim.expired;
                        continue;
                    }
                    claimProbe(ClaimProbePoint.pendingWait, call);
                    ownedWaitCondition.wait(call.deadline - now);
                    break;
                }
            }
        }
    }

    void tickClaimed(scope void delegate(ref Req, ref Resp) nothrow service) {
        synchronized (this) claimedServiceReady = true;
        scope(exit) synchronized (this) claimedServiceReady = false;
        OwnedCall[] batch;
        synchronized (this) {
            batch = claimPending;
            claimPending = null;
        }
        foreach (call; batch) {
            claimProbe(ClaimProbePoint.extracted, call);
            bool won = false;
            synchronized (ownedWaitMutex) {
                if (call.claim == OwnedClaim.pending) {
                    if (atomicLoad(ownedStopping))
                        call.claim = OwnedClaim.stopping;
                    else if (MonoTime.currTime >= call.deadline)
                        call.claim = OwnedClaim.expired;
                    else {
                        call.claim = OwnedClaim.claimed;
                        won = true;
                    }
                    if (!won) ownedWaitCondition.notifyAll();
                }
            }
            if (!won) continue;
            claimProbe(ClaimProbePoint.claimed, call);
            try {
                service(call.request, call.result);
            } catch (Throwable error) {
                publishClaimed(call, OwnedClaim.failed);
                throw error;
            }
            publishClaimed(call, OwnedClaim.completed);
        }
    }

    private void publishClaimed(OwnedCall call, OwnedClaim outcome) {
        synchronized (this) {
            traceOwned(outcome == OwnedClaim.failed ? BridgeResultKind.failed
                                                    : BridgeResultKind.completed,
                       call, call.serviceResultIdentity, call.result);
        }
        synchronized (ownedWaitMutex) {
            call.claim = outcome;
            ownedWaitCondition.notifyAll();
        }
    }
}

/**
 * Simple HTTP server implementation for D applications
 */
class HttpServer {
    // Compiler-enforced composition fence: native socket/thread transport is
    // an implementation mixin, while this module owns request routing.
    mixin HttpServerTransport;

    // --- Readiness (task 1740) --------------------------------------------
    //
    // `start()` opens the port at app.d:1171. The provider/handler delegates
    // are installed by `wireHttpProviders` ~3550 lines later. For the whole of
    // that span the listener accepted connections and ANSWERED them: measured
    // on a 32-core host, `--test`, plain `dub build` — 1196 replies of `500`
    // on `GET /api/camera` and 1058 replies of `{"status":"error","message":
    // "command handler not set"}` on `POST /api/command`, over a 202 ms
    // window; 1504-2065 replies over ~1.5 s with four instances pinned to
    // four cores under llvmpipe. So "the port answers" and even "the route
    // answers" did not mean "the app is ready", and the difference was
    // visible from outside ONLY by reading the response BODY.
    //
    // WHY A STATUS CODE AND NOT A `/api/ready` ROUTE. A second route would be
    // a SECOND readiness signal beside the body of `/api/command`, and the
    // tree already demonstrates where that ends: before this change there
    // were three disagreeing predicates in-tree (`run_test.d` waited for 200
    // on `/api/camera`, `tools/sanitizer/lane.d` had one mode matching the
    // string `command handler not set` and another matching 200 on
    // `/api/camera`, both behind `/api/registry` answering at all — and
    // `/api/registry` is served from a static table, so it answers throughout
    // the window). One code, on every `/api/*` route, is the only shape that
    // cannot drift: a caller does not have to know WHICH endpoint carries the
    // truth.
    //
    // WHY NOT SIMPLY MOVE `start()` BELOW THE WIRING. It is mechanically
    // possible (nothing between the two points touches `httpServer`), and it
    // is still the wrong trade: it replaces a diagnosable state (connect, get
    // 503) with an ambiguous one (ECONNREFUSED), which is indistinguishable
    // from "the process died", "the port is taken by a stale instance" and
    // "the probe never reached us". A startup that HANGS — GL under a
    // software rasteriser on a loaded VM is a real case — would then have no
    // port to ask at all. It would also move the `HTTP server started on port
    // N` log line ~3550 lines later, and `run_test.d`'s first wait leg keys on
    // exactly that string.
    //
    // TWO flags, ONE signal. Providers wired is not sufficient: `/api/command`
    // is an `Answered.mainThread` route, so between the wiring and the frame
    // loop's first `tickAll()` a request is accepted, spins 5 s in
    // `submitAndWait` and comes back as a timeout body — a third "not ready"
    // shape, which `tools/sanitizer/lane.d` was matching by string as well.
    // Readiness therefore means BOTH: the wiring completed AND the main loop
    // has drained the bridges at least once.
    private shared bool providersWired;
    private shared bool mainLoopTicked;
    // First tickAll publishes an opaque native-thread identity once; bridge
    // submitters read the integer atomically. Names and indices are outside
    // this contract.
    private shared size_t tickThreadIdentity_;

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
    // Both are marshaled onto the main thread, for different reasons and with
    // phase contracts that follow the lifetime of what each one reads:
    //
    //   * /api/tool/handles is MARSHALED onto the main thread
    //     (toolHandlesBridge, task 0563). The handle registry is not resident
    //     state: it is destroyed and rebuilt on every interactive draw, so
    //     "read it with no lock between settles" is not a contract it can
    //     honour — there is no moment at which the list is both complete and
    //     guaranteed to describe the caller's most recent change. See the
    //     bridge declaration below.
    //   * /api/tool/state is MARSHALED onto the main thread too (task 5940).
    //     Its resident fields are read at service time, during the ordinary
    //     tickAll before the tool update; there is deliberately no readiness
    //     barrier or parallel snapshot. Evidence: tool_state_owned_route_test.
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
    // W14-C: these nine adapters are application-owned even when their
    // current implementations only read a published snapshot or diagnostic
    // probe.  HttpServer owns transport and main-thread hand-off; the module
    // that owns each value owns the JSON construction/state access.
    private alias PortlessJsonProvider = string delegate();
    private PortlessJsonProvider toolDisarmProvider;
    private PortlessJsonProvider uiPolicyProvider;
    private PortlessJsonProvider toolpropsIdsProvider;
    private PortlessJsonProvider buttonAvailabilityProvider;
    private alias InputContextProvider =
        string delegate(bool havePoint, int x, int y, string key);
    private InputContextProvider inputContextProvider;
    private PortlessJsonProvider statsProvider;
    private PortlessJsonProvider pieProvider;
    private alias PerfResetHandler = void delegate();
    private PerfResetHandler perfResetHandler;
    private PortlessJsonProvider perfProvider;
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

    // GET /api/mesh/planes (task 1903 Stage B, plan §6.3) — the PLANE-COMPLETE
    // readback the per-family delta<->snapshot parity fixtures are frozen from.
    // Test-automation only, gated exactly as /api/changes is.
    //
    // MAIN THREAD, and for the same reason /api/model is: the provider hands
    // `http_json.meshPlanesJson` the LIVE mesh with no copy standing between
    // them, and a dump torn across a mid-edit array reassignment is not an
    // error, it is a fixture that looks like an answer.
    //
    // The four strings are the fixture's provenance (plan §6.3 rule 2), taken
    // from the query string — the capture script knows the SHA it is standing
    // on and the app does not.
    private alias MeshPlanesProvider =
        string delegate(string producedBy, string path, string family, string stand);
    private MeshPlanesProvider meshPlanesProvider;
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
    // POST /api/camera — sync bridge to set the live View. Used by
    // the cross-engine drag test to align vibe3d's camera with a
    // reference engine's before replaying a drag through /api/play-events.
    private alias CameraSetHandler = void delegate(JSONValue params);
    private CameraSetHandler cameraSetHandler;
    // Server-owned authorization configuration; all requests share this value.
    // Each dispatch snapshots it into HttpRequest.context, so concurrent
    // requests cannot carry different configured values.
    private HttpRequestContext serverContext_;

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
    private alias CommandHandler = void delegate(string id, string paramsJson,
                                                 bool interactive);
    private CommandHandler commandHandler;
    // Task 1520 — the UI-policy adapter. Separate FIELD, not a flag on the
    // one above, because the two carry opposite refusal policies and
    // `/api/command?origin=ui` (--test only) exists to drive the UI one.
    private CommandHandler uiCommandHandler;
    // `interactive` travels with every invocation instead of mutating an
    // application latch. Argstring sets it false; script batches set it from
    // `?interactive=`; replay inherits the bridge field as before (task 4711).
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

    // ----- /api/test/layer synchronous bridge -------------------------------
    // POST /api/test/layer {"kind":"empty","name":"...","index":N}
    // appends (or inserts) a layer of the given kind through `layer.add`.
    // The document format cannot yet persist a
    // non-mesh item (Stage 8/v8 is deferred to task 0616 by owner decision —
    // see doc/nonmesh_item_types_plan.md §Stage 6), so no path a real user
    // could reach — command argument, button, or menu — may create one in
    // this slice; a test driving this ONE dedicated endpoint is the sole
    // source. The live `Document` is touched from the main/GL thread only.
    private alias InjectLayerHandler = void delegate(JSONValue params);
    private InjectLayerHandler injectLayerHandler;

    // ----- /api/history/jump (multi-step) ----------------------------------
    // CommandHistory.jumpTo(target) called on the main thread via the same
    // sync pattern as /api/undo. `target` is the desired length of undoStack
    // after the jump — 0 = everything undone, undo.length = current, larger
    // walks into the redo stack.
    private alias JumpHandler = bool delegate(size_t target);
    private JumpHandler jumpHandler;

    private alias HistoryProvider = string delegate();   // returns JSON
    private HistoryProvider historyProvider;

    // ----- GET /api/trace / POST /api/trace/reset|disarm --------------------
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
    private TraceResetHandler traceDisarmHandler;

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
    // Task 1650 added `overlayOwner` (top level) and `overlayMode` per cell.
    // `overlayMode` is the stamp written by the N-cell loop that calls
    // `viewport_overlay_mode.resolveOverlayMode`. That is what lets a
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
        string delegate(int cell, string points, bool wantHash,
                        bool composedFrame);
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
    // Returns JSON {state, lockout, canUndo, canRedo}. Its complete encoder
    // runs inside undoStatusBridge's main-thread service (task 5820).
    private alias UndoStatusProvider = string delegate();
    private UndoStatusProvider undoStatusProvider;

    // ----- /api/history/replay provider ------------------------------------
    // Returns the canonical argstring line for undoStack[index], or "" when
    // the index is out of range. Called only inside replayBridge's main-thread
    // service, immediately before the same service dispatches the line.
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

    // Main-thread owner of the HTTP event player (task 5960 D2).
    private PlaybackController playbackController;
    // The PROCESSED barrier. `finished` flips inside
    // the frame that dispatched the last event, BEFORE that frame's tool
    // update, flush and draw; a read served in that same tickAll pass would
    // precede them. So `processed` requires a LATER pass: the frame that
    // consumed the event has then run to completion. Both counters are touched
    // only on the tick thread. Witness: tests/unit/playback_owner_test.d U9.
    private ulong tickPass_;
    private ulong playbackFinishPass_;

    // ========================================================================
    // MainThreadBridge instances (task 0183 C3) — one per marshaled endpoint,
    // constructed (and self-registered into `bridges`) in the HttpServer
    // constructor. The accept loop handles one client inline, so today at most
    // one request can be pending and drain order is inert; self-registration
    // removes the stale named roster the old hand-written app.d tick list
    // required. Each bridge's `service` delegate closes over `this` (reading
    // the handler/provider fields above AT TICK TIME, so it works even though
    // app.d wires those fields after HttpServer is constructed).
    private IMainThreadBridge[] bridges;

    struct ModelReq  { int layer = -1; bool detailed; }
    struct ModelResp { string result; string error; }
    private MainThreadBridge!(ModelReq, ModelResp) modelBridge;
    private Duration modelBudget_ = 5.seconds;

    // Task 0950 item F — /api/selection has its OWN bridge. The provider
    // walks Document.layers and resolves the active mesh, both main-thread
    // state; sharing another endpoint's epochs would allow their replies to
    // interleave.
    struct SelectionReq  { }
    struct SelectionResp { string result; string error; }
    private MainThreadBridge!(SelectionReq, SelectionResp) selectionBridge;
    private int selectionBridgeMaxIters_ = 2500;

    struct ToolStateReq  { }
    struct ToolStateResp { string result; string error; bool failed; }
    private MainThreadBridge!(ToolStateReq, ToolStateResp) toolStateBridge;
    private Duration toolStateBudget_ = 5.seconds;

    struct PortlessJsonReq  { }
    struct PortlessJsonResp { string result; string error; }
    static assert([__traits(allMembers, PortlessJsonResp)] ==
        ["result", "error"],
        "6780 portless JSON response channel order changed");
    private MainThreadBridge!(PortlessJsonReq, PortlessJsonResp)
        toolDisarmBridge;
    private MainThreadBridge!(PortlessJsonReq, PortlessJsonResp)
        uiPolicyBridge;
    private MainThreadBridge!(PortlessJsonReq, PortlessJsonResp)
        toolpropsIdsBridge;
    private MainThreadBridge!(PortlessJsonReq, PortlessJsonResp)
        buttonAvailabilityBridge;
    struct InputContextReq {
        bool havePoint;
        int x;
        int y;
        string key;
    }
    struct InputContextResp { string result; string error; }
    static assert([__traits(allMembers, InputContextResp)] ==
        ["result", "error"],
        "6780 input-context response channel order changed");
    private MainThreadBridge!(InputContextReq, InputContextResp)
        inputContextBridge;
    private MainThreadBridge!(PortlessJsonReq, PortlessJsonResp) statsBridge;
    private MainThreadBridge!(PortlessJsonReq, PortlessJsonResp) pieBridge;
    struct PerfResetReq  { }
    struct PerfResetResp { string error; }
    private MainThreadBridge!(PerfResetReq, PerfResetResp) perfResetBridge;
    private MainThreadBridge!(PortlessJsonReq, PortlessJsonResp) perfBridge;
    private Duration portlessRouteBudget_ = 5.seconds;

    struct HistoryReq  { }
    struct HistoryResp { string result; string error; }
    private MainThreadBridge!(HistoryReq, HistoryResp) historyBridge;

    struct UndoStatusReq  { }
    struct UndoStatusResp { string result; string error; }
    private MainThreadBridge!(UndoStatusReq, UndoStatusResp) undoStatusBridge;
    private Duration undoStatusBudget_ = 5.seconds;

    struct PipeEvalReq  { }
    struct PipeEvalResp { string result; string error; }
    private MainThreadBridge!(PipeEvalReq, PipeEvalResp) pipeEvalBridge;

    struct PathReq  { float t; }
    struct PathResp { string result; string error; }
    private MainThreadBridge!(PathReq, PathResp) pathBridge;
    private int pathBridgeMaxIters_ = 2500;

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
    // Task 5820: the pointer is non-null only inside executeCommand. It routes
    // adapter query delivery to the current execution's owner; the legacy
    // command response remains the explicitly named out-of-port remainder.
    private string* commandResultSink_;

    struct ReplayReq {
        size_t index;
        bool interactive;
        bool uiOrigin;
    }
    struct ReplayResp { string error; string line; string result; }
    private MainThreadBridge!(ReplayReq, ReplayResp) replayBridge;
    private Duration replayBudget_ = 120.seconds;

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

    // This is a synchronous state-changing action, not a read provider. The
    // in-process transport runs it inline only on the recorded tickAll thread,
    // so that channel never waits for a later host frame. Evidence:
    // tests.unit.test_mode_request_gate_test.
    private alias SubpatchHoldAction = string delegate(long ms, long ceilingMs);
    private SubpatchHoldAction subpatchHoldAction;
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

    struct VpProbeReq  {
        int cell = -1;
        string points;
        bool wantHash;
        bool composedFrame;
    }
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

    // Task 1903 Stage B — /api/mesh/planes. Its OWN bridge instance, same hard
    // rule as every other one (two endpoints sharing a bridge interleave their
    // epochs and one of them returns a torn or empty result).
    struct MeshPlanesReq  { string producedBy; string path; string family; string stand; }
    struct MeshPlanesResp { string result; string error; }
    private MainThreadBridge!(MeshPlanesReq, MeshPlanesResp) meshPlanesBridge;

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

    // Task 5950 invariant: this bridge is constructed, and so ticked, before
    // the command bridge. A
    // command answered earlier in the same tickAll pass can be followed by a
    // GET queued mid-pass while a later owned bridge (replay or layers) is
    // serviced; that GET waits for the next pass, after draw rebuilt the
    // registry. Evidence: tests.unit.model_handles_owned_transport_test and
    // tests/test_model_handles_owned_route.d.
    struct ToolHandlesReq  { }
    struct ToolHandlesResp { string result; string error; }
    private MainThreadBridge!(ToolHandlesReq, ToolHandlesResp) toolHandlesBridge;
    private Duration toolHandlesBudget_ = 5.seconds;

    struct PlayEventsReq {
        string body;
        MonoTime notAfter;
    }
    static assert([__traits(allMembers, PlayEventsReq)] == ["body", "notAfter"],
        "6810 play-events bridge request composition changed");
    struct PlayEventsResp {
        bool invalidLog;
        ulong generation;
        ulong replaced;
        string error;
    }
    static assert([__traits(allMembers, PlayEventsResp)] ==
            ["invalidLog", "generation", "replaced", "error"],
        "6810 play-events bridge response composition changed");
    private MainThreadBridge!(PlayEventsReq, PlayEventsResp) playEventsBridge;
    private Duration playEventsBudget_ = 5.seconds;

    struct PlayEventsStatusReq { }
    struct PlayEventsStatusResp { string result; string error; }
    private MainThreadBridge!(PlayEventsStatusReq, PlayEventsStatusResp)
        playEventsStatusBridge;
    private Duration playEventsStatusBudget_ = 5.seconds;

    enum FrameCountsOp : ubyte { read, reset }
    struct FrameCountsReq { FrameCountsOp op; }
    struct FrameCountsResp { FrameWorkSnapshot snapshot; }
    private MainThreadBridge!(FrameCountsReq, FrameCountsResp) frameCountsBridge;
    private Duration frameCountsBudget_ = 5.seconds;

    enum FramesOp : ubyte { read, reset }
    struct FramesReq { FramesOp op; }
    struct FramesResp { FrameProbeSnapshot snapshot; }
    private MainThreadBridge!(FramesReq, FramesResp) framesBridge;
    private Duration framesBudget_ = 5.seconds;

    public this(ushort port = 8080) {
        this.port = port;
        atomicStore(this.isRunning, false);
        this.playbackController = PlaybackController();

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
            }, "/api/model");

        selectionBridge = new MainThreadBridge!(SelectionReq, SelectionResp)(this,
            (ref SelectionReq req, ref SelectionResp resp) {
                try {
                    if (selectionDataProvider !is null)
                        resp.result = selectionDataProvider();
                    else
                        resp.error = "Selection data provider not set";
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            }, "/api/selection");

        toolStateBridge = new MainThreadBridge!(ToolStateReq, ToolStateResp)(this,
            (ref ToolStateReq req, ref ToolStateResp resp) {
                try {
                    resp.result = toolStateDataProvider !is null
                        ? toolStateDataProvider() : "{}";
                } catch (Exception e) {
                    resp.failed = true;
                    resp.error = e.msg;
                }
            }, "/api/tool/state");

        toolDisarmBridge = new MainThreadBridge!(PortlessJsonReq,
                PortlessJsonResp)(this,
            (ref PortlessJsonReq req, ref PortlessJsonResp resp) {
                try {
                    if (toolDisarmProvider is null)
                        resp.error = "tool-disarm provider not set";
                    else
                        resp.result = toolDisarmProvider();
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            }, "/api/tool/disarm");

        uiPolicyBridge = new MainThreadBridge!(PortlessJsonReq,
                PortlessJsonResp)(this,
            (ref PortlessJsonReq req, ref PortlessJsonResp resp) {
                try {
                    if (uiPolicyProvider is null)
                        resp.error = "UI-policy provider not set";
                    else
                        resp.result = uiPolicyProvider();
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            }, "/api/ui/policy");

        toolpropsIdsBridge = new MainThreadBridge!(PortlessJsonReq,
                PortlessJsonResp)(this,
            (ref PortlessJsonReq req, ref PortlessJsonResp resp) {
                try {
                    if (toolpropsIdsProvider is null)
                        resp.error = "tool-props ids provider not set";
                    else
                        resp.result = toolpropsIdsProvider();
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            }, "/api/toolprops/ids");

        buttonAvailabilityBridge = new MainThreadBridge!(PortlessJsonReq,
                PortlessJsonResp)(this,
            (ref PortlessJsonReq req, ref PortlessJsonResp resp) {
                try {
                    if (buttonAvailabilityProvider is null)
                        resp.error = "button-availability provider not set";
                    else
                        resp.result = buttonAvailabilityProvider();
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            }, "/api/buttons/availability");

        inputContextBridge = new MainThreadBridge!(InputContextReq,
                InputContextResp)(this,
            (ref InputContextReq req, ref InputContextResp resp) {
                try {
                    if (inputContextProvider is null)
                        resp.error = "input-context provider not set";
                    else
                        resp.result = inputContextProvider(
                            req.havePoint, req.x, req.y, req.key);
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            }, "/api/input/context");

        statsBridge = new MainThreadBridge!(PortlessJsonReq,
                PortlessJsonResp)(this,
            (ref PortlessJsonReq req, ref PortlessJsonResp resp) {
                try {
                    if (statsProvider is null)
                        resp.error = "stats provider not set";
                    else
                        resp.result = statsProvider();
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            }, "/api/stats");

        pieBridge = new MainThreadBridge!(PortlessJsonReq,
                PortlessJsonResp)(this,
            (ref PortlessJsonReq req, ref PortlessJsonResp resp) {
                try {
                    if (pieProvider is null)
                        resp.error = "pie provider not set";
                    else
                        resp.result = pieProvider();
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            }, "/api/pie");

        perfResetBridge = new MainThreadBridge!(PerfResetReq,
                PerfResetResp)(this,
            (ref PerfResetReq req, ref PerfResetResp resp) {
                try {
                    if (perfResetHandler is null)
                        resp.error = "perf-reset handler not set";
                    else
                        perfResetHandler();
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            }, "/api/perf/reset");

        perfBridge = new MainThreadBridge!(PortlessJsonReq,
                PortlessJsonResp)(this,
            (ref PortlessJsonReq req, ref PortlessJsonResp resp) {
                try {
                    if (perfProvider is null)
                        resp.error = "perf provider not set";
                    else
                        resp.result = perfProvider();
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            }, "/api/perf");

        historyBridge = new MainThreadBridge!(HistoryReq, HistoryResp)(this,
            (ref HistoryReq req, ref HistoryResp resp) {
                try {
                    if (historyProvider !is null)
                        resp.result = historyProvider();
                    else
                        resp.error = "history provider not set";
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            }, "/api/history");

        undoStatusBridge = new MainThreadBridge!(UndoStatusReq, UndoStatusResp)(this,
            (ref UndoStatusReq req, ref UndoStatusResp resp) {
                try {
                    if (undoStatusProvider !is null)
                        resp.result = undoStatusProvider();
                    else
                        resp.error = "undo status provider not set";
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            }, "/api/undo/status");

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
            }, "/api/tool/handles");

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
                executeCommand(req.id, req.params, req.interactive,
                               req.uiOrigin, resp.result, resp.error);
            });

        replayBridge = new MainThreadBridge!(ReplayReq, ReplayResp)(this,
            (ref ReplayReq req, ref ReplayResp resp) {
                try {
                    string line = replayProvider(req.index);
                    if (line.length == 0) {
                        resp.error = "no entry at given index";
                        return;
                    }
                    auto parsed = parseArgstring(line);
                    if (parsed.isEmpty)
                        throw new Exception("entry parsed as empty");
                    resp.line = line;
                    executeCommand(parsed.commandId, parsed.params.toString(),
                                   req.interactive, req.uiOrigin,
                                   resp.result, resp.error);
                } catch (Exception e) {
                    resp.error = e.msg;
                }
            }, "/api/history/replay");

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

        subpatchHoldBridge = new MainThreadBridge!(SubpHoldReq, SubpHoldResp)(
            this, &serviceSubpatchHold);

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
                        resp.result = viewportProbeProvider(
                            req.cell, req.points, req.wantHash,
                            req.composedFrame);
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
            }, "/api/layers");

        meshPlanesBridge = new MainThreadBridge!(MeshPlanesReq, MeshPlanesResp)(this,
            (ref MeshPlanesReq req, ref MeshPlanesResp resp) {
                if (meshPlanesProvider is null) {
                    resp.error = "mesh-planes provider not set";
                } else {
                    try {
                        resp.result = meshPlanesProvider(req.producedBy, req.path,
                                                         req.family, req.stand);
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

        // Playback bridges are appended without perturbing the established
        // bridge order. The phase boundary comes from app.d calling
        // tickEventPlayer before tickAll: an accepted log first ticks next frame.
        playEventsBridge = new MainThreadBridge!(PlayEventsReq, PlayEventsResp)(this,
            (ref PlayEventsReq req, ref PlayEventsResp resp) {
                auto outcome = playbackController.accept(req.body, req.notAfter);
                if (outcome.invalidLog) {
                    resp.invalidLog = true;
                    resp.error = "Failed to parse events";
                    return;
                }
                if (!outcome.accepted) {
                    resp.error = "timeout waiting for main thread";
                    return;
                }
                resp.generation = outcome.generation;
                resp.replaced = outcome.replaced;
            }, "/api/play-events");

        playEventsStatusBridge = new MainThreadBridge!(PlayEventsStatusReq,
                PlayEventsStatusResp)(this,
            (ref PlayEventsStatusReq req, ref PlayEventsStatusResp resp) {
                resp.result = encodePlaybackStatus(settledPlaybackStatus());
            }, "/api/play-events/status");

        frameCountsBridge = new MainThreadBridge!(FrameCountsReq,
                FrameCountsResp)(this,
            (ref FrameCountsReq req, ref FrameCountsResp resp) {
                enforce(false,
                    "frame-count bridge is served only by its owner tick");
            }, "/api/frames/counts");

        framesBridge = new MainThreadBridge!(FramesReq, FramesResp)(this,
            (ref FramesReq req, ref FramesResp resp) {
                enforce(false,
                    "frame probe bridge is served only by its owner tick");
            }, "/api/frames");
    }

    // Task 5820 invariant: both command entry services synchronously use this
    // one policy port, so history resolution and replay dispatch share one
    // main-thread service with no intervening queue/frame. The query sink and
    // GC bracket cover binding plus adapter delivery and unwind after the
    // closing brace on success or Exception. Evidence:
    // history_replay_boundary_test.d.
    private void executeCommand(string id, string params, bool interactive,
                                bool uiOrigin, ref string result,
                                ref string error) {
        // Clear the query-result slot at entry: a write command leaves it
        // empty so the HTTP thread emits the plain {"status":"ok"} body. A
        // query command's adapter delivery calls setCmdResult() to repopulate
        // this execution's result owner.
        result = "";
        auto previousResultSink = commandResultSink_;
        commandResultSink_ = &result;
        scope(exit) commandResultSink_ = previousResultSink;
        if (commandHandler is null) {
            error = "command handler not set";
            return;
        }

        // ---- Task 2070: the per-command GC bracket ----------------------
        //
        // WHY HERE AND NOT AT THE ROUTE. `GC.allocatedInCurrentThread` is
        // PER-THREAD, and `/api/command` arrives on the HTTP background thread
        // but does NOT run there: the route is `Answered.mainThread`, so the
        // route only fills a request, submits it and waits, while THIS port is
        // invoked by `MainThreadBridge.tick()` from the main loop. A bracket
        // taken at the route would read the HTTP thread's own allocation — the
        // request parse and response buffer, a few kB, stable across cases and
        // completely unrelated to the command. It would look plausible while
        // measuring nothing, which is the failure this comment prevents.
        //
        // Outermost in the scope so the window covers application binding and
        // adapter delivery too. `scope(exit)` keeps the bracket intact across
        // every return path. `end()` runs on a throw as well — the catch below
        // is INSIDE it — so a failing command still publishes its cost instead
        // of leaving the previous command's figures standing as this one's.
        g_commandGc.begin();
        scope(exit) g_commandGc.end();
        try {
            // Task 1520: pick the adapter. THIS PORT CATCHES, which is why no
            // test here observes an exception escaping an ImGui draw. It
            // observes the proxy "the UI adapter did not throw" — sound because
            // `uiCommandHandler` enters the same application binding as panel
            // delegates. Null UI callback deliberately falls back to script.
            if (uiOrigin && uiCommandHandler !is null)
                uiCommandHandler(id, params, interactive);
            else
                commandHandler(id, params, interactive);
            error = "";
        } catch (Exception e) {
            error = e.msg;
        }
    }

    private void serviceSubpatchHold(ref SubpHoldReq req,
                                     ref SubpHoldResp resp) {
        if (subpatchHoldAction is null) {
            resp.error = "subpatch-hold action unavailable during service";
        } else {
            try {
                resp.result = subpatchHoldAction(req.ms, req.ceilingMs);
                resp.error  = "";
            } catch (Exception e) {
                resp.error = e.msg;
            }
        }
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

    public void setToolDisarmProvider(PortlessJsonProvider provider) {
        this.toolDisarmProvider = provider;
    }

    public void setUiPolicyProvider(PortlessJsonProvider provider) {
        this.uiPolicyProvider = provider;
    }

    public void setToolpropsIdsProvider(PortlessJsonProvider provider) {
        this.toolpropsIdsProvider = provider;
    }

    public void setButtonAvailabilityProvider(PortlessJsonProvider provider) {
        this.buttonAvailabilityProvider = provider;
    }

    public void setInputContextProvider(InputContextProvider provider) {
        this.inputContextProvider = provider;
    }

    public void setStatsProvider(PortlessJsonProvider provider) {
        this.statsProvider = provider;
    }

    public void setPieProvider(PortlessJsonProvider provider) {
        this.pieProvider = provider;
    }

    public void setPerfResetHandler(PerfResetHandler handler) {
        this.perfResetHandler = handler;
    }

    public void setPerfProvider(PortlessJsonProvider provider) {
        this.perfProvider = provider;
    }

    version(unittest) {
        public size_t portlessOwnedPendingForTest(string path) {
            switch (path) {
            case "/api/tool/disarm":
                return toolDisarmBridge.ownedPendingForTest();
            case "/api/ui/policy":
                return uiPolicyBridge.ownedPendingForTest();
            case "/api/toolprops/ids":
                return toolpropsIdsBridge.ownedPendingForTest();
            case "/api/buttons/availability":
                return buttonAvailabilityBridge.ownedPendingForTest();
            case "/api/input/context":
                return inputContextBridge.ownedPendingForTest();
            case "/api/stats":
                return statsBridge.ownedPendingForTest();
            case "/api/pie":
                return pieBridge.ownedPendingForTest();
            case "/api/perf/reset":
                return perfResetBridge.ownedPendingForTest();
            case "/api/perf":
                return perfBridge.ownedPendingForTest();
            default:
                assert(false, "unknown W14-C route: " ~ path);
            }
        }

        public void setSelectionBridgeMaxItersForTest(int maxIters) {
            assert(maxIters >= 0);
            selectionBridgeMaxIters_ = maxIters;
        }

        public void setPathBridgeMaxItersForTest(int maxIters) {
            assert(maxIters >= 0);
            pathBridgeMaxIters_ = maxIters;
        }

        public void setModelBudgetForTest(Duration budget) {
            assert(budget >= Duration.zero);
            modelBudget_ = budget;
        }

        public void setToolHandlesBudgetForTest(Duration budget) {
            assert(budget >= Duration.zero);
            toolHandlesBudget_ = budget;
        }

        public void setFrameCountsBudgetForTest(Duration budget) {
            assert(budget >= Duration.zero);
            frameCountsBudget_ = budget;
        }

        public auto frameCountsBridgeForTest() {
            return frameCountsBridge;
        }

        public size_t frameCountsClaimPendingForTest() {
            return frameCountsBridge.claimPendingForTest();
        }

        public auto modelBridgeForTest() {
            return modelBridge;
        }

        public bool pathPendingForTest() {
            return pathBridge.legacyPendingForTest();
        }

        public bool subpatchHoldPendingForTest() {
            return subpatchHoldBridge.legacyPendingForTest();
        }

        public HttpResponse handleRequestForTest(string method, string path,
                                                 string body_ = "") {
            auto request = new HttpRequest(method, path, "HTTP/1.1");
            request.body = body_;
            return handleRequest(request);
        }

        public HttpResponse handleRequestWithContextForTest(
                string method, string path, HttpRequestContext carried) {
            auto request = new HttpRequest(method, path, "HTTP/1.1");
            request.context = carried;
            return handleRequest(request);
        }

        public bool singleThreadedChannelForTest() const nothrow {
            return inSingleThreadedChannel();
        }

        public void setFramesBudgetForTest(Duration budget) {
            assert(budget >= Duration.zero);
            framesBudget_ = budget;
        }

        public auto framesBridgeForTest() {
            return framesBridge;
        }

        public auto modelOwnedTraceForTest() {
            return modelBridge.ownedTraceForTest();
        }

        public auto toolHandlesOwnedTraceForTest() {
            return toolHandlesBridge.ownedTraceForTest();
        }

        public auto selectionOwnedTraceForTest() {
            return selectionBridge.ownedTraceForTest();
        }

        public auto toolStateOwnedTraceForTest() {
            return toolStateBridge.ownedTraceForTest();
        }

        public auto layersOwnedTraceForTest() {
            return layersBridge.ownedTraceForTest();
        }

        public auto historyOwnedTraceForTest() {
            return historyBridge.ownedTraceForTest();
        }

        public auto undoStatusOwnedTraceForTest() {
            return undoStatusBridge.ownedTraceForTest();
        }

        public auto replayOwnedTraceForTest() {
            return replayBridge.ownedTraceForTest();
        }

        public auto playEventsOwnedTraceForTest() {
            return playEventsBridge.ownedTraceForTest();
        }

        public size_t selectionOwnedPendingForTest() {
            return selectionBridge.ownedPendingForTest();
        }

        public size_t modelOwnedPendingForTest() {
            return modelBridge.ownedPendingForTest();
        }

        public size_t toolHandlesOwnedPendingForTest() {
            return toolHandlesBridge.ownedPendingForTest();
        }

        public size_t toolStateOwnedPendingForTest() {
            return toolStateBridge.ownedPendingForTest();
        }

        public size_t layersOwnedPendingForTest() {
            return layersBridge.ownedPendingForTest();
        }

        public size_t historyOwnedPendingForTest() {
            return historyBridge.ownedPendingForTest();
        }

        public size_t undoStatusOwnedPendingForTest() {
            return undoStatusBridge.ownedPendingForTest();
        }

        public size_t replayOwnedPendingForTest() {
            return replayBridge.ownedPendingForTest();
        }

        public bool historyProviderPresentForTest() const {
            return historyProvider !is null;
        }

        public bool undoStatusProviderPresentForTest() const {
            return undoStatusProvider !is null;
        }

        public bool replayProviderPresentForTest() const {
            return replayProvider !is null;
        }

        public bool commandPendingForTest() {
            return commandBridge.legacyPendingForTest();
        }

        public bool commandResultSinkActiveForTest() const {
            return commandResultSink_ !is null;
        }

        public void installCommandResultSinkForTest(ref string result) {
            commandResultSink_ = &result;
        }

        public void clearCommandResultSinkForTest() {
            commandResultSink_ = null;
        }

        public void setReplayBudgetForTest(Duration budget) {
            assert(budget >= Duration.zero);
            replayBudget_ = budget;
        }

        public void setUndoStatusBudgetForTest(Duration budget) {
            assert(budget >= Duration.zero);
            undoStatusBudget_ = budget;
        }

        public void setToolStateBudgetForTest(Duration budget) {
            assert(budget >= Duration.zero);
            toolStateBudget_ = budget;
        }

        public void setPlayEventsBudgetForTest(Duration budget) {
            assert(budget >= Duration.zero);
            playEventsBudget_ = budget;
        }

        public size_t playEventsOwnedPendingForTest() {
            return playEventsBridge.ownedPendingForTest();
        }

        public size_t playEventsStatusOwnedPendingForTest() {
            return playEventsStatusBridge.ownedPendingForTest();
        }

        public void holdPlayEventsOwnedWaitForTest(bool held) {
            playEventsBridge.holdOwnedWaitForTest(held);
        }

        public bool playEventsOwnedWaitReachedForTest() {
            return playEventsBridge.ownedWaitReachedForTest();
        }

        public MonoTime playEventsOwnedDeadlineForTest() {
            return playEventsBridge.ownedDeadlineForTest();
        }

        public auto playbackStatusForTest() const {
            return settledPlaybackStatus();
        }

        public auto playbackViewportForTest() const {
            return playbackController.recordedViewport();
        }

        public size_t playbackParseThreadForTest() const {
            return playbackController.parseThreadForTest();
        }

        public size_t playbackParseCallsForTest() const {
            return playbackController.parseCallsForTest();
        }

        public size_t playbackAcceptThreadForTest() const {
            return playbackController.acceptThreadForTest();
        }

        public size_t playbackAcceptCallsForTest() const {
            return playbackController.acceptCallsForTest();
        }

        public void wakeToolStateOwnedWaiterForTest() {
            toolStateBridge.wakeOwnedWaiterForTest();
        }

        public void holdSelectionOwnedWaitForTest(bool held) {
            selectionBridge.holdOwnedWaitForTest(held);
        }

        public bool selectionOwnedWaitReachedForTest() {
            return selectionBridge.ownedWaitReachedForTest();
        }

        public long selectionOwnedConditionWaitsForTest() {
            return selectionBridge.ownedConditionWaitsForTest();
        }

        public long selectionOwnedConditionReturnsForTest() {
            return selectionBridge.ownedConditionReturnsForTest();
        }

        public void wakeSelectionOwnedWaiterForTest() {
            selectionBridge.wakeOwnedWaiterForTest();
        }

        public void suppressSelectionOwnedCompletionNotifyForTest(bool suppress) {
            selectionBridge.suppressOwnedCompletionNotifyForTest(suppress);
        }

        public size_t toolHandlesBridgeTickIndexForTest() const {
            foreach (i, bridge; bridges)
                if (bridge is toolHandlesBridge) return i;
            return size_t.max;
        }

        public size_t toolStateBridgeTickIndexForTest() const {
            foreach (i, bridge; bridges)
                if (bridge is toolStateBridge) return i;
            return size_t.max;
        }

        public size_t commandBridgeTickIndexForTest() const {
            foreach (i, bridge; bridges)
                if (bridge is commandBridge) return i;
            return size_t.max;
        }
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

    /// GET /api/mesh/planes — the plane-complete readback (task 1903 §6.3).
    public void setMeshPlanesProvider(MeshPlanesProvider provider) {
        this.meshPlanesProvider = provider;
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

    public void setSubpatchHoldAction(SubpatchHoldAction action) {
        this.subpatchHoldAction = action;
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
    /// `target=frame` (task 4620) instead reads the already-submitted default
    /// backbuffer so tests can witness ImGui panel drawing from pixels.
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

    public void setTestMode(bool enabled) {
        serverContext_.testMode = enabled;
    }

    /// Enable fast-forward replay on the HTTP-driven event player (--perf
    /// mode). EventPlayer.begin() preserves this flag across /api/play-events
    /// requests, so it only needs setting once at startup.
    public void setPlayerFastForward(bool enabled) {
        playbackController.setFastForward(enabled);
    }

    public int  playerMouseX()    const { return playbackController.mouseX(); }
    public int  playerMouseY()    const { return playbackController.mouseY(); }
    public bool playerMouseDown() const { return playbackController.mouseDown(); }

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
     * The handler receives the invocation's continuous-interaction bit and
     * should throw on protocol failure; the message is forwarded to the client.
     */
    public void setCommandHandler(CommandHandler handler) {
        this.commandHandler = handler;
    }

    /// Task 1520 — the UI-origin adapter, used only by
    /// `POST /api/command?origin=ui` (rejected outside `--test`). It must
    /// dispatch through the application command binding with UI origin, the
    /// same policy the panel delegates use.
    public void setUiCommandHandler(CommandHandler handler) {
        this.uiCommandHandler = handler;
    }

    /**
     * Stash a forms-engine query (`?` read-back) result. Task 5820 routes an
     * active execution into its scoped result owner; outside that port the
     * legacy command response remains the named command-lifetime remainder.
     * The fallback is not a claim that the legacy command race is fixed.
     */
    public void setCmdResult(string json) {
        if (commandResultSink_ !is null)
            *commandResultSink_ = json;
        else
            commandBridge.resp.result = json;
    }

    /**
     * Set the test-only layer-injection handler (POST /api/test/layer). Same
     * synchronous main-thread dispatch as the other mutation bridges. See the
     * `injectLayerHandler` field doc comment for the full rationale.
     */
    public void setInjectLayerHandler(InjectLayerHandler handler) {
        this.injectLayerHandler = handler;
    }

    /// /api/history/jump (Phase 2 of the history-panel design doc)
    /// — multi-step jump. `target` is the desired undoStack length after
    /// the walk. Runs on main thread via the same sync bridge as undo/redo.
    public void setJumpHandler(JumpHandler handler) { this.jumpHandler = handler; }

    /** Set the /api/history JSON provider, invoked by its main-thread bridge. */
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

    /** Set the POST /api/trace/disarm handler used at test-session boundaries. */
    public void setTraceDisarmHandler(TraceResetHandler handler) {
        this.traceDisarmHandler = handler;
    }

    /**
     * Set the /api/undo/status JSON provider. The complete read-only encoder
     * runs from undoStatusBridge on the main thread (task 5820).
     */
    public void setUndoStatusProvider(UndoStatusProvider provider) {
        this.undoStatusProvider = provider;
    }

    /**
     * Set the replay provider — returns the canonical argstring line for
     * undoStack[index], or "" when the index is out of range. replayBridge
     * calls it on the main thread immediately before synchronous dispatch.
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
     * The ONE "not ready" answer this server ever gives (task 1740).
     *
     * 503 rather than a 200 carrying an error body, because the caller that
     * has to act on it is a machine: a readiness probe must be able to tell
     * "keep waiting" from "this is a refusal" WITHOUT parsing a body, and the
     * failure that produced this task was exactly a probe that could not.
     * `Retry-After: 0` states the retry is immediate — startup, not backoff.
     *
     * The body names the state rather than the missing slot, on purpose: a
     * body that said which provider was absent would invite callers to match
     * on THAT, and the whole point is that there is one thing to look at.
     */
    private static void respondNotReady(HttpResponse response) {
        response.statusCode = 503;
        response.headers["Retry-After"] = "0";
        response.headers["Content-Type"] = "application/json";
        response.body = `{"status":"starting","message":"the editor is still `
                      ~ `wiring its HTTP providers — retry"}`;
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
        request.context = serverContext_;
        HttpResponse response = new HttpResponse();

        // Task 1740 — the readiness gate. Scoped to `/api/*` deliberately:
        // the static index page is not a claim about application state, and
        // gating it would make "is anything alive on this port" unanswerable,
        // which is the one question the 503 exists to keep answerable.
        if (!ready() && request.path.startsWith("/api/")) {
            respondNotReady(response);
            return response;
        }

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
                       "<li>/api/mesh/planes - GET (--test only) every parallel plane of the active mesh, edge planes keyed by endpoint pair</li>" ~
                       "<li>/api/command - Execute one command (JSON {\"id\":...\"params\":...} OR argstring \"name arg:val ...\")</li>" ~
                       "<li>/api/gc/commands - GC bytes/collections/max pause for the last command (--test only)</li>" ~
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
            // Each GET owns its layer request and result through a
            // late service completion. The real-route isolation evidence is
            // tests.unit.model_handles_owned_transport_test.
            ModelReq bridgeRequest = ModelReq.init;
            bridgeRequest.layer = parseQueryInt(request.path, "layer", -1);
            bridgeRequest.detailed = (detailedModelDataProvider !is null);
            ModelResp initialResult = ModelResp.init;
            initialResult.result = "";
            initialResult.error = "";
            ModelResp timeoutResult = ModelResp.init;
            timeoutResult.result = "";
            timeoutResult.error = "timeout waiting for main thread";
            ModelResp stoppingResult = ModelResp.init;
            stoppingResult.result = "";
            stoppingResult.error = "timeout waiting for main thread";
            auto owned = modelBridge.submitOwned(
                bridgeRequest, initialResult, timeoutResult, stoppingResult,
                modelBudget_);
            if (owned.result.error.length == 0) {
                response.statusCode = 200;
                response.body = owned.result.result;
            } else {
                response.statusCode = 500;
                response.body = "{\"error\": \"Failed to retrieve model data\", \"message\": \""
                               ~ jsonEsc(owned.result.error) ~ "\"}";
            }
        }
    }

    private void route_apiSelection(HttpRequest request, HttpResponse response) {
        // Task 0950 item F — the provider walks Document.layers and resolves
        // the active mesh, so the bytes are produced by selectionBridge's
        // service body on the main thread. The real-HTTP thread-identity and
        // prepared-shadow cells live in tests.unit.selection_projection_test.
        response.headers["Content-Type"] = "application/json";
        if (selectionDataProvider !is null) {
            SelectionReq bridgeRequest = SelectionReq.init;
            SelectionResp initialResult = SelectionResp.init;
            initialResult.result = "";
            initialResult.error = "";
            SelectionResp timeoutResult = SelectionResp.init;
            timeoutResult.result = "";
            timeoutResult.error = "timeout waiting for main thread";
            SelectionResp stoppingResult = SelectionResp.init;
            stoppingResult.result = "";
            stoppingResult.error = "HTTP server stopping";
            immutable budget = (selectionBridgeMaxIters_ * 2L).msecs;
            auto owned = selectionBridge.submitOwned(
                bridgeRequest, initialResult, timeoutResult, stoppingResult,
                budget);
            if (owned.result.error.length == 0) {
                response.statusCode = 200;
                response.body = owned.result.result;
            } else {
                response.statusCode = 500;
                response.body = "{\"error\": \"Failed to retrieve selection data\", \"message\": \"" ~
                               jsonEsc(owned.result.error) ~ "\"}";
            }
        } else {
            response.statusCode = 500;
            response.body = "{\"error\": \"Selection data provider not set\"}";
        }
    }

    private void route_apiToolHandles(HttpRequest request, HttpResponse response) {
        // The owned GET cannot share result storage with a timed-out
        // call and retains the bridge phase documented at its declaration.
        // Evidence: tests.unit.model_handles_owned_transport_test.
        response.headers["Content-Type"] = "application/json";
        if (toolHandlesDataProvider is null) {
            // Preserve the pre-marshaling null-provider contract exactly:
            // 200 {"handles":null}, decided on the HTTP thread BEFORE ever
            // touching the bridge.
            response.statusCode = 200;
            response.body = `{"handles":null}`;
        } else {
            ToolHandlesReq bridgeRequest = ToolHandlesReq.init;
            ToolHandlesResp initialResult = ToolHandlesResp.init;
            initialResult.result = "";
            initialResult.error = "";
            ToolHandlesResp timeoutResult = ToolHandlesResp.init;
            timeoutResult.result = "";
            timeoutResult.error = "timeout waiting for main thread";
            ToolHandlesResp stoppingResult = ToolHandlesResp.init;
            stoppingResult.result = "";
            stoppingResult.error = "timeout waiting for main thread";
            auto owned = toolHandlesBridge.submitOwned(
                bridgeRequest, initialResult, timeoutResult, stoppingResult,
                toolHandlesBudget_);
            if (owned.result.error.length == 0) {
                response.statusCode = 200;
                response.body = owned.result.result;
            } else {
                response.statusCode = 500;
                response.body = "{\"error\": \"Failed to retrieve tool handles\", \"message\": \"" ~
                               jsonEsc(owned.result.error) ~ "\"}";
            }
        }
    }

    private void route_apiToolState(HttpRequest request, HttpResponse response) {
        // Task 5940: the owned service reads the live slot on the main thread
        // during tickAll, without waiting for a later tool update or draw.
        response.headers["Content-Type"] = "application/json";
        if (toolStateDataProvider is null) {
            response.statusCode = 200;
            response.body = `{}`;
        } else {
            auto owned = toolStateBridge.submitOwned(
                ToolStateReq.init,
                ToolStateResp("", "", false),
                ToolStateResp("", "timeout waiting for main thread", true),
                ToolStateResp("", "HTTP server stopping", true),
                toolStateBudget_);
            if (!owned.result.failed && owned.result.error.length == 0) {
                response.statusCode = 200;
                response.body = owned.result.result;
            } else {
                response.statusCode = 500;
                response.body = "{\"error\": \"Failed to retrieve tool state\", \"message\": \"" ~
                               jsonEsc(owned.result.error) ~ "\"}";
            }
        }
    }

    private PortlessJsonResp awaitPortlessJson(
            MainThreadBridge!(PortlessJsonReq, PortlessJsonResp) bridge) {
        return bridge.submitOwned(
            PortlessJsonReq.init, PortlessJsonResp.init,
            PortlessJsonResp("", "timeout waiting for main thread"),
            PortlessJsonResp("", "HTTP server stopping"),
            portlessRouteBudget_).result;
    }

    private void route_apiToolDisarm(HttpRequest request, HttpResponse response) {
        response.headers["Content-Type"] = "application/json";
        auto result = awaitPortlessJson(toolDisarmBridge);
        if (result.error.length == 0) {
            response.statusCode = 200;
            response.body = result.result;
        } else {
            response.statusCode = 500;
            response.body = "{\"error\":\"tool disarm read failed\",\"message\":\"" ~
                            jsonEsc(result.error) ~ "\"}";
        }
    }

    private void route_apiUiPolicy(HttpRequest request, HttpResponse response) {
        // Task 1520/1521 — what the UI policy did with the last user-origin
        // command line: the guard verdict, whether the prompt was suppressed
        // (`--test`), whether the command refused, and the notice text the
        // user would have been shown.
        //
        // The JSON builder is application-owned; this route only transports
        // its main-thread snapshot through the endpoint's dedicated bridge.
        response.headers["Content-Type"] = "application/json";
        auto result = awaitPortlessJson(uiPolicyBridge);
        if (result.error.length == 0) {
            response.statusCode = 200;
            response.body = result.result;
        } else {
            response.statusCode = 500;
            response.body = "{\"error\":\"" ~ jsonEsc(result.error) ~ "\"}";
        }
    }

    private void route_apiToolpropsIds(HttpRequest request, HttpResponse response) {
        // Task 0640 — the ImGui id namespace of the last Tool Properties
        // column drawn: one entry per section header and two per row (the
        // widget's id, and a probe of the row's id-stack seed).
        //
        // Empty `items` is the honest answer when the panel has not drawn
        // (hidden by default under --test until `ui.toolProperties show`),
        // when it is collapsed, or in a non-test run where nothing records.
        response.headers["Content-Type"] = "application/json";
        auto result = awaitPortlessJson(toolpropsIdsBridge);
        if (result.error.length == 0) {
            response.statusCode = 200;
            response.body = result.result;
        } else {
            response.statusCode = 500;
            response.body = "{\"error\": \"Failed to retrieve tool props ids\", \"message\": \"" ~
                           jsonEsc(result.error) ~ "\"}";
        }
    }

    private void route_apiButtonsAvailability(HttpRequest request, HttpResponse response) {
        // Task 0669 — every button the last complete frame drew, with the
        // `disabled` flag and the reason it was drawn WITH. This is the
        // rendered fact, not a re-computation: a test that asked the
        // availability resolver again would prove the resolver and say
        // nothing about whether the buttons still call it.
        //
        // Empty `buttons` is the honest answer before the first frame and
        // in a non-`--test` run, where nothing records.
        response.headers["Content-Type"] = "application/json";
        auto result = awaitPortlessJson(buttonAvailabilityBridge);
        if (result.error.length == 0) {
            response.statusCode = 200;
            response.body = result.result;
        } else {
            response.statusCode = 500;
            response.body = "{\"error\": \"Failed to retrieve button availability\", \"message\": \"" ~
                           jsonEsc(result.error) ~ "\"}";
        }
    }

    private void route_apiInputContext(HttpRequest request, HttpResponse response) {
        // Task 1810 — GET /api/input/context[?x=&y=][&key=<canon>]
        //
        // What the keyboard router would see right now: the zone under the
        // cursor (or under the given point), the selection type, the armed
        // tool, every zone rectangle of the last complete frame, and — when a
        // `key` is given — WHICH BINDING WINS and by what weight.
        //
        // The last part is the reason this route exists at all. A scoped
        // binding that resolves to the wrong row and one that resolves to
        // nothing are indistinguishable from their effects: in both cases the
        // expected thing did not happen. Without a readback, a test can pin
        // the effect and still be blind to the rule that produced it.
        //
        response.headers["Content-Type"] = "application/json";
        try {
            // Sentinel-based "was it given": the query helpers take a default,
            // and (0,0) is a legitimate pixel — so a missing x/y must not be
            // mistaken for the top-left corner, which is inside the tab strip.
            immutable int px = parseQueryInt(request.path, "x", int.min);
            immutable int py = parseQueryInt(request.path, "y", int.min);
            immutable bool havePoint = (px != int.min && py != int.min);
            immutable string canon = parseQueryString(request.path, "key", "");
            auto owned = inputContextBridge.submitOwned(
                InputContextReq(havePoint, havePoint ? px : 0,
                                havePoint ? py : 0, canon),
                InputContextResp.init,
                InputContextResp("", "timeout waiting for main thread"),
                InputContextResp("", "HTTP server stopping"),
                portlessRouteBudget_);
            if (owned.result.error.length == 0) {
                response.statusCode = 200;
                response.body = owned.result.result;
            } else {
                response.statusCode = 500;
                response.body = "{\"error\": \"Failed to resolve input context\", \"message\": \"" ~
                               jsonEsc(owned.result.error) ~ "\"}";
            }
        } catch (Exception e) {
            response.statusCode = 500;
            response.body = "{\"error\": \"Failed to resolve input context\", \"message\": \"" ~
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
        auto result = awaitPortlessJson(statsBridge);
        if (result.error.length == 0) {
            response.statusCode = 200;
            response.body = result.result;
        } else {
            response.statusCode = 500;
            response.body = "{\"error\": \"Failed to retrieve stat rows\", \"message\": \"" ~
                           jsonEsc(result.error) ~ "\"}";
        }
    }

    private void route_apiPie(HttpRequest request, HttpResponse response) {
        response.headers["Content-Type"] = "application/json";
        auto result = awaitPortlessJson(pieBridge);
        if (result.error.length == 0) {
            response.statusCode = 200;
            response.body = result.result;
        } else {
            response.statusCode = 500;
            response.body = "{\"error\": \"Failed to retrieve pie frame\", \"message\": \"" ~
                            jsonEsc(result.error) ~ "\"}";
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
            LayersReq bridgeRequest = LayersReq.init;
            LayersResp initialResult = LayersResp.init;
            initialResult.result = "";
            initialResult.error = "";
            LayersResp timeoutResult = LayersResp.init;
            timeoutResult.result = "";
            timeoutResult.error = "timeout waiting for main thread";
            LayersResp stoppingResult = LayersResp.init;
            stoppingResult.result = "";
            stoppingResult.error = "HTTP server stopping";
            auto owned = layersBridge.submitOwned(
                bridgeRequest, initialResult, timeoutResult, stoppingResult,
                5.seconds);
            if (owned.result.error.length == 0) {
                response.statusCode = 200;
                response.body = owned.result.result;
            } else {
                response.statusCode = 500;
                response.body = "{\"error\": \"Failed to retrieve layers\", \"message\": \"" ~
                               jsonEsc(owned.result.error) ~ "\"}";
            }
        }
    }

    private void route_apiPerfReset(HttpRequest request, HttpResponse response) {
        // The bridge adds one frame of latency before the perf lane's first
        // measured sample.
        response.headers["Content-Type"] = "application/json";
        auto owned = perfResetBridge.submitOwned(
            PerfResetReq.init, PerfResetResp.init,
            PerfResetResp("timeout waiting for main thread"),
            PerfResetResp("HTTP server stopping"),
            portlessRouteBudget_);
        if (owned.result.error.length == 0) {
            response.statusCode = 200;
            response.body = "{\"status\":\"ok\"}";
        } else {
            response.statusCode = 500;
            response.body = "{\"error\":\"perf probe reset failed\",\"message\":\"" ~
                            jsonEsc(owned.result.error) ~ "\"}";
        }
    }

    private void route_apiPerf(HttpRequest request, HttpResponse response) {
        // The application adapter retains the default-build "{}" contract;
        // the server only transports that main-thread result.
        response.headers["Content-Type"] = "application/json";
        auto result = awaitPortlessJson(perfBridge);
        if (result.error.length == 0) {
            response.statusCode = 200;
            response.body = result.result;
        } else {
            response.statusCode = 500;
            response.body = "{\"error\":\"perf probe read failed\",\"message\":\"" ~
                           jsonEsc(result.error) ~ "\"}";
        }
    }

    private void route_apiFramesCountsReset(HttpRequest request, HttpResponse response) {
        response.headers["Content-Type"] = "application/json";
        auto owned = frameCountsBridge.submitClaimed(
            FrameCountsReq(FrameCountsOp.reset), frameCountsBudget_);
        final switch (owned.kind) {
        case BridgeResultKind.completed:
            response.statusCode = 200;
            response.body = "{\"status\":\"ok\"}";
            break;
        case BridgeResultKind.ownerUnavailable:
            response.statusCode = 503;
            response.body = "{\"error\":\"frame-count owner unavailable\"}";
            break;
        case BridgeResultKind.timedOut:
            response.statusCode = 504;
            response.body = "{\"error\":\"timeout waiting for main thread\"}";
            break;
        case BridgeResultKind.stopping:
            response.statusCode = 503;
            response.body = "{\"error\":\"HTTP server stopping\"}";
            break;
        case BridgeResultKind.failed:
        case BridgeResultKind.submitted:
            response.statusCode = 500;
            response.body = "{\"error\":\"frame-count owner failed\"}";
            break;
        }
    }

    private void route_apiFramesCounts(HttpRequest request, HttpResponse response) {
        // Per-frame WORK COUNTS: draw submissions and submitted vertices
        // per pass, cells considered/rendered, GPU uploads, mesh-change
        // deliveries seen this frame, pipeline + operator evaluations, and
        // main-thread GC
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
        // Task 6357: the owner snapshots between frames; this thread only
        // serializes the detached value. Pending has a five-second deadline,
        // while a claimed operation waits for its actual owner outcome.
        response.headers["Content-Type"] = "application/json";
        auto owned = frameCountsBridge.submitClaimed(
            FrameCountsReq(FrameCountsOp.read), frameCountsBudget_);
        final switch (owned.kind) {
        case BridgeResultKind.completed:
          try {
            response.statusCode = 200;
            response.body = owned.result.snapshot.toJson();
          } catch (Exception e) {
            response.statusCode = 500;
            response.body = "{\"error\":\"frame-count probe read failed\",\"message\":\"" ~
                           jsonEsc(e.msg) ~ "\"}";
          }
          break;
        case BridgeResultKind.ownerUnavailable:
            response.statusCode = 503;
            response.body = "{\"error\":\"frame-count owner unavailable\"}";
            break;
        case BridgeResultKind.timedOut:
            response.statusCode = 504;
            response.body = "{\"error\":\"timeout waiting for main thread\"}";
            break;
        case BridgeResultKind.stopping:
            response.statusCode = 503;
            response.body = "{\"error\":\"HTTP server stopping\"}";
            break;
        case BridgeResultKind.failed:
        case BridgeResultKind.submitted:
            response.statusCode = 500;
            response.body = "{\"error\":\"frame-count owner failed\"}";
            break;
        }
    }

    private void route_apiFramesReset(HttpRequest request, HttpResponse response) {
        // Task 6511: a perf build asks the owner to reset at the frame
        // boundary; a default build has no live probe and touches no state.
        response.headers["Content-Type"] = "application/json";
        version (PerfProbe) {
            auto owned = framesBridge.submitClaimed(
                FramesReq(FramesOp.reset), framesBudget_);
            final switch (owned.kind) {
            case BridgeResultKind.completed:
                response.statusCode = 200;
                response.body = "{\"status\":\"ok\"}";
                break;
            case BridgeResultKind.ownerUnavailable:
                response.statusCode = 503;
                response.body = "{\"error\":\"frame probe owner unavailable\"}";
                break;
            case BridgeResultKind.timedOut:
                response.statusCode = 504;
                response.body = "{\"error\":\"timeout waiting for main thread\"}";
                break;
            case BridgeResultKind.stopping:
                response.statusCode = 503;
                response.body = "{\"error\":\"HTTP server stopping\"}";
                break;
            case BridgeResultKind.failed:
            case BridgeResultKind.submitted:
                response.statusCode = 500;
                response.body = "{\"error\":\"frame probe owner failed\"}";
                break;
            }
        } else {
            response.statusCode = 200;
            response.body = "{\"status\":\"ok\"}";
        }
    }

    private void route_apiFrames(HttpRequest request, HttpResponse response) {
        // Task 6511: a perf build receives an owner-made detached snapshot;
        // a default build has no live probe and answers immediately.
        response.headers["Content-Type"] = "application/json";
        version (PerfProbe) {
            auto owned = framesBridge.submitClaimed(
                FramesReq(FramesOp.read), framesBudget_);
            final switch (owned.kind) {
            case BridgeResultKind.completed:
                response.statusCode = 200;
                response.body = owned.result.snapshot.toJson();
                break;
            case BridgeResultKind.ownerUnavailable:
                response.statusCode = 503;
                response.body = "{\"error\":\"frame probe owner unavailable\"}";
                break;
            case BridgeResultKind.timedOut:
                response.statusCode = 504;
                response.body = "{\"error\":\"timeout waiting for main thread\"}";
                break;
            case BridgeResultKind.stopping:
                response.statusCode = 503;
                response.body = "{\"error\":\"HTTP server stopping\"}";
                break;
            case BridgeResultKind.failed:
            case BridgeResultKind.submitted:
                response.statusCode = 500;
                response.body = "{\"error\":\"frame probe owner failed\"}";
                break;
            }
        } else {
            response.statusCode = 200;
            response.body = "{}";
        }
    }

    private void route_apiMeshPlanes(HttpRequest request, HttpResponse response) {
        // The plane-complete readback (task 1903 Stage B, plan §6.3). Marshaled
        // onto the main thread — see the provider alias for why — and gated
        // exactly as /api/changes is: this is a test-automation surface whose
        // whole purpose is to freeze a fixture, and it walks the live mesh.
        response.headers["Content-Type"] = "application/json";
        if (!request.context.testMode) {
            response.statusCode = 403;
            response.body = `{"error":"mesh/planes is only available in --test mode"}`;
            return;
        }
        if (meshPlanesProvider is null) {
            response.statusCode = 500;
            response.body = `{"error":"mesh-planes provider not set"}`;
            return;
        }
        // Provenance rides the query string: the capture script knows the SHA
        // it is standing on, the app does not.
        meshPlanesBridge.req.producedBy = parseQueryString(request.path, "producedBy", "");
        meshPlanesBridge.req.path       = parseQueryString(request.path, "path", "");
        meshPlanesBridge.req.family     = parseQueryString(request.path, "family", "");
        meshPlanesBridge.req.stand      = parseQueryString(request.path, "stand", "");
        meshPlanesBridge.resp.result    = "";
        meshPlanesBridge.resp.error     = "";
        if (!meshPlanesBridge.submitAndWait())
            meshPlanesBridge.resp.error = "timeout waiting for main thread";
        if (meshPlanesBridge.resp.error.length == 0) {
            response.statusCode = 200;
            response.body = meshPlanesBridge.resp.result;
        } else {
            response.statusCode = 500;
            response.body = "{\"error\": \"Failed to dump mesh planes\", \"message\": \"" ~
                           jsonEsc(meshPlanesBridge.resp.error) ~ "\"}";
        }
    }

    private void route_apiCacheRebuilds(HttpRequest request, HttpResponse response) {
        // THE REBUILD RATES OF THE EPOCH-KEYED DERIVED CACHES (task 2000).
        //
        // Four caches in this tree are keyed on a `mesh_dirty` watcher and
        // rebuilt lazily at their reader. Every one of them stays CORRECT
        // however often it is rebuilt — a wrong key changes no value anywhere,
        // it only turns a once-per-gesture O(V) walk into a once-per-drag-STEP
        // one. No value assertion in any suite can see that; only a rate can,
        // and this endpoint is where the suite lane reads it.
        //
        // The counters are `__gshared`, monotone and NEVER RESET: a test reads
        // them as a DELTA across a step, exactly as `/api/changes`'s bus
        // counters are read (the runner resets app state between test
        // binaries, not these). `Answered.httpThread` and unsynchronised for
        // the same reason `/api/perf`'s integers are: plain scalars written on
        // the main thread, read as a diagnostic.
        //
        // NOT `/api/perf`: that probe is compiled out of every build but
        // `perf`, so the suite lane would read `{}` from it. The `perf`-build
        // twins of the first two rows are `perf_probe.Cat.snapGridBuild` and
        // `Cat.symPairingRebuild`, which is what the perf harness reads.
        response.headers["Content-Type"] = "application/json";
        if (!request.context.testMode) {
            response.statusCode = 403;
            response.body = `{"error":"cache/rebuilds is only available in --test mode"}`;
            return;
        }
        import snap                      : g_snapGridBuilds;
        import toolpipe.stages.symmetry  : g_symPairingRebuilds;
        import toolpipe.stages.actcenter : g_acenClusterRebuilds,
                                            g_acenBboxMembershipRebuilds;
        import toolpipe.stages.falloff   : g_falloffSelWeightRebuilds;
        import std.format : format;
        response.statusCode = 200;
        response.body = format(
            `{"snapGridBuilds":%d,"symmetryPairingRebuilds":%d,` ~
            `"acenClusterRebuilds":%d,"falloffSelWeightRebuilds":%d,` ~
            `"acenBboxMembershipRebuilds":%d}`,
            g_snapGridBuilds, g_symPairingRebuilds,
            g_acenClusterRebuilds, g_falloffSelWeightRebuilds,
            g_acenBboxMembershipRebuilds);
    }

    private void route_apiGcCommands(HttpRequest request, HttpResponse response) {
        // WHAT ONE COMMAND COST THE COLLECTOR (task 2070).
        //
        // Bytes allocated, collections triggered, and the worst single
        // stop-the-world pause, bracketed around the command bridge's
        // dispatch ON THE MAIN LOOP (see the bracket's own comment in the
        // ctor for why the thread matters and why the route is the wrong
        // place to sample).
        //
        // NOT `/api/perf`, for the same reason `/api/cache/rebuilds` is not:
        // `PerfProbe` is compiled out of every build but `perf`, so the suite
        // lane would read `{}`. `CommandGcProbe` is always compiled, so the
        // default gate can witness it.
        //
        // The running totals are monotone and NEVER RESET — read as a DELTA
        // across a step, exactly like `/api/changes` and
        // `/api/cache/rebuilds`. The `last*` fields are the MOST RECENT
        // command's own figures, which is what a per-case harness column
        // wants; `commands` is the anti-vacuity check that a bracket fired
        // at all, because a dead instrument and a genuinely free command
        // both read zero bytes.
        //
        // `Answered.httpThread` and unsynchronised on the same diagnostic
        // contract as `/api/perf`: plain scalars, single main-thread writer.
        response.headers["Content-Type"] = "application/json";
        if (!request.context.testMode) {
            response.statusCode = 403;
            response.body = `{"error":"gc/commands is only available in --test mode"}`;
            return;
        }
        import perf_probe : g_commandGc;
        response.statusCode = 200;
        response.body = g_commandGc.toJson();
    }

    private void route_apiChanges(HttpRequest request, HttpResponse response) {
        // recorded remainder (1906 §3.5 row 27, §1.8): the BUS COUNTERS own this
        // endpoint and it must stay that way. It is `Answered.httpThread`, and
        // `mesh_dirty.g_displayEpochs` / `g_geomEpochs` / `g_topoEpochs` are
        // main-thread-only, unsynchronised, and mutated from inside a live mesh
        // edit — reading one from here would be a data race, not a diagnostic:
        // each is a SCANNED ARRAY (`kSlots` address/epoch pairs), and a read
        // racing a mid-scan write from the main thread could see a torn slot.
        //
        // TASK 1932 (stage 4) EXTENDS THIS ROUTE WITH FOUR PLAIN SCALARS FROM
        // THE SAME MODULE, and that is NOT an exception to the paragraph
        // above — it is the SAME contract the bus counters already have.
        // `meshDirtySlotCeiling()` / `meshBirthSlotCeiling()` are compile-time
        // constants wrapped in a function (never written after process start,
        // so there is nothing to race); `meshBirthsRecorded()` and
        // `g_bgGpuUploads` are flat, monotone `ulong` counters, bumped from the
        // main thread and read here exactly like `changeBus.deliveryCount` —
        // scalar, monotone, read as a DELTA across a step, same as every
        // other counter on this route. What stays off this route is the
        // SCANNED tables themselves (`g_displayEpochs` etc.) — a consumer
        // needs an epoch compare, and reading a torn one here would be worse
        // than not answering.
        //
        // The plain integers below are safe for the same reason /api/perf's are:
        // scalar, monotone, read as DELTAS across a step. Stage 0 extended the
        // field list; the SHAPE (one whole-struct snapshot, then serialise) is
        // unchanged: one copy, then serialise, which NARROWS the window in
        // which a mid-format flush could mix two flushes but does not close
        // it — a struct copy is not atomic and this thread takes no lock.
        //
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
        if (!request.context.testMode) {
            response.statusCode = 403;
            response.body = `{"error":"changes is only available in --test mode"}`;
        } else {
            import change_bus : changeBus, regradeCensusChecks,
                                regradeCensusArmedChecks,
                                regradeCensusDisagreements;
            import seltype    : selTypeToken;
            import std.format : format;
            // TASK 1932 (stage 4) — the slot-ceiling instruments; see the
            // route's own comment above for why these four are safe to read
            // here when the SCANNED tables beside them are not.
            import mesh_dirty : meshDirtySlotCeiling, meshBirthSlotCeiling,
                                meshBirthsRecorded, g_bgGpuUploads;
            const snap = changeBus;
            response.statusCode = 200;
            response.body = format(
                `{"flushCount":%d,"lastSelDomains":%d,` ~
                `"lastLayerKinds":%d,` ~
                `"totalPosition":%d,"totalPoints":%d,"totalPolygons":%d,` ~
                `"totalMarks":%d,"totalMaterial":%d,` ~
                `"totalSelVertex":%d,"totalSelEdge":%d,"totalSelFace":%d,` ~
                `"totalSelItem":%d,` ~
                `"totalLayerAdded":%d,"totalLayerRemoved":%d,` ~
                `"totalLayerReordered":%d,"totalLayerRenamed":%d,` ~
                `"totalLayerVisible":%d,` ~
                `"totalLayerActive":%d,` ~
                `"missedPublishers":%d,"confinedCloseImbalance":%d,` ~
                `"nestedBatchOpens":%d,"unbatchedGeometryCommits":%d,` ~
                `"hideDerivesDeferred":%d,` ~
                `"batchUpgradeRefusals":%d,"opLogEntriesRecorded":%d,` ~
                `"batchLeaks":%d,"emptyDeltaOverMutation":%d,` ~
                `"mapDeltaMixRecorded":%d,"mapDeltaMixRefused":%d,` ~
                `"mapDeltaBindRefused":%d,` ~
                `"deliveryCount":%d,` ~
                `"lastDeliveryFlags":%d,"lastDeliverySelDomains":%d,` ~
                `"regradeCensusChecks":%d,` ~
                `"regradeCensusArmedChecks":%d,` ~
                `"regradeCensusDisagreements":%d,` ~
                `"currentTypeChanged":%d,"lastCurrentType":"%s",` ~
                // Task 1932 stage 4 — R3-2: all four fields the suite-tier
                // stand reads, so the endpoint and the reader agree.
                `"meshDirtySlotCeiling":%d,"meshBirthSlotCeiling":%d,` ~
                `"meshBirthsRecorded":%d,"bgGpuUploads":%d}`,
                snap.flushCount,
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
                snap.missedPublishers, snap.confinedCloseImbalance,
                // Task 1903 §5.8 — the mesh-edit seam counters. Serialised
                // from the SAME `snap` copy as everything else on this route,
                // which is why they live on the bus and not module-level in
                // `mesh.d`.
                snap.nestedBatchOpens, snap.unbatchedGeometryCommits,
                // Task 1903 Stage O — the hide-derive pair's witness. Same
                // `snap` copy as its neighbours, for the same reason.
                snap.hideDerivesDeferred,
                snap.batchUpgradeRefusals, snap.opLogEntriesRecorded,
                snap.batchLeaks,
                // Task 1903 Stage L3-a (ruling Q-K6) — a BACKSTOP, not a fix.
                // A recording batch that closed empty over a kernel which
                // reported work done. Asserted 0 by the suite; its natural
                // reachability was measured (every kernel on the delete /
                // remove paths has an explicit publisher) and its only known
                // driver is a deliberate unit cell.
                snap.emptyDeltaOverMutation,
                // Task 1903 Stage L1-P1 — the map-value delta counters. All
                // three are asserted 0 as a DELTA across a step (they are
                // process-cumulative), and each is driven non-zero by its own
                // unit cell so the zero can tell "never refused" from "never
                // ran".
                snap.mapDeltaMixRecorded, snap.mapDeltaMixRefused,
                snap.mapDeltaBindRefused,
                // Task 1906 stage 0 — the SYNCHRONOUS delivery boundary, as a
                // counter. `deliveryCount` is what the per-command census and
                // the delivery-granularity test read. `flushCount` beside it
                // counts the DOCUMENT-level flush (layer kinds, item selection,
                // current type) — since stage 3 a mesh edit does not move it at
                // all, and `lastFlushFlags` is gone from this payload rather
                // than left reading 0 (see change_bus.flush).
                //
                // `lastDeliverySubject` is NOT published (review NIT). It is a
                // raw heap address: it discloses the process's layout, it is
                // different on every run so no test can assert a value, and the
                // only useful question over the wire — "WHICH layer changed" —
                // needs a stable index this endpoint has no `Document` to
                // resolve. The field stays on the bus for the unit blocks that
                // assert identity against `&mesh`; it gets a wire form in stage
                // 2, when a consumer keys on the subject and there is something
                // to key.
                snap.deliveryCount,
                snap.lastDeliveryFlags, snap.lastDeliverySelDomains,
                // Task 1906 stage 1 — the re-grade DECOUPLING CENSUS (§2.3).
                // Module-level `__gshared` in `change_bus`, NOT fields of the
                // bus, so they are deliberately read LIVE here rather than
                // from `snap`: nothing asserts they agree with any field in
                // the snapshot, and a census counter that lagged a whole
                // response would be reporting the wrong step's verdict.
                // `regradeCensusDisagreements` is the finding — a non-zero
                // means the guard's `mutationVersion` term is NOT equivalent
                // to `CommandHistory.undoEpoch()` and open question #21 keeps
                // its recorded remainder; `regradeCensusArmedChecks` beside it
                // is what says the census ran WHERE IT COULD HAVE DISAGREED (a
                // zero there makes the other zero meaningless, and the plain
                // `regradeCensusChecks` does NOT say it — most rows are
                // disarmed ones, both terms at the `ulong.max` sentinel,
                // scored as agreements they could not have avoided).
                regradeCensusChecks,
                regradeCensusArmedChecks,
                regradeCensusDisagreements,
                snap.currentTypeChanged,
                selTypeToken(snap.lastCurrentType),
                meshDirtySlotCeiling(), meshBirthSlotCeiling(),
                meshBirthsRecorded(), g_bgGpuUploads);
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
            if (!pathBridge.submitAndWait(pathBridgeMaxIters_))
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
        immutable string target =
            parseQueryString(request.path, "target", "");
        if (target.length != 0 && target != "frame") {
            response.statusCode = 400;
            response.body = `{"error":"unknown viewport probe target: `
                          ~ jsonEsc(target) ~ `"}`;
            response.headers["Content-Type"] = "application/json";
            return;
        }
        if (target == "frame" && !request.context.testMode) {
            response.statusCode = 403;
            response.body = `{"error":"target=frame is only available in --test mode"}`;
            response.headers["Content-Type"] = "application/json";
            return;
        }
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
            vpProbeBridge.req.composedFrame = target == "frame";
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
        if (!request.context.testMode) {
            response.statusCode = 403;
            response.body = `{"error":"subpatch hold is --test only"}`;
            return;
        }
        if (subpatchHoldAction is null) {
            response.statusCode = 500;
            response.body = `{"error":"subpatch-hold action not installed"}`;
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

    private void route_apiPlayEventsStatus(HttpRequest request, HttpResponse response) {
        response.headers["Content-Type"] = "application/json";
        auto owned = playEventsStatusBridge.submitOwned(
            PlayEventsStatusReq.init,
            PlayEventsStatusResp("", ""),
            PlayEventsStatusResp("", "timeout waiting for main thread"),
            PlayEventsStatusResp("", "HTTP server stopping"),
            playEventsStatusBudget_);
        if (owned.result.error.length == 0) {
            response.statusCode = 200;
            response.body = owned.result.result;
        } else {
            response.statusCode = 500;
            response.body = `{"error": "Failed to retrieve playback status", "message": "`
                          ~ jsonEsc(owned.result.error) ~ `"}`;
        }
    }

    // Keep test-mode authorization in the transport owner. The play-events
    // body is an extraction boundary for the parser/owner slice, while this
    // request-context decision must stay with HttpServer.
    private void route_apiPlayEvents(HttpRequest request, HttpResponse response) {
        if (!request.context.testMode) {
            response.statusCode = 403;
            response.body = `{"error":"play-events is only available in --test mode"}`;
            response.headers["Content-Type"] = "application/json";
            return;
        }
        servePlayEvents(request, response);
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
        if (!request.context.testMode) {
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

    private void route_apiCommand(HttpRequest request, HttpResponse response) {
        if (commandHandler is null) {
            // Unreachable while the readiness gate in `handleRequest` stands
            // (a null handler means the wiring has not finished, and the gate
            // refuses every `/api/*` route before this one is entered). Kept
            // as the defensive arm it always was, but answering the SAME 503
            // rather than the old `200 {"status":"error","message":"command
            // handler not set"}`: one not-ready shape on the wire, or callers
            // go back to matching bodies. Task 1740.
            respondNotReady(response);
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
                if (wantUi && !request.context.testMode) {
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
            respondNotReady(response);   // task 1740 — see route_apiCommand
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
        // Task 5820 invariant: the ready encoder runs once inside
        // undoStatusBridge's main-thread service, so every depth, predicate and
        // lockout field observes one service state. The owned deadline/error
        // contract matches task 5800; evidence: history_replay_boundary_test.d.
        response.headers["Content-Type"] = "application/json";
        if (undoStatusProvider is null) {
            response.statusCode = 200;
            response.body = `{"state":"invalid","lockout":false,`
                          ~ `"canUndo":false,"canRedo":false}`;
        } else {
            UndoStatusReq bridgeRequest = UndoStatusReq.init;
            UndoStatusResp initialResult = UndoStatusResp.init;
            initialResult.result = "";
            initialResult.error = "";
            UndoStatusResp timeoutResult = UndoStatusResp.init;
            timeoutResult.result = "";
            timeoutResult.error = "timeout waiting for main thread";
            UndoStatusResp stoppingResult = UndoStatusResp.init;
            stoppingResult.result = "";
            stoppingResult.error = "HTTP server stopping";
            auto owned = undoStatusBridge.submitOwned(
                bridgeRequest, initialResult, timeoutResult, stoppingResult,
                undoStatusBudget_);
            if (owned.result.error.length == 0) {
                response.statusCode = 200;
                response.body = owned.result.result;
            } else {
                response.statusCode = 500;
                response.body =
                    `{"error": "Failed to retrieve undo status", "message": "`
                  ~ jsonEsc(owned.result.error) ~ `"}`;
            }
        }
    }

    private void route_apiHistory(HttpRequest request, HttpResponse response) {
        // Task 5800 invariant: the adapter's two stack walks execute only in
        // historyBridge's main-thread service; null remains an immediate 200,
        // while owned timeout/shutdown and caught provider exceptions share
        // the chosen JSON 500 envelope. Evidence: history_http_adapter_test.d.
        response.headers["Content-Type"] = "application/json";
        if (historyProvider is null) {
            response.statusCode = 200;
            response.body = `{"undo":[],"redo":[]}`;
        } else {
            HistoryReq bridgeRequest = HistoryReq.init;
            HistoryResp initialResult = HistoryResp.init;
            initialResult.result = "";
            initialResult.error = "";
            HistoryResp timeoutResult = HistoryResp.init;
            timeoutResult.result = "";
            timeoutResult.error = "timeout waiting for main thread";
            HistoryResp stoppingResult = HistoryResp.init;
            stoppingResult.result = "";
            stoppingResult.error = "HTTP server stopping";
            auto owned = historyBridge.submitOwned(
                bridgeRequest, initialResult, timeoutResult, stoppingResult,
                5.seconds);
            if (owned.result.error.length == 0) {
                response.statusCode = 200;
                response.body = owned.result.result;
            } else {
                response.statusCode = 500;
                response.body = "{\"error\": \"Failed to retrieve history\", \"message\": \""
                              ~ jsonEsc(owned.result.error) ~ "\"}";
            }
        }
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

    private void route_apiTraceDisarm(HttpRequest request, HttpResponse response) {
        if (traceDisarmHandler !is null) traceDisarmHandler();
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
        // Task 5820 invariant: HTTP validates only the raw index and builds the
        // wire response. replayBridge's owned main-thread service resolves that
        // exact history row and immediately calls executeCommand, so current
        // selection/mesh is used with no second queue or intervening frame.
        // Evidence: history_replay_boundary_test.d.
        response.headers["Content-Type"] = "application/json";
        if (replayProvider is null) {
            response.statusCode = 200;
            response.body = `{"status":"error","message":"replay provider not set"}`;
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

                ReplayReq bridgeRequest = ReplayReq.init;
                bridgeRequest.index = cast(size_t) idx;
                // Compatibility is the state of the legacy carrier's LAST
                // ASSIGNMENTS. The command route is its only writer through
                // either transport; replay writes neither flag and its service
                // reads only this request-owned copy, never a mutable borrow or
                // a second independently maintained latch (task 5820).
                bridgeRequest.interactive = commandBridge.req.interactive;
                bridgeRequest.uiOrigin = commandBridge.req.uiOrigin;
                ReplayResp initialResult = ReplayResp.init;
                initialResult.error = "";
                initialResult.line = "";
                initialResult.result = "";
                ReplayResp timeoutResult = ReplayResp.init;
                timeoutResult.error = "timeout waiting for main thread";
                timeoutResult.line = "";
                timeoutResult.result = "";
                ReplayResp stoppingResult = ReplayResp.init;
                stoppingResult.error = "HTTP server stopping";
                stoppingResult.line = "";
                stoppingResult.result = "";
                auto owned = replayBridge.submitOwned(
                    bridgeRequest, initialResult, timeoutResult, stoppingResult,
                    replayBudget_);
                if (owned.result.error.length == 0) {
                    response.statusCode = 200;
                    response.body = `{"status":"ok","line":"`
                                  ~ jsonEsc(owned.result.line) ~ `"}`;
                } else {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                  ~ jsonEsc(owned.result.error) ~ `"}`;
                }
            } catch (Exception e) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"`
                              ~ jsonEsc(e.msg) ~ `"}`;
            }
        }
    }

    private void servePlayEvents(HttpRequest request, HttpResponse response) {
        // Leave 50 ms inside the owned wait budget so a call still in the
        // queue at its service deadline is refused without changing
        // MainThreadBridge's shared claim protocol. The owner parses the raw
        // body before accepting it (task 6810); the full budget still governs
        // the waiter. Evidence: tests/unit/playback_parse_owner_test.d.
        enum Duration deadlineGuard = 50.msecs;
        immutable acceptWindow = playEventsBudget_ > deadlineGuard
            ? playEventsBudget_ - deadlineGuard : Duration.zero;
        PlayEventsReq bridgeRequest;
        bridgeRequest.body = request.body;
        bridgeRequest.notAfter = MonoTime.currTime + acceptWindow;
        auto owned = playEventsBridge.submitOwned(
            bridgeRequest,
            PlayEventsResp(false, 0, 0, ""),
            PlayEventsResp(false, 0, 0, "timeout waiting for main thread"),
            PlayEventsResp(false, 0, 0, "HTTP server stopping"),
            playEventsBudget_);
        if (owned.result.invalidLog) {
            response.statusCode = 400;
            response.body = `{"status": "error", "message": "Failed to parse events"}`;
        } else if (owned.result.error.length == 0) {
            import std.format : format;
            response.statusCode = 200;
            response.body = format(
                `{"status":"success","message":"Events loaded successfully","generation":%d,"replaced":%d}`,
                owned.result.generation, owned.result.replaced);
        } else {
            response.statusCode = 500;
            response.body = `{"status":"error","message":"`
                          ~ jsonEsc(owned.result.error) ~ `"}`;
        }
        response.headers["Content-Type"] = "application/json";
    }


    /**
     * The status line for a response code — reason phrase included.
     *
     * Split out of `formatResponse` and made `static` so a unittest can hold
     * it against the set of codes this server actually emits. The reason
     * phrase is not decoration: it is the half of the first line a human
     * reads in a curl transcript or a CI log, and every code missing from
     * this switch is printed as "<code> Unknown".
     *
     * 503 was that case for the whole of task 1740 — the one signal the task
     * exists to produce read `HTTP/1.1 503 Unknown` on the wire — and 403,
     * which eight routes in this file emit, has read `403 Unknown` since it
     * was introduced. Both are the same defect: a code added at an emission
     * site with nothing forcing a matching arm here. The census unittest at
     * the foot of this module is what forces it now: it scans this file for
     * every literal `statusCode = NNN` and demands an arm for each.
     */
    package static string statusLineFor(int code) {
        switch (code) {
            case 200: return "HTTP/1.1 200 OK";
            case 400: return "HTTP/1.1 400 Bad Request";
            case 403: return "HTTP/1.1 403 Forbidden";
            case 404: return "HTTP/1.1 404 Not Found";
            case 500: return "HTTP/1.1 500 Internal Server Error";
            case 503: return "HTTP/1.1 503 Service Unavailable";
            case 504: return "HTTP/1.1 504 Gateway Timeout";
            default:  return "HTTP/1.1 " ~ to!string(code) ~ " Unknown";
        }
    }

    /**
     * Format an HTTP response
     */
    private string formatResponse(HttpResponse response) {
        string statusLine = statusLineFor(response.statusCode);

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
        immutable bool wasActive = !playbackController.status().finished;
        immutable bool more = playbackController.tick();
        // The composition root calls this just BEFORE tickAll, so the pass
        // that closes the dispatching frame's drain is the next one.
        if (wasActive && !more)
            playbackFinishPass_ = tickPass_ + 1;
        return more;
    }

    /// The player's snapshot plus the frame barrier (see `tickPass_`).
    private PlaybackStatus settledPlaybackStatus() const {
        auto status = playbackController.status();
        status.frame = tickPass_;
        status.processed = status.finished && tickPass_ > playbackFinishPass_;
        return status;
    }

    /// Serve the two frame-count operations at the owner-thread frame boundary.
    public void tickFrameCounts(ref FrameWorkProbe probe) {
        FrameWorkProbe* owner = &probe;
        frameCountsBridge.tickClaimed((ref FrameCountsReq req,
                                       ref FrameCountsResp resp) nothrow {
            final switch (req.op) {
            case FrameCountsOp.read:
                resp.snapshot = owner.snapshot();
                break;
            case FrameCountsOp.reset:
                owner.reset();
                break;
            }
        });
    }

    /// Serve FrameProbe reads and resets at the owner-thread frame boundary.
    public void tickFrames(ref FrameProbe probe) {
        FrameProbe* owner = &probe;
        framesBridge.tickClaimed((ref FramesReq req,
                                  ref FramesResp resp) nothrow {
            final switch (req.op) {
            case FramesOp.read:
                resp.snapshot = owner.snapshot();
                break;
            case FramesOp.reset:
                owner.reset();
                break;
            }
        });
    }

    /**
     * Give the HTTP replay producer its main-thread immediate-delivery sink.
     * The server owns the player but not editor input, so the composition root
     * supplies this capability after both objects exist. Without a sink the
     * player's ordinary SDL-queue fallback remains active.
     */
    public void setEventPlayerSink(ImmediateEventSink sink) {
        playbackController.setImmediateSink(sink);
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
        immutable size_t identity = httpTransportThreadIdentity();
        synchronized (this) {
            if (atomicLoad(tickThreadIdentity_) == 0)
                atomicStore(tickThreadIdentity_, identity);
        }
        ++tickPass_;
        foreach (b; bridges) b.tick();
        // Second half of the readiness predicate (task 1740). Set AFTER the
        // drain, not before: the claim being published is "a bridged request
        // submitted from now on will be serviced", and that is only true once
        // this loop has actually run. The plain load first keeps the steady
        // state at one relaxed read per frame.
        if (!atomicLoad(mainLoopTicked)) atomicStore(mainLoopTicked, true);
    }

    private bool calledFromTickThread() nothrow {
        try {
            immutable size_t identity = httpTransportThreadIdentity();
            // The transport returns zero on a thread not attached to druntime.
            // Before the first tick and after stop the stored owner is also zero;
            // this term avoids relying on raw threads being unreachable here.
            return identity != 0 && atomicLoad(tickThreadIdentity_) == identity;
        } catch (Throwable) {
            return false;
        }
    }

    /**
     * Declare the provider/handler wiring complete (task 1740).
     *
     * Called from ONE place: the end of `wireHttpProviders`, immediately after
     * its `unwiredEndpoints()` completeness check. That placement is the whole
     * point — the check already enumerates every slot from `this.tupleof`, so
     * readiness is defined by the code that already knows what "wired" means
     * instead of by a second list. If that check throws, this is never
     * reached and the server never claims to be ready.
     */
    public void markProvidersWired() { atomicStore(providersWired, true); }

    /**
     * The single machine-readable readiness predicate: true once the wiring
     * completed AND the main loop has drained the bridges at least once.
     * While it is false every `/api/*` route answers 503 and nothing else.
     */
    public bool ready() const {
        return atomicLoad(providersWired) && atomicLoad(mainLoopTicked);
    }

    /**
     * Every provider/handler/action slot this server owns that nothing filled in.
     *
     * Task 0720 (audit №4, D5). `wireHttpProviders` installs 51 delegates in
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
                    || (n.length > 7 && n[$ - 7 .. $] == "Handler")
                    || (n.length > 6 && n[$ - 6 .. $] == "Action")) {
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

version (PerfProbe)
{
    private enum Answered kFramesAnswered = Answered.mainThread;
    static assert(kFramesAnswered == Answered.mainThread,
        "6730 PerfProbe frame routes must answer on the main thread");
}
else
{
    private enum Answered kFramesAnswered = Answered.httpThread;
    static assert(kFramesAnswered == Answered.httpThread,
        "6730 default frame routes must answer on the HTTP thread");
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
    RouteSpec("/api/selection",            "",     Match.exact,  Answered.mainThread, "route_apiSelection"),
    RouteSpec("/api/tool/handles",         "GET",  Match.exact,  Answered.mainThread, "route_apiToolHandles"),
    RouteSpec("/api/tool/state",           "GET",  Match.exact,  Answered.mainThread, "route_apiToolState"),
    RouteSpec("/api/tool/disarm",          "GET",  Match.exact,  Answered.mainThread, "route_apiToolDisarm"),
    RouteSpec("/api/toolprops/ids",        "GET",  Match.exact,  Answered.mainThread, "route_apiToolpropsIds"),
    RouteSpec("/api/ui/policy",            "GET",  Match.exact,  Answered.mainThread, "route_apiUiPolicy"),
    RouteSpec("/api/buttons/availability", "GET",  Match.exact,  Answered.mainThread, "route_apiButtonsAvailability"),
    RouteSpec("/api/input/context",        "GET",  Match.prefix, Answered.mainThread, "route_apiInputContext"),
    RouteSpec("/api/stats",                "GET",  Match.exact,  Answered.mainThread, "route_apiStats"),
    RouteSpec("/api/pie",                  "GET",  Match.exact,  Answered.mainThread, "route_apiPie"),
    RouteSpec("/api/layers",               "GET",  Match.exact,  Answered.mainThread, "route_apiLayers"),
    RouteSpec("/api/perf/reset",           "POST", Match.exact,  Answered.mainThread, "route_apiPerfReset"),
    RouteSpec("/api/perf",                 "GET",  Match.exact,  Answered.mainThread, "route_apiPerf"),
    RouteSpec("/api/frames/counts/reset",  "POST", Match.exact,  Answered.mainThread, "route_apiFramesCountsReset"),
    RouteSpec("/api/frames/counts",        "GET",  Match.exact,  Answered.mainThread, "route_apiFramesCounts"),
    RouteSpec("/api/frames/reset",         "POST", Match.exact,  kFramesAnswered, "route_apiFramesReset"),
    RouteSpec("/api/frames",               "GET",  Match.exact,  kFramesAnswered, "route_apiFrames"),
    RouteSpec("/api/changes",              "GET",  Match.exact,  Answered.httpThread, "route_apiChanges"),
    RouteSpec("/api/cache/rebuilds",       "GET",  Match.exact,  Answered.httpThread, "route_apiCacheRebuilds"),
    RouteSpec("/api/gc/commands",          "GET",  Match.exact,  Answered.httpThread, "route_apiGcCommands"),
    // Match.prefix: the provenance rides the query string (plan §6.3 rule 2),
    // and Match.exact compares the whole path. No other route is a prefix of
    // this one and none sits below it.
    RouteSpec("/api/mesh/planes",          "GET",  Match.prefix, Answered.mainThread, "route_apiMeshPlanes"),
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
    RouteSpec("/api/play-events/status",   "GET",  Match.exact,  Answered.mainThread, "route_apiPlayEventsStatus"),
    RouteSpec("/api/test/layer",           "POST", Match.exact,  Answered.mainThread, "route_apiTestLayer"),
    // Match.prefix (task 1520): `?origin=ui` puts a query string on the path,
    // and Match.exact compares the whole path — the query would never match.
    // No other route is a prefix of this one.
    RouteSpec("/api/command",              "POST", Match.prefix, Answered.mainThread, "route_apiCommand"),
    RouteSpec("/api/script",               "POST", Match.prefix, Answered.mainThread, "route_apiScript"),
    RouteSpec("/api/refire",               "POST", Match.exact,  Answered.mainThread, "route_apiRefire"),
    RouteSpec("/api/history/block",        "POST", Match.exact,  Answered.mainThread, "route_apiHistoryBlock"),
    RouteSpec("/api/undo/status",          "GET",  Match.exact,  Answered.mainThread, "route_apiUndoStatus"),
    RouteSpec("/api/history",              "GET",  Match.exact,  Answered.mainThread, "route_apiHistory"),
    RouteSpec("/api/trace",                "GET",  Match.exact,  Answered.httpThread, "route_apiTrace"),
    RouteSpec("/api/trace/reset",          "POST", Match.exact,  Answered.httpThread, "route_apiTraceReset"),
    RouteSpec("/api/trace/disarm",         "POST", Match.exact,  Answered.httpThread, "route_apiTraceDisarm"),
    RouteSpec("/api/history/jump",         "POST", Match.exact,  Answered.mainThread, "route_apiHistoryJump"),
    RouteSpec("/api/history/replay",       "POST", Match.exact,  Answered.mainThread, "route_apiHistoryReplay"),
    RouteSpec("/api/play-events",          "POST", Match.exact,  Answered.mainThread, "route_apiPlayEvents"),
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

private string retiredWrapperRouteProblem(const RouteSpec[] rs) {
    enum string[] retired = [
        "/api/select", "/api/transform", "/api/reset",
        "/api/load-mesh", "/api/undo", "/api/redo",
    ];
    // POPULATION FLOOR, and it is the point of these four lines. The scan
    // below is a "nothing matched" predicate, which is exactly the shape that
    // is VACUOUSLY TRUE over an empty set: hand it `rs.length == 0`, or empty
    // the `retired` list, and it returns `null` — a clean compile that has
    // measured nothing. Both denominators are therefore stated. `retired` is a
    // CLOSED historical set (the six routes task 4063 removed), so it is
    // pinned exactly; `kRoutes` grows and shrinks with the API, so its floor
    // is a "has this table been gutted" bound — 65 routes before the
    // retirement, 59 after, and anything under 50 means this guard is reading
    // a table that no longer describes the server.
    if (retired.length != 6)
        return "retired-route list is not the six routes task 4063 removed — "
             ~ "this scan can pass over an empty set";
    if (rs.length < 50)
        return "route table has fewer than 50 entries — this scan would be "
             ~ "reading a gutted table and would pass for that reason alone";
    foreach (route; rs)
        foreach (path; retired)
            if (route.path == path)
                return "retired wrapper route remains: " ~ path;
    return null;
}

static assert(retiredWrapperRouteProblem(kRoutes) is null,
              retiredWrapperRouteProblem(kRoutes));

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


/// Per-dispatch snapshot of server-owned authorization inputs. Dispatch
/// overwrites it from HttpServer; it is not independently configurable per
/// request.
struct HttpRequestContext {
    bool testMode;
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
    public HttpRequestContext context;

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

/// Task 6720: socket/thread-free request delivery for callers that share the
/// server process. Keeping this adapter in the server module preserves the
/// dispatcher's module-private boundary.
final class InProcessHttpTransport
{
    private HttpServer server_;

    this(HttpServer server)
    {
        if (server is null)
            throw new Exception("an in-process HTTP transport needs a server");
        server_ = server;
    }

    HttpResponse request(string method, string path, string body_)
    {
        auto request = new HttpRequest(method, path, "HTTP/1.1");
        request.body = body_;
        singleThreadedChannelDepth++;
        scope(exit) singleThreadedChannelDepth--;
        return server_.handleRequest(request);
    }
}

// Task 6740: the float-emitter source scan cannot see `%s` or `to!string`
// carrying a non-finite number. Exercise the production route table through
// the reusable dispatcher and let the JSON parser be the independent wire
// oracle. The census wires a real detailed-model provider so `/api/model`
// executes `meshToJsonDetailed`; its measured non-degraded-response floor
// keeps provider/handler errors and 4xx/5xx bodies from satisfying the claim.
// This stays in-module because kRoutes is the private population whose identity
// the test must consume; copying the table into tests would build a second
// collaborator and let production wiring drift green.
unittest {
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import core.time : MonoTime, msecs, seconds;
    import std.format : format;
    import std.json : JSONType, parseJSON;
    import std.string : startsWith, toLower;

    import mesh : makeCube;

    final class RouteReplies {
        shared bool done;
        HttpResponse[] responses;
        size_t traversed;
        string failure;
    }

    auto server = new HttpServer();
    auto censusMesh = makeCube();
    server.setDetailedModelDataProvider(
        () => meshToJsonDetailed(censusMesh));
    server.setToolDisarmProvider(() => `{}`);
    server.setUiPolicyProvider(() => `{}`);
    server.setToolpropsIdsProvider(() => `{}`);
    server.setButtonAvailabilityProvider(() => `{}`);
    server.setInputContextProvider(
        (bool havePoint, int x, int y, string key) => `{}`);
    server.setStatsProvider(() => `{}`);
    server.setPieProvider(() => `{}`);
    server.setPerfResetHandler(() {});
    server.setPerfProvider(() => `{}`);
    server.setTestMode(true);
    server.setModelBudgetForTest(100.msecs);
    server.setToolHandlesBudgetForTest(5.msecs);
    server.setFrameCountsBudgetForTest(5.msecs);
    server.setFramesBudgetForTest(5.msecs);
    server.setReplayBudgetForTest(5.msecs);
    server.setUndoStatusBudgetForTest(5.msecs);
    server.setToolStateBudgetForTest(5.msecs);
    server.setPlayEventsBudgetForTest(5.msecs);
    server.markProvidersWired();
    server.tickAll();
    FrameWorkProbe frameWorkOwner;
    server.tickFrameCounts(frameWorkOwner);
    assert(server.ready(),
        "6740 route JSON census: readiness setup did not reach the handlers");
    auto transport = new InProcessHttpTransport(server);
    auto replies = new RouteReplies();
    replies.responses.length = kRoutes.length;

    auto client = new Thread({
        try {
            foreach (i, route; kRoutes) {
                immutable method = route.method.length != 0 ? route.method : "GET";
                immutable body_ = method == "POST" ? `{}` : "";
                replies.responses[i] = transport.request(method, route.path, body_);
                replies.traversed = i + 1;
            }
        } catch (Throwable e) {
            replies.failure = e.msg;
        }
        atomicStore(replies.done, true);
    });
    client.start();
    scope (exit) {
        if (client.isRunning) {
            server.stop();
            client.join();
        }
    }

    immutable deadline = MonoTime.currTime + 10.seconds;
    while (!atomicLoad(replies.done) && MonoTime.currTime < deadline) {
        server.tickAll();
        server.tickFrameCounts(frameWorkOwner);
        Thread.sleep(1.msecs);
    }
    assert(atomicLoad(replies.done),
        "6740 route JSON census: the in-process route walk did not finish");
    client.join();
    assert(replies.failure.length == 0,
        "6740 route JSON census: route walk threw: " ~ replies.failure);
    assert(replies.traversed == 61,
        format("6740 route JSON census: expected to traverse all 61 kRoutes "
             ~ "rows, traversed %d", replies.traversed));

    string parseProblem(string body_) {
        try {
            cast(void) parseJSON(body_);
            return null;
        } catch (Exception e) {
            return e.msg;
        }
    }
    assert(parseProblem(`{"value":inf}`).length != 0,
        "6740 route JSON census: parseJSON accepted a non-finite bare token; "
        ~ "the route loop would not close the scanner's %s/to!string hole");

    size_t jsonResponses;
    size_t ownerSeededResponses;
    size_t configurationResponses;
    string[] degradedRoutes;
    foreach (i, route; kRoutes) {
        const response = replies.responses[i];
        assert(response !is null,
            "6740 route JSON census: no response for " ~ route.handler);
        const contentType = "Content-Type" in response.headers;
        if (contentType is null || !(*contentType).startsWith("application/json"))
            continue;
        jsonResponses++;
        const problem = parseProblem(response.body);
        assert(problem.length == 0,
            format("6740 route JSON census: %s %s (%s) returned invalid "
                 ~ "application/json: %s\nbody: %s",
                   route.method.length != 0 ? route.method : "ANY",
                   route.path, route.handler, problem, response.body));

        if (route.handler == "route_apiModel") {
            const model = parseJSON(response.body);
            const vertexCount = "vertexCount" in model.object;
            const vertices = "vertices" in model.object;
            assert(response.statusCode == 200
                && vertexCount !is null
                && vertexCount.type == JSONType.integer
                && vertexCount.integer == 8
                && vertices !is null
                && vertices.type == JSONType.array
                && vertices.array.length == 8,
                "6740 route JSON census: the live /api/model body did not "
                ~ "come from the one-cube detailed mesh emitter: "
                ~ response.body);
        }

        const lowerBody = response.body.toLower();
        immutable degraded = response.statusCode >= 400
            || lowerBody.canFind("provider not set")
            || lowerBody.canFind("handler not set");
        if (degraded) {
            degradedRoutes ~= format("%s %s (%s)",
                route.method.length != 0 ? route.method : "ANY",
                route.path, route.handler);
        } else if (route.handler == "route_apiFramesCounts"
                || route.handler == "route_apiFramesCountsReset") {
            ownerSeededResponses++;
        } else {
            configurationResponses++;
        }
    }
    assert(jsonResponses == 60,
        format("6740 route JSON census: measured JSON-response population "
             ~ "changed; expected 60 of 61, got %d", jsonResponses));
    // The two owner-seeded frame-count routes are their own population: the
    // default and PerfProbe builds both have to reach the real owner pump.
    assert(ownerSeededResponses == 2,
        format("6740 route JSON census: expected both owner-seeded "
             ~ "frame-count responses, got %d; degraded routes: %s",
               ownerSeededResponses, degradedRoutes.join(", ")));

    // Root HTML skips the JSON loop but belongs to the remaining live route
    // population. /api/frames is immediate in the default build (+2) and
    // owner-claimed in PerfProbe, where this census deliberately has no
    // FrameProbe owner; keep the two configuration floors independent.
    configurationResponses++;
    version (PerfProbe) {
        enum expectedConfigurationResponses = 28;
        assert(configurationResponses == expectedConfigurationResponses,
            format("6740 route JSON census: PerfProbe non-frame-count "
                 ~ "population changed; expected %d, got %d; degraded routes: %s",
                   expectedConfigurationResponses, configurationResponses,
                   degradedRoutes.join(", ")));
    } else {
        assert(configurationResponses == 30,
            format("6740 route JSON census: default-build non-frame-count "
                 ~ "population changed; expected 30, got %d; degraded routes: %s",
                   configurationResponses, degradedRoutes.join(", ")));
    }
}


// ---------------------------------------------------------------------------
// The STATUS LINE, task 1740 tail.
//
// `formatResponse` printed `HTTP/1.1 503 Unknown` for the whole of the work
// that introduced the 503 — the single signal the task exists to emit had a
// reason phrase reading "Unknown" in every curl transcript and CI log that
// showed it — and `403 Unknown` had been on the wire since 403 was first
// emitted. Both codes reached the wire with no arm in the switch because
// nothing connected an EMISSION SITE to the reason-phrase table.
//
// So this is a CENSUS, not a spot check on 503: it reads this module's own
// source through `__FILE_FULL_PATH__` (absolute, fixed at compile time — no
// dependence on the cwd of whatever runs the binary), collects every literal
// `statusCode = NNN` in it, and demands a named phrase for each. A seventh
// code added tomorrow at an emission site fails HERE rather than shipping a
// wrong first line.
//
// Three ways this could pass while proving nothing, each answered by a cell:
//   a. the scan matches nothing (a typo in the pattern, a moved file) and the
//      foreach over an empty set is green — cell A demands the codes it must
//      find, by value;
//   b. the default arm is deleted and every code returns something named —
//      cell C keeps an unemitted code answering "Unknown", which is the right
//      answer for a code nobody assigns and the proof the switch still has a
//      fallthrough to be caught by;
//   c. the phrase is named but wrong (`503 OK`) — cell B pins the two codes
//      this task is answerable for by their full text.
// ---------------------------------------------------------------------------
unittest {
    import std.file      : readText;
    import std.regex     : regex, matchAll;
    import std.algorithm : canFind, sort, uniq, map;
    import std.array     : array;

    // Cell A — the census. Absolute path baked in at compile time.
    string src;
    try src = readText(__FILE_FULL_PATH__);
    catch (Exception e)
        assert(false, "1740 status line: cannot read this module's own source "
            ~ "at " ~ __FILE_FULL_PATH__ ~ " (" ~ e.msg ~ ") — the census "
            ~ "cannot be performed, and a census that cannot run must not "
            ~ "report green");

    int[] emitted;
    foreach (m; src.matchAll(regex(`statusCode\s*=\s*([0-9]{3})\b`)))
        emitted ~= m[1].to!int;
    emitted = emitted.sort.uniq.array;

    // Anti-vacuity: the pattern must actually be finding the emission sites.
    // These six are what the module emitted on 2026-08-30; the assertion is on
    // CONTAINMENT, so adding a code is fine and losing the scan is not.
    foreach (must; [200, 400, 403, 404, 500, 503])
        assert(emitted.canFind(must),
            "1740 status line: the source scan did not find `statusCode = "
            ~ to!string(must) ~ "` in " ~ __FILE_FULL_PATH__ ~ " — the census "
            ~ "is reading the wrong text or the pattern broke, so every "
            ~ "assertion below it is vacuous. Found: " ~ to!string(emitted));

    foreach (code; emitted)
        assert(!HttpServer.statusLineFor(code).canFind("Unknown"),
            "1740 status line: this server assigns statusCode = "
            ~ to!string(code) ~ " somewhere in " ~ __FILE_FULL_PATH__
            ~ ", but formatResponse has no arm for it, so the wire carries `"
            ~ HttpServer.statusLineFor(code) ~ "`. The reason phrase is the half of the "
            ~ "first line a human reads; add the arm beside the emission");

    // Cell B — the two codes this task is answerable for, by full text.
    assert(HttpServer.statusLineFor(503) == "HTTP/1.1 503 Service Unavailable",
        "1740 status line: the readiness refusal is the ONE signal this task "
        ~ "produces, and its first line is what an external probe and every "
        ~ "log reader sees. Got `" ~ HttpServer.statusLineFor(503) ~ "`");
    assert(HttpServer.statusLineFor(504) == "HTTP/1.1 504 Gateway Timeout",
        "6357 status line: the pre-claim deadline must be a Gateway Timeout");
    assert(HttpServer.statusLineFor(403) == "HTTP/1.1 403 Forbidden",
        "1740 status line: 403 is emitted by eight routes here and read "
        ~ "`403 Unknown` before this task touched the switch. Got `"
        ~ HttpServer.statusLineFor(403) ~ "`");

    // Cell C — the default arm survives. Without this, "no Unknown anywhere"
    // is satisfiable by deleting the fallthrough, and an unassigned code would
    // then format as whatever the last arm happened to return.
    assert(HttpServer.statusLineFor(418) == "HTTP/1.1 418 Unknown",
        "1740 status line: a code this server never assigns must still fall "
        ~ "to the default arm — the census above proves nothing if that arm "
        ~ "is gone. Got `" ~ HttpServer.statusLineFor(418) ~ "`");
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
version (web)
{
}
else version (Posix)
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
