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
import std.format : format;

import drag_helpers;

void main() {}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

string buildPinnedRelativeDragLog(int vpX, int vpY, int vpW, int vpH,
                                  int x0, int y0, int totalDx, int totalDy,
                                  int steps = 20)
{
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    log ~= format(
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x0, y0);

    int lastRx, lastRy;
    foreach (i; 1 .. steps + 1) {
        int rx = cast(int)((cast(double)totalDx * i) / steps);
        int ry = cast(int)((cast(double)totalDy * i) / steps);
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            50.0 + i * 50.0, x0, y0, rx - lastRx, ry - lastRy);
        lastRx = rx; lastRy = ry;
    }
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        50.0 + (steps + 1) * 50.0, x0, y0);
    return log;
}

void runScalePlaneDrag(int plane) {
    post("http://localhost:8080/api/reset", "");
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
    Vec3 pivot = Vec3(0, 0, 0);
    float off = gizmoSize(pivot, vp) * 0.75f;
    Vec3 circleCenter =
        plane == 4 ? Vec3(pivot.x + off, pivot.y + off, pivot.z)
      : plane == 5 ? Vec3(pivot.x,       pivot.y + off, pivot.z + off)
                   : Vec3(pivot.x + off, pivot.y,       pivot.z + off);
    float cx, cy;
    assert(projectToWindow(circleCenter, vp, cx, cy),
        "scale plane circle center projects off-camera");

    string log = buildPinnedRelativeDragLog(cam.vpX, cam.vpY, cam.width,
                                            cam.height,
                                            cast(int)cx, cast(int)cy,
                                            80, 0, 20);
    playAndWait(log);

    foreach (i; 0 .. 8) {
        auto p = vertexPos(i);
        bool sx = (plane == 4 || plane == 6);
        bool sy = (plane == 4 || plane == 5);
        bool sz = (plane == 5 || plane == 6);

        if (sx) assert(fabs(p[0]) > 0.6,
            "v" ~ i.to!string ~ ".x did not scale for plane " ~ plane.to!string);
        else    assert(approx(p[0], pre[i][0], 1e-4),
            "v" ~ i.to!string ~ ".x drifted for plane " ~ plane.to!string);

        if (sy) assert(fabs(p[1]) > 0.6,
            "v" ~ i.to!string ~ ".y did not scale for plane " ~ plane.to!string);
        else    assert(approx(p[1], pre[i][1], 1e-4),
            "v" ~ i.to!string ~ ".y drifted for plane " ~ plane.to!string);

        if (sz) assert(fabs(p[2]) > 0.6,
            "v" ~ i.to!string ~ ".z did not scale for plane " ~ plane.to!string);
        else    assert(approx(p[2], pre[i][2], 1e-4),
            "v" ~ i.to!string ~ ".z drifted for plane " ~ plane.to!string);
    }
}

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
    // ScaleHandler arrow shaft: center + axis*(size/7) → center + axis*(size*1.18).
    Vec3 arrowStart = Vec3(pivot.x + size / 7.0f, pivot.y, pivot.z);
    Vec3 arrowEnd   = Vec3(pivot.x + size * 1.18f, pivot.y, pivot.z);
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
    float cx, cy, ux, uy;
    assert(projectToWindow(pivot, vp, cx, cy),
        "X-scale pivot projects off-camera");
    assert(projectToWindow(Vec3(1, 0, 0), vp, ux, uy),
        "X-scale unit axis projects off-camera");
    double sdx = cast(double)(ux - cx);
    double sdy = cast(double)(uy - cy);
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

unittest { // X-axis scale keeps dragging from relative motion even if x/y stop
    post("http://localhost:8080/api/reset", "");
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

    Vec3 pivot = Vec3(0, 0, 0);
    float size = gizmoSize(pivot, vp);
    Vec3 arrowStart = Vec3(pivot.x + size / 7.0f, pivot.y, pivot.z);
    Vec3 arrowEnd   = Vec3(pivot.x + size * 1.18f, pivot.y, pivot.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(arrowStart, vp, sx1, sy1),
        "X-arrow start projects off-camera");
    assert(projectToWindow(arrowEnd,   vp, sx2, sy2),
        "X-arrow end projects off-camera");

    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));

    float cx, cy, ux, uy;
    assert(projectToWindow(pivot, vp, cx, cy),
        "X-scale pivot projects off-camera");
    assert(projectToWindow(Vec3(1, 0, 0), vp, ux, uy),
        "X-scale unit axis projects off-camera");
    double sdx = cast(double)(ux - cx);
    double sdy = cast(double)(uy - cy);
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    assert(sLen > 1.0,
        "X-arrow projects too short for a reliable scale drag");
    int dx = cast(int)(80.0 * sdx / sLen);
    int dy = cast(int)(80.0 * sdy / sLen);

    string log = buildPinnedRelativeDragLog(cam.vpX, cam.vpY, cam.width,
                                            cam.height, x0, y0, dx, dy, 20);
    playAndWait(log);

    foreach (i; 0 .. 8) {
        auto p = vertexPos(i);
        assert(approx(p[1], pre[i][1], 1e-4),
            "v" ~ i.to!string ~ ".y drifted in relative X-scale");
        assert(approx(p[2], pre[i][2], 1e-4),
            "v" ~ i.to!string ~ ".z drifted in relative X-scale");
        assert(fabs(p[0]) > 0.6,
            "relative-only X scale did not move enough: "
            ~ pre[i][0].to!string ~ " → " ~ p[0].to!string);
    }
}

unittest { // XY plane scale: X/Y factors change, Z stays fixed
    runScalePlaneDrag(4);
}

unittest { // YZ plane scale: Y/Z factors change, X stays fixed
    runScalePlaneDrag(5);
}

unittest { // XZ plane scale: X/Z factors change, Y stays fixed
    runScalePlaneDrag(6);
}

unittest { // X-axis scale reaches zero with finite reverse drag
    post("http://localhost:8080/api/reset", "");
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

    Vec3 pivot = Vec3(0, 0, 0);
    float size = gizmoSize(pivot, vp);
    Vec3 arrowStart = Vec3(pivot.x + size / 7.0f, pivot.y, pivot.z);
    Vec3 arrowEnd   = Vec3(pivot.x + size * 1.18f, pivot.y, pivot.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(arrowStart, vp, sx1, sy1),
        "X-arrow start projects off-camera");
    assert(projectToWindow(arrowEnd,   vp, sx2, sy2),
        "X-arrow end projects off-camera");

    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));

    float cx, cy, ux, uy;
    assert(projectToWindow(pivot, vp, cx, cy),
        "X-scale pivot projects off-camera");
    assert(projectToWindow(Vec3(1, 0, 0), vp, ux, uy),
        "X-scale unit axis projects off-camera");
    double sdx = cast(double)(ux - cx);
    double sdy = cast(double)(uy - cy);
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    assert(sLen > 1.0,
        "X-arrow projects too short for a reliable scale drag");
    int dx = cast(int)(-1.25 * sLen * sdx / sLen);
    int dy = cast(int)(-1.25 * sLen * sdy / sLen);

    string log = buildPinnedRelativeDragLog(cam.vpX, cam.vpY, cam.width,
                                            cam.height, x0, y0, dx, dy, 20);
    playAndWait(log);

    foreach (i; 0 .. 8) {
        auto p = vertexPos(i);
        assert(fabs(p[0]) < 1e-4,
            "reverse X-scale did not reach zero: "
            ~ pre[i][0].to!string ~ " → " ~ p[0].to!string);
        assert(approx(p[1], pre[i][1], 1e-4),
            "v" ~ i.to!string ~ ".y drifted in zero X-scale");
        assert(approx(p[2], pre[i][2], 1e-4),
            "v" ~ i.to!string ~ ".z drifted in zero X-scale");
    }
}
