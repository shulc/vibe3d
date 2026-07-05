// Slice tool (mesh.sliceTool) — RMB gap-adjust drag (task 0288).
//
// The owner observed that the reference Slice exposes `gap` as an RMB click+drag
// gizmo (with a dashed-circle + value HUD) and that gap works even WITHOUT the
// Split option. This test drives a REAL right-button mouse drag through
// /api/play-events (the interactive onMouseButtonDown/Motion/Up path) and asserts
// via /api/tool/state that:
//   (a) with no line yet, RMB does nothing (gap stays 0, no gap drag);
//   (b) after a line is drawn, an RMB rightward drag RAISES `gap` from 0 to a
//       positive value proportional to the horizontal travel, and the drag ends
//       cleanly (gapDragging false);
//   (c) that gap applies WITHOUT Split — the mesh opens into a connected channel
//       (a cube belt cut goes 12v/10f -> 16v/14f), NOT the disconnected split.
//
// The HUD dashed-circle + value text is a screen-space ImGui overlay (a UI
// affordance) that cannot be screenshotted headlessly; the gap VALUE + RMB-adjust
// LOGIC it visualises are covered here by data (tool state + geometry).

import std.net.curl;
import std.json;
import std.math  : fabs, sqrt;
import std.format : format;
import core.thread : Thread;
import core.time   : dur;

import drag_helpers;   // Vec3, Viewport, fetchCamera, viewportFromCamera, projectToWindow, buildDragLog, playAndWait

void main() {}

enum string BASE = "http://localhost:8080";

void cmd(string s) {
    auto resp = cast(string) post(BASE ~ "/api/command", s);
    assert(parseJSON(resp)["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ resp);
}
void resetCube() {
    auto resp = cast(string) post(BASE ~ "/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}
JSONValue getModel()     { return parseJSON(cast(string) get(BASE ~ "/api/model")); }
JSONValue getToolState() { return parseJSON(cast(string) get(BASE ~ "/api/tool/state")); }
size_t vertCount() { return getModel()["vertices"].array.length; }
size_t faceCount() { return getModel()["faces"].array.length; }
double gapOf()     { return getToolState()["gap"].floating; }
void settle() { Thread.sleep(dur!"msecs"(180)); }

void scr(Vec3 w, const ref Viewport vp, out int px, out int py) {
    float fx, fy;
    assert(projectToWindow(w, vp, fx, fy), "world point projected off-screen");
    px = cast(int)(fx + 0.5f);
    py = cast(int)(fy + 0.5f);
}

// The two in-plane world axes of the tool's auto construction plane (mirrors
// test_slice_input_model.inPlaneAxes). U = along the drawn line, V = across.
void inPlaneAxes(const ref Viewport vp, out Vec3 U, out Vec3 V) {
    Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    float ax = fabs(camBack.x), ay = fabs(camBack.y), az = fabs(camBack.z);
    if (ax >= ay && ax >= az)       { V = Vec3(0,1,0); U = Vec3(0,0,1); }
    else if (ay >= ax && ay >= az)  { V = Vec3(1,0,0); U = Vec3(0,0,1); }
    else                            { V = Vec3(1,0,0); U = Vec3(0,1,0); }
}

// A JSON-Lines RIGHT-button drag log: btn:3 down at (x0,y0), `steps` motion
// events interpolating to (x1,y1) (motion state = SDL_BUTTON_RMASK = 4), btn:3
// up. Mirrors drag_helpers.buildDragLog but on the right button so it drives the
// tool's RMB gap-adjust gesture. Motions are 50 ms apart (own-frame delivery).
string buildRmbDragLog(int vpX, int vpY, int vpW, int vpH,
                       int x0, int y0, int x1, int y1, int steps = 16) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    double tDown = 50.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        tDown, x0, y0);
    int lastX = x0, lastY = y0;
    foreach (i; 1 .. steps + 1) {
        int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / steps);
        int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / steps);
        double t = tDown + i * 50.0;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":4,"mod":0}` ~ "\n",
            t, x, y, x - lastX, y - lastY);
        lastX = x; lastY = y;
    }
    double tUp = tDown + (steps + 1) * 50.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        tUp, x1, y1);
    return log;
}

// Draw a mid-plane belt line along U (down = Start, drag = End), leaving a live
// single cut (12v/10f). Returns the viewport used.
Viewport drawBeltLine() {
    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 U, V; inPlaneAxes(vp, U, V);
    Vec3 A = U * (-0.6f), B = U * (0.6f);
    int ax, ay, bx, by;
    scr(A, vp, ax, ay); scr(B, vp, bx, by);
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, ax, ay, bx, by, 20, 0), BASE);
    settle();
    return vp;
}

// ---------------------------------------------------------------------------
// (a) With no line drawn, RMB does nothing (gap stays 0, tool not gap-dragging).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set mesh.sliceTool on");
    settle();
    assert(getToolState()["lineDrawn"].type == JSONType.FALSE, "no line at activation");
    assert(fabs(gapOf()) < 1e-6, "gap starts at 0");

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    // An RMB drag with no line: the tool declines it (no gap gizmo to grab).
    playAndWait(buildRmbDragLog(vp.x, vp.y, vp.width, vp.height, 400, 300, 520, 300), BASE);
    settle();
    assert(fabs(gapOf()) < 1e-6, "RMB with no line must not change gap");
    assert(getToolState()["gapDragging"].type == JSONType.FALSE, "no gap drag in flight");

    cmd("tool.set mesh.sliceTool off");
    settle();
}

// ---------------------------------------------------------------------------
// (b)+(c) After a line is drawn, an RMB rightward drag raises gap from 0 to a
//         positive value, the gap applies WITHOUT Split (a connected channel:
//         12v/10f -> 16v/14f), and the drag ends cleanly.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    assert(vertCount() == 8 && faceCount() == 6, "fresh cube 8v/6f");
    cmd("tool.set mesh.sliceTool on");
    settle();

    Viewport vp = drawBeltLine();
    assert(getToolState()["lineDrawn"].type == JSONType.TRUE, "belt line drawn");
    assert(vertCount() == 12 && faceCount() == 10,
           format("single cut before gap (12v/10f), got %dv/%df", vertCount(), faceCount()));
    assert(fabs(gapOf()) < 1e-6, "gap still 0 before the RMB drag");
    // Split is OFF (default) — the gap must apply without it.
    assert(getToolState()["split"].type == JSONType.FALSE, "split off by default");

    // RMB drag to the RIGHT by ~120 px from the line's screen midpoint: gap rises.
    int mx, my;
    scr(Vec3(0, 0, 0), vp, mx, my);
    playAndWait(buildRmbDragLog(vp.x, vp.y, vp.width, vp.height, mx, my, mx + 120, my), BASE);
    settle();

    double g = gapOf();
    assert(g > 0.05, format("RMB rightward drag must RAISE gap above 0, got %.4f", g));
    // px→world is ~0.005/px, so 120 px ≈ 0.6; assert a proportional (loose) range.
    assert(g > 0.2 && g < 1.2, format("gap should track the ~120 px travel (~0.6), got %.4f", g));
    assert(getToolState()["gapDragging"].type == JSONType.FALSE,
           "RMB up must end the gap drag");

    // Gap applied WITHOUT split → a CONNECTED channel: two parallel cuts, 16v/14f
    // (NOT the disconnected split, and NOT a no-op).
    assert(vertCount() == 16 && faceCount() == 14,
           format("gap-without-split opens a channel (16v/14f), got %dv/%df",
                  vertCount(), faceCount()));

    cmd("tool.set mesh.sliceTool off");
    settle();
}
