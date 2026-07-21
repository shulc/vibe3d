// Interactive Poly Bevel handle-drag coverage.
//
// The poly.bevel TOOL's interactive mouse drag had ZERO test coverage — every
// poly-bevel fixture drives the mesh.bevel COMMAND / applyHeadless, never the
// tool's Shift/Inset drag handles. That gap let a hit-test regression ship
// (a stale queryMouse made the handles unclickable; fixed by hit-testing at
// the click event's own e.x/e.y). This drives the published handles directly:
// press each, drag, and assert it captures, the param grows, and the mesh
// bevels. NOTE: EventPlayer freshens the mouse position per injected event, so
// playback cannot reproduce the real-GUI queryMouse staleness itself — this is
// a "the interactive drag works" guard, not a queryMouse-vs-e.x/e.y unit test.

import std.net.curl;
import std.json;
import std.conv : to;
import std.format : format;
import core.thread : Thread;
import core.time : msecs;

void main() {}

enum BASE = "http://localhost:8080";

JSONValue getJson(string path) { return parseJSON(cast(string)get(BASE ~ path)); }

void cmd(string text) {
    auto r = parseJSON(cast(string)post(BASE ~ "/api/command", text));
    assert(r["status"].str == "ok", "command failed: " ~ text ~ " → " ~ r.toString);
}

void settle() { Thread.sleep(140.msecs); }

void play(string log) {
    auto r = parseJSON(cast(string)post(BASE ~ "/api/play-events", log));
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    foreach (_; 0 .. 200) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.true_) break;
        Thread.sleep(50.msecs);
    }
    settle(); // EventPlayer reports posted, not processed — let the queue drain.
}

string motion(int x, int y, int state = 0) {
    return format(`{"t":0.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":%d,"mod":0}`,
                  x, y, state);
}
string button(string kind, int x, int y) {
    return format(`{"t":0.0,"type":"%s","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, kind, x, y);
}

// Screen position of the tool's published handle part (0 = Shift, 1 = Inset).
void handleScreen(int part, out int x, out int y) {
    auto parts = getJson("/api/tool/handles")["handles"]["parts"].array;
    foreach (p; parts)
        if (p["part"].integer == part) {
            x = cast(int)(p["screen"].array[0].floating + 0.5);
            y = cast(int)(p["screen"].array[1].floating + 0.5);
            return;
        }
    assert(false, "handle part not published to /api/tool/handles: " ~ part.to!string);
}

void selectFaceZero() {
    auto sel = parseJSON(cast(string)post(BASE ~ "/api/select", `{"mode":"polygons","indices":[0]}`));
    assert(sel["status"].str == "ok", "face select failed");
}

// Shift handle: a DIRECT press (no hover) must capture, grow shift, and bevel.
unittest {
    auto reset = parseJSON(cast(string)post(BASE ~ "/api/reset?type=cube", ""));
    assert(reset["status"].str == "ok", "cube reset failed");
    selectFaceZero();

    cmd("tool.set poly.bevel on");
    settle(); // draw() must publish the handle bank + compute the gizmo frame.

    // The handles must be published + visible (they weren't introspectable at all
    // before this task — no toolHandlesJson override).
    auto handles = getJson("/api/tool/handles")["handles"];
    assert(handles["parts"].array.length == 2, "poly.bevel must publish 2 handles (Shift + Inset)");

    int sx, sy;
    handleScreen(0, sx, sy);
    play(button("SDL_MOUSEBUTTONDOWN", sx, sy));
    assert(getJson("/api/tool/state")["dragPart"].integer == 0,
        "Shift handle did not capture on a direct mouse-down — hit-test regression");

    play(motion(sx - 40, sy - 70, 1)); // up-left along the shift (normal) axis
    auto st = getJson("/api/tool/state");
    assert(st["shift"].floating > 1e-4, "dragging the Shift handle did not grow shift");
    assert(st["built"].type == JSONType.true_, "non-zero shift did not build a live preview");
    auto m = getJson("/api/model");
    assert(m["vertices"].array.length > 8 && m["faces"].array.length > 6,
        "Shift drag did not bevel the mesh (8v/6f cube unchanged)");

    play(button("SDL_MOUSEBUTTONUP", sx - 40, sy - 70));
    assert(getJson("/api/tool/state")["dragPart"].integer == -1, "mouse-up kept Shift captured");

    cmd("tool.set poly.bevel off");
    auto undo = parseJSON(cast(string)post(BASE ~ "/api/undo", ""));
    assert(undo["status"].str == "ok", "undo failed");
    assert(getJson("/api/model")["vertexCount"].integer == 8, "one undo did not restore the cube");
}

// Inset handle: a DIRECT press must capture on its own part (proves both
// handles are independently hit-testable, not just the first-registered).
unittest {
    auto reset = parseJSON(cast(string)post(BASE ~ "/api/reset?type=cube", ""));
    assert(reset["status"].str == "ok", "cube reset failed");
    selectFaceZero();
    cmd("tool.set poly.bevel on");
    settle();

    int ix, iy;
    handleScreen(1, ix, iy);
    play(button("SDL_MOUSEBUTTONDOWN", ix, iy));
    assert(getJson("/api/tool/state")["dragPart"].integer == 1,
        "Inset handle did not capture on a direct mouse-down — hit-test regression");
    play(button("SDL_MOUSEBUTTONUP", ix, iy));
    cmd("tool.set poly.bevel off");
}
