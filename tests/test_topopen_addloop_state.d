// Topology Pen P6 — addloop_state (item 9, doc/topopen_p6_addloop_plan.md
// "Testing Strategy").
//
// A Shift+MMB press landing on a primary-layer edge must arm the Add Loop
// gesture and expose it over /api/tool/state: addLoopArmed==true and the
// expected seed edge index — independently found via /api/model's own edge
// list (never assumed / never read from the tool's own prior output). A
// release without a matching arm (a bare Shift+MMB up) must not crash and
// must leave the gesture disarmed.
//
// Run via: ./run_test.d topopen_addloop_state

import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

enum uint LSHIFT = 0x0001;   // KMOD_LSHIFT — the Add Loop gesture's own modifier

string shiftMmbDownAt(double t0, int px, int py) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":2,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                  t0, px, py, LSHIFT);
}

string shiftMmbDownLog(int vpX, int vpY, int vpW, int vpH, int px, int py) {
    return viewportLog(vpX, vpY, vpW, vpH) ~ "\n" ~ shiftMmbDownAt(10.0, px, py) ~ "\n";
}

/// The index in /api/model's edge list (layer `layer`) of the unordered
/// pair (a,b), or -1 if no such edge exists — independent ground truth,
/// never assumed from mesh construction order.
int findEdgeIndex(int layer, int a, int b) {
    auto edges = readEdgesLayer(layer);
    foreach (i, e; edges)
        if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a)) return cast(int)i;
    return -1;
}

unittest {
    postJson("/api/reset", "");   // default cube, single layer == primary (layer 0)

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));

    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);

    // Edge 0-1's world-space midpoint (v0=(-0.5,-0.5,-0.5), v1=(0.5,-0.5,-0.5)
    // — the SAME cube belt seed the kernel's own insertEdgeLoops unittest and
    // this suite's Tier-B commitAddLoop unittests use).
    float sx, sy;
    assert(projectToWindow(Vec3(0.0f, -0.5f, -0.5f), vp, sx, sy),
        "edge 0-1's midpoint must project on-screen at this framing");

    int expectedSeed = findEdgeIndex(0, 0, 1);
    assert(expectedSeed >= 0, "setup: edge 0-1 must exist in the default cube's edge list");

    cmd("tool.set mesh.topoPen on");

    // Baseline: no Add Loop armed.
    auto s0 = getJson("/api/tool/state");
    assert(s0["addLoopArmed"].type == JSONType.false_, "must start disarmed");
    assert(cast(int)s0["addLoopSeed"].integer == -1, "must start with no seed edge");

    postJson("/api/play-events",
        shiftMmbDownLog(c.vpX, c.vpY, c.width, c.height, cast(int)sx, cast(int)sy));
    waitPlayerIdle();

    auto s1 = getJson("/api/tool/state");
    assert(s1["addLoopArmed"].type == JSONType.true_,
        "Shift+MMB press on a valid ring-seed edge must arm the Add Loop gesture");
    assert(cast(int)s1["addLoopSeed"].integer == expectedSeed,
        format("addLoopSeed must be the independently-found edge index %d; got %s",
               expectedSeed, s1["addLoopSeed"].toString));

    // The mesh itself must be untouched while merely armed (commit is
    // deferred to release).
    assert(vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12 && faceCountLayer(0) == 6,
        "arming Add Loop must not mutate the mesh");
}
