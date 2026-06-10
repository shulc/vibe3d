// Phase 0 repro — handle x N then in-session Ctrl+Z resets the panel value to 0.
//
// THIS TEST IS EXPECTED TO FAIL ON THE CURRENT BUILD (Phase 0 of the transform-
// tool sync fix). It pins the bug; it does NOT fix it.
//
// For EACH of Move, Rotate, Scale: two same-bank gizmo gestures in ONE wrapper
// session. The run-absolute field accumulates, so the published run total after
// gesture 1 = field1 and after gesture 2 = field2 (field2 strictly past field1).
// Then an in-session Ctrl+Z (keyboard chokepoint, tool LIVE).
//
// CURRENT BEHAVIOR:
//   * GEOMETRY steps back to the post-gesture-1 pose (CORRECT — the per-gesture
//     undo hook drives the reverted geometry). This part PASSES today.
//   * The PUBLISHED field resets to IDENTITY (0 for T/R, 1.0 for S) because the
//     session resync zeroes the field AFTER the revert hook restored it. This is
//     the bug. The field SHOULD read field1 (the run total of the step we reverted
//     to), keeping the panel in lockstep with the geometry.
//
// ASSERTIONS: after Ctrl+Z, geometry maxVertDiff(now, afterG1) is small (PASSES),
// AND the published field == field1, NOT identity (FAILS today — actual reads ~0
// for T/R, ~1.0 for S).
//
// Discipline (from the run-absolute templates): NO selection drain after
// /api/reset (history.clear); ~120ms settle after play-events; vec3 attrs double-
// quoted; ring/arrow/box grab retries on the undo count; published values read off
// /api/toolpipe/eval, geometry off /api/model.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, sin, cos, atan2, PI;
import std.conv : to;
import std.format : format;

import drag_helpers : Vec3, dot, cross, normalize, gizmoSize,
                      fetchCamera, viewportFromCamera, CameraState, Viewport,
                      projectToWindow, buildDragLog, playAndWait;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}
void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "/api/command '" ~ line ~ "' failed: "
        ~ r.toString);
}
long undoCount() { return getJson("/api/history")["undo"].array.length; }

void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(120.msecs);
}
void drainHistory() {
    foreach (_; 0 .. 100) {
        if (undoCount() == 0) return;
        postJson("/api/undo", "");
    }
}
bool replayIdle() {
    auto s = getJson("/api/play-events/status");
    auto f = "finished" in s;
    return f is null || f.type != JSONType.false_;
}

// SDL Ctrl+Z keystroke -> handleKeyDown -> navHistory(true). 122='z', mod 64 =
// KMOD_LCTRL. Drives the in-session keyboard chokepoint (NOT /api/undo).
string ctrlZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n",
        t, t + 10.0);
}

Vec3[] dumpVerts() {
    auto verts = getJson("/api/model")["vertices"].array;
    Vec3[] o; o.length = verts.length;
    foreach (i, v; verts) {
        auto a = v.array;
        o[i] = Vec3(cast(float)a[0].floating,
                    cast(float)a[1].floating,
                    cast(float)a[2].floating);
    }
    return o;
}
float maxVertDiff(Vec3[] a, Vec3[] b) {
    float m = 0;
    foreach (i; 0 .. a.length) {
        Vec3 d = a[i] - b[i];
        float len = sqrt(dot(d, d));
        if (len > m) m = len;
    }
    return m;
}

int findTopFace() {
    auto m = getJson("/api/model");
    auto verts = m["vertices"].array;
    foreach (fi, f; m["faces"].array) {
        bool top = true;
        foreach (vi; f.array) {
            double vy = verts[vi.integer].array[1].floating;
            if (fabs(vy - 0.5) > 1e-4) { top = false; break; }
        }
        if (top) return cast(int)fi;
    }
    assert(false, "no top face found in default cube");
}

void lockCamera() {
    auto r = postJson("/api/camera",
        `{"azimuth":0.5,"elevation":0.4,"distance":3.0,`
      ~ `"focus":{"x":0.0,"y":0.0,"z":0.0}}`);
    assert(r["status"].str == "ok", "camera lock failed: " ~ r.toString);
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
        postJson("/api/script", "tool.set xfrm.transform off");
        postJson("/api/script", "tool.set move off");
        postJson("/api/script", "tool.set rotate off");
        postJson("/api/script", "tool.set scale off");
        postJson("/api/script", "tool.set Transform off");
        foreach (_; 0 .. 200) {
            if (replayIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        postJson("/api/reset", "");                 // cube
        postJson("/api/command", "history.clear");  // wipe stacks, keep the cube
        postJson("/api/command", "workplane.reset");
        postJson("/api/command", "tool.pipe.attr axis mode world");
        if (cubePristine() && undoCount() == 0) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");
    postJson("/api/command", "workplane.reset");
    postJson("/api/command", "tool.pipe.attr axis mode world");
    assert(cubePristine(), "could not establish pristine cube baseline");
}

// Authoritative gizmo pivot from the evaluated ActionCenterPacket.
Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}

double publishedT(int axis) {
    auto j = getJson("/api/toolpipe/eval");
    auto t = "transform" in j.object;
    assert(t !is null, "eval has no transform block: " ~ j.toString);
    return (*t)["translate"].array[axis].floating;
}
double publishedR(int axis) {
    auto j = getJson("/api/toolpipe/eval");
    auto t = "transform" in j.object;
    assert(t !is null, "eval has no transform block: " ~ j.toString);
    return (*t)["rotate"].array[axis].floating;
}
double publishedS(int axis) {
    auto j = getJson("/api/toolpipe/eval");
    auto t = "transform" in j.object;
    assert(t !is null, "eval has no transform block: " ~ j.toString);
    return (*t)["scale"].array[axis].floating;
}

// Select the top face, ACEN.Auto, single-flag xfrm.transform. `flag` is one of
// "T"/"R"/"S"; the other two are turned off so a gesture cannot land on a foreign
// bank's handle.
void setupSingleBankScene(string flag) {
    establishCubeBaseline();
    lockCamera();
    int topFace = findTopFace();
    auto sel = postJson("/api/select",
        `{"mode":"polygons","indices":[` ~ topFace.to!string ~ `]}`);
    assert(sel["status"].str == "ok", "select failed: " ~ sel.toString);
    settle();
    cmd("actr.auto");
    cmd("tool.pipe.attr axis mode world");
    settle();
    cmd("tool.set xfrm.transform on");
    cmd("tool.attr xfrm.transform T " ~ (flag == "T" ? "true" : "false"));
    cmd("tool.attr xfrm.transform R " ~ (flag == "R" ? "true" : "false"));
    cmd("tool.attr xfrm.transform S " ~ (flag == "S" ? "true" : "false"));
}

Vec3 autoPivot = Vec3(0, 0.5f, 0);   // top-face centroid, stable under X/Y/Z

// --- Move +X arrow gesture ---------------------------------------------------
void arrowGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy,
                 out double ux, out double uy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,        pivot.y, pivot.z), vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}
void moveGestureOnHandle(long wantCount, double mag = 60.0) {
    foreach (attempt; 0 .. 8) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        int xa, ya; double ux, uy;
        arrowGrabPx(evalPivot(), vp, xa, ya, ux, uy);
        int xb = xa + cast(int)(mag * ux);
        int yb = ya + cast(int)(mag * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xa, ya, xb, yb, 10));
        settle();
        if (undoCount() == wantCount) return;
    }
    assert(false, "move +X arrow gesture did not record after retries");
}

// --- Scale +X handle gesture -------------------------------------------------
void axisGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy,
                out double ux, out double uy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size / 7.0f,  pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size * 1.18f, pivot.y, pivot.z), vp, sx2, sy2);
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
    gx = cast(int)sx2;
    gy = cast(int)sy2;
}
void scaleGestureOnHandle(long wantCount, double mag = 70.0) {
    foreach (attempt; 0 .. 8) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        int x1, y1; double ux, uy;
        axisGrabPx(evalPivot(), vp, x1, y1, ux, uy);
        int xb = x1 + cast(int)(mag * ux);
        int yb = y1 + cast(int)(mag * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  x1, y1, xb, yb, 12));
        settle();
        if (undoCount() == wantCount && publishedS(0) > 1.0 + 1e-3) return;
    }
    assert(false, "scale +X handle gesture did not record / grow SX after retries");
}

// --- Rotate principal-axis ring gesture (replica of test_rotate_drag_parity) -
void localFrame(Vec3 normal, out Vec3 right, out Vec3 up) {
    Vec3 fwd = normalize(normal);
    Vec3 tmp = fabs(fwd.x) < 0.9f ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
    right = normalize(cross(fwd, tmp));
    up    = cross(right, fwd);
}
float arcStartAngle(Vec3 n, Vec3 camFwd, Vec3 right, Vec3 up) {
    Vec3 dir = cross(n, camFwd);
    float len = sqrt(dot(dir, dir));
    if (len <= 1e-4f) return 0.0f;
    dir = dir / len;
    Vec3 mid = cross(n, dir);
    if (dot(mid, camFwd) < 0.0f) dir = dir * (-1.0f);
    return atan2(dot(dir, up), dot(dir, right));
}
double principalRingGesture(int axis, Vec3 center, long wantCount,
                            float arcDelta = 0.55f) {
    Vec3 axisVec = axis == 0 ? Vec3(1,0,0)
                 : axis == 1 ? Vec3(0,1,0)
                 :             Vec3(0,0,1);
    double preR = publishedR(axis);
    foreach (attempt; 0 .. 16) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        float radius = gizmoSize(center, vp);
        Vec3 right, up;
        localFrame(axisVec, right, up);
        Vec3 camFwd = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
        float startAngle = arcStartAngle(axisVec, camFwd, right, up);
        float pull = arcDelta + attempt * 0.08f;
        float a0 = startAngle + cast(float)(PI / 2.0);
        float a1 = a0 + pull;
        Vec3 w0 = center + right * (cos(a0) * radius) + up * (sin(a0) * radius);
        Vec3 w1 = center + right * (cos(a1) * radius) + up * (sin(a1) * radius);
        float x0f, y0f, x1f, y1f;
        if (!projectToWindow(w0, vp, x0f, y0f)) continue;
        if (!projectToWindow(w1, vp, x1f, y1f)) continue;
        string lg = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  cast(int)x0f, cast(int)y0f,
                                  cast(int)x1f, cast(int)y1f, 24);
        playAndWait(lg);
        settle();
        if (undoCount() == wantCount)
            return publishedR(axis) - preR;
    }
    assert(false, "principal ring gesture did not record after retries");
    return 0;
}

// ---------------------------------------------------------------------------
// MOVE — two +X arrow gestures, then in-session Ctrl+Z. Geometry steps back to
// post-gesture-1 (PASSES); the published TX should read field1, not 0 (FAILS).
// ---------------------------------------------------------------------------
unittest {
    setupSingleBankScene("T");
    long floor = undoCount();

    moveGestureOnHandle(floor + 1);
    assert(undoCount() == floor + 1, "Move gesture 1 records one in-session entry");
    double field1 = publishedT(0);
    assert(fabs(field1) > 1e-2, "Move gesture 1 produced a nonzero TX; got "
        ~ field1.to!string);
    auto afterG1 = dumpVerts();

    moveGestureOnHandle(floor + 2);
    assert(undoCount() == floor + 2, "Move gesture 2 records a second entry");
    double field2 = publishedT(0);
    assert(fabs(field2) > fabs(field1) + 1e-2,
        "Move gesture 2 accumulates the run total past gesture 1; field1="
        ~ field1.to!string ~ " field2=" ~ field2.to!string);

    // In-session Ctrl+Z pops gesture 2.
    playAndWait(ctrlZ(50.0));
    settle();

    // GEOMETRY part — PASSES today.
    float backDiff = maxVertDiff(dumpVerts(), afterG1);
    assert(backDiff < 2e-2,
        "[Move] Ctrl+Z reverts geometry to post-gesture-1: maxVertDiff="
        ~ backDiff.to!string);

    // FIELD part — FAILS today (resync zeroes the field after the revert hook
    // restored it; published TX reads ~0 instead of field1).
    double fieldAfterUndo = publishedT(0);
    // Tolerance is a fraction of the gesture-1 magnitude so a reset-to-0 cannot
    // sneak under an absolute bound when TX is small.
    assert(fabs(fieldAfterUndo - field1) < 0.2 * fabs(field1),
        "[Move] after in-session Ctrl+Z the published TX must equal the run total "
        ~ "of the reverted-to step (field1), NOT identity. field1="
        ~ field1.to!string ~ " got " ~ fieldAfterUndo.to!string);

    cmd("tool.set xfrm.transform off");
    drainHistory();
}

// ---------------------------------------------------------------------------
// ROTATE — two Y ring gestures, then in-session Ctrl+Z. Geometry steps back to
// post-gesture-1 (PASSES); the published RY should read field1, not 0 (FAILS).
// ---------------------------------------------------------------------------
unittest {
    setupSingleBankScene("R");
    long floor = undoCount();

    principalRingGesture(1, autoPivot, floor + 1);
    assert(undoCount() == floor + 1, "Rotate gesture 1 records one in-session entry");
    double field1 = publishedR(1);
    assert(fabs(field1) > 5.0, "Rotate gesture 1 produced a meaningful RY; got "
        ~ field1.to!string);
    auto afterG1 = dumpVerts();

    principalRingGesture(1, autoPivot, floor + 2);
    assert(undoCount() == floor + 2, "Rotate gesture 2 records a second entry");
    double field2 = publishedR(1);
    assert(fabs(field2) > fabs(field1) + 5.0,
        "Rotate gesture 2 accumulates the run total past gesture 1; field1="
        ~ field1.to!string ~ " field2=" ~ field2.to!string);

    playAndWait(ctrlZ(50.0));
    settle();

    // GEOMETRY part — PASSES today.
    float backDiff = maxVertDiff(dumpVerts(), afterG1);
    assert(backDiff < 2e-2,
        "[Rotate] Ctrl+Z reverts geometry to post-gesture-1: maxVertDiff="
        ~ backDiff.to!string);

    // FIELD part — FAILS today (published RY reads ~0 instead of field1).
    double fieldAfterUndo = publishedR(1);

    assert(fabs(fieldAfterUndo - field1) < 2.0,
        "[Rotate] after in-session Ctrl+Z the published RY must equal the run total "
        ~ "of the reverted-to step (field1), NOT identity. field1="
        ~ field1.to!string ~ " got " ~ fieldAfterUndo.to!string);

    cmd("tool.set xfrm.transform off");
    drainHistory();
}

// ---------------------------------------------------------------------------
// SCALE — two +X handle gestures, then in-session Ctrl+Z. Geometry steps back to
// post-gesture-1 (PASSES); the published SX should read field1, not 1.0 (FAILS).
// ---------------------------------------------------------------------------
unittest {
    setupSingleBankScene("S");
    long floor = undoCount();

    scaleGestureOnHandle(floor + 1);
    assert(undoCount() == floor + 1, "Scale gesture 1 records one in-session entry");
    double field1 = publishedS(0);
    assert(field1 > 1.0 + 1e-3, "Scale gesture 1 produced SX > 1; got "
        ~ field1.to!string);
    auto afterG1 = dumpVerts();

    scaleGestureOnHandle(floor + 2);
    assert(undoCount() == floor + 2, "Scale gesture 2 records a second entry");
    double field2 = publishedS(0);
    assert(field2 > field1 + 1e-3,
        "Scale gesture 2 accumulates the run total past gesture 1; field1="
        ~ field1.to!string ~ " field2=" ~ field2.to!string);

    playAndWait(ctrlZ(50.0));
    settle();

    // GEOMETRY part — PASSES today.
    float backDiff = maxVertDiff(dumpVerts(), afterG1);
    assert(backDiff < 2e-2,
        "[Scale] Ctrl+Z reverts geometry to post-gesture-1: maxVertDiff="
        ~ backDiff.to!string);

    // FIELD part — FAILS today (published SX reads ~1.0 instead of field1).
    double fieldAfterUndo = publishedS(0);

    assert(fabs(fieldAfterUndo - field1) < 5e-2,
        "[Scale] after in-session Ctrl+Z the published SX must equal the run total "
        ~ "of the reverted-to step (field1), NOT identity (1.0). field1="
        ~ field1.to!string ~ " got " ~ fieldAfterUndo.to!string);

    cmd("tool.set xfrm.transform off");
    drainHistory();
}
