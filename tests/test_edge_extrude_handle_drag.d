// Interactive drag coverage for the Edge Extrude tool's ON-HANDLE drag.
//
// tests/test_undo_tracker_extrude.d already drives this tool through real
// events, but only its OFF-handle branch — the blind 2-axis free drag, which
// measures from the PRESS pixel. The on-handle branch, the one that projects a
// per-event pixel increment onto the extrude axis, had no test at all. That
// increment takes its previous pixel from the cooked gesture and cross-checks
// it against the tool's own, so it needs a test that enters it.
//
// WHY THIS FILE WAS REWRITTEN (task 2690). Until now the gesture here grabbed
// the EXTRUDE arrow ALONE and the only thing asserted was the `extrude`
// attribute. Measured on this very stand, that gesture is EMPTY:
//
//     extrude = 0.524   <- the shipped assertion passed on this
//     width   = 0
//     /api/tool/state  "built": false
//     /api/mesh/planes before vs after: NOT ONE PLANE MOVED
//     the drop recorded ZERO undo entries
//
// The extrude arrow alone moves a number; the kernel `extrudeEdgesByMask`
// needs a non-zero WIDTH before it touches a single edge, and with n == 0 the
// tool never sets `built`, so `deactivate()` commits nothing. An attribute is
// not a witness that a tool built something — it is a witness that a drag
// began. So the gesture now grabs the WIDTH box (part 1) FIRST and the extrude
// arrow (part 0) second, and the assertions are the two the acceptance
// criterion names: the tool reports itself BUILT, and a PLANE actually moved.
//
// Both press points come from `/api/tool/handles` rather than from a local
// re-derivation of the arm geometry: a re-derivation that drifts away from the
// tool silently turns the drag back into the non-gesture described above, and
// nothing would say so.
//
// Separating the on-handle branch from the free one is still part of the
// design: a press that misses both arrows becomes the free drag, which moves
// `extrude` from VERTICAL travel only (`-dy * FREE_SCALE`). Both drags here
// are purely HORIZONTAL, so the free branch could not have produced any of it.
//
// Geometry: one edge of the cube at x = +0.5, z = -0.5. Its two adjacent faces
// are the +X and -Z faces, so the averaged normal — the extrude axis — is the
// diagonal (1,0,-1)/sqrt(2), which projects with a large horizontal component
// under the framing this file pins.

import std.algorithm : canFind, sort;
import std.conv : to;
import std.json;
import std.math : abs;
import std.net.curl : get, post;

import plane_diff_helpers;
import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "edge.extrude";

string getRaw(string path)  { return cast(string) get(BASE ~ path); }
JSONValue getJson(string path)  { return parseJSON(getRaw(path)); }
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

// --- the acceptance witness -------------------------------------------------
//
// THESE THREE CHANNELS FAIL CLOSED, which is why this file carries no separate
// positive control while tests/test_tool_gesture_g1.d does. That file asserts
// "the fresh dump EQUALS the frozen one" and "this residual is EMPTY" — a dead
// channel satisfies both for free, so it has to prove its channels alive first.
// Here every assertion is "something MOVED": a `/api/mesh/planes` answering a
// stale copy makes `moved` empty and the assert RED, an `/api/history` that
// stopped tracking makes the delta 0 and the `== 1` RED, and a `/api/tool/state`
// that dropped `built` throws on the key. A dead channel cannot make this file
// green.

/// The PLANE-COMPLETE readback. `/api/model` is not a substitute: it carries no
/// marks, no set masks and no per-face material/part, all of which are planes a
/// commit can move and an undo can lose.
string planes() { return getRaw("/api/mesh/planes"); }

long undoLen() { return cast(long) getJson("/api/history")["undo"].array.length; }

/// The screen anchor of a registered handle part.
void handlePx(int part, out int x, out int y) {
    auto h = getJson("/api/tool/handles")["handles"];
    assert(h.type != JSONType.null_,
        TOOL ~ " publishes no handle arbiter — part " ~ part.to!string
      ~ " cannot be grabbed, and a drag that grabs nothing is the empty "
      ~ "gesture this file exists to reject");
    foreach (p; h["parts"].array) {
        if (cast(int) p["part"].integer != part) continue;
        assert(p["screen"].type != JSONType.null_,
            "handle part " ~ part.to!string ~ " is off-camera");
        x = cast(int) p["screen"].array[0].floating;
        y = cast(int) p["screen"].array[1].floating;
        return;
    }
    assert(false, "no handle part " ~ part.to!string);
}

void drag(int x0, int y0, int x1, int y1, int steps = 12) {
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, steps), BASE);
    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(120));
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

unittest { // width, then a horizontal haul on the extrude arrow, and the tool builds
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    int ei = findEdgeXPosZNeg();
    assert(ei >= 0, "no cube edge found at x=+0.5, z=-0.5");
    r = postJson("/api/select",
        `{"mode":"edges","indices":[` ~ ei.to!string ~ `]}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    // The framing is PART OF THE GESTURE, not decoration: the handle anchors
    // this test grabs are read back per-frame, so the camera has to be pinned
    // or the two drags read a different arm on a different default.
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");

    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(250));

    immutable string planesBefore = planes();
    immutable long   u0           = undoLen();
    immutable size_t v0           = getJson("/api/model")["vertices"].array.length;

    // 1. the WIDTH box. Without it the kernel affects zero edges no matter how
    //    far the extrude arrow is hauled.
    int wx, wy; handlePx(1, wx, wy);
    drag(wx, wy, wx - 40, wy);

    // 2. the EXTRUDE arrow, purely horizontal.
    int ex, ey; handlePx(0, ex, ey);
    drag(ex, ey, ex + 70, ey);

    double after = queryExtrude();
    assert(after > 1e-3,
        "a horizontal drag on the extrude arrow should have driven extrude "
        ~ "positive — a press that missed both arrows would have fallen into "
        ~ "the free branch, which reads only vertical travel for extrude and "
        ~ "would have left it at 0. Got " ~ after.to!string);

    // THE CHECK THE OLD FILE DID NOT HAVE, half one: the tool says it BUILT.
    // `edge.extrude` is one of only six tools tree-wide that publish this
    // (edge_extend, edge_extrude, edge_bevel, poly_bevel, edge_slice,
    // loop_slice), so here the acceptance criterion is asserted literally.
    auto st = getJson("/api/tool/state");
    assert(st["built"].type == JSONType.true_,
        "the two handle drags left `built` FALSE while extrude reads "
        ~ after.to!string ~ ": " ~ st.toString ~ ". That is the empty gesture "
        ~ "this file shipped for months — `extrudeEdgesByMask` returned 0, so "
        ~ "the tool built nothing and the drop will record nothing, and an "
        ~ "attribute assertion cannot tell the difference");

    cmd("tool.set " ~ TOOL ~ " off");
    Thread.sleep(dur!"msecs"(250));

    // ...and half two: a PLANE actually moved, and the drop recorded it.
    auto moved = planeDiff(planesBefore, planes());
    assert(moved.canFind("vertices") && moved.canFind("counts"),
        "the gesture and its drop moved planes " ~ moved.to!string
        ~ " — `vertices` and `counts` are not both among them, so the mesh is "
        ~ "byte-identical to what it was before the drag. A tool attribute can "
        ~ "hold any value over that");
    immutable size_t v1 = getJson("/api/model")["vertices"].array.length;
    assert(v1 > v0,
        "the extrude added no vertex (still " ~ v0.to!string ~ ")");
    assert(undoLen() - u0 == 1,
        "the drop recorded " ~ (undoLen() - u0).to!string ~ " undo entr(ies), "
        ~ "expected exactly 1 — `deactivate()` commits only when the tool is "
        ~ "`built`, so 0 here means the whole gesture was a no-op");
}
