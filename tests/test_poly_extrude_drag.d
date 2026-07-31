// Interactive drag coverage for the Polygon Extrude tool's ON-HANDLE drag.
//
// The suite already drove this tool's OFF-handle branch (a blind vertical free
// drag measured from the press pixel), but never the handle itself — and the
// handle is the branch that runs the per-event increment. That increment now
// takes its previous pixel from the cooked gesture and cross-checks it against
// the tool's own, so it needs a test that actually enters it.
//
// Telling the two branches apart is the whole design of this test. A press that
// MISSES the arrow silently becomes the free drag, which also moves `distance`
// — so "distance changed" alone would prove nothing. The gesture here is
// therefore purely HORIZONTAL: the free branch reads only `e.y - dragStartMY`,
// so a horizontal drag leaves it at exactly zero, while the on-handle branch
// projects the pixel delta onto the extrude axis and moves. The +X face is
// chosen because its axis projects with a large horizontal component under the
// default camera, so that projection is far from degenerate.
//
// The press point is reconstructed from the arrow's own geometry rather than
// from /api/tool/handles: this tool does not override toolHandlesJson, so the
// endpoint reports no parts for it.

import std.conv : to;
import std.json;
import std.math : abs;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "poly.extrude";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double queryDistance() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " distance ?");
    assert(r["status"].str == "ok", "query distance failed: " ~ r.toString);
    return r["value"].floating;
}

unittest { // a purely horizontal drag on the arrow moves `distance`
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    // Face 3 is the cube's +X face: centroid (0.5,0,0), averaged normal +X.
    r = postJson("/api/select", `{"mode":"polygons","indices":[3]}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");

    // Settle so a draw() frame has built the gizmo frame the press hit-tests
    // against. The shaft runs from anchor + axis*(arm/6) to anchor + axis*arm
    // with arm = gizmoSize(anchor, vp) — the same 90 px target the running
    // gizmo uses — so 0.6*arm lands mid-shaft.
    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(200));

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 anchor = Vec3(0.5f, 0.0f, 0.0f);
    Vec3 axis   = Vec3(1.0f, 0.0f, 0.0f);
    float arm   = gizmoSize(anchor, vp);
    Vec3 press  = anchor + axis * (arm * 0.6f);

    float ax, ay, tx, ty, px, py;
    assert(projectToWindow(anchor, vp, ax, ay), "anchor projects behind camera");
    assert(projectToWindow(anchor + axis, vp, tx, ty),
        "anchor + X projects behind camera");
    assert(projectToWindow(press, vp, px, py), "shaft mid-point is off-camera");
    double sdx = tx - ax;
    assert(abs(sdx) > 20.0,
        "the extrude axis must project with a real horizontal component for "
        ~ "this test to separate the two branches, got " ~ sdx.to!string);

    // Purely horizontal, in whichever direction grows the projection.
    int x0 = cast(int) px, y0 = cast(int) py;
    int x1 = x0 + (sdx > 0 ? 80 : -80);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y0, 16), BASE);
    Thread.sleep(dur!"msecs"(120));

    double after = queryDistance();
    assert(after > 1e-3,
        "a horizontal drag on the extrude arrow should have driven distance "
        ~ "positive — a press that missed the arrow would have fallen into "
        ~ "the free branch, which reads only vertical travel and would have "
        ~ "left it at 0. Got " ~ after.to!string);

    cmd("tool.set " ~ TOOL ~ " off");
}
