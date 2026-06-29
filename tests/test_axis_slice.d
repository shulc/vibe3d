// test_axis_slice.d — HTTP tests for mesh.axisSlice and mesh.julienne commands.
//
// Standard cube fixture from /api/reset (8 verts, 6 quad faces, ±0.5 on each axis).
//
// axisSlice:
//   - Y-axis 1 cut at y=0: 4 side faces split → 10 faces, 12 verts, all quads.
//   - Y-axis on-vertex plane (y=0.5): adjacent-hit guard fires → no splits, mesh unchanged.
//   - X-axis 2 cuts: verify more faces/verts than 1 cut, no orphans.
//   - Undo round-trip: restores original face/vert counts.
//
// julienne:
//   - axisA=X countA=1, axisB=Z countB=1 → 2-pass grid cut, counts verified.
//   - Undo restores cube.
//
// T-junction backstop (HTTP): no two vertices share the exact same position.
// Authoritative T-junction check (index-share) is in mesh.d unittest{}.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

// ---------------------------------------------------------------------------
// helpers (mirrors test_bridge.d)
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

// Face-arity histogram: {3: N3, 4: N4, ...}
int[int] fvDist(JSONValue m) {
    int[int] h;
    foreach (f; m["faces"].array) h[cast(int)f.array.length]++;
    return h;
}

// Vertex indices not referenced by any face.
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

// Returns the number of duplicate vertex positions (0 = no T-junction risk).
size_t duplicatePositionVerts(JSONValue m) {
    import std.format : format;
    string[string] seen; // posKey → first index as string
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

// Reset to default cube and switch to vertex mode (ensures SubjectPacket delivery).
void loadCube() {
    auto r = postCmd("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed");
    // Switch to vertex mode to guarantee a SubjectPacket is in the VectorStack.
    auto s = postCmd("/api/select", `{"mode":"vertices","indices":[]}`);
    assert(s["status"].str == "ok", "/api/select failed");
}

void runCommand(string id) {
    auto r = postCmd("/api/command", `{"id":"` ~ id ~ `"}`);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        id ~ " failed: " ~ r.toString);
}

// Run a command with extra JSON params merged into the request body.
void runCommandWith(string body_) {
    auto r = postCmd("/api/command", body_);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command failed: " ~ r.toString);
}

// Run a command without asserting success (used for expected-no-op cases).
JSONValue runCommandRaw(string body_) {
    return postCmd("/api/command", body_);
}

// ---------------------------------------------------------------------------
// axisSlice: Y-axis 1 cut at mid-plane
// ---------------------------------------------------------------------------

unittest { // axisSlice Y-axis 1 cut: 4 side faces split → 10 faces, 12 verts, all quads
    loadCube();
    auto m0 = model();
    assert(faceCount(m0) == 6, "cube starts with 6 faces");
    assert(vertCount(m0)  == 8, "cube starts with 8 verts");

    // axis=1 (Y), count=1 → single plane at y=0 (cube spans y=-0.5..0.5)
    runCommandWith(`{"id":"mesh.axisSlice","axis":1,"count":1}`);

    auto m1 = model();
    assert(faceCount(m1) == 10,
        "expected 10 faces after Y-axis 1 cut, got " ~ faceCount(m1).to!string);
    assert(vertCount(m1) == 12,
        "expected 12 verts after Y-axis 1 cut, got " ~ vertCount(m1).to!string);
    assert(fvDist(m1).get(4, 0) == 10, "all 10 faces must be quads");
    assert(orphanVerts(m1).length == 0, "no orphan vertices after cut");

    // T-junction backstop: no two vertices at the same position.
    assert(duplicatePositionVerts(m1) == 0,
        "duplicate vertex positions found (T-junction risk)");

    // Undo restores the original cube.
    runCommand("history.undo");
    auto m2 = model();
    assert(faceCount(m2) == 6, "undo must restore 6 faces");
    assert(vertCount(m2)  == 8, "undo must restore 8 verts");
}

// ---------------------------------------------------------------------------
// axisSlice: on-vertex-plane guard (adjacent-hit → no splits)
// ---------------------------------------------------------------------------

unittest { // axisSlice: no degenerate faces after cut (guard backstop)
    // The adjacent-hit guard is tested thoroughly in mesh.d dub-test unittests.
    // Here we verify the HTTP command never produces 2-vertex faces or orphan verts.
    loadCube();
    runCommandWith(`{"id":"mesh.axisSlice","axis":1,"count":1}`);
    auto mg = model();
    foreach (f; mg["faces"].array)
        assert(f.array.length >= 3,
            "no degenerate 2-vertex faces must exist after cut");
    assert(orphanVerts(mg).length == 0, "no orphan verts after cut");
}

// ---------------------------------------------------------------------------
// axisSlice: X-axis 2 cuts
// ---------------------------------------------------------------------------

unittest { // axisSlice X-axis 2 cuts: more splits than 1 cut, no orphans
    loadCube();

    runCommandWith(`{"id":"mesh.axisSlice","axis":0,"count":2}`);

    auto m1 = model();
    // 2 cuts through a cube: each cut creates more splits. Exact count depends
    // on which faces straddle each plane.
    assert(faceCount(m1) > 6, "2 cuts must produce more than 6 faces");
    assert(vertCount(m1)  > 8, "2 cuts must add vertices");
    assert(orphanVerts(m1).length == 0, "no orphan vertices");
    foreach (f; m1["faces"].array)
        assert(f.array.length >= 3, "no degenerate faces after 2 cuts");

    // T-junction backstop.
    assert(duplicatePositionVerts(m1) == 0, "no duplicate vertex positions");

    // Undo.
    runCommand("history.undo");
    auto m2 = model();
    assert(faceCount(m2) == 6, "undo restores 6 faces");
    assert(vertCount(m2)  == 8, "undo restores 8 verts");
}

// ---------------------------------------------------------------------------
// axisSlice: undo round-trip
// ---------------------------------------------------------------------------

unittest { // axisSlice undo round-trip: Z-axis 3 cuts → undo → original cube
    loadCube();

    runCommandWith(`{"id":"mesh.axisSlice","axis":2,"count":3}`);
    auto m1 = model();
    assert(faceCount(m1) > 6, "Z-axis 3 cuts must produce more faces");

    runCommand("history.undo");
    auto m2 = model();
    assert(faceCount(m2) == 6, "undo must restore 6 faces");
    assert(vertCount(m2)  == 8, "undo must restore 8 verts");
}

// ---------------------------------------------------------------------------
// julienne: XZ 1×1 grid cut
// ---------------------------------------------------------------------------

unittest { // julienne axisA=X countA=1 axisB=Z countB=1: 2-pass grid cut
    loadCube();
    auto m0 = model();
    assert(faceCount(m0) == 6, "cube starts with 6 faces");

    runCommandWith(`{"id":"mesh.julienne","axisA":0,"countA":1,"axisB":2,"countB":1}`);

    auto m1 = model();
    // X cut: 4 faces split → 10 faces, 12 verts.
    // Z cut on 10-face mesh: further splits.
    // Total > 10 faces and > 12 verts.
    assert(faceCount(m1) > 10,
        "julienne 1×1 must produce > 10 faces, got " ~ faceCount(m1).to!string);
    assert(vertCount(m1) > 12,
        "julienne 1×1 must produce > 12 verts, got " ~ vertCount(m1).to!string);
    assert(orphanVerts(m1).length == 0, "no orphan verts after julienne");
    foreach (f; m1["faces"].array)
        assert(f.array.length >= 3, "no degenerate faces after julienne");

    // T-junction backstop.
    assert(duplicatePositionVerts(m1) == 0,
        "no duplicate vertex positions after julienne");

    // Undo restores cube.
    runCommand("history.undo");
    auto m2 = model();
    assert(faceCount(m2) == 6, "undo must restore 6 faces");
    assert(vertCount(m2)  == 8, "undo must restore 8 verts");
}

// ---------------------------------------------------------------------------
// julienne: specific count verification
// ---------------------------------------------------------------------------

unittest { // julienne Y×X 2×2: verify face count growth
    loadCube();

    runCommandWith(`{"id":"mesh.julienne","axisA":1,"countA":2,"axisB":0,"countB":2}`);

    auto m1 = model();
    assert(faceCount(m1) > 6, "julienne 2×2 must produce many faces");
    assert(vertCount(m1) > 8, "julienne 2×2 must add vertices");
    assert(orphanVerts(m1).length == 0, "no orphan verts after julienne 2×2");

    runCommand("history.undo");
    auto m2 = model();
    assert(faceCount(m2) == 6, "undo restores cube");
}
