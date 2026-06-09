// In-session Ctrl+Z contract + forms/panel non-interference
// (record+consolidate, Phase 1).
//
// Phase-3 audit (2026-06-07): swept for stale single-coalesced-entry / "no pop"
// / whole-run-cancel assumptions. NONE remain — this file was already rewritten
// to the record+consolidate contract atomically with Move recording in Phase 1
// (the green-interval table's "Assert adjusted in: Phase 1" rows). No assert
// changed in Phase 3; the suite is re-run to confirm green alongside the new
// tests/test_run_consolidation.d.
//
// CONTRACT (record+consolidate model — per-gesture in-session recording with
// run consolidation at the boundary / tool drop):
//
//   * While the tool is LIVE, EACH completed move gizmo gesture commits its
//     own TAGGED in-session history entry on mouse-up. A run of consecutive
//     same-bank gestures therefore appears mid-run as N separate in-session
//     entries on the undo stack (count grows +1 per gesture).
//   * An in-session Ctrl+Z is a PLAIN history pop: one press steps back ONE
//     gesture (geometry to the prior gesture's end state) and the tool stays
//     LIVE; it does NOT cancel the whole run.
//   * At a run boundary (relocate / element-pick / bank-switch) or tool drop
//     the run's tagged in-session entries CONSOLIDATE into ONE surviving
//     entry. A clean N-gesture run that is dropped collapses to ONE entry (one
//     post-drop Ctrl+Z reverts the whole run); a hard boundary yields a
//     SEPARATE surviving entry.
//
// Related coverage (audited, stays green):
//   * test_property_panel_drag.d:266 — 2 ON-handle drags then DROP: the two
//     in-session entries consolidate to ONE at the drop (+1 unchanged).
//   * test_relocate_boundary.d — relocate-split surviving-entry counts
//     unchanged (boundaries consolidate); open-mid-run counts grow per gesture.
//   * test_reevaluate.d — pure-panel/beginSession coalescing: 1 entry on drop.
//
// The two cases this file pins:
//
//  (1) In-session per-gesture stepping — a single OPEN run spanning TWO
//      ON-handle drags, tool STILL LIVE: the undo stack shows +2 in-session
//      entries (each tagged inSession, sharing one runId); ONE Ctrl+Z steps
//      back the LAST gesture (geometry to post-drag-1, count -> +1); a SECOND
//      Ctrl+Z steps the first gesture (geometry to the run baseline ==
//      post-run-A, count -> floor); a THIRD Ctrl+Z pops the committed run A.
//      The tool stays LIVE throughout.
//
//  (2) Mixed gizmo + panel/forms non-interference — a gizmo drag, then an
//      off-gizmo relocate boundary (consolidates the gizmo run to one surviving
//      entry), then SEVERAL `interactive` panel value edits (the tool.panelEdit
//      testMode path), then drop. The panel edits coalesce into the SAME
//      post-boundary run; total surviving entries == 2 (the relocate machinery
//      does not perturb panel coalescing).
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

// Count of TAGGED in-session entries currently on the undo stack — the
// per-gesture steps of an open run before consolidation. Reads the new
// /api/history `inSession` field.
long inSessionCount() {
    long n = 0;
    foreach (e; getJson("/api/history")["undo"].array)
        if (("inSession" in e.object) !is null && e["inSession"].boolean) ++n;
    return n;
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

// Select vertex 6 and VERIFY it took. Do NOT drain the select's UI-undo
// entry afterwards: undoing a select restores the PREVIOUS selection — on a
// shared per-worker instance that's whatever a preceding test left (e.g. an
// edge selection in Edges mode), silently retargeting every following gesture
// at the wrong elements while every count assert stays green (the -j
// "Move 2 verts" bleed: v6 frozen at (-1,0,1), tagged/undo counts perfect).
// The select entry simply sits BELOW the floor counters captured after it;
// the bounded Ctrl+Z ladders never pop that deep.
void selectV6() {
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    settle();
    auto s = getJson("/api/selection");
    assert(s["mode"].str == "vertices"
        && s["selectedVertices"].array.length == 1
        && s["selectedVertices"].array[0].integer == 6,
        "v6 selection did not take: " ~ s.toString);
}

// Pristine cube + EMPTY undo stack, retrying if a preceding test left the
// shared per-worker vibe3d dirty. The load-bearing discipline: /api/reset is
// ITSELF undoable (SceneReset snapshots the PRE-reset mesh), so we must NEVER
// drainHistory() after it — draining would pop the SceneReset and its revert()
// would restore the prior test's dirty mesh. Instead, reset to the cube then
// history.clear (a SideEffect command: wipes BOTH stacks WITHOUT touching the
// mesh), leaving the cube pristine AND undo=0. The FINAL fallback reset is left
// UN-undone so a genuinely unrestorable prior state still leaves a clean cube.
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
// (1) In-session per-gesture stepping (record+consolidate, Phase 1).
//
//     One v6 selection used for BOTH a pre-committed run AND the open run (so
//     no select-entry noise lands between them — /api/select is itself an
//     undoable UI-undo entry, which would otherwise sit on top of the committed
//     geometry run and steal a later Ctrl+Z). Sequence:
//       select v6 -> tool.set move -> drag (run A) -> DROP (commit+consolidate
//       run A to ONE entry) -> tool.set move AGAIN -> two ON-handle drags
//       (open run B, tool LIVE — each gesture records a tagged in-session entry,
//       so the stack grows +2).
//     Stepping:
//       Ctrl+Z #1 pops the LAST gesture (v6 back to post-drag-1, count +2 -> +1,
//                 tool LIVE);
//       Ctrl+Z #2 pops the first gesture (v6 back to the run baseline ==
//                 post-run-A, count +1 -> floor, tool LIVE);
//       Ctrl+Z #3 pops the committed run A (v6 back to the pristine cube).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    selectV6();   // verified select; entry stays below the floor (see helper)

    // --- Run A: a committed gizmo drag on v6 (the entry the 3rd Ctrl+Z pops). ---
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
    postJson("/api/script", "tool.set move off");   // commit + consolidate run A
    settle();
    auto v6AfterRunA = vert(6);   // run A's displacement; popped by 3rd Ctrl+Z
    long committedFloor = undoCount();
    assert(committedFloor >= 1,
        "run A should have committed+consolidated to one entry as the history " ~
        "floor; got " ~ committedFloor.to!string);

    // --- Run B: re-activate (same v6 selection — no select entry) and open a
    //     single run of two ON-handle drags, tool STILL LIVE. ---
    postJson("/api/script", "tool.set move");
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    arrowDirPx(evalPivot(), vp, ux, uy);

    auto v6BaselineB = vert(6);   // run B's baseline (== post-run-A)

    // Drag 1: on-handle +X haul. VERIFY-AND-RETRY keyed on the UNDO COUNT (not
    // a geometry delta): under a loaded -j run the pivot/camera read right
    // after re-activation can be a frame stale, so the derived grab pixel
    // misses the arrow and the drag records nothing (the run-B-not-recorded
    // flake). Keying on the count makes single-commit DETERMINISTIC: a MISSED
    // attempt has no on-handle grab => no commit => count unchanged (retry); a
    // SUCCESSFUL attempt records EXACTLY ONE in-session entry => +1 (stop).
    // No junk entry can sneak into the count while the tool is live: clicks
    // never reach the app's selection branches (gated on !anyToolActive), and
    // the historical false-green killer was never a junk entry at all — it was
    // the drain-after-select selection bleed, fixed at selectV6().
    foreach (attempt; 0 .. 6) {
        settle();
        cam = fetchCamera();
        vp  = viewportFromCamera(cam);
        arrowDirPx(evalPivot(), vp, ux, uy);
        int xa, ya;
        arrowGrabPx(evalPivot(), vp, xa, ya);
        int xb = xa + cast(int)(60.0 * ux);
        int yb = ya + cast(int)(60.0 * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xa, ya, xb, yb, 10));
        settle();
        if (undoCount() == committedFloor + 1) break;
    }
    auto v6AfterDrag1 = vert(6);
    // Gesture 1 recorded its own in-session entry on mouse-up.
    assert(undoCount() == committedFloor + 1,
        "gesture 1 should record ONE in-session entry; floor=" ~
        committedFloor.to!string ~ " now=" ~ undoCount().to!string);

    // Drag 2: RE-DERIVE the handle from the moved pivot (ON-handle re-grab, so
    // dragAxis >= 0 and NO relocate boundary fires) and haul back -X. Hauling
    // BACK (the proven test_property_panel_drag.d pattern) keeps the second
    // mouse-DOWN cleanly on the re-derived handle so the two drags stay one
    // open run rather than tripping the relocate boundary.
    // Same undo-count-keyed verify-and-retry as drag 1.
    foreach (attempt; 0 .. 6) {
        settle();
        cam = fetchCamera();
        vp  = viewportFromCamera(cam);
        arrowDirPx(evalPivot(), vp, ux, uy);
        int xc, yc;
        arrowGrabPx(evalPivot(), vp, xc, yc);
        int xd = xc - cast(int)(40.0 * ux);
        int yd = yc - cast(int)(40.0 * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xc, yc, xd, yd, 10));
        settle();
        if (undoCount() == committedFloor + 2) break;
    }

    auto v6BothDrags = vert(6);
    // Sanity: run B accumulated a net displacement away from its baseline.
    // (When this fired historically the gestures had recorded FINE — they were
    // dragging a stale predecessor selection; see selectV6().)
    assert(fabs(v6BothDrags[0] - v6BaselineB[0])
         + fabs(v6BothDrags[1] - v6BaselineB[1])
         + fabs(v6BothDrags[2] - v6BaselineB[2]) > 1e-2,
        "run B's two drags should leave v6 displaced from its baseline");

    // Run B is OPEN: each gesture recorded its own TAGGED in-session entry, so
    // the stack now sits at floor + 2 and both new entries are inSession.
    assert(undoCount() == committedFloor + 2,
        "two open gizmo gestures must record TWO in-session entries; floor=" ~
        committedFloor.to!string ~ " now=" ~ undoCount().to!string);
    assert(inSessionCount() == 2,
        "both open-run entries must be tagged inSession; got " ~
        inSessionCount().to!string);

    // Ctrl+Z #1 (tool still LIVE) -> plain history pop of the LAST gesture:
    // v6 back to the post-drag-1 value, NOT the run baseline. Count +2 -> +1.
    playAndWait(ctrlZ(50.0));
    settle();
    auto v6Step1 = vert(6);
    assert(fabs(v6Step1[0] - v6AfterDrag1[0]) < 1e-3 &&
           fabs(v6Step1[1] - v6AfterDrag1[1]) < 1e-3 &&
           fabs(v6Step1[2] - v6AfterDrag1[2]) < 1e-3,
        "in-session Ctrl+Z #1 must step back ONLY the last gesture (v6 -> " ~
        "post-drag-1); got (" ~ v6Step1[0].to!string ~ "," ~
        v6Step1[1].to!string ~ "," ~ v6Step1[2].to!string ~ ")");
    assert(undoCount() == committedFloor + 1,
        "Ctrl+Z #1 pops exactly one in-session gesture entry; floor=" ~
        committedFloor.to!string ~ " now=" ~ undoCount().to!string);

    // Ctrl+Z #2 (tool still LIVE) -> pops the first gesture: v6 back to the run
    // baseline (== post-run-A). Count +1 -> floor.
    playAndWait(ctrlZ(60.0));
    settle();
    auto v6Step2 = vert(6);
    assert(fabs(v6Step2[0] - v6BaselineB[0]) < 1e-3 &&
           fabs(v6Step2[1] - v6BaselineB[1]) < 1e-3 &&
           fabs(v6Step2[2] - v6BaselineB[2]) < 1e-3,
        "in-session Ctrl+Z #2 must step back the first gesture (v6 -> the run " ~
        "baseline == post-run-A); got (" ~ v6Step2[0].to!string ~ "," ~
        v6Step2[1].to!string ~ "," ~ v6Step2[2].to!string ~ ")");
    assert(undoCount() == committedFloor,
        "Ctrl+Z #2 pops the run back to the committed floor; floor=" ~
        committedFloor.to!string ~ " now=" ~ undoCount().to!string);

    // Run A is still applied (the two steps only touched run B's entries).
    assert(fabs(v6Step2[0] - v6AfterRunA[0]) < 1e-3 &&
           fabs(v6Step2[1] - v6AfterRunA[1]) < 1e-3 &&
           fabs(v6Step2[2] - v6AfterRunA[2]) < 1e-3,
        "the committed run A must survive stepping run B's gestures back");

    // Ctrl+Z #3 now pops the committed run A: v6 back to its pristine cube
    // corner (0.5, 0.5, 0.5).
    playAndWait(ctrlZ(70.0));
    settle();
    auto v6Popped = vert(6);
    assert(fabs(v6Popped[0] - 0.5) < 1e-3 &&
           fabs(v6Popped[1] - 0.5) < 1e-3 &&
           fabs(v6Popped[2] - 0.5) < 1e-3,
        "Ctrl+Z #3 must pop the committed run A (v6 back to (0.5,0.5,0.5)); got ("
        ~ v6Popped[0].to!string ~ "," ~ v6Popped[1].to!string ~ "," ~
        v6Popped[2].to!string ~ ")");
    assert(undoCount() == committedFloor - 1,
        "Ctrl+Z #3 pops exactly one committed entry; expected " ~
        (committedFloor - 1).to!string ~ " got " ~ undoCount().to!string);

    postJson("/api/script", "tool.set move off");
    settle();
}

// ---------------------------------------------------------------------------
// (2) Mixed gizmo + panel/forms non-interference.
//
//     A gizmo drag (run 1) -> off-gizmo relocate boundary (consolidates run 1
//     to one surviving entry) -> SEVERAL panel value edits (the interactive
//     tool.panelEdit path) -> drop. The panel edits coalesce into the SAME
//     post-boundary run, so the total surviving entries == 2: the relocate
//     machinery does NOT perturb panel coalescing.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    selectV6();
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
    // -> click-relocate that COMMITS+CONSOLIDATES run 1 and opens a fresh
    // session. The single-gesture run consolidates to ONE surviving entry.
    int xoff = cast(int)(xb + 220.0 * uy);
    int yoff = cast(int)(yb - 220.0 * ux);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();
    assert(undoCount() == stackBefore + 1,
        "the relocate click should commit+consolidate run 1 (one surviving " ~
        "entry); got " ~ (undoCount() - stackBefore).to!string);

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
