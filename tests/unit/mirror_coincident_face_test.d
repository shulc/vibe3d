// Task 1560 — a mirror that maps geometry onto itself WELDS THE VERTICES AND
// LEAVES THE FACES DOUBLED, and that is the correct answer, not a defect.
//
// Every number below comes from `tests/fixtures/mirror_coincident_face_policy.json`,
// a frozen capture of the reference editor measured on 2026-08-20. The house
// rule is measure once -> freeze -> the fixture is the regression from then on:
// nothing in this file re-measures anything, and no external editor is in the
// loop.
//
// WHY THIS FILE EXISTS. Our nightly invariant fuzz lane reported 23 confirmed
// failures that all shrank to one cell — mirror on a default cube giving 8
// vertices / 12 edges / 12 faces with every edge four-valent and 6 faces
// doubled, tagged `nonmanifold_edge`. The reference produces exactly that mesh.
// Had we "fixed" it we would have broken the parity, so what changed was that
// lane's invariant (it lives in the private tree) and what landed here is the
// law it now checks against.
//
// WHY THE FACE-IN-PLANE CELL IS THE ONE THAT EARNS THE FILE. A duplicate-face
// taxonomy keyed on edge valence is STRUCTURALLY BLIND to a face lying IN the
// mirror plane: it doubles with ZERO non-manifold edges (4v / 4e / 2f, every
// edge two-valent). Nothing in the fuzz lane, and nothing in
// `tests/test_mesh_mirror.d`, could see that cell before this file.
//
// WHY A CUBE THROUGH ITS OWN SYMMETRY PLANE CANNOT PIN THE WINDING. The
// mirror's own polygon flip cancels the reflection's reversal on a CLOSED
// solid, so the six clones come back in the SAME winding as their originals
// (measured: face 6 is `[0,3,2,1]`, byte-identical to face 0). A rig built on
// that cell would "confirm" a winding sensitivity that is not there. The cells
// that do discriminate winding are the seam quad and the in-plane quad, whose
// pairs ARE reversed, plus the hand-built doubled cube in the collapse block.
//
// MUTATIONS THAT REDDEN THIS FILE (both RUN, not asserted — see the task log):
//   * append a duplicate-face collapse (`unifyFaces()`) to the tail of
//     `Mesh.mirrorFacesPlane` — i.e. "fix the bug". T1 goes 12 -> 6 faces and
//     T3, the in-plane cell, goes 2 -> 1. That is the mutation the valence
//     taxonomy could not see and this file can.
//   * perturb one number in the fixture (in-plane `result.faces` 2 -> 3). T3
//     reddens, which is what proves the expectation is READ from the file
//     rather than hardcoded beside it.
module tests.unit.mirror_coincident_face_test;

import std.json;
import std.file      : readText;
import std.algorithm : sort;
import std.conv      : to;
import std.format    : format;

import mesh;
import math;
import mesh_ops.cleanup;

// TASK 1903 Stage E1 — `unifyFaces` is a free function over
// `ref MeshEditBatch` now, so it cannot be called on a bare `Mesh`. UNRECORDED
// because nothing here reads an op-log (see source/mesh_ops/cleanup.d).
private size_t unifyOnce(ref Mesh m) {
    auto ed = MeshEditBatch.unrecorded(m, kCleanupEditScope);
    const n = ed.unifyFaces();
    ed.close();
    return n;
}

// ---------------------------------------------------------------------------
// The frozen fixture
// ---------------------------------------------------------------------------

// Hard assert on a missing/invalid file — no try/catch (task 1062 rule,
// precedent tests/unit/edge_crease_weight_test.d:67).
private JSONValue fixture()
{
    static JSONValue cached;
    static bool loaded = false;
    if (!loaded)
    {
        cached = parseJSON(readText("tests/fixtures/mirror_coincident_face_policy.json"));
        checkProvenance(cached);
        loaded = true;
    }
    return cached;
}

private void checkProvenance(JSONValue fx)
{
    assert("provenance" in fx, "mirror fixture: no provenance block");
    auto prov = fx["provenance"];
    assert("source" in prov && prov["source"].type == JSONType.string,
        "mirror fixture: provenance.source missing");
    assert("captured_utc" in prov && prov["captured_utc"].type == JSONType.string,
        "mirror fixture: provenance.captured_utc missing");
    // A fixture that lost its measurement date is a fixture nobody can retire.
    assert(prov["captured_utc"].str.length >= 10,
        "mirror fixture: provenance.captured_utc is not a date");
}

private JSONValue namedCase(string block, string name)
{
    foreach (c; fixture()[block].array)
        if (c["name"].str == name) return c;
    assert(false, "mirror fixture: no case '" ~ name ~ "' in " ~ block);
}

private JSONValue mirrorCase(string name)   { return namedCase("mirror_cases", name); }
private JSONValue collapseCase(string name) { return namedCase("collapse_law_cases", name); }

// ---------------------------------------------------------------------------
// Rigs, built FROM the fixture so the geometry cannot drift away from the
// geometry that was measured
// ---------------------------------------------------------------------------

private Mesh settle(Vec3[] vs, uint[][] fs)
{
    Mesh m;
    m.vertices = vs;
    m.faces = fs;
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    return m;
}

private Mesh rigMesh(string rigName)
{
    auto rig = fixture()["rigs"][rigName];
    Vec3[] vs;
    foreach (v; rig["vertices"].array)
    {
        auto a = v.array;
        vs ~= Vec3(cast(float) jnum(a[0]), cast(float) jnum(a[1]), cast(float) jnum(a[2]));
    }
    uint[][] fs;
    foreach (f; rig["faces"].array)
    {
        uint[] ring;
        foreach (i; f.array) ring ~= cast(uint) i.integer;
        fs ~= ring;
    }
    return settle(vs, fs);
}

private double jnum(JSONValue v)
{
    return v.type == JSONType.integer   ? cast(double) v.integer
         : v.type == JSONType.uinteger  ? cast(double) v.uinteger
         : v.floating;
}

/// Mirror the WHOLE mesh — which is also the "no selection" operand, since
/// `Mesh.operandFaceMask()` falls back to every visible face and the command
/// layer's empty-selection convention is pinned end-to-end by
/// `tests/test_mesh_mirror.d` (fixture case `no_selection`).
private void mirrorAll(ref Mesh m, Vec3 center, Vec3 normal, float weld)
{
    bool[] mask;
    mask.length = m.faces.length;
    mask[] = true;
    m.mirrorFacesPlane(mask, center, normal, weld, /*flipNormals*/ true);
}

// ---------------------------------------------------------------------------
// Topology readers
// ---------------------------------------------------------------------------

/// How many FACE RECORDS reference each undirected edge, bucketed by count.
/// This is the "edge_face_valence_histogram" the fixture records; a bucket
/// above 2 is a non-manifold edge.
private int[int] valenceHist(ref Mesh m)
{
    int[ulong] ecnt;
    foreach (f; m.faces)
        foreach (k; 0 .. f.length)
        {
            uint a = f[k], b = f[(k + 1) % f.length];
            ulong key = a < b ? (cast(ulong) a << 32) | b : (cast(ulong) b << 32) | a;
            ecnt[key] = ecnt.get(key, 0) + 1;
        }
    int[int] hist;
    foreach (c; ecnt.values) hist[c] = hist.get(c, 0) + 1;
    return hist;
}

/// The captured coincidence key: the cyclic ring up to ROTATION and REVERSAL,
/// on exact vertex INDICES. Not the vertex set (see the divergence block at the
/// end of this file) and not a position test — the fixture's
/// `coincident_but_unwelded` row pins that identical coordinates with their own
/// vertex records do not coincide at all.
private immutable(uint)[] canonicalRing(const uint[] ring)
{
    if (ring.length == 0) return null;
    immutable(uint)[] best;
    void consider(const uint[] seq)
    {
        foreach (k; 0 .. seq.length)
        {
            immutable(uint)[] rot = (seq[k .. $] ~ seq[0 .. k]).idup;
            if (best is null || rot < best) best = rot;
        }
    }
    consider(ring);
    uint[] rev;
    rev.length = ring.length;
    foreach (k, v; ring) rev[ring.length - 1 - k] = v;
    consider(rev);
    return best;
}

/// The same key WITHOUT the reversal leg, so winding is preserved and can be
/// compared. Used where the fixture records concrete rings.
private immutable(uint)[] rotationKey(const uint[] ring)
{
    if (ring.length == 0) return null;
    immutable(uint)[] best;
    foreach (k; 0 .. ring.length)
    {
        immutable(uint)[] rot = (ring[k .. $] ~ ring[0 .. k]).idup;
        if (best is null || rot < best) best = rot;
    }
    return best;
}

/// Face indices grouped by coincidence class, classes of one dropped.
private size_t[][immutable(uint)[]] coincidenceClasses(ref Mesh m)
{
    size_t[][immutable(uint)[]] all;
    foreach (i, f; m.faces) all[canonicalRing(f)] ~= i;
    size_t[][immutable(uint)[]] dup;
    foreach (k, v; all) if (v.length > 1) dup[k] = v;
    return dup;
}

private bool isReversalOf(const uint[] a, const uint[] b)
{
    if (a.length != b.length) return false;
    uint[] rev;
    rev.length = b.length;
    foreach (k, v; b) rev[b.length - 1 - k] = v;
    return rotationKey(a) == rotationKey(rev);
}

// ---------------------------------------------------------------------------
// The fixture comparison itself. Every mirror cell goes through here, so the
// expectation is READ from the file in one place and a perturbed fixture number
// reddens the cell that reads it.
// ---------------------------------------------------------------------------

private void assertMatchesFixture(string caseName, ref Mesh m)
{
    auto want = mirrorCase(caseName)["result"];
    assert(m.vertices.length == want["vertices"].integer,
        format("%s: vertices — fixture says %d, we produced %d",
               caseName, want["vertices"].integer, m.vertices.length));
    assert(m.edges.length == want["edges"].integer,
        format("%s: edges — fixture says %d, we produced %d",
               caseName, want["edges"].integer, m.edges.length));
    assert(m.faces.length == want["faces"].integer,
        format("%s: faces — fixture says %d, we produced %d. A face count BELOW "
               ~ "the fixture's is the signature of a duplicate-face collapse "
               ~ "somewhere on the mirror path, which the reference does not do.",
               caseName, want["faces"].integer, m.faces.length));

    if ("edge_face_valence_histogram" !in want) return;
    auto ours = valenceHist(m);
    auto theirs = want["edge_face_valence_histogram"];
    foreach (bucket, count; theirs.object)
    {
        int b = bucket.to!int;
        assert(b in ours && ours[b] == count.integer,
            format("%s: %d edge(s) should carry %s faces, we have %d",
                   caseName, count.integer, bucket, (b in ours) ? ours[b] : 0));
    }
    // And no bucket the fixture does not name — otherwise "the histogram
    // matches" would hold for a mesh with extra non-manifold edges on top.
    foreach (b, c; ours)
        assert(b.to!string in theirs.object,
            format("%s: %d edge(s) carry %d faces, a valence the fixture does "
                   ~ "not name at all", caseName, c, b));
}

// ---------------------------------------------------------------------------
// T1 — the cell the fuzz lane flagged. 8 / 12 / 12, every edge four-valent,
// six doubled faces, and the doubled pairs are the reference's own rings.
// ---------------------------------------------------------------------------
unittest
{
    auto m = rigMesh("cube");
    mirrorAll(m, Vec3(0, 0, 0), Vec3(1, 0, 0), 0.001f);
    assertMatchesFixture("self_coincident_merge_on", m);

    // Six coincidence classes, each exactly two deep: a doubled shell, not a
    // pile. `1 + copies` is the ceiling a single duplication pass can reach.
    auto classes = coincidenceClasses(m);
    assert(classes.length == 6,
        format("expected 6 doubled faces, found %d coincidence class(es)",
               classes.length));
    foreach (k, members; classes)
        assert(members.length == 2,
            format("coincidence class %s is %d deep; one duplication pass "
                   ~ "cannot stack more than 2", k, members.length));

    // The SIX NEW rings, against the reference's own list. Compared up to
    // rotation but NOT up to reversal, so this pins the winding too — and the
    // point of the cell is that the winding came back UNCHANGED.
    auto newRings = mirrorCase("self_coincident_merge_on")["new_face_rings"];
    immutable(uint)[][] wantKeys;
    foreach (r; newRings.array)
    {
        uint[] ring;
        foreach (i; r.array) ring ~= cast(uint) i.integer;
        wantKeys ~= rotationKey(ring);
    }
    immutable(uint)[][] gotKeys;
    foreach (i; 6 .. m.faces.length) gotKeys ~= rotationKey(m.faces[i]);
    sort(wantKeys);
    sort(gotKeys);
    assert(wantKeys == gotKeys,
        format("the six new rings differ from the reference's: want %s got %s",
               wantKeys, gotKeys));

    // The trap, asserted so it cannot be re-discovered: this cell CANNOT pin a
    // winding-sensitive rule, because every clone came back in the original
    // winding. T2/T3 are where winding is discriminated.
    bool anyReversed = false;
    foreach (k, members; classes)
        if (isReversalOf(m.faces[members[0]], m.faces[members[1]])
            && rotationKey(m.faces[members[0]]) != rotationKey(m.faces[members[1]]))
            anyReversed = true;
    assert(!anyReversed,
        "a closed solid mirrored through its own symmetry plane returns its "
        ~ "clones in the SAME winding — if this fires, the rig changed and the "
        ~ "'cube cannot discriminate winding' note above needs re-measuring");
}

// ---------------------------------------------------------------------------
// T1b — control: with the weld OFF nothing merges, so the same mirror gives two
// separate shells. Pins that the doubling in T1 is the WELD's doing and not the
// mirror inventing faces.
// ---------------------------------------------------------------------------
unittest
{
    auto m = rigMesh("cube");
    mirrorAll(m, Vec3(0, 0, 0), Vec3(1, 0, 0), 0.0f);
    assertMatchesFixture("self_coincident_merge_off", m);
    assert(coincidenceClasses(m).length == 0,
        "with no weld the two shells share no vertex record, so nothing "
        ~ "coincides");
}

// ---------------------------------------------------------------------------
// T2 — the seam. A cube spanning x in [0,1] mirrored at x = 0: four seam verts
// weld, the seam face is left DOUBLED with OPPOSITE winding, and exactly four
// edges go four-valent.
// ---------------------------------------------------------------------------
unittest
{
    auto m = rigMesh("cube_shifted");
    mirrorAll(m, Vec3(0, 0, 0), Vec3(1, 0, 0), 0.001f);
    assertMatchesFixture("seam_plane_touches_geometry", m);

    auto classes = coincidenceClasses(m);
    assert(classes.length == 1,
        format("exactly one face lies in the seam, so exactly one coincidence "
               ~ "class; found %d", classes.length));
    foreach (k, members; classes)
    {
        assert(members.length == 2, "the seam face is doubled, not tripled");
        assert(isReversalOf(m.faces[members[0]], m.faces[members[1]]),
            format("the seam pair must be wound OPPOSITE ways: %s vs %s",
                   m.faces[members[0]], m.faces[members[1]]));
        assert(rotationKey(m.faces[members[0]]) != rotationKey(m.faces[members[1]]),
            "a reversal that is also a rotation would make this cell blind to "
            ~ "winding, same trap as the cube in T1");
    }
}

// ---------------------------------------------------------------------------
// T3 — THE CELL THAT EARNS THIS FILE. A quad lying IN the mirror plane doubles
// with ZERO non-manifold edges: 4v / 4e / 2f, every edge two-valent. No
// valence-keyed duplicate detector can see it, so the frozen face COUNT is the
// only thing standing between us and a silent collapse here.
// ---------------------------------------------------------------------------
unittest
{
    auto m = rigMesh("plane_quad");
    mirrorAll(m, Vec3(0, 0, 0), Vec3(0, 0, 1), 0.001f);
    assertMatchesFixture("face_lying_in_the_mirror_plane", m);

    // Said again in the terms the fuzz lane speaks, because this is the exact
    // blindness the task turned on: the mesh carries a duplicated face and NOT
    // ONE non-manifold edge.
    auto hist = valenceHist(m);
    foreach (b, c; hist)
        assert(b <= 2,
            format("the in-plane cell must have zero non-manifold edges; %d "
                   ~ "edge(s) carry %d faces", c, b));

    auto classes = coincidenceClasses(m);
    assert(classes.length == 1 && classes.values[0].length == 2,
        "the in-plane face is doubled onto its own vertex records");
    assert(isReversalOf(m.faces[0], m.faces[1]),
        format("the in-plane pair IS reversed, so this cell discriminates "
               ~ "winding: %s vs %s", m.faces[0], m.faces[1]));

    // The reference's own two rings, up to rotation, winding preserved.
    auto want = mirrorCase("face_lying_in_the_mirror_plane")["face_rings"];
    immutable(uint)[][] wantKeys;
    foreach (r; want.array)
    {
        uint[] ring;
        foreach (i; r.array) ring ~= cast(uint) i.integer;
        wantKeys ~= rotationKey(ring);
    }
    immutable(uint)[][] gotKeys = [rotationKey(m.faces[0]), rotationKey(m.faces[1])];
    sort(wantKeys);
    sort(gotKeys);
    assert(wantKeys == gotKeys,
        format("in-plane rings differ from the reference's: want %s got %s",
               wantKeys, gotKeys));
}

// ---------------------------------------------------------------------------
// T4 — the control. The plane cuts the solid but nothing coincides, so nothing
// welds and nothing doubles. Without this cell the three above would pass just
// as well for a mirror that doubles EVERYTHING unconditionally.
// ---------------------------------------------------------------------------
unittest
{
    auto m = rigMesh("cube");
    mirrorAll(m, Vec3(0.25f, 0, 0), Vec3(1, 0, 0), 0.001f);
    assertMatchesFixture("plane_cuts_through_at_no_symmetry", m);
    assert(coincidenceClasses(m).length == 0,
        "nothing coincides at x = 0.25, so no face may be doubled");
    assert(m.faces.length == 2 * 6,
        "a duplication doubles the operand and collapses nothing");
}

// ---------------------------------------------------------------------------
// T5 — the collapse is a SEPARATE, explicitly invoked pass. Mirroring the cube
// and then running the duplicate-polygon collapse gives back the six ORIGINAL
// rings, verbatim: same order, same winding. Nothing is flipped or merged.
// ---------------------------------------------------------------------------
unittest
{
    auto m = rigMesh("cube");
    mirrorAll(m, Vec3(0, 0, 0), Vec3(1, 0, 0), 0.001f);
    const size_t removed = unifyOnce(m);

    auto want = mirrorCase("self_coincident_then_explicit_collapse")["result"];
    assert(removed == 6, format("expected 6 faces removed, got %d", removed));
    assert(m.vertices.length == want["vertices"].integer);
    assert(m.edges.length == want["edges"].integer);
    assert(m.faces.length == want["faces"].integer,
        format("after the explicit collapse the fixture says %d faces, we have %d",
               want["faces"].integer, m.faces.length));

    // The SURVIVOR is the earlier polygon, byte-identical — not a rotation of
    // it, not a reversal, the ring as written.
    auto rings = mirrorCase("self_coincident_then_explicit_collapse")["surviving_face_rings"];
    assert(rings.array.length == m.faces.length);
    foreach (i, r; rings.array)
    {
        uint[] ring;
        foreach (v; r.array) ring ~= cast(uint) v.integer;
        assert(m.faces[i] == ring,
            format("survivor %d: fixture says %s, we kept %s", i, ring, m.faces[i]));
    }
    // And the survivors are the cube's own faces, so the collapse kept the
    // EARLIER of each pair rather than the mirrored clone.
    auto orig = rigMesh("cube");
    foreach (i; 0 .. orig.faces.length)
        assert(m.faces[i] == orig.faces[i],
            "the collapse must keep the earlier polygon, untouched");
}

// ---------------------------------------------------------------------------
// The collapse law itself — the four rows our `unifyFaces` can express, plus
// the one it gets wrong (T9). These are live-parity rows on the same read, so
// the divergence assertion in T9 cannot be vacuous.
// ---------------------------------------------------------------------------

private Mesh doubledCube(string how)
{
    auto orig = rigMesh("cube");
    uint[][] fs = orig.faces.dup;
    foreach (f; orig.faces)
    {
        uint[] c;
        c.length = f.length;
        switch (how)
        {
            case "reversed": foreach (k, v; f) c[f.length - 1 - k] = v;      break;
            case "verbatim": foreach (k, v; f) c[k] = v;                     break;
            case "rotated":  foreach (k, v; f) c[(k + f.length - 1) % f.length] = v; break;
            default: assert(false, "unknown doubling: " ~ how);
        }
        fs ~= c;
    }
    return settle(orig.vertices.dup, fs);
}

// T6 — winding is IGNORED. The reference's own documentation says the two faces
// must "face the same direction"; the capture says otherwise, and so do we.
// The verbatim and rotated rows are the controls that make "winding-blind" mean
// blind rather than inverted, and "the start index does not matter".
unittest
{
    foreach (row; ["reversed_duplicates", "same_winding_duplicates",
                   "rotated_ring_duplicates"])
    {
        immutable how = row == "reversed_duplicates" ? "reversed"
                      : row == "same_winding_duplicates" ? "verbatim" : "rotated";
        auto m = doubledCube(how);
        auto c = collapseCase(row);
        assert(m.faces.length == c["before"]["faces"].integer,
            format("%s: rig should start at %d faces", row,
                   c["before"]["faces"].integer));
        unifyOnce(m);
        assert(m.faces.length == c["after"]["faces"].integer,
            format("%s: fixture says %d faces after the collapse, we have %d",
                   row, c["after"]["faces"].integer, m.faces.length));
        assert(m.vertices.length == c["after"]["vertices"].integer);
    }
}

// T7 — no positional term at all. Two complete cubes at IDENTICAL coordinates,
// each with its own vertex records, do not collapse: the test is vertex
// IDENTITY, and the only tolerance in the pipeline is the vertex weld's.
// The second half runs that weld and shows it does NOT remove the doubled
// faces either — weld and collapse are two independent passes.
unittest
{
    auto orig = rigMesh("cube");
    Vec3[] vs = orig.vertices.dup ~ orig.vertices.dup;
    uint[][] fs = orig.faces.dup;
    foreach (f; orig.faces)
    {
        uint[] g;
        g.length = f.length;
        foreach (k, v; f) g[k] = v + 8u;
        fs ~= g;
    }

    {
        auto m = settle(vs.dup, fs.dup);
        auto c = collapseCase("coincident_but_unwelded");
        assert(m.vertices.length == c["before"]["vertices"].integer);
        unifyOnce(m);
        assert(m.faces.length == c["after"]["faces"].integer,
            format("coincident_but_unwelded: fixture says %d faces survive, "
                   ~ "we have %d", c["after"]["faces"].integer, m.faces.length));
        assert(m.vertices.length == c["after"]["vertices"].integer);
    }
    {
        auto m = settle(vs.dup, fs.dup);
        auto c = collapseCase("weld_then_collapse");
        m.weldCoincidentVertices(1e-12);
        // The weld REMAPS; it does not compact. The mirror path pairs it with
        // `compactUnreferenced()` for exactly this reason, so the rig does the
        // same — otherwise the 8 welded-away slots stay as orphans and the
        // vertex count reads 16 for a mesh that has 8 distinct corners.
        m.compactUnreferenced();
        m.rebuildEdgesFromFaces();
        auto w = c["after_vertex_weld"];
        assert(m.vertices.length == w["vertices"].integer,
            format("weld_then_collapse: fixture says %d verts after the weld, "
                   ~ "we have %d", w["vertices"].integer, m.vertices.length));
        assert(m.edges.length == w["edges"].integer);
        assert(m.faces.length == w["faces"].integer,
            "THE VERTEX WELD ALONE DOES NOT REMOVE THE DOUBLED FACES — this is "
            ~ "the ownership claim the whole task turned on");
        auto hist = valenceHist(m);
        foreach (bucket, count; w["edge_face_valence_histogram"].object)
        {
            int b = bucket.to!int;
            assert(b in hist && hist[b] == count.integer,
                format("weld_then_collapse: %d edge(s) should carry %s faces",
                       count.integer, bucket));
        }
        unifyOnce(m);
        assert(m.faces.length == c["after_collapse"]["faces"].integer,
            "and the collapse, run separately, is what removes them");
    }
}

// T8 — a shared MAJORITY of vertices is not a collapse. Two quads on three of
// four shared vertices are two different polygons and both survive.
unittest
{
    auto m = settle([Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0),
                     Vec3(0, 1, 0), Vec3(2, 0, 0)],
                    [[0u, 1u, 2u, 3u], [0u, 1u, 2u, 4u]]);
    auto c = collapseCase("partial_overlap");
    assert(m.faces.length == c["before"]["faces"].integer);
    unifyOnce(m);
    assert(m.faces.length == c["after"]["faces"].integer,
        format("partial_overlap: fixture says %d faces survive, we have %d",
               c["after"]["faces"].integer, m.faces.length));
}

// ---------------------------------------------------------------------------
// T9 — SELF-RETIRING DIVERGENCE MARKER.
//
// The captured law keys the collapse on the cyclic RING (up to rotation and
// reversal). Our `unifyFaces` (source/mesh_ops/cleanup.d) keys it on the
// sorted vertex SET, so it
// merges two polygons that share four vertices in an order that is neither a
// rotation nor a reversal — one convex quad and one self-crossing one, which
// the reference leaves alone.
//
// The marker is not a skip. It asserts BOTH halves, gap-closed condition FIRST:
// the day someone re-keys `unifyFaces` on the ring, this test fails saying so
// and asks to be retired (flip `status` to "closed"); until then an unrelated
// regression in the same call is red too, because the second half pins what we
// do today.
// ---------------------------------------------------------------------------
unittest
{
    auto c = collapseCase("same_vertex_set_different_ring");
    auto div = fixture()["classification"]["divergences"]["collapse_key_is_the_vertex_set"];
    immutable status = div["status"].str;
    assert(status == "open" || status == "closed",
        "divergence status must be exactly 'open' or 'closed', got '" ~ status ~ "'");

    auto m = settle([Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)],
                    [[0u, 1u, 2u, 3u], [0u, 2u, 1u, 3u]]);
    assert(m.faces.length == c["before"]["faces"].integer);
    unifyOnce(m);

    const long reference = c["after"]["faces"].integer;
    const long oursFrozen = div["vibe3d_faces_after"].integer;

    if (status == "open")
    {
        // (1) the gap-closed condition, checked FIRST: both fire on the same
        //     convergence and whichever runs first writes the message.
        assert(m.faces.length != reference,
            format("DIVERGENCE CLOSED: `unifyFaces` now agrees with the "
                   ~ "reference (%d faces survive). Retire the marker — set "
                   ~ "classification.divergences.collapse_key_is_the_vertex_set"
                   ~ ".status to \"closed\" and re-freeze vibe3d_faces_after.",
                   reference));
        // (2) and this is what we do today, so an unrelated regression is red.
        assert(m.faces.length == oursFrozen,
            format("open divergence: we keyed on the vertex set and should be "
                   ~ "left with %d face(s), got %d", oursFrozen, m.faces.length));
        // (3) coupling — a marked divergence must record DIFFERENT numbers, so
        //     re-arming the flag to silence a regression is unsatisfiable.
        assert(oursFrozen != reference,
            "an OPEN divergence whose two frozen numbers agree is a marker that "
            ~ "can never fire");
    }
    else
    {
        assert(m.faces.length == reference,
            format("retired divergence: the collapse must now key on the ring, "
                   ~ "leaving %d face(s); got %d", reference, m.faces.length));
        assert(oursFrozen == reference,
            "a CLOSED divergence must record the reference's own number");
    }
}
