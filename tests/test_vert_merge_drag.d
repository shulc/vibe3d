// Interactive drag coverage for the Vertex Merge tool's haul.
//
// Same gap, same reason as tests/test_poly_inset_drag.d: tests/test_vert_merge_tool.d
// drives this tool entirely through `tool.attr` + `tool.doApply`, so its MOTION
// path — the per-event pixel increment — has no other test. The conversion
// carries a runtime agreement check between the cooked gesture and the tool's
// own previous pixel, and a check nothing reaches is not a check.
//
// WHY THIS FILE WAS REWRITTEN (task 2690), and it is NOT the failure the two
// extrude pins had. THE DRAG WAS NEVER BROKEN — THE CAMERA WAS. `dist` is a
// WORLD threshold hauled in SCREEN pixels, so its gain per pixel scales with
// the camera's distance to the scene. On the framing this file used to inherit,
// the 60 px haul bought:
//
//     dist = 0.033   <- the shipped assertion (after > before + 1e-4) passed on this
//
// against a cube whose selected vertices stand 1.0 apart. Nothing came within
// anything: zero planes moved, zero undo entries. And it is not a matter of
// hauling further — measured on this stand, 120 px -> 0.097, 240 px -> 0.225,
// 400 px -> 0.443, 700 px -> 0.821, and ZERO planes moved at every one of them.
// A test that read this as "the drag is too short" would have lengthened a
// gesture that was already correct.
//
// What makes the same gesture a real merge is the CAMERA: at distance 40 a
// 400 px haul reaches dist 1.53, four vertices collapse into one (8 -> 5) and
// the drop records. So the framing below is PART OF THE GESTURE, not decoration,
// and the assertion is that the vertex count FELL — not that a number rose.
//
// `built` IS NOT AVAILABLE HERE, and that is measured: `/api/tool/state`
// publishes it for exactly six tools tree-wide (edge_extend, edge_extrude,
// edge_bevel, poly_bevel, edge_slice, loop_slice — `grep -rn '"built"' source/`)
// and `vert.merge` answers `{}`. A FALLEN VERTEX COUNT stands in for it and is
// strictly stronger on this tool: `built` would be the tool's claim that its
// kernel did work, and a collapsed count is that work read off the mesh.
//
// The tool draws no handle: any qualifying click in vertex mode begins the haul,
// anchored at the selected vertices' centroid. Only the vertical travel matters
// — dragging UP (screen y decreasing) increases the merge distance.

import http_client : testBaseUrl, getJson, postJson;
import std.algorithm : canFind, sort;
import std.conv : to;
import std.json;
import std.net.curl : get, post;

import plane_diff_helpers;
import drag_helpers;

void main() {}

alias BASE = testBaseUrl;
enum string TOOL = "vert.merge";

string getRaw(string path) { return cast(string) get(BASE ~ path); }


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

// --- the acceptance witness -------------------------------------------------
//
// EVERY CHANNEL BELOW FAILS CLOSED, which is why this file needs no separate
// positive control: each assertion is "something MOVED", so a `/api/mesh/planes`
// serving a stale copy leaves `moved` empty and goes RED, and an `/api/history`
// that stopped tracking leaves the delta at 0 and goes RED.

string planes() { return getRaw("/api/mesh/planes"); }
long undoLen() { return cast(long) getJson("/api/history")["undo"].array.length; }
size_t vertexCount() { return getJson("/api/model")["vertices"].array.length; }

unittest { // an upward haul at a framing where `dist` can actually reach a neighbour
    import core.thread : Thread;
    import core.time   : dur;

    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    r = postJson("/api/select", `{"mode":"vertices","indices":[0,1,2,3]}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    // DISTANCE 40, AND THAT NUMBER IS THE FIX. See the header: the same haul on
    // a close framing raises `dist` and merges nothing, at any length.
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":40.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");
    Thread.sleep(dur!"msecs"(250));

    immutable string planesBefore = planes();
    immutable long   u0           = undoLen();
    immutable size_t v0           = vertexCount();
    immutable double before       = queryDist();

    // Press anywhere in the viewport — no handle to hit, the haul anchors at
    // the selection centroid. 400 px UP is the whole gesture.
    auto cam = fetchCamera(BASE);
    immutable int cx = cam.vpX + cam.width  / 2;
    immutable int cy = cam.vpY + cam.height / 2;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cx, cy + 200, cx, cy - 200, 16), BASE);
    Thread.sleep(dur!"msecs"(120));

    immutable double after = queryDist();
    assert(after > before + 1e-4,
        "a 400 px upward haul should have raised dist above " ~ before.to!string
        ~ ", got " ~ after.to!string);

    // THE CHECK THE OLD FILE DID NOT HAVE, half one: vertices actually MERGED.
    // `dist` rising proves the motion path ran; only a fallen count proves the
    // threshold ever reached a neighbour.
    immutable size_t v1 = vertexCount();
    assert(v1 < v0,
        "the haul merged nothing (still " ~ v0.to!string ~ " vertices) even "
        ~ "though `dist` reads " ~ after.to!string ~ ". That is the failure "
        ~ "this file shipped for months: `dist` is a WORLD threshold hauled in "
        ~ "PIXELS, and on a close framing it rises to a value smaller than the "
        ~ "1.0 spacing of the selected cube vertices at every haul the viewport "
        ~ "can hold. The fix is the CAMERA, not a longer drag");

    cmd("tool.set " ~ TOOL ~ " off");
    Thread.sleep(dur!"msecs"(250));

    // ...and half two: a PLANE actually moved, and the drop recorded it.
    auto moved = planeDiff(planesBefore, planes());
    assert(moved.canFind("vertices") && moved.canFind("counts"),
        "the gesture and its drop moved planes " ~ moved.to!string
        ~ " — `vertices` and `counts` are not both among them, so the mesh is "
        ~ "byte-identical to what it was before the haul");
    assert(undoLen() - u0 == 1,
        "the drop recorded " ~ (undoLen() - u0).to!string ~ " undo entr(ies), "
        ~ "expected exactly 1 — a haul that merged nothing commits nothing");
}
