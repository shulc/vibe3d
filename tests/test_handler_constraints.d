// Handler-constraint tests (Stage A5 of doc/test_coverage_plan.md).
//
// Two interactive paths the move gizmo has beyond axis-arrow / plane-circle
// drags:
//
//   1. Ctrl + drag on the centerBox — the tool first waits for a screen
//      delta > 5 px to decide which of the two in-plane axes the user
//      meant, then locks the drag onto it (MoveTool.ctrlConstrain in
//      source/tools/move.d). Without this the centerBox would be a free
//      plane-drag; the Ctrl gate snaps it to the closer world axis.
//
//   2. Click outside the gizmo — when ACEN allows it (Auto / None /
//      Screen), the gizmo relocates to the click projected onto the
//      most-facing world plane and the drag continues in that plane
//      (MoveTool.onMouseButtonDown's relocate branch + planeDragDelta
//      dragAxis==3). Asserts here pin the "click in empty space then
//      drag still moves the mesh" behaviour that's easy to break when
//      reworking ACEN.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;

import drag_helpers;

void main() {}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

// SDL_Keymod KMOD_CTRL = 0x00C0 (KMOD_LCTRL | KMOD_RCTRL). Encoded
// here so the helper module stays free of an SDL dependency.
enum uint MOD_CTRL = 0x00C0;

void resetCubeSelectAllMove() {
    post("http://localhost:8080/api/reset", "");
    auto selResp = post("http://localhost:8080/api/select",
                        `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(parseJSON(cast(string)selResp)["status"].str == "ok",
        "select failed: " ~ cast(string)selResp);
    auto setResp = post("http://localhost:8080/api/script", "tool.set move");
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
        "tool.set move failed: " ~ cast(string)setResp);
}

unittest { // Ctrl + centerBox drag locks to the closest world axis
    resetCubeSelectAllMove();

    double[3][8] pre;
    foreach (i; 0 .. 8) pre[i] = vertexPos(i);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // centerBox sits at pivot (origin); its half-extent is gizmoSize*0.04
    // so the projected box is only ~3.6 px wide. Click on the projected
    // pivot itself — pointInPolygon2D against the box's six projected
    // quads catches that as a hit reliably.
    float cx, cy;
    assert(projectToWindow(Vec3(0, 0, 0), vp, cx, cy),
        "pivot projects off-camera");
    int x0 = cast(int)cx;
    int y0 = cast(int)cy;

    // Drag 80 px screen-right. The first 5 px get absorbed by the
    // ctrlConstrain deadzone, then the tool picks whichever in-plane
    // axis projects closest to the +X screen direction and locks to it.
    // With default camera (az=0.5 el=0.4) the most-facing world plane is
    // XY (Z is most aligned with camera back), and on screen world +X
    // projects near horizontal — the lock should pick world X.
    int x1 = x0 + 80;
    int y1 = y0;

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20, MOD_CTRL);
    playAndWait(log);

    int movedAxes = 0;
    double maxDx = 0, maxDy = 0, maxDz = 0;
    foreach (i; 0 .. 8) {
        auto p = vertexPos(i);
        double dx = fabs(p[0] - pre[i][0]);
        double dy = fabs(p[1] - pre[i][1]);
        double dz = fabs(p[2] - pre[i][2]);
        if (dx > maxDx) maxDx = dx;
        if (dy > maxDy) maxDy = dy;
        if (dz > maxDz) maxDz = dz;
    }
    if (maxDx > 0.05) movedAxes++;
    if (maxDy > 0.05) movedAxes++;
    if (maxDz > 0.05) movedAxes++;
    assert(movedAxes == 1,
        "Ctrl-constrain should pick exactly one world axis; got " ~
        movedAxes.to!string ~ " axes moved (maxDx=" ~ maxDx.to!string ~
        " maxDy=" ~ maxDy.to!string ~ " maxDz=" ~ maxDz.to!string ~ ")");
}

unittest { // click outside gizmo relocates + drags in most-facing plane
    resetCubeSelectAllMove();

    double[3][8] pre;
    foreach (i; 0 .. 8) pre[i] = vertexPos(i);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // Find a screen point well outside any gizmo handle. The right edge
    // of the X-arrow lies at world (size, 0, 0); push the click point
    // 3× past that along the projected axis direction so we're nowhere
    // near the arrow, the centerBox, or any plane circle.
    Vec3 pivot   = Vec3(0, 0, 0);
    float size   = gizmoSize(pivot, vp);
    Vec3 arrowEnd = Vec3(pivot.x + size, pivot.y, pivot.z);
    float px, py, ex, ey;
    assert(projectToWindow(pivot,    vp, px, py), "pivot off-camera");
    assert(projectToWindow(arrowEnd, vp, ex, ey), "arrow end off-camera");
    double dxAx = ex - px, dyAx = ey - py;
    double len  = sqrt(dxAx*dxAx + dyAx*dyAx);
    int x0 = cast(int)(px + 3.0 * dxAx);  // far past the arrow tip
    int y0 = cast(int)(py + 3.0 * dyAx);

    int x1 = x0 + 60;
    int y1 = y0;

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    // Click-outside Auto-mode behaviour: relocate gizmo, then drag in
    // the most-facing world plane. The drag is plane-locked, so the
    // mesh must move SOMEWHERE — the exact axes depend on which plane
    // ACEN picked. Just check the mesh moved overall and stayed rigid.
    double maxMove = 0;
    foreach (i; 0 .. 8) {
        auto p = vertexPos(i);
        double dx = p[0] - pre[i][0];
        double dy = p[1] - pre[i][1];
        double dz = p[2] - pre[i][2];
        double m = sqrt(dx*dx + dy*dy + dz*dz);
        if (m > maxMove) maxMove = m;
    }
    assert(maxMove > 0.05,
        "click-outside fallback drag didn't move the mesh (maxMove=" ~
        maxMove.to!string ~
        ") — click probably landed back on a gizmo handle");

    // Translation should be uniform — every vertex shifts by the same
    // world delta (rigid plane drag, no scaling).
    auto p0    = vertexPos(0);
    double dx0 = p0[0] - pre[0][0];
    double dy0 = p0[1] - pre[0][1];
    double dz0 = p0[2] - pre[0][2];
    foreach (i; 1 .. 8) {
        auto p = vertexPos(i);
        double dx = p[0] - pre[i][0];
        double dy = p[1] - pre[i][1];
        double dz = p[2] - pre[i][2];
        assert(approx(dx, dx0, 1e-4) &&
               approx(dy, dy0, 1e-4) &&
               approx(dz, dz0, 1e-4),
            "v" ~ i.to!string ~
            " shifted differently from v0 — non-rigid translation: " ~
            "v0Δ=(" ~ dx0.to!string ~ "," ~ dy0.to!string ~ "," ~
            dz0.to!string ~ ") v" ~ i.to!string ~ "Δ=(" ~
            dx.to!string ~ "," ~ dy.to!string ~ "," ~ dz.to!string ~ ")");
    }
}
