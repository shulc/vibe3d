// Topology Pen P4 — move_disambiguation (T4, doc/topopen_p4_plan.md "Test
// enumeration").
//
// The regression class P4 introduces: a plain-LMB press within the pen's
// PRESS-PICK reach (`topoPenPressPickPx` — task 0496) of an existing
// primary-layer vertex must ARM MOVE (grab it — vertex count stays put), while
// a press just OUTSIDE that reach must ARM PLACE (a genuinely new vertex
// appears). The existing multi-place fixtures
// (test_topopen_place_multi_accumulate.d) happen to space clicks 70-150px
// apart — clear of the reach — so they do NOT exercise this boundary; hence
// this dedicated test.
//
// Review NIT-1 (P4 review): the original "outside" probe was pinned 70px from
// vertex A's OWN screen position — clear of the reach, but so far clear that a
// future accidental widening (e.g. to 50px) would still pass this test
// unnoticed. Fixed by anchoring the tight probes on a SEPARATE second vertex
// (B, placed fresh so its screen position is known independently of the
// earlier grab-and-re-snap of A) and probing it from BOTH sides.
//
// Task 0496, second wave — THIS FILE IS THE EVIDENCE OF THE FIX. Its probes
// were 14px (grab) and 19px (place), pinning a 15px reach that was the fusion
// of two different measured queries. Measured live, the press pick reaches
// about 8px — brackets (7.07, 7.78] for a vertex, (7.00, 8.85] for an edge —
// so the probes are now:
//
//   7px  — at the bracket's lower end: must GRAB. Green before and after; the
//          in-reach half of the law did not move.
//   14px — must PLACE. This is the annulus: the reference resolved the
//          POLYGON here (its own `P_vert14` cell), we grabbed the vertex, and
//          the hover highlight advertised our answer. Red on the shipped code,
//          which counted 2 vertices where this now counts 3.
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

    // --- WITHIN the reach: (cx+5,cy+5) is sqrt(5^2+5^2)~=7.07px from A's own
    // screen position — which is exactly the largest distance at which the
    // reference was observed to enumerate a vertex candidate, i.e. the lower
    // end of the measured bracket. A stationary click there must ARM MOVE
    // (grab A) — vertex count must stay 1, never grow to 2, even though the
    // click lands off A's EXACT pixel.
    int wx = cx + 5, wy = cy + 5;
    Vec3 expectedWithin;
    assert(expectedRayHitOnSphere(c, cast(float)wx, cast(float)wy, R, expectedWithin),
        "the within-threshold pixel's camera-ray must hit the sphere");

    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, wx, wy));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 1,
        "a press WITHIN the press-pick reach of the vertex must ARM MOVE, not place a second "
      ~ "vertex");

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
        format("a press OUTSIDE the press-pick reach of A must ARM PLACE, adding vertex B; got %d",
              vertexCountLayer(1)));

    auto afterB = readVerticesLayer(1);
    assert(approxVec(expectedB, afterB[1], TOL),
        "the newly PLACED second vertex (B) must match its placement pixel's camera-ray hit");
    assert(approxVec(expectedWithin, afterB[0], TOL),
        "A (already grabbed once) must be untouched by B's placement click");

    // --- Tight probes, anchored on B's OWN projected screen position — THIS
    // is what actually pins the reach: two probes, one on each side of it, so
    // neither a narrowing nor a widening can pass unnoticed. `bScreenX/Y` is
    // derived from `expectedB` (the independently-computed ray-sphere hit),
    // not from the server's own reported vertex position — the probe's
    // expectation stays independent of the tool's own output.
    float bScreenX, bScreenY;
    assert(projectToWindow(expectedB, vp, bScreenX, bScreenY),
        "B's expected world position must project back onto the viewport");

    // Task 0496, second wave (the measured PRESS-PICK reach). The reference
    // printed one press limit of 8.0 and delivered a reach bracketed at
    // (7.07, 7.78] for vertices; the 15px this tool used to carry belonged to
    // no query at all. This pair of probes pins that from the outside:
    //   * kInsideProbePx  = 7px — the bracket's lower end, the largest
    //     distance at which the reference was seen to enumerate a vertex, so
    //     it must GRAB B.
    //   * kOutsideProbePx = 14px — THE ANNULUS. Past the reach, and the exact
    //     offset of the reference's own `P_vert14` cell, where it resolved the
    //     POLYGON. Must PLACE a third vertex. This assertion is RED on the
    //     shipped code, whose 15px gate grabbed B and left the count at 2.
    // Deliberately NOT probed: anything between 7.8px and 8.9px. The
    // measurement brackets the cut but does not locate it, and a test there
    // would be inventing precision.
    enum float kInsideProbePx  = 7.0f;
    enum float kOutsideProbePx = 14.0f;

    int ix = cast(int) round(bScreenX + kInsideProbePx);
    int iy = cast(int) round(bScreenY);

    Vec3 expectedInside;
    assert(expectedRayHitOnSphere(c, cast(float)ix, cast(float)iy, R, expectedInside),
        "the inside-threshold probe pixel's camera-ray must hit the sphere");

    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, ix, iy));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 2,
        format("a press ~%.0fpx from B is at the measured bracket's lower end (7.07px) and must "
             ~ "GRAB B, not place a third vertex; got %d vertices",
              kInsideProbePx, vertexCountLayer(1)));

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
        format("a press ~%.0fpx from B is in the ANNULUS — past the measured press-pick reach, "
             ~ "where the reference resolved the polygon — and must ARM PLACE, adding a THIRD "
             ~ "vertex rather than grabbing B; got %d vertices (the shipped 15px gate grabbed B "
             ~ "and left this at 2)", kOutsideProbePx, vertexCountLayer(1)));

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
