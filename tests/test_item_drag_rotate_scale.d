// Task 0614 Phase 3 — the item apply path, Rotate + Scale banks.
//
// Mirrors test_item_drag_move.d for the other two banks: a gesture must
// write layer.xform (rot / scl), leave mesh.vertices byte-identical, and —
// this is the L1 consequence, NOT L3's, so it holds under any axis frame —
// leave `pos` untouched (the action centre sits AT the item's own world
// pivot, so P-c == 0 for rotate/scale regardless of what basis the gesture
// is expressed in).
//
// IMPORTANT — what this file must NOT assert (0614 review / L3): under the
// measured default WORLD ring axis, a single-ring rotate LEFT-multiplies the
// item's own rotation, so on an already-rotated item ALL THREE euler
// components can legitimately move. The plan's own first draft asserted
// "only one rot component changes" here and that assertion is BACKWARDS
// under the measured law (see doc/item_mode_transform_plan.md §(c)). This
// file only asserts that SOME rotation happened and that the world pivot
// stayed fixed — never which/how many euler components moved.

import std.net.curl;
import std.json;
import std.math  : fabs;
import std.conv  : to;
import std.format: format;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

// The `vertices` array's own JSON text — NOT the whole /api/model response,
// which carries a fresh `"timestamp"` on every call and would poison an
// exact string compare regardless of whether the vertex data moved.
string verticesJson(int layer = 0) {
    auto j = parseJSON(cast(string)get(BASE ~ format("/api/model?layer=%d", layer)));
    return j["vertices"].toString();
}

JSONValue layerXform(int layer = 0) {
    auto j = parseJSON(cast(string)get(BASE ~ "/api/layers"));
    return j["layers"].array[layer]["xform"];
}

// -----------------------------------------------------------------------
// 1. Rotate — headless RY on an item with a non-zero pivot AND an already
//    non-zero base rotation (a genuinely composed case, not a from-identity
//    one). pos must stay bit-close to its pre-gesture value; mesh untouched.
// -----------------------------------------------------------------------

unittest {
    resetCube();
    cmd("layer.attr 0 pos.x 2.0");
    cmd("layer.attr 0 pivot.y 0.75");
    cmd("layer.attr 0 rot.z 20.0");
    cmd("layer.select index:0");

    auto before = layerXform(0);
    auto bp = before["pos"].array;
    string preVerts = verticesJson(0);

    cmd("tool.set rotate on");
    cmd("tool.attr rotate RY 40");
    cmd("tool.doApply");
    cmd("tool.set rotate off");

    auto after = layerXform(0);
    auto ap = after["pos"].array;

    assert(approx(ap[0].floating, bp[0].floating)
        && approx(ap[1].floating, bp[1].floating)
        && approx(ap[2].floating, bp[2].floating),
        "rotate about the item's own pivot must leave pos untouched — before="
        ~ before["pos"].toString ~ " after=" ~ after["pos"].toString);

    auto br = before["rot"].array, ar = after["rot"].array;
    bool rotChanged = !approx(br[0].floating, ar[0].floating)
                    || !approx(br[1].floating, ar[1].floating)
                    || !approx(br[2].floating, ar[2].floating);
    assert(rotChanged, "sanity: the rotate gesture must actually change rot");

    string postVerts = verticesJson(0);
    assert(preVerts == postVerts,
        "rotate apply must leave mesh.vertices byte-identical — "
        ~ "/api/model?layer=0 changed");
}

// -----------------------------------------------------------------------
// 2. Scale — a REAL gizmo scale-box drag. pos untouched, mesh untouched,
//    scl actually changes.
// -----------------------------------------------------------------------

unittest {
    resetCube();
    cmd("layer.attr 0 pos.x -1.5");
    cmd("layer.attr 0 pivot.x 0.25");
    cmd("layer.select index:0");

    auto before = layerXform(0);
    auto bp = before["pos"].array;
    string preVerts = verticesJson(0);

    post(BASE ~ "/api/script", "tool.set scale");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    // World pivot == pos.x + pivot.x == -1.25 here.
    Vec3 pivot = Vec3(-1.25f, 0, 0);
    int gx, gy; double ux, uy;
    axisGrabPx(pivot, vp, gx, gy, ux, uy);
    int x1 = gx + cast(int)(45.0 * ux);
    int y1 = gy + cast(int)(45.0 * uy);

    auto log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, gx, gy, x1, y1);
    playAndWait(log);

    post(BASE ~ "/api/script", "tool.set scale off");

    auto after = layerXform(0);
    auto ap = after["pos"].array;
    assert(approx(ap[0].floating, bp[0].floating)
        && approx(ap[1].floating, bp[1].floating)
        && approx(ap[2].floating, bp[2].floating),
        "scale about the item's own pivot must leave pos untouched — before="
        ~ before["pos"].toString ~ " after=" ~ after["pos"].toString);

    auto bs = before["scl"].array, as = after["scl"].array;
    assert(!approx(bs[0].floating, as[0].floating),
        "a real X scale-handle drag must actually change scl.x — before="
        ~ bs[0].floating.to!string ~ " after=" ~ as[0].floating.to!string);

    string postVerts = verticesJson(0);
    assert(preVerts == postVerts,
        "scale apply must leave mesh.vertices byte-identical — "
        ~ "/api/model?layer=0 changed");
}
