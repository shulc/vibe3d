// Module unittests for `falloff`, moved verbatim out of source/falloff.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.falloff_test;

import std.algorithm : max, min;
import std.json;
import std.math      : sqrt;
import math : Vec3, Viewport, projectToWindowFull, dot, cross,
              pointInPolygon2D, closestOnSegment2DSquared,
              AimViewport, aimSpace, ModelSpace;
import toolpipe.packets : FalloffPacket, FalloffType, FalloffShape, FalloffMix,
                          ElementConnect;
import falloff;

unittest { // Selection RAW-weight kernel vs the flat-grid diffusion law
           // (falloff-port Phase 2, tier-1 goldens). Builds a synthetic
           // 4-connected grid adjacency directly (no Mesh, no HTTP): an
           // (N+2)x(N+2) padded grid with only the inner NxN block marked
           // `inSel`, so the inner block's border vertices have a real
           // unselected neighbour one hop outside — the Dirichlet-0
           // boundary condition — exactly like a selection carved out of a
           // larger mesh.
    import std.math : abs;

    void buildPaddedGrid(int side, int N, out size_t[] offset,
                         out uint[] neighbors, out bool[] inSel)
    {
        int idx(int i, int j) { return i * side + j; }
        size_t nV = cast(size_t)(side * side);
        uint[][] adj = new uint[][](nV);
        foreach (i; 0 .. side)
            foreach (j; 0 .. side) {
                int v = idx(i, j);
                if (i > 0)        adj[v] ~= cast(uint) idx(i - 1, j);
                if (i < side - 1) adj[v] ~= cast(uint) idx(i + 1, j);
                if (j > 0)        adj[v] ~= cast(uint) idx(i, j - 1);
                if (j < side - 1) adj[v] ~= cast(uint) idx(i, j + 1);
            }
        offset = new size_t[](nV + 1);
        size_t cursor = 0;
        foreach (v; 0 .. nV) { offset[v] = cursor; cursor += adj[v].length; }
        offset[nV] = cursor;
        neighbors = new uint[](cursor);
        foreach (v; 0 .. nV)
            neighbors[offset[v] .. offset[v] + adj[v].length] = adj[v][];

        inSel = new bool[](nV);
        // Inner NxN block, offset by the 1-cell padding ring on every side.
        foreach (i; 1 .. N + 1)
            foreach (j; 1 .. N + 1)
                inSel[idx(i, j)] = true;
    }

    float smoothstepEase(float w) { return w * w * (3.0f - 2.0f * w); }

    // --- 5x5 selection (padded to a 7x7 grid) ---------------------------
    {
        size_t[] off; uint[] nbr; bool[] sel;
        buildPaddedGrid(7, 5, off, nbr, sel);
        int idx(int i, int j) { return i * 7 + j; }
        auto w2 = bakeSelectionRingWeights(off, nbr, sel, 2);
        // Block-relative (bi,bj) = (padded i,j) - 1: centre=(2,2),
        // edge=(2,1), diag=(1,1) — frozen 5x5 steps=2 goldens.
        assert(abs(w2[idx(3, 3)] - 0.25f)  < 1e-6f, "5x5 steps=2 centre");
        assert(abs(w2[idx(3, 2)] - 0.125f) < 1e-6f, "5x5 steps=2 edge");
        assert(abs(w2[idx(2, 2)] - 0.125f) < 1e-6f, "5x5 steps=2 diag");
    }

    // --- 7x7 selection (padded to a 9x9 grid) ---------------------------
    {
        size_t[] off; uint[] nbr; bool[] sel;
        buildPaddedGrid(9, 7, off, nbr, sel);
        int idx(int i, int j) { return i * 9 + j; }
        auto w2 = bakeSelectionRingWeights(off, nbr, sel, 2);
        // Block-relative (bi,bj) = (padded i,j) - 1 — frozen 7x7 steps=2
        // goldens by (dx,dz).
        assert(abs(w2[idx(2, 2)] - 0.17578125f) < 1e-6f, "7x7 steps=2 (1,1)");
        assert(abs(w2[idx(2, 3)] - 0.28125f)    < 1e-6f, "7x7 steps=2 (1,2)");
        assert(abs(w2[idx(3, 3)] - 0.515625f)   < 1e-6f, "7x7 steps=2 (2,2)");
        assert(abs(w2[idx(4, 4)] - 0.6796875f)  < 1e-6f, "7x7 steps=2 (3,3)");

        // steps_0 == steps_1 (S = max(steps,1) caps both to S=1).
        auto w0 = bakeSelectionRingWeights(off, nbr, sel, 0);
        auto w1 = bakeSelectionRingWeights(off, nbr, sel, 1);
        foreach (vi; 0 .. w0.length)
            assert(abs(w0[vi] - w1[vi]) < 1e-9f, "steps=0 must equal steps=1");
        assert(abs(w1[idx(4, 4)] - 0.84375f) < 1e-6f, "7x7 steps=0/1 centre");

        // Post-ease lock: FalloffStage applies a fixed smoothstep over the
        // RAW kernel output (see recomputeSelectionWeights) — this locks
        // the ease separately from the diffusion.
        assert(abs(smoothstepEase(w2[idx(4, 4)]) - 0.7579278945922852f) < 1e-5f,
               "post-ease smoothstep(0.6796875) must match the locked value");
    }

    // --- Degenerate invariants -------------------------------------------
    {
        // All-boundary: a single selected vertex surrounded entirely by
        // unselected padding — every neighbour is outside the selection,
        // so the lone selected vertex is itself the boundary → weight 0
        // regardless of steps.
        size_t[] off; uint[] nbr; bool[] sel;
        buildPaddedGrid(3, 1, off, nbr, sel);
        auto w = bakeSelectionRingWeights(off, nbr, sel, 2);
        foreach (vi; 0 .. w.length)
            if (sel[vi]) assert(abs(w[vi] - 0.0f) < 1e-6f,
                "all-boundary selection must read 0");

        // No-boundary: the WHOLE padded grid selected — no unselected
        // neighbour exists anywhere, so the BFS finds no boundary seed and
        // every vertex saturates at ring S -> weight 1.0.
        bool[] fullSel = new bool[](sel.length);
        fullSel[] = true;
        auto wFull = bakeSelectionRingWeights(off, nbr, fullSel, 2);
        foreach (v; wFull)
            assert(abs(v - 1.0f) < 1e-6f, "no-boundary (fully selected) must read 1");
    }
}

// ---------------------------------------------------------------------------
// Task 3022 — `falloff.steps` costs O(V+E) regardless of its VALUE: there is
// no missing kernel ceiling because there is nothing for one to cap.
// `capped = min(ring, S)` and `raw = capped / S` are the ONLY two places `S`
// appears anywhere in `bakeSelectionRingWeights` — the multi-source BFS
// visits each vertex at most once no matter how large `S` is (guarded by
// `ring[n] != UNSEEN`), and the Jacobi blur is a FIXED `foreach (pass; 0..4)`
// — so nothing here allocates or loops proportional to `steps`. Measured
// independently and earlier in doc/param_bounds_plan.md (task 0365 gap #11);
// this is the same conclusion reached a second way, pinned as a test.
//
// Proven two ways on a closed cycle (every vertex selected, so no vertex is
// ever a boundary and the BFS seeds nothing):
//   (a) a wall-clock watchdog on an ASTRONOMICALLY large `steps` — this is
//       what would trip if a "fix" for the (refuted) premise had added an
//       O(steps) loop to the kernel;
//   (b) the no-boundary degenerate reads EXACTLY 1.0 for ANY `S`, not merely
//       "close to 1": `capped == S` in the UNSEEN branch, so
//       `raw == S/S == 1` bit-for-bit, independent of how large S grows —
//       casting the same int to float twice and dividing by itself cannot
//       round to anything but exactly 1.0.
// ---------------------------------------------------------------------------
unittest {
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.format : format;

    enum size_t NV = 4000;
    size_t[] off = new size_t[](NV + 1);
    uint[]   nbr = new uint[](NV * 2);
    foreach (v; 0 .. NV) {
        off[v]         = v * 2;
        nbr[v * 2]     = cast(uint)((v + NV - 1) % NV);
        nbr[v * 2 + 1] = cast(uint)((v + 1) % NV);
    }
    off[NV] = NV * 2;
    bool[] sel = new bool[](NV);
    sel[] = true;

    auto sw = StopWatch(AutoStart.yes);
    auto w = bakeSelectionRingWeights(off, nbr, sel, 2_000_000_000);
    sw.stop();
    // 100ms is a wide margin over the true O(V+E) cost on 4000 vertices
    // (microseconds, measured well under 1ms) while still being ~15000x
    // tighter than a `steps`-proportional loop would take at S=2e9 (~1.5s
    // for a bare `long` increment loop alone, measured on this toolchain) —
    // wide enough to never flake, tight enough that an O(steps) mutation
    // cannot sneak under it.
    assert(sw.peek.total!"msecs" < 100,
           format("steps=2_000_000_000 must cost the SAME as any small steps "
                  ~ "value (O(V+E), not O(steps)) — took %d ms on %d vertices",
                  sw.peek.total!"msecs", NV));
    assert(w.length == NV);
    foreach (v; w)
        assert(v == 1.0f,
               "no-boundary selection must read EXACTLY 1.0 for ANY steps "
               ~ "value (capped == S in the UNSEEN branch, so raw == S/S == 1)");
}

unittest { // applyShape endpoints + linear midpoint
    // Ordinal-locked curve values at t=0.5: Linear=0.5, EaseIn=0.75,
    // EaseOut=0.25, Smooth=0.5. Asserted by ORDINAL/VALUE, not by a
    // vibe3d shape-STRING-to-taxonomy mapping (the "EaseIn"/"EaseOut"
    // labels are vibe3d's own naming for these two curves).
    import std.math : isClose;
    assert(isClose(applyShape(0.0f, FalloffShape.Linear,  0.5f, 0.5f), 1.0f));
    assert(isClose(applyShape(1.0f, FalloffShape.Linear,  0.5f, 0.5f), 0.0f));
    assert(isClose(applyShape(0.5f, FalloffShape.Linear,  0.5f, 0.5f), 0.5f));
    assert(isClose(applyShape(0.5f, FalloffShape.EaseIn,  0.5f, 0.5f), 0.75f));
    assert(isClose(applyShape(0.5f, FalloffShape.EaseOut, 0.5f, 0.5f), 0.25f));
    assert(isClose(applyShape(0.5f, FalloffShape.Smooth,  0.5f, 0.5f), 0.5f));
    // Custom Bezier: at in=out=0 collapses to linear (P1, P2 sit on the
    // baseline).
    assert(isClose(applyShape(0.5f, FalloffShape.Custom, 0.0f, 0.0f), 0.5f));
    assert(isClose(applyShape(0.2f, FalloffShape.Custom, 0.0f, 0.0f), 0.8f));
    // in=1, out=0 lifts P2 → curve sits above linear (more weight in
    // the second half). t=0.5: w = 0.5 + 1·0.25·0.5 = 0.625.
    assert(isClose(applyShape(0.5f, FalloffShape.Custom, 1.0f, 0.0f), 0.625f));
    // in=0, out=1 lowers P1 → curve sits below linear. t=0.5:
    // w = 0.5 - 0.25·0.5 = 0.375.
    assert(isClose(applyShape(0.5f, FalloffShape.Custom, 0.0f, 1.0f), 0.375f));
}

unittest { // linear falloff: vert at start = 1, at end = 0
    import std.math : isClose;
    FalloffPacket p;
    p.enabled = true;
    p.type    = FalloffType.Linear;
    p.shape   = FalloffShape.Linear;
    p.start   = Vec3(0, 0, 0);
    p.end     = Vec3(0, 1, 0);
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());
    assert(isClose(evaluateFalloff(p, Vec3(0, 0,    0), 0, vp), 1.0f));
    assert(isClose(evaluateFalloff(p, Vec3(0, 1,    0), 0, vp), 0.0f));
    assert(isClose(evaluateFalloff(p, Vec3(0, 0.25f, 0), 0, vp), 0.75f));
    assert(isClose(evaluateFalloff(p, Vec3(0, 0.75f, 0), 0, vp), 0.25f));
    // Past start, full influence; past end, none.
    assert(isClose(evaluateFalloff(p, Vec3(0, -2,   0), 0, vp), 1.0f));
    assert(isClose(evaluateFalloff(p, Vec3(0,  3,   0), 0, vp), 0.0f));
    // Off-axis distance ignored — projects onto the line.
    assert(isClose(evaluateFalloff(p, Vec3(5, 0.5f, 0), 0, vp), 0.5f));
}

unittest { // disabled packet returns 1.0 regardless of type
    import std.math : isClose;
    FalloffPacket p;
    p.enabled = false;
    p.type    = FalloffType.Linear;
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());
    assert(isClose(evaluateFalloff(p, Vec3(0, 1, 0), 0, vp), 1.0f));
}

unittest { // radial falloff: center = 1, surface = 0, outside = 0
    import std.math : isClose, sqrt;
    FalloffPacket p;
    p.enabled = true;
    p.type    = FalloffType.Radial;
    p.shape   = FalloffShape.Linear;
    p.center  = Vec3(0, 0, 0);
    p.size    = Vec3(1, 1, 1);
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());
    assert(isClose(evaluateFalloff(p, Vec3(0,    0, 0), 0, vp), 1.0f));
    assert(isClose(evaluateFalloff(p, Vec3(1,    0, 0), 0, vp), 0.0f));
    assert(isClose(evaluateFalloff(p, Vec3(0.5f, 0, 0), 0, vp), 0.5f));
    // Diagonal point at d = sqrt(0.5) ≈ 0.7071 → w = 1 - sqrt(0.5) ≈ 0.2929.
    assert(isClose(evaluateFalloff(p, Vec3(0.5f, 0.5f, 0), 0, vp),
                   1.0f - sqrt(0.5f), 1e-4f));
    // Outside the unit sphere → 0.
    assert(isClose(evaluateFalloff(p, Vec3(2,    0, 0), 0, vp), 0.0f));
    // Anisotropic ellipsoid: size=(2,1,1), point at x=1.
    p.size = Vec3(2, 1, 1);
    assert(isClose(evaluateFalloff(p, Vec3(1, 0, 0), 0, vp), 0.5f));
    assert(isClose(evaluateFalloff(p, Vec3(0, 1, 0), 0, vp), 0.0f));
}

unittest { // default-flip guard: a falloff with NO explicit shape now
    // yields the LINEAR curve value, not Smooth — guards against a silent
    // revert of FalloffConfig.shape's default (packets.d).
    import std.math : isClose;
    FalloffPacket p;   // p.shape left at its struct default.
    p.enabled = true;
    p.type    = FalloffType.Radial;
    p.center  = Vec3(0, 0, 0);
    p.size    = Vec3(1, 1, 1);
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());
    // t=0.25 → linear 0.75 (a Smooth default would give ≈0.844 instead —
    // this distinguishes the two curves at the same t).
    assert(isClose(evaluateFalloff(p, Vec3(0.25f, 0, 0), 0, vp), 0.75f));
}

unittest { // element falloff: spherical linear decay around a single-vertex
    // anchor. Golden points: dist=0.5, anchor at the origin; t = d/dist.
    import std.math : isClose;
    FalloffPacket p;
    p.enabled      = true;
    p.type         = FalloffType.Element;
    p.shape        = FalloffShape.Linear;
    p.pickedRadius = 0.5f;
    p.anchorPos    = [Vec3(0, 0, 0)];
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());
    assert(isClose(evaluateFalloff(p, Vec3(0, 0, 0),         0, vp), 1.0f));  // d=0
    assert(isClose(evaluateFalloff(p, Vec3(0.25f, 0, 0),     0, vp), 0.5f));  // d=0.25, t=0.5
    // d = sqrt(0.125) ≈ 0.35355 (t ≈ 0.7071) → w ≈ 0.292893 (= 1 - sqrt(2)/2).
    assert(isClose(evaluateFalloff(p, Vec3(0.25f, 0.25f, 0), 0, vp),
                   0.292893f, 1e-4f));
    assert(isClose(evaluateFalloff(p, Vec3(0.5f, 0, 0),      0, vp), 0.0f));  // d=0.5, t=1.0
}

unittest { // cylinder falloff: radial-perpendicular linear profile (axis-responsiveness)
    // Locks the cylinder kernel: weight decays linearly with radial distance
    // from the cylinder axis (measured perpendicular to it), reaching 0 at
    // r = max(size). Position along the axis is ignored entirely.
    //
    // The +Z sub-case proves axis-responsiveness: the same displacement that
    // produces w=0.3333 on the X component under +Y axis produces the same
    // weight on the Y component under +Z axis, and z-displacement (along the
    // axis) is ignored. This guards against any future "make it 1-D /
    // fixed-axis" regression that forgets to use cfg.normal.
    //
    // Golden values are analytic: r=0.75, shape=Linear, w = clamp(1-plen/r,0,1)
    // where plen = hypot of the two perpendicular-to-axis components.
    import std.math : isClose, sqrt;
    enum float tol = 1e-4f;

    // --- axis +Y: perpendicular plane is XZ ---
    FalloffPacket p;
    p.enabled = true;
    p.type    = FalloffType.Cylinder;
    p.shape   = FalloffShape.Linear;
    p.center  = Vec3(0, 0, 0);
    p.size    = Vec3(0.75f, 0.75f, 0.75f);
    p.normal  = Vec3(0, 1, 0);
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());

    // On-axis: plen=0 → w=1.0
    assert(isClose(evaluateFalloff(p, Vec3(0, 0.5f, 0), 0, vp), 1.0f, tol));
    // plen=0.5 → t=0.5/0.75=0.6667 → w=0.3333
    assert(isClose(evaluateFalloff(p, Vec3(0.5f, 0.5f, 0), 0, vp), 1.0f/3.0f, tol));
    // Same radius from a different XZ direction (plen=0.5 via Z) → same weight
    assert(isClose(evaluateFalloff(p, Vec3(0, 0.5f, 0.5f), 0, vp), 1.0f/3.0f, tol));
    // Diagonal: plen=sqrt(0.5)≈0.7071 → t≈0.9428 → w≈0.05719
    assert(isClose(evaluateFalloff(p, Vec3(0.5f, 0.5f, 0.5f), 0, vp),
                   1.0f - sqrt(0.5f)/0.75f, tol));
    // Outside (plen=0.8 > r=0.75) → w=0.0
    assert(isClose(evaluateFalloff(p, Vec3(0.8f, 0, 0), 0, vp), 0.0f, tol));

    // --- axis +Z: perpendicular plane is XY; z-displacement is ignored ---
    p.normal = Vec3(0, 0, 1);
    // On-axis (large z, plen=0) → w=1.0 regardless of z value
    assert(isClose(evaluateFalloff(p, Vec3(0, 0, 5.0f), 0, vp), 1.0f, tol));
    // plen from X only → same 0.3333
    assert(isClose(evaluateFalloff(p, Vec3(0.5f, 0, 0), 0, vp), 1.0f/3.0f, tol));
    // plen from Y only → same 0.3333
    assert(isClose(evaluateFalloff(p, Vec3(0, 0.5f, 0), 0, vp), 1.0f/3.0f, tol));
}

// ---------------------------------------------------------------------------
// Task 3025 — the intended law is DOCUMENTED at each function above
// ("degenerate line/ellipsoid/radius -> full influence") but was not, until
// now, WITNESSED: no test exercised the degenerate branches themselves, only
// real gradients. The corpus sweep for this task (every `tests/fixtures/*.json`
// that touches `falloff`, plus every block in this file and
// toolpipe/stages/falloff_test.d) found NO fixture/test accidentally parked
// on a degenerate falloff parameter while asserting something about a
// GRADIENT — the premise that motivated this task did not survive the
// sweep. What it DID surface is `tests/test_magnet.d`, which documents the
// same law from the CALLER's side: `mesh.magnet` used to inherit
// `elementWeight()`'s degenerate fallback (`dist<=0` -> every vertex weight
// 1.0, so every vertex snapped onto the target) and was fixed by REJECTING
// `dist<=0` at the command boundary rather than changing the shared kernel —
// this codebase's "REFUSE, never substitute" policy, applied to a falloff
// radius specifically. That test pins the CALLER's refusal; this one pins
// what the shared kernel itself returns when handed a degenerate input,
// which every OTHER caller still relies on (falloff.selection has its own
// degenerate law, pinned separately — the "no-boundary" block above).
//
// "Zero axis" is in the audit's own list of degenerate triggers, but
// measured precisely it is NOT independently degenerate for Cylinder: a
// zero axis falls back to `radialWeight` (a REAL gradient, if `size` is
// legit) — only a zero axis COMBINED WITH a non-positive `size` collapses
// to flat 1.0. The negative control below proves that distinction, not
// just the positive case; the audit's blanket "zero axis" phrasing
// overstates it.
// ---------------------------------------------------------------------------
unittest {
    import std.math : isClose;
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());

    // Linear: start == end (degenerate line) -> full weight everywhere, not
    // merely near the (collapsed) point.
    {
        FalloffPacket p;
        p.enabled = true;
        p.type    = FalloffType.Linear;
        p.shape   = FalloffShape.Linear;
        p.start   = Vec3(0.3f, -0.7f, 1.1f);
        p.end     = p.start;               // degenerate: zero-length axis
        foreach (pos; [Vec3(0, 0, 0), Vec3(50, 0, 0), Vec3(0.3f, -0.7f, 1.1f)])
            assert(isClose(evaluateFalloff(p, pos, 0, vp), 1.0f),
                   "Linear with start==end must read 1.0 EVERYWHERE, not "
                   ~ "just near the collapsed point");
    }

    // Radial: size == (0,0,0) (degenerate ellipsoid) -> full weight everywhere.
    {
        FalloffPacket p;
        p.enabled = true;
        p.type    = FalloffType.Radial;
        p.shape   = FalloffShape.Linear;
        p.center  = Vec3(0, 0, 0);
        p.size    = Vec3(0, 0, 0);
        foreach (pos; [Vec3(0, 0, 0), Vec3(1000, 0, 0)])
            assert(isClose(evaluateFalloff(p, pos, 0, vp), 1.0f),
                   "Radial with size=(0,0,0) must read 1.0 EVERYWHERE");
    }

    // Element: pickedRadius <= 0 (degenerate sphere) -> full weight everywhere.
    {
        FalloffPacket p;
        p.enabled      = true;
        p.type         = FalloffType.Element;
        p.shape        = FalloffShape.Linear;
        p.pickedRadius = 0.0f;
        p.anchorPos    = [Vec3(0, 0, 0)];
        foreach (pos; [Vec3(0, 0, 0), Vec3(1000, 0, 0)])
            assert(isClose(evaluateFalloff(p, pos, 0, vp), 1.0f),
                   "Element with pickedRadius=0 must read 1.0 EVERYWHERE");
        // A negative radius reads the same as zero (same "<= 1e-9" gate) —
        // this is the exact shape `tests/test_magnet.d` guards against one
        // caller away from here.
        p.pickedRadius = -3.0f;
        assert(isClose(evaluateFalloff(p, Vec3(1000, 0, 0), 0, vp), 1.0f),
               "Element with a negative pickedRadius must ALSO read 1.0 "
               ~ "EVERYWHERE, not merely near the anchor");
    }

    // Cylinder, size == (0,0,0): BOTH axis and size degenerate -> full weight.
    {
        FalloffPacket p;
        p.enabled = true;
        p.type    = FalloffType.Cylinder;
        p.shape   = FalloffShape.Linear;
        p.center  = Vec3(0, 0, 0);
        p.size    = Vec3(0, 0, 0);
        p.normal  = Vec3(0, 0, 0);
        foreach (pos; [Vec3(0, 0, 0), Vec3(1000, 0, 0)])
            assert(isClose(evaluateFalloff(p, pos, 0, vp), 1.0f),
                   "Cylinder with size=(0,0,0) must read 1.0 EVERYWHERE "
                   ~ "regardless of axis");
    }

    // NEGATIVE CONTROL — the correction above, proven rather than just
    // asserted: a zero cylinder AXIS with a REAL size is NOT degenerate. It
    // falls back to a genuine radial gradient, not flat 1.0.
    {
        FalloffPacket p;
        p.enabled = true;
        p.type    = FalloffType.Cylinder;
        p.shape   = FalloffShape.Linear;
        p.center  = Vec3(0, 0, 0);
        p.size    = Vec3(1, 1, 1);
        p.normal  = Vec3(0, 0, 0);          // degenerate axis, legit size
        assert(isClose(evaluateFalloff(p, Vec3(0, 0, 0), 0, vp), 1.0f),
               "at the center this still reads 1.0, same as any radial "
               ~ "gradient's centre — not evidence of transparency by itself");
        assert(isClose(evaluateFalloff(p, Vec3(0.5f, 0, 0), 0, vp), 0.5f),
               "a zero cylinder axis with a REAL size must fall back to a "
               ~ "genuine radial GRADIENT, not saturate to flat 1.0 — a "
               ~ "degenerate axis alone does not make this falloff "
               ~ "transparent, only a degenerate SIZE does");
        assert(isClose(evaluateFalloff(p, Vec3(1, 0, 0), 0, vp), 0.0f),
               "…and it must still reach 0 at the ellipsoid surface");
    }
}

unittest { // screen falloff: behind-camera handling
    import std.math : isClose;
    // Default Viewport has zero matrices; projectToWindowFull returns
    // false. Verifies the transparent / facing-only branch.
    FalloffPacket p;
    p.enabled    = true;
    p.type       = FalloffType.Screen;
    p.shape      = FalloffShape.Linear;
    p.screenCx   = 100;
    p.screenCy   = 100;
    p.screenSize = 50;
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());
    p.transparent = false;
    assert(isClose(evaluateFalloff(p, Vec3(0, 0, 0), 0, vp), 0.0f));
    p.transparent = true;
    assert(isClose(evaluateFalloff(p, Vec3(0, 0, 0), 0, vp), 1.0f));
}

unittest { // screen falloff: LINEAR profile (locks the curve; w = 1 - t)
    // Capture-verified against the reference engine: a Soft-Drag haul in an
    // ortho-top view on a flat grid yields a LINEAR screen attenuation
    // (RMS 0.003 vs 1-t; a Smooth curve would sit ~0.09 higher mid-ramp).
    // This guards screenWeight against silently switching shapes.
    //
    // Identity view+proj so world maps to the window predictably:
    //   projectToWindowFull → px = (x*0.5+0.5)*width.  With width=200 the
    //   origin lands at px=100 and a point at x=Δ lands at px=100+Δ*100
    //   (screen-distance Δ*100 from the disc centre).
    import std.math : isClose;
    Viewport vpW;
    vpW.view   = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    vpW.proj   = vpW.view;
    vpW.width  = 200;
    vpW.height = 200;
    auto vp = aimSpace(vpW, ModelSpace.world());
    FalloffPacket p;
    p.enabled    = true;
    p.type       = FalloffType.Screen;
    p.shape      = FalloffShape.Linear;
    p.screenCx   = 100;
    p.screenCy   = 100;
    p.screenSize = 100;        // screen-distance Δ*100 → t = Δ
    // t=0.25 → linear 0.75 (a Smooth profile would give ~0.844 — distinguishes it).
    assert(isClose(evaluateFalloff(p, Vec3(0.25f, 0, 0), 0, vp), 0.75f, 0.01f));
    // t=0.75 → linear 0.25 (Smooth → ~0.156).
    assert(isClose(evaluateFalloff(p, Vec3(0.75f, 0, 0), 0, vp), 0.25f, 0.01f));
    assert(isClose(evaluateFalloff(p, Vec3(0,    0, 0), 0, vp), 1.0f));  // centre
    assert(isClose(evaluateFalloff(p, Vec3(1.5f, 0, 0), 0, vp), 0.0f));  // beyond the disc
}

unittest { // lasso: empty / unset polygon falls through to weight = 1
    import std.math : isClose;
    FalloffPacket p;
    p.enabled    = true;
    p.type       = FalloffType.Lasso;
    p.transparent = true;
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());
    // No polygon → no-op falloff (matches plan: "unset / malformed → 1").
    assert(isClose(evaluateFalloff(p, Vec3(0, 0, 0), 0, vp), 1.0f));
}

unittest { // lasso: inside→1, outside→0, soft-border ramp via applyShape
    // Identity view+proj (width=height=200): origin→(100,100); x=Δ→px=100+Δ*100.
    // Lasso = a screen-pixel square [50,150]². Inside→1, outside→0; with a
    // soft border the outside weight ramps in via the (verified) shape curve.
    import std.math : isClose;
    Viewport vpW;
    vpW.view   = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    vpW.proj   = vpW.view;
    vpW.width  = 200;
    vpW.height = 200;
    auto vp = aimSpace(vpW, ModelSpace.world());
    FalloffPacket p;
    p.enabled    = true;
    p.type       = FalloffType.Lasso;
    p.shape      = FalloffShape.Linear;
    p.lassoPolyX = [50.0f, 150.0f, 150.0f,  50.0f];
    p.lassoPolyY = [50.0f,  50.0f, 150.0f, 150.0f];
    // origin → (100,100) inside → 1.
    assert(isClose(evaluateFalloff(p, Vec3(0, 0, 0), 0, vp), 1.0f));
    // x=0.6 → (160,100), 10px past the right edge; hard border → 0.
    p.softBorderPx = 0.0f;
    assert(isClose(evaluateFalloff(p, Vec3(0.6f, 0, 0), 0, vp), 0.0f));
    // same point with a 20px soft border → t = 10/20 = 0.5 → linear 0.5.
    p.softBorderPx = 20.0f;
    assert(isClose(evaluateFalloff(p, Vec3(0.6f, 0, 0), 0, vp), 0.5f, 0.02f));
}

unittest { // Selection (D.7): empty packet → all verts weight = 1
    import std.math : isClose;
    FalloffPacket p;
    p.enabled = true;
    p.type    = FalloffType.Selection;
    // selectionWeights left empty → "no constraint" path: every
    // vertIdx returns 1.0 regardless of position. Matches the
    // empty-selection-means-move-everything contract.
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());
    assert(isClose(evaluateFalloff(p, Vec3(0, 0, 0),    0, vp), 1.0f));
    assert(isClose(evaluateFalloff(p, Vec3(1, 2, 3),    7, vp), 1.0f));
}

unittest { // Selection (D.7): explicit weights array honored per-vert
    import std.math : isClose;
    FalloffPacket p;
    p.enabled = true;
    p.type    = FalloffType.Selection;
    // 4 verts: 2 selected (weight 1.0), 2 at decay positions.
    float[] w = [1.0f, 1.0f, 0.5f, 0.0f];
    p.selectionWeights = w;
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());
    assert(isClose(evaluateFalloff(p, Vec3.init, 0, vp), 1.0f));
    assert(isClose(evaluateFalloff(p, Vec3.init, 1, vp), 1.0f));
    assert(isClose(evaluateFalloff(p, Vec3.init, 2, vp), 0.5f));
    assert(isClose(evaluateFalloff(p, Vec3.init, 3, vp), 0.0f));
    // Out-of-range vertIdx degenerates to "no constraint" → 1.0.
    assert(isClose(evaluateFalloff(p, Vec3.init, 4,  vp), 1.0f));
    assert(isClose(evaluateFalloff(p, Vec3.init, -1, vp), 1.0f));
}

unittest { // Composite: empty contributor set → full influence
    import std.math : isClose;
    FalloffPacket p;
    p.enabled = true;
    p.type    = FalloffType.Composite;
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());
    assert(isClose(evaluateFalloff(p, Vec3(0, 0, 0), 0, vp), 1.0f));
}

unittest { // Composite math: Linear × Radial under each Mix Mode
    import std.math : isClose;
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());

    // Contributor A — Linear along +Y, weight 0.75 at y=0.25 (linear shape).
    FalloffPacket a;
    a.enabled = true;
    a.type    = FalloffType.Linear;
    a.shape   = FalloffShape.Linear;
    a.start   = Vec3(0, 0, 0);
    a.end     = Vec3(0, 1, 0);

    // Contributor B — Radial unit sphere (linear shape), weight 0.5 at
    // ellipsoid distance 0.5 from the center.
    FalloffPacket b;
    b.enabled = true;
    b.type    = FalloffType.Radial;
    b.shape   = FalloffShape.Linear;
    b.center  = Vec3(0, 0, 0);
    b.size    = Vec3(1, 1, 1);

    // Sample point: y=0.25 (A→0.75, Linear ignores off-line x) AND a radial
    // distance of 0.5 (B→0.5). Radial measures the full vector, so x is chosen
    // as √(0.5² − 0.25²) = √0.1875 to land the sphere distance exactly on 0.5.
    // Confirm the standalone weights first so the combine asserts rest on known wᵢ.
    Vec3 sample = Vec3(sqrt(0.1875f), 0.25f, 0);
    immutable float wA = evaluateFalloff(a, sample, 0, vp);  // 0.75
    immutable float wB = evaluateFalloff(b, sample, 0, vp);  // 0.5
    assert(isClose(wA, 0.75f));
    assert(isClose(wB, 0.5f));

    FalloffPacket comp;
    comp.enabled = true;
    comp.type    = FalloffType.Composite;

    // Helper: build a 2-contributor composite where B carries `m`.
    FalloffPacket build(FalloffMix m) {
        FalloffPacket c = comp;
        FalloffPacket bb = b;
        bb.mix = m;
        c.contributors = [a, bb];   // a seeds (its mix ignored)
        return c;
    }

    // evaluateFalloff takes `ref const` — bind each composite to a local.
    float evalMix(FalloffMix m) {
        auto c = build(m);
        return evaluateFalloff(c, sample, 0, vp);
    }
    // Multiply (default): 0.75 * 0.5 = 0.375
    assert(isClose(evalMix(FalloffMix.Multiply), 0.375f));
    // Add: 0.75 + 0.5 = 1.25 → clamp01 → 1.0
    assert(isClose(evalMix(FalloffMix.Add), 1.0f));
    // Subtract: 0.75 - 0.5 = 0.25
    assert(isClose(evalMix(FalloffMix.Subtract), 0.25f));
    // Max: max(0.75, 0.5) = 0.75
    assert(isClose(evalMix(FalloffMix.Max), 0.75f));
    // Min: min(0.75, 0.5) = 0.5
    assert(isClose(evalMix(FalloffMix.Min), 0.5f));
}

unittest { // Composite: single contributor == that contributor (byte-stable)
    import std.math : isClose;
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());
    FalloffPacket lin;
    lin.enabled = true;
    lin.type    = FalloffType.Linear;
    lin.shape   = FalloffShape.Linear;
    lin.start   = Vec3(0, 0, 0);
    lin.end     = Vec3(0, 1, 0);

    FalloffPacket comp;
    comp.enabled = true;
    comp.type    = FalloffType.Composite;
    comp.contributors = [lin];

    foreach (yi; 0 .. 5) {
        float y = yi * 0.25f;
        Vec3 pos = Vec3(0, y, 0);
        // Composite of one == the lone contributor, weight-for-weight.
        assert(isClose(evaluateFalloff(comp, pos, 0, vp),
                       evaluateFalloff(lin,  pos, 0, vp)));
    }
}

unittest { // Composite: three contributors fold left-to-right via per-elem mix
    import std.math : isClose;
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());
    // Three radial spheres of different sizes give three distinct weights
    // at one sample; we only need deterministic wᵢ to check the fold ORDER.
    FalloffPacket mk(float sz) {
        FalloffPacket p;
        p.enabled = true;
        p.type    = FalloffType.Radial;
        p.shape   = FalloffShape.Linear;
        p.center  = Vec3(0, 0, 0);
        p.size    = Vec3(sz, sz, sz);
        return p;
    }
    Vec3 sample = Vec3(0.5f, 0, 0);
    auto c0 = mk(1.0f);   // t=0.5 → 0.5
    auto c1 = mk(2.0f);   // t=0.25 → 0.75
    auto c2 = mk(4.0f);   // t=0.125 → 0.875
    assert(isClose(evaluateFalloff(c0, sample, 0, vp), 0.5f));
    assert(isClose(evaluateFalloff(c1, sample, 0, vp), 0.75f));
    assert(isClose(evaluateFalloff(c2, sample, 0, vp), 0.875f));

    // accum = 0.5; +0.75 = 1.25; *0.875 (no clamp mid-fold) = 1.09375;
    // final clamp01 → 1.0. Proves per-step is UNCLAMPED, final IS clamped.
    c1.mix = FalloffMix.Add;
    c2.mix = FalloffMix.Multiply;
    FalloffPacket comp;
    comp.enabled = true;
    comp.type    = FalloffType.Composite;
    comp.contributors = [c0, c1, c2];
    assert(isClose(evaluateFalloff(comp, sample, 0, vp), 1.0f));

    // Reorder so the product happens first: accum=0.5; *0.875=0.4375;
    // +0.75=1.1875 → clamp01 → 1.0. (Different intermediate, same clamp.)
    // Use a smaller seed to land inside [0,1] and prove order matters.
    auto d0 = mk(1.0f);          // 0.5
    auto d1 = mk(4.0f); d1.mix = FalloffMix.Multiply;  // 0.875
    auto d2 = mk(2.0f); d2.mix = FalloffMix.Subtract;  // 0.75
    // accum=0.5; *0.875=0.4375; -0.75=-0.3125 → clamp01 → 0.0
    FalloffPacket comp2;
    comp2.enabled = true;
    comp2.type    = FalloffType.Composite;
    comp2.contributors = [d0, d1, d2];
    assert(isClose(evaluateFalloff(comp2, sample, 0, vp), 0.0f));
}

unittest {
    // Linear falloff round-trip: {start, end} → packet with weight 0.5 mid-line.
    import std.json : parseJSON;
    import std.math : isClose;
    auto j = parseJSON(`{"type":"linear","shape":"linear",
                         "start":[0,1,0],"end":[0,-1,0]}`);
    auto fp = parseFalloffJson(j);
    assert(fp.enabled);
    assert(fp.type == FalloffType.Linear);
    assert(fp.shape == FalloffShape.Linear);
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());
    assert(isClose(evaluateFalloff(fp, Vec3(0,  1, 0), 0, vp), 1.0f));
    assert(isClose(evaluateFalloff(fp, Vec3(0,  0, 0), 0, vp), 0.5f));
    assert(isClose(evaluateFalloff(fp, Vec3(0, -1, 0), 0, vp), 0.0f));
}

unittest { // vertexMapWeight: lookup + clamp + degenerate cases
    import std.math : isClose;
    FalloffPacket fp;
    fp.enabled = true;
    fp.type    = FalloffType.VertexMap;
    Viewport vpW;
    auto vp = aimSpace(vpW, ModelSpace.world());

    // empty slice → full influence
    assert(isClose(evaluateFalloff(fp, Vec3(0, 0, 0), 0, vp), 1.0f));

    float[3] raw = [0.0f, 0.5f, 1.5f]; // last entry above 1 → clamped to 1
    fp.vertexMapWeights = raw[];
    assert(isClose(evaluateFalloff(fp, Vec3(0, 0, 0), 0, vp), 0.0f));
    assert(isClose(evaluateFalloff(fp, Vec3(0, 0, 0), 1, vp), 0.5f));
    assert(isClose(evaluateFalloff(fp, Vec3(0, 0, 0), 2, vp), 1.0f)); // clamped
    // out-of-range → full influence
    assert(isClose(evaluateFalloff(fp, Vec3(0, 0, 0), 5, vp), 1.0f));
    // negative vertIdx → full influence
    assert(isClose(evaluateFalloff(fp, Vec3(0, 0, 0), -1, vp), 1.0f));
}
