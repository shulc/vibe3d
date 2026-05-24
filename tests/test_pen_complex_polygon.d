// Pen complex-polygon test (Stage E1 of doc/test_coverage_plan.md).
//
// test_primitive_pen.d already covers triangles, quads, pentagons,
// single-Backspace + Enter, Esc cancel, and multi-polygon sessions.
// This file fills three remaining gaps:
//
//   1. >5-vert polygon — 6-click hexagon commits as one 6-gon.
//      Pentagon-only coverage misses any per-edge bookkeeping that
//      only kicks in for n ≥ 6 (e.g. an off-by-one in the closing-
//      edge loop).
//   2. Multiple Backspaces — pop the last 2 verts of a 6-click run,
//      commit as a 4-gon. Existing single-Backspace test only proves
//      one pop works; 2+ pops exercise the stack-style behaviour.
//   3. Cancel + redraw in the same Pen session — after Esc clears
//      an in-progress polygon, the user can immediately start a new
//      one without re-activating the tool. Pins the state machine's
//      Drawing → Idle → Drawing transition.

import std.net.curl;
import std.json;
import std.string : format;
import std.conv : to;
import core.thread : Thread;
import core.time : msecs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}
void resetEmpty() {
    auto r = postJson("/api/reset?empty=true", "");
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
}
void activatePen() {
    auto r = postJson("/api/command", "tool.set \"pen\" on 0");
    assert(r["status"].str == "ok", "tool.set pen failed: " ~ r.toString);
}
void deactivateTool() {
    postJson("/api/command", "tool.set \"pen\" off 0");
}
void playEvents(string events) {
    auto r = postJson("/api/play-events", events);
    assert(r["status"].str == "success",
        "play-events failed: " ~ r.toString);
}
void waitPlaybackFinish() {
    foreach (_; 0 .. 100) {
        auto j = getJson("/api/play-events/status");
        if (j["finished"].type == JSONType.TRUE) return;
        Thread.sleep(50.msecs);
    }
    assert(false, "playback didn't finish");
}

// Pixel coords assume the recorded 650×544 viewport; EventPlayer rescales.
enum SDLK_RETURN    = 13;
enum SDLK_ESCAPE    = 27;
enum SDLK_BACKSPACE = 8;
enum string LOG_HEADER =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n"
  ~ `{"t":1.0,"type":"SDL_WINDOWEVENT","sub":1}` ~ "\n"
  ~ `{"t":2.0,"type":"SDL_WINDOWEVENT","sub":3}`;

string clickAt(double t, int x, int y) {
    return format(
        `{"t":%g,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        t,        x, y,
        t + 5.0,  x, y,
        t + 10.0, x, y);
}
string keyDown(double t, int sym) {
    return format(`{"t":%g,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":0,"repeat":0}`,
                  t, sym);
}

// Hexagon click coords laid out on a screen-space hexagon centred near
// the cube's projected origin. Roughly 100 px radius — comfortable
// separation per pen-tool hit-test slack.
immutable int[2][6] HEX_CLICKS = [
    [475, 250],   // top
    [550, 290],   // upper-right
    [550, 350],   // lower-right
    [475, 380],   // bottom
    [400, 350],   // lower-left
    [400, 290],   // upper-left
];

unittest { // 6-click hexagon commits as one 6-gon
    resetEmpty();
    activatePen();
    string log = LOG_HEADER ~ "\n";
    double t = 100.0;
    foreach (xy; HEX_CLICKS) {
        log ~= clickAt(t, xy[0], xy[1]) ~ "\n";
        t += 100.0;
    }
    log ~= keyDown(t, SDLK_RETURN);
    playEvents(log);
    waitPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 6,
        "hexagon: expected 6 verts; got " ~
        m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 1,
        "hexagon: expected 1 face; got " ~
        m["faces"].array.length.to!string);
    auto face = m["faces"].array[0].array;
    assert(face.length == 6,
        "expected 6-gon face; got " ~ face.length.to!string ~ "-gon");
}

unittest { // 6 clicks + Backspace × 2 + Enter commits a 4-gon
    resetEmpty();
    activatePen();
    string log = LOG_HEADER ~ "\n";
    double t = 100.0;
    foreach (xy; HEX_CLICKS) {
        log ~= clickAt(t, xy[0], xy[1]) ~ "\n";
        t += 100.0;
    }
    // Pop the last 2 verts (HEX_CLICKS[5] then [4]) — the surviving
    // boundary should be HEX_CLICKS[0..4] in order.
    log ~= keyDown(t,         SDLK_BACKSPACE) ~ "\n";
    log ~= keyDown(t + 50.0,  SDLK_BACKSPACE) ~ "\n";
    log ~= keyDown(t + 100.0, SDLK_RETURN);
    playEvents(log);
    waitPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 4,
        "hex - 2 backspaces should leave 4 verts; got " ~
        m["vertices"].array.length.to!string);
    auto face = m["faces"].array[0].array;
    assert(face.length == 4,
        "expected 4-gon after backspaces; got " ~
        face.length.to!string ~ "-gon");
}

unittest { // Esc + redraw in the same Pen session works
    resetEmpty();
    activatePen();
    // First polygon: 3 clicks + Esc — cancelled.
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"
        ~ clickAt(200, 525, 250) ~ "\n"
        ~ clickAt(300, 475, 350) ~ "\n"
        ~ keyDown(400, SDLK_ESCAPE) ~ "\n"
        // Second polygon: 3 clicks + Enter — commits a triangle.
        ~ clickAt(500, 425, 250) ~ "\n"
        ~ clickAt(600, 525, 250) ~ "\n"
        ~ clickAt(700, 475, 350) ~ "\n"
        ~ keyDown(800, SDLK_RETURN);
    playEvents(log);
    waitPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 3,
        "cancel + redraw: expected 3 verts (only the second triangle); got " ~
        m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 1,
        "cancel + redraw: expected 1 face; got " ~
        m["faces"].array.length.to!string);
}
