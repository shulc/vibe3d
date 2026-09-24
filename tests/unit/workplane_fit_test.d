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
