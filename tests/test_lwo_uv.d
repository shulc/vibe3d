// test_lwo_uv.d — Stage 6 of the UV-maps milestone (#5): LWO UV wiring.
// Pure-D, source-backed (run_test.d's `dmd -unittest -i` path), so it drives the
// REAL LWO exporter + our OWN LWO reader end to end in-process — there is no HTTP
// surface for mesh maps, and this is the natural LWO sibling of test_uv_import.d /
// test_uv_export.d (which cover the assimp OBJ/glTF/FBX path).
//
// What it pins:
//   * io.lwo_export.exportLwo reconstructs the LWO two-tier UV (continuous VMAP
//     base + discontinuous VMAD overrides) from the flat per-corner "uv"
//     PolyVertex map, splitting overrides by face kind (FACE vs PTCH) so each
//     VMAD references a single kind (the lib's single-kind constraint).
//   * io.lwo_import.sceneFromLwo parses VMAP TXUV + VMAD TXUV and resolves them
//     back to the flat per-corner ImportedPart.uv stream (VMAP base overridden by
//     VMAD per corner), which flattenToMesh seeds into the "uv" map.
//   * Round-trip preserves the per-corner UV within tolerance AND preserves a
//     SEAM (a shared POSITION carrying different UVs on the two incident faces) —
//     the discontinuity the VMAD layer exists to store.
//   * A no-UV mesh exports + re-imports unchanged (no "uv" map either side).
//   * A MIXED-KIND mesh (one FACE quad + one PTCH/subpatch quad, each with a
//     distinct corner-UV) round-trips, exercising the per-kind VMAD split.
//
// Unlike the assimp path, our LWO reader does NOT weld positions — it preserves
// PNTS/POLS verbatim — so a seam authored as one shared position with two
// per-corner UVs round-trips WITHOUT any vertex-count change.

import std.math   : fabs;
import std.file   : remove, exists, getSize, write, readText, mkdirRecurse,
                    rmdirRecurse, tempDir;
import std.format : format;
import std.path   : buildPath;
import std.process : thisProcessID;
import std.uuid   : randomUUID;
import core.thread : Thread;
import core.time   : MonoTime, msecs, seconds;

version (Posix) {
    import core.sys.posix.sys.types : pid_t;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.unistd : fork, _exit;
}

import mesh : Mesh, MeshMap, MapDomain, kUvMapName;
import io.scene_ir  : ImportedScene, ImportedPart, flattenToMesh;
import io.lwo_export : exportLwo;
import io.lwo_import : sceneFromLwo;
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

// For a mesh: collect the per-corner UVs observed at a given position.
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
// fixtures (built in-process via flattenToMesh — same shapes as test_uv_export)
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

// SEAM mesh: two quads sharing the edge (1,0,0)-(1,1,0) as a single PAIR OF
// POSITIONS (P2,P3 are one vertex each, referenced by both faces), but with
// DIFFERENT UVs on the shared corners (a discontinuity). No weld needed: the
// shared positions ARE shared vertices already.
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

// The same two quads with NO UV — the no-map baseline.
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

// MIXED-KIND mesh: two quads, one FACE + one PTCH (subpatch), each with a
// distinct per-corner UV. Exercises the per-kind VMAD split on export (one VMAD
// for FACE overrides, one for PTCH) and the per-POLS-kind localToGlobal remap on
// import. The two quads still share P2,P3 as positions (a seam across kinds).
private Mesh makeMixedKindUvMesh() {
    auto m = makeSeamUvMesh();
    // Mark face 1 (the right quad) as a subpatch; face 0 stays FACE.
    m.resizeSubpatch();
    m.setFaceSubpatch(1, true);
    return m;
}

private string newTmpRootPath() {
    return buildPath(tempDir(), format("vibe3d-lwouv-%s-%d",
        randomUUID().toString(), thisProcessID));
}

unittest {
    assert(newTmpRootPath() != newTmpRootPath(),
        "temp root must not derive from the PID alone");
}

private __gshared string gTmpRoot;

private string tmp(string name) {
    if (!gTmpRoot.length) {
        gTmpRoot = newTmpRootPath();
        mkdirRecurse(gTmpRoot);
    }
    return buildPath(gTmpRoot, name);
}

private void cleanupTmpRoot() nothrow {
    const root = gTmpRoot;
    gTmpRoot = null;
    if (root.length && exists(root))
        try rmdirRecurse(root); catch (Exception) {}
}

shared static ~this() { cleanupTmpRoot(); }

version (Posix) {
    private Mesh makeCollisionMesh(int id) {
        auto m = makeQuadUvMesh();
        const xShift = cast(float) (id * 10);
        const uvShift = cast(float) id * 0.25f;
        foreach (ref v; m.vertices) v.x += xShift;
        auto map = m.meshMap(kUvMapName);
        assert(map !is null);
        foreach (ref value; map.data) value += uvShift;
        return m;
    }

    private void assertCollisionMesh(const ref Mesh m, int id) {
        assert(m.vertices.length == 4, "collision payload vertex count changed");
        assert(m.faces.length == 1 && m.faces[0].length == 4,
            "collision payload connectivity changed");
        const xShift = cast(float) (id * 10);
        const uvShift = cast(float) id * 0.25f;
        foreach (uint c; 0 .. 4) {
            const v = m.vertices[m.faces[0][c]];
            auto uv = cornerUv(m, 0, c);
            assert(uv.length == 2
                    && feq(uv[0], v.x - xShift + uvShift)
                    && feq(uv[1], v.y + uvShift),
                format("collision payload %d corner %d mismatch: pos=(%g,%g) uv=%s",
                       id, c, v.x, v.y, uv));
        }
    }

    private void waitForCollisionFile(string path) {
        const deadline = MonoTime.currTime + 5.seconds;
        while (!exists(path) && MonoTime.currTime < deadline)
            Thread.sleep(5.msecs);
        assert(exists(path), "collision barrier timed out waiting for " ~ path);
    }

    private int runCollisionChild(int id, string barrierDir) {
        int result;
        string path;
        try {
            path = tmp("collision.lwo");
            write(buildPath(barrierDir, format("root-%d", id)), gTmpRoot);
            if (exists(path)) remove(path);
            auto payload = makeCollisionMesh(id);
            exportLwo(payload, path);
            assert(exists(path) && getSize(path) > 0,
                format("collision payload %d was not written", id));
            write(buildPath(barrierDir, format("ready-%d", id)), path);

            waitForCollisionFile(buildPath(barrierDir, format("ready-%d", 1 - id)));

            ImportedScene scene;
            assert(sceneFromLwo(path, scene),
                format("collision payload %d could not be read", id));
            auto reloaded = flattenToMesh(scene);
            assertCollisionMesh(reloaded, id);
        } catch (Throwable t) {
            try write(buildPath(barrierDir, format("error-%d", id)), t.toString());
            catch (Throwable) {}
            result = 1;
        }

        if (id == 0) {
            cleanupTmpRoot();
            try write(buildPath(barrierDir, "cleaned-0"), "done");
            catch (Throwable) { result = 1; }
        } else {
            try {
                waitForCollisionFile(buildPath(barrierDir, "cleaned-0"));
                if (result == 0) {
                    assert(exists(path),
                        "worker 0 cleanup removed worker 1's LWO file");
                    ImportedScene scene;
                    assert(sceneFromLwo(path, scene),
                        "worker 1 could not re-read its file after worker 0 cleanup");
                    auto reloaded = flattenToMesh(scene);
                    assertCollisionMesh(reloaded, id);
                }
            } catch (Throwable t) {
                try write(buildPath(barrierDir, format("error-%d", id)), t.toString());
                catch (Throwable) {}
                result = 1;
            }
            cleanupTmpRoot();
        }
        return result;
    }

    private pid_t startCollisionChild(int id, string barrierDir) {
        const pid = fork();
        assert(pid >= 0, "fork failed for LWO collision worker");
        if (pid == 0) _exit(runCollisionChild(id, barrierDir));
        return pid;
    }

    private int waitCollisionChild(pid_t pid) {
        int status;
        assert(waitpid(pid, &status, 0) == pid, "waitpid failed for LWO collision worker");
        return status;
    }

    private string collisionError(string barrierDir, int id) {
        const path = buildPath(barrierDir, format("error-%d", id));
        return exists(path) ? readText(path) : "no child diagnostic";
    }

    private string sequentialError(string barrierDir, int id) {
        const path = buildPath(barrierDir, format("sequential-error-%d", id));
        return exists(path) ? readText(path) : "no child diagnostic";
    }

    private int runSequentialChild(int id, string barrierDir) {
        int result;
        try {
            const path = tmp("sequential.lwo");
            write(buildPath(barrierDir, format("sequential-root-%d", id)), gTmpRoot);
            if (id == 1) {
                assert(!exists(path),
                    "second sequential worker accepted the first invocation's leftover");
            }
            auto payload = makeCollisionMesh(id);
            exportLwo(payload, path);
            assert(exists(path) && getSize(path) > 0,
                format("sequential payload %d was not written", id));
            ImportedScene scene;
            assert(sceneFromLwo(path, scene),
                format("sequential payload %d could not be read", id));
            auto reloaded = flattenToMesh(scene);
            assertCollisionMesh(reloaded, id);
        } catch (Throwable t) {
            try write(buildPath(barrierDir, format("sequential-error-%d", id)), t.toString());
            catch (Throwable) {}
            result = 1;
        }
        if (id == 1) cleanupTmpRoot();
        return result;
    }

    private pid_t startSequentialChild(int id, string barrierDir) {
        const pid = fork();
        assert(pid >= 0, "fork failed for sequential LWO worker");
        if (pid == 0) _exit(runSequentialChild(id, barrierDir));
        return pid;
    }
}

// Export `m` to LWO, re-import via our own reader (sceneFromLwo + flattenToMesh).
private Mesh exportReimport(const ref Mesh m, string name) {
    const path = tmp(name);
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    exportLwo(m, path);
    assert(exists(path) && getSize(path) > 0, "no LWO output for " ~ name);

    ImportedScene s;
    const ok = sceneFromLwo(path, s);
    assert(ok, "sceneFromLwo failed for " ~ name);
    assert(s.parts.length > 0 && s.parts[0].vertices.length > 0
            && s.parts[0].faces.length > 0,
        "LWO import floor: re-imported scene is empty for " ~ name);
    auto mesh = flattenToMesh(s);
    assert(mesh.vertices.length > 0 && mesh.faces.length > 0,
        "LWO import floor: flattened round-trip mesh is empty for " ~ name);
    return mesh;
}

version (Posix) unittest {
    const barrierDir = buildPath(tempDir(),
        "vibe3d-lwouv-collision-" ~ randomUUID().toString());
    mkdirRecurse(barrierDir);
    scope(exit) if (exists(barrierDir)) rmdirRecurse(barrierDir);

    const first = startCollisionChild(0, barrierDir);
    const second = startCollisionChild(1, barrierDir);
    const firstStatus = waitCollisionChild(first);
    const secondStatus = waitCollisionChild(second);

    const firstRootMarker = buildPath(barrierDir, "root-0");
    const secondRootMarker = buildPath(barrierDir, "root-1");
    assert(exists(firstRootMarker),
        format("collision worker 0 did not report its temp root (status=%d): %s",
               firstStatus, collisionError(barrierDir, 0)));
    assert(exists(secondRootMarker),
        format("collision worker 1 did not report its temp root (status=%d): %s",
               secondStatus, collisionError(barrierDir, 1)));
    assert(exists(buildPath(barrierDir, "ready-0")),
        format("collision worker 0 failed before completing its own LWO write "
               ~ "(status=%d): %s", firstStatus,
               collisionError(barrierDir, 0)));
    assert(exists(buildPath(barrierDir, "ready-1")),
        format("collision worker 1 failed before completing its own LWO write "
               ~ "(status=%d): %s", secondStatus,
               collisionError(barrierDir, 1)));
    assert(firstStatus == 0 && secondStatus == 0,
        format("LWO temp isolation collision after the write/read barrier: "
               ~ "worker 0 status=%d: %s\nworker 1 status=%d: %s",
               firstStatus, collisionError(barrierDir, 0),
               secondStatus, collisionError(barrierDir, 1)));

    const firstRoot = readText(firstRootMarker);
    const secondRoot = readText(secondRootMarker);
    assert(firstRoot.length > 0 && secondRoot.length > 0 && firstRoot != secondRoot,
        format("concurrent workers shared a temp root: '%s' / '%s'",
               firstRoot, secondRoot));
    assert(!exists(firstRoot) && !exists(secondRoot),
        "concurrent worker roots survived owner cleanup");

    const sequentialFirst = startSequentialChild(0, barrierDir);
    const sequentialFirstStatus = waitCollisionChild(sequentialFirst);
    assert(sequentialFirstStatus == 0,
        "first sequential LWO worker failed: "
        ~ sequentialError(barrierDir, 0));

    const sequentialFirstRootMarker = buildPath(
        barrierDir, "sequential-root-0");
    assert(exists(sequentialFirstRootMarker),
        "first sequential worker did not report its temp root");
    const sequentialFirstRoot = readText(sequentialFirstRootMarker);
    assert(sequentialFirstRoot.length > 0,
        "first sequential worker reported an empty temp root");
    scope(exit) if (exists(sequentialFirstRoot))
        rmdirRecurse(sequentialFirstRoot);
    assert(exists(buildPath(sequentialFirstRoot, "sequential.lwo")),
        "first sequential worker did not leave an LWO file for the leftover check");

    const sequentialSecond = startSequentialChild(1, barrierDir);
    const sequentialSecondStatus = waitCollisionChild(sequentialSecond);
    assert(sequentialSecondStatus == 0,
        "second sequential LWO worker failed: "
        ~ sequentialError(barrierDir, 1));

    const sequentialSecondRootMarker = buildPath(
        barrierDir, "sequential-root-1");
    assert(exists(sequentialSecondRootMarker),
        "second sequential worker did not report its temp root");
    const sequentialSecondRoot = readText(sequentialSecondRootMarker);
    assert(sequentialSecondRoot.length > 0
            && sequentialFirstRoot != sequentialSecondRoot,
        format("sequential workers reused a temp root: '%s' / '%s'",
               sequentialFirstRoot, sequentialSecondRoot));
    assert(!exists(sequentialSecondRoot),
        "second sequential worker root survived owner cleanup");
    rmdirRecurse(sequentialFirstRoot);
    assert(!exists(sequentialFirstRoot),
        "parent cleanup left the first sequential worker root behind");
}

// ---------------------------------------------------------------------------
// simple quad — per-corner UV round-trips exactly (continuous; VMAP only)
// ---------------------------------------------------------------------------

unittest {
    auto orig = makeQuadUvMesh();
    assert(orig.meshMap(kUvMapName) !is null, "fixture must have a uv map");

    auto rt = exportReimport(orig, "quad.lwo");
    assert(rt.vertices.length == orig.vertices.length,
        format("quad: vertex count %d != %d", rt.vertices.length, orig.vertices.length));
    assert(rt.faces.length == 1, "quad: face count mismatch");

    auto map = rt.meshMap(kUvMapName);
    assert(map !is null, "quad: re-imported mesh lost its uv map");
    assert(map.domain == MapDomain.PolyVertex && map.dim == 2);

    // Per-corner UV == xy survived (match by geometry; corner order is stable
    // through our reader, but match by position to be order-agnostic).
    const face = rt.faces[0];
    foreach (uint c; 0 .. cast(uint) face.length) {
        const v = rt.vertices[face[c]];
        auto uv = cornerUv(rt, 0, c);
        assert(uv.length == 2 && feq(uv[0], v.x) && feq(uv[1], v.y),
            format("quad corner %d at (%g,%g) uv=%s, expected (%g,%g)",
                   c, v.x, v.y, uv, v.x, v.y));
    }
}

// ---------------------------------------------------------------------------
// seam — shared position, two distinct UVs, the discontinuity survives (VMAD)
// ---------------------------------------------------------------------------

unittest {
    auto orig = makeSeamUvMesh();
    assert(orig.meshMap(kUvMapName) !is null, "seam fixture must have a uv map");

    auto rt = exportReimport(orig, "seam.lwo");
    // No weld in the LWO path — the 6 authored positions stay 6 vertices.
    assert(rt.vertices.length == 6,
        format("seam: vertex count %d != 6 (no weld expected)", rt.vertices.length));
    assert(rt.faces.length == 2, "seam: two quads expected");

    auto map = rt.meshMap(kUvMapName);
    assert(map !is null, "seam: re-imported mesh lost its uv map");
    assert(map.data.length == rt.loops.length * 2);

    // The shared positions (1,0,0) and (1,1,0) must carry DIFFERENT UVs on the
    // two faces — the seam. Compare against the original's per-position UV set.
    foreach (sharedPos; [Vec3(1,0,0), Vec3(1,1,0)]) {
        auto origUvs = uvsAtPosition(orig, sharedPos);
        auto rtUvs   = uvsAtPosition(rt,   sharedPos);
        assert(origUvs.length == 2 && rtUvs.length == 2,
            format("seam: position (%g,%g,%g) should appear on 2 faces (orig=%d rt=%d)",
                   sharedPos.x, sharedPos.y, sharedPos.z, origUvs.length, rtUvs.length));
        // The two corner UVs differ (the seam is preserved).
        const differ = !feq(rtUvs[0][0], rtUvs[1][0]) || !feq(rtUvs[0][1], rtUvs[1][1]);
        assert(differ,
            format("seam lost: position (%g,%g,%g) has identical UV %s on both faces",
                   sharedPos.x, sharedPos.y, sharedPos.z, rtUvs[0]));
        // And each round-tripped UV matches one of the original's two values.
        foreach (rv; rtUvs) {
            bool matched = false;
            foreach (ov; origUvs)
                if (feq(rv[0], ov[0]) && feq(rv[1], ov[1])) { matched = true; break; }
            assert(matched,
                format("seam: round-trip UV %s at (%g,%g,%g) not in original set %s",
                       rv, sharedPos.x, sharedPos.y, sharedPos.z, origUvs));
        }
    }

    // Spot-check the non-shared corners too (P1,P4,P5,P6 — unique positions,
    // continuous VMAP base only). Each must equal the original's per-corner UV.
    foreach (uniquePos; [Vec3(0,0,0), Vec3(0,1,0), Vec3(2,0,0), Vec3(2,1,0)]) {
        auto origUvs = uvsAtPosition(orig, uniquePos);
        auto rtUvs   = uvsAtPosition(rt,   uniquePos);
        assert(origUvs.length == 1 && rtUvs.length == 1,
            format("unique position (%g,%g,%g): orig=%d rt=%d corners",
                   uniquePos.x, uniquePos.y, uniquePos.z, origUvs.length, rtUvs.length));
        assert(feq(rtUvs[0][0], origUvs[0][0]) && feq(rtUvs[0][1], origUvs[0][1]),
            format("unique (%g,%g,%g) uv %s != original %s",
                   uniquePos.x, uniquePos.y, uniquePos.z, rtUvs[0], origUvs[0]));
    }
}

// ---------------------------------------------------------------------------
// no UV — export + re-import unchanged (no "uv" map either side)
// ---------------------------------------------------------------------------

unittest {
    auto orig = makeSeamNoUvMesh();
    assert(orig.meshMap(kUvMapName) is null, "no-UV fixture must have no uv map");

    auto rt = exportReimport(orig, "nouv.lwo");
    assert(rt.vertices.length == orig.vertices.length, "no-UV: vertex count changed");
    assert(rt.faces.length == orig.faces.length, "no-UV: face count changed");
    assert(rt.meshMap(kUvMapName) is null,
        "no-UV: a \"uv\" map appeared after round-trip (should stay UV-less)");
}

// ---------------------------------------------------------------------------
// mixed kind — FACE + PTCH quads, per-kind VMAD split round-trips
// ---------------------------------------------------------------------------

unittest {
    auto orig = makeMixedKindUvMesh();
    assert(orig.meshMap(kUvMapName) !is null, "mixed fixture must have a uv map");
    assert(!orig.isFaceSubpatch(0) && orig.isFaceSubpatch(1),
        "mixed fixture: face 0 FACE, face 1 PTCH");

    auto rt = exportReimport(orig, "mixed.lwo");
    assert(rt.vertices.length == 6, "mixed: vertex count mismatch");
    assert(rt.faces.length == 2, "mixed: two quads expected");

    auto map = rt.meshMap(kUvMapName);
    assert(map !is null, "mixed: re-imported mesh lost its uv map");

    // The subpatch flags survive — the per-kind VMAD split must not perturb the
    // FACE/PTCH classification. (Reader sorts FACE chunk before PTCH chunk, so
    // re-imported face order may put the FACE quad first; identify by kind.)
    int faceCount = 0, ptchCount = 0;
    foreach (uint fi; 0 .. cast(uint) rt.faces.length)
        if (rt.isFaceSubpatch(fi)) ++ptchCount; else ++faceCount;
    assert(faceCount == 1 && ptchCount == 1,
        format("mixed: expected 1 FACE + 1 PTCH, got %d/%d", faceCount, ptchCount));

    // The seam at the shared positions still survives across the kind boundary.
    foreach (sharedPos; [Vec3(1,0,0), Vec3(1,1,0)]) {
        auto rtUvs = uvsAtPosition(rt, sharedPos);
        assert(rtUvs.length == 2,
            format("mixed: shared position (%g,%g,%g) should appear on 2 faces, got %d",
                   sharedPos.x, sharedPos.y, sharedPos.z, rtUvs.length));
        const differ = !feq(rtUvs[0][0], rtUvs[1][0]) || !feq(rtUvs[0][1], rtUvs[1][1]);
        assert(differ,
            format("mixed: seam lost at (%g,%g,%g): identical UV %s",
                   sharedPos.x, sharedPos.y, sharedPos.z, rtUvs[0]));
    }
}
