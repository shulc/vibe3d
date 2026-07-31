// Interactive drag coverage for the Radial Sweep tool's Start Angle handle.
//
// tests/test_fixture_radial_sweep.d drives this tool through parameters only;
// nothing in the suite had ever entered its MOTION path, which is where the
// per-event pixel increment lives. That increment now takes its previous pixel
// from the cooked gesture and cross-checks it against the tool's own, so it
// needs a test that reaches it.
//
// This tool consumes nothing when the press misses every handle, so
// `startAngle` moving off zero is by itself evidence that the press hit and
// the increment branch ran.
//
// Handle geometry, at the defaults (axis +Y, centre at the origin, start angle
// 0): the reference direction is -Z and the arm is 0.7 * gizmoSize, so the
// Start Angle handle sits at (0,0,-arm) and the direction it travels in as the
// angle grows — the live rotational tangent, axis x (pos - centre) — is -X.
// The End Angle handle defaults to 360 degrees, which lands it on the same
// point; the hit test tries Start first, so that is the one this drag grabs.

import std.conv : to;
import std.json;
import std.math : abs;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "mesh.radialSweepTool";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double queryStartAngle() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " startAngle ?");
    assert(r["status"].str == "ok", "query startAngle failed: " ~ r.toString);
    return r["value"].floating;
}

unittest { // dragging the Start Angle handle moves `startAngle` off zero
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    r = postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");

    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(200));

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 centre  = Vec3(0.0f, 0.0f, 0.0f);
    float arm    = gizmoSize(centre, vp) * 0.7f;
    Vec3 handle  = Vec3(0.0f, 0.0f, -arm);      // centre + refDir * arm
    Vec3 tangent = Vec3(-1.0f, 0.0f, 0.0f);     // live rotational tangent there

    float hx, hy, tx, ty;
    assert(projectToWindow(handle, vp, hx, hy), "handle projects behind camera");
    assert(projectToWindow(handle + tangent, vp, tx, ty),
        "handle + tangent projects behind camera");
    double dx = tx - hx, dy = ty - hy;
    double len = (dx * dx + dy * dy) ^^ 0.5;
    assert(len > 1e-6, "the handle tangent projects to a point");

    int x0 = cast(int) hx, y0 = cast(int) hy;
    int x1 = cast(int)(hx + dx / len * 80.0);
    int y1 = cast(int)(hy + dy / len * 80.0);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 16), BASE);
    Thread.sleep(dur!"msecs"(120));

    double after = queryStartAngle();
    assert(abs(after) > 0.5,
        "dragging the Start Angle handle should have moved startAngle off "
        ~ "zero — this tool consumes nothing when the press misses every "
        ~ "handle, so a zero here means the drag never began. Got "
        ~ after.to!string);

    cmd("tool.set " ~ TOOL ~ " off");
}
