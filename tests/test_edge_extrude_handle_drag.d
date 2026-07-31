// Interactive drag coverage for the Edge Extrude tool's ON-HANDLE drag.
//
// tests/test_undo_tracker_extrude.d already drives this tool through real
// events, but only its OFF-handle branch — the blind 2-axis free drag, which
// measures from the PRESS pixel. The on-handle branch, the one that projects a
// per-event pixel increment onto the extrude axis, had no test at all. That
// increment now takes its previous pixel from the cooked gesture and
// cross-checks it against the tool's own, so it needs a test that enters it.
//
// Separating the branches: a press that misses both arrows becomes the free
// drag, and the free drag moves `extrude` from VERTICAL travel only
// (`-dy * FREE_SCALE`). So the gesture here is purely HORIZONTAL — a miss
// would leave `extrude` at exactly 0, and a non-zero `extrude` is evidence the
// press landed on the arrow.
//
// Geometry: one edge of the cube at x = +0.5, z = -0.5. Its two adjacent faces
// are the +X and -Z faces, so the averaged normal — the extrude axis — is the
// diagonal (1,0,-1)/sqrt(2), which projects with a large horizontal component
// under the default camera.

import std.conv : to;
import std.json;
import std.math : abs;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "edge.extrude";

JSONValue getJson(string path)  { return parseJSON(cast(string) get(BASE ~ path)); }
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double queryExtrude() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " extrude ?");
    assert(r["status"].str == "ok", "query extrude failed: " ~ r.toString);
    return r["value"].floating;
}

// The cube's edge index whose two endpoints both sit at x=+0.5, z=-0.5.
// Looked up rather than hard-coded: edge order is a mesh-build detail.
int findEdgeXPosZNeg() {
    auto model = getJson("/api/model");
    auto verts = model["vertices"].array;
    foreach (i, e; model["edges"].array) {
        int a = cast(int) e.array[0].integer;
        int b = cast(int) e.array[1].integer;
        auto pa = verts[a].array, pb = verts[b].array;
        if (abs(pa[0].floating - 0.5) < 1e-4 && abs(pb[0].floating - 0.5) < 1e-4 &&
            abs(pa[2].floating + 0.5) < 1e-4 && abs(pb[2].floating + 0.5) < 1e-4)
            return cast(int) i;
    }
    return -1;
}

unittest { // a purely horizontal drag on the extrude arrow moves `extrude`
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    int ei = findEdgeXPosZNeg();
    assert(ei >= 0, "no cube edge found at x=+0.5, z=-0.5");
    r = postJson("/api/select",
        `{"mode":"edges","indices":[` ~ ei.to!string ~ `]}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");

    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(200));

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    // Anchor = midpoint of the selected edge; axis = averaged adjacent-face
    // normal. The shaft runs from anchor + axis*(arm/6) to anchor + axis*arm.
    Vec3 anchor = Vec3(0.5f, 0.0f, -0.5f);
    enum float R = 0.70710678f;
    Vec3 axis   = Vec3(R, 0.0f, -R);
    float arm   = gizmoSize(anchor, vp);
    Vec3 press  = anchor + axis * (arm * 0.6f);

    float ax, ay, tx, ty, px, py;
    assert(projectToWindow(anchor, vp, ax, ay), "anchor projects behind camera");
    assert(projectToWindow(anchor + axis, vp, tx, ty),
        "anchor + axis projects behind camera");
    assert(projectToWindow(press, vp, px, py), "shaft mid-point is off-camera");
    double sdx = tx - ax;
    assert(abs(sdx) > 20.0,
        "the extrude axis must project with a real horizontal component for "
        ~ "this test to separate the two branches, got " ~ sdx.to!string);

    int x0 = cast(int) px, y0 = cast(int) py;
    int x1 = x0 + (sdx > 0 ? 80 : -80);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y0, 16), BASE);
    Thread.sleep(dur!"msecs"(120));

    double after = queryExtrude();
    assert(after > 1e-3,
        "a horizontal drag on the extrude arrow should have driven extrude "
        ~ "positive — a press that missed both arrows would have fallen into "
        ~ "the free branch, which reads only vertical travel for extrude and "
        ~ "would have left it at 0. Got " ~ after.to!string);

    cmd("tool.set " ~ TOOL ~ " off");
}
