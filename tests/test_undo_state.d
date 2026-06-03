// Undo-service state/lockout + explicit undoability-override tests
// (undo-migration Phase 6, closes differences #4 + #5).
//
// All three behaviours are driven through the HTTP API so the test does
// not depend on ImGui rendering:
//   * /api/undo/status reports {state, lockout, canUndo, canRedo}.
//   * The undo.lockout.on/off test commands engage/release the hard
//     lockout; while locked, recording + /api/undo are no-ops and status
//     reports lockout:true.
//   * undo.test.suppress (Model + UndoSuppress) records NO entry; while
//     undo.test.force (SideEffect + UndoForce) DOES land on the stack.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

size_t historyLen(string side) {
    return getJson("/api/history")[side].array.length;
}

void translate(double dx) {
    auto resp = postJson("/api/transform",
        `{"kind":"translate","delta":[` ~ dx.to!string ~ `,0,0]}`);
    assert(resp["status"].str == "ok");
}

// Pristine history with a known mesh + selection. Selection is applied
// BEFORE the clear: /api/select records a UI-undo entry (P5), so clearing
// last guarantees an empty stack at the start of each test.
void freshSession() {
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    postJson("/api/command", "history.clear");
}

unittest { // /api/undo/status tracks active + canUndo/canRedo as edits flow.
    freshSession();

    auto s0 = getJson("/api/undo/status");
    assert(s0["state"].str == "active",
        "fresh session must be active; got " ~ s0.toString);
    assert(s0["lockout"].boolean == false, "fresh session must not be locked");
    assert(s0["canUndo"].boolean == false && s0["canRedo"].boolean == false,
        "empty stacks ⇒ canUndo/canRedo false; got " ~ s0.toString);

    translate(0.1);
    auto s1 = getJson("/api/undo/status");
    assert(s1["canUndo"].boolean == true && s1["canRedo"].boolean == false,
        "after one edit canUndo true, canRedo false; got " ~ s1.toString);

    postJson("/api/undo", "");
    auto s2 = getJson("/api/undo/status");
    assert(s2["canUndo"].boolean == false && s2["canRedo"].boolean == true,
        "after undo canRedo true; got " ~ s2.toString);
}

unittest { // Lockout freezes recording + undo; releasing restores both.
    freshSession();
    translate(0.1);              // one undoable entry on the stack
    size_t baseUndo = historyLen("undo");
    assert(baseUndo >= 1);

    // Engage the lockout.
    auto on = postJson("/api/command", "undo.lockout.on");
    assert(on["status"].str == "ok", "lockout.on failed: " ~ on.toString);
    auto sl = getJson("/api/undo/status");
    assert(sl["lockout"].boolean == true,
        "status must report lockout:true; got " ~ sl.toString);

    // A recording edit while locked must be a no-op (stack unchanged).
    translate(0.1);
    assert(historyLen("undo") == baseUndo,
        "locked-out edit must NOT record; undo grew from "
        ~ baseUndo.to!string ~ " to " ~ historyLen("undo").to!string);

    // /api/undo while locked must be a no-op too.
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "noop",
        "locked-out /api/undo must be noop; got " ~ u.toString);
    assert(historyLen("undo") == baseUndo,
        "locked-out undo must not pop the stack");

    // Release the lockout.
    auto off = postJson("/api/command", "undo.lockout.off");
    assert(off["status"].str == "ok", "lockout.off failed: " ~ off.toString);
    auto sr = getJson("/api/undo/status");
    assert(sr["lockout"].boolean == false,
        "status must report lockout:false after release; got " ~ sr.toString);

    // Undo now works again.
    auto u2 = postJson("/api/undo", "");
    assert(u2["status"].str == "ok",
        "undo after release must succeed; got " ~ u2.toString);
    assert(historyLen("undo") == baseUndo - 1,
        "released undo must pop one entry");
}

unittest { // UndoSuppress (on a Model command) ⇒ NO history entry.
    freshSession();
    size_t before = historyLen("undo");
    auto r = postJson("/api/command", "undo.test.suppress");
    assert(r["status"].str == "ok",
        "suppress command must apply; got " ~ r.toString);
    assert(historyLen("undo") == before,
        "UndoSuppress on a Model command must NOT record; undo grew from "
        ~ before.to!string ~ " to " ~ historyLen("undo").to!string);
}

unittest { // UndoForce (on a SideEffect command) ⇒ entry DOES land.
    freshSession();
    size_t before = historyLen("undo");
    auto r = postJson("/api/command", "undo.test.force");
    assert(r["status"].str == "ok",
        "force command must apply; got " ~ r.toString);
    assert(historyLen("undo") == before + 1,
        "UndoForce on a SideEffect command MUST record; undo went from "
        ~ before.to!string ~ " to " ~ historyLen("undo").to!string);
}
