// Tests for the interactive LoopSliceTool (factory id `mesh.loopSliceTool`),
// task 0228.
//
// These exercise the HEADLESS tool path (tool.set / tool.attr / tool.doApply)
// — hover-seeded interaction has no cursor in the HTTP harness, so
// applyHeadless() seeds from the FIRST SELECTED EDGE, mirroring
// `mesh.loopSlice` (source/commands/mesh/loop_slice.d). The interactive
// hover/drag path (source/tools/loop_slice_tool.d) is exercised separately
// via a live-Xvfb visual check (see doc/tasks/work/0228-*.md Результат).
//
//   T1 — tool ↔ command parity: same seed edge + same count via the tool
//        path yields the SAME V/E/F counts as the one-shot mesh.loopSlice
//        command.
//   T2 — single-loop Position: count=1 + position=0.3 lands the split
//        midpoint at t=0.3 along the seed edge.
//   T3 — undo: one tool.doApply → one undo step restores the original
//        counts.
//   T4 — no-op seed: a seed edge with a non-quad incident face (kernel's
//        T-junction guard) is a no-op — no geometry change, no crash.
//   T5 — Select New Polygons: after a cut, the created faces (and only
//        them) are selected.
//   T6 — Count>1 drag is a deliberate v1 geometric no-op: with count=3,
//        changing `position` (simulating what a drag would do) leaves the
//        evenly-spaced result unchanged.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;

void main() {}

// --- HTTP helpers (same shapes as tests/test_edge_extrude_tool.d) ----------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

void cmd(string s) {
    auto resp = post("http://localhost:8080/api/command", s);
    assert(parseJSON(resp)["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok", "/api/command failed: " ~ resp);
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
JSONValue getSelection() { return parseJSON(get("http://localhost:8080/api/selection")); }

// --- geometry helpers (mirror tests/test_loop_slice.d) ---------------------

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

// True if any vertex in `m` sits within eps of (x,y,z).
bool hasVertNear(JSONValue m, double x, double y, double z, double eps = 1e-4) {
    return vertAt(m, V3(x, y, z)) >= 0;
}

// ---------------------------------------------------------------------------
// T1. Tool ↔ command parity: cube seed edge 0-1 (the fixture used by the
//     insertEdgeLoops mesh.d unittests), count=3 — same V/E/F both ways.
// ---------------------------------------------------------------------------
unittest {
    // Reference: the one-shot command.
    resetCube();
    auto beforeCmd = getModel();
    int va = vertAt(beforeCmd, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(beforeCmd, V3( 0.5, -0.5, -0.5));
    assert(va >= 0 && vb >= 0, "cube verts 0/1 not found");
    int eiCmd = edgeIndex(beforeCmd, va, vb);
    assert(eiCmd >= 0, "cube edge 0-1 not found");
    postSelect("edges", [eiCmd]);
    postCommand(`{"id":"mesh.loopSlice","params":{"count":3}}`);
    auto cmdModel = getModel();

    // Tool path: same edge + same count via tool.set/attr/doApply.
    resetCube();
    auto before2 = getModel();
    int va2 = vertAt(before2, V3(-0.5, -0.5, -0.5));
    int vb2 = vertAt(before2, V3( 0.5, -0.5, -0.5));
    int ei2 = edgeIndex(before2, va2, vb2);
    postSelect("edges", [ei2]);
    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 3");
    cmd("tool.doApply");
    auto toolModel = getModel();

    assert(toolModel["vertexCount"].integer == cmdModel["vertexCount"].integer,
        "parity: vertex counts differ (tool "
        ~ toolModel["vertexCount"].integer.to!string ~ " vs cmd "
        ~ cmdModel["vertexCount"].integer.to!string ~ ")");
    assert(toolModel["faceCount"].integer == cmdModel["faceCount"].integer,
        "parity: face counts differ");
    assert(toolModel["edgeCount"].integer == cmdModel["edgeCount"].integer,
        "parity: edge counts differ");
}

// ---------------------------------------------------------------------------
// T2. Single-loop Position: count=1 + position=0.3 lands the split midpoint
//     at t=0.3 along seed edge 0-1: (-0.5,-0.5,-0.5) → (0.5,-0.5,-0.5), so
//     the new vertex must sit at (-0.2, -0.5, -0.5).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    int va = vertAt(before, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(before, V3( 0.5, -0.5, -0.5));
    int ei = edgeIndex(before, va, vb);
    assert(ei >= 0, "cube edge 0-1 not found");
    postSelect("edges", [ei]);

    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 1");
    cmd("tool.attr mesh.loopSliceTool position 0.3");
    cmd("tool.doApply");

    auto after = getModel();
    assert(after["vertexCount"].integer == 12, "expected 12 verts after one loop");
    assert(after["faceCount"].integer == 10, "expected 10 faces after one loop");
    // The kernel measures `t` from whichever end of the seed edge its
    // ring-walk visits first (an internal, direction-agnostic detail — see
    // LoopSliceTool.seedRail) — so position=0.3 lands the split at EITHER
    // x=-0.2 (30% from vertex 0) or x=+0.2 (30% from vertex 1), never both
    // and never at the x=0.0 default-position (0.5) midpoint.
    bool atNeg = hasVertNear(after, -0.2, -0.5, -0.5);
    bool atPos = hasVertNear(after,  0.2, -0.5, -0.5);
    assert(atNeg != atPos,
        "split midpoint at t=0.3 not found at exactly one of (-0.2|0.2, -0.5, -0.5)");
    assert(!hasVertNear(after, 0.0, -0.5, -0.5),
        "unexpected t=0.5 midpoint present — position param was ignored");
}

// ---------------------------------------------------------------------------
// T3. Undo after a tool.doApply restores the original counts (one step).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    int va = vertAt(before, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(before, V3( 0.5, -0.5, -0.5));
    int ei = edgeIndex(before, va, vb);
    postSelect("edges", [ei]);

    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 1");
    cmd("tool.doApply");
    auto after = getModel();
    assert(after["vertexCount"].integer == 12, "tool apply: expected 12 verts");
    assert(after["faceCount"].integer == 10, "tool apply: expected 10 faces");

    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    auto m = getModel();
    assert(m["vertexCount"].integer == before["vertexCount"].integer,
        "verts not restored on undo");
    assert(m["faceCount"].integer == before["faceCount"].integer,
        "faces not restored on undo");
    assert(m["edgeCount"].integer == before["edgeCount"].integer,
        "edges not restored on undo");
}

// ---------------------------------------------------------------------------
// T4. No-op seed: triangulate one cube face (mesh.triple), then seed on an
//     edge shared between a triangle-half and a still-quad neighbour — the
//     kernel's T-junction guard makes collectEdgeRing (and therefore the
//     tool) a no-op. No crash, no geometry change.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    postSelect("polygons", [0]);   // makeCube() face 0 = [0,3,2,1]
    postCommand(`{"id":"mesh.triple"}`);
    auto before = getModel();

    // Edge (0,1) is now incident to one triangle-half of the old face 0 and
    // the still-quad face [0,1,5,4] — a non-quad-adjacent seed.
    int va = vertAt(before, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(before, V3( 0.5, -0.5, -0.5));
    assert(va >= 0 && vb >= 0, "cube verts 0/1 not found after triple");
    int ei = edgeIndex(before, va, vb);
    assert(ei >= 0, "edge 0-1 not found after triple");
    postSelect("edges", [ei]);

    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 1");
    // doApply may report ok:false (nothing applied, à la the edge-extrude
    // identity-params test) — assert geometry didn't change regardless.
    post("http://localhost:8080/api/command", "tool.doApply");

    auto after = getModel();
    assert(after["vertexCount"].integer == before["vertexCount"].integer,
        "no-op seed changed vertex count");
    assert(after["faceCount"].integer == before["faceCount"].integer,
        "no-op seed changed face count");
    assert(after["edgeCount"].integer == before["edgeCount"].integer,
        "no-op seed changed edge count");
}

// ---------------------------------------------------------------------------
// T5. Select New Polygons: after a count=1 cut on the cube's closed
//     equatorial ring (ringLen=4), exactly 2*ringLen == 8 faces are selected
//     (mirrors the mesh.d insertEdgeLoops(3-arg) unittest's newFaceIndices
//     size) — /api/selection's `selectedFaces` is a list of SELECTED
//     indices (buildJsonArray, app.d), not a parallel bool array.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    int va = vertAt(before, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(before, V3( 0.5, -0.5, -0.5));
    int ei = edgeIndex(before, va, vb);
    postSelect("edges", [ei]);

    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 1");
    cmd("tool.attr mesh.loopSliceTool selectNew true");
    cmd("tool.doApply");

    auto after = getModel();
    assert(after["faceCount"].integer == 10, "expected 10 faces after one loop");

    auto sel = getSelection();
    size_t nSelected = sel["selectedFaces"].array.length;
    assert(nSelected == 8,
        "Select New Polygons: expected 8 selected faces, got "
        ~ nSelected.to!string);
}

// ---------------------------------------------------------------------------
// T6. Count>1 drag is a deliberate v1 geometric no-op: positions() ignores
//     `position` whenever count>1 (the (k+1)/(count+1) law owns every
//     position), so two doApply runs with count=3 but different `position`
//     values must produce byte-identical geometry.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto before = getModel();
    int va = vertAt(before, V3(-0.5, -0.5, -0.5));
    int vb = vertAt(before, V3( 0.5, -0.5, -0.5));
    int eiA = edgeIndex(before, va, vb);
    postSelect("edges", [eiA]);
    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 3");
    cmd("tool.attr mesh.loopSliceTool position 0.1");
    cmd("tool.doApply");
    auto modelA = getModel();

    resetCube();
    auto before2 = getModel();
    int va2 = vertAt(before2, V3(-0.5, -0.5, -0.5));
    int vb2 = vertAt(before2, V3( 0.5, -0.5, -0.5));
    int eiB = edgeIndex(before2, va2, vb2);
    postSelect("edges", [eiB]);
    cmd("tool.set mesh.loopSliceTool on");
    cmd("tool.attr mesh.loopSliceTool count 3");
    cmd("tool.attr mesh.loopSliceTool position 0.9");
    cmd("tool.doApply");
    auto modelB = getModel();

    assert(modelA["vertexCount"].integer == modelB["vertexCount"].integer,
        "count>1: vertex counts differ between position=0.1 and position=0.9");
    assert(modelA["faceCount"].integer == modelB["faceCount"].integer,
        "count>1: face counts differ between position=0.1 and position=0.9");

    // Every vertex in A has a coincident vertex in B (order-independent) —
    // position had no effect on the resulting geometry.
    foreach (i; 0 .. modelA["vertices"].array.length) {
        auto v = vert(modelA, i);
        assert(vertAt(modelB, v) >= 0,
            "count>1: vertex " ~ i.to!string ~ " from position=0.1 run has no match in position=0.9 run");
    }
}
