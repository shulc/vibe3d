// Task 0614 Phase 3 — the e2e proof of L4, the SAME-INDEX scale rule.
//
// Measured (doc/tasks/0614-evidence/phase0b_findings.md, Phase 0b case D):
// a gesture scale factor along frame axis j multiplies the item's own
// scl[j] — unconditionally, at every base rotation, INCLUDING the 90-degree
// control where the geometrically exact answer would land on a DIFFERENT
// index. At rot.y=90 the item's own local Z axis lies along world X, so the
// exactly-representable result of "scale world-X by k" would be scl==(1,1,k)
// — and the reference measured scl==(k,1,1) anyway. The reference is not
// representability-aware; it does a plain component-wise multiply by frame
// index, always.
//
// DO NOT "fix" the rot.y=90 assertion below back to expecting scl.z to
// change — that is the refuted candidate (nearest-item-axis / exact-
// conjugation), not the measured law. This exact inversion already
// happened once while writing this task's plan (see the plan's own
// "Capture response 2" section) before any code existed.
//
// The kernel-level version of this proof (matrix-exact, all three of
// 30/60/90 degrees) lives in source/tools/transform/item_xform_kernels.d's
// own unittest, covered by `dub test --config=modeling`. This file proves
// the WIRING delivers the gesture factor to the kernel at the right index
// end to end, through a real gizmo drag.

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

// A world-X scale-handle drag on an item rotated `rotYdeg` about Y must
// land on scl.x, NEVER scl.z — at every angle, including 90.
void runCase(float rotYdeg) {
    resetCube();
    cmd("layer.attr 0 rot.y " ~ rotYdeg.to!string);
    cmd("layer.select index:0");

    auto before = layerXform(0);
    string preVerts = verticesJson(0);

    post(BASE ~ "/api/script", "tool.set scale");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 pivot = Vec3(0, 0, 0);   // pos=pivot=0 here, item world pivot is the origin
    int gx, gy; double ux, uy;
    axisGrabPx(pivot, vp, gx, gy, ux, uy);   // WORLD-X handle (axisGrabPx targets +X)
    int x1 = gx + cast(int)(50.0 * ux);
    int y1 = gy + cast(int)(50.0 * uy);

    auto log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, gx, gy, x1, y1);
    playAndWait(log);

    post(BASE ~ "/api/script", "tool.set scale off");

    auto after = layerXform(0);
    auto as = after["scl"].array;
    auto ar = after["rot"].array;
    auto br = before["rot"].array;

    assert(!approx(as[0].floating, 1.0),
        format("rot.y=%.0f: a world-X scale drag must change scl.x, got scl=%s",
               rotYdeg, after["scl"].toString));
    assert(approx(as[1].floating, 1.0),
        format("rot.y=%.0f: a world-X scale drag must NOT touch scl.y, got scl=%s",
               rotYdeg, after["scl"].toString));
    assert(approx(as[2].floating, 1.0),
        format("rot.y=%.0f: THE SAME-INDEX RULE (L4) — a world-X scale drag must "
             ~ "land on scl.x, NOT scl.z, even at the 90-degree control where the "
             ~ "geometrically exact answer would be scl.z. Measured: "
             ~ "phase0b_findings.md case D writes (2,1,1) at every angle, never "
             ~ "(1,1,2). Got scl=%s", rotYdeg, after["scl"].toString));

    assert(approx(ar[0].floating, br[0].floating)
        && approx(ar[1].floating, br[1].floating)
        && approx(ar[2].floating, br[2].floating),
        "a scale gesture must never touch rot — before=" ~ before["rot"].toString
        ~ " after=" ~ after["rot"].toString);

    string postVerts = verticesJson(0);
    assert(preVerts == postVerts,
        format("rot.y=%.0f: scale apply must leave mesh.vertices byte-identical",
               rotYdeg));
}

unittest { runCase(90.0f); }   // the decisive control (phase0b_findings.md)
unittest { runCase(30.0f); }   // the non-aligned pose
