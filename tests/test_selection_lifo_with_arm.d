// Mixed-stack integration anchor for tasks 3693 and 3694.
//
// The production stack is [Edit(Model), Select(UI), Arm(ToolLifecycle)]. On
// the completed port all three records are strict LIFO. The resulting order is
// Arm -> Select -> Edit; this same cell asserted Select -> Edit -> Arm after
// task 3693, so its changed first step witnesses the lifecycle-head change.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : fabs;
import std.net.curl : get, post;
import std.string : format;

void main() {}

alias baseUrl = testBaseUrl;


void command(string line) {
    auto response = postJson("/api/command", line);
    assert(response["status"].str == "ok",
        "command failed: " ~ line ~ " -> " ~ response.toString);
}

void establishBaseline() {
    postJson("/api/script", "tool.set move off");
    postJson("/api/command", commandBody("scene.reset"));
    command("history.clear");
}

JSONValue undo() {
    auto response = postJson("/api/command", commandBody("history.undo"));
    assert(response["status"].str == "ok", "undo failed: " ~ response.toString);
    return response;
}

JSONValue status() {
    return getJson("/api/undo/status");
}

bool moveArmed() {
    auto state = getJson("/api/tool/state");
    auto tool = "tool" in state.object;
    return tool !is null && tool.type == JSONType.string && tool.str == "xfrm";
}

double vertexX(size_t index) {
    return getJson("/api/model")["vertices"].array[index].array[0].floating;
}

bool near(double a, double b) {
    return fabs(a - b) < 1e-6;
}

void assertDepths(long model, long ui, long lifecycle, string at) {
    auto s = status();
    assert(s["modelDepth"].integer == model
        && s["uiDepth"].integer == ui
        && s["toolLifecycleCount"].integer == lifecycle,
        format("%s: expected model/ui/lifecycle=%s/%s/%s, got %s/%s/%s",
            at, model, ui, lifecycle,
            s["modelDepth"].integer, s["uiDepth"].integer,
            s["toolLifecycleCount"].integer));
}

unittest {
    establishBaseline();
    const beforeX = vertexX(0);

    command(format("mesh.move_vertex from:{%g,-0.5,-0.5} to:{%g,-0.5,-0.5}",
        beforeX, beforeX + 0.25));
    auto selected = postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0]}`));
    assert(selected["status"].str == "ok", "selection failed: " ~ selected.toString);
    command("tool.set move on");

    assert(moveArmed(), "F4 setup: Move must be armed");
    assert(near(vertexX(0), beforeX + 0.25), "F4 setup: edit did not apply");
    assertDepths(1, 1, 1, "F4 setup");

    undo();
    assert(!moveArmed(), "F4 undo1 must revert Arm");
    assert(getJson("/api/selection")["selectedVertices"].array.length == 1,
        "F4 undo1 must leave Select applied");
    assert(near(vertexX(0), beforeX + 0.25),
        "F4 undo1 must leave Edit applied");
    assertDepths(1, 1, 0, "F4 undo1");

    undo();
    assert(getJson("/api/selection")["selectedVertices"].array.length == 0,
        "F4 undo2 must revert Select");
    assert(near(vertexX(0), beforeX + 0.25),
        "F4 undo2 must leave Edit applied");
    assert(!moveArmed(), "F4 undo2 must leave Arm reverted");
    assertDepths(1, 0, 0, "F4 undo2");

    undo();
    assert(near(vertexX(0), beforeX), "F4 undo3 must revert Edit");
    assert(!moveArmed(), "F4 undo3 must leave Arm reverted");
    assertDepths(0, 0, 0, "F4 undo3");
}
