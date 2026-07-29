// Topology Pen — place_no_bg_miss.
//
// Placement seed = camera-ray∩bg-surface hit (source/toolpipe/stages/
// constrain.d's `pointNearestFootBackground`), so a click CAN miss even
// with a background surface present, if the ray doesn't land on it — this
// file only covers the simplest, unambiguous miss: NO background source at
// all. Hides the sphere background layer (`layer.setVisible index:0
// value:false` -> `snap.backgroundSourcesSnapshot()` returns empty ->
// CONS's `bgSurfaceRayHit` finds nothing to raycast against ->
// `hit.hit == false`) and asserts the click places nothing.
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
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2;
    int cy = c.vpY + c.height / 2;

    assert(vertexCountLayer(1) == 0, "primary layer must start empty");

    cmd("tool.set mesh.topoPen on");
    // Mode dropdown (task 0483): this test drives PLAIN-LMB presses and
    // expects the place-on-empty/grab-move gesture, which is `point` —
    // the default is now `move`, which places nothing on empty space.
    cmd("tool.attr mesh.topoPen mode point");

    auto pr = postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 0,
        "a click with a hidden (no-source) background must place nothing");
}
