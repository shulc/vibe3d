// Interactive drag coverage for the Mirror tool's Center handle. Task 0233
// REMOVED the axis arrows from the Mirror gizmo (reference = 2 boxes + plane,
// no arrows), so center MOVE now runs only through the center box
// (planeDragDelta path), and a click where the old arrow shaft used to be is a
// free click-to-place relocation — no longer an axis-locked arrow drag.

import std.conv : to;
import std.json;
import std.math : abs;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "mesh.mirrorTool";

JSONValue getJson(string path) { return parseJSON(cast(string) get(BASE ~ path)); }

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double qf(string attr) {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "query " ~ attr ~ " failed: " ~ r.toString);
    return r["value"].floating;
}

Vec3 queriedCenter() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " center ?");
    assert(r["status"].str == "ok", "query center failed: " ~ r.toString);
    auto a = r["value"].array;
    return Vec3(cast(float) a[0].floating, cast(float) a[1].floating,
                cast(float) a[2].floating);
}

bool approx(double a, double b, double eps = 1e-3) { return abs(a - b) <= eps; }

void resetForMirrorCamera() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera set failed: " ~ r.toString);
    cmd("tool.set " ~ TOOL);
}

void dragWorldHandle(Vec3 handle, Vec3 axis, double pixels = 80.0, int steps = 16) {
    auto vp = viewportFromCamera(fetchCamera(BASE));
    float hx, hy, ax, ay;
    assert(projectToWindow(handle, vp, hx, hy), "handle projects behind camera");
    assert(projectToWindow(handle + axis, vp, ax, ay), "axis projects behind camera");
    double dx = ax - hx;
    double dy = ay - hy;
    double len = (dx * dx + dy * dy) ^^ 0.5;
    assert(len > 1e-6, "projected handle axis is degenerate");
    int x0 = cast(int) hx;
    int y0 = cast(int) hy;
    int x1 = cast(int)(hx + dx / len * pixels);
    int y1 = cast(int)(hy + dy / len * pixels);
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, steps), BASE);
    import core.thread : Thread;
    import core.time : dur;
    Thread.sleep(dur!"msecs"(120));
}

// ---------------------------------------------------------------------------
// 1. The axis arrows are GONE (task 0233). A drag that begins where the old X
//    arrow shaft used to be no longer hits an axis handle — it misses every
//    handle and falls through to click-to-place, which relocates the center to
//    the cursor's screen-projected point on the screen-facing plane through the
//    current center. So the OLD axis-constrained signature (center.x moves,
//    center.y/z stay exactly 0) must NO LONGER hold: the relocation is a free
//    screen-plane point that generally leaves the X axis. This is the
//    regression guard that the arrows were truly removed (not merely hidden).
// ---------------------------------------------------------------------------

unittest {
    resetForMirrorCamera();

    auto vp = viewportFromCamera(fetchCamera(BASE));
    float size = gizmoSize(Vec3(0, 0, 0), vp);
    // The former arrowX shaft location — now empty (no arrow handle there),
    // and well clear of the center box, so this click hits nothing.
    Vec3 grabPoint = Vec3(size * 0.5f, 0, 0);

    dragWorldHandle(grabPoint, Vec3(1, 0, 0));

    auto c = queriedCenter();
    // Center relocated (click-to-place fired) ...
    bool moved = abs(c.x) > 0.02 || abs(c.y) > 0.02 || abs(c.z) > 0.02;
    assert(moved, "a click at the former arrow location should relocate the center, got ("
        ~ c.x.to!string ~ "," ~ c.y.to!string ~ "," ~ c.z.to!string ~ ")");
    // ... and it is NOT an axis-locked X-only arrow move: with the arrow gone
    // the free screen-plane relocation leaves the X axis (y or z non-zero).
    assert(abs(c.y) > 1e-3 || abs(c.z) > 1e-3,
        "arrows removed (task 0233): a drag at the old X-arrow spot must be a free "
        ~ "click-to-place, not an axis-locked X-only move; got ("
        ~ c.x.to!string ~ "," ~ c.y.to!string ~ "," ~ c.z.to!string ~ ")");

    cmd("tool.set " ~ TOOL ~ " off");
}

// ---------------------------------------------------------------------------
// 2. Drag the center box — free (screen-plane) drag: center should move.
// ---------------------------------------------------------------------------

unittest {
    resetForMirrorCamera();

    dragWorldHandle(Vec3(0, 0, 0), Vec3(1, 0, 0), 60.0);

    auto c = queriedCenter();
    bool moved = abs(c.x) > 0.02 || abs(c.y) > 0.02 || abs(c.z) > 0.02;
    assert(moved, "dragging the center box should move center, got ("
        ~ c.x.to!string ~ "," ~ c.y.to!string ~ "," ~ c.z.to!string ~ ")");

    cmd("tool.set " ~ TOOL ~ " off");
}
