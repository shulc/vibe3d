// In-session action-center relocate commits the current undo run (Phase 1a
// of doc/transform_per_gesture_commit_plan.md).
//
// The undo unit is the tool SESSION: consecutive ON-handle gizmo drags
// coalesce into ONE history entry (pinned by test_property_panel_drag.d).
// The ONE additional boundary added here: an off-gizmo click during a live
// session, in a relocate-permitted action-center mode (Auto/None/Screen —
// `move`'s default is None), relocates the gizmo AND commits the current
// run, opening a fresh session for the subsequent drag. So
//   drag -> off-gizmo relocate -> drag -> drop  =>  TWO entries.
//
// Three scenarios:
//  (a) relocate-split count + post-drop Ctrl+Z grammar (2 entries, 2 undos).
//  (b) in-session Ctrl+Z (tool still live) restores geometry AND the pivot
//      to the RELOCATED point (run 2's start), NOT pre-relocate — the
//      restageRelocatePin() correctness pin. A SECOND Ctrl+Z then pops the
//      committed first run and lands on the pre-relocate pivot.
//  (c) W1 regression — TWO on-gizmo gestures WITHIN one userPlaced run (NO
//      boundary between them): per-gesture in-session undo returns the pin to
//      EACH gesture's true start. The Phase-1 pin-revert hook read gesture-START
//      from the FROZEN snapshot (the PRE-relocate pin); for the 2nd+ plain
//      gesture in a run nothing re-stages it, so that value was stale and undo
//      snapped the pin too far back. The fix captures gesture-START from the
//      LIVE pin at beginEdit. This case asserts the ACTUAL pin values at each
//      in-session step (gesture B start == gesture A's sticky-follow end;
//      gesture A start == the relocate point).
//
// All gestures drive the MAIN loop via drag_helpers.buildDragLog +
// /api/play-events (never an /api/command gesture — that races update() /
// navHistory on the background HTTP thread).

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
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

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

// Post-playback / post-command settle: /api/play-events/status reports
// `finished` once events are POSTED to the SDL queue, not processed, and
// /api/undo dispatches on the background HTTP thread; wait ~120ms so the
// main loop has applied the change before reading geometry/pivot.
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

// Establish a pristine cube + (near-)empty undo stack, retrying if a preceding
// test left the shared per-worker vibe3d dirty (the runner reuses ONE vibe3d
// per worker across its whole test slice). Mirrors test_reevaluate.d's proven
// `drainAndReset` discipline; the load-bearing detail is draining the undo
// stack BEFORE the reset, not only after.
//
// Why drain-before-reset matters: /api/reset is recorded on the undo stack
// (SceneReset is undoable, snapshotting the PRE-reset mesh). A preamble that
// only drains AFTER the reset therefore UNDOES its own reset — restoring
// whatever dirty mesh the previous test left (observed under -j4: a 9-vertex
// non-cube mesh surviving all 8 attempts, every reset immediately undone back
// to it). Draining BEFORE the reset pops the previous tool's own commands
// first, so the pre-reset mesh is already clean; the reset then yields a clean
// cube and the after-reset drain pops only the reset (and the select's
// UI-undo entry) back to that clean state. We verify GEOMETRY (v6 == the cube
// corner), not merely the vertex count, and retry — a transient bleed clears,
// a genuine regression would persist (reset always restores the cube).
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
    foreach (attempt; 0 .. 8) {
        // Close any tool the previous test left active (idempotent).
        postJson("/api/script", "tool.set move off");
        // Let a lingering replay drain so its queued mouse events cannot
        // perturb the reset.
        foreach (_; 0 .. 200) {
            if (playerIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        // Drain BEFORE the reset: pop the previous test's own commands so the
        // pre-reset mesh is clean (see header — without this we'd just undo
        // our own reset back to the dirty mesh).
        drainHistory();
        postJson("/api/reset", "");
        // Drain the reset (+ any select UI-undo) so count-delta asserts start
        // from a known floor; the pre-reset mesh is already clean.
        drainHistory();
        if (cubePristine()) return;
        Thread.sleep(20.msecs);
    }
    // Last reset stands (NOT undone) so a genuinely unrestorable prior state
    // still leaves a clean cube for the test's own assertions to run against.
    postJson("/api/reset", "");
    assert(cubePristine(), "could not establish pristine cube baseline");
}

// Authoritative gizmo pivot: /api/toolpipe/eval returns the evaluated
// ActionCenterPacket.center — the exact world point the gizmo renders at.
Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}

double[3] vert(int idx) {
    auto v = getJson("/api/model")["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

// Project the +X arrow handle's grab point (0.7 along the arrow) for the
// gizmo currently anchored at `pivot`, given the live camera viewport.
void arrowGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy) {
    float size = gizmoSize(pivot, vp);
    Vec3 arrowEnd   = Vec3(pivot.x + size,        pivot.y, pivot.z);
    Vec3 arrowStart = Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z);
    float sx1, sy1, sx2, sy2;
    projectToWindow(arrowStart, vp, sx1, sy1);
    projectToWindow(arrowEnd,   vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
}

// Screen-space +X arrow direction (unit), so a drag of N px along +X is
// stable across both drags (the camera is fixed for the gesture).
void arrowDirPx(Vec3 pivot, ref Viewport vp, out double ux, out double uy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size/6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,       pivot.y, pivot.z), vp, sx2, sy2);
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}

// SDL Ctrl+Z keystroke as a play-events log fragment routed to handleKeyDown
// -> navHistory(true). 122 = 'z', 0x0040 = KMOD_LCTRL (canonFromEvent reads
// KMOD_CTRL).
string ctrlZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n",
        t, t + 10.0);
}

// ---------------------------------------------------------------------------
// (a) Move: drag -> off-gizmo relocate -> drag -> drop => TWO undo entries.
//     Ctrl+Z #1 reverts the second run; Ctrl+Z #2 reverts the first + relocate.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    postJson("/api/script", "tool.set move");   // default ACEN mode = None (relocate-permitted)
    long stackBefore = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    double ux, uy;
    arrowDirPx(evalPivot(), vp, ux, uy);

    // Drag 1: grab the +X arrow handle, haul +X by 60px.
    int xa, ya;
    arrowGrabPx(evalPivot(), vp, xa, ya);
    int xb = xa + cast(int)(60.0 * ux);
    int yb = ya + cast(int)(60.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xa, ya, xb, yb, 10));
    settle();

    auto v6AfterRun1 = vert(6);   // displaced by run 1

    // Off-gizmo click well away from the gizmo (relocate). A degenerate
    // 1-step drag (down+up at the same point) is a discrete click; the
    // mouse-DOWN lands off every handle -> click-relocate in None mode.
    int xoff = cast(int)(xb + 220.0 * uy);   // perpendicular to the arrow -> clearly off-handle
    int yoff = cast(int)(yb - 220.0 * ux);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();

    long stackAfterRelocate = undoCount();
    assert(stackAfterRelocate == stackBefore + 1,
        "the relocate click should COMMIT run 1 (one new entry); got " ~
        (stackAfterRelocate - stackBefore).to!string);

    Vec3 relocatedPivot = evalPivot();   // run 2 starts here

    // Drag 2: re-grab the +X arrow handle at the RELOCATED pivot, haul +X.
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    int xc, yc;
    arrowGrabPx(relocatedPivot, vp, xc, yc);
    int xd = xc + cast(int)(60.0 * ux);
    int yd = yc + cast(int)(60.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xc, yc, xd, yd, 10));
    settle();

    auto v6AfterRun2 = vert(6);

    // Drop -> commits run 2.
    postJson("/api/script", "tool.set move off");
    settle();

    long stackAfter = undoCount();
    assert(stackAfter == stackBefore + 2,
        "drag + relocate + drag + drop should produce TWO undo entries; got " ~
        (stackAfter - stackBefore).to!string);

    // Ctrl+Z #1 reverts run 2 only: v6 back to its post-run-1 position.
    postJson("/api/undo", "");
    settle();
    auto v6undo1 = vert(6);
    assert(fabs(v6undo1[0] - v6AfterRun1[0]) < 1e-3 &&
           fabs(v6undo1[1] - v6AfterRun1[1]) < 1e-3 &&
           fabs(v6undo1[2] - v6AfterRun1[2]) < 1e-3,
        "Ctrl+Z #1 should revert only run 2 (back to post-run-1); got (" ~
        v6undo1[0].to!string ~ "," ~ v6undo1[1].to!string ~ "," ~
        v6undo1[2].to!string ~ ") want (" ~
        v6AfterRun1[0].to!string ~ "," ~ v6AfterRun1[1].to!string ~ "," ~
        v6AfterRun1[2].to!string ~ ")");

    // Ctrl+Z #2 reverts run 1: v6 back to the pristine cube corner.
    postJson("/api/undo", "");
    settle();
    auto v6undo2 = vert(6);
    assert(fabs(v6undo2[0] - 0.5) < 1e-3 &&
           fabs(v6undo2[1] - 0.5) < 1e-3 &&
           fabs(v6undo2[2] - 0.5) < 1e-3,
        "Ctrl+Z #2 should revert run 1 (back to cube); got (" ~
        v6undo2[0].to!string ~ "," ~ v6undo2[1].to!string ~ "," ~
        v6undo2[2].to!string ~ ")");
}

// ---------------------------------------------------------------------------
// (b) Move in-session cancel lands on the RELOCATED pin (restageRelocatePin):
//     drag -> off-gizmo relocate -> partial drag -> in-session Ctrl+Z restores
//     geometry to the post-first-run state AND the pivot to the RELOCATED
//     point; a SECOND in-session Ctrl+Z pops committed run 1 and lands on the
//     pre-relocate pivot.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    postJson("/api/script", "tool.set move");
    long stackBefore = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    double ux, uy;
    arrowDirPx(evalPivot(), vp, ux, uy);

    Vec3 prePivot = evalPivot();

    // Drag 1: on-handle +X haul.
    int xa, ya;
    arrowGrabPx(prePivot, vp, xa, ya);
    int xb = xa + cast(int)(60.0 * ux);
    int yb = ya + cast(int)(60.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xa, ya, xb, yb, 10));
    settle();
    auto v6AfterRun1 = vert(6);

    // Off-gizmo relocate.
    int xoff = cast(int)(xb + 220.0 * uy);
    int yoff = cast(int)(yb - 220.0 * ux);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();

    Vec3 relocatedPivot = evalPivot();
    // Sanity: the relocate actually MOVED the pivot away from pre-relocate.
    assert((fabs(relocatedPivot.x - prePivot.x) +
            fabs(relocatedPivot.y - prePivot.y) +
            fabs(relocatedPivot.z - prePivot.z)) > 1e-2,
        "relocate should move the pivot; pre=(" ~
        prePivot.x.to!string ~ "," ~ prePivot.y.to!string ~ "," ~
        prePivot.z.to!string ~ ") reloc=(" ~
        relocatedPivot.x.to!string ~ "," ~ relocatedPivot.y.to!string ~ "," ~
        relocatedPivot.z.to!string ~ ")");

    // Partial drag 2 (do NOT drop — keep the second run OPEN).
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    int xc, yc;
    arrowGrabPx(relocatedPivot, vp, xc, yc);
    int xd = xc + cast(int)(40.0 * ux);
    int yd = yc + cast(int)(40.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xc, yc, xd, yd, 8));
    settle();

    // In-session Ctrl+Z (tool still active, record+consolidate Phase 1): the
    // drag-2 gesture committed its own TAGGED in-session entry on mouse-up, so
    // navHistory does a PLAIN history.undo() that pops that one gesture entry
    // (geometry back to post-run-1) and resyncSession re-baselines the live
    // tool. The pivot stays on the RELOCATED point: the relocate's userPlaced
    // pin was committed PERMANENTLY at the boundary, so reverting drag 2's mesh
    // edit does not move the pin. Same observable as the old whole-run cancel,
    // reached now by per-gesture stepping. (Q-b pin gate: this pin assert must
    // stay green unchanged.)
    playAndWait(ctrlZ(50.0));
    settle();

    auto v6Cancel = vert(6);
    assert(fabs(v6Cancel[0] - v6AfterRun1[0]) < 1e-3 &&
           fabs(v6Cancel[1] - v6AfterRun1[1]) < 1e-3 &&
           fabs(v6Cancel[2] - v6AfterRun1[2]) < 1e-3,
        "in-session Ctrl+Z should restore geometry to post-run-1; got (" ~
        v6Cancel[0].to!string ~ "," ~ v6Cancel[1].to!string ~ "," ~
        v6Cancel[2].to!string ~ ")");

    Vec3 pivotAfterCancel = evalPivot();
    assert(fabs(pivotAfterCancel.x - relocatedPivot.x) < 1e-2 &&
           fabs(pivotAfterCancel.y - relocatedPivot.y) < 1e-2 &&
           fabs(pivotAfterCancel.z - relocatedPivot.z) < 1e-2,
        "the in-session step back should leave the pivot on the RELOCATED " ~
        "point, not pre-relocate; got (" ~
        pivotAfterCancel.x.to!string ~ "," ~ pivotAfterCancel.y.to!string ~
        "," ~ pivotAfterCancel.z.to!string ~ ") want reloc (" ~
        relocatedPivot.x.to!string ~ "," ~ relocatedPivot.y.to!string ~ "," ~
        relocatedPivot.z.to!string ~ ")");

    // A SECOND Ctrl+Z pops committed run 1: GEOMETRY back to the pristine
    // cube. (The relocate's userPlaced pin was committed PERMANENTLY at the
    // boundary — a history pop reverts the mesh edit, not the committed pin —
    // so the gizmo pivot legitimately stays at the relocated point; only run 1
    // first-step-then-pop chain matters for geometry here.)
    playAndWait(ctrlZ(50.0));
    settle();

    auto v6Pop = vert(6);
    assert(fabs(v6Pop[0] - 0.5) < 1e-3 &&
           fabs(v6Pop[1] - 0.5) < 1e-3 &&
           fabs(v6Pop[2] - 0.5) < 1e-3,
        "second Ctrl+Z should pop run 1 (geometry back to cube); got (" ~
        v6Pop[0].to!string ~ "," ~ v6Pop[1].to!string ~ "," ~
        v6Pop[2].to!string ~ ")");
}

// ---------------------------------------------------------------------------
// (c) W1 regression: TWO on-gizmo gestures WITHIN one userPlaced run (NO
//     boundary between them), pin-START per-gesture undo lands on the right
//     point.
//
//     The latent W1 bug: the Move commitEdit pin-revert hook read gesture-START
//     from the FROZEN snapshot (snapPlacedCenter — the PRE-relocate pin staged
//     at the last relocate). For the 2nd+ plain on-gizmo gesture in one
//     userPlaced run there is NO boundary to re-stage it, so that frozen value
//     is STALE: it is NOT the gesture's true start (= the previous gesture's
//     sticky-follow END). An in-session undo of gesture B then snapped the pin
//     too FAR back (to pre-relocate) instead of to gesture A's end. The fix
//     captures gesture-START from the LIVE pin at beginEdit; this test pins it.
//
//     Sequence (tool stays LIVE throughout):
//       relocate-click (pin placed, userPlaced=true) ->
//       drag A (on-handle haul at the relocated pivot; pin sticky-follows to
//               A's end) ->
//       drag B (on-handle RE-GRAB at A's end pivot, same run, NO boundary; pin
//               follows to B's end).
//     Stepping:
//       in-session Ctrl+Z #1 -> reverts gesture B; pin returns to B's START ==
//                 gesture A's sticky-follow END (assert the ACTUAL value);
//       in-session Ctrl+Z #2 -> reverts gesture A; pin returns to A's START ==
//                 the RELOCATE point (gesture A opened from the relocated pin,
//                 captured live at beginEdit; assert that actual value);
//       a further Ctrl+Z pops prior history (the consolidated relocate run).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    // Drain the select's UI-undo entry so the only thing below the open run is
    // the consolidated relocate run (the further Ctrl+Z lands cleanly).
    drainHistory();
    postJson("/api/script", "tool.set move");   // default ACEN = None (relocate-permitted)

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    double ux, uy;
    arrowDirPx(evalPivot(), vp, ux, uy);

    Vec3 prePivot = evalPivot();

    // Off-gizmo relocate FIRST: places the pin (userPlaced=true) so the
    // following gestures sticky-follow it. A degenerate 1-step click well off
    // every handle relocates in None mode. Grab pixels for the off point are
    // derived from the +X arrow grab so it is reliably clear of the gizmo.
    // Retry on the rare load-induced miss (pin did not move) — re-derive the
    // off-point from a fresh camera each attempt.
    int xg, yg;
    arrowGrabPx(prePivot, vp, xg, yg);
    foreach (attempt; 0 .. 4) {
        settle();
        cam = fetchCamera();
        vp  = viewportFromCamera(cam);
        arrowDirPx(evalPivot(), vp, ux, uy);
        arrowGrabPx(evalPivot(), vp, xg, yg);
        int xoff = cast(int)(xg + 220.0 * uy);
        int yoff = cast(int)(yg - 220.0 * ux);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xoff, yoff, xoff, yoff, 1));
        settle();
        auto p = evalPivot();
        if (fabs(p.x - prePivot.x) + fabs(p.y - prePivot.y)
            + fabs(p.z - prePivot.z) > 1e-2) break;
    }

    Vec3 relocatedPivot = evalPivot();   // gesture A's START pin
    assert((fabs(relocatedPivot.x - prePivot.x) +
            fabs(relocatedPivot.y - prePivot.y) +
            fabs(relocatedPivot.z - prePivot.z)) > 1e-2,
        "relocate should move the pivot; pre=(" ~
        prePivot.x.to!string ~ "," ~ prePivot.y.to!string ~ "," ~
        prePivot.z.to!string ~ ") reloc=(" ~
        relocatedPivot.x.to!string ~ "," ~ relocatedPivot.y.to!string ~ "," ~
        relocatedPivot.z.to!string ~ ")");

    // Gesture A: on-handle +X haul at the relocated pivot. The pin
    // sticky-follows to A's displaced end on mouse-up. VERIFY-AND-RETRY keyed on
    // the UNDO COUNT: a MISSED attempt (stale pivot/camera read => grab pixel off
    // the arrow) has no on-handle grab => no commit => count unchanged, so we
    // retry; the first SUCCESSFUL attempt records EXACTLY ONE in-session entry
    // => +1, and we stop immediately (no undo-and-retry — that could starve under
    // load, leaving zero committed gestures). 8 attempts because this case runs
    // after a relocate + extra gesture, so the worker is busiest here under -j.
    enum double MOVE_EPS = 1e-2;
    long floorA = undoCount();
    foreach (attempt; 0 .. 8) {
        settle();   // quiesce before (re-)derivation so the pivot read is fresh
        cam = fetchCamera();
        vp  = viewportFromCamera(cam);
        auto piv = evalPivot();
        arrowDirPx(piv, vp, ux, uy);
        int xa, ya;
        arrowGrabPx(piv, vp, xa, ya);
        int xb = xa + cast(int)(60.0 * ux);
        int yb = ya + cast(int)(60.0 * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xa, ya, xb, yb, 10));
        settle();
        if (undoCount() == floorA + 1) break;
    }
    assert(undoCount() == floorA + 1,
        "gesture A should record EXACTLY ONE in-session entry; floor=" ~
        floorA.to!string ~ " now=" ~ undoCount().to!string);
    auto v6AfterA = vert(6);
    Vec3 pivotEndA = evalPivot();   // gesture A's sticky-follow END == B's START
    // Sanity: gesture A dragged the pin a clear distance off the relocate point.
    // This is LOAD-BEARING for the witness — the W1 bug snaps the pin to the
    // PRE-relocate point; the fix snaps it to A's end. Those two are
    // distinguishable only when A's end is a clear distance off the relocate
    // point (and the relocate already moved the pivot clearly off pre-relocate,
    // asserted above). A 60px haul on this cube/camera always clears MOVE_EPS.
    assert((fabs(pivotEndA.x - relocatedPivot.x) +
            fabs(pivotEndA.y - relocatedPivot.y) +
            fabs(pivotEndA.z - relocatedPivot.z)) > MOVE_EPS,
        "gesture A should sticky-follow the pin away from the relocate point; " ~
        "reloc=(" ~ relocatedPivot.x.to!string ~ "," ~
        relocatedPivot.y.to!string ~ "," ~ relocatedPivot.z.to!string ~
        ") endA=(" ~ pivotEndA.x.to!string ~ "," ~ pivotEndA.y.to!string ~
        "," ~ pivotEndA.z.to!string ~ ")");

    // Gesture B: RE-GRAB the +X arrow at A's end pivot (ON-handle, dragAxis>=0,
    // so NO relocate boundary fires) and haul +X again — same userPlaced run,
    // NO re-stage. THIS is the gesture whose pin-START the old code read stale.
    // Same undo-count-keyed verify-and-retry (stop on the first committed entry).
    // No magnitude gate here: gesture B's SIZE is irrelevant to the witness —
    // B's START pin is captured at its beginEdit == A's sticky-follow END
    // regardless of how far B then hauls, so the Ctrl+Z #1 pin assert below holds
    // for ANY committed B. (Only A's move must be meaningful — asserted above.)
    long floorB = undoCount();   // == floorA + 1
    foreach (attempt; 0 .. 8) {
        settle();
        cam = fetchCamera();
        vp  = viewportFromCamera(cam);
        auto piv = evalPivot();
        arrowDirPx(piv, vp, ux, uy);
        int xc, yc;
        arrowGrabPx(piv, vp, xc, yc);
        int xd = xc + cast(int)(50.0 * ux);
        int yd = yc + cast(int)(50.0 * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xc, yc, xd, yd, 10));
        settle();
        if (undoCount() == floorB + 1) break;
    }
    assert(undoCount() == floorB + 1,
        "gesture B should record EXACTLY ONE in-session entry; floor=" ~
        floorB.to!string ~ " now=" ~ undoCount().to!string);

    // In-session Ctrl+Z #1 (tool LIVE): plain history pop of gesture B. Geometry
    // back to post-A AND the pin returns to gesture B's START == gesture A's
    // sticky-follow END (pivotEndA). The OLD bug snapped it to pre-relocate.
    playAndWait(ctrlZ(50.0));
    settle();
    auto v6Step1 = vert(6);
    assert(fabs(v6Step1[0] - v6AfterA[0]) < 1e-3 &&
           fabs(v6Step1[1] - v6AfterA[1]) < 1e-3 &&
           fabs(v6Step1[2] - v6AfterA[2]) < 1e-3,
        "Ctrl+Z #1 should revert gesture B (geometry to post-A); got (" ~
        v6Step1[0].to!string ~ "," ~ v6Step1[1].to!string ~ "," ~
        v6Step1[2].to!string ~ ")");
    Vec3 pivotStep1 = evalPivot();
    assert(fabs(pivotStep1.x - pivotEndA.x) < 1e-2 &&
           fabs(pivotStep1.y - pivotEndA.y) < 1e-2 &&
           fabs(pivotStep1.z - pivotEndA.z) < 1e-2,
        "W1: Ctrl+Z #1 must return the pin to gesture B's START == gesture A's " ~
        "sticky-follow END, NOT pre-relocate; got (" ~
        pivotStep1.x.to!string ~ "," ~ pivotStep1.y.to!string ~ "," ~
        pivotStep1.z.to!string ~ ") want endA (" ~
        pivotEndA.x.to!string ~ "," ~ pivotEndA.y.to!string ~ "," ~
        pivotEndA.z.to!string ~ ")");

    // In-session Ctrl+Z #2 (tool LIVE): plain history pop of gesture A. Geometry
    // back to the run baseline (== post-relocate, the cube corner) AND the pin
    // returns to gesture A's START == the RELOCATE point (captured live at A's
    // beginEdit, which fired AFTER the relocate's restage).
    playAndWait(ctrlZ(60.0));
    settle();
    auto v6Step2 = vert(6);
    assert(fabs(v6Step2[0] - 0.5) < 1e-3 &&
           fabs(v6Step2[1] - 0.5) < 1e-3 &&
           fabs(v6Step2[2] - 0.5) < 1e-3,
        "Ctrl+Z #2 should revert gesture A (geometry back to the cube corner); " ~
        "got (" ~ v6Step2[0].to!string ~ "," ~ v6Step2[1].to!string ~ "," ~
        v6Step2[2].to!string ~ ")");
    Vec3 pivotStep2 = evalPivot();
    assert(fabs(pivotStep2.x - relocatedPivot.x) < 1e-2 &&
           fabs(pivotStep2.y - relocatedPivot.y) < 1e-2 &&
           fabs(pivotStep2.z - relocatedPivot.z) < 1e-2,
        "W1: Ctrl+Z #2 must return the pin to gesture A's START == the RELOCATE " ~
        "point; got (" ~ pivotStep2.x.to!string ~ "," ~
        pivotStep2.y.to!string ~ "," ~ pivotStep2.z.to!string ~
        ") want reloc (" ~ relocatedPivot.x.to!string ~ "," ~
        relocatedPivot.y.to!string ~ "," ~ relocatedPivot.z.to!string ~ ")");

    // A further Ctrl+Z pops prior history (the consolidated relocate run /
    // baseline); the open run's two gesture entries are now fully reverted.
    long beforePop = undoCount();
    playAndWait(ctrlZ(70.0));
    settle();
    assert(undoCount() <= beforePop,
        "a further Ctrl+Z should pop prior history (no growth); before=" ~
        beforePop.to!string ~ " after=" ~ undoCount().to!string);

    postJson("/api/script", "tool.set move off");
    settle();
}
