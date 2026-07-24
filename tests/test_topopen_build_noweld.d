// Topology Pen P3 — build_noweld.
//
// A Shift+LMB drag (the documented gesture-map overlay slot for this
// tool's build action, gesture_map.md table A #4) landing EXACTLY on an
// existing vertex W's own screen pixel does NOT weld — it creates a
// brand-new, merely-nearby (not index-shared) vertex, connected to the
// drag's source A by a plain edge, while W itself stays a completely
// untouched, isolated vertex (SESSION-3 "weld1..weld4" finding:
// "Landing on an existing vertex's pixel behaves exactly like landing on
// empty space; there is no positional-weld/snap-to-vertex path").
//
// Run via: ./run_test.d topopen_build_noweld

import topopen_place_helpers;
import std.json;
import std.math   : abs, sqrt;
import std.format : format;

void main() {}

enum float  R      = 2.0f;
enum int    LON    = 96, LAT = 72;
enum double TOL    = R * 0.04;
enum uint   LSHIFT = 0x0001;   // KMOD_LSHIFT — the build overlay's modifier

unittest {
    setupSphereBg(R, LON, LAT);

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    int ax = c.vpX + c.width / 2, ay = c.vpY + c.height / 2;   // A
    int wx = ax + 90, wy = ay + 60;                            // W — a separate pre-placed vertex

    Vec3 expW;
    assert(expectedRayHitOnSphere(c, cast(float)wx, cast(float)wy, R, expW),
        "W's own camera-ray must hit the sphere");

    cmd("tool.set mesh.topoPen on");

    // A(0) and W(1), both via plain P2 clicks — two independent vertices.
    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, ax, ay));
    waitPlayerIdle();
    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, wx, wy));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 2, "both plain clicks must place their own vertex");

    // Shift+LMB drag FROM A TO W's EXACT pixel.
    auto pr = postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, ax, ay, wx, wy, 16, LSHIFT));
    assert("error" !in pr, "drag failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 3,
        format("landing on W must still create a NEW, distinct vertex (no weld); got %d vertices",
               vertexCountLayer(1)));
    assert(edgeCountLayer(1) == 1,
        format("expected exactly 1 new edge (A to the new vertex); got %d", edgeCountLayer(1)));
    assert(faceCountLayer(1) == 0, "CASE-EDGE must build no face");
    assert(hasEdgeLayer(1, 0, 2), "the new edge must connect A(0) to the NEW vertex(2), not to W(1)");
    assert(!hasEdgeLayer(1, 0, 1), "A must NOT be connected to W — the drag targets the new point, not W");
    assert(!hasEdgeLayer(1, 1, 2), "W must have no edge to the new vertex either — no weld means no connection at all");

    auto verts = readVerticesLayer(1);
    // W (index 1) itself must be untouched — same position it was placed at.
    assert(approxVec(expW, verts[1], TOL), "W's own position must be untouched by the drag landing on it");
    // The NEW vertex (index 2) lands near W (same camera ray) but is a
    // genuinely distinct index/entry — never literally reused as W's index.
    assert(approxVec(expW, verts[2], TOL),
        "the new vertex should land near W's position (same ray) despite being a distinct vertex");
}
