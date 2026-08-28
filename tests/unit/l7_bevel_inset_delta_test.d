// l7_bevel_inset_delta_test — the witnesses the FACE half of stage L7 owes
// that a frozen plane fixture cannot carry (task 1903;
// `undo_parity_l7_test.d` carries the plane-for-plane oracle, this file
// carries the SHAPE assertions and the refusals).
//
// LANE. All of it is `dub test --config=tests` (lane U) — `./run_test.d` never
// runs a `tests/unit/**` unittest block. The COMMAND-CONSTRUCTOR half of the
// seam is in lane S (`tests/test_poly_bevel_seam_counters.d`,
// `tests/test_edge_bevel_seam_counters.d`), because a unit cell that drives
// the KERNEL opens its own batch and stays green with the command still
// unrecorded.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — score a mutation that
// reddens two of these cells by running them in isolation.
module tests.unit.l7_bevel_inset_delta_test;

import std.conv   : to;
import std.format : format;

import command;
import mesh;
import mesh_edit_delta : MeshEditDelta;
import view;
import editmode;
import change_bus : changeBus;

import tests.unit.fixtures : makeTaggedGridFull, dumpMeshPlanes, diffMeshPlanes;
import commands.mesh.poly_inset : MeshPolygonInset;
import commands.mesh.bevel      : MeshBevel;

private Mesh* stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridFull(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

private string kindsOf(in MeshEditDelta d)
{
    string s;
    foreach (i, ref e; d.log) s ~= (i ? " " : "") ~ e.kind.to!string;
    return s;
}

/// Every face's winding, as text — the plane this family's whole undo debt is
/// about, and the ONE thing a silently-declined `setFaceWindings` moves.
private string windingsOf(in Mesh m)
{
    string s;
    foreach (fi, ref f; m.faces) s ~= f.to!string ~ ";";
    return s;
}

private string uvOf(in Mesh m)
{
    auto uv = m.meshMap(kUvMapName);
    if (uv is null) return "<no map>";
    string s;
    foreach (i, f; uv.data) s ~= (i ? "," : "") ~ format("%.9g", f);
    return s;
}

private void selectFaces(Mesh* m, const size_t[] fis)
{
    m.clearFaceSelection();
    foreach (fi; fis) m.selectFace(cast(int) fi);
}

// ---------------------------------------------------------------------------
// W-7-a1 — THE INSET CELL: after `revert()`, EVERY face's winding AND every
// per-corner UV value equals its pre-op value.
//
// TWO ASSERTIONS, AND THEY ARE SCORED BY TWO DIFFERENT MUTATIONS. Both are
// stated with what actually reddened, because §5.5's L7 addendum predicts a
// third thing that does not happen.
//
// (1) THE WINDING HALF. Mutation: put the RAW indexed write back —
//     `ed.faces[fi] = newVerts.dup;` in `insetFacesByMask` — so the bulk
//     `setFaceWindings` call finds every winding already installed and writes
//     nothing. The forward is byte-identical; the revert becomes
//
//       core.exception.ArrayIndexError@source/mesh.d(15188): index [16] is out
//       of bounds for array of length 16
//         ... Mesh.buildLoops <- mesh_edit_delta.finalize <- MeshEditDelta.revert
//
//     i.e. exactly the pre-L7 baseline this stage exists to close.
//
// (2) THE PER-CORNER HALF IS A REGRESSION GUARD HERE, NOT A DISCRIMINATOR, AND
//     THE CELL SAYS SO RATHER THAN LETTING IT POSE AS A WITNESS. Mutation:
//     delete `recordPolyVertexPayload(idx)` from `setFaceWindings`' full-hit
//     arm, so the `ReshapeFaces` entry is UNPAIRED. Run in isolation (the
//     kind-sequence cell below reddens on the same mutation): this cell stays
//     GREEN. Measured, and the reason is structural — the inset's cap has the
//     SAME ARITY as the face it replaces, so `CornerCarry.reshapeSrc`'s
//     equal-arity slot-for-slot re-derive lands on exactly the corners the
//     payload would have restored. The payload only bites where the ARITY
//     CHANGES: the square splice (`mesh.bevel/polySquare`) and
//     `bevelFinBundleSpineMultiEdge`, where it is measured at 7 of 12 original
//     corners coming back zero.
//
// SO THE PLAN'S CLAIM FOR THIS ROW IS WRONG IN BOTH DIRECTIONS. It says
// "`Mesh.setFaceWindings` SILENTLY DECLINES an unordered `idx` list … on the
// inset path that produces a revert which restores V/F/E, every mark word,
// `faceMaterial`, `facePart` and both set masks byte-identical and leaves only
// the WINDINGS wrong." Measured: `setFaceWindings` carries an ALWAYS-ON guard,
// so an unordered list is LOUD at the door —
// `AssertError@source/mesh.d(3417): Mesh.setFaceWindings: `idx` must be
// strictly ascending — the per-corner payload pairs by a single ordered sweep`
// — and a MISSING publisher is loud too, as the throw in (1). The silent
// failure is one layer down and it loses the per-corner plane, not the
// windings.
//
// WHAT SURVIVES OF THE PLAN'S POINT, and it is why this class still migrated
// first: the inset reaches no `compactUnreferenced`, so its log has no
// `[RemoveVerts, Reindex]` tail and NOTHING BUT the winding entry can be
// credited for its restore. That is the attribution the bevel groups cannot
// make.
unittest
{
    foreach (sel; [[cast(size_t) 7], [cast(size_t) 0, 1, 2, 3, 4, 5, 6, 7, 8]]) {
        auto m = stand();
        selectFaces(m, sel);
        immutable preW  = windingsOf(*m);
        immutable preUv = uvOf(*m);
        immutable preV  = m.vertices.length;
        immutable preF  = m.faces.length;

        auto v = new View(0, 0, 800, 600);
        auto c = new MeshPolygonInset(m, v, EditMode.Polygons);
        assert(c.apply(), format("mesh.poly_inset refused a %d-face mask",
                                 sel.length));
        assert(m.faces.length > preF && m.vertices.length > preV,
            "the inset moved no count — the round trip below is then satisfied "
          ~ "by an undo that does nothing");
        assert(windingsOf(*m) != preW,
            "the inset installed no winding — this cell measures the winding "
          ~ "publisher and there is nothing for it to measure");

        assert(c.revert(), "the undo must succeed");
        assert(m.vertices.length == preV && m.faces.length == preF,
            format("revert left V=%d F=%d, expected %d/%d",
                   m.vertices.length, m.faces.length, preV, preF));
        assert(windingsOf(*m) == preW, format(
            "mesh.poly_inset (%d-face mask): the WINDINGS did not come back.\n"
          ~ "  before: %s\n  after : %s\n"
          ~ "This is the one failure mode that leaves V/F/E, every mark word, "
          ~ "faceMaterial, facePart and both set masks byte-identical",
            sel.length, preW, windingsOf(*m)));
        // …and the PER-CORNER plane, which is the half a paired-but-declined
        // payload loses while the windings above still round-trip.
        assert(uvOf(*m) == preUv, format(
            "mesh.poly_inset (%d-face mask): the WINDINGS came back and the "
          ~ "per-corner UV plane did NOT.\n  before: %s\n  after : %s\n"
          ~ "That is the shape of an unpaired payload: `ReshapeFaces` restores "
          ~ "the winding, `CornerCarry` finds no `MeshMapDelta` adjacent to it "
          ~ "and re-derives the corners slot-for-slot instead of restoring "
          ~ "them verbatim", sel.length, preUv, uvOf(*m)));
    }
}

// ---------------------------------------------------------------------------
// W-7-a2 — the inset's op-log is a KIND SEQUENCE, asserted IN ORDER.
//
// Stage J made the `[MeshMapDelta, ReshapeFaces]` ADJACENCY contractual:
// `CornerCarry.payloadForCount` binds by adjacency, so an interposed entry
// unpairs the corner restore SILENTLY while the geometry still round-trips.
// A LENGTH assertion is satisfied by the broken log too.
//
// It also pins the BULK shape: ONE pair for the whole processed set, not one
// per face. The per-element path is measurably quadratic —
// `recordPolyVertexPayload` resolves corner bases by ONE ordered sweep over
// `faces`, measured at 31x (3 600 faces) and 66x (10 000) on card 2260 — and
// the GC byte counter points the WRONG WAY on that choice (card 2160), so the
// shape is pinned structurally here rather than by a timing.
//
// MUTATION: replace the bulk call with a per-face loop. The sequence grows to
// one `[MeshMapDelta, ReshapeFaces]` pair per face and the cell names it.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    selectFaces(m, [0, 1, 2, 3, 4, 5, 6, 7, 8]);
    auto v = new View(0, 0, 800, 600);
    auto c = new MeshPolygonInset(m, v, EditMode.Polygons);
    assert(c.apply(), "mesh.poly_inset refused the eight-face mask");

    // ALL NINE faces are selected and EIGHT process: face 5 is HIDDEN and
    // `maskMinusHiddenFaces` (the §3.3 backstop, task 0613) drops it, which is
    // why the cell selects it rather than skipping it. Each processed face
    // appends its corner ring and its N ring quads, and then ONE pair closes
    // the whole set.
    string want;
    foreach (i; 0 .. 8) want ~= "AddVerts AddFaces ";
    want ~= "MeshMapDelta ReshapeFaces";
    immutable seq = kindsOf(c.recordedDelta());
    assert(seq == want, format(
        "mesh.poly_inset recorded\n  [%s]\nexpected\n  [%s]\n"
      ~ "ONE `[MeshMapDelta, ReshapeFaces]` pair closes the whole processed "
      ~ "set — a pair PER FACE is the quadratic shape card 2260 measured at "
      ~ "31x/66x, and an entry interposed between the payload and its "
      ~ "`ReshapeFaces` unpairs the corner restore SILENTLY", seq, want));
}

// ---------------------------------------------------------------------------
// W-7-INERT — the inset and polygon-bevel cells say, in their OWN message,
// that the Point-domain map arm is INERT on their path.
//
// "A green over an inert payload must not read as coverage." `mesh.poly_inset`
// reaches no `compactUnreferenced`, so `removeVertsReverse` never runs and its
// documented Point-map zeroing cannot bite. That is why this class carries no
// `preMaps_` belt while `MeshBevel` does — and why a green here is NOT
// evidence that the belt next door is unnecessary.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    selectFaces(m, [7]);
    immutable preW = uvOfPoint(*m);

    auto v = new View(0, 0, 800, 600);
    auto c = new MeshPolygonInset(m, v, EditMode.Polygons);
    assert(c.apply(), "mesh.poly_inset refused");

    immutable seq = kindsOf(c.recordedDelta());
    assert(seq.length && !seq.indexOfSub("RemoveVerts"), format(
        "mesh.poly_inset recorded a `RemoveVerts` entry ([%s]). This cell's "
      ~ "whole statement is that the Point-map arm of `removeVertsReverse` is "
      ~ "INERT on this path — if the kernel started compacting, the cell is no "
      ~ "longer an inertness statement and `MeshPolygonInset` owes the "
      ~ "`preMaps_` belt `MeshBevel` carries", seq));

    assert(c.revert(), "the undo must succeed");
    assert(uvOfPoint(*m) == preW,
        "the Point-domain map moved across a `mesh.poly_inset` round trip — "
      ~ "which it cannot do without a compaction, so either the kernel changed "
      ~ "or this cell is measuring the wrong map");
}

/// The Point-domain map's values, as text.
private string uvOfPoint(in Mesh m)
{
    auto w = m.meshMap("W");
    if (w is null) return "<no map>";
    string s;
    foreach (i, f; w.data) s ~= (i ? "," : "") ~ format("%.9g", f);
    return s;
}

private bool indexOfSub(string hay, string needle)
{
    if (needle.length > hay.length) return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle) return true;
    return false;
}

// ---------------------------------------------------------------------------
// W-7-b1 — THE SQUARE-SPLICE CELL: the UNSELECTED neighbours' ARITIES come
// back.
//
// `bevelFacesByMask`'s third install (`ed.faces[fi] = rebuilt`) splices the
// square split points into faces NOBODY SELECTED, so the mesh stays
// watertight. It is also where an "append as processed" accumulator would be
// UNORDERED: the splice walks faces the mask SKIPPED, so its indices are not
// in the mask's order. That is why it takes its own bulk call.
//
// THE CHANNEL IS ARITY, NOT WINDING, AND THAT IS A MEASUREMENT. A winding
// comparison here is VACUOUS: the `group` path ends in `compactUnreferenced`,
// which renumbers every vertex, so EVERY winding differs after the forward
// whether or not the splice ran. Measured — with the splice's install removed
// entirely, a cell comparing neighbour WINDINGS stayed GREEN. Arity is
// reindex-invariant: measured on this stand, the five unselected faces go
// 4 -> 6/5/5/5/5 when the splice runs and come back to 4/4/4/4/4.
//
// THE MUTATION THAT SCORES IT MUST KEEP THE FORWARD IDENTICAL. Deleting the
// install outright changes the FORWARD (T-junctions; the frozen fixture catches
// it on `postOp`, `counts.edges` 48 vs 53) and says nothing about the undo. The
// honest one is to put the RAW indexed write back — `ed.faces[fi] = rebuilt;`
// instead of the accumulator — so the forward is byte-identical and only the
// publisher is gone. Its red, verbatim:
//
//   core.exception.ArrayIndexError@source/mesh.d(15188): index [23] is out of
//   bounds for array of length 16   ... Mesh.buildLoops <- mesh_edit_delta.finalize
//
// i.e. the revert THROWS. So in THIS group the missing publisher is LOUD, and
// that is exactly why `mesh.poly_inset` — where the same class of defect is
// silent — is the family's discriminating member and migrated first.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    selectFaces(m, [4, 7]);

    size_t[] arity(in Mesh mm) {
        size_t[] a;
        foreach (ref f; mm.faces) a ~= f.length;
        return a;
    }
    // The pre-op faces that are NOT in the operand mask — the ones only the
    // splice can touch. Face 5 is HIDDEN and therefore also unmasked.
    static immutable size_t[] kUnmasked = [0, 1, 2, 3, 5, 6, 8];
    auto preA = arity(*m);

    auto v = new View(0, 0, 800, 600);
    auto c = new MeshBevel(m, v, EditMode.Polygons);
    foreach (ref p; c.params()) {
        if (p.name == "inset")  *p.fptr = 0.1f;
        if (p.name == "shift")  *p.fptr = 0.05f;
        if (p.name == "group")  *p.bptr = true;
        if (p.name == "square") *p.bptr = true;
    }
    assert(c.apply(), "mesh.bevel (group+square) refused the stand");

    // The forward REACHED an unselected face — without this the round trip
    // below is satisfied by a splice that never ran.
    auto postA = arity(*m);
    size_t spliced = 0;
    foreach (fi; kUnmasked)
        if (fi < postA.length && postA[fi] != preA[fi]) ++spliced;
    assert(spliced >= 2, format(
        "the square splice changed the arity of %d unmasked face(s); expected "
      ~ "at least two. Without it this cell measures the same install the "
      ~ "plain polygon bevel does, and the mutation it is written for scores "
      ~ "nothing. (pre %s, post %s)", spliced, preA, postA));

    assert(c.revert(), "the undo must succeed — and before Stage L7-P2 it did "
                     ~ "not: it THREW out of buildLoops");
    assert(arity(*m) == preA, format(
        "the unselected neighbours' ARITIES did not come back.\n"
      ~ "  before: %s\n  after : %s\n"
      ~ "Arity is the channel because the group path's `compactUnreferenced` "
      ~ "renumbers every vertex, so a WINDING comparison here is green whether "
      ~ "or not the splice was published", preA, arity(*m)));
}

// ---------------------------------------------------------------------------
// W-7-REF — THE REFUSALS, asserted rather than frozen.
//
// A refusing command leaves `postOp == postUndo == pre`, so a frozen pair of
// dumps for it is a check that cannot come out differently (stage L5's
// decision, repeated). What CAN come out differently is what the refusal DOES:
// `apply()` must answer false, nothing may be left mutated, no edit frame may
// be left open, and `revert()` must answer false — a `true` there would replay
// belts that were never captured.
//
// BOTH REFUSALS HERE ARE POST-BATCH, which is the opposite of the loop-slice
// family's and is why the `batchLeaks` assertion is not decoration: the batch
// really is opened, the kernel really does refuse inside it, and the handle's
// destructor is what has to unwind.
// ---------------------------------------------------------------------------
unittest
{
    // `mesh.poly_inset` over a mesh where EVERY face is hidden: the empty
    // selection makes `operandFaceMask` the whole mesh, `maskMinusHiddenFaces`
    // (the §3.3 backstop, task 0613) empties it, and the kernel answers 0 —
    // AFTER the batch has been opened, which is what makes the `batchLeaks`
    // assertion below a real unwind check.
    //
    // NOT "select the hidden face": measured, `Mesh.selectFace` REFUSES a
    // hidden face (the Select AND Hide = empty-set invariant), so that
    // selection comes out EMPTY, `operandFaceMask` falls back to the whole
    // mesh and the command APPLIES. A refusal cell built that way is green on
    // any implementation and was caught here by running it.
    auto m = stand();
    m.clearFaceSelection();
    foreach (fi; 0 .. m.faces.length) m.setFaceHidden(fi, true);
    auto pre = dumpMeshPlanes(*m);
    immutable ulong leaks0 = changeBus.batchLeaks;

    auto v = new View(0, 0, 800, 600);
    auto c = new MeshPolygonInset(m, v, EditMode.Polygons);
    assert(!c.apply(),
        "mesh.poly_inset APPLIED over a mask holding only a HIDDEN face. "
      ~ "`maskMinusHiddenFaces` is the §3.3 backstop and the kernel's 0 is the "
      ~ "refusal; a command answering true here lands a history entry "
      ~ "describing no change");
    auto post = dumpMeshPlanes(*m);
    assert(diffMeshPlanes(pre, post) == "",
        "mesh.poly_inset refused and still moved the mesh: planes ["
      ~ diffMeshPlanes(pre, post) ~ "]");
    assert(changeBus.batchLeaks == leaks0, format(
        "mesh.poly_inset's refusal leaked %d edit frame(s) — and this refusal "
      ~ "IS post-batch, so this is a real unwind assertion and not a "
      ~ "pre-flight one", changeBus.batchLeaks - leaks0));
    assert(!c.revert(),
        "mesh.poly_inset's revert() answered TRUE after a refused forward");
}

unittest
{
    // `mesh.bevel`, polygon arm, over an all-hidden mesh — the same
    // post-batch refusal as `mesh.poly_inset`'s above, and the same reason it
    // is that one and not a parameter-based one.
    //
    // MEASURED, AND IT CORRECTS THIS COMMAND'S OWN DOC COMMENT: `bevel.d`
    // claims "|inset|<1e-6 && |shift|<1e-6 (polygon) … -> status:error", and
    // it is not true of `bevelFacesByMask` — a zero/zero polygon bevel still
    // processes every masked face and returns a non-zero count. The guard the
    // comment describes lives on the interactive tool's path, not here. A
    // refusal cell built on it would be green under any implementation of the
    // undo, which is how this was found.
    auto m = stand();
    m.clearFaceSelection();
    foreach (fi; 0 .. m.faces.length) m.setFaceHidden(fi, true);
    auto pre = dumpMeshPlanes(*m);
    immutable ulong leaks0 = changeBus.batchLeaks;

    auto v = new View(0, 0, 800, 600);
    auto c = new MeshBevel(m, v, EditMode.Polygons);
    foreach (ref p; c.params()) {
        if (p.name == "inset") *p.fptr = 0.1f;
        if (p.name == "shift") *p.fptr = 0.05f;
    }
    assert(!c.apply(),
        "mesh.bevel APPLIED over a mesh whose every face is HIDDEN. "
      ~ "`maskMinusHiddenFaces` empties the operand and the kernel's 0 is the "
      ~ "refusal; a command answering true here lands a history entry "
      ~ "describing no change");
    auto post = dumpMeshPlanes(*m);
    assert(diffMeshPlanes(pre, post) == "",
        "mesh.bevel refused and still moved the mesh: planes ["
      ~ diffMeshPlanes(pre, post) ~ "]");
    assert(changeBus.batchLeaks == leaks0, format(
        "mesh.bevel's refusal leaked %d edit frame(s)",
        changeBus.batchLeaks - leaks0));
    assert(!c.revert(),
        "mesh.bevel's revert() answered TRUE after a refused forward");
}

// ---------------------------------------------------------------------------
// W-7-DECLINE — THE EDGE ARM'S REFUSAL IS REAL, AND IT IS ASSERTED RATHER THAN
// LEFT AS A COMMENT.
//
// `mesh.bevel`'s EDGE arm keeps its `MeshSnapshot`: three candidate shapes for
// a delta were measured and all three are refused today (the numbers are at
// `commands/mesh/bevel.d`'s class doc comment — candidate (a) is inadmissible
// because rewrite #1 GROWS the face count 9 -> 11 / 9 -> 12; (b) is unsound
// because the merge pass can leave a corner on a vertex its source face does
// not contain; (c) loses a Point-domain map VALUE that needs a payload FIELD).
//
// A DECLINE THAT IS ONLY A COMMENT IS NOT A DECLINE. What this cell pins is
// that the edge arm records NOTHING and still undoes: a future edit that
// flips it to a recording batch WITHOUT the point-domain payload would be
// green on every other check in either lane — the mesh round-trips, because
// the delta and the snapshot cannot both be held — and would quietly lose the
// point-map values on every edge-bevel undo.
//
// MUTATION: give the edge arm the RECORDING constructor in
// `MeshBevel.runKernel`. The op-log assertion below reddens by name.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    // An INTERIOR manifold edge: the only operand for which a chamfer span
    // exists at all. Edge 1 (`[1, 5]`) has two incident faces on this grid.
    m.clearEdgeSelection();
    m.selectEdge(1);

    immutable preV = m.vertices.length;
    immutable preF = m.faces.length;
    immutable preW = windingsOf(*m);
    immutable prePt = uvOfPoint(*m);

    auto v = new View(0, 0, 800, 600);
    auto c = new MeshBevel(m, v, EditMode.Edges);
    foreach (ref p; c.params()) if (p.name == "width") *p.fptr = 0.1f;

    assert(c.apply(), "mesh.bevel (edge mode) refused an interior edge — the "
                    ~ "decline this cell pins would then be pinned over an op "
                    ~ "that never ran");
    assert(m.vertices.length > preV && m.faces.length > preF,
        "the edge bevel moved no count");

    assert(c.recordedDelta().log.length == 0, format(
        "mesh.bevel's EDGE arm recorded [%s]. It is DECLINED at this stage and "
      ~ "keeps its `MeshSnapshot`: the armed shape loses a Point-domain map "
      ~ "VALUE (`removeVertsReverse` zeroes a re-inserted vertex's point-map "
      ~ "values, and Stage L5-b's payload covers the SET MASKS only), which "
      ~ "needs a `MeshOpEntry` payload FIELD. A recording batch here without "
      ~ "that field round-trips the MESH and silently drops those values, "
      ~ "which is why this is asserted and not merely commented",
        kindsOf(c.recordedDelta())));
    assert(!c.isOperationInverse(),
        "mesh.bevel's EDGE arm reports `opInverse` in /api/history while it "
      ~ "still undoes through a whole-mesh snapshot");

    assert(c.revert(), "the edge arm's snapshot undo must succeed");
    assert(m.vertices.length == preV && m.faces.length == preF,
        format("undo left V=%d F=%d, expected %d/%d",
               m.vertices.length, m.faces.length, preV, preF));
    assert(windingsOf(*m) == preW,
        "the edge arm's snapshot undo did not restore the windings");
    assert(uvOfPoint(*m) == prePt, format(
        "the edge arm's snapshot undo did not restore the Point-domain map.\n"
      ~ "  before: %s\n  after : %s\n"
      ~ "This is the exact plane the DELTA path loses, which is why the arm is "
      ~ "declined — a green here is what the decline buys", prePt,
        uvOfPoint(*m)));
}
