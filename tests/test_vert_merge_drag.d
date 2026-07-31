// Interactive drag coverage for the Vertex Merge tool's haul.
//
// Same gap, same reason as tests/test_poly_inset_drag.d: tests/test_vert_merge_tool.d
// drives this tool entirely through `tool.attr` + `tool.doApply`, so its MOTION
// path — the per-event pixel increment — had no test at all. The conversion now
// carries a runtime agreement check between the cooked gesture and the tool's
// own previous pixel, and a check nothing reaches is not a check.
//
// The tool draws no handle: any qualifying click in vertex mode begins the haul,
// anchored at the selected vertices' centroid. Only the vertical travel matters
// — dragging UP (screen y decreasing) increases the merge distance.

import std.conv : to;
import std.json;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "vert.merge";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double queryDist() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " dist ?");
    assert(r["status"].str == "ok", "query dist failed: " ~ r.toString);
    return r["value"].floating;
}

unittest { // an upward haul drives `dist` up through the motion path
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    r = postJson("/api/select", `{"mode":"vertices","indices":[0,1,2,3]}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");
    double before = queryDist();

    // Press anywhere in the viewport — no handle to hit, the haul anchors at
    // the selection centroid. 60 px UP is the whole gesture.
    auto cam = fetchCamera(BASE);
    int cx = cam.vpX + cam.width  / 2;
    int cy = cam.vpY + cam.height / 2;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cx, cy, cx, cy - 60, 12), BASE);

    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(120));

    double after = queryDist();
    assert(after > before + 1e-4,
        "a 60 px upward haul should have raised dist above " ~ before.to!string
        ~ ", got " ~ after.to!string);

    cmd("tool.set " ~ TOOL ~ " off");
}
