// test_uv_pipeline.d — Stage 5 of the UV-maps milestone (#5): the combined,
// cross-format end-to-end pass. Pure-D, source-backed (run_test.d's
// `dmd -unittest -i` path pulls the full dependency graph incl. the
// static-linked assimp), so it drives the REAL import / `.v3d` codec / export
// in-process — there is no HTTP surface for mesh maps.
//
// Where the per-stage tests pin ONE leg each (test_uv_import = assimp import,
// test_native_v3d / test_v3d_layers = `.v3d` round-trip, test_uv_export = assimp
// export), THIS test chains EVERY in-scope #5 leg through a single pipeline and
// asserts the per-corner UVs survive the whole journey within tolerance:
//
//     OBJ-with-UV  --importViaAssimp-->  Mesh (welded, "uv" map)     [import leg]
//                  --writeV3d----------> .v3d  (formatVersion 5)     [.v3d save]
//                  --readV3d-----------> Mesh                        [.v3d load]
//                  --exportViaAssimp---> glTF                        [export leg]
//                  --importViaAssimp---> Mesh                        [re-import]
//
// End-to-end invariants asserted at the FINAL mesh:
//   * the "uv" map still exists (PolyVertex, dim 2),
//   * each corner's per-corner UV matches what it had right after the first
//     import (matched by corner geometry — assimp + glTF reorder/triangulate),
//   * the welded vertex count is consistent across the chain (export splits at
//     seams, import welds them back — the count returns to the welded original).
//
// A SEAM case (shared position, different adjacent-face UV) runs the same chain
// so the whole pipeline is exercised under corner-collapse: the discontinuity
// must survive the weld → save → load → split → re-weld journey.
//
// LWO is EXCLUDED here (a Stage 6 follow-up; the LWO writer dependency does not
// emit UV channels yet).

import std.math   : fabs;
import std.file   : write, remove, exists;
import std.format : format;

import mesh : Mesh, MeshMap, MapDomain, kUvMapName;
import io.scene_ir       : ImportedScene, flattenToMesh;
import io.scene_import   : importViaAssimp;
import io.scene_export   : exportViaAssimp;
import io.native         : writeV3d, readV3d, kV3dFormatVersion;
import io.assimp_runtime : initAssimp, isAssimpAvailable;
import math : Vec3;
import std.json : parseJSON;
import std.file : readText;

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

// Collect the per-corner UVs observed at a given position (corner order is
// assimp/glTF-dependent, so the pipeline is verified by geometry, not index).
private float[][] uvsAtPosition(const ref Mesh m, Vec3 pos) {
    float[][] result;
    foreach (uint fi; 0 .. cast(uint) m.faces.length) {
        const face = m.faces[fi];
        foreach (uint c; 0 .. cast(uint) face.length) {
            const v = m.vertices[face[c]];
            if (feq(v.x, pos.x) && feq(v.y, pos.y) && feq(v.z, pos.z))
                if (auto uv = cornerUv(m, fi, c)) if (uv.length == 2) result ~= uv;
        }
    }
    return result;
}

private string tmp(string name) { return "/tmp/vibe3d_uvpipe_" ~ name; }

// Import an OBJ from `text`, welding (the Stage-2 assimp import leg).
private Mesh importObj(string text, string name) {
    const path = tmp(name);
    write(path, text);
    scope(exit) if (exists(path)) remove(path);
    ImportedScene s;
    assert(importViaAssimp(path, s), "importViaAssimp failed for " ~ name);
    return flattenToMesh(s);
}

// .v3d save → load round-trip (the Stage-3 native codec leg). Asserts the saved
// file is the current format, then loads it back through the codec.
private Mesh saveLoadV3d(const ref Mesh m, string name) {
    const path = tmp(name);
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    writeV3d(m, path);
    assert(exists(path), "writeV3d produced no file for " ~ name);

    // Confirm the on-disk file is the current UV-carrying format (the version
    // the codec must emit once a PolyVertex map can exist; v5 added the
    // per-layer item-transform block).
    const j = parseJSON(readText(path));
    assert(j["formatVersion"].integer == kV3dFormatVersion,
        format(".v3d %s: formatVersion %d != %d",
               name, j["formatVersion"].integer, kV3dFormatVersion));
    assert(kV3dFormatVersion == 5, "this milestone's .v3d format version is 5");

    Mesh loaded;
    assert(readV3d(path, loaded), "readV3d failed for " ~ name);
    return loaded;
}

// Export `m` to `formatId`/`ext`, then re-import (welds). The Stage-4 export leg
// chained into the Stage-2 import leg.
private Mesh exportReimport(const ref Mesh m, string formatId, string ext, string name) {
    const path = tmp(name ~ ext);
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    assert(exportViaAssimp(m, path, formatId), "exportViaAssimp failed for " ~ formatId);
    assert(exists(path), "no export output for " ~ formatId);

    ImportedScene s;
    assert(importViaAssimp(path, s), "re-import failed for " ~ formatId);
    return flattenToMesh(s);
}

// ---------------------------------------------------------------------------
// OBJ fixtures driving the chain from an ACTUAL OBJ-with-UV file.
// ---------------------------------------------------------------------------

// A single unit quad authored with per-corner UV == (x,y). One position, one UV
// each — no seam. The simplest end-to-end witness.
enum string quadUvObj =
    "v 0 0 0\n" ~ "v 1 0 0\n" ~ "v 1 1 0\n" ~ "v 0 1 0\n"
    ~ "vt 0 0\n" ~ "vt 1 0\n" ~ "vt 1 1\n" ~ "vt 0 1\n"
    ~ "f 1/1 2/2 3/3 4/4\n";

// SEAM fixture: two quads sharing the edge (1,0,0)-(1,1,0) as POSITIONS, with
// DIFFERENT UVs on each face's copy of those corners (a discontinuity). The
// positional weld merges to 6 verts while the "uv" map keeps the per-corner
// difference — the case that must survive the full save/load/split/re-weld chain.
enum string seamObj =
    "v 0 0 0\n"   // 1  P1
    ~ "v 1 0 0\n" // 2  P2 (shared)
    ~ "v 1 1 0\n" // 3  P3 (shared)
    ~ "v 0 1 0\n" // 4  P4
    ~ "v 2 0 0\n" // 5  P5
    ~ "v 2 1 0\n" // 6  P6
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
    "v 0 0 0\n" ~ "v 1 0 0\n" ~ "v 1 1 0\n"
    ~ "v 0 1 0\n" ~ "v 2 0 0\n" ~ "v 2 1 0\n"
    ~ "f 1 2 3 4\n" ~ "f 2 5 6 3\n";

// ---------------------------------------------------------------------------
// The pipeline, asserted on the corner-UV-per-position fingerprint so it is
// robust to assimp/glTF reordering and to glTF triangulation.
// ---------------------------------------------------------------------------

// Build the set of distinct per-corner UVs seen at each named position, sorted,
// so two meshes with the same geometry+UV compare equal regardless of corner
// order or n-gon-vs-triangle topology.
private float[][] sortedUvsAt(const ref Mesh m, Vec3 pos) {
    auto uvs = uvsAtPosition(m, pos);
    // de-dup within tolerance (triangulation can repeat a corner-UV)
    float[][] distinct;
    foreach (uv; uvs) {
        bool seen = false;
        foreach (d; distinct)
            if (feq(d[0], uv[0]) && feq(d[1], uv[1])) { seen = true; break; }
        if (!seen) distinct ~= uv;
    }
    // stable sort by (u,v) for order-independent comparison
    import std.algorithm.sorting : sort;
    distinct.sort!((a, b) => a[0] != b[0] ? a[0] < b[0] : a[1] < b[1]);
    return distinct;
}

private void assertSameUvFingerprint(const ref Mesh a, const ref Mesh b,
                                     Vec3[] positions, string where) {
    foreach (pos; positions) {
        auto fa = sortedUvsAt(a, pos);
        auto fb = sortedUvsAt(b, pos);
        assert(fa.length == fb.length,
            format("%s: position (%g,%g,%g) has %d distinct corner-UVs vs %d",
                   where, pos.x, pos.y, pos.z, fa.length, fb.length));
        foreach (i; 0 .. fa.length)
            assert(feq(fa[i][0], fb[i][0]) && feq(fa[i][1], fb[i][1]),
                format("%s: position (%g,%g,%g) corner-UV #%d = %s, expected %s",
                       where, pos.x, pos.y, pos.z, i, fb[i], fa[i]));
    }
}

unittest {  // simple quad: OBJ → .v3d(v4) → glTF → re-import, UV preserved
    initAssimp();
    if (!isAssimpAvailable()) return;   // static-linked: should never skip

    // Leg 1: import an actual OBJ-with-UV file.
    auto imported = importObj(quadUvObj, "quad.obj");
    assert(imported.vertices.length == 4, "quad welds to 4 verts");
    assert(imported.meshMap(kUvMapName) !is null, "import leg must yield the uv map");
    const importedCount = imported.vertices.length;

    Vec3[] probe = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];

    // Leg 2+3: save to .v3d (v4) and load it back.
    auto afterV3d = saveLoadV3d(imported, "quad.v3d");
    assert(afterV3d.vertices.length == importedCount, ".v3d round-trip changed vertex count");
    assert(afterV3d.meshMap(kUvMapName) !is null, ".v3d round-trip lost the uv map");
    assertSameUvFingerprint(imported, afterV3d, probe, ".v3d round-trip");

    // Leg 4+5: export glTF and re-import (split-then-weld).
    auto roundtripped = exportReimport(afterV3d, "gltf2", ".gltf", "quad");
    assert(roundtripped.vertices.length == importedCount,
        format("end-to-end vertex count %d != welded original %d",
               roundtripped.vertices.length, importedCount));
    assert(roundtripped.meshMap(kUvMapName) !is null, "end-to-end lost the uv map");

    // The corner-UV fingerprint at every position equals the first import's.
    assertSameUvFingerprint(imported, roundtripped, probe, "end-to-end (quad)");
}

unittest {  // SEAM: the discontinuity survives weld → .v3d → glTF split → re-weld
    initAssimp();
    if (!isAssimpAvailable()) return;

    // The welded-count baseline (no UV): the two quads share 2 positions → 6.
    auto baseline = importObj(seamNoUvObj, "seam_nouv.obj");
    const weldedCount = baseline.vertices.length;
    assert(weldedCount == 6, format("seam baseline should weld to 6, got %d", weldedCount));

    // Leg 1: import the OBJ-with-seam-UV.
    auto imported = importObj(seamObj, "seam.obj");
    assert(imported.vertices.length == weldedCount,
        format("seam import must keep geometry welded: %d (expected %d)",
               imported.vertices.length, weldedCount));
    assert(imported.meshMap(kUvMapName) !is null, "seam import must yield the uv map");

    Vec3[] sharedPositions = [Vec3(1,0,0), Vec3(1,1,0)];

    // Sanity: the imported seam really IS a discontinuity (2 distinct UVs/pos).
    foreach (pos; sharedPositions) {
        auto fp = sortedUvsAt(imported, pos);
        assert(fp.length == 2,
            format("seam import: shared (%g,%g,%g) should carry 2 distinct UVs, got %d",
                   pos.x, pos.y, pos.z, fp.length));
    }

    // Leg 2+3: .v3d save/load (v4) preserves the discontinuity exactly.
    auto afterV3d = saveLoadV3d(imported, "seam.v3d");
    assert(afterV3d.vertices.length == weldedCount, ".v3d seam round-trip changed vertex count");
    assertSameUvFingerprint(imported, afterV3d, sharedPositions, ".v3d round-trip (seam)");

    // Leg 4+5: glTF export splits at the seam, re-import welds back to 6 verts.
    auto roundtripped = exportReimport(afterV3d, "gltf2", ".gltf", "seam");
    assert(roundtripped.vertices.length == weldedCount,
        format("end-to-end seam vertex count %d != welded original %d "
               ~ "(export-split not undone by import-weld)",
               roundtripped.vertices.length, weldedCount));
    assert(roundtripped.meshMap(kUvMapName) !is null, "end-to-end seam lost the uv map");

    // The discontinuity must still be present AND match the original per-position.
    foreach (pos; sharedPositions) {
        auto fp = sortedUvsAt(roundtripped, pos);
        assert(fp.length == 2,
            format("end-to-end seam lost: (%g,%g,%g) collapsed to %d distinct UVs",
                   pos.x, pos.y, pos.z, fp.length));
    }
    assertSameUvFingerprint(imported, roundtripped, sharedPositions, "end-to-end (seam)");
}
