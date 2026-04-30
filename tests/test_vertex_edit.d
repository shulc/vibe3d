// Tests for the mesh.vertex_edit command (Phase C.2 underpinning).
// MoveTool / RotateTool / ScaleTool will use this command to land each
// drag as one undo entry (snapshot at drag start, record at drag end).
//
// These tests exercise the command directly via /api/command to verify
// apply/revert correctness; tool-driven integration is covered separately
// once an event-playback log records a drag session.

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/command failed: " ~ resp);
}

string postCommandRaw(string body) {
    return cast(string)post("http://localhost:8080/api/command", body);
}

JSONValue postUndo() {
    return parseJSON(post("http://localhost:8080/api/undo", ""));
}

JSONValue postRedo() {
    return parseJSON(post("http://localhost:8080/api/redo", ""));
}

JSONValue getModel() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

double[3] vertexAt(int idx) {
    auto m = getModel();
    auto v = m["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

void assertVertex(int idx, double x, double y, double z, string label) {
    auto v = vertexAt(idx);
    assert(approxEqual(v[0], x),
        label ~ ": v" ~ idx.to!string ~ ".x expected " ~ x.to!string
        ~ ", got " ~ v[0].to!string);
    assert(approxEqual(v[1], y),
        label ~ ": v" ~ idx.to!string ~ ".y expected " ~ y.to!string
        ~ ", got " ~ v[1].to!string);
    assert(approxEqual(v[2], z),
        label ~ ": v" ~ idx.to!string ~ ".z expected " ~ z.to!string
        ~ ", got " ~ v[2].to!string);
}

// ---------------------------------------------------------------------------

unittest { // single-vertex edit + undo/redo
    resetCube();
    // v0 starts at (-0.5,-0.5,-0.5). Move it to (1,2,3).
    postCommand(`{"id":"mesh.vertex_edit","params":{`
              ~ `"indices":[0],`
              ~ `"before":[[-0.5,-0.5,-0.5]],`
              ~ `"after":[[1,2,3]]}}`);
    assertVertex(0, 1.0, 2.0, 3.0, "v0 after vertex_edit apply");

    // Undo → back to the cube corner.
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo of vertex_edit failed: " ~ u.toString);
    assertVertex(0, -0.5, -0.5, -0.5, "v0 after undo");

    // Redo → back to the edited position.
    auto r = postRedo();
    assert(r["status"].str == "ok", "redo of vertex_edit failed: " ~ r.toString);
    assertVertex(0, 1.0, 2.0, 3.0, "v0 after redo");
}

unittest { // multi-vertex edit
    resetCube();
    // Move v0, v1, v2 to fresh positions.
    postCommand(`{"id":"mesh.vertex_edit","params":{`
              ~ `"indices":[0,1,2],`
              ~ `"before":[[-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[0.5,0.5,-0.5]],`
              ~ `"after":[[1,1,1],[2,2,2],[3,3,3]]}}`);
    assertVertex(0, 1, 1, 1, "v0 moved");
    assertVertex(1, 2, 2, 2, "v1 moved");
    assertVertex(2, 3, 3, 3, "v2 moved");
    // v3 untouched.
    assertVertex(3, -0.5, 0.5, -0.5, "v3 untouched");

    // Single undo restores all three.
    assert(postUndo()["status"].str == "ok");
    assertVertex(0, -0.5, -0.5, -0.5, "v0 restored");
    assertVertex(1,  0.5, -0.5, -0.5, "v1 restored");
    assertVertex(2,  0.5,  0.5, -0.5, "v2 restored");
}

unittest { // mismatched lengths return error
    resetCube();
    auto resp = postCommandRaw(`{"id":"mesh.vertex_edit","params":{`
                             ~ `"indices":[0,1],`
                             ~ `"before":[[-0.5,-0.5,-0.5]],`
                             ~ `"after":[[1,2,3]]}}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for length mismatch, got: " ~ resp);
}

unittest { // missing indices field returns error
    resetCube();
    auto resp = postCommandRaw(`{"id":"mesh.vertex_edit","params":{`
                             ~ `"before":[[-0.5,-0.5,-0.5]],`
                             ~ `"after":[[1,2,3]]}}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for missing indices, got: " ~ resp);
}
