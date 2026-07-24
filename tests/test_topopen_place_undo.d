// Topology Pen — place_undo.
//
// One click -> 1 vertex; POST /api/undo -> back to 0 (the REV-1 undo
// wiring: `MeshVertexNew.evaluate()` snapshots pre-apply, `history_.record`
// is post-apply with no re-apply, so `revert()` == snapshot restore, one
// non-coalescing entry per click); POST /api/redo -> 1 vertex again
// (bonus, per the plan's Definition of Done).
//
// Run via: ./run_test.d topopen_place_undo

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
    int cx = c.vpX + c.width / 2;
    int cy = c.vpY + c.height / 2;

    cmd("tool.set mesh.topoPen on");

    auto pr = postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 1, "click must place exactly 1 vertex");

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);
    assert(vertexCountLayer(1) == 0, "undo must remove the placed vertex");

    auto r = postJson("/api/redo", "");
    assert(r["status"].str == "ok", "redo must succeed: " ~ r.toString);
    assert(vertexCountLayer(1) == 1, "redo must restore the placed vertex");
}
