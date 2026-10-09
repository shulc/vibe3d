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

// ---------------------------------------------------------------------------
// S1e: the SURF sub-chunks of an exported surface, against the reference's own
// fresh-cube export (material defaults capture Q1): COLR 0.6, DIFF 0.8,
// SPEC 0.04, GLOS 0.6, SMAN 0.698132 — and SMAN 0 for smoothing off.
// ---------------------------------------------------------------------------

/// Sub-chunk id → first F4 of its body, for the first SURF chunk of `b`.
private float[string] surfScalars(const(ubyte)[] b)
{
    static uint be32(const(ubyte)[] s) { return (s[0] << 24) | (s[1] << 16) | (s[2] << 8) | s[3]; }
    float[string] out_;
    size_t p = 12;
    while (p + 8 <= b.length) {
        const string id = cast(string) b[p .. p + 4].idup;
        const uint sz = be32(b[p + 4 .. p + 8]);
        if (id == "SURF") {
            const(ubyte)[] d = b[p + 8 .. p + 8 + sz];
            size_t q;
            foreach (_; 0 .. 2) { while (d[q] != 0) ++q; ++q; if (q & 1) ++q; }   // name, source
            while (q + 6 <= d.length) {
                const string sid = cast(string) d[q .. q + 4].idup;
                const uint ssz = (d[q + 4] << 8) | d[q + 5];
                if (ssz >= 4) {
                    uint u = be32(d[q + 6 .. q + 10]);
                    out_[sid] = *cast(float*) &u;
                }
                q += 6 + ssz + (ssz & 1);
            }
            return out_;
        }
        p += 8 + sz + (sz & 1);
    }
    assert(false, "no SURF chunk");
}

unittest { // a default surface exports the reference's fresh-cube values, SMAN included
    import std.math : abs;
    import mesh : Surface;
    Mesh m = kindTris([false], [0]);
    m.surfaces = [Surface()];
    const path = scratchPath("s1e_default");
    scope (exit) if (exists(path)) remove(path);
    exportLwo(m, path);
    auto s = surfScalars(cast(const(ubyte)[]) read(path));
    assert("SMAN" in s, "export: no SMAN sub-chunk for a smoothing surface");
    assert(abs(s["SMAN"] - 0.6981317f) <= 1e-6, format("export: SMAN %s, expected 0.698132", s["SMAN"]));
    assert(s["COLR"] == 0.6f && s["DIFF"] == 0.8f && s["SPEC"] == 0.04f && s["GLOS"] == 0.6f,
        format("export: COLR %s DIFF %s SPEC %s GLOS %s, expected 0.6 / 0.8 / 0.04 / 0.6",
               s["COLR"], s["DIFF"], s["SPEC"], s["GLOS"]));
}

unittest { // smoothing off exports SMAN 0 (always written)
    import mesh : Surface;
    Mesh m = kindTris([false], [0]);
    Surface off;
    off.smoothing = false;
    off.smoothingAngleDeg = 25;
    m.surfaces = [off];
    const path = scratchPath("s1e_off");
    scope (exit) if (exists(path)) remove(path);
    exportLwo(m, path);
    auto s = surfScalars(cast(const(ubyte)[]) read(path));
    assert("SMAN" in s, "export: smoothing off wrote no SMAN — the export law writes SMAN 0");
    assert(s["SMAN"] == 0, format("export: smoothing off wrote SMAN %s, expected 0", s["SMAN"]));
}

// S1d: SIDE is written iff the surface is double-sided (value 3, size 2); a
// single-sided surface writes none (absent reads as one-sided, captured C7k),
// so a default surface's bytes do not move.
private ptrdiff_t sideValue(const(ubyte)[] b)
{
    static uint be32(const(ubyte)[] s) { return (s[0] << 24) | (s[1] << 16) | (s[2] << 8) | s[3]; }
    size_t p = 12;
    while (p + 8 <= b.length) {
        const string id = cast(string) b[p .. p + 4].idup;
        const uint sz = be32(b[p + 4 .. p + 8]);
        if (id == "SURF") {
            const(ubyte)[] d = b[p + 8 .. p + 8 + sz];
            size_t q;
            foreach (_; 0 .. 2) { while (d[q] != 0) ++q; ++q; if (q & 1) ++q; }
            while (q + 6 <= d.length) {
                const string sid = cast(string) d[q .. q + 4].idup;
                const uint ssz = (d[q + 4] << 8) | d[q + 5];
                if (sid == "SIDE") {
                    assert(ssz == 2, format("export: SIDE of size %s, expected 2", ssz));
                    return (d[q + 6] << 8) | d[q + 7];
                }
                q += 6 + ssz + (ssz & 1);
            }
            return -1;
        }
        p += 8 + sz + (sz & 1);
    }
    assert(false, "no SURF chunk");
}

unittest { // SIDE iff double-sided
    import mesh : Surface;
    Mesh m = kindTris([false], [0]);
    Surface one, two;
    two.twoSided = true;
    m.surfaces = [one];
    const p1 = scratchPath("s1d_single");
    scope (exit) if (exists(p1)) remove(p1);
    exportLwo(m, p1);
    assert(sideValue(cast(const(ubyte)[]) read(p1)) == -1, "export: a single-sided surface wrote SIDE");
    m.surfaces = [two];
    const p2 = scratchPath("s1d_double");
    scope (exit) if (exists(p2)) remove(p2);
    exportLwo(m, p2);
    immutable v = sideValue(cast(const(ubyte)[]) read(p2));
    assert(v == 3, format("export: a double-sided surface wrote SIDE %s, expected 3", v));
}
