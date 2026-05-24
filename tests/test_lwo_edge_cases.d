// LWO format edge-case tests (Stage C4 of doc/test_coverage_plan.md).
//
// test_file_io.d already pins the basic save → load round-trip plus
// error handling for missing / garbage files. This module covers the
// shape gaps:
//   • empty mesh save → load
//   • multi-thousand-vert mesh (subdivided cube) save → load
//   • per-vertex coordinate preservation, not just topology counts
//   • idempotent multiple save / load cycles (no float drift)
//   • PTCH subpatch chunk on a manually-crafted LWO sets isSubpatch flags
//     (the engine's own export writes FACE only — see source/lwo.d:32 —
//     so this validates the LOAD path independently)

import std.net.curl;
import std.json;
import std.file : remove, exists, getSize, write;
import std.math : fabs;
import std.conv : to;
import std.format : format;
import std.bitmanip : nativeToBigEndian;

void main() {}

string baseUrl = "http://localhost:8080";

void runCmd(string id, string params = "") {
    string body = params.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    auto resp = post(baseUrl ~ "/api/command", body);
    auto j = parseJSON(cast(string)resp);
    assert(j["status"].str == "ok",
        id ~ " failed: " ~ cast(string)resp);
}

JSONValue model() {
    return parseJSON(cast(string)get(baseUrl ~ "/api/model"));
}

// Empty-mesh round-trip: importLWO rejects polygon-less files
// (source/lwo.d:175 — "no polygons" early-out). The save still produces
// a syntactically valid FORM/PNTS chunk, but reloading it is treated as
// invalid and the prior mesh stays. This pin documents that behaviour
// so a future change to support genuinely empty LWO files will trip
// this test and prompt a re-think.
unittest { // empty mesh save → reload is rejected (no POLS); prior mesh kept
    enum string path = "/tmp/vibe3d-test-empty.lwo";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    post(baseUrl ~ "/api/reset?empty=true", "");
    assert(model()["vertexCount"].integer == 0,
        "setup: empty reset should leave 0 verts");

    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "save did not create file even on empty mesh");

    // Re-cube the scene, then try to load — the load should be rejected
    // because the file has no POLS chunk; cube remains intact.
    post(baseUrl ~ "/api/reset", "");
    string body = `{"id":"file.load","params":{"path":"` ~ path ~ `"}}`;
    auto resp  = parseJSON(cast(string)post(baseUrl ~ "/api/command", body));
    assert(resp["status"].str == "error",
        "empty LWO should fail to load; got " ~ resp.toString);
    assert(model()["vertexCount"].integer == 8,
        "cube should still be intact after failed empty-mesh load");
}

unittest { // large mesh round-trip: subdivide twice → save → reload
    enum string path = "/tmp/vibe3d-test-large.lwo";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    post(baseUrl ~ "/api/reset", "");
    // Two Catmull-Clark passes on the cube blow vertex count up by ~16×.
    post(baseUrl ~ "/api/command", "select.typeFrom polygon");
    runCmd("mesh.subdivide");
    runCmd("mesh.subdivide");
    auto m0 = model();
    long preV = m0["vertexCount"].integer;
    long preF = m0["faceCount"].integer;
    assert(preV > 50,
        "subdivide×2 should generate a 50+ vert mesh; got " ~
        preV.to!string);

    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    post(baseUrl ~ "/api/reset", "");
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);

    auto m1 = model();
    assert(m1["vertexCount"].integer == preV,
        "large-mesh reload vertexCount mismatch: " ~
        preV.to!string ~ " → " ~ m1["vertexCount"].integer.to!string);
    assert(m1["faceCount"].integer == preF,
        "large-mesh reload faceCount mismatch: " ~
        preF.to!string ~ " → " ~ m1["faceCount"].integer.to!string);
}

unittest { // vertex positions preserved across save → reload
    enum string path = "/tmp/vibe3d-test-positions.lwo";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    post(baseUrl ~ "/api/reset", "");
    auto m0 = model();
    double[3][] pre;
    foreach (v; m0["vertices"].array) {
        pre ~= [v[0].floating, v[1].floating, v[2].floating];
    }

    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    post(baseUrl ~ "/api/reset?empty=true", "");
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);

    auto m1 = model();
    assert(m1["vertices"].array.length == pre.length,
        "reload changed vertex count");
    foreach (i, v; m1["vertices"].array) {
        foreach (k; 0 .. 3) {
            double drift = fabs(v[k].floating - pre[i][k]);
            assert(drift < 1e-5,
                "v" ~ i.to!string ~ " component " ~ k.to!string ~
                " drifted: pre=" ~ pre[i][k].to!string ~
                " post=" ~ v[k].floating.to!string ~
                " drift=" ~ drift.to!string);
        }
    }
}

unittest { // 5× save / load cycles don't accumulate float drift
    enum string path = "/tmp/vibe3d-test-cycles.lwo";
    scope(exit) if (exists(path)) remove(path);

    post(baseUrl ~ "/api/reset", "");
    auto m0 = model();
    double[3][] pre;
    foreach (v; m0["vertices"].array)
        pre ~= [v[0].floating, v[1].floating, v[2].floating];

    foreach (_; 0 .. 5) {
        runCmd("file.save", `{"path":"` ~ path ~ `"}`);
        post(baseUrl ~ "/api/reset?empty=true", "");
        runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    }

    auto m1 = model();
    foreach (i, v; m1["vertices"].array) {
        foreach (k; 0 .. 3) {
            double drift = fabs(v[k].floating - pre[i][k]);
            assert(drift < 1e-5,
                "v" ~ i.to!string ~ " component " ~ k.to!string ~
                " drifted across 5 cycles: pre=" ~ pre[i][k].to!string ~
                " post=" ~ v[k].floating.to!string);
        }
    }
}

// Manually-crafted LWO with a PTCH chunk: 4 verts forming a single quad
// at z=0, marked as a subdivision polygon. Validates the LOAD path's
// isSubpatch handling (the engine's exporter writes FACE only, so this
// is the only way to exercise PTCH parsing).
unittest { // PTCH chunk on load → isSubpatch flag set
    enum string path = "/tmp/vibe3d-test-ptch.lwo";
    scope(exit) if (exists(path)) remove(path);

    ubyte[] body;

    // ---- PNTS chunk: 4 verts × 3 float BE.
    ubyte[] pnts;
    void writeF32BE(ref ubyte[] o, float v) {
        union U { float f; uint u; }
        U u; u.f = v;
        ubyte[4] be = nativeToBigEndian(u.u);
        o ~= be[];
    }
    void writeU16BE(ref ubyte[] o, ushort v) {
        ubyte[2] be = nativeToBigEndian(v);
        o ~= be[];
    }
    void writeU32BE(ref ubyte[] o, uint v) {
        ubyte[4] be = nativeToBigEndian(v);
        o ~= be[];
    }
    void writeTag(ref ubyte[] o, string tag) {
        assert(tag.length == 4);
        foreach (c; tag) o ~= cast(ubyte)c;
    }
    foreach (xyz; [[-1f,-1f,0f], [1f,-1f,0f], [1f,1f,0f], [-1f,1f,0f]])
        foreach (c; xyz) writeF32BE(pnts, c);
    writeTag(body, "PNTS");
    writeU32BE(body, cast(uint)pnts.length);
    body ~= pnts;
    // LWO chunks are word-aligned; PNTS' 48 bytes is already even.

    // ---- POLS chunk: PTCH polytype, one 4-vert face.
    ubyte[] pols;
    writeTag(pols, "PTCH");
    writeU16BE(pols, 4);
    foreach (idx; [0, 1, 2, 3])
        writeU16BE(pols, cast(ushort)idx);
    writeTag(body, "POLS");
    writeU32BE(body, cast(uint)pols.length);
    body ~= pols;

    // ---- FORM wrapper.
    ubyte[] lwo;
    writeTag(lwo, "FORM");
    writeU32BE(lwo, cast(uint)(4 + body.length));    // "LWO2" + body
    writeTag(lwo, "LWO2");
    lwo ~= body;

    write(path, cast(void[])lwo);

    post(baseUrl ~ "/api/reset?empty=true", "");
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    auto m = model();
    assert(m["vertexCount"].integer == 4,
        "PTCH quad should load as 4 verts; got " ~
        m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 1,
        "PTCH quad should load as 1 face; got " ~
        m["faceCount"].integer.to!string);
    // The face must be marked subpatch.
    auto flags = m["isSubpatch"].array;
    assert(flags.length == 1,
        "isSubpatch should have one entry per face");
    assert(flags[0].type == JSONType.true_,
        "PTCH face should land with isSubpatch=true");
}
