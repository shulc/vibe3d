// Topology Pen P6 — addloop_drag (item 6, doc/topopen_p6_addloop_plan.md
// "Testing Strategy": "drag slides the ratio").
//
// A Shift+MMB press near one end of the seed edge, DRAGGED to release near
// a specific off-center point, must land the cut at the RELEASE ratio
// (independently recomputed from the cube's own vertex coordinates), not at
// 0.5 — proving the ratio tracks the cursor rather than being pinned to the
// press point or a fixed default.
//
// Run via: ./run_test.d topopen_addloop_drag

import topopen_place_helpers;
import std.json;
import std.math   : abs;
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

    // Edge 0-1: v0=(-0.5,-0.5,-0.5), v1=(0.5,-0.5,-0.5). Press near the v0
    // end (t=0.1 along the rail) and release near t=0.75 — a genuine drag
    // toward the OTHER end, off the r=0.5 midpoint.
    enum float rPress   = 0.1f;
    enum float rRelease = 0.75f;

    float pxF, pyF, rxF, ryF;
    assert(projectToWindow(Vec3(-0.5f + rPress,   -0.5f, -0.5f), vp, pxF, pyF),
        "the press-end point must project on-screen");
    assert(projectToWindow(Vec3(-0.5f + rRelease, -0.5f, -0.5f), vp, rxF, ryF),
        "the release point must project on-screen");
    int px = cast(int)pxF, py = cast(int)pyF;
    int rx = cast(int)rxF, ry = cast(int)ryF;

    assert(vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12 && faceCountLayer(0) == 6,
        "setup: pre-state must be the untouched cube");

    cmd("tool.set mesh.topoPen on");

    auto pr = postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, px, py, rx, ry, 16, LSHIFT, 2));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(0) == 12,
        format("Add Loop drag must still add exactly 4 vertices; got %d", vertexCountLayer(0)));
    assert(edgeCountLayer(0) == 20 && faceCountLayer(0) == 10,
        "Add Loop drag must still be a clean closed-ring cut (Δe=+8/Δf=+4)");

    // The new vertex on edge 0-1 must sit at the RELEASE ratio (or its
    // sign-flip complement — the orientation ambiguity the plan documents),
    // NOT at the r=0.5 midpoint.
    enum double eps = 1e-2;   // pixel-derived ray hit — looser than the exact-click cube test
    Vec3 lo = Vec3(-0.5f + rRelease,       -0.5f, -0.5f);
    Vec3 hi = Vec3(-0.5f + (1.0f-rRelease), -0.5f, -0.5f);
    assert(hasVertexNear(0, lo, eps) || hasVertexNear(0, hi, eps),
        "the drag's release ratio must place the new vertex at the independently-computed "
      ~ "off-center point (or its sign-flip), not the midpoint");
    assert(!hasVertexNear(0, Vec3(0.0f, -0.5f, -0.5f), eps),
        "sanity: an off-center drag must NOT land at the r=0.5 midpoint");
}
