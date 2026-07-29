// Topology Pen P3 — build_cube_flat.
//
// Bonus flat-surface sanity case (cube background instead of a sphere,
// mirroring test_topopen_place_cube_flat.d): a Shift+LMB drag (the
// documented gesture-map overlay slot for this tool's build action,
// gesture_map.md table A #4) FROM a hub vertex TO a second on-cube point
// builds a bare edge — proving CASE-EDGE isn't accidentally coupled to the
// sphere fixtures' curvature. Expected hits are computed independently via
// `expectedRayHitOnAabb` (ray-vs-axis-aligned-box), not through a work-plane
// clamp or by reading vibe3d's own output back.
//
// Run via: ./run_test.d topopen_build_cube_flat

import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

enum double TOL    = 0.02;   // matches test_topopen_place_cube_flat.d's sub-pixel slop
enum uint   LSHIFT = 0x0001; // KMOD_LSHIFT — the build overlay's modifier

unittest {
    setupCubeBg();

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;
    int bx = cx + 30, by = cy + 15;

    Vec3 expectedA, expectedB;
    assert(expectedRayHitOnAabb(c, cast(float)cx, cast(float)cy, 0.5f, expectedA),
        "hub A's camera-ray must hit the cube");
    assert(expectedRayHitOnAabb(c, cast(float)bx, cast(float)by, 0.5f, expectedB),
        "drag-destination B's camera-ray must hit the cube");

    cmd("tool.set mesh.topoPen on");
    // Mode dropdown (task 0483): this test drives PLAIN-LMB presses and
    // expects the place-on-empty/grab-move gesture, which is `point` —
    // the default is now `move`, which places nothing on empty space.
    cmd("tool.attr mesh.topoPen mode point");

    // Hub A via a plain P2 click.
    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 1);

    // Shift+LMB drag FROM A TO a fresh on-cube point B — CASE-EDGE.
    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, bx, by, 16, LSHIFT));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 2,
        format("expected 2 vertices after the drag; got %d", vertexCountLayer(1)));
    assert(edgeCountLayer(1) == 1,
        format("expected exactly 1 edge; got %d", edgeCountLayer(1)));
    assert(faceCountLayer(1) == 0, "CASE-EDGE must build no face");
    assert(hasEdgeLayer(1, 0, 1), "the new edge must connect A(0) and B(1)");

    auto verts = readVerticesLayer(1);
    assert(approxVec(expectedA, verts[0], TOL), "vertex 0 must be hub A's hit");
    assert(approxVec(expectedB, verts[1], TOL), "vertex 1 must be B's independently-computed hit");
}
