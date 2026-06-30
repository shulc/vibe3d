// HTTP tests for the weightMaps v6 codec round-trip.
// Exercises: save emits formatVersion==7, weightMaps block present when maps
// exist, absent when empty, and round-trip preserves values.

import std.net.curl;
import std.json;
import std.file   : remove, exists, write, readText;
import std.conv   : to;
import std.format : format;
import std.math   : fabs;

void main() {}

enum string kBase = "http://localhost:8080";

void resetCube() {
    post(kBase ~ "/api/reset", "");
}

void runCmd(string id, string paramsJson = "") {
    string body = paramsJson.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    auto j = parseJSON(cast(string) post(kBase ~ "/api/command", body));
    assert(j["status"].str == "ok", id ~ " failed: " ~ j.toString);
}

JSONValue model() {
    return parseJSON(cast(string) get(kBase ~ "/api/model"));
}

bool approxEq(double a, double b, double eps = 1e-5) {
    return fabs(a - b) < eps;
}

// --------------------------------------------------------------------------

unittest { // save emits formatVersion 7
    enum string path = "/tmp/vibe3d-test-weightmap-version.v3d";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "expected " ~ path ~ " after save");

    auto j = parseJSON(readText(path));
    assert(j["formatVersion"].integer == 7,
        "writer must emit formatVersion 7, got "
        ~ j["formatVersion"].integer.to!string);
}

unittest { // weightMaps block absent when no weight maps registered
    enum string path = "/tmp/vibe3d-test-weightmap-absent.v3d";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);

    auto j = parseJSON(readText(path));
    auto mesh = j["layers"][0]["mesh"];
    assert(("weightMaps" in mesh) is null,
        "weightMaps must be absent when no weight maps exist");
}

unittest { // weightMaps round-trip: create map, save, reload, verify
    enum string path = "/tmp/vibe3d-test-weightmap-roundtrip.v3d";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    // Create map "weights" and set vertex 0 to 0.75.
    runCmd("mesh.weightmap.create", `{"name":"weights"}`);
    runCmd("mesh.weightmap.set",    `{"name":"weights","vert":0,"weight":0.75}`);
    runCmd("mesh.weightmap.set",    `{"name":"weights","vert":1,"weight":0.5}`);

    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "expected " ~ path ~ " after save");

    // Inspect the saved JSON directly.
    auto j = parseJSON(readText(path));
    assert(j["formatVersion"].integer == 7);
    auto mesh = j["layers"][0]["mesh"];
    assert("weightMaps" in mesh, "weightMaps key must exist after save");
    auto wm = mesh["weightMaps"].array;
    assert(wm.length == 1, "expected 1 weight map");
    assert(wm[0]["name"].str == "weights");
    auto data = wm[0]["data"].array;
    assert(data.length == 8, "expected 8 floats (one per vertex)");
    assert(approxEq(data[0].floating, 0.75),
        format("vert 0 weight should be 0.75, got %g", data[0].floating));
    assert(approxEq(data[1].floating, 0.5),
        format("vert 1 weight should be 0.5, got %g", data[1].floating));
    // Remaining verts should be 0 (zero-filled on create).
    foreach (i; 2 .. data.length)
        assert(approxEq(data[i].floating, 0.0),
            format("vert %d weight should be 0.0, got %g", i, data[i].floating));

    // Load the saved file and verify the weight map survives.
    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    // Use falloff vertexMap + zero-TY to probe: all verts selected,
    // falloff type vertexMap, map="weights", TY=0 → no movement but
    // the stage must accept the map name without error (verifying the
    // map was loaded).
    auto j2 = parseJSON(cast(string) post(kBase ~ "/api/command",
        `tool.pipe.attr falloff type vertexMap`));
    assert(j2["status"].str == "ok", "type=vertexMap failed after reload");
    auto j3 = parseJSON(cast(string) post(kBase ~ "/api/command",
        `tool.pipe.attr falloff map weights`));
    assert(j3["status"].str == "ok", "map=weights failed after reload");
}
