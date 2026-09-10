// Quad private-preview stamp witness (task 5340).
//
// This test cannot observe the interactive dirty-key decision: --test
// deliberately bypasses that comparison and renders every cell selected by
// viewport.testRendersCell. It instead asserts the per-cell toolPreviewKey
// stamped before the bypass. The struct-level discrimination and declaration/
// stamp census live in tests/unit; a separate non-test live rig observes the
// actual cellsRendered transition.
module test_quad_preview_cell_refresh;

import drag_helpers : buildDragLog, fetchCamera, playAndWait;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;

import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;

void main() {}

private enum toolId = "prim.cylinder";

private void command(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command '" ~ line ~ "' failed: " ~ r.toString);
}

private ulong jsonUlong(JSONValue value) {
    switch (value.type) {
        case JSONType.uinteger: return value.uinteger;
        case JSONType.integer:  return cast(ulong)value.integer;
        case JSONType.float_:   return cast(ulong)value.floating;
        default: assert(false, "expected integer JSON, got " ~ value.toString);
    }
}

private ulong[] previewKeys(JSONValue display) {
    ulong[] keys;
    foreach (cell; display["cells"].array) {
        assert("toolPreviewKey" in cell,
            "/api/viewport/display omitted toolPreviewKey: " ~ cell.toString);
        keys ~= jsonUlong(cell["toolPreviewKey"]);
    }
    return keys;
}

private double queryFloat(string name) {
    auto r = postJson("/api/command", "tool.attr " ~ toolId ~ " " ~ name ~ " ?");
    assert(r["status"].str == "ok", "attribute query failed: " ~ r.toString);
    return r["value"].floating;
}

private void cleanup() {
    try command("tool.set " ~ toolId ~ " off"); catch (Exception) {}
    try command("viewport.layout Single"); catch (Exception) {}
}

unittest {
    scope(exit) cleanup();

    auto reset = postJson("/api/command", commandBody("scene.reset", `{"empty":true}`));
    assert(reset["status"].str == "ok", "empty reset failed: " ~ reset.toString);

    // Capture the full editor viewport before Quad divides it. The event log's
    // VIEWPORT row names this owner rect; mouse coordinates below land in the
    // bottom-right Perspective cell.
    auto full = fetchCamera();
    assert(full.width > 16 && full.height > 16,
        "viewport is too small to build a four-cell drag witness");

    command("viewport.layout Quad");
    Thread.sleep(150.msecs);
    auto display = getJson("/api/viewport/display");
    assert(jsonUlong(display["cellCount"]) == 4,
        "viewport.layout Quad did not take: cellCount="
        ~ display["cellCount"].toString);

    command("tool.set " ~ toolId);
    const halfW = full.width / 2;
    const halfH = full.height / 2;
    const cx = full.vpX + halfW + (full.width - halfW) / 2;
    const cy = full.vpY + halfH + (full.height - halfH) / 2;
    playAndWait(buildDragLog(full.vpX, full.vpY, full.width, full.height,
                             cx, cy, cx + 70, cy + 55, 12));
    Thread.sleep(150.msecs);

    immutable sizeBefore = queryFloat("sizeX");
    assert(sizeBefore > 0.01,
        "cylinder base drag produced no live preview; sizeX=" ~ sizeBefore.to!string);

    auto beforeDump = getJson("/api/viewport/display");
    auto before = previewKeys(beforeDump);
    assert(before.length == 4, "Quad stamp witness did not return four cells");
    foreach (key; before[1 .. $])
        assert(key == before[0],
            "toolPreviewKey must be shared across all four cells before the edit");

    command(format("tool.attr %s sizeX %.9g", toolId, sizeBefore + 0.5));

    ulong[] after;
    foreach (_; 0 .. 60) {
        after = previewKeys(getJson("/api/viewport/display"));
        if (after.length == 4 && after[0] != before[0]) break;
        Thread.sleep(50.msecs);
    }
    assert(after.length == 4 && after[0] != before[0],
        "toolPreviewKey did not move after a preview parameter change");
    foreach (key; after[1 .. $])
        assert(key == after[0],
            "toolPreviewKey must be identical across all four cells after the edit");
}
