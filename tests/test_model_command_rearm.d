// Task 6250 origin arm: mesh.subpatch_toggle commits a pending transform,
// applies the command, and re-arms a fresh run without rebuilding the toolpipe.
// Assert order is deliberate: each mutation's must-stay-green controls precede
// the assertion that must redden.

import core.thread : Thread;
import core.time : msecs;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : fabs;
import std.algorithm : canFind;

void main() {}

private enum double kTol = 1e-4;
private enum string kTabLog =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n" ~
    `{"t":1,"type":"SDL_WINDOWEVENT","sub":1}` ~ "\n" ~
    `{"t":2,"type":"SDL_WINDOWEVENT","sub":3}` ~ "\n" ~
    `{"t":50,"type":"SDL_KEYDOWN","sym":9,"scan":0,"mod":0,"repeat":0}` ~ "\n" ~
    `{"t":60,"type":"SDL_KEYUP","sym":9,"scan":0,"mod":0,"repeat":0}`;

private double number(JSONValue value) {
    final switch (value.type) {
        case JSONType.float_:   return value.floating;
        case JSONType.integer:  return cast(double)value.integer;
        case JSONType.uinteger: return cast(double)value.uinteger;
        case JSONType.string: case JSONType.array: case JSONType.object:
        case JSONType.true_: case JSONType.false_: case JSONType.null_:
            assert(false, "6250: expected JSON number, got " ~ value.toString);
    }
}

private JSONValue command(string line, string context) {
    auto response = postJson("/api/command", line);
    assert(response["status"].str == "ok",
        context ~ ": command failed: " ~ response.toString);
    return response;
}

private void resetFixture(string context) {
    command(commandBody("scene.reset"), context ~ " reset");
    command("history.clear", context ~ " clear history");
}

private void armPending(string context) {
    command("tool.set Transform on", context ~ " arm");
    command("tool.pipe.attr actionCenter mode origin", context ~ " origin arm");
    command("tool.beginSession", context ~ " begin session");
    command("tool.attr Transform TX 1.5", context ~ " pending TX");
}

unittest { // Live registry publishes the one-command continuation set.
    auto registry = getJson("/api/registry");
    auto rearms = registry["commandsRearmingToolAfterApply"].array;
    string[] commands;
    foreach (entry; registry["commands"].array) commands ~= entry.str;
    assert(commands.canFind("mesh.subpatch_toggle"),
        "6250 registry population: mesh.subpatch_toggle is not live");
    assert(rearms.length == 1 && rearms[0].str == "mesh.subpatch_toggle",
        "6250 live registry: continuation set changed: " ~ rearms.to!string);
}

private JSONValue toolState() { return getJson("/api/tool/state"); }
private JSONValue[] undoRows() { return getJson("/api/history")["undo"].array; }

private double[3] centre() {
    auto vertices = getJson("/api/model")["vertices"].array;
    assert(vertices.length == 8,
        "6250 population floor: cube must have 8 vertices, got "
        ~ vertices.length.to!string);
    double[3] result = [0.0, 0.0, 0.0];
    foreach (vertex; vertices) {
        auto xyz = vertex.array;
        foreach (axis; 0 .. 3) result[axis] += number(xyz[axis]);
    }
    foreach (axis; 0 .. 3) result[axis] /= vertices.length;
    return result;
}

private bool[] subpatchFlags() {
    bool[] result;
    foreach (value; getJson("/api/model")["isSubpatch"].array)
        result ~= value.type == JSONType.true_;
    return result;
}

private void assertTogglePopulation(string cell) {
    auto flags = subpatchFlags();
    assert(flags.length == 6,
        format("6250 %s: cube must have 6 faces, got %d", cell, flags.length));
    foreach (i, flag; flags)
        assert(flag, format("6250 %s: face %d was not toggled to subpatch", cell, i));
}

private void waitPlayback() {
    foreach (_; 0 .. 100) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.true_) {
            Thread.sleep(150.msecs);
            return;
        }
        Thread.sleep(50.msecs);
    }
    assert(false, "6250 F: Tab playback did not finish within 5 seconds");
}

private string[string] pipeAttrs(string task, string cell) {
    foreach (stage; getJson("/api/toolpipe")["stages"].array) {
        if (stage["task"].str != task) continue;
        string[string] result;
        foreach (name, value; stage["attrs"].object) result[name] = value.str;
        return result;
    }
    assert(false, format("6250 %s: %s stage disappeared from the toolpipe", cell, task));
}

unittest { // G — the command itself ran on a populated cube.
    resetFixture("G");
    auto before = subpatchFlags();
    assert(before.length == 6, "6250 G: fresh cube must have 6 faces");
    foreach (i, flag; before)
        assert(!flag, format("6250 G: fresh face %d unexpectedly subpatch", i));
    armPending("G");
    command("mesh.subpatch_toggle", "G toggle");
    assertTogglePopulation("G");
}

unittest { // C — the pending edit is committed, not cancelled.
    resetFixture("C");
    armPending("C");
    command("mesh.subpatch_toggle", "C toggle");
    assert(fabs(centre()[0] - 1.5) <= kTol,
        format("6250 C: pending TX was lost; x-centre %.6f, expected 1.5", centre()[0]));
}

unittest { // D — the capable transform remains armed.
    resetFixture("D");
    armPending("D");
    command("mesh.subpatch_toggle", "D toggle");
    auto state = toolState();
    assert("tool" in state && state["tool"].str == "xfrm",
        "6250 D: subpatch toggle dropped the capable transform: " ~ state.toString);
}

unittest { // H — in-place re-arm preserves loose transient pipe values.
    resetFixture("H");
    command("tool.set Transform on", "H arm");
    command("tool.pipe.attr actionCenter mode origin", "H action centre");
    command("tool.pipe.attr falloff dist 1.2", "H falloff distance");
    command("tool.beginSession", "H begin session");
    command("tool.attr Transform TX 1.5", "H pending TX");
    auto beforeAcen = pipeAttrs("ACEN", "H");
    auto beforeWght = pipeAttrs("WGHT", "H");
    auto pending = toolState();
    assert(beforeAcen.get("mode", "") == "origin"
        && fabs(beforeWght.get("dist", "0").to!double - 1.2) <= kTol,
        "6250 H population: loose ACEN/WGHT values were not configured before toggle");
    assert("editOpen" in pending && pending["editOpen"].type == JSONType.true_,
        "6250 H population: transform edit must be open before toggle: "
        ~ pending.toString);
    command("mesh.subpatch_toggle", "H toggle");
    auto afterAcen = pipeAttrs("ACEN", "H");
    auto afterWght = pipeAttrs("WGHT", "H");
    assert(afterAcen.get("mode", "") == "origin"
        && fabs(afterWght.get("dist", "0").to!double - 1.2) <= kTol,
        "6250 H: commit-and-rearm rebuilt or cleared the transient toolpipe");
}

unittest { // I — pre-apply commit precedes the command record.
    resetFixture("I");
    armPending("I");
    auto pending = toolState();
    assert("editOpen" in pending && pending["editOpen"].type == JSONType.true_,
        "6250 I population: transform edit must be open before toggle: "
        ~ pending.toString);
    immutable before = undoRows().length;
    command("mesh.subpatch_toggle", "I toggle");
    auto rows = undoRows();
    auto added = rows[before .. $];
    assert(added.length == 2,
        format("6250 I population: toggle must add exactly 2 rows, got %d", added.length));
    assert(added[0]["label"].str == "Transform 8 verts"
        && added[1]["label"].str == "mesh.subpatch_toggle",
        "6250 I: history order must be pending transform then toggle, got "
        ~ format("%s", added));
}

unittest { // A — the next absolute edit adds to the committed cage.
    resetFixture("A");
    armPending("A");
    command("mesh.subpatch_toggle", "A toggle");
    command("tool.beginSession", "A second session");
    command("tool.attr Transform TX 2.5", "A second TX");
    assert(fabs(centre()[0] - 4.0) <= kTol,
        format("6250 A: fresh absolute TX must land at 4.0, got %.6f", centre()[0]));
}

unittest { // B — re-arm zeroes every transform channel.
    resetFixture("B");
    armPending("B");
    command("mesh.subpatch_toggle", "B toggle");
    command("tool.beginSession", "B second session");
    command("tool.attr Transform TY 1.0", "B orthogonal TY");
    auto c = centre();
    assert(fabs(c[0] - 1.5) <= kTol && fabs(c[1] - 1.0) <= kTol,
        format("6250 B: re-arm retained stale channels; centre=(%.6f,%.6f)", c[0], c[1]));
}

unittest { // K — an armed tool without ForeignEditRearm is dropped.
    resetFixture("K");
    command("tool.set poly.bevel on", "K arm bevel");
    auto before = toolState();
    assert("tool" in before && before["tool"].str == "polyBevel",
        "6250 K population: poly.bevel must be armed before toggle: "
        ~ before.toString);
    command("mesh.subpatch_toggle", "K toggle");
    auto after = toolState();
    assert(after.object.length == 0,
        "6250 K: tool without ForeignEditRearm stayed armed: " ~ after.toString);
}

unittest { // Tab also drops an armed tool without ForeignEditRearm.
    resetFixture("K-tab");
    command("tool.set poly.bevel on", "K-tab arm bevel");
    auto before = toolState();
    assert("tool" in before && before["tool"].str == "polyBevel",
        "6250 K-tab population: poly.bevel must be armed before Tab: "
        ~ before.toString);
    auto response = postJson("/api/play-events", kTabLog);
    assert(response["status"].str == "success",
        "6250 K-tab: playback request failed: " ~ response.toString);
    waitPlayback();
    assertTogglePopulation("K-tab");
    auto after = toolState();
    assert(after.object.length == 0,
        "6250 K-tab: Tab left the non-capable tool armed: " ~ after.toString);
}

unittest { // E — an already-completed edit is not recorded twice.
    resetFixture("E");
    command("tool.set Transform on", "E arm");
    command("tool.pipe.attr actionCenter mode origin", "E origin arm");
    command("tool.attr Transform TX 1.5", "E TX");
    command("tool.doApply", "E apply");
    auto beforeModel = getJson("/api/model")["vertices"];
    auto completed = toolState();
    assert(beforeModel.array.length == 8 && fabs(centre()[0] - 1.5) <= kTol,
        "6250 E population: completed transform must move all 8 cube vertices");
    assert("editOpen" in completed && completed["editOpen"].type == JSONType.false_,
        "6250 E population: transform edit must be closed before toggle: "
        ~ completed.toString);
    immutable beforeDepth = undoRows().length;
    command("mesh.subpatch_toggle", "E toggle");
    auto afterModel = getJson("/api/model")["vertices"];
    auto state = toolState();
    assert(afterModel.toString == beforeModel.toString,
        "6250 E: toggle changed vertices after an already-completed edit");
    assert(undoRows().length == beforeDepth + 1,
        format("6250 E: completed edit toggle added %d rows, expected 1",
               undoRows().length - beforeDepth));
    assert("tool" in state && state["tool"].str == "xfrm",
        "6250 E: completed edit toggle dropped the transform");
}

unittest { // F — Tab uses the same command funnel and history law.
    resetFixture("F");
    armPending("F");
    immutable beforeDepth = undoRows().length;
    auto response = postJson("/api/play-events", kTabLog);
    assert(response["status"].str == "success",
        "6250 F: Tab playback request failed: " ~ response.toString);
    waitPlayback();
    assertTogglePopulation("F");
    assert(fabs(centre()[0] - 1.5) <= kTol,
        "6250 F: Tab lost the pending transform");
    auto state = toolState();
    assert("tool" in state && state["tool"].str == "xfrm",
        "6250 F: Tab dropped the transform: " ~ state.toString);
    auto rows = undoRows();
    assert(rows.length == beforeDepth + 2,
        format("6250 F: Tab added %d rows, expected 2", rows.length - beforeDepth));
    assert(rows[$ - 1]["label"].str == "mesh.subpatch_toggle",
        "6250 F: Tab did not record mesh.subpatch_toggle: " ~ rows[$ - 1].toString);
}
