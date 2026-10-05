module pen_rig_helpers;

// Rig for the polygon pen's placement cells: an empty scene seen from the top
// orthographic view with the camera focus placed AWAY from the origin (a focus
// at the origin cannot tell a focus-relative frame from the identity one), and
// gestures stated in WORLD points, turned into pixels through the matrices the
// cell renders with.

import drag_helpers : Vec3, Viewport, buildDragLog, fetchCamera, kPaceLine,
    playAndWait, projectToWindow, viewportFromCameraMatrices;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : PI, round, tan;

void penCommand(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "command `" ~ line ~ "` failed: " ~ r.toString);
}

/// Empty scene, no history, the automatic work plane, view preset `view`.
void penSceneEmpty(string view) {
    auto r = postJson("/api/command", commandBody("scene.reset", `{"empty":true}`));
    assert(r["status"].str == "ok", "empty reset failed: " ~ r.toString);
    penCommand("history.clear");
    penCommand("workplane.reset");
    penCommand("viewport.view " ~ view);
}

/// Camera focus `focus` (world) at OUR view scale of `ppm` pixels per metre
/// (viewgrid.d `viewWorldPerPixel`: ortho 1 / focalPx, perspective
/// 0.8 * distance / focalPx; field of view pi/4); a perspective view also
/// takes `azimuth` / `elevation`.
void penCameraAt(Vec3 focus, double ppm, double azimuth = 0, double elevation = 1.5) {
    const persp = getJson("/api/camera")["projKind"].str == "Perspective";
    const dist = fetchCamera().height / ((persp ? 1.6 : 2.0) * ppm * tan(PI / 8));
    string body = format(`{"focus":{"x":%.9f,"y":%.9f,"z":%.9f},"distance":%.9f`,
                         focus.x, focus.y, focus.z, dist);
    if (persp) body ~= format(`,"azimuth":%.9f,"elevation":%.9f`, azimuth, elevation);
    auto r = postJson("/api/camera", body ~ "}");
    assert(r["status"].str == "ok", "camera setup failed: " ~ r.toString);
}

/// Empty scene, an axis (ortho) view, camera focus `focus`, pen active.
void penRigEmpty(Vec3 focus, string view = "Top", double distance = 4.0) {
    penSceneEmpty(view);
    auto r = postJson("/api/camera", format(
        `{"focus":{"x":%.9f,"y":%.9f,"z":%.9f},"distance":%.9f}`,
        focus.x, focus.y, focus.z, distance));
    assert(r["status"].str == "ok", "camera setup failed: " ~ r.toString);
    assert(getJson("/api/camera")["projKind"].str == "Ortho",
        "rig premise: the axis view must be orthographic");
    penCommand("tool.set pen on");
}

/// Window pixel of a world point under the live camera; asserts it is inside
/// the viewport (a click outside it would test nothing).
int[2] worldPixel(Vec3 w) {
    Viewport vp = viewportFromCameraMatrices();
    float px, py;
    assert(projectToWindow(w, vp, px, py), "rig point behind the camera");
    int[2] p = [cast(int)round(px), cast(int)round(py)];
    assert(p[0] > vp.x && p[0] < vp.x + vp.width && p[1] > vp.y &&
        p[1] < vp.y + vp.height, format("rig point (%s,%s,%s) projects outside "
        ~ "the viewport at %s", w.x, w.y, w.z, p));
    return p;
}

/// One LMB click per world point (y is irrelevant from the top view).
void clickWorld(Vec3[] points...) {
    int[2][] pixels;
    foreach (w; points) pixels ~= worldPixel(w);
    clickPixels(pixels);
}

/// One LMB click per window pixel.
void clickPixels(int[2][] pixels...) {
    auto cam = fetchCamera();
    string log = format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,`
        ~ `"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~ kPaceLine,
        cam.vpX, cam.vpY, cam.width, cam.height);
    double t = 50;
    foreach (p; pixels) {
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,`
            ~ `"yrel":0,"state":0,"mod":0}` ~ "\n", t, p[0], p[1]);
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,`
            ~ `"y":%d,"clicks":1,"mod":0}` ~ "\n", t + 50, p[0], p[1]);
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,`
            ~ `"y":%d,"clicks":1,"mod":0}` ~ "\n", t + 100, p[0], p[1]);
        t += 150;
    }
    playAndWait(log);
}

/// One mouse motion (no button) over a world point.
void hoverWorld(Vec3 w) {
    auto cam = fetchCamera();
    auto p = worldPixel(w);
    playAndWait(format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,`
        ~ `"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~ kPaceLine
        ~ `{"t":50.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,`
        ~ `"yrel":0,"state":0,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, p[0], p[1]));
}

/// Press on the world point `from` and drag `dxPx` pixels in screen x.
void dragWorld(Vec3 from, int dxPx) {
    auto cam = fetchCamera();
    auto p = worldPixel(from);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
        p[0], p[1], p[0] + dxPx, p[1]));
}

void penAttr(string name, double value) {
    penCommand(format("tool.attr pen %s %.9f", name, value));
}

/// A JSON number; anything else (a NaN is published as null) reads as NaN,
/// so the caller's tolerance test fails instead of the read throwing.
private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger
         : v.type == JSONType.float_ ? v.floating : double.nan;
}

double penAttrValue(string name) {
    auto r = postJson("/api/command", "tool.attr pen " ~ name ~ " ?");
    assert(r["status"].str == "ok", "attr query " ~ name ~ " failed: " ~ r.toString);
    return num(r["value"]);
}

/// World positions of the primary mesh's vertices.
Vec3[] readVerts() {
    Vec3[] vs;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        vs ~= Vec3(cast(float)num(a[0]), cast(float)num(a[1]),
                   cast(float)num(a[2]));
    }
    return vs;
}
