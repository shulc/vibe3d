// P-F Phase 4 — frozen-run-frame correctness under acen=local + multi-cluster
// display scope (single-field mechanism (c), plan M5 / SDK-#3).
//
// Phases 2/3 (Move/Scale/Rotate) only ever touched the GLOBAL/gizmo-frame
// projection (composeFor's translate term reads the FROZEN runFrameR/U/F,
// xfrm_transform.d:3524-3527). The PER-CLUSTER fold (clusterM,
// xfrm_transform.d:3538-3545) was left untouched: it still composes one matrix
// per cluster about that cluster's OWN per-frame ap.right/up/fwd[cid]. So:
//
//   * Single-frame ACEN modes (auto/none/screen, ONE frozen frame for the whole
//     moving set) — the published run-absolute DISPLAY equals the GEOMETRY: the
//     gizmo frame IS the geometry frame. (case a)
//
//   * acen=local with MULTIPLE clusters — the published run-absolute display is
//     the SINGLE GIZMO-frame value (one frozen frame). It does NOT and CANNOT
//     equal any individual cluster's world geometry, because each cluster moves
//     along its OWN per-frame fwd[cid]. The display is STILL run-absolute
//     (accumulates across gestures, stable in the frozen gizmo frame); the
//     GEOMETRY is per-cluster-correct (clusters move independently — opposite-
//     normal clusters move in OPPOSITE world directions by the SAME basis-local
//     scalar). (case b)
//
//   * The frozen frame is the SDK-#3 fix: the run-frame is captured ONCE at the
//     run's first applyTRS and NEVER re-derived per frame. Under acen=local,
//     `currentBasis` re-derives the gizmo basis every frame; a per-frame read
//     would let the run-absolute DISPLAY drift as the cluster partition / basis
//     wobbles between gestures. The frozen frame holds the display coherent
//     across gestures even when the live basis would have re-derived. (case c)
//
//   * Relocate (resetRun) under acen=local resets the run-absolute field to
//     identity while leaving the committed geometry put (G8). (case d)
//
// This phase is TEST + SCOPE-DOC only: it pins behaviour that Phases 2/3 already
// produced. The per-cluster path was never on the Phase-2/3 change surface
// (confirmed: composeFor's clusterM at 3538-3545 reads ap.* per-frame; only the
// GLOBAL translate term at 3524-3527 reads the frozen frame).
//
// Discipline: selectV6-style minimal selection (NO select-undo drain after
// reset), drainHistory BEFORE reset, gizmo gestures via drag_helpers.buildDragLog
// + /api/play-events with the mandatory ~120ms settle, vec3 attrs double-quoted,
// published values read off /api/toolpipe/eval (never the raw panel struct),
// geometry off /api/model with count-keyed settle.
//
// ===========================================================================
// P-F DEFINITION-OF-DONE COVERAGE MAP (Phase 5)
// ---------------------------------------------------------------------------
// Each P-F sub-claim + each prior opponent objection -> its verifying test.
// No row is uncovered; this phase adds NO redundant test (the matrix is
// satisfied by the per-bank run-absolute suites + this acen=local file).
//
//   CLAIM / OBJECTION                         VERIFYING TEST (case)
//   ------------------------------------------------------------------------
//   run-absolute across gestures — Move       test_pf_move_pin (b)
//   run-absolute across gestures — Scale      test_run_absolute_scale (b)
//   run-absolute across gestures — Rotate     test_run_absolute_rotate (b)
//     (same-axis accumulation; BLOCKER-1)
//   round-2 read!=write wall resolved         test_reevaluate (1b/2 absolute
//     (single field; read==write==apply)        write) + test_pf_move_pin (a)
//   bare-write absolute (Q3, all 3 banks)     test_reevaluate; test_pf_move_pin
//                                               (a); test_run_absolute_scale (a);
//                                               test_run_absolute_rotate (a)
//   fresh-tool inert (hasLiveEval false)      test_reevaluate (Test 1)
//   in-session Ctrl+Z steps ONE gesture       test_run_absolute_scale (c);
//     (G8 per-gesture undo; redo restores)      test_run_absolute_rotate (d);
//                                               test_pf_move_pin (undo case)
//   drop consolidates run -> ONE entry        test_run_absolute_scale (a)
//   relocate -> identity (G8)                 test_pf_move_pin; _scale (e);
//                                               _rotate (f); THIS file (d);
//                                               test_relocate_boundary* (x5)
//   cross-bank hold (held bank survives)      test_run_absolute_scale (d);
//                                               test_run_absolute_rotate (e)
//   cross-bank GPU no double-apply            test_run_absolute_scale (d);
//     (own-bank fast-path drop-out, MAJOR-4)    test_run_absolute_rotate (e)
//   composeFor reads FULL field, no subtract  test_xfrm_fold_multibank
//     (BLOCKER-1; held bank survives a refold)
//   rotate Euler non-commute (BLOCKER-3)      test_run_absolute_rotate (c
//     -> same-axis only; cross-axis re-bakes)   cross-axis re-bake)
//   rotate geometry matrix unchanged          test_rotate_xfrm_reference
//   uniform hook across gesture + refire      test_falloff_refire_rs;
//     (MAJOR-5; in-session undo after refire     test_refire
//      restores field + geometry together)
//   M4 reset-site list (11 sites, resetRun)   THIS file (d) + _scale/_rotate (e)
//                                               + test_relocate_boundary* (x5)
//   M5 multi-cluster display scope            THIS file (b) — display = gizmo
//     (display = gizmo-frame, NOT per-cluster)   frame, single-frame == geometry
//   M6 frozen-frame capture ordering /        THIS file (a) single-frame; (c)
//     SDK-#3 frozen frame no drift              acen=local byte-stable run-frame
//   forms panel binds same field/ids          test_forms_* (x4)
//     (no repoint, no mirror member)
// ===========================================================================

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, PI, cos, sin;
import std.conv : to;
import std.string : format;

import drag_helpers;

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
double[3] vert(int idx) {
    auto v = getJson("/api/model")["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}
bool vertNear(double[3] a, double[3] b, double tol = 1e-2) {
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

void lockCamera() {
    auto r = postJson("/api/camera",
        `{"azimuth":0.5,"elevation":0.4,"distance":3.0,`
      ~ `"focus":{"x":0.0,"y":0.0,"z":0.0}}`);
    assert(r["status"].str == "ok", "camera lock failed: " ~ r.toString);
}

// ---------------------------------------------------------------------------
// Published / pivot accessors off /api/toolpipe/eval.
// ---------------------------------------------------------------------------
Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating, cast(float)c[1].floating,
                cast(float)c[2].floating);
}
Vec3 publishedTranslate() {
    auto j = getJson("/api/toolpipe/eval");
    auto t = "transform" in j.object;
    assert(t !is null, "eval has no transform block: " ~ j.toString);
    auto a = (*t)["translate"].array;
    return Vec3(cast(float)a[0].floating, cast(float)a[1].floating,
                cast(float)a[2].floating);
}
// The frozen per-run gizmo frame (P-F Phase 1 block).
struct RunFrame {
    bool valid;
    Vec3 origin, right, up, fwd;
}
RunFrame publishedRunFrame() {
    auto j = getJson("/api/toolpipe/eval");
    auto t = "transform" in j.object;
    assert(t !is null, "eval has no transform block: " ~ j.toString);
    RunFrame rf;
    rf.valid = (*t)["runFrameValid"].type == JSONType.true_;
    Vec3 v3(string k) {
        auto a = (*t)[k].array;
        return Vec3(cast(float)a[0].floating, cast(float)a[1].floating,
                    cast(float)a[2].floating);
    }
    rf.origin = v3("runFrameOrigin");
    rf.right  = v3("runFrameRight");
    rf.up     = v3("runFrameUp");
    rf.fwd    = v3("runFrameFwd");
    return rf;
}

// Cluster info (per-vertex cluster id + per-cluster signed fwd) off the eval. The
// divergence cases drive the gizmo's blue Z (fwd) handle via the committed local
// drag log: under acen=local each cluster moves along its OWN clusterFwd[cid],
// which for the asymmetric 3-poly selection is -Y for one cluster and +Y for the
// other (opposite world directions, SAME basis-local scalar).
struct ClusterInfo {
    Vec3[] centers;
    Vec3[] fwd;     // signed snapped face normal per cluster (axis index 2)
    int[]  clusterOf;
}
ClusterInfo readClusters() {
    auto j = getJson("/api/toolpipe/eval");
    ClusterInfo ci;
    foreach (c; j["actionCenter"]["clusterCenters"].array) {
        auto a = c.array;
        ci.centers ~= Vec3(cast(float)a[0].floating, cast(float)a[1].floating,
                           cast(float)a[2].floating);
    }
    foreach (c; j["actionCenter"]["clusterOf"].array)
        ci.clusterOf ~= cast(int)c.integer;
    foreach (f; j["axis"]["clusterFwd"].array) {
        auto a = f.array;
        ci.fwd ~= Vec3(cast(float)a[0].floating, cast(float)a[1].floating,
                       cast(float)a[2].floating);
    }
    return ci;
}

// ---------------------------------------------------------------------------
// Gizmo gesture helpers (verbatim shape from test_run_absolute_scale.d).
// ---------------------------------------------------------------------------
// Grab pixel + screen-space direction for the gizmo arrow along the world-space
// `axisDir` (the gizmo renders along the SHARED axis frame, which under acen=auto
// with a world-aligned cube is world-axis-aligned: right=+X, up=+Y, fwd=+Z). Used
// by the SINGLE-FRAME case (a), which grabs the +X arrow at the origin pivot. The
// acen=local divergence cases instead replay the committed Z-handle log
// (localFwdGesture), whose low blended pivot keeps the fwd handle clear.
void arrowGrabPx(Vec3 pivot, Vec3 axisDir, ref Viewport vp,
                 out int gx, out int gy, out double ux, out double uy) {
    float size = gizmoSize(pivot, vp);
    Vec3 a0 = pivot + axisDir * (size / 6.0f);
    Vec3 a1 = pivot + axisDir * size;
    float sx1, sy1, sx2, sy2;
    projectToWindow(a0, vp, sx1, sy1);
    projectToWindow(a1, vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}

// One ON-arrow Move gesture along `axisDir` against the CURRENT gizmo pivot.
// Verify-and-retry on the UNDO COUNT (a missed grab records nothing -> retry).
// Used by the SINGLE-FRAME case (a), where the gizmo pivot at the origin clears
// the X arrow for a clean synthetic grab.
void moveGestureOnArrow(Vec3 axisDir, long wantCount, double mag = 60.0) {
    foreach (attempt; 0 .. 8) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        int x1, y1; double ux, uy;
        arrowGrabPx(evalPivot(), axisDir, vp, x1, y1, ux, uy);
        int xb = x1 + cast(int)(mag * ux);
        int yb = y1 + cast(int)(mag * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  x1, y1, xb, yb, 12));
        settle();
        if (undoCount() == wantCount) return;
    }
    assert(false, "move arrow gesture did not record after retries");
}

// The committed acen=local Z-handle drag (the manual capture shared with
// test_acen_local_translate_parity.d). Under acen=local on the [11,12,13]
// asymmetric selection it drives the blue Z (fwd) handle, which the gizmo's low
// blended pivot keeps clear for a deterministic, non-degenerate grab (unlike a
// synthetic +Y/+Z grab at the same pivot, which the screen-projected handle
// length / overlap makes flaky). Replaying it ONCE = one committed gesture; the
// pivot/camera are pinned so a re-replay drives the SAME handle for accumulation.
string localFwdLog;
// Replay the captured local fwd-handle drag as ONE gesture; verify-and-retry on
// the undo count (a stray miss records nothing -> retry).
void localFwdGesture(long wantCount) {
    import std.file : readText;
    if (localFwdLog.length == 0)
        localFwdLog = readText("tests/events/acen_local_translate_drag.log");
    foreach (attempt; 0 .. 6) {
        settle();
        playAndWait(localFwdLog);
        settle();
        if (undoCount() == wantCount) return;
    }
    assert(false, "captured local fwd-handle gesture did not record after retries");
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
        postJson("/api/script", "tool.set move off");
        postJson("/api/script", "tool.set rotate off");
        postJson("/api/script", "tool.set Transform off");
        foreach (_; 0 .. 200) {
            if (replayIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        drainHistory();            // BEFORE the reset (/api/reset is undoable)
        postJson("/api/reset", "");
        drainHistory();            // AFTER the reset
        if (cubePristine()) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");
    assert(cubePristine(), "could not establish pristine cube baseline");
}

// Build a fresh multi-cluster acen=local Move scene: a segments-2 cube with an
// asymmetric 3-polygon selection (the proven 2-cluster setup from
// test_acen_local_translate_parity.d). Returns the two clusters' signed fwd.
ClusterInfo setupLocalMoveScene() {
    import core.thread : Thread;
    import core.time   : msecs;
    // Deactivate + settle + drain BEFORE the reset (the reset itself is undoable;
    // NEVER drain after it — draining would undo the empty reset and resurrect a
    // prior cube, doubling the mesh so the [11,12,13] selection maps to the wrong
    // polys). Mirrors test_acen_local_translate_parity's plain `reset?empty=true`.
    postJson("/api/script", "tool.set move off");
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
    cmd("select.typeFrom polygon");
    auto sel = postJson("/api/select", `{"mode":"polygons","indices":[11,12,13]}`);
    assert(sel["status"].str == "ok", "select failed: " ~ sel.toString);
    settle();
    cmd("tool.set move on");
    cmd("actr.local");                  // ACEN + AXIS local: 2 disjoint clusters
    settle();
    auto ci = readClusters();
    assert(ci.centers.length == 2,
        "expected 2 clusters for the asymmetric 3-poly selection, got "
        ~ ci.centers.length.to!string);
    return ci;
}

// ===========================================================================
// (a) SINGLE-FRAME ACEN (auto): published run-absolute DISPLAY == GEOMETRY.
//
// With ONE frozen frame for the whole moving set the gizmo frame IS the geometry
// frame, so the published TX maps directly to the world +X geometry advance. Two
// same-bank Move gestures keep the run total in the published TX AND the geometry
// equals baseline + published-TX along world +X. acen-mode-tagged: this equality
// holds ONLY for single-frame modes (contrast case b).
// ===========================================================================
unittest {
    establishCubeBaseline();
    lockCamera();
    // NO selection ⇒ whole-mesh moving set, ONE frame, pivot at origin. ACEN.Auto
    // with the whole mesh is a single-frame mode (one gizmo frame == one geometry
    // frame). A +X arrow drag advances every vertex by the same world +X delta.
    cmd("tool.set move");
    cmd("actr.auto");
    settle();
    long floor = undoCount();

    auto base = vert(6);
    moveGestureOnArrow(Vec3(1, 0, 0), floor + 1);
    assert(undoCount() == floor + 1, "gesture 1 records one in-session entry");
    double txG1 = publishedTranslate().x;
    assert(fabs(txG1) > 1e-2, "gesture 1 swept a meaningful TX; got "
        ~ txG1.to!string);
    auto afterG1 = vert(6);

    moveGestureOnArrow(Vec3(1, 0, 0), floor + 2);
    assert(undoCount() == floor + 2, "gesture 2 records a second in-session entry");
    auto pubT = publishedTranslate();
    auto afterG2 = vert(6);

    // RUN-ABSOLUTE: TX accumulates past gesture 1 alone.
    assert(fabs(pubT.x) > fabs(txG1) + 1e-2,
        "single-frame run-absolute: TX after gesture 2 is the run total, past "
        ~ "gesture 1 alone. txG1=" ~ txG1.to!string ~ " txG2=" ~ pubT.x.to!string);

    // DISPLAY == GEOMETRY (the single-frame equality): the +X arrow drag is a
    // world +X translation about the auto pivot, so v6 advanced by exactly the
    // published TX along world +X; Y/Z unchanged. This equality is what acen=local
    // multi-cluster CANNOT satisfy (case b).
    assert(fabs((afterG2[0] - base[0]) - pubT.x) < 2e-2,
        "single-frame acen=auto: published TX == world +X geometry advance "
        ~ "(display==geometry). dx=" ~ (afterG2[0]-base[0]).to!string
        ~ " TX=" ~ pubT.x.to!string);
    assert(fabs(afterG2[1] - base[1]) < 2e-2 && fabs(afterG2[2] - base[2]) < 2e-2,
        "single-frame: the +X move leaves Y/Z unchanged (pure world-+X frame)");
    // Geometry advanced monotonically across the two gestures.
    assert((afterG2[0] - afterG1[0]) * txG1 > 0,
        "geometry accumulated in gesture 1's direction across both gestures");

    cmd("tool.set move off");
    drainHistory();
}

// ===========================================================================
// (b) acen=local MULTI-CLUSTER: published display = GIZMO-frame value (stable,
//     run-absolute, accumulates); geometry is PER-CLUSTER-correct (clusters move
//     independently). display does NOT equal any one cluster's world geometry.
//
// THE M5 scope assertion. The two clusters of the asymmetric 3-poly selection
// have OPPOSITE-signed fwd (top cells +Y, bottom cell -Y). A single basis-local
// scalar pushed into headlessTranslate moves cluster A along +fwd_A and cluster B
// along +fwd_B — opposite WORLD directions, SAME basis-local magnitude. So:
//   * the published display (gizmo-frame headlessTranslate) is ONE number set,
//     STABLE and run-absolute across gestures;
//   * the per-cluster GEOMETRY diverges (opposite world directions) — proving
//     display CANNOT equal any single cluster's world delta;
//   * yet each cluster's |basis-local scalar| AGREES (independent-but-uniform).
// ===========================================================================
unittest {
    auto ci = setupLocalMoveScene();
    long floor = undoCount();

    // The captured gesture drives the blue Z (fwd) handle, which under acen=local
    // routes the one basis-local scalar into each cluster's OWN clusterFwd[cid].
    // For the asymmetric 3-poly selection those are OPPOSITE world directions
    // (-Y vs +Y), so the two clusters diverge observably while sharing one scalar.
    double fwdDot = dot(normalize(ci.fwd[0]), normalize(ci.fwd[1]));
    assert(fwdDot < -0.5,
        "the asymmetric 3-poly selection yields clusters with OPPOSITE local-fwd "
        ~ "(fwd dot < -0.5, so the Z handle diverges them); got " ~ fwdDot.to!string);

    auto pre = dumpVerts();

    // Gesture 1: the committed Z-handle drag.
    localFwdGesture(floor + 1);
    assert(undoCount() == floor + 1, "gesture 1 records one in-session entry");
    Vec3 pubG1 = publishedTranslate();
    double pubMagG1 = sqrt(dot(pubG1, pubG1));
    assert(pubMagG1 > 1e-2, "gesture 1 published a nonzero run-absolute translate");
    auto afterG1 = dumpVerts();

    // Per-cluster mean world displacement after gesture 1.
    Vec3[2] clMean(Vec3[] a, Vec3[] b) {
        Vec3[2] sum; int[2] cnt;
        foreach (vi, c; ci.clusterOf) {
            if (c < 0 || c > 1) continue;
            sum[c] = sum[c] + (b[vi] - a[vi]);
            ++cnt[c];
        }
        Vec3[2] mean;
        foreach (k; 0 .. 2) {
            assert(cnt[k] > 0, "cluster " ~ k.to!string ~ " has no verts");
            mean[k] = sum[k] / cast(float)cnt[k];
        }
        return mean;
    }
    Vec3[2] meanG1 = clMean(pre, afterG1);
    // Each cluster's signed scalar along its OWN local-fwd (the driven axis).
    double s0G1 = dot(meanG1[0], normalize(ci.fwd[0]));
    double s1G1 = dot(meanG1[1], normalize(ci.fwd[1]));
    assert(fabs(s0G1) > 1e-2 && fabs(s1G1) > 1e-2,
        "both clusters moved measurably along their own local-fwd: s0="
        ~ s0G1.to!string ~ " s1=" ~ s1G1.to!string);

    // PER-CLUSTER INDEPENDENCE: opposite world directions. The world-Y components
    // of the two clusters' mean displacements have OPPOSITE sign (fwd_0=-Y, fwd_1=+Y,
    // SAME basis-local scalar). This is the geometry the single gizmo-frame display
    // can NOT represent.
    assert(meanG1[0].y * meanG1[1].y < 0,
        "per-cluster geometry diverges in WORLD space (opposite-Y): cluster0.y="
        ~ meanG1[0].y.to!string ~ " cluster1.y=" ~ meanG1[1].y.to!string);
    // Independent-but-UNIFORM: the |basis-local scalar| agrees across clusters
    // (one headlessTranslate scalar, each cluster reads its own frame).
    assert(fabs(fabs(s0G1) - fabs(s1G1)) < 5e-2,
        "uniform basis-local scalar across clusters: |s0|=" ~ fabs(s0G1).to!string
        ~ " |s1|=" ~ fabs(s1G1).to!string);

    // M5 SCOPE: the published display does NOT equal both clusters' world deltas.
    double dispVsC0 = sqrt(dot(pubG1 - meanG1[0], pubG1 - meanG1[0]));
    double dispVsC1 = sqrt(dot(pubG1 - meanG1[1], pubG1 - meanG1[1]));
    assert(dispVsC0 > 1e-2 || dispVsC1 > 1e-2,
        "M5: the single gizmo-frame display does NOT equal both clusters' world "
        ~ "geometry (it cannot — they diverge). dispVsC0=" ~ dispVsC0.to!string
        ~ " dispVsC1=" ~ dispVsC1.to!string);

    // Gesture 2 (SAME bank, same shared gizmo): the published display ACCUMULATES
    // (run-absolute, stable in the frozen gizmo frame) — past gesture 1 alone.
    localFwdGesture(floor + 2);
    assert(undoCount() == floor + 2, "gesture 2 records a second in-session entry");
    Vec3 pubG2 = publishedTranslate();
    double pubMagG2 = sqrt(dot(pubG2, pubG2));
    assert(pubMagG2 > pubMagG1 + 1e-2,
        "acen=local multi-cluster: the published run-absolute display ACCUMULATES "
        ~ "across gestures (gizmo frame), |g1|=" ~ pubMagG1.to!string
        ~ " |g2|=" ~ pubMagG2.to!string);

    // GEOMETRY stayed per-cluster-correct after gesture 2 (clusters still diverge
    // in world space, still uniform in basis-local scalar).
    auto afterG2 = dumpVerts();
    Vec3[2] meanG2 = clMean(pre, afterG2);
    assert(meanG2[0].y * meanG2[1].y < 0,
        "after gesture 2 the clusters STILL diverge in world space (per-cluster "
        ~ "geometry unchanged by the run-absolute display flip)");
    double s0G2 = dot(meanG2[0], normalize(ci.fwd[0]));
    double s1G2 = dot(meanG2[1], normalize(ci.fwd[1]));
    assert(fabs(fabs(s0G2) - fabs(s1G2)) < 5e-2,
        "after gesture 2 the per-cluster basis-local scalar is STILL uniform");

    cmd("tool.set move off");
    drainHistory();
}

// ===========================================================================
// (c) FROZEN FRAME — no drift under acen=local across gestures (SDK-#3).
//
// The run-frame is captured ONCE at the run's first applyTRS and NEVER re-derived.
// Under acen=local, `currentBasis` re-derives the gizmo basis every frame; a
// per-frame read would let the run-absolute DISPLAY drift as the basis wobbles
// between gestures. We assert: across two same-bank gestures under acen=local the
// published run-frame is BYTE-STABLE (same origin/right/up/fwd) — it is the
// frozen frame, not re-derived. A re-derived frame (the pre-SDK-#3 bug) would let
// the run-absolute components shift basis between gestures, drifting the display.
// ===========================================================================
unittest {
    auto ci = setupLocalMoveScene();
    long floor = undoCount();

    localFwdGesture(floor + 1);
    assert(undoCount() == floor + 1, "gesture 1 records one entry");
    RunFrame rf1 = publishedRunFrame();
    assert(rf1.valid, "the run-frame is captured after the first applyTRS");
    Vec3 pubG1 = publishedTranslate();

    localFwdGesture(floor + 2);
    assert(undoCount() == floor + 2, "gesture 2 records a second entry");
    RunFrame rf2 = publishedRunFrame();
    Vec3 pubG2 = publishedTranslate();

    // FROZEN: the run-frame is identical across the two gestures (NOT re-derived).
    bool frameStable(Vec3 a, Vec3 b) {
        return fabs(a.x-b.x) < 1e-4 && fabs(a.y-b.y) < 1e-4 && fabs(a.z-b.z) < 1e-4;
    }
    assert(frameStable(rf1.origin, rf2.origin),
        "SDK-#3: the run-frame ORIGIN is frozen across gestures (not re-derived); "
        ~ "g1=(" ~ rf1.origin.x.to!string ~ "," ~ rf1.origin.y.to!string ~ ","
        ~ rf1.origin.z.to!string ~ ") g2=(" ~ rf2.origin.x.to!string ~ ","
        ~ rf2.origin.y.to!string ~ "," ~ rf2.origin.z.to!string ~ ")");
    assert(frameStable(rf1.right, rf2.right)
        && frameStable(rf1.up, rf2.up)
        && frameStable(rf1.fwd, rf2.fwd),
        "SDK-#3: the run-frame R/U/F axes are frozen across gestures (not "
        ~ "re-derived per frame under acen=local)");

    // CONSEQUENCE: the run-absolute display advanced COHERENTLY along the frozen
    // frame (colinear, accumulated) — it did NOT drift to a re-derived basis. A
    // re-derived frame would let pubG2 swing off pubG1's axis as the cluster
    // partition / basis wobbled between gestures.
    double colinear = dot(normalize(pubG1), normalize(pubG2));
    assert(colinear > 0.98,
        "the run-absolute TX did NOT drift across gestures (frozen frame, not "
        ~ "re-derived); colinear dot=" ~ colinear.to!string);
    double m1 = sqrt(dot(pubG1, pubG1)), m2 = sqrt(dot(pubG2, pubG2));
    assert(m2 > m1 + 1e-2,
        "the run-absolute TX accumulated (stable frozen frame): |g1|="
        ~ m1.to!string ~ " |g2|=" ~ m2.to!string);

    cmd("tool.set move off");
    drainHistory();
}

// ===========================================================================
// (d) RELOCATE under acen=local resets the field to identity (G8).
//
// A hard geometry-run boundary (selection change) under acen=local calls
// resetRun(), which resets the run-absolute headlessTranslate to 0 while leaving
// the committed gesture geometry put. Display follows the geometry re-baseline.
// ===========================================================================
unittest {
    auto ci = setupLocalMoveScene();
    long floor = undoCount();

    localFwdGesture(floor + 1);
    assert(undoCount() == floor + 1, "the gesture records one in-session entry");
    Vec3 pubBefore = publishedTranslate();
    assert(sqrt(dot(pubBefore, pubBefore)) > 1e-2,
        "the gesture left a run-absolute translate != 0");
    auto afterGesture = dumpVerts();

    // Selection change to a DIFFERENT polygon set = a hard geometry-run boundary
    // (resetRun). Re-selecting the same set would be a no-op. Use a disjoint set.
    auto sel = postJson("/api/select", `{"mode":"polygons","indices":[2,3]}`);
    assert(sel["status"].str == "ok", "relocate-select failed: " ~ sel.toString);
    settle();

    Vec3 pubAfter = publishedTranslate();
    assert(sqrt(dot(pubAfter, pubAfter)) < 2e-2,
        "the run boundary resets the run-absolute translate to identity (G8 "
        ~ "relocate->0) under acen=local; got mag "
        ~ sqrt(dot(pubAfter, pubAfter)).to!string);
    // The committed gesture geometry is untouched by the relocate.
    float keepDiff = maxVertDiff(dumpVerts(), afterGesture);
    assert(keepDiff < 2e-2,
        "the relocate does not move the committed gesture geometry: max per-vert "
        ~ "diff = " ~ keepDiff.to!string);

    cmd("tool.set move off");
    drainHistory();
}
