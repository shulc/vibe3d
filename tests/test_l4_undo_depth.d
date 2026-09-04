// test_l4_undo_depth — task 1903 Stage L4 (the slice / cut family), the S-lane
// witness the unit parity fixture cannot be.
//
// WHAT THIS ADDS OVER `tests/unit/undo_parity_l4_test.d`, which already
// compares eight per-plane dumps against a frozen oracle. That reader calls
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
//   2. THE COMMAND FUNNEL. `evaluate` false => `apply` false => the funnel
//      throws => `status:error` and NO history entry, read from the outside —
//      which is what the REFUSAL row at the bottom asserts.
//   3. A DIFFERENT STAND FROM THE FIXTURE'S. The unit reader runs on
//      `makeTaggedGridFull(3)`, an OPEN grid carrying a PolyVertex UV map.
//      These rows run on the default CUBE, which carries NO such map — so
//      `Mesh.recordPolyVertexPayload` takes its `hasPolyVertexMap()`
//      early-out, the `ReshapeFaces` and `FaceReindex` entries are UNPAIRED,
//      and a corner carry that assumed the pairing is a live defect here. A
//      family green on one stand and broken on the other is exactly what a
//      single-stand gate cannot see. The cube is also CLOSED where the grid is
//      open, so `mesh.cut` orphans nothing here and the compaction half of its
//      kernel is deliberately NOT what these rows measure.
//
// THE COMPARISON IS THE WHOLE PLANE DUMP, not a count. `/api/mesh/planes` is
// the only plane-COMPLETE readback. Counts round-trip on undos that lose
// windings, marks, set membership and map values.
//
// ANTI-VACUITY, PER ROW AND STATED IN THE MESSAGE: the forward must CHANGE the
// dump.
//
// THE STACK-DEPTH ASSERTION IS A DELTA ACROSS THE UNDO, NOT AN ABSOLUTE:
// `CommandHistory` caps the undo stack and `/api/reset` does not clear it.
//
// `/api/reset` does NOT restore the selection MODE either, and
// `select.typeFrom` takes its argument as a BODY STRING, not as a JSON
// parameter — both stated at the setup rows below, where they bite.
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
        row ~ ": the command must APPLY on this stand — got " ~ resp.toString);

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
      ~ "). Stage L4 built NO publisher because every kernel in this family "
      ~ "was measured to publish already — `Mesh.insertEdgePoint` at stage "
      ~ "L2-c and `Mesh.rebuildFacesWithChordSplits` at L2-d — so a tick here "
      ~ "does not mean \"a publisher is missing\"; it means an arming or a "
      ~ "record was REMOVED, most likely the `faceReindexScope()` around the "
      ~ "chord rebuild's `rewriteFaces`");
    immutable long unbatched = c1["unbatchedGeometryCommits"].integer
                             - c0["unbatchedGeometryCommits"].integer;
    assert(unbatched == 0,
        row ~ ": made " ~ unbatched.to!string ~ " UNBATCHED geometry "
      ~ "commit(s) — the batch must cover the whole kernel call. For "
      ~ "`mesh.edgeSlice` and `mesh.cut` that batch is stage L4-P0's own: "
      ~ "measured 4 -> 0 and 2 -> 0 when it landed");
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

    auto ru = postJ("/api/undo", "");
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
// command and hide the other four.
// ---------------------------------------------------------------------------

enum Step[] kCube         = [Step("/api/reset", "")];
enum Step[] kCubePolyMode = [Step("/api/reset", ""),
                             Step("/api/command", "select.typeFrom polygon")];
enum Step[] kCubeEdgeMode = [Step("/api/reset", ""),
                             Step("/api/command", "select.typeFrom edge")];

enum Step kSelFace0 = Step("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0]}`));

unittest { // mesh.axisSlice — ONE plane
    // On the cube every axis has extent, so the class's DEFAULT axis works
    // here where it refuses on the fixture's flat grid. Named anyway: a row
    // that leans on a default is a row that changes meaning when the default
    // does.
    undoRoundTrip("mesh.axisSlice/1", kCube,
        `{"id":"mesh.axisSlice","params":{"axis":1,"count":1}}`);
}

unittest { // mesh.axisSlice — the LADDER, three planes in ONE batch
    // The row that separates "the delta describes the ladder" from "the delta
    // describes the last plane". Both round-trip the COUNTS, because every
    // plane adds faces; only the plane-complete dump sees the difference.
    undoRoundTrip("mesh.axisSlice/3", kCube,
        `{"id":"mesh.axisSlice","params":{"axis":1,"count":3}}`);
}

unittest { // mesh.julienne — TWO axes, ONE delta
    // The batch lift (stage L4-c). Before it, `sliceAlongAxis` opened its own
    // batch and `evaluate` called it twice, so the entry described axis B
    // alone — with the undo-stack depth, the redo depth, every element count
    // and every /api/changes counter green, because the two opens were
    // SEQUENTIAL rather than nested. This row and the frozen
    // `mesh.julienne/xz` cell are the only two things that see it.
    undoRoundTrip("mesh.julienne", kCube,
        `{"id":"mesh.julienne","params":{"axisA":0,"countA":1,"axisB":2,"countB":1}}`);
}

unittest { // mesh.edgeSlice — a real chord split
    // Edges 0 and 2 of the default cube are opposite edges of one face, which
    // is what `edgeSliceEx` needs. This command opened NO batch until stage
    // L4-P0, so its `unbatchedGeometryCommits` row above is a live assertion
    // and not a formality: it read 4 before that commit.
    undoRoundTrip("mesh.edgeSlice", kCubeEdgeMode,
        `{"id":"mesh.edgeSlice","params":{"edges":[0,2],"tA":0.5,"tB":0.5}}`);
}

unittest { // mesh.cut — the delete kernel plus the clipboard
    undoRoundTrip("mesh.cut", kCubePolyMode ~ [kSelFace0], `{"id":"mesh.cut"}`);
}

// ---------------------------------------------------------------------------
// THE REFUSAL, and it is the row the family's own kernel makes possible.
//
// `mesh.edgeSlice` at `tA:0 tB:1` on two edges of one face snaps BOTH cuts to
// existing corners, which land adjacent in the winding; `edgeSliceEx` takes
// its TRUE no-op arm, restores `faces` and `vertices` itself, and reports
// `meshChanged == false`. The command must then answer `status:error`, record
// NO history entry, and leave every plane where it found it.
//
// THREE ASSERTIONS AND NOT ONE, because `postOp == pre` is what a CORRECT
// refusal and a NEVER-RAN row both produce: the funnel's answer, the untouched
// dump, and a CONTROL differing only in `tB` that must SUCCEED. Without the
// control, the refusal is satisfied by a command that refuses everything — a
// mistyped id, a stand with no such edge, a guard that fires first.
//
// AND `batchLeaks` MUST NOT MOVE. Before the migration this refusal ran
// `snap.restore`; there is no snapshot any more, so the refusal reverts the
// (empty) delta and returns false — and a refusal that answered `false` from
// `revert()` instead would pop the entry off BOTH history stacks.
// ---------------------------------------------------------------------------
unittest {
    runSteps("mesh.edgeSlice/refusal", kCubeEdgeMode);

    immutable string pre = planes();
    immutable size_t u0  = undoDepth();
    auto c0 = getJ("/api/changes");

    auto resp = postJ("/api/command",
        `{"id":"mesh.edgeSlice","params":{"edges":[0,2],"tA":0.0,"tB":1.0}}`);
    assert(resp["status"].str == "error",
        "mesh.edgeSlice at tA=0 tB=1 answered " ~ resp.toString ~ ". Both cuts "
      ~ "snap to existing corners that land ADJACENT in the shared face's "
      ~ "winding, so `edgeSliceEx` takes its TRUE no-op arm and the command "
      ~ "must refuse");

    assert(planes() == pre,
        "mesh.edgeSlice refused and still moved a plane — the kernel's own "
      ~ "rollback and the command's refusal disagree");
    assert(undoDepth() == u0,
        "mesh.edgeSlice refused and the undo stack moved from " ~ u0.to!string
      ~ " to " ~ undoDepth().to!string ~ " — a refusal records NO history "
      ~ "entry (CLAUDE.md's command no-op contract: there is no path that "
      ~ "answers ok while recording nothing, and none that errors while "
      ~ "recording something)");

    auto c1 = getJ("/api/changes");
    assert(c1["batchLeaks"].integer - c0["batchLeaks"].integer == 0,
        "the refusal leaked a MeshEditBatch frame — the refusal is decided "
      ~ "AFTER the batch closes, so a leak here means the close was skipped");
    assert(c1["emptyDeltaOverMutation"].integer
         - c0["emptyDeltaOverMutation"].integer == 0,
        "the refusal ticked emptyDeltaOverMutation. That counter is for a "
      ~ "kernel that MUTATED and recorded nothing; this arm mutated nothing, "
      ~ "so a tick means `acceptRecordedEdit` was handed a non-zero "
      ~ "`affected` — most likely `facesSplit` in place of `meshChanged`");

    // THE CONTROL: same stand, same edges, `tB` alone moved.
    runSteps("mesh.edgeSlice/refusal control", kCubeEdgeMode);
    auto ok = postJ("/api/command",
        `{"id":"mesh.edgeSlice","params":{"edges":[0,2],"tA":0.0,"tB":0.0}}`);
    assert(ok["status"].str == "ok",
        "the CONTROL refused too: mesh.edgeSlice on the same cube and the "
      ~ "same edges at tA=0 tB=0 must SUCCEED (both cuts still reuse corners, "
      ~ "but they land NON-adjacent and Pass 2 chord-splits). Without it the "
      ~ "refusal above is satisfied by a command that refuses everything");
}
