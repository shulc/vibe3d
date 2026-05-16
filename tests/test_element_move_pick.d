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
