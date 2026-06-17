// Element-move: clicking an element whose pixel COINCIDES with the gizmo
// center must relocate the action center to that element.
//
// Repro for the "handle doesn't move to the clicked element" bug: with an
// empty selection the Element-mode gizmo sits at the whole-mesh centroid
// (origin). The cube's most-facing face also projects right on top of the
// gizmo, so a click on that face lands on the move CENTER handle (centerBox).
// Before the fix the centerBox won the hit-test → the click started a
// center-plane drag instead of an element pick, so the gizmo never moved.
//
// MODO's ElementMove preset drops the transform center handle exactly so
// every click is an element pick; vibe3d now hides the centerBox in the
// element-move flow, so the click falls through to tryPickElement and the
// pivot relocates onto the clicked face.

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

void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(150.msecs);
}

long undoCount() { return getJson("/api/history")["undo"].array.length; }

void drainHistory() {
    foreach (_; 0 .. 100) {
        if (undoCount() == 0) return;
        postJson("/api/undo", "");
    }
}

void establishCubeBaseline() {
    import core.thread : Thread;
    import core.time   : msecs;
    bool cubePristine() {
        auto v = getJson("/api/model")["vertices"].array;
        if (v.length != 8) return false;
        auto c = v[6].array;
        return fabs(c[0].floating - 0.5) < 1e-3
            && fabs(c[1].floating - 0.5) < 1e-3
            && fabs(c[2].floating - 0.5) < 1e-3;
    }
    foreach (attempt; 0 .. 8) {
        postJson("/api/script", "tool.set xfrm.elementMove off");
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

Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}

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

// ---------------------------------------------------------------------------
// Empty selection ⇒ gizmo at origin. Click the most-facing face AT the gizmo
// center pixel. The pivot must relocate onto that face (≈0.5 off origin).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    // No selection: Element-mode gizmo sits at the whole-mesh centroid (origin),
    // and the moving set is the whole cube.
    postJson("/api/script", "tool.set xfrm.elementMove on");
    postJson("/api/command", "tool.pipe.attr falloff dist 4");
    settle();

    // Pivot starts at the origin (whole-mesh centroid).
    Vec3 start = evalPivot();
    assert(sqrt(start.x*start.x + start.y*start.y + start.z*start.z) < 0.1f,
        "empty-selection Element gizmo should start at the origin; got " ~
        "(" ~ start.x.to!string ~ "," ~ start.y.to!string ~ "," ~
        start.z.to!string ~ ")");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // The gizmo-center pixel = origin projected. The most-facing face projects
    // right here too, so this is the click that used to hit the centerBox.
    int gx, gy;
    {
        float sx, sy;
        assert(projectToWindow(Vec3(0, 0, 0), vp, sx, sy),
            "origin should be on-camera");
        gx = cast(int)sx; gy = cast(int)sy;
    }

    // Hover-settle over that pixel, then a DOWN-only pick (down + 1px motion,
    // no up) so we read the relocated anchor mid-gesture — before the haul of
    // the (whole-mesh) moving set + the mouse-up commit recompute the centroid.
    // Mirrors test_element_pick_fresh_hover's gesture 2.
    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height, gx, gy));
    settle();
    string downOnly = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n" ~
        `{"t":100.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":1,"yrel":0,"state":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, gx, gy, gx + 1, gy);
    playAndWait(downOnly);
    settle();

    Vec3 anchor = evalPivot();
    float moved = sqrt((anchor.x - start.x) * (anchor.x - start.x) +
                       (anchor.y - start.y) * (anchor.y - start.y) +
                       (anchor.z - start.z) * (anchor.z - start.z));

    // Release cleanly so a trailing test isn't left mid-gesture.
    string up = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, gx + 1, gy);
    playAndWait(up);
    settle();

    assert(moved > 0.3f,
        "clicking the face at the gizmo center must relocate the pivot onto " ~
        "the face (was stuck at the centerBox pre-fix); pivot moved only " ~
        moved.to!string ~ " to (" ~ anchor.x.to!string ~ "," ~
        anchor.y.to!string ~ "," ~ anchor.z.to!string ~ ")");

    postJson("/api/script", "tool.set xfrm.elementMove off");
    settle();
}
