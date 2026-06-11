// Box-construction snap coverage for the announcement-QA "Snap" item.
//
// Each SnapType is verified through the LIVE BoxTool base-corner click:
// the first click in BoxState.Idle runs `snapLocalHit` against the
// toolpipe SNAP stage (source/tools/box.d:2084), rewrites the base
// corner to the snapped target, and publishes the result to
// /api/snap/last via `publishLastSnap`. That published world-space
// SnapResult is our observable — `snapped==true` proves the box's base
// corner consumed that exact target (the same call rewrites startPoint).
//
// This is the gap the existing snap tests don't cover: test_toolpipe_snap
// only hits the /api/snap query endpoint, and test_snap_during_drag drives
// MoveTool — neither exercises snap during primitive construction.
//
// Reference geometry is the default unit cube (±0.5). Snap range is set
// effectively infinite so the nearest target of each type always fires
// regardless of camera; we assert the target TYPE and its coordinate
// pattern, both camera-independent.

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;
import std.format : format;
import core.thread : Thread;
import core.time : dur;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";

JSONValue getJson(string p)            { return parseJSON(cast(string)get(BASE ~ p)); }
JSONValue postJson(string p, string b) { return parseJSON(cast(string)post(BASE ~ p, b)); }

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

// Reset to the default unit cube (the snap reference), park the camera,
// activate prim.cube, and arm SNAP with one type + effectively-infinite
// range so the nearest target always qualifies.
void resetBoxWithSnap(string types) {
    auto r = postJson("/api/reset", "");          // default cube = 8 verts
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    cmd("history.clear");
    r = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":1.1,"distance":4.0,"focus":{"x":0,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
    cmd("tool.set prim.cube");
    cmd("tool.pipe.attr snap enabled true");
    cmd("tool.pipe.attr snap types " ~ types);
    cmd("tool.pipe.attr snap innerRange 999999");
    cmd("tool.pipe.attr snap outerRange 999999");
}

// Replay a single base-corner click (no motion) at the window pixel under
// the world origin, then return the box tool's published snap result.
JSONValue clickBaseCornerAtOrigin() {
    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    float px, py;
    assert(projectToWindow(Vec3(0, 0, 0), vp, px, py), "origin projects behind camera");
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        cam.vpX, cam.vpY, cam.width, cam.height, cast(int)px, cast(int)py);
    playAndWait(log, BASE);
    Thread.sleep(dur!"msecs"(150));   // post-playback drain settle (see CLAUDE.md)
    return getJson("/api/snap/last");
}

// SnapType bitmask values (source/snap.d): Vertex=1.
unittest { // Vertex snap fires on a cube vert during box base-corner click
    resetBoxWithSnap("vertex");
    auto sr = clickBaseCornerAtOrigin();
    assert(sr["snapped"].type == JSONType.true_,
        "box base click should snap to a vertex, got " ~ sr.toString);
    assert(cast(int)sr["targetType"].integer == 1,
        "targetType expected 1 (Vertex), got " ~ sr.toString);
    auto wp = sr["worldPos"].array;
    foreach (i, c; wp) {
        double v = c.floating;
        assert(approx(v, -0.5) || approx(v, 0.5),
            "worldPos[" ~ i.to!string ~ "]=" ~ v.to!string
            ~ " is not a cube-vert coordinate; got " ~ sr.toString);
    }
}
