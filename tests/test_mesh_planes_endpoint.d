// test_mesh_planes_endpoint — the SUITE tier of task 1903 Stage B's two new
// observables (plan §6.3 suite tier, §6.4).
//
//   1. `GET /api/mesh/planes` — the plane-complete readback the per-family
//      parity fixtures are frozen from. The dump's CONTENT is pinned in
//      `tests/unit/plane_dump_test.d`, in process, where a mesh can be built to
//      order; what only this tier can see is the WIRING — that the route
//      exists, that it is marshaled onto the main thread rather than answered
//      off the HTTP thread, that its provider is installed, and that the
//      provenance query parameters reach the body.
//   2. `/api/history`'s `"opInverse"` — the first reader
//      `Command.isOperationInverse()` has ever had.
//
// WHAT `opInverse` CAN AND CANNOT WITNESS, because a green row here is easy to
// over-read: the bit is `useDelta_`, which the command sets ABOUT ITSELF. A
// class that sets it true while its delta is empty reports true and is still
// broken. It is a cheap TELL. The things that can actually see that failure are
// the counted `MeshSnapshot`-holder census and the per-family plane-dump parity
// fixture; this file asserts the channel exists and DISCRIMINATES, and says so.
//
// The discrimination is what makes the row worth having: `mesh.delete` under
// the tracker reports true and a plain selection command reports false, in the
// same run. A field hard-wired to either constant fails one of the two.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.string : indexOf;

void main() {}

string BASE = "http://localhost:8080";

void resetGrid(int n) {
    auto resp = post(BASE ~ "/api/reset?type=grid&n=" ~ n.to!string, "");
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "/api/reset grid failed: " ~ cast(string)resp);
}

void cmd(string s) {
    auto resp = post(BASE ~ "/api/command", s);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ cast(string)resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post(BASE ~ "/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "/api/select failed: " ~ cast(string)resp);
}

JSONValue getPlanes(string query = "") {
    return parseJSON(cast(string)get(BASE ~ "/api/mesh/planes" ~ query));
}

JSONValue getModel()   { return parseJSON(cast(string)get(BASE ~ "/api/model")); }
JSONValue getHistory() { return parseJSON(cast(string)get(BASE ~ "/api/history")); }

// ---------------------------------------------------------------------------

unittest // /api/mesh/planes answers, and its counts agree with /api/model
{
    resetGrid(3);

    auto planes = getPlanes();
    auto model  = getModel();

    // The wiring, which is the whole reason this tier exists: a route with no
    // provider answers 500 with "provider not set", and a route missing from
    // the table answers 404 — neither of which parses into these fields.
    assert(planes["counts"]["vertices"].integer == model["vertexCount"].integer,
        "/api/mesh/planes and /api/model disagree on the vertex count — the "
      ~ "dump is not reading the same mesh the model provider is");
    assert(planes["counts"]["edges"].integer == model["edgeCount"].integer,
        "edge count disagrees with /api/model");
    assert(planes["counts"]["faces"].integer == model["faceCount"].integer,
        "face count disagrees with /api/model");

    // Non-vacuity: a 3x3 grid is not empty, so every "the arrays are present"
    // check below is over arrays with something in them.
    assert(planes["counts"]["faces"].integer == 9, "reset grid n=3 is 9 faces");
    assert(planes["edgePlanes"].array.length
           == planes["counts"]["edges"].integer,
        "one edgePlanes row per live edge");
}

unittest // the edge planes are keyed by ENDPOINT PAIR, low-first
{
    // The in-process test proves the dump SURVIVES a re-keying. What the wire
    // tier adds is that the shape actually shipped is the endpoint-keyed one:
    // a regression to index keys would still answer 200 with the right row
    // count, and only the key shape gives it away.
    resetGrid(3);

    auto planes = getPlanes();
    foreach (row; planes["edgePlanes"].array) {
        assert("ends" in row,
            "an edgePlanes row has no `ends` key — the edge planes have been "
          ~ "re-keyed by index, and a frozen parity fixture would then compare "
          ~ "two different index spaces after a delta replay rebuilds `edges`");
        auto ends = row["ends"].array;
        assert(ends.length == 2, "an edge key is a vertex-index PAIR");
        assert(ends[0].integer < ends[1].integer,
            "the endpoint key must be ordered low-first, or two dumps of the "
          ~ "same edge can disagree on its key");
        assert("marks" in row && "order" in row,
            "an edgePlanes row must carry both index-keyed edge planes");
    }
}

unittest // the plane dump MOVES with the mesh, and carries the tagged planes
{
    resetGrid(3);
    immutable string before = get(BASE ~ "/api/mesh/planes").idup;

    cmd("select.typeFrom polygon");
    postSelect("polygons", [4]);

    immutable string after = get(BASE ~ "/api/mesh/planes").idup;
    assert(before != after,
        "selecting a polygon did not change the plane dump — it is not reading "
      ~ "the live mesh, and a fixture frozen from it would witness nothing");

    // …and specifically the mark word moved, not just some timestamp. (The
    // dump deliberately carries NO timestamp, unlike /api/model — a fixture
    // that changed on every request could never be diffed.)
    auto j = getPlanes();
    bool anyFaceMark = false;
    foreach (w; j["faceMarks"].array) if (w.integer != 0) anyFaceMark = true;
    assert(anyFaceMark,
        "faceMarks is all zero after selecting face 4 — the Select bit is not "
      ~ "reaching the dump");
    assert(get(BASE ~ "/api/mesh/planes").idup == after,
        "two consecutive dumps of an unchanged mesh differ — the body carries "
      ~ "something that is not mesh state, and it cannot be frozen as a fixture");
}

unittest // the provenance block is always present, and the query fills it
{
    resetGrid(3);

    // Present with no query at all — the healthy case, so a change that drops
    // the block reddens here rather than only on a capture that supplied a SHA.
    auto bare = getPlanes();
    assert("provenance" in bare, "the provenance block must be unconditional");
    assert(bare["provenance"]["producedBy"].str == "",
        "with no query the SHA is empty, not absent");

    auto tagged = getPlanes("?producedBy=deadbeef&path=snapshot&family=delete"
                          ~ "&stand=makeTaggedGridFull");
    assert(tagged["provenance"]["producedBy"].str == "deadbeef", "producedBy");
    assert(tagged["provenance"]["path"].str       == "snapshot", "path");
    assert(tagged["provenance"]["family"].str     == "delete",   "family");
    assert(tagged["provenance"]["stand"].str == "makeTaggedGridFull", "stand");
}

// ---------------------------------------------------------------------------
// §6.4 — `/api/history` carries `opInverse`, and it DISCRIMINATES.
// ---------------------------------------------------------------------------

unittest // every history entry reports opInverse, and the bit is not a constant
{
    // `/api/history`'s arrays run OLDEST FIRST — `undo[0]` is `scene.reset`,
    // the entry the harness's own reset left behind. The entry a step just
    // recorded is `undo[$-1]`. Reading [0] here silently scores the wrong
    // command and was doing exactly that when this file was written.
    resetGrid(3);

    // (a) a selection command — UI class, no mesh undo record of either kind.
    cmd("select.typeFrom polygon");
    postSelect("polygons", [4]);

    auto h1 = getHistory();
    assert(h1["undo"].array.length > 0,
        "the selection did not record a history entry — this cell has nothing "
      ~ "to read");
    foreach (e; h1["undo"].array)
        assert("opInverse" in e,
            "a /api/history entry has no `opInverse` field — "
          ~ "Command.isOperationInverse() has lost its only reader");
    auto selTop = h1["undo"].array[$ - 1];
    assert(selTop["command"].str != "mesh.delete",
        "the top entry after a selection is a mesh edit — the fixture is not "
      ~ "in the state this cell describes");
    assert(!selTop["opInverse"].boolean,
        "the top entry after a selection (`" ~ selTop["command"].str
      ~ "`) reports opInverse=true. The bit means `this entry undoes itself by "
      ~ "an inverse OPERATION`, and a selection entry does not — a field wired "
      ~ "to a constant `true` reads exactly like this");

    // (b) mesh.delete — a class that records an operation-log delta
    // UNCONDITIONALLY since task 1903 stage L3-b deleted its
    // `undoTrackerEnabled()` fork and its `MeshSnapshot` arm.
    //
    // THE `undo.tracker.on` PRECONDITION THAT USED TO SIT HERE IS GONE, and
    // its removal STRENGTHENS this cell rather than weakening it. It was
    // added because the toggle is per-instance and survives /api/reset, so a
    // sibling test that left it off turned this cell red for a reason
    // unrelated to the class under test (test_undo_tracker_extrude,
    // 2026-08-25, 701/702 on the first full gate). With the fork gone the
    // toggle cannot steer `mesh.delete` at all — and setting it here would
    // now HIDE a regression: re-introducing a fork would leave this cell
    // green under a flag it set for itself.
    postSelect("polygons", [4]);
    cmd("mesh.delete");

    auto h2 = getHistory();
    assert(h2["undo"].array.length > 0, "mesh.delete recorded no entry");
    auto top = h2["undo"].array[$ - 1];
    assert(top["command"].str == "mesh.delete",
        "the top undo entry is `" ~ top["command"].str ~ "`, not mesh.delete — "
      ~ "this cell is reading the wrong entry");
    assert("opInverse" in top, "mesh.delete's entry has no `opInverse` field");
    assert(top["opInverse"].boolean,
        "mesh.delete reports opInverse=false, expected true. The class has no "
      ~ "second path left, so either it stopped setting `recorded_` — i.e. it "
      ~ "recorded no delta and refused — or the provider is wired to a "
      ~ "constant `false`, which the selection cell above cannot tell apart "
      ~ "on its own");

    // Redo entries carry it too — the same command, read from the other stack.
    // The two arms of the provider are two separate loops, so a green undo arm
    // says nothing about this one.
    auto resp = post(BASE ~ "/api/undo", "");
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "/api/undo failed: " ~ cast(string)resp);
    auto h3 = getHistory();
    assert(h3["redo"].array.length > 0, "undo left nothing on the redo stack");
    bool sawDeleteOnRedo = false;
    foreach (e; h3["redo"].array) {
        assert("opInverse" in e,
            "the redo arm of /api/history is missing `opInverse` — the two "
          ~ "arms are built by two separate loops and only one was updated");
        if (e["command"].str == "mesh.delete") {
            sawDeleteOnRedo = true;
            assert(e["opInverse"].boolean,
                "the undone mesh.delete reports opInverse=false on the redo "
              ~ "stack while it reported true on the undo stack — the two arms "
              ~ "disagree about the same command instance");
        }
    }
    assert(sawDeleteOnRedo,
        "the undone mesh.delete is not on the redo stack — this cell never "
      ~ "reached the assertion it exists for");
}
