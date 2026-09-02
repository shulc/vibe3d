/// test_ai_exploration.d — Unit tests for the ε-exploration controller.
///
/// Scope: PURE logic tests — the live ε→undo→re-grab path is not coverable
/// end-to-end through --test (ε is forced 0 under g_testMode).  All logic
/// is exercised via module unittests in source/ai/exploration.d (triggered by
/// the -unittest -i compile path) plus HTTP-level inertness checks below.
///
/// HTTP tests verify:
///   - Under --test, the explore hook is NOT installed (ε forced 0).
///   - The 0027 passive capture path is unchanged (byte-identical-off).
///   - undoEpoch is accessible via /api/undo/status without regression.

module test_ai_exploration;

import std.net.curl   : HTTP;
import std.json       : JSONValue, JSONType, parseJSON;
import std.string     : startsWith, indexOf;
import std.stdio      : writeln, writefln;
import std.exception  : enforce;
import std.conv       : to;
import std.file       : exists, readText, remove, tempDir;
import std.path       : buildPath;

// Pull in the exploration module so its own unittests are triggered by -i.
import ai.exploration;
import ai.interaction_log;
import ai.interaction;
import ai.training_dataset;
// Pull in command_history so its Phase-0 unittests run too.
import command_history;

// Task 1111: this file carries its OWN unittest blocks, so druntime runs them
// and never calls main() — which means the `void main() { runHttpTests(); }`
// that used to stand here had NEVER executed a single HTTP check. The body
// belongs in a unittest block, which druntime does run.
void main() {}

unittest { runHttpTests(); }

// ---------------------------------------------------------------------------
// Helper: HTTP GET/POST against the test server.
// ---------------------------------------------------------------------------
private string url(string base, string path) {
    return base ~ path;
}

private JSONValue getJson(string base, string path) {
    import std.net.curl : get;
    return parseJSON(cast(string)get(url(base, path)));
}

private JSONValue postJson(string base, string path, string body_ = "{}") {
    import std.net.curl : HTTP;
    auto http = HTTP();
    string response;
    http.onReceive = (ubyte[] data) { response ~= cast(string)data; return data.length; };
    http.method = HTTP.Method.post;
    http.url = url(base, path);
    http.setPostData(body_, "application/json");
    http.perform();
    return parseJSON(response.length ? response : `{}`);
}

private void reset(string base) {
    postJson(base, "/api/reset");
}

// ---------------------------------------------------------------------------
// runHttpTests: verifies inertness of the exploration path under --test.
// ---------------------------------------------------------------------------
void runHttpTests() {
    // NOTE: keep the literal "localhost:8080" — run_test.d isolates parallel
    // workers by textually rewriting it to that worker's port in a scratch copy
    // of the source. What stood here instead was
    // `environment.get("VIBE3D_TEST_PORT", "8080")`, and the runner has never
    // set that variable, so the moment this code started executing under -j N
    // it would have driven worker 0's instance — including POST /api/reset on
    // somebody else's scene.
    string base = "http://localhost:8080";

    // --- Inertness check 1: ε forced 0 under g_testMode -----------------------
    // We cannot directly observe whether the explore hook is set, but we CAN
    // verify that the 0027 passive capture path is unchanged: a handle grab
    // (played via event log) produces a record whose source does NOT start
    // with "live-explore:" even when VIBE3D_AI_EXPLORE is set in the
    // environment (the guard forces ε=0 regardless).
    //
    // Implementation: we use a temp AI-log file, replay an event log that
    // includes a handle apply, then check the source tag.
    //
    // Because VIBE3D_AI_LOG is only set if the test runner passes it in, and
    // we can't re-launch vibe3d from within the test, we use a simpler check:
    // assert that /api/undo/status is accessible and returns a sane structure
    // (exercises the undoEpoch accessor without regression).

    {
        reset(base);
        auto j = getJson(base, "/api/undo/status");
        assert(j.type == JSONType.object, "/api/undo/status must return an object");
        assert("canUndo" in j, "/api/undo/status must have canUndo field");

        // A reset does NOT leave an empty undo stack: it leaves a session
        // BOUNDARY entry, and the counts and the predicates report on that
        // entry differently, on purpose:
        //
        //   * `undoDepthCounts` (source/command_history.d:1049) stops at the
        //     first UndoBoundary (`:1054`), so modelDepth/uiDepth are 0 by
        //     construction — traversal stops at the boundary.
        //   * `canUndoModel` classifies the TAIL that the next strict-LIFO
        //     undo would step. That tail is the Model-class, undoable boundary,
        //     so the predicate is true even though the current-session count
        //     is zero.
        //   * `canUndo()` (`:989`) is just `undoStack.length > 0`.
        //
        // So the documented answer after a reset is the TRIPLE below. This
        // assertion previously read `canUndo must be false`, which encoded the
        // belief that a reset empties the stack. It does not — and the belief
        // survived only because this whole function never executed (task 1111:
        // druntime skipped `main`). Assert the triple, so the test now pins the
        // boundary semantics instead of merely passing.
        assert(j["canUndo"].type == JSONType.true_,
               "after reset the stack holds a boundary entry, so canUndo is true");
        assert(j["canUndoModel"].type == JSONType.true_,
               "the boundary entry is Model-class, so canUndoModel is true "
               ~ "(command_history.d tail predicate)");
        assert(j["modelDepth"].integer == 0,
               "counts stop AT the boundary, so modelDepth is 0 "
               ~ "(command_history.d:1049)");
        writeln("PASS: post-reset undo status reports the documented boundary triple");
    }

    // --- Inertness check 2: undo epoch increases after an undo ----------------
    // Reset → prim.cube (undoable) → /api/undo/status before undo → undo →
    // /api/undo/status after undo. We can't read the epoch directly over HTTP
    // today, but we can confirm canUndo flips correctly, proving the epoch
    // counter logic did not break the undo path.
    {
        size_t vertexCount() {
            return getJson(base, "/api/model")["vertices"].array.length;
        }

        reset(base);
        const vertsAtReset = vertexCount();
        auto atReset = getJson(base, "/api/undo/status");
        assert(atReset["modelDepth"].integer == 0, "reset leaves modelDepth 0");

        // The payload key is `id`. This block used to send `{"command": ...}`,
        // which /api/command answers with
        // `{"status":"error","message":"missing 'id' string field"}` — so both
        // POSTs below did NOTHING. Check the status of each, or a future
        // contract change goes silent again instead of red.
        auto mk = postJson(base, "/api/command", `{"id":"prim.cube"}`);
        assert(mk["status"].str == "ok", "prim.cube must be accepted: " ~ mk.toString);
        const vertsAfterCube = vertexCount();
        assert(vertsAfterCube > vertsAtReset,
               "prim.cube must actually add geometry, or the undo below undoes nothing");
        auto before = getJson(base, "/api/undo/status");
        assert(before["modelDepth"].integer == 1,
               "one Model entry above the boundary after prim.cube");
        assert(before["canRedo"].type == JSONType.false_,
               "a fresh action clears the redo timeline");

        auto un = postJson(base, "/api/command", `{"id":"history.undo"}`);
        assert(un["status"].str == "ok", "history.undo must be accepted: " ~ un.toString);
        auto after = getJson(base, "/api/undo/status");
        assert(after["modelDepth"].integer == 0, "the Model entry is gone after undo");
        assert(after["canRedo"].type == JSONType.true_, "undo makes redo available");
        assert(vertexCount() == vertsAtReset, "undo must restore the pre-cube geometry");

        // canUndo is NOT the signal here, and saying so is the point: the
        // boundary entry keeps it true in all three states, which is exactly
        // why the old `canUndo should be false after undo` was wrong.
        assert(atReset["canUndo"].type == JSONType.true_
            && before["canUndo"].type  == JSONType.true_
            && after["canUndo"].type   == JSONType.true_,
               "the boundary entry keeps canUndo true throughout — modelDepth "
               ~ "and canRedo are what move");
        writeln("PASS: undo path steps modelDepth 0->1->0 and arms redo, geometry restored");
    }

    // --- Inertness check 3: existing 0027 capture test not broken --------------
    // Placeholder: the 0027 capture tests are in test_ai_model_live_wiring.d
    // and test_ai_handle_candidates.d — they still pass at -j8 by the pre-commit
    // suite check.  Here we verify the sink is still registered (by checking
    // that a reset + query cycle returns valid JSON, confirming no crash).
    {
        reset(base);
        auto sel = getJson(base, "/api/selection");
        assert(sel.type == JSONType.object, "/api/selection must not crash");
        writeln("PASS: post-reset /api/selection returns valid JSON (sink not broken)");
    }

    writeln("All HTTP-level exploration inertness checks PASSED.");
}

// ---------------------------------------------------------------------------
// Additional in-process unit tests (supplement the module unittests).
// The module unittests in source/ai/exploration.d already cover all branches;
// these add cross-module coverage.
// ---------------------------------------------------------------------------

unittest { // defaultExploreSource has "live-explore:" prefix
    string s = defaultExploreSource();
    assert(s.startsWith("live-explore:"),
           "defaultExploreSource must start with live-explore:");
    assert(s.length > "live-explore:".length,
           "defaultExploreSource must append a pid");
}

unittest { // ε=0 controller is disabled and sampleOverrideIndex is always -1
    auto ctrl = new AiExplorationController(0.0f, 42u);
    assert(!ctrl.enabled());
    foreach (_; 0 .. 20)
        assert(ctrl.sampleOverrideIndex(4, 0) == -1);
}

unittest { // hasPending false initially
    auto ctrl = new AiExplorationController(1.0f, 7u);
    assert(!ctrl.hasPending());
    ctrl.discardPending();
    assert(!ctrl.hasPending());
}

unittest { // step on idle controller returns None immediately
    auto ctrl = new AiExplorationController(1.0f, 8u);
    float[16] view;
    view[] = 0.0f; view[0] = view[5] = view[10] = view[15] = 1.0f;
    auto r = ctrl.step(0UL, view, OptionalGrab());
    assert(r.kind == ResolutionKind.None);
}

unittest { // GOLD Emit record has correct appliedWinnerId + labeled by exporter
    import ai.interaction : AiCandidateKind, AiInteractionContext,
        AiAdvisorDecision;

    // Build minimal record with 3 candidates.
    AiCandidate[] cands;
    cands.length = 3;
    foreach (i; 0 .. 3) {
        cands[i].id   = "handle:" ~ i.to!string;
        cands[i].kind = AiCandidateKind.handle;
    }
    cands[0].isDefaultWinner = true;

    AiInteractionContext ctx;
    auto rec = makeAiInteractionLogRecord(
        "live-explore:test", "handles", ctx, cands, AiAdvisorDecision(), 2);
    // ε-sampled: index 2 was applied.

    string key = buildCandidateKey(cands);
    float[16] view;
    view[] = 0.0f; view[0] = view[5] = view[10] = view[15] = 1.0f;

    auto ctrl = new AiExplorationController(1.0f, 9u);
    ctrl.stagePending(rec, key, 2, 0UL, view);

    // Undo.
    ctrl.step(1UL, view, OptionalGrab());

    // Re-grab handle:0 (the default, a different candidate from index 2).
    OptionalGrab grab;
    grab.present   = true;
    grab.sortedKey = key;
    grab.partInt   = 0;
    auto resolved  = ctrl.step(1UL, view, grab);
    assert(resolved.kind == ResolutionKind.Emit);
    assert(resolved.record.appliedWinnerId == "handle:0");
    assert(resolved.record.appliedWinnerIndex == 0);

    // Feed through the REAL exporter — schema must be untouched.
    auto result = exportAiTrainingDatasetJsonl([resolved.record]);
    assert(result.stats.labeled   == 1);
    assert(result.stats.unlabeled == 0);
    assert(result.lines.length    == 1);
    assert(result.lines[0].indexOf(`"handle:0"`) >= 0);
}
