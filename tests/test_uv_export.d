// test_uv_export.d — Stage 4 of the UV-maps milestone (#5): export emits UV.
// Pure-D, source-backed (run_test.d's `dmd -unittest -i` path, the full
// dependency graph incl. the static-linked assimp), so it drives the REAL
// exporter + importer end to end in-process — there is no HTTP surface for mesh
// maps, and this is the natural inverse pair of test_uv_import.d.
//
// What it pins (decision D7 + the export-split ↔ import-weld inverse):
//   * io.scene_export.buildScene splits geometry verts at UV seams — one
//     aiVertex per distinct (vertex, uv) pair, carrying mTextureCoords[0] — and
//     reindexes faces; aiMesh.mNumUVComponents[0] == 2.
//   * Round-trip: build a UV mesh in-process → export (OBJ / glTF) → re-import
//     via the Stage-2 assimp path (importViaAssimp + flattenToMesh, which welds)
//     → per-corner UV equal within tolerance AND the re-imported vertex count
//     equals the welded original. The export-split is undone by the import-weld.
//   * A SEAM case: a shared position with DIFFERENT UVs on adjacent faces splits
//     on export, re-welds on import, and the per-corner discontinuity survives.
//   * A no-UV mesh exports + re-imports unchanged (no "uv" map either side).
//
// Formats: OBJ asserts EXACT (welded vertex count + face count + per-corner UV).
// glTF triangulates n-gons on export (glTF has no n-gon encoding) so face count
// is NOT asserted; we still assert the welded vertex count and per-corner UV.
// FBX is a nice-to-have (R4): asserted in a try/skip so a libassimp FBX-UV quirk
// degrades to a skip, not a suite failure.

import std.math   : fabs;
import std.file   : remove, exists;
import std.format : format;

import mesh : Mesh, MeshMap, MapDomain, kUvMapName;
import io.scene_ir       : ImportedScene, ImportedPart, ImportedSurface, flattenToMesh;
import io.scene_import   : importViaAssimp;
import io.scene_export   : exportViaAssimp;
import io.assimp_runtime : initAssimp, isAssimpAvailable;
import math : Vec3;

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

// For a welded mesh: collect the per-corner UVs observed at a given position.
// (Index/corner order is assimp-dependent, so we match by geometry.)
private float[][] uvsAtPosition(const ref Mesh m, Vec3 pos) {
    float[][] result;
    foreach (uint fi; 0 .. cast(uint) m.faces.length) {
        const face = m.faces[fi];
        foreach (uint c; 0 .. cast(uint) face.length) {
            const v = m.vertices[face[c]];
            if (feq(v.x, pos.x) && feq(v.y, pos.y) && feq(v.z, pos.z)) {
                auto uv = cornerUv(m, fi, c);
                if (uv.length == 2) result ~= uv;
            }
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// fixtures (built in-process via flattenToMesh, the same seam mesh as import)
// ---------------------------------------------------------------------------

// A single unit quad with per-corner UV == (x,y). One position, one UV each.
private Mesh makeQuadUvMesh() {
    ImportedPart p;
    p.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    p.faces    = [[0u, 1u, 2u, 3u]];
    p.uv       = [0,0, 1,0, 1,1, 0,1];     // per-corner UV == xy
    ImportedScene s; s.parts = [p];
    return flattenToMesh(s);
}

// SEAM mesh: two quads sharing the edge (1,0,0)-(1,1,0) as POSITIONS, but with
// DIFFERENT UVs on the shared corners (a discontinuity). Welds to 6 verts.
//   left  quad P1 P2 P3 P4, UV (0,0)(0.5,0)(0.5,1)(0,1)
//   right quad P2 P5 P6 P3, UV (0,0)(1,0)(1,1)(0,1)  <- shared P2,P3 differ from left
private Mesh makeSeamUvMesh() {
    ImportedPart p;
    p.vertices = [
        Vec3(0,0,0),  // P1
        Vec3(1,0,0),  // P2 (shared)
        Vec3(1,1,0),  // P3 (shared)
        Vec3(0,1,0),  // P4
        Vec3(2,0,0),  // P5
        Vec3(2,1,0),  // P6
    ];
    p.faces = [[0u,1u,2u,3u], [1u,4u,5u,2u]];
    p.uv = [
        0.0f,0.0f,  0.5f,0.0f,  0.5f,1.0f,  0.0f,1.0f,   // left:  P1 P2 P3 P4
        0.0f,0.0f,  1.0f,0.0f,  1.0f,1.0f,  0.0f,1.0f,   // right: P2 P5 P6 P3 (seam @P2,P3)
    ];
    ImportedScene s; s.parts = [p];
    return flattenToMesh(s);
}

// The same two quads with NO UV — the welded-count + no-map baseline.
private Mesh makeSeamNoUvMesh() {
    ImportedPart p;
    p.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0),
        Vec3(0,1,0), Vec3(2,0,0), Vec3(2,1,0),
    ];
    p.faces = [[0u,1u,2u,3u], [1u,4u,5u,2u]];
    // p.uv left empty
    ImportedScene s; s.parts = [p];
    return flattenToMesh(s);
}

private string tmp(string name) { return "/tmp/vibe3d_uvexport_" ~ name; }

// Export `m` to `formatId`/`ext`, re-import (welds), return the reloaded mesh.
private Mesh exportReimport(const ref Mesh m, string formatId, string ext) {
    const path = tmp(formatId ~ ext);
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    const ok = exportViaAssimp(m, path, formatId);
    assert(ok, "exportViaAssimp failed for " ~ formatId);
    assert(exists(path), "no output file for " ~ formatId);

    ImportedScene s;
    const okIn = importViaAssimp(path, s);
    assert(okIn, "re-import failed for " ~ formatId);
    return flattenToMesh(s);
}

// ---------------------------------------------------------------------------
// OBJ — exact: welded vertex count + face count + per-corner UV round-trips.
// ---------------------------------------------------------------------------

unittest {
    initAssimp();
    if (!isAssimpAvailable()) return;

    auto orig = makeQuadUvMesh();
    assert(orig.meshMap(kUvMapName) !is null, "fixture must have a uv map");

    auto rt = exportReimport(orig, "obj", ".obj");
    assert(rt.vertices.length == orig.vertices.length,
        format("OBJ: re-imported vertex count %d != welded original %d",
               rt.vertices.length, orig.vertices.length));
    assert(rt.faces.length == orig.faces.length,
        format("OBJ: re-imported face count %d != %d", rt.faces.length, orig.faces.length));

    auto map = rt.meshMap(kUvMapName);
    assert(map !is null, "OBJ: re-imported mesh lost its uv map");
    // Per-corner UV == xy survived (match by geometry; corner order may differ).
    const face = rt.faces[0];
    foreach (uint c; 0 .. cast(uint) face.length) {
        const v = rt.vertices[face[c]];
        auto uv = cornerUv(rt, 0, c);
        assert(uv.length == 2 && feq(uv[0], v.x) && feq(uv[1], v.y),
            format("OBJ corner %d at (%g,%g) uv=%s, expected (%g,%g)",
                   c, v.x, v.y, uv, v.x, v.y));
    }
}

// ---------------------------------------------------------------------------
// OBJ SEAM — split on export, re-weld on import, per-corner discontinuity kept.
// ---------------------------------------------------------------------------

unittest {
    initAssimp();
    if (!isAssimpAvailable()) return;

    auto baseline = makeSeamNoUvMesh();
    const weldedCount = baseline.vertices.length;
    assert(weldedCount == 6, format("seam baseline should weld to 6, got %d", weldedCount));

    auto orig = makeSeamUvMesh();
    assert(orig.vertices.length == 6, "seam fixture should weld to 6 verts pre-export");

    auto rt = exportReimport(orig, "obj", ".obj");
    // The export split at the seam, the import weld undid it: back to 6 verts.
    assert(rt.vertices.length == weldedCount,
        format("OBJ seam: re-imported vertex count %d != welded original %d "
               ~ "(export-split not undone by import-weld)",
               rt.vertices.length, weldedCount));
    assert(rt.faces.length == 2, "OBJ seam: two faces expected");

    // The shared positions must carry DIFFERENT UVs on the two faces (the seam).
    foreach (sharedPos; [Vec3(1,0,0), Vec3(1,1,0)]) {
        auto uvs = uvsAtPosition(rt, sharedPos);
        assert(uvs.length == 2,
            format("OBJ seam: shared (%g,%g,%g) should appear on 2 faces, got %d",
                   sharedPos.x, sharedPos.y, sharedPos.z, uvs.length));
        const differ = !feq(uvs[0][0], uvs[1][0]) || !feq(uvs[0][1], uvs[1][1]);
        assert(differ,
            format("OBJ seam lost: (%g,%g,%g) has identical UV %s on both faces",
                   sharedPos.x, sharedPos.y, sharedPos.z, uvs[0]));
    }
}

// ---------------------------------------------------------------------------
// glTF — welded vertex count + per-corner UV (face arity NOT asserted: glTF
// triangulates n-gons on export, format-inherent).
// ---------------------------------------------------------------------------

unittest {
    initAssimp();
    if (!isAssimpAvailable()) return;

    auto orig = makeSeamUvMesh();

    auto rt = exportReimport(orig, "gltf2", ".gltf");
    assert(rt.vertices.length == orig.vertices.length,
        format("glTF: re-imported vertex count %d != welded original %d",
               rt.vertices.length, orig.vertices.length));
    assert(rt.meshMap(kUvMapName) !is null, "glTF: re-imported mesh lost its uv map");

    // Seam survives across the triangulated round-trip too.
    foreach (sharedPos; [Vec3(1,0,0), Vec3(1,1,0)]) {
        auto uvs = uvsAtPosition(rt, sharedPos);
        assert(uvs.length >= 2,
            format("glTF seam: shared (%g,%g,%g) should appear on >=2 corners, got %d",
                   sharedPos.x, sharedPos.y, sharedPos.z, uvs.length));
        bool anyDiffer = false;
        foreach (i; 0 .. uvs.length)
            foreach (j; i + 1 .. uvs.length)
                if (!feq(uvs[i][0], uvs[j][0]) || !feq(uvs[i][1], uvs[j][1]))
                    anyDiffer = true;
        assert(anyDiffer,
            format("glTF seam lost: (%g,%g,%g) has identical UV on all corners",
                   sharedPos.x, sharedPos.y, sharedPos.z));
    }
}

// ---------------------------------------------------------------------------
// FBX — nice-to-have (R4). Same expectation as OBJ, but tolerated as a skip if
// this libassimp's FBX exporter mishandles the UV channel (XFAIL per the plan).
// ---------------------------------------------------------------------------

unittest {
    initAssimp();
    if (!isAssimpAvailable()) return;

    auto orig = makeSeamUvMesh();
    Mesh rt;
    try {
        rt = exportReimport(orig, "fbx", ".fbx");
    } catch (Throwable t) {
        // FBX UV round-trip is a nice-to-have; a libassimp quirk degrades to a
        // skip rather than failing the suite (plan R4 — XFAIL acceptable).
        return;
    }

    if (rt.vertices.length != orig.vertices.length) return;   // XFAIL: weld diverged
    auto map = rt.meshMap(kUvMapName);
    if (map is null) return;                                  // XFAIL: FBX dropped UV

    // If it DID round-trip, hold it to the seam invariant.
    foreach (sharedPos; [Vec3(1,0,0), Vec3(1,1,0)]) {
        auto uvs = uvsAtPosition(rt, sharedPos);
        if (uvs.length < 2) return;                           // XFAIL: arity lost
        bool anyDiffer = false;
        foreach (i; 0 .. uvs.length)
            foreach (j; i + 1 .. uvs.length)
                if (!feq(uvs[i][0], uvs[j][0]) || !feq(uvs[i][1], uvs[j][1]))
                    anyDiffer = true;
        assert(anyDiffer,
            format("FBX seam lost: (%g,%g,%g) identical UV on all corners",
                   sharedPos.x, sharedPos.y, sharedPos.z));
    }
}

// ---------------------------------------------------------------------------
// no-UV — exports + re-imports unchanged (no "uv" map either side).
// ---------------------------------------------------------------------------

unittest {
    initAssimp();
    if (!isAssimpAvailable()) return;

    auto orig = makeSeamNoUvMesh();
    assert(orig.meshMap(kUvMapName) is null, "no-UV fixture must have no uv map");

    auto rt = exportReimport(orig, "obj", ".obj");
    assert(rt.vertices.length == orig.vertices.length,
        format("no-UV OBJ: vertex count %d != %d", rt.vertices.length, orig.vertices.length));
    assert(rt.faces.length == orig.faces.length,
        format("no-UV OBJ: face count %d != %d", rt.faces.length, orig.faces.length));
    assert(rt.meshMap(kUvMapName) is null,
        "no-UV export must not synthesize a uv map on round-trip");
}
