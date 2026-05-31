module test_command_block;

// Tests for command-block (begin/end) grouping in the undo system.
//
// /api/history/block {"action":"begin","label":"..."} opens a command block;
// {"action":"end"} closes it. While open, every undoable command recorded
// (via /api/command, /api/transform, /api/select) is folded into the block
// and lands as ONE undo entry — a CompositeCommand whose undo() reverts all
// children in reverse and whose redo() re-applies them forward.
//
// Coverage:
//   1. Two transforms inside a block → ONE undo entry; undo reverts BOTH;
//      redo re-applies both.
//   2. Nested blockBegin/blockBegin flattens → still ONE entry.
//   3. Empty block → zero entries (no-op).
//   4. Block does not regress normal (un-blocked) recording.
//
// Cube layout (centered at origin, size 1):
//   v0=(-,-,-)  v1=(+,-,-)  v2=(+,+,-)  v3=(-,+,-)
//   v4=(-,-,+)  v5=(+,-,+)  v6=(+,+,+)  v7=(-,+,+)

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "/api/reset failed: " ~ cast(string)resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) {
        if (i > 0) idxJson ~= ",";
        idxJson ~= v.to!string;
    }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "/api/select failed: " ~ cast(string)resp);
}

void postTransform(string body) {
    auto resp = post("http://localhost:8080/api/transform", body);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "/api/transform failed: " ~ cast(string)resp);
}

void blockBegin(string label) {
    auto resp = post("http://localhost:8080/api/history/block",
        `{"action":"begin","label":"` ~ label ~ `"}`);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "/api/history/block begin failed: " ~ cast(string)resp);
}

void blockEnd() {
    auto resp = post("http://localhost:8080/api/history/block",
        `{"action":"end"}`);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "/api/history/block end failed: " ~ cast(string)resp);
}

JSONValue postUndo() {
    return parseJSON(cast(string)post("http://localhost:8080/api/undo", ""));
}

JSONValue postRedo() {
    return parseJSON(cast(string)post("http://localhost:8080/api/redo", ""));
}

// Drain the undo stack so count-based asserts aren't confused by maxDepth
// trimming, then re-reset the cube to a known state.
void drainAndReset() {
    while (postUndo()["status"].str == "ok") {}
    resetCube();
}

JSONValue getModel() {
    return parseJSON(cast(string)get("http://localhost:8080/api/model"));
}

JSONValue getHistory() {
    return parseJSON(cast(string)get("http://localhost:8080/api/history"));
}

double[3] vertexAt(int idx) {
    auto m = getModel();
    auto v = m["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

void assertVertex(int idx, double x, double y, double z, string label) {
    auto v = vertexAt(idx);
    assert(approxEqual(v[0], x),
        label ~ ": v" ~ idx.to!string ~ ".x expected " ~ x.to!string
        ~ ", got " ~ v[0].to!string);
    assert(approxEqual(v[1], y),
        label ~ ": v" ~ idx.to!string ~ ".y expected " ~ y.to!string
        ~ ", got " ~ v[1].to!string);
    assert(approxEqual(v[2], z),
        label ~ ": v" ~ idx.to!string ~ ".z expected " ~ z.to!string
        ~ ", got " ~ v[2].to!string);
}

// ---------------------------------------------------------------------------
// Begin/End shape & error handling
// ---------------------------------------------------------------------------

unittest { // missing action returns error
    resetCube();
    auto resp = post("http://localhost:8080/api/history/block", `{}`);
    assert(parseJSON(cast(string)resp)["status"].str == "error",
        "expected error for missing action, got: " ~ cast(string)resp);
}

unittest { // unknown action returns error
    resetCube();
    auto resp = post("http://localhost:8080/api/history/block",
        `{"action":"pause"}`);
    assert(parseJSON(cast(string)resp)["status"].str == "error",
        "expected error for unknown action, got: " ~ cast(string)resp);
}

// ---------------------------------------------------------------------------
// 1. Two transforms inside a block coalesce into ONE undo entry; undo reverts
//    BOTH children (unlike refire, which keeps only the last).
// ---------------------------------------------------------------------------

unittest {
    drainAndReset();
    postSelect("vertices", [0]);  // (-0.5, -0.5, -0.5)

    int undoBefore = cast(int)getHistory()["undo"].array.length;

    blockBegin("Move X then Y");
    postTransform(`{"kind":"translate","delta":[1,0,0]}`);  // → ( 0.5, -0.5, -0.5)
    postTransform(`{"kind":"translate","delta":[0,1,0]}`);  // → ( 0.5,  0.5, -0.5)
    blockEnd();

    // Both translates ACCUMULATE — a block re-runs every child, it does not
    // revert-then-reapply like refire. Final = original + (1,1,0).
    assertVertex(0, 0.5, 0.5, -0.5, "v0 reflects BOTH block children");

    // The whole block lands as exactly 1 undo entry.
    int undoAfter = cast(int)getHistory()["undo"].array.length;
    assert(undoAfter == undoBefore + 1,
        "expected 1 entry from command block, got delta = "
        ~ (undoAfter - undoBefore).to!string);

    // Undoing that ONE entry restores v0 fully (both children reverted).
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    assertVertex(0, -0.5, -0.5, -0.5, "v0 fully restored by single undo");

    // Redo re-applies both children in forward order.
    auto r = postRedo();
    assert(r["status"].str == "ok", "redo failed: " ~ r.toString);
    assertVertex(0, 0.5, 0.5, -0.5, "v0 = original + (1,1,0) after redo");
}

// ---------------------------------------------------------------------------
// 2. Nested blocks flatten — begin/begin/.../end/end → still ONE entry that
//    undoes every child.
// ---------------------------------------------------------------------------

unittest {
    drainAndReset();
    postSelect("vertices", [0]);  // (-0.5, -0.5, -0.5)

    int undoBefore = cast(int)getHistory()["undo"].array.length;

    blockBegin("Outer");
    postTransform(`{"kind":"translate","delta":[1,0,0]}`);  // child 1
    blockBegin("Inner");                                    // flattens
    postTransform(`{"kind":"translate","delta":[0,1,0]}`);  // child 2
    postTransform(`{"kind":"translate","delta":[0,0,1]}`);  // child 3
    blockEnd();   // inner end — defers (no entry yet)
    postTransform(`{"kind":"translate","delta":[1,0,0]}`);  // child 4
    blockEnd();   // outer end — commits the single composite

    // All four children accumulate: original + (2,1,1).
    assertVertex(0, 1.5, 0.5, 0.5, "v0 = original + (2,1,1) from flattened nest");

    // Only ONE entry from the whole nested structure.
    int undoAfter = cast(int)getHistory()["undo"].array.length;
    assert(undoAfter == undoBefore + 1,
        "nested blocks must produce exactly 1 entry, got delta = "
        ~ (undoAfter - undoBefore).to!string);

    // One undo reverts every child.
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    assertVertex(0, -0.5, -0.5, -0.5, "v0 fully restored by single undo of nest");
}

// ---------------------------------------------------------------------------
// 3. Empty block — no commands recorded between begin and end → 0 entries.
// ---------------------------------------------------------------------------

unittest {
    drainAndReset();
    int undoBefore = cast(int)getHistory()["undo"].array.length;

    blockBegin("Nothing");
    blockEnd();

    int undoAfter = cast(int)getHistory()["undo"].array.length;
    assert(undoAfter == undoBefore,
        "empty block must not push, got delta = "
        ~ (undoAfter - undoBefore).to!string);

    // A nested empty block is also a no-op.
    blockBegin("Outer empty");
    blockBegin("Inner empty");
    blockEnd();
    blockEnd();
    int undoAfter2 = cast(int)getHistory()["undo"].array.length;
    assert(undoAfter2 == undoBefore,
        "nested empty block must not push, got delta = "
        ~ (undoAfter2 - undoBefore).to!string);

    // Subsequent ops still work normally after empty blocks.
    postSelect("vertices", [0]);
    auto sel = parseJSON(cast(string)get("http://localhost:8080/api/selection"));
    assert(sel["selectedVertices"].array.length == 1);
}

// ---------------------------------------------------------------------------
// 4. Outside a block, recording is unchanged — each command is its own entry.
// ---------------------------------------------------------------------------

unittest {
    drainAndReset();
    postSelect("vertices", [0]);

    int undoBefore = cast(int)getHistory()["undo"].array.length;

    postTransform(`{"kind":"translate","delta":[1,0,0]}`);
    postTransform(`{"kind":"translate","delta":[0,1,0]}`);

    int undoAfter = cast(int)getHistory()["undo"].array.length;
    assert(undoAfter - undoBefore == 2,
        "two un-blocked transforms must be 2 entries, got delta = "
        ~ (undoAfter - undoBefore).to!string);

    // Each undoes independently (one entry per transform).
    auto u1 = postUndo();
    assert(u1["status"].str == "ok");
    assertVertex(0, 0.5, -0.5, -0.5, "after 1 undo: only 2nd transform reverted");
    auto u2 = postUndo();
    assert(u2["status"].str == "ok");
    assertVertex(0, -0.5, -0.5, -0.5, "after 2 undos: both reverted");
}
