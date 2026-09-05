// Frozen-fixture cell for the ROUNDED vertex-cap corner patch, read
// statically off the reference's own compute sites (task 4330, capture
// campaign batch C'), reading `tests/fixtures/edge_bevel_corner_patch_law.json`.
//
// WHY IT EXISTS. Behaviour-gap register row 20 was scheduled -- twice -- for
// a breakpoint sweep "that names the builder in ONE run". That sweep had
// already been spent; what the row still asked for, in its own words, was a
// STATIC READ of the corner-patch builder's argument setup: "which poles and
// handles it hands the interpolator". This cell freezes that read.
//
// THE ANSWER, and it refutes what was on file. There are no poles and no
// handles. Each side of the cap ring is COLLAPSED to a single cubic before
// the surface interpolator ever sees it, and the interpolator derives its own
// control points from that cubic. The open hypothesis on record -- that a wide
// gap's own POLYLINE stands in as the third boundary curve -- is wrong: the
// polyline supplies two endpoints and two end tangents, nothing more, so a
// side of three or more points is APPROXIMATED and the curve handed across
// does not pass through its interior points.
//
// WHAT ELSE THE READ SETTLED, and this is register row 22. A bevelled
// vertex's cap is not built by one uniform routine. Seventeen ordered gates
// stand between a ring and the patch construction, several of them reading
// the ring's SHAPE, so two rings of the same size can leave by different
// exits. Our shipped model registers every free-end cap ring uniformly. That
// is refuted in kind, not in degree -- and the cell pair
// `wide_notch_reaches_the_patch` / `three_used_slots_of_five_takes_its_own_exit`
// differs in ONE field and lands in two different routes.
//
// WHAT IT DOES NOT PIN. Anything in vibe3d. We ship no corner-patch
// construction; this cell exists so whoever ports one starts from the read
// law rather than from the plausible reading it refutes.
//
// MUTATIONS (each seen red, in isolation -- see the task card's Мутация):
//   * replace `knotTangent` with the textbook symmetric difference
//     `(next - prev) / 2` -> `the tangent law must be the unit-chord
//     bisector` reddens on the asymmetric cell, while the SYMMETRIC cell
//     above it stays green, which is the whole point of keeping it.
//   * make `tolerance` absolute (drop the divisor term) -> `the comparator
//     must be scale-relative` reddens, because the same 1e-6 offset must be
//     refused at unit scale and accepted at scale 1000.
//   * make `route` ignore the three-of-five gate -> `the cap route must
//     depend on the ring SHAPE` reddens with the two routes it collapsed.
//   * hand the raw polyline midpoint to `hermitePower` as a third
//     constraint -> `a side of three or more points is APPROXIMATED`
//     reddens.
//   * drop the clamp from `endKnotLong` -> `but SHORTENING it must move the
//     knot off the mirror` reddens, while the three cells that AGREE with
//     the rival stay green above it.
//   * mark every vertex-bevel setter as flooring its negatives -> `exactly
//     one of the four setters floors a negative` reddens, which is the
//     control that keeps a per-attribute law from being read as a tool-wide
//     one.
module tests.unit.edge_bevel_corner_patch_law_test;

import std.json;
import std.file   : readText;
import std.math   : abs, sqrt, acos, PI, fabs;
import std.format : format;

private enum string kFixture = "tests/fixtures/edge_bevel_corner_patch_law.json";

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

private V3 vec(JSONValue v) {
    assert(v.array.length == 3, "fixture: expected a 3-vector");
    return [num(v.array[0]), num(v.array[1]), num(v.array[2])];
}

private V3 sub(V3 a, V3 b) { return [a[0]-b[0], a[1]-b[1], a[2]-b[2]]; }
private V3 add(V3 a, V3 b) { return [a[0]+b[0], a[1]+b[1], a[2]+b[2]]; }
private V3 scale(V3 a, double k) { return [a[0]*k, a[1]*k, a[2]*k]; }
private double dot(V3 a, V3 b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
private double norm(V3 a) { return sqrt(dot(a, a)); }
private double dist(V3 a, V3 b) { return norm(sub(a, b)); }

private double degreesBetween(V3 a, V3 b) {
    const double na = norm(a), nb = norm(b);
    if (na == 0.0 || nb == 0.0) return 0.0;
    double c = dot(a, b) / (na * nb);
    if (c > 1.0) c = 1.0;
    if (c < -1.0) c = -1.0;
    return acos(c) * 180.0 / PI;
}

// ---------------------------------------------------------------------------
// The read laws, written out. Nothing here consults the fixture: the fixture
// is the frozen OUTPUT these are checked against.
// ---------------------------------------------------------------------------

// The engine's global scalar tolerance and comparator.
private double scalarTolerance(double v, double divisor, double floorTol) {
    const double t = (0.0 > v) ? (v / -divisor) : (v / divisor);
    return t > floorTol ? t : floorTol;
}

private int scalarCompare(double a, double b, double divisor, double floorTol) {
    const double m = (fabs(a) > fabs(b)) ? fabs(a) : fabs(b);
    const double tol = scalarTolerance(m, divisor, floorTol);
    const double d = a - b;
    return ((-tol < d) ? 1 : 0) - ((d < tol) ? 1 : 0);
}

private bool scalarEqual(double a, double b, double divisor, double floorTol) {
    return scalarCompare(a, b, divisor, floorTol) == 0;
}

// The endpoint+tangent cubic, in the power basis.
private V3[4] hermitePower(V3 p0, V3 p1, V3 t0, V3 t1) {
    const V3 d = sub(p1, p0);
    V3[4] c;
    c[0] = p0;
    c[1] = t0;
    foreach (k; 0 .. 3) {
        c[2][k] = 3.0 * d[k] - 2.0 * t0[k] - t1[k];
        c[3][k] = -2.0 * d[k] + t0[k] + t1[k];
    }
    return c;
}

private V3[4] powerToBezier(V3[4] c) {
    V3[4] b;
    foreach (k; 0 .. 3) {
        b[0][k] = c[0][k];
        b[1][k] = c[0][k] + c[1][k] / 3.0;
        b[2][k] = c[0][k] + 2.0 * c[1][k] / 3.0 + c[2][k] / 3.0;
        b[3][k] = c[0][k] + c[1][k] + c[2][k] + c[3][k];
    }
    return b;
}

private V3 evalPower(V3[4] c, double t) {
    V3 p;
    foreach (k; 0 .. 3)
        p[k] = c[0][k] + c[1][k]*t + c[2][k]*t*t + c[3][k]*t*t*t;
    return p;
}

private V3 evalPowerDerivative(V3[4] c, double t) {
    V3 p;
    foreach (k; 0 .. 3)
        p[k] = c[1][k] + 2.0*c[2][k]*t + 3.0*c[3][k]*t*t;
    return p;
}

// The per-knot tangent: each chord weighted by the OPPOSITE chord's length.
private V3 knotTangent(V3 pprev, V3 pcur, V3 pnext,
                       double divisor, double floorTol) {
    const V3 dp = sub(pcur, pprev);
    const V3 dn = sub(pnext, pcur);
    const double lp = norm(dp), ln = norm(dn);
    const double s = lp + ln;
    if (scalarEqual(s, 0.0, divisor, floorTol)) return [0.0, 0.0, 0.0];
    V3 t;
    foreach (k; 0 .. 3) t[k] = (ln * dp[k] + lp * dn[k]) / s;
    return t;
}

// The synthesised knot before a chain's first point. The branch is on the
// chain's POINT COUNT, not on its shape.
private V3 endKnotShort(V3 p0, V3 p1) {
    return sub(scale(p0, 2.0), p1);
}

private V3 endKnotLong(V3 p0, V3 p1, V3 p2, out double kOut) {
    const V3 d = sub(p0, p1);
    const V3 e = sub(p1, p2);
    double k = norm(e) / norm(d) + 2.0;
    if (k < 3.0) k = 3.0;              // the clamp -- see the discriminator
    kOut = k;
    return add(p2, scale(d, k));
}

// The refuted rival, kept as code so the gap is computed rather than quoted.
private V3 symmetricDifferenceTangent(V3 pprev, V3 pcur, V3 pnext) {
    return scale(sub(pnext, pprev), 0.5);
}

// ---------------------------------------------------------------------------
// The routing dispatcher, in the read's own gate order.
// ---------------------------------------------------------------------------

private struct RingShape {
    bool widthPositive;
    bool vertexFlagA, vertexFlagB, vertexFlagC;
    int  usedSlots, totalSlots, roundSegments;
    bool roundVertexCapPredicate;
    int  slotMarkerCountA, slotMarkerCountB, vertexExtraCount;
    bool vertexFlagPairBothSet;
    int  ringPoints, corners, arcSides;
}

private RingShape shapeOf(JSONValue v) {
    RingShape s;
    s.widthPositive           = v["width_positive"].boolean;
    s.vertexFlagA             = v["vertex_flag_a"].boolean;
    s.vertexFlagB             = v["vertex_flag_b"].boolean;
    s.vertexFlagC             = v["vertex_flag_c"].boolean;
    s.usedSlots               = cast(int) num(v["used_slots"]);
    s.totalSlots              = cast(int) num(v["total_slots"]);
    s.roundSegments           = cast(int) num(v["round_segments"]);
    s.roundVertexCapPredicate = v["round_vertex_cap_predicate"].boolean;
    s.slotMarkerCountA        = cast(int) num(v["slot_marker_count_a"]);
    s.slotMarkerCountB        = cast(int) num(v["slot_marker_count_b"]);
    s.vertexExtraCount        = cast(int) num(v["vertex_extra_count"]);
    s.vertexFlagPairBothSet   = v["vertex_flag_pair_both_set"].boolean;
    s.ringPoints              = cast(int) num(v["ring_points"]);
    s.corners                 = cast(int) num(v["corners"]);
    s.arcSides                = cast(int) num(v["arc_sides"]);
    return s;
}

private string route(RingShape s) {
    if (!s.widthPositive)                                   return "decline";
    if (s.vertexFlagA)                                      return "decline";
    if (s.vertexFlagB)                                      return "decline";

    const int extra = s.vertexFlagC ? 1 : 0;
    const int boundaryPoints = s.usedSlots * (s.roundSegments + 1) + extra;
    const int slotTally      = s.usedSlots + extra;

    if (boundaryPoints < 3)                                 return "decline";
    if (slotTally < 3)                                      return "decline";
    if (s.roundVertexCapPredicate)              return "round_vertex_cap";

    const bool fullyAccounted = s.roundSegments > 0
        && (s.slotMarkerCountA + s.vertexExtraCount + s.slotMarkerCountB)
           == s.totalSlots;
    if (fullyAccounted)                                  return "closed_ring";
    if (s.roundSegments <= 0)                             return "flat_level";
    if (s.usedSlots == 3 && s.totalSlots == 5)         return "three_of_five";
    if (s.slotMarkerCountB != 0)                              return "marker";
    if (s.vertexFlagPairBothSet)                           return "twin_flag";
    if (s.usedSlots == 0)                                     return "marker";
    if (s.ringPoints <= 2)                             return "plain_corner";
    if (s.roundSegments <= 0)                              return "no_patch";
    if (s.corners <= 2)                                    return "no_patch";
    if (s.arcSides <= 1)                                   return "no_patch";
    return "corner_patch";
}

// ---------------------------------------------------------------------------
// Cells
// ---------------------------------------------------------------------------

unittest // the cubic: coefficients, Bezier control points, endpoints, tangents
{
    auto fx  = fixture();
    auto blk = fx["hermite_cubic"];
    const double eps = num(fx["tolerance"]);

    assert(blk["cells"].array.length >= 3,
        "the cubic block must keep all three cells -- the generic one, the "
      ~ "straight two-point one and the degenerate one that shows why "
      ~ "'passes through the endpoints' is a weak check");

    foreach (cell; blk["cells"].array) {
        const string nm = cell["name"].str;
        const V3 p0 = vec(cell["start_point"]);
        const V3 p1 = vec(cell["end_point"]);
        const V3 t0 = vec(cell["start_tangent"]);
        const V3 t1 = vec(cell["end_tangent"]);

        const V3[4] c = hermitePower(p0, p1, t0, t1);
        foreach (i; 0 .. 4)
            assert(dist(c[i], vec(cell["power_coefficients"].array[i])) < eps,
                format("%s: power coefficient %s must match the read "
                     ~ "construction c0=P0, c1=T0, c2=3(P1-P0)-2T0-T1, "
                     ~ "c3=2(P0-P1)+T0+T1", nm, i));

        const V3[4] b = powerToBezier(c);
        foreach (i; 0 .. 4)
            assert(dist(b[i], vec(cell["bezier_control_points"].array[i])) < eps,
                format("%s: Bezier control point %s must match the read "
                     ~ "conversion", nm, i));

        // The two consequences the closure precondition leans on.
        assert(dist(b[0], p0) < eps && dist(b[3], p1) < eps,
            format("%s: the first and last control points must BE the "
                 ~ "endpoints -- the three-sided closure test is a test on "
                 ~ "endpoints, and that only follows from this", nm));
        assert(dist(evalPower(c, 0.0), p0) < eps
            && dist(evalPower(c, 1.0), p1) < eps,
            format("%s: the curve must interpolate its own endpoints", nm));
        assert(dist(evalPowerDerivative(c, 0.0), t0) < eps
            && dist(evalPowerDerivative(c, 1.0), t1) < eps,
            format("%s: the curve's end derivatives must BE the supplied "
                 ~ "tangents", nm));

        assert(dist(evalPower(c, 0.5), vec(cell["value_at_half"])) < eps,
            format("%s: the frozen midpoint must match", nm));
    }

    // The zero-tangent cell exists to show the endpoint check is weak: it
    // passes there too, with a completely different curve.
    auto zero = blk["cells"].array[2];
    assert(zero["name"].str == "zero_tangents",
        "the third cell must stay the degenerate one");
    assert(norm(vec(zero["start_tangent"])) == 0.0,
        "the degenerate cell must actually supply zero tangents, or it does "
      ~ "not demonstrate what it claims");
}

unittest // the tangent law: the bisector, and the rival that leans
{
    auto fx  = fixture();
    auto blk = fx["knot_tangent"];
    const double eps     = num(fx["tolerance"]);
    const double divisor = num(fx["scalar_comparator"]["relative_divisor"]);
    const double floorT  = num(fx["scalar_comparator"]["absolute_floor"]);

    // ORDER MATTERS HERE. The inert cell is asserted FIRST, so a single run
    // that reddens the asymmetric cell below still shows this one passed.
    JSONValue inert, asym, colin, degen;
    int seen = 0;
    foreach (cell; blk["cells"].array) {
        switch (cell["name"].str) {
            case "symmetric_corner_THE_INERT_CELL": inert = cell; ++seen; break;
            case "asymmetric_corner_3_to_1":        asym  = cell; ++seen; break;
            case "collinear_unequal_chords":        colin = cell; ++seen; break;
            case "degenerate_coincident":           degen = cell; ++seen; break;
            default: break;
        }
    }
    assert(seen == 4,
        "all four tangent cells must survive: the fixture is only evidence "
      ~ "because it carries the stand that CANNOT discriminate beside the "
      ~ "one that can");

    // (1) The inert cell. Read and rival AGREE here, exactly. This is the
    // stand a regular polygon corner hands you for free.
    {
        const V3 pp = vec(inert["previous_point"]);
        const V3 pc = vec(inert["point"]);
        const V3 pn = vec(inert["next_point"]);
        const V3 t  = knotTangent(pp, pc, pn, divisor, floorT);
        const V3 r  = symmetricDifferenceTangent(pp, pc, pn);
        assert(dist(t, r) < eps,
            format("the SYMMETRIC corner cannot separate the two tangent "
                 ~ "laws -- they must come out identical here, got %s vs %s",
                   t, r));
        assert(dist(t, vec(inert["tangent"])) < eps,
            "the inert cell's frozen tangent must match the read law");
    }

    // (2) Degenerate: the early exit, not a NaN.
    {
        const V3 t = knotTangent(vec(degen["previous_point"]),
                                 vec(degen["point"]),
                                 vec(degen["next_point"]), divisor, floorT);
        assert(t[0] == 0.0 && t[1] == 0.0 && t[2] == 0.0,
            "coincident knots must return the zero tangent through the "
          ~ "comparator's own early exit");
    }

    // (3) The discriminating cell. The read's tangent is the bisector of the
    // two UNIT chord directions; the rival leans toward the longer chord.
    {
        const V3 pp = vec(asym["previous_point"]);
        const V3 pc = vec(asym["point"]);
        const V3 pn = vec(asym["next_point"]);
        const V3 t  = knotTangent(pp, pc, pn, divisor, floorT);
        const V3 r  = symmetricDifferenceTangent(pp, pc, pn);

        assert(dist(t, vec(asym["tangent"])) < eps,
            "the discriminating cell's frozen tangent must match the read law");

        const V3 dp = sub(pc, pp), dn = sub(pn, pc);
        const V3 bis = add(scale(dp, 1.0 / norm(dp)), scale(dn, 1.0 / norm(dn)));
        assert(degreesBetween(t, bis) < 1e-9,
            format("the tangent law must be the unit-chord bisector: the "
                 ~ "read tangent %s is %s degrees off the bisector %s",
                   t, degreesBetween(t, bis), bis));

        const double gap = degreesBetween(t, r);
        assert(gap > 1.0,
            format("the symmetric-difference rival must MISS by a margin no "
                 ~ "rounding explains -- got %s degrees", gap));
        assert(abs(gap - num(asym["degrees_between_read_and_rival"])) < 1e-6,
            "the frozen refutation margin must match the computed one");
    }

    // (4) Collinear: direction agrees, magnitude does not. A stand that
    // compares directions only calls this a match.
    {
        const V3 pp = vec(colin["previous_point"]);
        const V3 pc = vec(colin["point"]);
        const V3 pn = vec(colin["next_point"]);
        const V3 t  = knotTangent(pp, pc, pn, divisor, floorT);
        const V3 r  = symmetricDifferenceTangent(pp, pc, pn);
        assert(degreesBetween(t, r) < 1e-9,
            "the collinear cell must NOT separate the two by direction");
        assert(abs(norm(t) - norm(r)) > 0.5,
            format("...but it must separate them by magnitude: %s vs %s",
                   norm(t), norm(r)));
    }

    foreach (cand; blk["refuted_candidates"].array)
        assert(cand["refuted_by"].str.length > 0,
            "every refuted candidate must name the cell that refutes it");
}

unittest // a two-point side is handed across STRAIGHT, and why
{
    auto fx  = fixture();
    auto law = fx["two_point_side_law"];
    const double eps = num(fx["tolerance"]);

    assert(law["synthesised_knot_is_a_reflection_when_fewer_than_three_points"]
             .boolean,
        "the two-point case only closes because the knot before the first is "
      ~ "SYNTHESISED by reflection; without that the tangent is undefined");
    assert(law["synthesis_is_computed_in_single_precision"].boolean,
        "the synthesis is done in single precision, so a parity band on this "
      ~ "construction is a single-precision band -- that is a property of "
      ~ "the read, not a measurement artefact");
    assert(law["three_or_more_points_uses_a_different_synthesis"].boolean
        && law["what_remains_open"].str.length > 0,
        "the read must keep saying which sub-case it did NOT settle");

    // Execute it: reflect, take the tangent at both ends, fit, and the
    // quadratic and cubic coefficients must vanish identically.
    const double divisor = num(fx["scalar_comparator"]["relative_divisor"]);
    const double floorT  = num(fx["scalar_comparator"]["absolute_floor"]);
    const V3 p0 = [0.25, -0.5, 1.5];
    const V3 p1 = [2.75, 0.5, -0.5];
    const V3 before = sub(scale(p0, 2.0), p1);   // 2*P0 - P1
    const V3 after  = sub(scale(p1, 2.0), p0);   // 2*P1 - P0
    const V3 t0 = knotTangent(before, p0, p1, divisor, floorT);
    const V3 t1 = knotTangent(p0, p1, after, divisor, floorT);
    assert(dist(t0, sub(p1, p0)) < eps && dist(t1, sub(p1, p0)) < eps,
        format("both end tangents of a two-point side must come out as the "
             ~ "chord itself: got %s and %s against %s", t0, t1, sub(p1, p0)));

    const V3[4] c = hermitePower(p0, p1, t0, t1);
    assert(norm(c[2]) < eps && norm(c[3]) < eps,
        format("a two-point side must be handed across as the STRAIGHT "
             ~ "segment -- quadratic %s and cubic %s must vanish", c[2], c[3]));

    // The rival: unit end tangents. It bulges, and by a lot.
    const V3 u = scale(sub(p1, p0), 1.0 / norm(sub(p1, p0)));
    const V3[4] rc = hermitePower(p0, p1, u, u);
    assert(norm(rc[2]) > 1.0 && norm(rc[3]) > 1.0,
        format("the unit-tangent rival must leave both coefficients "
             ~ "non-zero on this chord: %s, %s", rc[2], rc[3]));

    // The frozen straight cell is the same construction.
    foreach (cell; fx["hermite_cubic"]["cells"].array)
        if (cell["name"].str == "two_point_side_straight") {
            assert(norm(vec(cell["power_coefficients"].array[2])) < eps
                && norm(vec(cell["power_coefficients"].array[3])) < eps,
                "the frozen straight cell must carry zero curvature");
            return;
        }
    assert(false, "the straight two-point cell must stay in the fixture");
}

unittest // a side of three or more points is APPROXIMATED, not interpolated
{
    auto fx  = fixture();
    auto blk = fx["boundary_curve_construction"];
    const double divisor = num(fx["scalar_comparator"]["relative_divisor"]);
    const double floorT  = num(fx["scalar_comparator"]["absolute_floor"]);

    assert(blk["there_are_no_separate_poles_or_handles"].boolean,
        "the row asked which POLES and HANDLES are handed to the "
      ~ "interpolator; the read's answer is that there are none, and the "
      ~ "fixture has to keep saying so");
    assert(blk["end_tangent_magnitudes_are_equal"].boolean,
        "arc-length reparameterisation forces both end tangents to the same "
      ~ "magnitude -- the one structural consequence that holds even where "
      ~ "the end-knot synthesis is unread");
    assert(blk["refutes"].str.length > 0,
        "the refuted hypothesis must be named in the fixture, not only in "
      ~ "the toolcard");

    // A deliberately asymmetric three-point side. Give it the read's own
    // magnitude law (both tangents at the polyline length) and the interior
    // tangent law's directions; the fitted cubic must MISS the middle knot.
    const V3 a = [0.0, 0.0, 0.0];
    const V3 m = [1.0, 1.0, 0.0];
    const V3 b = [3.0, 1.2, 0.0];
    const double polyLen = dist(a, m) + dist(m, b);

    const V3 tm = knotTangent(a, m, b, divisor, floorT);
    assert(norm(tm) > 0.0, "the interior knot must have a tangent");

    // End directions taken from the same law with reflected outer knots --
    // the construction the read pins for a SHORT chain, used here only to
    // produce a concrete asymmetric pair.
    const V3 t0raw = knotTangent(sub(scale(a, 2.0), m), a, m, divisor, floorT);
    const V3 t1raw = knotTangent(m, b, sub(scale(b, 2.0), m), divisor, floorT);
    const V3 t0 = scale(t0raw, polyLen / norm(t0raw));
    const V3 t1 = scale(t1raw, polyLen / norm(t1raw));
    assert(abs(norm(t0) - norm(t1)) < 1e-12,
        "the two end tangents must have equal magnitude by construction");

    const V3[4] c = hermitePower(a, b, t0, t1);
    assert(dist(evalPower(c, 0.0), a) < 1e-12
        && dist(evalPower(c, 1.0), b) < 1e-12,
        "the fitted curve must still pin both endpoints");

    // The claim: it does NOT pass through the middle knot. Search the whole
    // parameter range, so "missed" is not an artefact of sampling at 0.5.
    double closest = double.max;
    for (int i = 0; i <= 2000; ++i) {
        const double t = i / 2000.0;
        const double d = dist(evalPower(c, t), m);
        if (d < closest) closest = d;
    }
    assert(closest > 1e-3,
        format("a side of three or more points is APPROXIMATED: the fitted "
             ~ "cubic must miss the interior knot, closest approach was %s "
             ~ "-- if this is zero, the boundary curve interpolates the "
             ~ "polyline and the read is wrong", closest));
}

unittest // the scalar comparator: scale-relative with a floor
{
    auto fx  = fixture();
    auto blk = fx["scalar_comparator"];
    const double divisor = num(blk["relative_divisor"]);
    const double floorT  = num(blk["absolute_floor"]);

    assert(divisor > 1.0 && floorT > 0.0,
        "both terms must be present: a comparator with only one of them is "
      ~ "one of the refuted rivals");

    foreach (cell; blk["cells"].array) {
        const string nm = cell["name"].str;
        const double a = num(cell["a"]), b = num(cell["b"]);
        assert(scalarEqual(a, b, divisor, floorT) == cell["equal"].boolean,
            format("%s: the comparator must agree with the frozen verdict", nm));
        const double m = (fabs(a) > fabs(b)) ? fabs(a) : fabs(b);
        assert(abs(scalarTolerance(m, divisor, floorT)
                   - num(cell["tolerance"])) < 1e-18,
            format("%s: the frozen tolerance must match the read formula", nm));
        assert(cast(int) num(cell["compare"])
               == scalarCompare(a, b, divisor, floorT),
            format("%s: the three-way result must match too", nm));
    }

    // THE DISCRIMINATOR. The same absolute offset, opposite verdicts.
    const double off = 1e-6;
    assert(!scalarEqual(1.0, 1.0 + off, divisor, floorT)
        &&  scalarEqual(1000.0, 1000.0 + off, divisor, floorT),
        "the comparator must be scale-relative: an offset of 1e-6 has to be "
      ~ "REFUSED at unit scale and ACCEPTED at scale 1000. No absolute "
      ~ "tolerance can do both, and no exact comparison can do either");

    // The floor's own regime, which a pure relative rule gets wrong.
    assert(scalarEqual(1e-11, 2e-11, divisor, floorT)
        && !scalarEqual(1e-9, 2e-9, divisor, floorT),
        "below the crossover the floor decides, so two values a factor of "
      ~ "two apart are equal at 1e-11 and unequal at 1e-9");

    const double crossover = num(blk["crossover_magnitude"]);
    assert(abs(crossover - divisor * floorT) < 1e-15,
        "the recorded crossover must be where the two terms meet");
}

unittest // the side-count dispatch and the three-sided closure precondition
{
    auto fx = fixture();

    auto disp = fx["side_count_dispatch"];
    bool sawRefused, sawThree, sawGeneral;
    foreach (r; disp["routes"].array) {
        const int n = cast(int) num(r["sides"]);
        const string want = r["route"].str;
        const string got = (n < 3) ? "refused"
                         : (n == 3) ? "three_sided" : "general_n_sided";
        assert(got == want,
            format("side count %s must route to %s, the read says %s",
                   n, want, got));
        if (want == "refused") sawRefused = true;
        if (want == "three_sided") sawThree = true;
        if (want == "general_n_sided") sawGeneral = true;
    }
    assert(sawRefused && sawThree && sawGeneral,
        "the dispatch table must exercise all three branches -- a table that "
      ~ "only lists valid counts cannot show the refusal below three");

    auto clos = fx["three_sided_closure_precondition"];
    assert(clos["tests"].array.length == 3
        && clos["comparison_is_componentwise"].boolean
        && clos["comparison_uses_the_scalar_comparator"].boolean,
        "all three closure tests must be recorded, componentwise, under the "
      ~ "shared comparator");

    // Execute the precondition on a triangle whose corners are offset by an
    // amount that straddles the tolerance.
    const double divisor = num(fx["scalar_comparator"]["relative_divisor"]);
    const double floorT  = num(fx["scalar_comparator"]["absolute_floor"]);

    bool closes(V3[3] starts, V3[3] ends) {
        foreach (i; 0 .. 3) {
            const V3 s = starts[i];
            const V3 e = ends[(i + 2) % 3];
            foreach (k; 0 .. 3)
                if (!scalarEqual(s[k], e[k], divisor, floorT)) return false;
        }
        return true;
    }

    V3[3] corners = [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]];
    V3[3] starts = corners;
    V3[3] ends   = [corners[1], corners[2], corners[0]];
    assert(closes(starts, ends), "an exactly closed ring must be accepted");

    ends[0] = [1.0 + 1e-7, 0.0, 0.0];
    starts[1] = [1.0, 0.0, 0.0];
    assert(closes(starts, ends),
        "a ring open by 1e-7 at unit scale is still CLOSED under the "
      ~ "comparator -- an exact test would refuse a patch the reference builds");

    ends[0] = [1.0 + 1e-6, 0.0, 0.0];
    assert(!closes(starts, ends),
        "a ring open by 1e-6 at unit scale must be refused, silently, with "
      ~ "no patch built");
}

unittest // the synthesised end knot, and the clamp that separates it from a mirror
{
    auto fx  = fixture();
    auto blk = fx["end_knot_synthesis"];
    const double eps = num(fx["tolerance"]);

    assert(blk["branch_is_on_point_count_not_shape"].boolean
        && blk["clamp_is_continuous_at_the_join"].boolean,
        "both structural facts must stay recorded: the branch is on the "
      ~ "chain LENGTH, and the two arms meet without a jump");

    // ORDER MATTERS. Every cell that AGREES with the refuted candidate is
    // asserted first, so a single run that reddens the clamp cell below has
    // already shown the agreeing cells agreeing.
    int agreeing = 0, clamped = 0;
    foreach (cell; blk["cells"].array) {
        const string nm = cell["name"].str;
        const V3 p0 = vec(cell["p0"]);
        const V3 p1 = vec(cell["p1"]);
        V3 got;
        double k = 0.0;
        if (cast(int) num(cell["chain_length"]) == 2) {
            got = endKnotShort(p0, p1);
        } else {
            got = endKnotLong(p0, p1, vec(cell["p2"]), k);
            assert(abs(k - num(cell["k"])) < eps,
                format("%s: the frozen k must match max(|far|/|near| + 2, 3)", nm));
            if (cell["clamp_engaged"].boolean) ++clamped;
        }
        assert(dist(got, vec(cell["synthesised_knot"])) < eps,
            format("%s: the synthesised knot must match the read law", nm));

        const V3 mirror = endKnotShort(p0, p1);
        assert(dist(mirror, vec(cell["mirror_of_p1_about_p0"])) < eps,
            format("%s: the frozen mirror must be the mirror", nm));
        if (dist(got, mirror) < eps) ++agreeing;
    }

    assert(agreeing >= 3,
        format("at least three of these cells must AGREE with the refuted "
             ~ "'always the mirror' candidate -- a corpus that never agrees "
             ~ "with the rival is not showing you how easy it is to believe "
             ~ "it; got %s", agreeing));
    assert(clamped == 1,
        format("exactly one cell may have the clamp engaged, or the "
             ~ "discriminator is not isolated; got %s", clamped));

    // THE DISCRIMINATOR: shorten the FAR segment and the clamp holds k at 3,
    // pushing the synthesised knot past the mirror. Lengthening it -- the
    // obvious next stand -- does NOT separate them, and the cell above proves
    // that rather than asserting it.
    double kShort, kLong;
    const V3 p0 = [0.0, 0.0, 0.0];
    const V3 p1 = [1.0, 0.0, 0.0];
    const V3 farLonger  = endKnotLong(p0, p1, [4.0, 0.0, 0.0], kLong);
    const V3 farShorter = endKnotLong(p0, p1, [1.5, 0.0, 0.0], kShort);
    const V3 mirror     = endKnotShort(p0, p1);
    assert(dist(farLonger, mirror) < eps,
        format("stretching the far segment must leave the synthesised knot "
             ~ "ON the mirror -- got %s against %s", farLonger, mirror));
    assert(dist(farShorter, mirror) > 0.25,
        format("but SHORTENING it must move the knot off the mirror, or the "
             ~ "clamp does nothing and 'always the mirror' survives -- got "
             ~ "%s against %s", farShorter, mirror));
    assert(kShort == num(blk["clamp_lower_bound"]),
        "and the clamped cell must sit exactly on the recorded bound");

    // The join is continuous: approach |far| == |near| from the free side.
    double kA, kB;
    endKnotLong(p0, p1, [2.0 - 1e-9, 0.0, 0.0], kA);
    endKnotLong(p0, p1, [2.0 + 1e-9, 0.0, 0.0], kB);
    assert(abs(kA - kB) < 1e-6,
        format("the two arms must meet without a jump: %s vs %s", kA, kB));
}

unittest // register row 12: the vertex bevel's attribute table and handle map
{
    auto fx  = fixture();
    auto blk = fx["vertex_bevel_attributes"];

    assert(cast(int) num(blk["register_row"]) == 12
        && blk["symbol_exists"].boolean,
        "this block is register row 12's evidence and must record that a "
      ~ "symbol existed to read");

    auto attrs = blk["attributes"].array;
    assert(attrs.length == cast(size_t) num(blk["attribute_count"]),
        "the declared attribute count and the listed attributes must agree -- "
      ~ "a table shorter than its own count is how a missing attribute hides");
    assert(attrs.length == 4,
        "the tool declares exactly four attributes; a different number means "
      ~ "the read is against a different build");

    // The clamp is PER ATTRIBUTE. A run that only ever looked at the round
    // level would report 'the setter floors negatives' as a tool-wide rule.
    int floored = 0;
    foreach (a; attrs) {
        const int idx = cast(int) num(a["index"]);
        const bool f  = a["setter_floors_negative_at_zero"].boolean;
        if (f) { ++floored; assert(idx == cast(int) num(
                     blk["round_level_attribute_index"]),
            "only the round level attribute floors its negatives"); }
    }
    assert(floored == 1,
        "exactly one of the four setters floors a negative -- if every one "
      ~ "did, the law would be a tool-wide setter policy and the control "
      ~ "attributes would not separate it");
    assert(blk["round_level_setter_floors_negative_at_zero"].boolean,
        "a negative round level is ACCEPTED and stored as zero, not refused "
      ~ "-- the same shape as the negative-scale law already on file");

    // The handle map. This is the half of row 12 the read actually closes.
    assert(cast(int) num(blk["viewport_handle_count"]) == 1
        && blk["round_level_has_no_viewport_handle"].boolean,
        "the reference draws exactly ONE viewport handle for this tool and "
      ~ "round level is not it, so our single-handle map MATCHES the "
      ~ "reference rather than falling short of it");
    assert(blk["what_remains_open"].str.length > 0,
        "and the row's real subject -- the per-vertex geometry under a "
      ~ "multi-adjacent selection -- must stay recorded as untouched");
}

unittest // register row 22: the cap route depends on the ring SHAPE
{
    auto fx  = fixture();
    auto blk = fx["ring_shape_routing"];

    assert(cast(int) num(blk["register_row"]) == 22,
        "this block is register row 22's evidence and must say so");
    assert(blk["refutes"].str.length > 0
        && blk["marker_semantics_not_decoded"].str.length > 0,
        "the block must both name what it refutes and admit what it did not "
      ~ "decode; a routing law that quietly claims to know the flag meanings "
      ~ "would be inventing them");

    // Every recorded gate must be reachable in the dispatcher's own order.
    assert(blk["gates"].array.length == 17,
        "all seventeen gates stay recorded, including the two that can never "
      ~ "fire -- dropping them would make the chain look tighter than it is");

    // ORDER MATTERS. The route table is asserted first; the shape-dependence
    // claim, which is what row 22 turns on, sits below it.
    JSONValue wide, threeOfFive;
    int paired = 0;
    foreach (cell; blk["cells"].array) {
        const string got = route(shapeOf(cell["shape"]));
        assert(got == cell["route"].str,
            format("%s: the read gate order sends this ring to %s, the "
                 ~ "fixture froze %s", cell["name"].str, got,
                   cell["route"].str));
        if (cell["name"].str == "wide_notch_reaches_the_patch") {
            wide = cell; ++paired;
        }
        if (cell["name"].str == "three_used_slots_of_five_takes_its_own_exit") {
            threeOfFive = cell; ++paired;
        }
    }

    assert(paired == 2,
        "the two cells that differ in ONE field must both survive");

    // The refutation, computed rather than quoted: the two shapes differ in
    // exactly one field and land in two different routes.
    auto wa = wide["shape"].object, tb = threeOfFive["shape"].object;
    int differing = 0;
    string differingKey;
    foreach (k, v; wa) {
        assert(k in tb, format("the two shapes must share their fields (%s)", k));
        if (v.toString != tb[k].toString) { ++differing; differingKey = k; }
    }
    assert(differing == 1 && differingKey == "total_slots",
        format("the pair must differ in exactly one field, and it must be "
             ~ "the slot count: %s fields differ (%s)", differing,
               differingKey));
    assert(route(shapeOf(wide["shape"])) != route(shapeOf(threeOfFive["shape"])),
        "the cap route must depend on the ring SHAPE: two rings identical "
      ~ "but for the vertex's slot count leave by different exits, so a "
      ~ "model that routes every free-end cap ring uniformly is not a "
      ~ "simplification of this -- it is a different construction");

    // The whole reason our flat corpus never caught it.
    RingShape flat = shapeOf(wide["shape"]);
    flat.roundSegments = 0;
    flat.ringPoints = 3;
    assert(route(flat) == "flat_level",
        "at round level zero the ring leaves before any shape-sensitive "
      ~ "gate, which is why a flat-level corpus agrees with a uniform model "
      ~ "and could not have exhibited this");

    assert(fx["provenance"]["method"].str == "static-read",
        "every row here was READ, not measured; the provenance must say so");
    assert(fx["boundary_curve_construction"]["symbol_exists"].boolean,
        "the row must record that a symbol existed to read -- the absence of "
      ~ "one is what would have justified a behavioural channel instead");
    assert(fx["what_this_read_did_not_settle"].array.length >= 4,
        "the read's own boundary must stay in the file: four things it did "
      ~ "not settle, named, so the next pass starts from them rather than "
      ~ "from a guess");
}
