// Tests for the interactive EdgeExtrudeTool (factory id `edge.extrude`),
// Phase 3 of doc/edge_extrude_plan.md.
//
// These exercise the HEADLESS tool path (tool.set / tool.attr / tool.doApply)
// and assert:
//   1. tool↔command parity — same edge selection + same extrude/width via the
//      tool path yields the SAME vertex/face/edge counts AND the same vertex
//      positions as the one-shot mesh.edge_extrude command.
//   2. undo-after-tool-apply restores the original counts (one undo step).
//   3. identity params (extrude=0,width=0) are a no-op.
//
// The tool path commits through ToolDoApplyCommand (snapshot pre →
// applyHeadless → snapshot post), so undo restores the pre-apply state in a
// single step. The kernel itself is covered by tests/test_edge_extrude.d.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;

void main() {}

// --- HTTP helpers (same shapes as tests/test_edge_extrude.d) ---------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
}

void resetGrid(int n) {
    auto resp = post("http://localhost:8080/api/reset?type=grid&n=" ~ n.to!string, "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset grid failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok", "/api/command failed: " ~ resp);
}

void cmd(string s) {
    auto resp = post("http://localhost:8080/api/command", s);
    assert(parseJSON(resp)["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

JSONValue postUndo() { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue getModel() { return parseJSON(get("http://localhost:8080/api/model")); }

// --- geometry helpers ------------------------------------------------------

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

int vertAt(JSONValue m, V3 p) {
    foreach (i; 0 .. m["vertices"].array.length) {
        auto v = vert(m, i);
        auto dx = v.x - p.x, dy = v.y - p.y, dz = v.z - p.z;
        if (sqrt(dx*dx + dy*dy + dz*dz) < 1e-4) return cast(int)i;
    }
    return -1;
}

// True if every vertex of `a` has a coincident vertex in `b` and vice versa.
bool sameVertexSet(JSONValue a, JSONValue b) {
    if (a["vertices"].array.length != b["vertices"].array.length) return false;
    foreach (i; 0 .. a["vertices"].array.length)
        if (vertAt(b, vert(a, i)) < 0) return false;
    return true;
}

// ---------------------------------------------------------------------------
// 1. Tool ↔ command parity (cube interior edge): the tool's headless path must
//    produce the same geometry as the one-shot mesh.edge_extrude command.
// ---------------------------------------------------------------------------

unittest {
    // --- Reference: the one-shot command. ---
    resetCube();
    auto before = getModel();
    int va = vertAt(before, V3(-0.5, 0.5, 0.5));
    int vb = vertAt(before, V3( 0.5, 0.5, 0.5));
    assert(va >= 0 && vb >= 0, "cube top-front endpoints not found");
    int ei = edgeIndex(before, va, vb);
    assert(ei >= 0, "cube top-front edge not found");
    postSelect("edges", [ei]);
    postCommand(`{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);
    auto cmdModel = getModel();

    auto cmdVC = cmdModel["vertexCount"].integer;
    auto cmdFC = cmdModel["faceCount"].integer;
    auto cmdEC = cmdModel["edgeCount"].integer;

    // --- Tool path: same selection + same params via tool.attr + doApply. ---
    resetCube();
    auto before2 = getModel();
    int va2 = vertAt(before2, V3(-0.5, 0.5, 0.5));
    int vb2 = vertAt(before2, V3( 0.5, 0.5, 0.5));
    int ei2 = edgeIndex(before2, va2, vb2);
    postSelect("edges", [ei2]);                 // selects edge + enters Edges mode
    cmd("tool.set edge.extrude on");
    cmd("tool.attr edge.extrude extrude 0.2");
    cmd("tool.attr edge.extrude width 0.1");
    cmd("tool.doApply");
    auto toolModel = getModel();

    assert(toolModel["vertexCount"].integer == cmdVC,
        "parity: tool verts " ~ toolModel["vertexCount"].integer.to!string ~
        " != cmd verts " ~ cmdVC.to!string);
    assert(toolModel["faceCount"].integer == cmdFC,
        "parity: tool faces " ~ toolModel["faceCount"].integer.to!string ~
        " != cmd faces " ~ cmdFC.to!string);
    assert(toolModel["edgeCount"].integer == cmdEC,
        "parity: tool edges " ~ toolModel["edgeCount"].integer.to!string ~
        " != cmd edges " ~ cmdEC.to!string);

    // Same positions (order-independent coincidence in both directions).
    assert(sameVertexSet(cmdModel, toolModel),
        "parity: tool vertex positions differ from the command's");
    assert(sameVertexSet(toolModel, cmdModel),
        "parity: command vertex positions differ from the tool's");
}

// ---------------------------------------------------------------------------
// 2. Tool ↔ command parity on a grid interior edge (different topology than
//    the cube — boundary endpoint dissolve + center inset).
// ---------------------------------------------------------------------------

unittest {
    resetGrid(2);
    auto before = getModel();
    int ei = edgeIndex(before, 3, 4);
    assert(ei >= 0, "interior edge (3,4) not found");
    postSelect("edges", [ei]);
    postCommand(`{"id":"mesh.edge_extrude","params":{"extrude":0.15,"width":0.08}}`);
    auto cmdModel = getModel();

    resetGrid(2);
    auto before2 = getModel();
    int ei2 = edgeIndex(before2, 3, 4);
    postSelect("edges", [ei2]);
    cmd("tool.set edge.extrude on");
    cmd("tool.attr edge.extrude extrude 0.15");
    cmd("tool.attr edge.extrude width 0.08");
    cmd("tool.doApply");
    auto toolModel = getModel();

    assert(toolModel["vertexCount"].integer == cmdModel["vertexCount"].integer,
        "grid parity: vertex counts differ");
    assert(toolModel["faceCount"].integer == cmdModel["faceCount"].integer,
        "grid parity: face counts differ");
    assert(toolModel["edgeCount"].integer == cmdModel["edgeCount"].integer,
        "grid parity: edge counts differ");
    assert(sameVertexSet(cmdModel, toolModel) && sameVertexSet(toolModel, cmdModel),
        "grid parity: vertex positions differ");
}

// ---------------------------------------------------------------------------
// 3. Undo after a tool.doApply restores the original counts (one undo step).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int va = vertAt(before, V3(-0.5, 0.5, 0.5));
    int vb = vertAt(before, V3( 0.5, 0.5, 0.5));
    int ei = edgeIndex(before, va, vb);
    postSelect("edges", [ei]);

    cmd("tool.set edge.extrude on");
    cmd("tool.attr edge.extrude extrude 0.2");
    cmd("tool.attr edge.extrude width 0.1");
    cmd("tool.doApply");
    auto after = getModel();
    assert(after["vertexCount"].integer == 12, "tool apply: expected 12 verts");
    assert(after["faceCount"].integer == 10, "tool apply: expected 10 faces");

    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    auto m = getModel();
    assert(m["vertexCount"].integer == before["vertexCount"].integer,
        "verts not restored on undo: " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == before["faceCount"].integer,
        "faces not restored on undo: " ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == before["edgeCount"].integer,
        "edges not restored on undo: " ~ m["edgeCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// 4. Identity params (extrude=0, width=0) via the tool path = no-op.
// ---------------------------------------------------------------------------

unittest {
    resetGrid(2);
    auto before = getModel();
    int ei = edgeIndex(before, 3, 4);
    postSelect("edges", [ei]);

    cmd("tool.set edge.extrude on");
    cmd("tool.attr edge.extrude extrude 0");
    cmd("tool.attr edge.extrude width 0");
    // doApply on a no-op tool returns false → ToolDoApplyCommand reports the
    // op didn't apply; geometry is unchanged either way.
    auto resp = cast(string)post("http://localhost:8080/api/command", "tool.doApply");
    // status may be "ok" or "error: nothing applied" depending on do_apply's
    // false handling — assert geometry didn't change regardless.
    auto m = getModel();
    assert(m["vertexCount"].integer == before["vertexCount"].integer,
        "no-op changed vertex count: " ~ resp);
    assert(m["faceCount"].integer == before["faceCount"].integer,
        "no-op changed face count: " ~ resp);
    assert(m["edgeCount"].integer == before["edgeCount"].integer,
        "no-op changed edge count: " ~ resp);
}
