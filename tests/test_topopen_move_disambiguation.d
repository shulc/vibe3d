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
// Review NIT-1 (P4 review): the original "outside" probe was pinned 70px
// from vertex A's OWN screen position — clear of 12px, but so far clear that
// a future accidental widening of `kTopoPenSnapPx` (e.g. to 50px) would still
// pass this test unnoticed. Fixed by anchoring the outside probe on a
// SEPARATE second vertex (B, placed fresh so its screen position is known
// independently of the earlier grab-and-re-snap of A) and aiming it only
// ~14px away — just outside the 12px threshold, close enough that any
// widening to >=14px would make the probe grab B instead of placing a third
// vertex, which the assertions below would catch.
//
// Run via: ./run_test.d topopen_move_disambiguation

import topopen_place_helpers;
import std.json;
import std.math   : abs, sqrt, round;
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

    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;

    cmd("tool.set mesh.topoPen on");
    // Mode dropdown (task 0483): this test drives PLAIN-LMB presses and
    // expects the place-on-empty/grab-move gesture, which is `point` —
    // the default is now `move`, which places nothing on empty space.
    cmd("tool.attr mesh.topoPen mode point");

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

    // --- Place a SEPARATE second vertex B, well clear of A (same spacing the
    // existing multi-place fixtures use), purely to serve as the anchor for
    // the tight outside-threshold probe below. This click must also ARM
    // PLACE (it is far from A too), so it doubles as a coarse outside-
    // threshold check in its own right.
    int bx = cx + 70, by = cy + 30;
    Vec3 expectedB;
    assert(expectedRayHitOnSphere(c, cast(float)bx, cast(float)by, R, expectedB),
        "B's placement pixel's camera-ray must hit the sphere");

    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, bx, by));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 2,
        format("a press OUTSIDE kTopoPenSnapPx of A must ARM PLACE, adding vertex B; got %d",
              vertexCountLayer(1)));

    auto afterB = readVerticesLayer(1);
    assert(approxVec(expectedB, afterB[1], TOL),
        "the newly PLACED second vertex (B) must match its placement pixel's camera-ray hit");
    assert(approxVec(expectedWithin, afterB[0], TOL),
        "A (already grabbed once) must be untouched by B's placement click");

    // --- Tight outside-threshold probe, anchored on B's OWN projected screen
    // position — THIS is what actually pins `kTopoPenSnapPx`: the probe
    // sits kProbeOffsetPx (14px) from B, just outside the 12px threshold. A
    // future accidental widening of the threshold to >=14px would make this
    // probe grab B instead of placing a third vertex, and the assertions
    // below would catch that (vertex count would stay 2, and B's position
    // would shift to the probe's hit instead of a new vertex appearing).
    // `bScreenX/Y` is derived from `expectedB` (the independently-computed
    // ray-sphere hit), not from the server's own reported vertex position —
    // the probe's expectation stays independent of the tool's own output.
    float bScreenX, bScreenY;
    assert(projectToWindow(expectedB, vp, bScreenX, bScreenY),
        "B's expected world position must project back onto the viewport");

    enum float kProbeOffsetPx = 14.0f;   // > kTopoPenSnapPx(12), comfortably < 15
    int px = cast(int) round(bScreenX + kProbeOffsetPx);
    int py = cast(int) round(bScreenY);

    Vec3 expectedProbe;
    assert(expectedRayHitOnSphere(c, cast(float)px, cast(float)py, R, expectedProbe),
        "the outside-threshold probe pixel's camera-ray must hit the sphere");

    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, px, py));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 3,
        format("a press ~%.0fpx from B (outside kTopoPenSnapPx=12) must ARM PLACE, adding a THIRD "
             ~ "vertex rather than grabbing B; got %d vertices (a widened threshold would grab B "
             ~ "instead and leave this at 2)", kProbeOffsetPx, vertexCountLayer(1)));

    auto afterProbe = readVerticesLayer(1);
    assert(approxVec(expectedProbe, afterProbe[2], TOL),
        "the newly PLACED third vertex must match the probe pixel's own independently-computed "
      ~ "camera-ray hit (proves it was PLACED, not merely a moved B)");
    assert(approxVec(expectedB, afterProbe[1], TOL),
        "B itself must be untouched by the probe click (proves the probe did NOT grab B)");
    assert(approxVec(expectedWithin, afterProbe[0], TOL),
        "A must remain untouched by the probe click");
}
