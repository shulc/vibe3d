// test_ai3d_controller.d — offline acceptance test for the AI3D async job
// controller (task 0381, doc/ai3d_ui_plan.md Phase 1). Runs the REAL
// Ai3dJobController in-process against the pure-stdlib Python fake worker
// (`python3 -m vibe3d_ai3d_worker serve --backend fake`) spawned as a
// subprocess — no GPU/torch, no vibe3d HTTP server involved.
//
// Skips gracefully (prints a notice, returns) when python3 or the worker
// package is unavailable, so CI without Python stays green.

import std.datetime.stopwatch : StopWatch, AutoStart;
import std.file : exists, mkdirRecurse, rmdirRecurse, write, tempDir;
import std.path : buildPath;
import std.process : environment, pipeProcess, Redirect, Pid, ProcessPipes,
    kill, wait, tryWait, execute, ProcessException;
import std.regex : matchFirst, regex;
import std.stdio : stderr;
import std.string : strip;
import std.uuid : randomUUID;
import core.thread : Thread;
import core.time : msecs, seconds, MonoTime;

import ai3d.job_controller : Ai3dJobController;
import ai3d.job_events : Ai3dEvent, Ai3dEventKind;

// Same 1x1 PNG fixture as tools/ai3d_worker/tests/test_worker_contract.py.
private immutable ubyte[] PNG_1X1 = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00,
    0x90, 0x77, 0x53, 0xDE,
    0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0x60, 0x60, 0x00, 0x00, 0x00, 0x04, 0x00, 0x01,
    0xF6, 0x17, 0x38, 0x55,
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

private bool python3Available() {
    try {
        auto r = execute(["python3", "--version"]);
        return r.status == 0;
    } catch (ProcessException) {
        return false;
    } catch (Exception) {
        return false;
    }
}

private struct FakeWorker {
    bool ok;
    Pid pid;
    ProcessPipes pipes;
    string baseUrl;
    string dataDir;
}

/// Spawn the fake worker with an OS-assigned port (`--port 0`) and learn the
/// actual bound port from its stdout "listening on http://host:port" line —
/// avoids any port-collision scheme across parallel test workers.
private FakeWorker spawnFakeWorker() {
    FakeWorker fw;
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

private void teardown(ref FakeWorker fw) {
    if (fw.pid !is null) {
        try { kill(fw.pid); } catch (Exception) {}
        try { wait(fw.pid); } catch (Exception) {}
    }
    if (fw.dataDir.length && exists(fw.dataDir)) {
        try { rmdirRecurse(fw.dataDir); } catch (Exception) {}
    }
}

private void removeQuiet(string path) {
    import std.file : remove;
    try { remove(path); } catch (Exception) {}
}

private string writeTempPng() {
    const path = buildPath(tempDir(), "vibe3d-ai3d-test-" ~ randomUUID().toString() ~ ".png");
    write(path, PNG_1X1);
    return path;
}

private bool waitUntil(scope bool delegate() pred, int timeoutMs) {
    auto deadline = MonoTime.currTime + timeoutMs.msecs;
    while (MonoTime.currTime < deadline) {
        if (pred()) return true;
        Thread.sleep(5.msecs);
    }
    return pred();
}

// ---------------------------------------------------------------------------
// Scenario 1: probeHealth() posts exactly one `health` event and creates no
// job. Also asserts the call itself returns near-instantly — proving the
// network round trip runs on the worker thread, never blocking the caller
// (Risk 1/2: no HTTP construction/blocking on the calling thread).
// ---------------------------------------------------------------------------
unittest {
    if (!python3Available()) { stderr.writeln("SKIP test_ai3d_controller (no python3)"); return; }
    auto fw = spawnFakeWorker();
    scope(exit) teardown(fw);
    if (!fw.ok) return;

    auto c = new Ai3dJobController();

    auto sw = StopWatch(AutoStart.yes);
    c.probeHealth(fw.baseUrl);
    sw.stop();
    assert(sw.peek.total!"msecs" < 200,
           "probeHealth() must return immediately — the network call runs on the worker thread");

    Ai3dEvent[] seen;
    assert(waitUntil({ c.drain((ref const Ai3dEvent e) { seen ~= e; }); return seen.length > 0; }, 5_000),
           "expected exactly one health event within 5s");

    assert(seen.length == 1, "probeHealth must post exactly one event");
    assert(seen[0].kind == Ai3dEventKind.health);
    assert(seen[0].healthOk, seen[0].message);
    assert(seen[0].healthProtocol == 1);
    assert(seen[0].healthBackend == "triposr");
    assert(seen[0].healthObjCapable);

    assert(c.join(5_000));
}

// ---------------------------------------------------------------------------
// Scenario 2: full generate lifecycle against the fake worker — submitted →
// (status)* → downloaded → terminal(succeeded), in that relative order, with
// the downloaded artifact staged to a real local path whose content matches
// the fake backend's fixed output.
// ---------------------------------------------------------------------------
unittest {
    if (!python3Available()) { stderr.writeln("SKIP test_ai3d_controller (no python3)"); return; }
    auto fw = spawnFakeWorker();
    scope(exit) teardown(fw);
    if (!fw.ok) return;

    auto c = new Ai3dJobController();
    const imagePath = writeTempPng();
    scope(exit) removeQuiet(imagePath);

    auto sw = StopWatch(AutoStart.yes);
    auto started = c.start(imagePath, fw.baseUrl, 10_000);
    sw.stop();
    assert(started);
    assert(sw.peek.total!"msecs" < 200,
           "start() must return immediately — the network call runs on the worker thread");

    Ai3dEvent[] all;
    string downloadedObjPath;
    bool sawSubmitted, sawDownloaded, sawTerminal;
    assert(waitUntil({
        c.drain((ref const Ai3dEvent e) {
            all ~= e;
            final switch (e.kind) {
                case Ai3dEventKind.submitted:      sawSubmitted = true; break;
                case Ai3dEventKind.downloaded:
                    sawDownloaded = true;
                    downloadedObjPath = e.objPath;
                    break;
                case Ai3dEventKind.terminal:        sawTerminal = true; break;
                case Ai3dEventKind.status:
                case Ai3dEventKind.health:
                case Ai3dEventKind.transportError:  break;
            }
        });
        return sawTerminal;
    }, 10_000), "expected a terminal event within 10s");

    assert(sawSubmitted, "expected a submitted event before terminal");
    assert(sawDownloaded, "expected a downloaded event before terminal (succeeded path)");
    // Order: downloaded must precede the terminal(succeeded) event.
    size_t downloadedIdx = size_t.max, terminalIdx = size_t.max;
    foreach (i, ref e; all) {
        if (e.kind == Ai3dEventKind.downloaded && downloadedIdx == size_t.max) downloadedIdx = i;
        if (e.kind == Ai3dEventKind.terminal && terminalIdx == size_t.max) terminalIdx = i;
    }
    assert(downloadedIdx < terminalIdx);

    auto terminalEv = all[terminalIdx];
    assert(terminalEv.state == "succeeded", terminalEv.state);
    assert(terminalEv.generation == 1);

    assert(exists(downloadedObjPath), "staged artifact must exist on disk");
    import std.file : readText;
    const obj = readText(downloadedObjPath);
    assert(obj.length > 0);
    import std.algorithm.searching : canFind;
    assert(obj.canFind("v 0 0 0") && obj.canFind("f 1 2 3"),
           "staged artifact should be the fake backend's fixed OBJ: " ~ obj);

    assert(c.join(5_000));
}

// ---------------------------------------------------------------------------
// Scenario 3: cancel requested immediately after start() (best-effort
// "queued" window — the fake worker's own running window is only ~100ms
// today; Phase 4 adds a `--delay` hook to exercise a real mid-RUNNING
// cancel deterministically). Asserts: a terminal `cancelled` event arrives
// within the ≤250ms poll-tick bound (generously bounded here at 2s to
// absorb process/scheduling jitter), no `downloaded` event is EVER posted
// for the cancelled job, and the controller is free (not busy) again
// afterward.
// ---------------------------------------------------------------------------
unittest {
    if (!python3Available()) { stderr.writeln("SKIP test_ai3d_controller (no python3)"); return; }
    auto fw = spawnFakeWorker();
    scope(exit) teardown(fw);
    if (!fw.ok) return;

    auto c = new Ai3dJobController();
    const imagePath = writeTempPng();
    scope(exit) removeQuiet(imagePath);

    assert(c.start(imagePath, fw.baseUrl, 10_000));
    c.requestCancel(); // fired as soon as possible after start() — no artificial delay

    Ai3dEvent[] all;
    bool sawTerminal, sawDownloaded;
    assert(waitUntil({
        c.drain((ref const Ai3dEvent e) {
            all ~= e;
            if (e.kind == Ai3dEventKind.terminal) sawTerminal = true;
            if (e.kind == Ai3dEventKind.downloaded) sawDownloaded = true;
        });
        return sawTerminal;
    }, 2_000), "expected a terminal event within 2s of requesting cancel");

    assert(!sawDownloaded, "a cancelled job must never post a downloaded event");
    foreach (ref e; all)
        if (e.kind == Ai3dEventKind.terminal)
            assert(e.state == "cancelled" || e.state == "failed",
                   "cancelled-before-success should terminate as cancelled (or a race-lost failed), got: " ~ e.state);

    assert(waitUntil({ return !c.busy(); }, 2_000));
    assert(c.join(5_000));
}

// ---------------------------------------------------------------------------
// Scenario 4: drain()'s delegate runs LOCK-FREE at the controller level too
// — while a job is still in flight, the drain delegate triggers MORE
// controller activity (a stand-in for `onAi3dEvent` dispatching
// `ai3d.importResult`, which itself re-enters app-level state) without
// deadlocking against the same event queue the worker thread is still
// pushing to.
// ---------------------------------------------------------------------------
unittest {
    if (!python3Available()) { stderr.writeln("SKIP test_ai3d_controller (no python3)"); return; }
    auto fw = spawnFakeWorker();
    scope(exit) teardown(fw);
    if (!fw.ok) return;

    auto c = new Ai3dJobController();
    const imagePath = writeTempPng();
    scope(exit) removeQuiet(imagePath);

    assert(c.start(imagePath, fw.baseUrl, 10_000));

    bool reentered;
    bool sawTerminal;
    assert(waitUntil({
        c.drain((ref const Ai3dEvent e) {
            if (!reentered) {
                reentered = true;
                // Re-enter the controller from inside the drain delegate —
                // would deadlock if drain() held the queue's mutex here.
                c.probeHealth(fw.baseUrl);
            }
            if (e.kind == Ai3dEventKind.terminal) sawTerminal = true;
        });
        return sawTerminal;
    }, 10_000), "expected the job to reach a terminal state without deadlocking");

    assert(reentered);
    assert(c.join(5_000));
}

void main() {}
