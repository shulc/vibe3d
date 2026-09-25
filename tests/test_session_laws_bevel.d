// Polygon Bevel on the tool session model (slice M3b,
// doc/tool_session_model_plan_2026-09-24.md R2.5 M3b, R3.2 haul table; captures
// in toolcards/tool_session_model: M0 C-H1-bev, C-H2-bev, C-H3-bev,
// C-H5-bev-mmb, C-H5-bev-shift, C-H6-bev; M0d C-K-tab / C-K-del).
//
//   C-H1-bev   the arm APPLIES the bevel (a zero-width ring: +4 vertices on one
//              quad); a haul is a step of that operation; Ctrl+Z pops the haul
//              (tool alive, 0/0, the ring stays); Ctrl+Z again pops the arm's
//              group with its activation row (UI door): tool off, mesh back.
//                                                   (opensAt=firstPress, m3b-a)
//   C-H2-bev   two plain hauls are two steps of ONE operation (no new ring);
//              Ctrl+Z restores the first haul's values and geometry.
//   C-H5-mmb   a motionless Middle tap after a haul opens a NEW operation that
//              clones the haul (+4 more vertices at the tap); Ctrl+Z pops the
//              whole new operation and restores the clone's start (283).
//                                                   (noClone=true, m3b-b)
//   C-H5-shift a Shift haul after a haul opens a NEW operation reset to 0 (the
//              same drag gives the same values, not twice them); Ctrl+Z pops it
//              and restores its start, 0/0, over the first operation.
//                                                   (Shift without reset, m3b-c)
//   C-K-tab    an idle armed Bevel under a UI-door command: the window closes
//              (the arm's ring is committed, one row), the tool keeps its tag
//              with no window; the next press opens one.
//   C-H3-bev   a hauled Bevel under a UI-door `select.invert`: one row, the tool
//              stays with no window and KEEPS its values (k_sel 0.04).
//
// Every gesture is real SDL input through /api/play-events; Ctrl+Z is a
// keystroke (the navigate chokepoint). Rig: the default cube, face 0 selected,
// polygon mode. Each cell asserts BEHAVIOUR (tool, attributes, mesh, rows), so
// it reads the same on a binary before this slice: red there where the law
// changed. `VIBE3D_CELL=<id>` runs one cell alone.

import slice_leak_helpers : slPlay, slMotion, slKey, slLine, slLineUi, slHistoryLabels,
    slHistoryLen, slMesh, SlMesh, slCmd, SL_SDLK_z, SL_KMOD_LCTRL, SL_KMOD_LSHIFT;
import http_client : getJson;
import drag_helpers : fetchCamera;
import std.format : format;
import std.json;
import std.math : abs;
import std.process : environment;

void main() {}

bool cell(string id) {
    const only = environment.get("VIBE3D_CELL", "");
    return only.length == 0 || only == id;
}

void ctrlZ(string what) { slKey(SL_SDLK_z, SL_KMOD_LCTRL, what); }

JSONValue st() { return getJson("/api/tool/state"); }
string tool() {
    auto s = st();
    return (s.type == JSONType.object && "tool" in s.object) ? s["tool"].str : "";
}
double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double) v.integer
         : v.type == JSONType.uinteger ? cast(double) v.uinteger : v.floating;
}
double shiftV() { return num(st()["shift"]); }
double insetV() { return num(st()["inset"]); }
bool applied() { return st()["applied"].type == JSONType.true_; }
long opIx() { return st()["op"].integer; }
bool near(double a, double b) { return abs(a - b) < 1e-4; }

string btnEv(double t, bool down, int btn, int x, int y, int mod) {
    return format(`{"t":%.1f,"type":"%s","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":%d}`,
                  t, down ? "SDL_MOUSEBUTTONDOWN" : "SDL_MOUSEBUTTONUP", btn, x, y, mod);
}
string motEv(double t, int x, int y, int state, int mod) {
    return format(`{"t":%.1f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":%d,"mod":%d}`,
                  t, x, y, state, mod);
}

/// A free haul off the handles (vertical -> shift, horizontal -> inset):
/// press, three held motions to (dx, dy), release. `btn` 1 or 2.
void haul(int dx, int dy, string what, int btn = 1, int mod = 0) {
    auto c = fetchCamera();
    const x = c.vpX + 70, y = c.vpY + c.height - 70;   // a corner: no handle there
    const state = btn == 1 ? 1 : 2;
    string log = motEv(20, x, y, 0, mod) ~ "\n" ~ btnEv(40, true, btn, x, y, mod) ~ "\n";
    foreach (i; 1 .. 4)
        log ~= motEv(40 + 30 * i, x + dx * i / 3, y + dy * i / 3, state, mod) ~ "\n";
    log ~= btnEv(200, false, btn, x + dx, y + dy, mod);
    slPlay(log, what);
}

/// A motionless tap (press + release at one pixel).
void tap(int btn, string what) {
    auto c = fetchCamera();
    const x = c.vpX + 70, y = c.vpY + c.height - 70;
    slPlay(motEv(20, x, y, 0, 0) ~ "\n" ~ btnEv(40, true, btn, x, y, 0) ~ "\n"
         ~ btnEv(80, false, btn, x, y, 0), what);
}

/// The default cube, face 0 selected, polygon mode, empty history.
SlMesh rig(string tag) {
    slCmd("scene.reset", `{"type":"cube"}`);
    slCmd("mesh.select", `{"mode":"polygons","indices":[0]}`);
    slLine("history.clear");
    const base = slMesh();
    assert(base.verts == 8 && base.faces == 6 && slHistoryLen() == 0,
           format("bevel floor (%s): the rig is not the cube on an empty history: %s, rows %s",
                  tag, base.toString, slHistoryLabels()));
    return base;
}

/// Arm through the UI door (the typed command line = the key door, C-H1-door).
void armUi(string tag) {
    slLineUi("tool.set poly.bevel on");
    assert(tool() == "polyBevel", format("bevel floor (%s): the UI arm did not arm: '%s'",
                                         tag, tool()));
}

// ---------------------------------------------------------------------------
// C-H1-bev — the arm applies; its group takes the activation row with it.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("C-H1-bev")) return;
    const base = rig("C-H1-bev");
    armUi("C-H1-bev");
    const a0 = slMesh();
    assert(applied() && a0.verts == 12 && a0.faces == 10 && slHistoryLen() == 1,
           format("C-H1-bev: the arm must apply a zero-width ring (a0 nv 12): applied %s, mesh %s, "
                  ~ "rows %s", applied(), a0.toString, slHistoryLabels()));
    haul(0, -40, "C-H1-bev h1");
    const g1 = slMesh();
    assert(shiftV() > 0.01 && g1.verts == 12 && g1.canon != a0.canon,
           format("bevel floor (C-H1-bev): the haul did not move the arm's ring: shift %s, mesh %s",
                  shiftV(), g1.toString));
    ctrlZ("C-H1-bev Ctrl+Z 1");
    assert(tool() == "polyBevel" && applied() && near(shiftV(), 0) && near(insetV(), 0)
           && slMesh().canon == a0.canon,
           format("C-H1-bev z1: the first Ctrl+Z must pop the haul only (tool on, 0/0, the ring "
                  ~ "stays): tool '%s', applied %s, shift %s, mesh %s",
                  tool(), applied(), shiftV(), slMesh().toString));
    ctrlZ("C-H1-bev Ctrl+Z 2");
    assert(tool() == "" && slHistoryLen() == 0 && slMesh().canon == base.canon,
           format("C-H1-bev z2: the second Ctrl+Z must pop the arm with its row: tool '%s', rows %s, "
                  ~ "mesh %s", tool(), slHistoryLabels(), slMesh().toString));
}

// ---------------------------------------------------------------------------
// C-H2-bev — a plain haul is a step of the live operation.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("C-H2-bev")) return;
    rig("C-H2-bev");
    armUi("C-H2-bev");
    haul(0, -40, "C-H2-bev h1");
    const s1 = shiftV();
    const g1 = slMesh();
    haul(0, -10, "C-H2-bev h2");
    assert(shiftV() > s1 + 1e-3 && slMesh().verts == 12 && opIx() == 0,
           format("C-H2-bev: the second plain haul must continue the SAME operation: shift %s "
                  ~ "(after h1 %s), mesh %s, op %s", shiftV(), s1, slMesh().toString, opIx()));
    ctrlZ("C-H2-bev Ctrl+Z");
    assert(tool() == "polyBevel" && near(shiftV(), s1) && slMesh().canon == g1.canon,
           format("C-H2-bev z1: Ctrl+Z must restore the first haul: tool '%s', shift %s (h1 %s), "
                  ~ "mesh %s (h1 %s)", tool(), shiftV(), s1, slMesh().toString, g1.toString));
    slLine("tool.set poly.bevel off");
}

// ---------------------------------------------------------------------------
// C-H5-bev-mmb — Middle clones the haul into a new operation, applied at once.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("C-H5-mmb")) return;
    rig("C-H5-mmb");
    armUi("C-H5-mmb");
    haul(0, -40, "C-H5-mmb h1");
    const s1 = shiftV(), i1 = insetV();
    const g1 = slMesh();
    tap(2, "C-H5-mmb tap");
    assert(slMesh().verts == 16 && opIx() == 1 && applied() && near(shiftV(), s1),
           format("C-H5-bev-mmb: a Middle tap must apply a CLONED second operation (nv 12 -> 16, "
                  ~ "shift kept): mesh %s, op %s, applied %s, shift %s (h1 %s)",
                  slMesh().toString, opIx(), applied(), shiftV(), s1));
    ctrlZ("C-H5-mmb Ctrl+Z");
    assert(tool() == "polyBevel" && slMesh().canon == g1.canon && near(shiftV(), s1)
           && near(insetV(), i1),
           format("C-H5-bev-mmb z1: Ctrl+Z must pop the whole clone and keep its start: tool '%s', "
                  ~ "mesh %s (h1 %s), shift %s (clone start %s)",
                  tool(), slMesh().toString, g1.toString, shiftV(), s1));
    slLine("tool.set poly.bevel off");
}

// ---------------------------------------------------------------------------
// C-H5-bev-shift — Shift resets: a new operation from 0.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("C-H5-shift")) return;
    rig("C-H5-shift");
    armUi("C-H5-shift");
    haul(0, -40, "C-H5-shift h1");
    const s1 = shiftV();
    const g1 = slMesh();
    haul(0, -40, "C-H5-shift hs", 1, SL_KMOD_LSHIFT);
    // The same drag from 0 gives about the same value (0.04 in the capture, not
    // 0.08); not exactly, as the new operation's handle sits nearer the eye.
    assert(slMesh().verts == 16 && opIx() == 1 && shiftV() > 0.5 * s1 && shiftV() < 1.5 * s1,
           format("C-H5-bev-shift: a Shift haul must open a new operation reset to 0 (nv 16, the "
                  ~ "same drag gives about %s, not twice it): mesh %s, op %s, shift %s",
                  s1, slMesh().toString, opIx(), shiftV()));
    ctrlZ("C-H5-shift Ctrl+Z");
    assert(tool() == "polyBevel" && slMesh().canon == g1.canon && near(shiftV(), 0)
           && near(insetV(), 0),
           format("C-H5-bev-shift z1: Ctrl+Z must pop the Shift operation to its start (0/0) over "
                  ~ "the first one: tool '%s', mesh %s (h1 %s), shift %s, inset %s",
                  tool(), slMesh().toString, g1.toString, shiftV(), insetV()));
    slLine("tool.set poly.bevel off");
}

// ---------------------------------------------------------------------------
// C-K-tab — an idle armed Bevel under a UI-door command.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("C-K-tab")) return;
    rig("C-K-tab");
    armUi("C-K-tab");
    slLineUi("mesh.subpatch_toggle");
    const k = slMesh();
    assert(tool() == "polyBevel" && !applied() && k.verts == 12
           && slHistoryLabels().length == 3,
           format("C-K-tab: the command must close the idle window keeping its ring (one row) and "
                  ~ "leave the tag with no window: tool '%s', applied %s, mesh %s, rows %s",
                  tool(), applied(), k.toString, slHistoryLabels()));
    haul(0, -40, "C-K-tab liveness");
    assert(applied() && slMesh().verts == 16,
           format("C-K-tab: the next press must open a window and apply (nv 12 -> 16): applied %s, "
                  ~ "mesh %s", applied(), slMesh().toString));
    slLine("tool.set poly.bevel off");
}

// ---------------------------------------------------------------------------
// C-H3-bev — a hauled Bevel under a UI-door selection command.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("C-H3-bev")) return;
    rig("C-H3-bev");
    armUi("C-H3-bev");
    haul(0, -40, "C-H3-bev h1");
    const s1 = shiftV();
    const g1 = slMesh();
    slLineUi("select.invert");
    assert(tool() == "polyBevel" && !applied() && near(shiftV(), s1) && slMesh().verts == g1.verts,
           format("C-H3-bev: the command must close the window and keep the tag and its values "
                  ~ "(k_sel 0.04): tool '%s', applied %s, shift %s (h1 %s), mesh %s",
                  tool(), applied(), shiftV(), s1, slMesh().toString));
    slLine("tool.set poly.bevel off");
}
