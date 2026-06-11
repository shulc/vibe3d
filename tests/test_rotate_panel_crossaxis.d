// Rotate handle->panel CROSS-AXIS must PRESERVE the baked axis.
//
// Scenario (R-only transform, top face selected):
//   1. A gizmo ring gesture about X bakes a rotation rxHeld (published RX != 0).
//   2. A gizmo ring gesture about Y is a CROSS axis. Under the cumulative-Euler
//      model (Phase 1) the run-absolute field holds the FULL cumulative ZYX Euler
//      of R_Y(b)·R_X(a) — RX is RETAINED in the field (no cross-axis re-bake on the
//      global path). At this point the GEOMETRY carries BOTH X and Y.
//   3. WHILE the wrapper session is still open (the gizmo mouse-up does NOT commit
//      / drop the tool), a PANEL edit writes RY to a NEW absolute angle via
//      `tool.attr xfrm.transform RY <newAngle>`. composeFor recomposes Rz·Ry·Rx
//      with the new RY component against the FROZEN run baseline/basis/pivot.
//
// EXPECTED: the panel RY edit PRESERVES the baked X. With X-then-Y the cumulative
// ZYX decomposition is exactly (a, b, 0), so the panel RY edit yields the geometry
// "bake RX(rxHeld) then apply RY(newAngle) on top" — equal to
// numericRotateSeqRef("RX", rxHeld, "RY", newAngle) — and NOT the RY-from-cube pose
// (X lost). The two references must differ (otherwise the test is vacuous), AND the
// live geometry must match the SEQUENTIAL one.
//
// Discipline (from the rotate run-absolute template): NO selection drain after
// /api/reset (history.clear instead); ~120ms settle after play-events; vec3 attrs
// double-quoted; published values read off /api/toolpipe/eval, geometry off
// /api/model; ring-grab retry on the undo count.

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
int[] topFaceVerts(int topFace) {
    int[] o;
    foreach (vi; getJson("/api/model")["faces"].array[topFace].array)
        o ~= cast(int)vi.integer;
    return o;
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
        postJson("/api/script", "tool.set rotate off");
        postJson("/api/script", "tool.set TransformRotate off");
        postJson("/api/script", "tool.set Transform off");
        postJson("/api/script", "tool.set xfrm.transform off");
        foreach (_; 0 .. 200) {
            if (replayIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        // Do NOT drainHistory() after /api/reset: SceneReset is itself undoable.
        // history.clear wipes BOTH stacks WITHOUT touching the mesh.
        postJson("/api/reset", "");                 // cube
        postJson("/api/command", "history.clear");  // wipe stacks, keep the cube
        if (cubePristine() && undoCount() == 0) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");
    assert(cubePristine(), "could not establish pristine cube baseline");
}

// Published run-absolute rotate component (deg) off /api/toolpipe/eval.
double publishedR(int axis) {
    auto j = getJson("/api/toolpipe/eval");
    auto t = "transform" in j.object;
    assert(t !is null, "eval has no transform block (no transform tool active?): "
        ~ j.toString);
    return (*t)["rotate"].array[axis].floating;
}

// --- principal-axis arc grab (replica of test_rotate_drag_parity.d) ---------
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

// Drive ONE principal-axis ring gesture about `axis` (0=X,1=Y,2=Z) at pivot
// `center`. Verify-and-retry on the UNDO COUNT. Returns the published `axis` angle
// delta this gesture produced (post - pre).
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
    assert(false, "principal ring gesture (axis " ~ axis.to!string
        ~ ") did not record after retries (ring-grab flake)");
    return 0;
}

// Select the top face, turn on R-only xfrm.transform. `localAcen` switches the
// action center to local (the drifting-basis guard).
int[] setupRotateScene(bool localAcen = false) {
    establishCubeBaseline();
    lockCamera();
    int topFace = findTopFace();
    auto sel = postJson("/api/select",
        `{"mode":"polygons","indices":[` ~ topFace.to!string ~ `]}`);
    assert(sel["status"].str == "ok", "select failed: " ~ sel.toString);
    settle();
    if (localAcen) cmd("actr.local"); else cmd("actr.auto");
    settle();
    cmd("tool.set xfrm.transform on");
    cmd("tool.attr xfrm.transform T false");
    cmd("tool.attr xfrm.transform S false");
    cmd("tool.attr xfrm.transform R true");
    return topFaceVerts(topFace);
}

Vec3 autoPivot = Vec3(0, 0.5f, 0);   // top-face centroid, stable under X/Y/Z

// Numeric reference: a fresh top-face-selected R-only session, then the supplied
// `tool.attr RX/RY/RZ ...` steps, returning the resulting vertex dump. Tears the
// tool down + drains history. `localAcen` mirrors the scene's action center so the
// reference applies about the SAME pivot/frame.
Vec3[] numericRotateRef(string[] steps, bool localAcen = false) {
    establishCubeBaseline();
    lockCamera();
    int tf = findTopFace();
    postJson("/api/select",
        `{"mode":"polygons","indices":[` ~ tf.to!string ~ `]}`);
    settle();
    if (localAcen) cmd("actr.local"); else cmd("actr.auto");
    settle();
    cmd("tool.set xfrm.transform on");
    cmd("tool.attr xfrm.transform T false");
    cmd("tool.attr xfrm.transform S false");
    cmd("tool.attr xfrm.transform R true");
    cmd("tool.beginSession");
    foreach (s; steps) cmd(s);
    settle();
    auto o = dumpVerts();
    cmd("tool.set xfrm.transform off");
    drainHistory();
    return o;
}

// Numeric reference for a SEQUENTIAL cross-axis cross-check: two SEPARATE tool
// sessions (the first baked + dropped, the second re-opened on the baked pose),
// faithfully mirroring the interactive cross-axis RE-BAKE (the first axis baked
// into geometry, the gizmo re-opened, the second axis composed on top). Returns
// the final vertex dump.
Vec3[] numericRotateSeqRef(string axisAttr1, double a1,
                           string axisAttr2, double a2, bool localAcen = false) {
    establishCubeBaseline();
    lockCamera();
    int tf = findTopFace();
    void selTop() {
        postJson("/api/select",
            `{"mode":"polygons","indices":[` ~ tf.to!string ~ `]}`);
        settle();
        if (localAcen) cmd("actr.local"); else cmd("actr.auto");
        settle();
    }
    void rOnly() {
        cmd("tool.set xfrm.transform on");
        cmd("tool.attr xfrm.transform T false");
        cmd("tool.attr xfrm.transform S false");
        cmd("tool.attr xfrm.transform R true");
    }
    // Session 1 — bake axis 1, then DROP the tool (commits the geometry).
    selTop();
    rOnly();
    cmd("tool.beginSession");
    cmd(format(`tool.attr xfrm.transform %s %.6f`, axisAttr1, a1));
    settle();
    cmd("tool.set xfrm.transform off");
    settle();
    // Session 2 — re-open on the baked pose, compose axis 2.
    selTop();
    rOnly();
    cmd("tool.beginSession");
    cmd(format(`tool.attr xfrm.transform %s %.6f`, axisAttr2, a2));
    settle();
    auto o = dumpVerts();
    cmd("tool.set xfrm.transform off");
    drainHistory();
    return o;
}

// Shared body for both acen modes. Drives X gesture, CROSS Y gesture, then a panel
// RY edit while the session stays open, and asserts the baked X is PRESERVED.
void runCrossAxisPanelCase(bool localAcen) {
    setupRotateScene(localAcen);
    long floor = undoCount();

    // Gesture 1 about X — bake rxHeld.
    principalRingGesture(0, autoPivot, floor + 1);
    assert(undoCount() == floor + 1, "X gesture records one in-session entry");
    double rxHeld = publishedR(0);
    assert(fabs(rxHeld) > 5.0,
        "X gesture left a meaningful published RX; got " ~ rxHeld.to!string);

    // Gesture 2 about Y — CROSS axis. CUMULATIVE-EULER (Phase 1): the field now
    // holds the FULL cumulative ZYX Euler of R_Y(b)·R_X(a), so the held X is
    // RETAINED in the FIELD (no cross-axis re-bake on the global path). Both modes
    // here select a SINGLE top face, which resolves to the GLOBAL single-frame path
    // (a single selection is not multi-cluster), so acen=local does NOT engage the
    // per-cluster legacy re-bake — the basis is the world-aligned face frame and the
    // cumulative model applies. (The per-cluster legacy re-bake is exercised by the
    // multi-cluster fixtures, e.g. test_rotate_crossaxis_localbasis scene (2).)
    principalRingGesture(1, autoPivot, floor + 2);
    assert(undoCount() == floor + 2,
        "Y cross-axis gesture records a second in-session entry");
    double ryHeld = publishedR(1);
    assert(fabs(ryHeld) > 5.0,
        "Y gesture left a published RY; got " ~ ryHeld.to!string);
    // The held X is RETAINED in the FIELD (cumulative-Euler, no cross-axis re-bake).
    assert(fabs(publishedR(0)) > 1.0,
        (localAcen ? "[acen=local] " : "[acen=auto] ")
        ~ "cumulative-Euler RETAINS the held RX in the FIELD (full ZYX "
        ~ "decomposition, no cross-axis re-bake); published RX should be nonzero, "
        ~ "got " ~ publishedR(0).to!string);

    // PANEL edit of RY to a NEW absolute angle WHILE the session is open.
    double newAngle = ryHeld + 25.0;
    cmd(format(`tool.attr xfrm.transform RY %.6f`, newAngle));
    settle();
    auto liveGeom = dumpVerts();

    // Expected (correct) pose: bake RX(rxHeld) then apply RY(newAngle) on top.
    auto seqRef = numericRotateSeqRef("RX", rxHeld, "RY", newAngle, localAcen);
    // Buggy pose: RY(newAngle) from the bare cube (X lost).
    auto cubeRef = numericRotateRef(
        [format(`tool.attr xfrm.transform RY %.6f`, newAngle)], localAcen);

    // The two references MUST differ (X is a real rotation), else the test is
    // vacuous. With rxHeld > 5 deg they are clearly distinct.
    float refDiff = maxVertDiff(seqRef, cubeRef);
    assert(refDiff > 0.05,
        "sanity: the sequential (X preserved) and cube-only (X lost) references "
        ~ "must DIFFER (rxHeld=" ~ rxHeld.to!string ~ "); got refDiff="
        ~ refDiff.to!string);

    float diffSeq  = maxVertDiff(liveGeom, seqRef);
    float diffCube = maxVertDiff(liveGeom, cubeRef);

    // THE PINNED BUG: the panel RY edit must PRESERVE the baked X — the live
    // geometry must match the SEQUENTIAL reference, NOT the cube-only one. On the
    // current build the panel edit re-applies from the session-start cube and the
    // live geometry matches cubeRef instead (X lost) -> this assert FAILS.
    assert(diffSeq < 3e-2,
        (localAcen ? "[acen=local] " : "[acen=auto] ")
        ~ "panel RY edit must PRESERVE the baked X (live geometry == bake-RX-then-"
        ~ "RY-on-top): maxVertDiff(live, seqRef)=" ~ diffSeq.to!string
        ~ " (vs maxVertDiff(live, cubeRef)=" ~ diffCube.to!string
        ~ ", refDiff=" ~ refDiff.to!string ~ ", rxHeld=" ~ rxHeld.to!string
        ~ ", newAngle=" ~ newAngle.to!string ~ ")");
    // And it must NOT be the X-lost cube pose.
    assert(diffCube > 0.05,
        (localAcen ? "[acen=local] " : "[acen=auto] ")
        ~ "panel RY edit must NOT collapse to RY-from-cube (X lost): "
        ~ "maxVertDiff(live, cubeRef)=" ~ diffCube.to!string);

    cmd("tool.set xfrm.transform off");
    drainHistory();
}

// ---------------------------------------------------------------------------
// BUG A — ACEN.Auto: cross-axis re-bake then panel RY edit must keep the baked X.
// EXPECTED TO FAIL on the current build.
// ---------------------------------------------------------------------------
unittest {
    runCrossAxisPanelCase(false);
}

// ---------------------------------------------------------------------------
// BUG A — ACEN.Local: same scenario under a per-face local action center frame
// (the drifting-basis guard). EXPECTED TO FAIL on the current build.
// ---------------------------------------------------------------------------
unittest {
    runCrossAxisPanelCase(true);
}
