// Topology Pen P4 — move_stationary_noop (T1, doc/topopen_p4_plan.md
// "Test enumeration").
//
// A stationary plain-LMB click (down+up at the SAME pixel) landing on an
// EXISTING primary-layer vertex must ARM MOVE (not Place, which would add a
// SECOND vertex) — and since the release re-snaps to the identical pixel's
// camera-ray hit (== the vertex's own current position), the eps no-op
// guard (`moveVertexTo`) must trigger: no mutation, no undo entry. Mirrors
// P3's degenerate-release convention (test_topopen_build_tri.d's undo/redo
// discipline), applied here to Move's stationary-grab case.
//
// Run via: ./run_test.d topopen_move_stationary_noop

import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

enum float R   = 2.0f;
enum int   LON = 96, LAT = 72;   // resolution rationale: topopen_place_helpers.d

unittest {
    setupSphereBg(R, LON, LAT);

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;

    cmd("tool.set mesh.topoPen on");
    // Mode dropdown (task 0483): this test drives PLAIN-LMB presses and
    // expects the place-on-empty/grab-move gesture, which is `point` —
    // the default is now `move`, which places nothing on empty space.
    cmd("tool.attr mesh.topoPen mode point");

    // Place vertex A via a plain click (P2/P4-Place path).
    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 1, "setup click must place exactly 1 vertex");
    assert(edgeCountLayer(1) == 0 && faceCountLayer(1) == 0);

    auto before          = readVerticesLayer(1);
    int  undoDepthBefore = cast(int) getJson("/api/history")["undo"].array.length;

    // Stationary re-click ON A itself: down+up at the SAME pixel. Must ARM
    // MOVE (findSourceVertex sees A at this exact screen pixel), and the
    // release's re-snap lands back at A's own current position -> clean
    // no-op via moveVertexTo's eps guard.
    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 1,
        "a stationary re-click on the vertex must NOT place a second vertex (proves MOVE armed, not PLACE)");

    auto after = readVerticesLayer(1);
    assert(after == before,
        "a stationary grab-and-release must leave every vertex byte-identical (independent expected: "
        ~ "the vertex list equals pre-click element-wise)");

    int undoDepthAfter = cast(int) getJson("/api/history")["undo"].array.length;
    assert(undoDepthAfter == undoDepthBefore,
        format("a stationary grab-and-release must record NO undo entry (clean no-op); "
             ~ "undo depth went %d -> %d", undoDepthBefore, undoDepthAfter));
}
