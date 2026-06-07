// Single-mode Rotate / Scale relocate boundary under the wrapper (Phase 2,
// Part A of doc/transform_per_gesture_commit_plan.md §6 test 3/4).
//
// The undo unit is the tool SESSION: consecutive ON-handle gizmo drags
// coalesce into ONE history entry. A click-away / action-center relocate
// during a live session commits the current run and opens a fresh one. For
// Rotate and Scale this boundary already exists on the SUB-TOOL itself
// (rotate.d / scale.d each do `if (editIsOpen()) commitEdit(...)` on the
// off-axis relocate branch, BEFORE re-anchoring + zeroing their accumulator).
// Their commit→notifyAcenUserPlaced ordering re-stages the relocated pin for
// free (the commit clears snapFrozen, so the subsequent setUserPlaced stages),
// so — unlike Move — no `restageRelocatePin` is needed. This test PINS that
// single-mode (TransformRotate / TransformScale) behaviour under the wrapper:
//   on-handle gizmo drag -> off-axis relocate -> on-handle gizmo drag -> drop
//      =>  TWO undo entries.
//
//   (a) Scale (TransformScale, S-only): single-axis handle drag (proven
//       reliable headlessly). Asserts the relocate-split count, the post-drop
//       Ctrl+Z grammar (geometry at each step), and reads the live scale
//       accumulator (`tool.attr TransformScale SX ?`) DURING the open session
//       to prove the gizmo drag drove the accumulator the panel exposes.
//   (b) Rotate (TransformRotate, R-only): ring drag at a screen angle proven
//       to land on the visible (hittable) semicircle of the X-ring.
//
// ACCUMULATOR READ-BACK NOTE (why the panel attr is read LIVE, not post-undo):
// the panel `SX`/`RX` slots bind to the WRAPPER's headlessScale/headlessRotate
// (transient drag state), while the undo accumulator-restore hooks roll back
// the SUB-TOOL's scaleAccum/angleAccum. resyncSession() (run after every
// history pop) zeroes the wrapper's headless* slots, so a post-undo `SX ?`
// query reads the reset value, NOT the restored accumulator. The accumulator
// that survives undo is observable through GEOMETRY (the restored accumulator
// drives the mesh) — so this test reads the live attr to confirm the gizmo
// drive, and uses geometry for the post-undo grammar. To guard the plan's
// "corrupted accumulator poisons the next gesture" concern, scenario (a) also
// drives a THIRD gesture after the relocate and asserts it composes from the
// relocated baseline (the accumulator was correctly re-snapped at the
// boundary, not left stale).
//
// All gestures drive the MAIN loop via drag_helpers.buildDragLog +
// /api/play-events (never an /api/command gesture — that races update() /
// navHistory on the background HTTP thread).

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, cos, sin, PI;
import std.conv : to;

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

// `?`-query read-back: returns the boxed "value" field.
JSONValue query(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "query '" ~ line ~ "' failed: " ~ r.toString);
    assert("value" in r, "query '" ~ line ~ "' returned no value: " ~ r.toString);
    return r["value"];
}

// Post-playback / post-undo settle (see test_relocate_boundary.d): events are
// POSTED to the SDL queue before processing, and /api/undo runs on the
// background HTTP thread — wait so the main loop has applied the change.
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
// test left the shared per-worker vibe3d dirty. `toolId` is dropped first so a
// stale live session can't bleed in. See test_relocate_boundary.d for the full
// rationale: the load-bearing detail is draining the undo stack BEFORE the
// reset (/api/reset is itself undoable; draining only AFTER it would undo our
// own reset and restore the prior test's dirty mesh), and verifying GEOMETRY
// (not just vertex count).
void establishCubeBaseline(string toolId) {
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
        postJson("/api/script", "tool.set " ~ toolId ~ " off");
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

// +X single-axis handle grab pixel + screen-space +X direction.
void axisGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy,
                out double ux, out double uy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size / 7.0f,   pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size * 1.18f,  pivot.y, pivot.z), vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}

// X-ring (normal = +X, lies in the YZ plane) grab pixel at a screen angle that
// lands on the VISIBLE (hittable) semicircle for the default test camera. 110°
// is well inside the hittable half (probed: 20/45/70/110/135/160 all rotate;
// 200–290 are the back half and miss). The drag is a fixed +25/+25px
// tangential nudge — enough to register a rotation arc without leaving the arc
// hit band.
void ringGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy) {
    float size = gizmoSize(pivot, vp);
    float a = 110.0f * cast(float)PI / 180.0f;
    Vec3 p = Vec3(pivot.x, pivot.y + cos(a) * size, pivot.z + sin(a) * size);
    float sx, sy;
    projectToWindow(p, vp, sx, sy);
    gx = cast(int)sx; gy = cast(int)sy;
}

// ---------------------------------------------------------------------------
// (a) Scale (TransformScale, S-only) single-mode relocate boundary.
//     NO selection ⇒ whole-mesh moving set, pivot at the origin, so a +X axis
//     scale drag actually scales v6.x (selecting only v6 would put the pivot
//     AT v6, leaving it fixed).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline("TransformScale");
    postJson("/api/script", "tool.set TransformScale");   // default ACEN = None (relocate-permitted)
    long stackBefore = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // Scale drag 1: grab +X handle, haul +X to scale up.
    Vec3 piv0 = evalPivot();
    int xa, ya; double ux, uy;
    axisGrabPx(piv0, vp, xa, ya, ux, uy);
    int xb = xa + cast(int)(80.0 * ux);
    int yb = ya + cast(int)(80.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xa, ya, xb, yb, 12));
    settle();

    auto v6Run1 = vert(6);
    assert(v6Run1[0] > 0.6,
        "scale drag 1 should grow v6.x past 0.6; got " ~ v6Run1[0].to!string);

    // Live accumulator read-back: the gizmo drag drove the panel SX slot.
    auto sxLive = query("tool.attr TransformScale SX ?");
    assert(sxLive.floating > 1.1,
        "live scale accumulator (SX) should reflect the gizmo drag (>1.1); got "
        ~ sxLive.toString);

    long stackAfterRun1 = undoCount();
    // Phase 2 flip: the scale gizmo gesture SELF-COMMITS a tagged in-session
    // entry on mouse-up (was: open run, no commit). The run stays open (the
    // entry is in-session, runOpen true) and consolidates at the relocate
    // boundary below — so the boundary count stays +1.
    assert(stackAfterRun1 == stackBefore + 1,
        "Phase 2: scale drag 1 self-commits one in-session entry mid-run; got "
        ~ (stackAfterRun1 - stackBefore).to!string ~ " new entries");

    // Off-axis relocate click (perpendicular to the +X handle ⇒ clearly off
    // every scale handle): commits run 1.
    int xoff = cast(int)(xb + 200.0 * uy);
    int yoff = cast(int)(yb - 200.0 * ux);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();

    long stackAfterRelocate = undoCount();
    assert(stackAfterRelocate == stackBefore + 1,
        "the relocate click should COMMIT scale run 1 (one new entry); got "
        ~ (stackAfterRelocate - stackBefore).to!string);

    Vec3 relocatedPivot = evalPivot();

    // Scale drag 2 at the RELOCATED pivot — proves the accumulator was
    // re-snapped at the boundary (a stale accumulator would mis-scale here).
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    int xc, yc; double u2, v2;
    axisGrabPx(relocatedPivot, vp, xc, yc, u2, v2);
    int xd = xc + cast(int)(60.0 * u2);
    int yd = yc + cast(int)(60.0 * v2);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xc, yc, xd, yd, 10));
    settle();

    // Drop ⇒ commits run 2.
    postJson("/api/script", "tool.set TransformScale off");
    settle();

    long stackAfter = undoCount();
    assert(stackAfter == stackBefore + 2,
        "scale drag + relocate + drag + drop should produce TWO undo entries; got "
        ~ (stackAfter - stackBefore).to!string);

    // Ctrl+Z #1 reverts run 2 only: v6 back to its post-run-1 scale.
    postJson("/api/undo", "");
    settle();
    auto v6Undo1 = vert(6);
    assert(fabs(v6Undo1[0] - v6Run1[0]) < 1e-3 &&
           fabs(v6Undo1[1] - v6Run1[1]) < 1e-3 &&
           fabs(v6Undo1[2] - v6Run1[2]) < 1e-3,
        "Ctrl+Z #1 should revert only scale run 2 (back to post-run-1); got ("
        ~ v6Undo1[0].to!string ~ "," ~ v6Undo1[1].to!string ~ ","
        ~ v6Undo1[2].to!string ~ ") want ("
        ~ v6Run1[0].to!string ~ "," ~ v6Run1[1].to!string ~ ","
        ~ v6Run1[2].to!string ~ ")");

    // Ctrl+Z #2 reverts run 1: v6 back to the pristine cube corner.
    postJson("/api/undo", "");
    settle();
    auto v6Undo2 = vert(6);
    assert(fabs(v6Undo2[0] - 0.5) < 1e-3 &&
           fabs(v6Undo2[1] - 0.5) < 1e-3 &&
           fabs(v6Undo2[2] - 0.5) < 1e-3,
        "Ctrl+Z #2 should revert scale run 1 (back to cube); got ("
        ~ v6Undo2[0].to!string ~ "," ~ v6Undo2[1].to!string ~ ","
        ~ v6Undo2[2].to!string ~ ")");
}

// ---------------------------------------------------------------------------
// (b) Rotate (TransformRotate, R-only) single-mode relocate boundary.
//     NO selection ⇒ whole-mesh moving set, pivot at the origin, so an X-ring
//     drag rotates v6 about X (its x stays 0.5).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline("TransformRotate");
    postJson("/api/script", "tool.set TransformRotate");
    long stackBefore = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // Ring drag 1: grab the X-ring on its visible half, tangential nudge.
    int xa, ya;
    ringGrabPx(evalPivot(), vp, xa, ya);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xa, ya, xa + 25, ya + 25, 12));
    settle();

    auto v6Run1 = vert(6);
    // An X-rotation keeps v6.x = 0.5 and moves it off the (0.5,0.5,0.5) corner.
    assert(fabs(v6Run1[0] - 0.5) < 1e-3,
        "X-ring rotation keeps v6.x = 0.5; got " ~ v6Run1[0].to!string);
    assert((fabs(v6Run1[1] - 0.5) + fabs(v6Run1[2] - 0.5)) > 0.05,
        "ring drag 1 should rotate v6 off the corner; got ("
        ~ v6Run1[1].to!string ~ "," ~ v6Run1[2].to!string ~ ")");

    long stackAfterRun1 = undoCount();
    // Phase 2 flip (mirrors the scale leg): the ring gizmo gesture SELF-COMMITS
    // a tagged in-session entry on mouse-up; the run stays open and consolidates
    // at the relocate boundary below, so the boundary count stays +1.
    assert(stackAfterRun1 == stackBefore + 1,
        "Phase 2: rotate ring drag 1 self-commits one in-session entry mid-run; "
        ~ "got " ~ (stackAfterRun1 - stackBefore).to!string ~ " new entries");

    // Off-ring relocate click well to the side of the gizmo.
    int xoff = xa + 200;
    int yoff = ya;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();

    long stackAfterRelocate = undoCount();
    assert(stackAfterRelocate == stackBefore + 1,
        "the off-ring relocate click should COMMIT rotate run 1; got "
        ~ (stackAfterRelocate - stackBefore).to!string);

    // Ring drag 2 at the relocated pivot.
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    int xc, yc;
    ringGrabPx(evalPivot(), vp, xc, yc);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xc, yc, xc + 25, yc + 25, 12));
    settle();

    // Drop ⇒ commits run 2.
    postJson("/api/script", "tool.set TransformRotate off");
    settle();

    long stackAfter = undoCount();
    assert(stackAfter == stackBefore + 2,
        "rotate ring drag + relocate + ring drag + drop should produce TWO "
        ~ "undo entries; got " ~ (stackAfter - stackBefore).to!string);

    // Ctrl+Z #1 reverts run 2 only: v6 back to its post-run-1 orientation.
    postJson("/api/undo", "");
    settle();
    auto v6Undo1 = vert(6);
    assert(fabs(v6Undo1[0] - v6Run1[0]) < 1e-3 &&
           fabs(v6Undo1[1] - v6Run1[1]) < 1e-3 &&
           fabs(v6Undo1[2] - v6Run1[2]) < 1e-3,
        "Ctrl+Z #1 should revert only rotate run 2 (back to post-run-1); got ("
        ~ v6Undo1[0].to!string ~ "," ~ v6Undo1[1].to!string ~ ","
        ~ v6Undo1[2].to!string ~ ") want ("
        ~ v6Run1[0].to!string ~ "," ~ v6Run1[1].to!string ~ ","
        ~ v6Run1[2].to!string ~ ")");

    // Ctrl+Z #2 reverts run 1: v6 back to the pristine cube corner.
    postJson("/api/undo", "");
    settle();
    auto v6Undo2 = vert(6);
    assert(fabs(v6Undo2[0] - 0.5) < 1e-3 &&
           fabs(v6Undo2[1] - 0.5) < 1e-3 &&
           fabs(v6Undo2[2] - 0.5) < 1e-3,
        "Ctrl+Z #2 should revert rotate run 1 (back to cube); got ("
        ~ v6Undo2[0].to!string ~ "," ~ v6Undo2[1].to!string ~ ","
        ~ v6Undo2[2].to!string ~ ")");
}
