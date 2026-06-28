// Cross-slot relocate boundary in a composed T+R+S preset (Phase 2, Part B of
// doc/transform_per_gesture_commit_plan.md §4 / §6 test 4b).
//
// Phase-3 audit (2026-06-07): the Move-leg open-mid-run count (+1, gizmo
// mouse-up record) landed in Phase 1; the rotate-leg mid-run count stayed
// UNCHANGED (panel TX, no gizmo mouse-up -> no per-gesture record); the +2/+3
// boundary/drop counts are unchanged (cross-slot PLAIN mirror trips the layer-A
// foreign-record guard, keeping single-bank-per-run). No assert changed in
// Phase 3, re-run to confirm green.
//
// THE LEAK (plan §4): in a composed preset (`Transform`, T+R+S all on) TWO
// edit sessions can be open at once — the Move session on the WRAPPER
// (XfrmTransformTool), and a Rotate/Scale session on the SUB-TOOL instance. A
// relocate (off-gizmo click) is a new logical run that must commit EVERY open
// session, not just the slot whose handler was clicked. Before Phase 2 a Move
// relocate committed only the wrapper's Move run and the open R/S sub-tool
// session LEAKED across the boundary into the next gesture. Phase 2 wires the
// symmetric commit: the wrapper Move-relocate branch calls the sub-tools'
// public `commitSessionIfOpen()` mirrors, so an off-gizmo Move relocate also
// closes any open Rotate/Scale session.
//
// DISPATCH FACT (why the leaked session here is R/S, committed by the Move
// relocate — NOT the other direction): in a composed preset the wrapper tries
// `moveSub.onMouseButtonDown` FIRST (it is `flagT`-gated and listed before
// R/S). In a relocate-permitted ACEN mode (None — the default) moveSub
// CONSUMES the off-gizmo click as a Move relocate and returns true, so the
// click never reaches the R/S relocate branch. The R/S-relocate→commit-Move
// direction is therefore only reachable when `flagT` is OFF — but then no
// wrapper Move session exists to leak. So the headless-reachable cross-slot
// case is exactly this one: a Move relocate committing an open R/S session.
// (The R/S→Move wrapper commit added in Phase 2 is correct defensive symmetry
// for any future dispatch ordering; it is not reachable through the current
// composed-preset dispatch, documented in the source comment at the rotate.d /
// scale.d relocate branches.)
//
// SUBSTITUTION (plan §6 4b allows it): the plan's nominal trigger is "off-axis
// click on a Rotate RING". Per the dispatch fact that ring click would route
// to the Move relocate anyway. This test instead opens a NON-EMPTY rotate
// sub-tool session via `tool.attr Transform RZ 30` on the already-live wrapper
// (the proven reEvaluate seam — test_reevaluate.d Test 5/7), then fires the
// off-gizmo Move relocate. Both sessions are then open, and the relocate must
// commit BOTH — the discriminating, deterministic observable.
//
// THE DISCRIMINATING ASSERTION: after the off-gizmo relocate click the undo
// stack jumps by EXACTLY 2 (the Move run + the rotate run, both committed AT
// the boundary). Without the Phase 2 cross-slot wiring it would jump by only
// 1 (the Move run); the rotate session would leak and commit late at drop. The
// FIRST-Move-run provenance is then made explicit via geometry across the
// Ctrl+Z chain: the first Move run's +X displacement is undone only on the
// LAST pop (it did NOT leak across the boundary).
//
// NO selection ⇒ whole-mesh moving set, pivot at the origin: a +X arrow drag
// moves the whole cube and RZ=30 actually rotates it (a non-empty rotate
// session). All gestures drive the MAIN loop via drag_helpers.buildDragLog +
// /api/play-events.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
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
void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

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
// test left the shared per-worker vibe3d dirty. See the detailed rationale in
// test_relocate_boundary.d: the load-bearing detail is draining the undo stack
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
        postJson("/api/script", "tool.set Transform off");
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

void arrowGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy,
                 out double ux, out double uy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,        pivot.y, pivot.z), vp, sx2, sy2);
    // Grab the +X move arrow well INSIDE its length (0.4 of the way from the
    // shaft base to the tip). The principal-axis rotate rings have radius
    // == `size`, so the Y-ring's circle passes THROUGH the arrow TIP region
    // (+X·size): a grab near the tip lands within the ring's 8 px hit-test
    // tolerance. In the compact Transform presentation the registration order
    // makes the rotate ring win an overlap (scale → rotate → move priority),
    // so a tip-side grab would resolve to the rotate ring, not the move arrow.
    // 0.4·shaft keeps the click on the bare arrow shaft, clear of every ring,
    // at both the origin pivot AND the off-origin relocated pivot this test
    // uses — pinning the gesture to the Move bank the scenario intends.
    gx = cast(int)(sx1 + 0.4f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.4f * (sy2 - sy1));
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}

// ---------------------------------------------------------------------------
// Cross-slot leak: a Move relocate commits the open Rotate sub-tool session.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    // NO selection ⇒ whole-mesh moving set; pivot at origin. (Selecting only
    // v6 would put the pivot AT v6, so RZ would not rotate v6 and the rotate
    // session would be a geometric no-op — it must be NON-empty to test that
    // the relocate commits it.)
    postJson("/api/script", "tool.set Transform");   // composed T+R+S, ACEN = None
    long stackBefore = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    Vec3 piv0 = evalPivot();
    int xa, ya; double ux, uy;
    arrowGrabPx(piv0, vp, xa, ya, ux, uy);

    // Move drag 1: opens the wrapper Move run, displaces the whole mesh +X.
    int xb = xa + cast(int)(60.0 * ux);
    int yb = ya + cast(int)(60.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xa, ya, xb, yb, 10));
    settle();
    auto v6Run1 = vert(6);
    assert(v6Run1[0] > 0.6,
        "move drag 1 should shift the whole mesh +X (v6.x>0.6); got "
        ~ v6Run1[0].to!string);
    // record+consolidate (Phase 1): the move gesture commits a TAGGED
    // in-session entry on mouse-up, so the stack grows +1 mid-run (the run
    // consolidates at the relocate boundary below). Flipped from the old
    // open-run "== stackBefore" observable.
    assert(undoCount() == stackBefore + 1,
        "move drag 1 records ONE in-session entry on mouse-up; got "
        ~ (undoCount() - stackBefore).to!string ~ " new entries");

    // Open a NON-EMPTY rotate sub-tool session, then rotate via the live
    // reEvaluate seam (Phase 1 addendum C).
    //
    // FAITHFUL RATIONALE (why the bare `tool.attr Transform RZ 30` no longer
    // suffices on its own): under per-gesture commit the Move gesture
    // SELF-COMMITS at its mouse-up above, so at this idle moment there is NO
    // open wrapper session and `hasLiveEval()` is FALSE. A non-interactive wire
    // attr on a tool with no open session is FAITHFULLY inert — it stores the
    // value and applies nothing (the fresh-tool rule). The OLD non-inert
    // behavior, where this attr "rotated for free", was an ARTIFACT of the gizmo
    // session staying open at idle — exactly the artifact per-gesture commit
    // removes; `hasLiveEval()` is deliberately left session-based (addendum
    // decision C). So we explicitly open the rotate sub-session via the
    // supported testMode opener (`tool.beginSession` → openLiveSessionForTest),
    // which is the headless stand-in for production's gizmo grab. With a session
    // genuinely open, `hasLiveEval()` is true and the subsequent `tool.attr RZ
    // 30` re-runs the rotate apply through reEvaluate, rotating the mesh AND
    // leaving the rotate sub-tool session open. Two sessions are then live:
    // wrapper Move (run, self-committed) + sub-tool Rotate (panel session).
    cmd("tool.beginSession Transform");
    settle();
    auto v6BeforeRot = vert(6);
    cmd("tool.attr Transform RZ 30");
    settle();
    auto v6AfterRot = vert(6);
    assert((fabs(v6AfterRot[0] - v6BeforeRot[0]) +
            fabs(v6AfterRot[1] - v6BeforeRot[1])) > 0.05,
        "RZ=30 should rotate the mesh (non-empty rotate session); before=("
        ~ v6BeforeRot[0].to!string ~ "," ~ v6BeforeRot[1].to!string
        ~ ") after=(" ~ v6AfterRot[0].to!string ~ ","
        ~ v6AfterRot[1].to!string ~ ")");
    // The rotate attr write is a PANEL TX (no gizmo mouse-up), so it records
    // NO per-gesture in-session entry — it stays an open sub-tool session until
    // the boundary commits it. The absolute count is still stackBefore + 1: the
    // Move drag-1 in-session entry recorded above is the only thing on the
    // stack; the rotate leg adds nothing here.
    assert(undoCount() == stackBefore + 1,
        "the rotate attr write must NOT record (panel session still open); the "
        ~ "stack stays at the Move in-session entry; got "
        ~ (undoCount() - stackBefore).to!string ~ " new entries");

    // Off-gizmo Move relocate click (perpendicular to the +X arrow ⇒ clearly
    // off every gizmo bank). This is the cross-slot boundary: it must commit
    // BOTH open sessions — the wrapper Move run AND the rotate sub-tool run.
    int xoff = cast(int)(xb + 220.0 * uy);
    int yoff = cast(int)(yb - 220.0 * ux);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();

    // THE DISCRIMINATING ASSERTION: +2 at the boundary. Timeline:
    //   (1) Move drag 1's in-session entry CONSOLIDATES into ONE surviving entry
    //       at this relocate boundary (the run closes here).
    //   (2) the open rotate PANEL session commits via the cross-slot
    //       commitSessionIfOpen mirror (+1) — it did NOT leak past the boundary.
    //   (3) the off-gizmo relocate CLICK opens a fresh Move session but with
    //       T=0 / R=identity / S=1 the whole fold is identity — no vertex changes
    //       — so buildEditCmd returns null and no entry is recorded (0). The
    //       precision-stable double kernel (task 0061) eliminated the 1-ULP float
    //       round-trip that used to produce a spurious vertex change here; the
    //       skipIdentityFold guard was extended to cover composed presets in the
    //       same condition so the no-op is explicit and drift-free.
    // So TWO entries are on the stack here. (A +1 here means the rotate session
    // LEAKED past the boundary.) The geometry provenance chain (Ctrl+Z × 3)
    // still verifies correct undo ordering — Ctrl+Z #3 must restore the pristine
    // cube — providing discrimination between correct and leaked behaviour.
    // The DROP count below is +3 total: Move run 1 (1 entry) + Rotate run (1)
    // + Move run 2 / drag 2 (1 entry consolidated at drop).
    long stackAfterRelocate = undoCount();
    assert(stackAfterRelocate == stackBefore + 2,
        "the Move relocate must commit BOTH open sessions (consolidated Move "
        ~ "run 1 + Rotate run) => +2 at the boundary; got "
        ~ (stackAfterRelocate - stackBefore).to!string
        ~ " (a +1 here means the rotate session LEAKED past the boundary)");

    // Move drag 2: fresh wrapper Move run at the relocated pivot.
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    Vec3 reloc = evalPivot();
    int xc, yc; double u2, v2;
    arrowGrabPx(reloc, vp, xc, yc, u2, v2);
    int xd = xc + cast(int)(60.0 * u2);
    int yd = yc + cast(int)(60.0 * v2);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xc, yc, xd, yd, 10));
    settle();
    auto v6Run2 = vert(6);

    // Drop ⇒ commits Move run 2.
    postJson("/api/script", "tool.set Transform off");
    settle();

    long stackAfter = undoCount();
    assert(stackAfter == stackBefore + 3,
        "drag + (RZ attr) + relocate + drag + drop should produce THREE undo "
        ~ "entries (Move run 1, Rotate run, Move run 2); got "
        ~ (stackAfter - stackBefore).to!string);

    // PROVENANCE of the FIRST Move run via geometry across the Ctrl+Z chain.
    // The undo stack top-to-bottom is: Move run 2, Rotate run, Move run 1.
    //   Ctrl+Z #1 pops Move run 2  → v6 back to the post-rotate state.
    //   Ctrl+Z #2 pops the Rotate run.
    //   Ctrl+Z #3 pops Move run 1  → v6 back to the pristine cube corner.
    // The first Move run's +X displacement therefore survives until the LAST
    // pop — it did NOT leak across the rotate boundary. A regression where the
    // wrapper Move commit silently no-ops would mis-stage this geometry, not
    // just the count.
    postJson("/api/undo", "");   // pop Move run 2
    settle();
    auto v6Undo1 = vert(6);
    assert(fabs(v6Undo1[0] - v6AfterRot[0]) < 1e-3 &&
           fabs(v6Undo1[1] - v6AfterRot[1]) < 1e-3 &&
           fabs(v6Undo1[2] - v6AfterRot[2]) < 1e-3,
        "Ctrl+Z #1 should pop Move run 2 (back to the post-rotate state); got ("
        ~ v6Undo1[0].to!string ~ "," ~ v6Undo1[1].to!string ~ ","
        ~ v6Undo1[2].to!string ~ ") want ("
        ~ v6AfterRot[0].to!string ~ "," ~ v6AfterRot[1].to!string ~ ","
        ~ v6AfterRot[2].to!string ~ ")");

    postJson("/api/undo", "");   // pop Rotate run
    settle();

    postJson("/api/undo", "");   // pop Move run 1
    settle();
    auto v6Undo3 = vert(6);
    assert(fabs(v6Undo3[0] - 0.5) < 1e-3 &&
           fabs(v6Undo3[1] - 0.5) < 1e-3 &&
           fabs(v6Undo3[2] - 0.5) < 1e-3,
        "Ctrl+Z #3 should pop Move run 1 (geometry back to the pristine cube); "
        ~ "got (" ~ v6Undo3[0].to!string ~ "," ~ v6Undo3[1].to!string ~ ","
        ~ v6Undo3[2].to!string ~ ")");
}
