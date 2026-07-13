// test_ai3d_ui.d — HTTP-driven acceptance test for the AI3D main-thread
// wiring (task 0381, doc/ai3d_ui_plan.md Phase 2): the app-owned
// Ai3dJobController's per-frame drain -> onAi3dEvent -> undoable
// ai3d.importResult path, exercised end-to-end against the REAL running
// vibe3d --test process (not a simulated in-process mock — Ai3dImportResult
// eventually touches the GPU/display-refresh path, which needs a real GL
// context that only the live process has).
//
// There is no production HTTP surface for the async controller until the
// Phase 3 modal exists (a live UI picker + Generate/Cancel button click), so
// this drives the test-only `ai3d.generate.start` / `ai3d.generate.cancel`
// hooks (commands/ai3d/generate_test_hooks.d, g_testMode-gated) instead —
// exactly the same "test-only headless hook" pattern as tool.beginSession.
//
// Skips gracefully when python3 / the worker package is unavailable.

import std.net.curl;
import std.json;
import std.stdio  : stderr;
import std.string : startsWith;
import core.thread : Thread;
import core.time   : msecs;

import ai3d_worker_helpers;

void main() {}

immutable baseUrl = "http://localhost:8080";

void resetApp() { post(baseUrl ~ "/api/reset", ""); }

JSONValue cmd(string argstring) {
    auto resp = cast(string) post(baseUrl ~ "/api/command", argstring);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ resp);
    return j;
}

JSONValue layers() { return parseJSON(cast(string) get(baseUrl ~ "/api/layers")); }

bool waitForLayerCount(size_t n, int timeoutMs) {
    return ai3dWaitUntil({ return layers()["layers"].array.length == n; }, timeoutMs);
}

// ---------------------------------------------------------------------------
// Scenario 1: successful generate -> exactly one new "AI 3D <prefix>" layer,
// which becomes active/primary; undo removes it and restores the prior
// active layer; redo re-applies it. Proves the drain -> onAi3dEvent ->
// runCommand(ai3d.importResult) path end-to-end, including the real
// GPU/display refresh (refreshDisplay) that only a live vibe3d process can
// exercise safely.
// ---------------------------------------------------------------------------
unittest {
    if (!ai3dPython3Available()) { stderr.writeln("SKIP test_ai3d_ui (no python3)"); return; }
    auto fw = spawnAi3dFakeWorker();
    scope(exit) teardownAi3dFakeWorker(fw);
    if (!fw.ok) return;

    resetApp();
    auto before = layers();
    const baseCount  = before["layers"].array.length;
    const baseActive = before["active"].integer;

    const imagePath = ai3dWriteTempPng();
    scope(exit) ai3dRemoveQuiet(imagePath);

    cmd(`ai3d.generate.start image:"` ~ imagePath ~ `" workerUrl:"` ~ fw.baseUrl ~ `"`);

    assert(waitForLayerCount(baseCount + 1, 10_000),
           "expected exactly one new layer after a successful generate");

    auto after = layers();
    auto ls = after["layers"].array;
    const newLayer = ls[$ - 1];
    assert(newLayer["name"].str.startsWith("AI 3D "),
           "new layer should be named 'AI 3D <prefix>', got: " ~ newLayer["name"].str);
    assert(newLayer["active"].type == JSONType.true_,
           "the imported layer should become the active/primary layer");
    assert(after["active"].integer == baseCount);

    // Undo removes it and restores the prior layer set + active index
    // (import_result.d restores by Layer OBJECT identity; the HTTP-visible
    // proxy for that is the full prior layer list/active index reappearing
    // exactly).
    cmd("history.undo");
    auto restored = layers();
    assert(restored["layers"].array.length == baseCount,
           "undo should remove the imported layer");
    assert(restored["active"].integer == baseActive,
           "undo should restore the prior active layer");

    // Redo re-applies it (same command, reusing the same Layer instance).
    cmd("history.redo");
    assert(waitForLayerCount(baseCount + 1, 2_000),
           "redo should re-apply the import");
}

// ---------------------------------------------------------------------------
// Scenario 2: cancel requested immediately after start() must never add a
// layer, and must leave the active layer unchanged. Exercises the
// downloaded-event-is-never-posted-for-a-cancelled-job guarantee
// (job_controller.d / ai3d.stage_artifact) all the way through the live
// app.d drain loop.
// ---------------------------------------------------------------------------
unittest {
    if (!ai3dPython3Available()) { stderr.writeln("SKIP test_ai3d_ui (no python3)"); return; }
    auto fw = spawnAi3dFakeWorker();
    scope(exit) teardownAi3dFakeWorker(fw);
    if (!fw.ok) return;

    resetApp();
    auto before = layers();
    const baseCount  = before["layers"].array.length;
    const baseActive = before["active"].integer;

    const imagePath = ai3dWriteTempPng();
    scope(exit) ai3dRemoveQuiet(imagePath);

    cmd(`ai3d.generate.start image:"` ~ imagePath ~ `" workerUrl:"` ~ fw.baseUrl ~ `"`);
    cmd("ai3d.generate.cancel"); // fired as soon as possible after start — no artificial delay

    // Bounded window for the async cancel to resolve (generous margin over
    // the ~250ms poll-tick / near-instant queued-cancel bound); this ALSO
    // ensures the controller is idle again before the next scenario's
    // ai3d.generate.start (single-in-flight is enforced across the whole
    // live process's one controller instance, not reset by /api/reset).
    Thread.sleep(2_000.msecs);

    auto after = layers();
    assert(after["layers"].array.length == baseCount,
           "a cancelled generate must never add a layer");
    assert(after["active"].integer == baseActive,
           "a cancelled generate must leave the active layer unchanged");
}

// ---------------------------------------------------------------------------
// Scenario 3: an unreachable worker (transport failure) must never add a
// layer either. No fake worker needed here — the point is the failure path.
// ---------------------------------------------------------------------------
unittest {
    resetApp();
    auto before = layers();
    const baseCount = before["layers"].array.length;

    const imagePath = ai3dWriteTempPng();
    scope(exit) ai3dRemoveQuiet(imagePath);

    cmd(`ai3d.generate.start image:"` ~ imagePath
        ~ `" workerUrl:"http://127.0.0.1:1" timeoutMs:2000`);

    Thread.sleep(2_500.msecs);
    auto after = layers();
    assert(after["layers"].array.length == baseCount,
           "a failed (unreachable worker) generate must never add a layer");
}
