// Task 6355 secondary witness, isolated from the morph-state assertions so
// druntime fail-fast cannot hide either reason a lost hook is wrong.

import core.thread : Thread;
import core.time : dur;
import http_client : getJson, postRaw, quiesce;
import http_command_helpers : commandBody;
import std.format : format;
import std.json : parseJSON;

void main() {}

private void postOk(string body) {
    const response = postRaw("/api/command", body);
    const json = parseJSON(response);
    assert("error" !in json
        && (("status" !in json) || json["status"].str == "ok"
                                || json["status"].str == "success"),
        "command failed: " ~ response);
}

private void cmd(string script) { postOk(script); }
private void command(string id, string params = "{}") {
    postOk(commandBody(id, params));
}
// Card test-sleep-removal: quiesce (frame fence + no pending preview build) replaces the fixed sleep (dur!"msecs"(180)).
private void settle() { quiesce(); }

private void resetCube() {
    command("scene.reset");
    command("history.clear");
    settle();
}

private long count(string key) { return getJson("/api/changes")[key].integer; }

unittest { // S7a: layer.select publishes both hook-owned counters
    resetCube();
    cmd("layer.add name:B");
    cmd("prim.sphere");
    const active0 = count("totalLayerActive");
    const delivery0 = count("deliveryCount");
    command("layer.select", `{"index":0,"mode":"set"}`);
    settle();
    const active1 = count("totalLayerActive");
    const delivery1 = count("deliveryCount");
    assert(active1 == active0 + 1 && delivery1 == delivery0 + 1,
        format("6355 S7 layer.select hook counters did not each advance once (active %d->%d, delivery %d->%d)",
               active0, active1, delivery0, delivery1));
}

unittest { // S7b: imagePlane.add publishes both hook-owned counters
    resetCube();
    cmd("layer.add name:B");
    cmd("prim.sphere");
    command("layer.select", `{"index":0,"mode":"set"}`);
    command("layer.select", `{"index":1,"mode":"add"}`);
    command("layer.select", `{"index":0,"mode":"remove"}`);
    const active0 = count("totalLayerActive");
    const delivery0 = count("deliveryCount");
    command("imagePlane.add");
    settle();
    const active1 = count("totalLayerActive");
    const delivery1 = count("deliveryCount");
    assert(active1 == active0 + 1 && delivery1 == delivery0 + 1,
        format("6355 S7 imagePlane.add hook counters did not each advance once (active %d->%d, delivery %d->%d)",
               active0, active1, delivery0, delivery1));
}
