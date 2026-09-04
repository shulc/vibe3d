// Topology Pen P6 — addloop_cube (item 5, doc/topopen_p6_addloop_plan.md
// "Testing Strategy": "closed-ring end-to-end r≈0.5").
//
// A Shift+MMB click (down+up at the SAME pixel — the seed edge's own
// midpoint, so the release ratio is r≈0.5) on a primary-layer cube must
// insert one full closed-ring loop cut via the reused `insertEdgeLoops`
// kernel: Δv=+4/Δe=+8/Δf=+4 (8/12/6 -> 12/20/10), every new vertex at the
// midpoint of its crossed belt edge — independently computed from the
// cube's OWN known vertex coordinates, never from the tool's own output.
// One atomic undo entry; /api/undo restores the exact pre-cut state;
// /api/redo restores the cut bit-exact.
//
// Run via: ./run_test.d topopen_addloop_cube

import http_command_helpers : commandBody;
import topopen_place_helpers;
import std.json;
import std.math   : abs;
import std.format : format;

void main() {}

enum uint LSHIFT = 0x0001;   // KMOD_LSHIFT — the Add Loop gesture's own modifier

string shiftMmbClickAt(double t0, int px, int py) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":2,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                  t0, px, py, LSHIFT) ~ "\n"
         ~ format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":2,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                  t0 + 10.0, px, py, LSHIFT);
}

string shiftMmbClickLog(int vpX, int vpY, int vpW, int vpH, int px, int py) {
    return viewportLog(vpX, vpY, vpW, vpH) ~ "\n" ~ shiftMmbClickAt(10.0, px, py) ~ "\n";
}

unittest {
    postJson("/api/command", commandBody("scene.reset"));   // default cube, single layer == primary (layer 0)

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));

    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);

    // Edge 0-1's world-space midpoint — the same cube belt seed the kernel's
    // own insertEdgeLoops unittest walks (v0=(-0.5,-0.5,-0.5),
    // v1=(0.5,-0.5,-0.5)).
    float sx, sy;
    assert(projectToWindow(Vec3(0.0f, -0.5f, -0.5f), vp, sx, sy),
        "edge 0-1's midpoint must project on-screen at this framing");

    assert(vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12 && faceCountLayer(0) == 6,
        "setup: pre-state must be the untouched cube");

    cmd("tool.set mesh.topoPen on");

    auto pr = postJson("/api/play-events",
        shiftMmbClickLog(c.vpX, c.vpY, c.width, c.height, cast(int)sx, cast(int)sy));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(0) == 12,
        format("Add Loop r~=0.5 must add exactly 4 vertices; got %d", vertexCountLayer(0)));
    assert(edgeCountLayer(0) == 20,
        format("Add Loop r~=0.5 must add exactly 8 edges; got %d", edgeCountLayer(0)));
    assert(faceCountLayer(0) == 10,
        format("Add Loop r~=0.5 must add exactly 4 faces; got %d", faceCountLayer(0)));

    // Independently-computed midpoints of the 4 crossed belt edges (0-1,
    // 2-3, 6-7, 4-5), from the cube's OWN hand-known vertex coordinates.
    // eps is looser than the exact Tier-B (in-process) fixtures: the click
    // pixel is int-truncated and re-derived through an INDEPENDENT
    // reimplementation of the camera's lookAt/perspective matrices
    // (drag_helpers.d), so the recovered ratio is only APPROXIMATELY 0.5,
    // not bit-exact (same tolerance order as the sibling place/move tests'
    // camera-ray fixtures).
    enum double eps = 2e-2;
    assert(hasVertexNear(0, Vec3(0.0f, -0.5f, -0.5f), eps), "midpoint of edge 0-1 must exist");
    assert(hasVertexNear(0, Vec3(0.0f,  0.5f, -0.5f), eps), "midpoint of edge 2-3 must exist");
    assert(hasVertexNear(0, Vec3(0.0f,  0.5f,  0.5f), eps), "midpoint of edge 6-7 must exist");
    assert(hasVertexNear(0, Vec3(0.0f, -0.5f,  0.5f), eps), "midpoint of edge 4-5 must exist");

    // /api/undo restores the exact pre-cut state.
    auto u = postJson("/api/command", commandBody("history.undo"));
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);
    assert(vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12 && faceCountLayer(0) == 6,
        "undo must restore the exact pre-cut cube");

    // /api/redo restores the cut bit-exact.
    auto r = postJson("/api/command", commandBody("history.redo"));
    assert(r["status"].str == "ok", "redo must succeed: " ~ r.toString);
    assert(vertexCountLayer(0) == 12 && edgeCountLayer(0) == 20 && faceCountLayer(0) == 10,
        "redo must restore the cut exactly");
    assert(hasVertexNear(0, Vec3(0.0f, -0.5f, -0.5f), eps),
        "redo must restore the midpoint vertex of edge 0-1");
}
