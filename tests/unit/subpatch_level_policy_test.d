// Module unittests for the subpatch DEPTH POLICY and the cage flatten it
// reads its input from (task 1374, phase 1).
//
// Two separate claims live here, and they are proved by different means:
//
//   1. `chooseSubpatchLevel` picks the SAME level as the formula it replaced
//      on every all-quad cage, and a DIFFERENT one — in a named, bounded band
//      — on triangle and n-gon cages. The reference side of that comparison is
//      the old formula WRITTEN OUT IN THIS FILE (`legacyChooseLevel`). It must
//      never be expressed in terms of `projectedLimitFaces` or
//      `chooseSubpatchLevel`: a reference that consults the policy under test
//      moves with it, and the equivalence assertion then passes for every
//      possible policy, including a deliberately broken one. That is the
//      inert-comparison failure mode this file exists to avoid.
//
//   2. `projectedLimitFaces` is the count OSD actually produces. Algebra is
//      not evidence for that, so the second half of the file builds real
//      previews through `OsdAccel.buildPreview` on quad, triangle and
//      hexagon cages and compares against `preview.faces.length`.
module tests.unit.subpatch_level_policy_test;

import math : Vec3;
import mesh : Mesh, SubpatchTrace, makeCube;
import subpatch_osd;

// ---------------------------------------------------------------------------
// The formula this task replaced, transcribed from the pre-1374
// `OsdAccel.buildPreview` depth-cap block (the `MAX_LIMIT_FACES` while-loop).
// Reference side ONLY — see the module header for why it is spelled out
// rather than called.
// ---------------------------------------------------------------------------
private int legacyChooseLevel(long nf, int requested,
                              long limitFaces = 1_500_000)
{
    int effectiveLevel = requested;
    long mul = 1L;
    foreach (k; 0 .. requested) mul *= 4L;
    long projected = nf * mul;
    while (effectiveLevel > 1 && projected > limitFaces) {
        --effectiveLevel;
        projected /= 4L;
    }
    return effectiveLevel;
}

// ---------------------------------------------------------------------------
// QUAD CAGES: identical, everywhere.
//
// This is the claim the change is allowed to make without an owner decision.
// The sweep deliberately walks THROUGH both cliff edges (nf·4^L crossing
// 1.5M at every requested level) rather than sampling round numbers, because
// the two formulas can only ever differ AT a cliff — a sweep that steps over
// one proves nothing.
// ---------------------------------------------------------------------------
unittest {
    foreach (int requested; 1 .. 5) {
        // Every nf where the legacy projection lands within ±4 of a cliff, plus
        // a coarse background sweep.
        long[] probes;
        foreach (int lvl; 1 .. requested + 1) {
            long mul = 1L;
            foreach (k; 0 .. lvl) mul *= 4L;
            immutable long cliff = 1_500_000 / mul;
            foreach (long d; -4 .. 5)
                if (cliff + d >= 1) probes ~= cliff + d;
        }
        foreach (long nf; [1L, 2L, 7L, 100L, 6_000L, 24_576L, 93_636L,
                           94_249L, 99_856L, 400_000L, 2_000_000L])
            probes ~= nf;

        foreach (long nf; probes) {
            immutable int want = legacyChooseLevel(nf, requested);
            immutable int got  = chooseSubpatchLevel(4 * nf, requested);
            if (got != want) {
                import std.format : format;
                assert(false, format(
                    "quad cage nf=%d requested=%d: the corner-based policy "
                    ~ "must be IDENTICAL to the face-based one it replaced, "
                    ~ "but legacy=%d new=%d", nf, requested, want, got));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// TRIANGLE CAGES: the level moves UP, in TWO bands at the shipped depth.
//
// Σ|f| = 3nf, so the true limit-face count is 0.75× the legacy projection and
// the legacy formula capped a level too early. This is a LIVE behaviour change
// — every triangulated import is in this class — and it costs 4× the
// refinement work inside each band. Both edges of both bands are asserted, not
// just membership: a band that silently widens is the regression to catch.
//
// TWO, not one. The general rule (see projectedLimitFaces' comment, and the
// exhaustive sweep further down) is that the new policy is the old one under a
// rescaled ceiling C' = 4C/r, so the two disagree in one band per LEVEL
// TRANSITION — R-1 of them at requested depth R, not one per cage class. At
// the shipped depth of 3 the triangle class has the L2 → L3 band below and the
// L1 → L2 band after it, and the SECOND one is the expensive one.
// ---------------------------------------------------------------------------
unittest {
    enum int kRequested = 3;   // app.d's subpatchDepth

    // ===== BAND A — nf ∈ [23 438, 31 250], L2 -> L3 =====================

    // Just BELOW the band: both formulas say 3.
    assert(legacyChooseLevel(23_437, kRequested) == 3);
    assert(chooseSubpatchLevel(3 * 23_437, kRequested) == 3,
        "nf=23437 tri: below band A, the policies must still agree");

    // The band's first cage: legacy drops to 2, the exact projection keeps 3.
    assert(legacyChooseLevel(23_438, kRequested) == 2);
    assert(chooseSubpatchLevel(3 * 23_438, kRequested) == 3,
        "nf=23438 tri: band A's lower edge — legacy capped to 2, the exact "
        ~ "corner projection (3*23438*16 = 1124976 <= 1.5M) admits 3");

    // The band's last cage: 3*31250 = 93750 corners, 16x = 1.5M exactly, so
    // the ceiling is met, not exceeded — `>` not `>=` is load-bearing here.
    assert(legacyChooseLevel(31_250, kRequested) == 2);
    assert(chooseSubpatchLevel(3 * 31_250, kRequested) == 3,
        "nf=31250 tri: band A's upper edge — 3*31250*16 = 1500000, exactly "
        ~ "the ceiling, which the strict `>` admits");

    // Just ABOVE the band: both say 2 again.
    assert(legacyChooseLevel(31_251, kRequested) == 2);
    assert(chooseSubpatchLevel(3 * 31_251, kRequested) == 2,
        "nf=31251 tri: above band A, the policies must agree again");

    // And the band is CONTIGUOUS — no interior cage where they re-agree.
    foreach (long nf; 23_438 .. 31_251) {
        if (nf % 97 != 0) continue;      // stride: 81 samples, not 7813
        assert(legacyChooseLevel(nf, kRequested) == 2);
        assert(chooseSubpatchLevel(3 * nf, kRequested) == 3,
            "band A interior: every cage in [23438, 31250] must move L2 -> L3");
    }

    // ===== BAND B — nf ∈ [93 751, 125 000], L1 -> L2 ====================
    //
    // THE EXPENSIVE ONE, and the one a reviewer chasing a Tab-cost regression
    // lands on first: ~100 000 triangles is what an ordinary OBJ / glTF / FBX
    // import produces. Inside this band the first Tab goes from 375 000 limit
    // faces to 1 500 000 — at this task's measured 4.45-4.96 us and ~225 B per
    // limit face, ~1.7 s -> ~7 s and ~85 MB -> ~345 MB. It is asserted here so
    // that the cost is a DECLARED property of the policy rather than a
    // discovery someone makes in a profiler.

    // Just BELOW band B both policies agree at 2 — the legacy projection is
    // exactly AT the ceiling there, which the strict `>` admits.
    assert(legacyChooseLevel(93_750, kRequested) == 2);
    assert(chooseSubpatchLevel(3 * 93_750, kRequested) == 2,
        "nf=93750 tri: below band B, both readings admit L2 "
        ~ "(legacy 93750*16 = 1500000 == the ceiling)");

    // The band's first cage: legacy falls to the floor of 1, the exact
    // projection still fits L2 (3*93751*4 = 1125012 <= 1.5M).
    assert(legacyChooseLevel(93_751, kRequested) == 1);
    assert(chooseSubpatchLevel(3 * 93_751, kRequested) == 2,
        "nf=93751 tri: band B's LOWER edge — legacy dropped to 1, the exact "
        ~ "corner projection (3*93751*4 = 1125012 <= 1.5M) admits 2. This is "
        ~ "the 4x cost this change introduces on triangulated imports");

    // The band's last cage: 3*125000 = 375000 corners, 4x = 1.5M exactly.
    assert(legacyChooseLevel(125_000, kRequested) == 1);
    assert(chooseSubpatchLevel(3 * 125_000, kRequested) == 2,
        "nf=125000 tri: band B's UPPER edge — 3*125000*4 = 1500000, exactly "
        ~ "the ceiling. 1.5M limit faces is the ~7 s / ~345 MB point measured "
        ~ "at matrix point D");

    // Just ABOVE: both fall to the floor of 1.
    assert(legacyChooseLevel(125_001, kRequested) == 1);
    assert(chooseSubpatchLevel(3 * 125_001, kRequested) == 1,
        "nf=125001 tri: above band B, the policies agree again at the floor");

    foreach (long nf; 93_751 .. 125_001) {
        if (nf % 397 != 0) continue;     // stride: 79 samples, not 31250
        assert(legacyChooseLevel(nf, kRequested) == 1);
        assert(chooseSubpatchLevel(3 * nf, kRequested) == 2,
            "band B interior: every cage in [93751, 125000] must move L1 -> L2");
    }
}

// ---------------------------------------------------------------------------
// THE GENERAL RULE, exhaustively — one band per LEVEL TRANSITION, R-1 of them.
//
// The two arms above and the hexagon arm below name specific bands, and an
// enumeration invites exactly the mistake this file made in its first draft:
// believing it is complete. It is not a substitute for the RULE, and the rule
// is what is checked here, over a full sweep with no stride.
//
// new admits L  iff  nf*r*4^(L-1) <= C   iff   nf*4^L <= 4C/r  ==  C'
// old admits L  iff  nf*4^L       <= C
//
// i.e. the same rule under a rescaled ceiling, so the disagreement set is
// exactly the union over transitions L in [2, R] of
//
//     nf in ( min(C,C')/4^L , max(C,C')/4^L ]
//
// — R-1 maximal runs, each with computed edges. Sweeping nf without a stride
// is what makes "the set is EXACTLY this" assertable rather than "these
// samples are in it": a strided sweep cannot see a band that is one cage wide
// in the wrong place.
// ---------------------------------------------------------------------------
unittest {
    enum long C      = 1_500_000;   // MEM_LIMIT_FACES, spelled out (reference)
    enum long kSweep = 140_000;     // > 125 000, the largest band edge in range

    static long pow4(int e) { long m = 1; foreach (_; 0 .. e) m *= 4; return m; }

    foreach (int requested; 2 .. 6) {
        foreach (long r; [3L, 4L, 6L]) {
            immutable long cPrime = 4 * C / r;
            immutable long lo     = cPrime < C ? cPrime : C;
            immutable long hi     = cPrime < C ? C      : cPrime;

            // Predicted bands, from the rule alone.
            long[2][] want;
            foreach (int L; 2 .. requested + 1) {
                immutable long a = lo / pow4(L) + 1;      // (lo/4^L, ...
                immutable long b = hi / pow4(L);          //           hi/4^L]
                if (b >= a) want ~= [a, b];
            }

            // Observed bands, from a full sweep of the two policies.
            long[2][] got;
            foreach (long nf; 1 .. kSweep + 1) {
                immutable bool differs =
                    legacyChooseLevel(nf, requested)
                        != chooseSubpatchLevel(r * nf, requested);
                if (differs) {
                    if (got.length && got[$-1][1] == nf - 1) got[$-1][1] = nf;
                    else                                      got ~= [nf, nf];
                }
            }

            import std.format : format;
            if (r == 4) {
                assert(got.length == 0, format(
                    "quad cages (r=4) rescale the ceiling by 1, so the two "
                    ~ "policies must NEVER disagree — found %s at requested=%d",
                    got, requested));
                continue;
            }
            assert(got.length == cast(size_t)(requested - 1), format(
                "r=%d requested=%d: the rule says ONE band per level "
                ~ "transition, i.e. R-1 = %d bands, but the sweep found %d: %s",
                r, requested, requested - 1, got.length, got));
            // `want` is built high-L-first, `got` low-nf-first: reverse one.
            foreach (i, b; got)
                assert(b == want[$ - 1 - i], format(
                    "r=%d requested=%d band %d: the rule predicts nf in "
                    ~ "(%d, %d] but the policies actually diverge on %s",
                    r, requested, i, want[$-1-i][0] - 1, want[$-1-i][1], b));
        }
    }

    // The band edges named in projectedLimitFaces' doc comment, in the task
    // file and in the arms above are all derived for C = 1 500 000. Re-deriving
    // them from `C` here would be a tautology on literals; what is NOT a
    // tautology, and is the thing that actually rots, is the reference `C`
    // above drifting away from the production ceiling. Tie them:
    assert(MEM_LIMIT_FACES == C,
        "the memory ceiling moved. Every band edge written down in this file, "
        ~ "in projectedLimitFaces' doc comment and in the task file was derived "
        ~ "for C = 1 500 000 and must be re-derived — including the expensive "
        ~ "triangle band nf in [93751, 125000], which is what a reader chasing "
        ~ "a Tab-cost regression looks for first");
}

// ---------------------------------------------------------------------------
// N-GON CAGES: the level moves DOWN — the memory ceiling was being BREACHED.
//
// Σ|f| = 6nf for a hexagonal cage, so the true count is 1.5× the legacy
// projection: the legacy formula admitted a level whose real stencil build is
// half again as large as the ceiling allows. This arm is why the fix is not
// optional — the constant exists to keep OSD's stencil build in memory, and
// it was not doing that job off a quad cage.
//
// Driven entirely through `cornerCount = 6*nf`, which is the reason the
// signature takes corners: asserting this on a real mesh would mean building
// a 62 501-hexagon cage.
//
// Stated at requested depth 2, where R-1 = 1 and this band is therefore the
// WHOLE divergence. At the SHIPPED depth of 3 the hexagon class has two, the
// second being nf in [15 626, 23 437] (L3 -> L2); both are covered by the
// exhaustive general-rule sweep above, which is where the completeness claim
// lives. Do not read this arm as "the hexagon band".
// ---------------------------------------------------------------------------
unittest {
    enum int kRequested = 2;

    assert(legacyChooseLevel(62_500, kRequested) == 2);
    assert(chooseSubpatchLevel(6 * 62_500, kRequested) == 2,
        "nf=62500 hex: 6*62500*4 = 1500000, exactly the ceiling — still 2");

    assert(legacyChooseLevel(62_501, kRequested) == 2);
    assert(chooseSubpatchLevel(6 * 62_501, kRequested) == 1,
        "nf=62501 hex: THE band's lower edge — the legacy projection (1000016) "
        ~ "fits the ceiling while the TRUE one (1500024) does not");

    assert(legacyChooseLevel(93_750, kRequested) == 2);
    assert(chooseSubpatchLevel(6 * 93_750, kRequested) == 1,
        "nf=93750 hex: the band's upper edge");

    assert(legacyChooseLevel(93_751, kRequested) == 1);
    assert(chooseSubpatchLevel(6 * 93_751, kRequested) == 1,
        "nf=93751 hex: above the band both formulas cap to 1");
}

// ---------------------------------------------------------------------------
// The memory ceiling is still ENFORCED — the property the constant exists for.
//
// Mutation this is here to catch: delete the `projectedLimitFaces(...) >
// memLimitFaces` term from `chooseSubpatchLevel`'s loop (i.e. return
// `requested` unconditionally). Every band assertion above still passes for
// the triangle arm — those expect the HIGHER level — so without this block a
// policy that caps nothing at all reads as an improvement.
// ---------------------------------------------------------------------------
unittest {
    // The concrete case the old constant was tuned around: the 24 576-quad
    // fixture at the app's requested depth of 3.
    assert(chooseSubpatchLevel(4 * 24_576, 3) == 2,
        "24576 quads at depth 3 projects 1572864 limit faces — over the "
        ~ "ceiling — so the policy must cap to 2");

    // General form. For EVERY (cage, request) in a wide sweep the answer must
    // either sit under the ceiling or be the floor of 1.
    foreach (long cc; [4L, 12L, 4_000L, 98_304L, 399_424L, 1_499_999L,
                       1_500_000L, 1_500_001L, 6_000_000L, 99_000_000L]) {
        foreach (int req; 1 .. 9) {
            immutable int lvl = chooseSubpatchLevel(cc, req);
            assert(lvl >= 1 && lvl <= req,
                "the policy may only ever LOWER the requested level, never raise it");
            assert(lvl == 1 || projectedLimitFaces(cc, lvl) <= MEM_LIMIT_FACES,
                "a level above the floor must fit the memory ceiling");
            if (lvl < req)
                assert(projectedLimitFaces(cc, lvl + 1) > MEM_LIMIT_FACES,
                    "the policy must pick the LARGEST level that fits — if "
                    ~ "level+1 also fits, it capped too far");
        }
    }

    // The ceiling is a parameter, and it is really read: the same cage answers
    // differently under a tighter one. Without this, `memLimitFaces` could be
    // ignored in favour of the enum and nothing above would notice.
    assert(chooseSubpatchLevel(4 * 24_576, 3, long.max) == 3,
        "an unbounded ceiling must admit the full requested depth");
    assert(chooseSubpatchLevel(4 * 24_576, 3, 1_000) == 1,
        "a tiny ceiling must drive the level to the floor of 1");
}

// ---------------------------------------------------------------------------
// Loop bound: an absurd `requested` cannot make the policy spin.
//
// `requested` arrives from app state / prefs / the command layer, and the
// policy's loop walks DOWN one level per iteration. MAX_SUBPATCH_LEVEL clamps
// it before the loop; this pins that the clamp is BEFORE the loop and not a
// comment about one. (It is deliberately not observable as a different ANSWER
// — no cage can be refined 16 times under the memory ceiling — so the
// assertion is on the answer's boundedness, and the real proof is that this
// test terminates.)
// ---------------------------------------------------------------------------
unittest {
    // Driven with an UNBOUNDED ceiling on purpose. Under the production
    // ceiling the clamp is invisible in the ANSWER — a cage that projects over
    // 1.5M limit faces is walked back down to the same level with or without
    // it, and only the iteration count differs — so an assertion phrased
    // against the default ceiling would be inert and would ALSO hang under the
    // mutation instead of failing. With `long.max` the projection loop never
    // bites, and the clamp becomes the only thing that can bound the answer.
    assert(chooseSubpatchLevel(4, int.max, long.max) == MAX_SUBPATCH_LEVEL,
        "an absurd requested level must be clamped BEFORE the projection loop "
        ~ "walks it down one step at a time");
    assert(chooseSubpatchLevel(4, 40, long.max) == MAX_SUBPATCH_LEVEL);
    assert(chooseSubpatchLevel(4, 5, long.max) == 5,
        "a request below the clamp must pass through untouched");

    assert(chooseSubpatchLevel(4, 0) == 0,
        "level < 1 is the caller's reject sentinel (buildPreview returns false) "
        ~ "and must be handed back untouched, not clamped up to 1");
    assert(projectedLimitFaces(4, int.max) == long.max,
        "the projection must saturate rather than wrap");
    assert(projectedLimitFaces(0, 3) == 0 && projectedLimitFaces(-5, 3) == 0);
}

// ---------------------------------------------------------------------------
// `projectedLimitFaces` == what OSD actually emits.
//
// The algebra above is only worth what this block says it is. Three cage
// classes, because the whole point of the change is that they DISAGREE:
// quads (where old and new both happened to be right), triangles, hexagons.
// ---------------------------------------------------------------------------
private long previewFaceCount(ref Mesh cage, int level) {
    OsdAccel      accel;
    // `~this()` calls only `clear()`, which leaves the LRU(2) slots — and the
    // `osdc_topology_t*` a successful build installs in one — alive. Every
    // fixture below would leak one OSD refiner per call without this.
    scope (exit) accel.destroyCache();
    Mesh          preview;
    SubpatchTrace trace;
    immutable bool ok = accel.buildPreview(cage, level, preview, trace);
    assert(ok, "buildPreview failed on the fixture cage");
    return cast(long)preview.faces.length;
}

private void markAll(ref Mesh m) {
    m.resizeSubpatch();
    foreach (fi; 0 .. m.faces.length) m.setSubpatch(fi, true);
}

unittest {
    // --- quads: the cube, 6 faces, 24 corners.
    {
        Mesh cage = makeCube();
        markAll(cage);
        foreach (int lvl; 1 .. 4)
            assert(previewFaceCount(cage, lvl) == projectedLimitFaces(24, lvl),
                "cube: OSD's limit face count must equal the corner projection");
        // ... and the LEGACY formula agrees here, which is exactly why a
        // quad-only fixture set could never have caught the bug.
        foreach (int lvl; 1 .. 4) {
            long mul = 1; foreach (k; 0 .. lvl) mul *= 4;
            assert(previewFaceCount(cage, lvl) == 6 * mul,
                "control: on a QUAD cage the legacy nf*4^L formula is also "
                ~ "right — a quad fixture cannot discriminate the two");
        }
    }

    // --- triangles: a tetrahedron, 4 faces, 12 corners.
    {
        Mesh cage;
        cage.vertices = [
            Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1),
        ];
        cage.addFace([0u, 2u, 1u]);
        cage.addFace([0u, 1u, 3u]);
        cage.addFace([0u, 3u, 2u]);
        cage.addFace([1u, 2u, 3u]);
        markAll(cage);
        foreach (int lvl; 1 .. 4) {
            immutable long got = previewFaceCount(cage, lvl);
            assert(got == projectedLimitFaces(12, lvl),
                "tetrahedron: OSD emits Sum|f| * 4^(L-1) limit faces");
            // THE DISCRIMINATOR. The legacy formula predicts nf*4^L = 4*4^L,
            // which is 4/3 of the truth — so this fixture separates the two
            // formulas, and the cube above cannot.
            long mul = 1; foreach (k; 0 .. lvl) mul *= 4;
            assert(got != 4 * mul,
                "the legacy nf*4^L projection must be WRONG here — if it is "
                ~ "right, this fixture is not discriminating and the tests "
                ~ "above prove nothing about triangles");
        }
    }

    // --- n-gons: one hexagon, 6 corners.
    {
        Mesh cage;
        cage.vertices = [
            Vec3(1, 0, 0), Vec3(0.5f, 0, 0.87f), Vec3(-0.5f, 0, 0.87f),
            Vec3(-1, 0, 0), Vec3(-0.5f, 0, -0.87f), Vec3(0.5f, 0, -0.87f),
        ];
        cage.addFace([0u, 1u, 2u, 3u, 4u, 5u]);
        markAll(cage);
        foreach (int lvl; 1 .. 4) {
            immutable long got = previewFaceCount(cage, lvl);
            assert(got == projectedLimitFaces(6, lvl),
                "hexagon: OSD emits Sum|f| * 4^(L-1) limit faces");
            long mul = 1; foreach (k; 0 .. lvl) mul *= 4;
            assert(got != 1 * mul,
                "the legacy projection UNDER-counts a hexagon by 1.5x — this "
                ~ "is the arm proving the memory ceiling was breachable");
        }
    }
}

// ---------------------------------------------------------------------------
// buildPreview REALLY chooses its level from corners — the production wiring,
// not just the pure function.
//
// This is the arm that catches the whole change being reverted at the CALL
// SITE (`chooseSubpatchLevel(cageCornerCount, ...)` -> `chooseSubpatchLevel(4 *
// nf, ...)`), which every assertion above is blind to: they exercise the pure
// function directly and so agree with a production path that never calls it.
//
// Driven by the CEILING rather than by the cage. Asking this question at the
// production ceiling of 1 500 000 needs a cage of at least 23 438 triangles —
// a 1.1-million-face refinement inside the unit lane, per assertion. One
// hexagon plus a ceiling of 20 asks it exactly.
// ---------------------------------------------------------------------------
unittest {
    Mesh cage;
    cage.vertices = [
        Vec3(1, 0, 0), Vec3(0.5f, 0, 0.87f), Vec3(-0.5f, 0, 0.87f),
        Vec3(-1, 0, 0), Vec3(-0.5f, 0, -0.87f), Vec3(0.5f, 0, -0.87f),
    ];
    cage.addFace([0u, 1u, 2u, 3u, 4u, 5u]);   // nf = 1, Sum|f| = 6
    markAll(cage);

    long facesAt(long ceiling) {
        OsdAccel      accel;
        scope (exit) accel.destroyCache();   // see previewFaceCount
        Mesh          preview;
        SubpatchTrace trace;
        immutable bool ok = accel.buildPreview(cage, 3, preview, trace, ceiling);
        assert(ok, "buildPreview failed on the hexagon cage");
        return cast(long)preview.faces.length;
    }

    // THE READING. Ceiling 20 admits level 1 only when the projection is read
    // in CORNERS (6, then 24, then 96). Read in FACES the same cage projects
    // 1, 4, 16 -- so it would admit level 2 and emit 24 faces.
    assert(facesAt(20) == 6,
        "ceiling 20: the corner projection admits level 1 only (6 limit "
        ~ "faces). 24 here means the level was chosen from the FACE count, "
        ~ "i.e. the pre-1374 formula is back at the call site");

    // CONTROLS. Ceiling 24 is a cell where both readings agree (both pick
    // level 2), and an unbounded ceiling reaches the full requested depth --
    // together they show the reading above is a LEVEL CHOICE and not a cage
    // that simply cannot refine further.
    assert(facesAt(24) == 24,
        "control: ceiling 24 admits level 2 under either reading");
    assert(facesAt(long.max) == 96,
        "control: with no ceiling the cage refines to the requested level 3");
}

// ---------------------------------------------------------------------------
// `flattenCageTopology` — output equivalence, and the ONE witness that is not
// inert.
//
// MEASURED, 2026-08-19, ldc2 1.42 / this druntime, appending 400 000 ints one
// at a time versus sizing once and filling by index:
//
//     append:  GC.allocatedInCurrentThread delta =      8 096 B, capacity 400 379
//     exact :  GC.allocatedInCurrentThread delta =  1 601 536 B, capacity 400 379
//     append: 7 pointer moves total, ~4 KB copied (8 moves / 69 KB on a
//             deliberately fragmented heap)
//
// So BOTH of the obvious witnesses for "this reallocates" are inert here, and
// the alloc-bytes one points the WRONG WAY: druntime grows a page-backed array
// in place through `GC.extend`, so the append path allocates almost nothing
// AFTER the first page and lands on the SAME capacity. The plan's premise for
// this site — "~19 reallocations with a memmove and full garbage each" — does
// not hold on this runtime; the copying is ~4 KB, not ~3.2 MB.
//
// What the old code could NOT do, and this can, is REUSE: it built a fresh
// local per rebuild. That is the property asserted below, and the mutation it
// catches is restoring the original (fresh local + `~=`).
// ---------------------------------------------------------------------------
unittest {
    // A cage with enough faces to be past every small-array special case, and
    // MIXED degree so the flatten's index bookkeeping is actually exercised
    // (a uniform-degree cage would pass a flatten that ignored `face.length`).
    Mesh cage;
    foreach (i; 0 .. 200)
        cage.vertices ~= Vec3(cast(float)i, 0, 0);
    foreach (i; 0 .. 40) {
        immutable uint b = cast(uint)(i * 4);
        cage.addFace([b, b + 1u, b + 2u]);                  // triangle
        cage.addFace([b, b + 1u, b + 2u, b + 3u]);          // quad
    }

    // --- output equivalence against the loop this replaced.
    int[] refCounts = new int[](cage.faces.length);
    int[] refIndices;
    foreach (fi, face; cage.faces) {
        refCounts[fi] = cast(int)face.length;
        foreach (vi; face) refIndices ~= cast(int)vi;
    }

    int[] counts, indices;
    immutable long cc = flattenCageTopology(cage, counts, indices);

    assert(cc == cast(long)refIndices.length,
        "the returned corner count must be Sum|f|");
    assert(counts  == refCounts,   "per-face counts must match the old loop");
    assert(indices == refIndices,  "flattened indices must match the old loop");
    assert(indices.length == cast(size_t)cc,
        "the index buffer must be sized EXACTLY to the corner count, with no "
        ~ "trailing slack a consumer would hash or hand to OSD");

    // --- THE WITNESS: called again with the same buffers, it must not move
    // them. A fresh-local `~=` flatten cannot satisfy this, because the buffer
    // it fills is a different one every call.
    auto countsPtr  = counts.ptr;
    auto indicesPtr = indices.ptr;
    immutable long cc2 = flattenCageTopology(cage, counts, indices);
    assert(cc2 == cc);
    assert(counts.ptr  is countsPtr,
        "a repeat flatten at the same cage size must reuse the counts buffer");
    assert(indices.ptr is indicesPtr,
        "a repeat flatten at the same cage size must reuse the index buffer — "
        ~ "this is the assertion that fails if the fresh-local `~=` flatten "
        ~ "comes back");

    // A SHRINKING cage must also not reallocate (capacity is retained), and
    // must not leave the previous cage's tail visible.
    Mesh small;
    small.vertices = cage.vertices[0 .. 8];
    small.addFace([0u, 1u, 2u, 3u]);
    immutable long ccSmall = flattenCageTopology(small, counts, indices);
    assert(ccSmall == 4);
    assert(indices.length == 4, "the buffer must be re-sized DOWN, not left long");
    assert(indices.ptr is indicesPtr, "shrinking must not reallocate either");
}

// ---------------------------------------------------------------------------
// `destroyCache()` is safe STANDALONE — the property that replaced an ordering
// contract on its callers (task 1374 review, SF-4).
//
// The LRU(2) slots own the OSD handles; `OsdAccel`'s own `osd` / `glEval` /
// `cageGlVbo` / `limitGlVbo` fields are borrowed aliases into whichever slot
// was last active. Freeing the slots while those aliases still point into them
// and `valid` still says yes is a use-after-free waiting for the next
// `refresh()`, which gates on `valid` and nothing else. That used to be
// prevented by every caller remembering to call `clear()` first — two sites,
// both correct, and a public function whose safety lived in a comment.
//
// `valid` is the only one of the five fields visible from outside the module,
// and it is also the one `refresh()` actually reads, so it is both the safety
// property and the witness. Mutation: delete the five reset lines at the
// bottom of `destroyCache()` (or just `valid = false;`) — this goes red, and
// with them present no call order can produce the dangling state.
// ---------------------------------------------------------------------------
unittest {
    Mesh cage = makeCube();
    markAll(cage);

    OsdAccel      accel;
    Mesh          preview;
    SubpatchTrace trace;
    assert(accel.buildPreview(cage, 2, preview, trace));
    assert(accel.valid,
        "control: a successful build must leave the accel valid — otherwise "
        ~ "the assertion below passes for a build that never happened");

    // NO clear() here. That is the whole point.
    accel.destroyCache();
    assert(!accel.valid,
        "destroyCache() must leave the accel invalid on its own: it just freed "
        ~ "the storage `osd`/`glEval`/`cageGlVbo`/`limitGlVbo` alias, and "
        ~ "`refresh()` gates on `valid` alone");

    // Idempotent — a second call must not double-free (the slots were reset to
    // CachedTopology.init above, so every handle guard sees null/0).
    accel.destroyCache();
    assert(!accel.valid);
}
