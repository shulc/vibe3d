// test_map_delta_counters.d — task 1903 Stage L1-P1, W-K16.
//
// The three map-value seam counters at `/api/changes`, as DELTAS around the
// whole map command family:
//
//   * `mapDeltaMixRecorded` — the RECORDER saw a `Kind.MapValueDelta` entry
//     adjacent, in one log, to an entry that moves an index space. Always a
//     bug, and it names the command being written.
//   * `mapDeltaMixRefused`  — the REPLAY skipped map entries in such a log.
//   * `mapDeltaBindRefused` — a map entry could not bind its map at replay.
//
// DELTAS AND NOT ABSOLUTES: all three are process-cumulative and this binary
// runs many tests, so a `== 0` on the absolute measures whatever ran before.
//
// -------------------------------------------------------------------------
// BLOCK 1 WAS A DEBT ROW AT L1-P1 AND IS DISCHARGED AT L1-a (task 2230).
// -------------------------------------------------------------------------
// At the commit that introduced the kind, NO SHIPPED RECORDER EMITTED IT, so
// the three counters could not move in this lane however broken the dispatch
// was: no mutation of the guard, the latch or the bind terms reddened block 1
// and its zeros were dead cells. It shipped anyway with that sentence
// attached, because block 2 was live from the start (it pins that the three
// fields are SERIALISED, and a counter nobody can read is a counter nobody
// will assert) and because block 1 became real at the commit that OWED it.
//
// THAT COMMIT IS STAGE L1-a. `commands/mesh/morph.d` now records
// `Kind.MapValueDelta` from five classes across all four `MapOp` arms, and
// `mesh.morph.apply` records `Kind.SetPos`, so every `mesh.morph.*` line below
// drives the kind's recorder, its replay guard and its bind terms for real.
// The mutation that shows it: make `bindMapForEntry` refuse unconditionally in
// `source/mesh_edit_delta.d` -> `mapDeltaBindRefused` moves on the undo pass
// and this block reddens naming it. Verified in this lane, task 2230.
//
// STILL PARTLY OWED, and named so nobody reads the green as total: the
// `mesh.weightmap.*` and `uv.*` lines are exercising commands that are STILL
// DENSE (their groups are L1-c and L1-d), so those four commands contribute
// nothing to these counters yet and their zeros remain dead cells. Only the
// five morph lines and their undo/redo are live.
//
// The witnesses that ARE potent at this commit all live in the OTHER lane —
// `dub test --config=tests`, over `tests/unit/map_value_delta_test.d`,
// `tests/unit/map_delta_census_test.d` and `source/mesh_edit_delta.d`'s own
// W-K1/W-K2 blocks. `./run_test.d` links the prebuilt archive and never RUNS a
// `source/**` or `tests/unit/**` unittest block (measured), so a cell placed
// here instead of there is a cell that cannot redden.
//
// The counters are also read on the DOCUMENT mesh — every command below goes
// through `/api/command`, which edits the primary layer — so no
// `g_isDocumentMesh` predicate is weakening these zeros.

import std.net.curl;
import std.json;
import std.format : format;

void main() {}

enum BASE = "http://localhost:8080";

JSONValue getJson(string path)  { return parseJSON(cast(string) get(BASE ~ path)); }
JSONValue postJson(string p, string b) { return parseJSON(cast(string) post(BASE ~ p, b)); }
JSONValue changes() { return getJson("/api/changes"); }

void cmdJ(string id, string paramsJson = "{}") {
    auto j = postJson("/api/command",
        `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`);
    assert(j["status"].str == "ok", "cmdJ `" ~ id ~ "` failed: " ~ j.toString);
}

// UNDO IS `/api/undo`, NOT a command id — and the return value is ASSERTED.
//
// THIS IS A DEFECT THIS FILE SHIPPED WITH (found at Stage L1-a, task 2230).
// Block 1 used to post `{"id":"undo"}` to `/api/command` ten times and read
// nothing back. There is no command registered under that id, so every one of
// those posts answered a non-ok status and performed NO UNDO — which means
// block 1 was vacuous for a SECOND, independent reason nobody had named: even
// after a recorder for the kind existed, the replay guard and the bind terms
// still would not have run, because the replay never happened. Measured: with
// `bindMapForEntry` mutated to refuse UNCONDITIONALLY, the old block stayed
// green.
//
// The lesson is the general one, and it is why the asserts are here: a request
// whose response nobody reads is not an exercise of anything. `n` is returned
// so a caller can say how many steps actually ran.
size_t undoN(size_t n) {
    size_t did = 0;
    foreach (_; 0 .. n) {
        auto j = postJson("/api/undo", "");
        if (j["status"].str != "ok") break;
        ++did;
    }
    return did;
}

size_t redoN(size_t n) {
    size_t did = 0;
    foreach (_; 0 .. n) {
        auto j = postJson("/api/redo", "");
        if (j["status"].str != "ok") break;
        ++did;
    }
    return did;
}

void selectAllVerts(int n) {
    import std.conv : to;
    string idx;
    foreach (i; 0 .. n) { if (i) idx ~= ","; idx ~= i.to!string; }
    auto j = postJson("/api/select", `{"mode":"vertices","indices":[` ~ idx ~ `]}`);
    assert(j["status"].str == "ok", "select failed: " ~ j.toString);
}

unittest { // block 1 — the family moves none of the three. LIVE for morph.*
    postJson("/api/reset", "");
    selectAllVerts(8);

    const before = changes();

    // The map family, one representative of each `MapOp` arm the kind will
    // carry once the groups migrate: Create, Values, Rename, Remove.
    cmdJ("mesh.weightmap.create", `{"name":"wmA"}`);
    cmdJ("mesh.weightmap.set",    `{"name":"wmA","vert":0,"weight":1.0}`);
    cmdJ("mesh.weightmap.rename", `{"from":"wmA","to":"wmB"}`);
    cmdJ("mesh.weightmap.remove", `{"name":"wmB"}`);

    cmdJ("mesh.morph.create", `{"name":"mA","kind":"relative"}`);
    cmdJ("mesh.morph.set",    `{"name":"mA","vert":6,"x":2.0,"y":0.0,"z":0.0}`);
    cmdJ("mesh.morph.clear",  `{"name":"mA","vert":6}`);
    cmdJ("mesh.morph.rename", `{"from":"mA","to":"mB"}`);
    cmdJ("mesh.morph.remove", `{"name":"mB"}`);

    cmdJ("uv.project", `{"mode":"planar","axis":"z"}`);

    // …and their UNDOs, because the replay guard and the bind terms only run
    // on `apply`/`revert`. A forward-only exercise cannot move `mapDeltaMix`-
    // `Refused` or `mapDeltaBindRefused` at all.
    //
    // THE COUNT IS ASSERTED. Ten commands were dispatched above and every one
    // of them lands a history entry, so ten undos must succeed; anything less
    // means the replay this block is measuring did not run and its three zeros
    // are dead cells again.
    const size_t undone = undoN(10);
    assert(undone == 10, format(
        "only %d of 10 undos succeeded — the replay that moves these counters "
      ~ "did not run, so the zeros below would be measuring nothing. (This is "
      ~ "the exact shape the file shipped with: ten posts to a command id that "
      ~ "does not exist, none of them checked.)", undone));

    // …and their REDOs, and then the undos again. `applyForward` is a separate
    // dispatch from `applyReverse` and has its own bind path: the `Create`
    // arm's forward REGISTERS a map and refuses on a taken name, which only a
    // redo can reach. Without this pass the whole forward half of
    // `patchMapValues` is unexercised in this lane.
    const size_t redone = redoN(10);
    assert(redone == 10, format(
        "only %d of 10 redos succeeded — the FORWARD half of the map dispatch "
      ~ "is then unexercised in this lane.", redone));
    const size_t undone2 = undoN(10);
    assert(undone2 == 10, format(
        "only %d of 10 second-pass undos succeeded", undone2));

    const after = changes();

    static struct Row { string key; string why; }
    static immutable Row[] rows = [
        Row("mapDeltaMixRecorded",
            "a command built a log carrying a map-value entry BESIDE an entry "
          ~ "that moves an index space. The map half of that log is refused at "
          ~ "replay, so the undo restores the geometry and not the map plane"),
        Row("mapDeltaMixRefused",
            "a replay actually skipped map entries — the runtime half of the "
          ~ "same violation"),
        Row("mapDeltaBindRefused",
            "a map entry could not bind its map at replay: gone, renamed, or "
          ~ "back with a different dim / domain / kind. History drift"),
        // The four invariant counters beside them, so a regression in the
        // batch machinery this stage touches does not hide behind the three
        // new zeros.
        Row("nestedBatchOpens",  "a command called a command"),
        Row("batchUpgradeRefusals", "a recording batch opened inside an unrecorded one"),
        Row("batchLeaks",        "an exception escaped between a batch open and its close"),
        Row("missedPublishers",  "a mutation bumped a version and published nothing"),
    ];

    foreach (ref r; rows) {
        const long d = after[r.key].integer - before[r.key].integer;
        assert(d == 0, format(
            "/api/changes.%s moved by %d across the map command family and its "
          ~ "undos — %s.", r.key, d, r.why));
    }
}

unittest { // block 2 — the three fields are SERIALISED. Live at this commit.
    // Without this the counters exist on the bus and nothing can read them,
    // which is exactly how a counter becomes a presence bit. A mutation that
    // drops any of the three from `/api/changes`'s format string reddens here.
    const c = changes();
    foreach (key; ["mapDeltaMixRecorded", "mapDeltaMixRefused",
                   "mapDeltaBindRefused"]) {
        assert(key in c, format(
            "/api/changes does not carry `%s`. The suite cannot assert a "
          ~ "counter it cannot read, and Stage L1-a's own witnesses read these "
          ~ "three over the wire.", key));
        assert(c[key].type == JSONType.integer, format(
            "/api/changes.%s is not an integer: %s", key, c[key].toString));
    }
}
