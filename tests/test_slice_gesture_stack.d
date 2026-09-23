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
import drag_helpers : Vec3, fetchCamera, viewportFromCamera, projectToWindow;
import std.format : format;
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
