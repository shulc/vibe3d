// test_l6_undo_depth — task 1903 Stage L6 (the duplication family) and Stage
// L7-d (`mesh.vertexBevel`), the S-lane witness the unit parity fixtures
// cannot be.
//
// WHAT THIS ADDS OVER `tests/unit/undo_parity_l6_test.d` and
// `tests/unit/undo_parity_l7d_test.d`, which already compare eleven per-plane
// dumps against two frozen oracles. Those readers call `Command.revert()`
// DIRECTLY, on a mesh they built themselves. They therefore say nothing about
// three things this file measures:
//
//   1. THE REAL UNDO STACK. `CommandHistory.undo` is what a user reaches, and
//      it does more than call `revert()`: it opens a global delivery batch,
//      picks the nearest Model entry, and — on a `false` from that entry —
//      discards the entry AND its whole trailing suffix (regression 0099). A
//      migrated command whose `revert()` answered `false` would still make the
//      unit readers green (they assert the return) and would silently truncate
//      history here. So every row asserts HOW MANY STEPS TOOK EFFECT: the undo
//      stack drops by EXACTLY ONE and the redo stack gains EXACTLY ONE.
//   2. THE COMMAND FUNNEL. `evaluate` false ⇒ `apply` false ⇒ the funnel
//      throws ⇒ `status:error` and NO history entry. Every row drives
//      `/api/command` and reads that contract from the outside — and for THIS
//      family that contract is the whole point of the stage: before
//      `Mesh.recordBulkAppendRound`, migrating `mesh.duplicate` or
//      `mesh.clone` would have closed a recording batch with an EMPTY op-log
//      over a real duplication, which `acceptRecordedEdit` refuses, so the
//      user would have got `status:error` over a changed document. That is
//      `emptyDeltaOverMutation`, asserted below on every row.
//   3. A DIFFERENT STAND FROM THE FIXTURES'. The unit readers run on
//      `makeTaggedGridFull(3)`, an open grid that carries a UV map. These rows
//      run on the default CUBE, which carries none — so
//      `Mesh.recordPolyVertexPayload` takes its `hasPolyVertexMap()` early-out
//      and the op-log shape is genuinely different here (measured:
//      `mesh.vertexBevel` records 4 entries on the cube against the grid's 5).
//      A family green on one stand and broken on the other is exactly what a
//      single-stand gate cannot see.
//
// THE COMPARISON IS THE WHOLE PLANE DUMP, not a count. `/api/mesh/planes` is
// the only plane-COMPLETE readback. Counts round-trip on undos that lose
// windings, marks, set membership and map values — that is the defect class
// this stage exists to close, and for `mesh.array` specifically the detach
// path's winding rewrite moves NOTHING BUT the windings.
//
// ANTI-VACUITY, PER ROW AND STATED IN THE MESSAGE: the forward must CHANGE the
// dump.
//
// THE STACK-DEPTH ASSERTION IS A DELTA ACROSS THE UNDO, NOT AN ABSOLUTE:
// `CommandHistory` caps the undo stack and `/api/reset` does not clear it.
//
// LANE: `./run_test.d` (lane S).
import http_client : testBaseUrl, postRaw;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

alias kBase = testBaseUrl;


JSONValue postJ(string path, string body_) {
    return parseJSON(postRaw(path, body_));
}

JSONValue getJ(string path) {
    return parseJSON(cast(string) get(kBase ~ path));
}

string planes() {
    return cast(string) get(kBase ~ "/api/mesh/planes");
}

size_t undoDepth() { return getJ("/api/history")["undo"].array.length; }
size_t redoDepth() { return getJ("/api/history")["redo"].array.length; }

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
/// effect, the two refusal counters, the number of steps the undo took, and
/// the plane-complete round-trip.
void undoRoundTrip(string row, in Step[] setup, string cmdJson) {
    runSteps(row, setup);

    immutable string pre = planes();
    immutable size_t u0  = undoDepth();
    auto c0 = getJ("/api/changes");

    auto resp = postJ("/api/command", cmdJson);
    assert(resp["status"].str == "ok",
        row ~ ": the command must APPLY on this stand — got " ~ resp.toString
      ~ ". For this family a refusal is the SPECIFIC failure the stage guards "
      ~ "against: an empty delta over a real mutation makes `apply()` return "
      ~ "false and the funnel throw, over a mesh that really was duplicated");

    immutable string mid = planes();
    assert(mid != pre,
        row ~ ": the command answered ok and changed NO plane. Its undo is "
      ~ "then satisfied by an undo that does nothing");

    // THE TWO COUNTERS THAT NAME THIS STAGE'S TWO FAILURE MODES, asserted as
    // deltas across the forward.
    auto c1 = getJ("/api/changes");
    immutable long empty = c1["emptyDeltaOverMutation"].integer
                         - c0["emptyDeltaOverMutation"].integer;
    assert(empty == 0,
        row ~ ": the command closed a RECORDING batch with an EMPTY delta "
      ~ "over a real mutation (emptyDeltaOverMutation +" ~ empty.to!string
      ~ "). That is the prospective defect stage L6 exists to not ship: with "
      ~ "no publisher at the appends, `Mesh.duplicateSelectedFaces` and "
      ~ "`Mesh.arrayFaces`' no-weld path reach no tracker hook at all");
    immutable long unbatched = c1["unbatchedGeometryCommits"].integer
                             - c0["unbatchedGeometryCommits"].integer;
    assert(unbatched == 0,
        row ~ ": made " ~ unbatched.to!string ~ " UNBATCHED geometry "
      ~ "commit(s) — the batch must cover the whole kernel call (stage L6-P0)");
    assert(c1["batchLeaks"].integer - c0["batchLeaks"].integer == 0,
        row ~ ": a MeshEditBatch leaked its frame");
    assert(c1["nestedBatchOpens"].integer - c0["nestedBatchOpens"].integer == 0,
        row ~ ": opened a NESTED batch");

    immutable size_t u1 = undoDepth();
    immutable size_t r1 = redoDepth();
    assert(u1 == u0 + 1 || u1 == u0,
        row ~ ": the apply moved the undo stack from " ~ u0.to!string ~ " to "
      ~ u1.to!string ~ " — expected +1, or +0 only when the stack is at its "
      ~ "cap");

    auto ru = postJ("/api/command", commandBody("history.undo"));
    assert(ru["status"].str == "ok", row ~ ": /api/undo failed: " ~ ru.toString);

    immutable size_t u2 = undoDepth();
    immutable size_t r2 = redoDepth();
    assert(u2 + 1 == u1,
        row ~ ": the undo moved the undo stack from " ~ u1.to!string ~ " to "
      ~ u2.to!string ~ " — expected exactly one step. More than one means the "
      ~ "entry's revert() answered false and CommandHistory truncated the "
      ~ "suffix behind it (regression 0099); zero means nothing was undone");
    assert(r2 == r1 + 1,
        row ~ ": the undo moved the redo stack from " ~ r1.to!string ~ " to "
      ~ r2.to!string ~ " — expected exactly +1");

    immutable string back = planes();
    assert(back == pre,
        row ~ ": the undo did not restore the mesh plane for plane.\n"
      ~ "  pre : " ~ contrast(pre, back)[0]
      ~ "\n  post: " ~ contrast(pre, back)[1]);
}

/// The two renderings WINDOWED ON THE FIRST DIFFERING CHARACTER — a leading
/// clip would print two identical strings under the word "not".
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
// command and hide the other five.
// ---------------------------------------------------------------------------

enum Step[] kCube         = [Step("/api/command", commandBody("scene.reset"))];
enum Step[] kCubePolyMode = [Step("/api/command", commandBody("scene.reset")),
                             Step("/api/command", "select.typeFrom polygon")];
enum Step[] kCubeVertMode = [Step("/api/command", commandBody("scene.reset")),
                             Step("/api/command", "select.typeFrom vertex")];

unittest { // mesh.clone — the append publisher with NO weld to credit
    // `mesh.clone` pins `weld = 0`, so its op-log is `[AddVerts, AddFaces]`
    // and nothing else (measured on this stand: 2 entries). If
    // `Mesh.recordBulkAppendRound` ever stops firing, this row is the one that
    // reports it as `status:error` rather than as a partial restore.
    undoRoundTrip("mesh.clone", kCube, `{"id":"mesh.clone"}`);
}

unittest { // mesh.duplicate — the other unconditionally hook-free member
    // Polygons mode and a face selection are BOTH required by `evaluate`, so
    // the setup builds them; without either, the row would measure a refusal.
    undoRoundTrip("mesh.duplicate",
        kCubePolyMode ~ [Step("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0]}`))],
        `{"id":"mesh.duplicate"}`);
}

unittest { // mesh.array — the DETACH path's winding install
    // A strict-subset selection is what turns `detachSubsetSource` on, and the
    // detach is the family's ONLY rewrite of an existing face's winding. That
    // rewrite is arity-preserving, so V/F/E and every mark word round-trip
    // whether or not it is restored — only the plane-complete dump sees it.
    undoRoundTrip("mesh.array",
        kCubePolyMode ~ [Step("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0]}`))],
        `{"id":"mesh.array","params":{"count":2,"offset":[1,0,0]}}`);
}

unittest { // mesh.mirror — with the weld ON, so `Kind.RemoveVerts` is in the log
    // A cube mirrored about x = 0.5 puts its +X face exactly on the image's,
    // so the weld fires and the log carries the `[MeshMapDelta, FaceReindex,
    // RemoveVerts, Reindex]` tail that stage L5-a's arming produces.
    undoRoundTrip("mesh.mirror", kCube,
        `{"id":"mesh.mirror","params":{"axis":"X","center":[0.5,0,0]}}`);
}

unittest { // mesh.radial_array — the third welding member
    undoRoundTrip("mesh.radial_array", kCube,
        `{"id":"mesh.radial_array","params":{"count":4,"axis":"Y"}}`);
}

unittest { // mesh.vertexBevel — stage L7-d, on a stand with NO per-corner map
    // The unit fixture runs this on `makeTaggedGridFull`, which carries a UV
    // map, so its op-log is `[AddVerts, MeshMapDelta, FaceReindex,
    // RemoveVerts, Reindex]`. Here the cube has no PolyVertex map, so
    // `recordPolyVertexPayload` returns early and the log is four entries with
    // the `FaceReindex` UNPAIRED — a shape the unit lane never sees, and one
    // where a corner carry that assumed the pairing would be a live defect.
    undoRoundTrip("mesh.vertexBevel", kCubeVertMode,
        `{"id":"mesh.vertexBevel","params":{"amount":0.2}}`);
}

// ---------------------------------------------------------------------------
// THE REFUSAL CONTRACT, from the outside. `evaluate` false ⇒ `apply` false ⇒
// the funnel throws ⇒ `status:error` and NO history entry. Frozen fixtures
// cannot carry this: a refusal leaves `postOp == postUndo == pre`, which the
// readers' anti-vacuity assert rejects outright.
//
// THREE ASSERTIONS, NOT ONE, because `postOp == postUndo == pre` is what a
// CORRECT refusal and a NEVER-RAN cell both produce: the status is `error`,
// the undo stack does NOT move, and a CONTROL command on the same stand
// answers `ok` and DOES move it.
// ---------------------------------------------------------------------------
void assertRefuses(string row, in Step[] setup, string cmdJson) {
    runSteps(row, setup);
    immutable string pre = planes();
    immutable size_t u0  = undoDepth();

    auto resp = postJ("/api/command", cmdJson);
    assert(resp["status"].str == "error",
        row ~ ": expected status:error, got " ~ resp.toString);
    assert(undoDepth() == u0,
        row ~ ": a REFUSED command left a history entry — the undo stack moved "
      ~ "from " ~ u0.to!string ~ " to " ~ undoDepth().to!string);
    assert(planes() == pre,
        row ~ ": a REFUSED command changed a plane");

    // THE CONTROL. Without it, every assertion above is satisfied by an
    // endpoint that stopped working, a stand that was never built, or a
    // command id that does not exist.
    auto ok = postJ("/api/command", `{"id":"mesh.clone"}`);
    assert(ok["status"].str == "ok",
        row ~ ": the CONTROL command refused too, so the three assertions "
      ~ "above say nothing about " ~ row ~ " — they say the stand is broken");
    assert(undoDepth() == u0 + 1 || undoDepth() == u0,
        row ~ ": the control command recorded no history entry");
}

unittest { // mesh.duplicate refuses with NO face selected
    assertRefuses("mesh.duplicate/empty",
        kCubePolyMode ~ [Step("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[]}`))],
        `{"id":"mesh.duplicate"}`);
}

unittest { // mesh.array refuses at count <= 1 — a pre-kernel gate
    assertRefuses("mesh.array/count1", kCube,
        `{"id":"mesh.array","params":{"count":1}}`);
}

unittest { // mesh.mirror refuses an invalid axis
    assertRefuses("mesh.mirror/badAxis", kCube,
        `{"id":"mesh.mirror","params":{"axis":"Q"}}`);
}

unittest { // mesh.vertexBevel refuses outside Vertices mode
    assertRefuses("mesh.vertexBevel/polyMode", kCubePolyMode,
        `{"id":"mesh.vertexBevel","params":{"amount":0.2}}`);
}
