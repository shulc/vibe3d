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
