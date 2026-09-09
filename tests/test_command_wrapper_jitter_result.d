// Task 4560, Jitter slice: direct command, live preview, panel refire, drop,
// undo and redo must all converge on the frozen pre-builder result. UI cancel
// is driven by a real Ctrl+Z event through navHistory/EditSession.

import core.thread : Thread;
import core.time : msecs;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.format : format;
import std.json : JSONType;
import std.math : fabs;

void main() {}

private immutable double[3][8] kAnchorBaseline = [
    [-0.5, -0.5, -0.5], [ 0.5, -0.5, -0.5],
    [ 0.5,  0.5, -0.5], [-0.5,  0.5, -0.5],
    [-0.5, -0.5,  0.5], [ 0.5, -0.5,  0.5],
    [ 0.5,  0.5,  0.5], [-0.5,  0.5,  0.5],
];
private immutable double[3] kAnchorAfter6 =
    [0.331583530, 0.238378137, 0.808284283];

private void cmd(string line) {
    auto j = postJson("/api/command", line);
    assert(j["status"].str == "ok" || j["status"].str == "success",
        line ~ " failed: " ~ j.toString);
}

private void resetScene() {
    auto j = postJson("/api/command", commandBody("scene.reset"));
    assert(j["status"].str == "ok", "scene.reset failed: " ~ j.toString);
}

private double[3][] positions() {
    double[3][] result;
    foreach (v; getJson("/api/model")["vertices"].array)
        result ~= [v.array[0].floating, v.array[1].floating,
                   v.array[2].floating];
    return result;
}

private double maxDiff(const double[3][] a, const double[3][] b) {
    assert(a.length == b.length);
    double d = 0.0;
    foreach (i; 0 .. a.length)
        foreach (axis; 0 .. 3)
            if (fabs(a[i][axis] - b[i][axis]) > d)
                d = fabs(a[i][axis] - b[i][axis]);
    return d;
}

private double[3][] frozenExpected() {
    auto result = kAnchorBaseline[].dup;
    result[6] = kAnchorAfter6;
    return result;
}

private size_t undoDepth() {
    return getJson("/api/history")["undo"].array.length;
}

private void selectLateVertex() {
    auto selected = postJson("/api/command", commandBody(
        "mesh.select", `{"mode":"vertices","indices":[6]}`));
    assert(selected["status"].str == "ok",
        "selecting anchor vertex 6 failed: " ~ selected.toString);
}

private void configureLiveJitter() {
    cmd("tool.attr xfrm.jitter seed 1749");
    cmd("tool.attr xfrm.jitter rangeY 0.31");
    cmd("tool.attr xfrm.jitter rangeZ 0.47");
    cmd("tool.attr xfrm.jitter rangeX 0.17");
}

private void waitPlaybackFinish() {
    foreach (_; 0 .. 100) {
        auto j = getJson("/api/play-events/status");
        if (j["finished"].type == JSONType.true_) {
            Thread.sleep(120.msecs);
            return;
        }
        Thread.sleep(50.msecs);
    }
    assert(false, "Jitter UI-cancel playback did not finish within 5s");
}

private void playCtrlZ() {
    enum log =
        `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n" ~
        `{"t":1,"type":"SDL_WINDOWEVENT","sub":1}` ~ "\n" ~
        `{"t":2,"type":"SDL_WINDOWEVENT","sub":3}` ~ "\n" ~
        `{"t":50,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n" ~
        `{"t":60,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}`;
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success",
        "Jitter Ctrl+Z playback failed: " ~ r.toString);
    waitPlaybackFinish();
}

unittest { // frozen direct command plus preview/refire/drop/undo/redo lifecycle
    scope(exit) {
        cmd("tool.set xfrm.jitter off");
        cmd("tool.pipe.attr falloff type none");
    }

    resetScene();
    const baseline = positions();
    const baselineDelta = maxDiff(baseline, kAnchorBaseline[]);
    assert(baselineDelta < 1e-9, format(
        "HTTP Jitter anchor baseline/order changed; max diff %.9g, " ~
        "vertex 0=(%.9g,%.9g,%.9g)", baselineDelta,
        baseline[0][0], baseline[0][1], baseline[0][2]));
    selectLateVertex();
    cmd("mesh.jitter rangeX:0.17 rangeY:0.31 rangeZ:0.47 seed:1749 " ~
        "enableX:true enableY:true enableZ:true");
    const expected = frozenExpected();
    const direct = positions();
    assert(maxDiff(direct, expected) < 1e-6, format(
        "direct Jitter diverged from frozen pre-builder anchor; max diff %.9g",
        maxDiff(direct, expected)));

    resetScene();
    selectLateVertex();
    cmd("tool.set xfrm.jitter on");
    const historyBefore = undoDepth();
    configureLiveJitter();
    const preview = positions();
    assert(maxDiff(preview, expected) < 1e-6, format(
        "Jitter preview diverged from frozen anchor; max diff %.9g",
        maxDiff(preview, expected)));
    assert(undoDepth() == historyBefore,
        "live Jitter preview recorded history before panel refire/drop");

    auto begin = postJson("/api/refire", `{"action":"begin"}`);
    assert(begin["status"].str == "ok", "refire begin failed: " ~ begin.toString);
    cmd("tool.attr xfrm.jitter rangeX 0.23");
    cmd("tool.attr xfrm.jitter rangeX 0.17");
    auto end = postJson("/api/refire", `{"action":"end"}`);
    assert(end["status"].str == "ok", "refire end failed: " ~ end.toString);
    const refired = positions();
    assert(maxDiff(refired, expected) < 1e-6, format(
        "Jitter panel-refire diverged from frozen anchor; max diff %.9g",
        maxDiff(refired, expected)));
    assert(undoDepth() == historyBefore + 1,
        "Jitter panel-refire must record exactly one result");

    cmd("tool.set xfrm.jitter off");
    assert(undoDepth() == historyBefore + 1,
        "dropping Jitter after refire duplicated history");
    cmd("history.undo");
    assert(maxDiff(positions(), baseline) < 1e-6,
        "Jitter undo did not restore the frozen baseline");
    cmd("history.redo");
    assert(maxDiff(positions(), expected) < 1e-6,
        "Jitter redo did not restore the frozen expected result");
}

unittest { // Ctrl+Z reaches EditSession and cancels a live preview
    scope(exit) cmd("tool.set xfrm.jitter off");
    resetScene();
    cmd("history.clear");
    selectLateVertex();
    const baseline = positions();
    const historyBefore = undoDepth();
    cmd("tool.set xfrm.jitter on");
    configureLiveJitter();
    assert(maxDiff(positions(), baseline) > 0.05,
        "UI-cancel control needs a populated live Jitter preview");
    playCtrlZ();
    assert(maxDiff(positions(), baseline) < 1e-6,
        "EditSession Ctrl+Z did not cancel the live Jitter preview");
    assert(undoDepth() == historyBefore,
        "EditSession live cancel popped or added history");
    assert(getJson("/api/buttons/availability")["activeToolId"].str.length == 0,
        "EditSession cancel must drop the Jitter tool after restoring it");
}

unittest { // zero-range accepted no-op remains a real history record
    resetScene();
    cmd("history.clear");
    selectLateVertex();
    const baseline = positions();
    const initialDepth = undoDepth();
    cmd("mesh.jitter rangeX:0.17 rangeY:0.31 rangeZ:0.47 seed:1749");
    const realPositions = positions();
    const afterRealDepth = undoDepth();
    assert(afterRealDepth == initialDepth + 1 &&
           maxDiff(realPositions, baseline) > 0.05,
        "zero-range history control needs one earlier real Jitter entry");
    cmd("mesh.jitter rangeX:0 rangeY:0 rangeZ:0 seed:1749");
    const afterNoopDepth = undoDepth();
    assert(afterNoopDepth == afterRealDepth + 1,
        "accepted zero-range Jitter silently lost its history record");
    cmd("history.undo");
    assert(undoDepth() == afterRealDepth &&
           maxDiff(positions(), realPositions) < 1e-6,
        "undo of zero-range Jitter did not pop exactly its no-op record");
    cmd("history.undo");
    assert(undoDepth() == initialDepth && maxDiff(positions(), baseline) < 1e-6,
        "real Jitter below zero-range no-op was lost from undo sequence");
}
