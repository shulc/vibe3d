// Frozen-fixture cell for two SOLVES read statically off the reference's own
// compute sites (task 2890, capture campaign batches B and C), reading
// `tests/fixtures/kernel_solve_reads.json`.
//
// WHY IT EXISTS. Both rows were scheduled for a boot, and neither needed
// one.
//
//   * The ring-alignment anchor (register row 14) was to be found by
//     sweeping chain start-vertex and winding over three or more
//     configurations, looking for what fixes the index-0 angle among three
//     named candidates. The read says there is no such quantity: the anchor
//     is the argmin of a displacement objective, found by a bounded search.
//     That sweep would have been hunting something that does not exist --
//     and, because reordering a chain also reorders the target slots, it
//     would have produced real differences with a different cause.
//   * The odd-valence junction ring correction (row 23) was to be read by an
//     rr/gdb before-and-after struct dump. The routine reads only its own
//     arguments, so it decodes statically, whole.
//
// WHAT IT PINS, and this is the part that could not be pinned by a
// behavioural fit at all: the MECHANISM behind "odd valence only". The
// correction's recurrence walks the ring in steps of two. On an even ring
// that walk splits into two disjoint orbits and never returns to its seed;
// on an odd ring it is a single cycle that does return, carrying an
// accumulated ratio that need not be one. The test below executes that walk
// and asserts the orbit structure, so the claim is checked rather than
// asserted -- and no amount of measuring output geometry would have shown
// it.
//
// WHAT IT DOES NOT PIN. Anything in vibe3d. We ship no radial alignment
// anchor search, and our junction ring feeds the reference's own captured
// control points rather than deriving them. This cell exists so whoever
// ports either one starts from the read law.
//
// MUTATIONS (each seen red, in isolation):
//   * change `step_stride` in the fixture from 2 to 1 -> the even ring stops
//     splitting into two orbits and `stride ... must split an even ring`
//     reddens. This is the mutation that matters: stride 1 is the reading
//     someone would arrive at without opening the routine, and it makes the
//     odd/even split vanish.
//   * replace the L1 pseudo-length with the Euclidean norm in
//     `pseudoLength` -> `the L1 pseudo-length must change the solved radii`
//     reddens, because the two agree and the read's oddest detail would
//     have been a harmless simplification.
//   * drop a refuted candidate from the fixture -> the refutation check
//     reddens.
module tests.unit.kernel_solve_law_test;

import std.json;
import std.file   : readText;
import std.math   : abs, sqrt, sin, cos, PI, fabs;
import std.format : format;

private enum string kFixture = "tests/fixtures/kernel_solve_reads.json";

private double num(JSONValue v) {
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        default: assert(false, "fixture: expected a number, got " ~ v.toString);
    }
}

private JSONValue fixture() { return parseJSON(readText(kFixture)); }

private alias V3 = double[3];
private V3 sub(V3 a, V3 b) { return [a[0]-b[0], a[1]-b[1], a[2]-b[2]]; }
private V3 add(V3 a, V3 b) { return [a[0]+b[0], a[1]+b[1], a[2]+b[2]]; }
private V3 scale(V3 a, double k) { return [a[0]*k, a[1]*k, a[2]*k]; }
private double dot(V3 a, V3 b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
private double norm(V3 a) { return sqrt(dot(a, a)); }

// ---------------------------------------------------------------------------
// Row 23 -- the junction ring radius correction, executed as read.
// ---------------------------------------------------------------------------

// The read scale: an L1 pseudo-length, NOT the Euclidean norm.
private double pseudoLength(V3 d, double coeff) {
    return sqrt(coeff * (fabs(d[0]) + fabs(d[1]) + fabs(d[2])));
}

private struct SolveOut { double[] radii; V3[] points; }

private SolveOut solveRing(V3 hub, in V3[] c, double coeff, int stride,
                           double seed, bool euclidean = false)
{
    const size_t n = c.length;
    auto t = new V3[](n);
    auto s = new double[](n);
    foreach (i; 0 .. n) {
        const V3 d = sub(c[i], hub);
        s[i] = euclidean ? norm(d) : pseudoLength(d, coeff);
        t[i] = (s[i] > 0.0) ? scale(d, 1.0 / s[i]) : d;
    }
    auto b = new double[](n);
    foreach (i; 0 .. n) {
        const double u = dot(t[i], t[(i + 1) % n]);
        b[i] = sqrt(fabs(1.0 - u * u));
    }
    auto a = new double[](n);
    a[0] = seed;
    // The stride-`stride` walk, exactly as read.
    size_t idx = 0;
    foreach (_; 0 .. n) {
        const size_t nxt = (idx + stride) % n;
        a[nxt] = a[idx] * b[idx] / b[(idx + 1) % n];
        idx = nxt;
    }
    double meanS = 0.0, meanA = 0.0;
    foreach (i; 0 .. n) { meanS += s[i]; meanA += a[i]; }
    meanS /= n; meanA /= n;
    const double k = (meanA != 0.0) ? meanS / meanA : 1.0;
    SolveOut o;
    o.radii = new double[](n);
    o.points = new V3[](n);
    foreach (i; 0 .. n) {
        o.radii[i] = a[i] * k;
        o.points[i] = add(hub, scale(t[i], o.radii[i]));
    }
    return o;
}

// A junction ring of N control points around a hub, deliberately irregular
// so the b_i are not all equal.
private V3[] ringStand(size_t n) {
    V3[] c;
    foreach (i; 0 .. n) {
        const double a = 2.0 * PI * i / n;
        const double r = 0.7 + 0.25 * ((i % 3) + 1);     // unequal radii
        c ~= [r * cos(a), r * sin(a), 0.11 * ((i % 2) ? 1.0 : -1.0)];
    }
    return c;
}

unittest // the stride-2 walk is what makes the correction odd-valence-only
{
    auto fx = fixture();
    auto row = fx["junction_ring_radius"];
    const int stride = cast(int) num(row["step_stride"]);

    // Executed, not asserted: walk the ring in steps of `stride` from 0 and
    // count how many of the N indices are reachable.
    size_t reach(size_t n, int st) {
        bool[] seen = new bool[](n);
        size_t idx = 0, hit = 0;
        while (!seen[idx]) { seen[idx] = true; ++hit; idx = (idx + st) % n; }
        return hit;
    }

    foreach (n; [5, 7, 9]) {
        assert(reach(n, stride) == n,
            format("stride %d must reach every index of an ODD ring of %d -- "
                 ~ "that single cycle returning to its own seed IS the "
                 ~ "accumulated inconsistency the correction shows; reached "
                 ~ "%d", stride, n, reach(n, stride)));
    }
    foreach (n; [4, 6, 8]) {
        assert(reach(n, stride) == n / 2,
            format("stride %d must split an even ring of %d into two disjoint "
                 ~ "orbits of %d -- that is why an even ring carries no "
                 ~ "correction; reached %d", stride, n, n / 2, reach(n, stride)));
    }
}

unittest // direction is preserved; the mean radius is preserved; L1 matters
{
    auto fx = fixture();
    auto row = fx["junction_ring_radius"];
    const double coeff  = num(row["pseudo_length_coefficient"]);
    const int    stride = cast(int) num(row["step_stride"]);
    const double seed   = num(row["seed"]);
    const V3 hub = [0.0, 0.0, 0.0];

    foreach (n; [5, 7]) {
        auto c = ringStand(n);
        auto got = solveRing(hub, c, coeff, stride, seed);

        // (a) every point stays on its own ray from the hub
        foreach (i; 0 .. n) {
            const V3 before = sub(c[i], hub);
            const V3 after  = sub(got.points[i], hub);
            const double cosang = dot(before, after) / (norm(before) * norm(after));
            assert(abs(cosang - 1.0) < 1e-12,
                format("valence %d side %d: the correction must move the "
                     ~ "control point ALONG ITS OWN RAY; cos(angle) = %s",
                       n, i, cosang));
        }

        // (b) the mean of the new radii equals the mean of the old scales
        double meanNew = 0.0, meanOld = 0.0;
        foreach (i; 0 .. n) {
            meanNew += got.radii[i];
            meanOld += pseudoLength(sub(c[i], hub), coeff);
        }
        assert(abs(meanNew / n - meanOld / n) < 1e-9,
            format("valence %d: the rescale must force the mean of the new "
                 ~ "radii onto the mean of the old (%s vs %s)",
                   n, meanNew / n, meanOld / n));

        // (c) the L1 pseudo-length is not a harmless simplification: swapping
        // it for the Euclidean norm changes the answer.
        auto euclid = solveRing(hub, c, coeff, stride, seed, /*euclidean=*/true);
        bool differs = false;
        foreach (i; 0 .. n)
            if (abs(got.radii[i] - euclid.radii[i]) > 1e-9) differs = true;
        assert(differs,
            format("valence %d: the L1 pseudo-length must change the solved "
                 ~ "radii against a Euclidean normalise -- if these agree, "
                 ~ "the read's oddest detail is inert and the fixture is "
                 ~ "over-claiming", n));
    }
}

// ---------------------------------------------------------------------------
// Row 14 -- the alignment anchor is the argmin of a displacement objective.
// ---------------------------------------------------------------------------

private double objective(in V3[] current, in V3[] target, V3 centre,
                         double theta)
{
    // rotation about +Z through `centre`, which is the ring axis on this stand
    const double cs = cos(theta), sn = sin(theta);
    double acc = 0.0;
    foreach (i; 0 .. current.length) {
        const double x = target[i][0] - centre[0];
        const double y = target[i][1] - centre[1];
        const V3 rot = [centre[0] + cs * x - sn * y,
                        centre[1] + sn * x + cs * y,
                        target[i][2]];
        acc += dot(sub(current[i], rot), sub(current[i], rot));
    }
    return sqrt(acc);
}

unittest // the objective's minimum is the anchor, and the refuted candidates miss it
{
    auto fx  = fixture();
    auto row = fx["radial_align_anchor"];

    foreach (k; ["anchor_is_the_first_selected_vertex_angle",
                 "anchor_is_a_fixed_basis_vector_convention",
                 "anchor_is_click_order"])
        assert(k in row["refuted"].object,
            format("the fixture must keep the refutation of %s -- these three "
                 ~ "are what the scheduled sweep was going to look for", k));

    // A five-vertex chain that is deliberately NOT already evenly spaced:
    // the register's own trap is a chain already laid out on the circle,
    // where every candidate anchor gives the same slot set.
    enum size_t N = 5;
    V3 centre = [0.0, 0.0, 0.0];
    V3[] current, target;
    const double[] wonky = [0.05, 0.9, 1.7, 3.4, 4.9];   // radians, uneven
    foreach (i; 0 .. N) {
        current ~= [cos(wonky[i]), sin(wonky[i]), 0.0];
        const double a = 2.0 * PI * i / N;               // the equal slots
        target  ~= [cos(a), sin(a), 0.0];
    }

    // Brute-force the true minimum over a fine grid, then confirm the read
    // SEARCH lands on it from the read schedule.
    double best = double.max, bestTheta = 0.0;
    for (int i = 0; i < 360000; ++i) {
        const double th = 2.0 * PI * i / 360000.0;
        const double f = objective(current, target, centre, th);
        if (f < best) { best = f; bestTheta = th; }
    }

    // The read schedule: start at 0, probe by one degree (or half of a full
    // turn over N when that is smaller), halve and flip on reversal, cap at
    // the read iteration count.
    auto search = row["search"];
    const double full  = num(search["full_turn"]);
    const double probe0 = num(search["initial_probe_radians"]);
    const double factor = num(search["step_factor_on_reversal"]);
    const int    cap    = cast(int) num(search["max_iterations"]);
    double step = (probe0 <= full / N) ? probe0 : (full / N) * factor;
    double th = 0.0, f = objective(current, target, centre, th);
    if (objective(current, target, centre, th + step) > f) step = -step;
    foreach (_; 0 .. cap) {
        const double th2 = th + step;
        const double f2 = objective(current, target, centre, th2);
        if (f2 < f) { th = th2; f = f2; }
        else step *= -factor;
        if (fabs(step) < 1e-12) break;
    }
    assert(abs(f - best) < 1e-6,
        format("the read search schedule must reach the objective's minimum: "
             ~ "found %s at theta=%s, brute force says %s at theta=%s",
               f, th, best, bestTheta));

    // The refuted candidates: each names a specific angle, and each gives a
    // STRICTLY WORSE objective than the minimum -- which is what "refuted"
    // has to mean for a law that is defined as an argmin.
    const double firstVertexAngle = wonky[0];
    const double fixedBasis       = 0.0;
    foreach (cand; [firstVertexAngle, fixedBasis]) {
        const double fc = objective(current, target, centre, cand);
        assert(fc > best + 1e-9,
            format("candidate anchor %s scores %s against the minimum %s -- "
                 ~ "on this stand it is indistinguishable from the read law, "
                 ~ "so the stand does not separate them", cand, fc, best));
    }

    assert(fx["provenance"]["method"].str == "static-read",
        "both blocks were READ, not measured; the provenance must say so");
    assert(row["symbol_exists"].boolean
        && fx["junction_ring_radius"]["symbol_exists"].boolean,
        "each row must record whether a symbol existed to read -- the "
        ~ "absence of one is what would justify a behavioural channel");
}
