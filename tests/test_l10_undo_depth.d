// test_l10_undo_depth — task 1903 Stage L10, the S-lane witness the unit
// parity fixture cannot be.
//
// WHAT THIS ADDS OVER `tests/unit/undo_parity_l10_test.d`, which already
// compares thirteen per-plane dumps against a frozen oracle. That reader calls
// `Command.revert()` DIRECTLY, on a mesh it built itself. It therefore says
// nothing about three things this file measures:
//
//   1. THE REAL UNDO STACK. `CommandHistory.undo` is what a user reaches, and
//      it does more than call `revert()`: it opens a global delivery batch,
//      picks the nearest Model entry, and — on a `false` from that entry —
//      discards the entry AND its whole trailing suffix (regression 0099). A
//      migrated command whose `revert()` answered `false` would still make the
//      unit reader green (it asserts the return) and would silently truncate
//      history here. So every row asserts HOW MANY STEPS TOOK EFFECT: the undo
//      stack drops by EXACTLY ONE and the redo stack gains EXACTLY ONE.
//   2. THE COMMAND FUNNEL. `evaluate` false ⇒ `apply` false ⇒ the funnel
//      throws ⇒ `status:error` and NO history entry. Every row drives
//      `/api/command` and reads that contract from the outside.
//   3. `mesh.bridge` AND `mesh.sweep`, WHICH HAVE NO CELL IN THE FIXTURE.
//      Stage L10's stand cannot present two bridgeable loops or a profile plus
//      a path, and a cell built on a second stand would be measuring that
//      stand rather than the family (card 2340, decision 8). Their command
//      halves are covered HERE and nowhere else — and they are the two whose
//      batch had to GROW over a post-kernel `deleteFacesByMask` before their
//      delta could invert it, so a hole here would be a hole exactly where the
//      stage did its most invasive work.
//
// THE COMPARISON IS THE WHOLE PLANE DUMP, not a count. `/api/mesh/planes` is
// the only plane-COMPLETE readback: vertices, faces, all three mark arrays,
// all three order arrays and their counters, the edge planes, materials,
// parts, surfaces, all three set registries and their masks, and every mesh
// map. Counts round-trip on undos that lose windings, marks, set membership
// and map values — that is the defect class this whole stage exists to close.
//
// ANTI-VACUITY, PER ROW AND STATED IN THE MESSAGE: the forward must CHANGE the
// dump. A row whose command refuses, or whose operand selection silently
// selected nothing, would compare the pre-op dump against itself and be green
// under every implementation of undo.
//
// THE STACK-DEPTH ASSERTION IS A DELTA ACROSS THE UNDO, NOT AN ABSOLUTE, and
// that is not style: `CommandHistory` caps the undo stack (measured: it sits
// at 50 on a long-lived instance), and `/api/reset` does NOT clear it. An
// `undoDepth() == 1` after the apply would pass on a fresh process and fail on
// a shared one, which is the "green for the wrong reason, red for the wrong
// reason" pair. The delta across the undo is cap-independent.
//
// LANE: `./run_test.d` (lane S).
import http_client : testBaseUrl, postRaw;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

alias kBase = testBaseUrl;

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------


JSONValue postJ(string path, string body_) {
    return parseJSON(postRaw(path, body_));
}

JSONValue getJ(string path) {
    return parseJSON(cast(string) get(kBase ~ path));
}

/// The plane-COMPLETE dump, as TEXT. Compared verbatim; `provenance` is empty
/// on this endpoint, so there is nothing in it that differs by construction.
string planes() {
    return cast(string) get(kBase ~ "/api/mesh/planes");
}

size_t undoDepth() { return getJ("/api/history")["undo"].array.length; }
size_t redoDepth() { return getJ("/api/history")["redo"].array.length; }

/// One setup step: a path and a body, run for effect. Failures are NOT
/// swallowed — a setup step that refuses leaves the row measuring a stand it
/// did not build, which is the shape that makes a green meaningless.
struct Step { string path; string body_; }

void runSteps(string row, in Step[] steps) {
    foreach (i, s; steps) {
        auto resp = postRaw(s.path, s.body_);
        assert(parseJSON(resp)["status"].str == "ok",
            row ~ ": setup step " ~ i.to!string ~ " (" ~ s.path ~ ") failed: "
          ~ resp ~ " — the stand this row measures was never built");
    }
}

/// stand → command → undo, asserting the funnel's answer, the forward's
/// effect, the number of steps the undo took, and the plane-complete
/// round-trip.
void undoRoundTrip(string row, in Step[] setup, string cmdJson) {
    runSteps(row, setup);

    immutable string pre = planes();
    immutable size_t u0 = undoDepth();

    auto resp = postJ("/api/command", cmdJson);
    assert(resp["status"].str == "ok",
        row ~ ": the command must APPLY on this stand — got " ~ resp.toString
      ~ ". A refusal here would make every assertion below compare the pre-op "
      ~ "dump against itself");

    immutable string mid = planes();
    assert(mid != pre,
        row ~ ": the command answered ok and changed NO plane. Its undo is "
      ~ "then satisfied by an undo that does nothing, and this row measures "
      ~ "nothing at all — check that the setup actually selected an operand");

    // The undo stack grew by exactly one on the way in. Read as a DELTA: the
    // stack is capped and /api/reset does not clear it, so an absolute would
    // be a different assertion on a fresh process than on a shared one.
    immutable size_t u1 = undoDepth();
    immutable size_t r1 = redoDepth();
    assert(u1 == u0 + 1 || u1 == u0,
        row ~ ": the apply moved the undo stack from " ~ u0.to!string ~ " to "
      ~ u1.to!string ~ " — expected +1, or +0 only when the stack is at its "
      ~ "cap. Anything else means the funnel recorded a different number of "
      ~ "entries than the one command it ran");

    auto ru = postJ("/api/command", commandBody("history.undo"));
    assert(ru["status"].str == "ok", row ~ ": /api/undo failed: " ~ ru.toString);

    // EXACTLY ONE STEP TOOK EFFECT. A `false` from a Model entry's revert()
    // discards that entry AND its trailing suffix, so the undo side would drop
    // by more than one and the redo side would not gain (regression 0099).
    immutable size_t u2 = undoDepth();
    immutable size_t r2 = redoDepth();
    assert(u2 + 1 == u1,
        row ~ ": the undo moved the undo stack from " ~ u1.to!string ~ " to "
      ~ u2.to!string ~ " — expected exactly one step. More than one means the "
      ~ "entry's revert() answered false and CommandHistory truncated the "
      ~ "suffix behind it (regression 0099); zero means nothing was undone");
    assert(r2 == r1 + 1,
        row ~ ": the undo moved the redo stack from " ~ r1.to!string ~ " to "
      ~ r2.to!string ~ " — expected exactly +1. The entry has to arrive on the "
      ~ "redo side, or the operation cannot be replayed and the step that took "
      ~ "effect is unaccounted for");

    immutable string back = planes();
    assert(back == pre,
        row ~ ": the undo did not restore the mesh plane for plane.\n"
      ~ "  This is the whole point of the stage: counts round-trip on undos "
      ~ "that lose windings, mark words, selection-order stamps, set "
      ~ "membership and map values.\n  pre : " ~ contrast(pre, back)[0]
      ~ "\n  post: " ~ contrast(pre, back)[1]);
}

/// The two renderings WINDOWED ON THE FIRST DIFFERING CHARACTER. A leading
/// clip is the wrong instrument here: the dump is tens of kilobytes and its
/// first term is the vertex array, so a lost mark word thousands of characters
/// in would print two identical strings under the word "not".
string[2] contrast(string a, string b) {
    size_t i = 0;
    immutable size_t n = a.length < b.length ? a.length : b.length;
    while (i < n && a[i] == b[i]) ++i;
    immutable size_t ctx  = 80;
    immutable size_t from = i > ctx ? i - ctx : 0;
    static string window(string s, size_t from) {
        immutable size_t to = from + 200 < s.length ? from + 200 : s.length;
        return (from > 0 ? "…" : "") ~ s[from .. to] ~ (to < s.length ? "…" : "");
    }
    return [window(a, from), window(b, from)];
}

// ---------------------------------------------------------------------------
// The rows. ONE unittest EACH, deliberately: druntime stops a module at its
// first failing assert, so a single block would report the first broken
// command and hide the other fourteen.
//
// FIFTEEN ROWS OVER THIRTEEN CLASSES — `mesh.collapse` contributes three,
// because its three modes are three different kernels behind one class.
// ---------------------------------------------------------------------------

enum Step[] kCube        = [Step("/api/command", commandBody("scene.reset"))];
enum Step[] kCubePolyMode = [Step("/api/command", commandBody("scene.reset")),
                             Step("/api/command", "select.typeFrom polygon")];

unittest { // mesh.triple — whole-mesh fallback, no selection
    undoRoundTrip("mesh.triple", kCubePolyMode, `{"id":"mesh.triple"}`);
}

unittest { // mesh.quadruple — needs triangle pairs, so triple first
    undoRoundTrip("mesh.quadruple",
        kCubePolyMode ~ [Step("/api/command", `{"id":"mesh.triple"}`)],
        `{"id":"mesh.quadruple"}`);
}

unittest { // mesh.detriangulate — same operand shape as quadruple
    undoRoundTrip("mesh.detriangulate",
        kCubePolyMode ~ [Step("/api/command", `{"id":"mesh.triple"}`)],
        `{"id":"mesh.detriangulate"}`);
}

unittest { // poly.unify — a duplicate face is the only operand it accepts
    undoRoundTrip("poly.unify",
        [Step("/api/command", commandBody("scene.reset", `{"empty":true}`)),
         Step("/api/command", commandBody("scene.loadMesh", `{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],`
                              ~ `"faces":[[0,1,2,3],[0,1,2,3]]}`))],
        `{"id":"poly.unify"}`);
}

unittest { // mesh.mergeFaces — two ADJACENT faces; a disjoint pair refuses
    undoRoundTrip("mesh.mergeFaces",
        kCube ~ [Step("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0,2]}`))],
        `{"id":"mesh.mergeFaces"}`);
}

unittest { // mesh.collapse, polygon mode
    undoRoundTrip("mesh.collapse/polygon",
        kCube ~ [Step("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0]}`))],
        `{"id":"mesh.collapse"}`);
}

unittest { // mesh.collapse, edge mode — a different kernel behind one class
    undoRoundTrip("mesh.collapse/edge",
        kCube ~ [Step("/api/command", commandBody("mesh.select", `{"mode":"edges","indices":[0]}`))],
        `{"id":"mesh.collapse"}`);
}

unittest { // mesh.collapse, vertex mode — the third kernel
    undoRoundTrip("mesh.collapse/vertex",
        kCube ~ [Step("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0,1]}`))],
        `{"id":"mesh.collapse"}`);
}

unittest { // vert.join — the collapse-then-weld member, with its policy
    undoRoundTrip("vert.join",
        kCube ~ [Step("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0,1]}`))],
        `{"id":"vert.join"}`);
}

unittest { // vert.merge — range:fixed so the pair is inside the weld radius
    undoRoundTrip("vert.merge",
        kCube ~ [Step("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0,1]}`))],
        `{"id":"vert.merge","params":{"range":"fixed","dist":10}}`);
}

unittest { // mesh.weldVertexPair — the same weld tail through the other door
    undoRoundTrip("mesh.weldVertexPair",
        kCube ~ [Step("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0]}`))],
        `{"id":"mesh.weldVertexPair","params":{"source":1,"target":0}}`);
}

unittest { // mesh.edgeJoin — a pentagon, dissolving its one 2-valent corner
    // The two edge indices are the mesh's OWN derived order, not the sorted
    // order `/api/mesh/planes` renders: measured on this stand, [0,1] is the
    // pair that shares vertex 1. Selecting the pair the sorted dump suggests
    // makes the command refuse on its degree guard, which the assert above
    // would report as "did not apply" rather than as a wrong stand.
    undoRoundTrip("mesh.edgeJoin",
        [Step("/api/command", commandBody("scene.reset", `{"empty":true}`)),
         Step("/api/command", commandBody("scene.loadMesh", `{"vertices":[[0,0,0],[1,0,0],[2,0,0],[2,1,0],`
                              ~ `[0,1,0]],"faces":[[0,1,2,3,4]]}`)),
         Step("/api/command", commandBody("mesh.select", `{"mode":"edges","indices":[0,1]}`))],
        `{"id":"mesh.edgeJoin"}`);
}

unittest { // mesh.reduce — needs a TRIANGLE mesh; a fresh quad cage refuses
    undoRoundTrip("mesh.reduce",
        kCubePolyMode ~ [Step("/api/command", `{"id":"mesh.subdivide"}`),
                         Step("/api/command", `{"id":"mesh.triple"}`)],
        `{"id":"mesh.reduce","params":{"ratio":0.5,"preserveBoundary":false}}`);
}

unittest { // mesh.sweep — polygon mode, the arm that DELETES the profile face
    // after the kernel. That deletion moved INSIDE the batch at Stage L10-e;
    // before it, the delta named the appends only and this round-trip would
    // come back one face short with every count still right.
    undoRoundTrip("mesh.sweep",
        [Step("/api/command", commandBody("scene.reset", `{"empty":true}`)),
         Step("/api/command", commandBody("scene.loadMesh", `{"vertices":[[1,0,0],[0,0,1],[-1,0,0],`
                              ~ `[0,0,-1]],"faces":[[0,1,2,3]]}`)),
         Step("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0]}`))],
        `{"id":"mesh.sweep","count":6,"axis":"Y","angle":6.2831853}`);
}

unittest { // mesh.bridge — polygon mode, the arm that DELETES both cap faces
    // after the kernel. Same story as sweep, and the same stage moved it in.
    undoRoundTrip("mesh.bridge",
        kCube ~ [Step("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0,1]}`))],
        `{"id":"mesh.bridge"}`);
}
