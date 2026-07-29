// Topology Pen — place_cube_flat.
//
// Bonus flat-surface sanity case with a cube background instead of a
// sphere. `focus=(0,0,0)` puts the cube's centre exactly on the lookAt
// forward axis, so the centre pixel's camera-ray is guaranteed to enter the
// cube (the centre is inside it) — the ray-AABB analogue of the sphere
// place tests' centre-pixel guarantee. The expected hit is computed
// independently via `expectedRayHitOnAabb` (ray-vs-axis-aligned-box), not
// through a work-plane clamp.
//
// Run via: ./run_test.d topopen_place_cube_flat

import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

enum double TOL = 0.02;   // BvhPick samples the pixel CENTRE (mx+0.5), a small
                          // sub-pixel offset from this test's exact NDC-zero
                          // pixel — same magnitude as the surface-raycast
                          // fixture's documented sub-pixel slop.

unittest {
    setupCubeBg();

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2;
    int cy = c.vpY + c.height / 2;

    Vec3 expected;
    bool ok = expectedRayHitOnAabb(c, cast(float)cx, cast(float)cy, 0.5f, expected);
    assert(ok, "centre-pixel camera-ray must hit the cube");

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
}
