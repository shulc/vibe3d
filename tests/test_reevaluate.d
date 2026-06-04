// Live re-evaluation contract tests (doc/tool_reevaluate_plan.md Phase 4).
//
// Verifies the faithful "attr edit re-evaluates a LIVE tool" seam:
//   - raw HTTP tool.attr on a FRESH tool (no session) stores the value and
//     moves nothing (D4 raw-HTTP branch);
//   - tool.panelEdit (the real first-edit panel entry) on a fresh tool OPENS a
//     session and moves geometry, with DELTA accumulation (correct for the
//     delta-driven applyMovePanelDelta path);
//   - tool.attr on a LIVE session is ABSOLUTE — the first write lands at exactly
//     the injected value (zero-wipe pin, MAJOR 1) and a second write lands at
//     the second absolute value, NOT the sum (no-accumulation, BLOCKER 1 / D1);
//   - the whole session coalesces to ONE undo entry after drop (D2);
//   - a stage-attr edit (falloff) re-evaluates the live pipe immediately.
//
// All driven over HTTP via the testMode-gated hooks tool.beginSession /
// tool.panelEdit (Phase 3). Cube layout (centered at origin, size 1):
//   v0=(-,-,-)  v2=(+,+,-)  v6=(+,+,+)

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

// Run an argstring command through /api/command (the same main-thread bridge
// the keyboard/UI path uses) and assert ok.
void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "/api/command '" ~ line ~ "' failed: "
        ~ r.toString);
}

// Run an argstring command and return the parsed JSON without asserting (for
// expected-error cases).
JSONValue cmdRaw(string line) {
    return postJson("/api/command", line);
}

void resetCube() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

void selectVerts(int[] idx) {
    string s = "[";
    foreach (i, v; idx) { if (i) s ~= ","; s ~= v.to!string; }
    s ~= "]";
    auto r = postJson("/api/select", `{"mode":"vertices","indices":` ~ s ~ `}`);
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

double[3] vertexAt(int idx) {
    auto v = getJson("/api/model")["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

void assertVertex(int idx, double x, double y, double z, string label) {
    auto v = vertexAt(idx);
    assert(approxEqual(v[0], x) && approxEqual(v[1], y) && approxEqual(v[2], z),
        label ~ ": v" ~ idx.to!string ~ " expected (" ~ x.to!string ~ ","
        ~ y.to!string ~ "," ~ z.to!string ~ "), got (" ~ v[0].to!string ~ ","
        ~ v[1].to!string ~ "," ~ v[2].to!string ~ ")");
}

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

bool canUndo() {
    return getJson("/api/undo/status")["canUndo"].boolean;
}

// True when no event-log replay is in flight. The runner reuses ONE vibe3d
// per worker across all that worker's tests; a preceding test's
// /api/play-events drag drains asynchronously on the background event player,
// so its mouse-move events can still be firing when the next test starts. We
// wait for the player to go idle before establishing our baseline so that
// leftover drag input cannot perturb this test's pristine-cube assertions.
bool replayIdle() {
    import std.json : JSONType;
    auto s = getJson("/api/play-events/status");
    auto f = "finished" in s;
    return f is null || f.type != JSONType.false_;  // absent ⇒ never played ⇒ idle
}

// Establish a known baseline: deactivate any tool (commit/close a stray
// session), wait for any in-flight replay to finish, drain the undo stack
// (command_history caps at 50, which would pin count-delta assertions), reset
// the cube, and re-drain. Then VERIFY the cube is actually pristine, retrying
// the reset a few times if not — a transient cross-test input bleed clears on
// re-reset, while a genuine geometry regression would persist (reset always
// restores the cube), so the retry defends against the documented -j flake
// without masking real failures.
void drainAndReset() {
    import core.thread : Thread;
    import core.time   : msecs;
    foreach (attempt; 0 .. 8) {
        // Close any tool the previous test left active (idempotent).
        postJson("/api/command", "tool.set move off");
        // Let a lingering replay drain.
        foreach (_; 0 .. 200) {
            if (replayIdle()) break;
            Thread.sleep(10.msecs);
        }
        foreach (_; 0 .. 100) {
            if (undoCount() == 0) break;
            postJson("/api/undo", "");
        }
        resetCube();
        foreach (_; 0 .. 100) {
            if (undoCount() == 0) break;
            postJson("/api/undo", "");
        }
        // Confirm the baseline took: v6 = (0.5, 0.5, 0.5).
        auto v = vertexAt(6);
        if (approxEqual(v[0], 0.5) && approxEqual(v[1], 0.5)
            && approxEqual(v[2], 0.5))
            return;
        Thread.sleep(20.msecs);
    }
    // Last reset stands; the test's own assertions will report if it's bad.
    resetCube();
}

// ---------------------------------------------------------------------------
// Test 1 — fresh-tool raw-HTTP inertness (D4 raw-HTTP branch)
// ---------------------------------------------------------------------------
unittest {
    drainAndReset();
    selectVerts([6]);                 // v6 = (0.5, 0.5, 0.5)
    cmd("tool.set move");

    long undoBefore = undoCount();

    // Raw tool.attr on a FRESH tool (no session, no interactive flag): stores
    // the value but must move NOTHING and add NO undo entry.
    cmd("tool.attr move TX 1.5");
    assertVertex(6, 0.5, 0.5, 0.5, "fresh-tool raw tool.attr is inert");
    assert(undoCount() == undoBefore,
        "fresh-tool tool.attr must add no undo entry; before="
        ~ undoBefore.to!string ~ " after=" ~ undoCount().to!string);

    cmd("tool.set move off");
}

// ---------------------------------------------------------------------------
// Test 1b-panel — panel first-edit opens session, DELTA accumulation is correct
// ---------------------------------------------------------------------------
unittest {
    drainAndReset();
    selectVerts([6]);
    cmd("tool.set move");

    long undoBefore = undoCount();
    assert(!canUndo() || undoCount() == undoBefore, "baseline");

    // applyMovePanelDelta is delta-driven: the first edit OPENS the session and
    // moves v6 by 0.05; the second ADDS 0.05 → 0.10 total. Accumulation HERE is
    // correct (it belongs to the delta path, not the absolute tool.attr path).
    cmd("tool.panelEdit 0.05 0 0");
    assertVertex(6, 0.55, 0.5, 0.5, "panel first edit opens session, +0.05");
    cmd("tool.panelEdit 0.05 0 0");
    assertVertex(6, 0.60, 0.5, 0.5, "panel second delta accumulates to +0.10");

    // Drop: the whole session coalesces to exactly ONE undo entry.
    bool couldUndoBeforeDrop = canUndo();
    cmd("tool.set move off");
    assert(undoCount() == undoBefore + 1,
        "panel-edit session must coalesce to ONE undo entry; before="
        ~ undoBefore.to!string ~ " after=" ~ undoCount().to!string);
    assert(canUndo(), "canUndo must be true after a committed session");

    // One undo restores the original mesh.
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    assertVertex(6, 0.5, 0.5, 0.5, "one undo restores the original");
}

// ---------------------------------------------------------------------------
// Test 1b-absolute — tool.attr/reEvaluate on a live session is ABSOLUTE
// (no accumulation + no zero-wipe). Regression-pins BLOCKER 1 + MAJOR 1.
// ---------------------------------------------------------------------------
unittest {
    drainAndReset();
    selectVerts([6]);
    cmd("tool.set move");

    long undoBefore = undoCount();

    // Open a live session with NO geometry change.
    cmd("tool.beginSession");
    assertVertex(6, 0.5, 0.5, 0.5, "beginSession opens session, moves nothing");

    // First absolute write: geometry must move to EXACTLY original+0.05.
    // If replayTranslateFromBaseline() zeroed headlessTranslate (MAJOR-1 bug),
    // this first write would apply 0.0 — the zero-wipe pin.
    cmd("tool.attr move TX 0.05");
    assertVertex(6, 0.55, 0.5, 0.5, "first live attr write lands at +0.05 (zero-wipe pin)");

    // Second absolute write: lands at original+0.10, NOT +0.15 (the rev-2
    // post-mode doApply accumulation bug would have produced 0.15).
    cmd("tool.attr move TX 0.10");
    assertVertex(6, 0.60, 0.5, 0.5, "second live attr write is absolute (+0.10, not 0.15)");

    // Drop → exactly ONE new undo entry → undo restores the original.
    cmd("tool.set move off");
    assert(undoCount() == undoBefore + 1,
        "live-session attr edits coalesce to ONE undo entry; before="
        ~ undoBefore.to!string ~ " after=" ~ undoCount().to!string);
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    assertVertex(6, 0.5, 0.5, 0.5, "one undo restores the original");
}

// ---------------------------------------------------------------------------
// Test 2 — live re-eval absolute, larger values (reconfirms D1)
// ---------------------------------------------------------------------------
unittest {
    drainAndReset();
    selectVerts([6]);
    cmd("tool.set move");

    cmd("tool.beginSession");
    cmd("tool.attr move TX 1.5");
    assertVertex(6, 2.0, 0.5, 0.5, "attr TX=1.5 ⇒ v6.x=2.0");
    cmd("tool.attr move TX 2.0");
    assertVertex(6, 2.5, 0.5, 0.5, "attr TX=2.0 ⇒ v6.x=2.5 (absolute, NOT 4.0)");

    cmd("tool.set move off");
}

// ---------------------------------------------------------------------------
// Test 4 — stage re-eval: a falloff attr edit re-evaluates the live pipe NOW.
//
// With NO selection the moving set is the whole mesh, gated by falloff weights.
// A radial falloff centered at v6 with a tight radius moves only v6 at first;
// widening the falloff `size` mid-session must re-blend immediately (without
// any further tool.attr), dragging neighbors along. Still ONE entry after drop.
// ---------------------------------------------------------------------------
unittest {
    drainAndReset();
    // No selection ⇒ whole mesh is the moving set; falloff weights gate it.
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "0.5,0.5,0.5"`);
    cmd(`tool.pipe.attr falloff size "1,1,1"`);

    long undoBefore = undoCount();

    cmd("tool.beginSession");
    cmd("tool.attr move TX 1.0");
    // Tight radius: v6 (at the center) gets full weight; v0 (the far corner)
    // is outside the falloff and stays put.
    assertVertex(6, 1.5, 0.5, 0.5, "v6 full-weight under tight radial");
    assertVertex(0, -0.5, -0.5, -0.5, "v0 outside tight radial — unmoved");

    // Widen the falloff via a STAGE attr edit. No further tool.attr — the pipe
    // must re-blend immediately and pull v0 along.
    cmd(`tool.pipe.attr falloff size "4,4,4"`);
    auto v0 = vertexAt(0);
    assert(v0[0] > -0.49,
        "stage-attr edit must re-blend the live pipe immediately: v0.x should "
        ~ "have moved from -0.5, got " ~ v0[0].to!string);

    // Drop still coalesces to ONE entry.
    cmd("tool.set move off");
    assert(undoCount() == undoBefore + 1,
        "stage-re-eval session must coalesce to ONE undo entry; before="
        ~ undoBefore.to!string ~ " after=" ~ undoCount().to!string);
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    assertVertex(6, 0.5, 0.5, 0.5, "one undo restores v6");
    assertVertex(0, -0.5, -0.5, -0.5, "one undo restores v0");

    // Leave the falloff stage in a clean state for following tests.
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type none");
    cmd("tool.set move off");
}
