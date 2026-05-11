// Tests for file.save / file.load LWO round-trip via /api/command params.
//
// Flow:
//   reset → save to /tmp/x.lwo → mutate state → reset → load /tmp/x.lwo
//   → /api/model topology matches the original cube.

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

unittest { // save → load round-trip preserves cube topology
    enum string path = "/tmp/vibe3d-test-roundtrip.lwo";
    if (exists(path)) remove(path);

    resetCube();
    auto orig = model();
    long origV = orig["vertexCount"].integer;
    long origE = orig["edgeCount"].integer;
    long origF = orig["faceCount"].integer;
    assert(origV == 8 && origE == 12 && origF == 6, "cube prerequisite");

    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "expected " ~ path ~ " after save");
    assert(getSize(path) > 0, "saved file is empty");

    // Mutate the scene, then reload to confirm the file actually drives geometry.
    // mesh.subdivide requires polygon edit mode — switch via the argstring
    // form (runCmd wraps everything in {"id": ...}, which doesn't accept
    // positional args).
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
    runCmd("mesh.subdivide");
    auto mutated = model();
    assert(mutated["vertexCount"].integer == 26,
        "subdivide should leave 26 verts before reload");

    runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    auto reloaded = model();
    assert(reloaded["vertexCount"].integer == origV,
        "reload vertexCount mismatch: expected "
        ~ origV.to!string ~ ", got "
        ~ reloaded["vertexCount"].integer.to!string);
    assert(reloaded["edgeCount"].integer == origE,
        "reload edgeCount mismatch");
    assert(reloaded["faceCount"].integer == origF,
        "reload faceCount mismatch");

    if (exists(path)) remove(path);
}

unittest { // file.load on a non-existent file returns error, doesn't crash
    enum string path = "/tmp/vibe3d-test-nonexistent.lwo";
    if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load",
        `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for missing file, got: " ~ resp);

    // Mesh state should be unchanged after a failed load.
    auto m = model();
    assert(m["vertexCount"].integer == 8, "mesh should be intact after failed load");
}

unittest { // file.load on a non-LWO file returns error
    enum string path = "/tmp/vibe3d-test-junk.lwo";
    write(path, "this is not a valid LWO file, just garbage bytes 0x12345678");
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load",
        `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for garbage file, got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after junk-file load");
}
