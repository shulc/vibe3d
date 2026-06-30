// test_uv_relax.d — tests for the `uv.relax` command.
//
// Pure-D source-backed tests exercise the kernel and command class in-process.
// There is no HTTP surface for creating/seeding UV maps, so the HTTP smoke test
// uses a hand-written .v3d fixture containing a 3×3 quad-grid with a perturbed
// center UV vertex.
//
// Coverage:
//   Source-backed:
//     1. Whole-map relax: center UV vertex converges toward (1,1); 12 border
//        loops byte-unchanged.
//     2. Revert: UV data restored byte-exact after apply().
//     3. Missing UV map: apply() throws (→ HTTP status:error).
//     4. All-seamed map: apply() returns false (all UV vertices pinned → no-op).
//     5. Selected-face scope: v4's UV class spans all 4 faces; selecting only
//        face 2 still pins the class (extends into unselected faces) → no-op.
//   HTTP smoke:
//     6. Load 3×3 grid fixture → uv.relax iter=50, strn=0.5 → center loops
//        ≈ (1,1), border unchanged in .v3d re-read; undo → byte-exact restore.
//     7. No UV map (default cube) → uv.relax → status:error.
//     8. iter=0 (map present) → uv.relax → status:error.

import std.math   : fabs;
import std.file   : write, remove, exists, readText;
import std.format : format;
import std.json   : parseJSON, JSONValue;

import mesh       : Mesh, MeshMap, MapDomain, makeCube, kUvMapName;
import view       : View;
import editmode   : EditMode;
import snapshot   : MeshSnapshot;
import uv_relax   : uvRelax;
import commands.mesh.uv_relax : UvRelax;
import std.net.curl : post, get;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

private enum string kBase = "http://localhost:8080";

private JSONValue runCmd(string id, string paramsJson = "") {
    string body_ = paramsJson.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    auto j = parseJSON(cast(string) post(kBase ~ "/api/command", body_));
    assert(j["status"].str == "ok", id ~ " failed: " ~ j.toString);
    return j;
}

private string runCmdRaw(string body_) {
    return cast(string) post(kBase ~ "/api/command", body_);
}

// ---------------------------------------------------------------------------
// Source-backed helpers
// ---------------------------------------------------------------------------

private enum float eps = 1e-4f;
private bool feq(float a, float b) { return fabs(a - b) < eps; }

// Build a 3×3 quad-grid mesh (9 verts, 4 quads) with a UV map seeded from
// vertex XY position (integer coords → exactly representable as float).
// Also perturbs the 4 center-vertex loops to (1.3, 1.3).
// Returns (m, centerLoops=[cL0,cL1,cL2,cL3]).
private Mesh make3x3WithUv(out size_t[4] centerLoops) {
    import math : Vec3;
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0),
        Vec3(0,1,0), Vec3(1,1,0), Vec3(2,1,0),
        Vec3(0,2,0), Vec3(1,2,0), Vec3(2,2,0),
    ];
    m.addFace([0u,1u,4u,3u]);
    m.addFace([1u,2u,5u,4u]);
    m.addFace([3u,4u,7u,6u]);
    m.addFace([4u,5u,8u,7u]);
    m.buildLoops();

    auto uvMap = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uvMap !is null);
    assert(uvMap.data.length == m.loops.length * 2);
    foreach (L; 0 .. m.loops.length) {
        const uint vi = m.loops[L].vert;
        uvMap.data[L * 2]     = m.vertices[vi].x;
        uvMap.data[L * 2 + 1] = m.vertices[vi].y;
    }

    // v4 appears at corner 2 of face 0, corner 3 of face 1,
    //            corner 1 of face 2, corner 0 of face 3.
    centerLoops[0] = m.faceCornerLoop(0, 2);
    centerLoops[1] = m.faceCornerLoop(1, 3);
    centerLoops[2] = m.faceCornerLoop(2, 1);
    centerLoops[3] = m.faceCornerLoop(3, 0);
    assert(centerLoops[0] != size_t.max && centerLoops[1] != size_t.max
        && centerLoops[2] != size_t.max && centerLoops[3] != size_t.max);

    foreach (cl; centerLoops) {
        uvMap.data[cl * 2]     = 1.3f;
        uvMap.data[cl * 2 + 1] = 1.3f;
    }
    return m;
}

// Set int param `name` on any command.
private void setIntParam(T)(T cmd, string name, int value) {
    import params : Param;
    foreach (ref p; cmd.params())
        if (p.name == name) { *p.iptr = value; return; }
    assert(false, "int param not found: " ~ name);
}

// Set float param `name` on any command.
private void setFloatParam(T)(T cmd, string name, float value) {
    import params : Param;
    foreach (ref p; cmd.params())
        if (p.name == name) { *p.fptr = value; return; }
    assert(false, "float param not found: " ~ name);
}

// ---------------------------------------------------------------------------
// Test 1: Whole-map relax — center UV vertex converges toward (1,1);
//         all 12 border loops are byte-unchanged (pinned → never written).
// ---------------------------------------------------------------------------
unittest {
    import std.algorithm : canFind;

    size_t[4] cl;
    auto m = make3x3WithUv(cl);
    View view = new View(0, 0, 800, 600);
    const float[] savedData = m.meshMap(kUvMapName).data.dup;

    auto cmd = new UvRelax(&m, view, EditMode.Vertices);
    setIntParam  (cmd, "iter", 50);
    setFloatParam(cmd, "strn", 0.5f);
    assert(cmd.apply(), "whole-map relax: apply() must return true");

    auto map = m.meshMap(kUvMapName);
    // Center loops must have converged well toward (1, 1).
    foreach (c; cl) {
        assert(feq(map.data[c * 2],     1.0f),
               format("center u ≈ 1 @ loop %d; got %g", c, map.data[c * 2]));
        assert(feq(map.data[c * 2 + 1], 1.0f),
               format("center v ≈ 1 @ loop %d; got %g", c, map.data[c * 2 + 1]));
    }
    // Border loops must be byte-unchanged.
    foreach (L; 0 .. m.loops.length) {
        if (cl[].canFind(L)) continue;
        assert(map.data[L * 2]     == savedData[L * 2],
               format("border u unchanged @ loop %d", L));
        assert(map.data[L * 2 + 1] == savedData[L * 2 + 1],
               format("border v unchanged @ loop %d", L));
    }
}

// ---------------------------------------------------------------------------
// Test 2: Revert — snap.restore gives byte-exact pre-apply UV data.
// ---------------------------------------------------------------------------
unittest {
    size_t[4] cl;
    auto m = make3x3WithUv(cl);
    View view = new View(0, 0, 800, 600);
    const float[] before = m.meshMap(kUvMapName).data.dup;

    auto cmd = new UvRelax(&m, view, EditMode.Vertices);
    assert(cmd.apply());
    assert(m.meshMap(kUvMapName).data != before, "apply must have changed UVs");

    assert(cmd.revert(), "revert() must return true after a successful apply");
    assert(m.meshMap(kUvMapName).data == before,
           "revert() must restore UV data byte-exact");
}

// ---------------------------------------------------------------------------
// Test 3: Missing UV map — apply() throws, not returns false.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();   // no UV map
    View view = new View(0, 0, 800, 600);
    auto cmd = new UvRelax(&m, view, EditMode.Vertices);
    bool threw = false;
    try { cmd.apply(); }
    catch (Exception) { threw = true; }
    assert(threw, "uv.relax on a mesh without a UV map must throw");
}

// ---------------------------------------------------------------------------
// Test 4: All-seamed UV map — every edge is a UV seam → all UV vertices
//         pinned → apply() returns false (no-op).
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    auto uvMap = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uvMap !is null);
    // Assign each loop a unique U value (V=0).  Every adjacent pair disagrees
    // in UV → every edge is a seam → no interior UV vertex exists.
    foreach (L; 0 .. m.loops.length)
        uvMap.data[L * 2] = cast(float)(L + 1);

    View view = new View(0, 0, 800, 600);
    auto cmd = new UvRelax(&m, view, EditMode.Vertices);
    setIntParam  (cmd, "iter", 5);
    setFloatParam(cmd, "strn", 1.0f);
    assert(!cmd.apply(),
           "all-seamed UV map: apply() must return false (all vertices pinned)");
}

// ---------------------------------------------------------------------------
// Test 5: Selected-face scope — v4's UV class spans all 4 faces; selecting
//         only face 2 pins the class (it extends into unselected faces) → no-op.
// ---------------------------------------------------------------------------
unittest {
    size_t[4] cl;
    auto m = make3x3WithUv(cl);
    View view = new View(0, 0, 800, 600);
    const float[] before = m.meshMap(kUvMapName).data.dup;

    // Select only face 2 (contains v4, but v4's UV class also reaches
    // faces 0, 1, 3 which are unselected → whole class is force-pinned).
    if (m.faceMarks.length < m.faces.length)
        m.faceMarks.length = m.faces.length;
    foreach (ref b; m.faceMarks) b &= ~Mesh.Marks.Select;
    m.faceMarks[2] |= Mesh.Marks.Select;

    auto cmd = new UvRelax(&m, view, EditMode.Vertices);
    assert(!cmd.apply(),
           "selected-face scope: apply() must return false when v4 class is "
           ~ "pinned by cross-face weld into unselected faces");
    assert(m.meshMap(kUvMapName).data == before,
           "selected-face scope: UV data must be byte-unchanged");
}

// ---------------------------------------------------------------------------
// HTTP Test 6: Load 3×3 grid fixture → uv.relax iter=50 strn=0.5 →
//             center loops ≈ (1,1); border loops unchanged in .v3d re-read.
//             Undo → all values restored byte-exact.
//
// UV data (32 floats, CSR loop order):
//   Face 0 [0,1,4,3]: (0,0),(1,0),(1.3,1.3),(0,1)
//   Face 1 [1,2,5,4]: (1,0),(2,0),(2,1),(1.3,1.3)
//   Face 2 [3,4,7,6]: (0,1),(1.3,1.3),(1,2),(0,2)
//   Face 3 [4,5,8,7]: (1.3,1.3),(2,1),(2,2),(1,2)
//
// Center loops: data offsets 4-5 (loop 2), 14-15 (loop 7),
//                             18-19 (loop 9), 24-25 (loop 12).
// "localhost:8080" is rewritten per-worker by run_test.d — keep literal.
// ---------------------------------------------------------------------------
unittest {
    enum string tmpLoad = "/tmp/vibe3d-test-uvrelax-input.v3d";
    enum string tmpSave = "/tmp/vibe3d-test-uvrelax-result.v3d";
    if (exists(tmpLoad)) remove(tmpLoad);
    if (exists(tmpSave)) remove(tmpSave);
    scope(exit) {
        if (exists(tmpLoad)) remove(tmpLoad);
        if (exists(tmpSave)) remove(tmpSave);
    }

    // Hand-written v3d fixture — 3×3 quad grid with center UV perturbed.
    // The 32 UV floats are listed in face-major / corner-major (CSR) order.
    enum string v3d = `{
  "formatVersion": 7,
  "layers": [{
    "name": "UV Relax Test",
    "visible": true,
    "selected": true,
    "mesh": {
      "vertices": [
        [0,0,0],[1,0,0],[2,0,0],
        [0,1,0],[1,1,0],[2,1,0],
        [0,2,0],[1,2,0],[2,2,0]
      ],
      "faces": [[0,1,4,3],[1,2,5,4],[3,4,7,6],[4,5,8,7]],
      "uvMaps": [{"name":"uv","dim":2,"data":[
        0,0, 1,0, 1.3,1.3, 0,1,
        1,0, 2,0, 2,1, 1.3,1.3,
        0,1, 1.3,1.3, 1,2, 0,2,
        1.3,1.3, 2,1, 2,2, 1,2
      ]}]
    }
  }]
}`;
    write(tmpLoad, v3d);

    post(kBase ~ "/api/reset", "");
    runCmd("file.load", `{"path":"` ~ tmpLoad ~ `"}`);

    // Apply relax with enough passes to converge the center well within eps.
    runCmd("uv.relax", `{"iter":50,"strn":0.5}`);

    runCmd("file.save", `{"path":"` ~ tmpSave ~ `"}`);
    assert(exists(tmpSave), "expected saved file at " ~ tmpSave);

    auto j = parseJSON(readText(tmpSave));
    assert(j["formatVersion"].integer == 7);
    auto meshJ = j["layers"][0]["mesh"];
    assert("uvMaps" in meshJ, "uvMaps must be present after uv.relax");
    auto uvData = meshJ["uvMaps"][0]["data"].array;
    assert(uvData.length == 32,
           format("expected 32 UV floats for 16-loop mesh, got %d", uvData.length));

    // Original (unperturbed) UV values for all 16 loops.
    // Center loops (2,7,9,12) hold the perturbed value (1.3,1.3).
    // All literals written as float to avoid int[] vs float[] type conflict.
    float[2][16] orig = [
        [0.0f,0.0f], [1.0f,0.0f], [1.3f,1.3f], [0.0f,1.0f],   // face 0 (loop 2 = center)
        [1.0f,0.0f], [2.0f,0.0f], [2.0f,1.0f], [1.3f,1.3f],   // face 1 (loop 7 = center)
        [0.0f,1.0f], [1.3f,1.3f], [1.0f,2.0f], [0.0f,2.0f],   // face 2 (loop 9 = center)
        [1.3f,1.3f], [2.0f,1.0f], [2.0f,2.0f], [1.0f,2.0f],   // face 3 (loop 12 = center)
    ];
    const size_t[] centerIdx = [2, 7, 9, 12];

    import std.algorithm : canFind;
    foreach (L; 0 .. 16) {
        float gotU = cast(float) uvData[L * 2].floating;
        float gotV = cast(float) uvData[L * 2 + 1].floating;
        if (centerIdx.canFind(L)) {
            // Center: must have moved toward (1, 1).
            assert(feq(gotU, 1.0f),
                   format("center loop %d u ≈ 1; got %g", L, gotU));
            assert(feq(gotV, 1.0f),
                   format("center loop %d v ≈ 1; got %g", L, gotV));
        } else {
            // Border: must be unchanged.
            assert(feq(gotU, orig[L][0]),
                   format("border loop %d u unchanged; expected %g got %g",
                          L, orig[L][0], gotU));
            assert(feq(gotV, orig[L][1]),
                   format("border loop %d v unchanged; expected %g got %g",
                          L, orig[L][1], gotV));
        }
    }

    // Undo and verify byte-exact restoration.
    post(kBase ~ "/api/undo", "");

    if (exists(tmpSave)) remove(tmpSave);
    runCmd("file.save", `{"path":"` ~ tmpSave ~ `"}`);
    assert(exists(tmpSave));

    auto j2      = parseJSON(readText(tmpSave));
    auto uvData2 = j2["layers"][0]["mesh"]["uvMaps"][0]["data"].array;
    assert(uvData2.length == 32);
    foreach (L; 0 .. 16) {
        float gotU = cast(float) uvData2[L * 2].floating;
        float gotV = cast(float) uvData2[L * 2 + 1].floating;
        assert(feq(gotU, orig[L][0]),
               format("undo: loop %d u restored; expected %g got %g",
                      L, orig[L][0], gotU));
        assert(feq(gotV, orig[L][1]),
               format("undo: loop %d v restored; expected %g got %g",
                      L, orig[L][1], gotV));
    }
}

// ---------------------------------------------------------------------------
// HTTP Test 7: Default cube has no UV map → uv.relax → status:error.
// ---------------------------------------------------------------------------
unittest {
    post(kBase ~ "/api/reset", "");
    auto resp = parseJSON(runCmdRaw(`{"id":"uv.relax"}`));
    assert(resp["status"].str == "error",
           "uv.relax on mesh without UV map must return status:error");
}

// ---------------------------------------------------------------------------
// HTTP Test 8: UV map present but iter=0 → kernel returns false →
//             apply() returns false → HTTP status:error.
// ---------------------------------------------------------------------------
unittest {
    enum string tmpLoad = "/tmp/vibe3d-test-uvrelax-iter0.v3d";
    if (exists(tmpLoad)) remove(tmpLoad);
    scope(exit) if (exists(tmpLoad)) remove(tmpLoad);

    // Minimal single-quad v3d with a UV map.
    enum string v3d = `{
  "formatVersion": 7,
  "layers": [{
    "name": "UV Relax iter0",
    "visible": true,
    "selected": true,
    "mesh": {
      "vertices": [[0,0,0],[1,0,0],[1,1,0],[0,1,0]],
      "faces": [[0,1,2,3]],
      "uvMaps": [{"name":"uv","dim":2,"data":[0,0,1,0,1,1,0,1]}]
    }
  }]
}`;
    write(tmpLoad, v3d);

    post(kBase ~ "/api/reset", "");
    runCmd("file.load", `{"path":"` ~ tmpLoad ~ `"}`);

    auto resp = parseJSON(runCmdRaw(`{"id":"uv.relax","params":{"iter":0}}`));
    assert(resp["status"].str == "error",
           "uv.relax iter=0 must return status:error (no-op convention)");
}
