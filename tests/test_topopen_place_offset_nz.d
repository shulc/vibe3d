// Topology Pen P2 (doc/topopen_p2_plan.md) — place_offset_nz.
//
// Same sphere/camera family as test_topopen_place_center.d, click at a
// different off-centre pixel (screen -X, +Y) than place_offset_px — a
// second distinct in-viewport pixel, still nearest-foot.
//
// Run via: ./run_test.d topopen_place_offset_nz

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

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 1.4, 10.0, 3.0 * R, 0.0, 0.0));

    auto c = fetchCamera();
    int px = c.vpX + c.width  / 2 - 60;
    int py = c.vpY + c.height / 2 + 70;

    Vec3 expected;
    bool ok = expectedNearestFootOnSphere(c, cast(float)px, cast(float)py, R, expected);
    assert(ok, "off-centre seed must be computable");

    assert(vertexCountLayer(1) == 0, "primary layer must start empty");

    cmd("tool.set mesh.topoPen on");

    auto pr = postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, px, py));
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
