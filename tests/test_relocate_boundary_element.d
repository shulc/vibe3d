// Element-falloff pick+haul relocate commits the current undo run (Phase 1b
// of doc/transform_per_gesture_commit_plan.md).
//
// Phase-3 audit (2026-06-07): element-pick boundary count (+1) confirmed
// on-contract — the consolidate-at-boundary gate moved from editIsOpen() to
// history.runOpen() in the Phase-1 addendum (A2). No assert changed in Phase 3,
// re-run to confirm green.
//
// Sibling of test_relocate_boundary.d (Phase 1a, the off-gizmo Move
// click-relocate). Phase 1b covers the OTHER relocate path: with
// falloff.element active (the `xfrm.elementMove` preset), an off-handle
// click PICKS a mesh element and re-anchors the action center to it, then
// hauls the moving set through that anchor (an "ElementMove" gesture). When
// a Move run is already open, that element pick is an in-session relocate
// boundary: it must COMMIT the prior run before the haul opens a fresh
// session. So
//   on-handle drag -> element-pick + haul -> drop  =>  TWO undo entries.
//
// Same snapFrozen trap as Phase 1a: at an in-session pick the element's
// setUserPlaced (fired from tryPickElement, BEFORE the boundary) does NOT
// stage the cancel baseline (snapFrozen is true from the prior run's
// beginEdit); the boundary commitEdit then discards the frozen snapshot
// WITHOUT restoring; so the wrapper re-stages the PICKED pin
// (restageActionCenterPin, reading the ACEN stage's live center — the
// picked element anchor) AFTER the commit, so the new session freezes the
// PICKED pin as its in-session-cancel baseline. The element-falloff sphere
// anchor (state.actionCenter.center) is therefore the picked element across
// the commit (R6).
//
// Two scenarios:
//  (a) on-handle drag + element-pick+haul + drop => TWO entries; Ctrl+Z #1
//      reverts only the haul, Ctrl+Z #2 reverts the first run.
//  (b) in-session Ctrl+Z (tool still live) after the pick+haul restores
//      geometry to post-first-run AND the pivot to the PICKED element
//      anchor (the relocated pin), clearly away from the pre-pick pivot.
//
// HEADLESS PICK NOTE: the element click-pick reads g_hoveredVertex/Edge/Face,
// populated by the per-frame CPU hover pass. EventPlayer batches due events
// in ONE tick, so a motion+click in a single play-events log fires the click
// with STALE (pre-motion) hover. The fix used here: drive the hover motion
// in its OWN play-events batch, settle (one frame refreshes hover over the
// target), THEN drive the pick+haul drag in a second batch. (test_element_-
// move_pick.d documents the same constraint and avoids the click path; here
// we drive it for real via the separated-batch trick.)
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

// Post-playback / post-command settle (see test_relocate_boundary.d): events
// are POSTED to the SDL queue before they are processed, and /api/undo runs
// on the background HTTP thread — wait so the main loop has applied the
// change before reading geometry/pivot.
void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(150.msecs);
}

void drainHistory() {
    foreach (_; 0 .. 100) {
        if (undoCount() == 0) return;
        postJson("/api/undo", "");
    }
}

// Establish a pristine cube + (near-)empty undo stack, retrying if a preceding
// test left the shared per-worker vibe3d dirty. See test_relocate_boundary.d
// for the full rationale: the load-bearing detail is draining the undo stack
// BEFORE the reset (/api/reset is itself undoable; draining only AFTER it would
// undo our own reset and restore the prior test's dirty mesh), and verifying
// GEOMETRY (not just vertex count).
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

// Authoritative gizmo pivot / element-falloff sphere anchor: the evaluated
// ActionCenterPacket.center (FalloffStage reads state.actionCenter.center
// from the same value).
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

// +X arrow handle grab pixel + screen-space +X direction, for the gizmo
// anchored at `pivot` (same helpers as test_relocate_boundary.d).
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

// Hover-only play-events batch (no mouse buttons) — refreshes the CPU hover
// pass over (x,y) so the subsequent (separate-batch) pick click lands on the
// hovered element.
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

// SDL Ctrl+Z keystroke as a play-events fragment (same as
// test_relocate_boundary.d). 122='z', mod 64 = KMOD_LCTRL.
string ctrlZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n",
        t, t + 10.0);
}

// Activate the element-move preset with a wide falloff sphere (dist 4) so a
// pick anywhere drags the whole cube (the empty-selection moving set). vert 6
// is pre-selected so the FIRST gesture is an on-handle gizmo drag at the
// (+0.5,+0.5,+0.5) corner — its gizmo sits ~90px wide on screen, well clear
// of the +Z face the second gesture picks (~158px away), so the second
// click cannot accidentally re-grab a handle.
void activateElementMovePreset() {
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    postJson("/api/script", "tool.set xfrm.elementMove on");
    postJson("/api/command", "tool.pipe.attr falloff dist 4");
    settle();
}

// The +Z face (face index 1) projects to ~(414,343) with the default test
// camera and is ~158px from the corner gizmo — a reliable element-pick
// target that never overlaps the gizmo.
enum int ZFACE_X = 414;
enum int ZFACE_Y = 343;

// ---------------------------------------------------------------------------
// (a) on-handle drag -> element-pick + haul -> drop => TWO undo entries.
//     Ctrl+Z #1 reverts only the haul; Ctrl+Z #2 reverts the first run.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    activateElementMovePreset();
    long stackBefore = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    double ux, uy;
    arrowDirPx(evalPivot(), vp, ux, uy);

    // Gesture 1: on-handle +X arrow drag — opens the wrapper Move run.
    int xa, ya;
    arrowGrabPx(evalPivot(), vp, xa, ya);
    int xb = xa + cast(int)(50.0 * ux);
    int yb = ya + cast(int)(50.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xa, ya, xb, yb, 10));
    settle();

    auto v6AfterRun1 = vert(6);
    long stackAfterRun1 = undoCount();
    // record+consolidate (Phase 1): gesture 1 commits a TAGGED in-session entry
    // on mouse-up (+1 mid-run); the element-pick boundary below consolidates the
    // run to ONE surviving entry. Flipped from the old open-run observable.
    assert(stackAfterRun1 == stackBefore + 1,
        "gesture 1 records ONE in-session entry on mouse-up; got " ~
        (stackAfterRun1 - stackBefore).to!string ~ " new entries");

    // Gesture 2: element-pick the +Z face (well clear of the gizmo) and
    // haul. The pick is the in-session relocate boundary -> commits run 1.
    // Hover in its own batch first so the pick click sees fresh hover state.
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                          ZFACE_X, ZFACE_Y));
    settle();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              ZFACE_X, ZFACE_Y, ZFACE_X, ZFACE_Y - 30, 10));
    settle();

    long stackAfterPick = undoCount();
    // Timeline (per-gesture record+consolidate, addendum-2): the element pick is
    // run 1's boundary -> run 1's in-session tail CONSOLIDATES into ONE surviving
    // entry (+1). The pick+haul is run 2's FIRST gesture; its drag mouse-up has
    // already SELF-COMMITTED a tagged in-session entry by this assert point (+1).
    // So mid-run we observe TWO entries: consolidated run 1 + run 2's open
    // gesture. (Run 2 has NOT yet consolidated -- that happens at the drop /
    // in-session cancel below.)
    assert(stackAfterPick == stackBefore + 2,
        "element pick consolidates run 1 (+1) and run 2's first gesture has " ~
        "already self-committed (+1); got " ~
        (stackAfterPick - stackBefore).to!string);

    auto v6AfterRun2 = vert(6);
    // Sanity: run 2's haul moved v6 (it lies inside the dist=4 sphere).
    assert((fabs(v6AfterRun2[0] - v6AfterRun1[0]) +
            fabs(v6AfterRun2[1] - v6AfterRun1[1]) +
            fabs(v6AfterRun2[2] - v6AfterRun1[2])) > 1e-3,
        "the pick+haul should move v6; run1=(" ~
        v6AfterRun1[0].to!string ~ "," ~ v6AfterRun1[1].to!string ~ "," ~
        v6AfterRun1[2].to!string ~ ") run2=(" ~
        v6AfterRun2[0].to!string ~ "," ~ v6AfterRun2[1].to!string ~ "," ~
        v6AfterRun2[2].to!string ~ ")");

    // Drop -> commits run 2.
    postJson("/api/script", "tool.set xfrm.elementMove off");
    settle();

    long stackAfter = undoCount();
    assert(stackAfter == stackBefore + 2,
        "on-handle drag + element-pick+haul + drop should produce TWO undo " ~
        "entries; got " ~ (stackAfter - stackBefore).to!string);

    // Ctrl+Z #1 reverts only run 2 (the haul): v6 back to post-run-1.
    postJson("/api/undo", "");
    settle();
    auto v6undo1 = vert(6);
    assert(fabs(v6undo1[0] - v6AfterRun1[0]) < 1e-3 &&
           fabs(v6undo1[1] - v6AfterRun1[1]) < 1e-3 &&
           fabs(v6undo1[2] - v6AfterRun1[2]) < 1e-3,
        "Ctrl+Z #1 should revert only the haul (back to post-run-1); got (" ~
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
// (b) In-session cancel lands on the PICKED element anchor
//     (restageActionCenterPin + R6 sphere-anchor integrity):
//     on-handle drag -> element-pick + partial haul -> in-session Ctrl+Z
//     restores geometry to post-run-1 AND the pivot to the PICKED element
//     anchor (the relocated pin), clearly away from the pre-pick gizmo pivot.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    activateElementMovePreset();
    long stackBefore = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    double ux, uy;
    arrowDirPx(evalPivot(), vp, ux, uy);

    Vec3 prePivot = evalPivot();   // gizmo pivot before the pick (corner)

    // Gesture 1: on-handle +X arrow drag.
    int xa, ya;
    arrowGrabPx(prePivot, vp, xa, ya);
    int xb = xa + cast(int)(50.0 * ux);
    int yb = ya + cast(int)(50.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xa, ya, xb, yb, 10));
    settle();
    auto v6AfterRun1 = vert(6);
    Vec3 run1Pivot = evalPivot();   // gizmo moved with the on-handle drag

    // Gesture 2: element-pick the +Z face + partial haul (do NOT drop —
    // keep run 2 OPEN).
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                          ZFACE_X, ZFACE_Y));
    settle();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              ZFACE_X, ZFACE_Y, ZFACE_X, ZFACE_Y - 25, 8));
    settle();

    long stackAfterPick = undoCount();
    // Timeline (per-gesture record+consolidate, addendum-2): the element pick is
    // run 1's boundary -> run 1's in-session tail CONSOLIDATES into ONE surviving
    // entry (+1). The pick+haul is run 2's FIRST gesture; its drag mouse-up has
    // already SELF-COMMITTED a tagged in-session entry by this assert point (+1).
    // So mid-run we observe TWO entries: consolidated run 1 + run 2's open
    // gesture. (Run 2 has NOT yet consolidated -- that happens at the drop /
    // in-session cancel below.)
    assert(stackAfterPick == stackBefore + 2,
        "element pick consolidates run 1 (+1) and run 2's first gesture has " ~
        "already self-committed (+1); got " ~
        (stackAfterPick - stackBefore).to!string);

    // In-session Ctrl+Z (tool still live, record+consolidate Phase 1): the
    // run-2 gesture committed its own TAGGED in-session entry on mouse-up, so
    // navHistory does a PLAIN history.undo() that pops it (geometry back to
    // post-run-1) and resyncSession re-baselines. The pivot stays on the PICKED
    // element anchor: restageActionCenterPin committed it permanently at the
    // element-pick boundary, so reverting run 2's mesh edit does not move it.
    // Same observable as the old whole-run cancel. (Q-b pin gate.)
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

    // The cancel baseline is the PICKED element anchor — a relocate to the +Z
    // face. Assert it relocated AWAY from the run-1 (corner) gizmo pivot. A
    // missing / mis-ordered restage would leave the frozen baseline at a
    // STALE point (the pre-pick corner) and the gizmo would snap back there.
    double moveFromRun1 =
        fabs(pivotAfterCancel.x - run1Pivot.x) +
        fabs(pivotAfterCancel.y - run1Pivot.y) +
        fabs(pivotAfterCancel.z - run1Pivot.z);
    assert(moveFromRun1 > 0.2,
        "in-session cancel must land the pivot on the PICKED element anchor, " ~
        "clearly away from the pre-pick corner pivot; cancel=(" ~
        pivotAfterCancel.x.to!string ~ "," ~ pivotAfterCancel.y.to!string ~
        "," ~ pivotAfterCancel.z.to!string ~ ") run1Pivot=(" ~
        run1Pivot.x.to!string ~ "," ~ run1Pivot.y.to!string ~ "," ~
        run1Pivot.z.to!string ~ ")");

    // R6 — element-falloff sphere anchor integrity: the picked anchor is the
    // +Z face (state.actionCenter.center == the picked element's click point
    // on that face), so its Z component sits on the +Z face plane and its
    // X/Y are near the face centre — distinct from the corner pivot's
    // (~0.5,~0.5). Assert the cancel pivot is on the +Z side and not at the
    // corner.
    assert(pivotAfterCancel.z > 0.3,
        "picked +Z-face anchor should have Z on the +Z face (~0.5); got z=" ~
        pivotAfterCancel.z.to!string);
    assert(fabs(pivotAfterCancel.x) < 0.35 && fabs(pivotAfterCancel.y) < 0.35,
        "picked +Z-face anchor should sit near the face centre (small X/Y), " ~
        "not at the corner pivot; got (" ~
        pivotAfterCancel.x.to!string ~ "," ~ pivotAfterCancel.y.to!string ~
        "," ~ pivotAfterCancel.z.to!string ~ ")");
}
