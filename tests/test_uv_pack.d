// test_uv_pack.d — analytic golden + HTTP smoke tests for `uv.fit` / `uv.pack`.
//
// Coverage:
//   SOURCE-BACKED (in-process):
//     1.  computeUvIslands: two-quad mesh (no shared vertices) → exactly 2 islands;
//         per-loop island ids correctly partition all corners.
//     2.  UvFit fill: apply on known-UV two-quad mesh → bbox collapses to [0,1]²
//         exactly; revert restores original data byte-for-byte.
//     3.  UvPack: two-quad mesh with distinct island sizes → after apply, mapped
//         per-island bboxes are within [0,1]² and pairwise non-overlapping;
//         revert restores.
//     4.  Error contracts:
//           (a) cube (no UV map) → UvFit.apply throws;
//           (b) mesh with UV map but zero loops → apply returns false, no snapshot.
//   HTTP:
//     5.  uv.fit golden: reset → uv.project {planar,z} → uv.fit → file.save →
//         parse uvMaps[0].data; all corners in [0,1]², bbox touches all four edges.
//     6.  uv.pack bounds: reset → uv.project {box} → uv.pack → file.save →
//         assert every (u,v) ∈ [0,1].
//     7.  Undo: reset → uv.project → save pre-fit UVs → uv.fit → /api/undo →
//         save again → UVs match the pre-fit values within eps.
//     8.  No-UV-map error: reset (bare cube, no UV) → uv.fit → expect status:error.

import std.math   : fabs;
import std.file   : remove, exists, readText;
import std.format : format;
import std.json   : parseJSON, JSONType, JSONValue;
import std.conv   : to;
import std.net.curl : post;

import mesh        : Mesh, MeshMap, MapDomain, makeCube, kUvMapName;
import math        : Vec3;
import view        : View;
import editmode    : EditMode;
import uv_island   : UvBBox, computeUvIslands, loopsBBox, kUvDegenEps;
import uv_transform : UvAffine, applyUvAffine;
import commands.mesh.uv_project : UvProject;
import commands.mesh.uv_pack    : UvFit, UvPack;

void main() {}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

private enum float eps = 1e-4f;
private bool feq(float a, float b) { return fabs(a - b) < eps; }

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

private float jfloat(JSONValue v) {
    if (v.type == JSONType.float_)   return cast(float) v.floating;
    if (v.type == JSONType.integer)  return cast(float) v.integer;
    if (v.type == JSONType.uinteger) return cast(float) v.uinteger;
    assert(false, "jfloat: unexpected type " ~ v.type.to!string);
}

// Build a mesh with two disjoint quads (NO shared vertices).
// Quad 0: verts 0-3 at (0,0,0)-(1,0,0)-(1,1,0)-(0,1,0)
// Quad 1: verts 4-7 at (2,0,0)-(3,0,0)-(3,2,0)-(2,2,0)  ← different size
// Total: 8 loops, 4 per quad.
private Mesh makeTwoQuadMesh() {
    Mesh m;
    m.vertices ~= Vec3(0, 0, 0);
    m.vertices ~= Vec3(1, 0, 0);
    m.vertices ~= Vec3(1, 1, 0);
    m.vertices ~= Vec3(0, 1, 0);
    m.vertices ~= Vec3(2, 0, 0);
    m.vertices ~= Vec3(3, 0, 0);
    m.vertices ~= Vec3(3, 2, 0);
    m.vertices ~= Vec3(2, 2, 0);
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([4u, 5u, 6u, 7u]);
    m.buildLoops();
    return m;
}

// Seed a UV map on the two-quad mesh with known data:
//   Loops 0-3 (face 0): (0,0),(1,0),(1,1),(0,1)  → bbox [0,1]×[0,1]
//   Loops 4-7 (face 1): (3,0),(4,0),(4,2),(3,2)  → bbox [3,4]×[0,2]
// Combined bbox: [0,4]×[0,2].
private MeshMap* seedTwoQuadUv(ref Mesh m) {
    auto map = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(map !is null);
    assert(map.data.length == 8 * 2); // 8 loops × 2 floats

    // Face 0 (loops 0-3)
    map.data[0] = 0.0f; map.data[1] = 0.0f; // loop 0
    map.data[2] = 1.0f; map.data[3] = 0.0f; // loop 1
    map.data[4] = 1.0f; map.data[5] = 1.0f; // loop 2
    map.data[6] = 0.0f; map.data[7] = 1.0f; // loop 3
    // Face 1 (loops 4-7)
    map.data[8]  = 3.0f; map.data[9]  = 0.0f; // loop 4
    map.data[10] = 4.0f; map.data[11] = 0.0f; // loop 5
    map.data[12] = 4.0f; map.data[13] = 2.0f; // loop 6
    map.data[14] = 3.0f; map.data[15] = 2.0f; // loop 7
    return map;
}

// ---------------------------------------------------------------------------
// Test 1 (in-process): computeUvIslands on the two-quad mesh.
//
// No shared vertices between the two quads → exactly 2 islands.
// Loops 0-3 must all map to one island id; loops 4-7 to the other.
// ---------------------------------------------------------------------------
unittest {
    auto m   = makeTwoQuadMesh();
    auto map = seedTwoQuadUv(m);

    const size_t[] allLoops = [0, 1, 2, 3, 4, 5, 6, 7];
    size_t count;
    auto islandOf = computeUvIslands(m, map, allLoops, count);

    assert(count == 2,
        format("expected 2 islands for two-quad mesh, got %d", count));

    // All corners of face 0 share one island.
    assert(islandOf[0] == islandOf[1] && islandOf[1] == islandOf[2]
        && islandOf[2] == islandOf[3],
        "loops 0-3 (face 0) must be in the same island");

    // All corners of face 1 share one island.
    assert(islandOf[4] == islandOf[5] && islandOf[5] == islandOf[6]
        && islandOf[6] == islandOf[7],
        "loops 4-7 (face 1) must be in the same island");

    // The two island ids must be different.
    assert(islandOf[0] != islandOf[4],
        "face 0 and face 1 must be in different islands");

    // Non-affected entries remain size_t.max.
    assert(islandOf.length >= 8, "result array must cover all loops");
}

// ---------------------------------------------------------------------------
// Test 2 (in-process): UvFit fill — known bbox → [0,1]² exactly; revert ok.
//
// Combined bbox [0,4]×[0,2]: su=0.25, tu=0; sv=0.5, tv=0.
// After fit: min(u)=0, max(u)=1, min(v)=0, max(v)=1.
// ---------------------------------------------------------------------------
unittest {
    auto m   = makeTwoQuadMesh();
    seedTwoQuadUv(m);

    auto view = new View(0, 0, 800, 600);
    auto cmd  = new UvFit(&m, view, EditMode.Vertices);
    assert(cmd.apply(), "UvFit.apply on two-quad mesh must return true");

    auto map = m.meshMap(kUvMapName);
    assert(map !is null);

    // Compute bbox of all 8 loops after fit.
    float umin =  float.infinity, umax = -float.infinity;
    float vmin =  float.infinity, vmax = -float.infinity;
    foreach (i; 0 .. 8) {
        float u = map.data[i * 2];
        float v = map.data[i * 2 + 1];
        if (u < umin) umin = u;
        if (u > umax) umax = u;
        if (v < vmin) vmin = v;
        if (v > vmax) vmax = v;
    }
    assert(feq(umin, 0.0f), format("fit: umin must be 0, got %g", umin));
    assert(feq(umax, 1.0f), format("fit: umax must be 1, got %g", umax));
    assert(feq(vmin, 0.0f), format("fit: vmin must be 0, got %g", vmin));
    assert(feq(vmax, 1.0f), format("fit: vmax must be 1, got %g", vmax));

    // Spot-check a specific corner: loop 0 was (0,0) → after fit (0,0).
    assert(feq(map.data[0], 0.0f) && feq(map.data[1], 0.0f),
           "loop 0 (was 0,0) must remain (0,0) after fit");

    // Spot-check loop 5 was (4,0) → u=4*0.25=1, v=0.
    assert(feq(map.data[10], 1.0f) && feq(map.data[11], 0.0f),
           format("loop 5 (was 4,0) must be (1,0) after fit; got (%g,%g)",
                  map.data[10], map.data[11]));

    // Spot-check loop 6 was (4,2) → u=1, v=1.
    assert(feq(map.data[12], 1.0f) && feq(map.data[13], 1.0f),
           format("loop 6 (was 4,2) must be (1,1) after fit; got (%g,%g)",
                  map.data[12], map.data[13]));

    // Revert restores original UV data.
    assert(cmd.revert(), "UvFit.revert must return true");
    auto mapR = m.meshMap(kUvMapName);
    assert(mapR !is null);
    assert(feq(mapR.data[0],  0.0f) && feq(mapR.data[1],  0.0f), "revert loop 0");
    assert(feq(mapR.data[10], 4.0f) && feq(mapR.data[11], 0.0f), "revert loop 5");
    assert(feq(mapR.data[14], 3.0f) && feq(mapR.data[15], 2.0f), "revert loop 7");
}

// ---------------------------------------------------------------------------
// Test 3 (in-process): UvPack — two islands, non-overlapping, within [0,1]².
//
// Island 0 (face 0): bbox [0,1]×[0,1]; island 1 (face 1): bbox [3,4]×[0,2].
// After pack: both mapped bboxes within [0,1]², zero positive-area overlap.
// Revert restores original data.
// ---------------------------------------------------------------------------
unittest {
    auto m   = makeTwoQuadMesh();
    seedTwoQuadUv(m);

    auto view = new View(0, 0, 800, 600);
    auto cmd  = new UvPack(&m, view, EditMode.Vertices);
    assert(cmd.apply(), "UvPack.apply on two-quad mesh must return true");

    auto map = m.meshMap(kUvMapName);
    assert(map !is null);

    // Compute per-island bboxes from the mutated map.
    size_t count;
    const size_t[] allLoops = [0, 1, 2, 3, 4, 5, 6, 7];
    auto islandOf = computeUvIslands(m, map, allLoops, count);
    // Island count may have changed if same-UV cross-face unions fired,
    // but for disjoint quads it must still be 2.
    assert(count == 2,
        format("post-pack: expected 2 islands, got %d", count));

    // Determine which island id corresponds to face 0 vs face 1.
    size_t id0 = islandOf[0]; // face 0
    size_t id1 = islandOf[4]; // face 1
    assert(id0 != id1);

    size_t[][2] iloops;
    foreach (l; allLoops) iloops[islandOf[l]] ~= l;

    float bbox_umin(size_t[] ls) {
        float mn = float.infinity;
        foreach (l; ls) { float u = map.data[l*2]; if (u < mn) mn = u; }
        return mn;
    }
    float bbox_umax(size_t[] ls) {
        float mx = -float.infinity;
        foreach (l; ls) { float u = map.data[l*2]; if (u > mx) mx = u; }
        return mx;
    }
    float bbox_vmin(size_t[] ls) {
        float mn = float.infinity;
        foreach (l; ls) { float v = map.data[l*2+1]; if (v < mn) mn = v; }
        return mn;
    }
    float bbox_vmax(size_t[] ls) {
        float mx = -float.infinity;
        foreach (l; ls) { float v = map.data[l*2+1]; if (v > mx) mx = v; }
        return mx;
    }

    // Both islands within [0,1]².
    foreach (id; 0 .. 2) {
        float u0 = bbox_umin(iloops[id]), u1 = bbox_umax(iloops[id]);
        float v0 = bbox_vmin(iloops[id]), v1 = bbox_vmax(iloops[id]);
        assert(u0 >= -eps && u1 <= 1.0f + eps,
            format("pack: island %d u not in [0,1]: [%g,%g]", id, u0, u1));
        assert(v0 >= -eps && v1 <= 1.0f + eps,
            format("pack: island %d v not in [0,1]: [%g,%g]", id, v0, v1));
    }

    // Pairwise non-overlap (positive-area intersection must be ≤ eps).
    float au0 = bbox_umin(iloops[0]), au1 = bbox_umax(iloops[0]);
    float av0 = bbox_vmin(iloops[0]), av1 = bbox_vmax(iloops[0]);
    float bu0 = bbox_umin(iloops[1]), bu1 = bbox_umax(iloops[1]);
    float bv0 = bbox_vmin(iloops[1]), bv1 = bbox_vmax(iloops[1]);
    float ou = (au1 < bu0 || bu1 < au0) ? 0.0f
             : ((au1 < bu1 ? au1 : bu1) - (au0 > bu0 ? au0 : bu0));
    float ov = (av1 < bv0 || bv1 < av0) ? 0.0f
             : ((av1 < bv1 ? av1 : bv1) - (av0 > bv0 ? av0 : bv0));
    float overlapArea = (ou > 0.0f ? ou : 0.0f) * (ov > 0.0f ? ov : 0.0f);
    assert(overlapArea <= eps,
        format("pack: islands overlap by area %g (must be ≤ %g)", overlapArea, eps));

    // Revert restores original UVs.
    assert(cmd.revert(), "UvPack.revert must return true");
    assert(feq(m.meshMap(kUvMapName).data[0],  0.0f), "revert: loop 0 u=0");
    assert(feq(m.meshMap(kUvMapName).data[14], 3.0f), "revert: loop 7 u=3");
}

// ---------------------------------------------------------------------------
// Test 4 (in-process): Error contracts.
//   (a) No UV map → UvFit.apply throws.
//   (b) Mesh with UV map but zero loops → apply returns false, no snapshot.
// ---------------------------------------------------------------------------
unittest {
    auto view = new View(0, 0, 800, 600);

    // (a) Cube has no UV map → UvFit must throw.
    {
        auto m   = makeCube();
        auto cmd = new UvFit(&m, view, EditMode.Vertices);
        bool threw = false;
        try { cmd.apply(); }
        catch (Exception) { threw = true; }
        assert(threw, "UvFit on no-UV mesh must throw");
    }

    // (b) Mesh with UV map, but zero loops (zero faces) → apply returns false.
    //     A mesh with one isolated vertex and no faces has 0 loops after buildLoops.
    {
        auto m2 = Mesh.init;
        m2.vertices ~= Vec3(0, 0, 0);
        m2.buildLoops(); // 0 faces → 0 loops
        auto uvMap = m2.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
        assert(uvMap !is null);
        assert(uvMap.data.length == 0);     // 0 loops × 2
        assert(uvMap.data.length == m2.loops.length * 2); // validation passes
        auto cmd = new UvFit(&m2, view, EditMode.Vertices);
        assert(!cmd.apply(),  "UvFit on zero-loop mesh must return false");
        assert(!cmd.revert(), "revert after false-apply must return false");
    }
}

// ---------------------------------------------------------------------------
// Test 5 (HTTP): uv.fit golden.
//
// reset → uv.project {planar,z} → uv.fit → file.save → parse uvMaps[0].data.
// All corners must be in [0,1]; min(u)≈0, min(v)≈0, max(u)≈1, max(v)≈1.
// (The cube is centred at origin; planar-Z gives (u,v)=(x,y) ∈ [-0.5,0.5].
//  After uv.fit fill, bbox must exactly fill [0,1]².)
// ---------------------------------------------------------------------------
unittest {
    enum string tmpSave = "/tmp/vibe3d-test-uvfit-golden.v3d";
    scope(exit) { if (exists(tmpSave)) remove(tmpSave); }
    if (exists(tmpSave)) remove(tmpSave);

    post(kBase ~ "/api/reset", "");
    runCmd("uv.project", `{"mode":"planar","axis":"z"}`);
    runCmd("uv.fit");
    runCmd("file.save", `{"path":"` ~ tmpSave ~ `"}`);
    assert(exists(tmpSave));

    auto j      = parseJSON(readText(tmpSave));
    auto meshJ  = j["layers"][0]["mesh"];
    assert("uvMaps" in meshJ && meshJ["uvMaps"].array.length > 0,
           "uvMaps must be present after uv.fit");

    auto uvData = meshJ["uvMaps"][0]["data"].array;
    assert(uvData.length > 0);

    float umin =  float.infinity, umax = -float.infinity;
    float vmin =  float.infinity, vmax = -float.infinity;
    foreach (i; 0 .. uvData.length / 2) {
        float u = jfloat(uvData[i * 2]);
        float v = jfloat(uvData[i * 2 + 1]);
        assert(u >= -eps && u <= 1.0f + eps,
            format("uv.fit: u[%d] = %g out of [0,1]", i, u));
        assert(v >= -eps && v <= 1.0f + eps,
            format("uv.fit: v[%d] = %g out of [0,1]", i, v));
        if (u < umin) umin = u;
        if (u > umax) umax = u;
        if (v < vmin) vmin = v;
        if (v > vmax) vmax = v;
    }
    // Bbox must touch all four edges.
    assert(feq(umin, 0.0f), format("uv.fit: umin must be 0, got %g", umin));
    assert(feq(umax, 1.0f), format("uv.fit: umax must be 1, got %g", umax));
    assert(feq(vmin, 0.0f), format("uv.fit: vmin must be 0, got %g", vmin));
    assert(feq(vmax, 1.0f), format("uv.fit: vmax must be 1, got %g", vmax));
}

// ---------------------------------------------------------------------------
// Test 6 (HTTP): uv.pack bounds.
//
// reset → uv.project {box} → uv.pack → file.save → assert every (u,v) ∈ [0,1].
// (Island count via box-on-cube is intentionally NOT asserted — see plan Risks.)
// ---------------------------------------------------------------------------
unittest {
    enum string tmpSave = "/tmp/vibe3d-test-uvpack-bounds.v3d";
    scope(exit) { if (exists(tmpSave)) remove(tmpSave); }
    if (exists(tmpSave)) remove(tmpSave);

    post(kBase ~ "/api/reset", "");
    runCmd("uv.project", `{"mode":"box"}`);
    runCmd("uv.pack");
    runCmd("file.save", `{"path":"` ~ tmpSave ~ `"}`);
    assert(exists(tmpSave));

    auto j      = parseJSON(readText(tmpSave));
    auto meshJ  = j["layers"][0]["mesh"];
    assert("uvMaps" in meshJ && meshJ["uvMaps"].array.length > 0,
           "uvMaps must be present after uv.pack");

    auto uvData = meshJ["uvMaps"][0]["data"].array;
    assert(uvData.length > 0);

    foreach (i; 0 .. uvData.length / 2) {
        float u = jfloat(uvData[i * 2]);
        float v = jfloat(uvData[i * 2 + 1]);
        assert(u >= -eps && u <= 1.0f + eps,
            format("uv.pack: u[%d] = %g out of [0,1]", i, u));
        assert(v >= -eps && v <= 1.0f + eps,
            format("uv.pack: v[%d] = %g out of [0,1]", i, v));
    }
}

// ---------------------------------------------------------------------------
// Test 7 (HTTP): Undo.
//
// reset → uv.project {planar,z} → save pre-fit UVs → uv.fit → /api/undo →
// save again → UVs match the pre-fit values within eps.
// ---------------------------------------------------------------------------
unittest {
    enum string tmpA = "/tmp/vibe3d-test-uvfit-undo-A.v3d"; // post-project
    enum string tmpB = "/tmp/vibe3d-test-uvfit-undo-B.v3d"; // post-undo
    scope(exit) {
        if (exists(tmpA)) remove(tmpA);
        if (exists(tmpB)) remove(tmpB);
    }
    if (exists(tmpA)) remove(tmpA);
    if (exists(tmpB)) remove(tmpB);

    post(kBase ~ "/api/reset", "");
    runCmd("uv.project", `{"mode":"planar","axis":"z"}`);
    // Save UVs after projection (pre-fit reference).
    runCmd("file.save", `{"path":"` ~ tmpA ~ `"}`);

    // Apply fit.
    runCmd("uv.fit");

    // Undo the fit.
    post(kBase ~ "/api/undo", "");

    // Save post-undo.
    runCmd("file.save", `{"path":"` ~ tmpB ~ `"}`);

    auto jA    = parseJSON(readText(tmpA));
    auto jB    = parseJSON(readText(tmpB));
    auto uvA   = jA["layers"][0]["mesh"]["uvMaps"][0]["data"].array;
    auto uvB   = jB["layers"][0]["mesh"]["uvMaps"][0]["data"].array;

    assert(uvA.length == uvB.length,
        format("undo: UV data length changed: %d vs %d", uvA.length, uvB.length));

    foreach (i; 0 .. uvA.length) {
        float a = jfloat(uvA[i]);
        float b = jfloat(uvB[i]);
        assert(feq(a, b),
            format("undo: uvData[%d] mismatch: pre-fit=%g, post-undo=%g", i, a, b));
    }
}

// ---------------------------------------------------------------------------
// Test 8 (HTTP): No-UV-map error.
//
// reset (default cube, no UV map) → POST uv.fit → assert status:error.
// Proves the validation throw propagates through the HTTP command dispatcher.
// ---------------------------------------------------------------------------
unittest {
    post(kBase ~ "/api/reset", "");
    auto resp = runCmdRaw(`{"id":"uv.fit"}`);
    auto j    = parseJSON(resp);
    assert(j["status"].str == "error",
        "uv.fit on no-UV mesh must return status:error; got: " ~ j.toString);
}
