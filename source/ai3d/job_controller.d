module ai3d.job_controller;

// ---------------------------------------------------------------------------
// Ai3dJobController — the async AI3D job driver (task 0381,
// doc/ai3d_ui_plan.md Phase 1). Owns a dedicated worker thread that runs the
// blocking `std.net.curl` transfers (via ai3d.stage_artifact); the main
// thread only ever calls start()/probeHealth()/drain()/requestCancel()/
// stop()/join() — never anything that blocks on the network.
//
// LOAD-BEARING: the constructor takes NO Document/Mesh/GpuMesh/View/ImGui/
// history reference. This class structurally cannot mutate the scene — the
// only channel out is the immutable Ai3dEvent queue (ai3d.event_queue),
// worker-thread-produced, main-thread-drained. The main thread is the sole
// document/UI mutator (see http_server.d:20-85 for the established
// boundary this mirrors).
// ---------------------------------------------------------------------------

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : msecs, seconds, MonoTime;

import ai3d.event_queue : Ai3dEventQueue;
import ai3d.job_events : Ai3dEvent, Ai3dEventKind;
import ai3d.stage_artifact : stageArtifact, probeHealthCheck, Ai3dProgress,
    Ai3dStageResult, Ai3dHealthResult, Ai3dDefaultRequestedFaces;

/// Shutdown join budget (Risk 4c). Comfortably above the per-transfer
/// Ai3dOperationTimeoutMs backstop (stage_artifact.d) so a wedged transfer
/// unwinds well inside this window in practice; app.d's shutdown path takes
/// the abrupt core.stdc.stdlib._exit(0) fallback if `join()` still times out.
enum Ai3dClientJoinTimeoutMs = 35_000;

final class Ai3dJobController {
    private Ai3dEventQueue queue_;
    private Thread worker_;
    private Thread healthWorker_;
    private shared bool abortRequested_; // set by requestCancel() OR stop()
    private shared bool busy_;           // true while a generate worker thread is alive

    this() {
        queue_ = new Ai3dEventQueue();
    }

    /// True while a generate job's worker thread is alive (single-in-flight
    /// enforcement, Phase 4 — see start()).
    bool busy() const {
        return atomicLoad(busy_);
    }

    /// Spawn the worker thread that runs the full generate pipeline
    /// (stageArtifact) against `workerUrl` for `imagePath`, posting events as
    /// it goes. No-ops (returns false) if a job is already in flight — the
    /// single-in-flight rule (Phase 4). `maxFaces` is the requested (not yet
    /// clamped) face budget for the create-job body; `stageArtifact` applies
    /// the authoritative `clampMaxFaces` bound regardless of what's passed
    /// here.
    bool start(string imagePath, string workerUrl, int timeoutMs = 120_000,
               int maxFaces = Ai3dDefaultRequestedFaces) {
        if (atomicLoad(busy_)) return false;
        atomicStore(busy_, true);
        atomicStore(abortRequested_, false);
        auto self = this;
        worker_ = new Thread({ self.runJob(imagePath, workerUrl, timeoutMs, maxFaces); });
        worker_.isDaemon = true;
        worker_.start();
        return true;
    }

    /// Spawn a short-lived thread that probes worker health and posts
    /// exactly ONE `health` event. Creates no job; does not touch the
    /// single-in-flight flag. This is what the modal calls on open (and the
    /// user can re-trigger) to populate its health line and gate Generate.
    void probeHealth(string workerUrl) {
        auto self = this;
        healthWorker_ = new Thread({ self.runHealthProbe(workerUrl); });
        healthWorker_.isDaemon = true;
        healthWorker_.start();
    }

    /// Request cooperative cancellation of the in-flight job (Risk 4). The
    /// worker observes this within Ai3dPollIntervalMs (poll-tick check) or
    /// immediately mid-transfer (the curl onProgress abort), whichever comes
    /// first, then posts a terminal `cancelled` event after issuing the
    /// generation-bound cancel DELETE.
    void requestCancel() {
        atomicStore(abortRequested_, true);
    }

    /// Shutdown hook: request abort of any in-flight transfer. Idempotent;
    /// safe to call even with no job running.
    void stop() {
        atomicStore(abortRequested_, true);
    }

    /// Join every spawned thread within `msTimeout`. Returns true iff all of
    /// them finished; false on a timeout — the caller (app.d shutdown path)
    /// must then take the abrupt core.stdc.stdlib._exit(0) fallback (Risk
    /// 4c) rather than falling into normal druntime teardown, which would
    /// try to join a thread still blocked inside libcurl's perform().
    bool join(int msTimeout = Ai3dClientJoinTimeoutMs) {
        auto deadline = MonoTime.currTime + msTimeout.msecs;
        bool joinOne(Thread t) {
            if (t is null) return true;
            while (t.isRunning) {
                if (MonoTime.currTime >= deadline) return false;
                Thread.sleep(10.msecs);
            }
            return true;
        }
        // Both threads get a fair shot at the shared deadline rather than
        // msTimeout each (a stuck job-worker must not starve the health
        // probe's slice, or vice versa, out of the shutdown budget).
        const okJob = joinOne(worker_);
        const okHealth = joinOne(healthWorker_);
        return okJob && okHealth;
    }

    /// Drain pending events on the main thread. Forwards to the queue's
    /// copy-under-mutex / lock-free-invoke contract (ai3d.event_queue) —
    /// `onEvent` runs with NO lock held, so it may safely dispatch
    /// `ai3d.importResult` (an assimp parse) without stalling a concurrent
    /// worker-thread push().
    void drain(scope void delegate(ref const Ai3dEvent) onEvent) {
        queue_.drain(onEvent);
    }

    private void runHealthProbe(string workerUrl) {
        Ai3dHealthResult r;
        try {
            r = probeHealthCheck(workerUrl, abortRequested_);
        } catch (Exception e) {
            Ai3dEvent ev;
            ev.kind = Ai3dEventKind.health;
            ev.healthOk = false;
            ev.code = "transport_error";
            ev.message = e.msg;
            queue_.push(ev);
            return;
        }
        Ai3dEvent ev;
        ev.kind = Ai3dEventKind.health;
        ev.healthOk = r.ok;
        ev.healthProtocol = r.protocol;
        ev.healthBackend = r.backend;
        ev.healthObjCapable = r.objCapable;
        ev.code = r.code;
        ev.message = r.message;
        queue_.push(ev);
    }

    private void runJob(string imagePath, string workerUrl, int timeoutMs, int maxFaces) {
        scope(exit) atomicStore(busy_, false);

        void onProgress(Ai3dProgress p) {
            Ai3dEvent ev;
            ev.jobId = p.jobId;
            ev.generation = p.generation;
            ev.state = p.state;
            ev.stage = p.stage;
            ev.progress = p.progress;
            ev.kind = (p.state == "submitted") ? Ai3dEventKind.submitted
                                               : Ai3dEventKind.status;
            queue_.push(ev);
        }

        Ai3dStageResult r;
        try {
            r = stageArtifact(workerUrl, imagePath, timeoutMs, maxFaces, abortRequested_, &onProgress);
        } catch (Exception e) {
            // stageArtifact() is documented not to throw; this is a
            // belt-and-braces backstop so a worker-thread bug can never
            // silently vanish the job with no terminal event.
            Ai3dEvent ev;
            ev.kind = Ai3dEventKind.transportError;
            ev.code = "transport_error";
            ev.message = e.msg;
            queue_.push(ev);
            return;
        }

        if (!r.ok) {
            Ai3dEvent ev;
            ev.kind = Ai3dEventKind.terminal;
            ev.jobId = r.jobId;
            ev.generation = r.generation;
            ev.state = r.cancelled ? "cancelled" : "failed";
            ev.code = r.code;
            ev.message = r.message;
            queue_.push(ev);
            return;
        }

        Ai3dEvent downloaded;
        downloaded.kind = Ai3dEventKind.downloaded;
        downloaded.jobId = r.jobId;
        downloaded.generation = r.generation;
        downloaded.objPath = r.objPath;
        downloaded.bytes = r.bytes;
        queue_.push(downloaded);

        Ai3dEvent terminal;
        terminal.kind = Ai3dEventKind.terminal;
        terminal.jobId = r.jobId;
        terminal.generation = r.generation;
        terminal.state = "succeeded";
        queue_.push(terminal);
    }
}

unittest {
    // State machine smoke test — no real network (invalid worker URL means
    // stageArtifact/probeHealthCheck fail fast, offline). Exercises: busy()
    // during start(), single-in-flight rejection, and that both a health
    // probe and a job worker eventually post a terminal-ish event, all
    // drainable and none touching any Document/Mesh (this class holds no
    // such reference at all, by construction).
    auto c = new Ai3dJobController();
    assert(!c.busy());

    auto started = c.start("/nonexistent.png", "http://127.0.0.1:1", 500);
    assert(started);
    assert(c.busy());
    assert(!c.start("/nonexistent.png", "http://127.0.0.1:1", 500),
           "single-in-flight: a second start() must no-op while busy");

    // Wait for the worker to finish (invalid URL fails immediately).
    auto deadline = MonoTime.currTime + 5.seconds;
    while (c.busy() && MonoTime.currTime < deadline)
        Thread.sleep(5.msecs);
    assert(!c.busy(), "worker should finish quickly against an unreachable host");

    bool sawTerminalOrError;
    c.drain((ref const Ai3dEvent e) {
        if (e.kind == Ai3dEventKind.terminal || e.kind == Ai3dEventKind.transportError)
            sawTerminalOrError = true;
    });
    assert(sawTerminalOrError);

    assert(c.join(1_000));
}

unittest {
    // Phase 4 (Risk 4c) precondition: join() must return FALSE within the
    // requested budget when the worker is still busy — this is exactly
    // the signal app.d's shutdown path uses to decide whether to fall
    // into normal teardown or take the abrupt core.stdc.stdlib._Exit(0)
    // path. Never actually calls _Exit here (that would kill the test
    // process) — only proves join()'s own timeout-return contract.
    //
    // A local TCP listener that accepts the connection but never responds
    // keeps stageArtifact's probeHealthCheck GET genuinely in flight (past
    // connect, waiting on a response) until its own
    // Ai3dOperationTimeoutMs backstop fires — a deterministic "worker
    // still busy" window regardless of sandbox networking policy (unlike
    // an actually-unreachable host, which some environments fail
    // instantly with no route rather than a slow connect timeout).
    import std.conv : to;
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.socket : TcpSocket, InternetAddress, SocketOptionLevel, SocketOption;

    auto listener = new TcpSocket();
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    listener.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
    listener.listen(1);
    const port = (cast(InternetAddress) listener.localAddress).port;
    scope(exit) listener.close();

    auto c = new Ai3dJobController();
    assert(c.start("/nonexistent.png", "http://127.0.0.1:" ~ port.to!string, 500));

    auto sw = StopWatch(AutoStart.yes);
    const joined = c.join(50); // budget far shorter than the 10s operation timeout
    sw.stop();
    assert(!joined, "join() must return false while the worker is still waiting on a response");
    assert(sw.peek.total!"msecs" < 500,
           "join() must return promptly at its OWN budget, not block until the worker finishes");

    // Clean up: let the real operation timeout resolve so no thread leaks
    // past this test (comfortably inside Ai3dClientJoinTimeoutMs=35s).
    assert(c.join(15_000), "worker should finish once its own operation timeout fires");
}
