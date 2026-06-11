// Phase 2.0 — SAFETY NET + MEASUREMENT for the upcoming cross-axis-rotate change.
//
// An upcoming Phase 2 will REMOVE the cross-axis rotate RE-BAKE and instead hold
// the FULL Euler in `headlessRotate`, applied from a FROZEN run baseline. This
// test pins the CURRENT (re-bake) behaviour as a golden so the change's geometry
// delta is visible, and quantifies whether the divergence is real.
//
// CURRENT behaviour (verified in source, NOT assumed):
//   * Live rotate fold = applyFold->composeFor (source/tools/xfrm_transform.d
//     ~3465) builds M = S·(Rz·Ry·Rx)·T (ZYX order, documented ~3454).
//   * Cross-axis gizmo gestures RE-BAKE: `rotateRunNeedsRebake` (~1432) bakes the
//     prior axis into `dragBaseline` and ZEROES the field, so composeFor only ever
//     sees a SINGLE live principal axis per gizmo run.
//   * The PER-CLUSTER rotate basis (ap.right/up/fwd[cid], composeFor call at
//     ~3614) is re-derived per frame. Only the GLOBAL TRANSLATE frame
//     (runFrameR/U/F, ~3593) is frozen — R/S keep the per-frame basis.
//
// Two measured scenes:
//   (1) acen=auto, single top face (WORLD-aligned basis): cross-axis X-then-Y
//       gizmo gesture. Asserts live == numericRotateSeqRef (Ry·Rx == sequential
//       bake-then-recompose). Pins "auto basis is unaffected" — should pass NOW
//       AND after Phase 2.
//   (2) acen=local, MULTI-CLUSTER segments-2 cube (drifting per-cluster basis):
//       cross-axis X-then-Y gizmo gesture. Captures the resulting vertex dump as a
//       hardcoded GOLDEN (CURRENT re-bake behaviour, captured 2026-06-09 on the
//       commit below). Asserts live == golden within a tight tol, AND reports
//       (stderr + assertion) whether the golden equals numericRotateSeqRef for the
//       same angles.
//
// Discipline (mirrors test_run_absolute_rotate.d / test_pf_acen_local.d): hermetic
// baseline via reset + history.clear (NEVER drainHistory after /api/reset, which is
// undoable); gizmo gestures via drag_helpers.buildDragLog + /api/play-events with
// the mandatory ~120ms settle; published values off /api/toolpipe/eval; geometry
// off /api/model with count-keyed settle; ring-grab verify-and-retry on the undo
// count (the known ring-grab flake — a missed grab records nothing).

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, sin, cos, atan2, PI;
import std.conv : to;
import std.format : format;
import std.stdio : stderr;

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
    assert(a.length == b.length,
        "vertex-count mismatch: " ~ a.length.to!string ~ " vs " ~ b.length.to!string);
    float m = 0;
    foreach (i; 0 .. a.length) {
        Vec3 d = a[i] - b[i];
        float len = sqrt(dot(d, d));
        if (len > m) m = len;
    }
    return m;
}

void lockCamera() {
    auto r = postJson("/api/camera",
        `{"azimuth":0.5,"elevation":0.4,"distance":3.0,`
      ~ `"focus":{"x":0.0,"y":0.0,"z":0.0}}`);
    assert(r["status"].str == "ok", "camera lock failed: " ~ r.toString);
}

// Published run-absolute rotate component (deg) off /api/toolpipe/eval.
double publishedR(int axis) {
    auto j = getJson("/api/toolpipe/eval");
    auto t = "transform" in j.object;
    assert(t !is null, "eval has no transform block (no transform tool active?): "
        ~ j.toString);
    return (*t)["rotate"].array[axis].floating;
}
// The single non-zero principal axis the run-absolute field currently carries,
// and its angle. A gizmo run only ever holds ONE live principal axis (the others
// are re-baked into geometry), so exactly one of RX/RY/RZ is non-zero after a
// principal gesture. Returns the axis index (0/1/2) of the largest |component| and
// its signed angle. This lets the test feed the ACTUAL axis the gesture drove into
// the sequential reference, rather than assuming which world axis a local-gizmo
// ring grab resolves to (under acen=local a world-Y ring grab can resolve to the
// Z handle, etc.).
bool hasTransformBlock() {
    auto j = getJson("/api/toolpipe/eval");
    return ("transform" in j.object) !is null;
}
void publishedAxisAngle(out int axis, out double deg, out string attr) {
    // The eval transform block can be transiently absent immediately after a
    // gesture if a post-playback event drain is still settling (the known runner
    // drain race: /api/play-events/status reports finished once events are POSTED,
    // not PROCESSED). Settle-and-retry until the active transform tool republishes
    // its block.
    foreach (_; 0 .. 20) {
        if (hasTransformBlock()) break;
        settle();
    }
    double best = -1;
    axis = 0;
    foreach (a; 0 .. 3) {
        double m = fabs(publishedR(a));
        if (m > best) { best = m; axis = a; }
    }
    deg  = publishedR(axis);
    attr = axis == 0 ? "RX" : axis == 1 ? "RY" : "RZ";
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
        postJson("/api/script", "tool.set move off");
        foreach (_; 0 .. 200) {
            if (replayIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        // Do NOT drainHistory() after /api/reset: SceneReset is itself undoable
        // and its revert() restores the PRE-reset (prior test's dirty) mesh, so
        // a drain-after-reset can leave a standing entry that reverts geometry to a
        // stale state. history.clear is a SideEffect command: it wipes BOTH stacks
        // WITHOUT touching the mesh, so the cube stays pristine AND undo=0.
        postJson("/api/reset", "");                 // cube
        postJson("/api/command", "history.clear");  // wipe stacks, keep the cube
        if (cubePristine() && undoCount() == 0) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");
    assert(cubePristine(), "could not establish pristine cube baseline");
}

// --- principal-axis arc grab (replica of test_run_absolute_rotate.d) --------
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
// UNDO COUNT (a missed grab records nothing -> retry). Returns the published
// `axis` angle delta this gesture produced (post - pre).
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
        if (undoCount() == wantCount) return publishedR(axis) - preR;
    }
    assert(false, "principal ring gesture (axis " ~ axis.to!string
        ~ ") did not record after retries (ring-grab flake)");
    return 0;
}

// As principalRingGesture, but ALSO captures the dominant published principal axis
// (the single non-zero RX/RY/RZ) and its angle at the EXACT moment the gesture is
// confirmed recorded — before returning, so no post-return settle window lets a
// still-draining replay event fire a background mouse-up that deactivates the
// unified transform tool (the observed runner failure: the tool is active right
// after the gesture but a re-read after extra settling finds the block gone). The
// `outAxis`/`outDeg`/`outAttr` are read in the SAME loop iteration that matches the
// undo count.
double principalRingGestureCapture(int axisAimed, Vec3 center, long wantCount,
                                   out int outAxis, out double outDeg,
                                   out string outAttr, out double[3] outRxyz,
                                   float arcDelta = 0.55f) {
    Vec3 axisVec = axisAimed == 0 ? Vec3(1,0,0)
                 : axisAimed == 1 ? Vec3(0,1,0)
                 :                  Vec3(0,0,1);
    double preR = publishedR(axisAimed);
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
            // Capture the dominant published axis AND the full RX/RY/RZ triple NOW,
            // while the tool is still active (verified true at this instant by the
            // runner DBG). Reading after a post-return settle window let a draining
            // replay event deactivate the tool.
            publishedAxisAngle(outAxis, outDeg, outAttr);
            outRxyz = [publishedR(0), publishedR(1), publishedR(2)];
            return outRxyz[axisAimed] - preR;
        }
    }
    assert(false, "principal ring gesture (axis " ~ axisAimed.to!string
        ~ ") did not record after retries (ring-grab flake)");
    return 0;
}

// ---------------------------------------------------------------------------
// Sequential cross-axis numeric reference: two SEPARATE tool sessions on the
// CURRENT mesh state (the first baked + dropped, the second re-opened on the
// baked pose), faithfully mirroring the interactive cross-axis RE-BAKE. Takes a
// setup delegate that establishes the scene (mesh + selection + actr mode), so it
// can run on either the acen=auto top-face cube or the acen=local multi-cluster
// cube. Returns the final vertex dump.
Vec3[] numericRotateSeqRef(void delegate() setupScene,
                           string axisAttr1, double a1,
                           string axisAttr2, double a2) {
    void rOnly() {
        cmd("tool.set xfrm.transform on");
        cmd("tool.attr xfrm.transform T false");
        cmd("tool.attr xfrm.transform S false");
        cmd("tool.attr xfrm.transform R true");
    }
    // Session 1 — bake axis 1, then DROP the tool (commits the geometry).
    setupScene();
    rOnly();
    cmd("tool.beginSession");
    cmd(format(`tool.attr xfrm.transform %s %.6f`, axisAttr1, a1));
    settle();
    cmd("tool.set xfrm.transform off");
    settle();
    // Session 2 — re-open on the baked pose, compose axis 2. Re-establish the
    // SAME selection + actr mode WITHOUT resetting the mesh (the baked pose must
    // survive). The setup delegate must therefore re-select + re-set actr without
    // a /api/reset between the two sessions — handled by the caller's delegate.
    rOnly();
    cmd("tool.beginSession");
    cmd(format(`tool.attr xfrm.transform %s %.6f`, axisAttr2, a2));
    settle();
    auto o = dumpVerts();
    cmd("tool.set xfrm.transform off");
    drainHistory();
    return o;
}

// ===========================================================================
// (1) acen=auto, single top face (WORLD-aligned basis).
//
// Cross-axis gizmo X-gesture then Y-gesture. The resulting vertex dump should
// MATCH numericRotateSeqRef("RX", rxHeld, "RY", ryAfter) — the sequential
// bake-then-recompose. World basis: the per-frame top-face basis is world-aligned
// and STABLE, so the re-bake (sequential geometry) is the same as the sequential
// numeric reference. This pins "auto basis is unaffected" — passes NOW AND after
// Phase 2 (a frozen-basis full-Euler about a stable world basis reproduces the
// sequential ZYX result exactly when the basis does not drift).
// ===========================================================================
Vec3 autoPivot = Vec3(0, 0.5f, 0);   // top-face centroid, stable under X/Y/Z

unittest {
    establishCubeBaseline();
    lockCamera();
    int topFace = findTopFace();
    postJson("/api/select",
        `{"mode":"polygons","indices":[` ~ topFace.to!string ~ `]}`);
    settle();
    cmd("tool.set xfrm.transform on");
    cmd("tool.attr xfrm.transform T false");
    cmd("tool.attr xfrm.transform S false");
    cmd("tool.attr xfrm.transform R true");
    cmd("actr.auto");          // explicit single-frame ACEN (top-face centroid)
    settle();
    long floor = undoCount();

    // Cross-axis: first gesture about world X, second about world Y. We CAPTURE
    // which principal component each gesture actually wrote at the instant it
    // records (a gizmo run holds ONE live axis; the others are re-baked into
    // geometry), so the sequential reference is fed the SAME two axes the live drag
    // drove — and the capture happens before any post-gesture settle window.
    int ax1; double deg1; string attr1; double[3] rxyz1;
    principalRingGestureCapture(0, autoPivot, floor + 1, ax1, deg1, attr1, rxyz1);
    assert(undoCount() == floor + 1, "gesture 1 records one in-session entry");
    assert(fabs(deg1) > 5.0, "gesture 1 left a nonzero held axis; got "
        ~ attr1 ~ "=" ~ deg1.to!string);

    int ax2; double deg2; string attr2; double[3] rxyz2;
    principalRingGestureCapture(1, autoPivot, floor + 2, ax2, deg2, attr2, rxyz2);
    assert(undoCount() == floor + 2, "gesture 2 records a second in-session entry");
    auto liveXY = dumpVerts();

    cmd("tool.set xfrm.transform off");
    drainHistory();

    // CROSS-AXIS: the second gesture drove a DIFFERENT principal axis than the
    // first. If a flaky ring grab re-resolved to the same axis this is a same-axis
    // run, not the cross-axis case we mean to pin.
    assert(ax2 != ax1,
        "cross-axis auto: gesture 2 drove a DIFFERENT principal axis than gesture 1 "
        ~ "(got " ~ attr1 ~ " then " ~ attr2 ~ ")");
    assert(fabs(deg2) > 5.0,
        "cross-axis auto: gesture 2's published angle is nonzero; got "
        ~ attr2 ~ "=" ~ deg2.to!string);
    // CUMULATIVE-EULER (Phase 1): the GLOBAL path no longer re-bakes cross-axis —
    // headlessRotate holds the FULL cumulative ZYX Euler, so the held FIRST axis is
    // RETAINED in the FIELD (it is part of the cumulative decomposition, not zeroed
    // into a re-baked geometry). Read from the gesture-2 snapshot (rxyz2), captured
    // while the tool was live. The GEOMETRY assertion below validates that this
    // retained-field cumulative orientation reproduces the sequential bake exactly
    // (geometry-neutrality) — the field representation changed, the geometry did not.
    assert(fabs(rxyz2[ax1]) > 1.0,
        "cumulative-Euler: the held first axis is RETAINED in the FIELD (no "
        ~ "cross-axis re-bake on the global path); published " ~ attr1
        ~ " should be nonzero, got " ~ rxyz2[ax1].to!string);

    // The sequential reference re-establishes the SAME acen=auto top-face scene per
    // session (a fresh reset for session 1; session 2 re-selects the SAME face on
    // the baked pose, no reset). It applies the SAME two axes/angles the live drag
    // drove (attr1=deg1 then attr2=deg2).
    bool firstSeqCall = true;
    void seqSetup() {
        if (firstSeqCall) {
            establishCubeBaseline();
            lockCamera();
            firstSeqCall = false;
        }
        int tf = findTopFace();
        postJson("/api/select",
            `{"mode":"polygons","indices":[` ~ tf.to!string ~ `]}`);
        settle();
    }
    auto seqRef = numericRotateSeqRef(&seqSetup, attr1, deg1, attr2, deg2);

    float diff = maxVertDiff(liveXY, seqRef);
    stderr.writeln("[MEASURE acen=auto] g1=", attr1, "(", deg1, ") g2=", attr2,
        "(", deg2, ") live-vs-numericRotateSeqRef maxVertDiff=", diff);
    assert(diff < 3e-2,
        "ASSERT (auto basis unaffected): cross-axis live geometry == sequential "
        ~ "numericRotateSeqRef (world-aligned, stable basis). max per-vert diff = "
        ~ diff.to!string);
}

// ===========================================================================
// (2) acen=local, MULTI-CLUSTER segments-2 cube (DRIFTING per-cluster basis).
//
// A cross-axis gizmo X-gesture then Y-gesture under acen=local on the asymmetric
// 3-poly selection (2 disjoint clusters, per-cluster frame drifts). The resulting
// vertex dump is captured as a hardcoded GOLDEN below (the CURRENT re-bake
// behaviour). We assert live == golden within a tight tol, and we ALSO compute and
// report whether that golden equals numericRotateSeqRef for the same angles —
// i.e. is the current re-bake result already the sequential reference, or does the
// drifting per-cluster basis make it something else?
// ===========================================================================

// NOTE on the acen=local cross-axis run: under acen=local the local gizmo basis +
// camera make the "world-Y" ring grab RESOLVE to either the gizmo's Y or Z handle
// run-to-run for the same aimed arc — both are genuine cross-axis runs. The test
// reads the ACTUAL recorded axes and feeds the SAME axes/angles to the sequential
// numeric reference, so the geometry assertion (live == seqRef) is robust to which
// handle the second grab resolves to. (A frozen vertex golden was previously pinned
// here to ONE specific drag (RX then RZ); it broke whenever the grab resolved to RY
// instead — replaced by the resolution-robust seqRef assertion below.)

// Build a fresh multi-cluster acen=local Rotate scene WITHOUT resetting (caller
// controls the reset, so the sequential reference can re-open on a baked pose).
// `doReset` true = a hermetic reset + fresh prim.cube; false = re-select on the
// EXISTING mesh.
Vec3 localPivot;   // the local gizmo pivot (read from the eval after actr.local)
void selectLocalClusters() {
    cmd("select.typeFrom polygon");
    auto sel = postJson("/api/select", `{"mode":"polygons","indices":[11,12,13]}`);
    assert(sel["status"].str == "ok", "select failed: " ~ sel.toString);
    settle();
}
void setupLocalRotateScene(bool doReset) {
    import core.thread : Thread;
    import core.time   : msecs;
    if (doReset) {
        postJson("/api/script", "tool.set xfrm.transform off");
        postJson("/api/script", "tool.set rotate off");
        foreach (__; 0 .. 200) { if (replayIdle()) break; Thread.sleep(10.msecs); }
        Thread.sleep(120.msecs);
        drainHistory();
        postJson("/api/reset?empty=true", "");
        foreach (_; 0 .. 40) {
            if (getJson("/api/model")["vertices"].array.length == 0) break;
            Thread.sleep(20.msecs);
        }
        lockCamera();
        cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
          ~ "segmentsX:2 segmentsY:2 segmentsZ:2 radius:0");
    }
    selectLocalClusters();
}

// Read the local gizmo pivot off the eval (the shared ACEN center).
Vec3 readPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating, cast(float)c[1].floating,
                cast(float)c[2].floating);
}

// Is every per-cluster basis vector (right/up/fwd of every cluster) a pure signed
// world axis (one component +/-1, the others 0)? On a stock axis-aligned cube the
// per-cluster frame is derived from face normals, which are all world-axis-aligned,
// so the basis NEVER drifts off the world axes — it only sign-flips between
// clusters. This is THE fact behind the Phase-2 assessment: with an axis-aligned
// (non-drifting) per-cluster basis the cross-axis re-bake equals a frozen-basis
// full-Euler, so Phase 2 is geometry-neutral on this mesh. A genuinely drifting
// (non-axis-aligned) basis would need a mesh with oblique face normals.
bool perClusterBasisAxisAligned() {
    auto ax = getJson("/api/toolpipe/eval")["axis"];
    bool isAxis(JSONValue v) {
        auto a = v.array;
        int nonzero = 0;
        foreach (k; 0 .. 3) {
            double c = a[k].floating;
            if (fabs(c) > 1e-4) {
                ++nonzero;
                if (fabs(fabs(c) - 1.0) > 1e-3) return false;  // not +/-1
            }
        }
        return nonzero == 1;
    }
    foreach (k; ["clusterRight", "clusterUp", "clusterFwd"])
        foreach (v; ax[k].array)
            if (!isAxis(v)) return false;
    return true;
}

unittest {
    // --- Drive the live cross-axis gesture under acen=local --------------------
    setupLocalRotateScene(true);
    cmd("tool.set xfrm.transform on");
    cmd("tool.attr xfrm.transform T false");
    cmd("tool.attr xfrm.transform S false");
    cmd("tool.attr xfrm.transform R true");
    cmd("actr.local");
    settle();
    localPivot = readPivot();

    // DOCUMENT THE CRUX: the per-cluster basis on this stock cube is axis-aligned
    // (non-drifting). This is WHY the cross-axis re-bake below equals the frozen-
    // basis sequential reference — and why Phase 2 (frozen basis + full Euler) is
    // expected to be geometry-neutral on this mesh. If a future change made the
    // per-cluster frame oblique, this would flip and the golden-vs-seqRef diff
    // would become the real witness of re-bake-vs-frozen divergence.
    assert(perClusterBasisAxisAligned(),
        "acen=local on a stock axis-aligned cube yields an axis-aligned (non-"
        ~ "drifting) per-cluster basis — the crux of the Phase-2 assessment");

    long floor = undoCount();

    // Cross-axis: world-X ring then world-Y ring about the local gizmo pivot. We
    // CAPTURE which principal component each gesture actually wrote at the instant
    // it records (a gizmo run holds ONE live axis), so the sequential reference is
    // fed the SAME axes the live drag drove — robust to a local-gizmo ring grab
    // resolving to a different handle than the world axis we aimed the arc at, and
    // robust to a post-gesture settle window deactivating the tool.
    int ax1; double deg1; string attr1; double[3] rxyz1;
    principalRingGestureCapture(0, localPivot, floor + 1, ax1, deg1, attr1, rxyz1);
    assert(undoCount() == floor + 1, "gesture 1 records one in-session entry");
    assert(fabs(deg1) > 5.0, "gesture 1 left a nonzero held axis; got "
        ~ attr1 ~ "=" ~ deg1.to!string);

    int ax2; double deg2; string attr2; double[3] rxyz2;
    principalRingGestureCapture(1, localPivot, floor + 2, ax2, deg2, attr2, rxyz2);
    assert(undoCount() == floor + 2, "gesture 2 records a second in-session entry");
    auto liveXY = dumpVerts();

    cmd("tool.set xfrm.transform off");
    drainHistory();

    // CROSS-AXIS under acen=local: the two gestures drove DIFFERENT principal axes
    // (the held first axis re-baked into geometry). This is the case that matters
    // for Phase 2 — a frozen-basis full-Euler would compose both axes at once
    // about ONE captured basis instead of re-deriving the per-cluster basis between
    // the two re-baked sessions.
    assert(ax2 != ax1,
        "cross-axis local: gesture 2 drove a DIFFERENT principal axis than gesture "
        ~ "1 (got " ~ attr1 ~ " then " ~ attr2 ~ ")");
    assert(fabs(deg2) > 5.0,
        "cross-axis local: gesture 2's published angle is nonzero; got "
        ~ attr2 ~ "=" ~ deg2.to!string);

    // --- Compute the sequential numeric reference for the SAME axes/angles ------
    // Session 1 resets + rebuilds the segments-2 cube; session 2 re-selects on the
    // baked pose (no reset). It applies attr1=deg1 then attr2=deg2 — the SAME two
    // axes the live drag drove.
    bool firstSeqCall = true;
    void seqSetup() {
        setupLocalRotateScene(firstSeqCall);   // reset only on the first call
        if (firstSeqCall) { cmd("actr.local"); settle(); }
        firstSeqCall = false;
    }
    auto seqRef = numericRotateSeqRef(&seqSetup, attr1, deg1, attr2, deg2);

    float liveVsSeq = maxVertDiff(liveXY, seqRef);
    stderr.writeln("[MEASURE acen=local] g1=", attr1, "(", deg1, ") g2=", attr2,
        "(", deg2, ") live-vs-numericRotateSeqRef maxVertDiff=", liveVsSeq);

    // --- CORRECTNESS WITNESS (matrix-as-truth) ---------------------------------
    // The acen=local cross-axis run keeps the LEGACY per-cluster re-bake (the
    // matrix-truth model is global-only), so its TWO gestures bake their held axis
    // into geometry between sessions. The geometry-correctness witness is that the
    // live cross-axis result equals the SEQUENTIAL numeric reference for the SAME
    // two captured axes/angles. On the world-aligned (non-drifting) per-cluster
    // basis of this cube that holds EXACTLY.
    //
    // We assert against `seqRef` rather than a frozen vertex golden: the golden was
    // pinned to ONE specific drag whose gesture-2 ring grab resolved to a specific
    // handle (RZ), but the grab can resolve to RY vs RZ run-to-run for the same
    // aimed arc (camera/gizmo geometry). seqRef is fed the ACTUAL captured axes, so
    // it is robust to that resolution variance while still pinning the geometry.
    assert(liveVsSeq < 3e-2,
        "ASSERT (acen=local cross-axis): live geometry == sequential "
        ~ "numericRotateSeqRef for the captured axes/angles (per-cluster re-bake on "
        ~ "a world-aligned basis reproduces the sequential bake). max per-vert diff = "
        ~ liveVsSeq.to!string);
}

// Drive ONE ring gesture about an EXPLICIT world-space ring axis `axisVec` (used
// for the tilted-gizmo case, where the ring axes are the workplane frame axes, not
// world X/Y/Z). Same verify-and-retry on the undo count as principalRingGesture.
// Returns the largest |published euler component| delta vs pre (a coarse magnitude
// sanity check only — for a NON-WORLD axis the world-ZYX euler does not map to the
// physical ring angle, so the geometry-recovered axis is the real witness).
double tiltedRingGesture(Vec3 axisVec, Vec3 center, long wantCount,
                         float arcDelta = 0.5f) {
    double[3] preTriple = [publishedR(0), publishedR(1), publishedR(2)];
    foreach (attempt; 0 .. 18) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        float radius = gizmoSize(center, vp);
        Vec3 right, up;
        localFrame(axisVec, right, up);
        Vec3 camFwd = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
        float startAngle = arcStartAngle(axisVec, camFwd, right, up);
        float pull = arcDelta + attempt * 0.07f;
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
            double best = 0;
            foreach (k; 0 .. 3) {
                double d = fabs(publishedR(k) - preTriple[k]);
                if (d > best) best = d;
            }
            return best;
        }
    }
    assert(false, "tilted ring gesture did not record after retries (ring-grab flake)");
    return 0;
}

// ===========================================================================
// (3) NON-WORLD GLOBAL BASIS — tilted workplane, WHOLE-MESH selection.
//
// THE bug fix for matrix-as-truth. With `axis mode workplane` + a TILTED
// workplane, the GLOBAL gizmo basis (currentBasis → AxisPacket) is NON-WORLD,
// yet the moving set is the whole mesh (one global cluster, NOT per-cluster:
// ClusterAxes.active needs >=2 clusters). So this is the GLOBAL path on a
// non-world basis — exactly the case the prior euler-as-truth model got WRONG
// (it composed the gesture about WORLD canon axes but applied composeFor about
// the frozen non-world runFrame, so the ring rotated about the WRONG physical
// axis). Matrix-as-truth composes runRotMatrix about the ACTUAL frozen ring axis
// (runFrameR/U/F[ax]) and applies it directly.
//
// WITNESS (single gesture, axis recovered from geometry — angle-independent and
// independent of the tool's matrix internals): a RIGHT-ring gesture about the
// tilted workplane must rotate the mesh about the workplane's RIGHT axis. We
// recover the rotation axis purely from the vertex displacements (each Δ ⟂ the
// rotation axis ⇒ the axis is the common normal of the displacement plane) and
// assert it is PARALLEL to wpRight and NOT parallel to world X. Under the prior
// euler-as-truth model the ring rotated about world X (the canon-vs-runFrame
// mismatch), so the recovered axis would be world X — this is the discriminator.
// ===========================================================================

// Recover the rotation axis (unit, sign-free) from a set of pre→post displacement
// vectors of a rigid rotation about a fixed pivot: every displacement is
// perpendicular to the axis, so the axis is the dominant normal of the
// displacement set. Found as the eigenvector of Σ(d⊗d) with the SMALLEST
// eigenvalue — i.e. the direction MOST perpendicular to every displacement.
// Implemented as the cross product of the two displacements with the largest
// mutual angle (robust for a clean rigid rotation; the cube has plenty).
Vec3 recoverRotationAxis(Vec3[] pre, Vec3[] post) {
    Vec3[] disp;
    foreach (i; 0 .. pre.length) {
        Vec3 d = post[i] - pre[i];
        if (sqrt(dot(d, d)) > 1e-3) disp ~= normalize(d);
    }
    assert(disp.length >= 2, "need >=2 moved verts to recover the rotation axis");
    // Pick the pair of displacements that are most non-parallel, cross them.
    Vec3 best = Vec3(0, 0, 0);
    float bestLen = -1;
    foreach (i; 0 .. disp.length)
        foreach (j; i + 1 .. disp.length) {
            Vec3 c = cross(disp[i], disp[j]);
            float l = sqrt(dot(c, c));
            if (l > bestLen) { bestLen = l; best = c; }
        }
    return normalize(best);
}

// |cos| between two directions (1 ⇒ parallel, sign-free).
float absCos(Vec3 a, Vec3 b) { return fabs(dot(normalize(a), normalize(b))); }

// Read the frozen run-frame (origin + right/up/fwd) off the eval transform block.
void readRunFrame(out Vec3 origin, out Vec3 right, out Vec3 up, out Vec3 fwd) {
    auto t = getJson("/api/toolpipe/eval")["transform"];
    Vec3 g(string key) {
        auto a = t[key].array;
        return Vec3(cast(float)a[0].floating, cast(float)a[1].floating,
                    cast(float)a[2].floating);
    }
    origin = g("runFrameOrigin");
    right  = g("runFrameRight");
    up     = g("runFrameUp");
    fwd    = g("runFrameFwd");
}

unittest {
    establishCubeBaseline();
    lockCamera();

    // Whole-mesh selection (no selection ⇒ the universal whole-mesh moving set,
    // a single GLOBAL cluster). Activate the tool FIRST: the preset's
    // (preset, acenMode, axisMode) tuple resets axis mode on activate, so the
    // workplane tilt must be applied AFTER the tool is live or it gets clobbered.
    cmd("tool.set xfrm.transform on");
    cmd("tool.attr xfrm.transform T false");
    cmd("tool.attr xfrm.transform S false");
    cmd("tool.attr xfrm.transform R true");
    settle();

    // Tilt the workplane and feed it to the AXIS stage so the GLOBAL gizmo basis
    // is NON-WORLD (oblique on all three axes).
    cmd("tool.pipe.attr axis mode workplane");
    cmd("workplane.rotate axis:Y angle:35");
    cmd("workplane.rotate axis:X angle:20");
    settle();

    // The gizmo's NON-WORLD ring axes = the workplane (AxisPacket) frame.
    Vec3 wpRight, wpUp, wpFwd;
    {
        auto ax = getJson("/api/toolpipe/eval")["axis"];
        Vec3 g(string k) {
            auto a = ax[k].array;
            return Vec3(cast(float)a[0].floating, cast(float)a[1].floating,
                        cast(float)a[2].floating);
        }
        wpRight = g("right"); wpUp = g("up"); wpFwd = g("fwd");
    }
    // CRUX precondition: wpRight must be NON-WORLD and materially off world X.
    assert(absCos(wpRight, Vec3(1, 0, 0)) < 0.97f,
        "non-world scene precondition: wpRight must be materially off world X "
        ~ "(workplane tilt did not take); |cos(wpRight, X)| = "
        ~ absCos(wpRight, Vec3(1, 0, 0)).to!string);

    Vec3[] baseline = dumpVerts();
    Vec3 pivot = readPivot();
    long floor = undoCount();

    // ONE gesture about the gizmo's RIGHT ring (a NON-WORLD axis).
    double d1 = tiltedRingGesture(wpRight, pivot, floor + 1);
    assert(undoCount() == floor + 1, "ng gesture records one in-session entry");
    assert(fabs(d1) > 5.0,
        "non-world gesture produced too small an angle; got " ~ d1.to!string);
    auto liveXY = dumpVerts();

    // Confirm the run-frame froze to the workplane axes.
    Vec3 rfO, rfR, rfU, rfF;
    readRunFrame(rfO, rfR, rfU, rfF);

    cmd("tool.set xfrm.transform off");
    drainHistory();
    cmd("tool.pipe.attr axis mode auto");
    cmd("workplane.reset");

    // Recover the physical rotation axis from the geometry alone.
    Vec3 recovered = recoverRotationAxis(baseline, liveXY);
    float cosWp    = absCos(recovered, wpRight);     // want ≈ 1 (own axis)
    float cosWorld = absCos(recovered, Vec3(1,0,0)); // want < 1 (NOT world X)
    stderr.writeln("[MEASURE non-world] gesture about wpRight=", wpRight.x, ",",
        wpRight.y, ",", wpRight.z, "  recoveredAxis=", recovered.x, ",",
        recovered.y, ",", recovered.z, "  |cos(rec,wpRight)|=", cosWp,
        "  |cos(rec,worldX)|=", cosWorld);

    // THE ASSERTIONS that prove bug #1 fixed on a NON-WORLD global basis:
    //   (a) the mesh rotated about the gizmo's OWN (workplane) RIGHT axis, and
    //   (b) NOT about world X (which is what the old euler-as-truth model did).
    assert(cosWp > 0.999f,
        "ASSERT (non-world basis bug fixed): the gizmo's RIGHT ring rotated the mesh "
        ~ "about the gizmo's OWN (workplane) axis; |cos(recovered, wpRight)| = "
        ~ cosWp.to!string ~ " (want ≈ 1)");
    assert(cosWorld < absCos(wpRight, Vec3(1,0,0)) + 1e-3f,
        "non-world discriminator: the recovered axis is the workplane axis, NOT "
        ~ "world X (the prior euler-as-truth bug rotated about world X); "
        ~ "|cos(recovered, worldX)| = " ~ cosWorld.to!string);
}
