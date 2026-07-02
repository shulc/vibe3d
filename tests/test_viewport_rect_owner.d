// Cell-rect single-owner regression guard (task 0182 / V1).
//
// The per-frame force-feed that used to stamp the ACTIVE cell's camera with
// the full 3D-area size (overriding whatever the true cell rect was) has been
// removed: the cell rect now has exactly one owner (the cell's camera). This
// is a DELIBERATE, non-byte-stable behaviour change for non-Single layouts —
// before the fix, the active cell's projection aspect used the full-area
// size; after the fix it uses its true half/quarter cell size.
//
// Without a direct assertion here, a regression that reintroduces the
// force-feed would ship green: test_viewport_follower_pick.d reads width
// dynamically and test_viewport_gizmo_origin.d tolerates the stomp, but
// neither asserts the size OWNER. This test does.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body) {
    return parseJSON(cast(string)post(baseUrl ~ path, body));
}

void runCmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double cameraWidth(int viewportIdx) {
    auto j = parseJSON(cast(string)get(
        baseUrl ~ "/api/camera?viewport=" ~ viewportIdx.to!string));
    return cast(double)j["width"].integer;
}

unittest { // SplitH: active cell (0) width == half the full-area width
    postJson("/api/reset", "{}");

    // Single layout: cell 0 spans the whole 3D area — this is the reference
    // "full-area width" the force-feed used to stamp onto every layout.
    double fullWidth = cameraWidth(0);
    assert(fullWidth > 0, "full-area width must be positive");

    runCmd(`{"id":"viewport.layout","params":"SplitH"}`);

    // The view owns its true cell size now: cell 0 (left half) must be
    // approximately half the full-area width, NOT the full-area width the
    // per-frame force-feed used to stamp on it every frame.
    double cell0Width = cameraWidth(0);
    double expectedHalf = fullWidth / 2.0;
    assert(abs_(cell0Width - expectedHalf) <= 1.0,
        "SplitH cell 0 width should be ~half the full-area width " ~
        "(full=" ~ fullWidth.to!string ~ ", half=" ~ expectedHalf.to!string ~
        ", got=" ~ cell0Width.to!string ~ ") — the active cell must own " ~
        "its true rect, not the full 3D-area size");
    assert(cell0Width < fullWidth - 1.0,
        "SplitH cell 0 width must be SMALLER than the full-area width " ~
        "(regression: force-feed re-stamped the full-area size) — " ~
        "full=" ~ fullWidth.to!string ~ ", got=" ~ cell0Width.to!string);

    postJson("/api/reset", "{}");
}

unittest { // Quad: active cell (0) width == quarter the full-area width
    postJson("/api/reset", "{}");

    double fullWidth = cameraWidth(0);

    runCmd(`{"id":"viewport.layout","params":"Quad"}`);

    double cell0Width = cameraWidth(0);
    double expectedQuarter = fullWidth / 2.0;   // Quad halves width (2 columns)
    assert(abs_(cell0Width - expectedQuarter) <= 1.0,
        "Quad cell 0 width should be ~half the full-area width (2 columns) " ~
        "(full=" ~ fullWidth.to!string ~ ", expected=" ~
        expectedQuarter.to!string ~ ", got=" ~ cell0Width.to!string ~ ")");
    assert(cell0Width < fullWidth - 1.0,
        "Quad cell 0 width must be SMALLER than the full-area width " ~
        "(regression: force-feed re-stamped the full-area size)");

    postJson("/api/reset", "{}");
}

private double abs_(double x) { return x < 0 ? -x : x; }
