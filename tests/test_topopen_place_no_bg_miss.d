// Topology Pen P2 (doc/topopen_p2_plan.md) — place_no_bg_miss.
//
// Under Point mode's nearest-foot rule, a click ALWAYS finds a point when a
// background surface exists — there is no "missed the silhouette" the way
// camera-ray had (see the plan's "Behavioral consequence" note). The only
// remaining miss is when there is NO background source at all: this test
// hides the sphere background layer (`layer.setVisible index:0 value:false`
// -> `snap.backgroundSourcesSnapshot()` returns empty -> CONS's
// `pointNearestFootBackground` finds no source -> `hit.hit == false`) and
// asserts the click places nothing.
//
// Run via: ./run_test.d topopen_place_no_bg_miss

import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

enum float R   = 2.0f;
enum int   LON = 96, LAT = 72;   // resolution rationale: topopen_place_helpers.d

unittest {
    setupSphereBg(R, LON, LAT);
    cmd("layer.setVisible index:0 value:false");   // hide the background sphere

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 1.4, 10.0, 3.0 * R, 0.0, 0.0));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2;
    int cy = c.vpY + c.height / 2;

    assert(vertexCountLayer(1) == 0, "primary layer must start empty");

    cmd("tool.set mesh.topoPen on");

    auto pr = postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 0,
        "a click with a hidden (no-source) background must place nothing");
}
