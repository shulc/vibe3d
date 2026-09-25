// The three cutting tools on the tool session model (slice M3,
// doc/tool_session_model_plan_2026-09-24.md R2.5 M3, R4.3, R4.5; captures in
// toolcards/tool_session_model: M0 H1/H2/H4/H5, M0b C-H1-door, M0c
// C-H2-ls-insert). The session owns each tool's gesture steps as ATTRIBUTE
// IMAGES, their redo, the window's first group and the activation row that
// group joins when the arm came through the key/UI door.
//
//   C-H1-es    Edge Slice armed by the UI door: the undo of the first gesture
//              ends the tool with its activation row.            (m3a)
//   C-H1-door  the same through the SCRIPT door: the first undo pops only the
//              gesture, the tool stays; the second pops the activation (gap
//              300, C-H1-door-es-api).                             (m3e)
//   C-H1-door-slice  the door rule on Slice (extrapolated from Edge Slice's
//              capture): script arm, first line, Ctrl+Z -> no line, tool stays.
//   ES-idle-middle   a Middle tap on an idle Edge Slice opens nothing.
//   C-H4-es    two latches, Ctrl+Z, Ctrl+Shift+Z: the popped point comes back
//              LIVE, and a third latch continues the same window.  (m3b)
//   C-H5-es    a Middle press inside the chain is a boundary of its own — no
//              point, no clone — and its undo leaves the chain.   (m3d)
//   EW         Edge Slice: a re-pick drag of point 2 is one step; its undo
//              restores the point's `t` (attribute, asserted FIRST) and then
//              the cut (mesh).        (chain out of the image / empty rebuild)
//   SW         Slice: a relocated line cut on the frozen plane N1, an orbit, a
//              fresh line on N2; the undo restores N1 (attribute, FIRST) and
//              the (L1, N1) cut (mesh).  (frozenNormal out of the image)
//   C-H1-ls    Loop Slice (UI door): the arming press's cut is the first group,
//              its drag a step of its own.                         (m3c)
//   LW(a)      Loop Slice: scrub A, scrub B, Ctrl+Z -> positions after A, then
//              the cut at A.                         (empty rebuild)
//   LW(b)      Loop Slice: scrub, `insertAt` (an Action write), Ctrl+Z -> the
//              insert alone is undone: count 1 at the scrubbed position (P1);
//              Ctrl+Z again -> the arm-time position, still armed.
//   S7         a raw `history.undo` between two navigate redos: the second
//              navigate redo re-arms BARE (the first group is replayed once).
//
// Every gesture is real SDL input through /api/play-events; Ctrl+Z and
// Ctrl+Shift+Z are keystrokes (the navigate chokepoint). Rig:
// tests/slice_leak_helpers.d (the 8v/4f open box). Each cell asserts
// BEHAVIOUR only (tool, points, mesh, attributes), so it reads the same on a
// binary before this slice: red there exactly where the law changed
// (C-H1-door, C-H4-es, C-H5-es, EW, LW(b)); the rest are regression witnesses
// and mutation targets. `VIBE3D_CELL=<id>` runs one cell alone (druntime stops
// a module at its first failed assert, which would hide the cells after it).

import slice_leak_helpers;
import http_client : getJson, postJson;
import drag_helpers : Vec3, fetchCamera, viewportFromCamera, projectToWindow;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs, round, sqrt;
import std.stdio : writeln;
import std.process : environment;

void main() {}

bool cell(string id) {
    const only = environment.get("VIBE3D_CELL", "");
    return only.length == 0 || only == id;
}

enum int[2][3] HINT_OFF = [[315, 303], [531, 355], [616, 270]];
enum SL_SDLK_x = 120;

void ctrlZ(string what)      { slKey(SL_SDLK_z, SL_KMOD_LCTRL, what); }
void ctrlShiftZ(string what) { slKey(SL_SDLK_z, SL_KMOD_LCTRL | SL_KMOD_LSHIFT, what); }

JSONValue toolState() { return getJson("/api/tool/state"); }

double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger : v.floating;
}

SlMesh boxRig(out long Hp) {
    auto pro = slPrologue(false, "polygons", &slBackAndLeft, true);
    Hp = pro.historyLen;
    const base = slMesh();
    assert(base.verts == 8 && base.faces == 4,
           "slice floor: the prologue is not the 8v/4f open box: " ~ base.toString);
    return base;
}

/// Latch point k of the front/right chain: press on the edge, short drag, release.
int[2] latch(const long[2][] P, size_t k, string tag) {
    const px = slEdgePixel(P[k][0], P[k][1], HINT_OFF[k], format("point %d (%s)", k + 1, tag));
    slClickDown(px[0], px[1], format("click %d (%s)", k + 1, tag));
    slDragUp(px[0], px[1], 0, 4, 3, format("drag %d (%s)", k + 1, tag));
    assert(slChain().pairs.length == k + 1,
           format("slice floor (%s): %d point(s) after latch %d", tag, slChain().pairs.length, k + 1));
    return px;
}

// ---------------------------------------------------------------------------
// C-H1-es — the UI (key) door: the first group takes the activation with it.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("C-H1-es")) return;
    long Hp;
    const base = boxRig(Hp);
    slLineUi("tool.set mesh.edgeSliceTool on");
    assert(slTool() == "edgeSlice" && slHistoryLen() == Hp + 1,
           format("slice floor (C-H1-es): the UI arm did not write its row: %s", slHistoryLabels()));
    latch(slFrontRightChain(), 0, "C-H1-es");
    ctrlZ("C-H1-es Ctrl+Z 1");
    assert(slTool() != "edgeSlice" && slHistoryLen() == Hp && slMesh().canon == base.canon,
           format("C-H1-es: the first Ctrl+Z after a UI-door arm did not end Edge Slice with its "
                  ~ "activation row: tool '%s', history %s (prologue %d), mesh %s",
                  slTool(), slHistoryLabels(), Hp, slMesh().toString));
    // The navigate redo re-seats the first group on a fresh tool — with its
    // baseline: the next point cuts (the replayed chain is a live chain).
    ctrlShiftZ("C-H1-es Ctrl+Shift+Z");
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 1,
           format("C-H1-es: the navigate redo did not re-arm with the first point: tool '%s', "
                  ~ "points %d", slTool(), slChain().pairs.length));
    latch(slFrontRightChain(), 1, "C-H1-es replay");
    assert(slMesh().faces > base.faces,
           format("C-H1-es: a point latched after the replay did not cut (the replayed chain "
                  ~ "has no baseline): mesh %s", slMesh().toString));
    slLine("tool.set mesh.edgeSliceTool off");
}

// ---------------------------------------------------------------------------
// C-H1-door-es-api — the SCRIPT door keeps its own row.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("C-H1-door")) return;
    long Hp;
    const base = boxRig(Hp);
    slLine("tool.set mesh.edgeSliceTool on");
    assert(slTool() == "edgeSlice" && slHistoryLen() == Hp + 1,
           format("slice floor (C-H1-door): the script arm did not write its row: %s",
                  slHistoryLabels()));
    latch(slFrontRightChain(), 0, "C-H1-door");
    ctrlZ("C-H1-door Ctrl+Z 1");
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 0 && slHistoryLen() == Hp + 1
           && slMesh().canon == base.canon,
           format("C-H1-door-es-api: the first Ctrl+Z after a SCRIPT arm must pop only the gesture "
                  ~ "and keep the tool (gap 300): tool '%s', points %d, history %s (prologue %d)",
                  slTool(), slChain().pairs.length, slHistoryLabels(), Hp));
    ctrlZ("C-H1-door Ctrl+Z 2");
    assert(slTool() != "edgeSlice" && slHistoryLen() == Hp,
           format("C-H1-door-es-api: the second Ctrl+Z did not pop the activation: tool '%s', "
                  ~ "history %s", slTool(), slHistoryLabels()));
}

// ---------------------------------------------------------------------------
// C-H1-door for Slice — the same door rule (gap 300 was captured on Edge
// Slice; the plan's `arm(door)` is one rule for the three tools): armed by the
// SCRIPT door, the first Ctrl+Z undoes the first line and its cut — back to
// the image the window opened from, no line — and the tool stays.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("C-H1-door-slice")) return;
    long Hp;
    const base = boxRig(Hp);
    slLine("tool.set mesh.sliceTool on");
    assert(slTool() == "slice" && slHistoryLen() == Hp + 1,
           "slice floor (C-H1-door-slice): the script arm did not write its row");
    slSliceDrawLine();
    assert(slMesh().faces > base.faces, "slice floor (C-H1-door-slice): the line did not cut");
    ctrlZ("C-H1-door-slice Ctrl+Z 1");
    assert(slTool() == "slice" && slHistoryLen() == Hp + 1 && slMesh().canon == base.canon
           && toolState()["lineDrawn"].type == JSONType.false_,
           format("C-H1-door-slice: the first Ctrl+Z after a script arm must undo the first line "
                  ~ "and its cut and keep the tool: tool '%s', history %s, mesh %s, state %s",
                  slTool(), slHistoryLabels(), slMesh().toString, toolState().toString));
    ctrlZ("C-H1-door-slice Ctrl+Z 2");
    assert(slTool() != "slice" && slHistoryLen() == Hp,
           "C-H1-door-slice: the second Ctrl+Z did not pop the activation");
}

// ---------------------------------------------------------------------------
// An IDLE Edge Slice takes no Middle press: with nothing latched there is no
// window for a boundary to open in (the press is not the tool's), so after a
// script arm the Ctrl+Z that follows pops the activation, not an empty group.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("ES-idle-middle")) return;
    long Hp;
    boxRig(Hp);
    slLine("tool.set mesh.edgeSliceTool on");
    const px = slEdgePixel(slFrontRightChain()[0][0], slFrontRightChain()[0][1], HINT_OFF[0],
                           "ES-idle-middle");
    slPlay(slMotion(20, px[0], px[1], 0) ~ "\n" ~ slButton(40, true, 2, px[0], px[1]) ~ "\n"
         ~ slButton(60, false, 2, px[0], px[1]), "the idle Middle tap");
    ctrlZ("ES-idle-middle Ctrl+Z");
    assert(slTool() != "edgeSlice" && slHistoryLen() == Hp,
           format("ES-idle-middle: a Middle tap on an idle Edge Slice opened a window: tool '%s', "
                  ~ "history %s", slTool(), slHistoryLabels()));
}

// ---------------------------------------------------------------------------
// RV-stash (review B1) — rule K after Enter: the first group of the re-armed
// chain stashes on its undo; once the history moves (the committed chain is
// undone), redo must redo the COMMITTED row, not re-seat the stale point on
// the pre-commit mesh.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("RV-stash")) return;
    long Hp;
    const base = boxRig(Hp);
    slLineUi("tool.set mesh.edgeSliceTool on");
    const P = slFrontRightChain();
    latch(P, 0, "RV-stash");
    latch(P, 1, "RV-stash");
    slKey(13, 0, "RV-stash Enter");
    const C = slMesh();
    assert(C.faces > base.faces && slChain().pairs.length == 0,
           "slice floor (RV-stash): Enter did not commit the chain");
    {   // point 3 starts a NEW chain (one point) on the committed mesh
        const px = slEdgePixel(P[2][0], P[2][1], HINT_OFF[2], "RV-stash point 3");
        slClickDown(px[0], px[1], "RV-stash click 3");
        slDragUp(px[0], px[1], 0, 4, 3, "RV-stash drag 3");
        assert(slChain().pairs.length == 1, "slice floor (RV-stash): point 3 did not latch");
    }
    ctrlZ("RV-stash Z1");
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 0 && slMesh().canon == C.canon,
           format("slice floor (RV-stash): Z1 is not K1: points %d, mesh %s",
                  slChain().pairs.length, slMesh().toString));
    ctrlZ("RV-stash Z2");
    assert(slMesh().canon == base.canon,
           format("slice floor (RV-stash): Z2 did not undo the committed chain: %s", slMesh().toString));
    ctrlShiftZ("RV-stash redo");
    assert(slMesh().canon == C.canon && slChain().pairs.length == 0,
           format("RV-stash: the redo after Z2 must bring back the committed Edge Slice row: mesh %s "
                  ~ "(committed %s), points %d, history %s", slMesh().toString, C.toString,
                  slChain().pairs.length, slHistoryLabels()));
    slLine("tool.set mesh.edgeSliceTool off");
}

// ---------------------------------------------------------------------------
// C-H4-es — the redo of a popped live step returns it live; the window goes on.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("C-H4-es")) return;
    long Hp;
    const base = boxRig(Hp);
    slLineUi("tool.set mesh.edgeSliceTool on");
    const P = slFrontRightChain();
    latch(P, 0, "C-H4-es");
    latch(P, 1, "C-H4-es");
    const M2 = slMesh();
    assert(M2.faces > base.faces, "slice floor (C-H4-es): two points did not cut: " ~ M2.toString);
    ctrlZ("C-H4-es Ctrl+Z");
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 1 && slMesh().canon == base.canon,
           format("slice floor (C-H4-es): Ctrl+Z did not pop the second point: tool '%s', points %d",
                  slTool(), slChain().pairs.length));
    // One point is no armed cut: the rebuild re-derives the phase from the chain.
    assert(toolState()["armed"].type == JSONType.false_ && toolState()["phase"].str == "edgeA",
           format("C-H4-es: a one-point chain restored as armed: %s", toolState().toString));
    ctrlShiftZ("C-H4-es Ctrl+Shift+Z");
    assert(slChain().pairs.length == 2 && slMesh().canon == M2.canon,
           format("C-H4-es: the redo did not return the popped point LIVE: points %d, mesh %s "
                  ~ "(two-point cut %s); tool state %s", slChain().pairs.length, slMesh().toString,
                  M2.toString, toolState().toString));
    latch(P, 2, "C-H4-es");
    assert(slChain().pairs.length == 3 && slHistoryLen() == Hp + 1,
           format("C-H4-es: the third point did not continue the same window: points %d, "
                  ~ "history %s", slChain().pairs.length, slHistoryLabels()));
    slLine("tool.set mesh.edgeSliceTool off");
}

// ---------------------------------------------------------------------------
// C-H5-es-mmb — a Middle press inside the chain: a boundary, no point.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("C-H5-es")) return;
    long Hp;
    const base = boxRig(Hp);
    slLineUi("tool.set mesh.edgeSliceTool on");
    const px = latch(slFrontRightChain(), 0, "C-H5-es-mmb");
    const M1 = slMesh();
    slPlay(slMotion(20, px[0], px[1], 0) ~ "\n" ~ slButton(40, true, 2, px[0], px[1]) ~ "\n"
         ~ slButton(60, false, 2, px[0], px[1]), "the Middle tap");
    assert(slChain().pairs.length == 1 && slMesh().canon == M1.canon,
           format("C-H5-es-mmb: the Middle tap must add no point (no clone): points %d, mesh %s",
                  slChain().pairs.length, slMesh().toString));
    ctrlZ("C-H5-es-mmb Ctrl+Z");
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 1,
           format("C-H5-es-mmb: the Ctrl+Z after the Middle tap must pop only its boundary: "
                  ~ "tool '%s', points %d", slTool(), slChain().pairs.length));
    ctrlZ("C-H5-es-mmb Ctrl+Z 2");
    assert(slTool() != "edgeSlice" && slMesh().canon == base.canon && slHistoryLen() == Hp,
           format("slice floor (C-H5-es-mmb): the first group did not end the tool: tool '%s'",
                  slTool()));
}

// ---------------------------------------------------------------------------
// EW — a re-pick drag is one step; the image restores the point, then the cut.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("EW")) return;
    long Hp;
    boxRig(Hp);
    slLineUi("tool.set mesh.edgeSliceTool on");
    const P = slFrontRightChain();
    latch(P, 0, "EW");
    latch(P, 1, "EW");
    const M2 = slMesh();
    latch(P, 2, "EW");
    const M3 = slMesh();
    const t0 = slLatchedT();
    assert(t0.length == 3 && toolState()["activePoint"].integer == 2,
           format("slice floor (EW): latchedT %s, activePoint %s", t0, toolState()["activePoint"]));

    // Re-pick point 2 (index 1) on its handle and drag it along its edge.
    int[2] hp;
    bool found;
    foreach (q; getJson("/api/tool/handles")["handles"]["parts"].array)
        if (q["part"].integer == 1 && q["screen"].type == JSONType.array) {
            hp = [cast(int)round(num(q["screen"][0])), cast(int)round(num(q["screen"][1]))];
            found = true;
        }
    assert(found, "slice rig (EW): no on-screen handle for point 2");
    slClickDown(hp[0], hp[1], "EW re-pick press");
    assert(toolState()["activePoint"].integer == 1,
           "slice floor (EW): the press did not re-pick point 2");
    slDragUp(hp[0], hp[1], 0, -6, 4, "EW re-pick drag");
    const t1 = slLatchedT();
    const M4 = slMesh();
    assert(t1.length == 3 && abs(t1[1] - t0[1]) > 1e-3 && M4.canon != M3.canon,
           format("slice floor (EW): the re-pick drag did not move point 2: t %s -> %s", t0, t1));

    ctrlZ("EW Ctrl+Z 1");
    const tz = slLatchedT();
    // The attribute FIRST: the image restores point 2's t and the active point
    // the image held before the press (the last latch, 2).
    assert(tz.length == 3 && abs(tz[1] - t0[1]) <= 1e-6
           && toolState()["activePoint"].integer == 2,
           format("EW: the undo of the re-pick drag did not restore the chain image: latchedT %s "
                  ~ "(before the drag %s), activePoint %s",
                  tz, t0, toolState()["activePoint"]));
    // Then the cut: the preview rebuilt FROM the restored image.
    assert(slMesh().canon == M3.canon,
           format("EW: the undo restored the chain but not its cut: mesh %s, expected %s",
                  slMesh().toString, M3.toString));
    ctrlZ("EW Ctrl+Z 2");
    assert(slLatchedT().length == 2 && slMesh().canon == M2.canon,
           format("EW: the second undo did not pop the third point: latchedT %s, mesh %s "
                  ~ "(two-point cut %s)", slLatchedT(), slMesh().toString, M2.toString));
    slLine("tool.set mesh.edgeSliceTool off");
}

// ---------------------------------------------------------------------------
// SW — Slice: the frozen plane orientation is part of the image.
// ---------------------------------------------------------------------------
double[3] frozenNormal() {
    auto r = postJson("/api/command", "tool.attr mesh.sliceTool frozenNormal ?");
    assert(r["status"].str == "ok", "slice rig (SW): frozenNormal query failed: " ~ r.toString);
    auto a = r["value"].array;
    return [num(a[0]), num(a[1]), num(a[2])];
}

void setCamera(double az, double el) {
    auto r = postJson("/api/camera", format(`{"azimuth":%s,"elevation":%s}`, az, el));
    assert(r["status"].str == "ok", "slice rig (SW): camera set failed: " ~ r.toString);
}

int[2] pxOf(double x, double y, double z) {
    auto vp = viewportFromCamera(fetchCamera());
    float sx, sy;
    assert(projectToWindow(Vec3(x, y, z), vp, sx, sy), "slice rig (SW): point off screen");
    return [cast(int)round(sx), cast(int)round(sy)];
}

unittest {
    if (!cell("SW")) return;
    long Hp;
    boxRig(Hp);
    const cam0 = getJson("/api/camera");
    slKey(SL_SDLK_c, SL_KMOD_LSHIFT, "Shift+C (Slice)");
    assert(slTool() == "slice", "slice floor (SW): Shift+C did not activate Slice");
    slLine("tool.attr mesh.sliceTool infinite true");
    // Gesture 1: a Middle relocate of the default line — its plane is the
    // FROZEN drag plane (no axis lock): the cut reads the frozen normal N1.
    const m = pxOf(0, 0.1, 0);
    slPlay(slMotion(20, m[0], m[1], 0) ~ "\n" ~ slButton(40, true, 2, m[0], m[1]) ~ "\n"
         ~ slButton(60, false, 2, m[0], m[1]), "SW gesture 1 (Middle relocate)");
    const N1 = frozenNormal();
    const M1 = slMesh();
    assert(M1.faces > 4, "slice floor (SW): gesture 1 did not cut: " ~ M1.toString);
    // The orbit: another dominant plane, so the fresh line freezes N2 != N1.
    setCamera(num(cam0["azimuth"]), 1.35);
    const a = pxOf(-0.3, 0, -0.3), b = pxOf(0.3, 0, 0.3);
    slPlay(slMotion(20, a[0], a[1], 0), "SW hover");
    {
        string log = format(`{"t":30.0,"type":"SDL_KEYDOWN","sym":1073742049,"scan":0,"mod":1,"repeat":0}`) ~ "\n"
            ~ slMotion(40, a[0], a[1], 0) ~ "\n"
            ~ format(`{"t":50.0,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":1}`, a[0], a[1]) ~ "\n";
        foreach (i; 1 .. 9)
            log ~= format(`{"t":%.1f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":1,"mod":1}`,
                          50.0 + 30 * i, a[0] + (b[0] - a[0]) * i / 8, a[1] + (b[1] - a[1]) * i / 8) ~ "\n";
        log ~= format(`{"t":400.0,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":1}`, b[0], b[1]) ~ "\n"
            ~ `{"t":420.0,"type":"SDL_KEYUP","sym":1073742049,"scan":0,"mod":0,"repeat":0}`;
        slPlay(log, "SW gesture 2 (Shift+drag fresh line)");
    }
    const N2 = frozenNormal();
    const M2 = slMesh();
    assert(abs(N1[0] - N2[0]) + abs(N1[1] - N2[1]) + abs(N1[2] - N2[2]) > 0.5,
           format("slice rig (SW): the orbit did not change the frozen plane (N1 %s, N2 %s) — "
                  ~ "without it the cell cannot tell the planes apart", N1, N2));
    assert(M2.canon != M1.canon, "slice floor (SW): the fresh line did not re-cut");
    setCamera(num(cam0["azimuth"]), num(cam0["elevation"]));

    ctrlZ("SW Ctrl+Z");
    const Nz = frozenNormal();
    assert(abs(Nz[0] - N1[0]) + abs(Nz[1] - N1[1]) + abs(Nz[2] - N1[2]) <= 1e-6,
           format("SW: the undo did not restore the frozen plane: %s (N1 %s, N2 %s)", Nz, N1, N2));
    assert(slMesh().canon == M1.canon,
           format("SW: the undo did not restore the (L1, N1) cut: mesh %s, expected %s",
                  slMesh().toString, M1.toString));
    slLine("tool.set mesh.sliceTool off");
}

// ---------------------------------------------------------------------------
// Loop Slice rig (front/right faces selected; the seed is their shared edge).
// ---------------------------------------------------------------------------
struct Rail { float ax, ay, bx, by; }

Rail seedRail() {
    auto m = getJson("/api/model");
    const lo = slCornerVert(m, 0.5, false, 0.5), hi = slCornerVert(m, 0.5, true, 0.5);
    assert(lo >= 0 && hi >= 0, "slice rig: the front/right vertical edge was not found");
    auto vp = viewportFromCamera(fetchCamera());
    auto a = m["vertices"].array[lo].array, b = m["vertices"].array[hi].array;
    Rail r;
    assert(projectToWindow(Vec3(a[0].floating, a[1].floating, a[2].floating), vp, r.ax, r.ay)
           && projectToWindow(Vec3(b[0].floating, b[1].floating, b[2].floating), vp, r.bx, r.by),
           "slice rig: the seed edge projects off screen");
    return r;
}

int[2] at(const Rail r, double f) {
    return [cast(int)round(r.ax + (r.bx - r.ax) * f), cast(int)round(r.ay + (r.by - r.ay) * f)];
}

void gesture(const Rail r, double f0, double f1, string what) {
    const p = at(r, f0);
    slClickDown(p[0], p[1], what ~ " (press)");
    string log;
    if (f0 != f1)
        foreach (i; 1 .. 9) {
            const q = at(r, f0 + (f1 - f0) * i / 8.0);
            log ~= slMotion(20 + 20 * i, q[0], q[1], 1) ~ "\n";
        }
    const e = at(r, f1);
    slPlay(log ~ slButton(220, false, 1, e[0], e[1]), what ~ " (release)");
}

/// Loop Slice's `positions`; empty when the tool is gone (no such key).
double[] positions() {
    auto s = toolState();
    double[] r;
    if (!("positions" in s.object)) return r;
    foreach (p; s["positions"].array) r ~= num(p);
    return r;
}

Rail lsRig(out long Hp) {
    slPrologue(false, "polygons", &slBackAndLeft, false);
    auto m = getJson("/api/model");
    const front = slFaceOnSide(m, 2, 1.0), right = slFaceOnSide(m, 0, 1.0);
    assert(front >= 0 && right >= 0, "slice rig: front/right faces not found");
    slCmd("mesh.select", format(`{"mode":"polygons","indices":[%d,%d]}`, front, right));
    Hp = slHistoryLen();
    return seedRail();
}

// C-H1-ls — Loop Slice opens its window at the ARM (ours: the arming press,
// gap 205 (b)): the arm's cut is the first group and the drag of that same
// press is a step of its own, so the first Ctrl+Z keeps the tool at the
// arm-time loop and the second ends it with its activation row. The arming
// press WITH a drag is the discriminating cell: under `firstPress` the whole
// press would be the first group and the first Ctrl+Z would end the tool. (m3c)
unittest {
    if (!cell("C-H1-ls")) return;
    long Hp;
    const rail = lsRig(Hp);
    const base = slMesh();
    slLineUi("tool.set mesh.loopSliceTool on");
    const pa = at(rail, 0.5);
    slClickDown(pa[0], pa[1], "C-H1-ls arming press");
    const A0 = slMesh();
    const pArm = positions();
    string log;
    foreach (i; 1 .. 9) {
        const q = at(rail, 0.5 - 0.25 * i / 8.0);
        log ~= slMotion(20 + 20 * i, q[0], q[1], 1) ~ "\n";
    }
    const e = at(rail, 0.25);
    slPlay(log ~ slButton(220, false, 1, e[0], e[1]), "C-H1-ls arming drag + release");
    assert(A0.faces > base.faces && slMesh().canon != A0.canon,
           "slice floor (C-H1-ls): the arming press did not cut and drag the loop");
    ctrlZ("C-H1-ls Ctrl+Z 1");
    const p1 = positions();
    assert(slTool() == "loopSlice" && slMesh().canon == A0.canon && p1.length == 1
           && abs(p1[0] - pArm[0]) <= 1e-6,
           format("C-H1-ls: the first Ctrl+Z must pop the arming drag and keep the tool at the "
                  ~ "arm-time loop: tool '%s', positions %s (arm %s), mesh %s",
                  slTool(), p1, pArm, slMesh().toString));
    ctrlZ("C-H1-ls Ctrl+Z 2");
    assert(slTool() != "loopSlice" && slMesh().canon == base.canon && slHistoryLen() == Hp,
           format("C-H1-ls: the second Ctrl+Z did not end the tool with its activation row: "
                  ~ "tool '%s', history %s", slTool(), slHistoryLabels()));
}

// LW(a) — scrub A, scrub B, Ctrl+Z: the positions after A, then the cut at A.
unittest {
    if (!cell("LW(a)")) return;
    long Hp;
    const rail = lsRig(Hp);
    slLineUi("tool.set mesh.loopSliceTool on");
    gesture(rail, 0.5, 0.5, "LW(a) arm (motionless)");
    gesture(rail, 0.5, 0.3, "LW(a) scrub A");
    const pA = positions();
    const MA = slMesh();
    gesture(rail, 0.3, 0.7, "LW(a) scrub B");
    const MB = slMesh();
    assert(MB.canon != MA.canon,
           "slice floor (LW(a)): scrub B did not move the loop");
    ctrlZ("LW(a) Ctrl+Z");
    const pz = positions();
    assert(pz.length == pA.length && abs(pz[0] - pA[0]) <= 1e-6,
           format("LW(a): the undo did not restore the positions after A: %s (after A %s)", pz, pA));
    assert(slMesh().canon == MA.canon,
           format("LW(a): the positions came back but the cut did not: mesh %s, expected %s",
                  slMesh().toString, MA.toString));
    slLine("tool.set mesh.loopSliceTool off");
}

// LW(b) — the insert (an Action write) is its own step; count is in the image.
unittest {
    if (!cell("LW(b)")) return;
    long Hp;
    const rail = lsRig(Hp);
    slLineUi("tool.set mesh.loopSliceTool on");
    gesture(rail, 0.5, 0.5, "LW(b) arm (motionless)");
    const pArm = positions();
    gesture(rail, 0.5, 0.7, "LW(b) scrub");
    const pScrub = positions();
    const MS = slMesh();
    assert(pScrub.length == 1 && abs(pScrub[0] - pArm[0]) > 1e-3,
           format("slice floor (LW(b)): the scrub did not move the loop: %s -> %s", pArm, pScrub));
    slLine("tool.attr mesh.loopSliceTool insertAt 0.3");
    assert(toolState()["count"].integer == 2,
           format("slice floor (LW(b)): insertAt did not add a slice: count %s", toolState()["count"]));
    ctrlZ("LW(b) Ctrl+Z 1");
    const p1 = positions();
    assert(toolState()["count"].integer == 1 && p1.length == 1 && abs(p1[0] - pScrub[0]) <= 1e-6,
           format("LW(b): the first Ctrl+Z must undo the insert alone (C-H2-ls-insert P1: count 1 "
                  ~ "at the scrubbed position): count %s, positions %s (scrubbed %s)",
                  toolState()["count"], p1, pScrub));
    assert(slMesh().canon == MS.canon,
           format("LW(b): the insert's undo did not restore the scrubbed cut: mesh %s", slMesh().toString));
    ctrlZ("LW(b) Ctrl+Z 2");
    const p2 = positions();
    assert(slTool() == "loopSlice" && toolState()["armed"].type == JSONType.true_
           && p2.length == 1 && abs(p2[0] - pArm[0]) <= 1e-6,
           format("LW(b): the second Ctrl+Z must pop the scrub and keep the tool armed: tool '%s', "
                  ~ "positions %s (arm-time %s)", slTool(), p2, pArm));
    slLine("tool.set mesh.loopSliceTool off");
}

// ---------------------------------------------------------------------------
// S7 — a raw `history.undo` between two navigate redos: the first group is
// replayed by the redo that follows its own undo, never again.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("S7")) return;
    long Hp;
    const base = boxRig(Hp);
    slLineUi("tool.set mesh.edgeSliceTool on");
    latch(slFrontRightChain(), 0, "S7");
    ctrlZ("S7 Ctrl+Z");
    assert(slTool() != "edgeSlice" && slHistoryLen() == Hp, "slice floor (S7): the session did not end");
    ctrlShiftZ("S7 Ctrl+Shift+Z 1");
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 1,
           format("slice floor (S7): the navigate redo did not re-arm WITH the first point: "
                  ~ "tool '%s', points %d", slTool(), slChain().pairs.length));
    slLine("history.undo");
    assert(slTool() != "edgeSlice" && slHistoryLen() == Hp && slMesh().canon == base.canon,
           format("slice floor (S7): the raw undo did not pop the activation: tool '%s', history %s",
                  slTool(), slHistoryLabels()));
    ctrlShiftZ("S7 Ctrl+Shift+Z 2");
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 0,
           format("S7: the second navigate redo replayed the first point again (it must re-arm "
                  ~ "bare): tool '%s', points %d", slTool(), slChain().pairs.length));
    slLine("tool.set mesh.edgeSliceTool off");
}

// ---------------------------------------------------------------------------
// doApply-es — `tool.doApply` on a tool whose policy does NOT say the headless
// apply replaces its window (slice M3b review R1): Edge Slice keeps today's
// door. (a) A REFUSED apply (one point: fewer than two edges) changes nothing
// — the live chain, the mesh and the rows stand; (b) an accepted one's undo
// returns the mesh as it stood, live chain and all (the status quo; a door
// that ended the window first would return the base instead).
// ---------------------------------------------------------------------------
unittest {
    if (!cell("doApply-es")) return;
    long Hp;
    const base = boxRig(Hp);
    slLineUi("tool.set mesh.edgeSliceTool on");
    latch(slFrontRightChain(), 0, "doApply-es");
    const m1 = slMesh();
    const L1 = slHistoryLabels();
    auto r = slPost("/api/command", "tool.doApply");
    assert(r["status"].str == "error",
           "doApply-es floor: one point must refuse the headless apply: " ~ r.toString);
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 1 && slMesh().canon == m1.canon
           && slHistoryLabels() == L1,
           format("doApply-es (a): a refused tool.doApply changed something: tool '%s', points %d, "
                  ~ "mesh %s (before %s), rows %s (before %s)", slTool(), slChain().pairs.length,
                  slMesh().toString, m1.toString, slHistoryLabels(), L1));
    latch(slFrontRightChain(), 1, "doApply-es");
    const m2 = slMesh();
    assert(m2.canon != base.canon, "doApply-es floor: two points cut nothing");
    slLine("tool.doApply");
    slLine("history.undo");
    assert(slMesh().canon == m2.canon,
           format("doApply-es (b): the undo of an accepted tool.doApply must return the mesh as it "
                  ~ "stood (live chain included), not the window's base: mesh %s (stood %s, base %s)",
                  slMesh().toString, m2.toString, base.toString));
    slLine("tool.set mesh.edgeSliceTool off");
}
