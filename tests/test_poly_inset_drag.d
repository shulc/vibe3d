// Interactive drag coverage for the Polygon Inset tool's haul.
//
// Why this file exists: the inset tool's `inset` param is exercised all over
// tests/test_poly_inset.d, but only through `tool.attr` — nothing in the suite
// ever drove its MOTION path. That matters beyond coverage bookkeeping: the
// per-event increment conversion carries a runtime agreement check (drag.d's
// `gesturePrevPixel`, live in every `debug` build), and a check that no test
// reaches proves nothing. This test makes it reachable.
//
// The tool draws no handle — any qualifying click in polygon mode begins the
// haul — so the press point is arbitrary and only the HORIZONTAL travel
// carries meaning: dragging RIGHT increases inset (law §27, task 7122, which
// changed this file's gesture from 60 px UP to 60 px RIGHT with the same
// assertion; per-increment values: tests/test_poly_inset_drag_value.d).

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.json;
import std.math : abs;
import std.format : format;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;
enum string TOOL = "mesh.polyInsetTool";


void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double queryInset() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " inset ?");
    assert(r["status"].str == "ok", "query inset failed: " ~ r.toString);
    return r["value"].floating;
}

void navigate(int modifiers) {
    playAndWait(format(
        `{"t":0.000,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":%d,"repeat":0}`,
        modifiers), BASE);
    import core.thread : Thread;
    import core.time : dur;
    Thread.sleep(dur!"msecs"(150));
}

unittest { // a rightward haul drives `inset` positive through the motion path
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    r = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[4]}`));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");
    const pre = getJson("/api/model");
    assert(abs(queryInset()) < 1e-6,
        "a freshly armed inset tool should start at 0");

    // Press anywhere inside the viewport — the tool has no handle to hit and
    // its step comes from the view's pixel size, whatever the press point.
    // 60 px RIGHT is the whole gesture.
    auto cam = fetchCamera(BASE);
    int cx = cam.vpX + cam.width  / 2;
    int cy = cam.vpY + cam.height / 2;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cx, cy, cx + 60, cy, 12), BASE);

    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(120));

    double after = queryInset();
    assert(after > 1e-4,
        "a 60 px rightward haul should have driven inset positive, got "
        ~ after.to!string);

    const dragged = getJson("/api/model");
    assert(dragged["vertexCount"].integer > pre["vertexCount"].integer,
        "the released inset gesture must change topology");
    navigate(64); // Ctrl+Z: the completed gesture, not a pending preview.
    assert(getJson("/api/model")["vertices"].toString == pre["vertices"].toString,
        "first undo must restore the pre-gesture mesh");
    navigate(65); // Ctrl+Shift+Z
    assert(getJson("/api/model")["vertices"].toString == dragged["vertices"].toString,
        "redo must restore the completed inset mesh");
    assert(abs(queryInset() - after) < 1e-6,
        "redo must restore the released Inset amount");

    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cx, cy, cx + 60, cy, 12), BASE);
    Thread.sleep(dur!"msecs"(120));
    const dragged2 = getJson("/api/model");
    const after2 = queryInset();
    assert(dragged2["vertexCount"].integer > dragged["vertexCount"].integer,
        "second released Inset must use the completed first mesh as its basis");
    navigate(64);
    assert(getJson("/api/model")["vertices"].toString == dragged["vertices"].toString
           && abs(queryInset() - after) < 1e-6,
        "undo of second Inset restores the first mesh and amount");
    navigate(64);
    assert(getJson("/api/model")["vertices"].toString == pre["vertices"].toString,
        "second undo restores the initial mesh");
    navigate(65);
    assert(getJson("/api/model")["vertices"].toString == dragged["vertices"].toString,
        "first redo restores first Inset step");
    navigate(65);
    assert(getJson("/api/model")["vertices"].toString == dragged2["vertices"].toString
           && abs(queryInset() - after2) < 1e-6,
        "second redo restores second Inset mesh and amount");

    cmd("tool.set " ~ TOOL ~ " off");
}

import std.conv : to;
