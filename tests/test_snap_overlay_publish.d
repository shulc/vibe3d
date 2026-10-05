// The frame draws the published snap (`g_lastSnap`); a tool no longer draws a
// copy of its own. So the publish IS the overlay: a family that stops
// publishing its idle hover shows nothing, one that does not clear on its drop
// leaves a stale mark. Idle hover per family (findings_O O1: with snap on, the
// hover target is marked in idle), presses, a held drag, read through
// /api/snap/last.

import http_client : testBaseUrl, postJson;
import http_command_helpers : commandBody;
import std.format : format;
import std.json;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;

private void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

private CameraState cam_;

/// `tool` armed over the default cube, vertex snap at an unbounded range; an
/// upper-left pixel, off every gizmo (a part under the pointer suppresses the
/// transform preview).
private void arm(string tool, out int x, out int y) {
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":0.5,"distance":6.0,"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    foreach (line; ["tool.set " ~ tool, "tool.pipe.attr snap enabled true", "tool.pipe.attr snap types vertex",
                    "tool.pipe.attr snap innerRange 999999", "tool.pipe.attr snap outerRange 999999"])
        cmd(line);
    cam_ = fetchCamera(BASE);
    x = cam_.vpX + cast(int)(cam_.width * 0.06);
    y = cam_.vpY + cast(int)(cam_.height * 0.06);
}

private void down(int x, int y, uint mod = 0) {
    playAndWait(buildDragDownLog(cam_.vpX, cam_.vpY, cam_.width, cam_.height, x, y, mod), BASE);
}
private void moveTo(int x0, int y0, int x1, int y1) {
    playAndWait(buildDragMotionLog(cam_.vpX, cam_.vpY, cam_.width, cam_.height, x0, y0, x1, y1, 2), BASE);
}
private void up(int x, int y, uint mod = 0) {
    playAndWait(buildDragUpLog(cam_.vpX, cam_.vpY, cam_.width, cam_.height, x, y, mod), BASE);
}

/// Idle hover (motion only, no button) with `tool` armed.
private JSONValue hoverWith(string tool) {
    int x, y;
    arm(tool, x, y);
    playAndWait(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":50.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":3,"yrel":3,"state":0,"mod":0}` ~ "\n"
      ~ `{"t":70.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":1,"yrel":0,"state":0,"mod":0}`,
        cam_.vpX, cam_.vpY, cam_.width, cam_.height, x, y, x + 1, y), BASE);
    return fetchSnapLast(BASE);
}

private bool isVertexSnap(JSONValue s) {
    return s["highlighted"].type == JSONType.true_ && s["snapped"].type == JSONType.true_
        && s["targetType"].integer == 1;
}

private immutable string[] families = ["prim.cube", "prim.sphere", "prim.vertex", "move", "rotate",
                                       "scale", "xfrm.transform"];

unittest { // every snapping family publishes its idle hover, and its drop clears it
    assert(families.length == 7);
    foreach (tool; families) {
        auto s = hoverWith(tool);
        assert(isVertexSnap(s), tool ~ ": the idle hover must publish a vertex snap, got " ~ s.toString);
        cmd("tool.set " ~ tool ~ " off");
        s = fetchSnapLast(BASE);
        assert(s["highlighted"].type == JSONType.false_,
            tool ~ ": a dropped tool's snap must not stay drawn: " ~ s.toString);
    }
}

unittest { // a press the tool does not take (an Alt orbit) retires the hover's snap
    auto s = hoverWith("move");
    assert(isVertexSnap(s), "control: the hover published");
    int x, y;
    x = cam_.vpX + cast(int)(cam_.width * 0.06); y = cam_.vpY + cast(int)(cam_.height * 0.06);
    enum uint KMOD_LALT = 0x0100;
    down(x, y, KMOD_LALT);
    s = fetchSnapLast(BASE);
    up(x, y, KMOD_LALT);
    assert(s["highlighted"].type == JSONType.false_,
        "an orbit press must not leave the hover's mark to turn into the drag cross: " ~ s.toString);
}

unittest { // a press publishes before any motion: placement and relocate
    foreach (tool; ["prim.vertex", "move"]) {
        int x, y;
        arm(tool, x, y);
        down(x, y);
        auto s = fetchSnapLast(BASE);
        up(x, y);
        assert(isVertexSnap(s), tool ~ ": the press must publish its snap, got " ~ s.toString);
    }
}

unittest { // a held handle drag publishes as it moves; the release clears it
    int x, y;
    arm("move", x, y);
    cmd("tool.set move off");   // select v0, then re-arm: the gizmo sits on it
    auto r = postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0]}`));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);
    cmd("tool.set move");
    // The X arrow's shaft (the press does not relocate, so it publishes
    // nothing), dragged toward v1.
    auto vp = viewportFromCamera(cam_);
    immutable Vec3 pivot = Vec3(-0.5f, -0.5f, -0.5f);
    immutable float size = gizmoSize(pivot, vp);
    float ax, ay, bx, by;
    assert(projectToWindow(Vec3(pivot.x + size * 0.6f, pivot.y, pivot.z), vp, ax, ay)
        && projectToWindow(Vec3(0.5f, -0.5f, -0.5f), vp, bx, by), "drag rig off camera");
    immutable int x0 = cast(int)ax, y0 = cast(int)ay, x1 = cast(int)bx, y1 = cast(int)by;
    down(x0, y0);
    assert(fetchSnapLast(BASE)["highlighted"].type == JSONType.false_,
        "control: the handle press published a snap, so the drag cell cannot tell");
    moveTo(x0, y0, x1, y1);
    auto held = fetchSnapLast(BASE);
    up(x1, y1);
    auto released = fetchSnapLast(BASE);
    assert(isVertexSnap(held), "the drag must publish its snap, got " ~ held.toString);
    assert(released["highlighted"].type == JSONType.false_,
        "the release must clear the drag's snap: " ~ released.toString);
}

unittest { // a switch away (not a drop) clears the vertex tool's hover through its door
    auto s = hoverWith("prim.vertex");
    assert(isVertexSnap(s), "control: the hover published");
    cmd("tool.set prim.cube");
    s = fetchSnapLast(BASE);
    assert(s["highlighted"].type == JSONType.false_,
        "prim.vertex: a switch away must clear its snap: " ~ s.toString);
}
