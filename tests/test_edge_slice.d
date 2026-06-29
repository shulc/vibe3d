// test_edge_slice.d — HTTP tests for mesh.edgeSlice command.
//
// Standard cube fixture from /api/reset (8 verts, 6 quad faces, ±0.5 each axis).
// Cube faces:
//   0: [0,3,2,1]  front (z=-0.5)
//   1: [4,5,6,7]  back  (z=+0.5)
//   2: [0,4,7,3]  left  (x=-0.5)
//   3: [1,2,6,5]  right (x=+0.5)
//   4: [3,7,6,2]  top   (y=+0.5)
//   5: [0,1,5,4]  bottom(y=-0.5)
//
// edgeSlice:
//   case (a) single shared face: edge(0,1) + edge(4,5) on bottom → 7 faces, 10 verts.
//   case (b) strip through intermediate face: edge(0,1) + edge(6,7) → >6 faces, >8 verts.
//   no-op guards: same edge, wrong arity → mesh unchanged.
//   undo round-trips both cases.
//   T-junction backstop: duplicatePositionVerts==0 after every successful cut.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

// ---------------------------------------------------------------------------
// helpers (mirrors test_axis_slice.d)
// ---------------------------------------------------------------------------

enum BASE = "http://localhost:8080";

JSONValue postCmd(string path, string body_) {
    auto resp = cast(string)post(BASE ~ path, body_);
    return parseJSON(resp);
}

JSONValue model() {
    return parseJSON(cast(string)get(BASE ~ "/api/model"));
}

long vertCount(JSONValue m) {
    return m["vertexCount"].integer;
}

size_t faceCount(JSONValue m) {
    return m["faces"].array.length;
}

int[int] fvDist(JSONValue m) {
    int[int] h;
    foreach (f; m["faces"].array) h[cast(int)f.array.length]++;
    return h;
}

int[] orphanVerts(JSONValue m) {
    bool[] refd;
    refd.length = cast(size_t)m["vertexCount"].integer;
    foreach (f; m["faces"].array)
        foreach (c; f.array) {
            auto vi = cast(size_t)c.integer;
            if (vi < refd.length) refd[vi] = true;
        }
    int[] orph;
    foreach (i; 0 .. refd.length) if (!refd[i]) orph ~= cast(int)i;
    return orph;
}

size_t duplicatePositionVerts(JSONValue m) {
    import std.format : format;
    string[string] seen;
    size_t count;
    if ("vertices" !in m.object) return 0;
    foreach (i, v; m["vertices"].array) {
        auto arr = v.array;
        string key = format("%.9f,%.9f,%.9f",
            arr[0].floating, arr[1].floating, arr[2].floating);
        if (key in seen) {
            count++;
        } else {
            seen[key] = i.to!string;
        }
    }
    return count;
}

// Reset to default cube and switch to edge mode (ensures SubjectPacket delivery).
void loadCube() {
    auto r = postCmd("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed");
    auto s = postCmd("/api/select", `{"mode":"edges","indices":[]}`);
    assert(s["status"].str == "ok", "/api/select (edges) failed");
}

void runCommand(string id) {
    auto r = postCmd("/api/command", `{"id":"` ~ id ~ `"}`);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        id ~ " failed: " ~ r.toString);
}

void runCommandWith(string body_) {
    auto r = postCmd("/api/command", body_);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command failed: " ~ r.toString);
}

JSONValue runCommandRaw(string body_) {
    return postCmd("/api/command", body_);
}

// Look up an edge index by its two endpoint vertex indices.
// Scans m["edges"] for the pair {a,b} in either order.
// Returns uint.max if not found.
uint edgeIndexByVerts(JSONValue m, int a, int b) {
    if ("edges" !in m.object) return uint.max;
    foreach (i, e; m["edges"].array) {
        int ea = cast(int)e.array[0].integer;
        int eb = cast(int)e.array[1].integer;
        if ((ea == a && eb == b) || (ea == b && eb == a))
            return cast(uint)i;
    }
    return uint.max;
}

import std.format : format;

// ---------------------------------------------------------------------------
// case (a): both edges on the same face (cube bottom face [0,1,5,4])
// edge(0,1) at y=-0.5,z=-0.5 row and edge(4,5) at y=-0.5,z=+0.5 row
// ---------------------------------------------------------------------------

unittest { // edgeSlice case (a): single shared face → 7 faces, 10 verts, no orphans
    loadCube();
    auto m0 = model();
    assert(faceCount(m0) == 6, "cube starts with 6 faces");
    assert(vertCount(m0)  == 8, "cube starts with 8 verts");

    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 4, 5);
    assert(eA != uint.max, "edge(0,1) must exist on cube");
    assert(eB != uint.max, "edge(4,5) must exist on cube");

    runCommandWith(format(`{"id":"mesh.edgeSlice","edges":[%d,%d]}`, eA, eB));

    auto m1 = model();
    assert(faceCount(m1) == 7,
        "case (a): expected 7 faces, got " ~ faceCount(m1).to!string);
    assert(vertCount(m1) == 10,
        "case (a): expected 10 verts, got " ~ vertCount(m1).to!string);
    assert(orphanVerts(m1).length == 0, "no orphan vertices after case (a)");
    foreach (f; m1["faces"].array)
        assert(f.array.length >= 3, "no degenerate faces after case (a)");
    assert(duplicatePositionVerts(m1) == 0,
        "no duplicate vertex positions after case (a) (T-junction backstop)");
}

// ---------------------------------------------------------------------------
// case (a): undo round-trip
// ---------------------------------------------------------------------------

unittest { // edgeSlice case (a): undo restores original cube
    loadCube();
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 4, 5);

    runCommandWith(format(`{"id":"mesh.edgeSlice","edges":[%d,%d]}`, eA, eB));
    assert(faceCount(model()) == 7, "7 faces before undo");

    runCommand("history.undo");
    auto m2 = model();
    assert(faceCount(m2) == 6, "undo must restore 6 faces");
    assert(vertCount(m2)  == 8, "undo must restore 8 verts");
}

// ---------------------------------------------------------------------------
// case (b): strip through an intermediate face
// edge(0,1) is on face0 [0,3,2,1]; edge(6,7) is on face1 [4,5,6,7] and face4 [3,7,6,2].
// BFS from face0 (and face5) reaches face4 via face0→face4 through edge(3,2).
// Result: 2 faces split → 8 faces, 11 verts.
// ---------------------------------------------------------------------------

unittest { // edgeSlice case (b): strip through intermediate face → >6 faces, >8 verts
    loadCube();
    auto m0 = model();

    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 6, 7);
    assert(eA != uint.max, "edge(0,1) must exist");
    assert(eB != uint.max, "edge(6,7) must exist");

    runCommandWith(format(`{"id":"mesh.edgeSlice","edges":[%d,%d]}`, eA, eB));

    auto m1 = model();
    assert(faceCount(m1) > 6,
        "case (b): strip cut must increase face count beyond 6, got " ~
        faceCount(m1).to!string);
    assert(vertCount(m1) > 8,
        "case (b): strip cut must add vertices beyond 8, got " ~
        vertCount(m1).to!string);
    assert(orphanVerts(m1).length == 0, "no orphan vertices after case (b)");
    foreach (f; m1["faces"].array)
        assert(f.array.length >= 3, "no degenerate faces after case (b)");
    assert(duplicatePositionVerts(m1) == 0,
        "no duplicate vertex positions after case (b) (T-junction backstop)");
}

// ---------------------------------------------------------------------------
// case (b): undo round-trip
// ---------------------------------------------------------------------------

unittest { // edgeSlice case (b): undo restores original cube
    loadCube();
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);
    uint eB = edgeIndexByVerts(m0, 6, 7);

    runCommandWith(format(`{"id":"mesh.edgeSlice","edges":[%d,%d]}`, eA, eB));
    assert(faceCount(model()) > 6, "cut produced more than 6 faces");

    runCommand("history.undo");
    auto m2 = model();
    assert(faceCount(m2) == 6, "undo must restore 6 faces");
    assert(vertCount(m2)  == 8, "undo must restore 8 verts");
}

// ---------------------------------------------------------------------------
// no-op guards: wrong arity and same edge
// ---------------------------------------------------------------------------

unittest { // edgeSlice guard: wrong arity (1 edge) → mesh unchanged
    loadCube();
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);

    // One edge only — evaluate must return false; mesh must stay intact.
    runCommandRaw(format(`{"id":"mesh.edgeSlice","edges":[%d]}`, eA));

    auto m1 = model();
    assert(faceCount(m1) == 6, "wrong-arity guard: face count must stay 6");
    assert(vertCount(m1)  == 8, "wrong-arity guard: vert count must stay 8");
}

unittest { // edgeSlice guard: same-edge no-op → mesh unchanged, no degenerate faces
    loadCube();
    auto m0 = model();
    uint eA = edgeIndexByVerts(m0, 0, 1);

    runCommandRaw(format(`{"id":"mesh.edgeSlice","edges":[%d,%d]}`, eA, eA));

    auto m1 = model();
    assert(faceCount(m1) == 6, "same-edge guard: face count must stay 6");
    assert(vertCount(m1)  == 8, "same-edge guard: vert count must stay 8");
    foreach (f; m1["faces"].array)
        assert(f.array.length >= 3, "no degenerate faces after same-edge no-op");
}
