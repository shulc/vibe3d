// Task 4560, Smooth slice: one deterministic result across the scripted
// command, live preview, refire carrier, drop, undo and redo paths.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.format : format;
import std.math : fabs;

void main() {}

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

private size_t undoDepth() {
    return getJson("/api/history")["undo"].array.length;
}

unittest {
    // The reused worker keeps tool and WGHT state across scene.reset, so both
    // are explicitly returned to neutral on every exit.
    scope(exit) {
        cmd("tool.set xfrm.smooth off");
        cmd("tool.pipe.attr falloff type none");
    }

    resetScene();
    const baseline = positions();
    cmd("mesh.smooth strn:0.73 iter:4");
    const commandExpected = positions();
    assert(maxDiff(baseline, commandExpected) > 0.05,
        "control: direct Smooth command must produce a non-empty result");

    resetScene();
    cmd("tool.set xfrm.smooth on");
    const historyBefore = undoDepth();
    cmd("tool.attr xfrm.smooth iter 4");
    cmd("tool.attr xfrm.smooth strn 0.73");
    const preview = positions();
    assert(maxDiff(preview, commandExpected) < 1e-6, format(
        "Smooth preview diverged from direct command; max diff %.9g",
        maxDiff(preview, commandExpected)));
    assert(undoDepth() == historyBefore,
        "a live Smooth preview must not record history before refire/drop");

    auto begin = postJson("/api/refire", `{"action":"begin"}`);
    assert(begin["status"].str == "ok", "refire begin failed: " ~ begin.toString);
    cmd("tool.attr xfrm.smooth strn 0.73");
    auto end = postJson("/api/refire", `{"action":"end"}`);
    assert(end["status"].str == "ok", "refire end failed: " ~ end.toString);
    const refired = positions();
    assert(maxDiff(refired, commandExpected) < 1e-6, format(
        "Smooth refire diverged from direct command; max diff %.9g",
        maxDiff(refired, commandExpected)));
    assert(undoDepth() == historyBefore + 1,
        "Smooth refire must record exactly one result");

    cmd("tool.set xfrm.smooth off");
    assert(undoDepth() == historyBefore + 1,
        "dropping Smooth after refire must not duplicate history");
    cmd("history.undo");
    assert(maxDiff(positions(), baseline) < 1e-6,
        "Smooth undo did not restore the shared baseline");
    cmd("history.redo");
    assert(maxDiff(positions(), commandExpected) < 1e-6,
        "Smooth redo did not restore the shared expected result");
}
