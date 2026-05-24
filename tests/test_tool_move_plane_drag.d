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

unittest { // XY plane drag of all verts moves them in X+Y, leaves Z alone
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

    // circleXY sits at center + axisX*0.75 + axisY*0.75 with normal Z
    // (handler.d:MoveHandler.draw, cirOffset = size*0.75). Project that
    // point; its on-screen projection is a small disc and pointInPolygon2D
    // hit-tests against the 32-point projected ring — clicking on the
    // exact world center gives a comfortable margin.
    Vec3 circleCenter = Vec3(pivot.x + size * 0.75f,
                             pivot.y + size * 0.75f,
                             pivot.z);
    float cx, cy;
    assert(projectToWindow(circleCenter, vp, cx, cy),
        "circleXY center projects off-camera");
    int x0 = cast(int)cx;
    int y0 = cast(int)cy;

    // Drag screen-down by 60 px. With default camera (az=0.5, el=0.4),
    // screen-down translates to a mix of -X and -Y in world coords; the
    // exact split doesn't matter — what matters is that Z stays zero
    // because the XY plane constraint zeroes the normal component.
    int x1 = x0;
    int y1 = y0 + 60;

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    bool anyXYMoved = false;
    foreach (i; 0 .. 8) {
        auto p = vertexPos(i);
        double dz = p[2] - pre[i][2];
        // Z must not change in an XY-plane drag.
        assert(approx(dz, 0.0, 1e-3),
            "v" ~ i.to!string ~ ".z moved on XY-plane drag: dz=" ~
            dz.to!string ~ " (" ~ pre[i][2].to!string ~ " → " ~
            p[2].to!string ~ ")");

        double dx = p[0] - pre[i][0];
        double dy = p[1] - pre[i][1];
        if (fabs(dx) > 0.05 || fabs(dy) > 0.05) anyXYMoved = true;
    }
    assert(anyXYMoved,
        "no vertex moved in X or Y — plane-circle hit-test likely missed");
}
