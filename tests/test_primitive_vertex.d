// Tests for prim.vertex — interactive single-vertex placement tool.
//
// The tool has no headless apply path (interactive only), so these tests
// use the full event-driven flow: activate the tool via tool.set, play
// a recorded SDL event log (LMB clicks at calibrated viewport pixels),
// then read /api/model and /api/selection to verify the result.
//
// Position coverage (MANDATORY):
//   The only new logic in this tool is the viewport→workplane unproject
//   (choosePlane / rayPlaneIntersect / transformPoint chain from pen.d).
//   A broken projection could produce wrong world positions while count /
//   isolation / undo still pass green.  We pin it by asserting that each
//   added vertex has its coordinate along the active construction-plane
//   normal ≈ 0 (i.e. it lies ON the construction plane through the frame
//   origin).  With focus set to the world origin via /api/camera before
//   playback, the frame origin = (0,0,0), so the normal-axis component of
//   every vertex must be ≈ 0 in absolute world terms.
//
// Two non-top-down cameras are used so both the "Z-normal plane" and
// "X-normal plane" branches of pickMostFacingPlane are exercised:
//   Case A  az=0.0,           el=0.2  →  Z-dominant camera  →  all vertices z ≈ 0
//   Case B  az=π/2 ≈ 1.5708,  el=0.1  →  X-dominant camera  →  all vertices x ≈ 0
//
// Exact world triples are intentionally NOT asserted (camera-dependent).
// That contract lives with mesh.addVertex (task 0131), which takes an
// absolute position.
//
// Viewport recording reference: (150,28  650×544, fovY=0.785398)

import std.net.curl;
import std.json;
import std.string : format;
import std.conv : to;
import std.math : fabs, PI;
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

void activateVertex() {
    auto resp = postJson("/api/command", "tool.set \"prim.vertex\" on 0");
    assert(resp["status"].str == "ok",
           "tool.set prim.vertex failed: " ~ resp.toString);
}

void deactivateTool() {
    postJson("/api/command", "tool.set \"prim.vertex\" off 0");
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

// Set camera via /api/camera and wait for it to take effect.
void setCamera(double azimuth, double elevation, double distance,
               double fx = 0.0, double fy = 0.0, double fz = 0.0)
{
    string body_ = format(
        `{"azimuth":%g,"elevation":%g,"distance":%g,"focus":{"x":%g,"y":%g,"z":%g}}`,
        azimuth, elevation, distance, fx, fy, fz);
    auto resp = postJson("/api/camera", body_);
    assert(resp["status"].str == "ok",
           "camera set failed: " ~ resp.toString);
}

// Compose an LMB click sequence (motion + down + up).
string clickAt(double t, int x, int y) {
    return format(
        `{"t":%g,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        t,        x, y,
        t + 5.0,  x, y,
        t + 10.0, x, y);
}

// Standard JSONL log header — required VIEWPORT line for EventPlayer
// pixel rescaling.
enum string LOG_HEADER =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n"
  ~ `{"t":1.0,"type":"SDL_WINDOWEVENT","sub":1}` ~ "\n"
  ~ `{"t":2.0,"type":"SDL_WINDOWEVENT","sub":3}`;

// ---------------------------------------------------------------------------
// 1. Count + isolation: 3 clicks → 3 vertices, 0 faces, 0 edges.
//
// Uses Case A camera (az=0, el=0.2, looking from +Z direction slightly
// elevated).  In auto-mode, pickMostFacingPlane returns Z as the dominant
// axis, so the construction plane is the world XY plane (Z ≈ 0 through origin).
// ---------------------------------------------------------------------------
unittest { // 3 clicks → 3 isolated vertices, no faces or edges
    resetEmpty();
    setCamera(0.0, 0.2, 3.0);
    activateVertex();

    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 350, 280) ~ "\n"
        ~ clickAt(200, 430, 280) ~ "\n"
        ~ clickAt(300, 390, 340);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 3,
        "count: expected 3 vertices, got "
        ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 0,
        "isolation: expected 0 faces, got "
        ~ m["faces"].array.length.to!string);
    assert(m["edges"].array.length == 0,
        "isolation: expected 0 edges, got "
        ~ m["edges"].array.length.to!string);
}

// ---------------------------------------------------------------------------
// 2. Position (MANDATORY) — plane-normal coordinate ≈ 0 (Case A: Z-dominant).
//
// Camera az=0, el=0.2, focus at origin.  auto-mode frame: Z is the camera-
// facing world axis, so frame_.normal = world Z = (0,0,1).  The construction
// plane is Z=0 in world space.  Every added vertex must have |z| < 0.05.
//
// This is the primary correctness gate for the unproject chain
// (choosePlane / rayPlaneIntersect / transformPoint).  A broken unproject
// would place vertices off the plane, making |z| >> 0.
// ---------------------------------------------------------------------------
unittest { // plane-normal ≈ 0 (Z-plane, az=0 el=0.2)
    resetEmpty();
    setCamera(0.0, 0.2, 3.0);
    activateVertex();

    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 350, 280) ~ "\n"
        ~ clickAt(200, 430, 300) ~ "\n"
        ~ clickAt(300, 390, 340);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 3,
        "plane-Z: expected 3 vertices, got "
        ~ m["vertices"].array.length.to!string);

    foreach (i, v; m["vertices"].array) {
        double z = v.array[2].floating;
        assert(fabs(z) < 0.05,
            "plane-Z: vertex " ~ i.to!string
            ~ " has z=" ~ z.to!string
            ~ " (expected ≈ 0, construction plane Z=0)");
    }
}

// ---------------------------------------------------------------------------
// 3. Position (MANDATORY) — plane-normal coordinate ≈ 0 (Case B: X-dominant).
//
// Camera az=π/2 ≈ 1.5708, el=0.1, focus at origin.  The camera looks from
// the +X direction.  auto-mode frame: X is the camera-facing world axis, so
// frame_.normal = world X = (1,0,0).  Construction plane is X=0 in world
// space.  Every added vertex must have |x| < 0.05.
//
// This case exercises the opposite pickMostFacingPlane branch from Case A,
// confirming choosePlane_ adapts to camera orientation rather than always
// using a fixed axis.
// ---------------------------------------------------------------------------
unittest { // plane-normal ≈ 0 (X-plane, az=π/2 el=0.1)
    resetEmpty();
    setCamera(PI / 2.0, 0.1, 3.0);
    activateVertex();

    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 360, 290) ~ "\n"
        ~ clickAt(200, 440, 290) ~ "\n"
        ~ clickAt(300, 400, 350);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 3,
        "plane-X: expected 3 vertices, got "
        ~ m["vertices"].array.length.to!string);

    foreach (i, v; m["vertices"].array) {
        double x = v.array[0].floating;
        assert(fabs(x) < 0.05,
            "plane-X: vertex " ~ i.to!string
            ~ " has x=" ~ x.to!string
            ~ " (expected ≈ 0, construction plane X=0)");
    }
}

// ---------------------------------------------------------------------------
// 4. Selection count == 1 after N clicks (newest vertex only).
//
// Each click calls clearVertexSelection before selectVertex, so only the
// most recently placed vertex is selected.  /api/selection must report
// exactly 1 selected vertex regardless of how many were added.
// ---------------------------------------------------------------------------
unittest { // selectedVertices.length == 1 after N clicks
    resetEmpty();
    setCamera(0.0, 0.2, 3.0);
    activateVertex();

    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 350, 280) ~ "\n"
        ~ clickAt(200, 430, 280) ~ "\n"
        ~ clickAt(300, 390, 340) ~ "\n"
        ~ clickAt(400, 370, 300);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m = getJson("/api/model");
    assert(m["vertices"].array.length == 4,
        "sel-count: expected 4 vertices, got "
        ~ m["vertices"].array.length.to!string);

    auto sel = getJson("/api/selection");
    auto sv = sel["selectedVertices"].array;
    assert(sv.length == 1,
        "sel-count: expected 1 selected vertex (newest only), got "
        ~ sv.length.to!string);
}

// ---------------------------------------------------------------------------
// 5. Per-click undo granularity: each click is its own history entry.
//
// After N clicks, Ctrl+Z once removes exactly 1 vertex (not all N).
// Two undos remove 2 total.
// ---------------------------------------------------------------------------
unittest { // per-click undo granularity
    resetEmpty();
    setCamera(0.0, 0.2, 3.0);
    activateVertex();

    string log = LOG_HEADER ~ "\n"
        ~ clickAt(100, 350, 280) ~ "\n"
        ~ clickAt(200, 430, 280) ~ "\n"
        ~ clickAt(300, 390, 340);
    playEvents(log);
    waitForPlaybackFinish();
    deactivateTool();

    auto m0 = getJson("/api/model");
    assert(m0["vertices"].array.length == 3,
        "undo-gran: expected 3 vertices before undo, got "
        ~ m0["vertices"].array.length.to!string);

    // First undo: 3 → 2 vertices.
    auto u1 = postJson("/api/undo", "");
    assert(u1["status"].str == "ok", "undo 1 failed: " ~ u1.toString);
    auto m1 = getJson("/api/model");
    assert(m1["vertices"].array.length == 2,
        "undo-gran: expected 2 vertices after 1 undo, got "
        ~ m1["vertices"].array.length.to!string);

    // Second undo: 2 → 1 vertex.
    auto u2 = postJson("/api/undo", "");
    assert(u2["status"].str == "ok", "undo 2 failed: " ~ u2.toString);
    auto m2 = getJson("/api/model");
    assert(m2["vertices"].array.length == 1,
        "undo-gran: expected 1 vertex after 2 undos, got "
        ~ m2["vertices"].array.length.to!string);
}

// ---------------------------------------------------------------------------
// 6. Tool stays active across clicks (no auto-deactivate).
//
// Two "bursts" of clicks with a gap between them, no Enter/Esc — tool should
// keep accumulating vertices across the gap.
// ---------------------------------------------------------------------------
unittest { // tool stays active across multiple click bursts
    resetEmpty();
    setCamera(0.0, 0.2, 3.0);
    activateVertex();

    // First burst: 2 clicks.
    string log1 = LOG_HEADER ~ "\n"
        ~ clickAt(100, 350, 280) ~ "\n"
        ~ clickAt(200, 430, 280);
    playEvents(log1);
    waitForPlaybackFinish();

    auto m1 = getJson("/api/model");
    assert(m1["vertices"].array.length == 2,
        "stays-active: expected 2 vertices after burst 1, got "
        ~ m1["vertices"].array.length.to!string);

    // Second burst: 2 more clicks — tool never deactivated.
    string log2 = LOG_HEADER ~ "\n"
        ~ clickAt(100, 390, 300) ~ "\n"
        ~ clickAt(200, 410, 340);
    playEvents(log2);
    waitForPlaybackFinish();
    deactivateTool();

    auto m2 = getJson("/api/model");
    assert(m2["vertices"].array.length == 4,
        "stays-active: expected 4 vertices after burst 2, got "
        ~ m2["vertices"].array.length.to!string);
    assert(m2["faces"].array.length == 0,
        "stays-active: expected 0 faces (isolation preserved), got "
        ~ m2["faces"].array.length.to!string);
}
