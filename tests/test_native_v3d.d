// Tests for the native .v3d document format round-trip via /api/command.
//
// Flow:
//   reset → mark every face subpatch → save to /tmp/x.v3d → mutate state
//   → load /tmp/x.v3d → /api/model topology + subpatch + surfaces match the
//   original cube exactly.

import std.net.curl;
import std.json;
import std.file : remove, exists, getSize, write;
import std.conv : to;

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
    assert(j["status"].str == "ok",
        id ~ " failed: " ~ resp);
}

string runCmdAllowError(string id, string params = "") {
    string body = params.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    return cast(string)post("http://localhost:8080/api/command", body);
}

JSONValue model() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

unittest { // save → load round-trip preserves geometry, subpatch and surfaces
    enum string path = "/tmp/vibe3d-test-roundtrip.v3d";
    if (exists(path)) remove(path);

    resetCube();

    // Mark every face as subpatch so the round-trip has a non-trivial flag
    // array to preserve. With no face selection mesh.subpatch_toggle inverts
    // the flag on every face (all false → all true on a fresh cube).
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
    runCmd("mesh.subpatch_toggle");

    auto orig = model();
    long origV = orig["vertexCount"].integer;
    long origE = orig["edgeCount"].integer;
    long origF = orig["faceCount"].integer;
    assert(origV == 8 && origE == 12 && origF == 6, "cube prerequisite");

    // Capture the exact arrays we expect to survive the round-trip.
    auto origFaces      = orig["faces"];
    auto origVertices   = orig["vertices"];
    auto origSubpatch   = orig["isSubpatch"];
    auto origSurfaces   = orig["surfaces"];
    // Every face should now be a subpatch.
    foreach (b; origSubpatch.array)
        assert(b.type == JSONType.true_, "expected all faces subpatch after toggle");

    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "expected " ~ path ~ " after save");
    assert(getSize(path) > 0, "saved file is empty");

    // Mutate the scene so a stale state can't masquerade as a successful load.
    runCmd("mesh.subdivide");
    auto mutated = model();
    assert(mutated["vertexCount"].integer == 26,
        "subdivide should leave 26 verts before reload");

    runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    auto reloaded = model();

    // Topology counts.
    assert(reloaded["vertexCount"].integer == origV,
        "reload vertexCount mismatch: expected "
        ~ origV.to!string ~ ", got "
        ~ reloaded["vertexCount"].integer.to!string);
    assert(reloaded["edgeCount"].integer == origE, "reload edgeCount mismatch");
    assert(reloaded["faceCount"].integer == origF, "reload faceCount mismatch");

    // Exact vertex positions (float text is deterministic — same %f formatter
    // on both the saved and reloaded mesh, identical values).
    assert(reloaded["vertices"].array.length == origVertices.array.length,
        "reload vertex array length mismatch");
    foreach (i, v; reloaded["vertices"].array) {
        auto o = origVertices.array[i].array;
        auto r = v.array;
        foreach (k; 0 .. 3)
            assert(r[k].floating == o[k].floating,
                "vertex " ~ i.to!string ~ " component " ~ k.to!string
                ~ " mismatch after round-trip");
    }

    // Exact face vertex-index lists.
    assert(reloaded["faces"].array.length == origFaces.array.length,
        "reload face array length mismatch");
    foreach (i, f; reloaded["faces"].array) {
        auto o = origFaces.array[i].array;
        auto r = f.array;
        assert(r.length == o.length,
            "face " ~ i.to!string ~ " arity mismatch after round-trip");
        foreach (k; 0 .. r.length)
            assert(r[k].integer == o[k].integer,
                "face " ~ i.to!string ~ " index " ~ k.to!string ~ " mismatch");
    }

    // Subpatch flags survive.
    assert(reloaded["isSubpatch"].array.length == origSubpatch.array.length,
        "reload subpatch array length mismatch");
    foreach (i, b; reloaded["isSubpatch"].array)
        assert(b.type == origSubpatch.array[i].type,
            "subpatch flag " ~ i.to!string ~ " mismatch after round-trip");

    // Surfaces survive (count + names; the default cube ships at least one).
    assert(reloaded["surfaces"].array.length == origSurfaces.array.length,
        "reload surface count mismatch");
    foreach (i, s; reloaded["surfaces"].array)
        assert(s["name"].str == origSurfaces.array[i]["name"].str,
            "surface " ~ i.to!string ~ " name mismatch after round-trip");

    if (exists(path)) remove(path);
}

unittest { // file.load on a non-existent .v3d returns error, doesn't crash
    enum string path = "/tmp/vibe3d-test-nonexistent.v3d";
    if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for missing file, got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8, "mesh should be intact after failed load");
}

unittest { // file.load on a malformed-JSON .v3d returns error
    enum string path = "/tmp/vibe3d-test-junk.v3d";
    write(path, "{ this is not valid json ]]]");
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for malformed JSON, got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after junk-file load");
}

unittest { // a wrong/future formatVersion is rejected cleanly
    enum string path = "/tmp/vibe3d-test-badver.v3d";
    write(path,
        `{"formatVersion":999,"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],`
        ~ `"faces":[[0,1,2]]}}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for unsupported formatVersion, got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after bad-version load");
}

unittest { // a face index >= 2^63 (parsed as uinteger by std.json) rejects cleanly
    // Critical durability case: such a literal must NOT throw an uncaught
    // JSONException when the reader pulls the index — it must degrade to a
    // clean error with the prior cube left untouched. Fed through the v3 layer
    // shape so the mesh-codec index check (not the version gate) is exercised.
    enum string path = "/tmp/vibe3d-test-hugeindex.v3d";
    write(path,
        `{"formatVersion":3,"primaryLayer":0,"layers":[{"name":"L","visible":true,`
        ~ `"selected":true,"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],`
        ~ `"faces":[[0,1,99999999999999999999]]}}]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for huge uinteger face index, got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after huge-index load");
}

unittest { // a non-object root is rejected cleanly
    enum string path = "/tmp/vibe3d-test-nonobjroot.v3d";
    write(path, `[1,2,3]`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for non-object root, got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after non-object-root load");
}

unittest { // a non-array "vertices" is rejected cleanly
    enum string path = "/tmp/vibe3d-test-nonarrayverts.v3d";
    write(path,
        `{"formatVersion":3,"primaryLayer":0,"layers":[{"name":"L","visible":true,`
        ~ `"selected":true,"mesh":{"vertices":42,"faces":[[0,1,2]]}}]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for non-array vertices, got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after non-array-vertices load");
}

unittest { // a non-array "faces" is rejected cleanly
    enum string path = "/tmp/vibe3d-test-nonarrayfaces.v3d";
    write(path,
        `{"formatVersion":3,"primaryLayer":0,"layers":[{"name":"L","visible":true,`
        ~ `"selected":true,"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],`
        ~ `"faces":"nope"}}]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for non-array faces, got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after non-array-faces load");
}

unittest { // an in-range-typed but out-of-range vertex index rejects cleanly
    enum string path = "/tmp/vibe3d-test-oob-index.v3d";
    write(path,
        `{"formatVersion":3,"primaryLayer":0,"layers":[{"name":"L","visible":true,`
        ~ `"selected":true,"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],`
        ~ `"faces":[[0,1,7]]}}]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for out-of-range vertex index, got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after out-of-range-index load");
}
