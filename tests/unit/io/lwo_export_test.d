// Module unittests for `io.lwo_export` (task 4067): a layer mixing plain
// faces (FACE) and subdivision faces (PTCH) must export so that a CONFORMANT
// reader -- one that binds each PTAG to the most-recent POLS chunk, per the
// format -- puts every surface tag on the right polygon.
//
// Why two round-trips, and why the second is the one that matters: see
// tests/unit/io/lwo_ptag_fixture.d. The first goes through our own importer,
// which decodes the legacy single-trailing-PTAG layout positionally (task
// 0683) and is green on either writer version; it is here as the floor that
// proves the fixture itself is sound. The second goes through the writer
// package's own reader (`lwo2.reader.readLwo2`), which binds conformantly and
// misreads the legacy layout -- it is RED on writer pin fc87b3f3 and GREEN on
// 8610ff2 ("emit PTAG SURF per POLS kind"). Keep the order: druntime stops a
// module at its first failed assert, so the floor must sit above the pin.
module tests.unit.io.lwo_export_test;

import std.file    : read, exists, remove, tempDir;
import std.path    : buildPath;
import std.format  : format;
import std.process : thisProcessID;
import mesh : Mesh;
import io.lwo_export : exportLwo;
import io.lwo_import : sceneFromLwo;
import io.scene_ir   : ImportedScene;
import lwo2.reader   : readLwo2;
import lwo2.writer   : Lwo2Object;
import tests.unit.io.lwo_ptag_fixture;

private string scratchPath(string stem)
{
    return buildPath(tempDir, format("vibe3d_4067_%s_%d.lwo", stem, thisProcessID));
}

unittest { // floor: our (legacy-tolerant) importer recovers the fixture's tags
    Mesh m = kindTris(kMixedSubpatch[], kMixedMaterial[]);
    const path = scratchPath("mixed_ours");
    scope (exit) if (exists(path)) remove(path);
    exportLwo(m, path);

    ImportedScene scene;
    assert(sceneFromLwo(path, scene), "mixed-kind LWO must import");
    assert(scene.parts.length == 1, "one layer in, one part out");
    auto part = scene.parts[0];
    assert(part.faces.length == kMixedSubpatch.length,
           format("all %d tris must survive, got %d", kMixedSubpatch.length, part.faces.length));
    assert(part.surfaces.length == kSurfaceNames.length, "surface table must survive");

    uint faceN = 0, ptchN = 0;
    foreach (i, face; part.faces) {
        const int k = sourceTri(part.vertices[face[0]].x);
        assert(k >= 0 && k < kMixedSubpatch.length, "imported poly must map to a source tri");
        assert(part.faceSubpatch[i] == kMixedSubpatch[k], "poly kind must survive the round-trip");
        if (part.faceSubpatch[i]) ++ptchN; else ++faceN;
        const uint mat = part.faceMaterial[i];
        assert(mat < part.surfaces.length, "material index must be in range");
        assert(part.surfaces[mat].name == kSurfaceNames[kMixedMaterial[k]],
               format("our importer: tri %d (%s) expected surface %s, got %s",
                      k, kMixedSubpatch[k] ? "PTCH" : "FACE",
                      kSurfaceNames[kMixedMaterial[k]], part.surfaces[mat].name));
    }
    assert(faceN == 2 && ptchN == 3, format("expected 2 FACE + 3 PTCH, got %d/%d", faceN, ptchN));
}

unittest { // the pin: a conformant most-recent-POLS reader gets every tag right
    Mesh m = kindTris(kMixedSubpatch[], kMixedMaterial[]);
    const path = scratchPath("mixed_conformant");
    scope (exit) if (exists(path)) remove(path);
    exportLwo(m, path);

    Lwo2Object rd = readLwo2(cast(const(ubyte)[]) read(path));
    assert(rd.layers.length == 1, "one LAYR expected");
    auto layer = rd.layers[0];
    assert(layer.polygons.length == kMixedSubpatch.length,
           format("all %d tris must be read, got %d", kMixedSubpatch.length, layer.polygons.length));
    assert(rd.surfaces.length == kSurfaceNames.length, "surface table must be read");

    // Population floor first: both kinds present with the fixture's counts.
    // These hold on either writer layout (POLS chunks are unchanged by the
    // fix) -- only the tag assert below discriminates.
    uint faceN = 0, ptchN = 0;
    foreach (poly; layer.polygons) if (poly.subpatch) ++ptchN; else ++faceN;
    assert(faceN == 2 && ptchN == 3, format("expected 2 FACE + 3 PTCH, got %d/%d", faceN, ptchN));

    foreach (poly; layer.polygons) {
        const int k = sourceTri(layer.points[poly.indices[0]][0]);
        assert(k >= 0 && k < kMixedSubpatch.length, "read poly must map to a source tri");
        assert(poly.subpatch == kMixedSubpatch[k], "poly kind must be read from its POLS chunk");
        assert(poly.surface < rd.surfaces.length, "surface index must be in range");
        const string want = kSurfaceNames[kMixedMaterial[k]];
        const string got  = rd.surfaces[poly.surface].name;
        assert(got == want,
               format("conformant PTAG decode: tri %d (%s) expected surface %s, got %s",
                      k, kMixedSubpatch[k] ? "PTCH" : "FACE", want, got));
    }
}
