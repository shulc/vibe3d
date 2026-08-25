// Golden-fixture + non-fixture coverage for edge weight / semi-sharp
// subdivision creases (task 1062). See doc/edge_weight_plan.md.
//
// Stage 1 (this file's first block) calls osdc_topology_create_sharp
// DIRECTLY, with ZERO vibe3d feature code in the loop — it proves the
// PINNED shim reproduces the frozen fixture before any vibe3d surface area
// exists to blame. Stage 6 (the following blocks) drives the real path
// (Mesh.setCreaseWeight -> subpatch_osd.OsdAccel.buildPreview), which is
// what actually exercises subpatch_osd's crease-merge kernel, the boundary
// guard, and the two cache-invalidation sites.
module tests.unit.edge_crease_weight_test;

import std.json;
import std.file      : readText;
import std.math      : abs, round, isNaN;
import std.format    : format;
import std.algorithm : sort, map;
import std.array     : array;

import math  : Vec3;
import mesh;
import osd.c;
import subpatch_osd;

// ---------------------------------------------------------------------------
// Fixture plumbing
// ---------------------------------------------------------------------------

double asDouble(JSONValue v) {
    final switch (v.type) {
        case JSONType.float_:    return v.floating;
        case JSONType.integer:   return cast(double) v.integer;
        case JSONType.uinteger:  return cast(double) v.uinteger;
        case JSONType.string:    case JSONType.array:  case JSONType.object:
        case JSONType.true_:     case JSONType.false_: case JSONType.null_:
            assert(false, "fixture: expected a number, got " ~ v.toString);
    }
}

// Self-contained provenance presence+vocabulary check (task 0366/1063).
// `tests/fixture_helpers.d`'s `requireProvenance` is NOT importable here —
// it lives outside `tests/unit`'s compiled source set
// (dub.json `tests` config sourcePaths == [source, tests/unit] only) — so
// this repeats its "source"/"method" vocabulary check locally rather than
// pull in the whole HTTP-test helper module.
private void checkProvenance(JSONValue fx) {
    assert("provenance" in fx,
        "edge_crease_weight fixture has no 'provenance' block");
    auto prov = fx["provenance"];
    static immutable string[] kSources = ["live-capture", "simulated", "analytic", "unknown"];
    static immutable string[] kMethods = ["capture-drag", "command", "from-trace",
                                          "rr-memory", "self-drive", "closed-form",
                                          "hand", "unknown"];
    bool oneOf(string v, const string[] allowed) {
        foreach (a; allowed) if (v == a) return true;
        return false;
    }
    assert("source" in prov && prov["source"].type == JSONType.string
        && oneOf(prov["source"].str, kSources),
        "edge_crease_weight fixture: provenance.source missing/invalid");
    assert("method" in prov && prov["method"].type == JSONType.string
        && oneOf(prov["method"].str, kMethods),
        "edge_crease_weight fixture: provenance.method missing/invalid");
}

// Hard assert on a missing file — no try/catch (task 1062 rule, precedent
// tests/test_acen_item_space.d:91-99).
JSONValue fixture() {
    static JSONValue cached;
    static bool loaded = false;
    if (!loaded) {
        cached = parseJSON(readText("tests/fixtures/edge_crease_weight.json"));
        checkProvenance(cached);
        loaded = true;
    }
    return cached;
}

// ---------------------------------------------------------------------------
// Unordered point-set comparison (OSD's vertex ordering need not equal the
// fixture's) — sort both by a coarse rounded key, then compare pairwise at
// the real tolerance. See edge_weight_plan.md §Testing for the tolerance
// derivation (1e-6, ~10x the measured 9.1e-8 floor, ~56000x below the
// smallest discriminating separation in this fixture).
// ---------------------------------------------------------------------------

private struct P { double x, y, z; }

private int cmpP(P a, P b) {
    enum double bucket = 1e-4;
    double ax = round(a.x / bucket), ay = round(a.y / bucket), az = round(a.z / bucket);
    double bx = round(b.x / bucket), by = round(b.y / bucket), bz = round(b.z / bucket);
    if (ax != bx) return ax < bx ? -1 : 1;
    if (ay != by) return ay < by ? -1 : 1;
    if (az != bz) return az < bz ? -1 : 1;
    return 0;
}

private void assertUnorderedMatchCore(P[] g, P[] w, double tol, string label) {
    assert(g.length == w.length,
        format("%s: vertex count mismatch: got %d want %d", label, g.length, w.length));
    g.sort!((a, b) => cmpP(a, b) < 0);
    w.sort!((a, b) => cmpP(a, b) < 0);
    foreach (i; 0 .. g.length) {
        immutable bool ok = abs(g[i].x - w[i].x) < tol
                          && abs(g[i].y - w[i].y) < tol
                          && abs(g[i].z - w[i].z) < tol;
        assert(ok, format(
            "%s: vertex %d mismatch after unordered sort: got (%.8f,%.8f,%.8f) want (%.8f,%.8f,%.8f)",
            label, i, g[i].x, g[i].y, g[i].z, w[i].x, w[i].y, w[i].z));
    }
}

void assertUnorderedMatch(const(Vec3)[] got, JSONValue want, double tol, string label) {
    P[] g = got.map!(v => P(v.x, v.y, v.z)).array;
    P[] w;
    foreach (vj; want.array) {
        auto a = vj.array;
        w ~= P(asDouble(a[0]), asDouble(a[1]), asDouble(a[2]));
    }
    assertUnorderedMatchCore(g, w, tol, label);
}

void assertUnorderedMatchVec(const(Vec3)[] got, const(Vec3)[] want, double tol, string label) {
    P[] g = got.map!(v => P(v.x, v.y, v.z)).array;
    P[] w = want.map!(v => P(v.x, v.y, v.z)).array;
    assertUnorderedMatchCore(g, w, tol, label);
}

// ---------------------------------------------------------------------------
// Cage geometry helpers. makeCube()'s own numbering (source/mesh.d): the
// fixture's `rig.creased_edge` (-0.5,0.5,0.5)-(0.5,0.5,0.5) is cage verts
// 7-6 (== 6-7, edgeKey is order-independent); `rig.creased_loop` ("the four
// edges of the +Y face") is face index 4 == addFace([3,7,6,2]), edges
// (3,7),(7,6),(6,2),(2,3).
// ---------------------------------------------------------------------------

private immutable uint[2][4] kLoopPairs = [[3,7], [7,6], [6,2], [2,3]];

// The open-box rig the fixture's `boundary_cases` were captured against
// (verified during planning by matching the +Y-corner boundary-crease
// vertex position (0.375,0.5,0.375) and the 25-vert/44-edge/20-poly level-1
// counts): makeCube()'s cage with the +Y face (addFace([3,7,6,2])) omitted.
private Mesh makeOpenBoxCage() {
    Mesh m;
    m.vertices = [
        Vec3(-0.5f, -0.5f, -0.5f), // 0
        Vec3( 0.5f, -0.5f, -0.5f), // 1
        Vec3( 0.5f,  0.5f, -0.5f), // 2
        Vec3(-0.5f,  0.5f, -0.5f), // 3
        Vec3(-0.5f, -0.5f,  0.5f), // 4
        Vec3( 0.5f, -0.5f,  0.5f), // 5
        Vec3( 0.5f,  0.5f,  0.5f), // 6
        Vec3(-0.5f,  0.5f,  0.5f), // 7
    ];
    m.addFace([0, 3, 2, 1]);  // -Z
    m.addFace([4, 5, 6, 7]);  // +Z
    m.addFace([0, 4, 7, 3]);  // -X
    m.addFace([1, 2, 6, 5]);  // +X
    // +Y (addFace([3, 7, 6, 2])) deliberately OMITTED -- open box.
    m.addFace([0, 1, 5, 4]);  // -Y
    m.buildLoops();
    return m;
}

// ---------------------------------------------------------------------------
// Stage 1 — the dependency law, zero vibe3d surface area.
// ---------------------------------------------------------------------------

private void runStage1Case(JSONValue c, string label) {
    immutable int   level  = cast(int) c["level"].integer;
    immutable float weight = cast(float) asDouble(c["weight"]);
    immutable bool  isLoop = c["note"].str == "creased loop";

    immutable float[24] cageXyz = [
        -0.5f, -0.5f, -0.5f,   0.5f, -0.5f, -0.5f,
         0.5f,  0.5f, -0.5f,  -0.5f,  0.5f, -0.5f,
        -0.5f, -0.5f,  0.5f,   0.5f, -0.5f,  0.5f,
         0.5f,  0.5f,  0.5f,  -0.5f,  0.5f,  0.5f,
    ];
    immutable int[6]  faceCounts  = [4, 4, 4, 4, 4, 4];
    immutable int[24] faceIndices = [
        0, 3, 2, 1,   4, 5, 6, 7,
        0, 4, 7, 3,   1, 2, 6, 5,
        3, 7, 6, 2,   0, 1, 5, 4,
    ];

    // clamp(10*w, 0, 10) -- inlined literally (NOT calling
    // subpatch_osd.creaseSharpnessFromWeight) so this stage proves the
    // DEPENDENCY's behaviour independent of our own kernel function, which
    // does not exist yet at this stage of the plan's reasoning.
    immutable float sharpness = weight <= 0.0f ? 0.0f
                               : weight >= 1.0f ? 10.0f : 10.0f * weight;

    int[] pairs = isLoop
        ? [3,7, 7,6, 6,2, 2,3]
        : [6, 7];
    float[] weights;
    foreach (i; 0 .. pairs.length / 2) weights ~= sharpness;

    auto topo = osdc_topology_create_sharp(
        8, 6, faceCounts.ptr, faceIndices.ptr, level,
        cast(int)(pairs.length / 2), pairs.ptr, weights.ptr,
        0, null, null);
    assert(topo !is null, label ~ ": topology create failed");
    scope (exit) osdc_topology_destroy(topo);

    immutable int nv = osdc_topology_limit_vert_count(topo);
    Vec3[] verts = new Vec3[](nv);
    osdc_evaluate(topo, cageXyz.ptr, cast(float*) verts.ptr);

    assertUnorderedMatch(verts, c["verts"], 1e-6, label);
}

unittest {
    auto fx = fixture();
    auto cases = fx["cases"].array;
    assert(cases.length == 49, "expected 49 fixture cases");
    foreach (i, c; cases)
        runStage1Case(c, format("Stage1 case %d (%s, L%s w=%s)",
            i, c["note"].str, c["level"].integer, c["weight"]));
}

// ---------------------------------------------------------------------------
// Stage 6 — the end-to-end golden: Mesh.setCreaseWeight -> OsdAccel.buildPreview.
// ---------------------------------------------------------------------------

private void runStage6Case(JSONValue c, string label) {
    immutable int   level  = cast(int) c["level"].integer;
    immutable float weight = cast(float) asDouble(c["weight"]);
    immutable bool  isLoop = c["note"].str == "creased loop";

    Mesh cage = makeCube();
    cage.resizeSubpatch();
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);

    if (isLoop) {
        foreach (pair; kLoopPairs) {
            uint ei = cage.edgeIndex(pair[0], pair[1]);
            assert(ei != ~0u, label ~ ": loop edge not found");
            assert(cage.setCreaseWeight(ei, weight));
        }
    } else {
        uint ei = cage.edgeIndex(6, 7);
        assert(ei != ~0u, label ~ ": creased edge not found");
        assert(cage.setCreaseWeight(ei, weight));
    }

    OsdAccel      accel;
    Mesh          preview;
    SubpatchTrace trace;
    bool ok = accel.buildPreview(cage, level, preview, trace);
    assert(ok, label ~ ": buildPreview failed");

    assertUnorderedMatch(preview.vertices, c["verts"], 1e-6, label);
}

unittest {
    auto fx = fixture();
    foreach (i, c; fx["cases"].array)
        runStage6Case(c, format("Stage6 case %d (%s, L%s w=%s)",
            i, c["note"].str, c["level"].integer, c["weight"]));
}

// ---------------------------------------------------------------------------
// Boundary cases — open-box rig, through the real code path. Lone-quad
// cases 6/8/9 are EXCLUDED (§2b′ pre-existing boundary-vertex divergence,
// gap-registry row); case 7 matches but is deliberately not asserted (would
// freeze a divergence as if intended — see edge_weight_plan.md §2b′).
// ---------------------------------------------------------------------------

unittest {
    // Boundary cases 0/4/5: bit-identical in the fixture (verified during
    // planning) -- a boundary-edge weight is inert. This is the "a weight
    // must never lower a boundary edge" requirement, read the other way: it
    // must never RAISE one above the structural infinite either (there is
    // nothing to raise it to).
    //
    // Each inertness case is asserted against ITS OWN fixture cell now, not
    // case 0's reused (task 1062 review, NIT 5): the previous version read
    // `bcases[0]` for both loop iterations and never touched `bcases[4]` or
    // `bcases[5]` at all -- it passed only because those three cells happen
    // to be byte-identical. Mutation proving this reads real, distinct
    // cells: point one iteration's comparison at `bcases[6]` (a
    // differently-shaped lone-quad case, 9 verts vs this rig's 25) -- reddens
    // on a vertex-count mismatch (verified 2026-08-17).
    auto fx = fixture();
    auto bcases = fx["boundary_cases"].array;

    Mesh cage0 = makeOpenBoxCage();
    cage0.resizeSubpatch();
    foreach (fi; 0 .. cage0.faces.length) cage0.setSubpatch(fi, true);
    OsdAccel accel0; Mesh preview0; SubpatchTrace trace0;
    assert(accel0.buildPreview(cage0, 1, preview0, trace0));
    assertUnorderedMatch(preview0.vertices, bcases[0]["verts"], 1e-6,
        "boundary case 0 (open box, no weight)");

    // Cases 4 and 5 both capture weight 0.05 on the boundary edge (case 5
    // under the reference's 'crease' boundary-rule variant, which coincides
    // with the default rule on THIS rig -- §2b′) -- read from their own
    // cells, each independently.
    foreach (idx; [4, 5]) {
        Mesh cage = makeOpenBoxCage();
        cage.resizeSubpatch();
        foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);
        uint eBoundary = cage.edgeIndex(6, 7);   // a rim edge of the missing +Y face
        assert(eBoundary != ~0u);
        assert(cage.setCreaseWeight(eBoundary, 0.05f));
        OsdAccel accel; Mesh preview; SubpatchTrace trace;
        assert(accel.buildPreview(cage, 1, preview, trace));
        assertUnorderedMatch(preview.vertices, bcases[idx]["verts"], 1e-6,
            format("boundary case %d (open box, weight 0.05 on a boundary "
                  ~ "edge, must be inert)", idx));
    }

    // A higher weight (1.0) is not its own captured fixture cell -- the
    // guard is structural (an edge with < 2 incident faces is skipped
    // entirely, §2b) and must hold for ANY magnitude, so the no-weight
    // baseline (case 0) is the honest comparison here, not a stand-in for a
    // case that does not exist.
    {
        Mesh cage = makeOpenBoxCage();
        cage.resizeSubpatch();
        foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);
        uint eBoundary = cage.edgeIndex(6, 7);
        assert(eBoundary != ~0u);
        assert(cage.setCreaseWeight(eBoundary, 1.0f));
        OsdAccel accel; Mesh preview; SubpatchTrace trace;
        assert(accel.buildPreview(cage, 1, preview, trace));
        assertUnorderedMatch(preview.vertices, bcases[0]["verts"], 1e-6,
            "boundary case 0 baseline (open box, weight 1.0 on a boundary "
          ~ "edge, must be inert)");
    }
}

unittest {
    // Boundary case 10 -- the edge-vs-endpoint guard trap. Interior edge
    // (0.5,-0.5,0.5)-(0.5,0.5,0.5) == cage verts 5-6: vert 6 sits on the
    // boundary rim (it's a corner of the missing +Y face) but the EDGE
    // itself has 2 incident faces (+X and +Z side walls), so the reference
    // DOES crease it. Mutation for this assertion: change subpatch_osd.d's
    // boundary guard from "edgeFaceTotal[ei] < 2" to "either endpoint is a
    // boundary vertex" -- verified 2026-08-17 to redden exactly this case
    // (see the task report for the run).
    auto fx = fixture();
    auto bcases = fx["boundary_cases"].array;

    Mesh cage = makeOpenBoxCage();
    cage.resizeSubpatch();
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);

    uint eInterior = cage.edgeIndex(5, 6);
    assert(eInterior != ~0u, "interior edge (5,6) not found");

    // Sanity check on the rig itself: this edge really is interior (2
    // incident faces) in our topology, matching the trap's premise.
    int incident = 0;
    foreach (face; cage.faces)
        foreach (i; 0 .. face.length) {
            uint a = face[i], b = face[(i + 1) % face.length];
            if ((a == 5 && b == 6) || (a == 6 && b == 5)) ++incident;
        }
    assert(incident == 2,
        format("edge (5,6) expected 2 incident faces, got %d", incident));

    assert(cage.setCreaseWeight(eInterior, 0.05f));
    OsdAccel accel; Mesh preview; SubpatchTrace trace;
    assert(accel.buildPreview(cage, 1, preview, trace));
    assertUnorderedMatch(preview.vertices, bcases[10]["verts"], 1e-6,
        "boundary case 10 (interior edge, one boundary-rim endpoint)");
}

// ---------------------------------------------------------------------------
// Non-fixture assertions — behaviour the capture cannot supply.
// ---------------------------------------------------------------------------

// creaseSharpnessFromWeight's NaN guard, tested DIRECTLY on the pure
// kernel. This is the assertion that actually discriminates `!(w > 0)`
// from `w <= 0`: verified 2026-08-17 that an end-to-end (buildPreview)
// check alone canNOT tell them apart, because the merge site's
// `if (s > sharp[ei]) sharp[ei] = s;` ALSO happens to reject NaN (any `>`
// comparison against NaN is false in IEEE754) — so even under the `w <= 0`
// mutation, NaN never reaches `sharp[]` and the end-to-end test below
// stayed green. This direct test is what actually reddens under that
// mutation (see the task report).
unittest {
    assert(creaseSharpnessFromWeight(float.nan) == 0.0f);
    assert(!isNaN(creaseSharpnessFromWeight(float.nan)));
    assert(creaseSharpnessFromWeight(0.0f)  == 0.0f);
    assert(creaseSharpnessFromWeight(-1.0f) == 0.0f);
    assert(creaseSharpnessFromWeight(0.5f)  == 5.0f);
    assert(creaseSharpnessFromWeight(1.0f)  == 10.0f);
    assert(creaseSharpnessFromWeight(2.0f)  == 10.0f);
}

// End-to-end companion: a NaN weight must never reach preview.vertices, and
// the resulting preview is bit-identical to "no crease". This is an
// integration-level regression pin (a real, if incidental, second layer of
// protection — see the direct kernel test above for the assertion that
// actually discriminates the kernel's own guard).
unittest {
    Mesh cageNan = makeCube();
    cageNan.resizeSubpatch();
    foreach (fi; 0 .. cageNan.faces.length) cageNan.setSubpatch(fi, true);
    uint eiNan = cageNan.edgeIndex(6, 7);
    assert(cageNan.setCreaseWeight(eiNan, float.nan));

    OsdAccel accelNan; Mesh previewNan; SubpatchTrace traceNan;
    assert(accelNan.buildPreview(cageNan, 2, previewNan, traceNan));
    foreach (v; previewNan.vertices)
        assert(!isNaN(v.x) && !isNaN(v.y) && !isNaN(v.z),
            "a NaN weight must never reach preview.vertices");

    Mesh cageBase = makeCube();
    cageBase.resizeSubpatch();
    foreach (fi; 0 .. cageBase.faces.length) cageBase.setSubpatch(fi, true);
    OsdAccel accelBase; Mesh previewBase; SubpatchTrace traceBase;
    assert(accelBase.buildPreview(cageBase, 2, previewBase, traceBase));

    assertUnorderedMatchVec(previewNan.vertices, previewBase.vertices, 1e-6,
        "a NaN weight must behave identically to no crease at all");
}

// The headline risk (§3): a weight written the obvious way must invalidate
// ---------------------------------------------------------------------------
// TASK 1906 STAGE 2d — the bus feed, by hand.
//
// `SubpatchPreview.rebuildIfStale` keys its freshness half on TWO terms: the
// change bus's per-mesh GEOMETRY epoch and `source.mutationVersion`. In the
// editor that epoch is advanced by `app.d`'s change-bus hub and by its
// per-layer feed at the frame drain. A unit test has neither — and
// `Mesh.deliverPending`'s subject filter means a scratch cage no `Document`
// owns gets no delivery at all — so the listener BODY is driven directly,
// which is what `mesh_dirty`'s header says a headless test should do.
//
// The blocks below would in fact invalidate on the VERSION term alone
// (`setCreaseWeight` commits `Material`, `setSubpatch` commits `Marks`, and
// both go through `commitChange`). The feed is here so the rig is the app's
// sequence rather than a subset of it: if the version term is ever dropped
// again these blocks must still be driving the same listener the editor does.
//
// Reading the mesh's own accumulator rather than naming a class keeps this
// honest: it is exactly what the mutator published, so a mutator that changes
// which class it publishes cannot silently desync the test from the app.
//
// THE ZEROING IS NOT OPTIONAL AND IT IS NOT TIDINESS. A rig that only READ the
// word would re-publish the SAME accumulated classes on every call — and a
// cage carries `Points | Polygons` from the moment it was built, so every feed
// would move the GEOMETRY epoch and the blocks below would invalidate for a
// reason that has nothing to do with the crease weight they are about.
// Measured: without the zeroing, dropping the preview's `mutationVersion` key
// term left this whole file GREEN.
//
// AND THE WORD ONLY EXISTS TO BE READ BECAUSE ITS CALLERS HOLD A DELIVERY
// BATCH OPEN (review of stage 3, M2). Since stage 3 every publisher DELIVERS,
// and `Mesh.deliverPending` TAKES AND ZEROES this pair before handing it to
// the bus — the subject filter does not save a scratch cage, it is fail-OPEN
// when `g_isDocumentMesh` is uninstalled, which is every headless test. So
// without the batch this function fed the epoch table a ZERO on all five
// calls and every staleness assertion in the two blocks below was free.
// Inside a batch a publish only REGISTERS, which is the same state a
// command's kernel runs in and the state this rig was written against.
//
// The assert is the anti-vacuity arm and it belongs HERE rather than at the
// call sites: it fires the moment somebody removes a batch, or moves a feed
// to a point where nothing has been published.
private void feedBus(ref Mesh cage) {
    import mesh_dirty : noteMeshChange;
    assert(cage.undeliveredChanges_ != 0,
        "RIG: the change accumulator is EMPTY at a feed — either the caller "
      ~ "dropped its `beginDeliveryBatchGlobal` (so the publisher's own "
      ~ "delivery took the word) or nothing was published since the last "
      ~ "feed. Either way the epoch table is being handed a ZERO and the "
      ~ "staleness assertions below cannot fail");
    noteMeshChange(cast(size_t)&cage, cage.undeliveredChanges_);
    cage.undeliveredChanges_ = 0;   // what the real delivery would have done
}

/// The two blocks below hold one of these for their whole body — see
/// `feedBus`. Spelled out at each site rather than hidden in a helper struct
/// so the `scope(exit)` is visible beside the mesh whose accumulator it keeps.
private enum string kHoldDelivery = q{
    import mesh : beginDeliveryBatchGlobal, endDeliveryBatchGlobal;
    beginDeliveryBatchGlobal();
    scope(exit) endDeliveryBatchGlobal();
};

// BOTH cache layers, or it presents to the user as "the weight does
// nothing". This is the position-only fast-path case: the FIRST-ever
// buildPreview call always takes the full-rebuild path regardless of any
// version-bump bug (SubpatchPreview.active starts false), so a one-shot
// "set a weight once, compare to no-weight baseline" test would NOT catch a
// dropped topologyVersion bump -- only a SECOND write, on an already-active
// preview with unchanged topology otherwise, exercises the fast path's
// staleness check. Mutation: delete the `++topologyVersion` line in
// Mesh.setCreaseWeight -- verified 2026-08-17 to redden the SECOND
// assertion below while leaving the first green (see the task report).
unittest {
    Mesh cage = makeCube();
    mixin(kHoldDelivery);
    cage.resizeSubpatch();
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);
    uint ei = cage.edgeIndex(6, 7);

    SubpatchPreview sp;

    // Both weights well BELOW the level-1 saturation threshold (0.1, per
    // the fixture's "level 1 already saturated at weight 0.1" falsifier) so
    // the two builds are genuinely different geometry, not two saturated
    // (and therefore identical) sharp edges -- 0.3/0.8 both saturate at
    // level 1 and would pass this assertion even with the bump removed.
    cage.setCreaseWeight(ei, 0.02f);
    feedBus(cage);
    sp.rebuildIfStale(cage, 1);
    assert(sp.active);
    Vec3[] afterFirst = sp.mesh.vertices.dup;

    cage.setCreaseWeight(ei, 0.05f);
    feedBus(cage);
    sp.rebuildIfStale(cage, 1);
    Vec3[] afterSecond = sp.mesh.vertices.dup;

    assert(afterSecond != afterFirst,
        "a SECOND weight write (different value) on an already-active "
      ~ "preview must move the surface again");
}

// Tab-toggle reuse key: a weight changed WHILE the preview is inactive must
// still be picked up when the preview is reactivated. Mutation: remove the
// crease-map fold from Mesh.SubpatchPreview.computeReusablePreviewKey --
// verified 2026-08-17 to redden this test (see the task report).
unittest {
    Mesh cage = makeCube();
    mixin(kHoldDelivery);
    cage.resizeSubpatch();
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);
    uint ei = cage.edgeIndex(6, 7);
    // Both weights below the level-1 saturation threshold (0.1) -- see the
    // comment on the two-write test above for why saturated values would
    // pass this assertion vacuously.
    cage.setCreaseWeight(ei, 0.02f);

    SubpatchPreview sp;
    feedBus(cage);
    sp.rebuildIfStale(cage, 1);
    assert(sp.active && sp.reusablePreviewReady);
    Vec3[] beforeToggle = sp.mesh.vertices.dup;

    // Toggle OFF: unmark every face (matches how the reusablePreviewKey
    // mechanism is actually reached -- `rebuild()`'s `!hasAnySubpatch()`
    // branch clears `active` WITHOUT touching reusablePreviewReady/Key; a
    // depth<=0 call clears the key too and would not exercise this path).
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, false);
    feedBus(cage);
    sp.rebuildIfStale(cage, 1);
    assert(!sp.active);

    // Change the weight WHILE the preview is off.
    cage.setCreaseWeight(ei, 0.05f);

    // Toggle back ON.
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);
    feedBus(cage);
    sp.rebuildIfStale(cage, 1);
    assert(sp.active);
    Vec3[] afterToggle = sp.mesh.vertices.dup;

    assert(afterToggle != beforeToggle,
        "reactivating after a weight change while the preview was off must "
      ~ "reflect the NEW weight, not resurrect the stale cached mesh");
}

// weight then topology edit: the crease map stays length-correct (no OOB,
// no crash) across a topology edit. Values are EXPECTED to scramble (the
// documented Point/Edge relocation gap, source/mesh.d — see the out-of-
// scope gap row); this assertion is bounds, not identity.
unittest {
    Mesh cage = makeCube();
    uint ei = cage.edgeIndex(6, 7);
    cage.setCreaseWeight(ei, 0.6f);
    assert(cage.creaseWeightMap().data.length == cage.edges.length);

    cage.edges ~= [cast(uint) 0, cast(uint) 200];
    cage.resizeEdgeSelection();

    auto m = cage.creaseWeightMap();
    assert(m !is null);
    assert(m.data.length == cage.edges.length,
        "crease map must stay length-correct after a topology edit");
    foreach (i; 0 .. cage.edges.length)
        cast(void) cage.edgeCreaseWeight(i);   // must not throw/crash
}

// Order independence ("mark then set weight" == "set weight then mark") and
// bit-identical off->on survival with an UNCHANGED weight (card's
// "Прочее").
unittest {
    Mesh cageA = makeCube();
    cageA.resizeSubpatch();
    foreach (fi; 0 .. cageA.faces.length) cageA.setSubpatch(fi, true);
    uint eiA = cageA.edgeIndex(6, 7);
    cageA.setCreaseWeight(eiA, 0.4f);

    Mesh cageB = makeCube();
    uint eiB = cageB.edgeIndex(6, 7);
    cageB.setCreaseWeight(eiB, 0.4f);   // weight set BEFORE the subpatch marks
    cageB.resizeSubpatch();
    foreach (fi; 0 .. cageB.faces.length) cageB.setSubpatch(fi, true);

    OsdAccel accelA; Mesh previewA; SubpatchTrace traceA;
    assert(accelA.buildPreview(cageA, 2, previewA, traceA));
    OsdAccel accelB; Mesh previewB; SubpatchTrace traceB;
    assert(accelB.buildPreview(cageB, 2, previewB, traceB));

    assert(previewA.vertices.length == previewB.vertices.length);
    foreach (i; 0 .. previewA.vertices.length)
        assert(previewA.vertices[i] == previewB.vertices[i],
            "mark-then-weight and weight-then-mark must build the identical preview");
}

// Duplicate-crease combine-by-MAX (Risk 3): a LOW crease-map weight on an
// edge that selective subpatch ALREADY forces to SHARP_INF must not lower
// it. Mixed mesh: only face 0 marked subpatch (the other 5 are not), so
// every edge of face 0 gets SHARP_INF from selective subpatch; adding a low
// (0.05 -> sharpness 0.5) crease weight on one of those edges must leave
// the preview UNCHANGED from the no-crease-map baseline. Mutation: change
// the merge from `if (s > sharp[ei]) sharp[ei] = s;` to an unconditional
// overwrite (`sharp[ei] = s;`) -- verified 2026-08-17 to redden this test
// (see the task report).
unittest {
    Mesh cageBase = makeCube();
    cageBase.resizeSubpatch();
    cageBase.setSubpatch(0, true);   // only face 0 marked
    OsdAccel accelBase; Mesh previewBase; SubpatchTrace traceBase;
    assert(accelBase.buildPreview(cageBase, 2, previewBase, traceBase));

    Mesh cage = makeCube();
    cage.resizeSubpatch();
    cage.setSubpatch(0, true);
    // Face 0 == addFace([0, 3, 2, 1]) -- edge (0,3) borders face 0 and one
    // un-marked face, so selective subpatch already forces it SHARP_INF.
    uint ei = cage.edgeIndex(0, 3);
    assert(ei != ~0u);
    assert(cage.setCreaseWeight(ei, 0.05f));   // sharpness 0.5 << SHARP_INF

    OsdAccel accel; Mesh preview; SubpatchTrace trace;
    assert(accel.buildPreview(cage, 2, preview, trace));

    assertUnorderedMatchVec(preview.vertices, previewBase.vertices, 1e-6,
        "a low crease weight on an already-SHARP_INF (selective-subpatch) "
      ~ "edge must not lower it -- combine must be MAX, not append/overwrite");
}
