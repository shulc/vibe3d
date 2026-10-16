module vibe3d.mesh.ops.mesh_ops.triangulate;

import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.util.math.math : Vec3;
import std.math : sqrt;
import vibe3d.mesh.core.mesh_planes : rewriteFaces, FaceSource;
import vibe3d.mesh.edit_log.mesh_edit_delta : MeshEditScope;

    // -----------------------------------------------------------------------
    // Triangulation family: Triple / Quadruple / Detriangulate
    // -----------------------------------------------------------------------

    // Above this ring size `tripleRingCorners` stops clipping and fans — and
    // the strip never runs above it either, because it needs the same corner
    // chooser and so inherits the same bound.
    // Clipping is O(n^3) worst case (n clips x n corners x n containment
    // probes), so one pathological n-gon could otherwise stall an edit; 256
    // corners caps a single face at ~1.7e7 probes. The fallback fans from a
    // GEOMETRICALLY chosen anchor — it is a DoS ceiling, not a law, and no
    // measured cell reaches it (the largest is the 18-entry keyhole ring).
    private enum size_t kMaxEarClipRing = 256;

    // The corner chooser's early-out threshold: the first ear whose quality
    // EXCEEDS this is taken without scoring the rest. Read under a debugger at
    // the site that consumes it (task 1270) — start-up writes the global holding
    // it DIRECTLY, with the bit pattern 0x3fe0000000000000 = 0.5, bypassing the
    // public setter that would clamp the value into [0, 0.01]. A static read of
    // that setter therefore says "at most 0.01", under which the law degenerates
    // to *first valid ear*; only a live read gets the shipped number.
    //
    // WHAT BEHAVIOUR PINS, over the 39 measured cells. The threshold is bounded
    // from BELOW and the bound is EXACTLY this value: at 0.49999 or under, two
    // cells break (`strip_np_one_quality`, `strip_np_twist_quality` — near-square
    // quads whose ears sit at exactly 0.5, which a threshold a hair under 0.5
    // lets the early-out take). Above it, behaviour says nothing at all: 0.5,
    // 0.6 and "no early-out whatsoever" reproduce every measured cell alike.
    // So the capture fixes the floor and the debugger fixes the value sitting
    // on it, and `qualityEarlyOutFires` in tests/unit/mesh_test.d is a
    // CONSTRUCTED ring — not a parity assertion — that pins it from above at
    // 0.79 so a drift in either direction is visible.
    //
    // It DOES fire on measured geometry: four cells reach an ear above 0.5
    // (max 0.587785, on a regular pentagon). On each of them the first ear over
    // the threshold also happens to be the maximum, which is why removing the
    // early-out changes no measured output while the constant still cannot be
    // lowered.
    //
    // The capture note's own explanation of WHY the reference is ring-dependent
    // — "the horseshoe's ears clear 0.5 in several places" — is wrong, and the
    // correction matters because it names the wrong knob: the horseshoe's best
    // ear is 0.4, so this threshold never fires there. The tie-break is what
    // moves that decomposition. See `tripleRingCorners`' header.
    private enum double kTripleQualityEarlyOut = 0.5;

    // The reference compares two qualities through a RELATIVE band: equal when
    // |a-b| < max(|a|,|b|)/3360000. The replacement is guarded by a conditional
    // move on that comparison, so a tie KEEPS THE EARLIER RING INDEX — which is
    // the whole of the ring-order dependence on shapes whose ears tie.
    //
    // Also not separated: every tie in the 21 measured cells is bit-identical
    // in double, and on the orbit fixture any divisor from 1e5 to 1e9 gives the
    // same 19/19. Only an absurdly wide band (1e3) breaks a cell. Read, not
    // fitted.
    private enum double kTripleCompareDivisor = 3360000.0;

    // ---- the STRIP's two constants (task 1320) -----------------------------

    // The strip refuses a ring on which any triangle of its DEGENERACY WALK has
    // an area under this. Read off the gate's own instructions and then read
    // again at run time (task 1282): the comparison goes through the same
    // relative comparator as `kTripleCompareDivisor`, but against a literal
    // zero its relative term is inert — `A < A/3360000` is impossible for
    // `A > 0` — so the whole gate collapses to this ABSOLUTE floor.
    //
    // IT IS ABSOLUTE ON PURPOSE, AND THAT IS NOT THE SCALE BUG IT LOOKS LIKE.
    // Every other degeneracy test in this file is deliberately RELATIVE to its
    // own operands, because an absolute floor on an area misclassifies a small
    // polygon (task 1230 shipped one and the inset kernel refused a 0.002-unit
    // face). This one is absolute because the behaviour being matched is
    // absolute: the reference refuses a valid convex ring purely for being
    // small, and 14 measured cells say so. Making it relative would be a
    // correctness improvement and a parity regression, so it stays, loudly.
    //
    // WHAT BEHAVIOUR PINS, over the 62 measured cells, and it pins this one
    // TIGHTLY — unlike `kTripleQualityEarlyOut`, which the capture could only
    // bound from below. A ladder of exact powers of two (`strip_scale14..19`,
    // mantissas bit-identical, only the exponent moving) plus a 1 % ladder
    // (`strip_fine0..7`) bracket it from BOTH sides:
    //   * at 9e-11 or below, `strip_fine2` and `strip_fine3` break;
    //   * at 1.1e-10 or above, `strip_fine4` breaks;
    //   * `area == 0` — the reading before task 1282 — breaks SIX:
    //     `strip_scale18`, `strip_scale19`, `strip_fine0`..`strip_fine3`.
    // So behaviour alone puts it inside (9.9e-11, 1.01e-10], and the constant
    // read out of the reference sits in that interval.
    //
    // THE SCALE IS PART OF THE ASSERTION. At coordinates of order 1 this floor
    // and `area == 0` are the same test — float32 spacing at 1 is ~6e-8, so a
    // triangle either has area 0 exactly or has area far above 1e-10. The two
    // only part company around 1e-5-sized geometry, which is why every cell
    // that separates them had to be built at that scale, and why a fixture at
    // unit scale cannot tell this constant from a wrong one.
    private enum double kStripDegenerateArea = 1e-10;

    // The strip refuses a ring on which any triangle of its EMISSION WALK
    // scores under this on the same metric the corner chooser uses,
    // `2*Area / (longest side)^2`.
    //
    // WHAT BEHAVIOUR PINS: only a wide band, and this is READ, not fitted. The
    // measured cells bound it from below at 0.002 (`strip_sliver_quad`, a
    // 10 x 0.02 convex quad whose two strip triangles score 0.00199999 — at any
    // floor at or under that, the strip takes a ring the reference declined)
    // and from above at 0.207 (`oct_default` / `oct_strip`, whose worst strip
    // triangle scores 0.207107). Anything in (0.002, 0.207) reproduces all 62
    // cells alike, so 0.01 is inside a band two orders wide and its exact value
    // rests on the read, not on the corpus. Same shape as
    // `kTripleQualityEarlyOut` one block up — say which half is measured.
    private enum double kStripQualityFloor = 0.01;


    /// The zig-zag walk itself — `n - 2` triangles of RING POSITIONS, starting
    /// from position `start` and closing over the ring (task 1320).
    ///
    /// Two cursors: `lo` climbing from `start`, `hi` descending from `start-1`,
    /// alternating, `lo` first. They stop when two corners are left, which is
    /// why the count is exactly `n - 2`.
    ///
    ///     n=8, start=0:  [0,1,7] [6,7,1] [1,2,6] [5,6,2] [2,3,5] [4,5,3]
    ///
    /// THE START IS A PARAMETER BECAUSE THE REFERENCE WALKS THIS TWICE FROM
    /// TWO DIFFERENT PLACES, and that is the whole reason its degeneracy gate
    /// could be isolated at all (task 1282):
    ///
    ///     degeneracy gate   walks from RING POSITION 0
    ///     everything else   walks from the corner the chooser picks
    ///
    /// so whenever the picked corner is not 0 the two walks inspect DIFFERENT
    /// triangles, and a ring can carry a degenerate triangle that only the gate
    /// ever sees. `strip_collinear5` is exactly that ring, and running both
    /// walks from one index silently admits it. Do not collapse the two call
    /// sites into one.
    ///
    /// The reference's degeneracy loop has no modulo in it — `lo` counts up
    /// from 0 and `hi` down from `n-1` and neither wraps. Ours is the same
    /// walk with `start == 0`, which produces the identical sequence because
    /// the two cursors meet before either can wrap; the unittest below asserts
    /// that equivalence directly rather than leaving it as a claim.
    private static uint[3][] stripWalkCorners(size_t n, size_t start) pure nothrow {
        uint[3][] w;
        if (n < 3) return w;
        size_t lo = start % n;
        size_t hi = (start + n - 1) % n;
        size_t left = n;
        bool fromLo = true;
        while (left > 2) {
            if (fromLo) {
                immutable size_t nx = (lo + 1) % n;
                w ~= cast(uint[3])[cast(uint)lo, cast(uint)nx, cast(uint)hi];
                lo = nx;
            } else {
                immutable size_t pv = (hi + n - 1) % n;
                w ~= cast(uint[3])[cast(uint)pv, cast(uint)hi, cast(uint)lo];
                hi = pv;
            }
            fromLo = !fromLo;
            --left;
        }
        return w;
    }


    private static bool posLess(const double[3] a, const double[3] b) pure nothrow @nogc {
        if (a[0] != b[0]) return a[0] < b[0];
        if (a[1] != b[1]) return a[1] < b[1];
        return a[2] < b[2];
    }

    /// Triangulate ONE face ring, returning the triangles as triples of RING
    /// CORNER indices (0 .. ring.length-1) — corner indices and not vertex ids
    /// because the caller has to carry per-corner maps (UVs, weights) through
    /// the split and therefore needs to know which OLD corner each new one
    /// came from. `vids` names the VERTEX each corner refers to; it matters
    /// only for a ring that visits one vertex twice (the keyhole of task 1220),
    /// where containment is decided by vertex identity — see below.
    ///
    /// THE LAW IS THE REFERENCE'S, READ AT ITS COMPUTE SITE (task 1270, ported
    /// 1280). It is one procedure, not a family of fitted rules:
    ///
    ///     rev = orient2(ring[n-1], ring[0], ring[1]) != orientation(ring)
    ///     while n > 3:  k = pick(ring); emit(ring[k-1], ring[k], ring[k+1]); drop k
    ///     emit the last three                    (last two swapped when rev)
    ///
    ///     pick: scan corners IN RING ORDER; skip reflex ones and any whose ear
    ///           contains-or-touches another ring vertex; score the rest by
    ///           quality = 2*Area / (longest side)^2 — 0.866 equilateral, 0.5
    ///           right-isoceles, -> 0 for a sliver; return the FIRST ear over
    ///           `kTripleQualityEarlyOut`, else keep the maximum, ties to the
    ///           EARLIER ring index.
    ///
    /// WHAT IT REPLACED, AND WHY THAT WAS TWO RULES. Task 1190 fitted outputs
    /// and could not reconcile them, so it shipped a quad rule (shorter
    /// non-folding diagonal) beside an n-gon rule (largest-area ear). Both are
    /// shadows of this one metric: a quad's longest side is usually its
    /// diagonal, so "shorter diagonal" ~ "higher quality", and area agrees with
    /// quality on the two cells 1190 had. They part company as soon as one ear
    /// is fat-but-small. Scored over the 19 quality-path cells of the 1270
    /// capture, largest-AREA gets 4 and this metric gets 19; over the eight
    /// horseshoe rotations, largest-AREA gets 0 and this gets 8.
    ///
    /// IT RE-INTRODUCES A RING-ORDER DEPENDENCE ON PURPOSE. 1190 made our
    /// answer invariant because the reference looked invariant on the three
    /// shapes measured then. It is not: on a horseshoe it gives THREE
    /// decompositions over eight rotations (orbit `00112211`). Say it plainly —
    /// this is a decision to follow the reference, the same direction as task
    /// 1230's offset family and the opposite of what 1190 did here.
    ///
    /// WHERE THE DEPENDENCE ACTUALLY COMES FROM, which is not where the capture
    /// note guessed. It is the TIE-BREAK, not the early-out: no ear on the
    /// horseshoe reaches 0.5 (its maximum is 0.4), so the early-out never fires
    /// there at all. Equal-quality ears are common on axis-aligned geometry,
    /// and "the earlier ring index wins" moves with the rotation. The winding
    /// channel has its own term, `rev`, which flips EVERY triangle of a ring
    /// whose first corner is reflex (divergence-ledger row 51).
    ///
    /// TWO ASYMMETRIES THAT LOOK LIKE BUGS AND ARE THE LAW:
    ///   * `orient2` counts a ZERO determinant as 1. So a collinear corner is
    ///     an ear when `wind == 1` and reflex when `wind == 0`, and a vertex
    ///     lying exactly on a chord vetoes the ear in one winding and not the
    ///     other. Both signs are exercised by the measured cells (`rev_hex`,
    ///     `rev_pent`, `rev_horse` are the `wind == 1` side).
    ///   * containment skips candidates by VERTEX IDENTITY, not by ring
    ///     position. That is what makes the keyhole work with no special case:
    ///     when one occurrence of a repeated vertex is a corner of the ear, the
    ///     other occurrence is skipped too, so "vertex inside its own ear"
    ///     never fires and the bridge edge stitches.
    ///
    /// THE PROJECTION FRAME IS RECOMPUTED EVERY ROUND, from the CORNER normal
    /// at ring index 0 (not Newell over the ring): `N = cross(v1-v0, v[n-1]-v0)`,
    /// dominant axis of |N|, and the 2-D work happens in the other two. On a
    /// ring whose corner normal is exactly zero it falls back to the axis of
    /// LEAST bounding-box extent. `Mesh.faceNormal` (Newell) is strictly more
    /// robust and is deliberately not what decides this — same split as task
    /// 0832's facing predicate.
    ///
    /// WHICH OF THE REFERENCE'S FOUR TRIANGULATORS THE CLIP IS, and what runs
    /// ahead of it. The command has a mode argument whose DEFAULT is a
    /// convex-only zig-zag STRIP; the clip is the other mode AND the strip's
    /// own fallback. Task 1280 shipped the clip alone, so on every CONVEX ring
    /// we answered with the fallback rather than the default; task 1320 ported
    /// the strip and closed that gap. `mode` chooses, and it defaults to the
    /// strip because a bare invocation of the reference's command is the strip.
    ///
    /// THE STRIP AND ITS THREE DECLINE GATES (task 1320; measured 1281+1282,
    /// each gate separated by a cell that fails ONLY it):
    ///
    ///     G1 convexity  every corner's edge-pair cross, dotted with the ring's
    ///                   cached corner normal, >= 0.       `strip_hex_concave`
    ///     G2 degeneracy every triangle of the walk from RING POSITION 0 has
    ///                   area >= 1e-10, absolute.          `strip_collinear5`
    ///     G3 quality    every triangle of the walk from the PICKED corner
    ///                   scores >= 0.01 on 2A/longest^2.   `strip_sliver_quad`
    ///
    /// All three pass -> emit the walk from the picked corner, verbatim. Any one
    /// declines -> fall through to the clip below, on the same ring. That is why
    /// every concave fixture in this repo was already in agreement: a concave
    /// ring fails G1, so both engines were always ending up in the clip.
    ///
    /// THE CORNER THE STRIP WALKS FROM IS THE CLIP'S OWN FIRST EAR — the same
    /// `pickCorner` below, called once. Measured, not assumed: the first tuple
    /// under each mode names the same corner on all ten rings that were driven
    /// both ways. On a QUAD that makes the two paths agree as triangle SETS by
    /// construction (a quad has two diagonals and one corner choice picks
    /// between them), so they differ there only in where each tuple STARTS —
    /// which is invisible to every rotation-tolerant face comparison in the
    /// fixture harness and needed an ordered channel to see at all.
    ///
    /// THE STRIP HAS NO `rev` TERM. The reference stores its walk verbatim, and
    /// that is also consistent: `rev` fires when the corner at ring position 0
    /// disagrees with the ring's own orientation, which is precisely what G1
    /// forbids — over the 62 measured cells `rev` is false on all 25 rings the
    /// strip admitted. So the clip's winding term has nothing to do here.
    ///
    /// Always returns exactly ring.length - 2 triangles (the caller asserts it).
    private static uint[3][] tripleRingCorners(const Vec3[] ring,
                                               const(uint)[] vids = null,
                                               Mesh.TriangulateMode mode = Mesh.TriangulateMode.Strip) {
        immutable size_t n = ring.length;
        uint[3][] tris;
        if (n < 3) return tris;
        if (n == 3) { tris ~= cast(uint[3])[0u, 1u, 2u]; return tris; }

        auto P = new double[3][](n);
        foreach (i; 0 .. n)
            P[i] = [cast(double)ring[i].x, cast(double)ring[i].y, cast(double)ring[i].z];

        // The identity a containment probe compares. A ring that names the same
        // vertex twice must treat both occurrences as ONE point; without `vids`
        // every corner is its own identity, which is the ordinary case.
        auto vid = new uint[](n);
        foreach (i; 0 .. n) vid[i] = (vids.length == n) ? vids[i] : cast(uint)i;

        auto idx = new uint[](n);
        foreach (i; 0 .. n) idx[i] = cast(uint)i;

        // The geometric stand-in for a clip that cannot run (the DoS ceiling
        // only): fan from the lexicographically smallest live corner.
        uint[3][] fanFallback(const uint[] live) {
            uint[3][] outT;
            if (live.length < 3) return outT;
            size_t anchor = 0;
            foreach (k; 1 .. live.length)
                if (posLess(P[live[k]], P[live[anchor]])) anchor = k;
            foreach (t; 1 .. live.length - 1)
                outT ~= cast(uint[3])[live[anchor],
                                      live[(anchor + t)     % live.length],
                                      live[(anchor + t + 1) % live.length]];
            return outT;
        }
        if (n > kMaxEarClipRing) return fanFallback(idx);

        // Dominant axis of a vector, and least-spread axis of a box, with the
        // tie directions the reference's own comparison chain has: X wins only
        // strictly, while Y wins ties against X.
        static size_t axisMaxExtent(const double[3] V) pure nothrow @nogc {
            immutable double x = V[0] < 0 ? -V[0] : V[0];
            immutable double y = V[1] < 0 ? -V[1] : V[1];
            immutable double z = V[2] < 0 ? -V[2] : V[2];
            if (x > y  && x > z) return 0;
            if (y >= x && y > z) return 1;
            return 2;
        }
        static size_t axisMinExtent(const double[3] V) pure nothrow @nogc {
            immutable double x = V[0] < 0 ? -V[0] : V[0];
            immutable double y = V[1] < 0 ? -V[1] : V[1];
            immutable double z = V[2] < 0 ? -V[2] : V[2];
            if (x < y  && x < z) return 0;
            if (y <= x && y < z) return 1;
            return 2;
        }

        // The 2-D frame the corner test and the shoelace both run in, taken
        // from the CORNER at ring index 0 of the ring as it stands NOW.
        void frameOf(const uint[] live, out size_t u, out size_t v) {
            const a = P[live[0]], b = P[live[1]], c = P[live[$ - 1]];
            immutable double ux = b[0]-a[0], uy = b[1]-a[1], uz = b[2]-a[2];
            immutable double wx = c[0]-a[0], wy = c[1]-a[1], wz = c[2]-a[2];
            double[3] N = [uy*wz - uz*wy, uz*wx - ux*wz, ux*wy - uy*wx];
            size_t k;
            if (N[0] != 0.0 || N[1] != 0.0 || N[2] != 0.0) {
                k = axisMaxExtent(N);
            } else {
                double[3] lo = P[live[0]], hi = P[live[0]];
                foreach (j; live) foreach (d; 0 .. 3) {
                    if (P[j][d] < lo[d]) lo[d] = P[j][d];
                    if (P[j][d] > hi[d]) hi[d] = P[j][d];
                }
                double[3] ext = [hi[0]-lo[0], hi[1]-lo[1], hi[2]-lo[2]];
                k = axisMinExtent(ext);
            }
            static immutable size_t[3] kAxis0 = [1, 2, 0];
            static immutable size_t[3] kAxis1 = [2, 0, 1];
            u = kAxis0[k];
            v = kAxis1[k];
        }

        static double det2(const double[3] a, const double[3] b, const double[3] c,
                           size_t u, size_t v) pure nothrow @nogc {
            return (b[u]-a[u]) * (c[v]-a[v]) - (c[u]-a[u]) * (b[v]-a[v]);
        }
        // ZERO COUNTS AS 1 — see the header. Not a defensive epsilon; the
        // asymmetry it creates is exercised by the measured cells.
        static int orient2(const double[3] a, const double[3] b, const double[3] c,
                           size_t u, size_t v) pure nothrow @nogc {
            return det2(a, b, c, u, v) >= 0 ? 1 : 0;
        }

        double shoelace(const uint[] live, size_t u, size_t v) {
            double s = 0.0;
            foreach (i; 0 .. live.length) {
                const p = P[live[i]], q = P[live[(i + 1) % live.length]];
                s += p[u]*q[v] - q[u]*p[v];
            }
            return s;
        }

        // 2*Area / (longest side)^2, on the UNSIGNED 3-D area — so the metric
        // is scale-free and independent of the projection frame.
        static double earQuality(const double[3] a, const double[3] b,
                                 const double[3] c) pure nothrow @nogc {
            static double d2(const double[3] p, const double[3] q) pure nothrow @nogc {
                immutable double dx = p[0]-q[0], dy = p[1]-q[1], dz = p[2]-q[2];
                return dx*dx + dy*dy + dz*dz;
            }
            immutable double ab = d2(a, b), bc = d2(b, c), ca = d2(c, a);
            if (ab == 0.0 || bc == 0.0 || ca == 0.0) return -1.0;
            double m = ab;
            if (bc > m) m = bc;
            if (ca > m) m = ca;
            immutable double ux = b[0]-a[0], uy = b[1]-a[1], uz = b[2]-a[2];
            immutable double wx = c[0]-a[0], wy = c[1]-a[1], wz = c[2]-a[2];
            immutable double cx = uy*wz - uz*wy;
            immutable double cy = uz*wx - ux*wz;
            immutable double cz = ux*wy - uy*wx;
            return sqrt(cx*cx + cy*cy + cz*cz) / m;
        }

        // The reference's relative comparison. `0` means "the same number", and
        // the replacement being guarded by it is what sends a tie to the
        // earlier ring index.
        static int dcompare(double a, double b) pure nothrow @nogc {
            immutable double fa = a < 0 ? -a : a;
            immutable double fb = b < 0 ? -b : b;
            immutable double mag = fa > fb ? fa : fb;
            double t = mag / kTripleCompareDivisor;
            if (!(t > 1e-10)) t = 1e-10;
            immutable double d = a - b;
            return (-t < d ? 1 : 0) - (d < t ? 1 : 0);
        }

        size_t pickCorner(const uint[] live) {
            immutable size_t m = live.length;
            size_t u, v;
            frameOf(live, u, v);
            immutable int wind = shoelace(live, u, v) >= 0 ? 1 : 0;
            double best = -1.0;
            size_t besti = 0;
            foreach (i; 0 .. m) {
                immutable uint ip  = live[(i + m - 1) % m];
                immutable uint iv  = live[i];
                immutable uint inx = live[(i + 1) % m];
                const pr = P[ip], cu = P[iv], nx = P[inx];
                if (orient2(pr, cu, nx, u, v) != wind) continue;   // reflex
                bool blocked = false;
                foreach (j; live) {
                    if (vid[j] == vid[ip] || vid[j] == vid[iv] || vid[j] == vid[inx])
                        continue;                                   // BY IDENTITY
                    const p = P[j];
                    if (orient2(cu, pr, p, u, v) == wind) continue;
                    if (orient2(pr, nx, p, u, v) == wind) continue;
                    if (orient2(nx, cu, p, u, v) == wind) continue;
                    blocked = true;
                    break;
                }
                if (blocked) continue;
                immutable double q = earQuality(pr, cu, nx);
                if (q > kTripleQualityEarlyOut) return i;
                if (q > best && dcompare(q, best) != 0) { best = q; besti = i; }
            }
            return besti;   // nothing qualified: clip corner 0, as the reference does
        }

        // ------------------------------------------------------------------
        // THE DEFAULT PATH: the zig-zag strip (task 1320). Runs first, and
        // falls through to the clip below whenever one of its three gates
        // declines. Above `kMaxEarClipRing` we never get here — that ceiling
        // returned the fan already — so the strip inherits the same DoS bound.
        // ------------------------------------------------------------------

        // The unsigned area of one triangle, as the degeneracy gate computes
        // it: from the Gram determinant rather than a cross product, and
        // carrying the factor 1/2 (so it is the area, not twice it — the read
        // was checked against the gate's own register values, 2.75 not 5.5).
        // A radicand at or below zero returns exactly 0.0.
        static double stripTriArea(const double[3] a, const double[3] b,
                                   const double[3] c) pure nothrow @nogc {
            immutable double ux = b[0]-a[0], uy = b[1]-a[1], uz = b[2]-a[2];
            immutable double vx = c[0]-a[0], vy = c[1]-a[1], vz = c[2]-a[2];
            immutable double uu = ux*ux + uy*uy + uz*uz;
            immutable double vv = vx*vx + vy*vy + vz*vz;
            immutable double uv = ux*vx + uy*vy + uz*vz;
            immutable double rad = uu*vv - uv*uv;
            return rad <= 0.0 ? 0.0 : 0.5 * sqrt(rad);
        }

        // Runs the three gates and, if all pass, the walk. `null` means
        // declined — never an empty array, since a ring of 4 or more corners
        // always yields at least two triangles.
        uint[3][] stripDecomposition() {
            // ---- G1: CONVEXITY, against the ring's CACHED CORNER NORMAL.
            // Not a Newell normal: the reference decides this against the same
            // corner-triangle normal the projection frame is taken from,
            // `cross(v1-v0, v[n-1]-v0)` at the ring's FIRST vertex. On a planar
            // ring the two agree and the 62 cells do not separate them (checked
            // offline, both give 62/62); on a NON-PLANAR ring they can differ,
            // and the corner normal is the one that was read. Same split as the
            // facing predicate of task 0832 — `Mesh.faceNormal` is strictly
            // more robust and is deliberately not what decides this.
            const double[3] a0 = P[idx[0]], b0 = P[idx[1]], c0 = P[idx[$ - 1]];
            immutable double nux = b0[0]-a0[0], nuy = b0[1]-a0[1], nuz = b0[2]-a0[2];
            immutable double nwx = c0[0]-a0[0], nwy = c0[1]-a0[1], nwz = c0[2]-a0[2];
            immutable double[3] N = [nuy*nwz - nuz*nwy,
                                     nuz*nwx - nux*nwz,
                                     nux*nwy - nuy*nwx];
            foreach (i; 0 .. n) {
                const p = P[idx[(i + n - 1) % n]];
                const c = P[idx[i]];
                const x = P[idx[(i + 1) % n]];
                immutable double ex = c[0]-p[0], ey = c[1]-p[1], ez = c[2]-p[2];
                immutable double fx = x[0]-c[0], fy = x[1]-c[1], fz = x[2]-c[2];
                immutable double cx = ey*fz - ez*fy;
                immutable double cy = ez*fx - ex*fz;
                immutable double cz = ex*fy - ey*fx;
                // ZERO PASSES. A collinear corner has an exactly zero cross and
                // a zero dot, and the gate declines only on a strictly negative
                // one — which is what makes a convex ring with a collinear
                // corner reach G2 at all, and `strip_collinear5` exists because
                // of it. The reference normalises this cross first; that cannot
                // change the sign, and the corpus does not separate the two.
                if (cx*N[0] + cy*N[1] + cz*N[2] < 0.0) return null;
            }

            // ---- G2: DEGENERACY, on the walk from RING POSITION 0.
            // The origin is the point: this walk starts at 0 with no reference
            // to the picked corner, so when the picked corner is not 0 it looks
            // at DIFFERENT triangles from G3's walk. Running it from `s`
            // instead admits `strip_collinear5`, whose degenerate triple the
            // quality walk never contains (its three scores are 0.862/0.419/
            // 0.533 against a 0.01 floor). See `stripWalkCorners`.
            foreach (t; stripWalkCorners(n, 0))
                if (stripTriArea(P[idx[t[0]]], P[idx[t[1]]], P[idx[t[2]]])
                        < kStripDegenerateArea)
                    return null;

            // ---- G3: QUALITY, on the walk from the PICKED corner.
            immutable size_t s = pickCorner(idx);
            auto walk = stripWalkCorners(n, s);
            foreach (t; walk)
                if (earQuality(P[idx[t[0]]], P[idx[t[1]]], P[idx[t[2]]])
                        < kStripQualityFloor)
                    return null;

            uint[3][] outT;
            foreach (t; walk)
                outT ~= cast(uint[3])[idx[t[0]], idx[t[1]], idx[t[2]]];
            return outT;
        }

        if (mode == Mesh.TriangulateMode.Strip && n >= 4) {
            auto st = stripDecomposition();
            if (st !is null) return st;
        }

        // `rev` is fixed ONCE, from the ring as it arrived.
        size_t u0, v0;
        frameOf(idx, u0, v0);
        immutable int po = shoelace(idx, u0, v0) >= 0 ? 1 : 0;
        immutable bool rev =
            orient2(P[idx[$ - 1]], P[idx[0]], P[idx[1]], u0, v0) != po;

        while (idx.length > 3) {
            immutable size_t m = idx.length;
            immutable size_t k = pickCorner(idx);
            immutable uint a = idx[(k + m - 1) % m];
            immutable uint b = idx[k];
            immutable uint c = idx[(k + 1) % m];
            tris ~= rev ? cast(uint[3])[a, c, b] : cast(uint[3])[a, b, c];
            idx = idx[0 .. k] ~ idx[k + 1 .. $];
        }
        tris ~= rev ? cast(uint[3])[idx[0], idx[2], idx[1]]
                    : cast(uint[3])[idx[0], idx[1], idx[2]];
        return tris;
    }

    /// Split each masked face (n-gon, n > 3) into (n−2) triangles, choosing the
    /// diagonals GEOMETRICALLY — see `tripleRingCorners` for the law and for
    /// what pins it. Already-triangles (length ≤ 3) pass through untouched
    /// regardless of the mask. Returns the number of faces changed.
    ///
    /// `mode` picks between the reference's two triangulators and defaults to
    /// the one its own command defaults to (task 1320). No production caller
    /// passes it; it exists so the ear clip — a separately measured law of ours
    /// — stays directly assertable on a ring the strip would otherwise take.
    ///
    /// `faceOriginOut` (optional): receives a mapping new_fi → original_fi,
    /// useful for re-selecting children of previously-selected parents after
    /// the topology swap. A face's own triangles stay CONTIGUOUS and in source
    /// order, which several callers lean on.
    ///
    /// Task 1190 retired the v1 fan from `f[0]`: it inverted triangles on a
    /// concave ring and made the whole result follow the ring's starting
    /// corner (divergence-ledger rows 25, 43, 50).
    size_t triangulateFacesByMask(ref Mesh m, in bool[] maskIn, uint[]* faceOriginOut = null,
                                  Mesh.TriangulateMode mode = Mesh.TriangulateMode.Strip) {
        const mask = m.maskMinusHiddenFaces(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        if (mask.length != m.faces.length) return 0;

        // PolyVertex remap, mechanism (b): triangulation changes arity — each
        // n-gon splits into (n-2) triangles; each triangle corner comes from a
        // specific OLD face corner.
        // Task 0830: this capture is the obligation handle. `beginCornerRelocate`
        // takes the OFFSETS only — a relocation names each source corner by
        // index and never looks a vertex up in an old winding — and it ARMS the
        // drop: a path out of here that rewrites `faces` without declaring loses
        // the plane rather than keeping values on foreign corners.
        auto rw = m.beginCornerRelocate();
        const bool remapUv = rw.active();
        const(uint)[] oldFaceLoop = rw.oldFaceLoop();
        uint[] oldLoopOfNewLoop;

        uint[][] newFaces;
        uint[]   faceOrigin;   // faceOrigin[new_fi] = original fi — ALREADY the
                                // newToOld correspondence mesh_planes.FaceSource
                                // wants (task 1902); fed straight in below
                                // instead of hand-building newWord/Order/
                                // Material/Part/SetMask, plan §6 Stage B.

        size_t changed = 0;

        foreach (fi; 0 .. m.faces.length) {
            auto f = m.faces[fi];

            if (!mask[fi] || f.length <= 3) {
                // Pass through untouched.
                newFaces   ~= f.dup;
                faceOrigin ~= cast(uint)fi;
                if (remapUv)
                    foreach (c; 0 .. f.length)
                        oldLoopOfNewLoop ~= Mesh.oldFaceLoopIndex(oldFaceLoop,
                                                             cast(uint)fi,
                                                             cast(uint)c);
            } else {
                // Diagonals chosen by geometry (tripleRingCorners), never by
                // ring position. Every triangle inherits the source face's
                // WHOLE marks word (Subpatch + Hide) via `faceOrigin` below
                // (mesh_planes.rewriteFaces's carry), the same "each piece
                // keeps the parent's word" rule as every other 1-to-many split
                // above.
                ++changed;
                auto ringPos = new Vec3[](f.length);
                foreach (c; 0 .. f.length) ringPos[c] = m.vertices[f[c]];
                const tri = tripleRingCorners(ringPos, f, mode);
                assert(tri.length == f.length - 2,
                    "tripleRingCorners must return exactly n-2 triangles");
                foreach (t; tri) {
                    newFaces   ~= [f[t[0]], f[t[1]], f[t[2]]];
                    faceOrigin ~= cast(uint)fi;
                    if (remapUv) {
                        // A triangle corner comes from the OLD corner the clip
                        // named — its ring index, not a fan's 0/i/i+1. Getting
                        // this wrong carries UVs onto foreign corners silently.
                        foreach (k; 0 .. 3)
                            oldLoopOfNewLoop ~= Mesh.oldFaceLoopIndex(oldFaceLoop,
                                                                 cast(uint)fi, t[k]);
                    }
                }
            }
        }

        if (changed == 0) return 0;

        // Task 1903 Stage K — ARMED, per rewrite. A triangulation records its
        // face change NOWHERE ELSE: it adds no face through `addFace` and
        // drops none through `deleteFacesByMask`, it hands one whole new array
        // to the primitive, so with the publisher disarmed the op-log names no
        // face change at all. The scope and not a batch-wide flag because
        // `compactUnreferenced()` five lines down records `RemoveVerts` +
        // `Reindex` through the OTHER hooked path, and this kernel must not
        // describe anything twice (plan §5.3, "K's red row").
        { auto arm = m.faceReindexScope();
          rewriteFaces(m, newFaces, FaceSource(faceOrigin)); }
        m.setFaceMarksFrom(m.faceMarks, ~Mesh.Marks.Select);
        if (remapUv) m.declareCornerProvenance(rw.relocated(oldLoopOfNewLoop));
        m.clearFaceSelectionResize();
        m.rebuildEdges();
        m.clearEdgeSelectionResize();
        m.compactUnreferenced();
        m.buildLoops();
        m.commitChange(MeshEditScope.Geometry);

        if (faceOriginOut !is null) *faceOriginOut = faceOrigin;
        return changed;
    }

// --- was in the body of `struct Mesh`: stripWalkCorners (reads `stripWalkCorners`, `kMaxEarClipRing`)
unittest { // stripWalkCorners: the walk from ring position 0 never wraps, so it
           // IS the reference's modulo-free degeneracy loop — task 1320.
    //
    // The reference runs this walk twice from two different origins. The
    // emission walk closes over the ring and needs the modulo; the degeneracy
    // walk counts `lo` up from 0 and `hi` down from n-1 with no modulo at all.
    // We use one function for both and pass the origin, which is only legitimate
    // if the two forms agree at origin 0. They do, because the cursors meet
    // before either can wrap — asserted here rather than argued, over every
    // ring size the clip will accept.
    import std.conv : to;
    foreach (n; 3 .. kMaxEarClipRing + 1) {
        auto w = stripWalkCorners(n, 0);
        assert(w.length == n - 2, "n=" ~ n.to!string ~ ": expected "
            ~ (n - 2).to!string ~ " triangles, got " ~ w.length.to!string);
        // The modulo-free form, written out independently.
        uint[3][] want;
        {
            size_t lo = 0, hi = n - 1, left = n;
            bool fromLo = true;
            while (left > 2) {
                if (fromLo) { want ~= cast(uint[3])[cast(uint)lo, cast(uint)(lo+1), cast(uint)hi]; ++lo; }
                else        { want ~= cast(uint[3])[cast(uint)(hi-1), cast(uint)hi, cast(uint)lo]; --hi; }
                fromLo = !fromLo;
                --left;
            }
        }
        assert(w == want, "n=" ~ n.to!string ~ ": the mod-n walk from 0 is "
            ~ w.to!string ~ " but the modulo-free loop gives " ~ want.to!string
            ~ " — they must agree at origin 0 or the degeneracy gate is walking"
            ~ " a different set of triangles from the reference's");
        // Every corner is covered and none is named out of range.
        foreach (t; w) foreach (k; 0 .. 3)
            assert(t[k] < n, "n=" ~ n.to!string ~ ": walk names corner "
                ~ t[k].to!string);
    }

    // …and away from 0 it DOES wrap — otherwise the parameter would be inert
    // and the two gates would be walking the same triangles after all.
    {
        auto w0 = stripWalkCorners(5, 0);
        auto w1 = stripWalkCorners(5, 1);
        assert(w0 == [cast(uint[3])[0,1,4], cast(uint[3])[3,4,1], cast(uint[3])[1,2,3]],
            "n=5 from 0: " ~ w0.to!string);
        assert(w1 == [cast(uint[3])[1,2,0], cast(uint[3])[4,0,2], cast(uint[3])[2,3,4]],
            "n=5 from 1: " ~ w1.to!string ~ " — this is the pentagon whose"
            ~ " degenerate triple only the walk from 0 contains");
    }
}

