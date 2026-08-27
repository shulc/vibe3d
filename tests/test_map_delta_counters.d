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
// THIS FILE IS A DEBT ROW, NOT A GREEN. READ THIS BEFORE TRUSTING ITS ZEROS.
// -------------------------------------------------------------------------
// At the commit that introduced the kind, NO SHIPPED RECORDER EMITS IT: all 21
// map command classes still record whole-mesh `MeshSnapshot` pairs, and the
// kind's first production caller is Stage L1-a (`commands/mesh/morph.d`). So
// the three counters below CANNOT MOVE in this lane however broken the
// dispatch is — no mutation of the guard, the latch or the bind terms reddens
// block 1, and its zeros are dead cells.
//
// It ships anyway, with this sentence attached, for two reasons. Block 2 is
// live TODAY: it pins that the three fields are actually SERIALISED, which a
// mutation of `http_server.d`'s format string reddens immediately — and a
// counter nobody can read is a counter nobody will assert. And block 1 becomes
// a real check the moment L1-a lands, which is the commit that OWES it: the
// migrated morph group exercises all four `MapOp` arms in production, and from
// then on a mixed log or a bind refusal shows up here.
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

void selectAllVerts(int n) {
    import std.conv : to;
    string idx;
    foreach (i; 0 .. n) { if (i) idx ~= ","; idx ~= i.to!string; }
    auto j = postJson("/api/select", `{"mode":"vertices","indices":[` ~ idx ~ `]}`);
    assert(j["status"].str == "ok", "select failed: " ~ j.toString);
}

unittest { // block 1 — the family moves none of the three. VACUOUS AT L1-P1.
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
    foreach (_; 0 .. 10) postJson("/api/command", `{"id":"undo"}`);

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
