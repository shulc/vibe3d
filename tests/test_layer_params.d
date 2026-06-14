// Survey #3 P3 — layer.attr command: generic per-layer Param write/read,
// UI-undo coalescing, and the "mesh untouched" (non-baked) contract.
//
// HTTP-driven, harness copied from tests/test_layers.d. The layer property
// edited here (pos.x, pos.y) is render-only / non-baked: writing it mutates the
// layer's stored transform but NEVER moves a vertex, so /api/model vertex count
// and per-layer mutationVersion must be unchanged after a write.
//
// Coalescing PATH (reported in the agent summary): the programmatic
// /api/command dispatch routes a non-query write through
// CommandHistory.recordCoalescing() (app.d), so consecutive LayerAttr writes to
// the SAME (index, attr) merge into ONE undo entry across SEPARATE /api/command
// calls — no same-generation latch is needed (unlike the forms-interactive
// tool.pipe.attr scrub). This test therefore asserts coalescing over HTTP. The
// compareOp/mergeFrom CONTRACT is additionally locked by an in-module unittest
// in source/commands/layer/commands.d.

import std.net.curl;
import std.json;
import std.conv    : to;
import core.thread : Thread;
import core.time   : dur;

void main() {}

immutable baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

JSONValue cmdMayFail(string argstring) {
    return parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
}

void resetCube() {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

JSONValue postUndo() {
    return parseJSON(cast(string)post(baseUrl ~ "/api/undo", ""));
}

void undoOk(string why) {
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo (" ~ why ~ ") failed: " ~ u.toString);
}

long undoCount() { return getJson("/api/history")["undo"].array.length; }

JSONValue getModelLayer(int layer) {
    return getJson("/api/model?layer=" ~ layer.to!string);
}

size_t vertCount(int layer) { return getModelLayer(layer)["vertices"].array.length; }

// Per-layer mutationVersion is exposed on /api/layers (not /api/model). It is
// the test-visible "did the mesh actually change" surface — a layer.attr write
// must leave it untouched (non-baked render data, not geometry).
ulong mutationVersion(int layer) {
    foreach (l; getJson("/api/layers")["layers"].array)
        if (l["index"].integer == layer)
            return cast(ulong)l["mutationVersion"].integer;
    assert(false, "no layer " ~ layer.to!string ~ " in /api/layers");
}

// Read a layer attr back via the `?` query idiom. The query short-circuit
// returns the boxed value under the "value" key of the {"status":"ok",...}
// response (the same marshal the tool/stage attr queries use). Driven through
// the argstring form (`layer.attr <i> <attr> ?`) — the dispatcher's positional
// injector populates index/attr/`?` from the parsed argstring.
double readAttr(int index, string attr) {
    auto body_ = "layer.attr " ~ index.to!string ~ " " ~ attr ~ " ?";
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
    assert(j["status"].str == "ok", "query `" ~ attr ~ "` failed: " ~ j.toString);
    assert("value" in j, "query response carries a value: " ~ j.toString);
    auto r = j["value"];
    if (r.type == JSONType.float_)   return r.floating;
    if (r.type == JSONType.integer)  return cast(double)r.integer;
    if (r.type == JSONType.uinteger) return cast(double)r.uinteger;
    assert(false, "unexpected value type for `" ~ attr ~ "`: " ~ j.toString);
}

// Write a layer attr via the argstring form (the forms-panel dispatch shape:
// `layer.attr <index> <attr> <value>`).
JSONValue writeAttr(int index, string attr, double value) {
    auto body_ = "layer.attr " ~ index.to!string ~ " " ~ attr ~ " " ~ value.to!string;
    return cmdMayFail(body_);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Set/read round-trip: a written value reads back through the `?` query.
unittest {
    resetCube();
    auto r = writeAttr(0, "pos.x", 1.5);
    assert(r["status"].str == "ok", "write pos.x failed: " ~ r.toString);

    import std.math : isClose;
    assert(isClose(readAttr(0, "pos.x"), 1.5, 1e-6),
           "pos.x reads back as written");

    // A second attr on the same layer is independent.
    writeAttr(0, "pos.z", -2.0);
    assert(isClose(readAttr(0, "pos.z"), -2.0, 1e-6), "pos.z independent");
    assert(isClose(readAttr(0, "pos.x"), 1.5, 1e-6), "pos.x untouched by pos.z");
}

// Mesh untouched: vertex count + per-layer mutationVersion unchanged after a
// layer.attr write (it is non-baked render data, not geometry).
unittest {
    resetCube();
    auto vBefore = vertCount(0);
    auto mvBefore = mutationVersion(0);

    writeAttr(0, "pos.x", 5.0);
    writeAttr(0, "rot.y", 30.0);
    writeAttr(0, "scl.z", 2.0);

    assert(vertCount(0) == vBefore, "vertex count unchanged by layer.attr");
    assert(mutationVersion(0) == mvBefore,
           "mutationVersion unchanged by layer.attr (non-baked, no mesh edit)");
}

// Undo coalescing: N consecutive writes to the SAME (index, attr) collapse to
// ONE undo entry over separate /api/command calls; ONE undo restores the
// ORIGINAL pre-run value. A write to a DIFFERENT attr does NOT coalesce.
unittest {
    import std.math : isClose;
    resetCube();

    // Capture the genuine pre-run value (the "original" the single undo must
    // restore). /api/reset rebuilds the mesh but the non-baked layer transform
    // is independent document state, so we read it rather than assume 0.
    auto orig = readAttr(0, "pos.x");
    auto base = undoCount();   // history.clear leaves the stack at a known base

    // Five writes to pos.x — a panel drag of one field.
    foreach (i; 0 .. 5)
        writeAttr(0, "pos.x", cast(double)(i + 1));   // 1,2,3,4,5
    assert(isClose(readAttr(0, "pos.x"), 5.0, 1e-6), "last write wins");
    assert(undoCount() == base + 1,
           "five same-attr writes coalesce to ONE undo entry (got "
           ~ undoCount().to!string ~ ", base " ~ base.to!string ~ ")");

    // One undo unwinds the whole run to the pre-run value.
    undoOk("coalesced pos.x run");
    assert(isClose(readAttr(0, "pos.x"), orig, 1e-6),
           "single undo restores the original pre-run value");
    assert(undoCount() == base, "undo dropped the one coalesced entry");

    // A different attr breaks the run → two separate entries.
    writeAttr(0, "pos.x", 7.0);
    writeAttr(0, "pos.y", 9.0);
    assert(undoCount() == base + 2,
           "pos.x then pos.y are TWO undo entries (no cross-attr coalesce), got "
           ~ undoCount().to!string);
}

// ---------------------------------------------------------------------------
// Phase 5: the `name` param rides the GENERIC registry end-to-end (the "one
// declaration" proof). `name` is a plain String param on LayerPropsProvider, so
// it must set/read/undo through the SAME `layer.attr` machinery as a transform
// component — distinct from (and in addition to) the explicit `layer.rename`.
// ---------------------------------------------------------------------------

// Read a layer's `name` back via the `?` query idiom (the String analogue of
// readAttr — the boxed query value is a JSON string for a String param).
string readName(int index) {
    auto body_ = "layer.attr " ~ index.to!string ~ " name ?";
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
    assert(j["status"].str == "ok", "name query failed: " ~ j.toString);
    assert("value" in j, "name query carries a value: " ~ j.toString);
    auto r = j["value"];
    assert(r.type == JSONType.string, "name query boxes a string: " ~ j.toString);
    return r.str;
}

// Write a layer's `name` via the argstring form (`layer.attr <i> name <value>`).
JSONValue writeName(int index, string value) {
    auto body_ = "layer.attr " ~ index.to!string ~ " name " ~ value;
    return cmdMayFail(body_);
}

// Set the name via `layer.attr`, read it back via `?`, and confirm the edit is
// UI-undoable. This proves `name` participates in the generic param path; the
// `.v3d` name round-trip is already covered by tests/test_v3d_layers.d (a
// multi-layer file with distinct names Tri/Quad/Pent saves + loads), so it is
// referenced rather than re-asserted here — the focus is the layer.attr path.
unittest {
    resetCube();

    // Capture the genuine pre-edit name (the value a single undo must restore).
    auto orig = readName(0);

    auto r = writeName(0, "Renamed");
    assert(r["status"].str == "ok", "write name failed: " ~ r.toString);
    assert(readName(0) == "Renamed", "name reads back as written via layer.attr");

    // The /api/layers envelope reflects the same name (the generic write hit the
    // live layer field, not a parallel copy).
    bool found = false;
    foreach (l; getJson("/api/layers")["layers"].array)
        if (l["index"].integer == 0) {
            assert(l["name"].str == "Renamed",
                   "/api/layers shows the layer.attr-written name");
            found = true;
        }
    assert(found, "layer 0 present in /api/layers");

    // One undo restores the original name (UI-undoable, like any other attr).
    auto base = undoCount();
    undoOk("layer.attr name edit");
    assert(readName(0) == orig, "single undo restores the pre-edit name");
    assert(undoCount() == base - 1, "undo dropped the name-edit entry");
}

// A run of `name` edits coalesces like any other attr: N writes to (layer 0,
// name) collapse into ONE undo entry, and one undo unwinds the whole run to the
// pre-run name.
unittest {
    resetCube();
    auto orig = readName(0);
    auto base = undoCount();

    foreach (i; 0 .. 4)
        writeName(0, "N" ~ (i + 1).to!string);   // N1, N2, N3, N4
    assert(readName(0) == "N4", "last name write wins");
    assert(undoCount() == base + 1,
           "four same-attr name writes coalesce to ONE undo entry (got "
           ~ undoCount().to!string ~ ", base " ~ base.to!string ~ ")");

    undoOk("coalesced name run");
    assert(readName(0) == orig,
           "single undo restores the original pre-run name");
    assert(undoCount() == base, "undo dropped the one coalesced entry");
}

// Query of an unknown attr name is handled gracefully (no crash; error status).
unittest {
    resetCube();
    auto body_ = "layer.attr 0 does.not.exist ?";
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
    assert(j["status"].str == "error",
           "unknown attr query returns an error status (no crash): " ~ j.toString);

    // The server is still alive and serving after the graceful error.
    assert(vertCount(0) == 8, "server still responsive after unknown-attr query");
}
