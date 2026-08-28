module tests.unit.mesh_ops.bevel_fin_test;

// Module unittests for the NON-MANIFOLD fin-bundle spine family
// (`source/mesh_ops/bevel_fin.d`), written by task 1903 Stage E4.
//
// WHAT IS AND IS NOT HERE. The family's BEHAVIOURAL law — the rail formula,
// the miter, the corner-cut, the two fan caps, and every refusal — is pinned in
// `tests/unit/mesh_ops/edge_bevel_test.d`, because the only production door to
// these kernels is `bevelEdgesByMask` and the law was captured through it. Those
// blocks are untouched by this stage. This file holds the two things they
// cannot say, both of which the conversion introduced or exposed:
//
//   1. THE BATCH IS DOING SOMETHING. `bevelEdgesByMask` is itself a free
//      function over `ref MeshEditBatch` since Stage G, and it hands a fin
//      bundle straight on to these kernels inside the batch its CALLER opened
//      (until G that batch was the transitional one edge_bevel.d held, plan
//      §4.4a). Its whole point is that one bevel stamps ONCE. Nothing on the wire can see
//      that: `/api/changes` counts UNBATCHED commits, and this path has a batch
//      either way — measured, the counter reads +0 with the batch and +0 with
//      the batch moved (E3 memo 11, the same trap the axis-slice ladder had).
//      `mutationVersion` is the discriminator, and it is not on the wire at
//      all.
//
//   2. WHAT THE OP-LOG SAYS, which is the stage's finding and is invisible to
//      every behavioural test in the tree.
//
// NOT PINNED HERE, deliberately, and recorded so the next reader does not
// mistake the gap for an oversight: `bevelFinBundleSpineMultiEdge` changes a
// fin's ARITY (the corner-cut splices ring vertices into an existing winding)
// and declares no corner provenance, so on a mesh carrying a PolyVertex map it
// trips mesh.d's `resizePolyVertexMaps` assert. Measured at E4 against the
// PRE-conversion body as well: the gap is pre-existing, it is a kernel outside
// the task 0830/0901 census, and it belongs to whoever closes that census — not
// to a byte-identity stage. Every stand below therefore carries no UV map.

import std.format : format;
import std.math   : cos, sin, PI;
import mesh;
import math;
import mesh_edit_delta;
import mesh_ops.bevel_fin;
import mesh_selsets : selSetEditPolygon, selSetEditVertex, selSetEditEdge, SetEditMode;

// TASK 1903 Stage G: `bevelEdgesByMask` — the two doors into these kernels —
// is a module-level free function over `ref MeshEditBatch` now, so the two
// batch blocks below open the batch THEMSELVES. That is the whole change Stage
// G makes to this file's meaning: the deferral that used to come from
// edge_bevel.d's TRANSITIONAL batch (plan §4.4a, which named Stage G as its
// removing stage) now comes from the caller's batch, which is what §4.1 says a
// caller owes. The measured ladders in `kUnbatched` are unchanged, because
// what they measure — how many stamps one fin bevel makes with NO batch
// anywhere — never depended on which frame held it.
private size_t bevelEdgesOnce(ref Mesh m, const bool[] mask, float width,
                              int roundLevel = 0, bool widthMode = false) {
    auto ed = MeshEditBatch.unrecorded(m, kEdgeBevelEditScope);
    immutable size_t n = ed.bevelEdgesByMask(mask, width, roundLevel, widthMode);
    ed.close();
    return n;
}

// ---------------------------------------------------------------------------
/// A fin bundle with every mark plane non-empty AND non-uniform, and it
/// SELECTS. That is load-bearing, not decoration: the delta declares
/// `MeshEditScope.Marks`, and on a stand where every mark plane is zero
/// "the marks were carried" and "there were no marks" are the same measurement
/// (Stage E2 review, BLOCKER B1, on exactly this shape).
private Mesh recFinStand(int n) {
    Mesh m;
    m.vertices = [Vec3(0, 0, 1), Vec3(0, 0, -1)];
    foreach (k; 0 .. n) {
        immutable float a = cast(float)(2.0 * PI * k / n);
        m.vertices ~= Vec3(cos(a), sin(a), 1);
        m.vertices ~= Vec3(cos(a), sin(a), -1);
    }
    foreach (k; 0 .. n)
        m.addFace([0u, cast(uint)(2 + 2 * k), cast(uint)(3 + 2 * k), 1u]);
    m.buildLoops();
    // `syncSelection` SIZES the mark planes — they are lazily grown and stay
    // `[]` until something asks for them, so without it `selectFace` has
    // nothing to write into.
    m.syncSelection();
    m.resetSelection();
    foreach (fi; 0 .. m.faces.length) {
        m.faceMaterial[fi] = cast(uint)(fi % 2);
        m.facePart[fi]     = cast(uint)(fi * 3);
    }
    m.setSubpatch(1, true);
    m.selectFace(0);
    m.selectVertex(2);
    m.selectEdge(1);
    m.faceSelectionOrder[2] = 11;
    bool[] ps = new bool[](m.faces.length);   ps[0] = true;
    selSetEditPolygon(m, "S", SetEditMode.replace, ps);
    bool[] vs = new bool[](m.vertices.length); vs[0] = true; vs[3] = true;
    selSetEditVertex(m, "V", SetEditMode.replace, vs);
    bool[] es = new bool[](m.edges.length);   es[2] = true;
    selSetEditEdge(m, "E", SetEditMode.replace, es);
    return m;
}

private int edgeIdx(ref Mesh m, uint a, uint b) {
    foreach (i; 0 .. m.edges.length) {
        uint u = m.edges[i][0], v = m.edges[i][1];
        if ((u == a && v == b) || (u == b && v == a)) return cast(int)i;
    }
    return -1;
}

private size_t countKind(ref MeshEditDelta d, MeshOpEntry.Kind k) {
    size_t n;
    foreach (ref e; d.log) if (e.kind == k) ++n;
    return n;
}

private string kindsOf(ref MeshEditDelta d) {
    import std.conv : to;
    string s = "[";
    foreach (i, ref e; d.log) { if (i) s ~= " "; s ~= e.kind.to!string; }
    return s ~ "]";
}

// ---------------------------------------------------------------------------
unittest { // ONE stamp, however many fins — the transitional batch's only
           // observable, and it SCALES
    // The cell is a SCALE check, not a location check: it says the stamp count
    // stays at 1 while the work grows with N, and it reddens with an amplitude
    // that grows too. It does NOT say where the batch is opened — moving the
    // open reads identically on every /api/changes counter (E3 memo 11), which
    // is why edge_bevel.d's spelling and count are ALSO pinned, as text, in
    // tests/unit/commit_seam_census_test.d.
    //
    // Measured on this stand with the deferral disabled (M-E4-BATCH: `if
    // (false) if (auto f = currentBatchFrame(&this))` in Mesh.commitChange):
    // N=3 -> 12, N=4 -> 14, N=5 -> 16 stamps for the ONE bevel below. That is
    // 2N+6, i.e. one per added rail vertex plus the tail, and it is what the
    // batch is holding at 1.
    static immutable ulong[3] kUnbatched = [12, 14, 16];
    foreach (i, n; [3, 4, 5]) {
        Mesh m = recFinStand(cast(int)n);
        immutable int es = edgeIdx(m, 0, 1);
        assert(es >= 0, "the fin stand lost its spine edge");
        assert(m.edgeFaceUseCounts()[es] == n,
            format("the N=%d stand's spine carries %d fins, not %d — every "
                 ~ "assertion below would be measuring an ordinary manifold "
                 ~ "bevel", n, m.edgeFaceUseCounts()[es], n));
        bool[] mask = new bool[](m.edges.length);
        mask[es] = true;

        immutable ulong base = m.mutationVersion;
        immutable size_t r = bevelEdgesOnce(m, mask, 0.4f);
        immutable ulong d = m.mutationVersion - base;

        // ANTI-VACUITY. `bevelEdgesByMask` returns 0 on every refusal, and a
        // refusal makes no commits at all — so `d == 1` would be FALSE, but a
        // future refusal that happened to stamp once would sail through. Pin
        // the work as well as the stamp.
        // 2N rim vertices stay, 2N rail vertices arrive, the two spine
        // vertices go: V = 2N + 2N, written as the sum it is.
        immutable size_t expectV = 2 * n + 2 * n;
        assert(r == 1 && m.faces.length == n + 2 && m.vertices.length == expectV,
            format("N=%d: the fin bevel returned %d and left V=%d F=%d; expected "
                 ~ "1, V=%d F=%d (the two spine verts go, 2N rails come, two fan "
                 ~ "caps are added). Every assertion in this block is vacuous on "
                 ~ "a refusal.", n, r, m.vertices.length, m.faces.length,
                   expectV, n + 2));
        assert(d == 1,
            format("N=%d: one fin-bundle bevel bumped mutationVersion by %d, "
                 ~ "expected exactly 1. The CALLER's `MeshEditBatch` — this "
                 ~ "block's own `bevelEdgesOnce`, since Stage G removed "
                 ~ "edge_bevel.d's two transitional opens (plan §4.4a) — is "
                 ~ "what defers every internal commit to one close(). Without "
                 ~ "it this reads %d on this stand — and it GROWS with N (12 / "
                 ~ "14 / 16 for N = 3 / 4 / 5), which is the half a single-N "
                 ~ "cell cannot see (task 1903 Stage E4, re-anchored at G).",
                   n, d, kUnbatched[i]));
    }
}

unittest { // the same, through the MULTI-EDGE door
    Mesh m = recFinStand(3);
    immutable int es = edgeIdx(m, 0, 1), ea = edgeIdx(m, 0, 2);
    assert(es >= 0 && ea >= 0, "the fin stand lost the spine or the extra edge");
    bool[] mask = new bool[](m.edges.length);
    mask[es] = true; mask[ea] = true;

    immutable ulong base = m.mutationVersion;
    immutable size_t r = bevelEdgesOnce(m, mask, 0.4f);
    immutable ulong d = m.mutationVersion - base;

    assert(r == 2,
        format("the spine + one extra edge returned %d, expected 2 (spine plus "
             ~ "the extras consumed). On a refusal the assertion below is "
             ~ "vacuous.", r));
    assert(d == 1,
        format("the multi-edge fin bevel bumped mutationVersion by %d, expected "
             ~ "1 — the caller's batch, which since Stage G is the ONLY one on "
             ~ "the stack (edge_bevel.d's second transitional open is gone). "
             ~ "Measured without the deferral: 14 (task 1903 Stage E4).", d));
}

// ===========================================================================
// THE RECORDING BLOCK (task 1903 Stage E4).
//
// The two blocks above open no batch of their own — they go through
// `bevelEdgesByMask`, whose transitional batch is UNRECORDED, which is what
// track 1 is about: the conversion axis, not the undo axis. This one opens the
// RECORDING constructor directly on the kernel, because it is the only thing in
// the tree that looks at what this family's op-log actually SAYS.
// ===========================================================================

/// The scope this family declares, written out from the enum INDEPENDENTLY of
/// `kBevelFinEditScope`.
///
/// `d.scope_` IS `kBevelFinEditScope` fed through `MeshEditTracker.declare`, so
/// `d.scope_ == kBevelFinEditScope` is the measurement judging itself: set the
/// constant to 0 and that equality stays true. Measured at Stage D2 on the
/// reduce family, where exactly that draft stayed green under
/// `enum uint kReduceEditScope = 0;`. So the expectation here is written from
/// what the kernels DO — they add 2N rail vertices and drop the two spine ones
/// (Points), rewrite every fin's winding and append two caps (Polygons), and
/// re-do the face selection and its order (Marks) — and NOT `Position`, because
/// no existing vertex moves. The equality against the constant is asserted
/// separately, AFTER it, where it can only see a broken `declare`/`close` path.
private enum uint kExpectedFinScope = MeshEditScope.Points
                                    | MeshEditScope.Polygons
                                    | MeshEditScope.Marks;

unittest { // the fin-bundle op-log NAMES NO WINDING CHANGE, and its revert FAULTS
    Mesh m = recFinStand(3);

    // STAND CANARY. Asserts the stand, not the code under test, so it can only
    // fire when `recFinStand` is edited: with nothing selected and every mark
    // word zero, the "declared Marks, recorded none" law below would be zero
    // compared with zero.
    assert(m.isFaceSelected(0) && m.isVertexSelected(2) && m.isEdgeSelected(1)
           && m.isFaceSubpatch(1) && m.faceSelectionOrder[2] == 11,
        "recFinStand selected/tagged nothing — the Marks half of the law below "
      ~ "would be vacuous (task 1903 Stage E4, and Stage E2 review BLOCKER B1 "
      ~ "for the shape)");

    immutable size_t preV = m.vertices.length, preF = m.faces.length;
    immutable int es = edgeIdx(m, 0, 1);

    MeshEditDelta d;
    size_t n;
    {
        auto ed = MeshEditBatch(m, kBevelFinEditScope);   // RECORDING
        n = ed.bevelIsolatedFinBundleSpine(cast(uint)es, 0.4f);
        d = ed.close();
    }

    // Anti-vacuity: this kernel returns 0 on every precondition failure, and a
    // 0-return satisfies every assertion below for free.
    assert(n == 1 && m.vertices.length == preV + 4 && m.faces.length == preF + 2,
        format("the stand beveled %d spine(s) (V %d -> %d, F %d -> %d), expected "
             ~ "1 (V +4: six rails in, two spine verts out; F +2: the two fan "
             ~ "caps) — every assertion below would be vacuous on a refusal",
               n, preV, m.vertices.length, preF, m.faces.length));

    assert(cast(uint)d.scope_ == kExpectedFinScope,
        format("a recording fin bevel declared scope 0x%x, expected 0x%x "
             ~ "(Points|Polygons|Marks). Missing: 0x%x. Unexpected: 0x%x. "
             ~ "`MeshEditDelta.finalize` reads scope_ back on a revert to decide "
             ~ "what to bump and rebuild, so a wrong constant is a wrong "
             ~ "invalidation, not a cosmetic mismatch (task 1903 Stage E4)",
               cast(uint)d.scope_, kExpectedFinScope,
               kExpectedFinScope & ~cast(uint)d.scope_,
               cast(uint)d.scope_ & ~kExpectedFinScope));
    assert(cast(uint)d.scope_ == kBevelFinEditScope,
        format("the delta's scope_ (0x%x) is not the kBevelFinEditScope the "
             ~ "batch was opened with (0x%x) — the declared scope is not "
             ~ "reaching MeshEditDelta.scope_ at all",
               cast(uint)d.scope_, kBevelFinEditScope));

    // THE FINDING, MEASURED — and STAGE L7-P2 CLOSED IT (2026-08-28). The
    // block is REWRITTEN rather than having its number widened, which is what
    // its own message demanded.
    //
    // WHAT IT USED TO SAY. Three fins were rewritten in place and the op-log
    // was four entries, `[AddVerts AddFaces RemoveVerts Reindex]`: the six
    // rails in, the two fan caps, the two spine vertices the tail compaction
    // dropped, and the renumbering after it. It said NOTHING about the three
    // fin WINDINGS, which the kernel installed with `ed.faces[fi] = nf;` — a
    // direct indexed write reaching no mutation hook at all — and `revert()`
    // THREW out of `finalize` -> `buildLoops` ("index [9] is out of bounds for
    // array of length 8"), leaving V and F back at 8/3 with six face corners
    // still pointing at rail vertices that no longer existed.
    //
    // THE DIAGNOSIS WAS "ABSENT PUBLISHER", NOT "DISARMED ONE", and it was
    // established the only way the two can be told apart — by ARMING
    // `MeshEditTracker.wantsFaceReindex` and re-measuring (E3 memo 12). The
    // armed log was BYTE-IDENTICAL and the revert still faulted, while the
    // same armed build reddened `tests/unit/mesh_ops/cleanup_test.d(785)`, so
    // the mutation was live and the primitive simply was not reached. Stage
    // K's per-rewrite arming scope could never have fixed it.
    //
    // WHAT L7-P2 DID. The install goes through `Mesh.setFaceWindings`, in ONE
    // BULK call after the two cap `addFace`s, so the log gains ONE
    // `ReshapeFaces` for all three fins — not one per fin. That is the shape
    // assertion below and it is not decoration: `recordPolyVertexPayload`
    // resolves corner bases by ONE ordered sweep over `faces`, so N single
    // calls are O(N.F), measured at 31x (3 600 faces) and 66x (10 000) on card
    // 2260. A per-fin loop still round-trips, so no value assertion anywhere
    // can see it.
    //
    // THE ASSERTION IS A KIND SEQUENCE, NOT A LENGTH, and that is the second
    // instruction this block's old message gave. A length is satisfied by a
    // broken log — Stage J made the `[MeshMapDelta, ReshapeFaces]` ADJACENCY
    // contractual (`CornerCarry.payloadForCount` binds by it), so an entry
    // interposed between a payload and its face entry unpairs the corner
    // restore SILENTLY while the geometry still round-trips. On THIS stand
    // there is no PolyVertex map, so no `MeshMapDelta` is recorded and the
    // sequence is the five below; the map-carrying variant is measured in the
    // per-corner block further down this file.
    assert(kindsOf(d) == "[AddVerts AddFaces ReshapeFaces RemoveVerts Reindex]",
        format("the fin bevel's op-log kinds are %s, expected\n"
             ~ "  [AddVerts AddFaces ReshapeFaces RemoveVerts Reindex]\n"
             ~ "  NO `ReshapeFaces` is the pre-L7-P2 state: the winding "
             ~ "install went back to a raw `ed.faces[fi] = nf;`, which reaches "
             ~ "no record primitive, and `revert()` then THROWS out of "
             ~ "buildLoops leaving the mesh half-reverted.\n"
             ~ "  MORE THAN ONE `ReshapeFaces` is the other regression: the "
             ~ "bulk call became a per-fin loop, which still round-trips and "
             ~ "is the O(N.F) shape card 2260 measured at 31x/66x.\n"
             ~ "  A different ORDER means an entry moved across the face "
             ~ "entry, which is what the corner payload pairs by.",
               kindsOf(d)));
    assert(countKind(d, MeshOpEntry.Kind.AddVerts)     == 1
        && countKind(d, MeshOpEntry.Kind.AddFaces)     == 1
        && countKind(d, MeshOpEntry.Kind.ReshapeFaces) == 1
        && countKind(d, MeshOpEntry.Kind.RemoveVerts)  == 1
        && countKind(d, MeshOpEntry.Kind.Reindex)      == 1
        && countKind(d, MeshOpEntry.Kind.FaceReindex)  == 0,
        format("the fin bevel's op-log is %s, expected exactly one each of "
             ~ "AddVerts / AddFaces / ReshapeFaces / RemoveVerts / Reindex and "
             ~ "NO FaceReindex — this kernel reaches no `rewriteFaces` at all, "
             ~ "so a FaceReindex appearing means somebody armed it (task 1903 "
             ~ "Stage L7-P2).", kindsOf(d)));

    // `d.revert(m)` IS CALLED NOW, and calling it IS the check. Before L7-P2
    // it threw out of `finalize` -> `buildLoops` ("index [9] is out of bounds
    // for array of length 8") and left the mesh HALF-REVERTED: V and F back at
    // the pre-op 8 / 3, but SIX face corners still pointing at rail vertices up
    // to index 13 that no longer existed. The N=4 stand was the same shape with
    // 8 dangling corners, and the multi-edge
    // door with 8.
    {
        auto preWind = new uint[][](m.faces.length);
        assert(d.revert(m),
            "revert() refused the fin-bundle delta outright");
        assert(m.vertices.length == preV && m.faces.length == preF,
            format("revert left V=%d F=%d, expected the pre-op %d / %d — the "
                 ~ "shape that used to be a THROW out of buildLoops",
                   m.vertices.length, m.faces.length, preV, preF));
        foreach (fi; 0 .. m.faces.length)
            foreach (c; m.faces[fi])
                assert(c < m.vertices.length,
                    format("revert left face %d naming vertex %d against %d "
                         ~ "live vertices — a DANGLING corner, which is "
                         ~ "exactly the half-reverted state this block used to "
                         ~ "record", fi, c, m.vertices.length));
        cast(void) preWind;
    }
}
