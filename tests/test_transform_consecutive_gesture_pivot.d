// Consecutive different-type gesture pivot invariant:
//
// In ONE live transform session, a ROTATE gesture followed by a MOVE-handle
// gesture must leave the gizmo pivot at the MOVED position on mouse-up, NOT
// at the stale rotate-gesture pivot.
//
// ROOT CAUSE (pre-fix):
//   Rotate mouse-up sets a display soft pin (ACEN soft-pin) in
//   Auto/None/Screen modes even without falloff — rotate.handler.center stays
//   at the pivot during the gesture, so the pin is the pre-move pivot P.
//   Move mouse-up (without falloff) did NOT update or clear the pin, so the
//   stale P survived. On the next idle update(), computeCenter() returned the
//   stale softPlaced (P), snapping the gizmo from P+Δ back to P.
//
// THE FIX (set-or-keep discipline):
//   Move mouse-up now sets pendingMoveSoftPin when (gestureMoved &&
//   (falloff.enabled || softActive)), where softActive = a prior gesture left
//   a soft pin. This overwrites the stale rotate pin with the moved pivot so
//   the gizmo stays at P+Δ. When NO soft pin is active and no falloff, the
//   predicate stays false — byte-identical with the pre-fix no-falloff path.
//
// Test cases:
//   1. PRIMARY (RED before fix, GREEN after): rotate-view-ring, then
//      move-Y-arrow in ONE session — pivot.y must ≈ the full move delta
//      after the move release, NOT ≈ 0 (the stale rotate pivot).
//   2. ACEN mode verified explicitly via /api/toolpipe/eval so the RED
//      signal is unambiguous (not "assumed none").
//   3. GREEN control: scale→move (no-falloff scale leaves NO soft pin;
//      scale→move was already correct pre-fix; stays GREEN).

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

// Pristine cube + empty selection + empty undo stack.
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

// Published action-center center (the gizmo pivot source of truth).
Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}

bool evalSoftPlaced() {
    return getJson("/api/toolpipe/eval")["actionCenter"]["isSoftPlaced"].type
           == JSONType.true_;
}

// Read the ACEN mode type integer from /api/toolpipe/eval.
// enum Mode { Auto=0, Select=1, SelectAuto=2, Element=3, Local=4,
//             Origin=5, Screen=6, Border=7, Manual=8, None=9 }
// The relocate-permitted modes (Auto/None/Screen) are 0, 9, 6.
int evalAcenType() {
    return cast(int)getJson("/api/toolpipe/eval")["actionCenter"]["type"].integer;
}

bool acenIsRelocatePermitted() {
    int t = evalAcenType();
    return t == 0   // Auto
        || t == 9   // None
        || t == 6;  // Screen
}

// Select all 8 cube verts and drag the view-ring handle by `px` upward pixels.
// Uses the same 95-px-to-the-right sampling as test_acen_softpin_settle.d.
// Returns the settled pivot after mouse-up.
Vec3 dragViewRingAllVerts(int px) {
    auto selResp = postJson("/api/select",
                            `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(selResp["status"].str == "ok", "select-all (ring) failed");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    Vec3 pivot = evalPivot();
    float cx, cy;
    assert(projectToWindow(pivot, vp, cx, cy), "rotate pivot off-camera");

    int x0 = cast(int)(cx + 95);
    int y0 = cast(int)cy;
    int x1 = x0;
    int y1 = y0 - px;

    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 20));
    settle();
    return evalPivot();
}

// Select all 8 cube verts and drag the Y arrow up by `px` window pixels.
// Returns the settled pivot Y after mouse-up (does NOT re-select; caller
// must select before if needed).
double dragYArrowAllVertsFrom(Vec3 piv, int px) {
    // Re-select all so the move arrow is clearly targeted.
    auto selResp = postJson("/api/select",
                            `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(selResp["status"].str == "ok", "select-all (Y drag) failed");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    float size = gizmoSize(piv, vp);
    Vec3 aStart = Vec3(piv.x, piv.y + size / 6.0f, piv.z);
    Vec3 aEnd   = Vec3(piv.x, piv.y + size,         piv.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(aStart, vp, sx1, sy1), "Y-arrow start off-camera");
    assert(projectToWindow(aEnd,   vp, sx2, sy2), "Y-arrow end off-camera");
    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double sdx = sx2 - sx1, sdy = sy2 - sy1;
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    int x1 = x0 + cast(int)(px * sdx / sLen);
    int y1 = y0 + cast(int)(px * sdy / sLen);

    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 20));
    settle();
    return evalPivot().y;
}

// Mean Y of all 8 verts (proxy for the moved-geometry centroid).
double meanVertY() {
    double s = 0;
    foreach (i; 0 .. 8) s += vertexPos(i)[1];
    return s / 8.0;
}

// ---------------------------------------------------------------------------
// PRIMARY assertion — rotate then move in ONE session, pivot follows the move.
//
// This test is RED before the fix (pivot.y ≈ 0, stale rotate soft-pin wins)
// and GREEN after (pivot.y ≈ full move delta, move overwrites the rotate pin).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();

    // Compose Transform: T=on, R=on, S=on in one session so both the rotate
    // ring and the move arrows are live simultaneously.
    postJson("/api/script", "tool.set Transform\n");
    settle();

    // --- Assert the ACEN mode explicitly so the RED signal is unambiguous ---
    // type 9=None, 0=Auto, 5=Screen — the relocate-permitted set.
    assert(acenIsRelocatePermitted(),
        "expected relocate-permitted ACEN mode (None/Auto/Screen), got type: "
        ~ evalAcenType().to!string);

    // --- Gesture 1: rotate view-ring drag (sets a soft pin at pivot ≈ 0) ---
    Vec3 pivAfterRotate = dragViewRingAllVerts(100);
    assert(evalSoftPlaced(),
        "rotate mouse-up must leave a display soft pin (relocate-permitted mode)");
    // The rotate handler.center stays at the pivot (≈ origin for a whole-cube
    // rotate), so the pin is near-zero.
    assert(fabs(pivAfterRotate.y) < 0.15,
        "post-rotate pivot.y should be near the rotate handler.center (≈ 0); "
        ~ "got " ~ pivAfterRotate.y.to!string);

    // --- Gesture 2: move Y arrow drag (STILL IN THE SAME TOOL SESSION) ----
    // Grab the current pivot so Y-arrow projection starts from the right place.
    Vec3 pivBeforeMove = evalPivot();
    double pivAfterMove = dragYArrowAllVertsFrom(pivBeforeMove, 100);

    // After the move geometry has translated, so the mean vert Y captures the
    // full-delta centroid (whole mesh, no falloff → every vert moved equally).
    double movedCentroid = meanVertY();

    // PRIMARY ASSERTION (RED pre-fix, GREEN post-fix):
    // The pivot must track the MOVED centroid, NOT snap back to the stale rotate
    // pin (≈ 0).  Pre-fix: pivAfterMove.y ≈ 0 (stale rotate pin wins).
    assert(pivAfterMove > 0.05,
        "rotate→move: pivot must follow the moved geometry (not snap to stale "
        ~ "rotate pin ≈ 0); pivot.y=" ~ pivAfterMove.to!string);

    // The pivot should sit close to the full-delta moved centroid.
    assert(fabs(pivAfterMove - movedCentroid) < 0.05,
        "rotate→move: pivot.y must ≈ moved-geometry centroid.y; pivot="
        ~ pivAfterMove.to!string ~ " centroid=" ~ movedCentroid.to!string);

    // The move's new soft pin is set (overwriting the rotate pin).
    assert(evalSoftPlaced(),
        "move mouse-up (softActive path) must set a new display soft pin");
}

// ---------------------------------------------------------------------------
// GREEN CONTROL — scale→move: no-falloff scale leaves NO soft pin, so the
// subsequent move is unaffected (already correct pre-fix; must stay green).
// Documents the asymmetry: rotate pins without falloff; scale does not.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();

    // Scale-only preset so only the scale bank renders.
    postJson("/api/script", "tool.set TransformScale\n");
    settle();

    // Confirm ACEN mode is relocate-permitted.
    assert(acenIsRelocatePermitted(),
        "expected relocate-permitted ACEN mode for scale, got type: "
        ~ evalAcenType().to!string);

    // Scale gesture: drag diagonally to grow the cube.  The scale handler does
    // NOT set a soft pin without falloff (scale's settle is falloff-only).
    auto selResp = postJson("/api/select",
                            `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(selResp["status"].str == "ok", "select-all (scale) failed");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 piv = evalPivot();
    float cx, cy;
    assert(projectToWindow(piv, vp, cx, cy), "scale pivot off-camera");
    // Drag an arbitrary direction to trigger a scale gesture.
    int x0 = cast(int)(cx + 60); int y0 = cast(int)(cy - 60);
    int x1 = x0 + 50;            int y1 = y0 - 50;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 20));
    settle();

    // No-falloff scale must NOT set a soft pin.
    assert(!evalSoftPlaced(),
        "no-falloff scale must NOT set a display soft pin "
        ~ "(scale settle is falloff-only; scale→move was already correct)");

    // Now switch to a move tool and drag Y.
    postJson("/api/script", "tool.set move\n");
    settle();

    Vec3 pivBeforeMove = evalPivot();
    double pivAfterMove = dragYArrowAllVertsFrom(pivBeforeMove, 100);
    double movedCentroid = meanVertY();

    // The move pivot should track the (now larger) cube's centroid cleanly —
    // no stale scale pin to fight.
    assert(pivAfterMove > 0.05,
        "scale→move (GREEN control): pivot must follow the move; got "
        ~ pivAfterMove.to!string);
    assert(fabs(pivAfterMove - movedCentroid) < 0.05,
        "scale→move (GREEN control): pivot.y must ≈ moved centroid.y; pivot="
        ~ pivAfterMove.to!string ~ " centroid=" ~ movedCentroid.to!string);
}
