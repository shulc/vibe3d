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

// Compose a drag from (x1,y1) to (x2,y2) — LMB-down at start, two motion
// frames (mid + end with state=1 to indicate LMB held), LMB-up at end.
string dragFromTo(double t, int x1, int y1, int x2, int y2) {
    int xm = (x1 + x2) / 2;
    int ym = (y1 + y2) / 2;
    return format(
        `{"t":%g,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        t,        x1, y1,
        t +  5.0, x1, y1,
        t + 10.0, xm, ym, xm - x1, ym - y1,
        t + 15.0, x2, y2, x2 - xm, y2 - ym,
        t + 20.0, x2, y2);
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

// =========================================================================
// Phase 6.9.1 — vertex editing (drag, weld, insert) + currentPoint
// =========================================================================

// -------------------------------------------------------------------------
// 6.9.1: click on existing vertex selects it (currentPoint updated);
// subsequent click on empty plane inserts a new vertex AFTER the selected
// one. Net result for a 3-click triangle + reselect-v0 + click-empty +
// Enter: 4-vert face (the inserted vertex sits between v0 and v1).
// -------------------------------------------------------------------------

unittest { // insert mid-sequence
    resetEmpty();
    activatePen();
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"   // v0
        ~ clickAt(200, 525, 250) ~ "\n"   // v1
        ~ clickAt(300, 475, 350) ~ "\n"   // v2  → currentPoint=2
        ~ clickAt(400, 425, 250) ~ "\n"   // re-click v0's pixel → selects v0
        ~ clickAt(500, 460, 280) ~ "\n"   // click empty → insert AFTER v0
        ~ keyDown(600, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 4,
        "insert: expected 4 verts, got "
        ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 1);
    assert(m["faces"].array[0].array.length == 4,
        "expected 4-gon, got " ~ m["faces"].array[0].array.length.to!string ~ "-gon");
}

// -------------------------------------------------------------------------
// 6.9.1: dragging an in-progress vertex onto another welds them — the
// dragged vertex drops out of the boundary list. 4 verts → drag v3 onto
// v0 → 3 verts → Enter commits a triangle.
// -------------------------------------------------------------------------

unittest { // weld via drag
    resetEmpty();
    activatePen();
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"   // v0
        ~ clickAt(200, 525, 250) ~ "\n"   // v1
        ~ clickAt(300, 525, 350) ~ "\n"   // v2
        ~ clickAt(400, 425, 350) ~ "\n"   // v3
        ~ dragFromTo(500, 425, 350, 425, 250) ~ "\n"  // drag v3 onto v0
        ~ keyDown(700, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 3,
        "weld: expected 3 verts after drag-weld, got "
        ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array[0].array.length == 3, "expected triangle after weld");
}

// -------------------------------------------------------------------------
// 6.9.1: dragging a vertex without dropping on another simply relocates
// it. After commit, the polygon's vertex set should differ from a no-drag
// baseline at the dragged vertex's index.
// -------------------------------------------------------------------------

unittest { // drag relocates without weld
    // Baseline: 3 clicks + Enter, no drag.
    resetEmpty();
    activatePen();
    string baseline = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"
        ~ clickAt(200, 525, 250) ~ "\n"
        ~ clickAt(300, 475, 350) ~ "\n"
        ~ keyDown(400, SDLK_RETURN);
    playEvents(baseline);
    waitForPlaybackFinish();
    deactivateTool();
    auto mb = getJson("/api/model");
    assert(mb["vertices"].array.length == 3);
    auto vbX = mb["vertices"].array[0].array[0].floating;

    // Drag v0 to a new pixel before Enter.
    resetEmpty();
    activatePen();
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"
        ~ clickAt(200, 525, 250) ~ "\n"
        ~ clickAt(300, 475, 350) ~ "\n"
        ~ dragFromTo(400, 425, 250, 350, 250) ~ "\n"   // drag v0 left
        ~ keyDown(600, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();
    auto md = getJson("/api/model");
    assert(md["vertices"].array.length == 3,
        "drag-relocate: still expected 3 verts (no weld), got "
        ~ md["vertices"].array.length.to!string);
    auto vdX = md["vertices"].array[0].array[0].floating;

    assert(fabs(vdX - vbX) > 0.01,
        "drag-relocate: expected v0.x to differ after drag (was "
        ~ vbX.to!string ~ ", now " ~ vdX.to!string ~ ")");
}

// -------------------------------------------------------------------------
// 6.9.1: numeric edit of currentPoint via tool.attr changes which vertex
// is "current". Editing posX/Y/Z then writes back into the buffer. After
// Enter, the polygon's vertices reflect the numeric edit.
// -------------------------------------------------------------------------

// -------------------------------------------------------------------------
// 6.9.1: tool.attr flip:true reverses the boundary winding on commit.
// Build a triangle, set flip via tool.attr, commit; verify the face's
// vertex index order is the reverse of the no-flip baseline.
// -------------------------------------------------------------------------

unittest { // flip reverses face winding
    // Baseline: 3 clicks + Enter, no flip.
    resetEmpty();
    activatePen();
    string baseline = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"
        ~ clickAt(200, 525, 250) ~ "\n"
        ~ clickAt(300, 475, 350) ~ "\n"
        ~ keyDown(400, SDLK_RETURN);
    playEvents(baseline);
    waitForPlaybackFinish();
    deactivateTool();
    auto mb = getJson("/api/model");
    assert(mb["faces"].array.length == 1);
    long[] faceB;
    foreach (e; mb["faces"].array[0].array) faceB ~= e.integer;

    // Same clicks but flip set via tool.attr before Enter.
    resetEmpty();
    activatePen();
    string log1 = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"
        ~ clickAt(200, 525, 250) ~ "\n"
        ~ clickAt(300, 475, 350);
    playEvents(log1);
    waitForPlaybackFinish();
    auto rf = postJson("/api/command", "tool.attr pen flip true");
    assert(rf["status"].str == "ok", "tool.attr flip failed: " ~ rf.toString);
    string log2 = LOG_HEADER ~ "\n" ~ keyDown(100, SDLK_RETURN);
    playEvents(log2);
    waitForPlaybackFinish();
    deactivateTool();

    auto mf = getJson("/api/model");
    assert(mf["faces"].array.length == 1);
    long[] faceF;
    foreach (e; mf["faces"].array[0].array) faceF ~= e.integer;
    assert(faceB.length == faceF.length, "flip: face length differs");

    // Flip reverses the boundary order.
    foreach (i; 0 .. faceB.length)
        assert(faceB[i] == faceF[$ - 1 - i],
            "flip: expected reversed boundary, baseline=" ~ faceB.to!string
            ~ " flipped=" ~ faceF.to!string);
}

unittest { // tool.attr posX rewrites the current vertex
    resetEmpty();
    activatePen();
    string log1 = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"
        ~ clickAt(200, 525, 250) ~ "\n"
        ~ clickAt(300, 475, 350);
    playEvents(log1);
    waitForPlaybackFinish();

    // currentPoint defaults to 2 (last appended). Set it to 0, then move
    // posX numerically; Enter commits.
    auto r1 = postJson("/api/command", "tool.attr pen currentPoint 0");
    assert(r1["status"].str == "ok", "tool.attr currentPoint failed: " ~ r1.toString);
    auto r2 = postJson("/api/command", "tool.attr pen posX 5.0");
    assert(r2["status"].str == "ok", "tool.attr posX failed: " ~ r2.toString);

    string log2 = LOG_HEADER ~ "\n" ~ keyDown(100, SDLK_RETURN);
    playEvents(log2);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 3);
    // v0.x should now be 5.0 (re-written via tool.attr posX).
    auto v0x = m["vertices"].array[0].array[0].floating;
    assert(fabs(v0x - 5.0) < 1e-3,
        "tool.attr posX: expected v0.x ~ 5.0, got " ~ v0x.to!string);
}

// =========================================================================
// Phase 6.9.5 — Make Quads (polygon strip)
// =========================================================================

// -------------------------------------------------------------------------
// 6.9.5: makeQuads strip — first 2 clicks anchor the leading edge; each
// subsequent click extends the strip by one parallelogram quad. Five
// clicks should commit a 3-quad strip with 8 verts.
// -------------------------------------------------------------------------

unittest { // makeQuads → 3-quad strip from 5 clicks
    resetEmpty();
    activatePen();
    auto rt = postJson("/api/command", "tool.attr pen makeQuads true");
    assert(rt["status"].str == "ok", "tool.attr makeQuads failed: " ~ rt.toString);

    // 5 clicks roughly traversing a strip from left to right.
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"   // anchor v0 (top)
        ~ clickAt(200, 425, 350) ~ "\n"   // anchor v1 (bot)
        ~ clickAt(300, 475, 250) ~ "\n"   // strip click 1 → +2 verts (1 quad)
        ~ clickAt(400, 525, 250) ~ "\n"   // strip click 2 → +2 verts (2 quads)
        ~ clickAt(500, 575, 250) ~ "\n"   // strip click 3 → +2 verts (3 quads)
        ~ keyDown(600, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    // 2 anchor + 3·2 strip-pair = 8 verts; 3 quads.
    assert(m["vertices"].array.length == 8,
        "makeQuads: expected 8 verts, got "
        ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 3,
        "makeQuads: expected 3 quads, got "
        ~ m["faces"].array.length.to!string);
    foreach (f; m["faces"].array)
        assert(f.array.length == 4,
            "makeQuads: every face must be a quad");
}

// -------------------------------------------------------------------------
// 6.9.5: makeQuads + only 2 clicks + Enter = nothing committed (need ≥4 verts
// to form one full quad).
// -------------------------------------------------------------------------

unittest { // makeQuads below minimum
    resetEmpty();
    activatePen();
    postJson("/api/command", "tool.attr pen makeQuads true");
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"
        ~ clickAt(200, 425, 350) ~ "\n"
        ~ keyDown(300, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 0,
        "makeQuads with 2 verts + Enter: should not commit, got "
        ~ m["vertices"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 6.9.5: 3 clicks form exactly one quad. Auto-corner sits at
// v3 = v1 + (v2 − v0) (parallelogram rule).
// -------------------------------------------------------------------------

unittest { // makeQuads parallelogram auto-corner
    resetEmpty();
    activatePen();
    postJson("/api/command", "tool.attr pen makeQuads true");
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 425, 250) ~ "\n"   // v0 (top anchor)
        ~ clickAt(200, 425, 350) ~ "\n"   // v1 (bot anchor)
        ~ clickAt(300, 525, 250) ~ "\n"   // v2 (top extend), v3 = v1 + (v2 - v0)
        ~ keyDown(400, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 4, "expected 4 verts (1 quad)");
    assert(m["faces"].array.length == 1, "expected 1 quad");

    // Verify parallelogram invariant: v3 - v1 == v2 - v0 (same offset on
    // both sides of the strip).
    auto verts = m["vertices"].array;
    double[3] v0 = [verts[0].array[0].floating, verts[0].array[1].floating, verts[0].array[2].floating];
    double[3] v1 = [verts[1].array[0].floating, verts[1].array[1].floating, verts[1].array[2].floating];
    double[3] v2 = [verts[2].array[0].floating, verts[2].array[1].floating, verts[2].array[2].floating];
    double[3] v3 = [verts[3].array[0].floating, verts[3].array[1].floating, verts[3].array[2].floating];
    foreach (i; 0 .. 3) {
        double offTop = v2[i] - v0[i];
        double offBot = v3[i] - v1[i];
        assert(fabs(offTop - offBot) < 1e-3,
            "parallelogram: axis " ~ i.to!string ~ " mismatch (top "
            ~ offTop.to!string ~ " vs bot " ~ offBot.to!string ~ ")");
    }
}

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
