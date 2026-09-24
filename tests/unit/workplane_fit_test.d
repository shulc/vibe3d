// Unit cells for `workplane_fit` on OUR arithmetic (task 7120). The skew-edge
// rule's tie branch (square hull) and its singular arm were never driven on
// the reference: the tie branch is implemented from the decoded text of
// laws.skew_edge_pair (`roll`, "tie branch"), the singular arm refuses.
module tests.unit.workplane_fit_test;

import std.math : abs, sqrt, sin, cos, PI;
import workplane_fit;

private double[2][] square(double angDeg) {
    const a = angDeg * PI / 180, c = cos(a), s = sin(a);
    double[2][] pts;
    foreach (p; [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]])
        pts ~= [c * p[0] - s * p[1], s * p[0] + c * p[1]];
    return pts;
}

unittest { // a non-tie rectangle: the major axis is its long side
    double[2][] r = [[0.0, 0.0], [2.0, 0.0], [2.0, 1.0], [0.0, 1.0]];
    auto h = hullReferenceOrder(r);
    assert(h.length == 4, "rectangle hull must keep its four corners");
    auto d = hullMajorAxis(h);
    assert(abs(abs(d[0]) - 1) < 1e-12 && abs(d[1]) < 1e-12, "2x1 rectangle: major axis must lie along u");
}

unittest { // tie, axis-aligned square: the bbox is square and equal to the side -> (0, 1)
    auto h = hullReferenceOrder(square(0));
    assert(h.length == 4, "square hull must keep its four corners");
    auto d = hullMajorAxis(h);
    assert(d[0] == 0 && d[1] == 1, "axis-aligned square: tie branch must return (0, 1)");
}

unittest { // tie, bbox square and equal to the rectangle side: (0, 1) even where
             // the rectangle direction is (-1, 0), which the swap arm alone
             // would turn into (0, -1). Found by search over small integer hulls.
    double[2][] pts = [[0.0, 3.0], [3.0, 3.0], [2.0, 1.0], [0.0, 0.0]];
    auto h = hullReferenceOrder(pts);
    assert(h.length == 4, "kite hull must keep its four points");
    auto d = hullMajorAxis(h);
    assert(d[0] == 0 && d[1] == 1, "square-bbox tie: the bbox arm must return (0, 1)");
}

unittest { // tie, square turned 30 deg: bbox not square-equal -> swap when |du| > |dv|
    auto h = hullReferenceOrder(square(30));
    assert(h.length == 4, "turned square hull must keep its four corners");
    auto d = hullMajorAxis(h);
    assert(abs(d[0]) <= abs(d[1]) + 1e-12,
        "turned square: the tie branch must leave |du| <= |dv| (swap arm)");
    assert(abs(sqrt(d[0] * d[0] + d[1] * d[1]) - 1) < 1e-12, "direction must stay unit");
}

unittest { // singular fit: every point on z = x, a plane through the world origin
    double[3][] p = [[1, 0, 1], [2, 1, 2], [0, 2, 0], [2, 2, 2]];
    double[3] n;
    assert(!planeFitNormal(p, n), "points on a plane through the origin must be singular");
    double[3][] q = [[1.0, 0, 1.5], [2.0, 1, 2], [0.0, 2, 0], [2.0, 2, 2]];
    assert(planeFitNormal(q, n), "an off-plane point must make the fit regular");
}

// Cells below pin the decoded steps one at a time. Every expectation was
// produced by the decode's own replica of the reference arithmetic (the
// private capture's skew_sim.py: hull_cw / major_axis / amax), not by ours.

unittest { // AxisMaxExtent tie rules
    assert(axisMaxExtent([1.0, 1, 0]) == 1, "x == y > z: y wins");
    assert(axisMaxExtent([1.0, 1, 1]) == 2, "x == y == z: z wins");
    assert(axisMaxExtent([1.0, 0, 1]) == 2, "x == z: z wins");
    assert(axisMaxExtent([1.0, 0, 0.5]) == 0, "x strictly largest");
    assert(axisMaxExtent([0.0, 1, 1]) == 2, "y == z: z wins");
    assert(axisMaxExtent([-2.0, 1, 2]) == 2, "|x| == |z|: z wins");
}

private void hullIs(double[2][] pts, double[2][] want, string what) {
    auto h = hullReferenceOrder(pts);
    assert(h.length == want.length, what ~ ": hull population differs from the decode");
    foreach (i; 0 .. want.length)
        assert(h[i] == want[i], what ~ ": hull list order differs from the decode");
}

unittest { // hull list order: start, ties, collinear drops, reversal
    // p0 tie (two lowest-v points): highest u starts; the list is reversed.
    hullIs([[0.0, 0], [2.0, 0], [2.0, 1], [0.0, 1]],
           [[0.0, 0], [0.0, 1], [2.0, 1], [2.0, 0]], "2x1 rectangle");
    // A point collinear with p0 in the FIRST direction must be dropped by the
    // collinear rule, or the scan pops below two points and stops.
    hullIs([[2.0, 0], [2.0, 0.5], [2.0, 1], [0.0, 1], [0.0, 0]],
           [[0.0, 0], [0.0, 1], [2.0, 1], [2.0, 0]], "collinear with p0");
    // A point on a hull edge away from p0: strict left turns drop it.
    hullIs([[0.0, 0], [2.0, 0], [2.0, 1], [1.0, 1], [0.0, 1]],
           [[0.0, 0], [0.0, 1], [2.0, 1], [2.0, 0]], "point on an edge");
}

unittest { // major axis: first strict diameter, strict area, the longer side
    // Equal diagonals and four equal-area candidates: the FIRST wins.
    auto a = hullMajorAxis(hullReferenceOrder([[0.0, 0], [2.0, 0], [2.0, 1], [0.0, 1]]));
    assert(a[0] == -1 && a[1] == 0, "2x1 rectangle: the decode gives (-1, 0)");
    // The winning rectangle's longer side is perpendicular to its edge.
    auto b = hullMajorAxis(hullReferenceOrder([[0.0, 0], [1.0, 0], [1.0, 3], [0.0, 3]]));
    assert(b[0] == 0 && b[1] == 1, "1x3 rectangle: the decode gives (0, 1)");
    // Two candidates of equal area with different directions: only a
    // STRICTLY smaller area replaces, so the earlier one stands.
    auto c = hullMajorAxis(hullReferenceOrder([[0.0, 2], [3.0, 4], [4.0, 4], [4.0, 1]]));
    const r17 = 1 / sqrt(17.0);
    assert(abs(c[0] + 4 * r17) < 1e-12 && abs(c[1] - r17) < 1e-12,
        "equal-area candidates: the decode keeps (-4, 1)/sqrt(17)");
}

unittest { // exact duplicate endpoints are merged before the fit
    import math : Vec3;
    Vec3[] four = [Vec3(1, -0.5f, -0.2f), Vec3(2, -0.5f, -1.2f), Vec3(2, 0.5f, -0.2f), Vec3(1, 0.5f, -1.2f)];
    Vec3[] five = four ~ Vec3(2, 0.5f, -0.2f);
    Vec3 x4, y4, z4, x5, y5, z5;
    assert(skewEdgePairFrame(four, x4, y4, z4) == SkewFit.ok, "four points must fit");
    assert(skewEdgePairFrame(five, x5, y5, z5) == SkewFit.ok, "five points must fit");
    assert(x4 == x5 && y4 == y5 && z4 == z5, "a duplicated endpoint must not weight the fit");
}
