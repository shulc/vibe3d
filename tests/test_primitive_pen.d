// Tests for subphase 6.9.0: Pen tool — skeleton + Polygons mode.
//
// Pen has no headless apply path (interactive only) so the test exercises
// the full event-driven flow: activate the tool via tool.set, play a
// recorded SDL event log (LMB clicks at calibrated viewport pixels +
// Enter / Backspace / Esc), then read /api/model and /api/selection back
// to verify topology.
//
// Per doc/pen_plan.md, 6.9.0 covers:
//   • LMB click adds a vertex to the in-progress polygon
//   • Enter (or double-click) commits when ≥3 verts → n-gon face
//   • Backspace pops the last vertex
//   • Esc / RMB cancels the in-progress sequence
//   • Construction plane locked at the first click
//
// Coordinates assume the recorded VIEWPORT (150,28 650x544) — EventPlayer
// rescales to the live viewport so absolute pixels match the recording's
// frame regardless of layout.

import std.net.curl;
import std.json;
import std.string : format;
import std.conv : to;
import std.math : fabs;
import core.thread : Thread;
import core.time : msecs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

void resetEmpty() {
    auto resp = postJson("/api/reset?empty=true", "");
    assert(resp["status"].str == "ok", "reset(empty) failed: " ~ resp.toString);
}

void activatePen() {
    auto resp = postJson("/api/command", "tool.set \"pen\" on 0");
    assert(resp["status"].str == "ok", "tool.set pen failed: " ~ resp.toString);
}

void deactivateTool() {
    auto resp = postJson("/api/command", "tool.set \"pen\" off 0");
    // Don't assert — tests may run out of order, deactivate is best-effort cleanup.
}

void playEvents(string events) {
    auto resp = postJson("/api/play-events", events);
    assert(resp["status"].str == "success",
        "play-events failed: " ~ resp.toString);
}

void waitForPlaybackFinish() {
    foreach (_; 0 .. 100) {
        auto j = getJson("/api/play-events/status");
        if (j["finished"].type == JSONType.TRUE) return;
        Thread.sleep(50.msecs);
    }
    assert(false, "playback didn't finish within 5s");
}

// SDL keycodes (from SDL_keycode.h).
enum SDLK_RETURN    = 13;
enum SDLK_ESCAPE    = 27;
enum SDLK_BACKSPACE = 8;

// Compose a click sequence (motion + LMB-down + LMB-up at given pixel).
string clickAt(double t, int x, int y, int clicks = 1) {
    return format(
        `{"t":%g,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":%d,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":%d,"mod":0}`,
        t,        x, y,
        t + 5.0,  x, y, clicks,
        t + 10.0, x, y, clicks);
}

string keyDown(double t, int sym) {
    return format(`{"t":%g,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":0,"repeat":0}`,
                  t, sym);
}

// Standard JSONL log header — required VIEWPORT line for EventPlayer
// to know the original recording's viewport for pixel rescaling.
enum string LOG_HEADER =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n"
  ~ `{"t":1.0,"type":"SDL_WINDOWEVENT","sub":1}` ~ "\n"
  ~ `{"t":2.0,"type":"SDL_WINDOWEVENT","sub":3}`;

// -------------------------------------------------------------------------
// 1. Triangle: 3 clicks + Enter → 3 verts / 1 face.
// -------------------------------------------------------------------------

unittest { // pen → triangle via 3 clicks + Enter
    resetEmpty();
    activatePen();
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"
        ~ clickAt(200, 525, 250) ~ "\n"
        ~ clickAt(300, 475, 350) ~ "\n"
        ~ keyDown(400, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 3,
        "triangle: expected 3 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 1,
        "triangle: expected 1 face, got " ~ m["faces"].array.length.to!string);
    auto face = m["faces"].array[0].array;
    assert(face.length == 3, "expected triangular face, got " ~ face.length.to!string ~ "-gon");
}

// -------------------------------------------------------------------------
// 2. Quad via 4 clicks + Enter → 4 verts / 1 face (4-gon).
// -------------------------------------------------------------------------

unittest { // pen → quad
    resetEmpty();
    activatePen();
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"
        ~ clickAt(200, 525, 250) ~ "\n"
        ~ clickAt(300, 525, 350) ~ "\n"
        ~ clickAt(400, 425, 350) ~ "\n"
        ~ keyDown(500, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 4,
        "quad: expected 4 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 1, "quad: expected 1 face");
    assert(m["faces"].array[0].array.length == 4,
        "expected quad, got " ~ m["faces"].array[0].array.length.to!string ~ "-gon");
}

// -------------------------------------------------------------------------
// 3. Pentagon via 5 clicks + Enter.
// -------------------------------------------------------------------------

unittest { // 5-gon
    resetEmpty();
    activatePen();
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 475, 220) ~ "\n"
        ~ clickAt(200, 555, 280) ~ "\n"
        ~ clickAt(300, 525, 380) ~ "\n"
        ~ clickAt(400, 425, 380) ~ "\n"
        ~ clickAt(500, 395, 280) ~ "\n"
        ~ keyDown(600, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 5,
        "pentagon: expected 5 verts");
    assert(m["faces"].array[0].array.length == 5,
        "expected 5-gon");
}

// -------------------------------------------------------------------------
// 4. Backspace removes last vertex; remaining 3 commit as triangle.
// -------------------------------------------------------------------------

unittest { // 4 clicks + Backspace + Enter → triangle
    resetEmpty();
    activatePen();
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"
        ~ clickAt(200, 525, 250) ~ "\n"
        ~ clickAt(300, 475, 350) ~ "\n"
        ~ clickAt(400, 460, 320) ~ "\n"
        ~ keyDown(500, SDLK_BACKSPACE) ~ "\n"
        ~ keyDown(600, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 3, "after backspace: expected 3 verts");
    assert(m["faces"].array.length == 1);
    assert(m["faces"].array[0].array.length == 3, "expected triangle");
}

// -------------------------------------------------------------------------
// 5. Esc cancels — no commit.
// -------------------------------------------------------------------------

unittest { // 4 clicks + Esc → empty mesh
    resetEmpty();
    activatePen();
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"
        ~ clickAt(200, 525, 250) ~ "\n"
        ~ clickAt(300, 525, 350) ~ "\n"
        ~ clickAt(400, 425, 350) ~ "\n"
        ~ keyDown(500, SDLK_ESCAPE);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 0,
        "esc cancel: expected empty mesh, got "
        ~ m["vertices"].array.length.to!string ~ " verts");
    assert(m["faces"].array.length == 0);
}

// -------------------------------------------------------------------------
// 6. Below minimum (2 clicks + Enter) — Enter is a no-op, no commit.
// -------------------------------------------------------------------------

unittest { // 2 clicks + Enter → still empty (need ≥3 for a polygon)
    resetEmpty();
    activatePen();
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"
        ~ clickAt(200, 525, 250) ~ "\n"
        ~ keyDown(300, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 0,
        "2 verts + Enter: should not commit, got "
        ~ m["vertices"].array.length.to!string ~ " verts");
}

// -------------------------------------------------------------------------
// 7. Multiple polygons in one Pen session: tool stays active across
//    commits (Idle → Drawing → commit → Idle → Drawing → commit).
// -------------------------------------------------------------------------

unittest { // two triangles, one Pen session
    resetEmpty();
    activatePen();
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100,  390, 250) ~ "\n"
        ~ clickAt(200,  450, 250) ~ "\n"
        ~ clickAt(300,  420, 320) ~ "\n"
        ~ keyDown(400,  SDLK_RETURN) ~ "\n"
        ~ clickAt(500,  500, 250) ~ "\n"
        ~ clickAt(600,  560, 250) ~ "\n"
        ~ clickAt(700,  530, 320) ~ "\n"
        ~ keyDown(800,  SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 6,
        "two triangles: expected 6 verts, got "
        ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 2,
        "two triangles: expected 2 faces, got "
        ~ m["faces"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 8. Undo restores previous state.
// -------------------------------------------------------------------------

unittest { // commit → undo → empty
    resetEmpty();
    activatePen();
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"
        ~ clickAt(200, 525, 250) ~ "\n"
        ~ clickAt(300, 475, 350) ~ "\n"
        ~ keyDown(400, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m1 = getJson("/api/model");
    assert(m1["vertices"].array.length == 3);

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    auto m2 = getJson("/api/model");
    assert(m2["vertices"].array.length == 0,
        "after undo: expected empty mesh, got "
        ~ m2["vertices"].array.length.to!string ~ " verts");
}
