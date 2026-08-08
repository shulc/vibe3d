// Tests for the per-layer item transform's `.v3d` round-trip.
//
// FORMAT NOTE (task 0616 Ph6, `.v3d` v8). The item transform used to live in
// its own grouped, hand-written block:
//     "xform": { "pos":[x,y,z], "rot":[x,y,z], "scl":[x,y,z], "pivot":[x,y,z] }
// omitted entirely when the transform was identity. v8 deleted that block. The
// transform is now twelve FLAT scalar keys inside the item's generic
// `channels` object — `pos.x` … `pivot.z`, the same names the param provider
// exposes — and `channels` is written IN FULL, so there is no longer an
// omit-when-default rule to test. Those two changes are what let a future item
// kind's channels ride the same codec with no version bump, which is the whole
// point of the v8 design.
//
// There is no HTTP surface that exposes a layer's transform through the file,
// so the round-trip is verified the way the per-corner UV tests verify theirs:
// write a hand-crafted v8 file, `file.load` it, `file.save` it back out, and
// compare the re-saved channel values off disk. The load fills `Layer.xform`
// through the generic param injector; the save re-emits it from the same
// params, so an exact match proves BOTH halves.
//
// Coverage:
//   1. round-trip: a non-default transform (distinct pos/rot/scl/pivot)
//      survives load -> save;
//   2. omitted keys: an item whose `channels` names no transform key loads as
//      identity — and v8 WRITES that identity back explicitly;
//   3. a default (reset) document writes the identity channel set, and carries
//      no retired `xform` / `name` / `visible` top-level keys;
//   4. version gate: the previous format version (v7) is rejected cleanly;
//   5. multi-layer: two items carry distinct transforms that round-trip
//      independently (no cross-item aliasing);
//   6. a channel value that is not a number degrades that ONE component and
//      still loads — and a degenerate `scl` is repaired to the band floor
//      rather than left singular.

import std.net.curl;
import std.json;
import std.file : remove, exists, getSize, write, readText;
import std.conv : to;
import std.math : isClose;

void main() {}

void resetCube() {
    post("http://localhost:8080/api/reset", "");
}

void runCmd(string id, string params = "") {
    string body = params.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    auto resp = post("http://localhost:8080/api/command", body);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok", id ~ " failed: " ~ resp);
}

string runCmdAllowError(string id, string params = "") {
    string body = params.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    return cast(string) post("http://localhost:8080/api/command", body);
}

JSONValue model() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

// Read a JSON number (float or int encoding) as a double for comparison.
private double num(const JSONValue v) {
    return v.type == JSONType.float_   ? v.floating
         : v.type == JSONType.integer  ? cast(double) v.integer
         : v.type == JSONType.uinteger ? cast(double) v.uinteger
         : double.nan;
}

// Assert the three flat channel keys `<group>.x/.y/.z` equal the expected
// three doubles (1e-6). The flat-key shape is the v8 form.
private void assertChannelTriple(const JSONValue channels, string group,
                                 double[3] want, string ctx) {
    static immutable string[3] axis = ["x", "y", "z"];
    foreach (k; 0 .. 3) {
        const key = group ~ "." ~ axis[k];
        assert(key in channels, ctx ~ ": missing channel " ~ key);
        assert(isClose(num(channels[key]), want[k], 1e-6),
            ctx ~ " " ~ key ~ " mismatch: expected " ~ want[k].to!string
            ~ ", got " ~ num(channels[key]).to!string);
    }
}

unittest { // 1. round-trip: a non-default transform survives load -> save
    enum string path = "/tmp/vibe3d-test-xform-in.v3d";
    write(path,
        `{"formatVersion":8,"primaryLayer":0,"layers":[`
        ~ `{"type":"mesh","selected":true,`
        ~ `"channels":{"name":"Tri","visible":true,`
        ~ `"pos.x":1.5,"pos.y":-2.0,"pos.z":3.25,`
        ~ `"rot.x":10.0,"rot.y":20.0,"rot.z":-30.0,`
        ~ `"scl.x":2.0,"scl.y":0.5,"scl.z":4.0,`
        ~ `"pivot.x":0.1,"pivot.y":0.2,"pivot.z":0.3},`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);

    // Geometry loaded (the triangle, not the reset cube) — proves the load took.
    auto m = model();
    assert(m["vertexCount"].integer == 3, "triangle should load (3 verts)");

    // Re-save and read the channels straight off disk.
    enum string outp = "/tmp/vibe3d-test-xform-out.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto saved = parseJSON(readText(outp));

    assert(saved["formatVersion"].integer == 8, "re-save is v8");
    auto l0 = saved["layers"].array[0];
    assert("xform" !in l0,
        "the grouped `xform` block is retired — a codec still emitting it "
        ~ "would be a second source of truth for the same twelve numbers");
    auto ch = l0["channels"];
    assertChannelTriple(ch, "pos",   [1.5, -2.0, 3.25],  "pos");
    assertChannelTriple(ch, "rot",   [10.0, 20.0, -30.0], "rot");
    assertChannelTriple(ch, "scl",   [2.0, 0.5, 4.0],     "scl");
    assertChannelTriple(ch, "pivot", [0.1, 0.2, 0.3],     "pivot");
    assert(ch["name"].str == "Tri",
        "`name` is a channel now, and it round-trips with the rest");
}

unittest { // 2. omitted transform keys load as identity
    // v8 has no omit-when-default rule, so identity is proved by the WRITTEN
    // values rather than by the absence of a key. The fixture omits every
    // transform key; the re-save must then carry the identity values
    // explicitly (0/0/1/0), not the previous document's numbers.
    enum string path = "/tmp/vibe3d-test-xform-missing.v3d";
    write(path,
        `{"formatVersion":8,"primaryLayer":0,"layers":[`
        ~ `{"type":"mesh","selected":true,"channels":{"name":"Tri"},`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    assert(model()["vertexCount"].integer == 3, "triangle should load");

    enum string outp = "/tmp/vibe3d-test-xform-missing-out.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto ch = parseJSON(readText(outp))["layers"].array[0]["channels"];
    assertChannelTriple(ch, "pos",   [0.0, 0.0, 0.0], "pos (omitted -> identity)");
    assertChannelTriple(ch, "rot",   [0.0, 0.0, 0.0], "rot (omitted -> identity)");
    assertChannelTriple(ch, "scl",   [1.0, 1.0, 1.0], "scl (omitted -> identity 1)");
    assertChannelTriple(ch, "pivot", [0.0, 0.0, 0.0], "pivot (omitted -> identity)");
    // The identity for `scl` is 1, not 0 — the one component where "left at
    // its default" and "zero-filled" read differently, which is why this
    // assertion is not decoration.
}

unittest { // 3. a default document writes the full identity channel set
    enum string outp = "/tmp/vibe3d-test-xform-defaultomit.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);

    resetCube();
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto saved = parseJSON(readText(outp));
    assert(saved["formatVersion"].integer == 8, "writer emits v8");
    auto l0 = saved["layers"].array[0];

    // The three keys that MOVED into `channels` must not also sit at the top
    // level: two representations of one value is exactly what v8 removed.
    assert("xform"   !in l0, "no retired grouped xform block");
    assert("name"    !in l0, "`name` lives in channels now, not at top level");
    assert("visible" !in l0, "`visible` lives in channels now, not at top level");
    assert("type"     in l0, "…and the item declares its kind");
    assert(l0["type"].str == "mesh");

    auto ch = l0["channels"];
    assert(ch["name"].str == "Layer 1");
    assert(ch["visible"].type == JSONType.true_);
    assertChannelTriple(ch, "pos",   [0.0, 0.0, 0.0], "default pos");
    assertChannelTriple(ch, "scl",   [1.0, 1.0, 1.0], "default scl");
}

unittest { // 4. version gate: the PREVIOUS format version is rejected cleanly
    // v7 rather than an ancient version on purpose: the near miss is the one a
    // user actually hits, and it is the one a reader that accepted "anything
    // close enough" would wave through.
    enum string path = "/tmp/vibe3d-test-xform-v7reject.v3d";
    write(path,
        `{"formatVersion":7,"primaryLayer":0,"layers":[`
        ~ `{"name":"Layer 1","visible":true,"selected":true,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for a v7 file (the Ph6 clean break), got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "cube must be intact after a rejected v7 load");
}

unittest { // 5. multi-layer: two items carry distinct transforms, no bleed
    enum string path = "/tmp/vibe3d-test-xform-multilayer.v3d";
    write(path,
        `{"formatVersion":8,"primaryLayer":0,"layers":[`
        ~ `{"type":"mesh","selected":true,`
        ~ `"channels":{"name":"A","visible":true,"pos.x":1.0},`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}},`
        ~ `{"type":"mesh","selected":false,`
        ~ `"channels":{"name":"B","visible":true,"rot.x":45.0,`
        ~ `"scl.x":3.0,"scl.y":3.0,"scl.z":3.0,`
        ~ `"pivot.x":5.0,"pivot.y":6.0,"pivot.z":7.0},`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],`
        ~ `"faces":[[0,1,2,3]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    assert(model()["vertexCount"].integer == 3, "primary (A) is the triangle");

    enum string outp = "/tmp/vibe3d-test-xform-multilayer-out.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto saved = parseJSON(readText(outp));
    auto layers = saved["layers"].array;
    assert(layers.length == 2, "both layers re-saved");

    // Layer A: pos.x = 1, everything else identity.
    auto xa = layers[0]["channels"];
    assert(xa["name"].str == "A");
    assertChannelTriple(xa, "pos",   [1.0, 0.0, 0.0], "A.pos");
    assertChannelTriple(xa, "rot",   [0.0, 0.0, 0.0], "A.rot");
    assertChannelTriple(xa, "scl",   [1.0, 1.0, 1.0], "A.scl");
    assertChannelTriple(xa, "pivot", [0.0, 0.0, 0.0], "A.pivot");

    // Layer B: a completely different transform — no bleed from A, in either
    // direction (A's `pos.x` must not appear on B, and B's pivot must not
    // appear on A).
    auto xb = layers[1]["channels"];
    assert(xb["name"].str == "B");
    assertChannelTriple(xb, "pos",   [0.0, 0.0, 0.0], "B.pos");
    assertChannelTriple(xb, "rot",   [45.0, 0.0, 0.0], "B.rot");
    assertChannelTriple(xb, "scl",   [3.0, 3.0, 3.0], "B.scl");
    assertChannelTriple(xb, "pivot", [5.0, 6.0, 7.0], "B.pivot");
}

unittest { // 6. a non-numeric channel value degrades ONE component, still loads
    // `pos.x` is a string and `scl.y` is `null`. Both are numbers the param
    // codec cannot read, so both fall to 0 — and 0 is a legal position but a
    // SINGULAR scale, which the reader's band repair must lift to the floor.
    //
    // Discriminating in three directions: the file still loads (a reader that
    // rejected the whole document over one bad number reads an error); the
    // sibling components of each bad one are untouched (a reader that dropped
    // the whole channel group reads identity for `pos.y`/`pos.z` too); and
    // `scl.y` comes back as the POSITIVE FLOOR, not as 0 — a codec without the
    // band repair loads a singular item transform, which is the state the
    // guard exists to make impossible.
    enum string path = "/tmp/vibe3d-test-xform-malformed.v3d";
    write(path,
        `{"formatVersion":8,"primaryLayer":0,"layers":[`
        ~ `{"type":"mesh","selected":true,`
        ~ `"channels":{"name":"Tri","visible":true,`
        ~ `"pos.x":"nope","pos.y":4.0,"pos.z":-6.0,`
        ~ `"rot.x":10.0,"scl.y":null,`
        ~ `"pivot.x":1.0,"pivot.y":2.0,"pivot.z":3.0},`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    assert(model()["vertexCount"].integer == 3,
        "the triangle must still load despite two unreadable channel values");

    enum string outp = "/tmp/vibe3d-test-xform-malformed-out.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto ch = parseJSON(readText(outp))["layers"].array[0]["channels"];

    assertChannelTriple(ch, "pos",   [0.0, 4.0, -6.0],  "pos (x unreadable -> 0)");
    assertChannelTriple(ch, "rot",   [10.0, 0.0, 0.0],  "rot (good)");
    assertChannelTriple(ch, "pivot", [1.0, 2.0, 3.0],   "pivot (good)");
    assert(isClose(num(ch["scl.x"]), 1.0, 1e-6), "scl.x untouched at identity");
    assert(isClose(num(ch["scl.z"]), 1.0, 1e-6), "scl.z untouched at identity");
    assert(num(ch["scl.y"]) > 0.0 && num(ch["scl.y"]) < 1e-3,
        "an unreadable scale falls to 0 and the band repair lifts it to the "
        ~ "POSITIVE floor — a codec without the repair loads a singular item "
        ~ "transform, got " ~ num(ch["scl.y"]).to!string);
}
