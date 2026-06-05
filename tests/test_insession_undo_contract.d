// In-session Ctrl+Z contract + forms/panel non-interference (Phase 3 of
// doc/transform_per_gesture_commit_plan.md §3, §6).
//
// CONTRACT (vibe3d DECISION, consistent with the long-standing in-session
// cancel semantics — NOT reference-derived for the in-session case; the
// reference captures only cover the post-drop grammar):
//
//   * While the tool is LIVE with an OPEN run, a Ctrl+Z reverts the WHOLE
//     open run via cancelUncommittedEdit() — one keystroke = the entire open
//     session (all drags since the last boundary), and it pops NOTHING from
//     history (the open run was never committed).
//   * Once a run is committed (relocate boundary / tool-drop), Ctrl+Z is a
//     plain history pop — one committed run per keystroke.
//
// Existing coverage (audited, kept green — this file only ADDS the gaps):
//   * test_property_panel_drag.d:216 — 2 ON-handle drags coalesce to 1 entry,
//     then the tool is DROPPED and a post-drop Ctrl+Z reverts both. That is
//     the committed-history path, NOT the in-session cancelUncommittedEdit
//     path.
//   * test_relocate_boundary.d (a)/(b) — relocate-split ⇒ 2 entries; in-session
//     Ctrl+Z AFTER a relocate boundary lands on the relocated pin.
//   * test_reevaluate.d — pure-panel/beginSession coalescing ⇒ 1 entry on drop.
//
// The two GAPS this file pins:
//
//  (1) In-session Ctrl+Z with NO boundary yet — a single open run spanning
//      TWO ON-handle drags, tool STILL LIVE: ONE Ctrl+Z cancels BOTH drags
//      (geometry back to the run's frozen baseline) and pops NOTHING from
//      history. A SECOND Ctrl+Z then pops the PREVIOUS committed entry (a
//      run committed before the open session was opened).
//
//  (2) Mixed gizmo + panel/forms non-interference — a gizmo drag, then an
//      off-gizmo relocate boundary (commits the gizmo run), then SEVERAL
//      `interactive` panel value edits (the tool.panelEdit testMode path),
//      then drop. The panel edits coalesce into the SAME post-boundary run;
//      total entries == 2 (the relocate machinery does not perturb panel
//      coalescing).
//
// All gizmo gestures drive the MAIN loop via drag_helpers.buildDragLog +
// /api/play-events. The testMode panel hooks (tool.panelEdit) dispatch via
// /api/command, which is marshalled onto the MAIN thread by the synchronous
// epoch-handshake bridge (the same path test_reevaluate.d relies on) — never
// a background-thread gesture.

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
// `finished` once events are POSTED to the SDL queue, not processed; wait
// ~120ms so the main loop has applied the change before reading state.
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

// Pristine cube + (near-)empty undo stack, retrying if a preceding test left
// the shared per-worker vibe3d dirty. The load-bearing discipline (mirrors
// test_relocate_boundary.d): /api/reset is ITSELF undoable (SceneReset
// snapshots the PRE-reset mesh), so we drain the undo stack BEFORE the reset
// (popping the previous test's own commands so the pre-reset mesh is already
// clean), then drain AFTER (popping only the reset + the select's UI-undo
// entry). The FINAL fallback reset is left UN-undone so a genuinely
// unrestorable prior state still leaves a clean cube to assert against.
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
        foreach (_; 0 .. 200) {
            if (playerIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        drainHistory();            // BEFORE the reset (see header)
        postJson("/api/reset", "");
        drainHistory();            // AFTER the reset
        if (cubePristine()) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");    // last reset stands, un-undone
    assert(cubePristine(), "could not establish pristine cube baseline");
}

// Authoritative gizmo pivot: evaluated ActionCenterPacket.center.
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

// Project the +X arrow handle's grab point (0.7 along the arrow) at `pivot`.
void arrowGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy) {
    float size = gizmoSize(pivot, vp);
    Vec3 arrowEnd   = Vec3(pivot.x + size,         pivot.y, pivot.z);
    Vec3 arrowStart = Vec3(pivot.x + size / 6.0f,  pivot.y, pivot.z);
    float sx1, sy1, sx2, sy2;
    projectToWindow(arrowStart, vp, sx1, sy1);
    projectToWindow(arrowEnd,   vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
}

// Screen-space +X arrow direction (unit).
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
// -> navHistory(true). 122 = 'z', mod 64 = KMOD_LCTRL.
string ctrlZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n",
        t, t + 10.0);
}

// /api/command bridge (synchronous, main-thread). Used ONLY for the testMode
// panel hooks (tool.panelEdit) — never for a gizmo gesture.
void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "/api/command '" ~ line ~ "' failed: "
        ~ r.toString);
}

// ---------------------------------------------------------------------------
// (1) In-session Ctrl+Z with NO boundary yet.
//
//     One v6 selection used for BOTH a pre-committed run AND the open run (so
//     no select-entry noise lands between them — /api/select is itself an
//     undoable UI-undo entry, which would otherwise sit on top of the committed
//     geometry run and steal the SECOND Ctrl+Z). Sequence:
//       select v6 -> tool.set move -> drag (run A) -> DROP (commit run A) ->
//       tool.set move AGAIN -> two ON-handle drags (open run B, tool LIVE).
//     A single in-session Ctrl+Z (navHistory sees the open wrapper run ->
//     cancelUncommittedEdit) reverts BOTH of run B's drags AND pops NOTHING
//     from history (count stays at the post-commit floor). A SECOND Ctrl+Z
//     then pops the previously committed run A (geometry back to the cube).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    // Drain the select's UI-undo entry so the only thing on history below the
    // open run will be the committed geometry run A (drain-after-select is safe;
    // it is NOT after a reset — see establishCubeBaseline()).
    drainHistory();

    // --- Run A: a committed gizmo drag on v6 (the entry the 2nd Ctrl+Z pops). ---
    postJson("/api/script", "tool.set move");   // default ACEN = None
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    double ux, uy;
    arrowDirPx(evalPivot(), vp, ux, uy);
    {
        int xa, ya;
        arrowGrabPx(evalPivot(), vp, xa, ya);
        int xb = xa + cast(int)(60.0 * ux);
        int yb = ya + cast(int)(60.0 * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xa, ya, xb, yb, 10));
        settle();
    }
    postJson("/api/script", "tool.set move off");   // commit run A
    settle();
    auto v6AfterRunA = vert(6);   // run A's displacement; popped by 2nd Ctrl+Z
    long committedFloor = undoCount();
    assert(committedFloor >= 1,
        "run A should have committed one entry as the history floor; got " ~
        committedFloor.to!string);

    // --- Run B: re-activate (same v6 selection — no select entry) and open a
    //     single run of two ON-handle drags, tool STILL LIVE. ---
    postJson("/api/script", "tool.set move");
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    arrowDirPx(evalPivot(), vp, ux, uy);

    auto v6BaselineB = vert(6);   // run B's frozen baseline (== post-run-A)

    // Drag 1: on-handle +X haul.
    {
        int xa, ya;
        arrowGrabPx(evalPivot(), vp, xa, ya);
        int xb = xa + cast(int)(60.0 * ux);
        int yb = ya + cast(int)(60.0 * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xa, ya, xb, yb, 10));
        settle();
    }
    // Drag 2: RE-DERIVE the handle from the moved pivot (ON-handle re-grab, so
    // dragAxis >= 0 and NO relocate boundary fires) and haul back -X. Hauling
    // BACK (the proven test_property_panel_drag.d pattern) keeps the second
    // mouse-DOWN cleanly on the re-derived handle so the two drags coalesce
    // into ONE open run rather than tripping the relocate boundary.
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    {
        int xc, yc;
        arrowGrabPx(evalPivot(), vp, xc, yc);
        int xd = xc - cast(int)(40.0 * ux);
        int yd = yc - cast(int)(40.0 * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xc, yc, xd, yd, 10));
        settle();
    }

    auto v6BothDrags = vert(6);
    // Sanity: run B accumulated a net displacement away from its baseline.
    assert(fabs(v6BothDrags[0] - v6BaselineB[0])
         + fabs(v6BothDrags[1] - v6BaselineB[1])
         + fabs(v6BothDrags[2] - v6BaselineB[2]) > 1e-2,
        "run B's two drags should leave v6 displaced from its baseline");

    // Run B is OPEN (uncommitted): history count is still the floor.
    assert(undoCount() == committedFloor,
        "an OPEN (uncommitted) run must not appear in history yet; floor=" ~
        committedFloor.to!string ~ " now=" ~ undoCount().to!string);

    // ONE in-session Ctrl+Z (tool still LIVE) -> cancelUncommittedEdit reverts
    // the WHOLE open run B (both drags) and pops NOTHING from history.
    playAndWait(ctrlZ(50.0));
    settle();

    auto v6AfterCancel = vert(6);
    assert(fabs(v6AfterCancel[0] - v6BaselineB[0]) < 1e-3 &&
           fabs(v6AfterCancel[1] - v6BaselineB[1]) < 1e-3 &&
           fabs(v6AfterCancel[2] - v6BaselineB[2]) < 1e-3,
        "one in-session Ctrl+Z must revert BOTH of run B's drags to its " ~
        "baseline (== post-run-A); got (" ~ v6AfterCancel[0].to!string ~ "," ~
        v6AfterCancel[1].to!string ~ "," ~ v6AfterCancel[2].to!string ~ ")");
    assert(undoCount() == committedFloor,
        "in-session cancel of an uncommitted run pops NOTHING from history; " ~
        "floor=" ~ committedFloor.to!string ~ " now=" ~ undoCount().to!string);

    // Run A is still applied (the cancel only touched open run B).
    assert(fabs(v6AfterCancel[0] - v6AfterRunA[0]) < 1e-3 &&
           fabs(v6AfterCancel[1] - v6AfterRunA[1]) < 1e-3 &&
           fabs(v6AfterCancel[2] - v6AfterRunA[2]) < 1e-3,
        "the committed run A must survive the in-session cancel of run B");

    // A SECOND Ctrl+Z now pops the PREVIOUS committed run A: v6 back to its
    // pristine cube corner (0.5, 0.5, 0.5).
    playAndWait(ctrlZ(60.0));
    settle();
    auto v6Popped = vert(6);
    assert(fabs(v6Popped[0] - 0.5) < 1e-3 &&
           fabs(v6Popped[1] - 0.5) < 1e-3 &&
           fabs(v6Popped[2] - 0.5) < 1e-3,
        "the SECOND Ctrl+Z must pop the previously committed run A (v6 back to "
        ~ "(0.5,0.5,0.5)); got (" ~ v6Popped[0].to!string ~ "," ~
        v6Popped[1].to!string ~ "," ~ v6Popped[2].to!string ~ ")");
    assert(undoCount() == committedFloor - 1,
        "the second Ctrl+Z pops exactly one committed entry; expected " ~
        (committedFloor - 1).to!string ~ " got " ~ undoCount().to!string);

    postJson("/api/script", "tool.set move off");
    settle();
}

// ---------------------------------------------------------------------------
// (2) Mixed gizmo + panel/forms non-interference.
//
//     A gizmo drag (run 1) -> off-gizmo relocate boundary (commits run 1) ->
//     SEVERAL panel value edits (the interactive tool.panelEdit path) -> drop.
//     The panel edits coalesce into the SAME post-boundary run, so the total
//     is exactly TWO entries: the relocate machinery does NOT perturb panel
//     coalescing (plan §4 R3 / §6 test 6).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    postJson("/api/script", "tool.set move");   // default ACEN = None
    long stackBefore = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    double ux, uy;
    arrowDirPx(evalPivot(), vp, ux, uy);

    // Run 1: on-handle +X gizmo drag.
    int xa, ya;
    arrowGrabPx(evalPivot(), vp, xa, ya);
    int xb = xa + cast(int)(60.0 * ux);
    int yb = ya + cast(int)(60.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xa, ya, xb, yb, 10));
    settle();
    auto v6AfterRun1 = vert(6);

    // Off-gizmo relocate: a discrete click well off every handle, in None mode
    // -> click-relocate that COMMITS run 1 and opens a fresh session.
    int xoff = cast(int)(xb + 220.0 * uy);
    int yoff = cast(int)(yb - 220.0 * ux);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();
    assert(undoCount() == stackBefore + 1,
        "the relocate click should commit run 1 (one new entry); got " ~
        (undoCount() - stackBefore).to!string);

    // Several panel value edits via the interactive tool.panelEdit path. They
    // REUSE the open post-boundary session (idempotent beginEdit) and must
    // COALESCE into that one run — NOT split, NOT re-trip the relocate
    // boundary (panel edits do not arrive through an off-gizmo mouse-down).
    auto v6BeforePanel = vert(6);
    cmd("tool.panelEdit 0.05 0 0");
    cmd("tool.panelEdit 0.05 0 0");
    cmd("tool.panelEdit 0.05 0 0");
    auto v6AfterPanel = vert(6);
    // Panel edits are delta-driven: three +0.05 ⇒ +0.15 along X.
    assert(fabs(v6AfterPanel[0] - (v6BeforePanel[0] + 0.15)) < 1e-3,
        "three +0.05 panel edits should accumulate to +0.15 on the open run; " ~
        "before=" ~ v6BeforePanel[0].to!string ~ " after=" ~
        v6AfterPanel[0].to!string);
    // The panel edits did NOT add any history entry while the run is open.
    assert(undoCount() == stackBefore + 1,
        "panel edits on an open run add NO history entry until drop; got " ~
        (undoCount() - stackBefore).to!string);

    // Drop -> commits the post-boundary run (gizmo-relocated start + the three
    // coalesced panel deltas) as ONE entry. Total == 2.
    postJson("/api/script", "tool.set move off");
    settle();
    assert(undoCount() == stackBefore + 2,
        "gizmo run + relocate + coalesced panel edits + drop => exactly TWO " ~
        "entries; got " ~ (undoCount() - stackBefore).to!string);

    // Ctrl+Z #1 pops the post-boundary run (gizmo-relocated + panel deltas):
    // geometry back to the post-run-1 position.
    postJson("/api/undo", "");
    settle();
    auto v6Undo1 = vert(6);
    assert(fabs(v6Undo1[0] - v6AfterRun1[0]) < 1e-3 &&
           fabs(v6Undo1[1] - v6AfterRun1[1]) < 1e-3 &&
           fabs(v6Undo1[2] - v6AfterRun1[2]) < 1e-3,
        "Ctrl+Z #1 should pop the whole post-boundary run (back to post-run-1); "
        ~ "got (" ~ v6Undo1[0].to!string ~ "," ~ v6Undo1[1].to!string ~ "," ~
        v6Undo1[2].to!string ~ ")");

    // Ctrl+Z #2 pops run 1: geometry back to the pristine cube corner.
    postJson("/api/undo", "");
    settle();
    auto v6Undo2 = vert(6);
    assert(fabs(v6Undo2[0] - 0.5) < 1e-3 &&
           fabs(v6Undo2[1] - 0.5) < 1e-3 &&
           fabs(v6Undo2[2] - 0.5) < 1e-3,
        "Ctrl+Z #2 should pop run 1 (back to the cube corner); got (" ~
        v6Undo2[0].to!string ~ "," ~ v6Undo2[1].to!string ~ "," ~
        v6Undo2[2].to!string ~ ")");
}
