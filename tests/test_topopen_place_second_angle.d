// Topology Pen P2 (doc/topopen_p2_plan.md) — place_second_angle.
//
// A DIFFERENT camera family than test_topopen_place_center.d's: X-dominant
// (near side-on, `az≈pi/2`) rather than Y-dominant — `mostFacingAxisNormal`
// picks world X, so the auto work-plane becomes X=0 through the origin
// instead of Y=0. `focus=(0,0,3R)` has X=0 (the plane's own axis), so the
// centre-pixel seed still equals `focus` (same trick, different axis).
// Proves the placement generalizes across which world axis the work-plane
// picks, not just the "straight-down" case every other place test uses.
//
// Run via: ./run_test.d topopen_place_second_angle

import topopen_place_helpers;
import std.json;
import std.math   : abs, sqrt;
import std.format : format;

void main() {}

enum float R   = 2.0f;
enum int   LON = 96, LAT = 72;   // resolution rationale: topopen_place_helpers.d
enum double TOL = R * 0.04;   // covers the mesh-resolution note in topopen_place_helpers.d

unittest {
    setupSphereBg(R, LON, LAT);

    // X-dominant: az=pi/2 (sin~1, cos~0), el=0.3 (cos=0.955 > sin=0.296) ->
    // camBack ~ (0.955, 0.296, ~0) -- X clearly dominant.
    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        1.5707963, 0.3, 10.0, 0.0, 0.0, 3.0 * R));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2;
    int cy = c.vpY + c.height / 2;

    Vec3 expected;
    bool ok = expectedNearestFootOnSphere(c, cast(float)cx, cast(float)cy, R, expected);
    assert(ok, "centre-pixel seed must be computable");
    // Discriminator: this seed's work-plane is X=0 (not Y=0), so the
    // predicted foot must sit on the sphere's +Z pole-ish region, not the
    // +X region test_topopen_place_center.d predicts.
    assert(expected.z > R * 0.9,
        format("expected foot should be near the +Z pole for an X-dominant "
             ~ "work-plane; got %s", expected));

    assert(vertexCountLayer(1) == 0, "primary layer must start empty");

    cmd("tool.set mesh.topoPen on");

    auto pr = postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 1,
        format("expected exactly 1 vertex placed; got %d", vertexCountLayer(1)));

    auto verts = readVerticesLayer(1);
    assert(approxVec(expected, verts[0], TOL),
        format("placed vertex %s should match the independently-computed "
             ~ "nearest-foot (%f,%f,%f)", verts[0], expected.x, expected.y, expected.z));

    double dist = sqrt(verts[0][0]*verts[0][0] + verts[0][1]*verts[0][1] + verts[0][2]*verts[0][2]);
    assert(abs(dist - R) < TOL,
        format("placed vertex must lie on the sphere surface (R=%f); got |v|=%f", R, dist));
}
