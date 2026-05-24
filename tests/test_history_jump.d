// Multi-step jump in CommandHistory (Phase 2 of
// the history-panel design doc). Each row click in the
// History panel translates to history.jumpTo(target) — internally
// undo/redo repeated until undoStack.length == target.
//
// Uses /api/transform translates as the recorded ops: simple
// snapshot-based commands with well-tested undo/redo paths, so the
// test exercises jumpTo mechanics without confounding from
// tool-driven entries.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

double[3] vertexPos(int i) {
    auto verts = getJson("/api/model")["vertices"].array;
    auto a = verts[i].array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

size_t historyLen(string side) {
    auto j = getJson("/api/history");
    return j[side].array.length;
}

bool approxEq(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

// Wipe history at test entry so prior-test entries don't bleed
// across. /api/reset only resets the mesh; the undo stack is
// global to the worker's vibe3d session. Walking history via
// /api/undo against a post-reset mesh is INCOHERENT (snapshots
// were captured against earlier baselines). history.clear is the
// correct wipe.
void clearHistory() {
    postJson("/api/command", "history.clear");
}

void translate(double dx) {
    auto resp = postJson("/api/transform",
        `{"kind":"translate","delta":[` ~ dx.to!string ~ `,0,0]}`);
    assert(resp["status"].str == "ok", "translate failed: " ~ resp.toString);
}

unittest { // jumpTo walks undo/redo correctly. Build 3 translates,
           // jump to middle, end, beginning, end again. Each step
           // observed via v6.x.
    postJson("/api/reset", "");
    clearHistory();
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);

    size_t baseLen = historyLen("undo");

    translate(0.1);    // baseLen+1
    translate(0.1);    // baseLen+2
    translate(0.1);    // baseLen+3

    size_t fullLen = baseLen + 3;
    assert(historyLen("undo") == fullLen,
        "expected " ~ fullLen.to!string ~ " entries; got "
        ~ historyLen("undo").to!string);
    assert(approxEq(vertexPos(6)[0], 0.8, 1e-4),
        "after 3 translates v6.x=0.8; got "
        ~ vertexPos(6)[0].to!string);

    // Jump back 2 steps (target = fullLen - 2 = baseLen + 1).
    auto r = postJson("/api/history/jump",
        ("{\"target\":" ~ (baseLen + 1).to!string ~ "}"));
    assert(r["status"].str == "ok",
        "jump to baseLen+1 failed: " ~ r.toString);
    assert(historyLen("undo") == baseLen + 1
        && historyLen("redo") >= 2,
        "expected undo=baseLen+1 redo>=2; got undo="
        ~ historyLen("undo").to!string ~ " redo="
        ~ historyLen("redo").to!string);
    assert(approxEq(vertexPos(6)[0], 0.6, 1e-4),
        "v6.x after 2-step undo should be 0.6; got "
        ~ vertexPos(6)[0].to!string);

    // Jump all the way back (target=0).
    r = postJson("/api/history/jump", `{"target":0}`);
    assert(r["status"].str == "ok",
        "jump to 0 failed: " ~ r.toString);
    assert(historyLen("undo") == 0);
    assert(approxEq(vertexPos(6)[0], 0.5, 1e-4),
        "v6.x at target=0 should be 0.5; got "
        ~ vertexPos(6)[0].to!string);

    // Jump forward to fullLen (everything reapplied).
    r = postJson("/api/history/jump",
        ("{\"target\":" ~ fullLen.to!string ~ "}"));
    assert(r["status"].str == "ok",
        "forward jump to fullLen failed: " ~ r.toString);
    assert(historyLen("undo") == fullLen);
    assert(approxEq(vertexPos(6)[0], 0.8, 1e-4),
        "v6.x at target=fullLen should be 0.8; got "
        ~ vertexPos(6)[0].to!string);
}

unittest { // Out-of-range target clamps silently to maxTarget.
    postJson("/api/reset", "");
    clearHistory();
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);

    size_t baseLen = historyLen("undo");
    translate(0.2);

    size_t fullLen = baseLen + 1;
    // Walk to 0 to populate redo.
    postJson("/api/history/jump", `{"target":0}`);
    assert(historyLen("undo") == 0);

    // target=999 → clamp to fullLen.
    auto r = postJson("/api/history/jump", `{"target":999}`);
    assert(r["status"].str == "ok",
        "out-of-range jump should succeed (clamped): " ~ r.toString);
    assert(historyLen("undo") == fullLen);
    assert(approxEq(vertexPos(6)[0], 0.7, 1e-4),
        "v6.x after clamped-forward jump should be 0.7; got "
        ~ vertexPos(6)[0].to!string);
}

unittest { // Negative target is rejected as an error.
    postJson("/api/reset", "");
    auto r = postJson("/api/history/jump", `{"target":-1}`);
    assert(r["status"].str == "error",
        "negative target should error; got " ~ r.toString);
}

unittest { // Missing target field is rejected.
    postJson("/api/reset", "");
    auto r = postJson("/api/history/jump", `{}`);
    assert(r["status"].str == "error",
        "missing target should error; got " ~ r.toString);
}
