// Tests for the per-layer item transform (`xform`) `.v3d` round-trip
// (per-item channels Phase 1).
//
// v5 of the format adds an OPTIONAL grouped per-layer `xform` block:
//   "xform": { "pos":[x,y,z], "rot":[x,y,z], "scl":[x,y,z], "pivot":[x,y,z] }
// authored as four `Vec3` channels (NOT a derived matrix). The block is omitted
// when the transform is all-default (pos=0, rot=0, scl=1, pivot=0); a missing
// block ⇒ identity (the within-v5 optional-field contract, NOT back-compat).
//
// There is no HTTP surface that exposes a layer's transform in Phase 1 (that is
// P4's `/api/layers` extension), so the round-trip is verified the same way the
// per-corner UV tests verify theirs: write a hand-crafted v5 file with an
// `xform` block, `file.load` it, `file.save` it back out, and compare the
// re-saved `xform` bytes off disk. The load fills `Layer.xform` from the block;
// the save re-emits it from `Layer.xform`, so an exact match proves BOTH halves
// (the reader stored the four channels, the writer emitted them).
//
// Coverage:
//   1. round-trip: a non-default xform (distinct pos/rot/scl/pivot) survives
//      load -> save byte-exact;
//   2. missing-block: a v5 layer with no `xform` loads as identity, so a
//      re-save omits the block (omit-when-default proves identity);
//   3. version gate: a formatVersion-4 file is rejected cleanly (clean break);
//   4. multi-layer: two layers carry distinct transforms that round-trip
//      independently (no cross-layer aliasing);
//   5. tolerant read: a malformed `xform` sub-array degrades that component to
//      its identity default and still loads.

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

// Assert a parsed [x,y,z] JSON triple equals the expected three doubles (1e-6).
private void assertTriple(const JSONValue arr, double[3] want, string ctx) {
    assert(arr.type == JSONType.array && arr.array.length == 3,
        ctx ~ ": not an [x,y,z] triple");
    foreach (k; 0 .. 3)
        assert(isClose(num(arr.array[k]), want[k], 1e-6),
            ctx ~ " component " ~ k.to!string ~ " mismatch: expected "
            ~ want[k].to!string ~ ", got " ~ num(arr.array[k]).to!string);
}

unittest { // round-trip: a non-default xform survives load -> save byte-exact
    enum string path = "/tmp/vibe3d-test-xform-in.v3d";
    write(path,
        `{"formatVersion":5,"primaryLayer":0,"layers":[`
        ~ `{"name":"Tri","visible":true,"selected":true,`
        ~ `"xform":{"pos":[1.5,-2.0,3.25],"rot":[10.0,20.0,-30.0],`
        ~ `"scl":[2.0,0.5,4.0],"pivot":[0.1,0.2,0.3]},`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);

    // Geometry loaded (the triangle, not the reset cube) — proves the load took.
    auto m = model();
    assert(m["vertexCount"].integer == 3, "triangle should load (3 verts)");

    // Re-save and read the xform block straight off disk.
    enum string outp = "/tmp/vibe3d-test-xform-out.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto saved = parseJSON(readText(outp));

    assert(saved["formatVersion"].integer == 5, "re-save is v5");
    auto l0 = saved["layers"].array[0];
    assert("xform" in l0, "non-default xform must be emitted on re-save");
    auto xf = l0["xform"];
    assertTriple(xf["pos"],   [1.5, -2.0, 3.25], "pos");
    assertTriple(xf["rot"],   [10.0, 20.0, -30.0], "rot");
    assertTriple(xf["scl"],   [2.0, 0.5, 4.0], "scl");
    assertTriple(xf["pivot"], [0.1, 0.2, 0.3], "pivot");
}

unittest { // missing-block: a v5 layer with no xform loads as identity
    // Omit-when-default means a re-save of an identity transform carries NO
    // xform key. So loading a file with no xform and re-saving with no xform key
    // proves the load left the transform at identity.
    enum string path = "/tmp/vibe3d-test-xform-missing.v3d";
    write(path,
        `{"formatVersion":5,"primaryLayer":0,"layers":[`
        ~ `{"name":"Tri","visible":true,"selected":true,`
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
    auto saved = parseJSON(readText(outp));
    assert("xform" !in saved["layers"].array[0],
        "a layer loaded with no xform must stay identity (omitted on re-save)");
}

unittest { // an identity reset cube re-saves with NO xform key (omit-when-default)
    enum string outp = "/tmp/vibe3d-test-xform-defaultomit.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);

    resetCube();
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto saved = parseJSON(readText(outp));
    assert(saved["formatVersion"].integer == 5, "writer emits v5");
    assert("xform" !in saved["layers"].array[0],
        "a default (identity) layer must omit the xform key entirely");
}

unittest { // version gate: a formatVersion-4 file is rejected cleanly (clean break)
    enum string path = "/tmp/vibe3d-test-xform-v4reject.v3d";
    write(path,
        `{"formatVersion":4,"primaryLayer":0,"layers":[`
        ~ `{"name":"Layer 1","visible":true,"selected":true,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for legacy v4 file (Phase 1 clean break), got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "cube must be intact after a rejected v4 load");
}

unittest { // multi-layer: two layers carry distinct transforms, round-trip independent
    enum string path = "/tmp/vibe3d-test-xform-multilayer.v3d";
    write(path,
        `{"formatVersion":5,"primaryLayer":0,"layers":[`
        ~ `{"name":"A","visible":true,"selected":true,`
        ~ `"xform":{"pos":[1.0,0.0,0.0],"rot":[0.0,0.0,0.0],`
        ~ `"scl":[1.0,1.0,1.0],"pivot":[0.0,0.0,0.0]},`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}},`
        ~ `{"name":"B","visible":true,"selected":false,`
        ~ `"xform":{"pos":[0.0,0.0,0.0],"rot":[45.0,0.0,0.0],`
        ~ `"scl":[3.0,3.0,3.0],"pivot":[5.0,6.0,7.0]},`
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
    auto xa = layers[0]["xform"];
    assertTriple(xa["pos"],   [1.0, 0.0, 0.0], "A.pos");
    assertTriple(xa["rot"],   [0.0, 0.0, 0.0], "A.rot");
    assertTriple(xa["scl"],   [1.0, 1.0, 1.0], "A.scl");
    assertTriple(xa["pivot"], [0.0, 0.0, 0.0], "A.pivot");

    // Layer B: a completely different transform — no bleed from A.
    auto xb = layers[1]["xform"];
    assertTriple(xb["pos"],   [0.0, 0.0, 0.0], "B.pos");
    assertTriple(xb["rot"],   [45.0, 0.0, 0.0], "B.rot");
    assertTriple(xb["scl"],   [3.0, 3.0, 3.0], "B.scl");
    assertTriple(xb["pivot"], [5.0, 6.0, 7.0], "B.pivot");
}

unittest { // tolerant read: a malformed xform sub-array degrades to identity, still loads
    // `pos` is a non-array (a number); `scl` is a too-short array. Both must be
    // skipped (left at identity: pos=0, scl=1) while `rot` and `pivot` parse
    // fine and the geometry loads. A re-save then shows pos=0/scl=1 (identity
    // for the skipped fields) with the good rot/pivot preserved.
    enum string path = "/tmp/vibe3d-test-xform-malformed.v3d";
    write(path,
        `{"formatVersion":5,"primaryLayer":0,"layers":[`
        ~ `{"name":"Tri","visible":true,"selected":true,`
        ~ `"xform":{"pos":42,"rot":[10.0,0.0,0.0],`
        ~ `"scl":[2.0,2.0],"pivot":[1.0,2.0,3.0]},`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    // The file still loaded despite the malformed sub-arrays.
    assert(model()["vertexCount"].integer == 3,
        "triangle must still load with a malformed xform");

    enum string outp = "/tmp/vibe3d-test-xform-malformed-out.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto saved = parseJSON(readText(outp));
    auto l0 = saved["layers"].array[0];
    // rot + pivot survived; the good values force the xform non-default, so the
    // block is present and the skipped fields show their identity defaults.
    assert("xform" in l0, "good rot/pivot keep the xform non-default");
    auto xf = l0["xform"];
    assertTriple(xf["pos"],   [0.0, 0.0, 0.0], "pos (malformed -> identity 0)");
    assertTriple(xf["rot"],   [10.0, 0.0, 0.0], "rot (good)");
    assertTriple(xf["scl"],   [1.0, 1.0, 1.0], "scl (malformed -> identity 1)");
    assertTriple(xf["pivot"], [1.0, 2.0, 3.0], "pivot (good)");
}
