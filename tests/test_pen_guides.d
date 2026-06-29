// Tests for Pen guide constraints: straightLine / worldAxis / rightAngle.
//
// Strategy: an empty scene, pen tool active, snap master ON with a single
// guide type enabled and a generous innerRange (100 px).  A 2- or 3-click
// sequence fixes a reference segment, then a final click is placed a few
// pixels OFF the guide but within innerRange.  With the guide ON the placed
// vertex should satisfy the corresponding world-space invariant; with the
// guide OFF (snap disabled for the negative control) the same pixel gives a
// raw hit that clearly does NOT satisfy the invariant.
//
// Recording viewport: (vpX:150, vpY:28, vpW:650, vpH:544) — same as
// test_primitive_pen.d. EventPlayer rescales to the live viewport, so these
// pixel coordinates work regardless of window layout.
//
// Invariants (world-space, tolerances are loose — robust to pixel rescaling
// and the exact innerRangePx):
//   straightLine : cross(v2-v0, v1-v0).length / (v1-v0).length < 0.005
//   worldAxis    : max abs(dot(normalize(v1-v0), axis)) over axes > 0.99
//   rightAngle   : abs(dot(normalize(v2-v1), normalize(v1-v0)))  < 0.05

import std.net.curl;
import std.json;
import std.string : format;
import std.conv   : to;
import std.math   : fabs, sqrt;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

// ---------------------------------------------------------------------------
// Common helpers (mirror test_primitive_pen.d).
// ---------------------------------------------------------------------------

void resetEmpty() {
    auto resp = postJson("/api/reset?empty=true", "");
    assert(resp["status"].str == "ok", "reset(empty) failed: " ~ resp.toString);
}

void activatePen() {
    auto resp = postJson("/api/command", "tool.set \"pen\" on 0");
    assert(resp["status"].str == "ok", "tool.set pen failed: " ~ resp.toString);
}

void deactivateTool() {
    postJson("/api/command", "tool.set \"pen\" off 0");
}

void cmd(string argstring) {
    auto j = postJson("/api/command", argstring);
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
}

void playEvents(string events) {
    auto resp = postJson("/api/play-events", events);
    assert(resp["status"].str == "success", "play-events failed: " ~ resp.toString);
}

void waitForPlaybackFinish() {
    foreach (_; 0 .. 100) {
        auto j = getJson("/api/play-events/status");
        if (j["finished"].type == JSONType.TRUE) return;
        Thread.sleep(50.msecs);
    }
    assert(false, "playback timed out");
}

// SDL keycodes.
enum SDLK_RETURN = 13;

// Motion + LMB-down + LMB-up at (x,y).
string clickAt(double t, int x, int y) {
    return format(
        `{"t":%g,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        t,        x, y,
        t +  5.0, x, y,
        t + 10.0, x, y);
}

string keyDown(double t, int sym) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":0,"repeat":0}`, t, sym);
}

// Required VIEWPORT header + focus events for EventPlayer pixel rescaling.
enum string LOG_HEADER =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n"
  ~ `{"t":1.0,"type":"SDL_WINDOWEVENT","sub":1}` ~ "\n"
  ~ `{"t":2.0,"type":"SDL_WINDOWEVENT","sub":3}`;

// Enable snap with a single guide type and a generous innerRange.
// outerRange is set equally large so highlights don't interfere.
void snapGuideOnly(string typeName) {
    cmd("tool.pipe.attr snap enabled true");
    cmd(`tool.pipe.attr snap types "` ~ typeName ~ `"`);
    cmd("tool.pipe.attr snap innerRange 100");
    cmd("tool.pipe.attr snap outerRange 100");
}

// Read world positions of all vertices from /api/model.
// Returns an array of [x, y, z] float arrays.
float[3][] readVerts() {
    auto m = getJson("/api/model");
    float[3][] vs;
    foreach (v; m["vertices"].array) {
        auto a = v.array;
        vs ~= [cast(float)a[0].floating,
               cast(float)a[1].floating,
               cast(float)a[2].floating];
    }
    return vs;
}

float vecLen(float[3] v) {
    return sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
}

float[3] vecSub(float[3] a, float[3] b) {
    return [a[0]-b[0], a[1]-b[1], a[2]-b[2]];
}

float[3] vecNorm(float[3] v) {
    float len = vecLen(v);
    if (len < 1e-9f) return v;
    return [v[0]/len, v[1]/len, v[2]/len];
}

float vecDot(float[3] a, float[3] b) {
    return a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
}

// Cross product (a × b).
float[3] vecCross(float[3] a, float[3] b) {
    return [a[1]*b[2] - a[2]*b[1],
            a[2]*b[0] - a[0]*b[2],
            a[0]*b[1] - a[1]*b[0]];
}

// ---------------------------------------------------------------------------
// Test 1 — straightLine
//
// v0 (420,300) and v1 (540,300) fix a screen-horizontal segment.
// v2 (590,320) is 20px below the screen extension of that segment.
// With guide ON the placed v2 must be colinear with v0-v1.
// With guide OFF (snap disabled) the same pixel gives a raw off-line hit.
// ---------------------------------------------------------------------------
unittest { // straightLine ON → colinear placement
    resetEmpty();
    activatePen();
    snapGuideOnly("straightLine");

    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 420, 300) ~ "\n"    // v0
        ~ clickAt(200, 540, 300) ~ "\n"    // v1 (same y → horizontal segment)
        ~ clickAt(300, 590, 320) ~ "\n"    // v2: 20 px below the extension
        ~ keyDown(400, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto vs = readVerts();
    assert(vs.length == 3, "straightLine ON: expected 3 verts, got " ~ vs.length.to!string);

    float[3] d01    = vecSub(vs[1], vs[0]);     // v1 - v0
    float[3] d02    = vecSub(vs[2], vs[0]);     // v2 - v0
    float[3] cross_ = vecCross(d01, d02);
    float    seg    = vecLen(d01);
    assert(seg > 1e-4f, "straightLine ON: degenerate segment");
    float colinearity = vecLen(cross_) / seg;
    assert(colinearity < 0.005f,
        format("straightLine ON: v2 not colinear (%.4f >= 0.005)", colinearity));
}

unittest { // straightLine OFF → v2 NOT colinear (negative control)
    resetEmpty();
    activatePen();
    // Snap disabled: free placement, no guide.
    cmd("tool.pipe.attr snap enabled false");

    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 420, 300) ~ "\n"
        ~ clickAt(200, 540, 300) ~ "\n"
        ~ clickAt(300, 590, 320) ~ "\n"    // same off-line pixel
        ~ keyDown(400, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto vs = readVerts();
    assert(vs.length == 3, "straightLine OFF: expected 3 verts");

    float[3] d01    = vecSub(vs[1], vs[0]);
    float[3] d02    = vecSub(vs[2], vs[0]);
    float[3] cross_ = vecCross(d01, d02);
    float    seg    = vecLen(d01);
    assert(seg > 1e-4f, "straightLine OFF: degenerate segment");
    float colinearity = vecLen(cross_) / seg;
    assert(colinearity > 0.01f,
        format("straightLine OFF: v2 is accidentally colinear (%.4f < 0.01) "
               ~ "— negative control failed", colinearity));
}

// ---------------------------------------------------------------------------
// Test 2 — worldAxis
//
// v0 (400,300), v1 (450,360): both pixel axes differ, so the free-hit
// direction is off all world axes. With worldAxis guide ON and innerRange=100,
// v1 snaps to the nearest world X/Y/Z axis through v0.
// ---------------------------------------------------------------------------
unittest { // worldAxis ON → v0→v1 segment parallel to a world axis
    // Three-click triangle so Enter actually commits (minCommitVerts=3).
    // The guide fires on the v1 placement (second click); the invariant checks
    // only the v0→v1 direction regardless of where v2 lands.
    resetEmpty();
    activatePen();
    snapGuideOnly("worldAxis");

    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 400, 300) ~ "\n"    // v0
        ~ clickAt(200, 450, 360) ~ "\n"    // v1: off-axis raw; guide snaps it
        ~ clickAt(300, 420, 340) ~ "\n"    // v2: arbitrary third vertex
        ~ keyDown(400, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto vs = readVerts();
    assert(vs.length == 3, "worldAxis ON: expected 3 verts, got " ~ vs.length.to!string);

    float[3] dir = vecNorm(vecSub(vs[1], vs[0]));
    assert(vecLen(vecSub(vs[1], vs[0])) > 1e-4f, "worldAxis ON: degenerate segment");

    // At least one world axis must be nearly parallel to the v0→v1 segment.
    float[3][3] axes = [[1.0f,0,0], [0,1.0f,0], [0,0,1.0f]];
    float bestDot = 0;
    foreach (ax; axes) {
        float d = fabs(vecDot(dir, ax));
        if (d > bestDot) bestDot = d;
    }
    assert(bestDot > 0.99f,
        format("worldAxis ON: v0→v1 not aligned to any world axis (best dot=%.4f)", bestDot));
}

unittest { // worldAxis OFF → v0→v1 NOT aligned to a world axis (negative control)
    resetEmpty();
    activatePen();
    cmd("tool.pipe.attr snap enabled false");

    // Same three pixels; without the guide v1 is a raw unsnapped hit.
    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 400, 300) ~ "\n"
        ~ clickAt(200, 450, 360) ~ "\n"    // same off-axis pixel, no guide
        ~ clickAt(300, 420, 340) ~ "\n"
        ~ keyDown(400, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto vs = readVerts();
    assert(vs.length == 3, "worldAxis OFF: expected 3 verts, got " ~ vs.length.to!string);

    float[3] dir = vecNorm(vecSub(vs[1], vs[0]));
    assert(vecLen(vecSub(vs[1], vs[0])) > 1e-4f, "worldAxis OFF: degenerate segment");

    float[3][3] axes = [[1.0f,0,0], [0,1.0f,0], [0,0,1.0f]];
    float bestDot = 0;
    foreach (ax; axes) {
        float d = fabs(vecDot(dir, ax));
        if (d > bestDot) bestDot = d;
    }
    assert(bestDot < 0.95f,
        format("worldAxis OFF: accidentally aligned to a world axis (best dot=%.4f)"
               ~ " — negative control failed", bestDot));
}

// ---------------------------------------------------------------------------
// Test 3 — rightAngle
//
// v0 (400,300), v1 (540,300) fix a screen-horizontal segment.
// v2 (600,330): 60px right and 30px below v1 — clearly NOT perpendicular to
// v0→v1. With rightAngle ON the guide forces v2 onto the in-plane
// perpendicular to v0→v1 through v1.
// ---------------------------------------------------------------------------
unittest { // rightAngle ON → (v2-v1)·(v1-v0) ≈ 0
    resetEmpty();
    activatePen();
    snapGuideOnly("rightAngle");

    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 400, 300) ~ "\n"    // v0
        ~ clickAt(200, 540, 300) ~ "\n"    // v1 (horizontal segment)
        ~ clickAt(300, 600, 330) ~ "\n"    // v2: off-perpendicular raw hit
        ~ keyDown(400, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto vs = readVerts();
    assert(vs.length == 3, "rightAngle ON: expected 3 verts, got " ~ vs.length.to!string);

    float[3] seg  = vecNorm(vecSub(vs[1], vs[0]));  // v1-v0 direction
    float[3] arm  = vecNorm(vecSub(vs[2], vs[1]));  // v2-v1 direction
    assert(vecLen(vecSub(vs[1], vs[0])) > 1e-4f, "rightAngle ON: degenerate segment");
    assert(vecLen(vecSub(vs[2], vs[1])) > 1e-4f, "rightAngle ON: v2 == v1");

    float dotVal = fabs(vecDot(seg, arm));
    assert(dotVal < 0.05f,
        format("rightAngle ON: v2-v1 not perpendicular to v1-v0 (|dot|=%.4f >= 0.05)", dotVal));
}

unittest { // rightAngle OFF → (v2-v1)·(v1-v0) clearly non-zero (negative control)
    resetEmpty();
    activatePen();
    cmd("tool.pipe.attr snap enabled false");

    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 400, 300) ~ "\n"
        ~ clickAt(200, 540, 300) ~ "\n"
        ~ clickAt(300, 600, 330) ~ "\n"    // same off-perpendicular pixel
        ~ keyDown(400, SDLK_RETURN);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto vs = readVerts();
    assert(vs.length == 3, "rightAngle OFF: expected 3 verts");

    float[3] seg = vecNorm(vecSub(vs[1], vs[0]));
    float[3] arm = vecNorm(vecSub(vs[2], vs[1]));
    assert(vecLen(vecSub(vs[1], vs[0])) > 1e-4f, "rightAngle OFF: degenerate segment");
    assert(vecLen(vecSub(vs[2], vs[1])) > 1e-4f, "rightAngle OFF: v2 == v1");

    float dotVal = fabs(vecDot(seg, arm));
    assert(dotVal > 0.3f,
        format("rightAngle OFF: accidentally near-perpendicular (|dot|=%.4f < 0.3)"
               ~ " — negative control failed", dotVal));
}
