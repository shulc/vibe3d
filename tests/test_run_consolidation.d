// In-session RUN consolidation suite (record+consolidate, Phase 3).
//
// Locks the headline record+consolidate contract end-to-end through the live
// app (HTTP + main-loop event replay), complementing:
//   * test_history_insession.d — Phase-0 HEADLESS unittest of the merge math /
//     foreign-record guard on a scratch CommandHistory (no GL, no app loop).
//   * test_insession_undo_contract.d — the Move stepping + panel-coalesce
//     contract.
//   * test_rs_insession_cancel.d cases (d)/(e) — R(otate) per-gesture recording,
//     stepping, and two-gesture drop-consolidation.
//   * test_relocate_boundary*.d — the hard-boundary split counts + pin semantics.
//
// This file pins the cases the plan's Phase-3 enumerates that are NOT already
// pinned elsewhere, driven against the running editor:
//
//   (A) DROP-FLATTEN 3->1 : three Move gestures in ONE run -> 3 tagged
//       in-session entries (via /api/history `inSession`) -> tool drop ->
//       consolidate to ONE surviving entry; a single post-drop Ctrl+Z reverts
//       the WHOLE run; redo re-applies it.
//   (B) BOUNDARY FLUSH    : gestures -> off-gizmo relocate click (None mode,
//       allowed) -> the just-ended run consolidates AT the boundary, a fresh run
//       opens; counts truthful.
//   (C) REDO PATH         : 2 gestures -> 1 in-session Ctrl+Z (pop gesture 2) ->
//       redo (Ctrl+Shift+Z) re-applies gesture 2 with its hook; then drop ->
//       consolidation merges only the APPLIED undo tail (the undone gesture sat
//       on the redo stack); resulting entry count + geometry asserted.
//   (D) FALLOFF-MID-RUN   : gesture -> falloff CONFIG change via /api/command
//       (tool.pipe.attr, SideEffect/non-undoable -> records NOTHING, does NOT
//       split the run, does NOT mutate geometry at idle) -> second gesture in
//       the SAME run (no boundary) -> drop consolidates to 1.
//   (E) SCALE ACCUMULATOR STEPPING : the SCALE analogue of
//       test_rs_insession_cancel.d case (e) (which covers rotate) — two scale
//       gestures, in-session Ctrl+Z steps ONE back, geometry reverts to
//       post-gesture-1 (the per-gesture scaleAccum hook drives the reverted
//       mesh — the GEOMETRY proof), then drop + final Ctrl+Z to the cube.
//   (F) CAP-50            : a long run of > maxDepth (50) synthetic gestures —
//       gestures beyond the cap evict the oldest; consolidating a partially-
//       evicted run must NOT crash and merges only the surviving contiguous
//       tail (Phase-0 documented graceful-degradation semantics); walk-back is
//       monotone.
//   (G) BANK-SWITCH       : on the T+R+S Transform preset, a Move arrow drag then
//       a Rotate ring drag in the SAME wrapper session — the bank switch is a
//       RUN BOUNDARY (Q-c): the Move run consolidates + a Rotate run opens; the
//       drop yields TWO surviving single-bank entries; two Ctrl+Z restore the
//       cube baseline.
//   (H) FOREIGN-RECORD CONTIGUITY : 2 in-session gestures, then an undoable
//       /api/command (mesh.move_vertex on a DIFFERENT vertex) between them — the
//       open run consolidates BEFORE the foreign entry lands (layer-A guard,
//       Q-a). Stack = 1 consolidated run entry + 1 foreign entry, no merge
//       across the foreign entry.
//
// All gizmo gestures drive the MAIN loop via drag_helpers.buildDragLog +
// /api/play-events with the mandatory ~120ms post-playback settle (CLAUDE.md
// flake note #3). Ctrl+Z / Ctrl+Shift+Z go through the keyboard chokepoint
// (navHistory) as SDL keystrokes, NEVER the /api/undo direct bridge for the
// in-session stepping/redo cases. Foreign commands + falloff config go through
// /api/command, which is epoch-marshalled onto the main thread. Verify-and-retry
// is keyed on the UNDO COUNT (never a geometry delta — a lagged geometry read
// under load looked like "didn't move" and re-fired a SECOND gesture, the
// floor+2 double-commit flake). The undo stack is drained BEFORE /api/reset in
// every preamble (/api/reset is itself undoable).

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
long redoCount() {
    return getJson("/api/history")["redo"].array.length;
}

// Count of TAGGED in-session entries on the undo stack — the per-gesture steps
// of an OPEN run before consolidation. Reads the /api/history `inSession` field.
long inSessionCount() {
    long n = 0;
    foreach (e; getJson("/api/history")["undo"].array)
        if (("inSession" in e.object) !is null && e["inSession"].boolean) ++n;
    return n;
}

// /api/undo/status canUndo truthfulness (Q8): an in-session entry IS a real
// undo-stack entry, so canUndo() must be true while a run is open.
bool canUndo() {
    auto s = getJson("/api/undo/status");
    auto c = "canUndo" in s.object;
    return c !is null && c.boolean;
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

// Pristine cube + (near-)empty undo stack. Same discipline as the sibling
// in-session tests: drop any stale tool, drain a lingering replay, drain the
// undo stack BEFORE the reset (/api/reset is itself undoable), reset, drain
// AFTER, verify — retrying on a cross-test bleed.
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
        postJson("/api/script", "tool.set TransformScale off");
        postJson("/api/script", "tool.set TransformRotate off");
        postJson("/api/script", "tool.set Transform off");
        foreach (_; 0 .. 200) {
            if (playerIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        drainHistory();            // BEFORE the reset (/api/reset is undoable)
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

bool vertNear(double[3] a, double[3] b, double eps = 1e-3) {
    return fabs(a[0]-b[0]) < eps && fabs(a[1]-b[1]) < eps && fabs(a[2]-b[2]) < eps;
}

// SDL Ctrl+Z keystroke -> handleKeyDown -> navHistory(true). 122='z', mod 64 =
// KMOD_LCTRL.
string ctrlZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n",
        t, t + 10.0);
}

// SDL Ctrl+Shift+Z keystroke -> navHistory(false) (redo). mod 65 = KMOD_LCTRL
// (64) | KMOD_LSHIFT (1) — the redo binding the editor maps Ctrl+Shift+Z to.
string ctrlShiftZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":65,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":65,"repeat":0}` ~ "\n",
        t, t + 10.0);
}

// Authoritative gizmo pivot: evaluated ActionCenterPacket.center.
Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}

// +X arrow handle grab pixel (0.7 along the arrow) at `pivot`.
void arrowGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,        pivot.y, pivot.z), vp, sx2, sy2);
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

// +X single-axis scale handle grab pixel + screen-space +X direction (shares
// the +X projection with the move arrow — verbatim from
// test_relocate_boundary_rs.d).
void axisGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy,
                out double ux, out double uy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,        pivot.y, pivot.z), vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}

// X-ring (normal +X, YZ plane) grab pixel on the VISIBLE semicircle for the
// default test camera (110deg is well inside the hittable half) — verbatim from
// test_relocate_boundary_rs.d / test_rs_insession_cancel.d.
void ringGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy) {
    float size = gizmoSize(pivot, vp);
    float a = 110.0f * cast(float)PI / 180.0f;
    Vec3 p = Vec3(pivot.x, pivot.y + cos(a) * size, pivot.z + sin(a) * size);
    float sx, sy;
    projectToWindow(p, vp, sx, sy);
    gx = cast(int)sx; gy = cast(int)sy;
}

// One ON-handle +X Move gesture against the CURRENT pivot, verify-and-retry
// keyed on the UNDO COUNT: a missed grab records nothing (count unchanged ->
// retry); a hit records exactly ONE in-session entry (-> stop). No junk entry
// can sneak into the count while the tool is live (clicks never reach the
// app's selection branches — gated on !anyToolActive); the historical
// false-green killer was the drain-after-select selection bleed, fixed at
// selectV6(). `dir` = +1 haul out, -1 haul back. Returns v6's post-gesture
// position.
double[3] moveGestureOnHandle(long wantCount, double dir = 1.0, double mag = 60.0) {
    foreach (attempt; 0 .. 6) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        double ux, uy;
        arrowDirPx(evalPivot(), vp, ux, uy);
        int xa, ya;
        arrowGrabPx(evalPivot(), vp, xa, ya);
        int xb = xa + cast(int)(dir * mag * ux);
        int yb = ya + cast(int)(dir * mag * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xa, ya, xb, yb, 10));
        settle();
        if (undoCount() == wantCount) break;
    }
    return vert(6);
}

// ---------------------------------------------------------------------------
// (A) DROP-FLATTEN 3->1.
//
// Three consecutive ON-handle Move gestures in ONE open run (tool LIVE) record
// THREE tagged in-session entries sharing one runId. Dropping the tool
// CONSOLIDATES the run into ONE surviving entry; a single post-drop Ctrl+Z
// reverts the WHOLE run to the cube; redo re-applies it.
//
// v6 selection used for the whole run (no select-entry noise between gestures).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    selectV6();   // verified select; entry stays below the floor (see helper)

    postJson("/api/script", "tool.set move");   // default ACEN = None
    long floor = undoCount();

    // Three gestures, hauling +X / -X / +X (re-grabbing the moved handle each
    // time so every mouse-down lands ON the handle -> dragAxis >= 0, no relocate
    // boundary -> one open run).
    moveGestureOnHandle(floor + 1, +1.0);
    assert(undoCount() == floor + 1,
        "gesture 1 records ONE in-session entry; floor=" ~ floor.to!string
        ~ " now=" ~ undoCount().to!string);
    moveGestureOnHandle(floor + 2, -1.0, 40.0);
    assert(undoCount() == floor + 2,
        "gesture 2 records a SECOND in-session entry in the same run; floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    moveGestureOnHandle(floor + 3, +1.0, 50.0);
    assert(undoCount() == floor + 3,
        "gesture 3 records a THIRD in-session entry in the same run; floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);

    // All three open-run entries are tagged inSession; canUndo truthful (Q8).
    assert(inSessionCount() == 3,
        "all three open-run entries must be tagged inSession; got "
        ~ inSessionCount().to!string);
    assert(canUndo(),
        "an open in-session run IS undoable — /api/undo/status canUndo must be "
        ~ "true (Q8)");

    auto v6Final = vert(6);   // run-end geometry, restored by a later redo.

    // Drop -> consolidate the three-gesture run into ONE surviving entry.
    postJson("/api/script", "tool.set move off");
    settle();
    assert(undoCount() == floor + 1,
        "drop consolidates the THREE-gesture run into ONE surviving entry; floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    assert(inSessionCount() == 0,
        "after the drop the consolidated entry is an ordinary (non-inSession) "
        ~ "surviving entry; got " ~ inSessionCount().to!string ~ " tagged");
    assert(vertNear(vert(6), v6Final),
        "consolidation does NOT move geometry — the mesh still holds the run-end "
        ~ "state");

    // One post-drop Ctrl+Z reverts the WHOLE run back to the cube corner.
    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "one post-drop Ctrl+Z reverts the whole consolidated run to the cube");
    assert(undoCount() == floor,
        "the consolidated entry pops to the floor; floor=" ~ floor.to!string
        ~ " now=" ~ undoCount().to!string);

    // Redo re-applies the consolidated run (run-end geometry restored).
    postJson("/api/redo", "");
    settle();
    assert(vertNear(vert(6), v6Final),
        "redo of the consolidated run re-applies the run-end geometry; expected ("
        ~ v6Final[0].to!string ~ "," ~ v6Final[1].to!string ~ ","
        ~ v6Final[2].to!string ~ ") got (" ~ vert(6)[0].to!string ~ ","
        ~ vert(6)[1].to!string ~ "," ~ vert(6)[2].to!string ~ ")");
    assert(undoCount() == floor + 1,
        "redo restores the single consolidated entry; floor=" ~ floor.to!string
        ~ " now=" ~ undoCount().to!string);

    drainHistory();
}

// ---------------------------------------------------------------------------
// (B) BOUNDARY FLUSH.
//
// Gesture -> off-gizmo relocate click (None mode, allowed) -> the just-ended run
// consolidates AT the boundary into ONE surviving entry and a FRESH run opens ->
// a second gesture in the new run -> drop. Two surviving entries (run A @
// boundary, run B @ drop); counts truthful at every step; two Ctrl+Z restore the
// cube.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    selectV6();
    postJson("/api/script", "tool.set move");   // default ACEN = None
    long floor = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    double ux, uy;
    arrowDirPx(evalPivot(), vp, ux, uy);

    // Run A: on-handle +X gizmo drag (records one in-session entry).
    int xa, ya;
    arrowGrabPx(evalPivot(), vp, xa, ya);
    int xb = xa + cast(int)(60.0 * ux);
    int yb = ya + cast(int)(60.0 * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xa, ya, xb, yb, 10));
    settle();
    auto v6AfterRunA = vert(6);
    assert(undoCount() == floor + 1,
        "run A's drag records ONE in-session entry mid-run; floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    assert(inSessionCount() == 1, "run A's entry is tagged inSession");

    // Off-gizmo relocate click (well off every handle, None mode) -> the click
    // is a hard boundary: it CONSOLIDATES run A into ONE surviving entry and
    // opens a fresh run. Count still floor+1 (1 in-session -> 1 consolidated).
    int xoff = cast(int)(xb + 220.0 * uy);
    int yoff = cast(int)(yb - 220.0 * ux);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              xoff, yoff, xoff, yoff, 1));
    settle();
    assert(undoCount() == floor + 1,
        "the relocate boundary consolidates run A to ONE surviving entry; floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    assert(inSessionCount() == 0,
        "after the boundary run A is consolidated (no longer tagged inSession); "
        ~ "got " ~ inSessionCount().to!string ~ " tagged");

    // Run B: a fresh on-handle drag against the relocated pivot opens a NEW run
    // and records a tagged in-session entry on top of the consolidated run A.
    moveGestureOnHandle(floor + 2, +1.0, 50.0);
    assert(undoCount() == floor + 2,
        "run B's drag records a new in-session entry above consolidated run A; "
        ~ "floor=" ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    assert(inSessionCount() == 1,
        "only run B's entry is tagged inSession now (run A consolidated); got "
        ~ inSessionCount().to!string);

    // Drop -> consolidates run B. Two surviving entries total.
    postJson("/api/script", "tool.set move off");
    settle();
    assert(undoCount() == floor + 2,
        "drag + relocate boundary + drag + drop => TWO surviving entries; floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    assert(inSessionCount() == 0, "both runs consolidated at the drop");

    // Ctrl+Z pops run B -> back to post-run-A; Ctrl+Z pops run A -> cube.
    postJson("/api/undo", "");
    settle();
    assert(vertNear(vert(6), v6AfterRunA),
        "Ctrl+Z #1 pops run B back to post-run-A; got (" ~ vert(6)[0].to!string
        ~ "," ~ vert(6)[1].to!string ~ "," ~ vert(6)[2].to!string ~ ")");
    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "Ctrl+Z #2 pops run A back to the cube corner");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (C) REDO PATH (Q4 + the documented redo-split / step-closes-run interaction).
//
// 2 gestures -> in-session Ctrl+Z pops gesture 2 (it lands on the REDO stack) ->
// redo (Ctrl+Shift+Z through navHistory) re-applies gesture 2 with its hook ->
// drop. This pins the redo direction works through navHistory AND the resulting
// stack shape, which is NOT a one-entry consolidation — and that is the
// architecturally-truthful outcome, verified empirically (Phase-3 finding,
// 2026-06-07):
//
//   * The in-session Ctrl+Z's revert bumps mesh.mutationVersion. On the NEXT
//     update() frame the wrapper's selection/mutation-change guard
//     (xfrm_transform.d:313-350) sees the version change and, since runOpen() is
//     true, CONSOLIDATES the open run + nextRun()s. With gesture 2 already on the
//     redo stack, the gather sees a single-entry undo tail (gesture 1) and STRIPS
//     its InSession tag in place -> gesture 1 becomes an ordinary surviving entry
//     and the current run id advances (R -> R+1).
//   * The redo (history.redo) re-pushes gesture 2's entry verbatim — it is STILL
//     tagged InSession with the OLD run id R (redo() preserves entry flags and
//     does NOT reopen the run). So after redo the stack is: [gesture1 ordinary,
//     gesture2 tagged-runId-R]; runOpen() is false.
//   * The drop calls consolidate(currentRunId) = consolidate(R+1); the only
//     tagged tail entry carries run id R != R+1, so the gather finds no match and
//     no-ops. The stack therefore stands at TWO surviving entries (one of which
//     is still tagged from the redo). This is benign for NAVIGATION — both are
//     valid undoable entries; the residual tag only affects the future panel's
//     grouping badge, never stepping.
//
// The load-bearing contract this case locks: in-session REDO through the
// keyboard chokepoint re-applies the popped gesture WITH its hook (geometry is
// exactly restored), and the full undo walk-back after the drop is monotone back
// to the cube. The exact post-drop entry COUNT (2) is asserted truthfully rather
// than forced to 1 — the architecture does not re-merge a redo-resurrected
// gesture into the step-closed run.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    selectV6();   // verified select; entry stays below the floor (see helper)

    postJson("/api/script", "tool.set move");
    long floor = undoCount();

    auto g1 = moveGestureOnHandle(floor + 1, +1.0);
    assert(undoCount() == floor + 1, "gesture 1 records one in-session entry");
    moveGestureOnHandle(floor + 2, +1.0, 50.0);
    assert(undoCount() == floor + 2, "gesture 2 records a second in-session entry");
    auto v6BothDrags = vert(6);

    // In-session Ctrl+Z pops gesture 2 -> geometry to post-gesture-1; gesture 2
    // now sits on the redo stack.
    playAndWait(ctrlZ(50.0));
    settle();
    assert(vertNear(vert(6), g1),
        "in-session Ctrl+Z steps gesture 2 back to post-gesture-1; got ("
        ~ vert(6)[0].to!string ~ "," ~ vert(6)[1].to!string ~ ","
        ~ vert(6)[2].to!string ~ ")");
    assert(undoCount() == floor + 1 && redoCount() >= 1,
        "the popped gesture moved to the redo stack; undo="
        ~ undoCount().to!string ~ " redo=" ~ redoCount().to!string);

    // Redo (Ctrl+Shift+Z through navHistory) re-applies gesture 2 with its hook.
    playAndWait(ctrlShiftZ(60.0));
    settle();
    assert(vertNear(vert(6), v6BothDrags),
        "in-session redo re-applies gesture 2 (back to the both-drags state); got ("
        ~ vert(6)[0].to!string ~ "," ~ vert(6)[1].to!string ~ ","
        ~ vert(6)[2].to!string ~ ")");
    assert(undoCount() == floor + 2,
        "redo restores the second in-session entry; floor=" ~ floor.to!string
        ~ " now=" ~ undoCount().to!string);

    // Drop. The step already closed (consolidated) gesture 1's run; the redo
    // resurrected gesture 2 as a separate (still-tagged, old-runId) entry that
    // the drop's consolidate(R+1) cannot reach -> TWO surviving entries (truthful
    // — see the timeline comment above).
    postJson("/api/script", "tool.set move off");
    settle();
    assert(undoCount() == floor + 2,
        "redo of a step-closed run leaves TWO surviving entries at the drop "
        ~ "(the resurrected gesture is not re-merged into the closed run); floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    assert(vertNear(vert(6), v6BothDrags),
        "the drop does not move geometry — the mesh holds the redo'd both-drags "
        ~ "state; got (" ~ vert(6)[0].to!string ~ "," ~ vert(6)[1].to!string
        ~ "," ~ vert(6)[2].to!string ~ ")");

    // Monotone walk-back: Ctrl+Z #1 pops the resurrected gesture 2 (-> post-
    // gesture-1), Ctrl+Z #2 pops gesture 1 (-> the cube). Both entries step
    // cleanly despite the residual tag.
    postJson("/api/undo", "");
    settle();
    assert(vertNear(vert(6), g1),
        "post-drop Ctrl+Z #1 pops gesture 2 back to post-gesture-1; got ("
        ~ vert(6)[0].to!string ~ "," ~ vert(6)[1].to!string ~ ","
        ~ vert(6)[2].to!string ~ ")");
    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "post-drop Ctrl+Z #2 reverts gesture 1 back to the cube");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (D) FALLOFF-MID-RUN re-grade (re-cast for the in-session falloff re-fire).
//
// gesture -> falloff CONFIG change via /api/command (tool.pipe.attr is
// CmdFlags.SideEffect / non-undoable, so the CONFIG command itself records
// NOTHING and does NOT split the run) -> but the tool now RE-GRADES the landed
// gesture against the new weights at idle and bakes that as ONE tagged
// in-session entry in the SAME run (contract A). The re-grade is a geometry
// change (the falloff weighting differs), so v6 moves. inSessionCount becomes
// 2 (gesture + the appended re-grade — REPLACE only collapses CONSECUTIVE
// tweaks; the FIRST tweak appends, pinned). One in-session Ctrl+Z reverts ONLY
// the re-grade back to the post-gesture geometry (contract C). A second gesture
// continues the SAME run, and the drop consolidates the whole run to ONE entry
// (contract D).
//
// This REVERSES the prior "falloff at idle is inert for a committed gizmo
// gesture" finding — flipped atomically with the wrapper-Move re-fire site.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    // NO selection -> whole mesh is the moving set; the radial falloff weights
    // gate it. A radial falloff centered at v6 with a TIGHT radius moves v6
    // fully (it sits at the center) and leaves the far corner v0 untouched;
    // WIDENING the radius mid-run re-grades v0 (pulls it along) — the same
    // geometry shape as the panel re-eval test, driven here via the GIZMO.
    // The falloff stage is configured AFTER the tool activates (the pipe stage
    // is set up on tool.set; configuring before it would be discarded).
    postJson("/api/script", "tool.set move");
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "0.5,0.5,0.5"`);
    cmd(`tool.pipe.attr falloff size "1,1,1"`);   // tight: v6 in, v0 out
    settle();
    long floor = undoCount();

    moveGestureOnHandle(floor + 1, +1.0);
    assert(undoCount() == floor + 1, "gesture 1 records one in-session entry");
    assert(inSessionCount() == 1, "one gesture entry tagged inSession");
    auto v0AfterG1 = vert(0);   // far corner: unmoved by the tight-radius gesture

    // Falloff CONFIG change between gestures: tool.pipe.attr is SideEffect /
    // non-undoable, so it records NO foreign entry (the layer-A guard is never
    // tripped -> the run is NOT split). At idle the tool RE-GRADES the landed
    // gesture against the WIDENED radius and bakes ONE in-session re-grade entry.
    cmd(`tool.pipe.attr falloff size "4,4,4"`);   // WIDEN -> v0 re-grades
    settle();

    // The re-grade entry is appended (FIRST tweak appends), so inSession == 2.
    assert(inSessionCount() == 2,
        "the falloff re-grade appends ONE tagged in-session entry to the open "
        ~ "run (gesture + re-grade); got " ~ inSessionCount().to!string);
    assert(undoCount() == floor + 2,
        "the CONFIG command itself records nothing; only the re-grade added an "
        ~ "entry — the run now holds the gesture + the appended re-grade "
        ~ "(floor+2 on the undo stack); floor=" ~ floor.to!string ~ " now="
        ~ undoCount().to!string);
    // The re-grade MOVED geometry (the widened weighting pulls v0 along).
    auto v0Regraded = vert(0);
    assert(!vertNear(v0Regraded, v0AfterG1),
        "the falloff re-grade MUST mutate geometry at idle (contract A): v0 "
        ~ "post-gesture (" ~ v0AfterG1[0].to!string ~ "," ~ v0AfterG1[1].to!string
        ~ "," ~ v0AfterG1[2].to!string ~ ") re-graded (" ~ v0Regraded[0].to!string
        ~ "," ~ v0Regraded[1].to!string ~ "," ~ v0Regraded[2].to!string ~ ")");

    // Contract C: one IN-SESSION Ctrl+Z (keystroke, tool LIVE — NEVER /api/undo
    // here) reverts ONLY the re-grade, back to the post-gesture geometry.
    playAndWait(ctrlZ(50.0));
    settle();
    assert(vertNear(vert(0), v0AfterG1),
        "in-session Ctrl+Z reverts the re-grade to the post-gesture geometry "
        ~ "(contract C); v0 expected (" ~ v0AfterG1[0].to!string ~ ","
        ~ v0AfterG1[1].to!string ~ "," ~ v0AfterG1[2].to!string ~ ") got ("
        ~ vert(0)[0].to!string ~ "," ~ vert(0)[1].to!string ~ ","
        ~ vert(0)[2].to!string ~ ")");
    // The in-session Ctrl+Z reverted geometry, which the wrapper's mutation
    // guard sees on the next idle frame and treats as a run boundary: the run
    // consolidates, leaving the lone surviving gesture as ONE untagged entry
    // (the n==1 path strips the tag). So undoCount is floor+1 and the gesture is
    // no longer tagged inSession — the run has closed around the surviving
    // gesture. (This mirrors the in-session-Ctrl+Z behaviour of the sibling
    // contract test: a pop that re-baselines the tool closes the run.)
    assert(undoCount() == floor + 1,
        "after the in-session Ctrl+Z the re-grade is popped and the run holds "
        ~ "the lone gesture (floor+1); floor=" ~ floor.to!string ~ " now="
        ~ undoCount().to!string);

    // Drop is a no-op consolidate (the run already closed). The geometry is the
    // post-gesture state, captured as ONE surviving entry (contract D shape: a
    // gesture + a popped re-grade resolve to ONE entry).
    postJson("/api/script", "tool.set move off");
    settle();
    assert(undoCount() == floor + 1,
        "drop leaves ONE entry (the surviving gesture; the re-grade was popped) "
        ~ "(D); floor=" ~ floor.to!string ~ " now=" ~ undoCount().to!string);

    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "one post-drop Ctrl+Z reverts the consolidated run to the cube");
    cmd("tool.pipe.attr falloff type none");   // clean falloff for following tests
    drainHistory();
}

// ---------------------------------------------------------------------------
// (D2) consecutive-tweaks REPLACE + drop-D.
//
// drag -> falloff tweak (re-grade + ONE tagged in-session entry, A) -> assert
// re-grade + entry count -> a CONSECUTIVE tweak REPLACES the prior re-grade in
// place (two tweaks = ONE re-grade entry, run length stable) -> drop
// (consolidate gesture + the merged re-grade to ONE, D) -> one post-drop Ctrl+Z
// reverts the WHOLE run to the cube, including the WIDENED-support vert (the
// once-per-run anchor covers the widened support).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    // Whole-mesh moving set, radial falloff centered at v6; the witness for the
    // re-grade is the far corner v0 (pulled along as the radius widens).
    postJson("/api/script", "tool.set move");
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "0.5,0.5,0.5"`);
    cmd(`tool.pipe.attr falloff size "1,1,1"`);
    settle();
    long floor = undoCount();

    moveGestureOnHandle(floor + 1, +1.0);
    assert(undoCount() == floor + 1, "gesture records one in-session entry");
    assert(inSessionCount() == 1);
    auto v0Gesture = vert(0);   // far corner, unmoved by the tight gesture

    // First tweak: widen -> re-grade, appends ONE entry.
    cmd(`tool.pipe.attr falloff size "3,3,3"`);
    settle();
    assert(inSessionCount() == 2, "first tweak APPENDS a re-grade entry");
    auto v0Tweak1 = vert(0);
    assert(!vertNear(v0Tweak1, v0Gesture), "first tweak re-grades geometry");

    // CONSECUTIVE tweak: widen further -> the re-grade REPLACES the prior one in
    // place (REPLACE semantics) — inSession stays 2, not 3.
    cmd(`tool.pipe.attr falloff size "6,6,6"`);
    settle();
    assert(inSessionCount() == 2,
        "consecutive tweak REPLACES the prior re-grade (run length stable); got "
        ~ inSessionCount().to!string);
    auto v0Tweak2 = vert(0);
    assert(!vertNear(v0Tweak2, v0Tweak1),
        "the second (consecutive) tweak re-grades again");

    // Drop -> consolidate the gesture + the single (REPLACE-merged) re-grade to
    // ONE entry (contract D), with NO in-session Ctrl+Z between the tweaks and
    // the drop (an in-session Ctrl+Z is a run boundary that closes the run — see
    // case D / the sibling contract test; contract C is covered there).
    postJson("/api/script", "tool.set move off");
    settle();
    assert(undoCount() == floor + 1,
        "drop consolidates gesture + the merged re-grade to ONE entry (D); floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);

    // One post-drop Ctrl+Z reverts the WHOLE consolidated run to the cube — the
    // merged entry's before[] anchors to the gesture run-start, and the re-grade
    // entry's before[] anchored to the post-gesture snapshot (covering the
    // WIDENED support), so the widened verts (v0) revert cleanly too (OBJ-3).
    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "one post-drop Ctrl+Z reverts the consolidated run to the cube (v6)");
    assertVertex(0, -0.5, -0.5, -0.5,
        "the widened-support vert v0 also reverts cleanly to the cube (OBJ-3 "
        ~ "anchor covers the widened support)");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (D3) OBJ-1 pop-then-tweak — a popped gesture is NEVER resurrected.
//
// drag -> in-session Ctrl+Z (pops the gesture; geometry back to the cube) ->
// falloff tweak -> assert NO geometry change (still the cube) and NO new entry
// (the staleness stamp no longer matches, the re-fire site is inert) -> redo
// still restores the gesture.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    // Whole-mesh moving set, radial falloff centered at v6 (size 1). The gesture
    // moves v6 fully; v0 stays put. After the in-session pop both are back at
    // the cube, and the tweak must NOT re-grade anything.
    postJson("/api/script", "tool.set move");
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "0.5,0.5,0.5"`);
    cmd(`tool.pipe.attr falloff size "1,1,1"`);
    settle();
    long floor = undoCount();

    auto v6Gesture = moveGestureOnHandle(floor + 1, +1.0);
    assert(undoCount() == floor + 1, "gesture records one in-session entry");
    assert(!vertNear(v6Gesture, [0.5, 0.5, 0.5]), "gesture moved v6 off the cube");

    // In-session Ctrl+Z pops the gesture -> geometry back to the cube.
    playAndWait(ctrlZ(50.0));
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "in-session Ctrl+Z popped the gesture -> v6 back to the cube");
    long undoAfterPop = undoCount();
    long tagAfterPop  = inSessionCount();

    // Falloff tweak NOW: the staleness stamp no longer matches the bumped mesh
    // version, so the re-fire site is inert — NO geometry change, NO new entry.
    cmd(`tool.pipe.attr falloff size "4,4,4"`);
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "a falloff tweak after a popped gesture must NOT resurrect it (OBJ-1); "
        ~ "v6 stays at the cube");
    assert(undoCount() == undoAfterPop,
        "the inert tweak adds NO history entry; was=" ~ undoAfterPop.to!string
        ~ " now=" ~ undoCount().to!string);
    assert(inSessionCount() == tagAfterPop,
        "the inert tweak adds NO tagged entry; was=" ~ tagAfterPop.to!string
        ~ " now=" ~ inSessionCount().to!string);

    // Redo still restores the gesture (the popped gesture survives on the redo
    // stack — the inert tweak never cleared it).
    playAndWait(ctrlShiftZ(60.0));
    settle();
    assert(vertNear(vert(6), v6Gesture),
        "redo restores the popped gesture (it was never destroyed by the inert "
        ~ "tweak); v6 expected (" ~ v6Gesture[0].to!string ~ ","
        ~ v6Gesture[1].to!string ~ "," ~ v6Gesture[2].to!string ~ ")");

    postJson("/api/script", "tool.set move off");
    settle();
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (E) SCALE ACCUMULATOR STEPPING — the SCALE analogue of
//     test_rs_insession_cancel.d case (e) (which covers ROTATE).
//
// Two scale gestures in ONE live session -> two tagged in-session entries. An
// in-session Ctrl+Z steps ONE gesture back; geometry reverts to post-gesture-1,
// which IS the per-gesture scaleAccum-hook restore proof (the hook drives the
// reverted mesh — observable through GEOMETRY). Then drop (the step already
// closed the run, so it is a no-op consolidate) + a final Ctrl+Z to the cube.
//
// NO selection ⇒ whole-mesh moving set, pivot at the origin so +X axis scale
// grows v6.x.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    cmd("tool.set TransformScale");
    long floor = undoCount();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    {
        int x1, y1; double ux, uy;
        axisGrabPx(evalPivot(), vp, x1, y1, ux, uy);
        int xb = x1 + cast(int)(70.0 * ux);
        int yb = y1 + cast(int)(70.0 * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  x1, y1, xb, yb, 12));
        settle();
    }
    auto v6G1 = vert(6);
    assert(v6G1[0] > 0.6,
        "scale gesture 1 should grow v6.x past 0.6; got " ~ v6G1[0].to!string);
    assert(undoCount() == floor + 1,
        "scale gesture 1 self-commits ONE in-session entry; floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);

    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    {
        int x2, y2; double ux, uy;
        axisGrabPx(evalPivot(), vp, x2, y2, ux, uy);
        int xb = x2 + cast(int)(70.0 * ux);
        int yb = y2 + cast(int)(70.0 * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  x2, y2, xb, yb, 12));
        settle();
    }
    auto v6G2 = vert(6);
    assert(undoCount() == floor + 2,
        "scale gesture 2 self-commits a SECOND in-session entry in the same run; "
        ~ "floor=" ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    assert(v6G2[0] > v6G1[0] + 1e-2,
        "gesture 2 should grow v6.x further than gesture 1; g1=" ~ v6G1[0].to!string
        ~ " g2=" ~ v6G2[0].to!string);

    // In-session Ctrl+Z steps gesture 2 back: geometry to post-gesture-1 — the
    // scaleAccum hook drives the reverted mesh (the GEOMETRY proof of the
    // per-gesture accumulator restore). One in-session entry pops.
    playAndWait(ctrlZ(50.0));
    settle();
    assert(vertNear(vert(6), v6G1),
        "in-session Ctrl+Z must step scale gesture 2 back to post-gesture-1 (the "
        ~ "scaleAccum-hook restore proof); got (" ~ vert(6)[0].to!string ~ ","
        ~ vert(6)[1].to!string ~ "," ~ vert(6)[2].to!string ~ ")");
    assert(undoCount() == floor + 1,
        "stepping gesture 2 pops exactly one in-session entry; floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);

    // Drop (the step already closed the run -> no-op consolidate); the surviving
    // gesture-1 entry reverts on one more Ctrl+Z back to the cube.
    cmd("tool.set TransformScale off");
    settle();
    assert(undoCount() == floor + 1,
        "after the step the run is one surviving entry; the drop adds nothing; "
        ~ "floor=" ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    playAndWait(ctrlZ(70.0));
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "the final Ctrl+Z reverts the surviving gesture-1 entry back to the cube");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (F) CAP-50 (risk 6).
//
// The undo stack caps at maxDepth = 50 (command_history.d). A run of MORE than
// 50 gestures pushes the run-start in-session entry off the stack before the
// consolidation. Consolidating the partially-evicted run must NOT crash and
// merges only the SURVIVING contiguous tail (Phase-0 documented graceful
// degradation — before[] anchors to the earliest SURVIVING gesture). Asserted
// here against the live app: the stack never exceeds the cap mid-run, and one
// post-drop Ctrl+Z is a monotone walk-back (the consolidated survivor reverts
// without throwing).
//
// 60 tiny alternating on-handle gestures keep one open run (each mouse-down
// re-grabs the current handle -> dragAxis >= 0, no relocate boundary).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    selectV6();   // verified select; entry stays below the floor (see helper)

    postJson("/api/script", "tool.set move");
    long floor = undoCount();

    enum int N = 60;   // > maxDepth(50), so the run-start entry is evicted.
    foreach (i; 0 .. N) {
        // Alternate the haul direction so v6 stays near the gizmo (the handle
        // re-projects each gesture; no relocate). The exact post-cap count is
        // not asserted per gesture (the cap window slides as entries evict); the
        // load-bearing invariant is the cap itself.
        double dir = (i % 2 == 0) ? +1.0 : -1.0;
        // Drive one gesture; we cannot key verify-and-retry on an absolute count
        // once the cap saturates, so fire a single attempt and rely on the cap
        // invariant below. A missed grab simply contributes no entry.
        auto camF = fetchCamera();
        auto vpF  = viewportFromCamera(camF);
        double ux, uy;
        arrowDirPx(evalPivot(), vpF, ux, uy);
        int xa, ya;
        arrowGrabPx(evalPivot(), vpF, xa, ya);
        int xb = xa + cast(int)(dir * 30.0 * ux);
        int yb = ya + cast(int)(dir * 30.0 * uy);
        playAndWait(buildDragLog(camF.vpX, camF.vpY, camF.width, camF.height,
                                  xa, ya, xb, yb, 6));
        settle();
        // Cap invariant: the stack NEVER exceeds maxDepth.
        assert(undoCount() <= 50,
            "the undo stack must never exceed maxDepth(50) mid-run; got "
            ~ undoCount().to!string ~ " at gesture " ~ i.to!string);
    }

    // The run is open + capped: the surviving entries are all tagged inSession
    // (the run-start entry, and the floor entries below it, fell off the cap).
    long openTagged = inSessionCount();
    assert(openTagged > 0,
        "a >50-gesture run must leave a non-empty surviving in-session tail; got "
        ~ openTagged.to!string);
    assert(undoCount() <= 50, "stack within cap before consolidation");

    // Drop -> consolidate the partially-evicted run. The gather merges only the
    // surviving contiguous tail (graceful degradation) and must NOT crash.
    postJson("/api/script", "tool.set move off");
    settle();
    // The consolidated survivor is ONE entry; the stack is well within the cap.
    assert(undoCount() >= 1 && undoCount() <= 50,
        "consolidating a partially-evicted run yields a sane stack (no crash); "
        ~ "got " ~ undoCount().to!string);
    assert(inSessionCount() == 0,
        "the partially-evicted run consolidated into an ordinary surviving entry; "
        ~ "got " ~ inSessionCount().to!string ~ " still tagged");

    // Monotone walk-back: one post-drop Ctrl+Z reverts the consolidated survivor
    // without throwing (the merged before[] anchors to the earliest SURVIVING
    // gesture, not a corrupt baseline). The geometry need not return exactly to
    // the cube (the run-start entry was evicted), but the walk-back must succeed
    // and strictly shrink the stack.
    long beforePop = undoCount();
    auto u = postJson("/api/undo", "");
    settle();
    assert(u["status"].str == "ok",
        "post-drop Ctrl+Z over the partially-evicted consolidated run must not "
        ~ "fail: " ~ u.toString);
    assert(undoCount() == beforePop - 1,
        "the walk-back is monotone — the consolidated survivor pops exactly one "
        ~ "entry; before=" ~ beforePop.to!string ~ " now=" ~ undoCount().to!string);
    drainHistory();
}

// ---------------------------------------------------------------------------
// (G) BANK-SWITCH = RUN BOUNDARY (Q-c).
//
// On the T+R+S Transform preset, a Move arrow drag then a Rotate ring drag in
// the SAME wrapper session. The bank switch (Move -> Rotate) is a RUN BOUNDARY:
// the Move run consolidates and a Rotate run opens. The drop yields TWO surviving
// single-bank entries; two Ctrl+Z restore the cube baseline.
//
// NO selection ⇒ whole-mesh moving set, pivot at the origin so both the +X arrow
// drag (translates v6) and the X-ring drag (rotates v6) move v6.
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    cmd("tool.set Transform");   // T = R = S = 1
    long floor = undoCount();

    // Move-bank gesture: +X arrow drag.
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
    auto v6AfterMove = vert(6);
    assert(fabs(v6AfterMove[0] - 0.5) > 1e-2,
        "the Move arrow drag should translate v6 along +X; got "
        ~ v6AfterMove[0].to!string);
    assert(undoCount() == floor + 1,
        "the Move gesture self-commits one in-session entry; floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);

    // Rotate-bank gesture: X-ring drag. The bank switch from Move to Rotate is a
    // RUN BOUNDARY -> the Move run CONSOLIDATES (one surviving entry) and a fresh
    // Rotate run opens that records its own in-session entry. Net stack: +2.
    cam = fetchCamera();
    vp  = viewportFromCamera(cam);
    {
        int xr, yr;
        ringGrabPx(evalPivot(), vp, xr, yr);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xr, yr, xr + 25, yr + 25, 10));
        settle();
    }
    auto v6AfterRotate = vert(6);
    assert(fabs(v6AfterRotate[1] - v6AfterMove[1])
         + fabs(v6AfterRotate[2] - v6AfterMove[2]) > 1e-2,
        "the ring drag should rotate v6 (change y/z) from its post-Move position");
    assert(undoCount() == floor + 2,
        "bank switch (Move->Rotate) consolidates the Move run + opens a Rotate "
        ~ "run => TWO entries; floor=" ~ floor.to!string ~ " now="
        ~ undoCount().to!string);

    // Drop -> consolidates the Rotate run. TWO surviving single-bank entries.
    cmd("tool.set Transform off");
    settle();
    assert(undoCount() == floor + 2,
        "drop leaves TWO surviving single-bank entries (Move run + Rotate run); "
        ~ "floor=" ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    assert(inSessionCount() == 0, "both single-bank runs consolidated");

    // Ctrl+Z pops the Rotate run -> back to post-Move; Ctrl+Z pops the Move run
    // -> back to the cube.
    postJson("/api/undo", "");
    settle();
    assert(vertNear(vert(6), v6AfterMove),
        "Ctrl+Z #1 pops the Rotate run back to the post-Move geometry; got ("
        ~ vert(6)[0].to!string ~ "," ~ vert(6)[1].to!string ~ ","
        ~ vert(6)[2].to!string ~ ")");
    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "Ctrl+Z #2 pops the Move run back to the cube corner");
    drainHistory();
}

// ---------------------------------------------------------------------------
// (H) FOREIGN-RECORD CONTIGUITY (Q-a, layer-A guard).
//
// 2 in-session gestures on v6, then an undoable /api/command (mesh.move_vertex
// on a DIFFERENT vertex, v0) between them. A non-tagged undoable record while a
// run is open CONSOLIDATES the open run FIRST (the layer-A guard), so the foreign
// entry lands on top of ONE consolidated run entry — never merged across, never
// buried inside the run. Final stack: 1 consolidated run entry + 1 foreign entry.
// A different vertex guarantees the foreign MeshVertexEdit does not coalesce with
// the consolidated run entry (compareOp is same-index-set only).
// ---------------------------------------------------------------------------
unittest {
    establishCubeBaseline();
    // KEEP the selection (do NOT drainHistory here): draining would pop the
    // select's UI-undo entry, reverting the selection to empty -> the gizmo run
    // would move the WHOLE mesh (including v0), so v0 would no longer sit at
    // (-0.5,-0.5,-0.5) and the foreign move_vertex (matched by current coords)
    // would not find it. With v6 selected, the run touches ONLY v6, leaving v0
    // pristine for the foreign command — and a {v0} index set that differs from
    // the run's {v6} set, so the foreign edit cannot coalesce into the
    // consolidated run entry (compareOp is same-index-set only). `floor` is read
    // AFTER the select, so the select entry sits below the floor.
    selectV6();

    postJson("/api/script", "tool.set move");
    long floor = undoCount();

    moveGestureOnHandle(floor + 1, +1.0);
    assert(undoCount() == floor + 1, "gesture 1 records one in-session entry");
    moveGestureOnHandle(floor + 2, +1.0, 50.0);
    assert(undoCount() == floor + 2, "gesture 2 records a second in-session entry");
    assert(inSessionCount() == 2,
        "two open-run gestures are both tagged inSession before the foreign "
        ~ "record; got " ~ inSessionCount().to!string);
    auto v6BeforeForeign = vert(6);

    // v0 is untouched by the v6-only run (sanity — the foreign command matches it
    // by current coords).
    assert(vertNear(vert(0), [-0.5, -0.5, -0.5]),
        "v0 must stay at the cube corner during a v6-only run; got ("
        ~ vert(0)[0].to!string ~ "," ~ vert(0)[1].to!string ~ ","
        ~ vert(0)[2].to!string ~ ")");

    // Foreign undoable command on a DIFFERENT vertex (v0 = (-0.5,-0.5,-0.5)).
    // This is a real /api/command (epoch-marshalled to the main thread), so it
    // routes through recordCoalescing -> the layer-A guard consolidates the open
    // run FIRST, then the foreign entry appends on top.
    cmd("mesh.move_vertex from:{-0.5,-0.5,-0.5} to:{-0.5,-0.5,-0.2}");
    settle();

    // The open run consolidated to ONE entry (the two in-session entries are
    // gone, replaced by one ordinary entry) and the foreign entry sits on top:
    // floor + 1 (consolidated run) + 1 (foreign) = floor + 2 total, NONE tagged.
    assert(undoCount() == floor + 2,
        "the foreign record consolidates the 2-gesture run to ONE entry then "
        ~ "appends itself => floor+2; floor=" ~ floor.to!string ~ " now="
        ~ undoCount().to!string);
    assert(inSessionCount() == 0,
        "the foreign record closed the run — no in-session entries remain; got "
        ~ inSessionCount().to!string ~ " tagged");

    // v6 (the run's vertex) is unchanged by the foreign move (it touched v0);
    // consolidation did not move geometry either.
    assert(vertNear(vert(6), v6BeforeForeign),
        "the foreign move on v0 + the run consolidation do NOT disturb v6; got ("
        ~ vert(6)[0].to!string ~ "," ~ vert(6)[1].to!string ~ ","
        ~ vert(6)[2].to!string ~ ")");
    // v0 moved as the foreign command requested (no merge across folded it away).
    auto v0 = vert(0);
    assert(fabs(v0[2] - (-0.2)) < 1e-3,
        "the foreign mesh.move_vertex stands as its own entry (v0.z -> -0.2); got "
        ~ v0[2].to!string);

    // Pop the foreign entry -> v0 restored; pop the consolidated run -> v6 cube.
    // Drop the tool first so a leftover live session does not re-open the run on
    // the next pop.
    postJson("/api/script", "tool.set move off");
    settle();
    postJson("/api/undo", "");
    settle();
    assert(fabs(vert(0)[2] - (-0.5)) < 1e-3,
        "Ctrl+Z #1 pops ONLY the foreign entry (v0.z back to -0.5), leaving the "
        ~ "consolidated run; got v0.z=" ~ vert(0)[2].to!string);
    assert(vertNear(vert(6), v6BeforeForeign),
        "popping the foreign entry must not touch the still-applied run's v6");

    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "Ctrl+Z #2 pops the consolidated run (v6 back to the cube corner)");
    drainHistory();
}
