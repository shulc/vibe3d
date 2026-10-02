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

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.algorithm : canFind, sort;
import std.conv : to;
import std.json;
import std.math : abs;
import std.format : format;
import std.net.curl : get, post;

import plane_diff_helpers;
import drag_helpers;

void main() {}

alias BASE = testBaseUrl;
enum string TOOL = "edge.extrude";

string getRaw(string path)  { return cast(string) get(BASE ~ path); }


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

double queryWidth() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " width ?");
    assert(r["status"].str == "ok", "query width failed: " ~ r.toString);
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

void navigate(bool undo) {
    const mod = undo ? 64 : 65;
    playAndWait(format(
        `{"t":50,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":%s,"repeat":0}` ~ "\n"
      ~ `{"t":60,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":%s,"repeat":0}` ~ "\n",
        mod, mod), BASE);
}

void setupEdge() {
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok");
    cmd("history.clear");
    int ei = findEdgeXPosZNeg();
    assert(ei >= 0);
    r = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"edges","indices":[` ~ ei.to!string ~ `]}`));
    assert(r["status"].str == "ok");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok");
    r = postJson("/api/command?origin=ui", "tool.set " ~ TOOL ~ " on");
    assert(r["status"].str == "ok" || r["status"].str == "success");
    import core.thread : Thread;
    import core.time : dur;
    Thread.sleep(dur!"msecs"(250));
}

void rightClick(int x, int y) {
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x, y, x, y, 1, 0, 3), BASE);
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
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    int ei = findEdgeXPosZNeg();
    assert(ei >= 0, "no cube edge found at x=+0.5, z=-0.5");
    r = postJson("/api/command", commandBody("mesh.select", `{"mode":"edges","indices":[` ~ ei.to!string ~ `]}`));
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
    immutable string firstImage = planes();
    assert(firstImage != planesBefore, "first handle drag changed no mesh plane");

    // 2. the EXTRUDE arrow, purely horizontal.
    int ex, ey; handlePx(0, ex, ey);
    drag(ex, ey, ex + 70, ey);
    immutable string secondImage = planes();
    assert(secondImage != firstImage, "second handle drag changed no mesh plane");
    navigate(true);
    assert(planes() == firstImage,
        "live Ctrl+Z did not restore the first completed Edge step");
    assert(undoLen() == u0 + 1, "live Ctrl+Z did not move one history row");
    navigate(false);
    assert(planes() == secondImage,
        "live Ctrl+Shift+Z did not restore the second Edge step");
    assert(undoLen() == u0 + 2, "live redo did not restore one history row");

    // A motionless Middle press clones the current operation on the selected
    // ridge. It is a row of its own and its undo restores the prior group.
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
        ex, ey, ex, ey, 1, 0, 2), BASE);
    immutable string middleImage = planes();
    assert(middleImage != secondImage,
        "Middle clone did not build a second topology operation");
    assert(undoLen() == u0 + 3,
        "Middle boundary did not append its own history row");
    navigate(true);
    assert(planes() == secondImage,
        "Middle undo did not restore the first operation end");
    navigate(false);
    assert(planes() == middleImage,
        "Middle redo did not restore the cloned operation");

    auto pr = postJson("/api/script?interactive=true",
        "tool.attr edge.extrude width 0.2\n");
    assert(pr["status"].str == "ok" || pr["status"].str == "success",
        "interactive Edge parameter write failed: " ~ pr.toString);
    immutable string paramImage = planes();
    assert(paramImage != middleImage,
        "interactive Width did not update the preview mesh");
    assert(undoLen() == u0 + 4,
        "interactive Width did not append its own history row");
    navigate(true);
    assert(planes() == middleImage,
        "interactive Width undo did not restore Middle image");
    navigate(false);
    assert(planes() == paramImage,
        "interactive Width redo did not restore its preview");

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

    cmd("tool.set move on");
    Thread.sleep(dur!"msecs"(250));
    assert(undoLen() == u0 + 5,
        "switch wrote a duplicate cumulative Edge row");
    navigate(true);
    assert(planes() == paramImage && undoLen() == u0 + 4,
        "outside z1 did not remove the Move activation alone");
    navigate(true);
    assert(planes() == middleImage && undoLen() == u0 + 3,
        "outside z2 did not remove the independent Width row");
    navigate(true);
    assert(planes() == secondImage && undoLen() == u0 + 2,
        "outside z3 did not remove the independent Middle row");

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
    assert(undoLen() - u0 == 2,
        "outside z3 must leave the two distinct handle rows");
}

unittest { // A foreign UiState row must beat completed-step cancel handling.
    setupEdge();
    immutable string initial = planes();
    int x, y; handlePx(1, x, y);
    drag(x, y, x - 40, y);
    immutable string completed = planes();
    immutable long d0 = undoLen();
    assert(completed != initial,
        "foreign-row fixture did not complete an Edge topology step");

    auto r = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"edges","indices":[]}`));
    assert(r["status"].str == "ok" && undoLen() == d0 + 1,
        "script-origin mesh.select did not append its UiState row");

    navigate(true);
    assert(undoLen() == d0,
        "completed Edge state intercepted Undo ahead of the foreign UiState row: depth "
        ~ undoLen().to!string ~ ", expected " ~ d0.to!string);
    navigate(true);
    assert(undoLen() == d0 - 1 && planes() == initial,
        "Undo remained trapped instead of reaching the completed Edge row");
}

unittest { // A zero Middle boundary has its own cursor despite equal images.
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok");
    cmd("history.clear");
    int ei = findEdgeXPosZNeg();
    assert(ei >= 0);
    r = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"edges","indices":[` ~ ei.to!string ~ `]}`));
    assert(r["status"].str == "ok");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok");
    cmd("tool.set " ~ TOOL ~ " on");
    import core.thread : Thread;
    import core.time : dur;
    Thread.sleep(dur!"msecs"(250));
    immutable string image = planes();
    immutable long u0 = undoLen();
    int x, y; handlePx(0, x, y);
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x, y, x, y, 1, 0, 2), BASE);
    assert(planes() == image, "zero Middle changed mesh image");
    assert(undoLen() == u0 + 1, "zero Middle omitted cursor row");
    navigate(true);
    assert(planes() == image && undoLen() == u0,
        "zero Middle undo failed to step its distinct row");
    navigate(false);
    assert(planes() == image && undoLen() == u0 + 1,
        "zero Middle redo failed to restore its distinct row");
    cmd("tool.set " ~ TOOL ~ " off");
}

unittest { // Edge first group: two Undos remove g1 and then its activation.
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok");
    cmd("history.clear");
    int ei = findEdgeXPosZNeg();
    assert(ei >= 0);
    r = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"edges","indices":[` ~ ei.to!string ~ `]}`));
    assert(r["status"].str == "ok");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok");
    r = postJson("/api/command?origin=ui", "tool.set " ~ TOOL ~ " on");
    assert(r["status"].str == "ok" || r["status"].str == "success");
    import core.thread : Thread;
    import core.time : dur;
    Thread.sleep(dur!"msecs"(250));
    immutable string initial = planes();
    immutable long u0 = undoLen();
    int x, y; handlePx(1, x, y);
    drag(x, y, x - 40, y);
    immutable string first = planes();
    assert(first != initial && undoLen() == u0 + 1,
        "fresh replay fixture did not build first step");
    navigate(true);
    assert(planes() == initial && undoLen() == u0,
        "Edge z1 must remove g1 while retaining its armed activation: u0 " ~ u0.to!string
        ~ ", now " ~ undoLen().to!string ~ ", plane delta "
        ~ planeDiff(initial, planes()).to!string);
    navigate(true);
    assert(planes() == initial && undoLen() == u0 - 1,
        "Edge z2 must remove the activation after g1 undo");
    navigate(false);
    assert(planes() == initial && undoLen() == u0,
        "Edge r1 re-arms bare; the old g1 redo row must be gone");
    navigate(false);
    assert(planes() == initial && undoLen() == u0,
        "Edge r2 must not restore the erased g1 row");
    handlePx(1, x, y);
    drag(x, y, x - 40, y);
    assert(planes() != initial && undoLen() == u0 + 1,
        "new Edge haul after bare re-arm must create a new g1 row");
    navigate(true);
    assert(planes() == initial && undoLen() == u0,
        "undo of the new g1 must restore the original mesh");
    navigate(false);
    assert(planes() != initial && undoLen() == u0 + 1,
        "redo of the new g1 must restore its mesh");
    cmd("tool.set " ~ TOOL ~ " off");
}

unittest { // A recording UI command closes after Middle without a carrier row.
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok");
    cmd("history.clear");
    int ei = findEdgeXPosZNeg();
    assert(ei >= 0);
    r = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"edges","indices":[` ~ ei.to!string ~ `]}`));
    assert(r["status"].str == "ok");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok");
    cmd("tool.set " ~ TOOL ~ " on");
    import core.thread : Thread;
    import core.time : dur;
    Thread.sleep(dur!"msecs"(250));
    immutable long u0 = undoLen();
    int x, y; handlePx(1, x, y);
    drag(x, y, x - 40, y);
    immutable string first = planes();
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x, y, x, y, 1, 0, 2), BASE);
    immutable string middle = planes();
    assert(middle != first && undoLen() == u0 + 2,
        "recording-close fixture lacks two topology rows");
    r = postJson("/api/command?origin=ui", "mesh.flip");
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "recording UI command failed: " ~ r.toString);
    assert(undoLen() == u0 + 3,
        "recording command close added a cumulative Edge row");
    navigate(true);
    assert(planes() == middle && undoLen() == u0 + 2,
        "recording-command z1 did not remove command alone: undo "
        ~ undoLen().to!string ~ ", expected " ~ (u0 + 2).to!string
        ~ ", planes " ~ planeDiff(middle, planes()).to!string);
    navigate(true);
    assert(planes() == first && undoLen() == u0 + 1,
        "recording-command z2 did not remove Middle alone");
    cmd("tool.set " ~ TOOL ~ " off");
}

unittest { // A recorded Edge step remains the mesh owner after RMB cancel.
    setupEdge();
    immutable string initial = planes();
    immutable long u0 = undoLen();
    int x, y; handlePx(1, x, y);
    drag(x, y, x - 40, y);
    immutable string first = planes();
    assert(first != initial && undoLen() == u0 + 1,
        "RMB fixture needs a completed history-owned step");
    rightClick(x, y);
    assert(planes() == first && undoLen() == u0 + 1,
        "RMB reverted the mesh but retained its completed history row");
    navigate(true);
    assert(planes() == initial && undoLen() == u0,
        "RMB left the next Undo inconsistent with the visible mesh");
}

unittest { // A close while a drag is held records its pending image once.
    setupEdge();
    immutable string initial = planes();
    immutable long u0 = undoLen();
    int x, y; handlePx(1, x, y);
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragDownLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x, y), BASE);
    playAndWait(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x, y, x - 40, y, 12), BASE);
    immutable string preview = planes();
    assert(preview != initial, "held-drag fixture did not build a preview");
    cmd("tool.set move on");
    assert(planes() == preview && undoLen() == u0 + 2,
        "mid-gesture close lost the pending Edge image or duplicated a row");
    playAndWait(buildDragUpLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x - 40, y), BASE);
    navigate(true);
    navigate(true);
    assert(planes() == initial,
        "mid-gesture close image did not round-trip through history: "
        ~ planeDiff(initial, planes()).to!string ~ ", undo " ~ undoLen().to!string);
}

unittest { // Full closed redo leaves a fresh Edge activation dormant.
    setupEdge();
    immutable string initial = planes();
    immutable long u0 = undoLen();
    int x, y; handlePx(1, x, y);
    drag(x, y, x - 40, y);
    immutable string first = planes();
    assert(first != initial && undoLen() == u0 + 1,
        "dormant fixture needs a topology row");
    cmd("tool.set move on");
    navigate(true);  // Move activation
    navigate(true);  // Edge topology row
    navigate(true);  // Edge activation
    navigate(false);
    navigate(false);
    navigate(false);
    assert(planes() == first && undoLen() == u0 + 2,
        "full closed redo did not restore its mesh and Move row: undo "
        ~ undoLen().to!string ~ ", u0 " ~ u0.to!string ~ ", delta "
        ~ planeDiff(first, planes()).to!string ~ ", history "
        ~ getJson("/api/history").toString);
    auto r = postJson("/api/command?origin=ui", "tool.set " ~ TOOL ~ " on");
    assert(r["status"].str == "ok" || r["status"].str == "success");
    immutable string rearmed = planes();
    immutable long fresh = undoLen();
    assert(rearmed == first, "fresh arm after closed redo changed full mesh");
    immutable double armWidth = getJson("/api/tool/state")["width"].floating;
    handlePx(1, x, y);
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragDownLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x, y), BASE);
    playAndWait(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x, y, x - 40, y, 12), BASE);
    auto st = getJson("/api/tool/state");
    assert(planes() == rearmed && undoLen() == fresh &&
        st["session"]["live"].type == JSONType.false_,
        "dormant Edge held drag armed or previewed topology before release");
    playAndWait(buildDragUpLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x - 40, y), BASE);
    assert(planes() == rearmed && undoLen() == fresh + 1,
        "dormant Edge drag must add one attr-only row without moving mesh");
    auto h = getJson("/api/history");
    assert(h["undo"].array[$ - 1]["command"].str == "tool.topology_adjustment",
        "dormant Edge drag wrote a topology carrier instead of an adjustment");
    st = getJson("/api/tool/state");
    assert(st["session"]["live"].type == JSONType.false_,
        "dormant Edge drag armed a topology operation");
    navigate(true);
    assert(planes() == rearmed && undoLen() == fresh - 1,
        "dormant z1 must remove adjustment and fresh activation together");
    navigate(false);
    assert(planes() == rearmed && undoLen() == fresh,
        "dormant r1 restores the bare activation, leaving adjustment in redo");
    // Law 4, generic (task 9020 item A; not an Edge Extend capture): the redo of the bare
    // activation re-creates the instance with its drop seed — the width it held at z1
    // with its own adjustment undone, i.e. the arm's (sticky) width, never the drag's.
    st = getJson("/api/tool/state");
    assert(st["session"]["dormant"].type == JSONType.true_ &&
        abs(st["width"].floating - armWidth) < 1e-5 && abs(armWidth) > 1e-3,
        "dormant r1 restored a live postmode or carried drag attrs: width "
        ~ st["width"].floating.to!string ~ " (the arm's " ~ armWidth.to!string ~ ")");
}

unittest { // Interactive Width follows the same closed-redo dormant path.
    setupEdge();
    immutable string initial = planes();
    immutable long u0 = undoLen();
    auto p = postJson("/api/script?interactive=true",
        "tool.attr edge.extrude width 0.2\n");
    assert(p["status"].str == "ok" || p["status"].str == "success");
    immutable string param = planes();
    assert(param != initial && undoLen() == u0 + 1,
        "interactive Width fixture did not create a mesh row");
    cmd("tool.set move on");
    navigate(true);
    navigate(true);
    navigate(true);
    navigate(false);
    navigate(false);
    navigate(false);
    assert(planes() == param && undoLen() == u0 + 2,
        "interactive Width did not survive full closed redo");
    auto r = postJson("/api/command?origin=ui", "tool.set " ~ TOOL ~ " on");
    assert(r["status"].str == "ok" || r["status"].str == "success");
    immutable long fresh = undoLen();
    int x, y; handlePx(1, x, y);
    drag(x, y, x - 40, y);
    assert(planes() == param && undoLen() == fresh + 1 &&
        getJson("/api/history")["undo"].array[$ - 1]["command"].str ==
            "tool.topology_adjustment",
        "post-param fresh drag must write only an attribute adjustment");
}

unittest { // A restored dormant predecessor keeps its activation provenance.
    setupEdge();
    int x, y; handlePx(1, x, y);
    drag(x, y, x - 40, y);
    cmd("tool.set move on");
    navigate(true); navigate(true); navigate(true);
    navigate(false); navigate(false); navigate(false);
    auto r = postJson("/api/command?origin=ui", "tool.set " ~ TOOL ~ " on");
    assert(r["status"].str == "ok" || r["status"].str == "success");
    cmd("tool.set move on");
    navigate(true); // Move reverts to the fresh dormant Edge activation.
    const image = planes();
    const depth = undoLen();
    auto st = getJson("/api/tool/state");
    assert(st["session"]["dormant"].type == JSONType.true_,
        "Undo Move lost the dormant state of its Edge predecessor");
    handlePx(1, x, y);
    drag(x, y, x - 40, y);
    assert(planes() == image && undoLen() == depth + 1,
        "restored dormant Edge drag changed mesh/selection or omitted its row");
    assert(getJson("/api/history")["undo"].array[$ - 1]["command"].str ==
        "tool.topology_adjustment",
        "restored dormant Edge drag wrote a topology row");
}

unittest { // A scripted write is the actual before-image of the next step.
    // A scripted attribute write ends the operation armed with the tool; a panel
    // write after it is attribute-only: its row changes no mesh, and its undo/redo
    // restore the scripted / the panel value (task 8930).
    setupEdge();
    const initial = planes();
    cmd("tool.attr edge.extrude width 0.1");
    assert(abs(queryWidth() - 0.1) < 1e-5,
        "scripted Width did not reach the armed Edge tool");
    auto p = postJson("/api/script?interactive=true",
        "tool.attr edge.extrude width 0.2\n");
    assert(p["status"].str == "ok" || p["status"].str == "success");
    assert(planes() == initial && abs(queryWidth() - 0.2) < 1e-5,
        "a panel Width after the scripted write changed the mesh or missed the attribute");
    assert(getJson("/api/history")["undo"].array[$ - 1]["command"].str ==
        "tool.topology_adjustment",
        "a panel Width after the scripted write is not an attribute-only row");
    navigate(true);
    assert(planes() == initial && abs(queryWidth() - 0.1) < 1e-5,
        "interactive Width undo lost the scripted pre-step attribute");
    navigate(false);
    assert(planes() == initial && abs(queryWidth() - 0.2) < 1e-5,
        "interactive Width redo lost the panel value or changed the mesh");
}

unittest { // The same scripted before-image survives an ordinary handle drag.
    setupEdge();
    const initial = planes();
    cmd("tool.attr edge.extrude width 0.1");
    int x, y; handlePx(0, x, y);
    drag(x, y, x + 70, y);
    const after = planes();
    const extrude = queryExtrude();
    assert(after != initial && extrude > 1e-3,
        "scripted Width and handle haul did not build a topology step");
    navigate(true);
    assert(planes() == initial && abs(queryWidth() - 0.1) < 1e-5
        && abs(queryExtrude()) < 1e-5,
        "handle undo lost the scripted pre-step attributes or mesh");
    navigate(false);
    assert(planes() == after && abs(queryWidth() - 0.1) < 1e-5
        && abs(queryExtrude() - extrude) < 1e-5,
        "handle redo lost the exact scripted plus gesture after-image");
}

unittest { // Pointer-written interactive dormant parameter creates an attr row.
    setupEdge();
    int x, y; handlePx(1, x, y);
    drag(x, y, x - 40, y);
    cmd("tool.set move on");
    navigate(true); navigate(true); navigate(true);
    navigate(false); navigate(false); navigate(false);
    auto r = postJson("/api/command?origin=ui", "tool.set " ~ TOOL ~ " on");
    assert(r["status"].str == "ok" || r["status"].str == "success");
    const image = planes();
    const depth = undoLen();
    const armWidth = queryWidth();   // sticky from the closed run's drag
    assert(abs(armWidth - 0.2) > 1e-3, "rig: the arm's Width equals the row's after (0.2)");
    auto p = postJson("/api/script?interactive=true",
        "tool.attr edge.extrude width 0.2\n");
    assert(p["status"].str == "ok" || p["status"].str == "success");
    assert(planes() == image && undoLen() == depth + 1 &&
        abs(queryWidth() - 0.2) < 1e-5 &&
        getJson("/api/history")["undo"].array[$ - 1]["command"].str ==
            "tool.topology_adjustment",
        "dormant interactive Width omitted its attribute-only row");
    navigate(true);
    assert(planes() == image && undoLen() == depth - 1,
        "dormant interactive Width undo lost mesh or activation pairing");
    // Law 4, generic (task 9020, model doc §R9; not an Edge Extend capture): the
    // activation redo re-creates the tool with its drop seed — the arm's Width (its own
    // row undone); the attribute-only row is then an orphan in it — its redo moves nothing
    // and Width stays the re-created tool's. Was: 0, then the row's after (0.2).
    navigate(false);
    assert(planes() == image && abs(queryWidth() - armWidth) < 1e-5,
        "dormant interactive Width activation redo lost its before attribute: width "
        ~ queryWidth().to!string ~ " (the arm's " ~ armWidth.to!string ~ ")");
    navigate(false);
    assert(planes() == image && abs(queryWidth() - armWidth) < 1e-5,
        "dormant interactive Width redo of an orphaned attribute row wrote Width "
        ~ queryWidth().to!string ~ " into the re-created tool, history "
        ~ getJson("/api/history").toString);
}

unittest { // Explicit drop while held must preserve its single pending row.
    setupEdge();
    immutable string initial = planes();
    immutable long u0 = undoLen();
    int x, y; handlePx(1, x, y);
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragDownLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x, y), BASE);
    playAndWait(buildDragMotionLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x, y, x - 40, y, 12), BASE);
    immutable string preview = planes();
    assert(preview != initial, "held explicit-drop fixture has no preview");
    cmd("tool.set " ~ TOOL ~ " off");
    assert(planes() == preview && undoLen() == u0 + 1,
        "explicit drop discarded pending image or appended duplicate row");
    playAndWait(buildDragUpLog(cam.vpX, cam.vpY, cam.width, cam.height,
        x - 40, y), BASE);
    navigate(true);
    assert(planes() == initial && undoLen() == u0,
        "explicit-drop pending row did not undo its full mesh");
}
