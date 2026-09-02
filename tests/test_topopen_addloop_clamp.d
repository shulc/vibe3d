// Topology Pen P6 — addloop_clamp (item 7, doc/topopen_p6_addloop_plan.md
// "Testing Strategy": "clamp (drag past the edge end)").
//
// A Shift+MMB drag released well PAST the seed edge's far endpoint must
// clamp the ratio to 1.0 (`closestPointOnSegmentToRay` clamps its returned
// point to the segment; `ratioFromCursor` re-derives the same clamped `t`)
// — landing exactly on a vertex — which `commitAddLoop`'s open-interval
// guard (verbatim `MeshAddLoop.evaluate`) rejects as a no-op: zero mesh
// mutation, no new undo entry.
//
// Run via: ./run_test.d topopen_addloop_clamp

import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

enum uint LSHIFT = 0x0001;   // KMOD_LSHIFT — the Add Loop gesture's own modifier

unittest {
    postJson("/api/reset", "");   // default cube, single layer == primary (layer 0)

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));

    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);

    // Edge 0-1: v0=(-0.5,-0.5,-0.5), v1=(0.5,-0.5,-0.5). Press at the
    // midpoint (a safe, unambiguous ring-seed pick) and release WELL past
    // v1's own position, along the SAME line — the closest point on the
    // real 3D segment to that release ray clamps to v1 itself (t=1).
    float pxF, pyF, rxF, ryF;
    assert(projectToWindow(Vec3(0.0f, -0.5f, -0.5f), vp, pxF, pyF),
        "the seed edge's midpoint must project on-screen");
    assert(projectToWindow(Vec3(1.0f, -0.5f, -0.5f), vp, rxF, ryF),
        "the past-the-end point must project on-screen");
    int px = cast(int)pxF, py = cast(int)pyF;
    int rx = cast(int)rxF, ry = cast(int)ryF;

    assert(vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12 && faceCountLayer(0) == 6,
        "setup: pre-state must be the untouched cube");

    auto historyBefore = historySurfaceCounts();

    cmd("tool.set mesh.topoPen on");

    auto pr = postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, px, py, rx, ry, 16, LSHIFT, 2));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12 && faceCountLayer(0) == 6,
        "a release clamped to a vertex (r>=1) must be a byte-identical no-op");

    // The arm row is visible by measured surface law
    // (`toolcards/undo_surfaces/`), but the clamped gesture must still add no
    // edit row.  Keeping these assertions separate prevents one noisy no-op
    // row from hiding behind the legitimate arm row.
    auto historyAfter = historySurfaceCounts();
    assert(historyAfter.editRows == historyBefore.editRows,
        "a clamp no-op must add ZERO edit rows");
    assert(historyAfter.lifecycleRows == historyBefore.lifecycleRows + 1,
        format("arming Topology Pen must surface exactly ONE lifecycle row; got %d",
               historyAfter.lifecycleRows - historyBefore.lifecycleRows));
}
