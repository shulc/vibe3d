// mesh_edit_delta_face_reindex_test — Stage H tests for `Kind.FaceReindex`
// (task 1902, `doc/reindex_primitive_plan.md` §7.4).
//
// The mechanism must be EXERCISED, not merely declared (plan §7.1): every
// test here arms `MeshEditTracker.wantsFaceReindex` on a test-local
// recorder and drives a REAL `mesh_planes.rewriteFaces` call — no production
// site does this (the flag defaults false and stays false everywhere in
// this task), so these are the only place `Kind.FaceReindex` is ever
// produced.
//
// SCOPE. Two planes, not one. The five `kFacePlanes` entries by value (task
// 1902 Stage H) AND the PolyVertex (UV) corner plane (task 1903 Stage J,
// which added `CornerCarry`'s `Kind.FaceReindex` case — before it, both
// `applyFaceReindex*` dropped the corner map unconditionally and this
// header said so). `makeTaggedGrid` carries a live UV map with one distinct
// value per corner, so a value that lands on the wrong corner is visible
// rather than merely length-correct.
//
// The corner tests need the fixture's rewrite to DECLARE a carry, which is
// why `buildFixture` opens a `beginCornerRewrite()` handle and passes it to
// `rewriteFaces` (the shape `extrudeFacesByMask` and `insertEdgeLoopsMulti`
// — the two `&rw` production sites Stage K arms — already use). Without it
// the live rewrite leaves the map in the OLD corner space, `CornerCarry`
// declines at replay entry for that reason alone, and every corner
// assertion below would be measuring the decline instead of the carry.
//
// WHAT THE FORWARD (redo) ORACLE HERE DOES **NOT** PIN, and Stage K must not
// read it as pinning (review round 1, MINOR-4). Two of the corner tests below
// assert the replayed map equals the live one BYTE FOR BYTE. That is exact
// here only because neither fixture passes a `blendOfNewVertex` table or a
// `PolyVertexGen` list to its rewrite, so the live op's own answer is pure
// vertex-matched carry — which is the one thing the entry CAN reproduce. At a
// real `&rw` site both are present and the forward replay is deliberately
// lossy: measured, `extrudeFacesByMask` on a 9-quad grid redoes 32 of 52
// corners exactly, the remaining 20 being the cap's blend corners and the
// walls' `SweepU`-generated ones. Undo is exact at both sites (36/36, 24/24)
// because it reads the recorded payload instead of inverting the
// correspondence. "Redo is byte-exact" is a property of THESE STANDS, not of
// the mechanism; the mechanism's redo remainder is recorded in the task card.
module tests.unit.mesh_edit_delta_face_reindex_test;

import mesh;
import mesh_planes;
import mesh_edit_delta;
import math : Vec3;
import core.exception : AssertError;
import std.format : format;
import std.conv : to;
import tests.unit.fixtures : makeTaggedGrid;

// ---------------------------------------------------------------------------
// Local helpers — deliberately NOT shared with mesh_planes_test.d's
// near-identical pair (that file's own header states why: this file's
// oracle must stay independently readable).
// ---------------------------------------------------------------------------

private Vec3 centroidOf(ref Mesh m, size_t fi) {
    Vec3 c = Vec3(0, 0, 0);
    auto f = m.faces[fi];
    foreach (vid; f) c = c + m.vertices[vid];
    return Vec3(c.x / f.length, c.y / f.length, c.z / f.length);
}

private size_t faceByCentroid(ref Mesh m, Vec3 target, double tol = 1e-4) {
    foreach (fi; 0 .. m.faces.length)
        if ((centroidOf(m, fi) - target).length < tol) return fi;
    assert(false, "no face at the expected centroid (" ~ target.to!string ~ ")");
}

private struct PlaneSnap { uint mat, prt; uint marks; int ord; ulong setMsk; }

private PlaneSnap snapAt(ref Mesh m, size_t fi) {
    return PlaneSnap(m.faceMaterial[fi], m.facePart[fi], m.faceMarks[fi],
                     m.faceSelectionOrder[fi], m.faceSetMask[fi]);
}

// Checks all FIVE kFacePlanes entries by value, including the whole
// `faceMarks` word — valid for a survivor/duplicate (exact carry both
// directions) and for forward replay (the post-mesh oracle), but NOT for a
// face restored from the drop set, where only Subpatch is carried (see the
// reverse test's own comment for why, and its separate manual asserts).
private void assertPlanesEq(PlaneSnap got, PlaneSnap want, string tag) {
    assert(got.mat == want.mat,
           format("%s: faceMaterial expected %d, got %d", tag, want.mat, got.mat));
    assert(got.prt == want.prt,
           format("%s: facePart expected %d, got %d", tag, want.prt, got.prt));
    assert(got.marks == want.marks,
           format("%s: faceMarks expected %d, got %d", tag, want.marks, got.marks));
    assert(got.ord == want.ord,
           format("%s: faceSelectionOrder expected %d, got %d", tag, want.ord, got.ord));
    assert(got.setMsk == want.setMsk,
           format("%s: faceSetMask expected %d, got %d", tag, want.setMsk, got.setMsk));
}

// ---------------------------------------------------------------------------
// Shared fixture builder: makeTaggedGrid() (9 faces, every kFacePlanes
// entry non-uniform) rewritten so old face 4 (the grid's middle) is
// DROPPED, old face 0 is DUPLICATED into two new faces (winding-identical
// to its ancestor both times — see the reverse test below for why an exact
// duplicate is the right choice here), and one brand-new face is CREATED
// over three fresh vertices (`kNoSource`) — all three destructive shapes
// §7.4 asks for, in a single entry.
// ---------------------------------------------------------------------------

private struct Fixture {
    Mesh m;
    MeshEditDelta delta;
    Vec3[9]      oldCentroid;
    PlaneSnap[9] oldPlane;
    bool[9]      oldHadSubpatch;   // isFaceSubpatch(of), captured pre-rewrite
    float[][9]   oldUv;            // per-corner UV of each OLD face, pre-rewrite
    float[]      postUv;           // the WHOLE map right after the live rewrite
}

// The NEW-face indices `buildFixture` produces, by construction: the seven
// survivors (old 1,2,3,5,6,7,8) at 0..6, then the two duplicates of old face
// 0, then the created face. Named rather than re-derived, because a forward
// replay re-runs the SAME `rewriteFaces` call with the SAME lists, so the
// order is part of the entry, not a coincidence to look up by centroid.
private enum uint kDupA    = 7;
private enum uint kDupB    = 8;
private enum uint kCreated = 9;
/// new index -> old index for the seven survivors, in fixture order.
private immutable uint[7] kSurvivorOld = [1, 2, 3, 5, 6, 7, 8];

// This face's corner values, as a fresh array (the map's own storage moves
// under every rebuild, so a slice would dangle across a replay).
private float[] uvOfFace(ref Mesh m, size_t fi) {
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null, "the stand must carry a PolyVertex map");
    assert(fi < m.faceLoop.length, "uvOfFace: face index out of range");
    const size_t base = m.faceLoop[fi];
    const size_t n    = m.faces[fi].length;
    return uv.data[base * uv.dim .. (base + n) * uv.dim].dup;
}

private void assertUvEq(in float[] got, in float[] want, string tag) {
    assert(got.length == want.length,
           format("%s: expected %d corner floats, got %d",
                  tag, want.length, got.length));
    foreach (i; 0 .. want.length)
        assert(got[i] == want[i],
               format("%s: corner float %d expected %s, got %s",
                      tag, i, want[i].to!string, got[i].to!string));
}

private Fixture buildFixture(bool armed) {
    Fixture fx;
    fx.m = makeTaggedGrid();
    assert(fx.m.faces.length == 9, "fixture: makeTaggedGrid is a 3x3 grid");

    // makeTaggedGrid stamps faceSelectionOrder on faces 2/6/7 only, leaving
    // the dropped face (4, below) at the default 0 — indistinguishable from
    // an entry that carries NO order for the drop set at all (both read 0).
    // Stamp it explicitly so a dropped `faceOrd` is a discriminating
    // mutation (§8 M8), not a coincidence.
    fx.m.faceSelectionOrder[4] = 999;

    foreach (fi; 0 .. 9) {
        fx.oldCentroid[fi]     = centroidOf(fx.m, fi);
        fx.oldPlane[fi]        = snapAt(fx.m, fi);
        fx.oldHadSubpatch[fi]  = fx.m.isFaceSubpatch(fi);
        fx.oldUv[fi]           = uvOfFace(fx.m, fi);
    }

    // A brand-new face over three NEW vertices, far from the grid so its
    // centroid cannot collide with any surviving/duplicated face.
    immutable uint nv0 = fx.m.addVertex(Vec3(100, 0, 0));
    immutable uint nv1 = fx.m.addVertex(Vec3(101, 0, 0));
    immutable uint nv2 = fx.m.addVertex(Vec3(100, 1, 0));

    uint[][] newFaces;
    uint[]   oldOfNew;
    foreach (fi; 0 .. 9) {
        if (fi == 4 || fi == 0) continue;   // dropped / duplicated, handled below
        newFaces ~= fx.m.faces[fi].dup;
        oldOfNew ~= cast(uint) fi;
    }
    newFaces ~= fx.m.faces[0].dup; oldOfNew ~= 0u;   // duplicate #1
    newFaces ~= fx.m.faces[0].dup; oldOfNew ~= 0u;   // duplicate #2
    newFaces ~= [nv0, nv1, nv2];   oldOfNew ~= kNoSource;   // create

    assert(newFaces.length == 10, "fixture: 7 survivors + 2 duplicates + 1 created");

    MeshEditTracker tracker;
    tracker.wantsFaceReindex = armed;
    fx.m.beginEditBatch(&tracker, MeshEditScope.Polygons);
    {
        // The corner-provenance handle, opened and passed through exactly as
        // the two production `&rw` sites do. It must outlive the call (its
        // destructor disarms the mesh), hence the block rather than a
        // temporary.
        auto rw = fx.m.beginCornerRewrite();
        rewriteFaces(fx.m, newFaces, FaceSource(oldOfNew), &rw);
    }
    // What every real kernel does at its tail, and what CONSUMES the
    // declaration just made: without it the pending `Carried` provenance
    // would survive into the replay's own `buildLoops` and be judged against
    // a corner space it never described.
    fx.m.rebuildEdges();
    fx.m.buildLoops();
    fx.delta = fx.m.endEditBatch();

    fx.postUv = fx.m.meshMap(kUvMapName).data.dup;

    return fx;
}

// ---------------------------------------------------------------------------
// (1)+(2) armed recorder, driven through drop+duplicate+create.
// ---------------------------------------------------------------------------

unittest // armed: exactly one FaceReindex entry is recorded for one rewriteFaces call
{
    auto fx = buildFixture(/*armed=*/true);
    // TWO entries, not one, since task 1903 Stage J: the corner PAYLOAD
    // (`Kind.MeshMapDelta`, the pre-rewrite per-corner values of every old
    // face) immediately followed by the face entry itself. The adjacency is
    // not decoration — `CornerCarry.payloadForCount` pairs the two by "the
    // MeshMapDelta immediately before, covering exactly `oldFaceCount`
    // faces", so an entry recorded between them would silently unpair the
    // corner restore and the UV assertions below would go quiet.
    assert(fx.delta.log.length == 2,
           format("expected the corner payload + the face entry for one "
                ~ "rewriteFaces call, got %d entries", fx.delta.log.length));
    assert(fx.delta.log[0].kind == MeshOpEntry.Kind.MeshMapDelta,
           "the corner payload must be recorded FIRST, immediately before "
         ~ "the face entry it belongs to");
    assert(fx.delta.log[0].mapArity.length == 9,
           format("the payload must cover every OLD face (9), got %d",
                  fx.delta.log[0].mapArity.length));
    assert(fx.delta.log[1].kind == MeshOpEntry.Kind.FaceReindex,
           "the second recorded entry must be Kind.FaceReindex");
    assert(fx.delta.log[1].oldFaceCount == 9,
           format("oldFaceCount must be the pre-rewrite face count (9), got %d",
                  fx.delta.log[1].oldFaceCount));
    // The drop set names exactly the ONE old index no new face names: 4.
    assert(fx.delta.log[1].fIdx.length == 1 && fx.delta.log[1].fIdx[0] == 4,
           "drop set must name exactly old face 4");
}

unittest // (3) forward replay reproduces the post-mesh, plane for plane
{
    auto fx = buildFixture(/*armed=*/true);

    // Oracle: the live mesh RIGHT AFTER rewriteFaces (== "the post-mesh").
    immutable size_t postCount = fx.m.faces.length;
    Vec3[]      wantCentroid = new Vec3[](postCount);
    PlaneSnap[] wantPlane    = new PlaneSnap[](postCount);
    foreach (nf; 0 .. postCount) {
        wantCentroid[nf] = centroidOf(fx.m, nf);
        wantPlane[nf]    = snapAt(fx.m, nf);
    }

    // Round-trip through the tracker: undo the batch, then redo it. Forward
    // replay (apply/redo) must reproduce the oracle above exactly — this is
    // the realistic path (redo always follows an undo in this system), and
    // a stricter test than calling apply() on an arbitrarily corrupted mesh.
    fx.delta.revert(fx.m);
    fx.delta.apply(fx.m);

    assert(fx.m.faces.length == postCount,
           format("forward replay: expected %d faces, got %d",
                  postCount, fx.m.faces.length));
    foreach (nf; 0 .. postCount) {
        immutable size_t got = faceByCentroid(fx.m, wantCentroid[nf]);
        assertPlanesEq(snapAt(fx.m, got), wantPlane[nf],
                       format("forward replay, new face %d (centroid %s)",
                              nf, wantCentroid[nf]));
    }
}

unittest // (4) reverse restores the pre-mesh, plane for plane, by centroid
{
    auto fx = buildFixture(/*armed=*/true);

    fx.delta.revert(fx.m);

    assert(fx.m.faces.length == 9,
           format("reverse: expected the pre-rewrite face count (9), got %d",
                  fx.m.faces.length));

    // Survivors + the duplicate's source (old faces 1,2,3,5,6,7,8 and 0) —
    // every old index EXCEPT the dropped one (4) — restore from the LIVE
    // (post-reindex) mesh at their first naming new index (plan §7.2).
    foreach (of; 0 .. 9) {
        if (of == 4) continue;   // the drop set — checked separately below
        immutable size_t got = faceByCentroid(fx.m, fx.oldCentroid[of]);
        assertPlanesEq(snapAt(fx.m, got), fx.oldPlane[of],
                       format("reverse, old face %d (centroid %s)",
                              of, fx.oldCentroid[of]));
    }

    // The drop set (old face 4): restored from the entry's own captured
    // planes, not from the live mesh (it has no live representative at
    // all). faceMarks is NOT asserted here beyond Subpatch — RemoveFaces's
    // reverse has never restored Select/Hide for a re-inserted face (only
    // its own module-level doc comment claims this; see
    // removeFacesReverse's comment in mesh_edit_delta.d), and FaceReindex
    // reuses that exact same drop-set shape rather than inventing a wider
    // contract this task did not set out to build.
    immutable size_t droppedNow = faceByCentroid(fx.m, fx.oldCentroid[4]);
    assert(fx.m.faceMaterial[droppedNow] == fx.oldPlane[4].mat,
           "reverse: dropped face must restore its own material");
    assert(fx.m.facePart[droppedNow] == fx.oldPlane[4].prt,
           "reverse: dropped face must restore its own part");
    assert(fx.m.faceSelectionOrder[droppedNow] == fx.oldPlane[4].ord,
           "reverse: dropped face must restore its own faceSelectionOrder "
         ~ "(task 1902 Stage H — RemoveFaces did not carry this before)");
    assert(fx.m.faceSetMask[droppedNow] == fx.oldPlane[4].setMsk,
           "reverse: dropped face must restore its own faceSetMask");
    assert(fx.m.isFaceSubpatch(droppedNow) == fx.oldHadSubpatch[4],
           "reverse: dropped face must restore its own Subpatch bit");
}

unittest // (5) disarmed: an op whose flag is OFF records NO FaceReindex entry
{
    auto fx = buildFixture(/*armed=*/false);
    assert(fx.delta.log.length == 0,
           format("an op with FaceReindex disabled recorded %d entry(ies), "
                ~ "expected 0", fx.delta.log.length));
}

// M10-discriminating companion. `buildFixture`'s "disarmed" case above sets
// `tracker.wantsFaceReindex = false` EXPLICITLY, so it cannot see the
// DEFAULT flip §8's M10 names ("flip wantsFaceReindex default to true
// without changing anything else") — an explicit assignment overwrites
// whatever the field's own default was, either way. This test relies on
// the default alone: no production call site (mesh.d's 12, extrude.d's 9)
// ever touches `wantsFaceReindex` either, so this is also the shape that
// actually matches how the flag reaches production code (plan §7.1).
unittest // a DEFAULT-CONSTRUCTED recorder — never touching wantsFaceReindex — records no FaceReindex entry
{
    Mesh m = makeTaggedGrid();
    uint[][] sameFaces = m.faces.dup;

    MeshEditTracker tracker;   // default-constructed; wantsFaceReindex untouched
    m.beginEditBatch(&tracker, MeshEditScope.Polygons);
    rewriteFaces(m, sameFaces, FaceSource.identity(sameFaces.length));
    MeshEditDelta delta = m.endEditBatch();

    assert(delta.log.length == 0,
           format("a default-constructed MeshEditTracker recorded %d "
                ~ "FaceReindex entry(ies) — wantsFaceReindex's default must "
                ~ "be false (plan §7.1: no production site opts in)",
                  delta.log.length));
}

// M7-discriminating fixture. §7.2 forbids deriving `oldFaceCount` as
// `max(faceOldOfNew)+1`: that derivation is right only when the highest old
// index was NOT the one dropped. The main round-trip fixture above drops a
// MIDDLE face (old 4) while old face 8 — the highest index — survives, so
// `max(faceOldOfNew)+1` would read 9 there too (8 survives, 8+1==9) and
// M7 would pass ACCIDENTALLY (measured, not assumed — this is exactly the
// "a middle-only drop leaves the derivation accidentally right" case §7.2
// itself names). This fixture drops the LAST old index instead, so a
// max-derived count would read 8, one short.
unittest // reverse: oldFaceCount cannot be derived from faceOldOfNew when the DROPPED face is the highest old index
{
    Mesh m = makeTaggedGrid();
    assert(m.faces.length == 9, "fixture: makeTaggedGrid is a 3x3 grid");

    // Drop old face 8 (the LAST / highest index); every other old face
    // survives at its own identity new index.
    uint[][] newFaces;
    uint[]   oldOfNew;
    foreach (fi; 0 .. 8) {   // 0..7, old face 8 excluded
        newFaces ~= m.faces[fi].dup;
        oldOfNew ~= cast(uint) fi;
    }
    assert(newFaces.length == 8, "fixture: 8 survivors, old face 8 dropped");

    MeshEditTracker tracker;
    tracker.wantsFaceReindex = true;
    m.beginEditBatch(&tracker, MeshEditScope.Polygons);
    rewriteFaces(m, newFaces, FaceSource(oldOfNew));
    MeshEditDelta delta = m.endEditBatch();

    // [payload, FaceReindex] — see test (1) for why the payload is there.
    assert(delta.log.length == 2 && delta.log[1].kind == MeshOpEntry.Kind.FaceReindex);
    assert(delta.log[1].oldFaceCount == 9,
           format("the recorded oldFaceCount must be the true pre-rewrite "
                ~ "count (9), got %d", delta.log[1].oldFaceCount));

    delta.revert(m);
    assert(m.faces.length == 9,
           format("revert restored %d faces, expected 9 — the highest old "
                ~ "face was dropped, so the correspondence cannot name it",
                  m.faces.length));
}

// ---------------------------------------------------------------------------
// Review finding B2 (task 1902 Stage H review, 2026-08-25): a SURVIVOR's
// winding read off the live mesh at reverse time is the POST-rewrite one —
// not always the PRE-rewrite one this entry must restore. `Mesh.
// removeVertsByMask`'s shape (`oldOfNew ~= fi` with a SHORTER winding, one
// corner dropped) is reproduced directly: face 0 keeps its own old index but
// loses a corner.
// ---------------------------------------------------------------------------
unittest // reverse: a SURVIVOR's PRE-rewrite winding must be restored, not its post-rewrite one
{
    Mesh m = makeTaggedGrid();
    assert(m.faces.length == 9, "fixture: makeTaggedGrid is a 3x3 grid");

    uint[] oldWinding0 = m.faces[0].dup;
    assert(oldWinding0.length == 4,
           "fixture: makeGridPlane(3) faces are quads (arity 4)");

    // Identity correspondence for every face EXCEPT face 0, whose new
    // winding drops its 4th corner (arity 4 -> 3) while keeping its own old
    // index (a KEPT face, not a drop/duplicate/create).
    uint[][] newFaces;
    uint[]   oldOfNew;
    foreach (fi; 0 .. 9) {
        newFaces ~= (fi == 0) ? [oldWinding0[0], oldWinding0[1], oldWinding0[2]]
                              : m.faces[fi].dup;
        oldOfNew ~= cast(uint) fi;
    }

    MeshEditTracker tracker;
    tracker.wantsFaceReindex = true;
    m.beginEditBatch(&tracker, MeshEditScope.Polygons);
    rewriteFaces(m, newFaces, FaceSource(oldOfNew));
    MeshEditDelta delta = m.endEditBatch();

    assert(m.faces[0].length == 3,
           format("setup: face 0 must have been rewritten to arity 3, got %d",
                  m.faces[0].length));

    delta.revert(m);

    assert(m.faces.length == 9, "reverse: face count must be restored");
    assert(m.faces[0].length == 4,
           format("reverse restored a SURVIVOR's post-rewrite winding — "
                ~ "arity %d expected 4", m.faces[0].length));
    assert(m.faces[0] == oldWinding0,
           format("reverse: survivor face 0 must restore its exact "
                ~ "PRE-rewrite winding %s, got %s",
                  oldWinding0.to!string, m.faces[0].to!string));
}

// ---------------------------------------------------------------------------
// Review finding B3 (task 1902 Stage H review, 2026-08-25):
// `recordFaceReindex`'s no-op guard used to fire on `oldOfNew.length == 0 &&
// newFaceLists.length == 0` — true both for a genuine no-op (0 faces in, 0
// out) AND for the DESTRUCTIVE case of dropping every face (select-all +
// delete), which lost the whole drop set. This drives exactly that rewrite
// (9 faces -> 0) and checks recording, reverse, and forward re-apply.
// ---------------------------------------------------------------------------
unittest // rewrite to ZERO faces (drop every face): one entry recorded, revert restores all, forward re-drops
{
    Mesh m = makeTaggedGrid();
    assert(m.faces.length == 9, "fixture: makeTaggedGrid is a 3x3 grid");

    Vec3[9]      oldCentroid;
    PlaneSnap[9] oldPlane;
    bool[9]      oldHadSubpatch;
    foreach (fi; 0 .. 9) {
        oldCentroid[fi]    = centroidOf(m, fi);
        oldPlane[fi]       = snapAt(m, fi);
        oldHadSubpatch[fi] = m.isFaceSubpatch(fi);
    }

    uint[][] noFaces;
    uint[]   noOld;

    MeshEditTracker tracker;
    tracker.wantsFaceReindex = true;
    m.beginEditBatch(&tracker, MeshEditScope.Polygons);
    rewriteFaces(m, noFaces, FaceSource(noOld));
    MeshEditDelta delta = m.endEditBatch();

    assert(m.faces.length == 0, "setup: every face dropped");
    assert(delta.log.length == 2,
           format("review finding B3: dropping every face must still "
                ~ "record the corner payload + ONE FaceReindex entry, not "
                ~ "zero — got %d", delta.log.length));
    assert(delta.log[1].kind == MeshOpEntry.Kind.FaceReindex);
    assert(delta.log[1].fIdx.length == 9,
           format("the drop set must name all 9 old faces, got %d",
                  delta.log[1].fIdx.length));

    delta.revert(m);
    assert(m.faces.length == 9,
           format("B3 revert must restore all 9 faces, got %d", m.faces.length));

    // Same documented drop-set limit test (4) above exercises: material /
    // part / faceSelectionOrder / faceSetMask / Subpatch by value, NOT the
    // whole faceMarks word (Select/Hide are not captured by this entry).
    foreach (of; 0 .. 9) {
        immutable size_t got = faceByCentroid(m, oldCentroid[of]);
        assert(m.faceMaterial[got] == oldPlane[of].mat,
               format("B3 revert, old face %d: material expected %d, got %d",
                      of, oldPlane[of].mat, m.faceMaterial[got]));
        assert(m.facePart[got] == oldPlane[of].prt,
               format("B3 revert, old face %d: part expected %d, got %d",
                      of, oldPlane[of].prt, m.facePart[got]));
        assert(m.faceSelectionOrder[got] == oldPlane[of].ord,
               format("B3 revert, old face %d: faceSelectionOrder expected "
                    ~ "%d, got %d", of, oldPlane[of].ord, m.faceSelectionOrder[got]));
        assert(m.faceSetMask[got] == oldPlane[of].setMsk,
               format("B3 revert, old face %d: faceSetMask expected %d, got %d",
                      of, oldPlane[of].setMsk, m.faceSetMask[got]));
        assert(m.isFaceSubpatch(got) == oldHadSubpatch[of],
               format("B3 revert, old face %d: Subpatch bit expected %s, got %s",
                      of, oldHadSubpatch[of], m.isFaceSubpatch(got)));
    }

    delta.apply(m);
    assert(m.faces.length == 0,
           format("B3 forward re-apply must drop every face again, got %d",
                  m.faces.length));
}

// ---------------------------------------------------------------------------
// Review finding S4 (task 1902 Stage H review, 2026-08-25):
// `applyFaceReindexReverse` used to open with `if (e.oldFaceCount == 0)
// return;`, making undo of a rewrite FROM an empty face array a no-op — the
// created faces were left behind instead of the mesh truncating back to 0.
// ---------------------------------------------------------------------------
unittest // reverse of a rewrite FROM an empty mesh (oldFaceCount == 0) must truncate back to 0 faces
{
    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0),
                  Vec3(2, 0, 0), Vec3(3, 0, 0), Vec3(2, 1, 0)];
    m.buildLoops();
    m.syncSelection();
    assert(m.faces.length == 0, "fixture: starts with zero faces");

    uint[][] newFaces = [[0u, 1u, 2u], [3u, 4u, 5u]];
    uint[]   oldOfNew = [kNoSource, kNoSource];   // both CREATED, no ancestor

    MeshEditTracker tracker;
    tracker.wantsFaceReindex = true;
    m.beginEditBatch(&tracker, MeshEditScope.Polygons);
    rewriteFaces(m, newFaces, FaceSource(oldOfNew));
    MeshEditDelta delta = m.endEditBatch();

    assert(m.faces.length == 2, "setup: two faces created");
    // ONE entry here, unlike the `makeTaggedGrid` fixtures above: this mesh
    // carries no PolyVertex map at all, so `recordPolyVertexPayload` returns
    // on its own first guard and no payload is recorded. That the payload is
    // paid for only when there is something to save is the point.
    assert(delta.log.length == 1 && delta.log[0].kind == MeshOpEntry.Kind.FaceReindex);
    assert(delta.log[0].oldFaceCount == 0,
           format("the recorded oldFaceCount must be the true pre-rewrite "
                ~ "count (0), got %d", delta.log[0].oldFaceCount));

    delta.revert(m);
    assert(m.faces.length == 0,
           format("review finding S4: revert of a rewrite FROM an empty "
                ~ "mesh must truncate every plane back to 0 faces — left %d "
                ~ "faces behind", m.faces.length));
    // NIT (task 1902 Stage H review): the assertion above only checked
    // `m.faces` itself. `applyFaceReindexReverse` assigns every one of the
    // five `kFacePlanes` arrays independently (restFaces/restMarks/restMat/
    // restPrt/restOrd/restSetMsk, each sized `e.oldFaceCount` — see
    // mesh_edit_delta.d), so a bug confined to any ONE of the other four
    // would not move `m.faces.length` at all and this test would stay green
    // over it. Assert all five truncate to 0 too.
    assert(m.faceMarks.length == 0,
           format("review finding S4: faceMarks must also truncate to 0, "
                ~ "got %d", m.faceMarks.length));
    assert(m.faceMaterial.length == 0,
           format("review finding S4: faceMaterial must also truncate to 0, "
                ~ "got %d", m.faceMaterial.length));
    assert(m.facePart.length == 0,
           format("review finding S4: facePart must also truncate to 0, "
                ~ "got %d", m.facePart.length));
    assert(m.faceSelectionOrder.length == 0,
           format("review finding S4: faceSelectionOrder must also "
                ~ "truncate to 0, got %d", m.faceSelectionOrder.length));
    assert(m.faceSetMask.length == 0,
           format("review finding S4: faceSetMask must also truncate to 0, "
                ~ "got %d", m.faceSetMask.length));
}

// ===========================================================================
// The PolyVertex (per-corner) plane — task 1903 Stage J.
//
// `CornerCarry.step` had no `Kind.FaceReindex` case, so both
// `applyFaceReindexForward` and `applyFaceReindexReverse` declared
// `CornerDrop.DeltaReplayDeclined` unconditionally and every replay of this
// kind came back with a length-correct, ALL-ZERO corner map. The four tests
// below pin the three shapes `FaceSource` admits (drop / duplicate / create)
// in ONE entry, both directions, plus the two failure modes a "carry" that
// merely runs would still exhibit: overwriting live values with defaults, and
// letting a dropped face's values survive into the slot that took its place.
// ===========================================================================

unittest // forward replay reproduces the LIVE post-op corner map, drop + duplicate + create
{
    auto fx = buildFixture(/*armed=*/true);

    // The oracle is the map the LIVE `rewriteFaces` produced (captured in the
    // fixture), so this asserts "redo agrees with the edit it redoes" rather
    // than agreeing with a second copy of the replay's own arithmetic. The
    // round-trip (revert then apply) is the realistic path — a redo always
    // follows an undo.
    fx.delta.revert(fx.m);
    fx.delta.apply(fx.m);

    auto uv = fx.m.meshMap(kUvMapName);
    assert(uv !is null, "the UV map must survive the replay");
    assert(uv.data.length == fx.postUv.length,
           format("forward replay: corner map length %d, expected %d",
                  uv.data.length, fx.postUv.length));

    // SURVIVORS — each new face's corners are its ancestor's, unmoved.
    foreach (nf, of; kSurvivorOld)
        assertUvEq(uvOfFace(fx.m, nf), fx.oldUv[of],
                   format("forward replay, survivor new face %d (old %d)", nf, of));

    // DUPLICATE — both new faces naming old face 0 carry old face 0's own
    // corner values. This is what M-J deletes.
    assertUvEq(uvOfFace(fx.m, kDupA), fx.oldUv[0],
               "forward replay: corner UV of the duplicated face (copy A) "
             ~ "came back zeroed — several new faces naming one old face "
             ~ "must EACH receive that face's corner values, a copy and "
             ~ "never a move");
    assertUvEq(uvOfFace(fx.m, kDupB), fx.oldUv[0],
               "forward replay: corner UV of the duplicated face (copy B) "
             ~ "came back zeroed — several new faces naming one old face "
             ~ "must EACH receive that face's corner values, a copy and "
             ~ "never a move");

    // CREATE (`kNoSource`) — zero, and that is MEASURED, not chosen: the live
    // carry resolves a `~0u` source face to no source corner at all and
    // `remapPolyVertexMaps` zeroes it. Asserted against the LIVE map so the
    // day the law changes, this reddens instead of quietly enshrining a
    // constant.
    assertUvEq(uvOfFace(fx.m, kCreated),
               fx.postUv[fx.m.faceLoop[kCreated] * uv.dim .. $].dup,
               "forward replay: the CREATED face's corners must be exactly "
             ~ "what the live rewrite left there");
    foreach (v; uvOfFace(fx.m, kCreated))
        assert(v == 0.0f,
               format("forward replay: a `kNoSource` face has no ancestor to "
                    ~ "inherit a corner from, so its corners are the honest "
                    ~ "zero — got %s", v.to!string));

    // And the whole plane, byte for byte, so a face this test forgot to name
    // cannot drift unseen.
    assert(uv.data == fx.postUv,
           "forward replay: the corner map must equal the one the live "
         ~ "rewrite produced, byte for byte");
}

unittest // reverse restores the PRE-rewrite corner map byte for byte, including the DROPPED face
{
    auto fx = buildFixture(/*armed=*/true);

    fx.delta.revert(fx.m);

    assert(fx.m.faces.length == 9, "reverse: the pre-rewrite face count");
    auto uv = fx.m.meshMap(kUvMapName);
    assert(uv !is null, "the UV map must survive the reverse replay");

    foreach (of; 0 .. 9)
        assertUvEq(uvOfFace(fx.m, of), fx.oldUv[of],
                   format("reverse, old face %d: the pre-rewrite corner "
                        ~ "values must come back", of));

    // The dropped face gets its own assertion with its own message: it is the
    // ONE shape no correspondence could restore (it has no live representative
    // anywhere in the post-op mesh), so it is the shape that proves the values
    // came from the recorded payload rather than from a lucky slot.
    foreach (i, v; fx.oldUv[4])
        assert(uvOfFace(fx.m, 4)[i] == v,
               format("reverse: the DROPPED face's corner %d must be "
                    ~ "restored from the recorded payload — expected %s, "
                    ~ "got %s", i, v.to!string, uvOfFace(fx.m, 4)[i].to!string));
}

unittest // a no-op forward replay is a no-op: an IDENTITY FaceReindex leaves every corner byte-identical
{
    // The failure this catches is a case that "carries" by overwriting every
    // corner with a default: face count, arity and map length all stay right,
    // the five `kFacePlanes` entries stay right, and only the VALUES go. An
    // identity rewrite is the cell where the correct answer is "change
    // nothing", so any invented value shows.
    Mesh m = makeTaggedGrid();
    uint[][] sameFaces;
    foreach (fi; 0 .. m.faces.length) sameFaces ~= m.faces[fi].dup;

    MeshEditTracker tracker;
    tracker.wantsFaceReindex = true;
    m.beginEditBatch(&tracker, MeshEditScope.Polygons);
    {
        auto rw = m.beginCornerRewrite();
        rewriteFaces(m, sameFaces, FaceSource.identity(sameFaces.length), &rw);
    }
    m.rebuildEdges();
    m.buildLoops();
    MeshEditDelta delta = m.endEditBatch();

    float[] before = m.meshMap(kUvMapName).data.dup;
    assert(before.length == 72, format("fixture: 36 corners x dim 2, got %d",
                                       before.length));
    size_t nz = 0;
    foreach (v; before) if (v != 0.0f) ++nz;
    assert(nz > 60,
           format("fixture: the stand's corner values must be mostly "
                ~ "non-zero or a zero-fill would pass this test — %d of %d "
                ~ "are non-zero", nz, before.length));

    delta.apply(m);
    assert(m.meshMap(kUvMapName).data == before,
           "forward replay of an IDENTITY FaceReindex must leave every "
         ~ "corner byte-identical — a carry that overwrites with defaults "
         ~ "reads as length-correct and loses every value");

    delta.revert(m);
    assert(m.meshMap(kUvMapName).data == before,
           "reverse replay of an IDENTITY FaceReindex must leave every "
         ~ "corner byte-identical");
}

unittest // the DROPPED face's corners must not survive into the slot that took its place
{
    // The scramble this file's module (`renumbersCorners`) exists to prevent,
    // in its FaceReindex form: old face 4 is dropped, so every later face
    // shifts down one and new face 3 is old face 5. A carry that dropped the
    // face from `faces` but not from the provenance array leaves new face 3
    // wearing old face 4's UV — length-correct, plane-correct, and wrong.
    auto fx = buildFixture(/*armed=*/true);
    fx.delta.revert(fx.m);
    fx.delta.apply(fx.m);

    assert(kSurvivorOld[3] == 5,
           "fixture: the new slot right after the drop must be old face 5");
    assertUvEq(uvOfFace(fx.m, 3), fx.oldUv[5],
               "the slot after the dropped face must carry old face 5's "
             ~ "corner UV, not the dropped face 4's");

    // Stronger, and independent of which slot: old face 4's corner values are
    // distinct in this stand, so none of them may appear ANYWHERE in the
    // post-replay plane.
    auto uv = fx.m.meshMap(kUvMapName);
    const size_t dim = uv.dim;   // NOT a hard-coded 2: a second PolyVertex map
                                 // on this stand would move the stride and a
                                 // literal would slice the wrong channel in
                                 // silence (review round 1, NIT-7).
    foreach (c; 0 .. fx.oldUv[4].length / dim) {
        const float u = fx.oldUv[4][c * dim], v = fx.oldUv[4][c * dim + 1];
        foreach (k; 0 .. uv.data.length / dim)
            assert(!(uv.data[k * dim] == u && uv.data[k * dim + 1] == v),
                   format("the dropped face's corner (%s, %s) survived into "
                        ~ "live corner %d — a dropped face's values must go "
                        ~ "with it", u.to!string, v.to!string, k));
    }
}

// ===========================================================================
// `reslotFrom`'s VERTEX-MATCH branch — review round 1, MAJOR-1.
//
// Every new face `buildFixture` builds is `faces[fi].dup` of its ancestor and
// the identity test's `sameFaces` is built the same way, so `from == to` holds
// at every call above and only `reslotFrom`'s slot-for-slot early return ever
// runs. The reviewer measured it: `assert(false, …)` inside the `from != to`
// branch left the whole `--config=tests` lane green.
//
// That branch is not an edge case — it is the half BOTH `&rw` production sites
// Stage K arms will take:
//
//   * `extrudeFacesByMask`'s CAP stands on CLONE vertices, so its winding
//     shares no vertex with its ancestor's: `from != to`, nothing matches, and
//     every cap corner is the honest zero (those are 4 of the 20 corners the
//     card's redo measurement records as inexact);
//   * `mesh_planes.rewriteFaces` gathers `recSurvIdx`/`recSurvLists` at all
//     (review finding B2) precisely because a SURVIVOR's winding can change
//     under a rewrite — and a changed winding with the same vertex SET is the
//     rotation cell below, where the correct answer is neither "keep the slots"
//     nor "zero" but "follow the vertex".
//
// So this stand is deliberately a second fixture rather than an extension of
// `buildFixture`: same `makeTaggedGrid` stand, no drop / duplicate / create at
// all, and the only two things that move are the two winding shapes. Nine new
// faces, nine old faces, 36 corners either way — the corner TOTAL is
// unchanged on purpose, so a length-driven zero-fill cannot masquerade as a
// carry (`resizePolyVertexMaps`'s insurance branch keeps a length-correct map
// whatever is in it).
// ===========================================================================

private struct WindFixture {
    Mesh          m;
    MeshEditDelta delta;
    float[][9]    oldUv;      // per-corner UV of each OLD face, pre-rewrite
    float[]       postUv;     // the WHOLE map right after the live rewrite
}

/// New face 0 = old face 0 with its winding ROTATED one corner. Same vertex
/// SET, so every new corner has a vertex match and the answer is a rotation of
/// the ancestor's values — the cell that separates "match by vertex" from
/// "keep the slots".
private enum uint kRotated = 0;
/// New face 8 = old face 8 moved onto four BRAND-NEW vertices while still
/// NAMING old face 8. The extrude-cap shape: a source face exists, but no
/// corner of it stands on any of these vertices, so the answer is zero.
private enum uint kOnFreshVerts = 8;

/// The ancestor's corner values as this rotation must deliver them: new corner
/// `j` stands on the vertex that was old corner `j + 1`, so the values shift
/// down one whole corner and wrap.
private float[] rotatedByOneCorner(in float[] faceUv, size_t dim) {
    assert(faceUv.length >= dim && faceUv.length % dim == 0,
           "rotatedByOneCorner: not a whole number of corners");
    // `.dup`, not decoration: `in float[]` is `const(float)[]` and D's `~`
    // keeps the element constness, so the concatenation alone is a
    // `const(float)[]` and will not convert to the `float[]` return type.
    return (faceUv[dim .. $] ~ faceUv[0 .. dim]).dup;
}

private WindFixture buildWindingFixture() {
    WindFixture fx;
    fx.m = makeTaggedGrid();
    assert(fx.m.faces.length == 9, "fixture: makeTaggedGrid is a 3x3 grid");
    foreach (fi; 0 .. 9) fx.oldUv[fi] = uvOfFace(fx.m, fi);

    // Four fresh vertices, far from the grid, forming the replacement quad for
    // old face 8. FOUR of them, not three: the corner total must stay 36 (see
    // the header) and the arity must stay 4 so `reslotFrom` cannot decline for
    // an arity reason instead of running its vertex match.
    immutable uint a = fx.m.addVertex(Vec3(100, 0, 0));
    immutable uint b = fx.m.addVertex(Vec3(101, 0, 0));
    immutable uint c = fx.m.addVertex(Vec3(101, 1, 0));
    immutable uint d = fx.m.addVertex(Vec3(100, 1, 0));

    uint[][] newFaces;
    uint[]   oldOfNew;
    foreach (fi; 0 .. 9) {
        if (fi == kRotated) {
            auto f = fx.m.faces[fi].dup;
            assert(f.length == 4, "fixture: the grid's faces are quads");
            newFaces ~= f[1 .. $] ~ f[0 .. 1];
        } else if (fi == kOnFreshVerts) {
            newFaces ~= [a, b, c, d];
        } else {
            newFaces ~= fx.m.faces[fi].dup;   // control: from == to
        }
        oldOfNew ~= cast(uint) fi;
    }
    assert(newFaces[kRotated] != fx.m.faces[kRotated],
           "fixture: the rotated face's winding must actually differ from its "
         ~ "ancestor's, or `reslotFrom` takes its `from == to` early return "
         ~ "and this whole stand measures the branch it means to avoid");
    assert(newFaces[kOnFreshVerts] != fx.m.faces[kOnFreshVerts],
           "fixture: the re-vertexed face's winding must differ from its "
         ~ "ancestor's for the same reason");

    MeshEditTracker tracker;
    tracker.wantsFaceReindex = true;
    fx.m.beginEditBatch(&tracker, MeshEditScope.Polygons);
    {
        auto rw = fx.m.beginCornerRewrite();
        rewriteFaces(fx.m, newFaces, FaceSource(oldOfNew), &rw);
    }
    fx.m.rebuildEdges();
    fx.m.buildLoops();
    fx.delta = fx.m.endEditBatch();
    fx.postUv = fx.m.meshMap(kUvMapName).data.dup;
    return fx;
}

unittest // forward replay follows the VERTEX through a rotated winding, and zeroes a face on all-new vertices
{
    auto fx = buildWindingFixture();
    const size_t dim = fx.m.meshMap(kUvMapName).dim;

    // Round-trip, the realistic path: a redo always follows an undo.
    fx.delta.revert(fx.m);
    fx.delta.apply(fx.m);

    auto uv = fx.m.meshMap(kUvMapName);
    assert(uv !is null, "the UV map must survive the replay");
    assert(uv.data.length == fx.postUv.length,
           format("forward replay: corner map length %d, expected %d",
                  uv.data.length, fx.postUv.length));

    // --- the ROTATION cell ------------------------------------------------
    // Two INDEPENDENT oracles, and they must agree. (a) the ancestor's values
    // rotated by one corner — derived from the pre-op map and the rule, so it
    // says WHAT the answer is; (b) the LIVE post-op map, so it says the replay
    // agrees with the edit it replays. Neither alone is enough: (a) alone
    // would enshrine the replay's own arithmetic, (b) alone would pass if the
    // live carry and the replay were wrong the same way.
    const float[] wantRot = rotatedByOneCorner(fx.oldUv[kRotated], dim);
    assert(wantRot != fx.oldUv[kRotated],
           "fixture: the rotation must actually MOVE values — with a "
         ~ "constant-valued stand this cell could not tell a vertex match "
         ~ "from a slot-for-slot copy");
    assertUvEq(uvOfFace(fx.m, kRotated), wantRot,
               "forward replay, rotated survivor: a new winding that is a "
             ~ "ROTATION of its ancestor's must carry each corner value to "
             ~ "the slot standing on the SAME VERTEX — keeping the slots "
             ~ "instead leaves every corner of this face one place off");
    assertUvEq(uvOfFace(fx.m, kRotated),
               fx.postUv[fx.m.faceLoop[kRotated] * dim
                         .. (fx.m.faceLoop[kRotated] + 4) * dim].dup,
               "forward replay, rotated survivor: and the LIVE rewrite must "
             ~ "have produced exactly that too");

    // --- the ALL-NEW-VERTICES cell (the extrude cap's shape) --------------
    bool ancestorHadValues = false;
    foreach (v; fx.oldUv[kOnFreshVerts]) if (v != 0.0f) ancestorHadValues = true;
    assert(ancestorHadValues,
           "fixture: the ancestor of the re-vertexed face must carry non-zero "
         ~ "corner values, or `zero` below would be satisfied by a carry that "
         ~ "copied them verbatim");
    foreach (i, v; uvOfFace(fx.m, kOnFreshVerts))
        assert(v == 0.0f,
               format("forward replay, face on all-new vertices: it NAMES old "
                    ~ "face %d, but no corner of that face stands on any of "
                    ~ "its vertices, so every corner is the honest zero — "
                    ~ "corner float %d came back %s, which is its ancestor's "
                    ~ "value carried slot-for-slot instead of matched by "
                    ~ "vertex", kOnFreshVerts, i, v.to!string));
    assertUvEq(uvOfFace(fx.m, kOnFreshVerts),
               fx.postUv[fx.m.faceLoop[kOnFreshVerts] * dim
                         .. (fx.m.faceLoop[kOnFreshVerts] + 4) * dim].dup,
               "forward replay, face on all-new vertices: and that zero is "
             ~ "MEASURED — it is what the LIVE rewrite left there");

    // --- the controls -----------------------------------------------------
    // The seven untouched survivors keep their own values. Without these the
    // two cells above are also satisfied by a carry that zeroed the map and
    // happened to be right about one face.
    foreach (fi; 1 .. 8) {
        if (fi == kOnFreshVerts) continue;
        assertUvEq(uvOfFace(fx.m, fi), fx.oldUv[fi],
                   format("forward replay, untouched survivor %d: an "
                        ~ "unchanged winding must still be carried slot for "
                        ~ "slot", fi));
    }

    assert(uv.data == fx.postUv,
           "forward replay: the whole corner map must equal the one the live "
         ~ "rewrite produced, byte for byte");
}

unittest // reverse restores the PRE-rewrite corners under both winding changes
{
    // The payload channel, on the two shapes a correspondence handles worst.
    // It also exercises `rewriteFaces`'s `recSurvIdx`/`recSurvLists` capture
    // (review finding B2): BOTH faces here are survivors whose winding
    // changed, so restoring them from the live post-rewrite mesh would give
    // the rotated / re-vertexed winding instead of the original.
    auto fx = buildWindingFixture();

    fx.delta.revert(fx.m);

    assert(fx.m.faces.length == 9, "reverse: the pre-rewrite face count");
    auto uv = fx.m.meshMap(kUvMapName);
    assert(uv !is null, "the UV map must survive the reverse replay");
    foreach (of; 0 .. 9)
        assertUvEq(uvOfFace(fx.m, of), fx.oldUv[of],
                   format("reverse, old face %d: the pre-rewrite corner "
                        ~ "values must come back", of));
}

// ---------------------------------------------------------------------------
// Task 4059 review — THE ARITY CHECK THE STRUCT GAVE UP.
//
// `recordFaceReindexIfWanted` used to take TWELVE COMPULSORY PARAMETERS. Task
// 4059 collapsed them into one `FaceReindexRecord` with EIGHT
// default-initialised fields, which is a better shape in every way but one:
// the compiler no longer refuses a caller that forgets an argument. There is
// exactly one call site today, and it is correct; the risk is the second one.
// A record built with a drop set but WITHOUT `oldFaceCount` compiles clean and
// then meets `recordFaceReindex`'s no-op guard
// (`oldFaceCount == 0 && newFaceLists.length == 0`), which swallows it whole
// and in silence — review finding B3's defect exactly, re-entering by a new
// door. `FaceReindexRecord.firstAssignedField` states the guard's real
// precondition: a no-op record is EMPTY, not merely zero in two fields.
//
// The probe is generated from `.tupleof`, so a NINTH field added to the
// record is covered with no edit here — which is also why this block asserts
// the probe's own behaviour first and only then drives the tracker.
// ---------------------------------------------------------------------------
unittest // a record filled but missing oldFaceCount is refused, not silently dropped
{
    // Half 1 — the probe itself, and its NON-VACUITY. An all-init record must
    // read as empty, or the assert in `recordFaceReindex` would fire on the
    // genuine no-op it is there to let through.
    FaceReindexRecord empty;
    assert(empty.firstAssignedField() is null,
           "an all-init FaceReindexRecord must read as unfilled, got `"
         ~ empty.firstAssignedField() ~ "`");

    // …and it must actually SEE a filled field, or half 2 proves nothing.
    FaceReindexRecord counted;
    counted.oldFaceCount = 9;
    assert(counted.firstAssignedField() == "oldFaceCount",
           "firstAssignedField must name oldFaceCount, got `"
         ~ counted.firstAssignedField() ~ "`");

    FaceReindexRecord dropped;
    dropped.dropIdx   = [FaceIdx.assumeFaceSpace(0), FaceIdx.assumeFaceSpace(1)];
    dropped.dropLists = [[0u, 1u, 2u], [2u, 3u, 0u]];
    // `oldFaceCount` deliberately NOT set — this is the mistake under test.
    assert(dropped.firstAssignedField() !is null,
           "a record carrying a drop set must not read as unfilled");

    // Half 2 — the guard. THE MUTATION TARGET: delete the `assert` in
    // `MeshEditTracker.recordFaceReindex`'s no-op branch and this line
    // reddens with "expected AssertError was not thrown".
    MeshEditTracker tracker;
    tracker.wantsFaceReindex = true;
    bool refused = false;
    try
        tracker.recordFaceReindex(dropped);
    catch (AssertError e)
        refused = true;
    assert(refused,
           "recordFaceReindex silently swallowed a FaceReindexRecord that "
         ~ "carried a drop set but no oldFaceCount — the no-op guard's "
         ~ "precondition (an EMPTY record) is unchecked again");

    // …and the genuine no-op still passes through without a throw, so the
    // check above is a discrimination and not a blanket refusal.
    MeshEditTracker quiet;
    quiet.wantsFaceReindex = true;
    quiet.recordFaceReindex(empty);
}
