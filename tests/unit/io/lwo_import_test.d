// Module unittests for `io.lwo_import`, moved verbatim out of source/io/lwo_import.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.io.lwo_import_test;

import std.file      : read, exists, getSize;
import std.algorithm : min;
import std.format    : format;
import mesh;
import math;
import io.scene_ir;
import log : logWarn, logInfo;
import std.bitmanip : nativeToBigEndian;
import io.lwo_import;

// task 0678 D3 — mixed FACE+PTCH layer round-trip: PTAG SURF poly indices are
// POLS-LOCAL per kind (one PTAG per kind, right after that kind's POLS — the
// same binding rule as VMAD).  The pre-fix importer read them as FLAT slots
// into the concatenated poly list, so on a mixed layer the PTCH tags landed on
// (and clobbered) the FACE slots; the pre-fix writer emitted one trailing PTAG
// covering both kinds, which no most-recent-POLS reader can disambiguate.
unittest {
    import std.file : tempDir, remove, exists;
    import std.path : buildPath;
    import std.math : abs;
    import mesh : Mesh, Surface;
    import io.lwo_export : exportLwo;

    // Four separate tris, tri k at x offset k*10 so each imported poly's
    // source is recoverable from its first vertex.  Faces 0,2 = FACE; 1,3 =
    // PTCH.  Materials: A,B,B,A — chosen so the flat misread produces a
    // DIFFERENT assignment than the correct per-kind remap.
    Mesh m = Mesh.init;
    uint[ulong] el;
    foreach (uint k; 0 .. 4) {
        const float x = k * 10.0f;
        const uint b = cast(uint) m.vertices.length;
        m.vertices ~= [Vec3(x, 0, 0), Vec3(x + 1, 0, 0), Vec3(x, 1, 0)];
        m.addFaceFast(el, [b, b + 1, b + 2]);
    }
    m.buildLoops();
    m.resizeSubpatch();
    m.setFaceSubpatch(1, true);
    m.setFaceSubpatch(3, true);
    Surface sa; sa.name = "MatA";
    Surface sb; sb.name = "MatB";
    m.surfaces = [sa, sb];
    m.faceMaterial = [0u, 1u, 1u, 0u];

    import std.process : thisProcessID;
    const string path = buildPath(tempDir,
        format("vibe3d_0678_d3_mixed_ptag_%d.lwo", thisProcessID));
    scope (exit) if (exists(path)) remove(path);
    exportLwo(m, path);

    ImportedScene scene;
    assert(sceneFromLwo(path, scene), "mixed-kind LWO must import");
    assert(scene.parts.length == 1);
    auto part = scene.parts[0];
    assert(part.faces.length == 4, "all four tris must survive");

    const string[4] wantName = ["MatA", "MatB", "MatB", "MatA"];
    foreach (i, face; part.faces) {
        const float x0 = part.vertices[face[0]].x;
        const int k = cast(int) ((x0 + 0.5f) / 10.0f);
        assert(k >= 0 && k < 4, "imported poly must map to a source tri");
        const bool wantSub = (k == 1 || k == 3);
        assert(part.faceSubpatch[i] == wantSub,
               "poly kind must survive the round-trip");
        const uint mat = part.faceMaterial[i];
        assert(mat < part.surfaces.length, "material index must be in range");
        assert(part.surfaces[mat].name == wantName[k],
               "PTAG SURF must bind per kind: mixed FACE+PTCH layer tags");
    }
}

// ---------------------------------------------------------------------------
// S1e: SURF smoothing and the absent-sub-chunk defaults (captured: material
// defaults capture Q1 import table; C8b (i)–(iv)).
// ---------------------------------------------------------------------------

/// The first surface of the image `img`, through the public importer.
private ImportedSurface importFirstSurface(ubyte[] img, string stem) {
    import std.file : tempDir, write, remove, exists;
    import std.path : buildPath;
    import std.process : thisProcessID;
    const string path = buildPath(tempDir, format("vibe3d_s1e_%s_%d.lwo", stem, thisProcessID));
    scope (exit) if (exists(path)) remove(path);
    write(path, img);
    ImportedScene scene;
    assert(sceneFromLwo(path, scene), "S1e: the hand-built LWO did not import: " ~ stem);
    assert(scene.parts.length == 1 && scene.parts[0].surfaces.length >= 1, "S1e: no surface imported: " ~ stem);
    return scene.parts[0].surfaces[0];
}

unittest { // SMAN rows: on @ angle, absent → OFF, 0 → OFF @ 0°, 3.5 stored unclamped
    import std.math : abs;
    import tests.unit.io.lwo_ptag_fixture : lwoImage, LwoSurf, LwoSub, lwoF4;
    auto on = importFirstSurface(lwoImage(["S"], [LwoSurf("S", [LwoSub("SMAN", lwoF4(0.6981317f))])]), "on");
    assert(on.smoothing && abs(on.smoothingAngleDeg - 40.0f) <= 1e-4,
        format("SMAN 0.6981317: smoothing %s angle %s, expected on @ 40°", on.smoothing, on.smoothingAngleDeg));
    auto absent = importFirstSurface(lwoImage(["S"], [LwoSurf("S", [LwoSub("DIFF", lwoF4(0.5f))])]), "absent");
    assert(!absent.smoothing, "SMAN absent: smoothing is on — the absent-SMAN law imports OFF");
    auto zero = importFirstSurface(lwoImage(["S"], [LwoSurf("S", [LwoSub("SMAN", lwoF4(0))])]), "zero");
    assert(!zero.smoothing, "SMAN 0: smoothing is on — C8b (i) is the SMAN > 0 rule");
    assert(zero.smoothingAngleDeg == 0, format("SMAN 0: angle %s, expected exactly 0 (C8b (i))", zero.smoothingAngleDeg));
    auto big = importFirstSurface(lwoImage(["S"], [LwoSurf("S", [LwoSub("SMAN", lwoF4(3.5f))])]), "big");
    assert(big.smoothing && abs(big.smoothingAngleDeg - 200.535f) <= 1e-3,
        format("SMAN 3.5: smoothing %s angle %s, expected on @ 200.535° unclamped (C8b (iv))",
               big.smoothing, big.smoothingAngleDeg));
}

unittest { // absent COLR / GLOS / SPEC / DIFF read the default material; a tag with no SURF is fresh
    import tests.unit.io.lwo_ptag_fixture : lwoImage, LwoSurf, LwoSub, lwoF4;
    auto bare = importFirstSurface(lwoImage(["S"], [LwoSurf("S", [LwoSub("TRAN", lwoF4(0))])]), "bare");
    assert(bare.baseColor == Vec3(0.6f, 0.6f, 0.6f), format("no COLR: base %s, expected 0.6 (C8b (ii))", bare.baseColor));
    assert(bare.glossiness == 0.6f && bare.specular == 0.04f && bare.diffuse == 0.8f,
        format("no GLOS/SPEC/DIFF: %s / %s / %s, expected 0.6 / 0.04 / 0.8",
               bare.glossiness, bare.specular, bare.diffuse));
    auto fresh = importFirstSurface(lwoImage(["S"], []), "nosurf");
    assert(fresh == ImportedSurface("S"),
        format("a TAGS name with no SURF: %s, expected a fresh ImportedSurface (on @ 40°, C8b (iii))", fresh));
}
