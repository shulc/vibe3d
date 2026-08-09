// Interactive drag coverage for the Radial Array tool's Offset handle.
//
// tests/test_fixture_radial_array.d and tests/test_mesh_radial_array.d drive
// this tool through parameters only; nothing in the suite had ever entered its
// MOTION path, which is where the per-event pixel increment lives. That
// increment now takes its previous pixel from the cooked gesture and
// cross-checks it against the tool's own, so it needs a test that reaches it.
//
// A press that misses both handles is not ignored here — it REPOSITIONS the
// rotation centre — but it does not touch `offset`, so `offset` moving off
// zero is evidence that the press hit the offset arrow and the increment ran.
//
// The press point is reconstructed from the arrow's own geometry rather than
// read off /api/tool/handles: with the default Y axis and a centre at the
// origin, the shaft runs from centre + Y*(arm/6) to centre + Y*arm. (The tool
// does now override toolHandlesJson — task 0660 — so the registry is readable
// here too; this test's independent reconstruction is left as it was, since it
// is what makes a geometry change fail loudly instead of silently following.)

import std.conv : to;
import std.json;
import std.math : abs;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "mesh.radialArrayTool";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double queryOffset() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " offset ?");
    assert(r["status"].str == "ok", "query offset failed: " ~ r.toString);
    return r["value"].floating;
}

unittest { // dragging the offset arrow moves `offset` off zero
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    r = postJson("/api/select", `{"mode":"polygons","indices":[4]}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");

    // Settle so a draw() frame has registered the handles the press
    // hit-tests against. 0.6*arm lands mid-shaft.
    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(200));

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 anchor = Vec3(0.0f, 0.0f, 0.0f);
    Vec3 axis   = Vec3(0.0f, 1.0f, 0.0f);
    float arm   = gizmoSize(anchor, vp);
    Vec3 press  = anchor + axis * (arm * 0.6f);

    float ax, ay, tx, ty, px, py;
    assert(projectToWindow(anchor, vp, ax, ay), "anchor projects behind camera");
    assert(projectToWindow(anchor + axis, vp, tx, ty),
        "centre + Y projects behind camera");
    assert(projectToWindow(press, vp, px, py), "shaft mid-point is off-camera");
    double dx = tx - ax, dy = ty - ay;
    double len = (dx * dx + dy * dy) ^^ 0.5;
    assert(len > 1e-6, "the offset axis projects to a point");

    int x0 = cast(int) px, y0 = cast(int) py;
    int x1 = cast(int)(px + dx / len * 80.0);
    int y1 = cast(int)(py + dy / len * 80.0);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 16), BASE);
    Thread.sleep(dur!"msecs"(120));

    double after = queryOffset();
    assert(abs(after) > 1e-3,
        "dragging the offset arrow should have moved offset off zero — a "
        ~ "press that missed the handles only repositions the centre and "
        ~ "leaves offset alone. Got " ~ after.to!string);

    cmd("tool.set " ~ TOOL ~ " off");
}
