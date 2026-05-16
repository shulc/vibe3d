// Tests for ElementMoveTool's click-to-pick (Stage 14.3).
//
// On LMB-down that doesn't hit the move-gizmo and has no modifier
// keys, ElementMoveTool projects every mesh element onto the
// viewport and finds the nearest within 16 px. The matching
// element's centroid is written into FalloffStage.pickedCenter,
// so the subsequent drag (or doApply) translates only the verts
// inside the element-falloff sphere around it.
//
// Driven through /api/play-events with a synthetic SDL click log,
// then inspected via /api/toolpipe.

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

double[3] pickedCenterAttr() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array)
        if (st["task"].str == "WGHT") {
            auto v = st["attrs"]["pickedCenter"].str;
            // "x,y,z" → 3 doubles.
            import std.string : split;
            import std.conv   : to;
            auto p = v.split(",");
            return [p[0].to!double, p[1].to!double, p[2].to!double];
        }
    assert(false, "WGHT stage missing");
}

JSONValue camera() {
    return getJson("/api/camera");
}

bool approxEq(double a, double b, double eps = 1e-3) {
    return fabs(a - b) < eps;
}

unittest { // headless API still works: pickedCenter set via tool.pipe.attr
           // is what the falloff stage publishes back.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff pickedCenter \"0.25,-0.3,0.7\"");
    auto pc = pickedCenterAttr();
    assert(approxEq(pc[0],  0.25, 1e-4),
        "pickedCenter.x expected 0.25, got " ~ pc[0].to!string);
    assert(approxEq(pc[1], -0.30, 1e-4));
    assert(approxEq(pc[2],  0.70, 1e-4));
}

unittest { // After preset activation, pickedCenter starts at the
           // FalloffStage default (Vec3.init / 0,0,0). Drag without
           // an explicit pickedCenter pulls verts toward origin via
           // the element-sphere there, which on the default cube
           // means only verts near origin move — i.e. nothing on a
           // standard ±0.5 cube.
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("tool.set xfrm.elementMove on");
    // Default dist = 0.5 after autoSize on cube (bbox half = 0.5).
    // Default pickedCenter = (0, 0, 0). No cube corner sits within
    // 0.5 of origin (corners at √(3·0.25) ≈ 0.87), so weights = 0,
    // doApply should leave everything alone.
    cmd("tool.attr xfrm.elementMove TX 0.3");
    cmd("tool.doApply");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        // Every corner stays on ±0.5.
        foreach (c; 0 .. 3)
            assert(approxEq(fabs(a[c].floating), 0.5, 1e-4),
                "default pickedCenter at origin shouldn't move corners");
    }
}

unittest { // Picking an element via click+drag must move the WHOLE
           // picked element regardless of how the falloff radius
           // compares to the element's extent. On the default cube
           // (autoSize → dist=0.5), a face's 4 corners sit at √2·0.5
           // ≈ 0.707 from the face centroid — well outside the
           // sphere — so without the picked-element override the
           // drag would produce zero motion (the bug this guards
           // against). The fix gives picked verts full weight; the
           // four +Z face verts (v4..v7) must move by the full drag
           // delta while the -Z face (v0..v3) stays put.
    import std.net.curl     : get, post;
    import std.json         : parseJSON, JSONValue;
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff pickedCenter \"0,0,0.5\"");
    cmd("tool.pipe.attr falloff dist 0.5");
    // Simulate a face pick by registering the +Z face's vert ring on
    // the FalloffStage. The HTTP attr surface doesn't expose
    // pickedVerts directly; doApply still runs through the same
    // elementWeight code path, so we drive the override via the same
    // TX numeric input used elsewhere in this file.
    //
    // For this scenario the +Z face is verts 4,5,6,7 on the default
    // cube. With pickedCenter at (0,0,0.5) and dist=0.5, NONE of those
    // corners sits inside the sphere — the only way they move is if
    // the picked-element override kicks in. We seed it by setting the
    // element-falloff `connect` to a non-Off value (which the
    // ElementMoveTool would do on a real click) and rely on the click-
    // pick path that lives in ElementMoveTool.onMouseButtonDown.
    //
    // Click path via the event log: project the +Z face centroid into
    // window pixels and synthesise an LMB-down + drag + LMB-up. The
    // pick logic in tryPickElement fills `pickedVerts`; the drag then
    // moves the picked face.
    JSONValue camResp = postJson("/api/camera",
        `{"azimuth":0,"elevation":0,"distance":3}`);
    assert(camResp["status"].str == "ok");
    auto cam = parseJSON(cast(string) get(baseUrl ~ "/api/camera"));
    int vpX = cast(int)cam["vpX"].integer;
    int vpY = cast(int)cam["vpY"].integer;
    int vpW = cast(int)cam["width"].integer;
    int vpH = cast(int)cam["height"].integer;
    // Viewport centre — +Z face centroid projects there with the
    // axis-aligned camera set above.
    int cx = vpX + vpW / 2;
    int cy = vpY + vpH / 2;
    import std.format : format;
    string log = format!`{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}
{"t":100,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}
{"t":200,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}
{"t":250,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":5,"yrel":0,"state":1,"mod":0}
{"t":300,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":20,"yrel":0,"state":1,"mod":0}
{"t":400,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":0,"mod":0}
`(vpX, vpY, vpW, vpH,
  cx, cy, cx, cy, cx+5, cy, cx+25, cy, cx+25, cy);
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success",
        "play-events failed: " ~ r.toString);
    // Poll until playback completes.
    foreach (_; 0 .. 50) {
        auto st = getJson("/api/play-events/status");
        if (st["finished"].boolean) break;
        import core.thread : Thread;
        import core.time   : msecs;
        Thread.sleep(50.msecs);
    }
    auto verts = getJson("/api/model")["vertices"].array;
    double[3][] vs;
    foreach (v; verts) {
        auto a = v.array;
        vs ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    // -Z face untouched.
    foreach (i; 0 .. 4)
        assert(approxEq(vs[i][2], -0.5, 1e-4)
            && approxEq(fabs(vs[i][0]), 0.5, 1e-4)
            && approxEq(fabs(vs[i][1]), 0.5, 1e-4),
            "v" ~ i.to!string ~ " on -Z face must stay put; got "
            ~ vs[i][0].to!string ~ "," ~ vs[i][1].to!string ~ ","
            ~ vs[i][2].to!string);
    // +Z face verts all moved by the SAME X delta — the whole face
    // dragged as a rigid unit (all four have picked-element weight 1).
    double dx = vs[4][0] - (-0.5);
    assert(dx > 0.05,
        "v4 (+Z face) must move along +X; got delta " ~ dx.to!string);
    foreach (i; 5 .. 8) {
        double di = vs[i][0] - [0.5, 0.5, -0.5][i-5];
        assert(approxEq(di, dx, 1e-4),
            "all +Z face verts must move together; v" ~ i.to!string
            ~ " delta " ~ di.to!string ~ " vs v4 delta " ~ dx.to!string);
    }
}

unittest { // Picked element must move even when an UNRELATED prior
           // selection exists. Selection is captured by the base
           // TransformTool to populate `vertexIndicesToProcess` — if
           // ElementMoveTool defers to that, the click-picked verts
           // (which aren't selected) are excluded from the drag loop
           // and the picked element stays put despite the gizmo
           // following it. The ElementMoveTool override should bypass
           // selection and iterate every vert; `elementWeight` then
           // gates per-vert via pickedVerts + sphere.
    import std.net.curl     : get, post;
    import std.json         : parseJSON, JSONValue;
    postJson("/api/reset", "");
    // Preselect face[0] = -Z face (verts 0..3). The click below picks
    // +Z face (verts 4..7), which has zero overlap with the selection.
    postJson("/api/select",
        `{"mode":"polygons","indices":[0]}`);
    cmd("tool.set xfrm.elementMove on");
    JSONValue camResp = postJson("/api/camera",
        `{"azimuth":0,"elevation":0,"distance":3}`);
    assert(camResp["status"].str == "ok");
    auto cam = parseJSON(cast(string) get(baseUrl ~ "/api/camera"));
    int vpX = cast(int)cam["vpX"].integer;
    int vpY = cast(int)cam["vpY"].integer;
    int vpW = cast(int)cam["width"].integer;
    int vpH = cast(int)cam["height"].integer;
    int cx = vpX + vpW / 2;
    int cy = vpY + vpH / 2;
    import std.format : format;
    string log = format!`{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}
{"t":100,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}
{"t":200,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}
{"t":250,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":5,"yrel":0,"state":1,"mod":0}
{"t":300,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":20,"yrel":0,"state":1,"mod":0}
{"t":400,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":0,"mod":0}
`(vpX, vpY, vpW, vpH,
  cx, cy, cx, cy, cx+5, cy, cx+25, cy, cx+25, cy);
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success",
        "play-events failed: " ~ r.toString);
    foreach (_; 0 .. 50) {
        auto st = getJson("/api/play-events/status");
        if (st["finished"].boolean) break;
        import core.thread : Thread;
        import core.time   : msecs;
        Thread.sleep(50.msecs);
    }
    auto verts = getJson("/api/model")["vertices"].array;
    double[3][] vs;
    foreach (v; verts) {
        auto a = v.array;
        vs ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    // -Z face (selected, but NOT picked) stays put — the picked
    // element wins, not the selection.
    foreach (i; 0 .. 4)
        assert(approxEq(vs[i][2], -0.5, 1e-4)
            && approxEq(fabs(vs[i][0]), 0.5, 1e-4)
            && approxEq(fabs(vs[i][1]), 0.5, 1e-4),
            "selected -Z face must stay put; v" ~ i.to!string
            ~ " moved to " ~ vs[i][0].to!string ~ ","
            ~ vs[i][1].to!string ~ "," ~ vs[i][2].to!string);
    // Picked +Z face moves as a rigid unit.
    double dx = vs[4][0] - (-0.5);
    assert(dx > 0.05,
        "picked +Z face must drag with the cursor despite -Z being "
        ~ "the selected element; got v4 delta " ~ dx.to!string);
    foreach (i; 5 .. 8) {
        double di = vs[i][0] - [0.5, 0.5, -0.5][i-5];
        assert(approxEq(di, dx, 1e-4),
            "picked +Z face verts must move together; v" ~ i.to!string
            ~ " delta " ~ di.to!string);
    }
}
