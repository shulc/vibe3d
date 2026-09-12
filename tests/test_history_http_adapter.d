module test_history_http_adapter;

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.json : JSONType, JSONValue;

void main() {}

private JSONValue command(string line) {
    auto response = postJson("/api/command", line);
    assert(response["status"].str == "ok",
        "history HTTP adapter command failed: " ~ response.toString());
    return response;
}

private JSONValue model() {
    return getJson("/api/model");
}

private void assertSameGeometry(JSONValue actual, JSONValue wanted,
                                string context) {
    assert(actual["vertices"] == wanted["vertices"],
        context ~ ": vertex payload changed");
    assert(actual["faces"] == wanted["faces"],
        context ~ ": face payload changed");
}

unittest { // endpoint responses plus a real geometry undo/redo round-trip
    command(commandBody("scene.reset"));
    command(commandBody("history.clear"));
    const baseline = model();
    assert(baseline["vertices"].array.length == 8,
        "history HTTP adapter geometry stand must begin with the 8-vertex cube");

    auto disarmed = postJson("/api/trace/disarm", "");
    assert(disarmed["status"].str == "ok",
        "history HTTP adapter trace disarm response changed: "
        ~ disarmed.toString());
    command(commandBody("mesh.subdivide"));
    assert(getJson("/api/trace").array.length == 0,
        "history HTTP adapter disarmed trace captured a command");

    auto firstUndo = command(commandBody("history.undo"));
    assert(firstUndo["status"].str == "ok",
        "history HTTP adapter first undo failed: " ~ firstUndo.toString());
    assertSameGeometry(model(), baseline,
        "history HTTP adapter disarmed-trace undo round-trip");
    command(commandBody("history.clear"));

    auto armed = postJson("/api/trace/reset", "");
    assert(armed["status"].str == "ok",
        "history HTTP adapter trace arm response changed: " ~ armed.toString());
    command(commandBody("mesh.subdivide"));
    const changed = model();
    assert(changed["vertices"].array.length == 26
        && changed["faces"].array.length == 24,
        "history HTTP adapter action witness: subdivide must produce 26 vertices "
        ~ "and 24 faces, got " ~ changed["vertices"].array.length.to!string
        ~ "/" ~ changed["faces"].array.length.to!string);

    auto trace = getJson("/api/trace").array;
    assert(trace.length == 1,
        "history HTTP adapter armed trace population floor: expected 1 row, got "
        ~ trace.length.to!string);
    assert(trace[0]["command"].str == "mesh.subdivide",
        "history HTTP adapter armed trace recorded the wrong command: "
        ~ trace[0].toString());

    auto beforeUndo = getJson("/api/history");
    assert(beforeUndo["undo"].array.length == 1,
        "history HTTP adapter HTTP population floor: expected 1 undo row");
    assert(beforeUndo["redo"].array.length == 0,
        "history HTTP adapter pre-undo redo stack must be empty");

    auto undo = command(commandBody("history.undo"));
    assert(undo["status"].str == "ok",
        "history HTTP adapter undo failed: " ~ undo.toString());
    assertSameGeometry(model(), baseline,
        "history HTTP adapter geometry-plus-undo round-trip");

    auto afterUndo = getJson("/api/history");
    assert(afterUndo["undo"].array.length == 0,
        "history HTTP adapter post-undo undo stack must be empty");
    assert(afterUndo["redo"].array.length == 1,
        "history HTTP adapter HTTP population floor: expected 1 redo row");
    auto redoRow = afterUndo["redo"].array[0];
    assert(redoRow["command"].str == "mesh.subdivide",
        "history HTTP adapter redo serialized the wrong source row");
    assert(redoRow["flags"].integer != 0,
        "history HTTP adapter redo lost its own flags");
    assert(redoRow["opInverse"].type == JSONType.true_
        || redoRow["opInverse"].type == JSONType.false_,
        "history HTTP adapter redo lost the opInverse self-report field");

    // opInverse is only the command's self-report. The geometry comparisons
    // above and below, not this boolean, prove the payload round-trips.
    auto redo = command(commandBody("history.redo"));
    assert(redo["status"].str == "ok",
        "history HTTP adapter redo failed: " ~ redo.toString());
    assertSameGeometry(model(), changed,
        "history HTTP adapter geometry redo round-trip");

    auto ended = postJson("/api/refire", `{"action":"begin"}`);
    assert(ended["status"].str == "ok",
        "history HTTP adapter refire begin response changed: " ~ ended.toString());
    ended = postJson("/api/refire", `{"action":"end"}`);
    assert(ended["status"].str == "ok",
        "history HTTP adapter refire end response changed: " ~ ended.toString());

    auto invalidRefire = postJson("/api/refire", `{"action":"pause"}`);
    assert(invalidRefire["status"].str == "error"
        && invalidRefire["message"].str == "'action' must be 'begin' or 'end'",
        "history HTTP adapter invalid refire response changed: "
        ~ invalidRefire.toString());
    auto invalidBlock = postJson("/api/history/block", `{"action":"pause"}`);
    assert(invalidBlock["status"].str == "error"
        && invalidBlock["message"].str == "'action' must be 'begin' or 'end'",
        "history HTTP adapter invalid block response changed: "
        ~ invalidBlock.toString());

    auto finalDisarm = postJson("/api/trace/disarm", "");
    assert(finalDisarm["status"].str == "ok"
        && getJson("/api/trace").array.length == 0,
        "history HTTP adapter final trace disarm response/state changed");
}
