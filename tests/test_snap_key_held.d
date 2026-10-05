// The snap key (X) while a mouse button is held (task 9470, fixture
// tests/fixtures/snap_key_drag.json, law doc in its `_about`):
//   * delivered while held iff the command reports MouseDownOk — the snap
//     toggle does iff the drag holds >= 1 snap guide: the background
//     constraint in the pipe (a tool drop or the user's toggle puts it there),
//     a new Slice line, the topology pen's or the pen's point drag; never Move itself;
//   * key-up: button held -> re-run now; after a press/release -> re-run iff
//     held > 500 ms; no button -> a hold > 500 ms fires undo and the snap state
//     stays on (a probable reference defect, copied: gap row 562);
//   * a UI toggle with no button records one entry with inert undo / redo; a
//     mid-drag toggle records nothing. Hold times come from the events' `ts`.
// Every cell reads /api/history depth at its moments. Rig: top ortho, 440 px/m.
// Must-stay-green controls run first in each block.

import drag_helpers : Vec3, fetchCamera, kPaceLine, playAndWait;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import pen_rig_helpers : penCameraAt, penCommand, penSceneEmpty, worldPixel;
import std.file : readText;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs;

void main() {}

private enum int K_X = 120, K_X_SCAN = 27, K_Q = 113, K_Q_SCAN = 20;
private enum int K_E = 101, K_E_SCAN = 8, K_Z = 122, K_Z_SCAN = 29, KMOD_LCTRL = 64;
private enum double kPx = 1.0 / 440.0;
private enum Vec3 kFocus = Vec3(0.07f, 1, 0);

private JSONValue fx() {
    static JSONValue cached;
    if (cached.type == JSONType.null_)
        cached = parseJSON(readText("tests/fixtures/snap_key_drag.json"));
    return cached;
}
private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer : v.floating;
}

// ---- events ----------------------------------------------------------------
private struct Log {
    string s;
    double t = 10;
    void motion(int[2] p, int state) {
        s ~= format(`{"t":%.1f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,`
            ~ `"state":%d,"mod":0}` ~ "\n", t, p[0], p[1], state);
        t += 10;
    }
    void button(bool down, int[2] p, int btn = 1) {
        s ~= format(`{"t":%.1f,"type":"%s","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
            t, down ? "SDL_MOUSEBUTTONDOWN" : "SDL_MOUSEBUTTONUP", btn, p[0], p[1]);
        t += 10;
    }
    void key(bool down, uint ts, int sym = K_X, int scan = K_X_SCAN, int mod = 0, int rep = 0) {
        s ~= format(`{"t":%.1f,"type":"%s","sym":%d,"scan":%d,"mod":%d,"repeat":%d,"ts":%d}` ~ "\n",
            t, down ? "SDL_KEYDOWN" : "SDL_KEYUP", sym, scan, mod, rep, ts);
        t += 10;
    }
    void focusLost() { s ~= format(`{"t":%.1f,"type":"SDL_WINDOWEVENT","sub":13}` ~ "\n", t); t += 10; }
    void tap(int sym, int scan, int mod = 0) { key(true, 0, sym, scan, mod); key(false, 0, sym, scan, mod); }
    void play() {
        auto c = fetchCamera();
        playAndWait(format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
            ~ `"fovY":0.785398}`, c.vpX, c.vpY, c.width, c.height) ~ "\n" ~ kPaceLine ~ s);
        s = null;
        t = 10;
    }
}
private int[2] lerp(int[2] a, int[2] b, int i, int n) {
    return [a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n];
}
/// Held motions i0..i1 of an n-step path a -> b.
private void path(ref Log l, int[2] a, int[2] b, int i0, int i1, int n) {
    foreach (i; i0 .. i1 + 1) l.motion(lerp(a, b, i, n), 1);
}

// ---- reads -----------------------------------------------------------------
private bool snapOn() {
    foreach (st; getJson("/api/toolpipe")["stages"].array)
        if (st["task"].str == "SNAP") return st["attrs"]["enabled"].str == "true";
    assert(0, "no SNAP stage");
}
private bool consOn() {
    foreach (st; getJson("/api/toolpipe")["stages"].array)
        if (st["id"].str == "constrain") return st["attrs"]["enabled"].str == "true";
    assert(0, "no constrain stage");
}
private string[] labels() {
    string[] r;
    foreach (e; getJson("/api/history")["undo"].array) r ~= e["label"].str;
    return r;
}
private long depth() { return cast(long)labels().length; }
private string snapTypes() {
    foreach (st; getJson("/api/toolpipe")["stages"].array)
        if (st["task"].str == "SNAP") return st["attrs"]["types"].str;
    assert(0, "no SNAP stage");
}
private string positions() { return getJson("/api/model")["vertices"].toString; }
private double qx() { return num(getJson("/api/model")["vertices"].array[0].array[0]); }
private string tool() {
    auto s = getJson("/api/tool/state");
    return ("tool" in s.object) ? s["tool"].str : "";
}

// ---- rigs ------------------------------------------------------------------
private void loadMesh(string json) {
    auto r = postJson("/api/command", commandBody("scene.loadMesh", json));
    assert(r["status"].str == "ok", "load-mesh failed: " ~ r.toString);
}
private void camera() {
    penCommand("viewport.view Top");
    penCameraAt(kFocus, 440);
    assert(getJson("/api/camera")["projKind"].str == "Ortho", "rig premise: top ortho");
}
/// Arm Move and drop it with the drop key: the drop puts the remembered
/// constraint into the pipe (the "after a Move session" state).
private void moveSession() {
    penCommand("tool.set move");
    Log l; l.tap(K_Q, K_Q_SCAN); l.play();
    assert(tool() == "" && consOn(), "rig premise: the drop key left the constraint out of the pipe");
}
/// q and the vertex target T; q selected; Move armed with vertex snapping
/// off; `latched`: after a Move session (constraint in the pipe).
private void moveRig(bool latched, string types = "vertex") {
    penSceneEmpty("Top");
    loadMesh(`{"vertices":[[0.03,1,0.07],[0.25,1,0.07]],"faces":[]}`);
    camera();
    penCommand("select.typeFrom vertex");
    auto r = postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0]}`));
    assert(r["status"].str == "ok", "select q failed: " ~ r.toString);
    if (latched) moveSession();
    penCommand("tool.set move");
    penCommand(`tool.pipe.attr snap types "` ~ types ~ `"`);
    penCommand("tool.pipe.attr snap innerRange 24");
    penCommand("tool.pipe.attr snap outerRange 40");
    penCommand("tool.pipe.attr snap enabled false");
    penCommand("history.clear");
    assert(consOn() == latched, "rig premise: the constraint's pipe state");
}
private int[2] qPx() { return worldPixel(Vec3(0.03f, 1, 0.07f)); }
private int[2] endPx() { return worldPixel(Vec3(0.245f, 1, 0.07f)); }

/// A tool drop puts the remembered constraint into the pipe; a cell that needs
/// a guide-less drag after one forgets it again (the user's toggle-off).
private void forgetConstraint() {
    if (consOn()) penCommand("constrain.toggle");
    assert(!consOn(), "rig premise: the constraint is still in the pipe");
}
/// `VIBE3D_CELL=<id>` runs one lost-up cell alone (a mutation drill's filter).
private bool cellOn(string id) {
    import std.process : environment;
    const only = environment.get("VIBE3D_CELL", "");
    return only.length == 0 || only == id;
}
private string what(string cell, string m) { return cell ~ ": " ~ m; }
private string[] fails;
private void expectDepth(string cell, string moment, long got, long want) {
    if (got != want) fails ~= format("%s: history depth %s %d, expected %d (%s)", cell, moment,
        got, want, labels());
}
private void flush() {
    import std.array : join;
    auto f = fails; fails = null;
    assert(f.length == 0, "\n  " ~ f.join("\n  "));
}

// ---------------------------------------------------------------------------
// Move: the controls, then delivery and the three key-up cases.
// ---------------------------------------------------------------------------
unittest {
    const double snappedX = num(fx()["move_snap_hold"]["snapped_x"]);
    const double rawX = num(fx()["move_snap_hold"]["raw_x"]);
    const n = 15;
    double drag(bool latched, bool snapAtPress) {
        moveRig(latched);
        if (snapAtPress) penCommand("tool.pipe.attr snap enabled true");
        Log l; l.motion(qPx, 0); l.button(true, qPx); path(l, qPx, endPx, 1, n, n);
        l.button(false, endPx); l.play();
        return qx();
    }
    // Controls (must stay green): snap on at the press lands on T; off is raw.
    const on = drag(true, true), off = drag(true, false);
    assert(abs(on - snappedX) <= 1e-4,
        format("control on: snap on at the press should land on T %.4f, got %.6f", snappedX, on));
    assert(abs(off - rawX) <= 0.5 * kPx && abs(off - snappedX) > 1.5 * kPx,
        format("control off: the raw end should be %.4f (half a px), got %.6f", rawX, off));
    const offFresh = drag(false, false);
    assert(abs(offFresh - off) <= 1e-6, format("control off (fresh): %.6f vs %.6f", offFresh, off));

    // move-snap-key-hold: X down mid-drag (constraint in the pipe) -> delivered,
    // LIVE snapping onto T; +0 mid-drag; up after the release (> 500 ms) re-runs.
    {
        const cell = "move-snap-key-hold";
        moveRig(true);
        const d0 = depth();
        Log l; l.motion(qPx, 0); l.button(true, qPx); path(l, qPx, endPx, 1, 7, n);
        l.key(true, 1000); l.play();
        assert(snapOn(), what(cell, "X during the held drag was not delivered (snap still off)"));
        expectDepth(cell, "after the mid-drag key-down", depth(), d0);
        // A repeat key-down of the held X is no new press (one: an even count
        // would toggle back and hide a second press).
        l.key(true, 1100, K_X, K_X_SCAN, 0, 1); l.play();
        assert(snapOn(), what(cell, "an autorepeat key-down toggled the snap state again"));
        // Another key's tap (dropped while held) is not the tracked key's up.
        l.tap(K_Z, K_Z_SCAN, KMOD_LCTRL); l.play();
        assert(snapOn() && depth() == d0, what(cell, "a Ctrl+Z tap during the held X acted"));
        path(l, qPx, endPx, 8, n, n); l.button(false, endPx); l.play();
        assert(abs(qx() - snappedX) <= 1e-4,
            format("%s: the drag should snap onto T %.4f after X, got %.6f", cell, snappedX, qx()));
        // The drag used the live snap state: its release records the one apply
        // (K-G2 move_hold +1), no re-grade entry for the state it already read.
        auto dh = fx()["undo_depth"]["move_hold"].array;
        expectDepth(cell, "after the release", depth(), d0 + dh[1].integer);
        l.key(false, 7000); l.play();
        assert(!snapOn(), what(cell, "the key-up after the release (held 6 s) did not revert"));
        expectDepth(cell, "after the key-up", depth(), d0 + dh[2].integer);
        // Undo never writes the snap state (findings_K-BV rule 2): the first
        // Ctrl+Z removes the toggle record and keeps the drag; the second
        // removes the drag. The snap state and types stay as they are.
        const types = snapTypes();
        l.tap(K_Z, K_Z_SCAN, KMOD_LCTRL); l.play();
        assert(abs(qx() - snappedX) <= 1e-4 && !snapOn() && snapTypes() == types,
            format("%s: undo 1 should remove only the toggle: x %.6f, snap %s, types '%s' (%s)",
                cell, qx(), snapOn(), snapTypes(), labels()));
        l.tap(K_Z, K_Z_SCAN, KMOD_LCTRL); l.play();
        assert(abs(qx() - 0.03) <= 1e-6 && !snapOn() && snapTypes() == types,
            format("%s: undo 2 should remove the drag: x %.6f, snap %s, types '%s' (%s)",
                cell, qx(), snapOn(), snapTypes(), labels()));
    }

    // Another binding in the same delivering drag stays dropped: Ctrl+Z (a
    // command without the flag) and E (a tool key).
    {
        const cell = "move-other-binding-held";
        moveRig(true);
        Log l; l.motion(qPx, 0); l.button(true, qPx); path(l, qPx, endPx, 1, 7, n); l.play();
        const d0 = depth(), x0 = qx();
        l.tap(K_Z, K_Z_SCAN, KMOD_LCTRL); l.tap(K_E, K_E_SCAN); l.play();
        assert(depth() == d0 && qx() == x0 && tool() == "xfrm",
            format("%s: Ctrl+Z / E reached the editor mid-drag: depth %d (%d), x %.6f (%.6f), tool '%s'",
                cell, depth(), d0, qx(), x0, tool()));
        path(l, qPx, endPx, 8, n, n); l.button(false, endPx); l.play();
    }

    // move-snap-key-tap: X down and up while held -> on, then reverted at once.
    {
        const cell = "move-snap-key-tap";
        moveRig(true);
        const d0 = depth();
        Log l; l.motion(qPx, 0); l.button(true, qPx); path(l, qPx, endPx, 1, 7, n);
        l.key(true, 1000); l.play();
        assert(snapOn(), what(cell, "X during the held drag was not delivered"));
        l.key(false, 1100); l.play();
        assert(!snapOn(), what(cell, "the key-up with the button held did not revert at once"));
        path(l, qPx, endPx, 8, n, n); l.button(false, endPx); l.play();
        assert(abs(qx() - off) <= 1e-6,
            format("%s: the drag should end raw (%.6f) after the revert, got %.6f", cell, off, qx()));
        expectDepth(cell, "after the release", depth(), d0 + 1);
    }

    // move-snap-key-short-after-release: X up 300 ms after its down, after the
    // release -> stays on (the re-run needs a hold over 500 ms).
    {
        const cell = "move-snap-key-short-after-release";
        moveRig(true);
        Log l; l.motion(qPx, 0); l.button(true, qPx); path(l, qPx, endPx, 1, 7, n);
        l.key(true, 1000); path(l, qPx, endPx, 8, n, n); l.button(false, endPx);
        l.key(false, 1300); l.play();
        assert(snapOn(), what(cell, "a 300 ms hold re-ran the toggle after the release"));
    }

    // move-snap-key-prepressed-no-guide: X down with no button (on), a drag
    // holding no guide, X up while held: the held re-run needs mouse-down-OK,
    // so nothing runs and the state stays on (fixture `_about`, key-up law).
    {
        const cell = "move-snap-key-prepressed-no-guide";
        moveRig(false);
        Log l; l.key(true, 1000); l.motion(qPx, 0); l.button(true, qPx);
        path(l, qPx, endPx, 1, 7, n); l.key(false, 1100); l.play();
        assert(snapOn(), what(cell, "the held key-up re-ran the toggle with no guide"));
        path(l, qPx, endPx, 8, n, n); l.button(false, endPx); l.play();
        penCommand("tool.pipe.attr snap enabled false");
    }

    // move-snap-key-fresh: the constraint not in the pipe, Move has no guide of
    // its own -> X dropped, and its key-up does nothing.
    {
        const cell = "move-snap-key-fresh";
        moveRig(false);
        const d0 = depth();
        Log l; l.motion(qPx, 0); l.button(true, qPx); path(l, qPx, endPx, 1, 7, n);
        l.key(true, 1000); l.play();
        assert(!snapOn(), what(cell, "X was delivered to a drag holding no guide"));
        path(l, qPx, endPx, 8, n, n); l.button(false, endPx); l.key(false, 7000); l.play();
        assert(!snapOn() && abs(qx() - off) <= 1e-6, format("%s: snap %s, x %.6f (raw %.6f)",
            cell, snapOn(), qx(), off));
        expectDepth(cell, "after the key-up", depth(), d0 + 1);
    }

    // A lost key-up leaves no stale tracker: X down (on), then focus loss
    // and / or a dropped X down in a guide-less drag, the release, X up over
    // 500 ms after the first down -> nothing re-runs, snap stays on.
    foreach (c; [[1, 1], [1, 0], [0, 1]]) {
        const cell = format("move-snap-key-lost-up-focus%d-redown%d", c[0], c[1]);
        if (!cellOn(cell)) continue;
        moveRig(false);
        Log l; l.key(true, 1000); l.play();
        assert(snapOn(), what(cell, "rig premise: X with no button did not toggle on"));
        if (c[0]) l.focusLost();
        l.motion(qPx, 0); l.button(true, qPx); path(l, qPx, endPx, 1, 7, n);
        if (c[1]) l.key(true, 2000);
        path(l, qPx, endPx, 8, n, n); l.button(false, endPx);
        l.key(false, c[1] ? 2600 : 1600); l.play();
        assert(snapOn(), what(cell, "a stale momentary tracker re-ran the toggle at the key-up"));
    }

    // move-snap-key-no-types: delivered with no snap type (the count is the
    // drag's guides, not its targets); the drag stays raw.
    {
        const cell = "move-snap-key-no-types";
        moveRig(true, "");
        Log l; l.motion(qPx, 0); l.button(true, qPx); path(l, qPx, endPx, 1, 7, n);
        l.key(true, 1000); l.play();
        assert(snapOn(), what(cell, "X was not delivered"));
        path(l, qPx, endPx, 8, n, n); l.button(false, endPx); l.key(false, 1100); l.play();
        assert(abs(qx() - off) <= 1e-6, format("%s: x %.6f, raw %.6f", cell, qx(), off));
    }

    // move-snap-key-prepressed: X down with no button (on at once, +1), the
    // drag snaps, the release (+1), the key-up after it (> 500 ms) re-runs (+1).
    {
        const cell = "move-snap-key-prepressed";
        moveRig(false);
        auto dd = fx()["undo_depth"]["move_prepressed"].array;
        const d0 = depth();
        Log l; l.key(true, 1000); l.play();
        assert(snapOn(), what(cell, "the pre-pressed X did not toggle at once"));
        expectDepth(cell, "after the key-down", depth(), d0 + dd[1].integer);
        l.motion(qPx, 0); l.button(true, qPx); path(l, qPx, endPx, 1, n, n);
        l.button(false, endPx); l.play();
        assert(abs(qx() - snappedX) <= 1e-4, format("%s: x %.6f, expected T %.4f", cell, qx(), snappedX));
        expectDepth(cell, "after the release", depth(), d0 + dd[2].integer);
        l.key(false, 4000); l.play();
        assert(!snapOn(), what(cell, "the key-up after the release did not revert"));
        expectDepth(cell, "after the key-up", depth(), d0 + dd[3].integer);
    }
    flush();
}

// ---------------------------------------------------------------------------
// No button: tap vs hold by `ts`, the copied undo, inert undo / redo.
// ---------------------------------------------------------------------------
unittest {
    void noTool() {
        penSceneEmpty("Top");
        camera();
        penCommand("tool.pipe.attr snap enabled false");
        penCommand("history.clear");
    }
    // snap-key-tap-no-button: 50 ms with pointer motion between -> stays on, +1.
    {
        const cell = "snap-key-tap-no-button";
        noTool();
        Log l; l.key(true, 1000);
        foreach (i; 0 .. 5) l.motion([400 + 10 * i, 300], 0);
        l.key(false, 1050); l.play();
        assert(snapOn(), what(cell, "a 50 ms tap did not stay on"));
        expectDepth(cell, "after the tap", depth(), 1);
        assert(labels()[$ - 1] == "Toggle Snap", what(cell, "top entry " ~ labels()[$ - 1]));
    }
    // snap-key-hold-450 / -550 (with pointer motion: motion is no cycle).
    foreach (ms; [450, 550]) {
        const cell = format("snap-key-hold-%d", ms);
        noTool();
        Log l; l.key(true, 1000);
        foreach (i; 0 .. 5) l.motion([400 + 10 * i, 300], 0);
        l.key(false, 1000 + ms); l.play();
        assert(snapOn(), what(cell, "the snap state did not stay on"));
        expectDepth(cell, "after the key-up", depth(), ms > 500 ? 0 : 1);
    }
    // snap-key-hold-no-tool: 600 ms -> undo pops the toggle's own record; the
    // state is NOT restored (copied defect).
    {
        const cell = "snap-key-hold-no-tool";
        noTool();
        Log l; l.key(true, 1000); l.play();
        expectDepth(cell, "after the key-down", depth(), 1);
        l.key(false, 1600); l.play();
        expectDepth(cell, "after the key-up", depth(), 0);
        assert(snapOn(), what(cell, "the undo restored the snap state"));
    }
    // snap-key-redo-inert: tap, Ctrl+Z, Ctrl+Shift+Z -> 1, 0, 1; state always on.
    {
        const cell = "snap-key-redo-inert";
        noTool();
        Log l; l.key(true, 1000); l.key(false, 1190); l.play();
        expectDepth(cell, "after the tap", depth(), 1);
        l.tap(K_Z, K_Z_SCAN, KMOD_LCTRL); l.play();
        expectDepth(cell, "after the undo", depth(), 0);
        assert(snapOn(), what(cell, "the undo wrote the snap state"));
        l.tap(K_Z, K_Z_SCAN, KMOD_LCTRL | 1); l.play();
        expectDepth(cell, "after the redo", depth(), 1);
        assert(snapOn(), what(cell, "the redo wrote the snap state"));
    }
    // A live apply, then a recording toggle and two undos (findings_K-BV rules
    // 1-3, K-G3 G3-s ii; task 9482): undo 1 removes the toggle and keeps the
    // apply, undo 2 removes the apply; neither writes the snap state or types.
    void moveApply() {
        Log l; l.motion(qPx, 0); l.button(true, qPx); path(l, qPx, endPx, 1, 5, 5);
        l.button(false, endPx); l.play();
        assert(labels().length >= 1 && labels()[$ - 1] == "Transform 1 verts",
            format("floor: the drag's apply is not on top: %s", labels()));
    }
    void twoUndos(string cell, void delegate() firstUndo, double applied, double raw) {
        const types = snapTypes();
        firstUndo();
        assert(abs(qx() - applied) <= 1e-6 && snapOn() && snapTypes() == types,
            format("%s: undo 1 should remove only the toggle: x %.6f, snap %s, types '%s' (%s)",
                cell, qx(), snapOn(), snapTypes(), labels()));
        Log l; l.tap(K_Z, K_Z_SCAN, KMOD_LCTRL); l.play();
        assert(abs(qx() - raw) <= 1e-6 && snapOn() && snapTypes() == types,
            format("%s: undo 2 should remove the drag: x %.6f, snap %s, types '%s' (%s)",
                cell, qx(), snapOn(), snapTypes(), labels()));
    }
    // snap-key-hold-no-button: X held 600 ms with no button (K-BV, K-G2 M4).
    {
        const cell = "snap-key-hold-no-button";
        moveRig(false);
        moveApply();
        const x1 = qx();
        Log l; l.key(true, 1000); l.play();
        assert(snapOn() && depth() == 2, format("%s: key-down %s, snap %s", cell, labels(), snapOn()));
        twoUndos(cell, { Log k; k.key(false, 1600); k.play(); }, x1, 0.03);
    }
    // The status-bar Snap button: a command row through the UI binding, the
    // door `?origin=ui` reaches. K-G3 G3-s: (i) no tool, +1 per click;
    // (ii) with a live apply, +1, and the two undos as above.
    void button() {
        auto r = postJson("/api/command?origin=ui", "snap.toggle");
        assert(r["status"].str == "ok", "status-button snap.toggle failed: " ~ r.toString);
    }
    {
        const cell = "snap-button-no-tool";
        noTool();
        button();
        expectDepth(cell, "after click 1", depth(), 1);
        assert(snapOn(), what(cell, "click 1 did not turn snapping on"));
        button();
        expectDepth(cell, "after click 2", depth(), 2);
        assert(!snapOn(), what(cell, "click 2 did not turn snapping off"));
    }
    {
        const cell = "snap-button-live-apply";
        moveRig(false);
        moveApply();
        const x1 = qx();
        button();
        assert(snapOn() && depth() == 2, format("%s: click %s, snap %s", cell, labels(), snapOn()));
        twoUndos(cell, { Log k; k.tap(K_Z, K_Z_SCAN, KMOD_LCTRL); k.play(); }, x1, 0.03);
    }
    // ui-pipe-attr-live-apply: the enabled state is no run term — a UI-door
    // enabled write over a live apply re-grades nothing (K-BV rule 2).
    {
        const cell = "ui-pipe-attr-live-apply";
        moveRig(false);
        moveApply();
        const before = labels();
        auto r = postJson("/api/command?origin=ui", "tool.pipe.attr snap enabled true");
        assert(r["status"].str == "ok", what(cell, r.toString));
        Log l; l.motion(qPx, 0); l.play();
        assert(labels() == before, format("%s: %s, before %s", cell, labels(), before));
    }
    // script-types-live-apply: a snap-TYPES write over a live apply is no
    // re-grade either, and undoing the apply leaves the types (K-G4 rule 4).
    {
        const cell = "script-types-live-apply";
        moveRig(false);
        moveApply();
        penCommand(`tool.pipe.attr snap types "edge"`);
        Log l; l.motion(qPx, 0); l.play();
        assert(labels() == ["Transform 1 verts"] && snapTypes() == "edge",
            format("%s: %s, types '%s'", cell, labels(), snapTypes()));
        l.tap(K_Z, K_Z_SCAN, KMOD_LCTRL); l.play();
        assert(depth() == 0 && abs(qx() - 0.03) <= 1e-6 && snapTypes() == "edge",
            format("%s: the undo %s, x %.6f, types '%s' (expected the drag gone, 'edge')",
                cell, labels(), qx(), snapTypes()));
    }
    // K-G4 (findings_K-G4, task 10050): drag 1, a snap change, drag 2, then
    // Ctrl+Z x3 in one live Move session. One record per drag; the change's
    // record sits between them (button, X tap, a snap-TYPE change) or is
    // removed by its own key-up undo (X held 600 ms); no undo writes the snap
    // state or types. Positions: v0 (x, z) — origin (0.03, 0.07), after drag 1
    // (0.12, 0.07), after drag 2 (0.12, 0.16); the walk is the fixture's.
    double[2] v0xz() {
        auto v = getJson("/api/model")["vertices"].array[0].array;
        return [num(v[0]), num(v[2])];
    }
    void drag(Vec3 a, Vec3 b) {
        const int[2] pa = worldPixel(a), pb = worldPixel(b);
        Log l; l.motion(pa, 0); l.button(true, pa); path(l, pa, pb, 1, 10, 10);
        l.button(false, pb); l.play();
    }
    enum double[2] O = [0.03, 0.07], D1 = [0.12, 0.07], D12 = [0.12, 0.16];
    foreach (kind; ["G4_A", "G4_Bt", "G4_B", "G4_C", "G4_K"]) {
        const cell = kind;
        moveRig(false);
        penCommand("tool.set move off");    // an arming record of its own (the
        penCommand("history.clear");        // fixture's E23): Z3 of B / K drops
        penCommand("tool.set move");        // the tool
        bool state() { return kind == "G4_C" ? snapTypes() == "vertex,edge" : snapOn(); }
        void at(string step, double[2] p, bool st) {
            const got = v0xz();
            assert(abs(got[0] - p[0]) <= 1.5 * kPx && abs(got[1] - p[1]) <= 1.5 * kPx && state() == st,
                format("%s %s: v0 (%.4f, %.4f), expected (%.4f, %.4f); snap/type %s, expected %s (%s)",
                    cell, step, got[0], got[1], p[0], p[1], state(), st, labels()));
        }
        drag(Vec3(0.03f, 1, 0.07f), Vec3(0.12f, 1, 0.07f));
        at("after drag 1", D1, false);
        const d1 = depth();
        Log l;
        final switch (kind) {
            case "G4_A": button(); break;
            case "G4_Bt": l.key(true, 1000); l.key(false, 1150); l.play(); break;
            case "G4_B": l.key(true, 1000); l.key(false, 1600); l.play(); break;
            case "G4_C":
                auto r = postJson("/api/command?origin=ui", "snap.toggleType edge");
                assert(r["status"].str == "ok", what(cell, r.toString));
                break;
            case "G4_K": break;
        }
        const bool changed = kind != "G4_K";
        const bool between = changed && kind != "G4_B";
        assert(depth() == d1 + (between ? 1 : 0),
            format("%s: the change recorded %s (expected %d entries)", cell, labels(), d1 + (between ? 1 : 0)));
        drag(Vec3(0.12f, 1, 0.07f), Vec3(0.12f, 1, 0.16f));
        at("after drag 2", D12, changed);
        l.tap(K_Z, K_Z_SCAN, KMOD_LCTRL); l.play();
        at("Z1 (removes drag 2)", D1, changed);
        l.tap(K_Z, K_Z_SCAN, KMOD_LCTRL); l.play();
        at(between ? "Z2 (removes the change)" : "Z2 (removes drag 1)", between ? D1 : O, changed);
        l.tap(K_Z, K_Z_SCAN, KMOD_LCTRL); l.play();
        at(between ? "Z3 (removes drag 1)" : "Z3 (removes the arming record)", O, changed);
        assert(between ? tool() == "xfrm" : tool() == "",
            format("%s Z3: tool '%s'", cell, tool()));
        if (kind == "G4_C") penCommand(`tool.pipe.attr snap types "vertex"`);
        penCommand("tool.set move off");
    }
    // Polygon Bevel with a live haul, BV_B (button) and BV_X (X held 571 ms,
    // no button), findings_K-BV: undo 1 removes the toggle, the bevel stays;
    // undo 2 removes the haul; snap stays on.
    foreach (viaKey; [false, true]) {
        const cell = viaKey ? "bevel-BV_X" : "bevel-BV_B";
        auto r = postJson("/api/command", commandBody("scene.reset"));
        assert(r["status"].str == "ok");
        penCommand("tool.pipe.attr snap enabled false");
        penCommand("select.typeFrom polygon");
        auto sel = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0]}`));
        assert(sel["status"].str == "ok", what(cell, sel.toString));
        const cube = positions();
        penCommand("tool.set poly.bevel on");
        Log l; l.motion([5, 5], 0); l.play();
        int[2] h; bool found;
        foreach (p; getJson("/api/tool/handles")["handles"]["parts"].array)
            if (p["part"].integer == 0) {
                h = [cast(int)(num(p["screen"].array[0]) + 0.5), cast(int)(num(p["screen"].array[1]) + 0.5)];
                found = true;
            }
        assert(found && tool() == "polyBevel", what(cell, "floor: no shift handle / tool not armed"));
        const v0 = positions();
        const int[2] h2 = [h[0] - 30, h[1] - 51];
        l.motion(h, 0); l.button(true, h); path(l, h, h2, 1, 6, 6); l.button(false, h2); l.play();
        const v1 = positions();
        assert(v1 != v0, what(cell, "floor: the haul moved nothing"));
        const types = snapTypes();
        if (viaKey) { l.key(true, 1000); l.play(); } else button();
        assert(snapOn(), what(cell, "the toggle did not turn snapping on"));
        if (viaKey) l.key(false, 1571); else l.tap(K_Z, K_Z_SCAN, KMOD_LCTRL);
        l.play();
        assert(positions() == v1 && snapOn() && snapTypes() == types,
            format("%s: undo 1 should remove only the toggle: bevel kept %s, snap %s, types '%s' (%s)",
                cell, positions() == v1, snapOn(), snapTypes(), labels()));
        l.tap(K_Z, K_Z_SCAN, KMOD_LCTRL); l.play();
        // The haul is gone. Ours also pops the arm's zero-width ring with it
        // (the UI command committed the window as one row: back to the cube,
        // 8 vertices); the reference keeps that ring (BV_X: 12 v, inset 0).
        assert(positions() == cube && snapOn() && snapTypes() == types,
            format("%s: undo 2 should remove the haul: %d verts, snap %s, types '%s' (%s)",
                cell, getJson("/api/model")["vertexCount"].integer, snapOn(), snapTypes(), labels()));
        penCommand("tool.set poly.bevel off");
    }
    // snap-type-ui-redo-inert: a UI snap-type change records one entry whose
    // undo and redo never write the types (K-G4 G4_C, rule 4); the script door
    // records nothing (gap 563's door).
    {
        const cell = "snap-type-ui-redo-inert";
        noTool();
        penCommand(`tool.pipe.attr snap types "vertex"`);
        penCommand("history.clear");
        penCommand("snap.toggleType edge");
        assert(depth() == 0 && snapTypes() == "vertex,edge",
            format("%s: script door %s, types '%s'", cell, labels(), snapTypes()));
        auto r = postJson("/api/command?origin=ui", "snap.toggleType edge");
        assert(r["status"].str == "ok", what(cell, r.toString));
        assert(depth() == 1 && snapTypes() == "vertex", format("%s: %s, types '%s'", cell, labels(), snapTypes()));
        Log l; l.tap(K_Z, K_Z_SCAN, KMOD_LCTRL); l.play();
        assert(depth() == 0 && snapTypes() == "vertex", format("%s: undo %s, types '%s'", cell, labels(), snapTypes()));
        l.tap(K_Z, K_Z_SCAN, KMOD_LCTRL | 1); l.play();
        assert(depth() == 1 && snapTypes() == "vertex", format("%s: redo %s, types '%s'", cell, labels(), snapTypes()));
    }
    // A non-momentary command key held 600 ms runs no key-up law ("[" =
    // select.invert, one entry that stays).
    {
        auto r = postJson("/api/command", commandBody("scene.reset"));
        assert(r["status"].str == "ok");
        penCommand("history.clear");
        Log l; l.key(true, 1000, 91, 47); l.key(false, 1600, 91, 47); l.play();
        expectDepth("non-momentary-key-hold", "after the key-up", depth(), 1);
    }
    // Script origin records nothing (gap row 563).
    {
        noTool();
        penCommand("snap.toggle");
        assert(snapOn() && depth() == 0,
            format("script snap.toggle: snap %s, depth %d (expected on, 0)", snapOn(), depth()));
    }
    flush();
}

// ---------------------------------------------------------------------------
// Families: delivery is the drag's guide count, never the tool.
// ---------------------------------------------------------------------------
private bool deliveredDuring(void delegate(ref Log) pressAndMove, void delegate(ref Log) rest) {
    penCommand("tool.pipe.attr snap enabled false");
    const d0 = depth();
    Log l; pressAndMove(l); l.key(true, 1000); l.play();
    const on = snapOn();
    assert(depth() == d0, format("mid-drag key: depth %d, expected %d (%s)", depth(), d0, labels()));
    l.key(false, 1100); rest(l); l.play();
    assert(!snapOn(), "the held key-up did not leave the snap state off");
    return on;
}

unittest { // Slice: a new line holds a guide; a press on a live line does not.
    penSceneEmpty("Top");
    loadMesh(`{"vertices":[[-0.3,1,-0.3],[0.3,1,-0.3],[0.3,1,0.3],[-0.3,1,0.3]],"faces":[[0,3,2,1]]}`);
    camera();
    penCommand("tool.set mesh.sliceTool on");
    assert(tool() == "slice", "slice floor: the tool did not arm: " ~ tool());
    const int[2] a = worldPixel(Vec3(-0.1f, 1, -0.45f)), b = worldPixel(Vec3(0.1f, 1, 0.45f));
    const newLine = deliveredDuring(
        (ref Log l) { l.motion(a, 0); l.button(true, a); path(l, a, b, 1, 4, 8); },
        (ref Log l) { path(l, a, b, 5, 8, 8); l.button(false, b); });
    assert(newLine, "slice-snap-key-new-line: X was not delivered to a new-line drag");
    const int[2] m = lerp(a, b, 1, 2);
    const int[2] m2 = [m[0] + 40, m[1]];
    const liveLine = deliveredDuring(
        (ref Log l) { l.motion(m, 0); l.button(true, m); l.motion(lerp(m, m2, 1, 2), 1); },
        (ref Log l) { l.motion(m2, 1); l.button(false, m2); });
    assert(!liveLine, "slice-snap-key-live-line: X was delivered to a press on the live line");
    // slice-snap-key-cancel: an RMB cancel of the new-line drag ends its guide.
    penCommand("tool.set mesh.sliceTool off");
    forgetConstraint();
    penCommand("tool.set mesh.sliceTool on");
    {
        Log l; l.motion(a, 0); l.button(true, a); path(l, a, b, 1, 4, 8);
        l.button(true, lerp(a, b, 4, 8), 3); l.button(false, lerp(a, b, 4, 8), 3);
        l.button(false, lerp(a, b, 4, 8)); l.play();
    }
    const afterCancel = deliveredDuring(
        (ref Log l) { l.motion(m, 0); l.button(true, m); l.motion(lerp(m, m2, 1, 2), 1); },
        (ref Log l) { l.motion(m2, 1); l.button(false, m2); });
    assert(!afterCancel, "slice-snap-key-cancel: the cancelled new line's guide outlived it");
    // slice-snap-key-drop: dropping Slice mid-drag ends its guide (a later
    // fresh Move drag holds none).
    {
        penCommand("tool.set mesh.sliceTool off");
        penCommand("tool.set mesh.sliceTool on");
        Log l; l.motion(a, 0); l.button(true, a); path(l, a, b, 1, 4, 8); l.play();
        penCommand("tool.set mesh.sliceTool off");
        l.button(false, b); l.play();
        forgetConstraint();
    }
    penCommand("select.typeFrom vertex");
    auto sel = postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0]}`));
    assert(sel["status"].str == "ok");
    penCommand("tool.set move");
    const v0 = worldPixel(Vec3(-0.3f, 1, -0.3f));
    const int[2] v1 = [v0[0] + 40, v0[1]];
    const afterDrop = deliveredDuring(
        (ref Log l) { l.motion(v0, 0); l.button(true, v0); l.motion(lerp(v0, v1, 1, 2), 1); },
        (ref Log l) { l.motion(v1, 1); l.button(false, v1); });
    assert(!afterDrop, "slice-snap-key-drop: the dropped Slice's guide outlived the tool");
    // slice-snap-key-switch: switching to Move mid-drag (the prepared door, no
    // release, no drop) ends the new line's guide too (task 9416).
    if (cellOn("slice-snap-key-switch")) {
        penCommand("tool.set mesh.sliceTool on");
        Log l; l.motion(a, 0); l.button(true, a); path(l, a, b, 1, 4, 8); l.play();
        penCommand("tool.set move");
        l.button(false, b); l.play();
        forgetConstraint();
        const afterSwitch = deliveredDuring(
            (ref Log m) { m.motion(v0, 0); m.button(true, v0); m.motion(lerp(v0, v1, 1, 2), 1); },
            (ref Log m) { m.motion(v1, 1); m.button(false, v1); });
        assert(!afterSwitch, "slice-snap-key-switch: the switched-away Slice's guide outlived the tool");
    }
    penCommand("tool.set move off");
    flush();
}

unittest { // Box base drag, Box size handle, Polygon Bevel haul.
    const int[2] a = worldPixel(Vec3(0.3f, 1, 0.2f));
    const int[2] b = [a[0] + 88, a[1] + 30];
    void baseDrag(ref Log l) { l.motion(a, 0); l.button(true, a); path(l, a, b, 1, 4, 8); }
    void baseRest(ref Log l) { path(l, a, b, 5, 8, 8); l.button(false, b); }
    bool box(bool latched, bool toggled = false) {
        penSceneEmpty("Top");
        camera();
        if (latched) moveSession();
        if (toggled) penCommand("constrain.toggle");
        penCommand("tool.set prim.cube");
        penCommand("history.clear");
        return deliveredDuring(&baseDrag, &baseRest);
    }
    assert(!box(false), "box-snap-key-fresh: X was delivered to a fresh base drag");
    assert(box(true), "box-snap-key-after-move: X was not delivered after a Move session "
        ~ "(the constraint in the pipe, no background layer)");
    assert(box(false, true), "box-snap-key-cons-toggled: X was not delivered with the user's "
        ~ "constraint toggled on");

    // Box size handle, fresh: dropped.
    {
        penSceneEmpty("Top");
        camera();
        penCommand("tool.set prim.cube");
        Log l; baseDrag(l); baseRest(l); l.play();
        int[2] h; bool found;
        foreach (p; getJson("/api/tool/handles")["handles"]["parts"].array)
            if (p["part"].integer == 1) {   // the +X side's size handle
                h = [cast(int)(num(p["screen"].array[0]) + 0.5), cast(int)(num(p["screen"].array[1]) + 0.5)];
                found = true;
            }
        assert(found, "box-size-snap-key floor: no +X size handle published");
        double sizeX() { return num(postJson("/api/command", "tool.attr prim.cube sizeX ?")["value"]); }
        const s0 = sizeX();
        penCommand("history.clear");
        const int[2] h2 = [h[0] + 30, h[1]];
        assert(!deliveredDuring(
            (ref Log l) { l.motion(h, 0); l.button(true, h); l.motion(lerp(h, h2, 1, 2), 1); },
            (ref Log l) { l.motion(h2, 1); l.button(false, h2); }),
            "box-size-snap-key: X was delivered to a fresh size-handle drag");
        assert(abs(sizeX() - s0 - 30 * kPx) <= 2 * kPx,
            format("box-size-snap-key floor: the drag did not run the size handle (sizeX %.4f -> %.4f)",
                s0, sizeX()));
        penCommand("tool.set prim.cube off");
    }

    bool bevel(bool latched) {
        auto r = postJson("/api/command", commandBody("scene.reset"));
        assert(r["status"].str == "ok");
        if (latched) moveSession();
        penCommand("select.typeFrom polygon");
        auto s = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[0]}`));
        assert(s["status"].str == "ok", "bevel select failed: " ~ s.toString);
        penCommand("tool.set poly.bevel on");
        Log l; l.motion([5, 5], 0); l.play();
        int[2] h; bool found;
        foreach (p; getJson("/api/tool/handles")["handles"]["parts"].array)
            if (p["part"].integer == 0) {
                h = [cast(int)(num(p["screen"].array[0]) + 0.5), cast(int)(num(p["screen"].array[1]) + 0.5)];
                found = true;
            }
        assert(found && tool() == "polyBevel", "bevel floor: no shift handle / tool not armed");
        penCommand("history.clear");
        const int[2] h2 = [h[0] - 30, h[1] - 51];
        const on = deliveredDuring(
            (ref Log l) { l.motion(h, 0); l.button(true, h); path(l, h, h2, 1, 3, 6); },
            (ref Log l) { path(l, h, h2, 4, 6, 6); l.button(false, h2); });
        penCommand("tool.set poly.bevel off");
        return on;
    }
    assert(!bevel(false), "bevel-snap-key-fresh: X was delivered to a fresh bevel haul");
    assert(bevel(true), "bevel-snap-key-after-move: X was not delivered after a Move session");
    flush();
}

// Topology pen point drag: its own guide -> the key is delivered. Delivery only:
// in this rig ours' topology pen does not grid-snap its point drag at all (a
// snap-on control equals the off one, measured), so the PRESS position law has
// no discriminating cell here.
unittest {
    penSceneEmpty("Top");
    loadMesh(`{"vertices":[[-1,1,-1],[1,1,-1],[1,1,1],[-1,1,1]],"faces":[[0,3,2,1]]}`);
    penCommand("layer.add name:Edit");
    camera();
    penCommand("tool.set mesh.topoPen on");
    penCommand("tool.attr mesh.topoPen mode point");
    penCommand(`tool.pipe.attr snap types "grid"`);
    penCommand("tool.pipe.attr snap enabled false");
    const int[2] a = worldPixel(Vec3(-0.33043f, 1, -0.19794f));
    const int[2] b = [a[0] + 73, a[1] + 10];
    Log l; l.motion(a, 0); l.button(true, a); l.button(false, a); l.play();
    assert(getJson("/api/model?layer=1")["vertexCount"].integer == 1,
        "topopen floor: the click placed no vertex on the background");
    l.motion(a, 0); l.button(true, a); path(l, a, b, 1, 15, 30);
    l.key(true, 1000); l.play();
    assert(snapOn(), "topopen-snap-key-hold: X was not delivered to the point drag");
    path(l, a, b, 16, 30, 30); l.button(false, b); l.play();
    l.key(false, 9000); l.play();
    // topopen-snap-key-switch: a switch to Move mid-drag ends the pen's guide (the
    // tool transition clears the registry; a later held button in Move holds none).
    if (cellOn("topopen-snap-key-switch")) {
        { Log m; m.motion(b, 0); m.button(true, b); path(m, b, a, 1, 4, 8); m.play(); }
        penCommand("tool.set move");
        { Log m; m.button(false, a); m.play(); }
        forgetConstraint();
        Log k; k.motion(a, 0); k.button(true, a); k.key(true, 1000); k.play();
        const afterSwitch = snapOn();
        k.key(false, 1100); k.button(false, a); k.play();
        penCommand("tool.pipe.attr snap enabled false");
        penCommand("tool.set move off");
        assert(!afterSwitch, "topopen-snap-key-switch: X was delivered in Move after a switch from "
            ~ "a topology pen drag (the pen's guide outlived its tool)");
    }
    penCommand("tool.set mesh.topoPen off");
    flush();
}

// Pen: a stroke point's drag holds the pen's guide whatever the guide bits
// (K-G3: always delivered); the guide ends at the release, so after the pen's
// clicks a held button holds no guide (task 9416).
unittest {
    penSceneEmpty("Top");
    camera();
    forgetConstraint();
    penCommand("tool.set pen on");
    penCommand("tool.pipe.attr snap enabled false");
    const int[2] a = worldPixel(Vec3(-0.2f, 1, 0)), b = worldPixel(Vec3(0.2f, 1, 0.1f));
    const int[2] e = [b[0] + 40, b[1]];
    void twoClicks() {
        Log l; l.motion(a, 0); l.button(true, a); l.button(false, a);
        l.motion(b, 0); l.button(true, b); l.button(false, b); l.play();
    }
    void cancelStroke(int[2] at) { Log l; l.button(true, at, 3); l.button(false, at, 3); l.play(); }
    foreach (types; ["", "worldAxis"]) {
        twoClicks();
        penCommand(`tool.pipe.attr snap types "` ~ types ~ `"`);
        Log l; l.motion(b, 0); l.button(true, b); path(l, b, e, 1, 4, 8); l.key(true, 1000); l.play();
        const on = snapOn();
        l.key(false, 1100); path(l, b, e, 5, 8, 8); l.button(false, e); l.play();
        penCommand("tool.pipe.attr snap enabled false");
        cancelStroke(e);
        assert(on, "pen-snap-key-drag (types '" ~ types ~ "'): X was not delivered to a stroke point drag");
    }
    twoClicks();
    Log l; l.button(true, b, 3); l.key(true, 1000); l.play();
    const leaked = snapOn();
    l.key(false, 1100); l.button(false, b, 3); l.play();
    penCommand("tool.pipe.attr snap enabled false");
    assert(!leaked, "pen-snap-key-after-click: X was delivered under a held button after the pen's "
        ~ "clicks (a click's guide outlived its release)");
    // pen-snap-key-drop: dropping the pen mid-drag ends its guide.
    twoClicks();
    { Log m; m.motion(b, 0); m.button(true, b); path(m, b, e, 1, 4, 8); m.play(); }
    penCommand("tool.set pen off");
    { Log m; m.button(false, e); m.play(); }
    forgetConstraint();
    penCommand("tool.set move");
    {
        Log k; k.motion(a, 0); k.button(true, a); k.key(true, 1000); k.play();
        const afterDrop = snapOn();
        k.key(false, 1100); k.button(false, a); k.play();
        penCommand("tool.pipe.attr snap enabled false");
        penCommand("tool.set move off");
        assert(!afterDrop, "pen-snap-key-drop: X was delivered in Move after the pen was dropped "
            ~ "mid-drag (the pen's guide outlived its tool)");
    }
    penCommand("tool.set pen on");
    // pen-snap-key-switch: a switch to Move mid-drag ends the pen's guide (a
    // later held button in Move holds none).
    twoClicks();
    { Log m; m.motion(b, 0); m.button(true, b); path(m, b, e, 1, 4, 8); m.play(); }
    penCommand("tool.set move");
    { Log m; m.button(false, e); m.play(); }
    forgetConstraint();
    Log k; k.motion(a, 0); k.button(true, a); k.key(true, 1000); k.play();
    const afterSwitch = snapOn();
    k.key(false, 1100); k.button(false, a); k.play();
    penCommand("tool.pipe.attr snap enabled false");
    penCommand("tool.set move off");
    assert(!afterSwitch, "pen-snap-key-switch: X was delivered in Move after a switch from a pen drag "
        ~ "(the pen's guide outlived its tool)");
    flush();
}
