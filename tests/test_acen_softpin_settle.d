// BUG-1 regression — Move gizmo settles at the FULL-delta pivot on mouse-up,
// with OR without falloff (the display soft-pin).
//
// THE BUG: during a Move drag the gizmo follows the FULL drag delta
// (center + worldStep, every motion frame). On mouse-up the active drag
// clears, so the wrapper's update()/draw() recompute the gizmo pose from the
// published action center → ActionCenterStage.computeCenter. In the recompute
// modes (Auto / None / Screen) with no userPlaced pin that returns
// centroidWithGeometryFallback() — the WEIGHTED moving-set bbox-center under
// falloff. With falloff the gizmo therefore SNAPPED BACK toward the original
// pivot at mouse-up, even though every reference editor keeps the Move gizmo at
// the settled full-delta position whether or not falloff is active.
//
// THE FIX (display soft-pin, variant b): on Move mouse-up the wrapper records
// the settled handler.center as a DISPLAY soft-pin on the ACEN stage
// (notifyAcenSoftPlaced → setSoftPlaced), gated to the relocate-allowed modes
// (Auto/None/Screen) — the exact set where the snap-back occurs. computeCenter
// then returns the soft pin instead of the weighted centroid. The soft pin is
// DELIBERATELY separate from userPlaced / the relocate snapshot machinery, so
// the relocate boundary / cross-slot commit / element-pick are untouched (see
// test_relocate_boundary*.d, which must stay green).
//
// What this pins:
//   1. No-falloff control: after a Y drag the settled pivot.y == the full delta
//      (== the moving-set centroid, exactly as today — byte-identical baseline).
//   2. Falloff: after the SAME Y drag the settled pivot.y still == the full
//      delta (NOT the small weighted centroid it returned before the fix).
//   3. Lifetime — new selection CLEARS the soft pin: after a falloff settle,
//      selecting a different vertex set recomputes the center to the new
//      selection's centroid (the settle does not stick across selections).
//   4. Lifetime — same-run stickiness: a 2nd same-run gesture starts from the
//      settled pin (sticky), so two consecutive +Y drags accumulate the pivot.
//
// All gestures drive the MAIN loop via drag_helpers.buildDragLog +
// /api/play-events (the production drag path), so the soft pin is set through
// the real wrapper mouse-up, not a synthetic attr write.

import std.net.curl;
import std.json;
import std.math   : fabs, sqrt;
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
    Thread.sleep(120.msecs);   // post-playback drain settle (status reports
                               // "finished" once events are POSTED, not processed)
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

// Pristine cube + empty selection + empty undo stack. /api/reset is itself
// undoable, so do not drain history after it; that can undo our own reset and
// restore a prior test's dirty mesh/selection.
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
        auto c = v[6].array;   // startup cube v6 = (0.5, 0.5, 0.5)
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

// The published action-center center (the gizmo pivot source of truth).
Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}

// ACEN pin introspection (surfaced on /api/toolpipe/eval actionCenter): the
// display soft-pin flag and the explicit-relocate userPlaced flag.
bool evalSoftPlaced() {
    return getJson("/api/toolpipe/eval")["actionCenter"]["isSoftPlaced"].type
           == JSONType.true_;
}
bool evalUserPlaced() {
    return getJson("/api/toolpipe/eval")["actionCenter"]["isUserPlaced"].type
           == JSONType.true_;
}

// SDL Ctrl+Z keystroke -> handleKeyDown -> navHistory(true). 122='z', mod 64 =
// KMOD_LCTRL. Played WHILE the Move tool is still live (no /api/undo) so it
// runs the in-session undo path — the exact path that strands the soft pin.
string ctrlZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n",
        t, t + 10.0);
}
// SDL Ctrl+Shift+Z keystroke -> navHistory(false) (redo). mod 65 = KMOD_LCTRL|
// KMOD_LSHIFT.
string ctrlShiftZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":65,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":65,"repeat":0}` ~ "\n",
        t, t + 10.0);
}

// Select all 8 cube verts (whole-mesh moving set, ACEN.Auto pivot = origin),
// then drag the Y arrow up by `px` window pixels and wait for the settle.
// Returns the settled pivot Y after mouse-up.
double dragYArrowAllVerts(int px) {
    auto selResp = postJson("/api/select",
                            `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(selResp["status"].str == "ok", "select-all failed");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    Vec3 pivot = evalPivot();           // ACEN.Auto, whole cube ⇒ ~origin
    float size = gizmoSize(pivot, vp);
    Vec3 aStart = Vec3(pivot.x, pivot.y + size / 6.0f, pivot.z);
    Vec3 aEnd   = Vec3(pivot.x, pivot.y + size,         pivot.z);
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

Vec3 dragViewRingAllVerts(int px) {
    auto selResp = postJson("/api/select",
                            `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(selResp["status"].str == "ok", "select-all failed");

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

void makeAsymmetricCube() {
    auto r = postJson("/api/command",
        "mesh.move_vertex from:{0.5,0.5,0.5} to:{1.25,0.5,0.2}");
    assert(r["status"].str == "ok", "asymmetry move_vertex failed: " ~ r.toString);
}

// Mean Y of all 8 verts — a proxy for the WEIGHTED moving-set centroid the old
// computeCenter returned on mouse-up under falloff (the snap-back value).
double meanVertY() {
    double s = 0;
    foreach (i; 0 .. 8) s += vertexPos(i)[1];
    return s / 8.0;
}

// ---------------------------------------------------------------------------
// Rotate sibling: falloff-weighted rotate must keep the ring pivot fixed after
// mouse-up. The rotate handler center does not move during the gesture; without
// a display soft-pin, the next idle action-center recompute can jump to the
// post-rotate weighted bbox center.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    makeAsymmetricCube();
    postJson("/api/script", "tool.set TransformRotate\n");

    Vec3 pivBefore = evalPivot();
    Vec3 pivAfter  = dragViewRingAllVerts(100);

    assert(evalSoftPlaced(),
        "Rotate mouse-up must set a display soft pin even without falloff; "
        ~ "asymmetric bbox centers are angle-dependent");
    assert(fabs(pivAfter.x - pivBefore.x) < 1e-3 &&
           fabs(pivAfter.y - pivBefore.y) < 1e-3 &&
           fabs(pivAfter.z - pivBefore.z) < 1e-3,
        "Rotate must keep the published pivot at the gesture center on an "
        ~ "asymmetric no-falloff mesh; before=("
        ~ pivBefore.x.to!string ~ "," ~ pivBefore.y.to!string ~ ","
        ~ pivBefore.z.to!string ~ ") after=("
        ~ pivAfter.x.to!string ~ "," ~ pivAfter.y.to!string ~ ","
        ~ pivAfter.z.to!string ~ ")");
}

unittest {
    establishCubeBaseline();
    postJson("/api/script",
        "tool.set TransformRotate\n" ~
        "tool.pipe.attr falloff type radial\n" ~
        `tool.pipe.attr falloff center "-0.5,-0.5,-0.5"` ~ "\n" ~
        `tool.pipe.attr falloff size "2,2,2"` ~ "\n");

    Vec3 pivBefore = evalPivot();
    Vec3 pivAfter  = dragViewRingAllVerts(100);

    assert(evalSoftPlaced(),
        "falloff Rotate mouse-up must set a display soft pin so the ring pivot "
        ~ "does not jump on the idle action-center recompute");
    assert(fabs(pivAfter.x - pivBefore.x) < 1e-3 &&
           fabs(pivAfter.y - pivBefore.y) < 1e-3 &&
           fabs(pivAfter.z - pivBefore.z) < 1e-3,
        "falloff Rotate must keep the published pivot at the gesture center; "
        ~ "before=(" ~ pivBefore.x.to!string ~ "," ~ pivBefore.y.to!string
        ~ "," ~ pivBefore.z.to!string ~ ") after=("
           ~ pivAfter.x.to!string ~ "," ~ pivAfter.y.to!string ~ ","
           ~ pivAfter.z.to!string ~ ")");
}

unittest {
    establishCubeBaseline();
    postJson("/api/script",
        "tool.set TransformRotate\n" ~
        "tool.pipe.attr falloff type radial\n" ~
        `tool.pipe.attr falloff center "-0.5,-0.5,-0.5"` ~ "\n" ~
        `tool.pipe.attr falloff size "2,2,2"` ~ "\n");

    Vec3 pivBefore = evalPivot();
    auto r = postJson("/api/script?interactive=true",
        "tool.attr TransformRotate RY 45\n");
    assert(r["status"].str == "ok",
        "interactive rotate property edit failed: " ~ r.toString);
    settle();
    Vec3 pivAfter = evalPivot();

    assert(evalSoftPlaced(),
        "falloff Rotate property edit must publish the matrix pivot as a display "
        ~ "soft pin, matching the handle path");
    assert(fabs(pivAfter.x - pivBefore.x) < 1e-3 &&
           fabs(pivAfter.y - pivBefore.y) < 1e-3 &&
           fabs(pivAfter.z - pivBefore.z) < 1e-3,
        "falloff Rotate property edit must keep the published pivot fixed; "
        ~ "before=(" ~ pivBefore.x.to!string ~ "," ~ pivBefore.y.to!string
        ~ "," ~ pivBefore.z.to!string ~ ") after=("
        ~ pivAfter.x.to!string ~ "," ~ pivAfter.y.to!string ~ ","
        ~ pivAfter.z.to!string ~ ")");
}

// ---------------------------------------------------------------------------
// Core BUG-1: no-falloff vs falloff — both settle at the FULL-delta pivot.
// ---------------------------------------------------------------------------
unittest {
    // --- No-falloff control: full-delta settle (today's behaviour) ----------
    establishCubeBaseline();
    postJson("/api/script", "tool.set move");   // ACEN default mode, relocate-allowed
    double pivotNoFalloff = dragYArrowAllVerts(100);
    double meanNoFalloff  = meanVertY();
    // Without falloff every vert moves by the full delta, so the centroid (the
    // computeCenter fallback) already equals the settled pivot — the soft pin
    // is a NO-OP here (byte-identical baseline). Pivot tracks the full delta.
    assert(pivotNoFalloff > 0.2,
        "no-falloff Y drag should lift the pivot well off origin; got "
        ~ pivotNoFalloff.to!string);
    assert(fabs(pivotNoFalloff - meanNoFalloff) < 1e-3,
        "no-falloff: pivot.y must equal the moving-set centroid.y (unchanged "
        ~ "fallback); pivot=" ~ pivotNoFalloff.to!string
        ~ " centroid=" ~ meanNoFalloff.to!string);

    // --- Falloff: SAME drag, soft pin keeps the full-delta settle -----------
    establishCubeBaseline();
    postJson("/api/script",
        "tool.set move\n" ~
        "tool.pipe.attr falloff type radial\n" ~
        `tool.pipe.attr falloff center "-0.5,-0.5,-0.5"` ~ "\n" ~
        `tool.pipe.attr falloff size "2,2,2"` ~ "\n");
    double pivotFalloff = dragYArrowAllVerts(100);
    double meanFalloff  = meanVertY();   // the WEIGHTED centroid (snap-back value)

    // The weighted centroid is MUCH smaller than the full delta (most verts are
    // damped) — this is the value the gizmo snapped back to before the fix.
    assert(meanFalloff < pivotNoFalloff * 0.5,
        "precondition: radial falloff should damp the centroid well below the "
        ~ "full delta; centroid=" ~ meanFalloff.to!string
        ~ " fullDelta=" ~ pivotNoFalloff.to!string);

    // THE FIX: the settled pivot tracks the FULL delta (soft pin = handler
    // center), NOT the weighted centroid. It matches the no-falloff settle.
    assert(fabs(pivotFalloff - pivotNoFalloff) < 0.05,
        "falloff settle must match the no-falloff full-delta pivot (display "
        ~ "soft-pin); falloff pivot=" ~ pivotFalloff.to!string
        ~ " no-falloff pivot=" ~ pivotNoFalloff.to!string);
    // And it is clearly NOT the weighted centroid (the pre-fix snap-back).
    assert(pivotFalloff > meanFalloff + 0.1,
        "falloff settle must NOT snap back to the weighted centroid; pivot="
        ~ pivotFalloff.to!string ~ " weightedCentroid=" ~ meanFalloff.to!string);
}

// ---------------------------------------------------------------------------
// Lifetime: a NEW selection clears the soft pin — the center recomputes to the
// new selection's centroid (the settle does NOT stick across a selection).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    postJson("/api/script",
        "tool.set move\n" ~
        "tool.pipe.attr falloff type radial\n" ~
        `tool.pipe.attr falloff center "-0.5,-0.5,-0.5"` ~ "\n" ~
        `tool.pipe.attr falloff size "2,2,2"` ~ "\n");
    double pivotSettled = dragYArrowAllVerts(100);
    assert(pivotSettled > 0.2, "precondition: a soft pin was settled off origin");

    // Select ONLY the top face's verts (v2,v3,v6,v7 — the y=+something corners
    // after the drag). The soft pin must be CLEARED so the center recomputes to
    // THIS selection's centroid, NOT the prior whole-mesh settle.
    postJson("/api/select", `{"mode":"vertices","indices":[4]}`);  // single vert
    settle();
    Vec3 piv = evalPivot();
    // The new selection is one vertex; the recomputed center sits AT that vert,
    // which differs from the prior whole-mesh settled pin.
    double v4y = vertexPos(4)[1];
    assert(fabs(piv.y - v4y) < 1e-3,
        "new single-vert selection must recompute the center to that vert "
        ~ "(soft pin cleared); pivot.y=" ~ piv.y.to!string
        ~ " v4.y=" ~ v4y.to!string);
    assert(fabs(piv.y - pivotSettled) > 0.05,
        "the recomputed center must DIFFER from the prior whole-mesh settle "
        ~ "(soft pin was cleared on the selection change); pivot.y="
        ~ piv.y.to!string ~ " priorSettle=" ~ pivotSettled.to!string);
}

// ---------------------------------------------------------------------------
// Lifetime: same-run stickiness — a 2nd consecutive gesture starts from the
// settled pin, so two +Y drags accumulate the pivot (no reselection between).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    postJson("/api/script",
        "tool.set move\n" ~
        "tool.pipe.attr falloff type radial\n" ~
        `tool.pipe.attr falloff center "-0.5,-0.5,-0.5"` ~ "\n" ~
        `tool.pipe.attr falloff size "2,2,2"` ~ "\n");

    // Gesture 1: select all + drag up → settle at pivot1.
    double pivot1 = dragYArrowAllVerts(100);
    assert(pivot1 > 0.2, "gesture 1 should settle the pivot off origin; got "
        ~ pivot1.to!string);

    // Gesture 2: WITHOUT reselecting, drag the Y arrow up AGAIN. The gizmo must
    // start from the settled pin (sticky soft pin), so the 2nd grab projects the
    // arrow from pivot1's height and the pivot climbs further. (A regression
    // where the soft pin was dropped between gestures would restart gesture 2
    // from the snapped-back weighted centroid, far below pivot1.)
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 piv = evalPivot();
    assert(fabs(piv.y - pivot1) < 1e-3,
        "between gestures (no reselection) the pivot must STAY at the gesture-1 "
        ~ "settle (sticky soft pin); pivot.y=" ~ piv.y.to!string
        ~ " pivot1=" ~ pivot1.to!string);

    float size = gizmoSize(piv, vp);
    Vec3 aStart = Vec3(piv.x, piv.y + size / 6.0f, piv.z);
    Vec3 aEnd   = Vec3(piv.x, piv.y + size,         piv.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(aStart, vp, sx1, sy1), "g2 Y-arrow start off-camera");
    assert(projectToWindow(aEnd,   vp, sx2, sy2), "g2 Y-arrow end off-camera");
    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double sdx = sx2 - sx1, sdy = sy2 - sy1;
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    int x1 = x0 + cast(int)(100 * sdx / sLen);
    int y1 = y0 + cast(int)(100 * sdy / sLen);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 20));
    settle();
    double pivot2 = evalPivot().y;
    assert(pivot2 > pivot1 + 0.1,
        "gesture 2 (sticky soft pin) must climb the pivot further than gesture "
        ~ "1; pivot2=" ~ pivot2.to!string ~ " pivot1=" ~ pivot1.to!string);
}

// ---------------------------------------------------------------------------
// BUG-2 (reviewer BLOCKER) — IN-SESSION Ctrl+Z must NOT strand the soft pin.
//
// THE PROVEN BUG: a falloff Move drag set a DISPLAY soft pin at mouse-up
// (notifyAcenSoftPlaced fires AFTER commitEdit, so the recorded Move undo hook
// never carried it). An in-session Ctrl+Z then ran the Move revert hook — which
// restored only the userPlaced pin, never the soft pin — and the update() clear
// is skipped on undo (undo bumps mutationVersion but not the selection hash). So
// geometry reverted to pristine while the gizmo pivot STAYED FLOATING at the
// settled height (reviewer probe: pivotSettled.y=0.4438, pivAfterUndo.y=0.4438,
// expected ~0).
//
// THE FIX: the Move commit now carries the gesture-START / gesture-END soft-pin
// endpoints into the same revert/apply closures as the userPlaced pin (capturing
// the gesture-START LIVE at beginEdit — the W1 lesson). Revert restores the
// gesture-START soft state (cleared for gesture-1) so the pivot recomputes to the
// reverted-geometry centroid; redo restores the settled soft pin.
//
// This test MUST FAIL pre-fix (pivot stays at the settled height after undo) and
// pass post-fix (pivot recomputes to ~pristine, then redo restores the settle).
unittest {
    establishCubeBaseline();
    postJson("/api/script",
        "tool.set move\n" ~
        "tool.pipe.attr falloff type radial\n" ~
        `tool.pipe.attr falloff center "-0.5,-0.5,-0.5"` ~ "\n" ~
        `tool.pipe.attr falloff size "2,2,2"` ~ "\n");

    // The pristine whole-cube Auto pivot (~origin) BEFORE any drag — the value
    // an in-session Ctrl+Z must recompute back to once geometry reverts.
    Vec3 pivPristine = evalPivot();

    // Falloff Move drag (tool stays LIVE on mouse-up — in-session).
    double pivotSettled = dragYArrowAllVerts(100);
    assert(pivotSettled > 0.2,
        "precondition: the falloff Move must settle the pivot off origin; got "
        ~ pivotSettled.to!string);
    assert(evalSoftPlaced(),
        "precondition: a display soft pin must be active after the falloff "
        ~ "Move settle");

    // IN-SESSION Ctrl+Z (tool still live, NOT /api/undo) — runs the Move revert
    // hook. Geometry reverts to pristine; the soft pin must be carried back so
    // the pivot RECOMPUTES to the reverted-geometry centroid (~pristine), NOT
    // the stale settled value (the proven BLOCKER).
    playAndWait(ctrlZ(50.0));
    settle();
    Vec3 pivAfterUndo = evalPivot();
    // Geometry actually reverted (the cube top vert is back near pristine).
    assert(fabs(meanVertY() - 0.0) < 0.05,
        "in-session Ctrl+Z should revert the geometry; meanVertY="
        ~ meanVertY().to!string);
    // THE FIX: the pivot recomputes to the reverted centroid — NOT the stale
    // settled height. (Pre-fix this assert FAILS: pivAfterUndo.y == pivotSettled.)
    assert(fabs(pivAfterUndo.y - pivotSettled) > 0.2,
        "in-session Ctrl+Z must NOT leave the gizmo floating at the settled "
        ~ "height (the stranded-soft-pin BLOCKER); pivAfterUndo.y="
        ~ pivAfterUndo.y.to!string ~ " pivotSettled.y="
        ~ pivotSettled.to!string);
    assert(fabs(pivAfterUndo.y - pivPristine.y) < 0.05,
        "in-session Ctrl+Z must recompute the pivot to the reverted-geometry "
        ~ "centroid (~pristine); pivAfterUndo.y=" ~ pivAfterUndo.y.to!string
        ~ " pivPristine.y=" ~ pivPristine.y.to!string);
    assert(!evalSoftPlaced(),
        "the soft pin must be cleared after the in-session undo of gesture-1 "
        ~ "(its gesture-START soft state was unset)");

    // REDO (Ctrl+Shift+Z) re-applies the gesture WITH its apply hook → the
    // settled soft pin returns and the pivot climbs back to the full delta.
    playAndWait(ctrlShiftZ(50.0));
    settle();
    Vec3 pivAfterRedo = evalPivot();
    assert(fabs(pivAfterRedo.y - pivotSettled) < 0.05,
        "redo must restore the settled soft-pin pivot; pivAfterRedo.y="
        ~ pivAfterRedo.y.to!string ~ " pivotSettled.y=" ~ pivotSettled.to!string);
    assert(evalSoftPlaced(),
        "the display soft pin must be re-set after redo");
}

// ---------------------------------------------------------------------------
// BUG-2 sibling — FALLOFF + RELOCATE (the untested combination the warning
// flagged). After a falloff Move settle (soft pin active), an off-gizmo relocate
// click must land the pivot at the click point (userPlaced WINS over softPlaced)
// AND clear the soft pin (setUserPlaced clears it). Proves the soft pin and the
// relocate/userPlaced machinery stay disjoint and compose correctly.
unittest {
    establishCubeBaseline();
    // `move`'s default ACEN mode is None — relocate-permitted (Auto/None/Screen).
    postJson("/api/script",
        "tool.set move\n" ~
        "tool.pipe.attr falloff type radial\n" ~
        `tool.pipe.attr falloff center "-0.5,-0.5,-0.5"` ~ "\n" ~
        `tool.pipe.attr falloff size "2,2,2"` ~ "\n");

    // Falloff Move drag → settle (soft pin active, tool live).
    double pivotSettled = dragYArrowAllVerts(100);
    assert(pivotSettled > 0.2, "precondition: a soft pin was settled off origin");
    assert(evalSoftPlaced(), "precondition: soft pin active after the settle");

    // Off-gizmo relocate click. Project the SETTLED pivot, then click well off
    // every handle (a degenerate 1-step drag = a discrete click). The mouse-DOWN
    // lands off the gizmo → click-relocate in None mode → setUserPlaced.
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 piv = evalPivot();
    float size = gizmoSize(piv, vp);
    // Two on-arrow projections give a screen-space arrow direction; the click is
    // placed perpendicular to it, far enough to clear every handle.
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(Vec3(piv.x, piv.y + size/6.0f, piv.z), vp, sx1, sy1),
        "arrow start off-camera");
    assert(projectToWindow(Vec3(piv.x, piv.y + size, piv.z), vp, sx2, sy2),
        "arrow end off-camera");
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    double ux = dx / len, uy = dy / len;
    int cx = cast(int)(sx1 + 220.0 * uy);   // perpendicular → clearly off-handle
    int cy = cast(int)(sy1 - 220.0 * ux);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cx, cy, cx, cy, 1));
    settle();

    // userPlaced WINS: the pivot is now the click's world projection (an explicit
    // relocate), NOT the prior soft-pin settle. And the soft pin is CLEARED.
    assert(evalUserPlaced(),
        "the off-gizmo relocate click must set userPlaced");
    assert(!evalSoftPlaced(),
        "setUserPlaced (relocate) must CLEAR the display soft pin (userPlaced "
        ~ "supersedes); soft pin still active after relocate");
    Vec3 pivAfterRelocate = evalPivot();
    // userPlaced wins: had the soft pin survived the relocate it would have
    // dominated computeCenter (Auto/None/Screen read softPlaced after userPlaced
    // only if userPlaced is unset), pinning the pivot at the settled value. The
    // pivot instead sits at the relocate's click-projection — clearly off the
    // settle — proving the explicit relocate superseded the display soft pin.
    assert(fabs(pivAfterRelocate.y - pivotSettled) > 0.02,
        "the relocated pivot must DIFFER from the prior soft-pin settle "
        ~ "(userPlaced wins, at the click point); pivAfterRelocate.y="
        ~ pivAfterRelocate.y.to!string ~ " pivotSettled.y="
        ~ pivotSettled.to!string);
}
