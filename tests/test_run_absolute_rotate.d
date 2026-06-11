// P-F Phase 3b — Rotate run-absolute panel value (single-field mechanism (c)),
// SAME-AXIS-ONLY + explicit re-bake transitions.
//
// Rotations do NOT commute, so headlessRotate is run-absolute ONLY across
// repeated SAME-AXIS principal gestures; a CROSS-axis gesture or a gesture after
// a view-ring forces a re-bake (graceful geometry-carried fallback — no
// fixed-order-Euler corruption). The cases:
//
//   (a) BARE-WRITE ABSOLUTE contract (mirrors test_reevaluate rotate value-edit):
//       an idle `tool.attr rotate RZ 90` write lands on headlessRotate.z = 90
//       absolutely, snapshot identity, composeFor reads the absolute → base
//       rotated 90; a SECOND write is ABSOLUTE (never additive at idle). STAYS
//       GREEN through every phase.
//
//   (b) SAME-AXIS RUN-ABSOLUTE accumulation (the Phase-3b FLIP / THE gate): two
//       same-axis Z-ring gestures (+turn, mouse-up, +turn again) -> the published
//       RZ (/api/toolpipe/eval transform.rotate[2]) ACCUMULATES the run total
//       (g1+g2 ≈ 135), NOT just gesture-2's angle (the un-fixed overwrite drain
//       would publish only g2). Geometry = base rotated by the run total (NOT g2,
//       NOT g1). This test MUST fail on the un-fixed overwrite drain.
//
//   (c) CROSS-AXIS RE-BAKE: a Z gesture then an X gesture -> geometry = R_X applied
//       on the R_Z-rotated mesh (SEQUENTIAL; the held Z is PRESERVED in the
//       re-baked baseline, not lost, not doubled). The published field after the
//       cross-axis gesture is the NEW axis only (RX != 0, RZ == 0 — geometry
//       carries the Z).
//
//   (d) IN-SESSION Ctrl+Z after same-axis g2 steps the geometry back to post-g1
//       (the per-gesture headlessRotate undo hook drives the reverted geometry);
//       redo restores it.
//
//   (e) CROSS-BANK GPU: a Rotate commit then a Move drag -> the Move geometry is
//       correct (no double-apply of the held rotation), and a same-axis
//       Rotate-after-Rotate GPU path is not double-applied (geometry == run total).
//
//   (f) RELOCATE -> RZ resets to 0 (G8 relocate->0, via resetRun()).
//
// Discipline: NO selection drain after reset; hermetic baseline via reset +
// history.clear (never drainHistory after /api/reset, which is undoable); gizmo
// gestures via drag_helpers.buildDragLog + /api/play-events with the mandatory
// ~120ms settle; vec3 attrs double-quoted; published values read off
// /api/toolpipe/eval (never the raw panel struct); geometry off /api/model with
// count-keyed settle; ring-grab retry on the undo count (the known ring-grab
// flake — a missed grab records nothing).

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
string ctrlShiftZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":65,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":65,"repeat":0}` ~ "\n",
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
double[3] vert(int idx) {
    auto v = getJson("/api/model")["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}
bool vertNear(double[3] a, double[3] b, double tol = 1.5e-2) {
    return fabs(a[0]-b[0]) < tol && fabs(a[1]-b[1]) < tol && fabs(a[2]-b[2]) < tol;
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

// Signed geometric Y-rotation angle (deg) that maps the XZ projection of
// (pre - center) onto (post - center), accumulated over `verts` (the engine's
// Rodrigues convention). A real, field-independent measure of how far the mesh
// actually rotated about +Y at `center` — used to distinguish run-absolute
// accumulation (monotonic) from an overwrite (replaces, can rotate BACK).
double geomYAngleDeg(Vec3[] pre, Vec3[] post_, int[] verts, Vec3 center) {
    double accC = 0, accS = 0;
    foreach (vi; verts) {
        double ax = pre[vi].x - center.x, az = pre[vi].z - center.z;
        double bx = post_[vi].x - center.x, bz = post_[vi].z - center.z;
        if (ax*ax + az*az < 1e-6) continue;
        accC += (ax*bx + az*bz);
        accS += (az*bx - ax*bz);
    }
    return atan2(accS, accC) * 180.0 / PI;
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
        foreach (_; 0 .. 200) {
            if (replayIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        // Do NOT drainHistory() after /api/reset: SceneReset is itself undoable
        // and its revert() restores the PRE-reset (prior test's dirty) mesh, so
        // a drain-after-reset can leave a standing entry that reverts geometry
        // to a stale state (the -j1 cross-test-bleed flake). history.clear is a
        // SideEffect command: it wipes BOTH stacks WITHOUT touching the mesh, so
        // the cube stays pristine AND undo=0.
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
// The principal X/Y/Z semicircle arcs reorient toward the camera every frame
// (RotateHandler.applyStart, handler.d), so a reliable synthetic click pixel
// requires replicating that arc geometry test-side.
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
// `center`, with a tangential pull of `arcDelta` radians. Verify-and-retry on the
// UNDO COUNT (a missed grab records nothing -> retry; a hit records one in-session
// entry -> stop). The pull grows on later retries so a borderline-deadzone first
// try still sweeps. NO mid-run undo (a rollback desyncs the run-absolute field from
// geometry). Returns the published `axis` angle delta this gesture produced
// (post - pre); `outLog` optionally receives the exact drag log that recorded.
double principalRingGesture(int axis, Vec3 center, long wantCount,
                            float arcDelta = 0.55f, string* outLog = null) {
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
        if (undoCount() == wantCount) {
            if (outLog !is null) *outLog = lg;
            return publishedR(axis) - preR;
        }
    }
    assert(false, "principal ring gesture (axis " ~ axis.to!string
        ~ ") did not record after retries (ring-grab flake)");
    return 0;
}

// Setup: cube, locked camera, top-face selected (ACEN.Auto pivot (0,0.5,0)).
// Defaults to the xfrm.transform preset with ONLY the R flag enabled, so a ring
// grab cannot land on a move arrow / scale box AND the view-ring does not steal
// the principal-arc click (mirrors test_rotate_drag_parity's setup, the proven
// principal-grab path). `crossBank == true` keeps T/R/S all on for the cross-bank
// GPU case.
int[] setupRotateScene(bool crossBank = false) {
    establishCubeBaseline();
    lockCamera();
    int topFace = findTopFace();
    auto sel = postJson("/api/select",
        `{"mode":"polygons","indices":[` ~ topFace.to!string ~ `]}`);
    assert(sel["status"].str == "ok", "select failed: " ~ sel.toString);
    settle();
    cmd("tool.set xfrm.transform on");
    if (crossBank) {
        cmd("tool.attr xfrm.transform T true");
        cmd("tool.attr xfrm.transform R true");
        cmd("tool.attr xfrm.transform S true");
    } else {
        cmd("tool.attr xfrm.transform T false");
        cmd("tool.attr xfrm.transform S false");
        cmd("tool.attr xfrm.transform R true");
    }
    return topFaceVerts(topFace);
}

Vec3 autoPivot = Vec3(0, 0.5f, 0);   // top-face centroid, stable under Y/X/Z

// Numeric reference: a fresh top-face-selected scene, R-only xfrm.transform, then
// the supplied `tool.attr RX/RY/RZ ...` + (optional) doApply steps, returning the
// resulting vertex dump. Used to cross-check the run-absolute / sequential
// geometry the drag produced. Tears the tool down + drains history.
Vec3[] numericRotateRef(string[] steps) {
    establishCubeBaseline();
    lockCamera();
    int tf = findTopFace();
    postJson("/api/select",
        `{"mode":"polygons","indices":[` ~ tf.to!string ~ `]}`);
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
                           string axisAttr2, double a2) {
    establishCubeBaseline();
    lockCamera();
    int tf = findTopFace();
    void selTop() {
        postJson("/api/select",
            `{"mode":"polygons","indices":[` ~ tf.to!string ~ `]}`);
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

// ---------------------------------------------------------------------------
// (a) BARE-WRITE ABSOLUTE — STAYS GREEN through every P-F phase.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    lockCamera();
    // NO selection ⇒ whole-mesh moving set, pivot at the origin.
    cmd("tool.set TransformRotate");

    long undoBefore = undoCount();
    cmd("tool.beginSession");
    auto baseV6 = vert(6);

    cmd(`tool.attr TransformRotate RZ 90`);
    settle();
    auto afterRz90 = vert(6);
    // A +90° rotation about Z (origin pivot) maps v6 (0.5,0.5,0.5) -> (-0.5,0.5,0.5).
    assert(fabs(afterRz90[0] - (-0.5)) < 2e-2 && fabs(afterRz90[1] - 0.5) < 2e-2,
        "bare RZ 90 rotates v6 to (-0.5,0.5,*): got ("
        ~ afterRz90[0].to!string ~ "," ~ afterRz90[1].to!string ~ ")");
    assert(fabs(publishedR(2) - 90.0) < 1e-2,
        "bare RZ write publishes RZ=90 absolutely; got "
        ~ publishedR(2).to!string);

    // A SECOND write is ABSOLUTE at idle (RZ 45 -> 45, not 135).
    cmd(`tool.attr TransformRotate RZ 45`);
    settle();
    assert(fabs(publishedR(2) - 45.0) < 1e-2,
        "second bare RZ write is ABSOLUTE at idle (45, not 135); got "
        ~ publishedR(2).to!string);

    cmd("tool.set TransformRotate off");
    assert(undoCount() == undoBefore + 1,
        "live-session attr edits coalesce to ONE undo entry");
    postJson("/api/undo", "");
    settle();
    assert(vertNear(vert(6), baseV6),
        "one undo restores the original");
    cmd("tool.set TransformRotate off");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (b) SAME-AXIS RUN-ABSOLUTE accumulation — THE GATE (fails on the un-fixed
//     overwrite drain).
//
// Two same-axis Z-ring gestures: the published RZ accumulates the RUN TOTAL
// (g1+g2), and the geometry is the cube rotated by that run total. The un-fixed
// drain (headlessRotate.z = deg) would publish only gesture-2's angle and the
// geometry would be base rotated by g2 alone.
// ---------------------------------------------------------------------------
unittest {
    int[] topVerts = setupRotateScene();   // R-only, ACEN.Auto, pivot (0,0.5,0)
    long floor = undoCount();
    auto pristine = dumpVerts();

    // Gesture 1 (same axis) — record ryG1.
    principalRingGesture(1, autoPivot, floor + 1, 0.55f);   // Y gesture 1
    assert(undoCount() == floor + 1, "Y gesture 1 records ONE in-session entry");
    double ryG1 = publishedR(1);
    assert(fabs(ryG1) > 15.0,
        "Y gesture 1 swept a meaningful published RY; got " ~ ryG1.to!string);
    auto afterG1 = dumpVerts();

    // Gesture 2 (SAME axis) — a fresh ring grab on the rotated gizmo.
    principalRingGesture(1, autoPivot, floor + 2, 0.55f);   // Y gesture 2 SAME axis
    assert(undoCount() == floor + 2,
        "Y gesture 2 records a SECOND in-session entry in the same run");
    double ryG2 = publishedR(1);
    auto afterG2 = dumpVerts();

    // d2geom = gesture 2's GEOMETRIC increment (afterG1 -> afterG2), field-
    // independent. The two same-axis gizmo gestures pull the SAME arc direction, so
    // gesture 2 ADDS a same-sign rotation ON TOP of gesture 1.
    //
    // THE BLOCKER-1 GATE: with run-absolute ACCUMULATION the field is FROZEN-baseline
    // + ADD, so gesture 2 rotates the cube FURTHER (d2geom is a real same-sign
    // advance, geomG2 ≈ 2·geomG1) and the published RY climbs to the run total
    // (ryG2 ≈ ryG1 + d2geom ≈ 2·ryG1). The un-fixed OVERWRITE drain
    // (`headlessRotate.<ax> = deg`) REPLACES the frozen-baseline field with gesture
    // 2's own angle ALONE (≈ gesture 1's, since both pull the same arc) ⇒ the
    // geometry SNAPS BACK to ≈ gesture-1's pose (d2geom ≈ 0) and ryG2 ≈ ryG1, NOT
    // the run total. So: (1) gesture 2 advanced the geometry (d2geom same-sign,
    // large), and (2) ryG2 == ryG1 + d2geom — BOTH FAIL on the overwrite drain
    // (d2geom ≈ 0, ryG2 ≈ ryG1) and PASS on the snapshot-ADD drain.
    double d2geom = geomYAngleDeg(afterG1, afterG2, topVerts, autoPivot);
    assert(ryG1 * d2geom > 0 && fabs(d2geom) > 10.0,
        "P-F Phase 3b BLOCKER-1: same-axis gesture 2 ADVANCES the geometry further "
        ~ "in gesture 1's direction (frozen-baseline ADD). The un-fixed OVERWRITE "
        ~ "drain replaces the field with gesture 2's angle alone, snapping the "
        ~ "geometry back to ≈ gesture 1's pose (d2geom ≈ 0). ryG1=" ~ ryG1.to!string
        ~ " d2geom=" ~ d2geom.to!string);
    assert(fabs(ryG2 - (ryG1 + d2geom)) < 3.0,
        "P-F Phase 3b BLOCKER-1: run total published after gesture 2 == ryG1 + "
        ~ "gesture-2's increment (the ACCUMULATED run total). ryG1=" ~ ryG1.to!string
        ~ " d2geom=" ~ d2geom.to!string ~ " ryG2=" ~ ryG2.to!string);
    // The run total clearly climbed past a single gesture (≈ 2·ryG1) — the
    // overwrite value (≈ ryG1) does not.
    assert(ryG1 * ryG2 > 0 && fabs(ryG2) > fabs(ryG1) + 10.0,
        "run total climbed past gesture 1 alone (accumulated, not overwritten): "
        ~ "ryG1=" ~ ryG1.to!string ~ " ryG2=" ~ ryG2.to!string);

    // The published field is in LOCKSTEP with the geometry: geometry after g1+g2 ==
    // numeric rotate by ryG2 (no double, no loss) — pins frozen-baseline + full-field.
    auto numRef = numericRotateRef(
        [format(`tool.attr xfrm.transform RY %.6f`, ryG2)]);
    float diff = maxVertDiff(afterG2, numRef);
    assert(diff < 2e-2,
        "geometry after same-axis g1+g2 == numeric rotate by the run-total RY "
        ~ "(no double-apply, no loss): max per-vert diff = " ~ diff.to!string);
}

// ---------------------------------------------------------------------------
// (c) CROSS-AXIS CUMULATIVE EULER — Y gesture then X gesture.
//
// CUMULATIVE-EULER (Phase 1): the GLOBAL path no longer re-bakes cross-axis. After
// RY-then-RX, headlessRotate holds the FULL cumulative ZYX Euler of the gesture-
// order orientation (R_X·R_Y), so BOTH RY (retained, from the prior gesture's
// decomposition) AND RX are nonzero in the published field. The GEOMETRY is
// UNCHANGED from the old re-bake result — R_X applied on the R_Y-rotated mesh —
// because composeFor rebuilds Rz·Ry·Rx from the cumulative Euler about the frozen
// run basis/pivot, and the decompose↔recompose roundtrip reproduces the same
// orientation. This case validates geometry-neutrality of the cumulative model.
// ---------------------------------------------------------------------------
unittest {
    setupRotateScene();
    long floor = undoCount();

    principalRingGesture(1, autoPivot, floor + 1);   // Y gesture
    assert(undoCount() == floor + 1, "Y gesture records one in-session entry");
    double ryHeld = publishedR(1);
    assert(fabs(ryHeld) > 5.0, "Y gesture left a nonzero RY; got " ~ ryHeld.to!string);
    auto afterY = dumpVerts();

    principalRingGesture(0, autoPivot, floor + 2);   // X gesture CROSS axis
    assert(undoCount() == floor + 2,
        "X gesture records a second in-session entry (run continues)");
    double rxAfter = publishedR(0);
    double ryAfter = publishedR(1);
    double rzAfter = publishedR(2);
    auto afterYX = dumpVerts();

    // FIELD (flipped for cumulative Euler): RX is the new axis angle and RY is
    // RETAINED — both are part of the cumulative ZYX decomposition of R_X·R_Y (no
    // cross-axis re-bake, no field-zero on the global path). NOTE: under cumulative
    // ZYX the published RX/RY/RZ are the DECOMPOSED Euler of the gesture-order
    // orientation, NOT the raw per-gesture drag angles — so the geometry reference
    // below replays the FULL published Euler in ONE session (panel→geometry
    // roundtrip) rather than the raw-angle sequential bake.
    assert(fabs(rxAfter) > 5.0,
        "cross-axis: the published RX is the new axis angle; got " ~ rxAfter.to!string);
    assert(fabs(ryAfter) > 1.0,
        "cumulative-Euler: the held RY is RETAINED in the FIELD (part of the "
        ~ "cumulative ZYX decomposition, NOT re-baked away); published RY should be "
        ~ "nonzero, got " ~ ryAfter.to!string);

    // GEOMETRY-NEUTRALITY: the live cumulative geometry == the FULL published Euler
    // (RX,RY,RZ) replayed as one numeric ZYX session. composeFor rebuilds Rz·Ry·Rx
    // from the cumulative Euler about the frozen run basis/pivot, so feeding the
    // published panel value back through the numeric path reproduces the live drag
    // EXACTLY — the cumulative-Euler panel↔geometry contract. (The independent
    // gesture-order check vs the raw drag angles lives in
    // test_rotate_crossaxis_localbasis scene (1), which is 0-diff.)
    auto numRef = numericRotateRef([
        format(`tool.attr xfrm.transform RX %.6f`, rxAfter),
        format(`tool.attr xfrm.transform RY %.6f`, ryAfter),
        format(`tool.attr xfrm.transform RZ %.6f`, rzAfter),
    ]);

    float diff = maxVertDiff(afterYX, numRef);
    assert(diff < 3e-2,
        "cross-axis geometry == full published Euler replayed numerically "
        ~ "(cumulative Euler panel↔geometry roundtrip; geometry-neutral): "
        ~ "max per-vert diff = " ~ diff.to!string);
    // And it is NOT the same as the Y-only pose (the X gesture really advanced it).
    assert(maxVertDiff(afterYX, afterY) > 0.02,
        "the cross-axis X gesture advanced the geometry beyond the Y-only pose");
}

// ---------------------------------------------------------------------------
// (d) IN-SESSION Ctrl+Z after same-axis g2 steps the geometry back to post-g1.
// ---------------------------------------------------------------------------
unittest {
    setupRotateScene();
    long floor = undoCount();

    principalRingGesture(1, autoPivot, floor + 1);   // Y gesture 1
    assert(undoCount() == floor + 1, "Y gesture 1 records one entry");
    auto afterG1 = dumpVerts();

    principalRingGesture(1, autoPivot, floor + 2);   // Y gesture 2 SAME axis
    assert(undoCount() == floor + 2, "Y gesture 2 records a second entry");
    auto afterG2 = dumpVerts();

    // In-session Ctrl+Z pops gesture 2 -> GEOMETRY reverts to post-gesture-1 (the
    // run-absolute headlessRotate undo hook fed applyTRS the gesture-START field).
    playAndWait(ctrlZ(50.0));
    settle();
    float backDiff = maxVertDiff(dumpVerts(), afterG1);
    assert(backDiff < 2e-2,
        "in-session Ctrl+Z reverts geometry to post-gesture-1 (run-absolute field "
        ~ "hook drove applyTRS): max per-vert diff = " ~ backDiff.to!string);

    // Redo re-applies gesture 2 -> back to the run-end geometry.
    playAndWait(ctrlShiftZ(60.0));
    settle();
    float fwdDiff = maxVertDiff(dumpVerts(), afterG2);
    assert(fwdDiff < 2e-2,
        "redo restores the run-end (both-gestures) geometry: max per-vert diff = "
        ~ fwdDiff.to!string);

    cmd("tool.set xfrm.transform off");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (e) CROSS-BANK GPU: Rotate commit -> Move drag geometry correct, and a
//     same-axis Rotate-after-Rotate GPU path is not double-applied.
//
// On the bare Transform preset (T=R=S) a Z-ring gesture leaves a held run-
// absolute RZ. A subsequent Move +X arrow drag must move the (already-rotated)
// mesh by the move delta, NOT re-apply the held rotation (the Rotate own-bank
// fast-path drops out via runGpuBufferDirty; Move drops to CPU on a held rotate).
// ---------------------------------------------------------------------------
unittest {
    setupRotateScene(true);          // T=R=S, ACEN.Auto pivot (0,0.5,0)
    long floor = undoCount();

    principalRingGesture(1, autoPivot, floor + 1);   // Y gesture
    assert(undoCount() == floor + 1, "rotate gesture records one in-session entry");
    double ryHeld = publishedR(1);
    assert(fabs(ryHeld) > 5.0, "rotate gesture left a held RY; got " ~ ryHeld.to!string);
    auto afterRot = dumpVerts();

    // A MOVE +X arrow drag in the SAME wrapper session. The cross-bank GPU path:
    // held rotate non-identity -> Move drops to CPU, geometry correct.
    settle();
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    float size = gizmoSize(autoPivot, vp);
    float s0x, s0y, s1x, s1y;
    projectToWindow(Vec3(autoPivot.x + size/6.0f, autoPivot.y, autoPivot.z), vp, s0x, s0y);
    projectToWindow(Vec3(autoPivot.x + size,        autoPivot.y, autoPivot.z), vp, s1x, s1y);
    int xa = cast(int)(s0x + 0.7f * (s1x - s0x));
    int ya = cast(int)(s0y + 0.7f * (s1y - s0y));
    double dx = s1x - s0x, dy = s1y - s0y;
    double len = sqrt(dx*dx + dy*dy);
    double ux = dx / len, uy = dy / len;
    int xb = xa + cast(int)(55.0 * ux);
    int yb = ya + cast(int)(55.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xa, ya, xb, yb, 12));
    settle();

    // The held RY SURVIVES the Move gesture (cross-bank hold through one fold).
    double ryAfterMove = publishedR(1);
    assert(fabs(ryAfterMove - ryHeld) < 1.0,
        "a Move gesture must NOT clear the held Rotate run-absolute RY (cross-bank "
        ~ "hold): held=" ~ ryHeld.to!string ~ " after Move=" ~ ryAfterMove.to!string);

    // CROSS-BANK GPU geometry assert: every vertex moved by the SAME world-space
    // delta as the move (a rigid translation of the already-rotated mesh), NOT a
    // re-applied rotation. Check the displacement is uniform across the top-face
    // verts (a re-applied rotation would produce per-vertex-varying deltas).
    auto afterMove = dumpVerts();
    int topFace = findTopFace();
    auto tv = topFaceVerts(topFace);
    Vec3 d0 = afterMove[tv[0]] - afterRot[tv[0]];
    foreach (vi; tv[1 .. $]) {
        Vec3 di = afterMove[vi] - afterRot[vi];
        Vec3 e = di - d0;
        assert(sqrt(dot(e, e)) < 2e-2,
            "cross-bank GPU: the Move applied a UNIFORM rigid translation (no "
            ~ "re-applied rotation); vert delta diverged by "
            ~ sqrt(dot(e, e)).to!string);
    }
    assert(sqrt(dot(d0, d0)) > 1e-2, "the Move actually displaced the mesh");

    cmd("tool.set xfrm.transform off");
    drainHistory();

    // --- same-axis Rotate-after-Rotate GPU not double-applied --------------
    // (re-uses (b)'s numeric cross-check shape but exercises the GPU path under
    // the T=R=S preset: the second same-axis gesture's own-bank fast-path drops to
    // CPU via runGpuBufferDirty, so geometry == the run total.)
    setupRotateScene(true);
    long floor2 = undoCount();
    principalRingGesture(1, autoPivot, floor2 + 1);
    assert(undoCount() == floor2 + 1, "g1 records one entry");
    principalRingGesture(1, autoPivot, floor2 + 2);
    assert(undoCount() == floor2 + 2, "g2 records a second entry");
    double ryTotal = publishedR(1);
    auto afterBoth = dumpVerts();

    auto numRef = numericRotateRef(
        [format(`tool.attr xfrm.transform RY %.6f`, ryTotal)]);

    float diff = maxVertDiff(afterBoth, numRef);
    assert(diff < 2e-2,
        "same-axis Rotate-after-Rotate GPU path == numeric run total (NOT double-"
        ~ "applied): max per-vert diff = " ~ diff.to!string);
}

// ---------------------------------------------------------------------------
// (f) RELOCATE -> RZ resets to 0 (G8).
// ---------------------------------------------------------------------------
unittest {
    setupRotateScene();              // R-only, ACEN.Auto.
    // Exercise the geometry-run boundary via a selection change (a hard boundary
    // that calls resetRun, like a relocate). After a Y gesture (RY != 0), changing
    // the selection resets the run-absolute RY to 0 while leaving the committed
    // geometry put (G8 relocate->0).
    long floor = undoCount();
    principalRingGesture(1, autoPivot, floor + 1);
    assert(undoCount() == floor + 1, "the gesture records one in-session entry");
    assert(fabs(publishedR(1)) > 5.0, "the gesture left a run-absolute RY != 0");
    auto afterGesture = dumpVerts();

    // Selection change to a DIFFERENT face = a hard geometry-run boundary
    // (resetRun). The committed gesture geometry is untouched; the run-absolute
    // field resets to identity. (Re-selecting the SAME face would be a no-op and
    // would NOT fire the boundary.)
    int topFace = findTopFace();
    int otherFace = -1;
    foreach (fi; 0 .. cast(int)getJson("/api/model")["faces"].array.length) {
        if (fi != topFace) { otherFace = fi; break; }
    }
    assert(otherFace >= 0, "no second face to select");
    postJson("/api/select",
        `{"mode":"polygons","indices":[` ~ otherFace.to!string ~ `]}`);
    settle();

    assert(fabs(publishedR(1)) < 1e-2,
        "the run boundary resets the run-absolute RY to 0 (G8 relocate->0); got "
        ~ publishedR(1).to!string);
    float keepDiff = maxVertDiff(dumpVerts(), afterGesture);
    assert(keepDiff < 2e-2,
        "the run boundary does not move the committed gesture geometry: max "
        ~ "per-vert diff = " ~ keepDiff.to!string);

    cmd("tool.set xfrm.transform off");
    drainHistory();
}
