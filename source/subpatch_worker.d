// Off-main-thread subpatch preview builds (task 1500).
//
// WHAT THIS BUYS, AND WHAT IT DOES NOT. It makes NO work go away: the same
// stencil table is built, from the same cage, at the same refinement level,
// and the result is bit-identical. What it buys is that the WINDOW STOPS
// FREEZING while that happens — the cage stays live, the camera orbits, and
// the preview is swapped in when it is ready. The two levers that would have
// been real speedups are both dead by measurement (task 1374): cost is not
// made monotonic in cage size at integer refinement levels, and buffer reuse
// was already taken in P0/P5 and cannot help the FIRST build by definition.
//
// ONE BUILD AT A TIME, ON PURPOSE. There is no pool and no queue depth. A
// second Tab while a build is running does not cancel it — the point of no
// return is inside a third-party library and there is nothing to cancel with —
// it lets the first finish and the receiver throws the result away on a key
// mismatch, then dispatches again. The price is named rather than hidden: up
// to one full build of background core burnt for nothing per re-Tab.
//
// THE THREAD NEVER TOUCHES GL, AND THAT IS INSTRUMENTED, NOT PROMISED.
// `OsdAccel.buildFromSnapshot` is the only thing that runs here, and
// `OsdAccel.installGl` — every GL call the build ever made — opens with
// `glThreadGuard`, so a call that drifts across the seam names the funnel
// instead of dying in a driver dispatch slot.
//
// THE THREAD NEVER READS THE LIVE MESH either: it is handed a `CageSnapshot`
// that owns every array it reads, because the main thread keeps editing the
// cage (a gizmo drag rewrites `vertices` every frame WITHOUT bumping
// `mutationVersion`).
module subpatch_worker;

import core.thread     : Thread;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.time       : MonoTime, dur, msecs;
import subpatch_osd    : OsdAccel, CageSnapshot, PreviewBuildResult;

/// One long-lived builder thread with a single-slot mailbox.
///
/// The protocol is deliberately small enough to state in full:
///   * `submit` may only be called when `busy` is false and no result is
///     waiting. `SubpatchPreview` enforces that with `buildPending`.
///   * `tryTake` is the ONLY way a result leaves; it is non-blocking and
///     answers false until the build has published.
///   * `waitIdle` is the bounded join `OsdAccel.clear()` runs through, so a
///     destructive call on the main thread cannot free a handle the builder
///     is still reading.
final class SubpatchWorker {
    private Thread     thread_;
    private Mutex      mtx_;
    private Condition  cond_;

    // ---- guarded by mtx_ -------------------------------------------------
    private bool shutdown_;
    private bool jobQueued_;     // submitted, not yet picked up
    private bool jobRunning_;    // picked up, not yet published
    private bool resultReady_;   // published, not yet taken

    private OsdAccel*     accel_;
    private CageSnapshot* snap_;
    private ulong         generation_;
    private ulong         key_;
    private PreviewBuildResult result_;
    // ----------------------------------------------------------------------

    this() {
        mtx_  = new Mutex;
        cond_ = new Condition(mtx_);
        thread_ = new Thread(&loop);
        thread_.name = "subpatch-build";
        // Daemon so a forgotten `shutdown()` cannot wedge process exit in
        // `thread_joinAll`. `shutdown()` is still called from the app's exit
        // path — the daemon flag is the backstop, not the plan.
        thread_.isDaemon = true;
        thread_.start();
    }

    /// MAIN THREAD. Hand one build over. Precondition (asserted): nothing in
    /// flight and no untaken result.
    void submit(OsdAccel* accel, CageSnapshot* snap, ulong generation, ulong key) {
        synchronized (mtx_) {
            assert(!jobQueued_ && !jobRunning_ && !resultReady_,
                   "SubpatchWorker.submit while a build is in flight");
            accel_      = accel;
            snap_       = snap;
            generation_ = generation;
            key_        = key;
            jobQueued_  = true;
            cond_.notifyAll();
        }
    }

    /// MAIN THREAD, non-blocking. True (and fills `res`) iff a finished build
    /// is waiting. Ownership of `res.topo` passes to the caller when
    /// `res.topoOwned` — see `OsdAccel.retireResult`.
    bool tryTake(out PreviewBuildResult res) {
        synchronized (mtx_) {
            if (!resultReady_) return false;
            res          = result_;
            result_      = PreviewBuildResult.init;
            resultReady_ = false;
            return true;
        }
    }

    /// A build is queued or running (a published-but-untaken result is NOT
    /// busy: the builder is idle and nothing is being read).
    @property bool busy() {
        synchronized (mtx_) return jobQueued_ || jobRunning_;
    }

    @property bool resultWaiting() {
        synchronized (mtx_) return resultReady_;
    }

    /// MAIN THREAD. Bounded join: wait until the builder is idle. Returns
    /// false on TIMEOUT, and the caller must then treat the build as
    /// ABANDONED — see `SubpatchPreview.joinInFlight` for why the deliberate
    /// answer there is to leak the topology rather than free memory a
    /// running thread is reading.
    bool waitIdle(long timeoutMs) {
        immutable deadline = MonoTime.currTime + dur!"msecs"(timeoutMs);
        synchronized (mtx_) {
            while (jobQueued_ || jobRunning_) {
                immutable now = MonoTime.currTime;
                if (now >= deadline) return false;
                cond_.wait(deadline - now);
            }
            return true;
        }
    }

    /// MAIN THREAD, at process shutdown. Asks the loop to leave and joins it
    /// bounded; a builder still inside the third-party stencil build is left
    /// to the daemon flag rather than waited on forever.
    void shutdown(long timeoutMs = 5_000) {
        synchronized (mtx_) {
            shutdown_ = true;
            cond_.notifyAll();
        }
        waitIdle(timeoutMs);
    }

    // ------------------------------------------------------------------
    // Builder thread.
    // ------------------------------------------------------------------
    private void loop() {
        for (;;) {
            OsdAccel*     accel;
            CageSnapshot* snap;
            ulong         gen, key;
            synchronized (mtx_) {
                while (!shutdown_ && !jobQueued_) cond_.wait();
                if (shutdown_) return;
                jobQueued_  = false;
                jobRunning_ = true;
                accel = accel_;
                snap  = snap_;
                gen   = generation_;
                key   = key_;
            }

            PreviewBuildResult res;
            res.generation = gen;
            res.key        = key;
            // PUBLISH FROM `scope(exit)`, NOT FROM THE SUCCESS POINT. The
            // build has three early `return false`s of its own plus whatever
            // the stencil builder throws; every one of them is an ARRIVAL as
            // far as the receiver is concerned — it clears `buildPending` and
            // leaves the cage on screen. A build that could fail without
            // publishing would hang the barrier until its ceiling.
            scope(exit) {
                synchronized (mtx_) {
                    result_      = res;
                    resultReady_ = true;
                    jobRunning_  = false;
                    cond_.notifyAll();
                }
            }
            try {
                accel.buildFromSnapshot(*snap, res);
            } catch (Throwable t) {
                res.ok = false;
                try {
                    import log : logError;
                    logError("subpatch", "preview build failed: " ~ t.msg);
                } catch (Exception) {}
            }
        }
    }
}
