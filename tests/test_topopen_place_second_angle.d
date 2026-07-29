// Topology Pen — place_second_angle.
//
// A DIFFERENT camera family than test_topopen_place_center.d's: X-dominant
// (near side-on, `az≈pi/2`) rather than the Y/Z-mixed centre-pixel family —
// `focus=(0,0,0)` still puts the sphere's centre exactly on the lookAt
// forward axis, so the centre pixel's camera-ray is guaranteed to hit,
// independent of azimuth/elevation. Proves the placement generalizes across
// camera angle, not just the one family the other place tests use.
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

    // X-dominant: az=pi/2 (sin~1, cos~0), el=0.3 — a near side-on view,
    // orthogonal in character to the other place tests' camera family.
    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        1.5707963, 0.3, 8.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2;
    int cy = c.vpY + c.height / 2;

    Vec3 expected;
    bool ok = expectedRayHitOnSphere(c, cast(float)cx, cast(float)cy, R, expected);
    assert(ok, "centre-pixel camera-ray must hit the sphere");

    assert(vertexCountLayer(1) == 0, "primary layer must start empty");

    cmd("tool.set mesh.topoPen on");
    // Mode dropdown (task 0483): this test drives PLAIN-LMB presses and
    // expects the place-on-empty/grab-move gesture, which is `point` —
    // the default is now `move`, which places nothing on empty space.
    cmd("tool.attr mesh.topoPen mode point");

    auto pr = postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 1,
        format("expected exactly 1 vertex placed; got %d", vertexCountLayer(1)));

    auto verts = readVerticesLayer(1);
    assert(approxVec(expected, verts[0], TOL),
        format("placed vertex %s should match the independently-computed "
             ~ "camera-ray hit (%f,%f,%f)", verts[0], expected.x, expected.y, expected.z));

    double dist = sqrt(verts[0][0]*verts[0][0] + verts[0][1]*verts[0][1] + verts[0][2]*verts[0][2]);
    assert(abs(dist - R) < TOL,
        format("placed vertex must lie on the sphere surface (R=%f); got |v|=%f", R, dist));
}
