// In-session Ctrl+Z cancels an OPEN rotate/scale sub-tool session.
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
//   (d) Post-gizmo-R-drag (mouse RELEASED, ring run still open — gizmo mouse-up
//       does not commit, per coalescing): in-session Ctrl+Z now CANCELS that
//       open run (geometry reverted, NO history pop) — the documented behavior
//       change. A second Ctrl+Z then pops the prior committed entry.
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

// Pristine cube + (near-)empty undo stack. Same discipline as the sibling
// in-session-cancel tests: drop any stale tool, let a lingering replay drain,
// drain the undo stack BEFORE the reset (/api/reset is itself undoable), reset,
// drain AFTER, and verify the cube took — retrying on a cross-test bleed.
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
        drainHistory();            // BEFORE the reset (see header of the sibling)
        postJson("/api/reset", "");
        drainHistory();            // AFTER the reset
        if (cubePristine()) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");    // last reset stands, un-undone
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
// must restore v6 to (0.5,0.5,0.5), add NO history entry, and leave the session
// reopenable (a following RZ edit lands correctly).
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

    // Reopenable: cancel CLOSED the session (faithful — a closed tool stores
    // attrs but moves nothing, D4), so re-open with beginSession, then a fresh
    // RZ=30 edit must reproduce the SAME absolute geometry as before — proving
    // the accumulator + headless mirror were reset to the baseline, not left
    // stale at the cancelled 30°.
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

    // Reopenable: cancel CLOSED the session, so re-open, then a fresh SX=2
    // reproduces v6.x=1.0 absolutely (accum reset to baseline, not stale).
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
// (d) Post-gizmo-R-drag idle: documented BEHAVIOR CHANGE.
//
//     An R ring gizmo drag leaves the rotate run OPEN after mouse-UP (gizmo
//     mouse-up does NOT commit — per-gesture coalescing). With the fix, an
//     in-session Ctrl+Z at THAT point (mouse released ⇒ activeDrag is null)
//     CANCELS the open run: geometry reverts, NO history pop. A SECOND Ctrl+Z
//     then pops the prior committed entry. (Today, pre-fix, the first Ctrl+Z
//     would have popped the prior entry instead — this asserts the new, D6-
//     consistent behavior.)
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
    //     do NOT drop the tool. The run stays OPEN (no commit on mouse-up). ---
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
    // The open run B is not yet on history.
    assert(undoCount() == committedFloor,
        "an OPEN (uncommitted) rotate run must not appear on history; floor="
        ~ committedFloor.to!string ~ " now=" ~ undoCount().to!string);

    // Ctrl+Z #1 (mouse released ⇒ activeDrag null) CANCELS the open run B:
    // geometry back to post-run-A, NO history pop. (THE BEHAVIOR CHANGE.)
    playAndWait(ctrlZ(50.0));
    settle();
    auto v6AfterCancel = vert(6);
    assert(fabs(v6AfterCancel[0] - v6AfterRunA[0]) < 1e-3 &&
           fabs(v6AfterCancel[1] - v6AfterRunA[1]) < 1e-3 &&
           fabs(v6AfterCancel[2] - v6AfterRunA[2]) < 1e-3,
        "post-gizmo-drag in-session Ctrl+Z must cancel the open run B (back to "
        ~ "post-run-A); got (" ~ v6AfterCancel[0].to!string ~ ","
        ~ v6AfterCancel[1].to!string ~ "," ~ v6AfterCancel[2].to!string ~ ")");
    assert(undoCount() == committedFloor,
        "cancelling the open run pops NOTHING from history; floor="
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
