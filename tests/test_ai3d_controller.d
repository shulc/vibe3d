// test_ai3d_controller.d — offline acceptance test for the AI3D async job
// controller (task 0381, doc/ai3d_ui_plan.md Phase 1). Runs the REAL
// Ai3dJobController in-process against the pure-stdlib Python fake worker
// (`python3 -m vibe3d_ai3d_worker serve --backend fake`), spawned via
// ai3d_worker_helpers.d — no GPU/torch, no vibe3d HTTP server involved.
//
// Skips gracefully (prints a notice, returns) when python3 or the worker
// package is unavailable, so CI without Python stays green.

import std.datetime.stopwatch : StopWatch, AutoStart;
import std.file : exists, readText;
import std.algorithm.searching : canFind;
import std.stdio : stderr;
import core.time : MonoTime, seconds;

import ai3d_worker_helpers;
import ai3d.job_controller : Ai3dJobController;
import ai3d.job_events : Ai3dEvent, Ai3dEventKind;

// ---------------------------------------------------------------------------
// Scenario 1: probeHealth() posts exactly one `health` event and creates no
// job. Also asserts the call itself returns near-instantly — proving the
// network round trip runs on the worker thread, never blocking the caller
// (Risk 1/2: no HTTP construction/blocking on the calling thread).
// ---------------------------------------------------------------------------
unittest {
    if (!ai3dPython3Available()) { stderr.writeln("SKIP test_ai3d_controller (no python3)"); return; }
    auto fw = spawnAi3dFakeWorker();
    scope(exit) teardownAi3dFakeWorker(fw);
    if (!fw.ok) return;

    auto c = new Ai3dJobController();

    auto sw = StopWatch(AutoStart.yes);
    c.probeHealth(fw.baseUrl);
    sw.stop();
    assert(sw.peek.total!"msecs" < 200,
           "probeHealth() must return immediately — the network call runs on the worker thread");

    Ai3dEvent[] seen;
    assert(ai3dWaitUntil({ c.drain((ref const Ai3dEvent e) { seen ~= e; }); return seen.length > 0; }, 5_000),
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
    if (!ai3dPython3Available()) { stderr.writeln("SKIP test_ai3d_controller (no python3)"); return; }
    auto fw = spawnAi3dFakeWorker();
    scope(exit) teardownAi3dFakeWorker(fw);
    if (!fw.ok) return;

    auto c = new Ai3dJobController();
    const imagePath = ai3dWriteTempPng();
    scope(exit) ai3dRemoveQuiet(imagePath);

    auto sw = StopWatch(AutoStart.yes);
    auto started = c.start(imagePath, fw.baseUrl, 10_000);
    sw.stop();
    assert(started);
    assert(sw.peek.total!"msecs" < 200,
           "start() must return immediately — the network call runs on the worker thread");

    Ai3dEvent[] all;
    string downloadedObjPath;
    bool sawSubmitted, sawDownloaded, sawTerminal;
    assert(ai3dWaitUntil({
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
    const obj = readText(downloadedObjPath);
    assert(obj.length > 0);
    assert(obj.canFind("v 0 0 0") && obj.canFind("f 1 2 3"),
           "staged artifact should be the fake backend's fixed OBJ: " ~ obj);

    assert(c.join(5_000));
}

// ---------------------------------------------------------------------------
// Scenario 3: cancel requested immediately after start() (best-effort
// "queued" window — the fake worker's own running window is only ~100ms
// today; Phase 4 adds a `--delay` hook to exercise a real mid-RUNNING
// cancel deterministically). Asserts: a terminal `cancelled` event arrives
// within a generously bounded window (absorbing process/scheduling
// jitter), no `downloaded` event is EVER posted for the cancelled job, and
// the controller is free (not busy) again afterward.
// ---------------------------------------------------------------------------
unittest {
    if (!ai3dPython3Available()) { stderr.writeln("SKIP test_ai3d_controller (no python3)"); return; }
    auto fw = spawnAi3dFakeWorker();
    scope(exit) teardownAi3dFakeWorker(fw);
    if (!fw.ok) return;

    auto c = new Ai3dJobController();
    const imagePath = ai3dWriteTempPng();
    scope(exit) ai3dRemoveQuiet(imagePath);

    assert(c.start(imagePath, fw.baseUrl, 10_000));
    c.requestCancel(); // fired as soon as possible after start() — no artificial delay

    Ai3dEvent[] all;
    bool sawTerminal, sawDownloaded;
    assert(ai3dWaitUntil({
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

    assert(ai3dWaitUntil({ return !c.busy(); }, 2_000));
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
    if (!ai3dPython3Available()) { stderr.writeln("SKIP test_ai3d_controller (no python3)"); return; }
    auto fw = spawnAi3dFakeWorker();
    scope(exit) teardownAi3dFakeWorker(fw);
    if (!fw.ok) return;

    auto c = new Ai3dJobController();
    const imagePath = ai3dWriteTempPng();
    scope(exit) ai3dRemoveQuiet(imagePath);

    assert(c.start(imagePath, fw.baseUrl, 10_000));

    bool reentered;
    bool sawTerminal;
    assert(ai3dWaitUntil({
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
