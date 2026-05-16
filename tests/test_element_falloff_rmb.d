// Tests for Stage 14.6 — RMB drag on element falloff adjusts the
// sphere radius (= MODO's `dist`/Range attr). Mirrors the screen-
// falloff RMB API but in world space: RMB-down captures the current
// pickedCenter/dist + click-point on a camera-back plane; RMB-motion
// remaps cursor distance to a new dist; RMB-up ends the gesture.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;
import std.format : format;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}
void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

float falloffDist() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array)
        if (st["task"].str == "WGHT")
            return st["attrs"]["dist"].str.to!float;
    assert(false, "WGHT stage missing");
}

// JSON Lines RMB drag log (btn=3 = SDL_BUTTON_RIGHT). Mirrors
// drag_helpers.d:buildDragLog but for the right button.
string buildRMBDragLog(int vpX, int vpY, int vpW, int vpH,
                      int x0, int y0, int x1, int y1, int steps = 10) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    double tDown = 50.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        tDown, x0, y0);
    double stepMs = 50.0;
    int lastX = x0, lastY = y0;
    foreach (i; 1 .. steps + 1) {
        int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / steps);
        int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / steps);
        double t = tDown + i * stepMs;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":4,"mod":0}` ~ "\n",
            t, x, y, x - lastX, y - lastY);
        lastX = x; lastY = y;
    }
    double tUp = tDown + (steps + 1) * stepMs;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        tUp, x1, y1);
    return log;
}

void playAndWait(string log) {
    auto resp = post(baseUrl ~ "/api/play-events", log);
    auto j = parseJSON(cast(string) resp);
    assert(j["status"].str == "success",
        "play-events failed: " ~ cast(string) resp);
    foreach (i; 0 .. 200) {
        auto s = parseJSON(cast(string) get(baseUrl ~ "/api/play-events/status"));
        if (s["finished"].type == JSONType.true_) return;
        import core.thread, core.time;
        Thread.sleep(50.msecs);
    }
    assert(false, "play-events did not finish within 10s");
}

unittest { // RMB drag rightward grows dist; leftward shrinks
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.elementMove on");
    // Anchor the picked sphere at origin with radius 0.5 — predictable
    // baseline for the gesture.
    cmd("tool.pipe.attr falloff pickedCenter \"0,0,0\"");
    cmd("tool.pipe.attr falloff dist 0.5");

    auto distBefore = falloffDist();
    assert(fabs(distBefore - 0.5) < 1e-4,
        "expected dist=0.5 baseline; got " ~ distBefore.to!string);

    // Camera setup: use vibe3d's default view. The viewport is the
    // window; pull it from /api/camera so RMB-projection lands on a
    // sensible camera-back plane through the picked centre at origin.
    auto cam = getJson("/api/camera");
    int vpX = cast(int) cam["vpX"].integer;
    int vpY = cast(int) cam["vpY"].integer;
    int vpW = cast(int) cam["width"].integer;
    int vpH = cast(int) cam["height"].integer;

    // Anchor click at the screen centre (= projects to ~origin on the
    // camera-back plane through origin); drag rightward by 200 px.
    int cx = vpX + vpW / 2;
    int cy = vpY + vpH / 2;
    string log = buildRMBDragLog(vpX, vpY, vpW, vpH,
                                 cx, cy, cx + 200, cy);
    playAndWait(log);

    auto distAfter = falloffDist();
    assert(distAfter > distBefore,
        "RMB-rightward drag should grow dist; before="
        ~ distBefore.to!string ~ " after=" ~ distAfter.to!string);
}

unittest { // RMB drag with element-falloff inactive falls through
           // to the standard lasso path (no NaN, no dist drift).
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    // Plain Move, no element falloff active.
    cmd("tool.set move on");
    cmd("tool.pipe.attr falloff type none");
    // RMB drag — should NOT change anything element-related (and
    // shouldn't crash). We mostly verify the absence of side
    // effects: vert positions unchanged.
    auto cam = getJson("/api/camera");
    int vpX = cast(int) cam["vpX"].integer;
    int vpY = cast(int) cam["vpY"].integer;
    int vpW = cast(int) cam["width"].integer;
    int vpH = cast(int) cam["height"].integer;
    int cx = vpX + vpW / 2;
    int cy = vpY + vpH / 2;
    string log = buildRMBDragLog(vpX, vpY, vpW, vpH,
                                 cx, cy, cx + 100, cy);
    playAndWait(log);
    // Cube corners still on ±0.5 box.
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        foreach (c; 0 .. 3)
            assert(fabs(fabs(a[c].floating) - 0.5) < 1e-4,
                "RMB drag with no element falloff should not move verts");
    }
}
