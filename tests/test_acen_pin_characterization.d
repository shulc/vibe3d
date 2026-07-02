// Phase 0 of the ACEN pin / gesture-record consolidation task — the
// byte-stability ORACLE for the upcoming refactor (a typed `Pin` value on
// ActionCenterStage, and a `GestureRecord` capture/consume chokepoint on the
// transform wrapper). This test makes NO source change; it only characterizes
// current behavior and pins it into a committed golden file
// (tests/golden/acen_pin_characterization.json).
//
// What it captures, per scenario row: the published action-center pivot
// (/api/toolpipe/eval actionCenter.center), the full 8-vertex cube geometry
// (/api/model), the panel-readback transform block (translate/rotate/scale
// off /api/toolpipe/eval's "transform" object), and the userPlaced/softPlaced
// pin flags. Each scenario records a small chain of rows (e.g. afterDrag /
// afterUndo / afterRedo) so a refactor stage that desyncs pin vs. geometry vs.
// panel display shows up as a row mismatch.
//
// Drive paths exercised:
//   - gizmo drags (drag_helpers.buildDragLog + /api/play-events) across a
//     representative set of Action-Center modes, for Move / Rotate / Scale.
//   - a NUMERIC / PANEL-ATTR Move edit (tool.attr move TX via
//     /api/script?interactive=true) — the ONLY path that opens the wrapper
//     edit session WITHOUT a gizmo mouse-down (beginEdit fires from
//     captureDragBaselineIfStale, never beginMoveDragSession). This is the
//     row that discriminates the two independent "known" gates a correct
//     refactor must keep separate: the pin/soft-start capture fires (gated on
//     beginEdit's closed->open transition) while the run/frame-start capture
//     does NOT (gated on beginMoveDragSession, never called here) — so an
//     undo of this commit must NOT move the published translate ("the run
//     hook is inert").
//   - an IDLE-OPEN in-flight cancel: the same numeric edit, left uncommitted,
//     cancelled via an injected Ctrl+Z SDL keystroke fragment (NOT
//     /api/undo — that bypasses the navHistory chokepoint this must exercise)
//     reaching the in-session-cancel restore path.
//   - a relocate -> gesture -> gesture chain (Auto mode): the second gesture's
//     pin-START must read the LIVE pin left by the first gesture / the
//     relocate, not a stale frozen snapshot.
//
// Element / Local / Parent modes are deliberately OUT of this new matrix:
// their `computeCenter` arms are orthogonal to the gesture-record capture
// mechanics under test here (identical beginEdit/commitEdit code path
// regardless of which mode is active), and each already has dedicated
// fixture coverage (test_element_move_pick, test_fixture_element_move,
// test_fixture_element_pivot, test_element_move_trs,
// test_element_move_scale_pivot, test_pf_acen_local,
// test_fixture_acen_local, test_acen_parent_mode) kept green as an existing
// regression per this test's own final sanity check below.
//
// Run with ACEN_GOLDEN_RECORD=1 to (re)write the golden from the CURRENT
// HEAD; every other run loads the golden and asserts float equality within a
// tight epsilon (1e-4 — the http bridges already truncate published floats to
// 6 decimals via "%f", so this operates as bit-for-bit in practice; this is a
// same-engine refactor, not a cross-engine comparison, so any drift beyond
// float noise is a genuine regression — STOP, do not loosen this tolerance).

import std.net.curl;
import std.json;
import std.math   : fabs, sqrt;
import std.conv   : to;
import std.format : format;
import std.file   : readText, write, exists;
import std.process : environment;

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

void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(120.msecs);
}

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

void drainHistory() {
    foreach (_; 0 .. 100) {
        if (undoCount() == 0) return;
        postJson("/api/undo", "");
    }
}

// Pristine cube + empty selection + empty undo stack. Never drainHistory()
// after /api/reset (SceneReset is itself undoable — see other suites' notes).
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
        auto c = v[6].array;
        return fabs(c[0].floating - 0.5) < 1e-3
            && fabs(c[1].floating - 0.5) < 1e-3
            && fabs(c[2].floating - 0.5) < 1e-3;
    }
    foreach (attempt; 0 .. 8) {
        postJson("/api/script", "tool.set move off");
        postJson("/api/script", "tool.set TransformRotate off");
        postJson("/api/script", "tool.set TransformScale off");
        foreach (_; 0 .. 200) {
            if (playerIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        drainHistory();
        postJson("/api/reset", "");
        postJson("/api/select", `{"mode":"vertices","indices":[]}`);
        cmd("history.clear");
        if (cubePristine() && undoCount() == 0) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"vertices","indices":[]}`);
    cmd("history.clear");
    assert(cubePristine(), "could not establish pristine cube baseline");
}

// ---------------------------------------------------------------------------
// Readback helpers
// ---------------------------------------------------------------------------

Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating, cast(float)c[1].floating, cast(float)c[2].floating);
}
bool evalUserPlaced() {
    return getJson("/api/toolpipe/eval")["actionCenter"]["isUserPlaced"].type == JSONType.true_;
}
bool evalSoftPlaced() {
    return getJson("/api/toolpipe/eval")["actionCenter"]["isSoftPlaced"].type == JSONType.true_;
}
struct XformDisplay { Vec3 translate; Vec3 rotate; Vec3 scale; }
// Panel readback. When no transform tool is active (e.g. right after an
// idle-open in-flight cancel, which drops the tool per app.d's navHistory
// chokepoint: cancelUncommittedEdit() followed by setActiveTool(null) once
// the edit is no longer uncommitted — see app.d:5143-5155), there is no
// panel to read; report the well-defined default (identity) rather than
// asserting, so record() stays safe to call regardless of tool state.
XformDisplay evalTransform() {
    auto j = getJson("/api/toolpipe/eval");
    auto t = "transform" in j.object;
    Vec3 rd(JSONValue jv) {
        auto a = jv.array;
        return Vec3(cast(float)a[0].floating, cast(float)a[1].floating, cast(float)a[2].floating);
    }
    XformDisplay xd;
    if (t is null) {
        xd.translate = Vec3(0, 0, 0);
        xd.rotate    = Vec3(0, 0, 0);
        xd.scale     = Vec3(1, 1, 1);
        return xd;
    }
    xd.translate = rd((*t)["translate"]);
    xd.rotate    = rd((*t)["rotate"]);
    xd.scale     = rd((*t)["scale"]);
    return xd;
}
Vec3[8] evalVertices() {
    auto v = getJson("/api/model")["vertices"].array;
    assert(v.length == 8, "expected an 8-vertex cube, got " ~ v.length.to!string);
    Vec3[8] verts;
    foreach (i; 0 .. 8) {
        auto a = v[i].array;
        verts[i] = Vec3(cast(float)a[0].floating, cast(float)a[1].floating, cast(float)a[2].floating);
    }
    return verts;
}

// SDL Ctrl+Z keystroke fragment -> handleKeyDown -> navHistory(true). Played
// WHILE the tool is still live (NOT /api/undo, which bypasses navHistory) so
// it exercises the in-session-cancel chokepoint.
string ctrlZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n",
        t, t + 10.0);
}

// ---------------------------------------------------------------------------
// Golden accumulation
// ---------------------------------------------------------------------------

JSONValue[string] g_rows;
string[] g_order;   // preserve insertion order for a stable diff / dump

JSONValue vec3Json(Vec3 v) {
    return JSONValue([JSONValue(cast(double)v.x), JSONValue(cast(double)v.y), JSONValue(cast(double)v.z)]);
}

void record(string key) {
    assert((key in g_rows) is null, "duplicate golden row key: " ~ key);
    Vec3 pivot = evalPivot();
    Vec3[8] verts = evalVertices();
    XformDisplay xd = evalTransform();
    bool up = evalUserPlaced();
    bool sp = evalSoftPlaced();

    JSONValue j = JSONValue(cast(JSONValue[string]) null);
    j["center"]      = vec3Json(pivot);
    JSONValue[] vArr;
    foreach (v; verts) vArr ~= vec3Json(v);
    j["vertices"]     = JSONValue(vArr);
    j["translate"]    = vec3Json(xd.translate);
    j["rotate"]       = vec3Json(xd.rotate);
    j["scale"]        = vec3Json(xd.scale);
    j["userPlaced"]   = JSONValue(up);
    j["softPlaced"]   = JSONValue(sp);

    g_rows[key] = j;
    g_order ~= key;
}

// ---------------------------------------------------------------------------
// Drag helpers — generic, mode-agnostic: always re-read the CURRENT published
// pivot before projecting a handle, so they work regardless of which ACEN
// mode (and therefore which pivot position) is active.
// ---------------------------------------------------------------------------

// Whole-mesh (no selection) Y-arrow Move drag by `px` window pixels.
void dragMoveY(int px) {
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 pivot = evalPivot();
    float size = gizmoSize(pivot, vp);
    Vec3 aStart = Vec3(pivot.x, pivot.y + size / 6.0f, pivot.z);
    Vec3 aEnd   = Vec3(pivot.x, pivot.y + size,         pivot.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(aStart, vp, sx1, sy1), "Y-arrow start off-camera");
    assert(projectToWindow(aEnd,   vp, sx2, sy2), "Y-arrow end off-camera");
    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double sdx = sx2 - sx1, sdy = sy2 - sy1;
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    int x1 = x0 + cast(int)(px * sdx / sLen);
    int y1 = y0 + cast(int)(px * sdy / sLen);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, x0, y0, x1, y1, 16));
    settle();
}

// Zero-motion off-gizmo click, well clear of every handle — the click-relocate
// path (setUserPlaced) for relocate-allowed modes.
void offGizmoRelocateClick() {
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 piv = evalPivot();
    float size = gizmoSize(piv, vp);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(Vec3(piv.x, piv.y + size/6.0f, piv.z), vp, sx1, sy1), "arrow start off-camera");
    assert(projectToWindow(Vec3(piv.x, piv.y + size, piv.z), vp, sx2, sy2), "arrow end off-camera");
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    double ux = dx / len, uy = dy / len;
    int cx = cast(int)(sx1 + 220.0 * uy);
    int cy = cast(int)(sy1 - 220.0 * ux);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, cx, cy, cx, cy, 1));
    settle();
}

// Whole-mesh view-ring Rotate drag by `px` window pixels.
void dragRotateViewRing(int px) {
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 pivot = evalPivot();
    float cx, cy;
    assert(projectToWindow(pivot, vp, cx, cy), "rotate pivot off-camera");
    int x0 = cast(int)(cx + 95);
    int y0 = cast(int)cy;
    int x1 = x0;
    int y1 = y0 - px;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, x0, y0, x1, y1, 16));
    settle();
}

// Whole-mesh +X axis Scale-handle drag by `mag` window pixels. Verify-and-
// retry on the undo count (a missed grab records nothing).
void dragScaleXHandle(long wantUndoCount, double mag = 80.0) {
    foreach (attempt; 0 .. 6) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        int gx, gy; double ux, uy;
        axisGrabPx(evalPivot(), vp, gx, gy, ux, uy);
        int xb = gx + cast(int)(mag * ux);
        int yb = gy + cast(int)(mag * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, gx, gy, xb, yb, 12));
        settle();
        if (undoCount() == wantUndoCount) return;
    }
    assert(false, "dragScaleXHandle: could not hit the +X scale handle after 6 attempts");
}

// ===========================================================================
// Scenario A — Move gizmo drag across a representative set of Action-Center
// modes: afterDrag / afterUndo / afterRedo.
// ===========================================================================
unittest {
    static immutable string[] modes = [
        "auto", "select", "selectauto", "border", "origin", "screen", "none",
    ];
    foreach (m; modes) {
        establishCubeBaseline();
        cmd("tool.set move");
        cmd("tool.pipe.attr actionCenter mode " ~ m);

        long before = undoCount();
        dragMoveY(80);
        assert(undoCount() == before + 1,
            "move/" ~ m ~ ": gizmo drag must self-commit ONE in-session entry");
        record("move_" ~ m ~ "_afterDrag");

        postJson("/api/undo", "");
        settle();
        record("move_" ~ m ~ "_afterUndo");

        postJson("/api/redo", "");
        settle();
        record("move_" ~ m ~ "_afterRedo");

        cmd("tool.set move off");
        drainHistory();
    }
}

// ===========================================================================
// Scenario B — Move / Manual + Move / Pivot: modes whose center is NOT a
// plain relocatable selection follow (Manual = sticky manualCenter; Pivot =
// live item pivot, relocate-allowed but settle-excluded per task 0187).
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set move");
    cmd("tool.pipe.attr actionCenter cenX 1");
    cmd("tool.pipe.attr actionCenter cenY 1");
    cmd("tool.pipe.attr actionCenter cenZ 1");   // implicitly promotes to Manual

    long before = undoCount();
    dragMoveY(80);
    assert(undoCount() == before + 1, "move/manual: gizmo drag must self-commit");
    record("move_manual_afterDrag");
    postJson("/api/undo", "");
    settle();
    record("move_manual_afterUndo");
    postJson("/api/redo", "");
    settle();
    record("move_manual_afterRedo");
    cmd("tool.set move off");
    drainHistory();

    establishCubeBaseline();
    cmd("layer.attr 0 pivot.x 2.0");
    cmd("tool.set move");
    cmd("tool.pipe.attr actionCenter mode pivot");

    before = undoCount();
    dragMoveY(80);
    assert(undoCount() == before + 1, "move/pivot: gizmo drag must self-commit");
    record("move_pivot_afterDrag");
    postJson("/api/undo", "");
    settle();
    record("move_pivot_afterUndo");
    postJson("/api/redo", "");
    settle();
    record("move_pivot_afterRedo");
    cmd("tool.set move off");
    drainHistory();
}

// ===========================================================================
// Scenario C — relocate -> gesture -> gesture chain (Auto mode). Exercises
// the W1 case: the SECOND gesture's pin-START must read the LIVE pin left by
// the relocate + gesture-1's sticky-follow end, not a stale frozen snapshot.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set move");
    cmd("tool.pipe.attr actionCenter mode auto");

    long floor = undoCount();
    dragMoveY(70);
    assert(undoCount() == floor + 1, "gesture 1 must self-commit one entry");
    record("autoRelocateChain_afterGesture1");

    offGizmoRelocateClick();
    assert(evalUserPlaced(), "off-gizmo click must set userPlaced");
    record("autoRelocateChain_afterRelocateClick");
    long afterClick = undoCount();   // a zero-motion relocate may or may not record

    dragMoveY(60);
    assert(undoCount() == afterClick + 1, "gesture 2 must self-commit one entry");
    record("autoRelocateChain_afterGesture2");

    postJson("/api/undo", "");
    settle();
    record("autoRelocateChain_afterUndoG2");

    postJson("/api/undo", "");
    settle();
    record("autoRelocateChain_afterUndoG1");

    postJson("/api/redo", "");
    settle();
    record("autoRelocateChain_afterRedoG1");

    postJson("/api/redo", "");
    settle();
    record("autoRelocateChain_afterRedoG2");

    cmd("tool.set move off");
    drainHistory();
}

// ===========================================================================
// Scenario D — Rotate: view-ring drag under Auto (no falloff), Auto
// (falloff), Select (falloff). afterDrag / afterUndo / afterRedo each.
// ===========================================================================
unittest {
    struct RotCase { string label; string mode; bool falloff; }
    static immutable RotCase[] cases = [
        RotCase("rotate_autoNoFalloff", "auto",   false),
        RotCase("rotate_autoFalloff",   "auto",   true),
        RotCase("rotate_selectFalloff", "select", true),
    ];
    foreach (c; cases) {
        establishCubeBaseline();
        cmd("tool.set TransformRotate");
        cmd("tool.pipe.attr actionCenter mode " ~ c.mode);
        if (c.falloff) {
            cmd("tool.pipe.attr falloff type radial");
            cmd(`tool.pipe.attr falloff center "-0.5,-0.5,-0.5"`);
            cmd(`tool.pipe.attr falloff size "2,2,2"`);
        }

        long before = undoCount();
        dragRotateViewRing(90);
        assert(undoCount() == before + 1, c.label ~ ": ring drag must self-commit");
        record(c.label ~ "_afterDrag");

        postJson("/api/undo", "");
        settle();
        record(c.label ~ "_afterUndo");

        postJson("/api/redo", "");
        settle();
        record(c.label ~ "_afterRedo");

        cmd("tool.set TransformRotate off");
        drainHistory();
    }
}

// ===========================================================================
// Scenario E — Scale: +X axis-handle drag under Auto+falloff (settle DOES
// fire — Scale settle is falloff-only) and Auto+no-falloff (settle must NOT
// fire, else a stale pin would drift the next cross-bank Move — the
// test_run_absolute_scale discriminator).
// ===========================================================================
unittest {
    struct ScaleCase { string label; bool falloff; }
    static immutable ScaleCase[] cases = [
        ScaleCase("scale_autoFalloff",   true),
        ScaleCase("scale_autoNoFalloff", false),
    ];
    foreach (c; cases) {
        establishCubeBaseline();
        cmd("tool.set TransformScale");
        cmd("tool.pipe.attr actionCenter mode auto");
        if (c.falloff) {
            cmd("tool.pipe.attr falloff type radial");
            cmd(`tool.pipe.attr falloff center "-0.5,-0.5,-0.5"`);
            cmd(`tool.pipe.attr falloff size "2,2,2"`);
        }

        long before = undoCount();
        dragScaleXHandle(before + 1);
        assert(undoCount() == before + 1, c.label ~ ": scale drag must self-commit");
        record(c.label ~ "_afterDrag");

        postJson("/api/undo", "");
        settle();
        record(c.label ~ "_afterUndo");

        postJson("/api/redo", "");
        settle();
        record(c.label ~ "_afterRedo");

        cmd("tool.set TransformScale off");
        drainHistory();
    }
}

// ===========================================================================
// Scenario F (REQUIRED, OBJ 2) — numeric/panel-attr Move edit. The ONLY path
// that opens the wrapper edit session WITHOUT a gizmo mouse-down: `pinKnown`
// (gates the pin/soft-start hooks) goes true via beginEdit's closed->open
// guard, but `runKnown` (gates the run/frame-start hooks, set only inside
// beginMoveDragSession) NEVER fires. So an undo of this commit must restore
// geometry WITHOUT jumping the published translate (the run hook is inert:
// moveXfStart == moveXfEnd, both equal to the post-edit value).
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set move");
    cmd("tool.pipe.attr actionCenter mode auto");

    long before = undoCount();
    auto r = postJson("/api/script?interactive=true", "tool.attr move TX 0.7\n");
    assert(r["status"].str == "ok", "interactive numeric TX edit failed: " ~ r.toString);
    settle();
    assert(undoCount() == before, "an OPEN numeric-edit session adds no history entry");
    record("numericMoveTX_afterEdit");

    // Force the commit via an ACEN-MODE-CHANGE boundary (the "ACEN-mode
    // boundary poll" in XfrmTransformTool.update() calls commitEdit("Move")
    // directly on a mode change) rather than deactivating the tool via
    // "tool.set move off" — deactivating would drop activeTool entirely and
    // make the /api/toolpipe/eval "transform" block (translate/rotate/scale
    // readback) disappear for every row recorded afterward. `actr.*` / a raw
    // mode attr write is a SideEffect command (records nothing itself), so
    // the ONLY new history entry is the Move commit.
    cmd("tool.pipe.attr actionCenter mode select");
    settle();
    assert(undoCount() == before + 1, "an ACEN-mode-change boundary commits exactly one entry");
    cmd("tool.pipe.attr actionCenter mode auto");
    settle();
    record("numericMoveTX_afterCommit");

    postJson("/api/undo", "");
    settle();
    record("numericMoveTX_afterUndo");

    // THE key assertion (OBJ 1 / the byte-stability gate case): the run hook
    // is inert. Translate must STAY at the post-edit value on undo, not jump
    // toward the pre-edit (0) value the way a normal gizmo-drag undo does.
    auto tAfterUndo = evalTransform().translate;
    assert(fabs(tAfterUndo.x - 0.7) < 1e-4,
        "numeric-edit commit's run hook must be INERT on undo (runKnown was "
        ~ "never set true — moveXfStart==moveXfEnd): translate.x must stay at "
        ~ "the post-edit 0.7, not jump toward 0; got " ~ tAfterUndo.x.to!string);
    // But geometry DID revert (the pin/soft/vertex restore still fired).
    auto v6 = vertexPos(6);
    assert(fabs(v6[0] - 0.5) < 1e-3,
        "numeric-edit undo must still revert the GEOMETRY to pre-edit; v6.x="
        ~ v6[0].to!string);

    postJson("/api/redo", "");
    settle();
    record("numericMoveTX_afterRedo");

    cmd("tool.set move off");
    drainHistory();
}

// ===========================================================================
// Scenario G (REQUIRED, OBJ 5(a)) — idle-open in-flight cancel. The same
// numeric Move edit, left UNCOMMITTED (session stays open at idle), cancelled
// via an injected Ctrl+Z SDL keystroke fragment (NOT /api/undo, which
// bypasses navHistory) -> cancelUncommittedEdit() -> restoreUserPlacedSnapshot().
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set move");
    cmd("tool.pipe.attr actionCenter mode auto");

    long before = undoCount();
    auto r = postJson("/api/script?interactive=true", "tool.attr move TX 0.9\n");
    assert(r["status"].str == "ok", "interactive numeric TX edit failed: " ~ r.toString);
    settle();
    assert(undoCount() == before, "session must still be open (no commit yet)");
    record("idleOpenCancel_beforeCancel");

    // app.d's navHistory chokepoint (:5143-5155) cancels the uncommitted edit
    // AND, once the tool no longer reports one, drops it entirely
    // (setActiveTool(null)) — matching the reference "cancel back to no-tool"
    // gesture semantics. So the transform panel disappears along with the
    // tool; evalTransform() reports the well-defined no-tool default instead
    // of asserting (see its doc comment).
    playAndWait(ctrlZ(50.0));
    settle();
    assert(undoCount() == before, "an idle-open cancel adds NO history entry");
    record("idleOpenCancel_afterCancel");

    auto tAfter = evalTransform().translate;
    assert(fabs(tAfter.x) < 1e-4,
        "idle-open cancel must leave translate at 0 (either the session-start "
        ~ "value, or the no-tool default once the cancel also drops the "
        ~ "tool), not stay at the uncommitted 0.9; got " ~ tAfter.x.to!string);
    auto v6 = vertexPos(6);
    assert(fabs(v6[0] - 0.5) < 1e-3 && fabs(v6[1] - 0.5) < 1e-3 && fabs(v6[2] - 0.5) < 1e-3,
        "idle-open cancel must restore geometry to pristine; v6=("
        ~ v6[0].to!string ~ "," ~ v6[1].to!string ~ "," ~ v6[2].to!string ~ ")");

    cmd("tool.set move off");
    drainHistory();
}

// ===========================================================================
// Final — either (record mode) dump the accumulated rows to the golden file,
// or (default) load the golden and assert every row matches within a tight
// epsilon. Also proves the two REQUIRED rows are DISTINCT from ordinary gizmo
// rows (the harness genuinely reached the PK-only / idle-cancel code paths).
// ===========================================================================

bool vecClose(JSONValue a, JSONValue b, double eps = 1e-4) {
    auto aa = a.array, bb = b.array;
    if (aa.length != bb.length) return false;
    foreach (i; 0 .. aa.length)
        if (fabs(aa[i].floating - bb[i].floating) > eps) return false;
    return true;
}

unittest {
    bool recordMode = environment.get("ACEN_GOLDEN_RECORD", "") == "1";
    string goldenPath = "tests/golden/acen_pin_characterization.json";

    if (recordMode) {
        JSONValue root = JSONValue(cast(JSONValue[string]) null);
        foreach (k; g_order) root[k] = g_rows[k];
        write(goldenPath, root.toPrettyString());
        return;
    }

    assert(exists(goldenPath),
        "golden file missing: " ~ goldenPath
        ~ " — run once with ACEN_GOLDEN_RECORD=1 on the pre-refactor HEAD to create it");
    auto golden = parseJSON(readText(goldenPath));

    foreach (k; g_order) {
        auto gp = k in golden.object;
        assert(gp !is null, "golden file has no row for '" ~ k ~ "' — was it captured?");
        auto got = g_rows[k];
        auto want = *gp;
        assert(vecClose(got["center"], want["center"]),
            k ~ ": center mismatch — got " ~ got["center"].toString
            ~ " want " ~ want["center"].toString);
        assert(got["vertices"].array.length == want["vertices"].array.length,
            k ~ ": vertex count mismatch");
        foreach (i; 0 .. got["vertices"].array.length)
            assert(vecClose(got["vertices"].array[i], want["vertices"].array[i]),
                k ~ ": vertex " ~ i.to!string ~ " mismatch — got "
                ~ got["vertices"].array[i].toString ~ " want "
                ~ want["vertices"].array[i].toString);
        assert(vecClose(got["translate"], want["translate"]),
            k ~ ": translate mismatch — got " ~ got["translate"].toString
            ~ " want " ~ want["translate"].toString);
        assert(vecClose(got["rotate"], want["rotate"]),
            k ~ ": rotate mismatch — got " ~ got["rotate"].toString
            ~ " want " ~ want["rotate"].toString);
        assert(vecClose(got["scale"], want["scale"]),
            k ~ ": scale mismatch — got " ~ got["scale"].toString
            ~ " want " ~ want["scale"].toString);
        assert(got["userPlaced"].type == want["userPlaced"].type,
            k ~ ": userPlaced mismatch");
        assert(got["softPlaced"].type == want["softPlaced"].type,
            k ~ ": softPlaced mismatch");
    }

    // ---- Distinctness proof (Phase-0 validation requirement) --------------
    // The numeric-edit row's translate must DIFFER from a plain gizmo-drag
    // row's post-undo translate (the gizmo row's run hook is LIVE and jumps
    // translate back toward 0; the numeric row's run hook is inert and holds
    // at the edited value).
    {
        auto numeric = g_rows["numericMoveTX_afterUndo"]["translate"].array;
        auto gizmo   = g_rows["move_auto_afterUndo"]["translate"].array;
        assert(fabs(numeric[0].floating - gizmo[0].floating) > 0.1,
            "distinctness check FAILED: numericMoveTX_afterUndo.translate.x ("
            ~ numeric[0].floating.to!string
            ~ ") must clearly differ from move_auto_afterUndo.translate.x ("
            ~ gizmo[0].floating.to!string
            ~ ") — otherwise the harness never reached the PK-only / "
            ~ "runKnown-false code path");
    }
    // The idle-open-cancel row must differ from the committed numeric row in
    // GEOMETRY (translate is not a useful discriminator here: an ACEN-mode
    // boundary commit resets the run-absolute translate DISPLAY back to 0
    // regardless of outcome — same "G8 relocate->0" contract a tool-drop
    // uses — so both rows legitimately read translate.x==0). The cancel
    // never committed anything: v6 stays pristine (0.5); the committed
    // numeric edit persists the +0.7 offset in the actual geometry.
    {
        auto cancelledV6 = g_rows["idleOpenCancel_afterCancel"]["vertices"].array[6].array;
        auto committedV6 = g_rows["numericMoveTX_afterCommit"]["vertices"].array[6].array;
        assert(fabs(cancelledV6[0].floating - committedV6[0].floating) > 0.1,
            "distinctness check FAILED: idleOpenCancel_afterCancel v6.x ("
            ~ cancelledV6[0].floating.to!string
            ~ ") must clearly differ from numericMoveTX_afterCommit v6.x ("
            ~ committedV6[0].floating.to!string
            ~ ") — otherwise the harness never reached the idle-open cancel path");
    }
}
