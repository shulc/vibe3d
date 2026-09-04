// test_l8_undo_depth — task 1903 Stage L8 (the extrude / extend family), the
// S-lane witness the unit parity fixture cannot be.
//
// WHAT THIS ADDS OVER `tests/unit/undo_parity_l8_test.d`, which already
// compares seven per-plane dumps against a frozen oracle. That reader calls
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
//      throws => `status:error` and NO history entry, read from the outside.
//   3. A DIFFERENT STAND FROM THE FIXTURE'S. The unit reader runs on
//      `makeTaggedGridBent(3)`, an open grid carrying a UV map and two
//      off-plane vertices. These rows run on the default CUBE, which carries
//      NO PolyVertex map — so `Mesh.recordPolyVertexPayload` takes its
//      `hasPolyVertexMap()` early-out, the `FaceReindex` entries are UNPAIRED,
//      and a corner carry that assumed the pairing is a live defect here. A
//      family green on one stand and broken on the other is exactly what a
//      single-stand gate cannot see. The cube is also CLOSED, where the grid
//      is open, so the `n == 0` "closed island with no boundary edge" arm is
//      reachable here and nowhere in the unit lane.
//
// THE TWO DECLINED COMMANDS GET ROWS TOO, and that is the point of including
// them. `mesh.edge_extrude` and `mesh.edge_extend` keep their whole-mesh
// `MeshSnapshot` (stage L8-d, argued at each class declaration and measured in
// `tests/unit/l8_extrude_delta_test.d`'s block 4). Their rows here assert the
// SHIPPED behaviour still round-trips — a decline is a claim that the current
// path is BETTER, and a claim like that needs a witness of its own or nothing
// stops someone migrating them on the grounds that "the family is done".
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
      ~ "). Stage L8 built NO publisher because every kernel in this family "
      ~ "was measured to publish already, so a tick here does not mean "
      ~ "\"a publisher is missing\" — it means an arming or a record was "
      ~ "REMOVED, most likely a `rewriteFaces` that left its "
      ~ "`faceReindexScope()`");
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
// command and hide the other five.
// ---------------------------------------------------------------------------

enum Step[] kCube         = [Step("/api/reset", "")];
enum Step[] kCubePolyMode = [Step("/api/reset", ""),
                             Step("/api/command", "select.typeFrom polygon")];
enum Step[] kCubeVertMode = [Step("/api/reset", ""),
                             Step("/api/command", "select.typeFrom vertex")];
enum Step[] kCubeEdgeMode = [Step("/api/reset", ""),
                             Step("/api/command", "select.typeFrom edge")];

enum Step kSelFace0 = Step("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0]}`));

unittest { // poly.extrude — the RIGID arm of extrudeFacesByMask
    // Its op-log on this stand is `[AddVerts, FaceReindex]` — no
    // `MeshMapDelta`, because the cube carries no PolyVertex map. The unit
    // lane only ever sees the PAIRED shape.
    undoRoundTrip("poly.extrude", kCubePolyMode ~ [kSelFace0],
        `{"id":"poly.extrude","params":{"distance":0.4}}`);
}

unittest { // mesh.smooth_shift — the SMOOTH arm of the same kernel
    // On a CUBE the two arms genuinely differ (adjacent faces meet at 90 deg,
    // so the averaged vertex normal is not the region normal) — unlike on a
    // flat grid, where they are byte-identical and the unit fixture had to
    // move to `makeTaggedGridBent` to tell them apart.
    undoRoundTrip("mesh.smooth_shift", kCubePolyMode ~ [kSelFace0],
        `{"id":"mesh.smooth_shift","params":{"shift":0.4}}`);
}

unittest { // mesh.vertexExtrude — the family's only `Kind.SetPos` member
    // `width` MUST be non-zero: `shift` alone is a confirmed no-op and the
    // command would REFUSE, which this row would report as a funnel failure
    // rather than as the no-op it is (the refusal has its own row below).
    undoRoundTrip("mesh.vertexExtrude", kCubeVertMode,
        `{"id":"mesh.vertexExtrude","params":{"shift":0.3,"width":0.2}}`);
}

unittest { // mesh.strokeExtrude — THREE spans, so the per-span groups exist
    // `extrudeAlongPath` opens one `faceReindexScope()` PER SPAN, and stage K
    // armed it — before that arming this revert THREW out of `buildLoops` and
    // left the mesh half-reverted (plan section 5.5's L8 note). A one-span
    // path cannot see a reverse that replays the groups in the wrong order.
    undoRoundTrip("mesh.strokeExtrude", kCubePolyMode ~ [kSelFace0],
        `{"id":"mesh.strokeExtrude","params":{"path":[[0,0,0],[0,0.4,0],`
      ~ `[0.2,0.8,0],[0.5,1.0,0.2]]}}`);
}

unittest { // mesh.edge_extrude — DECLINED at L8-d, and still correct
    // The snapshot path is what restores this command's per-corner map, and
    // this row is the witness that it keeps doing so. If someone migrates it,
    // the geometry here still round-trips and this row stays GREEN — which is
    // why the decline's real witness is the unit block, not this one. What
    // this row catches is the OTHER direction: a change that breaks the
    // shipped snapshot path while the decline still names it.
    undoRoundTrip("mesh.edge_extrude", kCubeEdgeMode,
        `{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);
}

unittest { // mesh.edge_extend — the other decline
    undoRoundTrip("mesh.edge_extend", kCubeEdgeMode,
        `{"id":"mesh.edge_extend","params":{"inset":0.1,"shift":0.15}}`);
}

// ---------------------------------------------------------------------------
// THE REFUSAL CONTRACT, from the outside. `evaluate` false => `apply` false =>
// the funnel throws => `status:error` and NO history entry. The frozen fixture
// cannot carry this: a refusal leaves `postOp == postUndo == pre`, which
// `compareOrCapture`'s anti-vacuity assert rejects outright.
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

unittest { // poly.extrude refuses at distance == 0
    assertRefuses("poly.extrude/zero", kCubePolyMode ~ [kSelFace0],
        `{"id":"poly.extrude","params":{"distance":0}}`);
}

unittest { // mesh.vertexExtrude refuses at width == 0, whatever `shift` is
    // Documented in the class comment and captured: `shift` alone is a
    // CONFIRMED no-op. The row passes a non-zero `shift` on purpose, so a
    // refusal here cannot be read as "nothing was asked for".
    assertRefuses("mesh.vertexExtrude/width0", kCubeVertMode,
        `{"id":"mesh.vertexExtrude","params":{"shift":0.3,"width":0}}`);
}

unittest { // mesh.strokeExtrude refuses a path of fewer than two points
    assertRefuses("mesh.strokeExtrude/1point", kCubePolyMode ~ [kSelFace0],
        `{"id":"mesh.strokeExtrude","params":{"path":[[0,0,0]]}}`);
}

unittest { // mesh.smooth_shift refuses outside Polygons mode
    assertRefuses("mesh.smooth_shift/vertMode", kCubeVertMode,
        `{"id":"mesh.smooth_shift","params":{"shift":0.4}}`);
}
