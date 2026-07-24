// Topology Pen P4 — move_disambiguation (T4, doc/topopen_p4_plan.md "Test
// enumeration").
//
// The regression class P4 introduces: a plain-LMB press within
// `kTopoPenSnapPx` (12px) of an existing primary-layer vertex must ARM MOVE
// (grab it — vertex count stays put), while a press just OUTSIDE the
// threshold must ARM PLACE (a genuinely new vertex appears). The existing
// multi-place fixtures (test_topopen_place_multi_accumulate.d) happen to
// space clicks 70-150px apart — clear of the 12px threshold — so they do
// NOT exercise this boundary; hence this dedicated test.
//
// Run via: ./run_test.d topopen_move_disambiguation

import topopen_place_helpers;
import std.json;
import std.math   : abs, sqrt;
import std.format : format;

void main() {}

enum float  R   = 2.0f;
enum int    LON = 96, LAT = 72;
enum double TOL = R * 0.04;

unittest {
    setupSphereBg(R, LON, LAT);

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;

    cmd("tool.set mesh.topoPen on");

    // Place A at the center pixel.
    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 1, "setup click must place exactly 1 vertex");

    // --- WITHIN threshold: (cx+5,cy+5) is sqrt(5^2+5^2)~=7.07px from A's own
    // screen position, comfortably inside kTopoPenSnapPx (12px). A
    // stationary click there must ARM MOVE (grab A) — vertex count must
    // stay 1, never grow to 2, even though the click lands off A's EXACT
    // pixel.
    int wx = cx + 5, wy = cy + 5;
    Vec3 expectedWithin;
    assert(expectedRayHitOnSphere(c, cast(float)wx, cast(float)wy, R, expectedWithin),
        "the within-threshold pixel's camera-ray must hit the sphere");

    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, wx, wy));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 1,
        "a press WITHIN kTopoPenSnapPx of the vertex must ARM MOVE, not place a second vertex");

    auto afterWithin = readVerticesLayer(1);
    assert(approxVec(expectedWithin, afterWithin[0], TOL),
        "the grabbed vertex must re-snap to the within-threshold pixel's own independently-computed "
      ~ "camera-ray hit (proves it was MOVED, not merely left in place)");

    // --- OUTSIDE threshold: (cx+70,cy+30) is ~70px+ from A's current screen
    // position (which tracked to roughly (wx,wy) after the move above) —
    // clear of the 12px threshold, matching the existing multi-place
    // fixtures' own spacing. A stationary click there must ARM PLACE.
    int ox = cx + 70, oy = cy + 30;
    Vec3 expectedOutside;
    assert(expectedRayHitOnSphere(c, cast(float)ox, cast(float)oy, R, expectedOutside),
        "the outside-threshold pixel's camera-ray must hit the sphere");

    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, ox, oy));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 2,
        format("a press OUTSIDE kTopoPenSnapPx must ARM PLACE, adding a second vertex; got %d",
              vertexCountLayer(1)));

    auto afterOutside = readVerticesLayer(1);
    assert(approxVec(expectedOutside, afterOutside[1], TOL),
        "the newly PLACED second vertex must match the outside-threshold pixel's camera-ray hit");
    assert(approxVec(expectedWithin, afterOutside[0], TOL),
        "the FIRST vertex (A, already grabbed once) must be untouched by the second, unrelated click");
}
