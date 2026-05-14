// Lasso-falloff drag test (Stage B4 of doc/test_coverage_plan.md).
//
// Builds a tight quad around v6's projected pixel, installs it as the
// falloff lasso polygon (softBorder=0 ⇒ inside=1 / outside=0), then drags
// the move tool. Only v6 should move — all other selected verts have
// weight 0 because their pixel projection falls outside the lasso quad.
//
// Drives the live lassoWeight path (source/falloff.d) through the same
// MoveTool drag flow tests A1–A5 exercise; complements test_toolpipe_falloff,
// which only round-trips the setAttr surface.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;
import std.format : format;

import drag_helpers;

void main() {}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

unittest { // lasso encloses v6 only — only v6 moves under move drag
    post("http://localhost:8080/api/reset", "");

    auto selResp = post("http://localhost:8080/api/select",
                        `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(parseJSON(cast(string)selResp)["status"].str == "ok",
        "select failed: " ~ cast(string)selResp);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // Project each cube vert to a window pixel so we can build a quad
    // that hugs v6 alone. Float-coords with no rounding — lassoPoly is
    // matched in float pixel space.
    float[8] vxPx, vyPx;
    immutable float[3][8] vw = [
        [-0.5f,-0.5f,-0.5f], [ 0.5f,-0.5f,-0.5f],
        [ 0.5f, 0.5f,-0.5f], [-0.5f, 0.5f,-0.5f],
        [-0.5f,-0.5f, 0.5f], [ 0.5f,-0.5f, 0.5f],
        [ 0.5f, 0.5f, 0.5f], [-0.5f, 0.5f, 0.5f],
    ];
    foreach (i; 0 .. 8) {
        assert(projectToWindow(Vec3(vw[i][0], vw[i][1], vw[i][2]), vp,
                               vxPx[i], vyPx[i]),
            "v" ~ i.to!string ~ " projects off-camera");
    }

    // Build a 10 px-wide square around v6's pixel. Then verify every
    // OTHER vert's pixel sits outside that square — the cube's default
    // projection comfortably separates corners by > 50 px so a 10 px
    // box can isolate any single corner.
    float cx6 = vxPx[6], cy6 = vyPx[6];
    enum float R = 10.0f;
    foreach (i; 0 .. 8) {
        if (i == 6) continue;
        bool outside = (vxPx[i] < cx6 - R) || (vxPx[i] > cx6 + R)
                    || (vyPx[i] < cy6 - R) || (vyPx[i] > cy6 + R);
        assert(outside,
            "v" ~ i.to!string ~ " pixel falls inside the 10 px box "
            ~ "around v6 — camera-projection layout changed; tighten R "
            ~ "or use a different separation strategy");
    }

    // "x1,y1;x2,y2;x3,y3;x4,y4" — closed quad around v6's pixel.
    string poly = format("%g,%g;%g,%g;%g,%g;%g,%g",
        cx6 - R, cy6 - R,
        cx6 + R, cy6 - R,
        cx6 + R, cy6 + R,
        cx6 - R, cy6 + R);

    string script =
        "tool.set move\n" ~
        "tool.pipe.attr falloff type lasso\n" ~
        "tool.pipe.attr falloff softBorder 0\n" ~
        `tool.pipe.attr falloff lassoPoly "` ~ poly ~ `"` ~ "\n";
    auto setResp = post("http://localhost:8080/api/script", script);
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
        "tool.set + lasso config failed: " ~ cast(string)setResp);

    double[3][8] pre;
    foreach (i; 0 .. 8) pre[i] = vertexPos(i);

    Vec3 pivot = Vec3(0, 0, 0);
    float size = gizmoSize(pivot, vp);
    Vec3 arrowStart = Vec3(pivot.x, pivot.y + size / 6.0f, pivot.z);
    Vec3 arrowEnd   = Vec3(pivot.x, pivot.y + size,         pivot.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(arrowStart, vp, sx1, sy1), "Y-arrow start off-camera");
    assert(projectToWindow(arrowEnd,   vp, sx2, sy2), "Y-arrow end off-camera");
    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double sdx = cast(double)(sx2 - sx1), sdy = cast(double)(sy2 - sy1);
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    int x1 = x0 + cast(int)(100.0 * sdx / sLen);
    int y1 = y0 + cast(int)(100.0 * sdy / sLen);

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    // v6 was inside the lasso ⇒ weight 1 ⇒ moves by the full drag delta.
    auto p6 = vertexPos(6);
    double dy6 = p6[1] - pre[6][1];
    assert(dy6 > 0.1,
        "v6 (inside lasso) should move by the full +Y delta: dy6=" ~
        dy6.to!string);

    // Every other vert was outside ⇒ weight 0 ⇒ no motion at all.
    foreach (i; 0 .. 8) {
        if (i == 6) continue;
        auto p = vertexPos(i);
        foreach (k; 0 .. 3) {
            assert(approx(p[k], pre[i][k], 1e-4),
                "v" ~ i.to!string ~ " (outside lasso) moved on component " ~
                k.to!string ~ ": " ~ pre[i][k].to!string ~ " → " ~
                p[k].to!string);
        }
    }
}
