// Topology Pen — place_multi_accumulate.
//
// Three clicks at three distinct pixels (in ONE /api/play-events call)
// accumulate three vertices in the primary layer, each independently
// verified as an on-surface camera-ray hit — proving the tool stays armed
// across repeated clicks (no auto-deactivate) and each click is its own
// command (three additions, not one merged edit). The background sphere's
// vertex count is asserted unchanged throughout (primary-only mutation).
//
// Run via: ./run_test.d topopen_place_multi_accumulate

import topopen_place_helpers;
import std.json;
import std.math   : abs, sqrt;
import std.format : format;

void main() {}

enum float R   = 2.0f;
enum int   LON = 96, LAT = 72;   // resolution rationale: topopen_place_helpers.d
enum double TOL = R * 0.04;   // covers the mesh-resolution note in topopen_place_helpers.d

unittest {
    setupSphereBg(R, LON, LAT);

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;

    int[2][3] pts = [
        [cx,      cy],
        [cx + 70, cy + 30],
        [cx - 50, cy - 60],
    ];

    Vec3[3] expected;
    foreach (i, p; pts) {
        bool ok = expectedRayHitOnSphere(c, cast(float)p[0], cast(float)p[1], R, expected[i]);
        assert(ok, format("click %d's camera-ray must hit the sphere", i));
    }

    int bgBefore = vertexCountLayer(0);
    assert(vertexCountLayer(1) == 0, "primary layer must start empty");

    cmd("tool.set mesh.topoPen on");
    // Mode dropdown (task 0483): this test drives PLAIN-LMB presses and
    // expects the place-on-empty/grab-move gesture, which is `point` —
    // the default is now `move`, which places nothing on empty space.
    cmd("tool.attr mesh.topoPen mode point");

    auto pr = postJson("/api/play-events", multiClickLog(c.vpX, c.vpY, c.width, c.height, pts));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 3,
        format("3 clicks must accumulate exactly 3 vertices; got %d", vertexCountLayer(1)));

    foreach (i, exp; expected) {
        assert(hasVertexNear(1, exp, TOL),
            format("click %d's independently-computed camera-ray hit (%f,%f,%f) "
                 ~ "must be present among the placed vertices", i, exp.x, exp.y, exp.z));
        double dist = sqrt(exp.x*exp.x + exp.y*exp.y + exp.z*exp.z);
        assert(abs(dist - R) < TOL, "each expected hit must itself be on-surface (sanity)");
    }

    assert(vertexCountLayer(0) == bgBefore,
        "background sphere layer must be untouched by any of the 3 clicks");
}
