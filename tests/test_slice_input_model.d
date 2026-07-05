// Slice tool (mesh.sliceTool) — INTERACTIVE INPUT MODEL (task 0286).
//
// The owner observed the reference Slice tool's live interaction model and made
// it ground truth:
//   1. On tool activation NOTHING is shown (no gizmo/line/handles) and nothing is
//      cut — the viewport stays clean until the user acts.
//   2. The FIRST LMB click+drag sets BOTH points (down = Start, drag = End),
//      drawing the line and cutting the mesh.
//   3. The SECOND LMB click+drag TRANSLATES both points in the plane (the whole
//      line moves; both endpoints shift by the same delta) and re-cuts from the
//      baseline — still exactly ONE slice, never stacked.
//   4. Ctrl during the FIRST drag constrains the drawn line to the dominant
//      mouse-movement axis (an axis-aligned line).
//   5. Ctrl during the SECOND drag constrains the translation to a single axis
//      (the same dominant-axis lock MoveTool applies to a free move).
//
// Drives real SDL mouse sequences through /api/play-events (the interactive
// onMouseButtonDown/Motion/Up path), camera-agnostic: it reconstructs the same
// most-facing construction plane the tool picks and lays lines on it, so the cut
// always crosses the cube in a clean 4-edge belt (8v/6f -> 12v/10f). The Ctrl
// tests set the SDL keymod on the drag events (play-events restores modifier
// state, so SDL_GetModState() reads Ctrl inside the tool handler).

import std.net.curl;
import std.json;
import std.math  : abs, fabs, sqrt;
import std.format : format;
import core.thread : Thread;
import core.time   : dur;

import drag_helpers;   // Vec3, Viewport, fetchCamera, viewportFromCamera, projectToWindow, buildDragLog, playAndWait

void main() {}

enum string BASE = "http://localhost:8080";

// SDL keymod for the left Ctrl key (KMOD_LCTRL). `mods & KMOD_CTRL` in the tool
// is non-zero for this, so it engages the Ctrl axis-lock without touching
// Alt/Shift (which the tool reserves for camera nav / redraw).
enum uint KMOD_LCTRL = 64;

void cmd(string s) {
    auto resp = cast(string) post(BASE ~ "/api/command", s);
    assert(parseJSON(resp)["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ resp);
}

void resetCube() {
    auto resp = cast(string) post(BASE ~ "/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

JSONValue getModel()     { return parseJSON(cast(string) get(BASE ~ "/api/model")); }
JSONValue getToolState() { return parseJSON(cast(string) get(BASE ~ "/api/tool/state")); }
long undoCount()         { return parseJSON(cast(string) get(BASE ~ "/api/history"))["undo"].array.length; }

size_t vertCount() { return getModel()["vertices"].array.length; }
size_t faceCount() { return getModel()["faces"].array.length; }

void settle() { Thread.sleep(dur!"msecs"(180)); }   // post-playback drain guard

// Screen pixel for a world point on the active viewport.
void scr(Vec3 w, const ref Viewport vp, out int px, out int py) {
    float fx, fy;
    bool ok = projectToWindow(w, vp, fx, fy);
    assert(ok, "world point projected off-screen — camera assumptions broke");
    px = cast(int) (fx + 0.5f);
    py = cast(int) (fy + 0.5f);
}

// The tool's current Start / End line, read back from /api/tool/state.
void toolLine(out Vec3 s, out Vec3 e) {
    auto st = getToolState();
    s = Vec3(cast(float)st["startX"].floating, cast(float)st["startY"].floating,
             cast(float)st["startZ"].floating);
    e = Vec3(cast(float)st["endX"].floating, cast(float)st["endY"].floating,
             cast(float)st["endZ"].floating);
}

// The two in-plane world axes of the tool's auto construction plane (the two
// world axes most perpendicular to the view — the ones the tool's workplaneHit
// and the Ctrl axis-lock both operate within). U is laid along, V is the shift
// axis. Mirrors the frame reconstruction in test_slice_session.d.
void inPlaneAxes(const ref Viewport vp, out Vec3 U, out Vec3 V) {
    Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    float ax = fabs(camBack.x), ay = fabs(camBack.y), az = fabs(camBack.z);
    if (ax >= ay && ax >= az)       { V = Vec3(0,1,0); U = Vec3(0,0,1); }
    else if (ay >= ax && ay >= az)  { V = Vec3(1,0,0); U = Vec3(0,0,1); }
    else                            { V = Vec3(1,0,0); U = Vec3(0,1,0); }
}

// Count how many WORLD-AXIS components of `d` exceed `tol` in magnitude. A
// world-axis-aligned vector has exactly 1; a genuine diagonal has 2+. This is
// the camera-agnostic fingerprint the Ctrl axis-lock is asserted with.
int dominantAxisCount(Vec3 d, float tol = 0.2f) {
    int n = 0;
    if (fabs(d.x) > tol) n++;
    if (fabs(d.y) > tol) n++;
    if (fabs(d.z) > tol) n++;
    return n;
}

Vec3 sub(Vec3 a, Vec3 b) { return Vec3(a.x-b.x, a.y-b.y, a.z-b.z); }
Vec3 norm(Vec3 v) {
    float L = sqrt(v.x*v.x + v.y*v.y + v.z*v.z);
    return L > 1e-9f ? Vec3(v.x/L, v.y/L, v.z/L) : Vec3(0,0,0);
}

// ---------------------------------------------------------------------------
// (a) NOTHING is drawn/committed before the first drag, and (b) the FIRST drag
//     sets a line + cuts. (c) A SECOND drag translates BOTH endpoints by the
//     same delta and re-cuts from baseline — still exactly ONE slice.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    assert(vertCount() == 8 && faceCount() == 6, "fresh cube must be 8v/6f");
    immutable long baseUndo = undoCount();

    // Activate the tool. (a) NOTHING yet — no line drawn, mesh untouched.
    cmd("tool.set mesh.sliceTool on");
    settle();
    assert(getToolState()["lineDrawn"].type == JSONType.FALSE,
           "at activation no line is drawn (clean viewport)");
    assert(vertCount() == 8 && faceCount() == 6,
           "activation alone must not cut the mesh");
    assert(undoCount() == baseUndo, "activation must not commit anything");

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 U, V;
    inPlaneAxes(vp, U, V);

    // (b) FIRST drag: down = Start, drag = End — a fresh mid-plane line along U.
    Vec3 A1 = U * (-0.6f), B1 = U * (0.6f);
    int a1x, a1y, b1x, b1y;
    scr(A1, vp, a1x, a1y);
    scr(B1, vp, b1x, b1y);
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, a1x, a1y, b1x, b1y, 20, 0), BASE);
    settle();

    assert(getToolState()["lineDrawn"].type == JSONType.TRUE,
           "the first drag must mark a line as drawn");
    assert(vertCount() == 12 && faceCount() == 10,
           format("first drag must cut the cube (12v/10f), got %dv/%df",
                  vertCount(), faceCount()));

    Vec3 s0, e0; toolLine(s0, e0);   // the drawn line

    // (c) SECOND drag: click at the line midpoint (clear of the endpoints) and
    //     translate along V. BOTH endpoints must shift by the SAME delta.
    Vec3 mid0 = Vec3(0, 0, 0), mid1 = V * 0.3f;
    int m0x, m0y, m1x, m1y;
    scr(mid0, vp, m0x, m0y);
    scr(mid1, vp, m1x, m1y);
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, m0x, m0y, m1x, m1y, 20, 0), BASE);
    settle();

    assert(vertCount() == 12 && faceCount() == 10,
           format("second drag must refine ONE slice, not stack — got %dv/%df",
                  vertCount(), faceCount()));

    Vec3 s1, e1; toolLine(s1, e1);
    Vec3 dS = sub(s1, s0), dE = sub(e1, e0);
    // Both endpoints moved (a real translate, not a stray endpoint grab)...
    float dSlen = sqrt(dS.x*dS.x + dS.y*dS.y + dS.z*dS.z);
    assert(dSlen > 0.1f, format("second drag must move the line (|dStart|=%.3f)", dSlen));
    // ...and by the SAME delta (a rigid line translation).
    assert(fabs(dS.x - dE.x) < 0.02f && fabs(dS.y - dE.y) < 0.02f &&
           fabs(dS.z - dE.z) < 0.02f,
           format("both endpoints must translate by the same delta: dStart=(%.3f,%.3f,%.3f) dEnd=(%.3f,%.3f,%.3f)",
                  dS.x, dS.y, dS.z, dE.x, dE.y, dE.z));

    // Clean teardown — one baked undo entry for the whole session.
    cmd("tool.set mesh.sliceTool off");
    settle();
    assert(undoCount() == baseUndo + 1, "tool-drop must bake exactly one undo entry");
}

// ---------------------------------------------------------------------------
// (d) Ctrl during the FIRST drag axis-locks the drawn line DIRECTION. A diagonal
//     screen drag that WITHOUT Ctrl yields a diagonal (2-axis) line must, WITH
//     Ctrl, yield a world-axis-aligned (1-axis) line.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set mesh.sliceTool on");
    settle();

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 U, V;
    inPlaneAxes(vp, U, V);

    // Diagonal target: equal parts along both in-plane axes.
    Vec3 A = Vec3(0, 0, 0);
    Vec3 B = U * 0.5f + V * 0.5f;
    int ax, ay, bx, by;
    scr(A, vp, ax, ay);
    scr(B, vp, bx, by);

    // --- Control: NO Ctrl → the drawn line follows the diagonal (2 axes). ---
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, ax, ay, bx, by, 20, 0), BASE);
    settle();
    Vec3 sF, eF; toolLine(sF, eF);
    Vec3 dirFree = norm(sub(eF, sF));
    assert(dominantAxisCount(dirFree) >= 2,
           format("a diagonal drag WITHOUT Ctrl must give a non-axis-aligned line, dir=(%.3f,%.3f,%.3f)",
                  dirFree.x, dirFree.y, dirFree.z));

    // Redraw fresh with Ctrl held (Shift+drag would also redraw, but a fresh
    // tool session is the cleanest reset of the "first drag" state).
    cmd("tool.set mesh.sliceTool off");
    settle();
    resetCube();
    cmd("tool.set mesh.sliceTool on");
    settle();
    cam = fetchCamera(BASE);
    vp  = viewportFromCamera(cam);
    inPlaneAxes(vp, U, V);
    B = U * 0.5f + V * 0.5f;
    scr(Vec3(0,0,0), vp, ax, ay);
    scr(B, vp, bx, by);

    // --- Ctrl → the drawn line snaps to ONE dominant world axis. ---
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, ax, ay, bx, by, 20, KMOD_LCTRL), BASE);
    settle();
    Vec3 sC, eC; toolLine(sC, eC);
    Vec3 dirLock = norm(sub(eC, sC));
    assert(dominantAxisCount(dirLock) == 1,
           format("Ctrl on the first drag must axis-lock the line, dir=(%.3f,%.3f,%.3f)",
                  dirLock.x, dirLock.y, dirLock.z));

    cmd("tool.set mesh.sliceTool off");
    settle();
}

// ---------------------------------------------------------------------------
// (e) Ctrl during the SECOND drag axis-locks the TRANSLATION. A diagonal
//     translate that WITHOUT Ctrl moves the line along 2 axes must, WITH Ctrl,
//     move it along exactly ONE world axis (both endpoints by that same delta).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set mesh.sliceTool on");
    settle();

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 U, V;
    inPlaneAxes(vp, U, V);

    // Draw the line along U first (the first drag).
    Vec3 A1 = U * (-0.6f), B1 = U * (0.6f);
    int a1x, a1y, b1x, b1y;
    scr(A1, vp, a1x, a1y);
    scr(B1, vp, b1x, b1y);
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, a1x, a1y, b1x, b1y, 20, 0), BASE);
    settle();
    assert(vertCount() == 12, "first drag must cut");

    Vec3 s0, e0; toolLine(s0, e0);
    Vec3 mid0Line = (s0 + e0) * 0.5f;

    // Second drag with Ctrl: a diagonal translate (components along BOTH in-plane
    // axes) biased toward V — the axis PERPENDICULAR to the drawn line, so the
    // dominant-axis lock resolves to V and the translated line still crosses the
    // cube as a clean belt (translating ALONG the line's own axis would only shift
    // the clipped span, not translate the cut). WITHOUT Ctrl this is a 2-axis
    // move; WITH Ctrl the lock must collapse it to V alone.
    Vec3 startPix = Vec3(0, 0, 0);
    Vec3 endPix   = U * 0.1f + V * 0.4f;   // diagonal, V-dominant
    int m0x, m0y, m1x, m1y;
    scr(startPix, vp, m0x, m0y);
    scr(endPix,   vp, m1x, m1y);
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, m0x, m0y, m1x, m1y, 20, KMOD_LCTRL), BASE);
    settle();

    assert(vertCount() == 12 && faceCount() == 10, "Ctrl translate must keep ONE slice");

    Vec3 s1, e1; toolLine(s1, e1);
    Vec3 mid1Line = (s1 + e1) * 0.5f;
    Vec3 transl   = sub(mid1Line, mid0Line);
    // Both endpoints shifted by the same delta (rigid translate)...
    Vec3 dS = sub(s1, s0), dE = sub(e1, e0);
    assert(fabs(dS.x - dE.x) < 0.02f && fabs(dS.y - dE.y) < 0.02f &&
           fabs(dS.z - dE.z) < 0.02f,
           "Ctrl second drag must still translate both endpoints equally");
    // ...and the translation is along exactly ONE world axis.
    float tlen = sqrt(transl.x*transl.x + transl.y*transl.y + transl.z*transl.z);
    assert(tlen > 0.05f, format("Ctrl translate must actually move the line (|t|=%.3f)", tlen));
    assert(dominantAxisCount(transl, 0.05f) == 1,
           format("Ctrl on the second drag must axis-lock the translation, t=(%.3f,%.3f,%.3f)",
                  transl.x, transl.y, transl.z));

    cmd("tool.set mesh.sliceTool off");
    settle();
}
