// Topology Pen P4 — move_undo_redo (T3, doc/topopen_p4_plan.md "Test
// enumeration").
//
// After a Move drag, ONE undo restores the exact pre-move vertex position;
// redo re-applies the move exactly. Mirrors P3's own undo/redo discipline
// (test_topopen_build_tri.d) applied to Move's OWN dedicated undo entry
// (`topoPenMoveEditFactory`, wireName "mesh.topoPen_move" — distinct from
// the build gesture's "mesh.topoPen_build", OBJ-3 FOLDED).
//
// Run via: ./run_test.d topopen_move_undo_redo

import http_command_helpers : commandBody;
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
    int nx = cx + 80, ny = cy + 40;

    Vec3 expectedA, expectedMoved;
    assert(expectedRayHitOnSphere(c, cast(float)cx, cast(float)cy, R, expectedA));
    assert(expectedRayHitOnSphere(c, cast(float)nx, cast(float)ny, R, expectedMoved));

    cmd("tool.set mesh.topoPen on");
    // Mode dropdown (task 0483): this test drives PLAIN-LMB presses and
    // expects the place-on-empty/grab-move gesture, which is `point` —
    // the default is now `move`, which places nothing on empty space.
    cmd("tool.attr mesh.topoPen mode point");

    // Place A, then drag it to a new pixel (T2's own scenario, replayed here
    // so this file stays independently runnable).
    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 1);

    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, nx, ny, 16));
    waitPlayerIdle();

    auto moved = readVerticesLayer(1);
    assert(approxVec(expectedMoved, moved[0], TOL), "setup: the drag must land at the release hit");

    // One undo restores the EXACT pre-move vertex position — a single
    // atomic undo entry, not a partial/incremental one.
    auto u = postJson("/api/command", commandBody("history.undo"));
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);
    assert(vertexCountLayer(1) == 1, "undo must not change the vertex COUNT (Move never adds/removes)");

    auto afterUndo = readVerticesLayer(1);
    assert(approxVec(expectedA, afterUndo[0], TOL),
        "undo must restore A's exact pre-move position");

    // Redo re-applies the move exactly.
    auto r = postJson("/api/command", commandBody("history.redo"));
    assert(r["status"].str == "ok", "redo must succeed: " ~ r.toString);

    auto afterRedo = readVerticesLayer(1);
    assert(approxVec(expectedMoved, afterRedo[0], TOL),
        "redo must restore the EXACT moved position");
}
