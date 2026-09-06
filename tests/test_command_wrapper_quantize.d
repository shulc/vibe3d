// Task 4580: Quantize is the R6 command-wrapper pilot. Exercise both producers
// of its sparse result through the real tool lifecycle: mouse preview -> drop
// -> undo, and panel refire -> one history entry -> undo. The no-op cell keeps
// an empty result from becoming an empty history row.

import drag_helpers : buildDragLog, fetchCamera, playAndWait;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.json;
import std.math : fabs;

void main() {}

private void cmd(string line) {
    auto j = postJson("/api/command", line);
    assert(j["status"].str == "ok", line ~ " failed: " ~ j.toString);
}

private void resetCube() {
    auto j = postJson("/api/command", commandBody("scene.reset"));
    assert(j["status"].str == "ok", "scene.reset failed: " ~ j.toString);
}

private JSONValue model() {
    return getJson("/api/model");
}

private size_t historyCount() {
    return getJson("/api/history")["undo"].array.length;
}

private double coord(int vertex, int axis) {
    return model()["vertices"].array[vertex].array[axis].floating;
}

private bool close(double a, double b) { return fabs(a - b) < 1e-5; }

unittest { // live gesture -> one sparse preview -> drop/undo
    resetCube();
    auto selected = postJson("/api/command",
        commandBody("mesh.select", `{"mode":"vertices","indices":[0]}`));
    assert(selected["status"].str == "ok", "vertex selection setup failed");
    cmd("tool.set xfrm.quantize on");
    scope(exit) cmd("tool.set xfrm.quantize off");

    const before = coord(0, 0);
    const unselectedBefore = coord(1, 0);
    const entriesBefore = historyCount();
    auto cam = fetchCamera();
    const x0 = cam.vpX + cam.width / 2;
    const y0 = cam.vpY + cam.height / 2;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x0 + 80, y0, 6));
    assert(!close(coord(0, 0), before),
        "control: Quantize drag must produce a visible preview");
    assert(close(coord(1, 0), unselectedBefore),
        "Quantize result must preserve vertices outside the moving set");

    cmd("tool.set xfrm.quantize off");
    assert(historyCount() == entriesBefore + 1,
        "Quantize drop must record exactly one result");
    cmd("history.undo");
    assert(close(coord(0, 0), before),
        "one undo must restore the pre-gesture Quantize baseline");
}

unittest { // panel refire keeps only the last result; empty result records none
    resetCube();
    cmd("tool.set xfrm.quantize on");
    scope(exit) cmd("tool.set xfrm.quantize off");
    const before = coord(0, 0);
    const entriesBefore = historyCount();

    assert(postJson("/api/refire", `{"action":"begin"}`)["status"].str == "ok");
    cmd("tool.attr xfrm.quantize X 0.3");
    cmd("tool.attr xfrm.quantize Y 0.3");
    cmd("tool.attr xfrm.quantize Z 0.3");
    assert(postJson("/api/refire", `{"action":"end"}`)["status"].str == "ok");
    assert(close(coord(0, 0), -0.6),
        "final panel result must quantize the cube from the session baseline");
    assert(historyCount() == entriesBefore + 1,
        "three panel ticks must consolidate to one Quantize entry");

    cmd("tool.set xfrm.quantize off");
    cmd("history.undo");
    assert(close(coord(0, 0), before),
        "panel refire must undo in one step");

    cmd("tool.set xfrm.quantize on");
    const noOpBefore = historyCount();
    assert(postJson("/api/refire", `{"action":"begin"}`)["status"].str == "ok");
    cmd("tool.attr xfrm.quantize X 0.5");
    cmd("tool.attr xfrm.quantize Y 0.5");
    cmd("tool.attr xfrm.quantize Z 0.5");
    assert(postJson("/api/refire", `{"action":"end"}`)["status"].str == "ok");
    cmd("tool.set xfrm.quantize off");
    assert(historyCount() == noOpBefore,
        "an empty Quantize result must not create a history entry");
}
