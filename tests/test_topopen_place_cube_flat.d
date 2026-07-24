// Topology Pen P2 (doc/topopen_p2_plan.md) — place_cube_flat.
//
// Bonus flat-surface sanity case with a cube background instead of a
// sphere (reuses the SAME camera/focus recipe as
// tests/fixtures/topo_pen_surface_raycast.json's "point_cube_posx_face"
// and test_fixture_topology_pen_tool.d's P2 recompute): a Y-dominant
// camera makes the auto work-plane XZ (normal +Y) through the origin;
// `focus=(2,0,0.15)` has Y=0, so the seed equals `focus`. Nearest point on
// the unit cube (+-0.5 half-extent) to (2,0,0.15): X clamps 2->0.5, Y/Z
// pass through -> (0.5,0,0.15), an EXACT (non-approximate) flat-surface
// foot — no chord-error tolerance needed here, unlike the sphere cases.
//
// Run via: ./run_test.d topopen_place_cube_flat

import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

enum double TOL = 1e-3;   // exact flat-surface foot -- tight tolerance

unittest {
    setupCubeBg();

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 1.4, 5.0, 2.0, 0.0, 0.15));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2;
    int cy = c.vpY + c.height / 2;

    auto vp = viewportFromCamera(c);
    Vec3 dir = screenRay(cast(float)cx, cast(float)cy, vp);
    Vec3 seed;
    bool ok = rayPlaneIntersect(vp.eye, dir, Vec3(0, 0, 0), Vec3(0, 1, 0), seed);
    assert(ok, "centre-pixel seed must be computable");
    Vec3 expected = nearestPointOnAABB(seed, 0.5f);

    assert(vertexCountLayer(1) == 0, "primary layer must start empty");

    cmd("tool.set mesh.topoPen on");

    auto pr = postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 1,
        format("expected exactly 1 vertex placed; got %d", vertexCountLayer(1)));

    auto verts = readVerticesLayer(1);
    assert(approxVec(expected, verts[0], TOL),
        format("placed vertex %s should match the exact flat-surface foot (%f,%f,%f)",
               verts[0], expected.x, expected.y, expected.z));
    assert(approxVec(Vec3(0.5f, 0.0f, 0.15f), verts[0], 0.02),
        format("placed vertex should be (0.5,0,0.15); got %s", verts[0]));
}
