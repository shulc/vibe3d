module ai3d_worker_helpers;

// Shared helpers for AI3D tests (test_ai3d_controller.d, test_ai3d_ui.d):
// spawn/teardown the pure-stdlib Python fake worker
// (`python3 -m vibe3d_ai3d_worker serve --backend fake`) as a subprocess,
// and a 1x1 PNG fixture to feed it as a generate input. std.*-only (no
// project imports) so this compiles under the cheap HTTP-driver test path
// too, per the *_helpers.d convention (dirEntries("tests", "*_helpers.d")
// in run_test.d pulls every such file into every test's compile).

import std.conv : to;
import std.file : exists, mkdirRecurse, rmdirRecurse, write, tempDir, remove;
import std.path : buildPath;
import std.process : environment, pipeProcess, Redirect, Pid, ProcessPipes,
    kill, wait, execute, ProcessException;
import std.regex : matchFirst, regex;
import std.stdio : stderr;
import std.string : strip;
import std.uuid : randomUUID;
import core.thread : Thread;
import core.time : msecs, MonoTime;

// Same 1x1 PNG fixture as tools/ai3d_worker/tests/test_worker_contract.py.
immutable ubyte[] ai3dPng1x1 = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00,
    0x90, 0x77, 0x53, 0xDE,
    0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0x60, 0x60, 0x00, 0x00, 0x00, 0x04, 0x00, 0x01,
    0xF6, 0x17, 0x38, 0x55,
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

bool ai3dPython3Available() {
    try {
        auto r = execute(["python3", "--version"]);
        return r.status == 0;
    } catch (Exception) {
        return false;
    }
}

struct Ai3dFakeWorker {
    bool ok;
    Pid pid;
    ProcessPipes pipes;
    string baseUrl;
    string dataDir;
}

/// Spawn the fake worker with an OS-assigned port (`--port 0`) and learn the
/// actual bound port from its stdout "listening on http://host:port" line —
/// avoids any port-collision scheme across parallel test workers. Returns
/// `.ok == false` (never throws) when python3 or the worker package is
/// unavailable, so callers can skip gracefully.
/// `delayMs` (task 0381 Phase 4) is the fake backend's PER-PHASE sleep (5
/// phases) — the default (0, meaning the worker's own `--delay 20` default)
/// gives a ~100ms total run window, far shorter than a real controller's
/// 250ms poll tick, so a "cancel while genuinely running" test needs a
/// wider window (e.g. 150) to reliably land its cancel after the worker has
/// actually reported state=="running" at least once, instead of collapsing
/// into the queued-cancel path.
Ai3dFakeWorker spawnAi3dFakeWorker(int delayMs = 0) {
    Ai3dFakeWorker fw;
    const workerRoot = "tools/ai3d_worker";
    if (!exists(workerRoot)) {
        stderr.writeln("SKIP: tools/ai3d_worker not found (cwd not repo root?)");
        return fw;
    }

    fw.dataDir = buildPath(tempDir(), "vibe3d-ai3d-test-" ~ randomUUID().toString());
    mkdirRecurse(fw.dataDir);

    string[string] env = environment.toAA();
    if (auto existing = "PYTHONPATH" in env)
        env["PYTHONPATH"] = workerRoot ~ ":" ~ *existing;
    else
        env["PYTHONPATH"] = workerRoot;

    string[] args = [
        "python3", "-m", "vibe3d_ai3d_worker", "serve",
        "--host", "127.0.0.1", "--port", "0",
        "--data-dir", fw.dataDir, "--backend", "fake",
    ];
    if (delayMs > 0)
        args ~= ["--delay", delayMs.to!string];
    try {
        fw.pipes = pipeProcess(args, Redirect.stdout | Redirect.stderr, env);
    } catch (ProcessException e) {
        stderr.writeln("SKIP: failed to spawn fake worker: ", e.msg);
        return fw;
    }
    fw.pid = fw.pipes.pid;

    auto re = regex(`listening on (http://\S+)`);
    string line = fw.pipes.stdout.readln();
    auto m = matchFirst(line, re);
    if (m.empty) {
        stderr.writeln("SKIP: fake worker did not report a listening URL (got: '", line, "')");
        try { kill(fw.pid); wait(fw.pid); } catch (Exception) {}
        return fw;
    }
    fw.baseUrl = m[1].strip;
    fw.ok = true;
    return fw;
}

void teardownAi3dFakeWorker(ref Ai3dFakeWorker fw) {
    if (fw.pid !is null) {
        try { kill(fw.pid); } catch (Exception) {}
        try { wait(fw.pid); } catch (Exception) {}
    }
    if (fw.dataDir.length && exists(fw.dataDir)) {
        try { rmdirRecurse(fw.dataDir); } catch (Exception) {}
    }
}

void ai3dRemoveQuiet(string path) {
    try { remove(path); } catch (Exception) {}
}

string ai3dWriteTempPng() {
    const path = buildPath(tempDir(), "vibe3d-ai3d-test-" ~ randomUUID().toString() ~ ".png");
    write(path, ai3dPng1x1);
    return path;
}

/// Poll `pred` at a 5ms cadence until it returns true or `timeoutMs` elapses;
/// always evaluates `pred` once more after a timeout (so a predicate that
/// only just became true at the deadline is not missed).
bool ai3dWaitUntil(scope bool delegate() pred, int timeoutMs) {
    auto deadline = MonoTime.currTime + timeoutMs.msecs;
    while (MonoTime.currTime < deadline) {
        if (pred()) return true;
        Thread.sleep(5.msecs);
    }
    return pred();
}
