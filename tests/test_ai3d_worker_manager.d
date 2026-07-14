// test_ai3d_worker_manager.d — offline acceptance test for the AI3D worker
// lifecycle manager (task 0403, source/ai3d/worker_manager.d): drives the
// REAL Ai3dWorkerManager (spawn -> health -> kill) against the pure-stdlib
// Python fake worker backend, in-process — no GPU/torch, no vibe3d HTTP
// server involved. This proves the exact mechanism the Generate 3D panel's
// Start/Stop buttons drive: unlike ai3d_worker_helpers.spawnAi3dFakeWorker()
// (which other AI3D tests use to stand up a worker directly, out-of-band, so
// THEY can point some other component at it), here the MANAGER itself does
// the spawning.
//
// Skips gracefully (prints a notice, returns) when python3 is unavailable,
// so CI without Python stays green — same convention as
// test_ai3d_controller.d.

import std.conv    : to;
import std.file    : exists, tempDir, mkdirRecurse, rmdirRecurse;
import std.path    : buildPath;
import std.random  : uniform;
import std.socket  : TcpSocket, InternetAddress;
import std.stdio   : stderr;
import core.thread : Thread;
import core.time   : msecs, seconds, MonoTime;

import ai3d_worker_helpers : ai3dPython3Available;
import ai3d.worker_manager : Ai3dWorkerManager, Ai3dWorkerState,
    Ai3dInstallConfig, saveAi3dConfig;
import ai3d.stage_artifact : probeHealthCheck;

// run_test.d always runs from the repo root (ai3d_worker_helpers.
// spawnAi3dFakeWorker makes the same "tools/ai3d_worker" assumption).
private enum ai3dWorkerRoot = "tools/ai3d_worker";

private ushort pickFreePort() {
    auto s = new TcpSocket();
    scope(exit) s.close();
    s.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
    return (cast(InternetAddress) s.localAddress).port;
}

// D disallows a try/catch directly inside a scope(exit) statement, so
// best-effort cleanup goes through this nothrow helper instead (same
// pattern as remesh_job.d's own tryRemove).
private void tryRmdirRecurse(string dir) nothrow {
    try rmdirRecurse(dir); catch (Exception) {}
}

unittest {
    if (!ai3dPython3Available()) {
        stderr.writeln("SKIP test_ai3d_worker_manager (no python3)");
        return;
    }
    if (!exists(ai3dWorkerRoot)) {
        stderr.writeln("SKIP test_ai3d_worker_manager (tools/ai3d_worker not found — cwd not repo root?)");
        return;
    }

    const scratch = buildPath(tempDir(),
        "vibe3d_ai3d_worker_mgr_test_" ~ uniform(0, int.max).to!string);
    mkdirRecurse(scratch);
    scope(exit) tryRmdirRecurse(scratch);
    const cfgPath = buildPath(scratch, "ai3d.json");

    // A hand-written config, as install_linux.sh would leave it — except
    // backend=fake and python="python3" (no venv, no torch): the fake
    // backend needs neither, only tools/ai3d_worker importable, which the
    // PYTHONPATH passed to startWorker() below provides.
    Ai3dInstallConfig cfg;
    cfg.installed = true;
    cfg.python    = "python3";
    cfg.backend   = "fake";
    cfg.port      = pickFreePort();
    saveAi3dConfig(cfg, cfgPath);

    auto mgr = new Ai3dWorkerManager(cfgPath);
    assert(mgr.state() == Ai3dWorkerState.installedStopped,
           "config written + installed=true, not yet started");

    assert(mgr.startWorker(["PYTHONPATH": ai3dWorkerRoot]),
           "startWorker must spawn the fake-backend subprocess");
    assert(mgr.state() == Ai3dWorkerState.running);

    // Poll /v1/health until ready via the SAME call the Generate 3D modal's
    // health line drives (ai3d.stage_artifact.probeHealthCheck, through
    // Ai3dJobController.probeHealth() in the running app). The fake backend
    // boots in well under a second; a generous ceiling keeps this robust on
    // a loaded CI box.
    shared bool neverStop = false;
    bool healthy;
    const deadline = MonoTime.currTime + 10.seconds;
    while (MonoTime.currTime < deadline) {
        mgr.pollWorker();
        assert(mgr.state() == Ai3dWorkerState.running, "must not have exited early");
        auto h = probeHealthCheck(mgr.workerUrl(), neverStop);
        if (h.ok) { healthy = true; break; }
        Thread.sleep(50.msecs);
    }
    assert(healthy, "worker must become healthy at " ~ mgr.workerUrl());

    assert(mgr.stopWorker(), "stopWorker must report it killed a live process");
    assert(mgr.state() == Ai3dWorkerState.installedStopped);
    assert(!mgr.stopWorker(), "second stopWorker() is a no-op — nothing left to kill");

    // The process is actually gone (connection refused), not just slow to
    // respond.
    auto afterKill = probeHealthCheck(mgr.workerUrl(), neverStop);
    assert(!afterKill.ok, "worker must actually be dead after stopWorker()");
}

void main() {}
