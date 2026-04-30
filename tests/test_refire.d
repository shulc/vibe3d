// Tests for Phase C refire infrastructure. /api/refire opens/closes a
// refire block on the command history; while open, each /api/transform,
// /api/select, /api/command call's command goes through history.fire(),
// which reverts the previous live command before applying the new one.
// Net stack effect = 1 entry per refire block.
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
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
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
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/select failed: " ~ resp);
}

void postTransform(string body) {
    auto resp = post("http://localhost:8080/api/transform", body);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/transform failed: " ~ resp);
}

void refireBegin() {
    auto resp = post("http://localhost:8080/api/refire", `{"action":"begin"}`);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/refire begin failed: " ~ resp);
}

void refireEnd() {
    auto resp = post("http://localhost:8080/api/refire", `{"action":"end"}`);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/refire end failed: " ~ resp);
}

JSONValue postUndo() {
    return parseJSON(post("http://localhost:8080/api/undo", ""));
}

// Drain the undo stack so subsequent count-based asserts don't get
// confused by maxDepth (50) trimming. Then re-reset the cube to put the
// mesh back into a known state — that final reset is the only entry left
// on the stack at the start of the test.
void drainAndReset() {
    while (postUndo()["status"].str == "ok") {}
    resetCube();
}

JSONValue getModel() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

JSONValue getHistory() {
    return parseJSON(get("http://localhost:8080/api/history"));
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
    auto resp = post("http://localhost:8080/api/refire", `{}`);
    assert(parseJSON(resp)["status"].str == "error",
        "expected error for missing action, got: " ~ resp);
}

unittest { // unknown action returns error
    resetCube();
    auto resp = post("http://localhost:8080/api/refire", `{"action":"toggle"}`);
    assert(parseJSON(resp)["status"].str == "error",
        "expected error for unknown action, got: " ~ resp);
}

unittest { // begin then end with nothing in between is a no-op
    resetCube();
    refireBegin();
    refireEnd();
    // Nothing bad should happen; subsequent ops still work normally.
    postSelect("vertices", [0]);
    auto sel = parseJSON(get("http://localhost:8080/api/selection"));
    assert(sel["selectedVertices"].array.length == 1);
}

// ---------------------------------------------------------------------------
// Refire coalesces multiple transforms into ONE undo entry
// ---------------------------------------------------------------------------

unittest { // 3 translates inside one refire block → 1 stack entry
    drainAndReset();
    postSelect("vertices", [0]);  // (-0.5, -0.5, -0.5)

    int undoBefore = cast(int)getHistory()["undo"].array.length;

    refireBegin();
    postTransform(`{"kind":"translate","delta":[1,0,0]}`);   // → ( 0.5, -0.5, -0.5)
    postTransform(`{"kind":"translate","delta":[0,1,0]}`);   // → (-0.5,  0.5, -0.5)
    postTransform(`{"kind":"translate","delta":[0,0,1]}`);   // → (-0.5, -0.5,  0.5)
    refireEnd();

    // Final state: only the LAST translate's effect survives — refire
    // reverts the previous one before each new fire. So the final mesh
    // shows v0 moved by (0,0,1) only, not the sum.
    assertVertex(0, -0.5, -0.5, 0.5, "v0 reflects only last refire fire");

    // The whole block lands as exactly 1 undo entry.
    int undoAfter = cast(int)getHistory()["undo"].array.length;
    assert(undoAfter == undoBefore + 1,
        "expected 1 entry from refire block, got delta = "
        ~ (undoAfter - undoBefore).to!string);

    // Undoing that one entry restores v0 fully.
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    assertVertex(0, -0.5, -0.5, -0.5, "v0 restored by single undo");
}

unittest { // refire with rotate then scale — only the last param survives
    import std.math : PI;
    import std.format : format;

    resetCube();
    postSelect("vertices", [6]);  // (+0.5, +0.5, +0.5)

    refireBegin();
    // Pretend the user is dragging a rotate slider — first 90deg, then 180deg.
    postTransform(format(
        `{"kind":"rotate","axis":[0,1,0],"angle":%.10f,"pivot":[0,0,0]}`,
        PI / 2));
    postTransform(format(
        `{"kind":"rotate","axis":[0,1,0],"angle":%.10f,"pivot":[0,0,0]}`,
        PI));
    refireEnd();

    // 180 around Y about origin: (x,y,z) → (-x, y, -z).
    // v6 = (0.5, 0.5, 0.5) → (-0.5, 0.5, -0.5)
    assertVertex(6, -0.5, 0.5, -0.5, "v6 after final 180deg rotate");

    auto u = postUndo();
    assert(u["status"].str == "ok");
    assertVertex(6, 0.5, 0.5, 0.5, "v6 restored after undoing the refire block");
}

// ---------------------------------------------------------------------------
// Refire with an empty body (no fires) doesn't push anything
// ---------------------------------------------------------------------------

unittest { // empty refire block produces 0 stack entries
    drainAndReset();
    int undoBefore = cast(int)getHistory()["undo"].array.length;

    refireBegin();
    refireEnd();

    int undoAfter = cast(int)getHistory()["undo"].array.length;
    assert(undoAfter == undoBefore,
        "empty refire block should not push, got delta = "
        ~ (undoAfter - undoBefore).to!string);
}

// ---------------------------------------------------------------------------
// Mesh state after refire matches what would happen if the user had only
// fired the last command (= MODO refire semantics)
// ---------------------------------------------------------------------------

unittest { // refire result == direct apply of the last fire
    resetCube();
    postSelect("vertices", [0]);

    refireBegin();
    postTransform(`{"kind":"translate","delta":[2,0,0]}`);   // way past
    postTransform(`{"kind":"translate","delta":[0.3,0,0]}`); // settle
    postTransform(`{"kind":"translate","delta":[0.7,0,0]}`); // final
    refireEnd();

    // v0 final = original + 0.7 (the LAST fire's delta) — earlier fires
    // were reverted before each new one.
    assertVertex(0, 0.2, -0.5, -0.5, "v0 = original + 0.7 (final delta only)");
}

// ---------------------------------------------------------------------------
// Outside refire, /api/transform behaves as before (every call = 1 entry)
// ---------------------------------------------------------------------------

unittest { // 3 separate transforms (no refire) = 3 stack entries
    drainAndReset();
    postSelect("vertices", [0]);

    int undoBefore = cast(int)getHistory()["undo"].array.length;

    postTransform(`{"kind":"translate","delta":[1,0,0]}`);
    postTransform(`{"kind":"translate","delta":[0,1,0]}`);
    postTransform(`{"kind":"translate","delta":[0,0,1]}`);

    int undoAfter = cast(int)getHistory()["undo"].array.length;
    int delta = undoAfter - undoBefore;
    assert(delta == 3,
        "expected 3 entries from sequential transforms, got delta = "
        ~ delta.to!string);

    // All three deltas accumulate (each is its own apply, no revert).
    assertVertex(0, 0.5, 0.5, 0.5, "v0 = original + (1,1,1)");
}

// ---------------------------------------------------------------------------
// Begin twice (no end) — defensive: existing block commits before the new
// one opens. (Useful if a tool was killed mid-drag without an end call.)
// ---------------------------------------------------------------------------

unittest { // refireBegin twice — middle commits, second block opens fresh
    resetCube();
    postSelect("vertices", [0]);

    refireBegin();
    postTransform(`{"kind":"translate","delta":[0.1,0,0]}`);
    // No refireEnd — instead a second begin should commit the dangling
    // block as one entry, then open a fresh one.
    refireBegin();
    postTransform(`{"kind":"translate","delta":[0,0.2,0]}`);
    refireEnd();

    // Final v0: the FIRST block landed at (-0.4,-0.5,-0.5) (delta 0.1 in X).
    // Then the SECOND block fired translate(+0.2 Y) on that state →
    // (-0.4, -0.3, -0.5).
    assertVertex(0, -0.4, -0.3, -0.5, "v0 after two-block defensive flow");

    // Two stack entries (one per block).
    auto u1 = postUndo();
    assert(u1["status"].str == "ok", "1st undo failed: " ~ u1.toString);
    assertVertex(0, -0.4, -0.5, -0.5, "after 1st undo: 2nd block reverted");

    auto u2 = postUndo();
    assert(u2["status"].str == "ok", "2nd undo failed: " ~ u2.toString);
    assertVertex(0, -0.5, -0.5, -0.5, "after 2nd undo: 1st block reverted");
}
