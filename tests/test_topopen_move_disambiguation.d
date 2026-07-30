// Topology Pen P4 — move_disambiguation (T4, doc/topopen_p4_plan.md "Test
// enumeration").
//
// The regression class P4 introduces: a plain-LMB press within the pen's snap
// gate (`topoPenSnapPx`, 15 nominal px x the view pixel scale — task 0496) of an
// existing primary-layer vertex must ARM MOVE
// (grab it — vertex count stays put), while a press just OUTSIDE the
// threshold must ARM PLACE (a genuinely new vertex appears). The existing
// multi-place fixtures (test_topopen_place_multi_accumulate.d) happen to
// space clicks 70-150px apart — clear of the threshold — so they do
// NOT exercise this boundary; hence this dedicated test.
//
// Review NIT-1 (P4 review): the original "outside" probe was pinned 70px
// from vertex A's OWN screen position — clear of the gate, but so far clear that
// a future accidental widening of the gate (e.g. to 50px) would still
// pass this test unnoticed. Fixed by anchoring the outside probe on a
// SEPARATE second vertex (B, placed fresh so its screen position is known
// independently of the earlier grab-and-re-snap of A) and probing it from BOTH
// sides of the gate — 14px (inside: must grab) and 19px (outside: must place).
// The 14px probe is the one that moved when the gate did: it PLACED under the
// old invented 12px threshold and GRABS under the measured 15px one.
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
    // screen position, comfortably inside the snap gate. A
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
        "a press WITHIN the snap gate of the vertex must ARM MOVE, not place a second vertex");

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
        format("a press OUTSIDE the snap gate of A must ARM PLACE, adding vertex B; got %d",
              vertexCountLayer(1)));

    auto afterB = readVerticesLayer(1);
    assert(approxVec(expectedB, afterB[1], TOL),
        "the newly PLACED second vertex (B) must match its placement pixel's camera-ray hit");
    assert(approxVec(expectedWithin, afterB[0], TOL),
        "A (already grabbed once) must be untouched by B's placement click");

    // --- Tight outside-threshold probe, anchored on B's OWN projected screen
    // position — THIS is what actually pins the gate: two probes, one on each
    // side of it, so neither a narrowing nor a widening can pass unnoticed.
    // `bScreenX/Y` is derived from `expectedB` (the independently-computed
    // ray-sphere hit), not from the server's own reported vertex position —
    // the probe's expectation stays independent of the tool's own output.
    float bScreenX, bScreenY;
    assert(projectToWindow(expectedB, vp, bScreenX, bScreenY),
        "B's expected world position must project back onto the viewport");

    // Task 0496 (the measured snap gate): the threshold is 15 nominal px x the
    // view's pixel scale, not the old invented 12. THIS pair of probes is what
    // pins that number from the outside, and each one fails on the other side
    // of the change:
    //   * kInsideProbePx  = 14px — INSIDE the measured 15px gate, so it must
    //     GRAB B. Under the old 12px threshold this same probe PLACED a third
    //     vertex (it was this test's "just outside" probe), so this assertion
    //     is red on the pre-0496 code.
    //   * kOutsideProbePx = 19px — outside the gate, so it must PLACE. Tight
    //     enough that any further widening past ~19px would be caught here.
    enum float kInsideProbePx  = 14.0f;
    enum float kOutsideProbePx = 19.0f;

    int ix = cast(int) round(bScreenX + kInsideProbePx);
    int iy = cast(int) round(bScreenY);

    Vec3 expectedInside;
    assert(expectedRayHitOnSphere(c, cast(float)ix, cast(float)iy, R, expectedInside),
        "the inside-threshold probe pixel's camera-ray must hit the sphere");

    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, ix, iy));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 2,
        format("a press ~%.0fpx from B is INSIDE the measured %.0fpx snap gate and must GRAB B, "
             ~ "not place a third vertex; got %d vertices (the pre-0496 12px threshold placed one "
             ~ "here)", kInsideProbePx, kInsideProbePx + 1.0f, vertexCountLayer(1)));

    auto afterInside = readVerticesLayer(1);
    assert(approxVec(expectedInside, afterInside[1], TOL),
        "the grabbed B must re-snap to the inside-threshold probe's own independently-computed "
      ~ "camera-ray hit (proves it was MOVED by the grab, not left in place)");

    // B has MOVED to the inside probe's hit, so the outside probe must be
    // anchored on B's NEW screen position, not its original one.
    float b2ScreenX, b2ScreenY;
    assert(projectToWindow(expectedInside, vp, b2ScreenX, b2ScreenY),
        "B's post-grab world position must project back onto the viewport");

    int px = cast(int) round(b2ScreenX + kOutsideProbePx);
    int py = cast(int) round(b2ScreenY);

    Vec3 expectedProbe;
    assert(expectedRayHitOnSphere(c, cast(float)px, cast(float)py, R, expectedProbe),
        "the outside-threshold probe pixel's camera-ray must hit the sphere");

    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, px, py));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 3,
        format("a press ~%.0fpx from B (outside the measured 15px snap gate) must ARM PLACE, "
             ~ "adding a THIRD vertex rather than grabbing B; got %d vertices (a further widened "
             ~ "threshold would grab B instead and leave this at 2)",
              kOutsideProbePx, vertexCountLayer(1)));

    auto afterProbe = readVerticesLayer(1);
    assert(approxVec(expectedProbe, afterProbe[2], TOL),
        "the newly PLACED third vertex must match the probe pixel's own independently-computed "
      ~ "camera-ray hit (proves it was PLACED, not merely a moved B)");
    assert(approxVec(expectedInside, afterProbe[1], TOL),
        "B itself must be untouched by the probe click — it must still sit where the inside-probe "
      ~ "grab left it (proves the outside probe did NOT grab B)");
    assert(approxVec(expectedWithin, afterProbe[0], TOL),
        "A must remain untouched by the probe click");
}
