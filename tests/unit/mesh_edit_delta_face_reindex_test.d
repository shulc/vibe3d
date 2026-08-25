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
// SCOPE, stated so nobody assumes more coverage than exists: the PolyVertex
// (UV) corner map is deliberately NOT asserted here. `makeTaggedGrid`
// carries a live UV map, and `CornerCarry` (mesh_edit_delta.d) has no
// `Kind.FaceReindex` case of its own yet — 1903 owns generalising the
// corner-carry protocol to duplicate/create shapes (plan §7.5); this task's
// `renumbersCorners` conservatively treats a FaceReindex entry as a
// renumbering so the corner map is explicitly DROPPED on replay rather than
// left silently stale (see that function's own comment in
// mesh_edit_delta.d). Asserting the five `kFacePlanes` entries by value is
// this file's whole job.
module tests.unit.mesh_edit_delta_face_reindex_test;

import mesh;
import mesh_planes;
import mesh_edit_delta;
import math : Vec3;
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
    rewriteFaces(fx.m, newFaces, FaceSource(oldOfNew));
    fx.delta = fx.m.endEditBatch();

    return fx;
}

// ---------------------------------------------------------------------------
// (1)+(2) armed recorder, driven through drop+duplicate+create.
// ---------------------------------------------------------------------------

unittest // armed: exactly one FaceReindex entry is recorded for one rewriteFaces call
{
    auto fx = buildFixture(/*armed=*/true);
    assert(fx.delta.log.length == 1,
           format("expected exactly one recorded entry for one rewriteFaces "
                ~ "call, got %d", fx.delta.log.length));
    assert(fx.delta.log[0].kind == MeshOpEntry.Kind.FaceReindex,
           "the recorded entry must be Kind.FaceReindex");
    assert(fx.delta.log[0].oldFaceCount == 9,
           format("oldFaceCount must be the pre-rewrite face count (9), got %d",
                  fx.delta.log[0].oldFaceCount));
    // The drop set names exactly the ONE old index no new face names: 4.
    assert(fx.delta.log[0].fIdx.length == 1 && fx.delta.log[0].fIdx[0] == 4,
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

    assert(delta.log.length == 1 && delta.log[0].kind == MeshOpEntry.Kind.FaceReindex);
    assert(delta.log[0].oldFaceCount == 9,
           format("the recorded oldFaceCount must be the true pre-rewrite "
                ~ "count (9), got %d", delta.log[0].oldFaceCount));

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
    assert(delta.log.length == 1,
           format("review finding B3: dropping every face must still "
                ~ "record ONE FaceReindex entry, not zero — got %d",
                  delta.log.length));
    assert(delta.log[0].kind == MeshOpEntry.Kind.FaceReindex);
    assert(delta.log[0].fIdx.length == 9,
           format("the drop set must name all 9 old faces, got %d",
                  delta.log[0].fIdx.length));

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
