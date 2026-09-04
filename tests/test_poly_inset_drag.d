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
// haul, anchored at the selected faces' centroid — so the press point is
// arbitrary and only the VERTICAL travel carries meaning: dragging UP (screen
// y decreasing) increases inset.

import http_client : testBaseUrl, postJson;
import http_command_helpers : commandBody;
import std.json;
import std.math : abs;
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

unittest { // an upward haul drives `inset` positive through the motion path
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    r = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[4]}`));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");
    assert(abs(queryInset()) < 1e-6,
        "a freshly armed inset tool should start at 0");

    // Press anywhere inside the viewport — the tool has no handle to hit and
    // anchors the haul at the selection centroid regardless of where the
    // press landed. 60 px UP is the whole gesture.
    auto cam = fetchCamera(BASE);
    int cx = cam.vpX + cam.width  / 2;
    int cy = cam.vpY + cam.height / 2;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cx, cy, cx, cy - 60, 12), BASE);

    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(120));

    double after = queryInset();
    assert(after > 1e-4,
        "a 60 px upward haul should have driven inset positive, got "
        ~ after.to!string);

    cmd("tool.set " ~ TOOL ~ " off");
}

import std.conv : to;
