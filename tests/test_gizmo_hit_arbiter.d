// The transform gizmo's one hit pass (task 9409), through the shipped presets.
//
// A  bare Transform: the arbiter's miss stands. The move bank's plane circles
//    are not registered there (and not drawn), so a press on the XY circle's
//    spot must not start a plane drag — the bank takes the arbiter's miss and
//    runs no test of its own (the hit pass is the draw pass).
//    The same holds where only the centre disc is drawn: the uniform-scale
//    preset registers the disc alone, so a press on an axis arm's spot
//    starts no axis scale.
// B  Move: the overlap law reaches production (capture K-HO, press M_Xf_onZ).
//    A hover <= 0.5 px from the Z shaft and 3.5..4.5 px from the X shaft makes
//    Z hot, although X is registered first — the factory's `nearestOnScreen`.

import http_client : getJson, postJson, testBaseUrl;
import http_command_helpers : commandBody;
import std.format : format;
import std.json;
import std.math : sqrt;
import http_client : post = keepAlivePost;

import drag_helpers : playAndWait, fetchCamera, viewportFromCameraMatrices,
                      projectToWindow, gizmoSize, Vec3, Viewport;

void main() {}

// Restated from handles/gizmo_metrics.d: the move arm runs from a fifth of the
// gizmo size to the full size; a plane circle sits 0.8 along both of its axes.
private enum float ARM_START = 0.2f, ARM_END = 1.0f, PLANE_OFFSET = 0.8f;

private void cmd(string script) { post(testBaseUrl() ~ "/api/script", script); }

private string header() {
    auto c = fetchCamera();
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
                  c.vpX, c.vpY, c.width, c.height);
}

private void hover(int x, int y) {
    string log = header();
    foreach (i; 0 .. 5)
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
                      50.0 + i * 20.0, x, y);
    playAndWait(log);
}

private void button(string type, int x, int y) {
    playAndWait(header() ~ format(`{"t":50.000,"type":"%s","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
                                  type, x, y));
}

private Vec3 pivot() {
    auto p = getJson("/api/tool/state")["pivot"].array;
    return Vec3(cast(float)p[0].floating, cast(float)p[1].floating, cast(float)p[2].floating);
}

private void setUp(string camera) {
    postJson("/api/command", commandBody("scene.reset"));
    postJson("/api/camera", camera);
    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`));
}

// Screen distance from (x, y) to the projected segment a..b.
private double segDist(double x, double y, float[2] a, float[2] b) {
    double dx = b[0] - a[0], dy = b[1] - a[1];
    double t = ((x - a[0]) * dx + (y - a[1]) * dy) / (dx * dx + dy * dy);
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    double ex = a[0] + t * dx - x, ey = a[1] + t * dy - y;
    return sqrt(ex * ex + ey * ey);
}

private float[2] screenOf(Vec3 w, const ref Viewport vp) {
    float x, y;
    assert(projectToWindow(w, vp, x, y), format("%s projects off-camera", w));
    return [x, y];
}

unittest { // A: bare Transform, a press on the unregistered XY circle's spot
    setUp(`{"azimuth":0.785,"elevation":0.6,"distance":3.2}`);
    cmd("tool.set Transform on");
    scope(exit) cmd("tool.set Transform off");
    auto vp = viewportFromCameraMatrices();
    immutable Vec3 c = pivot();
    immutable float s = gizmoSize(c, vp);
    auto at = screenOf(Vec3(c.x + s * PLANE_OFFSET, c.y + s * PLANE_OFFSET, c.z), vp);
    immutable int x = cast(int)at[0], y = cast(int)at[1];
    hover(x, y);
    assert(getJson("/api/tool/handles")["handles"]["hot"].integer == -1,
        format("rig: the circle spot (%d, %d) must be off every registered part", x, y));
    button("SDL_MOUSEBUTTONDOWN", x, y);
    immutable long axis = getJson("/api/tool/state")["dragAxis"].integer;
    button("SDL_MOUSEBUTTONUP", x, y);
    assert(axis < 4, format("a press on the undrawn XY circle (%d, %d) started plane drag %d", x, y, axis));
}

unittest { // A: the uniform-scale preset, a press on the undrawn X arm
    setUp(`{"azimuth":0.785,"elevation":0.6,"distance":3.2}`);
    cmd("tool.set xfrm.scaleUniform on");
    scope(exit) cmd("tool.set xfrm.scaleUniform off");
    auto vp = viewportFromCameraMatrices();
    immutable Vec3 c = pivot();
    auto at = screenOf(Vec3(c.x + gizmoSize(c, vp) * 0.6f, c.y, c.z), vp);
    immutable int x = cast(int)at[0], y = cast(int)at[1];
    hover(x, y);
    assert(getJson("/api/tool/handles")["handles"]["hot"].integer == -1,
        format("rig: the arm spot (%d, %d) must be off the registered disc", x, y));
    button("SDL_MOUSEBUTTONDOWN", x, y);
    immutable long axis = getJson("/api/tool/state")["dragAxis"].integer;
    button("SDL_MOUSEBUTTONUP", x, y);
    assert(axis < 0 || axis > 2, format("a press on the undrawn X arm (%d, %d) started axis scale %d", x, y, axis));
}

unittest { // B: Move, the K-HO press M_Xf_onZ makes the nearer Z shaft hot
    setUp(`{"azimuth":2.356194,"elevation":0.044521,"distance":3.0}`);
    cmd("tool.set move");
    scope(exit) cmd("tool.set move off");
    auto vp = viewportFromCameraMatrices();
    immutable Vec3 c = pivot();
    immutable float s = gizmoSize(c, vp);
    auto x0 = screenOf(Vec3(c.x + s * ARM_START, c.y, c.z), vp), x1 = screenOf(Vec3(c.x + s * ARM_END, c.y, c.z), vp);
    auto z0 = screenOf(Vec3(c.x, c.y, c.z + s * ARM_START), vp), z1 = screenOf(Vec3(c.x, c.y, c.z + s * ARM_END), vp);
    int px = -1, py = -1;
    foreach (y; 0 .. vp.height + vp.y) foreach (x; 0 .. vp.width + vp.x) {
        if (px >= 0) break;
        immutable dz = segDist(x, y, z0, z1), dx = segDist(x, y, x0, x1);
        if (dz <= 0.5 && dx >= 3.5 && dx <= 4.5) { px = x; py = y; }
    }
    assert(px >= 0, "rig: no press 0.5 px from the Z shaft and 3.5..4.5 px from X");
    hover(px, py);
    immutable long hot = getJson("/api/tool/handles")["handles"]["hot"].integer;
    assert(hot == 2, format("press (%d, %d): the Z shaft is nearer on screen and must be hot, got part %d",
                            px, py, hot));
}
