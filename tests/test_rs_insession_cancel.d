// In-session Ctrl+Z cancels an OPEN rotate/scale sub-tool session.
//
// Phase-3 audit (2026-06-07): case (d)'s flip (post-gizmo-R-drag stepping) and
// case (e) (two-gesture rotate run -> step / drop-consolidate) already landed in
// Phase 2, atomic with R/S recording (green-interval table). Cases (a)/(b)/(c)
// are PANEL-path sessions (tool.beginSession + tool.attr, no mouse-up) whose
// session stays OPEN at idle, so cancelUncommittedEdit still aborts them
// unchanged. No assert changed in Phase 3; re-run to confirm green. The SCALE
// analogue of case (e)'s per-gesture stepping is added in
// tests/test_run_consolidation.d case (E).
//
// THE BUG (found by code review): the rotate/scale geometry sessions live on
// the R/S SUB-TOOLS (MS-5), not the XfrmTransformTool wrapper. A PANEL value
// edit (tool.attr RZ … on a live session) opens that sub-tool session at IDLE
// (mouse NOT held). Before this fix the P0 Ctrl+Z chokepoint
// (app.d navHistory → hasUncommittedEdit → cancelUncommittedEdit) was wired to
// the WRAPPER-ONLY editIsOpen() predicate, so it never saw the open sub-tool
// run: an in-session Ctrl+Z popped a prior committed step (or no-op'd on an
// empty stack) while the geometry STAYED transformed.
//
// THE FIX widens hasUncommittedEdit() to `editIsOpen() || (subToolEditOpen() &&
// activeDrag is null)` and makes cancelUncommittedEdit() abort the open R/S
// sub-tool sessions alongside its own. The `activeDrag is null` clause keeps
// MID-GIZMO-DRAG Ctrl+Z (mouse HELD) behaving exactly as before — it falls
// through to history.undo() rather than cancelling the live drag.
//
// CONTRACT pinned here (consistent with test_insession_undo_contract.d's D6
// whole-open-run-cancel):
//   (a) Rotate: beginSession → RZ value edit (geometry moves, NO history entry)
//       → in-session Ctrl+Z ⇒ geometry RESTORED, NO history pop, session
//       reopenable (a following edit works).
//   (b) Scale: same via SX.
//   (c) Combined T (wrapper) + R (sub-tool) open in ONE live session ⇒ a single
//       in-session Ctrl+Z reverts BOTH (whole-open-run).
//   (d) Post-gizmo-R-drag (mouse RELEASED): Phase 2 per-gesture recording — the
//       ring gesture SELF-COMMITS a tagged in-session entry on mouse-up, so an
//       in-session Ctrl+Z is plain history stepping: #1 pops that gesture
//       (geometry reverts, count -1), #2 pops the prior committed entry. (This
//       flips the pre-Phase-2 cancel-the-open-run behavior; (a)-(c) stay.)
//
// IMPORTANT — the Ctrl+Z MUST go through the keyboard/navHistory chokepoint, so
// it is injected as an SDL keystroke via /api/play-events. The /api/undo HTTP
// bridge calls history.undo() DIRECTLY (bypassing navHistory) and would NOT
// exercise the fix.
//
// Cube layout (centered at origin, size 1): v6 = (0.5, 0.5, 0.5).

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, sin, cos, PI;
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

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

// Post-playback / post-command settle: /api/play-events/status reports
// `finished` once events are POSTED to the SDL queue, not processed.
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

// Pristine cube + EMPTY undo stack. Same discipline as the sibling in-session
// tests: drop any stale tool, let a lingering replay drain, then reset to the
// cube and history.clear (a SideEffect command — wipes BOTH stacks WITHOUT
// touching the mesh). NEVER drainHistory() after /api/reset: SceneReset is
// itself undoable and its revert() would restore the prior test's dirty mesh.
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
        // Drop whatever the previous test left active (try all relevant presets).
        postJson("/api/script", "tool.set move off");
        postJson("/api/script", "tool.set TransformRotate off");
        postJson("/api/script", "tool.set TransformScale off");
        postJson("/api/script", "tool.set Transform off");
        foreach (_; 0 .. 200) {
            if (playerIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        // Do NOT drainHistory() after /api/reset: SceneReset is itself undoable
        // and its revert() restores the PRE-reset (prior test's dirty) mesh, so
        // a drain-after-reset can leave a standing entry that reverts geometry
        // to a stale state (the -j1 cross-test-bleed flake). history.clear is a
        // SideEffect command: it wipes BOTH stacks WITHOUT touching the mesh, so
        // the cube stays pristine AND undo=0.
        postJson("/api/reset", "");                 // cube
        postJson("/api/command", "history.clear");  // wipe stacks, keep the cube
        if (cubePristine() && undoCount() == 0) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");    // last reset stands, un-undone
    postJson("/api/command", "history.clear");
    assert(cubePristine(), "could not establish pristine cube baseline");
}

double[3] vert(int idx) {
    auto v = getJson("/api/model")["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

void assertVertex(int idx, double x, double y, double z, string label) {
    auto v = vert(idx);
    assert(fabs(v[0]-x) < 1e-3 && fabs(v[1]-y) < 1e-3 && fabs(v[2]-z) < 1e-3,
        label ~ ": v" ~ idx.to!string ~ " expected (" ~ x.to!string ~ ","
        ~ y.to!string ~ "," ~ z.to!string ~ "), got (" ~ v[0].to!string ~ ","
        ~ v[1].to!string ~ "," ~ v[2].to!string ~ ")");
}

// SDL Ctrl+Z keystroke as a play-events log fragment → handleKeyDown →
// navHistory(true). 122 = 'z', mod 64 = KMOD_LCTRL.
string ctrlZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n",
        t, t + 10.0);
}

Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}

// X-ring grab pixel (normal = +X, YZ plane) on the VISIBLE semicircle for the
// default test camera — borrowed verbatim from test_relocate_boundary_rs.d.
void ringGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy) {
    float size = gizmoSize(pivot, vp);
    float a = 110.0f * cast(float)PI / 180.0f;
    Vec3 p = Vec3(pivot.x, pivot.y + cos(a) * size, pivot.z + sin(a) * size);
    float sx, sy;
    projectToWindow(p, vp, sx, sy);
    gx = cast(int)sx; gy = cast(int)sy;
}

// ---------------------------------------------------------------------------
// (a) Rotate: in-session Ctrl+Z cancels the open rotate sub-tool session.
//
// NO selection ⇒ whole-mesh moving set, rotate pivot at the origin (selecting
// only v6 would put the pivot AT v6, leaving it fixed). v6 = (0.5, 0.5, 0.5);
// RZ=30 about the workplane Z at the origin moves it. ONE in-session Ctrl+Z
// must restore v6 to (0.5,0.5,0.5), add NO history entry, and deactivate the
// tool. A following reactivation + RZ edit must still land correctly.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    cmd("tool.set TransformRotate");

    long undoBefore = undoCount();

    // Open a live rotate session (sub-tool session, no geometry change), then
    // drive an absolute RZ value through the reEvaluate seam.
    cmd("tool.beginSession");
    assertVertex(6, 0.5, 0.5, 0.5, "rotate beginSession opens session, moves nothing");

    cmd("tool.attr TransformRotate RZ 30");
    auto vMoved = vert(6);
    assert(fabs(vMoved[0] - 0.5) + fabs(vMoved[1] - 0.5) > 1e-2,
        "RZ=30 must move v6 away from (0.5,0.5,…); got (" ~ vMoved[0].to!string
        ~ "," ~ vMoved[1].to!string ~ ")");
    // The open sub-tool run is NOT yet on history.
    assert(undoCount() == undoBefore,
        "an OPEN rotate sub-tool session must add no history entry; before="
        ~ undoBefore.to!string ~ " now=" ~ undoCount().to!string);

    // THE FIX: in-session Ctrl+Z (tool still LIVE, mouse not held) must cancel
    // the open rotate run — geometry restored, NO history pop.
    playAndWait(ctrlZ(50.0));
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "in-session Ctrl+Z must restore v6 to the pre-edit cube corner");
    assert(undoCount() == undoBefore,
        "in-session cancel of an uncommitted rotate run pops NOTHING; before="
        ~ undoBefore.to!string ~ " now=" ~ undoCount().to!string);

    cmd("tool.set TransformRotate");
    // Reopenable: cancel deactivated the tool, so reactivate and re-open with
    // beginSession. A fresh RZ=30 edit must reproduce the SAME absolute
    // geometry as before — proving the accumulator + headless mirror were reset
    // to the baseline, not left stale at the cancelled 30°.
    cmd("tool.beginSession");
    cmd("tool.attr TransformRotate RZ 30");
    auto vAgain = vert(6);
    assert(fabs(vAgain[0] - vMoved[0]) < 1e-3 && fabs(vAgain[1] - vMoved[1]) < 1e-3,
        "a following RZ=30 edit (after re-open) must reproduce the same absolute "
        ~ "geometry (accumulator reset to baseline, not stale); first=("
        ~ vMoved[0].to!string ~ "," ~ vMoved[1].to!string ~ ") again=("
        ~ vAgain[0].to!string ~ "," ~ vAgain[1].to!string ~ ")");

    // Drop commits ONE entry (normal coalescing unaffected); undo restores.
    cmd("tool.set TransformRotate off");
    settle();
    assert(undoCount() == undoBefore + 1,
        "dropping after the second edit coalesces to ONE entry; before="
        ~ undoBefore.to!string ~ " after=" ~ undoCount().to!string);
    drainHistory();
}

// ---------------------------------------------------------------------------
// (b) Scale: in-session Ctrl+Z cancels the open scale sub-tool session.
//     SX=2 about the origin ⇒ v6.x = 1.0; one in-session Ctrl+Z restores 0.5.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    cmd("tool.set TransformScale");

    long undoBefore = undoCount();

    cmd("tool.beginSession");
    assertVertex(6, 0.5, 0.5, 0.5, "scale beginSession opens session, moves nothing");

    cmd("tool.attr TransformScale SX 2");
    assertVertex(6, 1.0, 0.5, 0.5, "SX=2 ⇒ v6.x=1.0 (open scale sub-tool session)");
    assert(undoCount() == undoBefore,
        "an OPEN scale sub-tool session must add no history entry; before="
        ~ undoBefore.to!string ~ " now=" ~ undoCount().to!string);

    playAndWait(ctrlZ(50.0));
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "in-session Ctrl+Z must restore v6.x to the pre-edit 0.5");
    assert(undoCount() == undoBefore,
        "in-session cancel of an uncommitted scale run pops NOTHING; before="
        ~ undoBefore.to!string ~ " now=" ~ undoCount().to!string);

    cmd("tool.set TransformScale");
    // Reopenable: cancel deactivated the tool, so reactivate and re-open. A
    // fresh SX=2 reproduces v6.x=1.0 absolutely (accum reset to baseline, not
    // stale).
    cmd("tool.beginSession");
    cmd("tool.attr TransformScale SX 2");
    assertVertex(6, 1.0, 0.5, 0.5,
        "a following SX=2 after re-open reproduces v6.x=1.0 (accum reset)");

    cmd("tool.set TransformScale off");
    settle();
    assert(undoCount() == undoBefore + 1,
        "dropping after the second edit coalesces to ONE entry; before="
        ~ undoBefore.to!string ~ " after=" ~ undoCount().to!string);
    drainHistory();
}

// ---------------------------------------------------------------------------
// (c) Combined T (wrapper) + R (sub-tool) open in ONE live session: a single
//     in-session Ctrl+Z reverts BOTH (whole-open-run contract). On the bare
//     Transform preset (T=R=S=1) a TX edit opens the WRAPPER session and an RZ
//     edit opens the ROTATE sub-tool session — two open sessions at once. ONE
//     Ctrl+Z must cancel both and pop nothing.
//
// NO selection ⇒ whole-mesh moving set, pivot at origin so both slots move v6.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    cmd("tool.set Transform");

    long undoBefore = undoCount();

    cmd("tool.beginSession");
    cmd("tool.attr Transform TX 1");      // wrapper (Move) session open
    cmd("tool.attr Transform RZ 30");     // rotate sub-tool session open
    auto vBoth = vert(6);
    assert(!(fabs(vBoth[0] - 0.5) < 1e-3 && fabs(vBoth[1] - 0.5) < 1e-3
                                         && fabs(vBoth[2] - 0.5) < 1e-3),
        "combined T+R moved v6 away from the cube corner; got ("
        ~ vBoth[0].to!string ~ "," ~ vBoth[1].to!string ~ ")");
    assert(undoCount() == undoBefore,
        "both open sessions are uncommitted — no history entry yet; before="
        ~ undoBefore.to!string ~ " now=" ~ undoCount().to!string);

    // ONE in-session Ctrl+Z reverts the WHOLE open run (wrapper T + sub-tool R).
    playAndWait(ctrlZ(50.0));
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "one in-session Ctrl+Z must revert BOTH the open T and R sessions");
    assert(undoCount() == undoBefore,
        "whole-open-run cancel pops NOTHING from history; before="
        ~ undoBefore.to!string ~ " now=" ~ undoCount().to!string);

    cmd("tool.set Transform off");
    settle();
    drainHistory();
}

// ---------------------------------------------------------------------------
// (d) Post-gizmo-R-drag idle: Phase 2 per-gesture recording FLIP.
//
//     An R ring gizmo drag now SELF-COMMITS on mouse-UP as a tagged in-session
//     entry (record+consolidate, Phase 2). With the mouse RELEASED (activeDrag
//     is null), the run is CLOSED + recorded, so an in-session Ctrl+Z is plain
//     history stepping: Ctrl+Z #1 POPS that one ring gesture (geometry reverts
//     to post-run-A, count drops by one in-session entry, tool stays live);
//     Ctrl+Z #2 then pops the prior committed run A.
//
//     This is the case-(d) flip the plan pins to Phase 2 (the same
//     flip-in-one-phase lesson as Phase 1's Move contract): the behavior change
//     (recording closes the R/S session at mouse-up, so navHistory's whole-run
//     cancel clause no longer fires for an R/S gizmo run) and its test rewrite
//     land together. Cases (a)/(b)/(c) are PANEL paths (tool.beginSession +
//     tool.attr, no mouse-up) — their session stays OPEN at idle, so
//     cancelUncommittedEdit still aborts them: they SURVIVE UNCHANGED above.
//
//     NO selection ⇒ whole-mesh moving set, pivot at the origin so the ring
//     drag rotates v6.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();

    // --- Run A: a committed rotate ring drag (the entry the 2nd Ctrl+Z pops).
    //     Drop the tool to commit it, leaving it as the history floor. ---
    cmd("tool.set TransformRotate");
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    {
        int xa, ya;
        ringGrabPx(evalPivot(), vp, xa, ya);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xa, ya, xa + 25, ya + 25, 10));
        settle();
    }
    cmd("tool.set TransformRotate off");   // commit run A
    settle();
    auto v6AfterRunA = vert(6);
    long committedFloor = undoCount();
    assert(committedFloor >= 1,
        "rotate run A should commit one entry as the history floor; got "
        ~ committedFloor.to!string);

    // --- Run B: re-activate and do ONE ring drag, then RELEASE the mouse but
    //     do NOT drop the tool. Under Phase 2 the gizmo mouse-up SELF-COMMITS
    //     gesture B as a tagged in-session entry, so the run is CLOSED + on the
    //     history stack (one new entry above the floor). ---
    cmd("tool.set TransformRotate");
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    {
        int xb, yb;
        ringGrabPx(evalPivot(), vp, xb, yb);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xb, yb, xb + 25, yb + 25, 10));
        settle();
    }
    auto v6RunB = vert(6);
    assert(fabs(v6RunB[0] - v6AfterRunA[0]) + fabs(v6RunB[1] - v6AfterRunA[1])
                                            + fabs(v6RunB[2] - v6AfterRunA[2]) > 1e-2,
        "run B's ring drag should displace v6 from its post-run-A position");
    // FLIP: gesture B self-committed an in-session entry on mouse-up.
    assert(undoCount() == committedFloor + 1,
        "Phase 2: the ring gesture self-commits an in-session entry on mouse-up; "
        ~ "floor=" ~ committedFloor.to!string ~ " now=" ~ undoCount().to!string);

    // Ctrl+Z #1 (mouse released ⇒ activeDrag null) is plain in-session stepping:
    // POP gesture B — geometry back to post-run-A, count drops by one. (FLIP.)
    playAndWait(ctrlZ(50.0));
    settle();
    auto v6AfterStep = vert(6);
    assert(fabs(v6AfterStep[0] - v6AfterRunA[0]) < 1e-3 &&
           fabs(v6AfterStep[1] - v6AfterRunA[1]) < 1e-3 &&
           fabs(v6AfterStep[2] - v6AfterRunA[2]) < 1e-3,
        "post-gizmo-drag in-session Ctrl+Z must STEP gesture B back (to post-run-A); "
        ~ "got (" ~ v6AfterStep[0].to!string ~ ","
        ~ v6AfterStep[1].to!string ~ "," ~ v6AfterStep[2].to!string ~ ")");
    assert(undoCount() == committedFloor,
        "stepping gesture B pops exactly one in-session entry; floor="
        ~ committedFloor.to!string ~ " now=" ~ undoCount().to!string);

    // Ctrl+Z #2 now pops the prior committed run A: v6 back to the cube corner.
    playAndWait(ctrlZ(60.0));
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "the SECOND Ctrl+Z pops the prior committed rotate run A (back to cube)");
    assert(undoCount() == committedFloor - 1,
        "the second Ctrl+Z pops exactly one committed entry; expected "
        ~ (committedFloor - 1).to!string ~ " got " ~ undoCount().to!string);

    cmd("tool.set TransformRotate off");
    settle();
    drainHistory();
}

// ---------------------------------------------------------------------------
// (e) Phase 2 R-run of TWO ring gestures → step → consolidate.
//
//     TWO consecutive ring drags in ONE live session (NO relocate between them)
//     land as TWO tagged in-session entries sharing one run id. DROPPING the
//     tool then CONSOLIDATES the run into ONE surviving entry — a single
//     post-drop Ctrl+Z reverts the WHOLE run back to the cube. This is the
//     headline record+consolidate behavior for R/S: per-gesture recording mid-
//     run + run consolidation at the drop.
//
//     A SECOND pass exercises per-gesture STEPPING: two gestures, then an
//     in-session Ctrl+Z steps ONE gesture back. Geometry reverts to
//     post-gesture-1, which is itself the accumulator-restore proof — the
//     per-gesture angleAccum hook restored the rotate accumulator (it drives the
//     reverted mesh; the panel `RX ?` attr reads the wrapper's transient
//     headless slot, which resyncSession zeroes after a pop, so the accumulator
//     is observable through GEOMETRY, not the live attr — see
//     test_relocate_boundary_rs's note). The in-session undo bumps mutationVersion
//     + resyncSession re-baselines, so the wrapper's selection/mutation boundary
//     CLOSES the run on the step (the remaining gesture becomes a consolidated
//     surviving entry) — the drop is then a no-op consolidate and the post-drop
//     Ctrl+Z still reverts the survivor.
//
//     NO selection ⇒ whole-mesh moving set, pivot at the origin (X-ring keeps
//     v6.x = 0.5).
// ---------------------------------------------------------------------------
unittest {
    // --- Pass 1: 2 gestures → 2 in-session entries → DROP consolidates to 1. ---
    establishCubeBaseline();
    cmd("tool.set TransformRotate");
    long floor = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    {
        int x1, y1;
        ringGrabPx(evalPivot(), vp, x1, y1);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  x1, y1, x1 + 25, y1 + 25, 10));
        settle();
    }
    auto v6Gesture1 = vert(6);
    assert(undoCount() == floor + 1,
        "ring gesture 1 self-commits ONE in-session entry; floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);

    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    {
        int x2, y2;
        ringGrabPx(evalPivot(), vp, x2, y2);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  x2, y2, x2 + 25, y2 + 25, 10));
        settle();
    }
    auto v6Gesture2 = vert(6);
    assert(undoCount() == floor + 2,
        "ring gesture 2 self-commits a SECOND in-session entry in the same run; "
        ~ "floor=" ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    assert(fabs(v6Gesture2[1] - v6Gesture1[1]) + fabs(v6Gesture2[2] - v6Gesture1[2]) > 1e-2,
        "gesture 2 should rotate v6 further from its post-gesture-1 position");

    // DROP consolidates the two-gesture run into ONE surviving entry.
    cmd("tool.set TransformRotate off");
    settle();
    assert(undoCount() == floor + 1,
        "drop consolidates the two-gesture run into ONE surviving entry; floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);

    // A single post-drop Ctrl+Z reverts the WHOLE run back to the cube.
    playAndWait(ctrlZ(60.0));
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "one post-drop Ctrl+Z reverts the consolidated run back to the cube");
    assert(undoCount() == floor,
        "post-drop Ctrl+Z pops the single consolidated entry; floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    drainHistory();

    // --- Pass 2: 2 gestures → in-session Ctrl+Z steps ONE gesture back. ---
    establishCubeBaseline();
    cmd("tool.set TransformRotate");
    long floor2 = undoCount();

    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    {
        int x1, y1;
        ringGrabPx(evalPivot(), vp, x1, y1);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  x1, y1, x1 + 25, y1 + 25, 10));
        settle();
    }
    auto v6G1 = vert(6);

    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    {
        int x2, y2;
        ringGrabPx(evalPivot(), vp, x2, y2);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  x2, y2, x2 + 25, y2 + 25, 10));
        settle();
    }
    assert(undoCount() == floor2 + 2,
        "two ring gestures record two in-session entries; floor="
        ~ floor2.to!string ~ " now=" ~ undoCount().to!string);

    // In-session Ctrl+Z steps gesture 2 back: geometry to post-gesture-1 (the
    // restored accumulator drives the reverted mesh — the GEOMETRY proof of the
    // per-gesture hook). One in-session entry pops.
    playAndWait(ctrlZ(50.0));
    settle();
    auto v6Step = vert(6);
    assert(fabs(v6Step[0] - v6G1[0]) < 1e-3 &&
           fabs(v6Step[1] - v6G1[1]) < 1e-3 &&
           fabs(v6Step[2] - v6G1[2]) < 1e-3,
        "in-session Ctrl+Z must step gesture 2 back to post-gesture-1; got ("
        ~ v6Step[0].to!string ~ "," ~ v6Step[1].to!string ~ ","
        ~ v6Step[2].to!string ~ ")");
    assert(undoCount() == floor2 + 1,
        "stepping gesture 2 pops exactly one in-session entry; floor="
        ~ floor2.to!string ~ " now=" ~ undoCount().to!string);

    // Drop (the step already closed the run, so this is a no-op consolidate);
    // the surviving gesture-1 entry is reverted by one more Ctrl+Z.
    cmd("tool.set TransformRotate off");
    settle();
    assert(undoCount() == floor2 + 1,
        "after the step the run is already one surviving entry; the drop adds "
        ~ "nothing; floor=" ~ floor2.to!string ~ " now=" ~ undoCount().to!string);
    playAndWait(ctrlZ(70.0));
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "the final Ctrl+Z reverts the surviving gesture-1 entry back to the cube");
    assert(undoCount() == floor2,
        "the final Ctrl+Z pops the last entry; floor="
        ~ floor2.to!string ~ " now=" ~ undoCount().to!string);
    drainHistory();
}
