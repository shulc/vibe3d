// test_uv_unwrap.d — tests for the `uv.unwrap` command.
//
// Asymmetric tent fixture: 3×3 quad grid where v4 is shifted to (1.3, 1.0, h)
// rather than the symmetric centre (1,1,h).  With mode=planar (axis=Z) the
// seed places v4's UV at (1.3, 1.0); the cotan-weighted harmonic minimum is
// near the centroid of the neighbours' UVs ~(1,1), so GS provably reduces the
// Dirichlet energy.
//
// Coverage:
//   Source-backed (in-process):
//     1. Asymmetric tent: apply(mode=planar, seams=boundary, iter=30) returns
//        true; Dirichlet energy drops vs iter=0 seed; boundary loops
//        byte-unchanged; revert() byte-exact.
//     2. No-pin guard: closed cube + planar seed → apply() = false.
//     3. Box-fragmentation: mode=box on cube → apply() = false.
//     4. Seed-only (iter=0): map created + seeded; apply() = true.
//     5. Wrong-dim guard: existing map with dim=1 → apply() throws.
//   HTTP smoke:
//     6. Load tent fixture (no uvMaps) → uv.unwrap {planar, boundary, iter=30}
//        → save → energy lower than seed + no NaN + interior in bbox;
//        undo → byte-exact restore.
//     7. Default cube → uv.unwrap → status:error (no-pin guard).
//     8. uv.relax regression: perturbed 3×3 grid still converges after the
//        weld extraction refactor.

import std.math      : fabs, sqrt, acos, isNaN, isInfinity;
import std.file      : write, remove, exists, readText;
import std.format    : format;
import std.json      : parseJSON, JSONValue;
import std.algorithm : canFind;

import mesh          : Mesh, MeshMap, MapDomain, kUvMapName, makeCube;
import math          : Vec3;
import view          : View;
import editmode      : EditMode;
import snapshot      : MeshSnapshot;
import uv_project    : UvProjMode, UvProjAxis, projectUv;
import uv_unwrap     : uvUnwrap, uvDirichletEnergy, uvAngularDistortion;
import commands.mesh.uv_unwrap : UvUnwrap;
import std.net.curl  : post, get;

void main() {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private enum string kBase = "http://localhost:8080";
private enum float  eps   = 1e-4f;

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

private bool feq(float a, float b) { return fabs(a - b) < eps; }

// Build the asymmetric tent: 3×3 quad grid, v4 at (1.3, 1.0, h).
// No UV map — the command will create it.
private Mesh makeTent(float h = 1.5f) {
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0),   Vec3(2,0,0),
        Vec3(0,1,0), Vec3(1.3f,1.0f,h), Vec3(2,1,0),
        Vec3(0,2,0), Vec3(1,2,0),   Vec3(2,2,0),
    ];
    m.addFace([0u,1u,4u,3u]);
    m.addFace([1u,2u,5u,4u]);
    m.addFace([3u,4u,7u,6u]);
    m.addFace([4u,5u,8u,7u]);
    m.buildLoops();
    return m;
}

// Return the loop indices of v4's 4 corners (one per face).
private size_t[4] centerLoops(const ref Mesh m) {
    size_t[4] cl;
    cl[0] = m.faceCornerLoop(0, 2);   // face 0, corner 2 = v4
    cl[1] = m.faceCornerLoop(1, 3);   // face 1, corner 3 = v4
    cl[2] = m.faceCornerLoop(2, 1);   // face 2, corner 1 = v4
    cl[3] = m.faceCornerLoop(3, 0);   // face 3, corner 0 = v4
    return cl;
}

// Compute the "seed-only" UV data for a mesh (planar axis=Z, u=x, v=y).
private float[] seedUV(const ref Mesh m) {
    float[] d = new float[](m.loops.length * 2);
    Vec3 zeroN = Vec3(0,0,1);
    foreach (L; 0 .. m.loops.length) {
        float[2] uv = projectUv(m.vertices[m.loops[L].vert],
                                UvProjMode.Planar, UvProjAxis.Z,
                                Vec3(0,0,0), 1.0f, zeroN);
        d[L * 2]     = uv[0];
        d[L * 2 + 1] = uv[1];
    }
    return d;
}

// Set an int param on a command.
private void setIntParam(T)(T cmd, string pname, int value) {
    import params : Param;
    foreach (ref p; cmd.params())
        if (p.name == pname) { *p.iptr = value; return; }
    assert(false, "int param not found: " ~ pname);
}

// Set a string (enum) param on a command.
private void setEnumParam(T)(T cmd, string pname, string value) {
    import params : Param;
    foreach (ref p; cmd.params())
        if (p.name == pname) { *p.sptr = value; return; }
    assert(false, "enum param not found: " ~ pname);
}

// ---------------------------------------------------------------------------
// Test 1: Source-backed — asymmetric tent, Dirichlet energy drops vs seed,
//         boundary loops byte-unchanged, revert() byte-exact.
// ---------------------------------------------------------------------------
unittest {
    auto m    = makeTent();
    View view = new View(0, 0, 800, 600);

    // Seed UV: planar axis=Z.  v4=(1.3, 1.0, h) → UV (1.3, 1.0).
    // v4's UV class minimum (weighted centroid of boundary neighbours at
    // (1,0),(0,1),(2,1),(1,2)) is near (1,1) — different from (1.3,1.0),
    // so GS has something to do.
    const float[] seedData = seedUV(m);
    const double E0 = uvDirichletEnergy(m, seedData);

    auto cmd = new UvUnwrap(&m, view, EditMode.Vertices);
    setIntParam  (cmd, "iter",  30);
    setEnumParam (cmd, "mode",  "planar");
    setEnumParam (cmd, "seams", "boundary");
    assert(cmd.apply(), "asymmetric tent apply() must return true");

    const double E1 = uvDirichletEnergy(m, m.meshMap(kUvMapName).data);
    assert(E1 < E0,
           format("Dirichlet energy must decrease: E0=%g E1=%g", E0, E1));

    // All UV values finite.
    foreach (L; 0 .. m.loops.length) {
        float u = m.meshMap(kUvMapName).data[L * 2];
        float v = m.meshMap(kUvMapName).data[L * 2 + 1];
        assert(!isNaN(u) && !isInfinity(u), format("NaN/Inf u at loop %d", L));
        assert(!isNaN(v) && !isInfinity(v), format("NaN/Inf v at loop %d", L));
    }

    // Boundary loops byte-unchanged (pinned → never written).
    const auto cl = centerLoops(m);
    foreach (L; 0 .. m.loops.length) {
        if (cl[].canFind(L)) continue;
        assert(m.meshMap(kUvMapName).data[L * 2]     == seedData[L * 2],
               format("boundary u changed at loop %d", L));
        assert(m.meshMap(kUvMapName).data[L * 2 + 1] == seedData[L * 2 + 1],
               format("boundary v changed at loop %d", L));
    }

    // Revert restores byte-exact (no UV map before apply → map removed).
    assert(cmd.revert(), "revert() must return true");
    assert(m.meshMap(kUvMapName) is null,
           "revert() must remove the map created by apply()");
}

// ---------------------------------------------------------------------------
// Test 2: No-pin guard — closed cube + planar seed → apply() = false.
// ---------------------------------------------------------------------------
unittest {
    auto m    = makeCube();
    View view = new View(0, 0, 800, 600);

    auto cmd = new UvUnwrap(&m, view, EditMode.Vertices);
    setIntParam  (cmd, "iter",  30);
    setEnumParam (cmd, "mode",  "planar");
    setEnumParam (cmd, "seams", "boundary");

    const bool ok = cmd.apply();
    assert(!ok, "closed cube + planar seed: no boundary → no pins → false");
    // Mesh had no UV map, and apply() returned false → no map should exist.
    assert(m.meshMap(kUvMapName) is null,
           "no-pin guard: no UV map must remain after false apply");
}

// ---------------------------------------------------------------------------
// Test 3: Box-fragmentation — mode=box on cube → all-pinned → apply() = false.
// ---------------------------------------------------------------------------
unittest {
    auto m    = makeCube();
    View view = new View(0, 0, 800, 600);

    auto cmd = new UvUnwrap(&m, view, EditMode.Vertices);
    setIntParam  (cmd, "iter",  30);
    setEnumParam (cmd, "mode",  "box");
    setEnumParam (cmd, "seams", "boundary");
    assert(!cmd.apply(),
           "box on cube: per-face UV → all seams → all-pinned → false");
    assert(m.meshMap(kUvMapName) is null,
           "box-fragmented: no UV map must remain after false apply");
}

// ---------------------------------------------------------------------------
// Test 4: Seed-only (iter=0) — map created + seeded; apply() = true.
// ---------------------------------------------------------------------------
unittest {
    auto m    = makeCube();
    View view = new View(0, 0, 800, 600);
    assert(m.meshMap(kUvMapName) is null, "cube starts without UV map");

    auto cmd = new UvUnwrap(&m, view, EditMode.Vertices);
    setIntParam  (cmd, "iter",  0);
    setEnumParam (cmd, "mode",  "planar");
    setEnumParam (cmd, "seams", "boundary");
    assert(cmd.apply(), "iter=0 (seed-only): apply() must return true");
    assert(m.meshMap(kUvMapName) !is null, "iter=0: UV map must be created");
    assert(m.meshMap(kUvMapName).data.length == m.loops.length * 2,
           "iter=0: UV data must be correctly sized");

    // Revert removes the map.
    assert(cmd.revert(), "iter=0: revert() must return true");
    assert(m.meshMap(kUvMapName) is null,
           "iter=0: revert() must remove the map");
}

// ---------------------------------------------------------------------------
// Test 5: Wrong-dim guard — existing dim=1 map → apply() throws.
// ---------------------------------------------------------------------------
unittest {
    auto m    = makeCube();
    View view = new View(0, 0, 800, 600);

    auto bad = m.addMeshMap(kUvMapName, 1, MapDomain.PolyVertex);
    assert(bad !is null);

    auto cmd = new UvUnwrap(&m, view, EditMode.Vertices);
    bool threw = false;
    try { cmd.apply(); } catch (Exception) { threw = true; }
    assert(threw, "wrong-dim UV map: apply() must throw");
}

// ---------------------------------------------------------------------------
// HTTP Test 6: Load tent fixture (no uvMaps) → uv.unwrap {planar, boundary,
//   iter=30} → save → energy drops vs seed + no NaN + interior in bbox;
//   undo → byte-exact restore.
// ---------------------------------------------------------------------------
unittest {
    enum string tmpLoad = "/tmp/vibe3d-test-uvunwrap-input.v3d";
    enum string tmpSave = "/tmp/vibe3d-test-uvunwrap-result.v3d";
    if (exists(tmpLoad)) remove(tmpLoad);
    if (exists(tmpSave)) remove(tmpSave);
    scope(exit) {
        if (exists(tmpLoad)) remove(tmpLoad);
        if (exists(tmpSave)) remove(tmpSave);
    }

    // v4 at (1.3, 1.0, 1.5) — asymmetric tent, NO uvMaps in fixture.
    // The command will create the UV map via planar projection (u=x, v=y),
    // placing v4's UV at (1.3, 1.0), then relax toward the harmonic minimum.
    enum string v3d = `{
  "formatVersion": 7,
  "layers": [{
    "name": "UV Unwrap Test",
    "visible": true,
    "selected": true,
    "mesh": {
      "vertices": [
        [0,0,0],[1,0,0],[2,0,0],
        [0,1,0],[1.3,1.0,1.5],[2,1,0],
        [0,2,0],[1,2,0],[2,2,0]
      ],
      "faces": [[0,1,4,3],[1,2,5,4],[3,4,7,6],[4,5,8,7]]
    }
  }]
}`;
    write(tmpLoad, v3d);

    post(kBase ~ "/api/reset", "");
    runCmd("file.load", `{"path":"` ~ tmpLoad ~ `"}`);

    // Apply with explicit params so the test is not sensitive to defaults.
    runCmd("uv.unwrap", `{"mode":"planar","seams":"boundary","iter":30}`);

    runCmd("file.save", `{"path":"` ~ tmpSave ~ `"}`);
    assert(exists(tmpSave), "expected saved file after uv.unwrap");

    auto j      = parseJSON(readText(tmpSave));
    auto mj     = j["layers"][0]["mesh"];
    assert("uvMaps" in mj, "uvMaps must be present after uv.unwrap");
    auto uvArr  = mj["uvMaps"][0]["data"].array;
    assert(uvArr.length == 32,
           format("expected 32 UV floats for 16-loop mesh, got %d", uvArr.length));

    // Loop-to-vertex mapping for the fixture (CSR order, 4 quads × 4 corners):
    //   Face 0 [v0,v1,v4,v3]: loops 0-3  verts 0,1,4,3
    //   Face 1 [v1,v2,v5,v4]: loops 4-7  verts 1,2,5,4
    //   Face 2 [v3,v4,v7,v6]: loops 8-11 verts 3,4,7,6
    //   Face 3 [v4,v5,v8,v7]: loops 12-15 verts 4,5,8,7
    // v4 corners: loops 2,7,9,12
    const size_t[] centerIdx = [2, 7, 9, 12];

    // Seed UV (planar axis=Z, u=x, v=y) for each loop from fixture verts.
    float[2][16] seed;
    float[2][9] verts = [
        [0f,0f],[1f,0f],[2f,0f],[0f,1f],[1.3f,1.0f],[2f,1f],[0f,2f],[1f,2f],[2f,2f]
    ];
    // Re-build from CSR vert order per face.
    const uint[4][4] faceVerts = [[0,1,4,3],[1,2,5,4],[3,4,7,6],[4,5,8,7]];
    foreach (fi; 0 .. 4)
        foreach (c; 0 .. 4) {
            uint vi = faceVerts[fi][c];
            seed[fi*4+c][0] = verts[vi][0];  // u = x
            seed[fi*4+c][1] = verts[vi][1];  // v = y
        }

    // Extract relaxed UV.
    float[2][16] relaxed;
    foreach (L; 0 .. 16) {
        relaxed[L][0] = cast(float) uvArr[L * 2].floating;
        relaxed[L][1] = cast(float) uvArr[L * 2 + 1].floating;
    }

    // No NaN / Inf.
    foreach (L; 0 .. 16)
        foreach (k; 0 .. 2) {
            const float v = relaxed[L][k];
            assert(!isNaN(v) && !isInfinity(v),
                   format("NaN/Inf at loop %d component %d: %g", L, k, v));
        }

    // Boundary loops must be unchanged (seed = planar projection).
    foreach (L; 0 .. 16) {
        if (centerIdx.canFind(L)) continue;
        assert(feq(relaxed[L][0], seed[L][0]),
               format("boundary u changed at loop %d: seed=%g got=%g",
                      L, seed[L][0], relaxed[L][0]));
        assert(feq(relaxed[L][1], seed[L][1]),
               format("boundary v changed at loop %d: seed=%g got=%g",
                      L, seed[L][1], relaxed[L][1]));
    }

    // Interior UVs within boundary bbox [0,2]².
    foreach (L; centerIdx) {
        assert(relaxed[L][0] >= -1e-4f && relaxed[L][0] <= 2.0f + 1e-4f,
               format("interior u out of [0,2]: %g", relaxed[L][0]));
        assert(relaxed[L][1] >= -1e-4f && relaxed[L][1] <= 2.0f + 1e-4f,
               format("interior v out of [0,2]: %g", relaxed[L][1]));
    }

    // Dirichlet energy must drop (compute analytically from fixture geometry).
    {
        import mesh : Mesh;
        Mesh mm;
        mm.vertices = [
            Vec3(0,0,0), Vec3(1,0,0),       Vec3(2,0,0),
            Vec3(0,1,0), Vec3(1.3f,1.0f,1.5f), Vec3(2,1,0),
            Vec3(0,2,0), Vec3(1,2,0),       Vec3(2,2,0),
        ];
        mm.addFace([0u,1u,4u,3u]);
        mm.addFace([1u,2u,5u,4u]);
        mm.addFace([3u,4u,7u,6u]);
        mm.addFace([4u,5u,8u,7u]);
        mm.buildLoops();

        float[] seedFlat    = new float[](32);
        float[] relaxedFlat = new float[](32);
        foreach (L; 0 .. 16) {
            seedFlat[L*2]      = seed[L][0];
            seedFlat[L*2+1]    = seed[L][1];
            relaxedFlat[L*2]   = relaxed[L][0];
            relaxedFlat[L*2+1] = relaxed[L][1];
        }
        const double E0 = uvDirichletEnergy(mm, seedFlat);
        const double E1 = uvDirichletEnergy(mm, relaxedFlat);
        assert(E1 < E0,
               format("HTTP: Dirichlet energy must drop: E0=%g E1=%g", E0, E1));
    }

    // Undo → byte-exact restore of original (no uvMaps).
    post(kBase ~ "/api/undo", "");
    if (exists(tmpSave)) remove(tmpSave);
    runCmd("file.save", `{"path":"` ~ tmpSave ~ `"}`);
    auto j2 = parseJSON(readText(tmpSave));
    // After undo, the UV map created by uv.unwrap should be gone.
    auto mj2 = j2["layers"][0]["mesh"];
    assert("uvMaps" !in mj2 || mj2["uvMaps"].array.length == 0,
           "undo: UV map must be removed (was created by uv.unwrap)");
}

// ---------------------------------------------------------------------------
// HTTP Test 7: Default cube → uv.unwrap → status:error (no-pin guard).
// ---------------------------------------------------------------------------
unittest {
    post(kBase ~ "/api/reset", "");
    auto resp = parseJSON(runCmdRaw(
        `{"id":"uv.unwrap","params":{"mode":"planar","seams":"boundary","iter":30}}`));
    assert(resp["status"].str == "error",
           "cube + planar seed: uv.unwrap must return status:error (no-pin guard)");
}

// ---------------------------------------------------------------------------
// HTTP Test 8: uv.relax regression — weld extraction must not break uv.relax.
// ---------------------------------------------------------------------------
unittest {
    enum string tmpLoad = "/tmp/vibe3d-test-uvunwrap-relax.v3d";
    enum string tmpSave = "/tmp/vibe3d-test-uvunwrap-relax-out.v3d";
    if (exists(tmpLoad)) remove(tmpLoad);
    if (exists(tmpSave)) remove(tmpSave);
    scope(exit) {
        if (exists(tmpLoad)) remove(tmpLoad);
        if (exists(tmpSave)) remove(tmpSave);
    }

    // Same fixture as test_uv_relax.d HTTP test (centre UV perturbed to 1.3).
    enum string v3d = `{
  "formatVersion": 7,
  "layers": [{
    "name": "Relax Regression",
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
    runCmd("uv.relax", `{"iter":50,"strn":0.5}`);
    runCmd("file.save", `{"path":"` ~ tmpSave ~ `"}`);

    auto j     = parseJSON(readText(tmpSave));
    auto uvArr = j["layers"][0]["mesh"]["uvMaps"][0]["data"].array;
    assert(uvArr.length == 32, "relax regression: expected 32 UV floats");

    // Centre loops must have converged to ≈ (1,1).
    const size_t[] centreIdx = [2, 7, 9, 12];
    foreach (L; centreIdx) {
        float gotU = cast(float) uvArr[L * 2].floating;
        float gotV = cast(float) uvArr[L * 2 + 1].floating;
        assert(feq(gotU, 1.0f),
               format("relax regression: centre loop %d u ≈ 1; got %g", L, gotU));
        assert(feq(gotV, 1.0f),
               format("relax regression: centre loop %d v ≈ 1; got %g", L, gotV));
    }
}
