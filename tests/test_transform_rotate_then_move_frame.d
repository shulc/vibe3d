// test_transform_rotate_then_move_frame.d
// Task 0032: translate-basis de-rotation for rotate-then-move geometry alignment.
// Plan: doc/transform_rotate_then_move_frame_plan.md
//
// RED test (Stage 0): the primary bug unittest demonstrates the divergence
// (cos of geometry delta vs world delta ≈ 0.29 pre-fix for scenario (a)).
// After Stage 1 (applyFold translate-basis de-rotation), all assertions become
// GREEN (cos > 0.99). The two control unittests pass both before and after.
//
// Bug summary: in ONE Transform session (falloff OFF, default Auto/None ACEN),
// rotate then move → committed geometry translates by run.r · worldDelta (the
// held rotation applied to the cursor delta), while the move handle/arrows stay
// world-aligned. The geometry detaches from the handle by the held angle.
//
// Fix (applyFold): build a TRANSLATE-ONLY de-rotated triple
//   tdX/tdY/tdZ = run.rᵀ · inputBasis
// where inputBasis = frame.valid ? frame.axes : runFrame, passed to
// composeFor's translate axes. sX=tX (scale) is UNCHANGED.
//
// OUT OF SCOPE: ACEN=Element rotate→move is intentionally NOT asserted with
// cos > 0.99. Element never settles a frame (frame.valid stays false) and the
// move projects onto a live, per-frame-drifting element basis, so a residual
// skew predates this fix. The de-rotation strictly improves Element (removes
// the dominant run.r term) but cannot make it exact — closing that is a
// separate task. The cases here cover the world-input bug + scale isolation.

import std.net.curl;
import std.json;
import std.math   : fabs, sqrt, PI;
import std.conv   : to;
import std.format : format;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(120.msecs);
}

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

void drainHistory() {
    foreach (_; 0 .. 100) {
        if (undoCount() == 0) return;
        postJson("/api/undo", "");
    }
}

void clearHistory() {
    auto r = postJson("/api/command", "history.clear");
    assert(r["status"].str == "ok", "history.clear failed: " ~ r.toString);
}

void establishCubeBaseline() {
    import core.thread : Thread;
    import core.time   : msecs;
    bool playerIdle() {
        auto s = getJson("/api/play-events/status");
        auto f = "finished" in s;
        return f is null || f.type != JSONType.false_;
    }
    bool cubePristine() {
        auto v = getJson("/api/model")["vertices"].array;
        if (v.length != 8) return false;
        auto c = v[6].array;
        return fabs(c[0].floating - 0.5) < 1e-3
            && fabs(c[1].floating - 0.5) < 1e-3
            && fabs(c[2].floating - 0.5) < 1e-3;
    }
    bool selectionPristine() {
        auto s = getJson("/api/selection");
        return s["mode"].str == "vertices"
            && s["selectedVertices"].array.length == 0
            && s["selectedEdges"].array.length == 0
            && s["selectedFaces"].array.length == 0;
    }
    foreach (attempt; 0 .. 8) {
        postJson("/api/script", "tool.set move off");
        foreach (_; 0 .. 200) {
            if (playerIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        drainHistory();
        postJson("/api/reset", "");
        postJson("/api/select", `{"mode":"vertices","indices":[]}`);
        clearHistory();
        if (cubePristine() && selectionPristine()) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"vertices","indices":[]}`);
    clearHistory();
    assert(cubePristine() && selectionPristine(),
        "could not establish pristine cube baseline");
}

Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}

int evalAcenType() {
    return cast(int)getJson("/api/toolpipe/eval")["actionCenter"]["type"].integer;
}

bool acenIsRelocatePermitted() {
    int t = evalAcenType();
    return t == 0   // Auto
        || t == 9   // None
        || t == 6;  // Screen
}

Vec3 readVert6() {
    auto v = getJson("/api/model")["vertices"].array[6].array;
    return Vec3(cast(float)v[0].floating,
                cast(float)v[1].floating,
                cast(float)v[2].floating);
}

float cosAngle(Vec3 a, Vec3 b) {
    float la = sqrt(a.x*a.x + a.y*a.y + a.z*a.z);
    float lb = sqrt(b.x*b.x + b.y*b.y + b.z*b.z);
    if (la < 1e-9f || lb < 1e-9f) return 0.0f;
    return (a.x*b.x + a.y*b.y + a.z*b.z) / (la * lb);
}

// Drag the view-ring for a single selected vertex (index 6).
// Click 95px to the right of the projected pivot center, drag `upPx` upward.
// Returns the pivot position after mouse-up.
Vec3 dragViewRingSingleVert6(int upPx) {
    auto selResp = postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    assert(selResp["status"].str == "ok", "select vert6 (ring) failed");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 pivot = evalPivot();
    float cx, cy;
    assert(projectToWindow(pivot, vp, cx, cy), "rotate pivot off-camera");

    int x0 = cast(int)(cx + 95);
    int y0 = cast(int)cy;
    int x1 = x0;
    int y1 = y0 - upPx;

    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 20));
    settle();
    return evalPivot();
}

// Drag the X-arrow from the given pivot by `px` pixels along the arrow's
// screen-space direction. Returns (pivotBefore, pivotAfter) so the caller can
// derive the world-space handle direction.
void dragXArrowSingleVert6(Vec3 piv, int px,
                            out Vec3 pivotBefore, out Vec3 pivotAfter) {
    auto selResp = postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    assert(selResp["status"].str == "ok", "select vert6 (X drag) failed");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // Project the X-arrow: pivot + gizmoSize*0.5*(1,0,0) → mid,
    //                       pivot + gizmoSize*(1,0,0)     → tip.
    float size = gizmoSize(piv, vp);
    Vec3 aMid = Vec3(piv.x + size * 0.5f, piv.y, piv.z);
    Vec3 aTip = Vec3(piv.x + size,         piv.y, piv.z);
    float mx, my, tx, ty;
    assert(projectToWindow(aMid, vp, mx, my), "X-arrow mid off-camera");
    assert(projectToWindow(aTip, vp, tx, ty), "X-arrow tip off-camera");

    // Click at 70% from mid toward tip; drag `px` pixels along the arrow dir.
    float dx = tx - mx, dy = ty - my;
    float dLen = sqrt(dx*dx + dy*dy);
    if (dLen < 1.0f) dLen = 1.0f;
    int x0 = cast(int)(mx + 0.7f * dx);
    int y0 = cast(int)(my + 0.7f * dy);
    int x1 = x0 + cast(int)(px * dx / dLen);
    int y1 = y0 + cast(int)(px * dy / dLen);

    pivotBefore = evalPivot();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 20));
    settle();
    pivotAfter = evalPivot();
}

// ---------------------------------------------------------------------------
// PRIMARY (RED pre-fix, GREEN post-fix):
// Scenario (a): view-ring rotate on a single off-axis vertex, then X-arrow move
// in the SAME session. The geometry delta must be COLLINEAR with the handle's
// world-X direction (cos > 0.99).
//
// Pre-fix: cos ≈ 0.29 (~73° off) because applyFold builds
//   M = run.r · T(worldDelta) → net translate = run.r · worldDelta.
// Post-fix: applyFold de-rotates the translate basis:
//   tdX = run.rᵀ · inputBasis → M = run.r · T(run.rᵀ · worldDelta) = T(worldDelta).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();

    postJson("/api/script", "tool.set Transform\n");
    settle();

    assert(acenIsRelocatePermitted(),
        "expected relocate-permitted ACEN (Auto/None/Screen), got type: "
        ~ evalAcenType().to!string);

    // Gesture 1: view-ring rotate on vertex 6 only.
    // The view-ring drag (95px right, 60px up) creates a non-trivial rotation.
    // With a single off-axis vert the centroid = vert position, so pivot ≈ vert.
    dragViewRingSingleVert6(60);
    Vec3 p0AfterRot = readVert6();

    // Gesture 2 (SAME session): X-arrow move.
    Vec3 pivBefore, pivAfter;
    dragXArrowSingleVert6(p0AfterRot, 80, pivBefore, pivAfter);
    Vec3 pAfterMove = readVert6();

    Vec3 geomDelta  = pAfterMove - p0AfterRot;
    Vec3 worldDelta = pivAfter   - pivBefore;   // handle direction (world-X ≈)

    float c = cosAngle(geomDelta, worldDelta);

    // Pre-fix cos ≈ 0.29 — this assertion is RED before the Stage 1 fix.
    // After the fix cos ≈ 1 (geometry tracks the handle exactly).
    assert(c > 0.99f,
        "rotate→move-X: geometry delta must be collinear with handle (cos>0.99);"
        ~ " got cos=" ~ c.to!string
        ~ " geomDelta=(" ~ geomDelta.x.to!string ~ "," ~ geomDelta.y.to!string ~ "," ~ geomDelta.z.to!string ~ ")"
        ~ " worldDelta=(" ~ worldDelta.x.to!string ~ "," ~ worldDelta.y.to!string ~ "," ~ worldDelta.z.to!string ~ ")");
}

// ---------------------------------------------------------------------------
// GREEN CONTROL — pure move-X with NO prior rotate: cos must already be ≈ 1.
// Verifies the assertion is not vacuously true and that a fresh move is
// byte-identical to the pre-fix path (run.r == I → de-rotation is a no-op).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();

    postJson("/api/script", "tool.set Transform\n");
    settle();

    auto selResp = postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    assert(selResp["status"].str == "ok", "select vert6 (pure-move control) failed");

    Vec3 p0 = readVert6();

    Vec3 pivBefore, pivAfter;
    dragXArrowSingleVert6(evalPivot(), 80, pivBefore, pivAfter);
    Vec3 pAfterMove = readVert6();

    Vec3 geomDelta  = pAfterMove - p0;
    Vec3 worldDelta = pivAfter   - pivBefore;

    float c = cosAngle(geomDelta, worldDelta);
    assert(c > 0.99f,
        "pure move-X (no prior rotate): cos must be ≈ 1 even pre-fix;"
        ~ " got cos=" ~ c.to!string);
}

// ---------------------------------------------------------------------------
// BLOCKER-2 CONTROL — pure scale (fresh session): scale basis must be correct.
//
// The fix introduces tdX/tdY/tdZ as a SEPARATE translate-only triple; it does
// not touch tX/tY/tZ, so sX=tX (scale capture at applyFold:4624) is unchanged.
// This control runs a Scale-only gesture on all 8 verts and checks that the
// centroid vertex (index 6 at 0.5,0.5,0.5 — offset from origin) moves FURTHER
// from origin after a uniform-grow drag. The fix must leave this byte-identical
// to the pre-fix behavior (de-rotation gate: flagR && !runRotIsIdentity() does
// NOT fire for a pure scale run with no rotation held → tdX=tX, no-op).
// Intra-session rotate→scale coverage: sX=tX reads the UNMODIFIED tX/tY/tZ
// regardless of tdX/tdY/tdZ, so the scale basis is byte-stable post-fix.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();

    // Scale-only preset, all 8 verts selected so pivot = centroid = origin.
    postJson("/api/script", "tool.set TransformScale\n");
    settle();
    auto selResp = postJson("/api/select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(selResp["status"].str == "ok", "select-all (scale control) failed");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 piv = evalPivot();   // origin ≈ (0,0,0) for full-cube selection

    // Distance of vertex 6 from origin before scale.
    Vec3 pBefore = readVert6();
    float distBefore = sqrt(pBefore.x*pBefore.x
                          + pBefore.y*pBefore.y
                          + pBefore.z*pBefore.z);

    // Project the pivot (≈ origin) and click on the uniform-scale disc.
    // The uniform scale disc is in the center of the gizmo; dragging the mouse
    // radially outward from the pivot grows the mesh. We project the pivot and
    // click 30px off in screen space, then drag another 60px outward.
    float cx, cy;
    assert(projectToWindow(piv, vp, cx, cy), "scale pivot off-camera");
    int x0 = cast(int)(cx + 30); int y0 = cast(int)cy;
    int x1 = x0 + 80;            int y1 = y0;

    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 20));
    settle();

    Vec3 pAfterScale = readVert6();
    float distAfter = sqrt(pAfterScale.x*pAfterScale.x
                         + pAfterScale.y*pAfterScale.y
                         + pAfterScale.z*pAfterScale.z);

    // Scale grew the mesh: vertex moved FURTHER from origin.
    assert(distAfter > distBefore + 0.01f,
        "scale-only (BLOCKER-2 control): vertex should move further from origin;"
        ~ " distBefore=" ~ distBefore.to!string
        ~ " distAfter=" ~ distAfter.to!string);
}
