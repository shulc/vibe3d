// Edge Extend's rotate and scale bank presses (task 9468): the embedded banks
// are driven directly, so a press on a rotate ring or a scale arm reaches the
// bank's OWN hit test (`RotateTool` / `ScaleTool.onMouseButtonDown`), never
// the arbiter. Each cell presses a real handle and reads which part of which
// bank it took — the scale bank arms a plane scale (part 7) on a miss, and a
// rotate miss falls through to the haul, so a dead hit test shows as a wrong
// part or a wrong bank, never as "nothing happened".
//
// Rig: the plane rig's +X ridge edge (7, 8), a generic perspective camera (no
// ring is culled edge-on), one bank on. A motionless click on empty space
// opens the operation (no handle is drawn before it, gap 217); the handle then
// stands at the edge's mid (1, 0.5, 0) plus offset 0.

import edge_extend_gesture_helpers;
import http_client : getJson, postJson;
import drag_helpers : viewportFromCameraMatrices, projectToWindow, gizmoSize,
    cross, normalize, DV = Vec3, DViewport = Viewport;
import std.format : format;
import std.json;

void main() {}

enum DV kHandle = DV(1.0f, 0.5f, 0.0f);

void bankRig(string bank) {
    auto r = postJson("/api/command", `{"id":"scene.reset"}`);
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    loadPlaneRig();
    setSymmetryX(false);
    selectEdges(edgesOf([[7, 8]]));
    r = postJson("/api/camera", `{"azimuth":0.7,"elevation":0.5,"distance":5.0,"focus":{"x":0.5,"y":0.3,"z":0},"roll":0}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    assert(getJson("/api/camera")["projKind"].str != "Ortho", "rig premise: the view must be perspective");
    cmd("tool.set edge.extend on");
    cmd("tool.attr edge.extend moveHandle false");
    cmd("tool.attr edge.extend " ~ bank ~ "Handle true");
    cmd("history.clear");
    settle(250);
    auto c = viewCentre();
    click(Px(c.x - 300, c.y + 250));   // opens the operation, offset 0
    auto s = toolState();
    assert(s["runStarted"].type == JSONType.true_ && offset() == Offset(0, 0, 0),
        "rig: the opening click did not open a zero-offset operation: " ~ s.toString);
}

void assertGrabbed(Px p, string bank, int part, string what) {
    press(p);
    auto s = toolState();
    assert(s["dragBank"].str == bank && s["dragAxis"].integer == part,
        format("%s: the press at %s took bank %s part %s, expected %s part %d (%s)",
            what, p, s["dragBank"].str, s["dragAxis"], bank, part, s.toString));
    release(p);
}

unittest { // the scale bank's X arm
    bankRig("scale");
    auto h = getJson("/api/tool/handles")["handles"];
    assert(h.type == JSONType.object, "rig: no handle registry for the embedded banks");
    double sx, sy;
    bool found;
    foreach (q; h["parts"].array)
        if (q["part"].integer == 20 && q["screen"].type == JSONType.array) {
            sx = q["screen"][0].floating; sy = q["screen"][1].floating; found = true;
        }
    assert(found, "rig: the scale X arm (registry part 20) has no screen anchor: " ~ h.toString);
    assertGrabbed(Px(cast(int) sx, cast(int) sy), "scale", 0, "scale X arm");
}

unittest { // the rotate bank's X ring
    bankRig("rotate");
    auto vp = viewportFromCameraMatrices();
    // The ring's end where it meets the view plane: c + r * (eₓ × f), on the
    // drawn half whichever half the camera draws.
    immutable DV f = DV(-vp.view[2], -vp.view[6], -vp.view[10]);
    immutable DV end = kHandle + normalize(cross(DV(1, 0, 0), f)) * gizmoSize(kHandle, vp);
    float x, y;
    assert(projectToWindow(end, vp, x, y), "rig: the ring point is behind the camera");
    assertGrabbed(Px(cast(int) x, cast(int) y), "rotate", 0, "rotate X ring");
}
