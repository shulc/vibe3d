// Forms-engine query (read-back) tests — the `?` wire idiom (forms_engine_plan
// Phase 1).
//
// Verifies that `tool.attr <id> <attr> ?` and `tool.pipe.attr <stage> <attr> ?`
// become QUERIES that resolve the attr against the active tool/stage params()
// schema and return the live value as the command result, instead of writing:
//   - a fresh-tool attr query returns the schema default;
//   - write-then-query round-trips for float / bool / int-enum;
//   - an unknown attr query → clean error (status != ok);
//   - a stage-attr query round-trips (falloff geometry attrs);
//   - a query moves NO geometry and records NO undo entry;
//   - a query works while a LIVE session is open (returns the live value).
//
// All driven over HTTP via /api/command, mirroring test_reevaluate's idioms.

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

// Run a command and assert ok.
void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "/api/command '" ~ line ~ "' failed: "
        ~ r.toString);
}

// Run a command, return raw parsed JSON (for query-result + error inspection).
JSONValue cmdRaw(string line) {
    return postJson("/api/command", line);
}

// Run a `?`-query command, assert ok, return the boxed "value".
JSONValue query(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "query '" ~ line ~ "' failed: " ~ r.toString);
    assert("value" in r,
        "query '" ~ line ~ "' returned no value field: " ~ r.toString);
    return r["value"];
}

void resetCube() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

double[3] vertexAt(int idx) {
    auto v = getJson("/api/model")["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

void selectVerts(int[] idx) {
    string s = "[";
    foreach (i, v; idx) { if (i) s ~= ","; s ~= v.to!string; }
    s ~= "]";
    auto r = postJson("/api/select", `{"mode":"vertices","indices":` ~ s ~ `}`);
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

// ---------------------------------------------------------------------------
// 1. Fresh-tool attr query returns the schema default.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set move");
    // XfrmTransformTool float attrs default to 0; T/R/S bool flags vary by
    // preset, so probe a numeric default that is unambiguous.
    auto tx = query("tool.attr move TX ?");
    assert(tx.type == JSONType.float_ || tx.type == JSONType.integer,
        "TX query should box a number, got " ~ tx.toString);
    assert(approxEqual(tx.floating, 0.0),
        "fresh-tool TX default should be 0, got " ~ tx.toString);
    cmd("tool.set move off");
}

// ---------------------------------------------------------------------------
// 2. Write-then-query round-trips: float (TX), bool (T), int-enum (sphere
//    method).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set move");

    // Float round-trip.
    cmd("tool.attr move TX 1.5");
    auto tx = query("tool.attr move TX ?");
    assert(approxEqual(tx.floating, 1.5),
        "TX write-then-query should be 1.5, got " ~ tx.toString);

    // Bool round-trip — set both states and read back.
    cmd("tool.attr move T true");
    auto tTrue = query("tool.attr move T ?");
    assert(tTrue.type == JSONType.true_,
        "T after write true should be JSON true, got " ~ tTrue.toString);
    cmd("tool.attr move T false");
    auto tFalse = query("tool.attr move T ?");
    assert(tFalse.type == JSONType.false_,
        "T after write false should be JSON false, got " ~ tFalse.toString);

    cmd("tool.set move off");

    // Int-enum round-trip on a primitive tool that has one (sphere `method`).
    cmd("tool.set prim.sphere");
    auto m0 = query("tool.attr prim.sphere method ?");
    assert(m0.type == JSONType.string,
        "intEnum method should box as wireTag string, got " ~ m0.toString);
    assert(m0.str == "globe",
        "fresh sphere method default should be 'globe', got " ~ m0.str);
    cmd("tool.attr prim.sphere method qball");
    auto m1 = query("tool.attr prim.sphere method ?");
    assert(m1.str == "qball",
        "sphere method after write should be 'qball', got " ~ m1.str);
    cmd("tool.set prim.sphere off");
}

// ---------------------------------------------------------------------------
// 3. Unknown attr query → clean error (status != ok, no crash).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set move");
    auto r = cmdRaw("tool.attr move NOPE ?");
    assert(r["status"].str == "error",
        "unknown-attr query should error, got " ~ r.toString);
    assert("value" !in r,
        "errored query must not carry a value field: " ~ r.toString);
    cmd("tool.set move off");
}

// ---------------------------------------------------------------------------
// 4. Stage-attr query round-trips (falloff geometry attrs).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    // Radial falloff exposes center/size (Vec3) in params(). Write then query.
    cmd("tool.pipe.attr falloff type radial");
    cmd(`tool.pipe.attr falloff size "2,3,4"`);
    auto sz = query("tool.pipe.attr falloff size ?");
    assert(sz.type == JSONType.array && sz.array.length == 3,
        "falloff size query should box a [x,y,z] array, got " ~ sz.toString);
    assert(approxEqual(sz.array[0].floating, 2.0)
        && approxEqual(sz.array[1].floating, 3.0)
        && approxEqual(sz.array[2].floating, 4.0),
        "falloff size round-trip mismatch: " ~ sz.toString);

    // An attr the CURRENT type does not expose resolves as unknown (runtime
    // visibility): radial does not expose linear's `start`.
    auto miss = cmdRaw("tool.pipe.attr falloff start ?");
    assert(miss["status"].str == "error",
        "querying a type-filtered-out stage attr should error: "
        ~ miss.toString);

    // Reset falloff to a clean state for following tests.
    cmd("tool.pipe.attr falloff type none");
}

// ---------------------------------------------------------------------------
// 5. A query moves NO geometry and records NO undo entry.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set move");
    selectVerts([6]);

    auto before = vertexAt(6);
    long undoBefore = undoCount();

    // A burst of queries — both namespaces — must not touch the mesh or stack.
    query("tool.attr move TX ?");
    query("tool.attr move TY ?");
    cmd("tool.pipe.attr falloff type radial");
    auto undoAfterStageWrite = undoCount();
    query("tool.pipe.attr falloff size ?");

    auto after = vertexAt(6);
    assert(approxEqual(before[0], after[0])
        && approxEqual(before[1], after[1])
        && approxEqual(before[2], after[2]),
        "queries must not move geometry: v6 before "
        ~ before.to!string ~ " after " ~ after.to!string);
    // The falloff type write is non-undoable (SideEffect), so the count must
    // not grow across the queries that bracket it.
    assert(undoCount() == undoAfterStageWrite,
        "queries must record no undo entry: count moved from "
        ~ undoAfterStageWrite.to!string ~ " to " ~ undoCount().to!string);
    assert(undoCount() == undoBefore,
        "neither the queries nor the SideEffect stage write should add undo "
        ~ "entries: before=" ~ undoBefore.to!string
        ~ " after=" ~ undoCount().to!string);

    cmd("tool.pipe.attr falloff type none");
    cmd("tool.set move off");
}

// ---------------------------------------------------------------------------
// 6. Query works while a LIVE session is open — returns the live value, and
//    does not disturb the in-flight session.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set move");
    selectVerts([6]);

    // Open a live edit session (testMode hook) and drive an absolute write.
    cmd("tool.beginSession");
    cmd("tool.attr move TX 0.75");

    // Query mid-session: must return the live attr value without ending or
    // perturbing the session.
    auto tx = query("tool.attr move TX ?");
    assert(approxEqual(tx.floating, 0.75),
        "mid-session query should return the live TX 0.75, got " ~ tx.toString);

    // The session is still live: a follow-up absolute write must replace, not
    // accumulate (proving the query did not commit/reset the session).
    cmd("tool.attr move TX 0.25");
    auto tx2 = query("tool.attr move TX ?");
    assert(approxEqual(tx2.floating, 0.25),
        "post-query absolute write should land at 0.25, got " ~ tx2.toString);

    cmd("tool.set move off");
}
