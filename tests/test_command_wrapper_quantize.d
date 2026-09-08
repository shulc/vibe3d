// Task 4580: Quantize is the R6 command-wrapper pilot. Exercise both producers
// of its sparse result through the real tool lifecycle: mouse preview -> drop
// -> undo, and panel refire -> one history entry -> undo. The no-op cell keeps
// an empty result from becoming an empty history row.

import drag_helpers : buildDragLog, fetchCamera, playAndWait;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
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

private double[3][] positions() {
    double[3][] result;
    foreach (v; model()["vertices"].array) {
        double[3] p = [v.array[0].floating, v.array[1].floating,
                       v.array[2].floating];
        result ~= p;
    }
    return result;
}

private bool positionsClose(const double[3][] a, const double[3][] b) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length)
        foreach (axis; 0 .. 3)
            if (!close(a[i][axis], b[i][axis])) return false;
    return true;
}

private double maxPositionDiff(const double[3][] a, const double[3][] b) {
    assert(a.length == b.length);
    double result = 0.0;
    foreach (i; 0 .. a.length)
        foreach (axis; 0 .. 3)
            if (fabs(a[i][axis] - b[i][axis]) > result)
                result = fabs(a[i][axis] - b[i][axis]);
    return result;
}

private struct ChangeCounts {
    long deliveries;
    long positions;
}

private ChangeCounts changeCounts() {
    auto j = getJson("/api/changes");
    return ChangeCounts(j["deliveryCount"].integer,
                        j["totalPosition"].integer);
}

private string radialSizeLine(double size) {
    return format(`tool.pipe.attr falloff size "%.9g,%.9g,%.9g"`,
                  size, size, size);
}

private void configureRadialFalloff(double size) {
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "-0.5,-0.5,-0.5"`);
    cmd(radialSizeLine(size));
}

private double[3][] dragQuantizePreview() {
    auto cam = fetchCamera();
    const x0 = cam.vpX + cam.width / 2;
    const y0 = cam.vpY + cam.height / 2;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x0 + 80, y0, 6));
    return positions();
}

private double queryStepX() {
    auto j = postJson("/api/command", "tool.attr xfrm.quantize X ?");
    assert(j["status"].str == "ok", "Quantize X query failed: " ~ j.toString);
    return j["value"].floating;
}

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

unittest { // falloff drag -> refire reuses the preview's cooked packet
    resetCube();
    cmd("tool.set xfrm.quantize on");
    scope(exit) {
        cmd("tool.set xfrm.quantize off");
        cmd("tool.pipe.attr falloff type none");
    }
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "-0.5,-0.5,-0.5"`);
    cmd(`tool.pipe.attr falloff size "2,2,2"`);

    const before = positions();
    auto cam = fetchCamera();
    const x0 = cam.vpX + cam.width / 2;
    const y0 = cam.vpY + cam.height / 2;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x0 + 80, y0, 6));
    const preview = positions();
    const nearDelta = fabs(preview[0][0] - before[0][0]);
    const farDelta = fabs(preview[6][0] - before[6][0]);
    assert(nearDelta > 1e-3 && farDelta > 1e-6 && farDelta < nearDelta * 0.5,
        format("control: radial falloff must produce distinct nonzero weights; " ~
               "near=%.9g far=%.9g", nearDelta, farDelta));

    const stepX = queryStepX();
    assert(postJson("/api/refire", `{"action":"begin"}`)["status"].str == "ok");
    cmd(format("tool.attr xfrm.quantize X %.9g", stepX));
    assert(postJson("/api/refire", `{"action":"end"}`)["status"].str == "ok");
    const refired = positions();
    assert(positionsClose(refired, preview),
        "falloff refire result differs from the live Quantize preview");
}

// Task 4730: a real falloff write and a Quantize refire cannot occupy the
// dangerous cached interval through the automation entry points. Each command
// bridge is serviced once per frame; the explicit parameter phase re-cooks F1
// before the next tool.attr can refire. A multi-line script uses that same
// bridge once per line, so it cannot bypass the phase either.
unittest {
    enum double f0Size = 2.0;
    enum double f1Size = 0.75;

    // First produce independent geometry for both inputs. This is the
    // discriminator floor: making F1 equal F0 must fail here, before an
    // ordering claim can be accepted on two geometrically identical inputs.
    resetCube();
    cmd("tool.set xfrm.quantize on");
    configureRadialFalloff(f0Size);
    const f0 = dragQuantizePreview();
    const stepX = queryStepX();
    const beforeF1 = changeCounts();
    cmd(radialSizeLine(f1Size));
    // /api/model is main-thread bridged. Reaching this read proves that the
    // frame which serviced the F1 write also passed its parameter phase.
    const f1 = positions();
    const afterF1 = changeCounts();
    assert(maxPositionDiff(f0, f1) > 0.01,
        format("F0/F1 control: distinct radial inputs must produce distinct " ~
               "positions; max diff %.9g", maxPositionDiff(f0, f1)));
    assert(afterF1.deliveries == beforeF1.deliveries + 1 &&
           afterF1.positions == beforeF1.positions + 1,
        format("F1 must be applied by one Position delivery before any refire; " ~
               "deliveries %d->%d, Position %d->%d",
               beforeF1.deliveries, afterF1.deliveries,
               beforeF1.positions, afterF1.positions));

    cmd("tool.set xfrm.quantize off");
    cmd("tool.pipe.attr falloff type none");

    // Repeat F0, then put the real F1 write and refire request in one script.
    // The script is the strongest HTTP attempt at the requested order; its
    // lines still cross a frame boundary because commandBridge ticks once.
    resetCube();
    cmd("tool.set xfrm.quantize on");
    scope(exit) {
        cmd("tool.set xfrm.quantize off");
        cmd("tool.pipe.attr falloff type none");
    }
    configureRadialFalloff(f0Size);
    const repeatedF0 = dragQuantizePreview();
    assert(positionsClose(repeatedF0, f0),
        "control: the second F0 preview must reproduce the oracle geometry");

    assert(postJson("/api/refire", `{"action":"begin"}`)["status"].str == "ok");
    const beforeScript = changeCounts();
    auto script = postJson("/api/script",
        radialSizeLine(f1Size) ~ "\n" ~
        format("tool.attr xfrm.quantize X %.9g", stepX));
    assert(script["status"].str == "ok", "two-line refire script failed: " ~ script.toString);
    // This bridged read is serviced on the following frame, after the refire
    // frame's parameter phase. Any stale acknowledgement would add a third
    // Position delivery there and replace the geometry again.
    const afterRefireAndTick = positions();
    const afterScript = changeCounts();
    assert(postJson("/api/refire", `{"action":"end"}`)["status"].str == "ok");

    assert(positionsClose(afterRefireAndTick, f1),
        format("the frame boundary must apply F1 before cached refire; " ~
               "max diff from F1 %.9g, from F0 %.9g",
               maxPositionDiff(afterRefireAndTick, f1),
               maxPositionDiff(afterRefireAndTick, f0)));
    assert(afterScript.deliveries == beforeScript.deliveries + 2 &&
           afterScript.positions == beforeScript.positions + 2,
        format("F1 tick + refire must deliver Position exactly twice and the " ~
               "next parameter tick must deliver zero; deliveries %d->%d, " ~
               "Position %d->%d", beforeScript.deliveries,
               afterScript.deliveries, beforeScript.positions,
               afterScript.positions));
}
