// Interactive drag coverage for the Smooth Shift tool's handle drag.
//
// tests/test_smooth_shift.d drives this tool entirely through `tool.attr`
// + `tool.doApply`; nothing in the suite had ever entered its MOTION path. That
// path runs a per-event pixel increment which now takes its previous pixel from
// the cooked gesture and cross-checks it against the tool's own, so it needs a
// test that reaches it.
//
// Two details make this one different from the extrude pins:
//
//   * There is no off-handle fallback branch — a press that misses the arrow is
//     simply not consumed and no drag begins. So `inset` moving away from zero
//     is by itself proof that the press hit the handle and the increment ran.
//   * The press hit-test reads `queryMouse()`, not the event's own pixel, and
//     the override behind `queryMouse` is only updated on MOTION events. A drag
//     log that opens with the button-down would hit-test against a stale
//     cursor, so a hover motion is played first and given a frame to land.

import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "mesh.smoothShiftTool";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double queryShift() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " shift ?");
    assert(r["status"].str == "ok", "query shift failed: " ~ r.toString);
    return r["value"].floating;
}

// VIEWPORT + a single hover motion, so the cursor override the press
// hit-test reads is pointing at the handle before the button goes down.
string buildHoverLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`
        ~ "\n" ~
        `{"t":30.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
        ~ "\n",
        vpX, vpY, vpW, vpH, x, y);
}

unittest { // dragging the offset arrow moves `shift` off zero
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    // Face 4 is the cube's +Y face: centroid (0,0.5,0), normal +Y — so the
    // offset arrow is drawn straight up the world Y axis.
    r = postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");

    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(200));

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 anchor = Vec3(0.0f, 0.5f, 0.0f);
    Vec3 axis   = Vec3(0.0f, 1.0f, 0.0f);
    float arm   = gizmoSize(anchor, vp);
    Vec3 press  = anchor + axis * (arm * 0.6f);

    float ax, ay, tx, ty, px, py;
    assert(projectToWindow(anchor, vp, ax, ay), "anchor projects behind camera");
    assert(projectToWindow(anchor + axis, vp, tx, ty),
        "anchor + axis projects behind camera");
    assert(projectToWindow(press, vp, px, py), "shaft mid-point is off-camera");
    double dx = tx - ax, dy = ty - ay;
    double len = (dx * dx + dy * dy) ^^ 0.5;
    assert(len > 1e-6, "the offset axis projects to a point");

    int x0 = cast(int) px, y0 = cast(int) py;
    playAndWait(buildHoverLog(cam.vpX, cam.vpY, cam.width, cam.height, x0, y0), BASE);
    Thread.sleep(dur!"msecs"(150));

    int x1 = cast(int)(px + dx / len * 80.0);
    int y1 = cast(int)(py + dy / len * 80.0);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 16), BASE);
    Thread.sleep(dur!"msecs"(120));

    double after = queryShift();
    assert(abs(after) > 1e-3,
        "dragging the offset arrow should have moved shift off zero — this "
        ~ "tool consumes nothing when the press misses the handle, so a zero "
        ~ "here means the drag never began. Got " ~ after.to!string);

    cmd("tool.set " ~ TOOL ~ " off");
}
