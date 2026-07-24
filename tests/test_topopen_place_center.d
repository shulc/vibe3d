// Topology Pen — place_center_predicted.
//
// Background = a UV sphere at the world origin. Placement seed = camera-ray
// hit (CONFIRMED by a live cross-engine differential against the reference
// editor, superseding P2's
// work-plane-cursor derivation — see source/toolpipe/stages/constrain.d's
// `pointNearestFootBackground`). `focus=(0,0,0)` puts the sphere's centre
// exactly on the lookAt forward axis, so the viewport CENTRE pixel's ray is
// guaranteed to pass through the sphere (the centre is always inside it) —
// the simplest possible camera-ray hit to predict independently.
//
// Asserts: (a) exactly one vertex is added to the PRIMARY (empty) layer;
// (b) it matches the independently-computed camera-ray∩sphere hit;
// (c) it lies ON the sphere surface.
//
// Run via: ./run_test.d topopen_place_center

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
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2;
    int cy = c.vpY + c.height / 2;

    Vec3 expected;
    bool ok = expectedRayHitOnSphere(c, cast(float)cx, cast(float)cy, R, expected);
    assert(ok, "centre-pixel camera-ray must hit the sphere");

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
             ~ "camera-ray hit (%f,%f,%f)", verts[0], expected.x, expected.y, expected.z));

    double dist = sqrt(verts[0][0]*verts[0][0] + verts[0][1]*verts[0][1] + verts[0][2]*verts[0][2]);
    assert(abs(dist - R) < TOL,
        format("placed vertex must lie on the sphere surface (R=%f); got |v|=%f", R, dist));

    assert(vertexCountLayer(0) == sphereVertexCount(LON, LAT),
        "background sphere layer must be untouched by the click");
}
