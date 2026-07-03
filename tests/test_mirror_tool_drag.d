// Interactive drag coverage for the Mirror tool's Center handle (M2 of task
// 0227): dragging the mover's axis arrow (axisDragDelta path) and its
// center box (planeDragDelta path) both write into params_.center, and the
// panel/tool.attr `center` field tracks the drag live.

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
// 1. Drag the X arrow — axis-constrained: only center.x should move.
// ---------------------------------------------------------------------------

unittest {
    resetForMirrorCamera();

    auto vp = viewportFromCamera(fetchCamera(BASE));
    float size = gizmoSize(Vec3(0, 0, 0), vp);
    // A point along the arrowX shaft (start..end = size/6..size), well clear
    // of the center box so the hit-test picks the arrow, not the box.
    Vec3 grabPoint = Vec3(size * 0.5f, 0, 0);

    dragWorldHandle(grabPoint, Vec3(1, 0, 0));

    auto c = queriedCenter();
    assert(c.x > 0.05, "dragging the X arrow should move center.x, got " ~ c.x.to!string);
    assert(approx(c.y, 0.0), "X-arrow drag must not move center.y, got " ~ c.y.to!string);
    assert(approx(c.z, 0.0), "X-arrow drag must not move center.z, got " ~ c.z.to!string);

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
