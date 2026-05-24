// Interactive move-tool drag test (Stage A1 of doc/test_coverage_plan.md).
//
// What this exercises end-to-end:
//   1. select vertex 6 (cube corner (0.5,0.5,0.5))
//   2. tool.set move — gizmo appears at ACEN.Auto pivot = v6
//   3. play a synthesized MOUSEBUTTONDOWN + N motion + UP sequence
//      onto the X-arrow handle; events flow through the live SDL/tool
//      pipeline, not /api/transform — so the test pins the entire
//      hit-test → axisDragDelta → applyDelta path that the UI uses.
//   4. /api/model verifies v6 moved in +X and stayed put in Y/Z; all
//      other cube vertices are untouched.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;

import drag_helpers;

void main() {}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

unittest { // X-axis drag of v6 only moves v6 in +X
    post("http://localhost:8080/api/reset", "");

    auto selResp = post("http://localhost:8080/api/select",
                        `{"mode":"vertices","indices":[6]}`);
    assert(parseJSON(cast(string)selResp)["status"].str == "ok",
        "select failed: " ~ cast(string)selResp);

    auto setResp = post("http://localhost:8080/api/script", "tool.set move");
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
        "tool.set move failed: " ~ cast(string)setResp);

    auto pre6 = vertexPos(6);
    auto pre0 = vertexPos(0);
    auto pre7 = vertexPos(7);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // ACEN.Auto with single-vertex selection ⇒ gizmo pivot = v6.
    Vec3 pivot = Vec3(0.5f, 0.5f, 0.5f);
    float size = gizmoSize(pivot, vp);
    // Match handler.d:MoveHandler — arrow shaft starts at pivot+axis*(size/6)
    // so it doesn't clip into the centerBox; tip at pivot+axis*size.
    Vec3 arrowStart = Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z);
    Vec3 arrowEnd   = Vec3(pivot.x + size,         pivot.y, pivot.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(arrowStart, vp, sx1, sy1),
        "X-arrow start projects off-camera");
    assert(projectToWindow(arrowEnd,   vp, sx2, sy2),
        "X-arrow end projects off-camera");

    // Click ~70 % along the arrow from start — far from the centerBox at
    // pivot and from any plane circle at the corners. Hit-test threshold
    // is 8 px so the click lands solidly on the shaft.
    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));

    // Drag ~100 px along the on-screen projection of the world X-axis.
    // Magnitude chosen so the world delta is comfortably > 0.1 regardless
    // of camera aspect — tiny layout drift won't shrink the actual move
    // below the 0.1 lower-bound assertion.
    double sdx = cast(double)(sx2 - sx1);
    double sdy = cast(double)(sy2 - sy1);
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    assert(sLen > 1.0,
        "X-arrow projects too short to drive a robust drag (camera bad?)");
    int x1 = x0 + cast(int)(100.0 * sdx / sLen);
    int y1 = y0 + cast(int)(100.0 * sdy / sLen);

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    auto post6 = vertexPos(6);
    auto post0 = vertexPos(0);
    auto post7 = vertexPos(7);

    double dx = post6[0] - pre6[0];
    double dy = post6[1] - pre6[1];
    double dz = post6[2] - pre6[2];
    // X-arrow drag must be a pure +X translation. Lower-bound 0.1 keeps
    // the test honest about whether the drag actually fired — anything
    // smaller usually means hit-test missed the shaft.
    assert(dx > 0.1,
        "v6.x should grow with +X drag: dx=" ~ dx.to!string ~
        " (pre.x=" ~ pre6[0].to!string ~ " post.x=" ~ post6[0].to!string ~ ")");
    assert(approx(dy, 0.0, 0.01),
        "v6.y should not change in X-only drag: dy=" ~ dy.to!string);
    assert(approx(dz, 0.0, 0.01),
        "v6.z should not change in X-only drag: dz=" ~ dz.to!string);

    // Unselected vertices must stay put.
    foreach (k; 0 .. 3) {
        assert(approx(post0[k], pre0[k], 1e-4),
            "v0 moved on X-arrow drag of v6 (component " ~ k.to!string ~ ")");
        assert(approx(post7[k], pre7[k], 1e-4),
            "v7 moved on X-arrow drag of v6 (component " ~ k.to!string ~ ")");
    }
}
