// Interactive scale-tool drag test (Stage A3 of doc/test_coverage_plan.md).
//
// Selects all 8 cube verts (so the entire mesh scales), activates the
// scale tool, and drags the X-arrow tip away from the pivot. The pin:
//   • clicking the X-arrow hits dragAxis==0 (axis-locked scale)
//   • the per-axis scale path multiplies X-components only — Y and Z
//     of every vertex must stay unchanged
//   • factor > 1 because we drag in the projected +X direction

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;

import drag_helpers;

void main() {}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

unittest { // X-axis scale: drag X-arrow → mesh X spreads, Y / Z stay
    post("http://localhost:8080/api/reset", "");

    // Select all 8 cube verts so the whole mesh participates (ACEN.Auto
    // centroid lands at the origin and scaling is symmetric).
    auto selResp = post("http://localhost:8080/api/select",
                        `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(parseJSON(cast(string)selResp)["status"].str == "ok",
        "select failed: " ~ cast(string)selResp);

    auto setResp = post("http://localhost:8080/api/script", "tool.set scale");
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
        "tool.set scale failed: " ~ cast(string)setResp);

    double[3][8] pre;
    foreach (i; 0 .. 8) pre[i] = vertexPos(i);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    Vec3 pivot = Vec3(0, 0, 0);  // ACEN.Auto centroid for full cube = origin
    float size = gizmoSize(pivot, vp);
    // ScaleHandler arrow shaft: center + axis*(size/7) → center + axis*size.
    Vec3 arrowStart = Vec3(pivot.x + size / 7.0f, pivot.y, pivot.z);
    Vec3 arrowEnd   = Vec3(pivot.x + size,         pivot.y, pivot.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(arrowStart, vp, sx1, sy1),
        "X-arrow start projects off-camera");
    assert(projectToWindow(arrowEnd,   vp, sx2, sy2),
        "X-arrow end projects off-camera");

    // 70 % along the shaft — same rationale as the move test.
    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));

    // Drag ~80 px along the on-screen +X projection. Drag distance per
    // axisDragDelta math (drag.d): d_world = (Δpx · ŝ) / |s| · |axis|;
    // an 80 px push along the projected axis gives roughly +80/|s| world
    // units of scale factor — comfortably > 0.5, well beyond noise.
    double sdx = cast(double)(sx2 - sx1);
    double sdy = cast(double)(sy2 - sy1);
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    assert(sLen > 1.0,
        "X-arrow projects too short for a reliable scale drag");
    int x1 = x0 + cast(int)(80.0 * sdx / sLen);
    int y1 = y0 + cast(int)(80.0 * sdy / sLen);

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    foreach (i; 0 .. 8) {
        auto p = vertexPos(i);
        // Y and Z components must not change in an X-only scale.
        assert(approx(p[1], pre[i][1], 1e-4),
            "v" ~ i.to!string ~ ".y drifted in X-scale: " ~
            pre[i][1].to!string ~ " → " ~ p[1].to!string);
        assert(approx(p[2], pre[i][2], 1e-4),
            "v" ~ i.to!string ~ ".z drifted in X-scale: " ~
            pre[i][2].to!string ~ " → " ~ p[2].to!string);
        // X moves outward from the pivot (0): |x| should grow. The pre
        // |x| is exactly 0.5; require post |x| ≥ 0.6 so the factor is
        // visibly > 1 even with conservative drag projection.
        assert(fabs(p[0]) > 0.6,
            "v" ~ i.to!string ~ ".x didn't scale out: " ~
            pre[i][0].to!string ~ " → " ~ p[0].to!string);
        // X sign preserved (no flip): scaling factor > 0.
        assert((p[0] > 0) == (pre[i][0] > 0),
            "v" ~ i.to!string ~ ".x flipped sign — negative scale factor");
    }
}
