// test_uv_import.d — Stage 2 of the UV-maps milestone (#5): import stops
// discarding UVs. Pure-D, source-backed (run_test.d's `dmd -unittest -i` path,
// the full dependency graph incl. the static-linked assimp), so it can drive the
// REAL importer end to end in-process — there is no HTTP surface for mesh maps.
//
// What it pins:
//   * scene_ir threading: an ImportedPart carrying a per-corner `uv` stream,
//     flattened via `flattenToMesh`, populates the `"uv"` PolyVertex map 1:1 with
//     face corners (faceCornerLoop addressing); a part with NO uv yields NO map.
//     The skip-aware concatenation drops a degenerate face's UV corners too.
//   * assimp path (GAP 4): a real OBJ with `vt` UVs imports through
//     `importViaAssimp` → `flattenToMesh` with geometry WELDED (vertex count ==
//     the no-UV import) and the `"uv"` map present with the expected per-corner
//     values. Includes a SEAM-SPLIT fixture: the same position carries different
//     UVs on adjacent faces — the weld merges the position but the per-corner UV
//     differs (the whole point of the discontinuous PolyVertex domain).
//
// LWO UV import is DEFERRED to the LWO UV stage (uv_maps_plan §Stage 6); no LWO
// case here (the spike kept assimp-only in scope for Stage 2).

import std.math   : fabs;
import std.file   : write, remove, exists;
import std.format : format;

import mesh : Mesh, MeshMap, MapDomain, kUvMapName;
import io.scene_ir     : ImportedScene, ImportedPart, ImportedSurface, flattenToMesh;
import io.scene_import : importViaAssimp;
import io.assimp_runtime : initAssimp, isAssimpAvailable;

void main() {}

private bool feq(float a, float b, float eps = 1e-4f) {
    return fabs(a - b) < eps;
}

// Read the per-corner UV at (face fi, corner c) from a mesh's "uv" map, or null.
private float[] cornerUv(const ref Mesh m, uint fi, uint c) {
    auto map = m.meshMap(kUvMapName);
    if (map is null) return null;
    const size_t loop = m.faceCornerLoop(fi, c);
    if (loop == size_t.max) return null;
    const size_t b = loop * map.dim;
    if (b + map.dim > map.data.length) return null;
    return map.data[b .. b + map.dim].dup;
}

// ---------------------------------------------------------------------------
// scene_ir threading (pure-D, no assimp): ImportedPart.uv → "uv" map
// ---------------------------------------------------------------------------

unittest {  // a single-quad part with per-corner UV → 4-corner "uv" map, 1:1
    ImportedPart p;
    p.vertices = [Vec3Lit(0,0,0), Vec3Lit(1,0,0), Vec3Lit(1,1,0), Vec3Lit(0,1,0)];
    p.faces    = [[0u, 1u, 2u, 3u]];
    // distinct, invertible per-corner UV: corner c → (c, 10+c)
    p.uv = [0,10, 1,11, 2,12, 3,13];

    ImportedScene s;
    s.parts = [p];
    auto m = flattenToMesh(s);

    auto map = m.meshMap(kUvMapName);
    assert(map !is null, "flattenToMesh should create the \"uv\" map when the part has uv");
    assert(map.domain == MapDomain.PolyVertex, "uv map must be PolyVertex domain");
    assert(map.dim == 2, "uv map must be dim 2");
    assert(map.data.length == m.loops.length * 2,
        format("uv map length %d != loops*2 %d", map.data.length, m.loops.length * 2));

    foreach (uint c; 0 .. 4) {
        auto uv = cornerUv(m, 0, c);
        assert(uv.length == 2 && feq(uv[0], c) && feq(uv[1], 10 + c),
            format("corner %d uv = %s, expected (%d,%d)", c, uv, c, 10 + c));
    }
}

unittest {  // a part with NO uv → NO "uv" map (UV-less import stays UV-less)
    ImportedPart p;
    p.vertices = [Vec3Lit(0,0,0), Vec3Lit(1,0,0), Vec3Lit(1,1,0), Vec3Lit(0,1,0)];
    p.faces    = [[0u, 1u, 2u, 3u]];
    // p.uv left empty

    ImportedScene s;
    s.parts = [p];
    auto m = flattenToMesh(s);
    assert(m.meshMap(kUvMapName) is null,
        "no part uv ⇒ no \"uv\" map should be created");
}

unittest {  // skip-aware: a degenerate (<3) face's UV corners drop with the face
    ImportedPart p;
    p.vertices = [Vec3Lit(0,0,0), Vec3Lit(1,0,0), Vec3Lit(1,1,0), Vec3Lit(0,1,0)];
    // face 0 is a degenerate 2-gon (dropped); face 1 is the real quad.
    p.faces    = [[0u, 1u], [0u, 1u, 2u, 3u]];
    // uv stream parallel to ALL corners: 2 for the dropped face, 4 for the quad.
    p.uv = [99,99, 99,99,                 // dropped face's corners
            0,10, 1,11, 2,12, 3,13];      // the surviving quad's corners

    ImportedScene s;
    s.parts = [p];
    auto m = flattenToMesh(s);

    assert(m.faces.length == 1, "degenerate face should be dropped");
    auto map = m.meshMap(kUvMapName);
    assert(map !is null && map.data.length == m.loops.length * 2);
    // The surviving quad's UV must NOT be shifted by the dropped face's corners.
    foreach (uint c; 0 .. 4) {
        auto uv = cornerUv(m, 0, c);
        assert(uv.length == 2 && feq(uv[0], c) && feq(uv[1], 10 + c),
            format("post-drop corner %d uv = %s, expected (%d,%d) — stream misaligned",
                   c, uv, c, 10 + c));
    }
}

// ---------------------------------------------------------------------------
// assimp path (GAP 4): real OBJ with UV, geometry welded, per-corner UV survives
// ---------------------------------------------------------------------------

// A unit quad in the XY plane authored with per-corner UVs. One position, one
// UV each — no seam. Verifies the basic mTextureCoords → "uv" capture + weld.
enum string quadUvObj =
    "v 0 0 0\n"
    ~ "v 1 0 0\n"
    ~ "v 1 1 0\n"
    ~ "v 0 1 0\n"
    ~ "vt 0 0\n"
    ~ "vt 1 0\n"
    ~ "vt 1 1\n"
    ~ "vt 0 1\n"
    ~ "f 1/1 2/2 3/3 4/4\n";

// SEAM-SPLIT fixture: two quads sharing the edge (1,0,0)-(1,1,0) as POSITIONS,
// but the shared positions carry DIFFERENT UVs on each face. The positional weld
// merges the 6 distinct positions to 6 verts (left quad + right quad share the
// middle edge's 2 positions), while the "uv" map keeps the per-corner difference.
//
// Positions: P1(0,0) P2(1,0) P3(1,1) P4(0,1)   [left quad]
//            P5(2,0) P6(2,1)                    [right quad reuses P2,P3]
// Left  quad:  P1 P2 P3 P4  with UV  (0,0)(0.5,0)(0.5,1)(0,1)
// Right quad:  P2 P5 P6 P3  with UV  (0.5,0)(1,0)(1,1)(0.5,1)   <-- agrees on shared edge
// To make it a true SEAM we give the shared edge DIFFERENT UVs on the two faces:
//   left  uses vt for P2=(0.5,0), P3=(0.5,1)
//   right uses vt for P2=(0.0,0), P3=(0.0,1)   (a discontinuity at the shared edge)
enum string seamObj =
    "v 0 0 0\n"   // 1  P1
    ~ "v 1 0 0\n" // 2  P2 (shared)
    ~ "v 1 1 0\n" // 3  P3 (shared)
    ~ "v 0 1 0\n" // 4  P4
    ~ "v 2 0 0\n" // 5  P5
    ~ "v 2 1 0\n" // 6  P6
    // UVs
    ~ "vt 0.0 0.0\n"  // 1  left P1
    ~ "vt 0.5 0.0\n"  // 2  left P2
    ~ "vt 0.5 1.0\n"  // 3  left P3
    ~ "vt 0.0 1.0\n"  // 4  left P4
    ~ "vt 0.0 0.0\n"  // 5  right P2 (DIFFERENT uv on the shared vertex → seam)
    ~ "vt 1.0 0.0\n"  // 6  right P5
    ~ "vt 1.0 1.0\n"  // 7  right P6
    ~ "vt 0.0 1.0\n"  // 8  right P3 (DIFFERENT uv on the shared vertex → seam)
    ~ "f 1/1 2/2 3/3 4/4\n"   // left  quad
    ~ "f 2/5 5/6 6/7 3/8\n";  // right quad (P2,P3 carry the seam UVs)

// The same two quads with NO UVs — the welded-vertex-count baseline.
enum string seamNoUvObj =
    "v 0 0 0\n"
    ~ "v 1 0 0\n"
    ~ "v 1 1 0\n"
    ~ "v 0 1 0\n"
    ~ "v 2 0 0\n"
    ~ "v 2 1 0\n"
    ~ "f 1 2 3 4\n"
    ~ "f 2 5 6 3\n";

private string tmp(string name) { return "/tmp/vibe3d_uvtest_" ~ name; }

private Mesh importObj(string text, string name) {
    const path = tmp(name);
    write(path, text);
    scope(exit) if (exists(path)) remove(path);
    ImportedScene s;
    const ok = importViaAssimp(path, s);
    assert(ok, "importViaAssimp failed for " ~ name);
    return flattenToMesh(s);
}

unittest {  // single quad with UV → "uv" map present, per-corner round-trip
    initAssimp();
    if (!isAssimpAvailable()) return;   // assimp unavailable: skip (shouldn't happen, static)

    auto m = importObj(quadUvObj, "quad.obj");
    assert(m.vertices.length == 4, format("quad should weld to 4 verts, got %d", m.vertices.length));
    assert(m.faces.length == 1, "quad should be 1 face");

    auto map = m.meshMap(kUvMapName);
    assert(map !is null, "quad-with-UV import must create the \"uv\" map");
    assert(map.domain == MapDomain.PolyVertex && map.dim == 2);
    assert(map.data.length == m.loops.length * 2);

    // Each corner's UV must equal its vertex position's (x,y) — the way we
    // authored the fixture (vt == xy). assimp may reorder corners, so match by
    // the corner's geometry, not by index.
    const face = m.faces[0];
    foreach (uint c; 0 .. cast(uint) face.length) {
        const v = m.vertices[face[c]];
        auto uv = cornerUv(m, 0, c);
        assert(uv.length == 2 && feq(uv[0], v.x) && feq(uv[1], v.y),
            format("corner %d at (%g,%g) uv=%s, expected (%g,%g)",
                   c, v.x, v.y, uv, v.x, v.y));
    }
}

unittest {  // GAP-4 seam: geometry welded to the no-UV count, per-corner UV differs
    initAssimp();
    if (!isAssimpAvailable()) return;

    // Baseline: the no-UV import welds the two quads to 6 distinct positions.
    auto baseline = importObj(seamNoUvObj, "seam_nouv.obj");
    const weldedCount = baseline.vertices.length;
    assert(weldedCount == 6,
        format("no-UV seam fixture should weld to 6 verts, got %d", weldedCount));
    assert(baseline.meshMap(kUvMapName) is null, "no-UV import must have no \"uv\" map");

    // With UV: SAME welded vertex count (geometry stays welded — A4 kept for
    // geometry, reversed only for UV), and a "uv" map carrying the seam.
    auto m = importObj(seamObj, "seam_uv.obj");
    assert(m.vertices.length == weldedCount,
        format("UV import must keep geometry welded: %d verts (expected %d)",
               m.vertices.length, weldedCount));
    assert(m.faces.length == 2, "two quads expected");

    auto map = m.meshMap(kUvMapName);
    assert(map !is null, "seam import must create the \"uv\" map");
    assert(map.data.length == m.loops.length * 2);

    // The shared positions (1,0,0) and (1,1,0) must carry DIFFERENT UVs on the
    // two faces — that is the seam the discontinuous map exists to store. Find,
    // for each of the two shared positions, the corner-UV on each face and assert
    // they differ. (Index/order is assimp-dependent; match by geometry.)
    bool checkedShared = false;
    foreach (sharedPos; [Vec3Lit(1,0,0), Vec3Lit(1,1,0)]) {
        float[][] uvsAtPos;
        foreach (uint fi; 0 .. cast(uint) m.faces.length) {
            const face = m.faces[fi];
            foreach (uint c; 0 .. cast(uint) face.length) {
                const v = m.vertices[face[c]];
                if (feq(v.x, sharedPos.x) && feq(v.y, sharedPos.y) && feq(v.z, sharedPos.z)) {
                    auto uv = cornerUv(m, fi, c);
                    assert(uv.length == 2);
                    uvsAtPos ~= uv;
                }
            }
        }
        assert(uvsAtPos.length == 2,
            format("shared position (%g,%g,%g) should appear on exactly 2 faces, got %d",
                   sharedPos.x, sharedPos.y, sharedPos.z, uvsAtPos.length));
        // The two corner-UVs at this welded position must DIFFER (the seam).
        const differ = !feq(uvsAtPos[0][0], uvsAtPos[1][0])
                    || !feq(uvsAtPos[0][1], uvsAtPos[1][1]);
        assert(differ,
            format("seam lost: position (%g,%g,%g) has identical UV %s on both faces",
                   sharedPos.x, sharedPos.y, sharedPos.z, uvsAtPos[0]));
        checkedShared = true;
    }
    assert(checkedShared, "seam fixture exercised no shared positions");
}

// Local Vec3 literal helper (mesh.Vec3 is math.Vec3).
private auto Vec3Lit(float x, float y, float z) {
    import math : Vec3;
    return Vec3(x, y, z);
}
