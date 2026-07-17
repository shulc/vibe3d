// Tests for the AI Modeling Copilot Phase 2 (task 0402, doc/ai_copilot_plan.md):
// the passive findings-list panel's ONLY act-on — copilot.selectFinding —
// must SELECT the finding's element set through the normal command/history
// path (Ctrl+Z-undoable, promoteGeometryType) and do NOTHING ELSE (no
// mutation, no frame-to-fit, no tool-arming). copilot.analyze is the
// read-only refresh that populates the list. Both are dispatched via
// /api/command — the same path the panel's Analyze button / row click use,
// so this test drives the identical code path a real UI click would.
//
// Task 0422: the AI Modeling Copilot is paused behind kCopilotEnabled —
// copilot.analyze/copilot.selectFinding are no longer registered commands
// while it's off. Every unittest below early-skips in that state so the
// suite stays green; flipping kCopilotEnabled back to `true` re-enables
// every assertion as-is.

import std.net.curl;
import std.json;
import std.algorithm : sort;
import std.stdio : stderr;
import ai.copilot_gate : kCopilotEnabled;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void resetCube() {
    auto resp = postJson("/api/reset?type=cube", "");
    assert(resp["status"].str == "ok", "/api/reset cube failed");
}

void runCmd(string argstring) {
    auto r = postJson("/api/command", argstring);
    assert(r["status"].str == "ok",
        "/api/command \"" ~ argstring ~ "\" failed: " ~ r.toString);
}

// Fire-and-forget: used where the command is EXPECTED to report an error
// (a guard-clause apply() returning false, e.g. the AI-off inert case or an
// out-of-range index) — the point of the assertion is the (lack of a)
// selection side effect, not the HTTP status.
void runCmdIgnoringError(string argstring) {
    postJson("/api/command", argstring);
}

JSONValue selection() { return getJson("/api/selection"); }

long[] sortedLongs(JSONValue arr) {
    long[] r;
    foreach (v; arr.array) r ~= v.integer;
    r.sort();
    return r;
}

unittest { // act-on selects the finding's element set, undoably
    if (!kCopilotEnabled) { stderr.writeln("SKIP: test_copilot_panel (kCopilotEnabled=false, task 0422)"); return; }
    resetCube();
    runCmd("ai.enable");

    auto before = selection();
    assert(before["selectedVertices"].array.length == 0);
    assert(before["selectedEdges"].array.length == 0);
    assert(before["selectedFaces"].array.length == 0);

    runCmd("copilot.analyze");

    // Independently confirm what findings[0] should be via the Phase-1
    // endpoint — analyzeMesh() is deterministic over the same (unmutated)
    // mesh, so /api/ai/analyze and copilot.analyze's stored result agree.
    auto findings = getJson("/api/ai/analyze");
    assert(findings.type == JSONType.array && findings.array.length >= 1,
        "cube should yield at least one finding to act on");
    auto f0 = findings.array[0];
    assert(f0["category"].str == "subdivReadiness");
    auto expectedEdges = sortedLongs(f0["edges"]);
    assert(expectedEdges.length > 0);

    runCmd("copilot.selectFinding index:0");

    auto sel = selection();
    assert(sel["mode"].str == "edges",
        "act-on must select in edge mode: " ~ sel.toString);
    assert(sel["selType"].str == "edge");
    assert(sortedLongs(sel["selectedEdges"]) == expectedEdges,
        "act-on must select exactly the finding's edge set: " ~ sel.toString);
    // Select-ONLY: no other element type is touched.
    assert(sel["selectedVertices"].array.length == 0);
    assert(sel["selectedFaces"].array.length == 0);

    // Ctrl+Z (history.undo) must revert the selection change like every
    // other selection command (CmdFlags.UiState — same class as mesh.select).
    runCmd("history.undo");
    auto afterUndo = selection();
    assert(afterUndo["selectedEdges"].array.length == 0,
        "undo must revert the act-on selection: " ~ afterUndo.toString);
}

unittest { // AI-off: act-on is inert (no auto-apply, no selection change)
    if (!kCopilotEnabled) { stderr.writeln("SKIP: test_copilot_panel (kCopilotEnabled=false, task 0422)"); return; }
    resetCube();
    runCmd("ai.enable");
    runCmd("copilot.analyze"); // populate findings while AI is on
    runCmd("ai.disable");

    auto before = selection();

    runCmdIgnoringError("copilot.selectFinding index:0");

    auto after = selection();
    assert(before == after,
        "AI-off must leave selection completely unchanged: before=" ~
        before.toString ~ " after=" ~ after.toString);
}

unittest { // an out-of-range finding index is a no-op, not a crash
    if (!kCopilotEnabled) { stderr.writeln("SKIP: test_copilot_panel (kCopilotEnabled=false, task 0422)"); return; }
    resetCube();
    runCmd("ai.enable");
    runCmd("copilot.analyze");

    auto before = selection();
    runCmdIgnoringError("copilot.selectFinding index:999");
    auto after = selection();
    assert(before == after,
        "an out-of-range finding index must not change selection: " ~
        after.toString);
}

unittest { // copilot.analyze itself never touches selection (pure read)
    if (!kCopilotEnabled) { stderr.writeln("SKIP: test_copilot_panel (kCopilotEnabled=false, task 0422)"); return; }
    resetCube();
    runCmd("ai.enable");
    runCmd("select.vertex"); // put the editor in a known, non-default mode

    auto before = selection();
    runCmd("copilot.analyze");
    auto after = selection();
    assert(before == after,
        "copilot.analyze must not change selection: before=" ~
        before.toString ~ " after=" ~ after.toString);
}
