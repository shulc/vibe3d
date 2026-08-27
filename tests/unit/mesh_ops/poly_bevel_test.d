// Module unittests for the POLYGON bevel family — `mesh_ops.poly_bevel`'s
// three entries (`insetFacesByMask`, `bevelFacesByMask`, `spikeFacesByMask`)
// AS SEEN THROUGH THE EDIT SEAM. Task 1903 Stage F2.
//
// WHAT LIVES HERE AND WHAT DOES NOT. The family's BEHAVIOURAL blocks — the
// reference-parity group/warped/flat/square/segments cases — stay where they
// already are: six inside `source/mesh_ops/poly_bevel.d` (moved out of the
// mixin template by this stage, §2.7) and twenty-nine in
// `tests/unit/mesh_test.d`. This file is only the SEAM: what a RECORDING
// batch's op-log says about each entry, what `revert()` does with it, and how
// many stamps the batch defers. Nothing here re-checks geometry.
//
// Every block opens its own batch explicitly rather than through a helper: the
// point of each is WHICH constructor was used and what came back from
// `close()`, so hiding the constructor would hide the subject.
module tests.unit.mesh_ops.poly_bevel_test;

import std.format : format;
import std.conv   : to;
import mesh;
import math;
import mesh_ops.poly_bevel;
import mesh_edit_delta : MeshEditDelta, MeshOpEntry, MeshEditScope;
import mesh_selsets : selSetEditPolygon, selSetEditVertex, selSetEditEdge,
                      SetEditMode;

// ---------------------------------------------------------------------------
// The stand, AUDITED PLANE BY PLANE (памятка E2 №5). A recording stand that
// carries one `faceMarks` bit and no selection makes "the revert was complete"
// true for a reason that has nothing to do with the kernel — that is how Stage
// E2's first recording block went green over a stand that could not exhibit
// the loss it was supposed to measure.
//
// NON-ZERO ON FACE 0, deliberately: a rim slot that `addFace` grew is already
// zero, so a source face tagged with a zero cannot tell "the rim inherited the
// tag" from "the rim was zero-grown". Two of Stage F2's differential controls
// (the subpatch carry and the `faceSetMask` carry) read 0/1140 on a stand that
// tagged only the hidden face, and were fixed by the STAND (памятка 28).
// ---------------------------------------------------------------------------
private Mesh recPolyBevelStand() {
    Mesh m = makeGridPlane(3);        // 9 quads, open grid, 16 verts
    m.resetSelection();
    m.faceMaterial.length = m.faces.length;
    m.facePart.length     = m.faces.length;
    foreach (fi; 0 .. m.faces.length) {
        m.faceMaterial[fi] = cast(uint)(fi % 2) + 1;
        m.facePart[fi]     = cast(uint)(fi % 3) + 2;
    }
    m.resizeSubpatch();
    m.setFaceSubpatch(0, true);       // IN the mask and NOT hidden
    m.setFaceSubpatch(8, true);
    m.setFaceHidden(8, true);         // the §3.3 hidden-face backstop cell
    m.selectFace(4);
    m.selectVertex(1);
    m.selectEdge(3);
    { auto s = new bool[](m.faces.length);    s[0] = true;
      selSetEditPolygon(m, "pset", SetEditMode.add, s); }
    { auto s = new bool[](m.vertices.length); s[0] = true;
      selSetEditVertex(m, "vset", SetEditMode.add, s); }
    { auto s = new bool[](m.edges.length);    s[2] = true;
      selSetEditEdge(m, "eset", SetEditMode.add, s); }
    size_t corners = 0;
    foreach (fi; 0 .. m.faces.length) corners += m.faces[fi].length;
    MeshMap uv;
    uv.name = kUvMapName; uv.dim = 2; uv.domain = MapDomain.PolyVertex;
    uv.data.length = corners * 2;
    foreach (i; 0 .. uv.data.length) uv.data[i] = cast(float)(i % 7) * 0.125f;
    m.meshMaps ~= uv;
    return m;
}

private string kindsOf(ref MeshEditDelta d) {
    string s = "[";
    foreach (i, ref e; d.log) { if (i) s ~= " "; s ~= e.kind.to!string; }
    return s ~ "]";
}

private size_t countKind(ref MeshEditDelta d, MeshOpEntry.Kind k) {
    size_t n; foreach (ref e; d.log) if (e.kind == k) ++n; return n;
}

private bool[] faceMask(ref Mesh m, size_t n) {
    auto b = new bool[](m.faces.length);
    foreach (i; 0 .. n) b[i] = true;
    return b;
}

unittest { // THE STAND'S OWN CANARY — first, so a stand that stopped carrying
           // a plane cannot make the blocks below vacuous.
    Mesh m = recPolyBevelStand();
    assert(m.faces.length == 9 && m.vertices.length == 16,
        format("recPolyBevelStand is not the 3x3 grid any more (V=%d F=%d)",
               m.vertices.length, m.faces.length));
    assert(m.isFaceSubpatch(0), "face 0 must carry the Subpatch bit — a rim "
        ~ "slot defaults to FALSE, so a stand whose source face is not a "
        ~ "subpatch cannot tell the carry from the default");
    assert(m.isFaceHidden(8), "face 8 must be HIDDEN — it is the §3.3 "
        ~ "`maskMinusHiddenFaces` backstop cell");
    assert(m.faceMaterial[0] == 1 && m.facePart[0] == 2,
        "face 0's material/part must be NON-ZERO for the same reason");
    assert(m.faceSetMask.length > 0 && m.faceSetMask[0] != 0,
        "face 0 must be in a polygon selection set");
    assert(m.isFaceSelected(4) && m.isVertexSelected(1) && m.isEdgeSelected(3),
        "all three selection domains must be non-empty");
    bool hasUv = false;
    foreach (ref mp; m.meshMaps) if (mp.name == kUvMapName) hasUv = true;
    assert(hasUv, "the stand must carry a PolyVertex UV map");
}

unittest { // the declared SCOPE, written out independently of the enum
    // The value, not just the fact that a constant exists — the census row in
    // `commit_seam_census_test.d` pins that there is ONE
    // `kPolyBevelEditScope`; this pins what it says. Measured on a recording
    // batch around each of the three entries: `scope_` reads 0xe.
    //
    // `Position` (0x1) is ABSENT and that is the measurable difference from
    // `kLoopSliceEditScope` / `kCutEditScope` (both 0xf): no entry in this
    // family moves an EXISTING vertex — every new coordinate is an
    // `ed.addVertex` argument — so this family consumes no `setVertexPos` at
    // all, which is also why its §5.7 census row is a clean `== 0`.
    immutable uint want = MeshEditScope.Points | MeshEditScope.Polygons
                        | MeshEditScope.Marks;
    static struct Cell { string name; int kind; }
    static immutable Cell[3] cells = [Cell("inset", 0), Cell("bevel", 1),
                                      Cell("spike", 2)];
    foreach (c; cells) {
        Mesh m = recPolyBevelStand();
        auto mk = faceMask(m, 1);
        MeshEditDelta d;
        {
            auto ed = MeshEditBatch(m, kPolyBevelEditScope);   // RECORDING
            if      (c.kind == 0) ed.insetFacesByMask(mk, 0.1f);
            else if (c.kind == 1) ed.bevelFacesByMask(mk, 0.1f, 0.2f);
            else                  ed.spikeFacesByMask(mk, 0.5f);
            d = ed.close();
        }
        assert(d.scope_ == want,
            format("%s: a recording poly-bevel declared scope 0x%x, expected "
                 ~ "0x%x (Points|Polygons|Marks). `MeshEditTracker.declare` is "
                 ~ "what ends up in `MeshEditDelta.scope_`, so a wrong constant "
                 ~ "does not fail until Stage K/L7/L2 reads the delta. The "
                 ~ "`Position` bit must stay CLEAR: this family moves no "
                 ~ "existing vertex (task 1903 Stage F2).",
                   c.name, d.scope_, want));
    }
}

unittest { // WHAT THE OP-LOG SAYS — and it now says something about ONE of the
           // four face reshapes. STAGE L2-f FLIPPED THE SPIKE ROW (2026-08-28);
           // STAGE L7 STILL OWES THE OTHER THREE.
    //
    // WHAT CHANGED, AND WHAT DID NOT. `mesh.spikey` is an L2 command (the L
    // table is keyed by COMMAND, памятка E1 №3), so Stage L2-f gave ITS install
    // — `ed.faces[fi] = [v0, v1, apex]` — a publisher: the kernel now collects
    // the parent windings and hands them to `Mesh.setFaceWindings` in ONE bulk
    // call after the fan loop. So the spike cell below expects a `ReshapeFaces`
    // and CALLS `revert()`; the four inset/bevel cells still expect none and
    // still do not, because `insetFacesByMask` and `bevelFacesByMask` install
    // their other three windings by index and are L7's.
    //
    // The paragraphs below are the Stage F2 measurement as it stood; they are
    // kept because the DIAGNOSIS they record (absent publisher, not disarmed —
    // established by ARMING and re-measuring) is what the three remaining rows
    // still rest on. Read "four" as "four, of which one is now closed".
    // Measured at Stage F2 on the stand above, under a RECORDING batch:
    //
    //   inset  0.1, 1 face   -> [AddVerts AddFaces]        revert() THROWS
    //   inset  0.1, 8 faces  -> 8 x [AddVerts AddFaces]    revert() THROWS
    //   bevel  0.1/0.2       -> [AddVerts AddFaces]        revert() THROWS
    //   bevel  group, grid, FULL mask (8 processed, 1 hidden) ->
    //                            7 x [AddVerts AddFaces] + [RemoveVerts
    //                            Reindex]                  revert() THROWS
    //   bevel  group, closed cube, all 6 -> [AddVerts] (0 AddFaces) +
    //                            [RemoveVerts Reindex]     revert() THROWS
    //   spike  0.5           -> [AddVerts AddFaces]        revert() THROWS
    //   empty mask           -> []                          (nothing recorded)
    //
    // THE LAW IS NOT "one [AddVerts AddFaces] pair per processed face" — a
    // review of this block caught that overstatement (2026-08-26) and it is
    // corrected here: it is one pair per processed face THAT APPENDS AT LEAST
    // ONE CORNER. Under `group` the shared-corner memo
    // (`sharedVertIdxByLevel`) can serve a face ENTIRELY from vertices an
    // earlier face in the same group already appended, so a face can be
    // PROCESSED (count toward `n`) while contributing ZERO AddVerts/AddFaces
    // of its own — measured 7 pairs for 8 processed faces on the grid stand's
    // full mask, and 1 pair for 6 processed faces on a closed cube, where
    // every face shares its whole corner set with a neighbour and `AddFaces`
    // reads 0 (no new face is appended at all, only the one shared apex
    // vertex). And `if (anyClamped || group) ed.compactUnreferenced();` means
    // this family is NOT publisher-silent on the group path: whenever `group`
    // orphans a vertex — every incident face's corner having moved to the
    // shared apex — the batch also carries `[RemoveVerts Reindex]`. `edge_
    // bevel.d` (Stage G) calls `compactUnreferenced` too, so G inherits this
    // same non-uniform-pair, non-silent shape.
    //
    // The throw is `index [16] is out of bounds for array of length 16` out of
    // the LIFO replay, and it leaves the mesh HALF-REVERTED: V back to 16 with
    // F still 9 and 4..32 windings pointing at vertices that no longer exist.
    //
    // WHY, AND THE DIAGNOSIS IS *ABSENT PUBLISHER*, NOT DISARMED — distinguished
    // by ARMING THE FLAG AND MEASURING (памятка 12/21), never by reading. With
    // `MeshEditTracker.wantsFaceReindex = true` at its declaration the op-log
    // of every cell above is BYTE-IDENTICAL and the revert still throws. The
    // mutation's potency was checked on a FOREIGN family: the same armed build
    // reddens `tests/unit/mesh_ops/cleanup_test.d(785)` ("revert restored
    // V=4 F=3, expected V=4 F=2"). So the primitive is never reached — this
    // family calls no `rewriteFaces` at all (census row, comment-stripped) and
    // instead installs FOUR windings by INDEX: `ed.faces[fi] = newVerts.dup`
    // (the inset ring), `= finalVerts.dup` (the bevel cap), `= rebuilt` (the
    // square splice into an UNSELECTED neighbour) and `= [v0, v1, apex]` (the
    // spike's first fan triangle). Stage K's per-rewrite arming scope CANNOT
    // reach any of them; the owner is the L stage, and it is TWO L stages, not
    // one — L7 for `mesh.poly_inset` and `mesh.bevel`'s polygon arm, L2 for
    // `mesh.spikey` (the L table is keyed by COMMAND, памятка E1 №3).
    //
    // THIS ALSO CORRECTS PLAN §5.5's L7 ROW, which reads "`poly_inset` is
    // clear (append-only)". It is not: `insetFacesByMask` replaces the source
    // face's winding in its own slot, at equal arity, and no hook sees it.
    //
    // `revert()` IS NOT CALLED IN THIS BLOCK, and that is a MEASUREMENT rather
    // than caution — calling it aborts the module. The observable that flips
    // when the family is fixed is the LIST OF ENTRY KINDS below.
    //
    // NO REVERSE MAP MEASUREMENT IS POSSIBLE HERE, and that is worth stating
    // because F1's family could do one: there the armed build stopped throwing
    // and the PolyVertex map could be watched coming back zeroed. Here arming
    // changes nothing, so there is no reverse to attribute by variant — the
    // FORWARD carry is all that can be measured, and it is (Stage F2, on this
    // stand): uv 72 floats / 61 non-zero becomes 104/61 after an inset,
    // 104/91 after a bevel, 152/138 after a grouped bevel of four faces,
    // 144/133 with `square`, and 88/67 after a spike. Nothing is zeroed, so
    // this family is inside the 0682/0830 corner-carry census on the forward
    // side — and, exactly as the F1 review measured for Loop Slice, A FORWARD
    // CARRY SAYS NOTHING ABOUT THE REVERSE.
    // `reshapes` is 0 for the rows L7 still owns and 1 for the spike, whose
    // publisher landed at L2-f. A single shared `== 0` would have to be
    // weakened to `>= 0` to let the spike through, which is the shape that
    // cannot come out differently.
    static struct Cell { string name; int kind; size_t nsel; size_t faces;
                         size_t reshapes; }
    static immutable Cell[5] cells = [
        Cell("inset, 1 face",  0, 1, 1, 0), Cell("inset, 8 faces", 0, 9, 8, 0),
        Cell("bevel, 1 face",  1, 1, 1, 0), Cell("bevel, 4 faces", 1, 4, 4, 0),
        Cell("spike, 1 face",  2, 1, 1, 1),
    ];
    foreach (c; cells) {
        Mesh m = recPolyBevelStand();
        auto preWind = new uint[][](m.faces.length);
        foreach (fi; 0 .. m.faces.length) preWind[fi] = m.faces[fi].dup;
        immutable size_t preV = m.vertices.length, preF = m.faces.length;
        auto mk = faceMask(m, c.nsel);
        MeshEditDelta d;
        size_t n;
        {
            auto ed = MeshEditBatch(m, kPolyBevelEditScope);   // RECORDING
            if      (c.kind == 0) n = ed.insetFacesByMask(mk, 0.1f);
            else if (c.kind == 1) n = ed.bevelFacesByMask(mk, 0.1f, 0.2f);
            else                  n = ed.spikeFacesByMask(mk, 0.5f);
            d = ed.close();
        }
        assert(n == c.faces,
            format("%s: the kernel processed %d face(s), expected %d — every "
                 ~ "count below would be vacuous (task 1903 Stage F2). Note "
                 ~ "face 8 is HIDDEN on this stand, so a full mask processes "
                 ~ "EIGHT.", c.name, n, c.faces));
        assert(countKind(d, MeshOpEntry.Kind.AddVerts) == c.faces
            && countKind(d, MeshOpEntry.Kind.AddFaces) == c.faces,
            format("%s: the op-log is %s — expected exactly %d AddVerts and %d "
                 ~ "AddFaces, one pair per PROCESSED FACE (task 1903 Stage F2).",
                   c.name, kindsOf(d), c.faces, c.faces));
        assert(countKind(d, MeshOpEntry.Kind.ReshapeFaces) == c.reshapes
            && countKind(d, MeshOpEntry.Kind.FaceReindex)  == 0
            && countKind(d, MeshOpEntry.Kind.RemoveFaces)  == 0,
            format("%s: the op-log is %s — expected exactly %d ReshapeFaces, "
                 ~ "no FaceReindex and no RemoveFaces.\n"
                 ~ "  For the three INSET/BEVEL rows the expectation is 0 and "
                 ~ "an entry appearing is GOOD NEWS: Stage F2 measured the "
                 ~ "publisher ABSENT, not disarmed (arming `wantsFaceReindex` "
                 ~ "left the log byte-identical, because those kernels reach "
                 ~ "no `rewriteFaces` at all and install their windings by "
                 ~ "index), so somebody has given one of them a publisher and "
                 ~ "plan §5.3's OTHER-audit rows plus §5.5's L7 row move with "
                 ~ "it.\n"
                 ~ "  For the SPIKE row the expectation is 1 and a 0 is a "
                 ~ "REGRESSION: Stage L2-f routed `ed.faces[fi] = [v0, v1, "
                 ~ "apex]` through `Mesh.setFaceWindings`, and without it the "
                 ~ "revert below throws `index out of bounds` out of the LIFO "
                 ~ "replay.", c.name, kindsOf(d), c.reshapes));

        // THE REVERT, CALLED — for the spike row only, and calling it IS the
        // check. Before L2-f this block deliberately did not call `revert()`
        // on any cell because it aborted the module (`index [16] is out of
        // bounds for array of length 16`, leaving V back at 16 with F still 9
        // and windings pointing at vertices that no longer exist). A cell that
        // still declined to call it after L2-f would not have tested the
        // migration. The three L7 rows still decline, for the reason above.
        if (c.reshapes > 0) {
            assert(d.revert(m),
                format("%s: revert() refused the delta outright", c.name));
            assert(m.vertices.length == preV && m.faces.length == preF,
                format("%s: revert left V=%d F=%d, expected the pre-op V=%d "
                     ~ "F=%d", c.name, m.vertices.length, m.faces.length,
                       preV, preF));
            foreach (fi; 0 .. m.faces.length)
                assert(m.faces[fi] == preWind[fi],
                    format("%s: face %d came back as %s, expected its pre-op "
                         ~ "winding %s — the fan's parent slot is the one the "
                         ~ "L2-f publisher restores, and a count-only "
                         ~ "assertion is green on this failure", c.name, fi,
                           m.faces[fi].to!string, preWind[fi].to!string));
        }
    }
    {   // GROUP, grid, FULL mask — the review's cell (round 1, MAJOR-1): the
        // five cells above never pass `group=true`, so the header's revised
        // law above was never exercised by a cell. Explicit per-Kind expected
        // COUNTS, not `== processed`, because `== processed` is exactly the
        // identity this law breaks.
        Mesh m = recPolyBevelStand();
        auto mk = faceMask(m, m.faces.length);   // full mask; face 8 is HIDDEN
        MeshEditDelta d;
        size_t n;
        {
            auto ed = MeshEditBatch(m, kPolyBevelEditScope);   // RECORDING
            n = ed.bevelFacesByMask(mk, 0.1f, 0.2f, true, 0);  // group=true
            d = ed.close();
        }
        assert(n == 8,
            format("bevel, group, grid full mask: the kernel processed %d "
                 ~ "face(s), expected 8 — face 8 is HIDDEN on this stand, so "
                 ~ "a full mask processes EIGHT and every count below would "
                 ~ "be vacuous (task 1903 Stage F2).", n));
        assert(countKind(d, MeshOpEntry.Kind.AddVerts)    == 7
            && countKind(d, MeshOpEntry.Kind.AddFaces)    == 7
            && countKind(d, MeshOpEntry.Kind.RemoveVerts) == 1
            && countKind(d, MeshOpEntry.Kind.Reindex)     == 1,
            format("bevel, group, grid full mask: the op-log is %s — expected "
                 ~ "exactly 7 AddVerts, 7 AddFaces, 1 RemoveVerts, 1 Reindex "
                 ~ "for 8 PROCESSED faces. The shared-corner memo served one "
                 ~ "of the eight entirely from earlier appends (7 pairs, not "
                 ~ "8), and `compactUnreferenced` published the orphaned "
                 ~ "vertex's removal plus the resulting reindex (task 1903 "
                 ~ "Stage F2).", kindsOf(d)));
        assert(countKind(d, MeshOpEntry.Kind.ReshapeFaces) == 0
            && countKind(d, MeshOpEntry.Kind.FaceReindex)  == 0
            && countKind(d, MeshOpEntry.Kind.RemoveFaces)  == 0,
            format("bevel, group, grid full mask: the op-log now names a face "
                 ~ "RESHAPE/FaceReindex/RemoveFaces (%s) — this family still "
                 ~ "calls no `rewriteFaces` at all (task 1903 Stage F2).",
                   kindsOf(d)));
    }
    {   // GROUP, closed cube, all 6 — the review's other cell. On a closed
        // solid EVERY face shares its whole corner set with a neighbour once
        // grouped, so the accumulator appends exactly one shared apex vertex
        // and no new face at all: `AddFaces` reads 0.
        Mesh m = makeCube();
        m.resetSelection();
        immutable size_t v0 = m.vertices.length, f0 = m.faces.length;
        auto mk = faceMask(m, m.faces.length);   // all 6 faces, none hidden
        MeshEditDelta d;
        size_t n;
        {
            auto ed = MeshEditBatch(m, kPolyBevelEditScope);   // RECORDING
            n = ed.bevelFacesByMask(mk, 0.1f, 0.2f, true, 0);  // group=true
            d = ed.close();
        }
        assert(n == 6,
            format("bevel, group, closed cube: the kernel processed %d "
                 ~ "face(s), expected 6 — every count below would be vacuous "
                 ~ "(task 1903 Stage F2).", n));
        assert(countKind(d, MeshOpEntry.Kind.AddVerts)    == 1
            && countKind(d, MeshOpEntry.Kind.AddFaces)    == 0
            && countKind(d, MeshOpEntry.Kind.RemoveVerts) == 1
            && countKind(d, MeshOpEntry.Kind.Reindex)     == 1,
            format("bevel, group, closed cube: the op-log is %s — expected "
                 ~ "exactly 1 AddVerts, 0 AddFaces, 1 RemoveVerts, 1 Reindex. "
                 ~ "A closed cube's 6 faces share their whole corner sets with "
                 ~ "their neighbours once grouped, so only the one shared "
                 ~ "apex vertex is appended and no face is (task 1903 Stage "
                 ~ "F2).", kindsOf(d)));
        assert(countKind(d, MeshOpEntry.Kind.ReshapeFaces) == 0
            && countKind(d, MeshOpEntry.Kind.FaceReindex)  == 0
            && countKind(d, MeshOpEntry.Kind.RemoveFaces)  == 0,
            format("bevel, group, closed cube: the op-log now names a face "
                 ~ "RESHAPE/FaceReindex/RemoveFaces (%s) — this family still "
                 ~ "calls no `rewriteFaces` at all (task 1903 Stage F2).",
                   kindsOf(d)));
        assert(m.vertices.length == v0 && m.faces.length == f0,
            format("bevel, group, closed cube: V %d->%d F %d->%d — one "
                 ~ "AddVerts against one RemoveVerts is a net-zero vertex "
                 ~ "count and zero AddFaces is a net-zero face count; a "
                 ~ "mismatch means the op-log no longer matches the mesh "
                 ~ "(task 1903 Stage F2).",
                   v0, m.vertices.length, f0, m.faces.length));
    }
    {   // the REFUSAL cell: an empty mask records nothing at all.
        Mesh m = recPolyBevelStand();
        auto mk = new bool[](m.faces.length);
        MeshEditDelta d;
        size_t n;
        {
            auto ed = MeshEditBatch(m, kPolyBevelEditScope);
            n = ed.insetFacesByMask(mk, 0.1f);
            d = ed.close();
        }
        assert(n == 0 && d.log.length == 0,
            format("an EMPTY mask processed %d face(s) and recorded %d op-log "
                 ~ "entr(ies) %s — a refusal must reach no mutation hook at "
                 ~ "all, which is what makes `status:error, did not apply` an "
                 ~ "honest answer (task 1903 Stage F2).",
                   n, d.log.length, kindsOf(d)));
    }
}

unittest { // ONE stamp per gesture, however many faces the mask selects — and
           // it SCALES.
    // A SCALE check, not a location check (E3 memo 11). Measured on this stand
    // with the deferral disabled (M-F2-BATCH: `if (false) if (auto f =
    // currentBatchFrame(&this))` in `Mesh.commitChange`):
    //
    //     faces processed      1      4      8
    //     inset  unbatched    10     34     66      (8n + 2)
    //     bevel  unbatched    10     34     66      (8n + 2)
    //     spike  unbatched     6     18     34      (4n + 2)
    //
    // The batch holds all nine at 1, and the amplitude grows with the face
    // count — the half a single-face cell cannot see, and the half NO WIRE
    // COUNTER can see at all: at suite level a batch per face and a batch over
    // the whole mask read identically on every `/api/changes` counter, so
    // `mutationVersion` in the unit lane is the only discriminator (памятка 11).
    //
    // THE THREE ENTRIES ARE SEPARATE CELLS ON PURPOSE. They have DIFFERENT
    // unbatched slopes (8n+2 against 4n+2), so a single `== 1` row over one
    // entry would be satisfied while another entry's batch was missing.
    static struct Cell { string name; int kind; }
    static immutable Cell[3] entries = [Cell("inset", 0), Cell("bevel", 1),
                                        Cell("spike", 2)];
    foreach (c; entries)
        foreach (nsel; [cast(size_t)1, 4, 9]) {
            Mesh m = recPolyBevelStand();
            auto mk = faceMask(m, nsel);
            immutable ulong base = m.mutationVersion;
            size_t n;
            {
                auto ed = MeshEditBatch.unrecorded(m, kPolyBevelEditScope);
                if      (c.kind == 0) n = ed.insetFacesByMask(mk, 0.1f);
                else if (c.kind == 1) n = ed.bevelFacesByMask(mk, 0.1f, 0.2f);
                else                  n = ed.spikeFacesByMask(mk, 0.5f);
                ed.close();
            }
            assert(n > 0, format("%s/%d: the kernel processed nothing — the "
                               ~ "delta below would be vacuous", c.name, nsel));
            immutable ulong delta = m.mutationVersion - base;
            assert(delta == 1,
                format("%s over %d masked face(s) bumped mutationVersion by "
                     ~ "%d, expected exactly 1 — one deferred stamp at "
                     ~ "`close()`. Unbatched the same cells measure 10 / 34 / "
                     ~ "66 (inset, bevel) and 6 / 18 / 34 (spike), i.e. the "
                     ~ "ladder GROWS with the mask while the batched figure "
                     ~ "does not: this is a SCALE check and a constant-1 row "
                     ~ "over one face could not see a batch that had gone "
                     ~ "missing on the others (task 1903 §3.1, Stage F2).",
                       c.name, nsel, delta));
        }
}
