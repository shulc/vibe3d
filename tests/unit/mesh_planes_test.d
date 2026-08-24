// mesh_planes_test — L3, the BEHAVIOURAL oracle for `mesh_planes.rewriteFaces`
// / `rewriteVertices` (task 1902, `doc/reindex_primitive_plan.md` §3 L3).
//
// THE ONE RULE THAT MAKES THIS A GATE AND NOT THEATRE: the plane list below
// is HAND-WRITTEN, independently of `mesh_planes.kFacePlanes` — it is never
// derived from it, and no line here reads `kFacePlanes` at all. If this test
// iterated `kFacePlanes` instead, deleting `"faceMaterial"` from that table
// would shrink the primitive AND this test's coverage together, and the
// suite would go green straight through the mutation (plan §3's stated
// trap). §8 mutation M4 ("delete `faceMaterial` from `kFacePlanes`") is
// exactly this scenario, and it must redden HERE, by name, run in isolation
// (druntime stops a module at its first failed assert, so with two planes
// broken for two different reasons the second hides behind the first).
//
// L1 (the two `static assert`s on `Mesh.tupleof`) and L2 (the runtime
// name-prefix census + tree-scan gate) live in `mesh_planes.d` and
// `mesh_planes_census_test.d` respectively — this file does not duplicate
// either. What closes the loop between "a plane was added to `kFacePlanes`"
// and "the primitive actually carries it" is THIS file's independent list:
// extending it without touching `kFacePlanes` reddens here by name; the
// reverse (extending `kFacePlanes` without extending this list) is silent —
// which is fine, because that is a coverage gap for the NEXT person to close,
// not a correctness bug the guard needs to catch (L1/L2 already force every
// new per-face field to be classified one way or the other).
module tests.unit.mesh_planes_test;

import mesh;
import mesh_planes;
import math : Vec3;
import std.format : format;

// ---------------------------------------------------------------------------
// Local helpers — deliberately NOT shared with
// tests/unit/mesh_selsets_polygon_carry_test.d's near-identical pair: this
// file's oracle must stay independently readable, not entangled with another
// test module's private state.
// ---------------------------------------------------------------------------

private Vec3 centroidOf(ref Mesh m, size_t fi) {
    Vec3 c = Vec3(0, 0, 0);
    auto f = m.faces[fi];
    foreach (vid; f) c = c + m.vertices[vid];
    return Vec3(c.x / f.length, c.y / f.length, c.z / f.length);
}

private size_t faceByCentroid(ref Mesh m, Vec3 target, double tol = 1e-4) {
    foreach (fi; 0 .. m.faces.length) {
        if ((centroidOf(m, fi) - target).length < tol) return fi;
    }
    assert(false, "no surviving face at the expected centroid");
}

private Vec3 vertPos(ref Mesh m, size_t vi) { return m.vertices[vi]; }

private size_t vertByPosition(ref Mesh m, Vec3 target, double tol = 1e-4) {
    foreach (vi; 0 .. m.vertices.length) {
        if ((m.vertices[vi] - target).length < tol) return vi;
    }
    assert(false, "no surviving vertex at the expected position");
}

// ---------------------------------------------------------------------------
// L3 — faces. All five `kFacePlanes` entries, one hand-written assertion
// each, on a SINGLE rewrite (one `rewriteFaces` call carries every plane at
// once — that is the primitive's whole point).
// ---------------------------------------------------------------------------

unittest // rewriteFaces carries faceMarks/faceMaterial/facePart/faceSelectionOrder/faceSetMask, tracked by centroid across a middle-face drop
{
    Mesh m = makeGridPlane(3);      // 9 quads, open, row-major fi = i*3 + j
    m.resetSelection();

    // A distinct value per face per plane, so "carried" and "zero-filled"
    // (or "carried from the WRONG face") cannot coincide by accident.
    foreach (fi; 0 .. m.faces.length) {
        m.faceMaterial[fi]       = cast(uint)(100 + fi);
        m.facePart[fi]           = cast(uint)(200 + fi);
        m.faceSelectionOrder[fi] = cast(int)(300 + fi);
        m.faceSetMask[fi]        = cast(ulong)(1 + fi);
        m.faceMarks[fi]          = (fi % 2 == 0) ? Mesh.Marks.Select : Mesh.Marks.Subpatch;
    }

    // The TRACKED face gets a value on every plane that no OTHER face
    // shares (seeded above OR after this override), so a carry that reads
    // the wrong source face cannot coincidentally pass.
    enum size_t tracked = 7;
    m.faceMaterial[tracked]       = 9001;
    m.facePart[tracked]           = 9002;
    m.faceSelectionOrder[tracked] = 9003;
    m.faceSetMask[tracked]        = 0x9004UL;
    m.faceMarks[tracked]          = Mesh.Marks.Select | Mesh.Marks.Hide;

    immutable Vec3 wantCentroid = centroidOf(m, tracked);

    // Drop face 4 — the grid's MIDDLE, strictly BEFORE `tracked` in array
    // order — so the tracked face's index SHIFTS (7 -> 6). A TAIL drop
    // could not discriminate a carry bug from a correct one: every
    // surviving index would be unchanged (plan §4 point 3 / point 2).
    enum size_t dropped = 4;
    static assert(dropped < tracked, "the drop must sit BEFORE the tracked face");

    uint[][] newFaces;
    uint[]   oldOfNew;
    foreach (fi; 0 .. m.faces.length) {
        if (fi == dropped) continue;
        newFaces ~= m.faces[fi].dup;
        oldOfNew ~= cast(uint) fi;
    }
    assert(newFaces.length == m.faces.length - 1, "fixture: exactly one face dropped");

    rewriteFaces(m, newFaces, FaceSource(oldOfNew));

    immutable size_t survivor = faceByCentroid(m, wantCentroid);
    assert(survivor != tracked,
           "the tracked face DID shift index (7 -> 6) — that shift is the "
         ~ "property under test; if this fails the fixture stopped "
         ~ "discriminating a carry bug from a correct carry");

    assert(m.faceMaterial[survivor] == 9001,
           format("plane `faceMaterial` did not follow its face across the "
                ~ "rewrite: face at centroid (%s) expected material 9001, "
                ~ "got %d", wantCentroid, m.faceMaterial[survivor]));
    assert(m.facePart[survivor] == 9002,
           format("plane `facePart` did not follow its face across the "
                ~ "rewrite: face at centroid (%s) expected part 9002, got %d",
                  wantCentroid, m.facePart[survivor]));
    assert(m.faceSelectionOrder[survivor] == 9003,
           format("plane `faceSelectionOrder` did not follow its face "
                ~ "across the rewrite: face at centroid (%s) expected order "
                ~ "9003, got %d", wantCentroid, m.faceSelectionOrder[survivor]));
    assert(m.faceSetMask[survivor] == 0x9004UL,
           format("plane `faceSetMask` did not follow its face across the "
                ~ "rewrite: face at centroid (%s) expected mask 0x9004, got "
                ~ "0x%x", wantCentroid, m.faceSetMask[survivor]));
    assert(m.faceMarks[survivor] == (Mesh.Marks.Select | Mesh.Marks.Hide),
           format("plane `faceMarks` did not follow its face across the "
                ~ "rewrite: face at centroid (%s) expected word %d, got %d",
                  wantCentroid, cast(int)(Mesh.Marks.Select | Mesh.Marks.Hide),
                  m.faceMarks[survivor]));
}

// ---------------------------------------------------------------------------
// L3 — vertices. The three `kVertPlanes` entries, same shape, tracked by
// POSITION across a middle-vertex drop.
// ---------------------------------------------------------------------------

unittest // rewriteVertices carries vertexMarks/vertexSelectionOrder/vertexSetMask, tracked by position across a middle-vertex drop
{
    Mesh m = makeGridPlane(3);      // 16 vertices, row-major vi = i*4 + j
    m.resetSelection();

    foreach (vi; 0 .. m.vertices.length) {
        m.vertexMarks[vi]          = (vi % 2 == 0) ? Mesh.Marks.Select : Mesh.Marks.Hide;
        m.vertexSelectionOrder[vi] = cast(int)(400 + vi);
        m.vertexSetMask[vi]        = cast(ulong)(1 + vi);
    }

    enum size_t tracked = 9;
    m.vertexMarks[tracked]          = Mesh.Marks.Select | Mesh.Marks.Subpatch;
    m.vertexSelectionOrder[tracked] = 9101;
    m.vertexSetMask[tracked]        = 0x9102UL;

    immutable Vec3 wantPos = m.vertices[tracked];

    // Drop vertex 5 — before `tracked` in array order — so the tracked
    // vertex's index shifts (9 -> 8). None of the dropped vertex's incident
    // faces are rewritten here; this test is about the PLANE CARRY on
    // `rewriteVertices` alone, independent of `faces`.
    enum size_t dropped = 5;
    static assert(dropped < tracked);

    Vec3[] newVerts;
    uint[] oldOfNew;
    foreach (vi; 0 .. m.vertices.length) {
        if (vi == dropped) continue;
        newVerts ~= m.vertices[vi];
        oldOfNew ~= cast(uint) vi;
    }
    assert(newVerts.length == m.vertices.length - 1, "fixture: exactly one vertex dropped");

    rewriteVertices(m, newVerts, VertSource(oldOfNew));

    immutable size_t survivor = vertByPosition(m, wantPos);
    assert(survivor != tracked,
           "the tracked vertex DID shift index (9 -> 8) — see the face-side "
         ~ "test above for why a tail drop cannot discriminate this");

    assert(m.vertexMarks[survivor] == (Mesh.Marks.Select | Mesh.Marks.Subpatch),
           format("plane `vertexMarks` did not follow its vertex across the "
                ~ "rewrite: vertex at %s expected word %d, got %d",
                  wantPos, cast(int)(Mesh.Marks.Select | Mesh.Marks.Subpatch),
                  m.vertexMarks[survivor]));
    assert(m.vertexSelectionOrder[survivor] == 9101,
           format("plane `vertexSelectionOrder` did not follow its vertex "
                ~ "across the rewrite: vertex at %s expected order 9101, "
                ~ "got %d", wantPos, m.vertexSelectionOrder[survivor]));
    assert(m.vertexSetMask[survivor] == 0x9102UL,
           format("plane `vertexSetMask` did not follow its vertex across "
                ~ "the rewrite: vertex at %s expected mask 0x9102, got 0x%x",
                  wantPos, m.vertexSetMask[survivor]));
}

// ---------------------------------------------------------------------------
// FaceSource length-mismatch guard (plan §9 risk table: "a length mismatch
// silently truncates a plane" — must be a loud `assert`, not silence).
// ---------------------------------------------------------------------------

unittest // rewriteFaces rejects a FaceSource whose length disagrees with newFaces
{
    import core.exception : AssertError;
    import std.exception  : assertThrown;

    Mesh m = makeGridPlane(2);      // 4 quads
    m.resetSelection();

    uint[][] newFaces = m.faces.dup;               // 4 faces
    uint[]   tooShort  = [0u, 1u, 2u];              // only 3 entries

    assertThrown!AssertError(
        rewriteFaces(m, newFaces, FaceSource(tooShort)),
        "rewriteFaces must assert when FaceSource.oldOfNew.length disagrees "
      ~ "with newFaces.length, not silently truncate a plane");
}
