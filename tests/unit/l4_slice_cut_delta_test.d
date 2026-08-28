// l4_slice_cut_delta_test — the op-log KIND SEQUENCES of task 1903 stage L4's
// five classes, the batch lift that makes `mesh.julienne`'s entry whole, the
// clipboard contract `mesh.cut` must NOT change, and the source census that
// says the five are off the whole-mesh snapshot.
//
// THE FROZEN FIXTURE (`tests/unit/undo_parity_l4_test.d`) IS THE OTHER HALF,
// and neither is enough alone. It compares the migrated undo, plane for plane,
// against the pre-migration `MeshSnapshot` oracle — so it catches a revert that
// restores LESS. It cannot see the SHAPE of the log that got it there, and the
// shape is contractual: since stage J the `[MeshMapDelta, <face entry>]`
// adjacency is what pairs a per-corner payload with the entry it belongs to
// (`CornerCarry.payloadForCount`), so an entry interposed between such a pair
// zeroes a UV map SILENTLY while the geometry still round-trips. A LENGTH
// assertion is satisfied by that log. Hence: sequences here, planes there.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — run the blocks in
// isolation when scoring a mutation.
module tests.unit.l4_slice_cut_delta_test;

import std.conv   : to;
import std.format : format;

import command;
import mesh;
import view;
import editmode;
import math : Vec3;
import mesh_edit_delta : MeshEditDelta, MeshOpEntry;

import tests.unit.fixtures : makeTaggedGridFull;

import commands.mesh.axis_slice   : MeshAxisSlice, MeshJulienne;
import commands.mesh.screen_slice : MeshScreenSlice;
import commands.mesh.edge_slice   : MeshEdgeSlice;
import commands.mesh.cut_         : MeshCut;

// ---------------------------------------------------------------------------
// Shared scaffolding.
// ---------------------------------------------------------------------------

/// The family's stand — the same one the frozen fixture uses, so a divergence
/// between the two files is a divergence about the CODE and never about the
/// mesh. Its own non-vacuity is asserted in `undo_parity_l4_test.d`; asserting
/// it twice would be two copies of one claim, and the copy nobody reads is the
/// one that drifts.
private Mesh* stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridFull(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

/// A view, as an LVALUE — every `Command` constructor takes `ref View`. One
/// per process is enough: nothing here orbits or frames, and the one cell that
/// PROJECTS (`mesh.screenSlice`) wants the default camera.
private View gView_;
private ref View v()
{
    if (gView_ is null) gView_ = new View(0, 0, 800, 600);
    return gView_;
}

private string kindsOf(ref const MeshEditDelta d)
{
    string t;
    foreach (ref e; d.log) t ~= " " ~ e.kind.to!string;
    return "[" ~ t ~ " ]";
}

private MeshOpEntry.Kind[] kindSeq(ref const MeshEditDelta d)
{
    MeshOpEntry.Kind[] k;
    foreach (ref e; d.log) k ~= e.kind;
    return k;
}

private void assertSeq(string who, ref const MeshEditDelta d,
                       MeshOpEntry.Kind[] want)
{
    assert(kindSeq(d) == want, format(
        "%s recorded %s, expected %s.\n"
      ~ "  A LENGTH would not have caught this: stage J made the "
      ~ "`[MeshMapDelta, <face entry>]` ADJACENCY contractual, and an entry "
      ~ "interposed between such a pair unpairs the corner restore SILENTLY "
      ~ "while the geometry still round-trips.",
        who, kindsOf(d), want.to!string));
}

private void setI_(Command c, string n, int val)
{
    foreach (ref p; c.params()) if (p.name == n) { *p.iptr = val; return; }
    assert(false, "no int param `" ~ n ~ "` on " ~ c.name());
}
private void setF_(Command c, string n, float val)
{
    foreach (ref p; c.params()) if (p.name == n) { *p.fptr = val; return; }
    assert(false, "no float param `" ~ n ~ "` on " ~ c.name());
}
private void setEdges_(Command c, uint[] val)
{
    foreach (ref p; c.params()) if (p.name == "edges") { *p.uiaPtr = val; return; }
    assert(false, "no IntArray param `edges` on " ~ c.name());
}

// ===========================================================================
// 1. THE KIND SEQUENCES.
//
// The family built NO publisher. Every entry below comes from a kernel that
// already had one at the branch point:
//
//   `Mesh.insertEdgePoint`             AddVerts + ReshapeFaces   (Stage L2-c)
//   `Mesh.rebuildFacesWithChordSplits` FaceReindex               (Stage L2-d)
//   `Mesh.deleteFacesByMask`           MeshMapDelta + RemoveFaces
//   `Mesh.compactUnreferenced`         RemoveVerts + Reindex
//
// So these assertions are a MEASUREMENT of what stage L2 left behind, turned
// into a contract. §5.5's L4 row predicted `AddVerts`/`AddFaces`/
// `ReshapeFaces` and "needs FaceReindex: no"; both halves are stale and the
// row is corrected in the plan by the commit that lands this file.
// ===========================================================================

unittest // mesh.axisSlice — one plane, and the ladder
{
    alias K = MeshOpEntry.Kind;

    // ONE plane across the middle of the sheet. `axis: 0` and not the class's
    // DEFAULT of 1: the stand is an XZ sheet with no Y extent, so the default
    // axis hits `span < 1e-6f` and REFUSES. A cell that took the default would
    // assert against an empty delta and pass for the wrong reason.
    Mesh* m = stand();
    auto c = new MeshAxisSlice(m, v(), EditMode.Polygons);
    setI_(cast(Command) c, "axis", 0);
    setI_(cast(Command) c, "count", 1);
    assert(c.apply(), "mesh.axisSlice refused axis 0 on the stand — the cell "
                    ~ "is vacuous, and the likeliest cause is that the stand "
                    ~ "lost its X extent");

    // FOUR straddling edges on a 3x3 sheet, hence four `[AddVerts,
    // ReshapeFaces]` pairs, then ONE `FaceReindex` for the chord rebuild.
    //
    // THE `MeshMapDelta` SITS ON THE FIRST PAIR ONLY, and that asymmetry is
    // the measurement rather than an oversight: a splice changes the mesh's
    // TOTAL corner count while the PolyVertex maps are still the pre-op ones,
    // so from the second splice on `recordPolyVertexPayload` finds the maps
    // out of step with `faces` and DECLINES. That decline is exactly why the
    // command carries a `preMaps_` belt — see `axis_slice.d`'s header.
    assertSeq("mesh.axisSlice/x1", c.recordedDelta(),
              [K.AddVerts, K.MeshMapDelta, K.ReshapeFaces,
               K.AddVerts, K.ReshapeFaces,
               K.AddVerts, K.ReshapeFaces,
               K.AddVerts, K.ReshapeFaces,
               K.FaceReindex]);

    // THE LADDER: three planes in ONE batch, so the log is the single-plane
    // log THREE TIMES OVER and not once. This is what the batch spanning the
    // whole `foreach` buys, and a batch per cut would leave the delta holding
    // the LAST group alone — with the face count, the vertex count and
    // `opInverse` all green, because every plane adds faces.
    Mesh* m3 = stand();
    auto c3 = new MeshAxisSlice(m3, v(), EditMode.Polygons);
    setI_(cast(Command) c3, "axis", 0);
    setI_(cast(Command) c3, "count", 3);
    assert(c3.apply(), "mesh.axisSlice refused count 3");

    immutable size_t reindexes = () {
        size_t n = 0;
        foreach (ref e; c3.recordedDelta().log)
            if (e.kind == K.FaceReindex) ++n;
        return n;
    }();
    assert(reindexes == 3, format(
        "mesh.axisSlice at count 3 recorded %d `FaceReindex` entr(ies), "
      ~ "expected one per plane. ONE means the delta describes a single cut — "
      ~ "either the ladder is running in three batches and only the last "
      ~ "survives, or `count` is not reaching the loop. Neither moves a "
      ~ "/api/changes counter and neither moves any element count, because "
      ~ "every plane adds faces: %s", reindexes, kindsOf(c3.recordedDelta())));
    assert(c3.recordedDelta().log.length
         > c.recordedDelta().log.length,
        "the three-plane ladder recorded no more than the one-plane cut");
}

unittest // mesh.julienne — TWO AXES IN ONE DELTA, which is the batch lift
{
    alias K = MeshOpEntry.Kind;

    Mesh* m = stand();
    auto c = new MeshJulienne(m, v(), EditMode.Polygons);
    setI_(cast(Command) c, "axisA", 0);
    setI_(cast(Command) c, "countA", 1);
    setI_(cast(Command) c, "axisB", 2);
    setI_(cast(Command) c, "countB", 1);
    assert(c.apply(), "mesh.julienne refused the X/Z pair on the stand");

    // TWO `FaceReindex` entries — one chord rebuild per axis. ONE is the
    // pre-lift shape: `sliceAlongAxis` opened and closed its own batch and
    // `evaluate` called it twice, so the second `close()` overwrote the first
    // delta and the undo entry described axis B alone.
    //
    // WHY THIS COUNT AND NOT A COUNTER. `changeBus.nestedBatchOpens` and
    // `batchLeaks` are BOTH 0 under the broken shape — the two opens were
    // sequential, not nested — and so are the face, vertex and edge counts,
    // because both axes add faces. This number and the frozen
    // `mesh.julienne/xz` plane dump are the only two things that see it.
    size_t reindexes = 0, addVerts = 0;
    foreach (ref e; c.recordedDelta().log) {
        if (e.kind == K.FaceReindex) ++reindexes;
        if (e.kind == K.AddVerts)    ++addVerts;
    }
    assert(reindexes == 2, format(
        "mesh.julienne recorded %d `FaceReindex` entr(ies), expected 2 — one "
      ~ "per axis. ONE means the delta describes the SECOND axis alone, which "
      ~ "is the shape before `sliceAlongAxis` took the caller's frame by `ref` "
      ~ "(task 1903 Stage L4-c). Log: %s", reindexes, kindsOf(c.recordedDelta())));
    // NINE, and the prediction written first was EIGHT — recorded as a death
    // rather than edited away, because the reason is the assertion's whole
    // value. "Four per axis" assumes the second pass sees the ORIGINAL sheet.
    // It does not: the X cut leaves a new chord edge running along x = 0 from
    // z = -1/3 to z = +1/3, and the Z plane straddles THAT too. So the second
    // pass has FIVE straddling edges, not four — which is a positive
    // statement that the two axes ran SEQUENTIALLY INSIDE ONE FRAME, on the
    // same mesh, rather than being two independent cuts of the pre-op sheet.
    assert(addVerts == 9, format(
        "mesh.julienne recorded %d `AddVerts` entr(ies), expected 9 — four "
      ~ "straddling edges on the X plane, and FIVE on the Z plane, because "
      ~ "the X cut's own chord along x=0 straddles z=0 as well. FOUR means "
      ~ "only one axis ran; EIGHT would mean the second pass ran against the "
      ~ "PRE-CUT sheet instead of the cut one", addVerts));

    // …and the same class at ONE axis must record strictly less, or the
    // assertion above is measuring something that does not depend on axisB.
    Mesh* m1 = stand();
    auto c1 = new MeshJulienne(m1, v(), EditMode.Polygons);
    setI_(cast(Command) c1, "axisA", 0);
    setI_(cast(Command) c1, "countA", 1);
    setI_(cast(Command) c1, "axisB", 0);          // == axisA, so pass 2 is skipped
    setI_(cast(Command) c1, "countB", 1);
    assert(c1.apply(), "mesh.julienne refused the single-axis control");
    size_t r1 = 0;
    foreach (ref e; c1.recordedDelta().log) if (e.kind == K.FaceReindex) ++r1;
    assert(r1 == 1, format(
        "the single-axis control recorded %d `FaceReindex` entr(ies), expected "
      ~ "1. Without this the two-axis assertion above is satisfied by a class "
      ~ "that always records two", r1));
}

unittest // mesh.screenSlice — the same kernel through a camera plane
{
    alias K = MeshOpEntry.Kind;

    Mesh* m = stand();
    auto c = new MeshScreenSlice(m, v(), EditMode.Polygons);
    setF_(cast(Command) c, "ax", 200);
    setF_(cast(Command) c, "ay", 100);
    setF_(cast(Command) c, "bx", 600);
    setF_(cast(Command) c, "by", 500);
    assert(c.apply(), "mesh.screenSlice refused — either the screen line is "
                    ~ "degenerate under this viewport or the plane misses the "
                    ~ "stand, and the cell is vacuous either way");
    // The SHAPE is `cutByPlane`'s; the COUNT of pairs depends on how many
    // edges the camera plane straddles, so this asserts the shape and not the
    // arithmetic: one `MeshMapDelta` on the first face entry, at least one
    // `[AddVerts, ReshapeFaces]` pair, exactly one `FaceReindex` at the end.
    auto seq = kindSeq(c.recordedDelta());
    assert(seq.length >= 4, format("mesh.screenSlice recorded %s", kindsOf(c.recordedDelta())));
    assert(seq[0] == K.AddVerts && seq[1] == K.MeshMapDelta
        && seq[2] == K.ReshapeFaces && seq[$ - 1] == K.FaceReindex,
        format("mesh.screenSlice recorded %s, expected a leading "
             ~ "`[AddVerts, MeshMapDelta, ReshapeFaces]` and a trailing "
             ~ "`FaceReindex` — the `cutByPlane` shape",
               kindsOf(c.recordedDelta())));
}

unittest // mesh.edgeSlice — arm (i) and arm (ii), and the arm (ii) is the point
{
    alias K = MeshOpEntry.Kind;

    // arm (i): a real chord split across face 0's OPPOSITE edges.
    Mesh* m = stand();
    auto c = new MeshEdgeSlice(m, v(), EditMode.Edges);
    setEdges_(cast(Command) c, [0u, 2u]);
    setF_(cast(Command) c, "tA", 0.5f);
    setF_(cast(Command) c, "tB", 0.5f);
    assert(c.apply(), "mesh.edgeSlice refused edges 0/2 at t=0.5");
    assertSeq("mesh.edgeSlice/split", c.recordedDelta(),
              [K.AddVerts, K.MeshMapDelta, K.ReshapeFaces,
               K.AddVerts, K.ReshapeFaces,
               K.FaceReindex]);

    // arm (ii), KEEP + FINALIZE — the one place in this family where appends
    // occur with NO Pass-2 entry. Two ADJACENT edges of face 0: `tA = 0.5`
    // splices a real vertex in, `tB = 0` reuses the shared corner, the two
    // land adjacent in the winding, `rebuildFacesWithChordSplits`'
    // adjacent-hit guard splits nothing, and the kernel runs its finalize tail
    // by hand. `meshChanged` is TRUE and the edit must be RECORDED.
    //
    // THE ABSENCE OF `FaceReindex` IS THE ASSERTION. With it, this cell is
    // `mesh.edgeSlice/split` under another name — the sequence is what tells
    // the two arms apart, since the vertex count moves in both.
    Mesh* m2 = stand();
    auto c2 = new MeshEdgeSlice(m2, v(), EditMode.Edges);
    setEdges_(cast(Command) c2, [0u, 1u]);
    setF_(cast(Command) c2, "tA", 0.5f);
    setF_(cast(Command) c2, "tB", 0.0f);
    assert(c2.apply(),
        "mesh.edgeSlice REFUSED the KEEP+FINALIZE operand (edges 0/1, tA=0.5, "
      ~ "tB=0). That arm has `facesSplit == 0` and `meshChanged == true`, so a "
      ~ "command that gated `acceptRecordedEdit` on `facesSplit` instead of "
      ~ "`meshChanged` reverts a real edit and records nothing — on an operand "
      ~ "a user reaches with two clicks");
    assertSeq("mesh.edgeSlice/keepFinalize", c2.recordedDelta(),
              [K.AddVerts, K.MeshMapDelta, K.ReshapeFaces]);
    assert(m2.faces.length == 9,
        format("the KEEP+FINALIZE cell split a face (F=%d, expected 9) — it is "
             ~ "then arm (i) and the missing `FaceReindex` above would be a "
             ~ "defect rather than the arm's signature", m2.faces.length));
}

unittest // mesh.cut — the delete kernel, both halves
{
    alias K = MeshOpEntry.Kind;

    // An INTERIOR face: nothing is orphaned, so the log stops at the face drop.
    Mesh* m = stand();
    m.clearFaceSelection();
    m.selectFace(7);
    auto c = new MeshCut(m, v(), EditMode.Polygons);
    assert(c.apply(), "mesh.cut refused face 7");
    assertSeq("mesh.cut/selected", c.recordedDelta(),
              [K.MeshMapDelta, K.RemoveFaces]);

    // The CORNER face: its outer vertex becomes face-unreferenced and the
    // kernel compacts, which is the half a closed solid cannot reach at all.
    Mesh* m2 = stand();
    m2.clearFaceSelection();
    m2.selectFace(0);
    auto c2 = new MeshCut(m2, v(), EditMode.Polygons);
    assert(c2.apply(), "mesh.cut refused face 0");
    assertSeq("mesh.cut/orphan", c2.recordedDelta(),
              [K.MeshMapDelta, K.RemoveFaces, K.RemoveVerts, K.Reindex]);
    assert(m2.vertices.length == 15, format(
        "the corner cut left V=%d, expected 15 — with no compaction the two "
      ~ "cells record the same log and the second is the first written twice",
        m2.vertices.length));
}

// ===========================================================================
// 2. THE CLIPBOARD CONTRACT — unchanged by the migration, and asserted
//    BECAUSE it is unchanged.
//
// `mesh.cut` commits the clip only after the delete confirms, and undo
// deliberately does NOT wipe it. A migration that started reverting the
// clipboard would be a behaviour change nobody asked for, and no geometry
// assertion anywhere would see it.
// ===========================================================================

unittest
{
    import geometry_clipboard : geometryClipboard, GeometryClip;

    // A sentinel the command must overwrite, so "the clip survived" and "the
    // clip was never written" are different pictures.
    geometryClipboard = GeometryClip.init;

    Mesh* m = stand();
    m.clearFaceSelection();
    m.selectFace(7);
    auto c = new MeshCut(m, v(), EditMode.Polygons);
    assert(c.apply(), "mesh.cut refused face 7");
    assert(!geometryClipboard.empty,
        "mesh.cut applied and left the clipboard EMPTY — the clip is committed "
      ~ "after the delete confirms, and without it the assertion below is "
      ~ "satisfied by a clipboard nobody ever filled");
    immutable size_t clipVerts = geometryClipboard.verts.length;
    immutable size_t clipFaces = geometryClipboard.faces.length;

    assert(c.revert(), "mesh.cut's revert refused");
    assert(!geometryClipboard.empty
        && geometryClipboard.verts.length == clipVerts
        && geometryClipboard.faces.length == clipFaces,
        format("undoing mesh.cut changed the clipboard (V %d -> %d, F %d -> %d). "
             ~ "Undoing a cut deliberately KEEPS the clip — standard cut/undo "
             ~ "behaviour, stated at the class and unchanged by the delta "
             ~ "migration", clipVerts, geometryClipboard.verts.length,
               clipFaces, geometryClipboard.faces.length));

    // …and the geometry DID come back, or the cell above is asserting that a
    // no-op left the clipboard alone.
    assert(m.faces.length == 9,
        format("mesh.cut's revert left F=%d, expected the pre-cut 9",
               m.faces.length));
}

// ===========================================================================
// 3. THE SOURCE CENSUS — the five are OFF the whole-mesh snapshot.
//
// A per-file COUNT and not a per-file boolean: `axis_slice.d` held TWO
// `private MeshSnapshot` fields, one per class, and a boolean is satisfied by
// deleting either one.
//
// THE PATH LIST IS DE-DUPLICATED, and that is not decoration: a duplicated
// literal leaves one file unscanned and the census green forever. The byte
// floor is the other half — a scan that read nothing passes every count
// assertion for free.
// ===========================================================================

unittest
{
    import std.file : readText;
    import std.path : dirName, buildPath;
    import std.algorithm : sort, uniq, count;
    import std.array : array;

    // `__FILE_FULL_PATH__`-rooted, never cwd-rooted: the unit lane's working
    // directory is the project root today, and a census that quietly finds
    // nothing when it is not is a test that passes for the wrong reason.
    immutable repo = dirName(dirName(dirName(__FILE_FULL_PATH__)));  // tests/unit/<f> -> repo

    static immutable string[] kFiles = [
        "source/commands/mesh/axis_slice.d",
        "source/commands/mesh/screen_slice.d",
        "source/commands/mesh/edge_slice.d",
        "source/commands/mesh/cut.d",
    ];
    {
        auto uniquePaths = kFiles.dup.sort.uniq.array;
        assert(uniquePaths.length == kFiles.length, format(
            "the census path list holds a DUPLICATE: %d entries, %d distinct. "
          ~ "A duplicated literal leaves one file unscanned and this census "
          ~ "green forever", kFiles.length, uniquePaths.length));
    }

    size_t scanned = 0;
    foreach (rel; kFiles) {
        immutable text = readText(buildPath(repo, rel));
        scanned += text.length;
        immutable size_t nSnap = text.count("private MeshSnapshot");
        assert(nSnap == 0, format(
            "%s still declares %d `private MeshSnapshot` field(s). Task 1903 "
          ~ "stage L4 moved all five classes in this family onto a "
          ~ "`MeshEditDelta`; a surviving whole-mesh capture means either a "
          ~ "class was missed or one was quietly put back, and the second "
          ~ "reads as a fix rather than as a regression. A per-file COUNT and "
          ~ "not a boolean: axis_slice.d held TWO", rel, nSnap));
        assert(text.count("import snapshot") == 0
            || text.count("MeshSnapshot") == 0, format(
            "%s imports `snapshot` and still names `MeshSnapshot`", rel));
    }
    assert(scanned >= 100, format(
        "the census read %d byte(s) across %d file(s) — a scan that read "
      ~ "nothing satisfies every count assertion above for free",
        scanned, kFiles.length));

    // THE POSITIVE CONTROL. The predicate must still FIND a snapshot where one
    // really is, or "no file holds one" is a claim about a predicate that
    // matches nothing. `mesh.split_edge` is snapshot-backed and is not in this
    // family; if task 1903 ever migrates it, re-base this control onto another
    // holder rather than deleting it.
    {
        immutable ctl = readText(buildPath(repo, "source/commands/mesh/split_edge.d"));
        assert(ctl.count("private MeshSnapshot") >= 1,
            "the CONTROL moved: source/commands/mesh/split_edge.d no longer "
          ~ "declares a `private MeshSnapshot`, so the predicate above matches "
          ~ "nothing and every one of the four assertions passes for free. "
          ~ "Re-base this control onto another snapshot holder — "
          ~ "`grep -rn 'private MeshSnapshot' source/commands/` — never delete "
          ~ "it");
    }
}
