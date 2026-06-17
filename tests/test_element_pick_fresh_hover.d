// Element click-pick must read the CURRENT hover, not last frame's
// (regression for the "element click-pick reads current hover, not last
// frame's" fix in source/app.d refreshHoverPickAt + source/tools/
// xfrm_transform.d).
//
// Root cause: g_hoveredVertex/Edge/Face is refreshed once per render frame
// by the CPU/GPU hover pass. XfrmTransformTool.tryPickElement reads it on
// mouse-DOWN. On a fast interactive click that follows a large cursor jump,
// the down is processed before any frame re-picks at the new coords, so the
// pick anchored the action center to the STALE element (the one under the
// PREVIOUS click), not the one actually under the cursor now. The fix
// synchronously refreshes the GPU hover pick at the click coordinates before
// the tool sees the down event.
//
// The repro drives two element-pick gestures with the element-move preset
// (a wide dist=4 sphere so any pick hauls the whole cube; elementMode=polyCent
// so a face pick anchors at the face centroid → clean, predictable coords):
//
//   Gesture 1 — hover-settle THEN pick the +Y (top) face. The +Y face
//   centroid is world (0,0.5,0); this establishes an anchor with y≈0.5.
//
//   Gesture 2 — THE KEY: pick the +X face (world centroid (0.5,0,0)) WITH NO
//   preceding hover-settle batch (a single down-only / down+tiny-motion batch,
//   simulating the fast interactive click). We then read the evaluated action
//   center (/api/toolpipe/eval → actionCenter.center).
//
// Assertion: the pivot relocated to the +X face anchor — x≈0.5, |y|<0.1,
// |z|<0.1. Before the fix it stayed at the stale +Y anchor (y≈0.5, x≈0). The
// proven post-fix value from the repro for the +X down-only pick was
// [0.5, 0.004, 0.009].
//
// Like test_relocate_boundary_element.d, the hover for gesture 1 is driven in
// its OWN play-events batch (settle lets one frame refresh hover over the +Y
// face) so its pick lands cleanly; gesture 2 deliberately OMITS that batch —
// that omission is exactly the stale-hover trap the fix closes.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;
import std.string : format;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(150.msecs);
}

void drainHistory() {
    foreach (_; 0 .. 100) {
        if (undoCount() == 0) return;
        postJson("/api/undo", "");
    }
}

// Pristine cube + drained undo stack, retrying if a preceding test left the
// shared per-worker vibe3d dirty (same pattern as
// test_relocate_boundary_element.d: drain BEFORE the reset, verify geometry).
void establishCubeBaseline() {
    import core.thread : Thread;
    import core.time   : msecs;
    bool playerIdle() {
        auto s = getJson("/api/play-events/status");
        auto f = "finished" in s;
        return f is null || f.type != JSONType.false_;
    }
    bool cubePristine() {
        auto v = getJson("/api/model")["vertices"].array;
        if (v.length != 8) return false;
        auto c = v[6].array;   // startup cube v6 = (0.5, 0.5, 0.5)
        return fabs(c[0].floating - 0.5) < 1e-3
            && fabs(c[1].floating - 0.5) < 1e-3
            && fabs(c[2].floating - 0.5) < 1e-3;
    }
    foreach (attempt; 0 .. 8) {
        postJson("/api/script", "tool.set xfrm.elementMove off");
        foreach (_; 0 .. 200) {
            if (playerIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        drainHistory();
        postJson("/api/reset", "");
        drainHistory();
        if (cubePristine()) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");
    assert(cubePristine(), "could not establish pristine cube baseline");
}

// Authoritative gizmo pivot / element-falloff sphere anchor: the evaluated
// ActionCenterPacket.center (FalloffStage reads its anchor from the same
// value, so this is the single source of truth for "where the pick landed").
Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}

// Hover-only play-events batch (no mouse buttons) — refreshes the CPU/GPU
// hover pass over (x,y) so a subsequent SEPARATE-batch pick click lands on
// the hovered element.
string hoverLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            50.0 + i * 20.0, x, y);
    return log;
}

// A down+tiny-motion pick batch with NO preceding hover-settle batch — the
// "fast interactive click" the fix targets. A single 1px motion keeps the
// gesture a haul-capable drag without a separate hover frame at the new
// coords; the fix synchronously refreshes the GPU hover pick at (x,y) before
// the down reaches the tool. (No mouse-up: we read the live anchor mid-gesture,
// matching the repro's down-only pick.)
string pickNoHoverLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    log ~= format(
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y);
    log ~= format(
        `{"t":100.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":1,"yrel":0,"state":1,"mod":0}` ~ "\n",
        x + 1, y);
    return log;
}

// Activate the element-move preset with a wide falloff sphere (dist 4) so a
// pick anywhere hauls the whole cube, and elementMode=polyCent so a face pick
// anchors at the FACE CENTROID (clean coords: +Y face → (0,0.5,0), +X face →
// (0.5,0,0)). vert 6 pre-selected so the preset has a non-empty selection.
void activateElementMovePreset() {
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    postJson("/api/script", "tool.set xfrm.elementMove on");
    postJson("/api/command", "tool.pipe.attr falloff dist 4");
    postJson("/api/command", "tool.pipe.attr falloff elementMode polyCent");
    settle();
}

// Project a world point to a window pixel with the live camera.
void worldPx(Vec3 w, ref CameraState cam, ref Viewport vp, out int px, out int py) {
    float sx, sy;
    assert(projectToWindow(w, vp, sx, sy),
        "world point off-camera: (" ~ w.x.to!string ~ "," ~ w.y.to!string ~
        "," ~ w.z.to!string ~ ")");
    px = cast(int)sx;
    py = cast(int)sy;
}

// ---------------------------------------------------------------------------
// Gesture 1 anchors at the +Y face (y≈0.5); gesture 2 — the fast click with NO
// preceding hover batch — must relocate the anchor to the +X face (x≈0.5).
// Before the fix the anchor stayed stale at the +Y face.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    activateElementMovePreset();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // +Y (top) face centroid (0,0.5,0) and +X face centroid (0.5,0,0).
    int yx, yy, xx, xy;
    worldPx(Vec3(0, 0.5f, 0), cam, vp, yx, yy);
    worldPx(Vec3(0.5f, 0, 0), cam, vp, xx, xy);

    // The two faces must project to clearly distinct pixels, else the test is
    // not exercising a "large cursor jump".
    double jump = sqrt(cast(double)((xx - yx) * (xx - yx) +
                                    (xy - yy) * (xy - yy)));
    assert(jump > 30.0,
        "+Y and +X face pixels too close to be a meaningful cursor jump: " ~
        "(" ~ yx.to!string ~ "," ~ yy.to!string ~ ") vs (" ~
        xx.to!string ~ "," ~ xy.to!string ~ ")");

    // Gesture 1: hover-settle on the +Y face THEN a small pick+haul there.
    // Establishes the action center at the +Y anchor (y≈0.5).
    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height, yx, yy));
    settle();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             yx, yy, yx, yy - 12, 6));
    settle();

    Vec3 anchorY = evalPivot();
    assert(anchorY.y > 0.3,
        "gesture 1 should anchor at the +Y face (y≈0.5); got y=" ~
        anchorY.y.to!string);

    // Gesture 2 — THE KEY: pick the +X face with NO separate hover-settle
    // batch (a down + 1px-motion batch = the fast interactive click). The fix
    // synchronously re-picks GPU hover at the click coords before the down, so
    // tryPickElement anchors to the +X face, not the stale +Y face.
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    worldPx(Vec3(0.5f, 0, 0), cam, vp, xx, xy);
    playAndWait(pickNoHoverLog(cam.vpX, cam.vpY, cam.width, cam.height, xx, xy));
    settle();

    Vec3 anchorX = evalPivot();

    // The pivot must have relocated to the +X face anchor. Pre-fix it stayed at
    // the +Y anchor (y≈0.5, x≈0); post-fix it is the +X anchor [0.5, ~0, ~0].
    assert(fabs(anchorX.x - 0.5f) < 0.05f,
        "fast +X click must relocate the anchor to the +X face (x≈0.5); got " ~
        "(" ~ anchorX.x.to!string ~ "," ~ anchorX.y.to!string ~ "," ~
        anchorX.z.to!string ~ ") — pre-fix this stayed at the stale +Y anchor");
    assert(fabs(anchorX.y) < 0.1f,
        "+X face anchor should have |y|<0.1 (the stale +Y anchor had y≈0.5); " ~
        "got y=" ~ anchorX.y.to!string);
    assert(fabs(anchorX.z) < 0.1f,
        "+X face anchor should have |z|<0.1; got z=" ~ anchorX.z.to!string);

    // Release cleanly so a trailing test isn't left mid-gesture.
    string up = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, xx + 1, xy);
    playAndWait(up);
    settle();
    postJson("/api/script", "tool.set xfrm.elementMove off");
    settle();
}
