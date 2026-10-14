module tests.unit.ai3d.worker_manager_source_public_test;

import std.array   : replace;
import std.conv    : to;
import std.file    : exists, read, write, mkdirRecurse, getSize, dirEntries, SpanMode, thisExePath;
import std.json    : JSONValue, JSONType, parseJSON, JSONException;
import std.path    : buildPath, dirName, isAbsolute;
import std.process : environment, Pid, spawnProcess, tryWait, kill, wait;
import std.stdio   : File, stdin;
import core.time   : MonoTime, msecs, seconds;
import core.thread : Thread;
import log : logWarn;
import ai3d.stage_artifact : normalizeLocalWorkerUrl;
import std.file : tempDir, rmdirRecurse;
import std.random : uniform;
import ai3d.worker_manager;

version (unittest) {
    import std.file : tempDir, rmdirRecurse;
    import std.random : uniform;

    private string makeScratchDir(string tag) {
        auto d = buildPath(tempDir(),
            "vibe3d_ai3d_worker_mgr_ut_" ~ tag ~ "_" ~ uniform(0, int.max).to!string);
        mkdirRecurse(d);
        return d;
    }

    private void cleanScratchDir(string dir) nothrow {
        try rmdirRecurse(dir); catch (Exception) {}
    }
}


// Config round-trip: a fully populated Ai3dInstallConfig serializes and
// parses back identically.
unittest {
    auto dir = makeScratchDir("roundtrip");
    scope(exit) cleanScratchDir(dir);
    const path = buildPath(dir, "ai3d.json");

    Ai3dInstallConfig c;
    c.installed     = true;
    c.python        = "/opt/vibe3d-ai3d/venv/bin/python";
    c.backend       = "trellis";
    c.trellisRoot   = "/opt/vibe3d-ai3d/TRELLIS";
    c.modelCacheDir = "/opt/vibe3d-ai3d/hf-cache";
    c.port          = 47899;

    saveAi3dConfig(c, path);
    auto q = loadAi3dConfig(path);

    assert(q.version_ == kAi3dConfigVersion);
    assert(q.installed == true);
    assert(q.python == "/opt/vibe3d-ai3d/venv/bin/python");
    assert(q.backend == "trellis");
    assert(q.trellisRoot == "/opt/vibe3d-ai3d/TRELLIS");
    assert(q.modelCacheDir == "/opt/vibe3d-ai3d/hf-cache");
    assert(q.port == 47899);
}

// Missing file -> defaults (not installed), no throw.
unittest {
    auto dir = makeScratchDir("missing");
    scope(exit) cleanScratchDir(dir);
    auto c = loadAi3dConfig(buildPath(dir, "does_not_exist.json"));
    assert(c.installed == false);
    assert(c.port == kAi3dDefaultPort);
}

// Malformed JSON -> defaults, no throw.
unittest {
    auto dir = makeScratchDir("malformed");
    scope(exit) cleanScratchDir(dir);
    const path = buildPath(dir, "ai3d.json");
    write(path, "{ not json ]]");
    auto c = loadAi3dConfig(path);
    assert(c.installed == false);
}

// A corrupted/out-of-range port falls back to the default rather than being
// passed through as-is (kernel-boundary clamp).
unittest {
    auto dir = makeScratchDir("badport");
    scope(exit) cleanScratchDir(dir);
    const path = buildPath(dir, "ai3d.json");
    write(path, `{"version":1,"installed":true,"python":"/x/python",
                  "backend":"trellis","trellisRoot":"/x","port":999999}`);
    auto c = loadAi3dConfig(path);
    assert(c.port == kAi3dDefaultPort);
}

// null modelCacheDir round-trips to "" (== standard cache), not the literal
// string "null".
unittest {
    auto dir = makeScratchDir("nullcache");
    scope(exit) cleanScratchDir(dir);
    const path = buildPath(dir, "ai3d.json");

    Ai3dInstallConfig c;
    c.installed = true;
    c.python    = "/x/python";
    saveAi3dConfig(c, path);

    auto text = cast(string) read(path);
    import std.algorithm.searching : canFind;
    assert(text.canFind(`"modelCacheDir": null`));

    auto q = loadAi3dConfig(path);
    assert(q.modelCacheDir.length == 0);
}



// Ai3dWorkerManager.state(): notInstalled (no config file) ->
// installedStopped (config written, not started) -> the running transition
// is covered end-to-end by the fake-backend lifecycle test below (it needs
// a real subprocess to prove running/stopped honestly).
unittest {
    auto dir = makeScratchDir("state");
    scope(exit) cleanScratchDir(dir);
    const path = buildPath(dir, "ai3d.json");

    auto mgr = new Ai3dWorkerManager(path);
    assert(mgr.state() == Ai3dWorkerState.notInstalled);
    // The default (no config file) backend is trellis, so modelPresent() probes
    // the real HF model cache during construction. Whether the model is actually
    // there is HOST-DEPENDENT — present on a dev box that ran a generation, absent
    // on a clean CI runner — so assert only that constructing + probing ran
    // WITHOUT THROWING (the old `== true` asserted the cache-hit value and was a
    // latent CI-only failure). modelPresent() itself is a pure getter.
    cast(void) mgr.modelPresent();

    Ai3dInstallConfig c;
    c.installed = true;
    c.python    = "/x/python";
    c.backend   = "fake";
    saveAi3dConfig(c, path);

    mgr.refresh();
    assert(mgr.state() == Ai3dWorkerState.installedStopped);
    assert(mgr.modelPresent() == true, "fake backend needs no HF model cache");
}

// resolveModelCacheDir precedence + modelSnapshotPresent's filesystem probe
// (mirrors vibe3d_ai3d_worker/server.py's _resolve_cache_dir /
// _fs_find_snapshot pair exactly).
unittest {
    auto dir = makeScratchDir("modelcache");
    scope(exit) cleanScratchDir(dir);

    assert(resolveModelCacheDir(dir) == dir, "explicit override wins");

    assert(!modelSnapshotPresent("jetx/TRELLIS-image-large", dir),
           "empty cache dir -> not present");

    const snap = buildPath(dir, "models--jetx--TRELLIS-image-large", "snapshots", "deadbeef");
    mkdirRecurse(snap);
    write(buildPath(snap, "config.json"), "{}");
    assert(modelSnapshotPresent("jetx/TRELLIS-image-large", dir),
           "a non-empty snapshot dir -> present");

    const emptySnapModel = "org/empty-model";
    const emptySnap = buildPath(dir, "models--org--empty-model", "snapshots", "emptyrev");
    mkdirRecurse(emptySnap);
    assert(!modelSnapshotPresent(emptySnapModel, dir),
           "a snapshot dir with no files -> treated as not present");
}

version (Posix)
unittest {
    // Editor worker lifecycle (task 0403): spawn -> health -> kill, driven
    // through the worker's `fake` backend (no torch/GPU/model -- a
    // deterministic canned OBJ), proving the REAL subprocess + health-poll
    // + kill machinery end to end, entirely offline. Reuses
    // ai3d.stage_artifact.probeHealthCheck for the health poll -- the SAME
    // call the Generate 3D modal's health line already drives.
    //
    // Never touches the owner's live TRELLIS worker on :47831: a fresh
    // ephemeral port is picked the same way ai3d.job_controller's own
    // join()-timeout unittest does (bind :0, read the OS-assigned port
    // back, close, reuse the number -- a tiny, accepted race window).
    import std.socket : TcpSocket, InternetAddress;
    import ai3d.stage_artifact : probeHealthCheck;

    ushort pickFreePort() {
        auto s = new TcpSocket();
        scope(exit) s.close();
        s.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
        return (cast(InternetAddress) s.localAddress).port;
    }

    // Repo-root-relative path to tools/ai3d_worker, resolved at COMPILE
    // TIME from this module's own source location -- works regardless of
    // the test binary's cwd. Set as PYTHONPATH so a bare system python3
    // (no venv, no install) can `-m vibe3d_ai3d_worker` without an
    // editable install -- exactly the "fake backend, no torch/GPU" ask.
    enum repoRoot  = dirName(dirName(dirName(dirName(dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))))))));
    enum workerDir = buildPath(repoRoot, "tools", "ai3d_worker");
    assert(exists(buildPath(workerDir, "vibe3d_ai3d_worker", "server.py")),
           "sanity: the worker package must be findable at " ~ workerDir);

    auto dir = makeScratchDir("lifecycle");
    scope(exit) cleanScratchDir(dir);
    const cfgPath = buildPath(dir, "ai3d.json");

    Ai3dInstallConfig cfg;
    cfg.installed = true;
    cfg.python    = "python3"; // resolved via $PATH -- never a venv here
    cfg.backend   = "fake";
    cfg.port      = pickFreePort();
    saveAi3dConfig(cfg, cfgPath);

    auto mgr = new Ai3dWorkerManager(cfgPath);
    assert(mgr.state() == Ai3dWorkerState.installedStopped);

    const started = mgr.startWorker(["PYTHONPATH": workerDir]);
    assert(started, "startWorker must spawn the fake-backend subprocess");
    assert(mgr.state() == Ai3dWorkerState.running);

    // Poll /v1/health until ready. The fake backend boots in well under a
    // second; a generous ceiling keeps this robust on a loaded CI box.
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
    assert(healthy, "worker must become healthy: " ~ mgr.workerUrl());

    assert(mgr.stopWorker(), "stopWorker must report it killed a live process");
    assert(mgr.state() == Ai3dWorkerState.installedStopped);

    // Process is actually gone -- a second stopWorker() is a no-op, and the
    // health endpoint is unreachable (connection refused, not just slow).
    assert(!mgr.stopWorker());
    auto afterKill = probeHealthCheck(mgr.workerUrl(), neverStop);
    assert(!afterKill.ok, "worker must actually be dead after stopWorker()");
}
