// Interactive drag coverage for the Vertex Extrude tool's handle drag.
//
// tests/test_vertex_extrude_tool.d drives this tool entirely through `tool.attr`
// + `tool.doApply`; nothing else in the suite enters its MOTION path. That path
// runs a per-event pixel increment which takes its previous pixel from the
// cooked gesture and cross-checks it against the tool's own, so it needs a test
// that reaches it.
//
// WHY THIS FILE WAS REWRITTEN (task 2690) — the same defect as
// tests/test_edge_extrude_handle_drag.d, a second time in the same tree. The
// gesture here grabbed the EXTRUDE arrow ALONE and asserted the `shift`
// attribute. Measured on this very stand, that gesture is EMPTY:
//
//     shift = 0.028    <- the shipped assertion (abs(shift) > 1e-3) passed on this
//     width = 0
//     /api/mesh/planes before vs after: NOT ONE PLANE MOVED
//     the drop recorded ZERO undo entries
//
// The extrude arrow alone moves a number; the kernel needs a non-zero WIDTH
// before it emits a single vertex, and with nothing emitted `deactivate()`
// commits nothing. So the gesture now grabs the WIDTH part (1) FIRST and the
// extrude arrow (0) second, and the assertions are the two the acceptance
// criterion names: the tool built, and a plane actually moved.
//
// `built` IS NOT AVAILABLE HERE, and that is measured rather than assumed:
// `/api/tool/state` publishes it for exactly six tools tree-wide (edge_extend,
// edge_extrude, edge_bevel, poly_bevel, edge_slice, loop_slice —
// `grep -rn '"built"' source/`), and `mesh.vertexExtrude` answers `{}`. What
// stands in for it is STRICTLY STRONGER on this tool, not weaker: the VERTEX
// COUNT must have grown. `built` is the tool's own claim that its kernel
// returned non-zero; a risen vertex count is that claim's consequence, read off
// the mesh.
//
// Both press points come from `/api/tool/handles`, never from a local
// re-derivation of the arm geometry: a re-derivation that drifts away from the
// tool silently returns the non-gesture above and nothing says so. The hover
// before each press is load-bearing — the press hit-test reads `queryMouse()`,
// whose override is only updated on MOTION events, so a log that opens with the
// button-down would hit-test against a stale cursor.

import std.algorithm : canFind, sort;
import std.conv : to;
import std.format : format;
import std.json;
import std.net.curl : get, post;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "mesh.vertexExtrude";

string getRaw(string path) { return cast(string) get(BASE ~ path); }
JSONValue getJson(string path) { return parseJSON(getRaw(path)); }
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

double queryShift() {
    auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " shift ?");
    assert(r["status"].str == "ok", "query shift failed: " ~ r.toString);
    return r["value"].floating;
}

// --- the acceptance witness -------------------------------------------------
//
// EVERY CHANNEL BELOW FAILS CLOSED, which is why this file needs no separate
// positive control: each assertion is "something MOVED", so a `/api/mesh/planes`
// serving a stale copy leaves `moved` empty and goes RED, and an `/api/history`
// that stopped tracking leaves the delta at 0 and goes RED. (The frozen
// fixtures in tests/test_tool_gesture_g*.d assert "EQUAL" and "EMPTY", which a
// dead channel satisfies for free — that is why THEY open with a control.)

string planes() { return getRaw("/api/mesh/planes"); }
long undoLen() { return cast(long) getJson("/api/history")["undo"].array.length; }
size_t vertexCount() { return getJson("/api/model")["vertices"].array.length; }

string[] planeDiff(string aText, string bText) {
    auto a = parseJSON(aText);
    auto b = parseJSON(bText);
    bool[string] keys;
    foreach (k, _; a.objectNoRef) keys[k] = true;
    foreach (k, _; b.objectNoRef) keys[k] = true;
    string[] names;
    foreach (k, _; keys) if (k != "provenance") names ~= k;
    names.sort();
    string[] diff;
    foreach (k; names) {
        auto pa = k in a.objectNoRef;
        auto pb = k in b.objectNoRef;
        if (pa is null || pb is null) { diff ~= k; continue; }
        if (pa.toString() != pb.toString()) diff ~= k;
    }
    return diff;
}

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

/// A stationary hover, so the press hit-test reads a cursor already on the part.
void hover(int x, int y) {
    import core.thread : Thread;
    import core.time   : dur;
    auto cam = fetchCamera(BASE);
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            50.0 + i * 20.0, x, y);
    playAndWait(log, BASE);
    Thread.sleep(dur!"msecs"(150));
}

void drag(int x0, int y0, int x1, int y1, int steps = 16) {
    import core.thread : Thread;
    import core.time   : dur;
    auto cam = fetchCamera(BASE);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, steps), BASE);
    Thread.sleep(dur!"msecs"(120));
}

unittest { // width, then the extrude arrow — and the kernel emits geometry
    import core.thread : Thread;
    import core.time   : dur;

    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");

    // v6 = (0.5,0.5,0.5): its three adjacent faces average to the (1,1,1)
    // diagonal, which is the extrude axis the arrow is drawn along.
    r = postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);

    // The framing is PART OF THE GESTURE: both press points are handle anchors
    // read back per-frame, so the camera is pinned rather than inherited.
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);

    cmd("tool.set " ~ TOOL ~ " on");
    Thread.sleep(dur!"msecs"(250));

    immutable string planesBefore = planes();
    immutable long   u0           = undoLen();
    immutable size_t v0           = vertexCount();

    // 1. the WIDTH part. Without it the kernel emits nothing however far the
    //    extrude arrow is hauled — that is the whole finding this file records.
    int wx, wy; handlePx(1, wx, wy);
    hover(wx, wy);
    drag(wx, wy, wx + 70, wy - 50);

    // 2. the EXTRUDE arrow.
    int sx, sy; handlePx(0, sx, sy);
    hover(sx, sy);
    drag(sx, sy, sx + 70, sy - 50);

    // THE CHECK THE OLD FILE DID NOT HAVE, half one: the kernel emitted
    // geometry. This stands in for `built`, which this tool does not publish.
    immutable size_t v1 = vertexCount();
    assert(v1 > v0,
        "the two handle drags added no vertex (still " ~ v0.to!string
        ~ ") while shift reads " ~ queryShift().to!string ~ ". That is the "
        ~ "empty gesture this file shipped for months: the extrude arrow moves "
        ~ "`shift` whether or not `width` ever left zero, and with width == 0 "
        ~ "the kernel touches nothing and the drop records nothing");

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
