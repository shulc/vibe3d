module vibe3d.editing.selection.query.tests.unit.snap_regression_test;

import vibe3d.editing.selection.query.snap;
import vibe3d.util.math.math : Vec3, closestOnSegment2DSquared;
import vibe3d.util.spatial.spatial : Viewport, ModelSpace, projectToWindowFull;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : SnapPacket, SnapType, SnapMode;
import vibe3d.editing.selection.query.toolpipe.guide : SnapGuide, kGuidePrioritySeed;
import std.math : sqrt, round;



// ---------------------------------------------------------------------------
// S4(a) of doc/toolpipe_architecture_plan.md — the guide registry, and the
// equivalence that makes registering a real guide safe later.
//
// Phase (a) lands the interface, the registry and the arbitration path with
// the registry EMPTY, so the arbitration branch is unreachable and nothing in
// the tree ranks differently. That is a statement about REACHABILITY, and a
// test cannot observe it — the grep is the proof, not this block.
//
// What this block proves is the other half, the half phase (b) will rest on:
// that the two ranking paths AGREE. Four obligations:
//
//   1. EQUIVALENCE. A guide whose `proximity` mirrors the service's own
//      distance rule — same projection, same pixel difference, same sqrt,
//      priority 0 — must reproduce the no-guide result field for field,
//      INCLUDING the tie-break. If phase (b)'s first guide changes a fixture,
//      this block says the change came from the guide's policy and not from
//      the mechanism that carries it.
//   2. IDENTITY. The guide is offered exactly the candidates the enumeration
//      offers, with exactly the (type, index, slot) triple the sibling seam
//      `SnapAdmit` sees for the same query — cross-checked against a real
//      `admit` run rather than against a hand-written expectation. A design
//      that consulted the guide only about the WINNER would pass an
//      "equivalence" test and fails this one.
//   3. RE-RANK. The guide's `distPx` is the ranking value, not decoration: a
//      guide that inverts the distance order must hand the snap to the
//      FARTHEST candidate. This is the assertion that fails if the returned
//      distance is dropped and the service's own is ranked instead.
//   4. ARBITRATION. Between two guides that both admit a candidate, the higher
//      `priority` decides — and priority outranks distance, which is exactly
//      the rule phase (b) turns on.
//
// The fixture is collinear vertices with NO faces, so `needVis` is false and
// ranking is pure screen distance: what the assertions observe is the property
// under test and not the visibility gate.
// ---------------------------------------------------------------------------
version (unittest) {
    import vibe3d.editing.selection.query.toolpipe.guide : GuideDrawState;

    /// A guide that answers with the service's own rule: same projection, same
    /// pixel difference, same sqrt, priority 0, admits everything that
    /// projects. Registering it must change nothing.
    private class MirrorGuide : SnapGuide {
        Viewport vp;
        int      sx, sy;

        // Observation channel — the candidates this guide was offered, in
        // order, as a packed (type, idx, slot) key. Fixed storage: the walk is
        // hot and an allocating guide would be testing the allocator.
        long[256] seen;
        size_t    seenCount;

        // What the stage pushed in, and what it last asked us to draw.
        float          innerPx = -1, outerPx = -1;
        GuideDrawState draw    = GuideDrawState.Off;

        // The priority this guide answers with — 0 for the mirror, overridden
        // by the arbitration block below.
        int answerPrio = 0;
        // When true the guide INVERTS the ranking: near reads as far. The
        // inverted distance stays inside the acceptance range on purpose —
        // `bestDist` is what the merge tests against `innerRangePx`, so a
        // guide's answer decides acceptance as well as order, and an inverted
        // ranking that reported 900 px would prove nothing but a miss.
        bool  invert     = false;
        float invertBase = 0;
        // Types this guide refuses outright.
        bool admitAll = true;
        // One candidate promoted above the rest. This is the ONLY way to
        // exercise the accumulator's priority term: `arbitrate` settles which
        // GUIDE answers for a candidate, and if every candidate then comes
        // back at the same priority, "(priority, distance)" and "distance" are
        // the same rule. A guide that ranks one candidate above its
        // neighbours is what tells them apart.
        int elevateIdx  = -1;
        int elevatePrio = 1;
        // When true this guide never touches the priority slot at all, which
        // is how "did not say" is told apart from "said 0".
        bool silent = false;

        this(Viewport v, int x, int y) { vp = v; sx = x; sy = y; }

        // `nothrow` so the S1 predicate below — which is `nothrow` by its
        // alias — can call it and record the same sequence.
        static long key(SnapType t, int idx, int slot) pure nothrow @safe {
            return (cast(long)t << 40) | (cast(long)(idx + 2) << 8) | cast(long)slot;
        }

        override void limits(float i, float o) { innerPx = i; outerPx = o; }

        override bool proximity(Vec3 candWorld, SnapType type, int idx, int slot,
                       ref float distPx, ref int priority)
        {
            if (seenCount < seen.length) seen[seenCount++] = key(type, idx, slot);
            if (!admitAll) return false;
            float qx, qy, qz;
            if (!projectToWindowFull(candWorld, vp, qx, qy, qz)) return false;
            immutable float dx = qx - cast(float)sx;
            immutable float dy = qy - cast(float)sy;
            immutable float d  = sqrt(dx * dx + dy * dy);
            distPx   = invert ? (invertBase - d) : d;
            // `silent` leaves the slot exactly as the caller seeded it — the
            // only way to observe that the seed exists.
            if (!silent) priority = (idx == elevateIdx) ? elevatePrio : answerPrio;
            return true;
        }

        override void setDrawState(GuideDrawState s) { draw = s; }
    }
}


unittest {
    import vibe3d.util.math.math     : lookAt, perspectiveMatrix;
    import std.math : PI;

    // Same reason as the S1 block above: this module's other unittests
    // populate the slot-0 grids, and a fresh local Mesh can land on a recycled
    // address carrying the same (never-changed) bus epoch.
    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    Mesh m;
    m.vertices = [
        Vec3(0.00f, 0, 0),   // 0 — directly under the cursor pixel
        Vec3(0.15f, 0, 0),   // 1 — the runner-up
        Vec3(0.30f, 0, 0),   // 2 — the farthest, and still inside acceptance
    ];

    float px0, py0, ndc0;
    assert(projectToWindowFull(m.vertices[0], vp, px0, py0, ndc0),
        "fixture: vertex 0 must project on-screen");
    immutable int sx = cast(int)round(px0);
    immutable int sy = cast(int)round(py0);

    float pixDist(Vec3 w) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: every candidate must project on-screen");
        immutable float dx = qx - cast(float)sx;
        immutable float dy = qy - cast(float)sy;
        return sqrt(dx * dx + dy * dy);
    }

    SnapPacket cfg;
    cfg.enabled      = true;
    cfg.enabledTypes = SnapType.Vertex;   // discrete tier only, one type
    cfg.snapScope    = SnapMode.Global;
    cfg.innerRangePx = 30.0f;
    cfg.outerRangePx = 100.0f;

    immutable float d0 = pixDist(m.vertices[0]);
    immutable float d1 = pixDist(m.vertices[1]);
    immutable float d2 = pixDist(m.vertices[2]);
    assert(d0 < d1 && d1 < d2,
        "fixture: the three candidates must rank strictly by screen distance");
    assert(d2 < cfg.innerRangePx,
        "fixture: even the farthest candidate must be able to SNAP, so that a "
        ~ "re-ranking guide's winner is a snap and not a bare highlight");

    // The value an inverting guide reflects distances about: `invertBase - d`
    // reverses the order while keeping every answer inside acceptance, so what
    // the re-rank block observes is the ORDER changing and not the range test
    // failing.
    immutable float invertBase = d2 + 1.0f;
    assert(invertBase <= cfg.innerRangePx,
        "fixture: the whole reflected range must stay inside acceptance, or "
        ~ "the re-rank block would be testing the acceptance test");

    // Not any candidate's position: the pass-through assertions are only
    // meaningful if the input is distinguishable from every candidate.
    immutable Vec3 cursorWorld = Vec3(7.5f, -3.25f, 1.125f);

    static bool sameVec(Vec3 a, Vec3 b) {
        return a.x == b.x && a.y == b.y && a.z == b.z;
    }
    // Field for field rather than `a == b`, so a failure names WHICH field
    // diverged and a field added to SnapResult shows up here as an omission.
    static bool sameResult(SnapResult a, SnapResult b) {
        return sameVec(a.worldPos, b.worldPos)
            && sameVec(a.highlightPos, b.highlightPos)
            && a.snapped        == b.snapped
            && a.highlighted    == b.highlighted
            && a.targetType     == b.targetType
            && a.targetIndex    == b.targetIndex
            && a.targetSource   == b.targetSource
            && a.constraintType == b.constraintType;
    }

    // --- baseline: no guide at all, i.e. every call site in the tree ---------
    SnapResult bare = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg);
    assert(bare.snapped && bare.targetIndex == 0
        && bare.targetType == SnapType.Vertex && bare.targetSource == 0,
        "baseline: vertex 0 sits under the cursor");
    assert(sameVec(bare.worldPos, m.vertices[0]));

    // --- 1. EQUIVALENCE: the mirror guide changes nothing --------------------
    invalidateSnapGrids();
    auto mirror = new MirrorGuide(vp, sx, sy);
    SnapResult guided = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
                                   [mirror]);
    assert(sameResult(bare, guided),
        "S4 equivalence: a guide that mirrors the service's own distance rule "
        ~ "must reproduce the no-guide result field for field — this is the "
        ~ "pin that makes registering a REAL guide a change of policy and not "
        ~ "a change of mechanism");

    // --- 2. IDENTITY: the guide sees the enumeration, not the winner ---------
    // Cross-checked against the sibling seam rather than a hand-written list:
    // both are consulted per candidate, in the same walk, so the sequences
    // must be identical. A guide consulted only about the winner would have a
    // sequence of length 1 here.
    invalidateSnapGrids();
    long[256] admitSeen;
    size_t    admitCount;
    SnapResult admitted = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null,
        (SnapType t, int i, int s) {
            if (admitCount < admitSeen.length)
                admitSeen[admitCount++] = MirrorGuide.key(t, i, s);
            return true;
        });
    assert(sameResult(bare, admitted), "sanity: the S1 seam is still neutral");
    assert(admitCount >= 3,
        "fixture: the enumeration must offer all three vertices, else the "
        ~ "sequence comparison below is vacuous");
    assert(mirror.seenCount == admitCount,
        "S4 identity: the guide must be offered exactly as many candidates as "
        ~ "the admission predicate is — the two seams sit in the same walk");
    assert(mirror.seen[0 .. mirror.seenCount] == admitSeen[0 .. admitCount],
        "S4 identity: and the same candidates, in the same order, with the "
        ~ "same (type, index, slot) triple");

    // --- 3. RE-RANK: the guide's distance is the ranking value ---------------
    invalidateSnapGrids();
    auto inverted = new MirrorGuide(vp, sx, sy);
    inverted.invert     = true;
    inverted.invertBase = invertBase;
    SnapResult flipped = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
                                    [inverted]);
    assert(flipped.snapped && flipped.targetIndex == 2,
        "S4 re-rank: a guide that inverts the distance order must hand the "
        ~ "snap to the FARTHEST candidate — if the service ranked by its own "
        ~ "distance and merely asked the guide for permission, vertex 0 would "
        ~ "still win and nothing would announce it");
    assert(sameVec(flipped.worldPos, m.vertices[2]),
        "the guide re-ranks a candidate; it never moves one");

    // --- ...and rejecting everything is the clean pass-through --------------
    invalidateSnapGrids();
    auto refuses = new MirrorGuide(vp, sx, sy);
    refuses.admitAll = false;
    SnapResult none = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
                                 [refuses]);
    SnapPacket offCfg = cfg;
    offCfg.enabled = false;
    SnapResult disabled = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), offCfg);
    assert(sameResult(none, disabled),
        "S4: a guide that admits nothing must be the same clean pass-through "
        ~ "as `cfg.enabled == false` — a rejected candidate must be as if it "
        ~ "had never been enumerated");

    // --- 4a. RANKING: priority outranks distance BETWEEN CANDIDATES ---------
    // One guide, mirroring the distance rule, that promotes the FARTHEST
    // candidate by one priority level. The promoted candidate must win even
    // though two nearer ones were offered first and were admitted.
    //
    // This is the block that separates "(priority, distance) wins" from
    // "nearest wins", and it is the only shape that can: `arbitrate` settles
    // which GUIDE answers for a candidate, so a fixture where every candidate
    // comes back at the same priority leaves the accumulator's priority term
    // dead and unobserved. Deleting the term must fail HERE.
    invalidateSnapGrids();
    auto elevator = new MirrorGuide(vp, sx, sy);
    elevator.elevateIdx  = 2;
    elevator.elevatePrio = 1;
    SnapResult elevated = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null,
                                     null, [elevator]);
    assert(elevated.snapped && elevated.targetIndex == 2,
        "S4 ranking: a candidate at a higher priority beats a nearer one at a "
        ~ "lower priority — priority is the first term of the key, distance "
        ~ "only the second");
    assert(sameVec(elevated.worldPos, m.vertices[2]));

    // ...and the promotion must not be order-dependent: promoting the NEAREST
    // candidate changes nothing, because it already won on distance.
    invalidateSnapGrids();
    auto elevateNear = new MirrorGuide(vp, sx, sy);
    elevateNear.elevateIdx = 0;
    SnapResult elevatedNear = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null,
                                         null, [elevateNear]);
    assert(sameResult(bare, elevatedNear),
        "promoting the candidate that already won on distance is a no-op — "
        ~ "the priority term must not reorder anything by itself");

    // --- 4. ARBITRATION: priority outranks distance --------------------------
    // Two guides over the same candidates. `low` mirrors the distance rule at
    // priority 0; `high` inverts it at priority 1. The higher priority must
    // decide, and it must decide AGAINST the nearer candidate — otherwise
    // "(priority, distance)" would be indistinguishable from "distance".
    invalidateSnapGrids();
    auto low  = new MirrorGuide(vp, sx, sy);
    auto high = new MirrorGuide(vp, sx, sy);
    high.invert     = true;
    high.invertBase = invertBase;
    high.answerPrio = 1;
    SnapResult arb = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
                                [low, high]);
    assert(arb.snapped && arb.targetIndex == 2,
        "S4 arbitration: the higher-priority guide decides, even though the "
        ~ "lower-priority one reported a shorter distance");

    // Order of registration must not matter to the priority decision.
    invalidateSnapGrids();
    auto low2  = new MirrorGuide(vp, sx, sy);
    auto high2 = new MirrorGuide(vp, sx, sy);
    high2.invert     = true;
    high2.invertBase = invertBase;
    high2.answerPrio = 1;
    SnapResult arbSwapped = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null,
                                       null, [high2, low2]);
    assert(sameResult(arb, arbSwapped),
        "S4 arbitration: priority decides, so registration order must not — "
        ~ "it settles EQUAL priorities and nothing else");

    // ...and when the priorities ARE equal, registration order is the whole
    // tie-break the registry can offer. Two guides at priority 0 that disagree
    // about distance: the FIRST registered must be the one heard.
    invalidateSnapGrids();
    auto firstMirror = new MirrorGuide(vp, sx, sy);
    auto secondFlip  = new MirrorGuide(vp, sx, sy);
    secondFlip.invert     = true;
    secondFlip.invertBase = invertBase;
    assert(firstMirror.answerPrio == secondFlip.answerPrio,
        "fixture: this block is about EQUAL priorities");
    SnapResult tiedPrio = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null,
                                     null, [firstMirror, secondFlip]);
    assert(tiedPrio.snapped && tiedPrio.targetIndex == 0,
        "S4 arbitration: at equal priority the first-registered guide is "
        ~ "heard — a later guide must not be able to overrule a peer it does "
        ~ "not outrank");
    invalidateSnapGrids();
    auto firstFlip    = new MirrorGuide(vp, sx, sy);
    firstFlip.invert     = true;
    firstFlip.invertBase = invertBase;
    auto secondMirror = new MirrorGuide(vp, sx, sy);
    SnapResult tiedPrioSwapped = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg,
                                            null, null,
                                            [firstFlip, secondMirror]);
    assert(tiedPrioSwapped.snapped && tiedPrioSwapped.targetIndex == 2,
        "and the same two guides in the other order give the other answer — "
        ~ "which is what makes the previous assertion about ORDER and not "
        ~ "about which guide happens to be right");

    // --- the PRE-SEEDED priority: "did not say" is not "said 0" -------------
    // MEASURED (kGuidePrioritySeed). A guide that never touches the priority
    // slot answers with the seed, so it OUTRANKS a guide that explicitly says
    // zero — and it does so from second place in the registry, where a
    // same-priority peer could not have overruled the first.
    //
    // FAILS ON AN `out` PARAMETER, which is what this used to be: the silent
    // guide's answer would zero itself, the two priorities would tie, and
    // registration order would hand the result to `saysZero` instead.
    invalidateSnapGrids();
    auto saysZero = new MirrorGuide(vp, sx, sy);
    assert(saysZero.answerPrio == 0, "fixture: the loud guide names zero");
    auto saysNothing = new MirrorGuide(vp, sx, sy);
    saysNothing.silent     = true;
    saysNothing.invert     = true;
    saysNothing.invertBase = invertBase;
    assert(kGuidePrioritySeed > saysZero.answerPrio,
        "fixture: the seed must outrank an explicit zero, or this proves nothing");
    SnapResult seeded = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
                                   [saysZero, saysNothing]);
    assert(seeded.snapped && seeded.targetIndex == 2,
        "S4: the priority slot is PRE-SEEDED, so a guide that ignores it is heard at the "
        ~ "seed's rank and not at zero");

    // --- the tie-break survives the guide path ------------------------------
    // Two coincident vertices: a tie by construction (a mirrored ±x pair only
    // ties to within floating point, which is not a tie). The service breaks
    // it by ascending index under a strict `<`; the mirror guide, feeding the
    // same distances into the same comparison, must break it the same way.
    invalidateSnapGrids();
    Mesh tie;
    tie.vertices = [Vec3(0.25f, 0, 0), Vec3(0.25f, 0, 0)];
    assert(pixDist(tie.vertices[0]) == pixDist(tie.vertices[1]),
        "fixture: the two candidates must be an EXACT tie, otherwise this "
        ~ "block tests ranking and not tie-breaking");
    assert(pixDist(tie.vertices[0]) < cfg.innerRangePx,
        "fixture: the tied pair must be close enough to snap");

    SnapResult tieBare = snapCursor(cursorWorld, sx, sy, vp, tie, ModelSpace.world(), cfg);
    assert(tieBare.snapped && tieBare.targetIndex == 0,
        "the tie goes to the lower index");
    invalidateSnapGrids();
    auto tieMirror = new MirrorGuide(vp, sx, sy);
    SnapResult tieGuided = snapCursor(cursorWorld, sx, sy, vp, tie, ModelSpace.world(), cfg, null,
                                      null, [tieMirror]);
    assert(sameResult(tieBare, tieGuided),
        "S4 equivalence: the tie-break is part of the result, so it is part "
        ~ "of the equivalence — a guide path that compared with `<=` would "
        ~ "hand the tie to the higher index and pass every other assertion "
        ~ "in this block");

    // --- the constraint tier carries the same arbitration --------------------
    invalidateSnapGrids();
    float pxa, pya, ndca;
    assert(projectToWindowFull(Vec3(1, 0, 0), vp, pxa, pya, ndca));
    immutable int cx = cast(int)round(pxa);
    immutable int cy = cast(int)round(pya);

    // The constraint tier: a box whose z = 0 face is under the pixel, corners out of range.
    setItemSnapFrames([ItemSnapFrame(Vec3(0, 0, 0), Vec3(-60, -60, -60), Vec3(60, 0, 0), true)]);
    scope (exit) setItemSnapFrames(null);
    SnapPacket ccfg = cfg;
    ccfg.enabledTypes = SnapType.Box;

    SnapResult cBare = snapCursor(cursorWorld, cx, cy, vp, m, ModelSpace.world(), ccfg);
    assert(cBare.snapped && cBare.constraintType == SnapType.Box,
        "fixture: a box-face constraint must fire at this pixel, otherwise "
        ~ "the constraint-tier assertions below are vacuous");

    invalidateSnapGrids();
    auto cMirror = new MirrorGuide(vp, cx, cy);
    SnapResult cGuided = snapCursor(cursorWorld, cx, cy, vp, m, ModelSpace.world(), ccfg, null,
                                    null, [cMirror]);
    assert(sameResult(cBare, cGuided),
        "S4 equivalence holds in the constraint tier too");

    invalidateSnapGrids();
    auto cRefuses = new MirrorGuide(vp, cx, cy);
    cRefuses.admitAll = false;
    SnapResult cNone = snapCursor(cursorWorld, cx, cy, vp, m, ModelSpace.world(), ccfg, null, null,
                                  [cRefuses]);
    assert(cRefuses.seenCount >= 1,
        "fixture: the face planes must be offered to the guide");
    assert(!cNone.snapped && cNone.constraintType == SnapType.None
        && sameVec(cNone.worldPos, cursorWorld),
        "S4: a guide that rejects must be able to veto a CONSTRAINT too — "
        ~ "otherwise a guide whose whole job is an admission rule would "
        ~ "reject every element and then watch a constraint hit sail past it");

    invalidateSnapGrids();
}


// Task 20262040: the edited-mesh finder must carry the same S4 guide election.
// Evidence: doc/application_layers_wave5_query_acceptance_2026-10-09/README.md.
unittest {
    import vibe3d.util.math.math : lookAt, perspectiveMatrix;
    import std.math : PI;

    invalidateSnapGrids();
    Viewport vp;
    vp.eye = Vec3(0, 0, 5);
    vp.view = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width = vp.height = 800;
    Mesh m;
    m.vertices = [Vec3(0.00f, 0, 0), Vec3(0.15f, 0, 0), Vec3(0.30f, 0, 0)];

    float px0, py0, z0, px2, py2, z2;
    assert(projectToWindowFull(m.vertices[0], vp, px0, py0, z0)
        && projectToWindowFull(m.vertices[2], vp, px2, py2, z2),
        "edited guide fixture: both endpoint vertices must project");
    immutable int sx = cast(int)round(px0);
    immutable int sy = cast(int)round(py0);
    auto inverted = new MirrorGuide(vp, sx, sy);
    inverted.invert = true;
    inverted.invertBase = sqrt((px2 - sx) * (px2 - sx) + (py2 - sy) * (py2 - sy)) + 1.0f;
    SnapPacket cfg;

    assert(editedVertexAt(sx, sy, vp, m, ModelSpace.world(), cfg, 30, null) == 0,
        "edited guide baseline: null guides keep the nearest vertex 0");
    assert(editedVertexAt(sx, sy, vp, m, ModelSpace.world(), cfg, 30, [inverted]) == 2,
        "edited guide forwarding: the inverted guide must elect vertex 2");
    assert(inverted.seenCount == 3,
        "edited guide population: exactly three edited vertices reach the guide");
    assert(inverted.seen[0 .. inverted.seenCount] == [
        MirrorGuide.key(SnapType.Vertex, 0, 0),
        MirrorGuide.key(SnapType.Vertex, 1, 0),
        MirrorGuide.key(SnapType.Vertex, 2, 0)],
        "edited guide identity: vertices 0, 1, 2 are offered once in edited slot 0");
    invalidateSnapGrids();
}






// ---------------------------------------------------------------------------
// TASK 0551 — THE REGISTRY MEETS THE CASCADE: PRIORITY IS STILL THE FIRST TERM.
//
// This block exists because the four S4 guide unittests above CANNOT observe
// this. Their fixture is `enabledTypes = SnapType.Vertex` over a vertices-only
// mesh — ONE cascade class — so no candidate of theirs can ever reach a second
// cascade slot, and they would have stayed green whatever the cascade did to
// priority between classes. Citing them as evidence that the registry is
// unaffected was a null control, and this is the test that could have failed.
//
// The two directions are asserted separately because a fold that reads no
// priority breaks BOTH, and each direction fails on its own:
//
//   * Elevate the EDGE over a vertex the cascade would have preferred.
//   * Elevate the VERTEX over an edge the cascade would have preferred.
//
// Each half first pins, with the SAME guide at a flat priority, that the
// cascade really does prefer the other class — otherwise "the higher priority
// won" would be indistinguishable from "the cascade happened to agree".
// ---------------------------------------------------------------------------
version (unittest) {
    /// A guide that answers with the service's own screen distance and a
    /// priority that depends on the candidate's TYPE.
    ///
    /// Deliberately not a knob on `MirrorGuide`: that guide keys its promotion
    /// on element INDEX, which is the one axis that cannot express "this class
    /// outranks that class", and it carries five other switches this block must
    /// be seen not to depend on.
    private class TypePriorityGuide : SnapGuide {
        Viewport vp;
        int      sx, sy;
        SnapType elevateType = SnapType.None;
        int      elevatePrio = 1;
        int      basePrio    = 0;

        this(Viewport v, int x, int y) { vp = v; sx = x; sy = y; }


        override bool proximity(Vec3 candWorld, SnapType type, int idx, int slot,
                       ref float distPx, ref int priority)
        {
            float qx, qy, qz;
            if (!projectToWindowFull(candWorld, vp, qx, qy, qz)) return false;
            immutable float dx = qx - cast(float)sx;
            immutable float dy = qy - cast(float)sy;
            distPx  = sqrt(dx * dx + dy * dy);
            priority = (type == elevateType) ? elevatePrio : basePrio;
            return true;
        }

    }
}


unittest {
    import vibe3d.util.math.math     : lookAt, perspectiveMatrix;
    import std.math : PI, round;

    invalidateSnapGrids();

    // The same 80 px per world unit at z = 0 the behavioural test above uses:
    // screen = (400 + 80x, 400 - 80y).
    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    // Vertex 0 is the contested vertex; the edge runs out of it along +X, so
    // the edge's nearest point is always at least as close as the vertex.
    Mesh m;
    m.vertices = [ Vec3(0, 0, 0), Vec3(1, 0, 0) ];
    m.edges    = [ [0u, 1u] ];

    SnapPacket cfg;
    cfg.enabled      = true;
    cfg.enabledTypes = SnapType.Vertex | SnapType.Edge;   // TWO cascade classes

    immutable float base = kCandidateToleranceBasePx;
    immutable float tolV = kVertexToleranceScale * base;

    float[2] pixelOf(Vec3 w) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: every fixture point must project on-screen");
        return [qx, qy];
    }

    // Distances the two classes will carry into the cascade, for a cursor.
    void measure(Vec3 cursorWorld, out int sx, out int sy,
                 out float dVert, out float dEdge)
    {
        auto cpix = pixelOf(cursorWorld);
        sx = cast(int)round(cpix[0]);
        sy = cast(int)round(cpix[1]);
        auto a = pixelOf(m.vertices[0]);
        auto b = pixelOf(m.vertices[1]);
        dVert = sqrt((a[0] - sx) * (a[0] - sx) + (a[1] - sy) * (a[1] - sy));
        float t;
        dEdge = sqrt(closestOnSegment2DSquared(cast(float)sx, cast(float)sy,
                                               a[0], a[1], b[0], b[1], t));
    }

    // --- direction 1: the guide puts EDGE above the vertex the cascade wants -
    // Geometry is the reported case: the vertex trails by more than one base
    // and less than the doubled one, so the cascade prefers the VERTEX.
    {
        immutable Vec3 cursorWorld = Vec3(0.2f, 0.05f, 0);
        int sx, sy; float dVert, dEdge;
        measure(cursorWorld, sx, sy, dVert, dEdge);
        immutable float trail = dVert - dEdge;
        assert(dEdge < dVert && trail > base && trail < tolV,
            "fixture: the cascade must prefer the VERTEX here, or elevating "
            ~ "the edge would prove nothing about priority");

        // Control: the same guide at a FLAT priority must leave the cascade's
        // own answer standing. Without this line "the edge won" could be the
        // guide's mere presence rather than its priority.
        invalidateSnapGrids();
        auto flat = new TypePriorityGuide(vp, sx, sy);
        SnapResult f = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
                                  [flat]);
        assert(f.snapped && f.targetType == SnapType.Vertex,
            "control: at a flat priority the cascade decides, and it says "
            ~ "Vertex");

        invalidateSnapGrids();
        auto edgeUp = new TypePriorityGuide(vp, sx, sy);
        edgeUp.elevateType = SnapType.Edge;
        SnapResult r = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
                                  [edgeUp]);
        assert(r.snapped && r.targetType == SnapType.Edge && r.targetIndex == 0,
            "a guide that outranks the vertex class must WIN, even though the "
            ~ "cross-type cascade prefers the vertex on distance. Resolving "
            ~ "Vertex here means the cascade was asked before the priorities "
            ~ "were compared, and the registry's rule — higher priority wins "
            ~ "outright, at any distance — was silently dropped");
    }

    // --- direction 2: the guide puts VERTEX above the edge the cascade wants -
    // Same geometry, cursor further out along the edge: now the vertex trails
    // by MORE than its doubled tolerance, so the cascade prefers the EDGE.
    {
        immutable Vec3 cursorWorld = Vec3(0.28f, 0.05f, 0);
        int sx, sy; float dVert, dEdge;
        measure(cursorWorld, sx, sy, dVert, dEdge);
        immutable float trail = dVert - dEdge;
        assert(trail >= tolV,
            "fixture: the vertex must trail by its WHOLE doubled tolerance, or "
            ~ "the cascade would prefer it and elevating it would prove "
            ~ "nothing");
        assert(dVert <= cfg.innerRangePx,
            "fixture: and the vertex must still be inside the acceptance "
            ~ "range, or promoting it would produce a highlight and not a snap");

        invalidateSnapGrids();
        auto flat = new TypePriorityGuide(vp, sx, sy);
        SnapResult f = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
                                  [flat]);
        assert(f.snapped && f.targetType == SnapType.Edge,
            "control: at a flat priority the cascade decides, and at this "
            ~ "distance it says Edge");

        invalidateSnapGrids();
        auto vertUp = new TypePriorityGuide(vp, sx, sy);
        vertUp.elevateType = SnapType.Vertex;
        SnapResult r = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null, null,
                                  [vertUp]);
        assert(r.snapped && r.targetType == SnapType.Vertex
            && r.targetIndex == 0,
            "and the other direction: a guide that outranks the EDGE class "
            ~ "must win against the class the cascade prefers. The two "
            ~ "directions are asserted separately because a fold that reads no "
            ~ "priority at all breaks both, and neither one alone shows it");
    }

    invalidateSnapGrids();
}
