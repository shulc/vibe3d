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
//
// WHAT THIS FILE WAS MISSING (task 2690), and it is NOT the failure the two
// extrude handle pins had. Measured on this stand, THE DRAG HERE IS REAL: it
// moves twelve planes, grows the cube from 8 vertices to 12 and records one
// undo entry. The defect was the ASSERTION — `distance > 1e-3` and nothing
// else. `distance` is a tool attribute, and an attribute rises on a gesture
// whose kernel touched nothing; that is exactly how the two sibling files in
// this family shipped green over an empty drag. So a no-op regression in
// `PolyExtrudeTool.rebuildPreview` — the kernel returning 0, `built` staying
// false, `deactivate()` committing nothing — would have left this file green.
// It now asserts the two things the acceptance criterion names: the tool
// built, and a plane actually moved.
//
// `built` IS NOT AVAILABLE ON THE WIRE HERE, and that is measured rather than
// assumed: `/api/tool/state` publishes it for exactly six tools tree-wide
// (edge_extend, edge_extrude, edge_bevel, poly_bevel, edge_slice, loop_slice —
// `grep -rn '"built"' source/`), and `poly.extrude` answers `{}` even though it
// carries the flag internally. A GROWN VERTEX COUNT stands in for it and is
// strictly stronger: `built = (n != 0)` is the tool's own claim about its
// kernel's return, and the count is that claim's consequence read off the mesh.

import http_client : testBaseUrl, getJson, postJson;
import std.algorithm : canFind, sort;
import std.conv : to;
import std.json;
import std.math : abs;
import std.net.curl : get, post;

import plane_diff_helpers;
import drag_helpers;

void main() {}

alias BASE = testBaseUrl;
enum string TOOL = "poly.extrude";

string getRaw(string path) { return cast(string) get(BASE ~ path); }


// --- the acceptance witness -------------------------------------------------
//
// EVERY CHANNEL BELOW FAILS CLOSED, which is why this file needs no separate
// positive control: each assertion is "something MOVED", so a `/api/mesh/planes`
// serving a stale copy leaves `moved` empty and goes RED, and an `/api/history`
// that stopped tracking leaves the delta at 0 and goes RED. (The frozen fixtures
// in tests/test_tool_gesture_g*.d assert "EQUAL" and "EMPTY", which a dead
// channel satisfies for free — that is why THEY open with a control.)

/// The PLANE-COMPLETE readback. `/api/model` is not a substitute: it carries no
/// marks, no set masks and no per-face material/part.
string planes() { return getRaw("/api/mesh/planes"); }
long undoLen() { return cast(long) getJson("/api/history")["undo"].array.length; }
size_t vertexCount() { return getJson("/api/model")["vertices"].array.length; }

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

    // The framing is PART OF THE GESTURE: the press point is derived from the
    // arm at the live camera, so the camera is pinned rather than inherited.
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");

    // Settle so a draw() frame has built the gizmo frame the press hit-tests
    // against. The shaft runs from anchor + axis*(arm/6) to anchor + axis*arm
    // with arm = gizmoSize(anchor, vp) — the same 90 px target the running
    // gizmo uses — so 0.6*arm lands mid-shaft.
    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(200));

    immutable string planesBefore = planes();
    immutable long   u0           = undoLen();
    immutable size_t v0           = vertexCount();

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

    // THE CHECK THIS FILE DID NOT HAVE, half one: the kernel emitted geometry.
    // This stands in for `built`, which this tool does not put on the wire.
    immutable size_t v1 = vertexCount();
    assert(v1 > v0,
        "the drag added no vertex (still " ~ v0.to!string ~ ") while distance "
        ~ "reads " ~ after.to!string ~ ". `rebuildPreview` sets `built` from "
        ~ "its kernel's return and `deactivate()` commits only when built, so "
        ~ "a kernel that touched nothing leaves the attribute exactly where "
        ~ "this test used to stop looking");

    cmd("tool.set " ~ TOOL ~ " off");
    Thread.sleep(dur!"msecs"(250));

    // ...and half two: a PLANE actually moved, and the drop recorded it.
    auto moved = planeDiff(planesBefore, planes());
    assert(moved.canFind("vertices") && moved.canFind("counts"),
        "the gesture and its drop moved planes " ~ moved.to!string
        ~ " — `vertices` and `counts` are not both among them, so the mesh is "
        ~ "byte-identical to what it was before the drag. A tool attribute can "
        ~ "hold any value over that");
    assert(undoLen() - u0 == 1,
        "the drop recorded " ~ (undoLen() - u0).to!string ~ " undo entr(ies), "
        ~ "expected exactly 1 — `deactivate()` commits only when the tool "
        ~ "built, so 0 here means the whole gesture was a no-op");
}
