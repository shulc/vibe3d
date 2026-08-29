module mesh_visibility;

// The visibility probe: `VisibilityProbe`, its builder `visibilityProbe`, and
// the whole-mesh convenience wrapper `visibleVertices` → extracted from
// `struct Mesh` (task 3230, step 2 of `doc/tasks/work/2910-mesh-struct-seams.md`).
//
// WHY THIS GROUP FIRST AMONG THE PLAN'S CANDIDATES: it reads zero private
// members of `Mesh` and leaks zero of its own (its state lives inside
// `VisibilityProbe`'s own `private { … }` block, which travels whole), no
// census test names any of its three public symbols, and it is the ONLY
// consumer of `screen_buckets` inside `mesh.d` — so this move deletes that
// import from the god module rather than merely relocating it. Coupling
// measured 2026-08-29 (`doc/tasks/work/3230-mesh-seam-step-two.md` §Посылка).
//
// TWO NAMES BEYOND THE PLAN'S THREE MOVE WITH IT, and both are decisions
// recorded in the card rather than in the plan: `VisibilityCounters` /
// `g_visCounters` (below) are `version(unittest)`-only instrumentation used
// EXCLUSIVELY by `evaluate()`/`visibilityProbe()` and by
// `tests/unit/snap_visibility_corpus_test.d` — moving them here avoids a
// fresh two-way dependency (`mesh_visibility` reading a global back out of
// `mesh`) that leaving them behind would have created, given `mesh.d`
// re-exports this module.
//
// re-exported unchanged: `public import mesh_visibility;` in `mesh.d`, the
// same home template `mesh_topo` / `mesh_corner_maps` / `mesh_gpu` already
// use. `visibilityProbe`/`visibleVertices` reach every existing
// `m.visibilityProbe(...)` / `m.visibleVertices(...)` call site through UFCS
// (measured mechanism, plan 2910 §1.6 П3) — but UFCS through a `public
// import` re-export needs the free function NAMED in the caller's own
// import, not merely reachable through `mesh`'s re-export (measured with a
// standalone probe: a caller doing `import mesh : Mesh;` does NOT see a
// free function `mesh_visibility` only re-exports; adding the name to that
// selective import list fixes it). `source/snap.d` and
// `tests/unit/snap_visibility_corpus_test.d` are edited for exactly this —
// see the card's §Находки.

import mesh : Mesh;
import math : Vec3, Viewport, ModelSpace, projectionSpace, projectToWindowFull,
              frontFacingLocal, pointInPolygon2D;
import perf_probe : g_perf, Cat;
import screen_buckets : ScreenBuckets, buildScreenBuckets, queryScreenCell,
                        OCCL_CELL_PX, MAX_OCCL_BUCKET_INTS;

// ---------------------------------------------------------------------------
// VISIBILITY-MASK INSTRUMENTATION — test-only (task 1351 Ф1).
//
// `visibleVertices` decides five separate things, and from OUTSIDE the
// call only the `bool[]` comes back — so a corpus that compares masks cannot
// say WHICH clause produced a given bit, and a fixture set that quietly stopped
// reaching one of them would keep comparing byte-identical against its own
// silence (the inert-measurement trap, task 0635). These counters are what
// `tests/unit/snap_visibility_corpus_test.d` asserts non-zero, one clause at a
// time.
//
// WHY NOT `perf_probe.Cat`. The perf counters are gated on `version(PerfProbe)`,
// which the `tests` build configuration does not define — a corpus written
// against them would read zeroes in the gate that actually runs it. These are
// gated on `version(unittest)` instead, so they exist exactly where the corpus
// does and cost the shipped build nothing (the increments are not compiled).
// The perf counters (`snapVisVertexProbe`, `snapVisPairsTested`, ...) answer a
// different question — cost per drag in a running editor — and both sets stay.
version (unittest) {
    struct VisibilityCounters {
        // --- clause counters ---
        long occluded;      // seeded TRUE by pass 1, turned false by pass 2
        long seedFalse;     // never seeded: no unhidden front-facing face owns it
        long invalidProj;   // behind the camera — `projectToWindowFull` said no
        long hiddenSkip;    // faces dropped by `isFaceHidden`
        long anyValidSkip;  // faces dropped: EVERY corner is behind the eye
        long allValidSkip;  // faces dropped: SOME corner is behind the eye
        // --- PATH counters (task 1351 Ф1.5) ---
        //
        // The five clause counters above take IDENTICAL values on the linear
        // walk and on the bucketed broad phase, by the superset contract: the
        // broad phase only narrows WHICH occluders are offered to an unchanged
        // exact predicate. So not one of them witnesses that the buckets were
        // consulted at all — which is the exact defect that made the snap
        // ELECTION corpus unable to testify about the candidate grid (it kept
        // the same digest with the grid ceiling dropped to zero). These two
        // say which arm ran, and the corpus asserts a per-fixture EXPECTED
        // value rather than a total.
        long gridQueries;   // vertex probes answered from a bucket
        long linearQueries; // vertex probes that walked the whole front list
        // The two clauses the query PAD buys, each separately falsifiable.
        // Without them "the pad is applied" is unobservable: the mask is
        // identical either way and `gridQueries` merely shifts a little.
        long gridOutsideVp; // ...from a bucket, at a pixel OUTSIDE the viewport
        long gridNegPixel;  // ...from a bucket, at a NEGATIVE window pixel,
                            //    i.e. where the absolute cell index is < 0
        // (candidate x occluder) bbox tests — the quantity the broad phase
        // exists to reduce. The perf build counts the same thing as
        // `Cat.snapVisPairsTested`; this copy exists because the `tests`
        // build configuration does not define PerfProbe, so the corpus could
        // not read that one.
        long pairsTested;
        void reset() { this = VisibilityCounters.init; }
    }
    __gshared VisibilityCounters g_visCounters;
}

// -----------------------------------------------------------------------
// VisibilityProbe — the BUILT half of `visibleVertices`, split from the
// per-vertex ANSWER so a caller that needs five vertices stops paying for
// a hundred thousand.
//
// WHY THE SPLIT IS BIT-IDENTICAL, and it is by construction rather than by
// measurement: pass 2's answer for a vertex depends on nothing pass 2
// writes. It reads the seed, the projected pixel and the front list, all
// produced by passes 0 and 1; it writes only its own `vis[vi]`. The walk
// order over the front list can change WHICH occluder stops the walk, but
// not WHETHER one does — the loop breaks at the first occluder and the
// result is a bool. So evaluating on demand, in any order, and memoising,
// returns the same array `visibleVertices` returned before.
//
// THE ONE ASYMMETRY WORTH SPELLING OUT, because the obvious factoring gets
// it backwards: a vertex that IS seeded but whose projection failed comes
// out VISIBLE, not hidden. Pass 1 seeds every corner of a front-facing
// unhidden face BEFORE the all-corners-valid filter runs, so a face with
// one corner behind the eye still seeds all four; pass 2 then skipped such
// a vertex (`continue`) and left the seeded `true` standing. Writing
// `if (!seed || !valid) return false` would flip those to hidden. The
// corpus's `straddling` fixture is the one that says so.
//
// WHAT IT DOES NOT KEEP, and why (task 1351 Ф2):
//   * the per-face `sxs` / `sys` screen-corner arrays. A face reaches the
//     front list only when EVERY corner projected, so `sxs[i]` is exactly
//     `vsx[face[i]]` by construction — two GC blocks per face, ~200 000
//     of them on a 100 K mesh, holding a copy of something already in
//     hand. They are gathered into one reused scratch instead.
//   * `front.reserve(faces.length)` on an 80-byte record: 8.0 MB touched
//     unconditionally on every call at n = 316, even when the front list
//     comes out EMPTY. That is most of the "expensive degenerate pass" the
//     earlier measurements could not explain. Three flat arrays replace it.
// -----------------------------------------------------------------------
struct VisibilityProbe {
    // "no faces, or no vertices ⇒ nothing can occlude, everything is
    // visible". This is the sentinel `snap.d` used to spell as
    // `vis.length == 0`, and it is the DEFAULT so that a probe which was
    // never built at all — snap's `!needVis` path — admits everything
    // without needing a second flag to say so.
    bool admitsAll = true;

    private {
        const(Mesh)* mesh_;
        Vec3     localEye_;
        float[]  vsx_, vsy_;
        bool[]   vsValid_;
        bool[]   seed_;
        // The front list, flat: one allocation per column instead of one
        // record per face plus two per face.
        uint[]   frontIdx_;
        float[]  frontBox_;    // 4 per entry: minX, maxX, minY, maxY
        double[] frontN_;      // 3 per entry: the face plane's normal
        // Reused corner gather for `pointInPolygon2D`.
        float[]  scratchX_, scratchY_;
        // Memo: `computed_` says an answer exists, `answer_` is it. Two
        // bitsets rather than a tri-state byte array so a 100 K mesh costs
        // 25 KB, and because `edgeVisible` asks about both endpoints and
        // `faceVisible` about every corner — one index arrives many times.
        ulong[]  computed_, answer_;
        // THE BROAD PHASE (task 1351 Ф3). Buckets the front list's screen
        // boxes over the viewport-plus-pad rectangle, so a candidate walks
        // one cell instead of the whole list. Superset semantics: a cell
        // holds every box that OVERLAPS it, the exact bbox/polygon/depth
        // tests below are unchanged, and a pixel the buckets do not cover
        // falls back to walking everything. So the mask is identical and
        // only the count of pairs tested moves.
        ScreenBuckets buckets_;
        float    domPad_;
        version (unittest) float vpX_, vpY_, vpW_, vpH_;
    }

    /// Is vertex `vi` visible? Memoised; the first call for an index does
    /// the work, later ones read the bit.
    bool visible(size_t vi) {
        if (admitsAll) return true;
        if (vi >= seed_.length) return false;
        immutable size_t w = vi >> 6;
        immutable ulong  b = 1UL << (vi & 63);
        if (computed_[w] & b) return (answer_[w] & b) != 0;
        computed_[w] |= b;
        g_perf.count(Cat.snapVisVertexProbe, 1);
        immutable bool ans = evaluate(vi);
        if (ans) answer_[w] |= b;
        return ans;
    }

    // ---------------------------------------------------------------
    // The depth gate. Ported from the reference, which was measured
    // bit-exactly over 501 candidate evaluations with zero violations
    // (task 0534). Naming the three clauses in its own terms:
    //
    //   O = the eye, C = the candidate, H = where the pick ray meets the
    //   occluder's surface.
    //
    //   1. COINCIDENCE EXEMPTION — keep when |H - C| <= tol(C), where
    //      tol(C) = max(maxabs(C) / 3_360_000, 1e-10). The tolerance is
    //      RELATIVE to the candidate's own largest coordinate (≈ 2.976e-7
    //      of it, ≈ 2.5 float32 ulps) — NOT to the camera distance — and
    //      it SHORT-CIRCUITS the depth compare. It answers "is this
    //      candidate the very point the ray hit", nothing else.
    //   2. DEPTH COMPARE — cull iff |O - C| > |O - H|, strictly. Euclidean
    //      along the ray, with NO epsilon of its own.
    //   3. Equality keeps: at |O - C| == |O - H| the candidate is offered.
    //
    // Clause 3 is the ONE clause with no live confirmation, and that is a
    // property of the measurement rather than a gap to close: the
    // reference's candidate positions arrive on a float32 grid 1.4e6
    // times coarser than the ulp of the double they are compared against,
    // so an exact tie cannot be constructed by placing geometry at all.
    // The DIRECTION is confirmed (501 evaluations, 0 violations); only the
    // last ulp is a static read. Here it is doubly unobservable: our ray
    // is cast THROUGH the candidate, so |O - C| == |O - H| implies H == C
    // and clause 1 always fires first — a mutation of the `>= 0` to `> 0`
    // is provably inert, and measuring it confirmed that (task 1351, M1:
    // `tm1 == 0.0` never occurs over the visibility corpus, and clause 1
    // would swallow it if it did, since `tol >= 1e-10 > 0`). It is written
    // as `>= 0` anyway, so the boundary sits where the reference puts it.
    //
    // What this replaced: a `1e-4` relative epsilon ON THE DEPTH COMPARE
    // ITSELF (`t >= 1 - OCCL_EPS` kept). That was the wrong quantity — the
    // reference puts no tolerance on the compare — and, read even as a
    // relative tolerance, ~300x looser than the coincidence constant.
    //
    // NOT ported here, and deliberately: the occluder SET. This walk still
    // occludes only within one mesh, and skips per-FACE ownership; the
    // reference occludes across every visible non-marked item and exempts
    // per-ITEM. That is a separate and much wider behaviour change (it
    // moves what every snap client sees); see task 0539.
    // ---------------------------------------------------------------
    private bool evaluate(size_t vi) {
        import math : pointInPolygon2D;
        import std.math : abs, sqrt;

        enum double COINCIDENCE_DIVISOR = 3_360_000.0;
        enum double COINCIDENCE_FLOOR   = 1e-10;

        if (!seed_[vi]) {
            version (unittest) ++g_visCounters.seedFalse;
            return false;
        }
        // Seeded but with no screen position: pass 2 had nothing to test
        // it against and left the seed standing. See the asymmetry note on
        // the struct.
        if (!vsValid_[vi]) return true;

        immutable float vsxi = vsx_[vi], vsyi = vsy_[vi];
        const Vec3 vpos = mesh_.vertices[vi];
        const double cx = vpos.x, cy = vpos.y, cz = vpos.z;
        const double dirX = cx - localEye_.x, dirY = cy - localEye_.y,
                     dirZ = cz - localEye_.z;
        const double lenDir = sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ);

        // tol(C) = max(maxabs(C) / 3_360_000, 1e-10) — relative to the
        // CANDIDATE's largest coordinate, so it is a constant of this
        // vertex and is hoisted out of the occluder walk.
        double maxAbsC = abs(cx);
        if (abs(cy) > maxAbsC) maxAbsC = abs(cy);
        if (abs(cz) > maxAbsC) maxAbsC = abs(cz);
        double tol = maxAbsC / COINCIDENCE_DIVISOR;
        if (tol < COINCIDENCE_FLOOR) tol = COINCIDENCE_FLOOR;

        long tested = 0;
        scope (exit) {
            g_perf.count(Cat.snapVisPairsTested, tested);
            version (unittest) g_visCounters.pairsTested += tested;
        }

        // THE TWO ARMS. `bucket` is the cell's box list when the pixel is
        // inside the bucketed domain, and the whole front list when it is
        // not — the same superset argument the candidate grid's
        // `allIndices()` path rests on: a superset re-tested by an
        // unchanged exact predicate returns the same answer, only slower.
        //
        // The linear arm is LIVE in the editor, not a backstop.
        // `edgeVisible` asks about BOTH endpoints of an edge that the
        // cursor's own neighbourhood gathered, and Edge is an EXTENT kind,
        // so a long edge's far endpoint is routinely hundreds of pixels
        // outside the domain. Expect `snapVisPixelOutside` to be non-zero
        // on any case with the Edge type on.
        bool inDomain;
        const(int)[] bucket = queryScreenCell(buckets_, vsxi, vsyi, inDomain);
        if (!inDomain) {
            g_perf.count(Cat.snapVisPixelOutside, 1);
            version (unittest) ++g_visCounters.linearQueries;
        } else {
            version (unittest) {
                ++g_visCounters.gridQueries;
                if (vsxi < vpX_ || vsxi > vpX_ + vpW_ ||
                    vsyi < vpY_ || vsyi > vpY_ + vpH_)
                    ++g_visCounters.gridOutsideVp;
                if (vsxi < 0.0f || vsyi < 0.0f) ++g_visCounters.gridNegPixel;
            }
        }

        foreach (jj; 0 .. (inDomain ? bucket.length : frontIdx_.length)) {
            immutable size_t j = inDomain ? cast(size_t)bucket[jj] : jj;
            ++tested;
            immutable size_t bo = j * 4;
            if (vsxi < frontBox_[bo]     || vsxi > frontBox_[bo + 1] ||
                vsyi < frontBox_[bo + 2] || vsyi > frontBox_[bo + 3]) continue;

            const(uint)[] face = mesh_.faces[frontIdx_[j]];
            bool ownsVi = false;
            foreach (v; face) if (v == vi) { ownsVi = true; break; }
            if (ownsVi) continue;

            // The face is in the front list only when EVERY corner
            // projected, so its screen ring IS `vsx_`/`vsy_` read at its
            // own indices — gathered here instead of stored per face.
            //
            // SLICED TO `face.length`, not passed whole: `pointInPolygon2D`
            // iterates over `xs.length`, so a longer scratch would close
            // the ring through stale corners left by a bigger face and
            // answer a different question.
            foreach (i, vk; face) {
                scratchX_[i] = vsx_[vk];
                scratchY_[i] = vsy_[vk];
            }
            if (!pointInPolygon2D(vsxi, vsyi,
                                  scratchX_[0 .. face.length],
                                  scratchY_[0 .. face.length])) continue;

            immutable size_t no = j * 3;
            const double denom = frontN_[no] * dirX + frontN_[no + 1] * dirY
                               + frontN_[no + 2] * dirZ;
            if (abs(denom) < 1e-9) continue;   // ray parallel to the plane
            const Vec3 p0 = mesh_.vertices[face[0]];
            const double t = (frontN_[no]     * (cast(double)p0.x - localEye_.x)
                            + frontN_[no + 1] * (cast(double)p0.y - localEye_.y)
                            + frontN_[no + 2] * (cast(double)p0.z - localEye_.z))
                            / denom;
            if (t <= 0.0) continue;            // no hit in front of the eye

            // t - 1, formed as dot(n, p0 - C)/denom rather than by
            // subtracting 1 from t: the subtraction cancels catastrophically
            // exactly where the exemption is decided (t within 1e-8 of 1).
            const double tm1 = (frontN_[no]     * (cast(double)p0.x - cx)
                              + frontN_[no + 1] * (cast(double)p0.y - cy)
                              + frontN_[no + 2] * (cast(double)p0.z - cz))
                              / denom;

            // |H - C| = |t - 1| * |C - O|, since H = O + t*(C - O).
            if (abs(tm1) * lenDir <= tol) continue;   // clause 1
            if (tm1 >= 0.0) continue;                 // clauses 2 + 3

            version (unittest) ++g_visCounters.occluded;
            return false;
        }
        return true;
    }
}

/// Build the visibility probe: passes 0 and 1 of the old
/// `visibleVertices`, with pass 2 left to `VisibilityProbe.visible`.
///
/// `queryPadPx` widens the pixel domain the probe expects to be asked
/// about, beyond the viewport itself. Snap passes `2 * outerRangePx`,
/// because an EXTENT candidate (an edge, a face) can be gathered by the
/// cursor's own neighbourhood while the endpoint or corner the gate then
/// asks about sits outside the viewport. It is a HINT and never a limit:
/// a pixel outside the domain is still answered, just without the broad
/// phase's help.
///
/// FORMER `Mesh` member, `const`-qualified; `m` is that `this`, made
/// explicit for the free-function move (task 3230, plan 2910 step 2).
VisibilityProbe visibilityProbe(const ref Mesh m, Vec3 eye, const ref Viewport vp,
                                const ModelSpace ms,
                                float queryPadPx = 80.0f) {
    import math : projectToWindowFull, projectionSpace, ModelSpace,
                  frontFacingLocal;
    import std.math : isFinite;

    // DoS clamp on the one numeric that SCALES this call's allocation.
    // `queryPadPx` reaches here from the `outerRange` Param, which carries
    // no `.min`/`.max` — and a Param's UI bounds would not clamp the
    // headless `injectParamsInto` path anyway. Two things the kernel owes
    // regardless: a named ceiling BEFORE the value scales any work, and a
    // non-finite reject, because `enforceBounds` does not clamp NaN/Inf.
    //
    // The Param deliberately gets NO `.min().max().enforceBounds()` to go
    // with this. `outerRangePx <= 0` is a DOCUMENTED contract, not an
    // out-of-range value: `queryCandidateGrid` reads it as "degenerate
    // range, answer from the linear scan", and the snap election corpus
    // drives exactly that path (`outerRangePx = 0.0f`). A `.min()` floor
    // would make that state unreachable from the UI while leaving the
    // headless path able to produce it — worse than no floor. The kernel
    // caps (this one, and `MAX_GRID_INTS` / `MAX_OCCL_BUCKET_INTS`) are
    // therefore the whole of the bound, which is the documented exception.
    //
    // HONEST NOTE ON WHAT TESTS THIS. Removing these two lines is GREEN, and
    // that is deliberate rather than a gap: `buildScreenBuckets` carries its
    // own `MAX_DOMAIN_PX` refusal, which is the guard that actually stops
    // the out-of-bounds write (measured — take THAT one out and the corpus
    // dies on `ArrayIndexError` in the fill pass). This clamp is the
    // born-clamped default the standing rule asks for on any numeric that
    // scales an allocation; it is defence in depth, not the tested layer.
    // `tests/unit/snap_visibility_corpus_test.d` pins the CONTRACT that no
    // pad value can change the mask, which is what a caller can rely on.
    enum float MAX_QUERY_PAD_PX = 4096.0f;
    if (!isFinite(queryPadPx) || queryPadPx < 0.0f) queryPadPx = 0.0f;
    if (queryPadPx > MAX_QUERY_PAD_PX) queryPadPx = MAX_QUERY_PAD_PX;

    VisibilityProbe p;
    if (m.vertices.length == 0 || m.faces.length == 0) return p;   // admitsAll
    p.admitsAll = false;
    p.mesh_ = &m;

    const Viewport vpLocal = projectionSpace(vp, ms);
    p.localEye_ = ms.isIdentity ? eye : ms.toLocalPoint(eye);

    // Pass 0. Project every vertex once. Behind-camera verts get
    // vsValid=false and skip both candidate selection and occluder polygon
    // membership.
    //
    // The projected DEPTH is deliberately not kept (task 1350). It was
    // stored in a fourth per-call `new float[]` that nothing in the tree
    // ever read: pass 2's occlusion test is a ray/plane solve in local
    // space against the occluder's own plane, so it derives its depth
    // from the candidate and the plane, never from the window Z. `ndcZ`
    // stays as the out-parameter `projectToWindowFull` requires.
    p.vsx_     = new float[](m.vertices.length);
    p.vsy_     = new float[](m.vertices.length);
    p.vsValid_ = new bool [](m.vertices.length);
    p.seed_    = new bool [](m.vertices.length);
    foreach (vi, q; m.vertices) {
        float sx, sy, ndcZ;
        if (projectToWindowFull(q, vpLocal, sx, sy, ndcZ)) {
            p.vsx_[vi] = sx; p.vsy_[vi] = sy;
            p.vsValid_[vi] = true;
        } else {
            version (unittest) ++g_visCounters.invalidProj;
        }
    }
    immutable size_t words = (m.vertices.length + 63) / 64;
    p.computed_ = new ulong[](words);
    p.answer_   = new ulong[](words);

    // Pass 1: collect front-facing faces with cached screen bboxes + plane
    // normals, and seed the visibility mask.
    // The plane normal is carried in DOUBLE (the facing dot moved out to
    // `math.frontFacingLocal`, which carries its own in double too).
    // The depth half of this gate compares against a coincidence tolerance
    // of ~2.98e-7 RELATIVE to the candidate's largest coordinate (see
    // `evaluate`) — about 2.5 float32 ulps. In float arithmetic the
    // ray-plane solve's own rounding is the same size as that tolerance,
    // so the exemption would be decided by noise; positions stay float
    // (the reference's candidate positions arrive on a float32 grid too),
    // only the arithmetic is widened.
    //
    // `fn` is STORED rather than recomputed on demand. Recomputing "the
    // same expression, therefore the same bits" is not a guarantee an
    // optimiser owes anyone — under `ldc -O` in a different inlining
    // context the contraction can differ, and the two-lane gate builds
    // with dmd, so a divergence would ship unseen. 24 bytes a face in one
    // flat array buys the question away.
    static double[3] planeNormal(Vec3 a, Vec3 b, Vec3 c) {
        const double ux = cast(double)b.x - a.x, uy = cast(double)b.y - a.y,
                     uz = cast(double)b.z - a.z;
        const double vx = cast(double)c.x - a.x, vy = cast(double)c.y - a.y,
                     vz = cast(double)c.z - a.z;
        return [uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx];
    }
    size_t maxRing = 0;
    foreach (fi, ref face; m.faces) {
        if (face.length < 3) continue;
        // Hide (task 0613 S4) — a hidden face is not drawn, so it must
        // neither SEED visibility for its corners (the `seed = true`
        // below) nor OCCLUDE anything behind it (pass 2 walks the front
        // list). One `continue` delivers both, and it is the only Hide
        // read this function needs:
        //   * a vertex whose incident faces are ALL hidden is exactly the
        //     derived-hidden rule (§1.2), and none of them seeds it, so it
        //     comes out false without a separate `isVertexHidden` sweep —
        //     a sweep here would be inert, and an inert guard is a guard
        //     nobody can test;
        //   * a hidden EDGE has a hidden endpoint by the same rule, so
        //     `edgeVisible` in snap.d falls out too;
        //   * a loose vertex is in no face, so it is never seeded true.
        // A hidden face's corners that ALSO touch a visible face stay
        // visible, which is right: they are on screen, drawn by that face.
        if (m.isFaceHidden(fi)) {
            version (unittest) ++g_visCounters.hiddenSkip;
            continue;
        }
        // FACING — task 0832. This used to be its own copy of the rule
        // (the plane of the first triangle, culled at `>= 0`); it is now
        // `math.frontFacingLocal`, the one home, and the rule it applies
        // is the reference's, adopted for parity. Read that function's
        // comment before changing anything here — in particular, snap is
        // the ONLY consumer of this mask, and the reference's snap gesture
        // was never measured, so applying the rule here is a named
        // ASSUMPTION rather than a measurement.
        if (!frontFacingLocal(m.vertices, face, p.localEye_)) continue;
        // `fn` is now ONLY the ray-plane's plane for the depth gate in
        // `evaluate` — it no longer decides facing, and the two are
        // separate questions: a face this predicate keeps can still have a
        // degenerate first-triangle plane (that is exactly the split-face
        // shape), which the `abs(denom) < 1e-9` guard already answers by
        // declining to occlude through it.
        double[3] fn = planeNormal(m.vertices[face[0]], m.vertices[face[1]],
                                   m.vertices[face[2]]);
        foreach (vi; face) p.seed_[vi] = true;

        float mnx = float.infinity, mxx = -float.infinity;
        float mny = float.infinity, mxy = -float.infinity;
        bool anyValid = false;
        foreach (vk; face) {
            if (!p.vsValid_[vk]) continue;
            anyValid = true;
            if (p.vsx_[vk] < mnx) mnx = p.vsx_[vk];
            if (p.vsx_[vk] > mxx) mxx = p.vsx_[vk];
            if (p.vsy_[vk] < mny) mny = p.vsy_[vk];
            if (p.vsy_[vk] > mxy) mxy = p.vsy_[vk];
        }
        // A face with any corner behind the camera can't reliably act as
        // an occluder via screen-space tests — skip it. Vertex-on-face
        // candidacy was already seeded above, so nothing is lost.
        if (!anyValid) {
            version (unittest) ++g_visCounters.anyValidSkip;
            continue;
        }
        bool allValid = true;
        foreach (vk; face) if (!p.vsValid_[vk]) { allValid = false; break; }
        if (!allValid) {
            version (unittest) ++g_visCounters.allValidSkip;
            continue;
        }

        p.frontIdx_ ~= cast(uint)fi;
        p.frontBox_ ~= mnx; p.frontBox_ ~= mxx;
        p.frontBox_ ~= mny; p.frontBox_ ~= mxy;
        p.frontN_   ~= fn[0]; p.frontN_ ~= fn[1]; p.frontN_ ~= fn[2];
        if (face.length > maxRing) maxRing = face.length;
    }
    p.scratchX_ = new float[](maxRing);
    p.scratchY_ = new float[](maxRing);

    // THE BROAD PHASE. The domain is the viewport widened by the query
    // pad — bounded BY CONSTRUCTION, which is what lets the kernel drop a
    // face whose clipped box is empty instead of piling every off-screen
    // face into the border cells. Pixels outside it are still answered,
    // by the linear arm.
    p.domPad_ = queryPadPx;
    version (unittest) {
        p.vpX_ = cast(float)vpLocal.x;      p.vpY_ = cast(float)vpLocal.y;
        p.vpW_ = cast(float)vpLocal.width;  p.vpH_ = cast(float)vpLocal.height;
    }
    p.buckets_ = buildScreenBuckets(
        p.frontBox_,
        cast(float)vpLocal.x - queryPadPx,
        cast(float)vpLocal.y - queryPadPx,
        cast(float)(vpLocal.x + vpLocal.width)  + queryPadPx,
        cast(float)(vpLocal.y + vpLocal.height) + queryPadPx,
        OCCL_CELL_PX, MAX_OCCL_BUCKET_INTS);
    if (!p.buckets_.built) g_perf.count(Cat.snapVisGridBail, 1);
    return p;
}

// Task 0617 Stage 4: `ms` is the caller's `ModelSpace` for THIS mesh
// (identity for a plain call). `vertices[]` stays local/unchanged
// throughout — cheaper than transforming every vertex to world, and
// correct because every quantity this function actually COMPARES is
// either a pure forward projection (exact under composition, §3.3) or
// a ray/plane intersection PARAMETER `t` along a single eye->candidate
// ray, which an invertible affine map preserves exactly (the same
// reason `bvh_pick` leaves a ray's `t` alone, §3.4 of the plan) — so
// running pass 2's occlusion depth-gate entirely in LOCAL space (local
// eye, local vertices, local plane normals) reaches the same cull
// decisions as running it in world space would. Pass 1's front-facing
// SIGN test needs no `ms.mirrored` correction either: `localEye` is
// already `M⁻¹·eye`, which alone answers "is the eye on the outward
// side" correctly for any invertible `M` — see `ModelSpace.mirrored`'s
// doc comment in math.d for the identity.
///
/// THE WHOLE-MESH form. Kept at its historical signature so the five test
/// files that pin the LAW through it (`test_mesh_occlusion_gate.d`,
/// `tests/unit/facing_predicate_test.d`, `tests/unit/mesh_test.d`,
/// `test_hide_geometry_pick.d`, `test_pick_item_transform.d`) go on
/// pinning it unchanged. Interactive callers should build a
/// `visibilityProbe` and ask it about the handful of vertices they
/// actually have — this form asks about all of them.
bool[] visibleVertices(const ref Mesh m, Vec3 eye, const ref Viewport vp, const ModelSpace ms) {
    bool[] vis = new bool[](m.vertices.length);
    if (m.vertices.length == 0 || m.faces.length == 0) return vis;
    auto probe = visibilityProbe(m, eye, vp, ms);
    foreach (vi; 0 .. m.vertices.length) vis[vi] = probe.visible(vi);
    return vis;
}

// The by-value gate anchor every module that grows out of `struct Mesh` must
// carry (task 3160 step 1, `doc/tasks/work/2910-mesh-struct-seams.md` §2.1).
// The anchor lives HERE, but the `mixin MeshByValueGate!(...)` that actually
// enforces it does NOT: `tests/unit/mesh_visibility_gate_test.d` carries that,
// targeting this module by name (`mixin MeshByValueGate!(mesh_visibility)`)
// rather than through `__traits(parent, byValueGateAnchor)`.
//
// WHY THE SPLIT, and it is measured, not styled (task 3230). `source/*.d`
// must NEVER import anything under `tests/unit/`, even behind
// `version(unittest)`: `run_test.d`'s HTTP-test lane prebuilds ALL of
// `source/**` (the `modeling` dub config's own file list — `dub describe
// --config=modeling --data=source-files`) into ONE `-unittest` static
// library shared by every per-test binary, and that library build does not
// include `tests/unit/**` at all. A first draft put
// `import tests.unit.mesh_by_value_gate;` right here, under
// `version(unittest)`: `dub test --config=tests` built it clean (that config
// puts `source` and `tests/unit` on ONE sourcePaths list), but
// `./run_test.d` failed at LINK time —
// `undefined reference to tests.unit.mesh_by_value_gate.__ModuleInfo` —
// because the prebuilt library referenced a module it never compiled. This
// module therefore stays import-free beyond the anchor.
version (unittest) private void byValueGateAnchor() {}
