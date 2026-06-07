// Off-gizmo click commits the run in relocate-DISALLOWED action-center modes
// (Phase 5 of doc/transform_per_gesture_commit_plan.md).
//
// Phase-3 audit (2026-06-07): P5 boundary count (+2) + the in-session step
// reverting only the post-click run (pin stays at the picked anchor) confirmed
// on-contract; the consolidate gate moved editIsOpen() -> history.runOpen() in
// the Phase-1 addendum (A3). No assert changed in Phase 3, re-run to confirm
// green.
//
// Phases 1a/1b/2 added the relocate-commit boundary for the modes where an
// off-gizmo click actually RELOCATES the gizmo (Auto/None/Screen). The
// reference splits the undo run on an off-gizmo click EVEN in the pinned
// modes (Select/SelectAuto/Element/Local/Origin/Manual/Border), where nothing
// visibly moves — the trigger is the off-gizmo mouse-DOWN itself. Phase 5
// matches that: a plain off-gizmo LMB-down while ANY transform session is open
// commits every open session WITHOUT relocating anything; the next drag opens
// a fresh session = a separate undo entry.
//
// Scenarios:
//  (a) actr.select: on-handle drag -> off-gizmo click -> on-handle drag ->
//      drop => TWO undo entries; per-run Ctrl+Z grammar (geometry staging).
//  (b) actr.select, SAME sequence WITHOUT the off-gizmo click => ONE entry
//      (control — pins that the boundary, not the second drag, is what splits).
//  (c) off-gizmo click with NO open session (fresh tool, no drag yet) => ZERO
//      new entries (fully inert — no empty undo entry); a following single
//      drag+drop => exactly one.
//  (d) Element mode (xfrm.elementMove): on-handle drag -> off-gizmo click that
//      MISSES all elements -> in-session Ctrl+Z reverts only the post-click
//      run AND the pivot stays at the PICKED point (the verbatim re-stage,
//      stageCurrentActionCenterPin — regression for constraint 5). Uses the
//      two-batch hover technique from test_relocate_boundary_element.d.
//  (e) alt-modified click between drags must NOT split. GAP NOTE: buildDragLog
//      emits motion/button events with mod=0 and there is no helper to inject
//      a modifier-held LMB-down through the play-events log, so this case is
//      documented here rather than shipped as a fragile hand-rolled log. The
//      modifier gate is exercised structurally: the Phase 5 branch reads
//      SDL_GetModState() and the `plain2` filter excludes Alt/Ctrl/Shift, the
//      same filter the element-pick PRE-step uses; app.d routes Alt+LMB orbit
//      to the tool before its own DragMode branch, so the gate lives in the
//      tool (verified by code read, xfrm_transform.d onMouseButtonDown).
//
// All gestures drive the MAIN loop via drag_helpers.buildDragLog +
// /api/play-events (never an /api/command gesture — that races update() /
// navHistory on the background HTTP thread). Reset preamble drains the undo
// stack BEFORE the reset (/api/reset is itself undoable).

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

void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(140.msecs);
}

void drainHistory() {
    foreach (_; 0 .. 100) {
        if (undoCount() == 0) return;
        postJson("/api/undo", "");
    }
}

// Establish a pristine cube + (near-)empty undo stack (drain BEFORE the reset,
// since /api/reset is itself undoable — see test_relocate_boundary.d header).
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
        postJson("/api/script", "tool.set move off");
        postJson("/api/script", "tool.set xfrm.elementMove off");
        foreach (_; 0 .. 200) {
            if (playerIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        drainHistory();              // pop the prior test's commands FIRST
        postJson("/api/reset", "");
        drainHistory();              // pop the reset (+ select UI-undo)
        if (cubePristine()) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");      // last reset stands (not undone)
    assert(cubePristine(), "could not establish pristine cube baseline");
}

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

// +X arrow handle grab pixel + screen-space +X direction for the gizmo at
// `pivot` (same helpers as test_relocate_boundary.d).
void arrowGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,        pivot.y, pivot.z), vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
}
void arrowDirPx(Vec3 pivot, ref Viewport vp, out double ux, out double uy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size/6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,       pivot.y, pivot.z), vp, sx2, sy2);
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}

// Hover-only batch (no buttons) — refreshes the CPU hover pass so a subsequent
// (separate-batch) click sees fresh hover state.
string hoverLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            50.0 + i * 20.0, x, y);
    return log;
}

string ctrlZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n",
        t, t + 10.0);
}

// ---------------------------------------------------------------------------
// (a) actr.select: on-handle drag -> off-gizmo click -> on-handle drag ->
//     drop => TWO undo entries. Ctrl+Z #1 reverts run 2, #2 reverts run 1.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    postJson("/api/script", "tool.set move");
    // actr.select: relocate-DISALLOWED. An off-gizmo click is inert for the
    // pivot but MUST commit the run under Phase 5.
    postJson("/api/script", "actr.select");
    settle();
    long stackBefore = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    double ux, uy;
    arrowDirPx(evalPivot(), vp, ux, uy);

    // Drag 1: grab +X arrow, haul +X 60px.
    int xa, ya;
    arrowGrabPx(evalPivot(), vp, xa, ya);
    int xb = xa + cast(int)(60.0 * ux);
    int yb = ya + cast(int)(60.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xa, ya, xb, yb, 10));
    settle();
    auto v6AfterRun1 = vert(6);

    Vec3 pivotBeforeClick = evalPivot();

    // Off-gizmo click (degenerate 1-step drag = discrete click) well away from
    // the gizmo. In actr.select this does NOT relocate — Phase 5 commits run 1.
    int xoff = cast(int)(xb + 220.0 * uy);
    int yoff = cast(int)(yb - 220.0 * ux);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();

    long stackAfterClick = undoCount();
    assert(stackAfterClick == stackBefore + 1,
        "the off-gizmo click in actr.select should COMMIT run 1 (one new " ~
        "entry); got " ~ (stackAfterClick - stackBefore).to!string);

    // The pivot must NOT have moved (relocate-disallowed mode).
    Vec3 pivotAfterClick = evalPivot();
    assert(fabs(pivotAfterClick.x - pivotBeforeClick.x) < 1e-3 &&
           fabs(pivotAfterClick.y - pivotBeforeClick.y) < 1e-3 &&
           fabs(pivotAfterClick.z - pivotBeforeClick.z) < 1e-3,
        "Phase 5 must NOT relocate the pivot in actr.select; before=(" ~
        pivotBeforeClick.x.to!string ~ "," ~ pivotBeforeClick.y.to!string ~
        "," ~ pivotBeforeClick.z.to!string ~ ") after=(" ~
        pivotAfterClick.x.to!string ~ "," ~ pivotAfterClick.y.to!string ~
        "," ~ pivotAfterClick.z.to!string ~ ")");

    // Drag 2: re-grab +X arrow at the (unchanged) pivot, haul +X.
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    int xc, yc;
    arrowGrabPx(pivotAfterClick, vp, xc, yc);
    int xd = xc + cast(int)(60.0 * ux);
    int yd = yc + cast(int)(60.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xc, yc, xd, yd, 10));
    settle();

    // Drop -> commits run 2.
    postJson("/api/script", "tool.set move off");
    settle();

    long stackAfter = undoCount();
    assert(stackAfter == stackBefore + 2,
        "drag + off-gizmo click + drag + drop in actr.select should produce " ~
        "TWO undo entries; got " ~ (stackAfter - stackBefore).to!string);

    // Ctrl+Z #1 reverts run 2 only: v6 back to post-run-1.
    postJson("/api/undo", "");
    settle();
    auto v6undo1 = vert(6);
    assert(fabs(v6undo1[0] - v6AfterRun1[0]) < 1e-3 &&
           fabs(v6undo1[1] - v6AfterRun1[1]) < 1e-3 &&
           fabs(v6undo1[2] - v6AfterRun1[2]) < 1e-3,
        "Ctrl+Z #1 should revert only run 2 (back to post-run-1); got (" ~
        v6undo1[0].to!string ~ "," ~ v6undo1[1].to!string ~ "," ~
        v6undo1[2].to!string ~ ")");

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
// (b) Control: actr.select, SAME two drags WITHOUT the off-gizmo click between
//     => ONE entry. Pins that the BOUNDARY (the click), not the second drag,
//     is what splits the run.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    postJson("/api/script", "tool.set move");
    postJson("/api/script", "actr.select");
    settle();
    long stackBefore = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    double ux, uy;
    arrowDirPx(evalPivot(), vp, ux, uy);

    // Drag 1: on-handle +X haul.
    int xa, ya;
    arrowGrabPx(evalPivot(), vp, xa, ya);
    int xb = xa + cast(int)(60.0 * ux);
    int yb = ya + cast(int)(60.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xa, ya, xb, yb, 10));
    settle();

    // Drag 2: re-grab the +X arrow at the (unchanged, pinned) pivot and haul
    // BACK -X (the proven test_property_panel_drag pattern keeps the second
    // mouse-DOWN reliably ON the handle).
    Vec3 pivot = evalPivot();
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    int xc, yc;
    arrowGrabPx(pivot, vp, xc, yc);
    int xd = xc - cast(int)(40.0 * ux);
    int yd = yc - cast(int)(40.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xc, yc, xd, yd, 10));
    settle();

    // Drop.
    postJson("/api/script", "tool.set move off");
    settle();

    long stackAfter = undoCount();
    assert(stackAfter == stackBefore + 1,
        "two ON-handle drags with NO off-gizmo click between should COALESCE " ~
        "to ONE entry; got " ~ (stackAfter - stackBefore).to!string);

    // One Ctrl+Z reverts BOTH drags to the pristine cube corner.
    postJson("/api/undo", "");
    settle();
    auto v6 = vert(6);
    assert(fabs(v6[0] - 0.5) < 1e-3 &&
           fabs(v6[1] - 0.5) < 1e-3 &&
           fabs(v6[2] - 0.5) < 1e-3,
        "one Ctrl+Z should revert the single coalesced run (back to cube); " ~
        "got (" ~ v6[0].to!string ~ "," ~ v6[1].to!string ~ "," ~
        v6[2].to!string ~ ")");
}

// ---------------------------------------------------------------------------
// (c) Off-gizmo click with NO open session (fresh tool, no drag yet) => ZERO
//     new entries (fully inert — no empty undo entry). A following single
//     drag+drop => exactly one.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    postJson("/api/script", "tool.set move");
    postJson("/api/script", "actr.select");
    settle();
    long stackBefore = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    double ux, uy;
    arrowDirPx(evalPivot(), vp, ux, uy);

    // Off-gizmo click with NO session open yet.
    int xa, ya;
    arrowGrabPx(evalPivot(), vp, xa, ya);
    int xoff = cast(int)(xa + 220.0 * uy);
    int yoff = cast(int)(ya - 220.0 * ux);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();

    long stackAfterInertClick = undoCount();
    assert(stackAfterInertClick == stackBefore,
        "an off-gizmo click with NO open session must be fully inert (no " ~
        "empty undo entry); got " ~
        (stackAfterInertClick - stackBefore).to!string ~ " new entries");

    // A following single drag + drop => exactly one entry.
    Vec3 pivot = evalPivot();
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    int xb, yb;
    arrowGrabPx(pivot, vp, xb, yb);
    int xc = xb + cast(int)(60.0 * ux);
    int yc = yb + cast(int)(60.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xb, yb, xc, yc, 10));
    settle();
    postJson("/api/script", "tool.set move off");
    settle();

    long stackAfter = undoCount();
    assert(stackAfter == stackBefore + 1,
        "a single drag+drop after the inert click should produce EXACTLY one " ~
        "entry; got " ~ (stackAfter - stackBefore).to!string);
}

// ---------------------------------------------------------------------------
// (d) Element mode (xfrm.elementMove): on-handle drag -> off-gizmo click that
//     MISSES all elements -> in-session Ctrl+Z reverts only the post-click run
//     AND the pivot stays at the PICKED point (the verbatim re-stage,
//     stageCurrentActionCenterPin). Regression for constraint 5: a wrong
//     re-stage would yank the pivot to a stale pin.
//
// Element mode is relocate-DISALLOWED. We first PICK the +Z face (so userPlaced
// is genuinely set to that anchor), haul, then click EMPTY SPACE that misses
// every element — that click is the Phase 5 boundary (commit, no relocate). An
// in-session Ctrl+Z of the post-click run must leave the pivot at the picked
// +Z anchor.
// ---------------------------------------------------------------------------
enum int ZFACE_X = 414;   // +Z face projects here with the default test camera
enum int ZFACE_Y = 343;

unittest {
    establishCubeBaseline();
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    postJson("/api/script", "tool.set xfrm.elementMove on");
    postJson("/api/command", "tool.pipe.attr falloff dist 4");
    settle();
    long stackBefore = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    double ux, uy;
    arrowDirPx(evalPivot(), vp, ux, uy);

    // Gesture 1: element-pick the +Z face + haul (opens run 1, pins userPlaced
    // to the +Z anchor). Hover in its own batch first (stale-hover trap).
    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                          ZFACE_X, ZFACE_Y));
    settle();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              ZFACE_X, ZFACE_Y, ZFACE_X, ZFACE_Y - 30, 10));
    settle();

    Vec3 pickedPivot = evalPivot();   // the +Z element anchor
    auto v6AfterRun1 = vert(6);
    assert(pickedPivot.z > 0.3,
        "gesture 1 should pin the pivot to the +Z face anchor; got z=" ~
        pickedPivot.z.to!string);

    // Off-gizmo click in EMPTY SPACE that misses every element (top-left
    // corner of the viewport, far from the cube). Hover there first so the
    // CPU pick pass clears any prior hover, then click. In Element mode an
    // empty click does NOT pick (tryPickElement returns false) and the move
    // bank declines (relocate-disallowed) -> Phase 5 commits run 1.
    int emptyX = cam.vpX + 12;
    int emptyY = cam.vpY + 12;
    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                          emptyX, emptyY));
    settle();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              emptyX, emptyY, emptyX, emptyY, 1));
    settle();

    long stackAfterClick = undoCount();
    assert(stackAfterClick == stackBefore + 1,
        "the off-element click in Element mode should COMMIT run 1 (one new " ~
        "entry); got " ~ (stackAfterClick - stackBefore).to!string);

    // Pivot must remain the PICKED +Z anchor (no relocate).
    Vec3 pivotAfterClick = evalPivot();
    assert(fabs(pivotAfterClick.x - pickedPivot.x) < 1e-2 &&
           fabs(pivotAfterClick.y - pickedPivot.y) < 1e-2 &&
           fabs(pivotAfterClick.z - pickedPivot.z) < 1e-2,
        "Phase 5 must NOT relocate the picked pivot; picked=(" ~
        pickedPivot.x.to!string ~ "," ~ pickedPivot.y.to!string ~ "," ~
        pickedPivot.z.to!string ~ ") after=(" ~
        pivotAfterClick.x.to!string ~ "," ~ pivotAfterClick.y.to!string ~
        "," ~ pivotAfterClick.z.to!string ~ ")");

    // Gesture 2 (post-click run): re-grab the +X arrow at the picked pivot and
    // partial-haul (do NOT drop — keep run 2 OPEN).
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    int xc, yc;
    arrowGrabPx(pivotAfterClick, vp, xc, yc);
    int xd = xc + cast(int)(40.0 * ux);
    int yd = yc + cast(int)(40.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xc, yc, xd, yd, 8));
    settle();

    // In-session Ctrl+Z (record+consolidate Phase 1): gesture 2 committed its
    // own TAGGED in-session entry on mouse-up, so navHistory does a PLAIN
    // history.undo() that pops it (geometry back to post-run-1) and
    // resyncSession re-baselines. The pivot stays on the picked +Z anchor: the
    // Phase 5 boundary re-staged it verbatim (stageCurrentActionCenterPin) and
    // the pin is permanent, so reverting gesture 2's mesh edit does not move it
    // (constraint 5). Same observable as the old whole-run cancel. (Q-b gate.)
    playAndWait(ctrlZ(50.0));
    settle();

    auto v6Cancel = vert(6);
    assert(fabs(v6Cancel[0] - v6AfterRun1[0]) < 1e-3 &&
           fabs(v6Cancel[1] - v6AfterRun1[1]) < 1e-3 &&
           fabs(v6Cancel[2] - v6AfterRun1[2]) < 1e-3,
        "in-session Ctrl+Z should revert only the post-click run (back to " ~
        "post-run-1); got (" ~ v6Cancel[0].to!string ~ "," ~
        v6Cancel[1].to!string ~ "," ~ v6Cancel[2].to!string ~ ")");

    Vec3 pivotAfterCancel = evalPivot();
    assert(fabs(pivotAfterCancel.x - pickedPivot.x) < 1e-2 &&
           fabs(pivotAfterCancel.y - pickedPivot.y) < 1e-2 &&
           fabs(pivotAfterCancel.z - pickedPivot.z) < 1e-2,
        "in-session cancel must leave the pivot at the PICKED +Z anchor " ~
        "(verbatim re-stage); picked=(" ~
        pickedPivot.x.to!string ~ "," ~ pickedPivot.y.to!string ~ "," ~
        pickedPivot.z.to!string ~ ") cancel=(" ~
        pivotAfterCancel.x.to!string ~ "," ~ pivotAfterCancel.y.to!string ~
        "," ~ pivotAfterCancel.z.to!string ~ ")");

    // Cleanup so the next test starts from a clean tool.
    postJson("/api/script", "tool.set xfrm.elementMove off");
    settle();
}
