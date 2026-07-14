// Tests for the AI Modeling Copilot Phase 3 (task 0402, doc/ai_copilot_plan.md):
// copilot.cycleFinding must move the panel's active finding (wrapping at the
// list bounds) and perform the SAME select-only act-on a row click performs,
// sharing copilot.selectFinding's code path (commands/copilot/cycle_finding.d
// delegates to CopilotSelectFindingCommand internally) — so cycling tracks
// selection exactly like Phase 2's act-on does, with the same AI-off
// inertness discipline (checked in the command, not just the panel UI).
//
// The ghost overlay itself (copilot_overlay.d) is a pure GL draw with no
// HTTP-observable side effect — it is exercised for "does it crash" via a
// live probe during development, but its actual on-screen appearance needs
// the owner's live GUI eyeball (headless cannot verify appearance).

import std.net.curl;
import std.json;
import std.algorithm : sort;

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

void resetGrid(int n) {
    import std.conv : to;
    auto resp = postJson("/api/reset?type=grid&n=" ~ n.to!string, "");
    assert(resp["status"].str == "ok", "/api/reset grid failed");
}

void runCmd(string argstring) {
    auto r = postJson("/api/command", argstring);
    assert(r["status"].str == "ok",
        "/api/command \"" ~ argstring ~ "\" failed: " ~ r.toString);
}

// Fire-and-forget: used where the command is EXPECTED to report an error
// (a guard-clause apply() returning false, e.g. the AI-off inert case or an
// empty findings list) — the point of the assertion is the (lack of a)
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

long[] edgesOf(JSONValue finding) { return sortedLongs(finding["edges"]); }

unittest { // cycle tracks selection to the next/prev finding, wrapping at bounds
    resetCube();
    runCmd("ai.enable");
    runCmd("copilot.analyze");

    auto findings = getJson("/api/ai/analyze").array;
    assert(findings.length >= 1, "cube should yield at least one finding");
    immutable int n = cast(int) findings.length;

    // Establish a known starting point exactly like a row click would.
    runCmd("copilot.selectFinding index:0");
    assert(sortedLongs(selection()["selectedEdges"]) == edgesOf(findings[0]));

    if (n >= 2) {
        runCmd("copilot.cycleFinding dir:1");
        assert(sortedLongs(selection()["selectedEdges"]) == edgesOf(findings[1]),
            "cycle dir:1 from index 0 must select finding[1]'s edges");

        // From index 1, (n-1) more dir:1 steps must wrap all the way back
        // around to index 0.
        foreach (_; 0 .. n - 1)
            runCmd("copilot.cycleFinding dir:1");
        assert(sortedLongs(selection()["selectedEdges"]) == edgesOf(findings[0]),
            "cycling dir:1 all the way around must wrap back to index 0");

        // From index 0, dir:-1 must wrap to the LAST index (n-1), not go
        // out of range.
        runCmd("copilot.cycleFinding dir:-1");
        assert(sortedLongs(selection()["selectedEdges"]) == edgesOf(findings[n - 1]),
            "cycle dir:-1 from index 0 must wrap to the last finding");
    } else {
        // Single finding: the wrap collapses to the same index both ways —
        // selection stays on the (only) finding's element set (the inner
        // act-on still re-runs — idempotent re-select — see cycle_finding.d).
        runCmd("copilot.cycleFinding dir:1");
        assert(sortedLongs(selection()["selectedEdges"]) == edgesOf(findings[0]),
            "with a single finding, cycling dir:1 must stay on it");
        runCmd("copilot.cycleFinding dir:-1");
        assert(sortedLongs(selection()["selectedEdges"]) == edgesOf(findings[0]),
            "with a single finding, cycling dir:-1 must also stay on it");
    }
}

unittest { // no active finding yet: dir:1 starts at the front, dir:-1 at the back
    resetCube();
    runCmd("ai.enable");
    runCmd("copilot.analyze"); // setFindings() resets active_ to -1

    auto findings = getJson("/api/ai/analyze").array;
    assert(findings.length >= 1);
    immutable int n = cast(int) findings.length;

    runCmd("copilot.cycleFinding dir:1");
    assert(sortedLongs(selection()["selectedEdges"]) == edgesOf(findings[0]),
        "first cycle dir:1 with no prior active finding must select index 0");

    runCmd("copilot.analyze"); // reset active_ to -1 again
    runCmd("copilot.cycleFinding dir:-1");
    assert(sortedLongs(selection()["selectedEdges"]) == edgesOf(findings[n - 1]),
        "first cycle dir:-1 with no prior active finding must select the last index");
}

unittest { // AI-off: cycle is inert (no selection change, no auto-apply)
    resetCube();
    runCmd("ai.enable");
    runCmd("copilot.analyze");
    runCmd("copilot.selectFinding index:0"); // establish a known active/selection
    runCmd("ai.disable");

    auto before = selection();
    runCmdIgnoringError("copilot.cycleFinding dir:1");
    auto after = selection();
    assert(before == after,
        "AI-off must leave selection completely unchanged on cycle: before=" ~
        before.toString ~ " after=" ~ after.toString);
}

unittest { // cycling with an empty findings list is a safe no-op, not a crash
    // CopilotPanel.findings_ is an on-demand, app-global list (Phase-0 Q6) --
    // it is NOT cleared by /api/reset, only replaced by the next
    // copilot.analyze call. So "empty findings" must be produced by actually
    // analyzing a mesh with zero findings. An EMPTY mesh is the one input that
    // yields zero across ALL Phase-4 detector categories -- a flat grid now
    // legitimately reports a naked-boundary Topology finding (Phase 4 changed
    // the Phase-1 "flat grid = 0 findings" contract), so load empty instead.
    postJson("/api/load-mesh", `{"vertices":[],"faces":[]}`);
    runCmd("ai.enable");
    runCmd("copilot.analyze");
    assert(getJson("/api/ai/analyze").array.length == 0,
        "an empty mesh must yield zero findings");

    auto before = selection();
    runCmdIgnoringError("copilot.cycleFinding dir:1");
    auto after = selection();
    assert(before == after,
        "cycling with an empty findings list must not change selection: " ~
        after.toString);
}

unittest { // redo after undo of a cycle must RE-select the same finding, not advance again
    // Regression guard: cycle_finding.apply() recomputes the next index from
    // panel.active(). If undo doesn't restore active_, redo advances AGAIN
    // (finding[2]) instead of re-selecting finding[1]. select_finding.revert()
    // restores active_ (panel.restoreActive) to keep cycle redo idempotent.
    resetCube();
    runCmd("ai.enable");
    runCmd("copilot.analyze");

    auto findings = getJson("/api/ai/analyze").array;
    immutable int n = cast(int) findings.length;
    if (n < 3) return; // need >=3 to tell "re-select finding[1]" from "advance to finding[2]"

    runCmd("copilot.selectFinding index:0");
    runCmd("copilot.cycleFinding dir:1"); // -> finding[1]
    assert(sortedLongs(selection()["selectedEdges"]) == edgesOf(findings[1]),
        "cycle dir:1 from index 0 must select finding[1]");

    postJson("/api/undo", ""); // pop the cycle -> back to finding[0]
    assert(sortedLongs(selection()["selectedEdges"]) == edgesOf(findings[0]),
        "undo of a cycle must restore finding[0]'s selection");

    postJson("/api/redo", ""); // re-apply the cycle -> MUST be finding[1], not finding[2]
    assert(sortedLongs(selection()["selectedEdges"]) == edgesOf(findings[1]),
        "redo of a cycle must re-select finding[1], not advance to finding[2] "
        ~ "(cycle recomputes from panel.active(); revert() must restore it)");
}
