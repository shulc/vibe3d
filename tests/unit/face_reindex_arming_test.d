// ===========================================================================
// Task 1903 Stage K — `Kind.FaceReindex` is armed PER REWRITE, and this file
// is what says which rewrites and proves it is per rewrite.
//
// THREE THINGS ARE PINNED HERE, and they fail for three different reasons:
//
//  1. **The scope is per rewrite, not per batch.** One batch that runs an
//     ARMED kernel and then an op that records `RemoveFaces` must revert to
//     exactly its starting state. Under a batch-wide flag the second op's
//     drop is described TWICE — once by `recordRemoveFaces`, once by
//     `mesh_planes.rewriteFaces`' publisher — and the LIFO revert then lands
//     on a state neither entry describes. Plan §5.3's Stage E1 row saw that as
//     a face count PAST its starting value; on this stand it shows up as a
//     wrong EDGE count instead, and the cell says why. That is not a
//     hypothetical: it is the failure that made the flag a scope
//     (plan §5.3, "K's red row").
//
//  2. **What each armed family's revert restores, and what it does not.**
//     Full-state, plane by plane, on a stand where every plane is populated
//     and non-uniform. The residual is asserted as a residual: an
//     `expectedResidual` list per family, checked BOTH ways, so closing one
//     of those gaps reddens here and forces the row to be rewritten rather
//     than quietly widening what "complete" means.
//
//  3. **The armed SET, as a source census.** An arm added to a kernel this
//     stage measured and left out reddens by name, and so does an arm
//     removed from one it put in. The census also pins the SHAPE the plan
//     asked for — one scope per rewrite, never one scope spanning two — which
//     no behavioural test on today's tree can see, because the only kernel
//     with two rewrites in one function (`edge_bevel.bevelEdgesByMask`) is
//     measured UNARMED and has nothing recording between its two calls.
//
// WHY THE STANDS CARRY A UV MAP AND A WEIGHT MAP. The residual lists below
// distinguish "lost a Select bit" from "lost a VALUE", and that distinction is
// the whole arm/do-not-arm rule. On a stand with no per-corner and no
// per-vertex map both classes read as "nothing to lose" and every family looks
// clean — including the two the stage refuses to arm.
// ===========================================================================
module tests.unit.face_reindex_arming_test;

import std.algorithm.sorting   : sort;
import std.array               : join, split;
import std.file                : readText, exists, isDir, dirEntries, SpanMode;
import std.format              : format;
import std.path                : buildPath, dirName, relativePath;
import std.string              : indexOf, strip, startsWith;

import mesh;
import math;
import mesh_edit_delta;
import snapshot : MeshSnapshot;
import mesh_ops.extrude;
import mesh_ops.loop_slice;
import mesh_ops.cleanup;
import mesh_ops.revolve;
import tests.unit.fixtures : makeTaggedGridFull, dumpMeshPlanes, diffMeshPlanes,
                             explainMeshPlaneDiff;

private size_t countKind(ref MeshEditDelta d, MeshOpEntry.Kind k)
{
    size_t n;
    foreach (ref e; d.log) if (e.kind == k) ++n;
    return n;
}

private string kindsOf(ref MeshEditDelta d)
{
    import std.conv : to;
    string[] ks;
    foreach (ref e; d.log) ks ~= e.kind.to!string;
    return "[" ~ ks.join(" ") ~ "]";
}

private bool[] faceMaskOf(ref Mesh m, uint[] idx...)
{
    auto b = new bool[](m.faces.length);
    foreach (i; idx) b[i] = true;
    return b;
}

private bool[] vertMaskOf(ref Mesh m, uint[] idx...)
{
    auto b = new bool[](m.vertices.length);
    foreach (i; idx) b[i] = true;
    return b;
}

/// The pre-op state in BOTH forms the residual check needs: the plane TABLE,
/// which names what moved, and the TYPED planes, which are the only way to say
/// what SHAPE the move had.
///
/// The table alone is what made the first draft of this file green under a
/// planted value loss (Stage K review, MAJOR-1): six of the seven families
/// already list `vertexSetMask`, so "that plane differs" was true before the
/// damage and true after it. A name cannot distinguish "grew by four zeros"
/// from "element 0 was overwritten"; the values can.
private struct PreState
{
    string[string] planes;
    MeshSnapshot   snap;
}

private PreState capturePre(ref Mesh m)
{
    PreState p;
    p.planes = dumpMeshPlanes(m);
    p.snap   = MeshSnapshot.capture(m);
    return p;
}

// ---------------------------------------------------------------------------
// 1. THE DOUBLE REVERT — the failure the scope exists to make unreachable.
// ---------------------------------------------------------------------------

/// `makeTaggedGridFull` with one face made DEGENERATE, so a single batch can
/// run an ARMED kernel (`cleanDegenerateFaces`, which drops that face through
/// `mesh_planes.rewriteFaces` and records nothing else about it) and then a
/// DISARMED one (`deleteFacesByMask`, which drops a face through
/// `recordRemoveFaces` AND reaches the same primitive).
///
/// The stand must carry BOTH, in one batch, or the cell cannot see the bug:
/// on a batch containing only the armed op a batch-wide flag and a per-rewrite
/// scope produce byte-identical logs.
private Mesh mixedBatchStand()
{
    Mesh m = makeTaggedGridFull();
    // Face 8: repeat a winding index. `cleanDegenerateFaces` collapses it to a
    // triangle (its RESHAPE half) without touching the face count, so the
    // count assertions below stay about the DELETE.
    m.faces[8] = [m.faces[8][0], m.faces[8][1], m.faces[8][1], m.faces[8][2]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    return m;
}

unittest // one batch, an ARMED rewrite and a RemoveFaces-recording op: no double revert
{
    Mesh m = mixedBatchStand();
    immutable size_t preF = m.faces.length;
    immutable size_t preV = m.vertices.length;
    auto pre = capturePre(m);

    size_t cleaned, deleted;
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, kCleanupEditScope | MeshEditScope.Polygons);
        // (a) the ARMED kernel: its face change reaches the op-log only
        //     through `Kind.FaceReindex`.
        cleaned = cleanDegenerateFaces(ed);
        // (b) the DISARMED one: `Mesh.deleteFacesByMask` records
        //     `RemoveFaces` itself AND calls `mesh_planes.rewriteFaces`. If the
        //     arming from (a) were still in force, this drop would be in the
        //     log twice.
        deleted = ed.deleteFacesByMask(faceMaskOf(ed.mesh, 0u));
        d = ed.close();
    }

    // Anti-vacuity FIRST, and on BOTH halves: a batch where either op did
    // nothing is a batch where one arming rule cannot be told from the other.
    assert(cleaned == 1,
        format("the stand's degenerate face was not cleaned (%d) — with no "
             ~ "armed rewrite in the batch, a batch-wide flag and a "
             ~ "per-rewrite scope produce the same log and this cell is "
             ~ "vacuous", cleaned));
    assert(deleted == 1,
        format("the stand's delete removed %d face(s), expected 1 — without a "
             ~ "second face drop recorded through `recordRemoveFaces` there "
             ~ "is no second description to conflict with", deleted));

    // The op-log names the armed drop ONCE and the recorded drop ONCE, in two
    // different kinds. THIS is the assertion a batch-wide flag reddens.
    immutable size_t nReindex = countKind(d, MeshOpEntry.Kind.FaceReindex);
    immutable size_t nRemove  = countKind(d, MeshOpEntry.Kind.RemoveFaces);
    assert(nReindex == 1 && nRemove == 1,
        format("the mixed batch logged %d FaceReindex and %d RemoveFaces "
             ~ "entr(ies), expected 1 and 1 — log %s.\n"
             ~ "  TWO FaceReindex: the arming survived `cleanDegenerateFaces` "
             ~ "and described `deleteFacesByMask`'s drop a SECOND time. "
             ~ "`Mesh.FaceReindexArm.~this` must RESTORE the flag, not merely "
             ~ "drop its pointer.\n"
             ~ "  ZERO FaceReindex: `Mesh.faceReindexScope()` is not SETTING "
             ~ "the flag, so every armed kernel in this stage is inert and "
             ~ "each family's recorded revert is back to throwing or to "
             ~ "silently dropping its face change.\n"
             ~ "  (task 1903 Stage K, plan §5.3)",
               nReindex, nRemove, kindsOf(d)));

    immutable bool reverted = d.revert(m);
    assert(reverted,
        format("revert() refused the mixed batch outright — log %s. That is a "
             ~ "third state, neither the clean revert this cell asserts nor "
             ~ "the overshoot it guards against; re-measure before touching "
             ~ "this block", kindsOf(d)));

    // THE COUNT IS NOT THE WHOLE CHANNEL, AND THAT IS MEASURED. Plan §5.3's
    // Stage E1 row describes the double revert as a face count landing PAST
    // its starting value (F=3 against a pre-op F=2, on `unifyFaces`'
    // two-face stand). On THIS stand it does not: mutating the scope to a
    // batch-wide flag leaves the count at 9 and produces a WRONG MESH —
    // E=23 against a pre-op E=25 — because `FaceReindex⁻¹` restores the whole
    // face ARRAY rather than inserting into it, so replaying it either side
    // of `RemoveFaces⁻¹` lands the array at a state neither entry describes.
    // Measured 2026-08-27. The count assertion is kept because an overshoot is
    // still the loudest form; the plane comparison below is what actually
    // catches it here, and a count-only cell on this stand would be GREEN
    // under the bug.
    assert(m.faces.length == preF,
        format("revert landed on %d face(s) against a pre-op %d. A count "
             ~ "ABOVE the pre-op value is the double revert in its loudest "
             ~ "form: both `RemoveFaces⁻¹` and `FaceReindex⁻¹` re-inserted the "
             ~ "face `deleteFacesByMask` dropped. A count BELOW it is a revert "
             ~ "that lost one", m.faces.length, preF));
    assert(m.vertices.length == preV,
        format("revert landed on %d vertices against a pre-op %d",
               m.vertices.length, preV));

    // Geometry and every per-face plane come back; the residual is the
    // Select-class one every armed family carries (see block 2).
    auto rev = dumpMeshPlanes(m);
    foreach (plane; ["counts", "vertices", "faces", "edges",
                     "faceMaterial", "facePart", "faceSetMask", "map:uv"]) {
        assert(rev[plane] == pre.planes[plane],
            format("the mixed batch's revert did not restore `%s`.%s",
                   plane, explainMeshPlaneDiff(pre.planes, rev)));
    }
}

// ---------------------------------------------------------------------------
// 2. WHAT EACH ARMED FAMILY'S REVERT RESTORES — full state, plane by plane.
// ---------------------------------------------------------------------------

/// The planes an armed family is measured NOT to restore, checked BOTH ways.
///
/// THE RULE STAGE K DRAWS, and why these lists are allowed to be non-empty.
/// A `Kind.FaceReindex` entry is the publisher for the face array, the
/// per-face planes carried through `FaceSource`, and — since Stage J — the
/// per-corner map. It is the publisher for NOTHING ELSE. Every family armed
/// by this stage was measured to lose only:
///
///   * **Select-class planes** — the Select bit of `vertexMarks`/`edgeMarks`/
///     `faceMarks`, the three `*SelectionOrder` arrays and the three order
///     counters. They are cleared by kernel TAILS (`resetSelection`,
///     `clearVertexSelection`, `clearFaceSelectionResize`,
///     `setFaceMarksFrom(…, ~Marks.Select)`) that run AFTER the rewrite, so no
///     face-rewrite entry could carry them. Subpatch and Hide, which sit in
///     the same word, DO come back — which is how we know this is the Select
///     bit and not "faceMarks is lost".
///   * **array LENGTHS** — `faceSelectionOrder` and friends left grown to the
///     post-op length with every value intact, from `finalizeTopologyEdit`'s
///     resize.
///
/// `vertexSetMask` WAS ON SIX OF THE SEVEN LISTS AND IS ON NONE OF THEM NOW
/// (2026-08-28, task 1903 Stage L2-c). It was a LENGTH residual of exactly the
/// kind above — `finalize`'s blanket length sync simply did not name that
/// plane, the same hole task 1060's review had closed for `faceSetMask`. The
/// frozen parity oracle caught it on `mesh.split_edge` and the line was added,
/// so the plane now comes back exactly and naming it here would be asserting a
/// difference that no longer exists. A SHORTER list is what a closed gap looks
/// like, which is what the shape assertion's own message says.
///
/// A family that loses a VALUE is NOT armed by this stage — see the census in
/// block 3 and the three refusals it names.
private struct ArmedFamily
{
    string   name;
    string[] expectedResidual;
}

// ---------------------------------------------------------------------------
// THE RESIDUAL'S SHAPE, NOT ITS NAME.
// ---------------------------------------------------------------------------
//
// `expectedResidual` above is a set of plane NAMES, and a name is satisfied by
// ANY difference at all. That is not a theoretical hole — it was measured
// (Stage K review, MAJOR-1). With a real value loss planted in
// `extrudeFacesByMask`,
//
//     if (ed.mesh.vertexSetMask.length > 0) ed.mesh.vertexSetMask[0] = 0;
//
// immediately before its rewrite, `dub test --config=tests` answered
// `290 modules passed unittests`, EXIT=0 — fully green — because
// `vertexSetMask` was on six of the seven lists at the time, so "this plane
// differs" was true before the damage and true after it. (Stage L2-c has since
// taken it off all seven by fixing the length sync, but the HOLE the review
// found is about any plane a list names, not about that one.) The rule the whole
// stage rests on ("armed families lose Select bits and array LENGTHS; a family
// that loses a VALUE is not armed") had no machine check for any plane it had
// already named.
//
// SWAPPING THE INSTRUMENT DOES NOT FIX IT. `meshPlaneDiffs`, the `.tupleof`
// comparator in `tests/unit/mesh_ops/seam_differential.d`, `return`s at a
// `.length` mismatch, so on a grown plane it never reaches element 0 either.
// The fix has to be a statement about the SHAPE of the growth, against the
// PRE-OP values — which is the same two-clause rule, said in a form a
// mutation can break.
//
// FOUR LAWS, ONE PER PLANE CLASS, EACH MEASURED ON ALL SEVEN FAMILIES
// (2026-08-27). The `default:` arm of `residualLaw` is the tripwire: a plane
// that reaches a residual list without a law here reddens by name rather than
// riding in unchecked, which is exactly how the hole above opened.
private enum ResidualLaw
{
    /// A MARKS word. Masked with `~Marks.Select` it must still equal pre,
    /// element for element, over pre's whole length, and any tail the resize
    /// left must be masked-zero. So the Select bit may go — that IS the
    /// residual — and Subpatch, Hide and Lock may not.
    selectBitOnly,

    /// An ARRAY left grown by `finalizeTopologyEdit`'s resize: pre is a
    /// PREFIX, byte for byte, and the tail is the plane's default. This is the
    /// clause the planted mutation broke, and the only one that can tell
    /// "grew" from "lost".
    grownWithDefaultTail,

    /// A selection-ORDER plane the revert leaves at its POST-OP value,
    /// truncated (or zero-extended) to the restored length. Measured true on
    /// all seven families for `vertexSelectionOrder`, `edgeSelectionOrder` and
    /// the three counters: the revert restores the array's LENGTH and does not
    /// touch its contents.
    postOpTruncated,

    /// `faceSelectionOrder` alone, and it gets NO value claim — deliberately,
    /// with the reason measured rather than assumed. The face revert carries a
    /// PERMUTATION: on `extrudeFacesByMask` the post-op array is
    /// `[0,0,11,0,0,23,1,0,1,…]` (the consumed source face's slot gone, later
    /// faces shifted down) and the reverted one is `[0,0,11,0,1,0,23,1,0]` —
    /// the post-op stamps carried back through `FaceReindex⁻¹`. Neither pre
    /// nor post-op is the right thing to compare against without re-deriving
    /// that permutation here, so this law asserts only that the array is long
    /// enough for the restored face count. Anything stronger would be a
    /// re-implementation of the code under test.
    facePermutedLengthOnly,
}

private ResidualLaw residualLaw(string family, string plane)
{
    switch (plane)
    {
        case "vertexMarks":
        case "edgeMarks":
        case "faceMarks":
            return ResidualLaw.selectBitOnly;
        case "vertexSetMask":
        case "faceSetMask":
            return ResidualLaw.grownWithDefaultTail;
        case "vertexSelectionOrder":
        case "edgeSelectionOrder":
        case "orderCounters":
            return ResidualLaw.postOpTruncated;
        case "faceSelectionOrder":
            return ResidualLaw.facePermutedLengthOnly;
        default:
            assert(false,
                format("%s: `%s` reached the residual list with NO recorded "
                     ~ "SHAPE law, so the only thing checked about it is that "
                     ~ "it differs — which is true of a harmless resize and of "
                     ~ "a lost value alike (Stage K review, MAJOR-1). Add its "
                     ~ "law to `residualLaw` beside the four above, and say "
                     ~ "there what a legitimate residual on this plane looks "
                     ~ "like", family, plane));
    }
}

private void assertSelectBitOnly(string family, string plane,
                                 const(uint)[] pre, const(uint)[] rev)
{
    enum uint keep = ~cast(uint) Mesh.Marks.Select;
    assert(rev.length >= pre.length,
        format("%s: `%s` came back SHORTER than pre-op (%d < %d). A marks "
             ~ "plane below its pre-op length is a lost element, not a lost "
             ~ "Select bit", family, plane, rev.length, pre.length));
    foreach (i; 0 .. pre.length)
        assert((rev[i] & keep) == (pre[i] & keep),
            format("%s: `%s`[%d] came back as 0x%x against a pre-op 0x%x, and "
                 ~ "they differ OUTSIDE the Select bit (masked: 0x%x vs 0x%x). "
                 ~ "The residual this stage records is Select ALONE; Subpatch, "
                 ~ "Hide and Lock share the word and are carried by the same "
                 ~ "entry, so a difference here means the word is not being "
                 ~ "carried — and this family must come back OUT of the armed "
                 ~ "set", family, plane, i, rev[i], pre[i],
                   rev[i] & keep, pre[i] & keep));
    foreach (i; pre.length .. rev.length)
        assert((rev[i] & keep) == 0,
            format("%s: `%s` was left GROWN to %d (pre-op %d) and its tail "
                 ~ "element %d is 0x%x, not the default. A grown tail is a "
                 ~ "recorded residual only while it is DEFAULT: a non-default "
                 ~ "one is state invented by the revert",
                   family, plane, rev.length, pre.length, i, rev[i]));
}

private void assertGrownWithDefaultTail(string family, string plane,
                                        const(ulong)[] pre, const(ulong)[] rev)
{
    assert(rev.length >= pre.length,
        format("%s: `%s` came back SHORTER than pre-op (%d < %d) — the "
             ~ "recorded residual is a plane left GROWN, never one truncated",
               family, plane, rev.length, pre.length));
    foreach (i; 0 .. pre.length)
        assert(rev[i] == pre[i],
            format("%s: `%s`[%d] came back as %d against a pre-op %d. THIS IS "
                 ~ "THE CHECK THE PLANE'S NAME COULD NOT MAKE: the family is "
                 ~ "allowed to leave this array GROWN (values intact, tail "
                 ~ "defaulted) and is NOT allowed to lose a value in it. A "
                 ~ "family that loses one is not armed by this stage — that is "
                 ~ "the rule `bevelVerticesByMask` is refused under",
                   family, plane, i, rev[i], pre[i]));
    foreach (i; pre.length .. rev.length)
        assert(rev[i] == 0,
            format("%s: `%s` was left grown to %d (pre-op %d) and tail element "
                 ~ "%d is %d, not 0. `finalizeTopologyEdit`'s resize defaults "
                 ~ "the tail; a non-default one is state the revert invented",
                   family, plane, rev.length, pre.length, i, rev[i]));
}

private void assertPostOpTruncated(string family, string plane,
                                   const(int)[] post, const(int)[] rev)
{
    foreach (i; 0 .. rev.length)
    {
        immutable int want = i < post.length ? post[i] : 0;
        assert(rev[i] == want,
            format("%s: `%s`[%d] came back as %d; the post-op value there was "
                 ~ "%d. This plane's recorded residual is `the revert restored "
                 ~ "the LENGTH and left the contents alone`, so an element "
                 ~ "that is neither the post-op value nor the zero-extension "
                 ~ "means the revert PARTIALLY restored it — half a restore is "
                 ~ "a state neither the pre-op nor the post-op mesh ever had",
                   family, plane, i, rev[i], want));
    }
}

private void assertResidualLaw(string family, string plane,
                               MeshSnapshot pre, MeshSnapshot post,
                               MeshSnapshot rev)
{
    final switch (residualLaw(family, plane))
    {
        case ResidualLaw.selectBitOnly:
            if (plane == "vertexMarks")
                assertSelectBitOnly(family, plane, pre.vertexMarks, rev.vertexMarks);
            else if (plane == "edgeMarks")
                assertSelectBitOnly(family, plane, pre.edgeMarks, rev.edgeMarks);
            else
                assertSelectBitOnly(family, plane, pre.faceMarks, rev.faceMarks);
            break;

        case ResidualLaw.grownWithDefaultTail:
            if (plane == "vertexSetMask")
                assertGrownWithDefaultTail(family, plane,
                                           pre.vertexSetMask, rev.vertexSetMask);
            else
                assertGrownWithDefaultTail(family, plane,
                                           pre.faceSetMask, rev.faceSetMask);
            break;

        case ResidualLaw.postOpTruncated:
            if (plane == "vertexSelectionOrder")
                assertPostOpTruncated(family, plane,
                                      post.vertexSelectionOrder,
                                      rev.vertexSelectionOrder);
            else if (plane == "edgeSelectionOrder")
                assertPostOpTruncated(family, plane,
                                      post.edgeSelectionOrder,
                                      rev.edgeSelectionOrder);
            else
                assert(rev.vertexSelectionOrderCounter == post.vertexSelectionOrderCounter
                    && rev.edgeSelectionOrderCounter   == post.edgeSelectionOrderCounter
                    && rev.faceSelectionOrderCounter   == post.faceSelectionOrderCounter,
                    format("%s: the order counters came back %d/%d/%d; the "
                         ~ "post-op values were %d/%d/%d and the pre-op ones "
                         ~ "%d/%d/%d. The recorded residual is `the revert "
                         ~ "leaves the counters where the kernel tail put "
                         ~ "them`; a THIRD value is a partial restore",
                           family,
                           rev.vertexSelectionOrderCounter,
                           rev.edgeSelectionOrderCounter,
                           rev.faceSelectionOrderCounter,
                           post.vertexSelectionOrderCounter,
                           post.edgeSelectionOrderCounter,
                           post.faceSelectionOrderCounter,
                           pre.vertexSelectionOrderCounter,
                           pre.edgeSelectionOrderCounter,
                           pre.faceSelectionOrderCounter));
            break;

        case ResidualLaw.facePermutedLengthOnly:
            assert(rev.faceSelectionOrder.length >= rev.faces.length,
                format("%s: `faceSelectionOrder` came back with %d entr(ies) "
                     ~ "for %d restored face(s). Its VALUES carry the face "
                     ~ "permutation and are deliberately unclaimed here (see "
                     ~ "`ResidualLaw.facePermutedLengthOnly`), but an array "
                     ~ "shorter than the face count is an out-of-bounds read "
                     ~ "waiting for the next selection query",
                       family, rev.faceSelectionOrder.length, rev.faces.length));
            break;
    }
}

private void assertRevertShape(string name, ref Mesh m, ref MeshEditDelta d,
                               PreState pre, in string[] expectedResidual)
{
    assert(countKind(d, MeshOpEntry.Kind.FaceReindex) >= 1,
        format("%s: the op-log carries NO FaceReindex entry (%s) — this "
             ~ "kernel's `mesh_planes.rewriteFaces` call is no longer inside "
             ~ "a `faceReindexScope()`, or no longer reaches the primitive at "
             ~ "all. Everything below would then measure the DISARMED path",
               name, kindsOf(d)));

    // The POST-OP state, captured before the revert runs: two of the four
    // residual laws below are statements about what the revert did NOT touch,
    // and there is no way to say that without it.
    auto postSnap = MeshSnapshot.capture(m);

    immutable bool ok = d.revert(m);
    assert(ok, format("%s: revert() refused the delta outright (%s)",
                      name, kindsOf(d)));

    auto rev = dumpMeshPlanes(m);
    auto got = diffMeshPlanes(pre.planes, rev).split(", ");
    string[] gotClean;
    foreach (g; got) if (g.strip.length) gotClean ~= g.strip;
    gotClean.sort();

    string[] want = expectedResidual.dup;
    want.sort();

    assert(gotClean == want,
        format("%s: the armed revert's residual moved.\n  expected exactly: "
             ~ "[%s]\n  measured        : [%s]\n%s\n"
             ~ "A SHORTER list means a gap closed — good news, and this row "
             ~ "moves with it (and so does the plan's §5.5 note that owes it). "
             ~ "A LONGER one means the arming, or Stage J's corner carry, "
             ~ "stopped restoring something it did restore on 2026-08-27; "
             ~ "a plane named here that is NOT Select-class and NOT an array "
             ~ "length is the line this stage draws, and the family must come "
             ~ "back OUT of the armed set",
               name, want.join(", "), gotClean.join(", "),
               explainMeshPlaneDiff(pre.planes, rev)));

    // AND WHAT SHAPE EACH OF THEM HAS. The list above says only that these
    // planes moved; without the laws below, a value overwritten inside a plane
    // the list already names is indistinguishable from the resize the list is
    // recording — measured green under exactly that damage (MAJOR-1).
    auto revSnap = MeshSnapshot.capture(m);
    foreach (plane; gotClean)
        assertResidualLaw(name, plane, pre.snap, postSnap, revSnap);

    // The half that must NEVER be in the residual, stated positively so a
    // future edit to `expectedResidual` cannot smuggle one of these in.
    // `surfaces` and the three set-NAME registries joined this list with the
    // planes themselves (Stage K review, MINOR-5): they were measured inert on
    // every family, and an inert plane nobody asserts is one nobody notices
    // moving.
    foreach (plane; ["counts", "vertices", "faces", "edges",
                     "faceMaterial", "facePart", "faceSetMask", "map:uv", "map:W",
                     "surfaces", "vertexSetNames", "edgeSetNames",
                     "polygonSetNames"]) {
        assert(rev[plane] == pre.planes[plane],
            format("%s: `%s` is what a FaceReindex entry is the PUBLISHER "
                 ~ "for (or, for the two maps, what Stage J's CornerCarry and "
                 ~ "the vertex path owe), and the armed revert did not "
                 ~ "restore it. This is not a residual to record — it is the "
                 ~ "condition under which Stage K leaves a family UNARMED "
                 ~ "(as it does `bevelVerticesByMask`, `bevelEdgesByMask` and "
                 ~ "`arrayFacesGrid`).%s",
                   name, plane, explainMeshPlaneDiff(pre.planes, rev)));
    }
}

/// The Select bit, in isolation from the two bits sharing its word — the
/// anti-vacuity guard for the whole residual story. If Subpatch/Hide were also
/// lost, "the residual is Select-class" would be a mis-attribution.
private void assertNonSelectMarksSurvive(string name, ref Mesh m)
{
    assert(m.isFaceSubpatch(1),
        name ~ ": face 1's Subpatch bit did not come back. The residual this "
             ~ "stage records is the SELECT bit of faceMarks; Subpatch and "
             ~ "Hide sit in the same word and are carried by the same entry, "
             ~ "so losing them means the word is not being carried at all");
    assert(m.isFaceHidden(5),
        name ~ ": face 5's Hide bit did not come back — same word as Select, "
             ~ "same entry, and it is what tells a Select-only residual from "
             ~ "a lost faceMarks");
}

unittest // armed: Mesh.triangulateFacesByMask
{
    Mesh m = makeTaggedGridFull();
    auto pre = capturePre(m);
    size_t n;
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry | MeshEditScope.Marks);
        n = ed.triangulateFacesByMask(faceMaskOf(ed.mesh, 0u, 4u));
        d = ed.close();
    }
    assert(n == 2 && m.faces.length == 11,
        format("the stand triangulated %d face(s) to F=%d, expected 2 and 11 "
             ~ "— every assertion below is vacuous on a no-op",
               n, m.faces.length));
    assertRevertShape("triangulateFacesByMask", m, d, pre,
                      ["edgeMarks", "faceMarks"]);
    assertNonSelectMarksSurvive("triangulateFacesByMask", m);
}

unittest // armed: mesh.rebuildFacesWithChordSplits — the Stage L2-d site
{
    // `splitFaceByVertices` is the one production caller that reaches this
    // kernel with a single-face mask; `mesh_ops/cut.d`'s plane cut and
    // `edgeSliceEx` are the others and belong to L4.
    //
    // Face 4 of the tagged grid is the interior quad [5, 6, 10, 9]; 5 and 10
    // are its diagonal, i.e. a NON-ADJACENT pair, which is the whole
    // precondition — an adjacent pair is refused and the cell would be vacuous.
    Mesh m = makeTaggedGridFull();
    auto pre = capturePre(m);
    size_t n;
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry);
        n = ed.mesh.splitFaceByVertices(4, 5, 10);
        d = ed.close();
    }
    assert(n == 1 && m.faces.length == 10,
        format("the stand split %d face(s) to F=%d, expected 1 and 10 — every "
             ~ "assertion below is vacuous on a no-op", n, m.faces.length));
    // MEASURED, and it is the SHORTEST residual of the eight armed families:
    // the Select bit of `edgeMarks` (dropped by the kernel's own
    // `clearEdgeSelectionResize` tail, after the rewrite) and the
    // `faceSelectionOrder` stamps. `faceMarks` is NOT here — the kernel
    // re-applies each parent's Select bit onto its emitted slots through
    // `setFacesSelectedFrom`, so the face layer round-trips — and neither are
    // `faceMaterial`, `facePart` or `faceSetMask`, which is the whole point of
    // routing through `rewriteFaces`: the primitive carries all five per-face
    // planes through the correspondence and `Kind.FaceReindex` restores them.
    // Under the cheaper `AddFaces` + `ReshapeFaces` route those three would
    // come back SHIFTED BY ONE and would each need naming here.
    assertRevertShape("rebuildFacesWithChordSplits", m, d, pre,
                      ["edgeMarks", "faceSelectionOrder"]);
    assertNonSelectMarksSurvive("rebuildFacesWithChordSplits", m);
}

unittest // armed: mesh_ops.extrude.extrudeVerticesByMask
{
    Mesh m = makeTaggedGridFull();
    auto pre = capturePre(m);
    size_t n;
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry | MeshEditScope.Marks);
        n = extrudeVerticesByMask(ed, vertMaskOf(ed.mesh, 5u), 0.5f, 0.2f);
        d = ed.close();
    }
    assert(n == 1 && m.faces.length == 17,
        format("the stand extruded %d vertex/vertices to F=%d, expected 1 and "
             ~ "17", n, m.faces.length));
    assertRevertShape("extrudeVerticesByMask", m, d, pre,
                      ["edgeMarks", "faceMarks"]);
    assertNonSelectMarksSurvive("extrudeVerticesByMask", m);
}

unittest // armed: mesh_ops.extrude.extrudeFacesByMask — the `&rw` site Stage J unblocked
{
    Mesh m = makeTaggedGridFull();
    auto pre = capturePre(m);
    size_t n;
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry | MeshEditScope.Marks);
        n = extrudeFacesByMask(ed, faceMaskOf(ed.mesh, 4u), 0.5f);
        d = ed.close();
    }
    assert(n == 1 && m.faces.length == 13,
        format("the stand extruded %d face(s) to F=%d, expected 1 and 13",
               n, m.faces.length));

    // The corner payload Stage J added rides IMMEDIATELY BEFORE the face entry
    // — the adjacency is contractual and it is what makes `map:uv` come back
    // below. Asserted here rather than left to the plane check: without it, a
    // stand whose UV happened to be zero would pass the plane check too.
    assert(countKind(d, MeshOpEntry.Kind.MeshMapDelta) == 1,
        format("the armed face extrude logged %d MeshMapDelta entr(ies), "
             ~ "expected 1 — `mesh_planes.rewriteFaces` records the pre-op "
             ~ "corner values immediately before the FaceReindex entry, and "
             ~ "without that payload the reverse zeroes the whole UV map "
             ~ "(task 1903 Stage J). Log %s",
               countKind(d, MeshOpEntry.Kind.MeshMapDelta), kindsOf(d)));

    assertRevertShape("extrudeFacesByMask", m, d, pre,
                      ["edgeMarks", "faceMarks", "faceSelectionOrder",
                       "orderCounters", "vertexMarks",
                       "vertexSelectionOrder"]);
    assertNonSelectMarksSurvive("extrudeFacesByMask", m);
}

unittest // armed: mesh_ops.extrude.smoothShiftFacesByMask
{
    Mesh m = makeTaggedGridFull();
    auto pre = capturePre(m);
    size_t n;
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry | MeshEditScope.Marks);
        n = smoothShiftFacesByMask(ed, faceMaskOf(ed.mesh, 4u), 0.5f, 1.0f, false);
        d = ed.close();
    }
    assert(n == 1 && m.faces.length == 13,
        format("the stand smooth-shifted %d face(s) to F=%d, expected 1 and 13",
               n, m.faces.length));
    assertRevertShape("smoothShiftFacesByMask", m, d, pre,
                      ["edgeMarks", "faceMarks", "faceSelectionOrder",
                       "orderCounters", "vertexMarks",
                       "vertexSelectionOrder"]);
    assertNonSelectMarksSurvive("smoothShiftFacesByMask", m);
}

unittest // armed: mesh_ops.loop_slice.insertEdgeLoopsMulti — the second `&rw` site
{
    Mesh m = makeTaggedGridFull();
    auto pre = capturePre(m);
    bool ok;
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, kLoopSliceEditScope);
        uint[] nfi;
        ok = insertEdgeLoopsMulti(ed, [ed.mesh.edgeIndex(0, 1)], [0.5f], nfi);
        d = ed.close();
    }
    assert(ok && m.faces.length == 12,
        format("the stand cut %s to F=%d, expected true and 12",
               ok, m.faces.length));
    assert(countKind(d, MeshOpEntry.Kind.MeshMapDelta) == 1,
        format("the armed loop slice logged %d MeshMapDelta entr(ies), "
             ~ "expected 1 — see the face-extrude cell for why the payload is "
             ~ "asserted separately. Log %s",
               countKind(d, MeshOpEntry.Kind.MeshMapDelta), kindsOf(d)));
    assertRevertShape("insertEdgeLoopsMulti", m, d, pre,
                      ["edgeMarks", "edgeSelectionOrder", "faceMarks",
                       "faceSelectionOrder", "orderCounters", "vertexMarks",
                       "vertexSelectionOrder"]);
    assertNonSelectMarksSurvive("insertEdgeLoopsMulti", m);
}

unittest // armed: mesh_ops.cleanup.cleanDegenerateFaces
{
    Mesh m = mixedBatchStand();
    auto pre = capturePre(m);
    size_t n;
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, kCleanupEditScope);
        n = cleanDegenerateFaces(ed);
        d = ed.close();
    }
    assert(n == 1 && m.faces[8].length == 3,
        format("the stand cleaned %d face(s), face 8 arity %d — expected 1 "
             ~ "and 3", n, m.faces[8].length));
    assertRevertShape("cleanDegenerateFaces", m, d, pre,
                      ["edgeMarks", "edgeSelectionOrder", "faceMarks"]);
    assertNonSelectMarksSurvive("cleanDegenerateFaces", m);
}

unittest // armed: mesh_ops.revolve.extrudePathStep_, through extrudeAlongPath
{
    Mesh m = makeTaggedGridFull();
    auto pre = capturePre(m);
    size_t n;
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, kRevolveEditScope);
        n = extrudeAlongPath(ed, faceMaskOf(ed.mesh, 4u),
                             [Vec3(0, 0, 0), Vec3(0, 0, 0.5f), Vec3(0, 0, 1.0f)]);
        d = ed.close();
    }
    assert(n == 8 && m.faces.length == 17,
        format("the stand swept %d face(s) to F=%d, expected 8 and 17",
               n, m.faces.length));

    // TWO path spans, so `extrudePathStep_` runs TWICE and each run opens its
    // OWN scope: two payload+entry PAIRS, in that order. A single scope held
    // across both runs would still produce two entries, so the count alone is
    // not the discriminator — the PAIRING is, and an orphaned FaceReindex is
    // exactly what zeroes a UV map (measured on `bevelEdgesByMask`, which is
    // why that family is not armed).
    assert(countKind(d, MeshOpEntry.Kind.FaceReindex) == 2
        && countKind(d, MeshOpEntry.Kind.MeshMapDelta) == 2,
        format("a two-span sweep logged %d FaceReindex and %d MeshMapDelta "
             ~ "entr(ies), expected 2 and 2 — one PAIR per `extrudePathStep_` "
             ~ "call. A FaceReindex without its own payload declines the "
             ~ "corner carry on reverse and zeroes the map. Log %s",
               countKind(d, MeshOpEntry.Kind.FaceReindex),
               countKind(d, MeshOpEntry.Kind.MeshMapDelta), kindsOf(d)));

    assertRevertShape("extrudeAlongPath", m, d, pre,
                      ["edgeMarks", "faceMarks", "faceSelectionOrder",
                       "orderCounters", "vertexMarks",
                       "vertexSelectionOrder"]);
    assertNonSelectMarksSurvive("extrudeAlongPath", m);
}

// ---------------------------------------------------------------------------
// 3. THE ARMED SET, AS A SOURCE CENSUS.
// ---------------------------------------------------------------------------

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// Every `faceReindexScope()` call in production source, as
/// `"<relative path>:<enclosing function>"`.
///
/// KEYED ON THE ENCLOSING FUNCTION, NOT A LINE NUMBER, deliberately: a line
/// number in a test is a citation that rots on the next edit above it, and
/// this file already carries one lesson about that (task 1903 Stage J review,
/// MINOR-3). The function name is what the arm/do-not-arm decision is ABOUT.
private bool isArmCallLine(string line)
{
    immutable string s = line.strip;
    if (s.indexOf("faceReindexScope()") < 0) return false;
    if (s.startsWith("//") || s.startsWith("*")) return false;
    // The DECLARATION of the scope itself is not a use of it. Matched by the
    // return type, which no call site carries.
    if (s.indexOf("FaceReindexArm faceReindexScope()") >= 0) return false;
    return true;
}

private string[] scanArmSites(string rel, string text)
{
    import std.regex : ctRegex, matchFirst;

    // A D function declaration at column 0 (the `mesh_ops/` free functions) or
    // at four spaces (`Mesh`'s methods). The captured group is the declared
    // name. Deliberately anchored and deliberately NOT matching a statement:
    // the blacklist below is the second half of that, because
    // `size_t n = f(x)` and `assert(...)` both parse as "identifier, paren".
    enum declRe = ctRegex!(`^(?: {4})?(?:private |public |package |static |final |override |const |inout )*`
                         ~ `[A-Za-z_][A-Za-z0-9_.!\[\]\(\)]*[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(`);
    static immutable string[] notADecl = [
        "if", "assert", "foreach", "foreach_reverse", "while", "switch",
        "return", "catch", "version", "debug", "scope", "with", "cast",
        "enforce", "format", "static",
    ];

    // NESTING IS RESOLVED BY BRACE DEPTH, NOT BY INDENT, and that is not
    // fussiness: four of the seven armed kernels contain a NESTED helper
    // (`extrude.d`'s `ivKey` / `predInFace_`, `loop_slice.d`'s
    // `splitFaceTracked`, `revolve.d`'s `newPos`) declared at exactly the
    // indentation a `Mesh` method uses, and an indent rule attributes the arm
    // to the helper. Measured: the first draft of this census reported
    // `extrude.d:ivKey` twice.
    //
    // A declaration counts as an OWNER only at depth 0 (a module-level free
    // function) or depth 1 (a member of a module-level aggregate). Anything
    // deeper is a nested helper and is skipped.
    enum aggRe = ctRegex!(`^(?:private |public |package |static |final |abstract |extern\S* )*`
                        ~ `(?:struct|class|union|interface|template)[ \t]`);

    string[] out_;
    auto lines = text.split("\n");
    int depth = 0;
    bool aggregateAtTop = false;   // is the depth-0 construct a struct/class?
    string owner = "<unresolved>";
    foreach (line; lines) {
        immutable string t = line.strip;
        immutable bool comment = t.startsWith("//") || t.startsWith("*")
                              || t.startsWith("/*");
        if (!comment && depth == 0 && !matchFirst(line, aggRe).empty)
            aggregateAtTop = true;
        // Depth 0 is a module-level declaration; depth 1 is a member ONLY when
        // the depth-0 construct is an aggregate. Inside a FUNCTION body depth
        // is also 1, and that is where the nested helpers live — accepting
        // depth 1 unconditionally is what made the first draft answer
        // `extrude.d:ivKey`.
        immutable bool ownerLevel = depth == 0 || (depth == 1 && aggregateAtTop);
        if (!comment && ownerLevel) {
            auto mm = matchFirst(line, declRe);
            if (!mm.empty) {
                immutable string nm = mm[1];
                bool skip = false;
                foreach (kw; notADecl) if (nm == kw) { skip = true; break; }
                if (!skip) owner = nm;
            }
        }
        if (isArmCallLine(line)) out_ ~= rel ~ ":" ~ owner;
        if (comment) continue;
        // Braces, with `//` tails and the `'{'`/`'}'` character literals that
        // appear in this tree's parsers removed first.
        string code = line;
        immutable ptrdiff_t c = code.indexOf("//");
        if (c >= 0) code = code[0 .. c];
        foreach (lit; ["'{'", "'}'", "\"{\"", "\"}\""])
            while (code.indexOf(lit) >= 0) {
                immutable ptrdiff_t k = code.indexOf(lit);
                code = code[0 .. k] ~ code[k + lit.length .. $];
            }
        foreach (ch; code) {
            if (ch == '{') ++depth;
            else if (ch == '}') {
                --depth;
                if (depth <= 0) { depth = 0; aggregateAtTop = false; }
            }
        }
    }
    return out_;
}

unittest // the resolver itself, on hand-written text — it is the census's only instrument
{
    // Two shapes and three decoys. Without this cell a resolver that answers
    // `<unresolved>` everywhere would make the census compare one constant
    // list against another constant list.
    immutable string sample =
        "size_t kernelA(ref MeshEditBatch ed, int x)\n"
      ~ "{\n"
      ~ "    assert(x > 0);\n"
      ~ "    if (x == 1) {\n"
      ~ "        { auto arm = ed.faceReindexScope();\n"
      ~ "          rewriteFaces(ed, f, s); }\n"
      ~ "    }\n"
      ~ "}\n"
      ~ "struct S {\n"
      ~ "    void methodB() {\n"
      ~ "        // { auto arm = faceReindexScope(); }  <- a commented-out one\n"
      ~ "        /// { auto arm = faceReindexScope(); } <- and a doc example\n"
      ~ "        { auto arm = faceReindexScope();\n"
      ~ "          rewriteFaces(this, f, s); }\n"
      ~ "    }\n"
      ~ "    FaceReindexArm faceReindexScope() { return FaceReindexArm.init; }\n"
      ~ "}\n"
      ~ "size_t kernelC(ref MeshEditBatch ed)\n"
      ~ "{\n"
      ~ "    uint nestedHelper(uint a) { return a; }\n"
      ~ "    { auto arm = ed.faceReindexScope();\n"
      ~ "      rewriteFaces(ed, f, s); }\n"
      ~ "}\n";
    auto got = scanArmSites("x.d", sample);
    assert(got == ["x.d:kernelA", "x.d:methodB", "x.d:kernelC"],
        format("the arm-site resolver answered %s, expected "
             ~ "[x.d:kernelA, x.d:methodB, x.d:kernelC]. It must see through "
             ~ "an `assert(`, an `if (`, a `//` and a `///` line; it must not "
             ~ "count the scope's own DECLARATION as a use; and it must "
             ~ "attribute an arm to the ENCLOSING KERNEL, not to a nested "
             ~ "helper declared just above it (`kernelC` — the shape that "
             ~ "made the first draft report `extrude.d:ivKey`). If it cannot, "
             ~ "the census below is comparing noise", got));
}

/// The set this stage MEASURED and armed, 2026-08-27, plus the one stage L2-d
/// added on 2026-08-28. Every entry earned its place by a full-state revert
/// diff on a `makeTaggedGridFull` stand (block 2); every kernel that reaches
/// `mesh_planes.rewriteFaces` and is NOT here was measured too, and its refusal
/// is written at its own call site.
///
/// `rebuildFacesWithChordSplits` IS THE L2-d ENTRY, and it did not merely gain
/// an arm — it gained the `rewriteFaces` CALL. Until then it installed its
/// result with a raw `faces._store = newFacesArr;` plus five hand-rebuilt plane
/// assignments, so a recording batch came back with an EMPTY op-log and
/// `revert()` answered `true` with the chord split still in. Three of those
/// five planes (`faceMaterial`, `facePart`, `faceSetMask`) have no restorer
/// outside `Kind.RemoveFaces`, which is why the route is `FaceReindex` and not
/// the cheaper `AddFaces` + `ReshapeFaces`.
private static immutable string[] kArmedSites = [
    "source/mesh.d:rebuildFacesWithChordSplits",
    // Task 1903 Stage L5-a. The weld's apply half, reached by
    // `weldCoincidentVertices` and therefore by `mesh_ops/cleanup.cleanupMesh`
    // (L5), by `arrayFaces` / `radialArrayFaces` / `mirrorFacesPlane` (L6) and
    // by the reduce family (L10). Its TWIN `applyVertexRemapAndRebuild` — same
    // file, reached by `weldVertexPairs` — is deliberately NOT here: L5
    // measured this one and left the other to L10, and the two are separable
    // on purpose. Adding the twin without its own measured residual row in
    // block 2 is the mutation this census exists to redden.
    "source/mesh.d:applyVertexRemap",
    "source/mesh.d:triangulateFacesByMask",
    "source/mesh_ops/cleanup.d:cleanDegenerateFaces",
    "source/mesh_ops/extrude.d:extrudeFacesByMask",
    "source/mesh_ops/extrude.d:extrudeVerticesByMask",
    "source/mesh_ops/extrude.d:smoothShiftFacesByMask",
    "source/mesh_ops/loop_slice.d:insertEdgeLoopsMulti",
    "source/mesh_ops/revolve.d:extrudePathStep_",
];

private string[] productionTargets()
{
    string[] targets = [buildPath(repoRoot, "source", "mesh.d")];
    immutable opsDir = buildPath(repoRoot, "source", "mesh_ops");
    assert(exists(opsDir) && isDir(opsDir),
           "the census cannot find source/mesh_ops/ at " ~ opsDir);
    foreach (entry; dirEntries(opsDir, SpanMode.shallow)) {
        if (!entry.isFile) continue;
        if (entry.name.length < 2 || entry.name[$ - 2 .. $] != ".d") continue;
        targets ~= entry.name;
    }
    // `mesh_edit_delta.d` calls `rewriteFaces` too — on the REPLAY path, where
    // no batch is recording — so it is scanned as well: an arm appearing there
    // would mean a replay re-recording its own entry.
    targets ~= buildPath(repoRoot, "source", "mesh_edit_delta.d");
    targets ~= buildPath(repoRoot, "source", "mesh_planes.d");
    return targets;
}

unittest // the census: exactly these kernels arm FaceReindex, and no others
{
    string[] found;
    size_t scanned;
    foreach (f; productionTargets()) {
        found ~= scanArmSites(relativePath(f, repoRoot), readText(f));
        ++scanned;
    }
    assert(scanned >= 12,
        format("only %d file(s) scanned — the walk is not reaching the tree "
             ~ "it claims to guard (source/mesh_ops/ alone has 15 files as of "
             ~ "this writing), so an empty result would mean nothing", scanned));

    found.sort();
    string[] want = kArmedSites.dup;
    want.sort();

    assert(found == want,
        format("the set of kernels arming `Kind.FaceReindex` moved.\n"
             ~ "  expected: %s\n  found   : %s\n"
             ~ "A NEW entry: Stage K measured every `rewriteFaces` caller and "
             ~ "left three out on purpose — `Mesh.arrayFacesGrid` (its own "
             ~ "growth is hook-free, so a delta describes only the weld pass "
             ~ "and lands on a third mesh while answering true — which it "
             ~ "already does DISARMED, so arming would not be the cause and "
             ~ "is not the cure; L6 owes it a publisher at its two appends), "
             ~ "`bevel_vertex.bevelVerticesByMask` (the revert loses "
             ~ "per-vertex map VALUES, not just Select bits) and "
             ~ "`edge_bevel.bevelEdgesByMask` (its second rewrite cannot "
             ~ "record a corner payload, so the entry is orphaned and the "
             ~ "reverse zeroes the UV map).\nTHAT LAST REFUSAL HAS A SECOND, "
             ~ "INDEPENDENT GROUND measured on 2026-08-28 (task 2320, stage "
             ~ "L7-P1), and it is the one that decides when the arm can land. "
             ~ "The orphaned-payload half above is closable — a prototype "
             ~ "giving each of the two rewrites its OWN corner-provenance "
             ~ "handle produced one `MeshMapDelta` per `FaceReindex` and an "
             ~ "armed revert with 0 of 72 UV floats differing (against 71 of "
             ~ "72 under the shared handle; not 72, because the stand\'s "
             ~ "corner 0 is already 0). That prototype is NOT in the tree: it "
             ~ "is observable from no lane while the family is unarmed, so it "
             ~ "waits. What it uncovered is: the armed revert ALSO loses a "
             ~ "Point-domain map VALUE — `map:W` zeroed at the two consumed "
             ~ "endpoints, because `removeVertsReverse` re-inserts a dropped "
             ~ "vertex with its Point-map values zeroed. That is a lost VALUE, "
             ~ "which this block refuses outright, so ARMING THIS FAMILY IS "
             ~ "GATED ON `Kind.RemoveVerts` CARRYING POINT-DOMAIN MAP VALUES "
             ~ "and on nothing else. Until then this roster stays at nine. "
             ~ "Each refusal is written at its "
             ~ "call site with the measurement; read it before adding an arm "
             ~ "there.\nA MISSING entry: a family lost its arming, and its "
             ~ "recorded revert is back to throwing or to silently dropping "
             ~ "the face change (plan §5.3)",
               want.join("\n            "), found.join("\n            ")));
}

// ---------------------------------------------------------------------------
// 3b. THE SECOND CENSUS TERM — the FLAG, not the spelling of the scope.
// ---------------------------------------------------------------------------
//
// The census above pins the set of lines that say `faceReindexScope()`. It
// cannot pin the RULE, because `MeshEditTracker.wantsFaceReindex` is a PUBLIC
// field (`source/mesh_edit_delta.d`) and a kernel can arm itself without
// spelling the scope at all.
//
// Measured, not argued (Stage K review, MAJOR-2): with
//
//     if (ed.mesh.isRecordingEdits()) ed.rec().wantsFaceReindex = true;
//
// added to `bevelVerticesByMask` — a BATCH-WIDE arm, i.e. strictly worse than
// a scope because nothing ever puts it back — the arm-site census stayed
// GREEN. What went red was that family's own op-log pin, in a different file,
// by luck: a family without such a pin would have had nothing to catch it.
//
// So the second term is about the field. THE FLAG HAS EXACTLY ONE OWNER —
// `Mesh.FaceReindexArm` and the `faceReindexScope()` factory that fills it —
// and every other line in `source/` that ASSIGNS it is a finding. That is the
// invariant the scope's whole nesting/restore argument rests on: a write from
// anywhere else is a flag whose restore nobody owns.
private string codeOutsideStrings(string line)
{
    string code = line;
    immutable ptrdiff_t c = code.indexOf("//");
    if (c >= 0) code = code[0 .. c];
    foreach (lit; ["'{'", "'}'", "\"{\"", "\"}\""])
        while (code.indexOf(lit) >= 0) {
            immutable ptrdiff_t k = code.indexOf(lit);
            code = code[0 .. k] ~ code[k + lit.length .. $];
        }
    return code;
}

/// Does this line ASSIGN `wantsFaceReindex`?
///
/// The field's own DECLARATION (`bool wantsFaceReindex = false;`) is an
/// initializer, not a write, and is matched out by its leading type — the one
/// exclusion, spelled narrowly so that `something.wantsFaceReindex = false`
/// somewhere else in the tree still counts. A comparison (`== `) is not a
/// write and neither is the read the factory makes when it saves `prev_`.
private bool isFlagWriteLine(string line)
{
    import std.regex : ctRegex, matchFirst;
    enum declRe  = ctRegex!(`^\s*(?:private |public |package )?bool\s+wantsFaceReindex\b`);
    enum writeRe = ctRegex!(`\bwantsFaceReindex\s*=[^=]`);

    immutable string s = line.strip;
    if (s.startsWith("//") || s.startsWith("*") || s.startsWith("/*")) return false;
    if (!matchFirst(line, declRe).empty) return false;
    return !matchFirst(codeOutsideStrings(line), writeRe).empty;
}

/// The line ranges (0-based, inclusive) of the two blocks that OWN the flag.
/// Empty for every file but `source/mesh.d`.
private size_t[2][] flagOwnerRanges(string[] lines)
{
    size_t[2][] ranges;
    foreach (i, line; lines) {
        immutable string t = line.strip;
        if (t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")) continue;
        immutable bool isOwner = t.startsWith("struct FaceReindexArm")
                              || t.indexOf("FaceReindexArm faceReindexScope()") >= 0;
        if (!isOwner) continue;
        int depth = 0;
        bool opened = false;
        foreach (j; i .. lines.length) {
            foreach (ch; codeOutsideStrings(lines[j])) {
                if (ch == '{') { ++depth; opened = true; }
                else if (ch == '}') --depth;
            }
            if (opened && depth <= 0) { ranges ~= [i, j]; break; }
        }
    }
    return ranges;
}

/// Flag writes in `text` that are OUTSIDE the owner blocks, as
/// `"<rel>:<line> <statement>"`. `insideCount` counts the ones inside, which
/// is the anti-vacuity term: a range walk that swallowed the whole file would
/// otherwise report an empty finding list and read as a clean tree.
private string[] scanFlagWrites(string rel, string text, out size_t insideCount)
{
    auto lines  = text.split("\n");
    auto owned  = flagOwnerRanges(lines);
    string[] out_;
    insideCount = 0;
    foreach (i, line; lines) {
        if (!isFlagWriteLine(line)) continue;
        bool inside = false;
        foreach (r; owned) if (i >= r[0] && i <= r[1]) { inside = true; break; }
        if (inside) ++insideCount;
        else out_ ~= format("%s:%d %s", rel, i + 1, line.strip);
    }
    return out_;
}

unittest // the flag-write resolver, on hand-written text
{
    // Without this cell a resolver that answered "no writes anywhere" would
    // make the census below compare an empty list against an empty list — the
    // exact vacuity that let the batch-wide arm through in the first place.
    immutable string sample =
        "struct MeshEditTracker {\n"
      ~ "    bool wantsFaceReindex = false;\n"     // the DECLARATION, not a write
      ~ "}\n"
      ~ "struct Mesh {\n"
      ~ "    struct FaceReindexArm {\n"
      ~ "        ~this() {\n"
      ~ "            rec_.wantsFaceReindex = prev_;\n"        // owned
      ~ "        }\n"
      ~ "    }\n"
      ~ "    FaceReindexArm faceReindexScope() {\n"
      ~ "        a.prev_ = a.rec_.wantsFaceReindex;\n"        // a READ
      ~ "        if (a.rec_ !is null) a.rec_.wantsFaceReindex = true;\n"  // owned
      ~ "    }\n"
      ~ "    void somethingElse() {\n"
      ~ "        // rec_.wantsFaceReindex = true;  <- commented out\n"
      ~ "        if (rec_.wantsFaceReindex == true) return;\n"  // a COMPARISON
      ~ "        rec_.wantsFaceReindex = true;\n"             // THE FINDING
      ~ "    }\n"
      ~ "}\n";
    size_t inside;
    auto got = scanFlagWrites("x.d", sample, inside);
    assert(inside == 2,
        format("the resolver placed %d write(s) inside the owner blocks, "
             ~ "expected 2 (the destructor's restore and the factory's set). "
             ~ "Zero would mean the range walk found no owner at all, and the "
             ~ "census would then report a clean tree for the wrong reason",
               inside));
    assert(got == ["x.d:17 rec_.wantsFaceReindex = true;"],
        format("the resolver answered %s. It must skip the field DECLARATION, "
             ~ "a `//`-commented write, a `==` comparison and the factory's "
             ~ "READ of the previous value, and it must report the one write "
             ~ "that sits outside both owner blocks", got));
}

/// Every `.d` file under `source/`. WIDER than `productionTargets()` above on
/// purpose: the arm-site census only has to look where `rewriteFaces` is
/// called, but a bare `wantsFaceReindex = true` needs no rewrite anywhere near
/// it and would arm every rewrite the batch runs afterwards from any file at
/// all.
private string[] productionSourceTree()
{
    immutable srcDir = buildPath(repoRoot, "source");
    assert(exists(srcDir) && isDir(srcDir),
           "the flag census cannot find source/ at " ~ srcDir);
    string[] targets;
    foreach (entry; dirEntries(srcDir, SpanMode.depth)) {
        if (!entry.isFile) continue;
        if (entry.name.length < 2 || entry.name[$ - 2 .. $] != ".d") continue;
        targets ~= entry.name;
    }
    return targets;
}

unittest // the flag has ONE owner, and it is the arm primitive
{
    string[] findings;
    size_t scanned, insideTotal;
    foreach (f; productionSourceTree()) {
        size_t inside;
        findings ~= scanFlagWrites(relativePath(f, repoRoot), readText(f), inside);
        insideTotal += inside;
        ++scanned;
    }
    assert(scanned >= 100,
        format("only %d file(s) under source/ scanned — an empty finding list "
             ~ "would then mean the walk, not the tree", scanned));
    assert(insideTotal == 2,
        format("%d flag write(s) sit inside `Mesh.FaceReindexArm` / "
             ~ "`faceReindexScope()`, expected 2 (the destructor's restore and "
             ~ "the factory's set). Fewer means the arm primitive itself "
             ~ "changed shape and this census is now measuring nothing; more "
             ~ "means the owner grew a write that has to be argued",
               insideTotal));

    assert(findings.length == 0,
        format("`MeshEditTracker.wantsFaceReindex` is written outside its one "
             ~ "owner:\n            %s\n"
             ~ "The field is PUBLIC, so a kernel can arm itself without ever "
             ~ "spelling `faceReindexScope()` — and the census above, which "
             ~ "reads that spelling, stays green while it does (Stage K "
             ~ "review, MAJOR-2: a batch-wide arm planted in "
             ~ "`bevelVerticesByMask` was caught only by that family's own "
             ~ "op-log pin, in another file, by luck).\n"
             ~ "A bare write is STRICTLY WORSE than the scope it imitates: "
             ~ "nothing restores it, so every later rewrite in the batch is "
             ~ "armed too, and one that already records `RemoveFaces` then "
             ~ "double-reverts (plan §5.3). Arm through "
             ~ "`{ auto arm = ed.faceReindexScope(); rewriteFaces(…); }` and "
             ~ "add the kernel to `kArmedSites` with its measured residual",
               findings.join("\n            ")));
}

unittest // the SHAPE: one scope per rewrite, never one scope spanning two
{
    // The plan asked for TWO scopes in `edge_bevel.bevelEdgesByMask` rather
    // than one spanning both of its rewrites. That family is measured UNARMED,
    // so no behavioural cell can show the difference today — and on today's
    // tree nothing that records sits BETWEEN those two calls, so even armed
    // the two shapes would produce identical logs. The law is therefore pinned
    // where it is actually observable: in the SOURCE.
    //
    // The scope is spelled as a one-statement block at every armed site:
    //
    //     { auto arm = ed.faceReindexScope();
    //       rewriteFaces(ed, newFaces, src); }
    //
    // so the block a scope opens must close after exactly ONE `rewriteFaces(`
    // call. A scope holding two would leave the flag set across whatever sits
    // between them — which is the batch-wide failure at a smaller radius.
    size_t checked;
    foreach (f; productionTargets()) {
        immutable string rel  = relativePath(f, repoRoot);
        auto lines = readText(f).split("\n");
        foreach (i, line; lines) {
            if (!isArmCallLine(line)) continue;
            ++checked;
            // Walk forward to the closing `}` of the block this scope opened,
            // counting braces from the line that opened it.
            int depth = 0;
            size_t rewrites = 0;
            bool closed = false;
            foreach (j; i .. lines.length) {
                foreach (ch; lines[j]) {
                    if (ch == '{') ++depth;
                    else if (ch == '}') {
                        --depth;
                        if (depth <= 0) { closed = true; break; }
                    }
                }
                if (lines[j].indexOf("rewriteFaces(") >= 0) ++rewrites;
                if (closed) break;
            }
            assert(closed,
                format("%s:%d — a `faceReindexScope()` block never closes; "
                     ~ "the census cannot tell what it covers", rel, i + 1));
            assert(rewrites == 1,
                format("%s:%d — this `faceReindexScope()` block covers %d "
                     ~ "`rewriteFaces(` call(s), expected exactly 1. The "
                     ~ "arming is PER REWRITE: a scope spanning two rewrites "
                     ~ "leaves the flag set across everything between them, "
                     ~ "which is the batch-wide failure (plan §5.3, \"K's red "
                     ~ "row\") at a smaller radius, and it is what 1902 §2.6 "
                     ~ "means for `edge_bevel.bevelEdgesByMask`'s two sites. "
                     ~ "Zero calls means the scope is arming nothing at all",
                       rel, i + 1, rewrites));
        }
    }
    assert(checked == kArmedSites.length,
        format("the shape check visited %d scope(s), the census names %d — "
             ~ "the two scans disagree about what exists, so one of them is "
             ~ "reading the wrong tree", checked, kArmedSites.length));
}

unittest // the scope RESTORES: a rewrite after the block is not armed
{
    // The mixed-batch cell above proves this end to end, through two real
    // kernels. This one proves the primitive itself, so a regression in
    // `Mesh.FaceReindexArm.~this` is attributed HERE rather than blamed on
    // whichever kernel pairing happens to expose it.
    Mesh m = makeTaggedGridFull();
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry | MeshEditScope.Marks);
        assert(!ed.mesh.wantsFaceReindexRecording(),
            "a fresh recording batch must start DISARMED — `wantsFaceReindex` "
          ~ "defaults to false and no production site sets it directly");
        {
            auto arm = ed.mesh.faceReindexScope();
            assert(ed.mesh.wantsFaceReindexRecording(),
                "inside the scope the open batch must want FaceReindex "
              ~ "entries — otherwise every armed site above is a no-op and "
              ~ "the whole stage is inert");
        }
        assert(!ed.mesh.wantsFaceReindexRecording(),
            "the scope did not RESTORE on exit. That is the batch-wide flag "
          ~ "wearing a scope's spelling: every later rewrite in the batch is "
          ~ "still armed, and one that already records `RemoveFaces` then "
          ~ "double-reverts (plan §5.3)");

        // Nesting restores to the value it FOUND, not to false.
        {
            auto outer = ed.mesh.faceReindexScope();
            {
                auto inner = ed.mesh.faceReindexScope();
                assert(ed.mesh.wantsFaceReindexRecording(), "nested: armed");
            }
            assert(ed.mesh.wantsFaceReindexRecording(),
                "a nested scope's exit disarmed the OUTER one — the "
              ~ "destructor must put back the value it found, not false");
        }
        assert(!ed.mesh.wantsFaceReindexRecording(), "nested: fully restored");
        d = ed.close();
    }
    assert(d.log.length == 0,
        format("the arming cells above mutated the mesh: %s. They must only "
             ~ "flip a flag, or the scope is being measured through whatever "
             ~ "else they did", kindsOf(d)));
}

unittest // no batch open: the scope is inert and its destructor does not fault
{
    Mesh m = makeTaggedGridFull();
    assert(!m.wantsFaceReindexRecording(),
        "with no batch open there is no recorder to want anything");
    {
        auto arm = m.faceReindexScope();
        assert(!m.wantsFaceReindexRecording(),
            "a scope opened with no recorder must stay inert — arming a null "
          ~ "tracker would be a null dereference on the next line, and every "
          ~ "armed kernel above is also called from UNRECORDED batches (the "
          ~ "interactive preview path, plan §9)");
    }
    // An `unrecorded` batch has a frame but no tracker — the other half of the
    // same inertness, and the one the preview path actually takes.
    {
        auto ed = MeshEditBatch.unrecorded(m, MeshEditScope.Geometry);
        auto arm = ed.mesh.faceReindexScope();
        assert(!ed.mesh.wantsFaceReindexRecording(),
            "an UNRECORDED batch has a frame but no recorder; the scope must "
          ~ "stay inert there too");
        ed.close();
    }
}
