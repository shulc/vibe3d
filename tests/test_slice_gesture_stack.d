// test_slice_gesture_stack.d — task 7137 (S1b), owner decisions В22 and В21
// for the Slice tool (Shift+C). Each press..release gesture that re-defines an
// existing line is its own undo step — a motionless click included — and
// Ctrl+Z pops them one at a time; the Ctrl+Z that removes the session's FIRST
// gesture cancels the cut, ends the tool and pops its activation row. Block R
// (verdict `C1-s-r verdict: R-first`): Ctrl+Shift+Z re-arms the tool WITH that
// first line, live and released, and the redo after it is empty. Law:
// doc/measured_laws.md §22, toolcards/bugfix_w17_slice_tools.
//
// All input is real SDL events (/api/play-events). Meshes are compared as
// canonical values (tests/slice_leak_helpers.d `slMesh`); every assert prints
// WHICH of the recorded meshes it got, so a mutation that pops the wrong step
// names itself.

import slice_leak_helpers;
import drag_helpers : Vec3, fetchCamera, viewportFromCamera, projectToWindow,
    gizmoSize, cross, dot, normalize;
import http_client : getJson;
import std.format : format;
import std.json : JSONType;
import std.math : PI, cos, sin, sqrt;
import std.stdio : writeln;

void main() {}

void ctrlZ(string what)      { slKey(SL_SDLK_z, SL_KMOD_LCTRL, what); }
void ctrlShiftZ(string what) { slKey(SL_SDLK_z, SL_KMOD_LCTRL | SL_KMOD_LSHIFT, what); }

unittest {
    auto pro = slPrologue(false, "polygons", &slBackAndLeft, false);
    const Hp = pro.historyLen;
    const base = slMesh();
    assert(base.verts == 8 && base.faces == 4,
           "slice floor: the prologue is not the 8v/4f open box: " ~ base.toString);

    slKey(SL_SDLK_c, SL_KMOD_LSHIFT, "Shift+C (Slice)");
    assert(slTool() == "slice", "slice floor: Shift+C did not activate the Slice tool");
    const Ha = slHistoryLen();
    assert(Ha == Hp + 1 && slHistoryLabels()[$ - 1] == "Activate Tool",
           format("slice floor: Shift+C did not write one activation row: %s", slHistoryLabels()));

    // Gesture 1 — the line (world x = 0).
    slSliceDrawLine();
    const M1 = slMesh();
    assert(M1.faces > 4, "slice floor: gesture 1 did not cut: " ~ M1.toString);

    // The line body's midpoint on screen: far from both endpoint handles.
    auto vp = viewportFromCamera(fetchCamera());
    float ax, ay, bx, by;
    assert(projectToWindow(Vec3(0, -0.6f, 0), vp, ax, ay)
           && projectToWindow(Vec3(0, 0.6f, 0), vp, bx, by),
           "slice rig: the slice line projects off screen");
    const mx = cast(int)((ax + bx) / 2), my = cast(int)((ay + by) / 2);

    // Gesture 2 — drag the line body 40 px (a translate re-defines the line).
    slFullDrag(mx, my, mx + 40, my, 8, "gesture 2 (line-body drag)");
    const M2 = slMesh();
    assert(M2.faces > 4 && M2.canon != M1.canon,
           format("second gesture did not re-define the line: mesh %s (gesture 1 %s)",
                  M2.toString, M1.toString));

    // Gesture 3 — a motionless click on the line body.
    const nx = mx + 40;
    slPlay(slMotion(20, nx, my, 0) ~ "\n" ~ slButton(40, true, 1, nx, my) ~ "\n"
         ~ slButton(60, false, 1, nx, my), "gesture 3 (motionless click)");
    const M3 = slMesh();
    assert(M3.canon == M2.canon && slHistoryLen() == Ha,
           format("slice floor: the motionless click changed the mesh or the history: %s, %s",
                  M3.toString, slHistoryLabels()));

    string which(const SlMesh m) {
        return m.canon == M2.canon ? "M2" : m.canon == M1.canon ? "M1"
             : m.canon == base.canon ? "base" : "other " ~ m.toString;
    }

    ctrlZ("Ctrl+Z 1");
    auto z1 = slMesh();
    assert(z1.canon == M2.canon && slTool() == "slice" && slHistoryLen() == Ha,
           format("a motionless gesture was not a separate undo step: mesh %s (expected M2), "
                  ~ "tool '%s', history %d (expected %d)",
                  which(z1), slTool(), slHistoryLen(), Ha));
    ctrlZ("Ctrl+Z 2");
    auto z2 = slMesh();
    assert(z2.canon == M1.canon && slTool() == "slice" && slHistoryLen() == Ha,
           format("ctrl+z did not pop the newest slice gesture: mesh %s (expected M1), "
                  ~ "tool '%s', history %d (expected %d)",
                  which(z2), slTool(), slHistoryLen(), Ha));
    ctrlZ("Ctrl+Z 3");
    auto z3 = slMesh();
    assert(z3.canon == base.canon && slTool() != "slice" && slHistoryLen() == Ha - 1,
           format("ctrl+z of the first gesture did not end the tool and pop its row: mesh %s "
                  ~ "(expected base), tool '%s', history %s (expected %d rows)",
                  which(z3), slTool(), slHistoryLabels(), Ha - 1));

    // Block R — verdict R-first.
    assert(slCanRedo(), "slice floor: no redo after the session ended");
    ctrlShiftZ("Ctrl+Shift+Z (re-arm)");
    auto r1 = slMesh();
    assert(slTool() == "slice" && r1.canon == M1.canon && slHistoryLen() == Ha,
           format("slice redo did not re-arm with its first gesture: tool '%s', mesh %s "
                  ~ "(expected M1), history %d (expected %d)",
                  slTool(), which(r1), slHistoryLen(), Ha));
    // Button-less motion across the line body: a released tool ignores it.
    string log;
    foreach (i; 1 .. 9) log ~= slMotion(20 + 20 * i, mx + 5 * i, my, 0) ~ "\n";
    slPlay(log, "button-less motion over the line body");
    auto r2 = slMesh();
    assert(r2.canon == M1.canon,
           format("slice redo left the re-armed tool mid-drag: mesh %s after a button-less "
                  ~ "motion (expected M1)", which(r2)));
    assert(!slCanRedo(), "slice redo: the redo after the re-arm is not empty");
    writeln("slice gesture stack: M1 ", M1, " M2 ", M2, " re-armed ", which(r2));
    slKey(SL_SDLK_w, 0, "W (drop Slice)");
}

// Block G — an RMB gap drag is its own undo step and restores the gap it
// changed (the gap is part of the line state a gesture writes). Added by the
// diff sweep: without it, the press-time latch of the gap drag stayed green.
unittest {
    slPrologue(false, "polygons", &slBackAndLeft, false);
    const base = slMesh();
    slKey(SL_SDLK_c, SL_KMOD_LSHIFT, "Shift+C (Slice)");
    const Ha = slHistoryLen();
    slSliceDrawLine();
    const M1 = slMesh();
    assert(M1.faces > 4, "slice floor (block G): the line did not cut: " ~ M1.toString);
    auto vp = viewportFromCamera(fetchCamera());
    float ax, ay, bx, by;
    projectToWindow(Vec3(0, -0.6f, 0), vp, ax, ay);
    projectToWindow(Vec3(0, 0.6f, 0), vp, bx, by);
    const mx = cast(int)((ax + bx) / 2) + 60, my = cast(int)((ay + by) / 2);
    string log = slMotion(20, mx, my, 0) ~ "\n" ~ slButton(40, true, 3, mx, my) ~ "\n";
    foreach (i; 1 .. 7) log ~= slMotion(40 + 20 * i, mx + 10 * i, my, 4) ~ "\n";
    log ~= slButton(200, false, 3, mx + 60, my);
    slPlay(log, "RMB gap drag");
    const M2 = slMesh();
    assert(M2.canon != M1.canon && slHistoryLen() == Ha,
           format("slice floor (block G): the gap drag did not change the cut: %s (line %s)",
                  M2.toString, M1.toString));
    slKey(SL_SDLK_z, SL_KMOD_LCTRL, "Ctrl+Z (the gap drag)");
    const z = slMesh();
    assert(z.canon == M1.canon && slTool() == "slice",
           format("an RMB gap drag was not its own undo step: mesh %s (expected the line's %s, "
                  ~ "base %s), tool '%s'", z.toString, M1.toString, base.toString, slTool()));
    slKey(SL_SDLK_w, 0, "W (drop Slice)");
}

// The line's endpoints and the body midpoint on screen (world x = 0, y ±0.6).
void slLinePixels(out int ax, out int ay, out int bx, out int by, out int mx, out int my) {
    auto vp = viewportFromCamera(fetchCamera());
    float fax, fay, fbx, fby;
    assert(projectToWindow(Vec3(0, -0.6f, 0), vp, fax, fay)
           && projectToWindow(Vec3(0, 0.6f, 0), vp, fbx, fby),
           "slice rig: the slice line projects off screen");
    ax = cast(int)fax; ay = cast(int)fay; bx = cast(int)fbx; by = cast(int)fby;
    mx = cast(int)((fax + fbx) / 2); my = cast(int)((fay + fby) / 2);
}

/// Press at (x0, y0) and hold the button over `n` motions to (x1, y1) —
/// no release.
void slPressHold(int x0, int y0, int x1, int y1, int n, string what) {
    slClickDown(x0, y0, what ~ " (press)");
    string log;
    foreach (i; 1 .. n + 1)
        log ~= slMotion(20 + 20 * i, x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n, 1) ~ "\n";
    slPlay(log, what ~ " (held motion)");
}

float len3(Vec3 v) { return sqrt(dot(v, v)); }

bool slLineDrawn() {
    auto s = getJson("/api/tool/state");
    return ("lineDrawn" in s.object) !is null && s["lineDrawn"].type == JSONType.true_;
}

// Block D — Ctrl+Z DURING a drag on gesture N > 1 cancels ONLY the gesture in
// flight: the mesh returns to gesture N-1's, the stack keeps gestures 1..N-1,
// the tool stays and the history does not move. This is the owner's standing
// rule ("the first Ctrl+Z cancels the LIVE edit, the tool stays"), NOT a
// captured law — gap row 225. The release that follows is a stray and changes
// nothing.
unittest {
    slPrologue(false, "polygons", &slBackAndLeft, false);
    const base = slMesh();
    slKey(SL_SDLK_c, SL_KMOD_LSHIFT, "Shift+C (Slice)");
    const Ha = slHistoryLen();
    slSliceDrawLine();
    const M1 = slMesh();
    int ax, ay, bx, by, mx, my;
    slLinePixels(ax, ay, bx, by, mx, my);
    slFullDrag(mx, my, mx + 40, my, 8, "block D gesture 2 (line-body drag)");
    const M2 = slMesh();
    assert(M1.faces > 4 && M2.canon != M1.canon,
           format("slice floor (block D): gestures 1/2 did not cut distinct lines: %s, %s",
                  M1.toString, M2.toString));

    string which(const SlMesh m) {
        return m.canon == M2.canon ? "M2" : m.canon == M1.canon ? "M1"
             : m.canon == base.canon ? "base" : "other " ~ m.toString;
    }

    slPressHold(mx + 40, my, mx + 80, my, 8, "block D gesture 3 (in flight)");
    const mid = slMesh();
    assert(mid.canon != M2.canon,
           "slice floor (block D): the in-flight gesture 3 did not move the cut: " ~ which(mid));
    ctrlZ("block D Ctrl+Z mid-drag");
    const d = slMesh();
    assert(slTool() == "slice" && d.canon == M2.canon && slHistoryLen() == Ha,
           format("ctrl+z mid-drag did not cancel only the gesture in flight: tool '%s', mesh %s "
                  ~ "(expected M2), history %d (expected %d)", slTool(), which(d),
                  slHistoryLen(), Ha));
    slPlay(slButton(20, false, 1, mx + 80, my), "block D stray release");
    const r = slMesh();
    assert(r.canon == M2.canon && slHistoryLen() == Ha,
           format("the release after a mid-drag ctrl+z changed something: mesh %s (expected M2), "
                  ~ "history %d", which(r), slHistoryLen()));
    ctrlZ("block D Ctrl+Z (gesture 2)");
    const z2 = slMesh();
    assert(slTool() == "slice" && z2.canon == M1.canon && slHistoryLen() == Ha,
           format("the mid-drag cancel lost gesture 2 off the stack: tool '%s', mesh %s "
                  ~ "(expected M1), history %d (expected %d)", slTool(), which(z2),
                  slHistoryLen(), Ha));
    ctrlZ("block D Ctrl+Z (gesture 1)");
    const z1 = slMesh();
    assert(slTool() != "slice" && z1.canon == base.canon && slHistoryLen() == Ha - 1,
           format("the mid-drag cancel lost gesture 1: tool '%s', mesh %s (expected base), "
                  ~ "history %d (expected %d)", slTool(), which(z1), slHistoryLen(), Ha - 1));
}

// Block D1 — the same on gesture 1: Ctrl+Z mid-drag returns to the armed
// state before it (tool stays, no line captured, no history row moved).
unittest {
    slPrologue(false, "polygons", &slBackAndLeft, false);
    const base = slMesh();
    slKey(SL_SDLK_c, SL_KMOD_LSHIFT, "Shift+C (Slice)");
    const Ha = slHistoryLen();
    int ax, ay, bx, by, mx, my;
    slLinePixels(ax, ay, bx, by, mx, my);
    slPressHold(ax, ay, bx, by, 10, "block D1 gesture 1 (in flight)");
    const mid = slMesh();
    assert(mid.faces > 4 && slLineDrawn(),
           "slice floor (block D1): the in-flight gesture 1 did not preview a cut: " ~ mid.toString);
    ctrlZ("block D1 Ctrl+Z mid-drag");
    const d = slMesh();
    assert(slTool() == "slice" && d.canon == base.canon && slHistoryLen() == Ha && !slLineDrawn(),
           format("ctrl+z mid-drag on gesture 1 did not return to the armed tool: tool '%s', "
                  ~ "mesh %s (base %s), history %d (expected %d), lineDrawn %s",
                  slTool(), d.toString, base.toString, slHistoryLen(), Ha, slLineDrawn()));
    slPlay(slButton(20, false, 1, bx, by), "block D1 stray release");
    assert(slMesh().canon == base.canon && !slLineDrawn() && slHistoryLen() == Ha,
           "the release after a mid-drag ctrl+z on gesture 1 captured a line");
    slKey(SL_SDLK_w, 0, "W (drop Slice)");
}

// Block N — a raw `history.redo` re-arm (bare, by design) spends the first
// gesture a navigate undo held: the next navigate undo + redo re-arms bare
// and does not replay it.
unittest {
    slPrologue(false, "polygons", &slBackAndLeft, false);
    const base = slMesh();
    slKey(SL_SDLK_c, SL_KMOD_LSHIFT, "Shift+C (Slice)");
    slSliceDrawLine();
    const M1 = slMesh();
    ctrlZ("block N Ctrl+Z (ends the session)");
    assert(slTool() != "slice" && slMesh().canon == base.canon,
           "slice floor (block N): ctrl+z did not end the one-gesture session");
    slCmd("history.redo");
    assert(slTool() == "slice" && slMesh().canon == base.canon,
           "slice floor (block N): the raw history.redo did not re-arm bare");
    ctrlZ("block N Ctrl+Z (undoes the raw re-arm)");
    assert(slTool() != "slice", "slice floor (block N): ctrl+z did not undo the raw re-arm");
    ctrlShiftZ("block N Ctrl+Shift+Z");
    const r = slMesh();
    assert(slTool() == "slice" && r.canon == base.canon,
           format("a navigate redo replayed a first gesture a raw redo had already spent: "
                  ~ "tool '%s', mesh %s (base %s, the spent gesture %s)", slTool(),
                  r.canon == M1.canon ? "M1" : r.toString, base.toString, M1.toString));
    slKey(SL_SDLK_w, 0, "W (drop Slice)");
}

// Block O — a rotate-ring gesture (Custom axis) is its own step and its undo
// restores the orientation it wrote (vector).
unittest {
    slPrologue(false, "polygons", &slBackAndLeft, false);
    slKey(SL_SDLK_c, SL_KMOD_LSHIFT, "Shift+C (Slice)");
    const Ha = slHistoryLen();
    slSliceDrawLine();
    Vec3 lineEnd(string p) {
        auto st = getJson("/api/tool/state");
        return Vec3(cast(float)st[p ~ "X"].floating, cast(float)st[p ~ "Y"].floating,
                    cast(float)st[p ~ "Z"].floating);
    }
    // The Custom extrusion vector that reproduces the drawn plane (the line
    // runs along Y; the draw classified the Z extrusion). Written without a
    // degenerate intermediate vector.
    const ld = normalize(lineEnd("end") - lineEnd("start"));
    assert(ld.y > 0.99f && getJson("/api/tool/state")["axis"].str == "z",
           "slice rig (block O): the drawn line is not the Y line with a Z extrusion");
    slLine("tool.attr mesh.sliceTool vectorZ 1");
    slLine("tool.attr mesh.sliceTool vectorY 0");
    slLine("tool.attr mesh.sliceTool axis custom");
    Vec3 vec() {
        auto s = getJson("/api/tool/state");
        return Vec3(cast(float)s["vectorX"].floating, cast(float)s["vectorY"].floating,
                    cast(float)s["vectorZ"].floating);
    }
    const Mc = slMesh();
    const v0 = vec();
    assert(getJson("/api/tool/state")["axis"].str == "custom" && Mc.faces > 4,
           "slice floor (block O): the Custom-axis line did not cut: " ~ Mc.toString);
    auto st = getJson("/api/tool/state");
    const s0 = Vec3(cast(float)st["startX"].floating, cast(float)st["startY"].floating,
                    cast(float)st["startZ"].floating);
    const e0 = Vec3(cast(float)st["endX"].floating, cast(float)st["endY"].floating,
                    cast(float)st["endZ"].floating);
    auto vp = viewportFromCamera(fetchCamera());
    const c = (s0 + e0) * 0.5f;
    const radius = gizmoSize(c, vp, 46.0f);   // SliceTool.RING_RADIUS_PX
    Vec3 a = normalize(e0 - s0);
    Vec3 rg = cross(a, Vec3(0, 1, 0));
    if (sqrt(dot(rg, rg)) < 1e-6f) rg = cross(a, Vec3(1, 0, 0));
    rg = normalize(rg);
    Vec3 up = normalize(cross(a, rg));
    float p0x, p0y, p1x, p1y;
    enum float A0 = PI * 0.5f, DA = 0.7f;
    assert(projectToWindow(c + rg * (cos(A0) * radius) + up * (sin(A0) * radius), vp, p0x, p0y)
           && projectToWindow(c + rg * (cos(A0 + DA) * radius) + up * (sin(A0 + DA) * radius),
                              vp, p1x, p1y),
           "slice rig (block O): the rotate ring projects off screen");
    slFullDrag(cast(int)(p0x + 0.5f), cast(int)(p0y + 0.5f), cast(int)(p1x + 0.5f),
               cast(int)(p1y + 0.5f), 20, "block O rotate-ring drag");
    const Mr = slMesh();
    const v1 = vec();
    assert(Mr.canon != Mc.canon && len3(v1 - v0) > 1e-3f && slHistoryLen() == Ha,
           format("slice floor (block O): the ring drag did not tilt the cut: vector %s -> %s, "
                  ~ "mesh changed %s", v0, v1, Mr.canon != Mc.canon));
    ctrlZ("block O Ctrl+Z (the ring gesture)");
    const z = slMesh();
    const vz = vec();
    assert(slTool() == "slice" && z.canon == Mc.canon && len3(vz - v0) < 1e-5f,
           format("a rotate-ring gesture was not undone off the stack: tool '%s', mesh restored %s, "
                  ~ "vector %s (expected %s)", slTool(), z.canon == Mc.canon, vz, v0));
    slKey(SL_SDLK_w, 0, "W (drop Slice)");
}
