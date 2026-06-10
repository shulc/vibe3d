// Plane-drag (screen-plane / axis-pair) move-tool test (Stage A4 of
// doc/test_coverage_plan.md).
//
// The MoveHandler exposes three plane handles — small circles at the
// quad corners — each constraining drag to one of XY / YZ / XZ. We
// drive the XY circle (dragAxis==4) and check that the resulting
// translation lives entirely in world XY, with Z untouched. This pins
// the planeDragDelta code path (drag.d), separate from the axis path
// already covered by test_tool_move_drag.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;

import drag_helpers;

void main() {}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

void runMovePlaneDrag(int plane) {
    post("http://localhost:8080/api/reset", "");

    auto selResp = post("http://localhost:8080/api/select",
                        `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(parseJSON(cast(string)selResp)["status"].str == "ok",
        "select failed: " ~ cast(string)selResp);

    auto setResp = post("http://localhost:8080/api/script", "tool.set move");
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
        "tool.set move failed: " ~ cast(string)setResp);

    double[3][8] pre;
    foreach (i; 0 .. 8) pre[i] = vertexPos(i);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // ACEN.Auto pivot for full cube = origin.
    Vec3 pivot = Vec3(0, 0, 0);
    float size = gizmoSize(pivot, vp);

    // Plane handles sit at center + two basis axes * 0.75*gizmoSize:
    //   4 = XY, 5 = YZ, 6 = XZ.
    float off = size * 0.75f;
    Vec3 circleCenter =
        plane == 4 ? Vec3(pivot.x + off, pivot.y + off, pivot.z)
      : plane == 5 ? Vec3(pivot.x,       pivot.y + off, pivot.z + off)
                   : Vec3(pivot.x + off, pivot.y,       pivot.z + off);
    float cx, cy;
    assert(projectToWindow(circleCenter, vp, cx, cy),
        "plane circle center projects off-camera");
    int x0 = cast(int)cx;
    int y0 = cast(int)cy;

    // Drag screen-down by 60 px. The exact in-plane split depends on
    // camera projection; the pin is that the plane normal component is
    // stripped and at least one in-plane component changes.
    int x1 = x0;
    int y1 = y0 + 60;

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    bool anyInPlaneMoved = false;
    foreach (i; 0 .. 8) {
        auto p = vertexPos(i);
        double dx = p[0] - pre[i][0];
        double dy = p[1] - pre[i][1];
        double dz = p[2] - pre[i][2];
        if (plane == 4) {
            assert(approx(dz, 0.0, 1e-3),
                "v" ~ i.to!string ~ ".z moved on XY-plane drag: dz=" ~ dz.to!string);
            if (fabs(dx) > 0.05 || fabs(dy) > 0.05) anyInPlaneMoved = true;
        } else if (plane == 5) {
            assert(approx(dx, 0.0, 1e-3),
                "v" ~ i.to!string ~ ".x moved on YZ-plane drag: dx=" ~ dx.to!string);
            if (fabs(dy) > 0.05 || fabs(dz) > 0.05) anyInPlaneMoved = true;
        } else {
            assert(approx(dy, 0.0, 1e-3),
                "v" ~ i.to!string ~ ".y moved on XZ-plane drag: dy=" ~ dy.to!string);
            if (fabs(dx) > 0.05 || fabs(dz) > 0.05) anyInPlaneMoved = true;
        }
    }
    assert(anyInPlaneMoved,
        "no vertex moved in plane " ~ plane.to!string ~ " — plane-circle hit-test likely missed");
}

unittest { // XY plane drag moves in X+Y, leaves Z alone
    runMovePlaneDrag(4);
}

unittest { // YZ plane drag moves in Y+Z, leaves X alone
    runMovePlaneDrag(5);
}

unittest { // XZ plane drag moves in X+Z, leaves Y alone
    runMovePlaneDrag(6);
}
