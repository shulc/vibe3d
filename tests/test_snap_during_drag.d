// Snap-during-drag test (Stage B1 of doc/test_coverage_plan.md).
//
// Enables vertex-snap with effectively-infinite range, drags v0's
// X-arrow toward v1's screen position, then asserts v0 lands AT v1
// (its X = v1.X, Y / Z preserved because both share them on a cube).
//
// What this exercises that the existing test_toolpipe_snap.d doesn't:
//   • the full /api/play-events → MoveTool.onMouseMotion → applySnapToDelta
//     → constrainSnapDelta path runs on every motion event during a live
//     drag (toolpipe_snap only hits /api/snap as a stand-alone query).
//   • the dragged-vertex exclusion (`exclude` array in MoveTool) keeps
//     v0 from snapping to itself.

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;
import std.format : format;

import drag_helpers;

void main() {}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

unittest { // axis-X drag of v0 with vertex snap lands v0 on v1
    post("http://localhost:8080/api/reset", "");

    auto selResp = post("http://localhost:8080/api/select",
                        `{"mode":"vertices","indices":[0]}`);
    assert(parseJSON(cast(string)selResp)["status"].str == "ok",
        "select failed: " ~ cast(string)selResp);

    string script =
        "tool.set move\n" ~
        "tool.pipe.attr snap enabled true\n" ~
        "tool.pipe.attr snap types vertex\n" ~
        "tool.pipe.attr snap innerRange 999999\n" ~
        "tool.pipe.attr snap outerRange 999999\n";
    auto setResp = post("http://localhost:8080/api/script", script);
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
        "tool.set + snap config failed: " ~ cast(string)setResp);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // ACEN.Auto pivot for single-vertex selection = v0 = (-0.5,-0.5,-0.5).
    Vec3 pivot = Vec3(-0.5f, -0.5f, -0.5f);
    float size = gizmoSize(pivot, vp);
    Vec3 arrowStart = Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z);
    Vec3 arrowEnd   = Vec3(pivot.x + size,         pivot.y, pivot.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(arrowStart, vp, sx1, sy1), "arrowStart off-camera");
    assert(projectToWindow(arrowEnd,   vp, sx2, sy2), "arrowEnd off-camera");

    // Click on the shaft (50 %) — solidly inside the 8 px hit window.
    int x0 = cast(int)(sx1 + 0.5f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.5f * (sy2 - sy1));

    // Drag the cursor to v1's screen pixel. With huge snap range and
    // v0 excluded, v1 is the closest vert and applySnapToDelta lands
    // the gizmo at v1.
    float v1x, v1y;
    assert(projectToWindow(Vec3(0.5f, -0.5f, -0.5f), vp, v1x, v1y),
        "v1 off-camera");
    int x1 = cast(int)v1x;
    int y1 = cast(int)v1y;

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    auto p0 = vertexPos(0);
    // Axis-X snap: v0.x snaps to v1.x = 0.5; Y / Z stay (v1.y/z also
    // equal v0.y/z so the equal-position check is unambiguous here).
    assert(approx(p0[0], 0.5),
        "v0.x should snap to v1.x=0.5, got " ~ p0[0].to!string);
    assert(approx(p0[1], -0.5),
        "v0.y should stay at -0.5 (axis-X drag), got " ~ p0[1].to!string);
    assert(approx(p0[2], -0.5),
        "v0.z should stay at -0.5 (axis-X drag), got " ~ p0[2].to!string);

    // The snap target itself must not have moved (selection is just v0).
    auto p1 = vertexPos(1);
    assert(approx(p1[0], 0.5) && approx(p1[1], -0.5) && approx(p1[2], -0.5),
        "v1 (snap target) drifted: (" ~ p1[0].to!string ~ "," ~
        p1[1].to!string ~ "," ~ p1[2].to!string ~ ")");
}
