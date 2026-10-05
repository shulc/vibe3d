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

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.string : format;
import std.conv : to;
import std.math : fabs, PI;
import core.thread : Thread;
import core.time : msecs;

void main() {}

alias baseUrl = testBaseUrl;


void resetEmpty() {
    auto resp = postJson("/api/command", commandBody("scene.reset", `{"empty":true}`));
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
    auto u1 = postJson("/api/command", commandBody("history.undo"));
    assert(u1["status"].str == "ok", "undo 1 failed: " ~ u1.toString);
    auto m1 = getJson("/api/model");
    assert(m1["vertices"].array.length == 2,
        "undo-gran: expected 2 vertices after 1 undo, got "
        ~ m1["vertices"].array.length.to!string);

    // Second undo: 2 → 1 vertex.
    auto u2 = postJson("/api/command", commandBody("history.undo"));
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

// ---------------------------------------------------------------------------
// vertex-guide-off: the Vertex tool strips the guide-constraint snap types
// (`snap.kGuideTypes`) from its query, so with ONLY World Axis enabled a click
// 30 px above the X axis is not pulled onto it. Without the strip the vertex
// lands on the axis (y = 0) — the mutation this cell exists to see.
// ---------------------------------------------------------------------------
unittest { // vertex-guide-off: World Axis alone does not move a placed vertex
    resetEmpty();
    setCamera(0.0, 0.2, 3.0);
    foreach (c; ["tool.pipe.attr snap enabled true", "tool.pipe.attr snap types worldAxis",
                 "tool.pipe.attr snap innerRange 999999", "tool.pipe.attr snap outerRange 999999"]) {
        auto r = postJson("/api/command", c);
        assert(r["status"].str == "ok", c ~ " failed: " ~ r.toString);
    }
    scope (exit) postJson("/api/command", "tool.pipe.attr snap enabled false");
    activateVertex();
    playEvents(LOG_HEADER ~ "\n" ~ clickAt(100, 515, 270));
    waitForPlaybackFinish();
    deactivateTool();

    auto vs = getJson("/api/model")["vertices"].array;
    assert(vs.length == 1, "vertex-guide-off: expected 1 vertex, got " ~ vs.length.to!string);
    const double x = vs[0].array[0].floating, y = vs[0].array[1].floating;
    assert(fabs(x) > 0.02 && fabs(y) > 0.02,
        format("vertex-guide-off: the vertex (%.4f, %.4f) sits on a world axis — a guide "
             ~ "type reached the Vertex tool's snap", x, y));
}

// ---------------------------------------------------------------------------
// 7. The drag (task 9499, K-C5): the press places the vertex, every motion
//    moves it live, the RELEASE records the one undo entry. Risk cells: undo
//    depth mid-drag; a Ctrl+Z held under the button is dropped (control: the
//    same keys after the release pop the entry); RMB removes the live vertex;
//    a drop records it, a switch is refused; redo restores the dragged point;
//    the change deliveries are the press's plus one per motion. All cells run;
//    the failures are reported together.
// ---------------------------------------------------------------------------
string ev(string type, double t, int x, int y, int btn = 1, int state = 1) {
    if (type == "motion")
        return format(`{"t":%g,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":%d,"mod":0}`,
                      t, x, y, state);
    return format(`{"t":%g,"type":"SDL_MOUSEBUTTON%s","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                  t, type == "down" ? "DOWN" : "UP", btn, x, y);
}

string ctrlZ(double t) {
    return format(`{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
                ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}`, t, t + 5);
}

void play(string[] events...) {
    string log = LOG_HEADER;
    foreach (e; events) log ~= "\n" ~ e;
    playEvents(log);
    waitForPlaybackFinish();
}

double[][] verts() {
    double[][] r;
    foreach (v; getJson("/api/model")["vertices"].array) {
        double[] p;
        foreach (c; v.array) p ~= c.type == JSONType.float_ ? c.floating : cast(double)c.integer;
        r ~= p;
    }
    return r;
}

size_t undoDepth() { return getJson("/api/history")["undo"].array.length; }
ulong deliveries() { return getJson("/api/changes")["deliveryCount"].integer; }

unittest { // the drag gesture: one record, at the release
    enum int X = 350, Y = 280, N = 8, STEP = 10;
    string[] fails;
    void check(bool ok, lazy string m) { if (!ok) fails ~= m; }
    void begin() {
        resetEmpty();
        setCamera(0.0, 0.2, 3.0);
        postJson("/api/command", commandBody("history.clear"));
        activateVertex();
    }
    // Press, then N motions of STEP px in x, the button held.
    string[] pressAndDrag() {
        string[] e = [ev("motion", 10, X, Y, 1, 0), ev("down", 20, X, Y)];
        foreach (i; 1 .. N + 1) e ~= ev("motion", 20 + 10 * i, X + STEP * i, Y);
        return e;
    }
    enum double tUp = 20 + 10 * N + 10;

    // R1 + R7: mid-drag the vertex moved and nothing is recorded; the release
    // records one entry; the deliveries are the press's plus one per motion.
    begin();
    immutable d0 = deliveries();
    play(ev("motion", 10, X, Y, 1, 0), ev("down", 20, X, Y));
    immutable pressDeliveries = deliveries() - d0;
    const atPress = verts();
    play(pressAndDrag()[2 .. $]);
    const mid = verts();
    check(atPress.length == 1 && mid.length == 1,
          format("R1: one vertex at the press and mid-drag, got %d / %d", atPress.length, mid.length));
    check(undoDepth() == 0, format("R1: nothing is recorded before the release, depth %d", undoDepth()));
    check(mid.length == 1 && atPress.length == 1 && mid[0][0] - atPress[0][0] > 0.05,
          format("R1: the vertex must follow the drag (+x), press %s, mid %s", atPress, mid));
    check(pressDeliveries == 2, format("R7: the press delivers 2 (measured), got %d", pressDeliveries));
    check(deliveries() - d0 == pressDeliveries + N,
          format("R7: one delivery per motion: %d motions, %d deliveries after the press's %d",
                 N, deliveries() - d0 - pressDeliveries, pressDeliveries));
    play(ev("up", tUp, X + STEP * N, Y));
    const released = verts();
    check(undoDepth() == 1, format("R1: the release records one entry, depth %d", undoDepth()));
    check(released == mid, format("R1: the release keeps the dragged point %s, got %s", mid, released));

    // R2: undo removes it, redo restores the dragged point.
    postJson("/api/command", commandBody("history.undo"));
    check(verts().length == 0, format("R2: undo removes the vertex, %s", verts()));
    postJson("/api/command", commandBody("history.redo"));
    check(verts() == released, format("R2: redo restores %s, got %s", released, verts()));
    deactivateTool();

    // R3 + control: a Ctrl+Z under the held button is dropped; after the
    // release the same keys pop the gesture's entry and the tool stays.
    begin();
    play(pressAndDrag() ~ [ctrlZ(tUp - 5), ev("up", tUp + 10, X + STEP * N, Y)]);
    check(verts().length == 1 && undoDepth() == 1,
          format("R3: the held Ctrl+Z is dropped: 1 vertex, depth 1; got %d, %d", verts().length, undoDepth()));
    play(ctrlZ(10));
    check(verts().length == 0, format("R3 control: Ctrl+Z after the release removes it, %s", verts()));
    play(ev("motion", 10, X, Y, 1, 0), ev("down", 20, X, Y), ev("up", 30, X, Y));
    check(verts().length == 1, "R3 control: the tool stays armed after the Ctrl+Z");
    deactivateTool();

    // R4: RMB under the held LMB removes the live vertex; nothing recorded.
    begin();
    play(pressAndDrag() ~ [ev("down", tUp - 6, X + STEP * N, Y, 3), ev("up", tUp - 3, X + STEP * N, Y, 3),
                           ev("motion", tUp, X, Y), ev("up", tUp + 10, X, Y)]);
    check(verts().length == 0 && undoDepth() == 0,
          format("R4: RMB cancels the live vertex: 0 vertices, depth 0; got %d, %d", verts().length, undoDepth()));
    deactivateTool();

    // R5: a drop records the live vertex where it stands; later events move nothing.
    begin();
    play(pressAndDrag());
    const dropped = verts();
    auto off = postJson("/api/command", "tool.set \"prim.vertex\" off 0");
    check(off["status"].str == "ok", "R5: the drop failed: " ~ off.toString);
    play(ev("motion", 10, X, Y), ev("up", 20, X, Y));
    check(undoDepth() == 1 && verts() == dropped,
          format("R5: the drop records %s (depth 1); got %s, depth %d", dropped, verts(), undoDepth()));

    // R6: a switch to another tool during the drag is refused; the release records.
    begin();
    play(pressAndDrag());
    auto sw = postJson("/api/command", "tool.set prim.cube");
    check(sw["status"].str == "error", "R6: a switch during the drag must be refused: " ~ sw.toString);
    play(ev("up", 10, X + STEP * N, Y));
    check(undoDepth() == 1 && verts().length == 1,
          format("R6: the release still records: depth %d, %d vertices", undoDepth(), verts().length));
    postJson("/api/command", "tool.set prim.cube off");
    deactivateTool();

    // R8: a raw history.undo during the drag restores an image without the
    // live vertex; the gesture is then over (no write, no record, no crash).
    resetEmpty();
    setCamera(0.0, 0.2, 3.0);
    postJson("/api/command", commandBody("history.clear"));
    postJson("/api/command", commandBody("mesh.addVertex", `{"pos":[0,0,0]}`));
    activateVertex();   // after the command: a mesh command drops an armed tool
    play(pressAndDrag()[0 .. 4]);
    check(verts().length == 2, format("R8: the live vertex beside the added one, %s", verts()));
    auto u = postJson("/api/command", commandBody("history.undo"));
    check(u["status"].str == "ok", "R8: the raw undo failed: " ~ u.toString);
    play(pressAndDrag()[4 .. $] ~ [ev("up", tUp, X + STEP * N, Y)]);
    check(verts().length == 0 && undoDepth() == 0,
          format("R8: after the raw undo the drag writes and records nothing: %s, depth %d",
                 verts(), undoDepth()));
    deactivateTool();

    // R9: with no live vertex the tool leaves RMB alone: the lasso selects.
    begin();
    play(ev("motion", 10, X, Y, 1, 0), ev("down", 20, X, Y), ev("up", 30, X, Y),
         ev("motion", 40, X + 60, Y, 1, 0), ev("down", 50, X + 60, Y), ev("up", 60, X + 60, Y));
    string[] lasso = [ev("motion", 10, X - 30, Y - 30, 4, 0), ev("down", 20, X - 30, Y - 30, 3)];
    foreach (i, p; [[X + 90, Y - 30], [X + 90, Y + 30], [X - 30, Y + 30], [X - 30, Y - 30]])
        lasso ~= ev("motion", 30 + 10 * i, p[0], p[1], 1, 4);
    play(lasso ~ ev("up", 80, X - 30, Y - 30, 3));
    auto sel = getJson("/api/selection");
    check(verts().length == 2 && sel["selectedVertices"].array.length == 2,
          format("R9: an idle RMB lasso over the two vertices selects both: %s", sel.toString));
    deactivateTool();

    assert(fails.length == 0, format("%-(%s\n%)", fails));
}
