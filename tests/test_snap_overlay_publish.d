// Task 9444 (OVL3): the frame draws the published snap (`g_lastSnap`); a tool
// no longer draws a copy of its own. So the publish IS the overlay: a family
// that stops publishing its idle hover shows nothing. One idle-hover cell per
// family (findings_O O1: with snap on, the hover target is marked in idle),
// read through /api/snap/last, then the clear on a tool switch.

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

/// `tool` armed over the default cube, vertex snap at an unbounded range;
/// returns the viewport header and an upper-left pixel, off every gizmo (a
/// part under the pointer suppresses the transform preview).
private string arm(string tool, out int x, out int y) {
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":0.5,"distance":6.0,"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    cmd("tool.set " ~ tool);
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types vertex");
    cmd("tool.pipe.attr snap innerRange 999999");
    cmd("tool.pipe.attr snap outerRange 999999");
    auto cam = fetchCamera(BASE);
    x = cam.vpX + cast(int)(cam.width * 0.06);
    y = cam.vpY + cast(int)(cam.height * 0.06);
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                  cam.vpX, cam.vpY, cam.width, cam.height) ~ "\n";
}

private string ev(double t, string type, int x, int y) {
    return type == "SDL_MOUSEMOTION"
        ? format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":3,"yrel":3,"state":%d,"mod":0}`,
                 t, x, y, 0) ~ "\n"
        : format(`{"t":%.3f,"type":"%s","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, t, type, x, y) ~ "\n";
}

/// Idle hover (motion only, no button) with `tool` armed.
private JSONValue hoverWith(string tool) {
    int x, y;
    const head = arm(tool, x, y);
    playAndWait(head ~ ev(50, "SDL_MOUSEMOTION", x, y) ~ ev(70, "SDL_MOUSEMOTION", x + 1, y), BASE);
    return fetchSnapLast(BASE);
}

private bool isVertexSnap(JSONValue s) {
    return s["highlighted"].type == JSONType.true_ && s["snapped"].type == JSONType.true_
        && s["targetType"].integer == 1;
}

unittest { // every snapping family publishes its idle hover
    string[] families = ["prim.cube", "prim.sphere", "prim.vertex", "move", "rotate", "scale",
                         "xfrm.transform"];
    assert(families.length == 7);
    foreach (tool; families) {
        auto s = hoverWith(tool);
        assert(isVertexSnap(s), tool ~ ": the idle hover must publish a vertex snap, got " ~ s.toString);
    }
}

unittest { // a tool switch clears what the last tool published
    auto s = hoverWith("prim.sphere");
    assert(s["highlighted"].type == JSONType.true_, "control: the hover published");
    cmd("tool.set prim.sphere off");
    s = fetchSnapLast(BASE);
    assert(s["highlighted"].type == JSONType.false_,
        "a dropped tool's snap must not stay drawn: " ~ s.toString);
}

unittest { // a press publishes before any motion: placement and relocate
    foreach (tool; ["prim.vertex", "move"]) {
        int x, y;
        const head = arm(tool, x, y);
        playAndWait(head ~ ev(50, "SDL_MOUSEBUTTONDOWN", x, y), BASE);
        auto s = fetchSnapLast(BASE);
        playAndWait(head ~ ev(50, "SDL_MOUSEBUTTONUP", x, y), BASE);
        assert(isVertexSnap(s), tool ~ ": the press must publish its snap, got " ~ s.toString);
    }
}

unittest { // a held handle drag publishes as it moves; the release clears it
    int x, y;
    const head = arm("move", x, y);
    cmd("tool.set move off");   // select v0, then re-arm: the gizmo sits on it
    auto r = postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0]}`));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);
    cmd("tool.set move");
    // The X arrow's shaft (the press does not relocate, so it publishes
    // nothing), dragged toward v1.
    auto vp = viewportFromCamera(fetchCamera(BASE));
    immutable Vec3 pivot = Vec3(-0.5f, -0.5f, -0.5f);
    immutable float size = gizmoSize(pivot, vp);
    float ax, ay, bx, by;
    assert(projectToWindow(Vec3(pivot.x + size * 0.6f, pivot.y, pivot.z), vp, ax, ay)
        && projectToWindow(Vec3(0.5f, -0.5f, -0.5f), vp, bx, by), "drag rig off camera");
    immutable int x0 = cast(int)ax, y0 = cast(int)ay, x1 = cast(int)bx, y1 = cast(int)by;
    playAndWait(head ~ ev(50, "SDL_MOUSEBUTTONDOWN", x0, y0), BASE);
    assert(fetchSnapLast(BASE)["highlighted"].type == JSONType.false_,
        "control: the handle press published a snap, so the drag cell cannot tell");
    playAndWait(head ~ ev(70, "SDL_MOUSEMOTION", (x0 + x1) / 2, (y0 + y1) / 2)
                     ~ ev(90, "SDL_MOUSEMOTION", x1, y1), BASE);
    auto held = fetchSnapLast(BASE);
    playAndWait(head ~ ev(110, "SDL_MOUSEBUTTONUP", x1, y1), BASE);
    auto released = fetchSnapLast(BASE);
    assert(isVertexSnap(held), "the drag must publish its snap, got " ~ held.toString);
    assert(released["highlighted"].type == JSONType.false_,
        "the release must clear the drag's snap: " ~ released.toString);
}
