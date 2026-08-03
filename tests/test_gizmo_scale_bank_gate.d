// Task 0606 — WHICH banks push the scale boxes out, driven through the real
// tool, and does the pick region go with them.
//
// The geometry law (a tenth of the arm, at every handle size) is pinned in
// tests/test_gizmo_scale_bank_standoff.d against `ScaleHandler` directly.
// This file pins the thing that file cannot see: the GATE — the wrapper's
// decision about when to turn the stand-off on — plus the behavioural half of
// the hit-region claim, both through the shipped preset over HTTP.
//
// WHY THREE CELLS AND NOT TWO. An all-on cell against an all-off cell is
// consistent with "shift when translate is on", "shift when rotate is on" and
// "shift when either is on" — all three predict the same two readings, so
// that pair cannot name the gate, and the measuring run needed a second
// session to break the tie. It broke it by flipping one flag at a time off
// one arm: a cell with TRANSLATE OFF that shifted anyway, and a cell with
// ROTATE OFF that shifted anyway. Each refutes one of the single-flag rivals;
// the disjunction survives both. The same three cells are reproduced here, so
// a future edit that quietly narrows the gate to whichever term is convenient
// fails on the OTHER cell.
//
//   A  T=0 R=0 S=1   control — the scale bank alone, box at 1.00 of the arm
//   B  T=1 R=0 S=1   rotate OFF and shifted   -> kills gate(R)
//   C  T=0 R=1 S=1   translate OFF and shifted -> kills gate(T)
//
// Every cell writes all three flags explicitly. A preset re-arm does NOT
// clear attributes a previous `tool.attr` wrote — that leak spoiled one cell
// of the measuring run, which recorded it as a miss rather than reinterpreting
// the reading, and it would spoil these the same way.
//
// One preset (`Transform`) throughout, so presentation is constant and only
// the flags vary: in the compact presentation the scale bank registers axis
// HEAD handles whose screen anchor is the box itself. The per-mode
// `TransformScale` preset would have been the obvious control, but it draws
// the full bank, whose anchor is 70 % along the stem — a different point, and
// comparing the two would have measured the presentation rather than the gate.

import std.conv   : to;
import std.format : format;
import std.json;
import std.math   : abs, sqrt;
import std.net.curl : get, post;

import drag_helpers : playAndWait, fetchCamera, viewportFromCamera,
                      projectToWindow, gizmoSize, Vec3, Viewport;

void main() {}

private enum string baseUrl = "http://localhost:8080";

// Part-id bases from source/tools/transform/xfrm_transform.d — scale occupies
// 20..29, one part per axis head in the compact presentation.
private enum int SCALE_BASE = 20;

// The law, restated independently of handles/gl_util.d's enums.
private enum double ARM_ALONE  = 1.00;
private enum double ARM_BESIDE = 1.10;

private JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
private JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}
private void cmd(string script) { post(baseUrl ~ "/api/script", script); }

private string hoverLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            50.0 + i * 20.0, x, y);
    return log;
}

// Arm the bare Transform preset with an explicit T/R/S triple.
private void armCell(bool t, bool r, bool s) {
    cmd("tool.set Transform on");
    cmd("tool.attr Transform T " ~ (t ? "true" : "false"));
    cmd("tool.attr Transform R " ~ (r ? "true" : "false"));
    cmd("tool.attr Transform S " ~ (s ? "true" : "false"));
}

// Put `Transform` back the way the preset ships it. A worker runs its whole
// slice of tests against ONE vibe3d, and a preset re-arm does not clear
// attributes a `tool.attr` wrote — which is the same leak that spoiled a cell
// of the measuring run. Without this, the next test in the slice to arm
// `Transform` would get whatever flags the last cell here left, and would
// pass or fail for a reason having nothing to do with itself.
private void restoreTransformPreset() {
    cmd("tool.set Transform on");
    cmd("tool.attr Transform T true");
    cmd("tool.attr Transform R true");
    cmd("tool.attr Transform S true");
    cmd("tool.set Transform off");
}

// The screen anchor of one scale axis head, and whether it is registered and
// on-camera at all.
private bool scaleAnchor(int axis, out double sx, out double sy) {
    auto handles = getJson("/api/tool/handles")["handles"];
    if (handles.type == JSONType.null_) return false;
    foreach (p; handles["parts"].array) {
        if (cast(int)p["part"].integer != SCALE_BASE + axis) continue;
        if (!p["visible"].boolean) return false;
        if (p["screen"].type == JSONType.null_) return false;
        auto a = p["screen"].array;
        sx = a[0].floating;
        sy = a[1].floating;
        return true;
    }
    return false;
}

private Vec3 pivotFromState() {
    auto p = getJson("/api/tool/state")["pivot"].array;
    return Vec3(cast(float)p[0].floating,
                cast(float)p[1].floating,
                cast(float)p[2].floating);
}

// A camera that frames the gizmo obliquely, so no axis is near enough to the
// view direction to be culled and all three heads are readable.
private void setUp() {
    postJson("/api/reset", "");
    postJson("/api/camera", `{"azimuth":0.785,"elevation":0.6,"distance":3.2}`);
    postJson("/api/select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
}

// Where the box's outer face is PREDICTED to project, for a given arm factor.
// The gizmo carries the world basis here (fresh cube, auto action centre,
// world axis mode), the same assumption tests/drag_helpers.d's axisGrabPx
// makes; part 20/21/22 are +X/+Y/+Z in that order.
private void predict(int axis, double armFactor, Vec3 pivot,
                     ref Viewport vp, out float px, out float py) {
    float size = gizmoSize(pivot, vp);
    float d = cast(float)(size * armFactor);
    Vec3 w = pivot;
    if      (axis == 0) w.x += d;
    else if (axis == 1) w.y += d;
    else                w.z += d;
    assert(projectToWindow(w, vp, px, py),
           "the predicted box position is off-camera — the camera set-up "
           ~ "no longer frames the gizmo");
}

unittest { // The gate is (translate OR rotate) — three cells, one control
    setUp();
    scope(exit) restoreTransformPreset();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // --- Cell A: the control. The scale bank on its own must not move. -----
    armCell(false, false, true);
    Vec3 pivot = pivotFromState();

    double[3] aX, aY;
    bool[3]   aOk;
    foreach (axis; 0 .. 3) aOk[axis] = scaleAnchor(axis, aX[axis], aY[axis]);
    assert(aOk[0] && aOk[1] && aOk[2],
           "the control cell did not register all three scale heads — the "
           ~ "part numbering, the preset or the view cull changed, and the "
           ~ "comparison below has no baseline");

    foreach (axis; 0 .. 3) {
        float ex, ey;
        predict(axis, ARM_ALONE, pivot, vp, ex, ey);
        double err = sqrt((aX[axis] - ex) * (aX[axis] - ex)
                        + (aY[axis] - ey) * (aY[axis] - ey));
        assert(err < 1.5,
               format("control cell: scale head %d sits %.2f px from the arm "
                      ~ "end, where a bank drawn alone belongs. A stand-off "
                      ~ "has leaked into the alone case.", axis, err));
    }

    // --- Cells B and C: one companion each, and it is a DIFFERENT one. -----
    // B has rotate off, C has translate off. Both must shift, and that pair
    // is what makes the gate a disjunction rather than either single term.
    foreach (cell; 0 .. 2) {
        immutable bool t = (cell == 0);
        immutable bool r = (cell == 1);
        immutable string label = t ? "translate alone (rotate OFF)"
                                   : "rotate alone (translate OFF)";
        armCell(t, r, true);

        // The pivot must not have drifted between cells, or the distances
        // below are measuring the camera and not the box.
        Vec3 p2 = pivotFromState();
        assert(abs(p2.x - pivot.x) < 1e-4 && abs(p2.y - pivot.y) < 1e-4
                                          && abs(p2.z - pivot.z) < 1e-4,
               "the action centre moved between cells — nothing downstream "
               ~ "is comparable");

        foreach (axis; 0 .. 3) {
            double bx, by;
            assert(scaleAnchor(axis, bx, by),
                   format("%s: scale head %d vanished", label, axis));

            // Absolute: it must land on 1.10 of the arm.
            float ex, ey;
            predict(axis, ARM_BESIDE, pivot, vp, ex, ey);
            double err = sqrt((bx - ex) * (bx - ex) + (by - ey) * (by - ey));

            // And the rival it must NOT land on — the alone position, which
            // is where we drew it before this port and where a gate on the
            // other flag alone would still draw it.
            double toAlone = sqrt((bx - aX[axis]) * (bx - aX[axis])
                                + (by - aY[axis]) * (by - aY[axis]));

            assert(err < 1.5,
                   format("%s: scale head %d is %.2f px off the stood-off "
                          ~ "position (1.10 of the arm) and %.2f px from the "
                          ~ "alone position. Either the stand-off did not "
                          ~ "fire for this companion — which would make the "
                          ~ "gate the OTHER flag alone, not a disjunction — "
                          ~ "or it fired by the wrong amount.",
                          label, axis, err, toAlone));
            assert(toAlone > 6.0,
                   format("%s: scale head %d did not move away from the alone "
                          ~ "position (%.2f px). This companion does not gate "
                          ~ "the stand-off, so the gate is not a disjunction.",
                          label, axis, toAlone));
        }
    }
}

unittest { // The pick region tracks the box a companion bank pushed out
    // The trap this closes, in full: the stand-off could have been passed at
    // the DRAW call, whose sibling — the sync that re-derives what the hit
    // test reads — takes no arguments and would have kept the old distance.
    // The box would be drawn 12 px out and grabbed 12 px in.
    //
    // No amount of reading positions can see that. The anchor `/api/tool/-
    // handles` publishes is derived from the same field the draw overwrites
    // later in the frame, so it reports the DRAWN place either way. Only a
    // press can tell, and it has to be a press placed relative to the drawn
    // box: 6 px beyond it, which is inside the head's 12 px grab disc when
    // the pick region moved and 18 px outside it when it did not.
    setUp();
    scope(exit) restoreTransformPreset();
    auto cam = fetchCamera();

    foreach (cell; 0 .. 3) {
        immutable bool t = (cell == 1);
        immutable bool r = (cell == 2);
        immutable string label = cell == 0 ? "alone"
                               : cell == 1 ? "beside translate"
                                           : "beside rotate";
        armCell(t, r, true);

        auto vp = viewportFromCamera(cam);
        Vec3 pivot = pivotFromState();
        float cx, cy;
        assert(projectToWindow(pivot, vp, cx, cy), "pivot off-camera");

        // Probe the X head. Its anchor is the drawn box; step 6 px further
        // out along the same screen ray.
        double bx, by;
        assert(scaleAnchor(0, bx, by), label ~ ": scale head 0 not registered");
        double dx = bx - cx, dy = by - cy;
        double d  = sqrt(dx * dx + dy * dy);
        assert(d > 40.0,
               label ~ ": the box projects only " ~ d.to!string ~ " px from the "
               ~ "centre — too foreshortened for a 6 px step to mean anything");
        int probeX = cast(int)(bx + dx / d * 6.0);
        int probeY = cast(int)(by + dy / d * 6.0);

        playAndWait(hoverLog(cast(int)cam.vpX, cast(int)cam.vpY,
                             cast(int)cam.width, cast(int)cam.height,
                             probeX, probeY));

        auto after = getJson("/api/tool/handles")["handles"];
        int hot = cast(int)after["hot"].integer;
        assert(hot == SCALE_BASE,
               format("%s: hovering 6 px past the DRAWN scale box (%d, %d) "
                      ~ "made part %d hot, not the scale head %d. The drawn "
                      ~ "box and the region that grabs it are not in the same "
                      ~ "place.", label, probeX, probeY, hot, SCALE_BASE));
    }
}
