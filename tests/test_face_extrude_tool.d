// Tests for PolyExtrudeTool (interactive face extrude, factory id `poly.extrude`).
//
// Covers:
//   1. Headless apply: tool.set on → tool.attr distance → tool.doApply → same
//      topology as the one-shot poly.extrude command (10 faces / 12 verts).
//   2. Undo: one step restores the original cube (6 faces / 8 verts).
//   3. Tool↔command parity: headless tool produces identical face count to
//      the one-shot command path.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok", "/api/command failed: " ~ resp);
}

JSONValue postUndo() { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue getModel() { return parseJSON(get("http://localhost:8080/api/model")); }

void postSelect(string mode, int[] indices) {
    import std.array : join;
    import std.algorithm : map;
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// TEST 1: Headless tool path.
// `tool.set poly.extrude on` + `tool.attr poly.extrude distance 0.5` +
// `tool.doApply` must produce the same topology as the one-shot command.
unittest { // HeadlessTool
    resetCube();
    postSelect("polygons", [0]);   // switch to Polygons mode + select face 0

    // Activate the interactive tool (does NOT extrude yet — distance=0 at activate).
    postCommand("tool.set poly.extrude on");
    // Set the distance parameter.
    postCommand("tool.attr poly.extrude distance 0.5");
    // Apply: runs the kernel once from the clean cage.
    postCommand("tool.doApply");

    auto m = getModel();
    assert(m["faces"].array.length == 10,
        "testHeadlessTool: expected 10 faces after headless apply, got " ~
        m["faces"].array.length.to!string);
    assert(m["vertices"].array.length == 12,
        "testHeadlessTool: expected 12 verts after headless apply, got " ~
        m["vertices"].array.length.to!string);
}

// TEST 2: Undo restores the original mesh after a headless apply.
unittest { // HeadlessToolUndo
    resetCube();
    postSelect("polygons", [0]);

    postCommand("tool.set poly.extrude on");
    postCommand("tool.attr poly.extrude distance 0.5");
    postCommand("tool.doApply");
    assert(getModel()["faces"].array.length == 10, "testHeadlessToolUndo: after apply");

    postUndo();
    auto undone = getModel();
    assert(undone["faces"].array.length == 6,
        "testHeadlessToolUndo: after undo expected 6 faces, got " ~
        undone["faces"].array.length.to!string);
    assert(undone["vertices"].array.length == 8,
        "testHeadlessToolUndo: after undo expected 8 verts, got " ~
        undone["vertices"].array.length.to!string);
}

// TEST 3: Tool↔command parity.
// The headless tool and the one-shot command must produce the same face count.
unittest { // ToolCommandParity
    // One-shot command result.
    resetCube();
    postSelect("polygons", [0]);
    postCommand(`{"id":"poly.extrude","params":{"distance":0.5}}`);
    size_t cmdFaces = getModel()["faces"].array.length;
    size_t cmdVerts = getModel()["vertices"].array.length;

    // Headless tool result.
    resetCube();
    postSelect("polygons", [0]);
    postCommand("tool.set poly.extrude on");
    postCommand("tool.attr poly.extrude distance 0.5");
    postCommand("tool.doApply");
    size_t toolFaces = getModel()["faces"].array.length;
    size_t toolVerts = getModel()["vertices"].array.length;

    assert(cmdFaces == toolFaces,
        "testToolCommandParity: command " ~ cmdFaces.to!string ~
        " faces vs tool " ~ toolFaces.to!string);
    assert(cmdVerts == toolVerts,
        "testToolCommandParity: command " ~ cmdVerts.to!string ~
        " verts vs tool " ~ toolVerts.to!string);
}
