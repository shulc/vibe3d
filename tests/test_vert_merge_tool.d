// Tests for the interactive Vertex Merge tool (factory id `vert.merge`,
// task 0360 — promotes the pre-existing one-shot vert.merge command to a
// no-handle, drag-anywhere-haul interactive tool driven via
// tool.set/tool.attr/tool.doApply). The one-shot command's own `range`/
// `keep`/`morph` params are untouched (tests/test_vert_merge_join.d covers
// those); this file exercises the interactive tool's own boundary law
// (mesh.weldVerticesByMask's `<=` inclusive threshold fix, task 0360) and
// session lifecycle.
//
// Cube layout (makeCube):
//   v0=(-0.5,-0.5,-0.5)  v1=(0.5,-0.5,-0.5)  v2=(0.5,0.5,-0.5)  v3=(-0.5,0.5,-0.5)
//   v4=(-0.5,-0.5, 0.5)  v5=(0.5,-0.5, 0.5)  v6=(0.5,0.5, 0.5)  v7=(-0.5,0.5, 0.5)

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/command failed: " ~ resp ~ "\nbody: " ~ body);
}

// Non-asserting variant for calls EXPECTED to report "did not apply" (e.g.
// tool.doApply below the merge threshold — mesh.weldVerticesByMask's own
// n==0 no-op guard reports failure the same way the one-shot command's
// no-op does, see tests/test_vert_merge_join.d's postCommandRaw).
void postCommandRaw(string body) {
    post("http://localhost:8080/api/command", body);
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

// Move v0 to within `dist` of v1 along X (v1 stays at (0.5,-0.5,-0.5)).
void placeV0AtDistanceFromV1(double dist) {
    double x = 0.5 - dist;
    postCommand(`{"id":"mesh.move_vertex","params":{"from":[-0.5,-0.5,-0.5],"to":[` ~
                 x.to!string ~ `,-0.5,-0.5]}}`);
}

// ---------------------------------------------------------------------------
// A — headless session on already-coincident verts: same result as the
//     one-shot command's range:auto coincident case (8 -> 7 verts). Undo
//     restores 8v/6f exactly.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    postCommand(`{"id":"mesh.move_vertex","params":{"from":[-0.5,-0.5,-0.5],"to":[0.5,-0.5,-0.5]}}`);
    postSelect("vertices", [0, 1]);

    postCommand("tool.set vert.merge on");
    postCommand("tool.doApply");   // default dist_ = 0.001, plenty for exact coincidence
    postCommand("tool.set vert.merge off");

    auto m = getModel();
    assert(m["vertexCount"].integer == 7,
        "A: expected 7 verts after weld, got " ~ m["vertexCount"].integer.to!string);

    auto u = postUndo();
    assert(u["status"].str == "ok", "A: undo failed: " ~ u.toString);
    auto mUndo = getModel();
    assert(mUndo["vertexCount"].integer == before["vertexCount"].integer,
        "A undo: vertex count not restored");
    assert(mUndo["faceCount"].integer == before["faceCount"].integer,
        "A undo: face count not restored");
}

// ---------------------------------------------------------------------------
// B — boundary law via the interactive path (task 0360 captured law: `<=`,
//     not `<`): v0 placed EXACTLY 0.3 from v1. dist=0.29 must NOT merge;
//     dist=0.3 (the exact boundary) MUST merge. Isolated two-vertex pair —
//     does not depend on the still-open whole-mesh transitive-clustering
//     question (see mesh.weldVerticesByMask's doc-comment).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    placeV0AtDistanceFromV1(0.3);
    postSelect("vertices", [0, 1]);

    postCommand("tool.set vert.merge on");
    postCommand("tool.attr vert.merge dist 0.29");
    postCommandRaw("tool.doApply");   // expected no-op, see helper doc-comment
    postCommand("tool.set vert.merge off");

    auto belowBoundary = getModel();
    assert(belowBoundary["vertexCount"].integer == 8,
        "B: dist=0.29 (below the 0.3 boundary) must not merge, got " ~
        belowBoundary["vertexCount"].integer.to!string);
}

unittest {
    resetCube();
    placeV0AtDistanceFromV1(0.3);
    postSelect("vertices", [0, 1]);

    postCommand("tool.set vert.merge on");
    postCommand("tool.attr vert.merge dist 0.3");
    postCommand("tool.doApply");
    postCommand("tool.set vert.merge off");

    auto atBoundary = getModel();
    assert(atBoundary["vertexCount"].integer == 7,
        "B: dist=0.3 (exactly at the boundary, inclusive) must merge, got " ~
        atBoundary["vertexCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// C — selection scoping: only SELECTED vertices are weld candidates, even
//     when an unselected vertex would otherwise be within `dist`.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    placeV0AtDistanceFromV1(0.1);
    // Select only v0 -- v1 is NOT selected, so no weld should occur even
    // though v0 and v1 are well within dist=0.5 of each other.
    postSelect("vertices", [0]);

    postCommand("tool.set vert.merge on");
    postCommand("tool.attr vert.merge dist 0.5");
    postCommandRaw("tool.doApply");   // expected no-op, see helper doc-comment
    postCommand("tool.set vert.merge off");

    auto m = getModel();
    assert(m["vertexCount"].integer == 8,
        "C: unselected v1 must not be pulled into the weld, got " ~
        m["vertexCount"].integer.to!string);
}
