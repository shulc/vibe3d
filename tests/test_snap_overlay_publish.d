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

/// Idle hover (motion only, no button) with `tool` armed over the default
/// cube and vertex snap at an unbounded range.
private JSONValue hoverWith(string tool) {
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
    // Upper-left of the viewport: off every gizmo (a part under the pointer
    // suppresses the transform preview); the unbounded range still snaps.
    auto cam = fetchCamera(BASE);
    immutable int x = cam.vpX + cast(int)(cam.width * 0.06);
    immutable int y = cam.vpY + cast(int)(cam.height * 0.06);
    playAndWait(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":50.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":3,"yrel":3,"state":0,"mod":0}` ~ "\n"
      ~ `{"t":70.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":1,"yrel":0,"state":0,"mod":0}`,
        cam.vpX, cam.vpY, cam.width, cam.height, x, y, x + 1, y), BASE);
    return fetchSnapLast(BASE);
}

unittest { // every snapping family publishes its idle hover
    string[] families = ["prim.cube", "prim.sphere", "prim.vertex", "move", "rotate", "scale",
                         "xfrm.transform"];
    assert(families.length == 7);
    foreach (tool; families) {
        auto s = hoverWith(tool);
        assert(s["highlighted"].type == JSONType.true_ && s["snapped"].type == JSONType.true_
            && s["targetType"].integer == 1,
            tool ~ ": the idle hover must publish a vertex snap, got " ~ s.toString);
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
