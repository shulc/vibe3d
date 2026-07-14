// Task 0389 integration coverage: mesh.loopSlice (Loop Slice) must NOT drop
// the per-face Subpatch flag. Owner-reported regression: on a subdiv model
// (every face marked Subpatch), running Loop Slice instantly reverted the
// WHOLE model to plain polygons. Root cause was systemic — `resetSelection()`
// unconditionally cleared subpatch, and the loop_slice kernel itself did not
// propagate the bit into the faces it rebuilds — see doc/tasks/ for the full
// writeup.
//
// This test drives the exact reported scenario end-to-end through the HTTP
// API: mark the whole cube Subpatch via mesh.subpatch_toggle (the same logic
// the Tab-key handler in app.d uses), run mesh.loopSlice, and assert every
// resulting face — pre-existing AND newly cut — is still Subpatch. A second
// case checks the inverse leak (a plain cube must not spontaneously gain
// Subpatch faces from the cut).

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

// ----- HTTP helpers (mirrors tests/test_loop_slice.d + tests/test_subpatch.d) ---

void postReset() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

void postCommand(string id) {
    auto resp = post("http://localhost:8080/api/command", `{"id":"` ~ id ~ `"}`);
    assert(parseJSON(resp)["status"].str == "ok", id ~ " failed: " ~ resp);
}

/// Post command with params JSON (e.g. `{"count":3}`). Asserts ok.
void postCommandParams(string id, string paramsJson) {
    auto resp = post("http://localhost:8080/api/command",
        `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", id ~ " failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    import std.array : appender;
    auto s = appender!string("[");
    foreach (i, v; indices) { if (i > 0) s ~= ","; s ~= v.to!string; }
    s ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ s.data ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

JSONValue getModel() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

/// Index of the undirected edge {a,b} in model["edges"], or -1.
int edgeIdx(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

bool[] subpatchFlags(JSONValue m) {
    bool[] r;
    foreach (n; m["isSubpatch"].array) r ~= n.type == JSONType.true_;
    return r;
}

// ---------------------------------------------------------------------------

unittest { // Loop Slice on an all-Subpatch cube: every pre-existing AND
           // newly-cut face must stay Subpatch (the exact owner-reported
           // regression — the whole mesh used to revert to plain polygons).
    postReset();

    // Mark the whole cube Subpatch — mirrors pressing Tab with no selection.
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
    postCommand("mesh.subpatch_toggle");
    auto marked = getModel();
    foreach (i, b; subpatchFlags(marked))
        assert(b, "face " ~ i.to!string ~ " should be Subpatch before the cut");

    // Loop Slice through the belt edge 0-1 (closed ring, default count=3;
    // same topology as tests/test_loop_slice.d's Case 2).
    int eiSeed = edgeIdx(marked, 0, 1);
    assert(eiSeed >= 0, "belt edge 0-1 must exist");
    postSelect("edges", [eiSeed]);
    postCommandParams("mesh.loopSlice", `{"count":3}`);

    auto after = getModel();
    assert(after["faceCount"].integer == 18,
           "F must be 18 after loopSlice count=3");

    auto sub = subpatchFlags(after);
    assert(sub.length == 18, "expected 18 per-face subpatch entries");
    foreach (i, b; sub)
        assert(b, "face " ~ i.to!string ~ " must still be Subpatch after Loop Slice");
}

unittest { // Loop Slice on a PLAIN cube must NOT spontaneously mark
           // anything Subpatch (inverse-leak guard, so a blanket-true bug
           // could not masquerade as the fix above).
    postReset();
    auto before = getModel();
    int eiSeed = edgeIdx(before, 0, 1);
    assert(eiSeed >= 0, "belt edge 0-1 must exist");
    postSelect("edges", [eiSeed]);
    postCommandParams("mesh.loopSlice", `{"count":3}`);

    auto after = getModel();
    assert(after["faceCount"].integer == 18, "F must be 18 after loopSlice count=3");
    foreach (i, b; subpatchFlags(after))
        assert(!b, "face " ~ i.to!string ~ " must stay plain — no face was ever marked Subpatch");
}
