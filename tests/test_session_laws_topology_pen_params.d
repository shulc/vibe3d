// Topology pen session laws, slice S7a (wave plan 8640 §9.7 and its
// amendments A2-A15): the operation context (Offset X/Y/Z and the step
// descriptor) and the parameter-row fold. Same rig as
// tests/test_session_laws_topology_pen.d (tests/topology_pen_session_helpers.d);
// the laws are the capture's (session_capture fixtures c0..c4), every number
// below is OUR run's, compared within the run.
//
//   offsets-live / -edge / -loop  L18  a Move-family drag writes the Offset live:
//                                      the pressed element's anchor travel
//   descriptor-kinds              S7a  the press end writes its kind; an undo
//                                      shows the open image's (none)
//   descriptor-not-writable       S7a  no write door reaches the descriptor
//   offsets-reset-per-press       H1-move z1  a press resets the context
//   offset-before-press           H3f, A7  pre-press writes are rows of their own
//   offset-after-undo             N1   a write after an undone press is a row
//   redo-in-session               N2   an in-instance redo restores the AFTER offsets
//   redo-after-rearm              L2   a re-armed instance reads offsets 0
//   switch-back-offsets           X-w  a lifecycle re-arm reads offsets 0
//   rearm-typed-offsets           X-toggle  a re-typed arm reads offsets 0
//   absorb-*                      L15, C1-F1/F2/F3  pre-press rows fold into the
//                                      activation; a script-door arm opens nothing
//   mode-steps                    K-modes-b
//   param-redo-*                  L2p/L2s/L44/L53  the unclosed row redoes only in
//                                      its instance; a closed one anywhere
//   descriptor-after-redo-rearm   L2q
//   fold-*                        L38/L41/L42/L43/L45/L55  the fold at a press,
//                                      a switch, a re-typed arm; group redo
//   pop-one-open-rows             L54  undo pops one open row at a time
//   switch-closed-redo            C4-switch-closed (L53 Closed)
//   rearm-redo-opens-nothing      ours: a re-arming redo opens no block
//   fold-on-drop                  gap t: a drop folds by the switch rule
//   fold-not-on-command           §9.19.3: a command close is no fold trigger
//   discard-resets-offsets        a discarded gesture restores its context
//
// `VIBE3D_CELL=<id>` runs one cell alone; the last block pins the population.
//
// Run via: ./run_test.d test_session_laws_topology_pen_params

import topology_pen_session_helpers;
import http_client : getJson;
import std.algorithm : canFind;
import std.array : join;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs, sqrt;
import std.path : buildPath, dirName;
import std.process : environment;
import std.stdio : writeln;

void main() {}

__gshared int cellsRun;

bool cell(string id) {
    const only = environment.get("VIBE3D_CELL", "");
    const on = only.length == 0 || only == id;
    if (on) ++cellsRun;
    return on;
}

PenRig rig() {
    return penRigLoad(buildPath(dirName(__FILE_FULL_PATH__), "fixtures",
                                "topology_pen_session_rig.v3d"));
}

// The capture rig's three Move gestures, in grid spacings (66.8 px spacing).
enum double kSp = 66.8;
void moveV5(string what)  { penGesture(penVertexPx(5, what), 20 / kSp, 12 / kSp, 1, 0, what); }
void moveV10(string what) { penGesture(penVertexPx(10, what), -18 / kSp, 10 / kSp, 1, 0, what); }
void moveV6(string what)  { penGesture(penVertexPx(6, what), 16 / kSp, -14 / kSp, 1, 0, what); }

enum PEN_SDLK_ESCAPE = 27;

void z(string what)  { penCtrlZ(what); }
void sz(string what) { penCtrlShiftZ(what); }

/// An interactive (panel-origin) attribute write on the armed pen.
void w(string attr, string value) {
    auto r = penPost("/api/script?interactive=true",
                     "tool.attr " ~ kPenToolId ~ " " ~ attr ~ " " ~ value);
    assert(r["status"].str == "ok", "interactive write " ~ attr ~ " " ~ value ~ " failed: "
                                    ~ r.toString);
}

JSONValue attrOf(string tool, string attr) {
    auto r = penPost("/api/command", "tool.attr " ~ tool ~ " " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "attribute query " ~ attr ~ " failed: " ~ r.toString);
    return r["value"];
}

double num(JSONValue v) {
    import std.conv : to;
    return v.type == JSONType.string ? v.str.to!double : penNum(v);
}

string attrStr(string attr) { return attrOf(kPenToolId, attr).toString; }
double attrNum(string attr) { return num(attrOf(kPenToolId, attr)); }

/// The written 0.1 as it reads back (stored as a float).
bool is01(double v) { return abs(v - 0.1) < 1e-6; }

double[3] offs() { return [attrNum("offsetX"), attrNum("offsetY"), attrNum("offsetZ")]; }
bool isZero(double[3] o) { return o[0] == 0 && o[1] == 0 && o[2] == 0; }
double len3(double[3] o) { return sqrt(o[0] * o[0] + o[1] * o[1] + o[2] * o[2]); }
string fmt3(double[3] o) { return format("(%.7g, %.7g, %.7g)", o[0], o[1], o[2]); }

long redoLen() { return cast(long)getJson("/api/history")["redo"].array.length; }

/// The step descriptor's content (`/api/tool/state`): the attributes are
/// session state no write door reaches, so `tool.attr ?` reports their length.
long stepKindNow() { return getJson("/api/tool/state")["stepKind"].integer; }
string stepVertsNow() { return getJson("/api/tool/state")["stepVerts"].toString; }

/// armed / mesh / undo length at one step.
void at(string id, string step, const PenMesh want, bool armed, long hist) {
    const m = penMesh();
    assert(m == want && penArmed() == armed && penHistoryLen() == hist,
           format("%s %s: mesh %s the expected %s, armed %s (expected %s), history %d (expected %d) %s",
                  id, step, m == want ? "==" : "!=", want.toString, penArmed(), armed,
                  penHistoryLen(), hist, penHistoryLabels()));
}

void offsAre(string id, string step, double[3] want) {
    const o = offs();
    assert(o == want, format("%s %s: offsets %s, expected %s", id, step, fmt3(o), fmt3(want)));
}

double[3] delta(const PenMesh a, const PenMesh b, long v) {
    const i = cast(size_t)v;
    return [a.pos[i][0] - b.pos[i][0], a.pos[i][1] - b.pos[i][1], a.pos[i][2] - b.pos[i][2]];
}

double[3] mean2(double[3] a, double[3] b) {
    return [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2];
}

bool near3(double[3] a, double[3] b, double tol) {
    return abs(a[0] - b[0]) <= tol && abs(a[1] - b[1]) <= tol && abs(a[2] - b[2]) <= tol;
}

/// A second empty-background pixel (the near side of the background sphere).
int[2] emptyPx2() { return penRound(penProject([0.25, -0.55, sqrt(1.0 - 0.0625 - 0.3025)])); }

// ===========================================================================
// The operation context: written live by the Move family (L18, ours).
// ===========================================================================

// offsets-live — a vertex Move drag reports its Offset WHILE held (read between
// motion and release) and after the release: the vertex's travel since the press.
unittest {
    if (!cell("offsets-live")) return;
    const r = rig();
    penArmUi(r);
    const from = penVertexPx(5, "offsets-live v5");
    const sp = penSpacingPx() / kSp;
    string log = penMotion(20, from[0], from[1], 0, 0) ~ "\n"
               ~ penButton(40, true, 1, from[0], from[1], 0) ~ "\n";
    int x = from[0], y = from[1];
    foreach (i; 1 .. 7) {
        x = from[0] + cast(int)(20 * sp * i / 6);
        y = from[1] + cast(int)(12 * sp * i / 6);
        log ~= penMotion(40 + 40 * i, x, y, 1, 0) ~ "\n";
    }
    penPlay(log, "offsets-live: held drag on v5");
    const held = penMesh();
    const oHeld = offs();
    assert(penMoved(held, r.a0) == [5L] && len3(oHeld) > 1e-3,
           format("offsets-live held: moved %s, offsets %s (a held drag must report its offset)",
                  penIdx(penMoved(held, r.a0)), fmt3(oHeld)));
    assert(near3(oHeld, delta(held, r.a0, 5), 1e-6),
           format("offsets-live held: offsets %s, the vertex travelled %s", fmt3(oHeld),
                  fmt3(delta(held, r.a0, 5))));
    // The release lands 6 px past the last motion: its own pixel decides.
    penPlay(penButton(20, false, 1, x + 6, y + 4, 0), "offsets-live release");
    const g1 = penMesh();
    const o = offs();
    assert(g1 != held, "offsets-live rig: the release pixel did not move the vertex further");
    assert(penHistoryLen() == r.hp + 2 && len3(o) > 1e-3 && near3(o, delta(g1, r.a0, 5), 1e-6),
           format("offsets-live g1: offsets %s, the vertex travelled %s, history %s", fmt3(o),
                  fmt3(delta(g1, r.a0, 5)), penHistoryLabels()));
    writeln("PASS offsets-live");
}

// offsets-live-edge — an EDGE Move reports its midpoint's travel: the mean of
// its two endpoints' deltas, which differ (each re-snaps on its own).
unittest {
    if (!cell("offsets-live-edge")) return;
    const r = rig();
    penArmUi(r);
    penGesture(penEdgePx(5, 6, "offsets-live-edge e56"), 20 / kSp, 12 / kSp, 1, 0,
               "offsets-live-edge drag");
    const g1 = penMesh();
    const d5 = delta(g1, r.a0, 5), d6 = delta(g1, r.a0, 6);
    assert(penMoved(g1, r.a0) == [5L, 6L] && !near3(d5, d6, 1e-5),
           format("offsets-live-edge rig: moved %s, deltas %s / %s (must differ)",
                  penIdx(penMoved(g1, r.a0)), fmt3(d5), fmt3(d6)));
    const o = offs();
    assert(near3(o, mean2(d5, d6), 1e-6),
           format("offsets-live-edge: offsets %s, the midpoint travelled %s (v5 alone %s)",
                  fmt3(o), fmt3(mean2(d5, d6)), fmt3(d5)));
    writeln("PASS offsets-live-edge");
}

// offsets-live-loop — a Move Loop (RMB on e56) reports the PRESSED edge's
// midpoint travel, not a loop-wide mean: while held (the targets the release
// would commit) and at the release's own pixel.
unittest {
    if (!cell("offsets-live-loop")) return;
    const r = rig();
    penArmUi(r);
    const from = penEdgePx(5, 6, "offsets-live-loop e56");
    const sp = penSpacingPx() / kSp;
    string log = penMotion(20, from[0], from[1], 0, 0) ~ "\n"
               ~ penButton(40, true, 3, from[0], from[1], 0) ~ "\n";
    int x = from[0], y = from[1];
    foreach (i; 1 .. 7) {
        y = from[1] - cast(int)(15 * sp * i / 6);
        log ~= penMotion(40 + 40 * i, x, y, penButtonMask(3), 0) ~ "\n";
    }
    penPlay(log, "offsets-live-loop: held loop drag");
    const oHeld = offs();
    assert(penMesh() == r.a0 && len3(oHeld) > 1e-3,
           format("offsets-live-loop held: the deferred loop must not move yet (moved %s) and must "
                  ~ "report its offset %s", penIdx(penMoved(penMesh(), r.a0)), fmt3(oHeld)));
    penPlay(penButton(20, false, 3, x, y - 6, 0), "offsets-live-loop release");
    const g1 = penMesh();
    const moved = penMoved(g1, r.a0);
    assert(moved.length > 2 && moved.canFind(5L) && moved.canFind(6L),
           format("offsets-live-loop rig: the loop moved %s", penIdx(moved)));
    const want = mean2(delta(g1, r.a0, 5), delta(g1, r.a0, 6));
    const o = offs();
    assert(len3(o) > 1e-3 && near3(o, want, 1e-6) && !near3(o, oHeld, 1e-6),
           format("offsets-live-loop: offsets %s, the pressed edge's midpoint travelled %s (held %s)",
                  fmt3(o), fmt3(want), fmt3(oHeld)));
    writeln("PASS offsets-live-loop");
}

// descriptor-kinds — the press end writes the descriptor: a vertex Move is
// kind 1 over {5}, an edge Move kind 2 over {5, 6}, a Move Loop kind 4; the
// undo of a press shows its OPEN image (kind 0, N-none), an in-instance redo
// the after image.
unittest {
    if (!cell("descriptor-kinds")) return;
    const r = rig();
    penArmUi(r);
    assert(stepKindNow() == 0, "descriptor-kinds a0: kind " ~ stepKindNow().to!string);
    moveV5("descriptor-kinds g1");
    assert(stepKindNow() == 1 && stepVertsNow() == "[5]",
           format("descriptor-kinds g1: kind %s verts %s", stepKindNow().to!string, stepVertsNow()));
    penGesture(penEdgePx(9, 10, "descriptor-kinds e9-10"), 10 / kSp, 14 / kSp, 1, 0,
               "descriptor-kinds g2");
    assert(stepKindNow() == 2 && ["[9,10]", "[10,9]"].canFind(stepVertsNow()),
           format("descriptor-kinds g2: kind %s verts %s", stepKindNow().to!string, stepVertsNow()));
    z("descriptor-kinds z1");
    assert(stepKindNow() == 0 && stepVertsNow() == "[]",
           format("descriptor-kinds z1: kind %s verts %s (the open image)", stepKindNow().to!string,
                  stepVertsNow()));
    sz("descriptor-kinds r1");
    assert(stepKindNow() == 2,
           format("descriptor-kinds r1: kind %s (the after image)", stepKindNow().to!string));
    penGesture(penEdgePx(5, 6, "descriptor-kinds loop e56"), 0, -15 / kSp, 3, 0,
               "descriptor-kinds g3");
    assert(stepKindNow() == 4,
           format("descriptor-kinds g3: kind %s (Move Loop)", stepKindNow().to!string));
    // A vertex Move released on another vertex WELDS into it: the grabbed vertex
    // is gone, so the moved set is empty (its kind stays a vertex move).
    const before = penMesh();
    const from = penVertexPx(0, "descriptor-kinds weld v0");
    const onto = penVertexPx(1, "descriptor-kinds weld v1");
    penPlay(penGestureEvents(from[0], from[1], onto[0], onto[1], 1, 0, 8), "descriptor-kinds weld");
    assert(penMesh().nv == before.nv - 1,
           format("descriptor-kinds weld rig: v0 dropped on v1 did not weld: %s -> %s",
                  before.toString, penMesh().toString));
    assert(stepKindNow() == 1 && stepVertsNow() == "[]",
           format("descriptor-kinds weld: kind %s verts %s", stepKindNow().to!string, stepVertsNow()));
    writeln("PASS descriptor-kinds");
}

// descriptor-not-writable — the descriptor is session state, not a wire
// route: a write of `stepKind` / `stepVerts` / `stepOrig` is refused at the
// script door AND the interactive (panel) door, leaves the descriptor as the
// press wrote it and writes no row. The Offset beside it stays writable (the
// control: the same door accepts it and writes its row).
unittest {
    if (!cell("descriptor-not-writable")) return;
    const r = rig();
    penArmUi(r);
    moveV5("descriptor-not-writable g1");
    const g1 = penMesh();
    assert(stepKindNow() == 1 && stepVertsNow() == "[5]",
           format("descriptor-not-writable rig: kind %s verts %s", stepKindNow(), stepVertsNow()));
    const hist = penHistoryLen(), redo = redoLen();
    size_t refused;
    void refuse(string door, string attr, string value, JSONValue resp) {
        assert(resp["status"].str != "ok",
               format("descriptor-not-writable: the %s door accepted %s %s: %s", door, attr, value,
                      resp.toString));
        assert(stepKindNow() == 1 && stepVertsNow() == "[5]" && penHistoryLen() == hist
               && redoLen() == redo && penMesh() == g1,
               format("descriptor-not-writable: after the %s door's %s %s: kind %s verts %s, "
                      ~ "history %s (expected %s) %s", door, attr, value, stepKindNow(),
                      stepVertsNow(), penHistoryLen(), hist, penHistoryLabels()));
        ++refused;
    }
    foreach (av; [["stepKind", "42"], ["stepVerts", "7"], ["stepOrig", "3"]]) {
        const line = "tool.attr " ~ kPenToolId ~ " " ~ av[0] ~ " " ~ av[1];
        refuse("script", av[0], av[1], penPost("/api/command", line));
        refuse("interactive", av[0], av[1], penPost("/api/script?interactive=true", line));
    }
    // The array spelling, which the argstring cannot carry, by the JSON body.
    refuse("script (JSON)", "stepVerts", "[1, 2]", penPost("/api/command",
        `{"id":"tool.attr","params":{"tool":"` ~ kPenToolId ~ `","attr":"stepVerts","value":[1,2]}}`));
    assert(refused == 7, format("descriptor-not-writable: %s refusals checked, expected 7", refused));
    w("offsetX", "0.1");
    assert(is01(attrNum("offsetX")) && penHistoryLen() == hist + 1,
           format("descriptor-not-writable control: offsetX %s, history %s (expected %s)",
                  attrNum("offsetX"), penHistoryLen(), hist + 1));
    writeln("PASS descriptor-not-writable");
}

// ===========================================================================
// A press opens the operation; M-H keeps the context to its instance.
// ===========================================================================

// offsets-reset-per-press — H1-move z1: g1 leaves non-zero offsets, g2 on v10
// resets them at ITS press, so undoing g2 shows zeros (not g1's).
unittest {
    if (!cell("offsets-reset-per-press")) return;
    const r = rig();
    penArmUi(r);
    moveV5("offsets-reset-per-press g1");
    const g1 = penMesh();
    const o1 = offs();
    assert(len3(o1) > 1e-3, "offsets-reset-per-press g1: offsets " ~ fmt3(o1));
    moveV10("offsets-reset-per-press g2");
    assert(len3(offs()) > 1e-3 && offs() != o1,
           "offsets-reset-per-press g2: offsets " ~ fmt3(offs()));
    z("offsets-reset-per-press z1");
    at("offsets-reset-per-press", "z1", g1, true, r.hp + 2);
    offsAre("offsets-reset-per-press", "z1 (g2's open image)", [0, 0, 0]);
    writeln("PASS offsets-reset-per-press");
}

// offset-before-press — H3f, A7: before any press an Offset write and a Mode
// write are each a row; the undo walks back through both, then the arm.
unittest {
    if (!cell("offset-before-press")) return;
    const r = rig();
    penArmUi(r);
    w("offsetX", "0.1");
    at("offset-before-press", "w1", r.a0, true, r.hp + 2);
    assert(is01(attrNum("offsetX")),
           "offset-before-press w1: offsetX " ~ attrStr("offsetX"));
    w("mode", "point");
    at("offset-before-press", "w2", r.a0, true, r.hp + 3);
    z("offset-before-press z1");
    at("offset-before-press", "z1", r.a0, true, r.hp + 2);
    assert(attrStr("mode") == `"move"` && is01(attrNum("offsetX")),
           format("offset-before-press z1: mode %s offsetX %s", attrStr("mode"), attrStr("offsetX")));
    z("offset-before-press z2");
    at("offset-before-press", "z2", r.a0, true, r.hp + 1);
    offsAre("offset-before-press", "z2", [0, 0, 0]);
    z("offset-before-press z3");
    at("offset-before-press", "z3", r.a0, false, r.hp);
    writeln("PASS offset-before-press");
}

// offset-after-undo — N1 (the row half): g1, g2, Ctrl+Z, then an Offset write
// is a row of its own and changes no geometry (S7a re-applies nothing).
unittest {
    if (!cell("offset-after-undo")) return;
    const r = rig();
    penArmUi(r);
    moveV5("offset-after-undo g1");
    const g1 = penMesh();
    moveV10("offset-after-undo g2");
    z("offset-after-undo z1");
    at("offset-after-undo", "z1", g1, true, r.hp + 2);
    w("offsetX", "0.1");
    at("offset-after-undo", "w1", g1, true, r.hp + 3);
    writeln("PASS offset-after-undo");
}

// redo-in-session — N2: g1, Ctrl+Z, Ctrl+Shift+Z in the SAME instance restores
// g1's after offsets, bit-equal. (Above redo-after-rearm: one run shows this
// half green and that one's red line under the M-H mutations.)
unittest {
    if (!cell("redo-in-session")) return;
    const r = rig();
    penArmUi(r);
    moveV5("redo-in-session g1");
    const g1 = penMesh();
    const o1 = offs();
    assert(len3(o1) > 1e-3, "redo-in-session g1: offsets " ~ fmt3(o1));
    z("redo-in-session z1");
    at("redo-in-session", "z1", r.a0, true, r.hp + 1);
    offsAre("redo-in-session", "z1", [0, 0, 0]);
    sz("redo-in-session r1");
    at("redo-in-session", "r1", g1, true, r.hp + 2);
    offsAre("redo-in-session", "r1 (g1's after offsets)", o1);
    writeln("PASS redo-in-session");
}

// redo-after-rearm — L2 r1-r3: after the activation's undo the redo re-arms a
// fresh instance: offsets 0 at every redo step, the mesh back to g2.
unittest {
    if (!cell("redo-after-rearm")) return;
    const r = rig();
    penArmUi(r);
    moveV5("redo-after-rearm g1");
    const g1 = penMesh();
    moveV10("redo-after-rearm g2");
    const g2 = penMesh();
    assert(len3(offs()) > 1e-3, "redo-after-rearm g2: offsets " ~ fmt3(offs()));
    foreach (s; ["z1", "z2", "z3"]) z("redo-after-rearm " ~ s);
    at("redo-after-rearm", "z3", r.a0, false, r.hp);
    sz("redo-after-rearm r1");
    at("redo-after-rearm", "r1", r.a0, true, r.hp + 1);
    offsAre("redo-after-rearm", "r1", [0, 0, 0]);
    sz("redo-after-rearm r2");
    at("redo-after-rearm", "r2", g1, true, r.hp + 2);
    offsAre("redo-after-rearm", "r2", [0, 0, 0]);
    sz("redo-after-rearm r3");
    at("redo-after-rearm", "r3", g2, true, r.hp + 3);
    offsAre("redo-after-rearm", "r3", [0, 0, 0]);
    writeln("PASS redo-after-rearm");
}

// switch-back-offsets — X-w z1: g1, W, Ctrl+Z re-arms the pen with g1 kept and
// offsets 0 (the predecessor restore strips the operation context).
unittest {
    if (!cell("switch-back-offsets")) return;
    const r = rig();
    penArmUi(r);
    moveV5("switch-back-offsets g1");
    const g1 = penMesh();
    assert(len3(offs()) > 1e-3, "switch-back-offsets g1: offsets " ~ fmt3(offs()));
    penKey(PEN_SDLK_w, 0, "switch-back-offsets W");
    assert(!penArmed() && penTool().length && penHistoryLen() == r.hp + 3,
           format("switch-back-offsets W: tool '%s', history %s", penTool(), penHistoryLabels()));
    z("switch-back-offsets z1");
    at("switch-back-offsets", "z1", g1, true, r.hp + 2);
    offsAre("switch-back-offsets", "z1", [0, 0, 0]);
    writeln("PASS switch-back-offsets");
}

// rearm-typed-offsets — X-toggle: a re-typed arm is a fresh instance (offsets
// 0, the attribute cache must not carry them), and so is its undo's re-arm.
unittest {
    if (!cell("rearm-typed-offsets")) return;
    const r = rig();
    penArmUi(r);
    moveV5("rearm-typed-offsets g1");
    const g1 = penMesh();
    assert(len3(offs()) > 1e-3, "rearm-typed-offsets g1: offsets " ~ fmt3(offs()));
    penLineUi("tool.set " ~ kPenToolId ~ " on");
    at("rearm-typed-offsets", "exit", g1, true, r.hp + 3);
    offsAre("rearm-typed-offsets", "exit", [0, 0, 0]);
    z("rearm-typed-offsets z1");
    at("rearm-typed-offsets", "z1", g1, true, r.hp + 2);
    offsAre("rearm-typed-offsets", "z1", [0, 0, 0]);
    z("rearm-typed-offsets z2");
    at("rearm-typed-offsets", "z2", r.a0, true, r.hp + 1);
    z("rearm-typed-offsets z3");
    at("rearm-typed-offsets", "z3", r.a0, false, r.hp);
    writeln("PASS rearm-typed-offsets");
}

// ===========================================================================
// The fold into the activation (M-G; L15, C1-F1/F2/F3, K-modes-b).
// ===========================================================================

// absorb-first-press — L15: a pre-press write folds into the activation at the
// first press: Ctrl+Z pops g1 (loop stays true), the next pops BOTH rows.
unittest {
    if (!cell("absorb-first-press")) return;
    const r = rig();
    penArmUi(r);
    w("loop", "true");
    moveV5("absorb-first-press g1");
    at("absorb-first-press", "g1", penMesh(), true, r.hp + 3);
    z("absorb-first-press z1");
    at("absorb-first-press", "z1", r.a0, true, r.hp + 2);
    assert(attrStr("loop") == "true", "absorb-first-press z1: loop " ~ attrStr("loop"));
    z("absorb-first-press z2");
    at("absorb-first-press", "z2 (the write and the activation as one)", r.a0, false, r.hp);
    writeln("PASS absorb-first-press");
}

// mode-steps — K-modes-b: a pre-press mode write folds into the activation at
// the first place; a post-press one is its own row.
unittest {
    if (!cell("mode-steps")) return;
    const r = rig();
    penArmUi(r);
    w("mode", "point");
    penTap(penEmptyBackgroundPx(), 1, 0, "mode-steps place1");
    const p1 = penMesh();
    penTap(emptyPx2(), 1, 0, "mode-steps place2");
    const p2 = penMesh();
    // One vertex per place (the face list `/api/model` reports does not carry
    // the one-point polygon the reference adds; not this slice's law).
    assert(p1.nv == r.a0.nv + 1 && p2.nv == r.a0.nv + 2 && penHistoryLen() == r.hp + 4,
           format("mode-steps rig: place1 %s place2 %s from %s, history %s", p1.toString,
                  p2.toString, r.a0.toString, penHistoryLabels()));
    w("mode", "fill");
    at("mode-steps", "w2", p2, true, r.hp + 5);
    z("mode-steps z1");
    at("mode-steps", "z1", p2, true, r.hp + 4);
    assert(attrStr("mode") == `"point"`, "mode-steps z1: mode " ~ attrStr("mode"));
    z("mode-steps z2");
    at("mode-steps", "z2", p1, true, r.hp + 3);
    z("mode-steps z3");
    at("mode-steps", "z3", r.a0, true, r.hp + 2);
    assert(attrStr("mode") == `"point"`, "mode-steps z3: mode " ~ attrStr("mode"));
    z("mode-steps z4");
    at("mode-steps", "z4", r.a0, false, r.hp);
    writeln("PASS mode-steps");
}

// absorb-after-undone-press — C1-F1 (F-first, generalised by L41): a write
// after an undone press is NOT absorbed by the later press; it pops alone.
unittest {
    if (!cell("absorb-after-undone-press")) return;
    const r = rig();
    penArmUi(r);
    moveV5("absorb-after-undone-press g1");
    z("absorb-after-undone-press z0");
    w("mode", "point");
    penTap(penEmptyBackgroundPx(), 1, 0, "absorb-after-undone-press place");
    assert(penMesh().nv == r.a0.nv + 1 && penHistoryLen() == r.hp + 3,
           "absorb-after-undone-press rig: " ~ penHistoryLabels().join(","));
    z("absorb-after-undone-press z1");
    at("absorb-after-undone-press", "z1", r.a0, true, r.hp + 2);
    assert(attrStr("mode") == `"point"`, "absorb-after-undone-press z1: mode " ~ attrStr("mode"));
    z("absorb-after-undone-press z2");
    at("absorb-after-undone-press", "z2 (the write alone)", r.a0, true, r.hp + 1);
    assert(attrStr("mode") == `"move"`, "absorb-after-undone-press z2: mode " ~ attrStr("mode"));
    z("absorb-after-undone-press z3");
    at("absorb-after-undone-press", "z3", r.a0, false, r.hp);
    writeln("PASS absorb-after-undone-press");
}

// absorb-redo — C1-F2 (Absorb + F-preset + group): the activation group's redo
// restores NONE of its rows' attributes (offsetX reads 0), then g1; the group
// pops whole again.
unittest {
    if (!cell("absorb-redo")) return;
    const r = rig();
    penArmUi(r);
    w("offsetX", "0.1");
    moveV5("absorb-redo g1");
    const g1 = penMesh();
    z("absorb-redo z1");
    at("absorb-redo", "z1", r.a0, true, r.hp + 2);
    z("absorb-redo z2");
    at("absorb-redo", "z2", r.a0, false, r.hp);
    sz("absorb-redo r1");
    at("absorb-redo", "r1", r.a0, true, r.hp + 2);
    offsAre("absorb-redo", "r1 (F-preset)", [0, 0, 0]);
    sz("absorb-redo r2");
    at("absorb-redo", "r2", g1, true, r.hp + 3);
    offsAre("absorb-redo", "r2", [0, 0, 0]);
    z("absorb-redo zz1");
    at("absorb-redo", "zz1", r.a0, true, r.hp + 2);
    z("absorb-redo zz2");
    at("absorb-redo", "zz2 (the group again)", r.a0, false, r.hp);
    writeln("PASS absorb-redo");
}

// absorb-script-arm — C1-F3 Keep: a SCRIPT-door arm opens nothing to fold
// into: the pre-press write stays its own step.
unittest {
    if (!cell("absorb-script-arm")) return;
    const r = rig();
    auto a = penPost("/api/command", "tool.set " ~ kPenToolId ~ " on");
    assert(a["status"].str == "ok" && penArmed() && penHistoryLen() == r.hp + 1,
           "absorb-script-arm rig: the script arm " ~ a.toString ~ " " ~ penHistoryLabels().join(","));
    w("loop", "true");
    moveV5("absorb-script-arm g1");
    z("absorb-script-arm z1");
    at("absorb-script-arm", "z1", r.a0, true, r.hp + 2);
    assert(attrStr("loop") == "true", "absorb-script-arm z1: loop " ~ attrStr("loop"));
    z("absorb-script-arm z2");
    at("absorb-script-arm", "z2 (the write alone)", r.a0, true, r.hp + 1);
    assert(attrStr("loop") == "false", "absorb-script-arm z2: loop " ~ attrStr("loop"));
    z("absorb-script-arm z3");
    at("absorb-script-arm", "z3", r.a0, false, r.hp);
    writeln("PASS absorb-script-arm");
}

/// Whether `tool` is the active tool: its attribute query answers (the tool
/// state route publishes no id for Smooth Shift).
bool armedTool(string tool, string attr) {
    return penPost("/api/command", "tool.attr " ~ tool ~ " " ~ attr ~ " ?")["status"].str == "ok";
}

// absorb-restores-predecessor — [A2-3]/[A3-4]: the group's undo goes through
// the activation path's TAIL: Smooth Shift (a topology tool with a session
// token) is re-armed with its attribute image AND its token, so the next
// Ctrl+Z navigates its own SECOND step: `shift` back to that step's before
// value. (Its first step carries its activation by its own policy, so the
// attribute witness is the second.)
unittest {
    if (!cell("absorb-restores-predecessor")) return;
    enum ss = "mesh.smoothShiftTool";
    const r = rig();
    penLineUi("tool.set " ~ ss ~ " on");
    assert(armedTool(ss, "shift") && num(attrOf(ss, "shift")) == 0,
           "absorb-restores-predecessor rig: Smooth Shift not armed at shift 0");
    double ssStep(string v, long hist) {
        auto s1 = penPost("/api/script?interactive=true", "tool.attr " ~ ss ~ " shift " ~ v);
        assert(s1["status"].str == "ok" && penHistoryLen() == hist,
               "absorb-restores-predecessor: the Smooth Shift step " ~ v ~ " " ~ s1.toString ~ " "
               ~ penHistoryLabels().join(","));
        return num(attrOf(ss, "shift"));
    }
    const before = ssStep("0.3", r.hp + 2);
    const s1 = penMesh();
    const after = ssStep("0.5", r.hp + 3);
    const s2 = penMesh();
    assert(abs(before - 0.3) < 1e-6 && abs(after - 0.5) < 1e-6,
           format("absorb-restores-predecessor: shift %s then %s", before, after));
    penArmUi(r);
    w("loop", "true");
    moveV5("absorb-restores-predecessor g1");
    assert(penHistoryLen() == r.hp + 6, "absorb-restores-predecessor rig: " ~ penHistoryLabels().join(","));
    z("absorb-restores-predecessor z1");
    assert(penArmed() && penMesh() == s2 && penHistoryLen() == r.hp + 5,
           "absorb-restores-predecessor z1: " ~ penHistoryLabels().join(","));
    z("absorb-restores-predecessor z2");
    assert(armedTool(ss, "shift") && penMesh() == s2 && penHistoryLen() == r.hp + 3
           && abs(num(attrOf(ss, "shift")) - after) < 1e-6,
           format("absorb-restores-predecessor z2: Smooth Shift armed %s, shift %s, history %s",
                  armedTool(ss, "shift"), num(attrOf(ss, "shift")), penHistoryLabels()));
    z("absorb-restores-predecessor z3");
    assert(armedTool(ss, "shift") && penMesh() == s1 && penHistoryLen() == r.hp + 2,
           format("absorb-restores-predecessor z3: Smooth Shift armed %s, mesh %s its first step, "
                  ~ "history %s", armedTool(ss, "shift"), penMesh() == s1 ? "==" : "!=",
                  penHistoryLabels()));
    // m12's red line ([A3-4]): the restored instance navigated its OWN step.
    assert(abs(num(attrOf(ss, "shift")) - before) < 1e-6,
           format("absorb-restores-predecessor z3: shift %s (expected the step's before %s), "
                  ~ "history %s", num(attrOf(ss, "shift")), before, penHistoryLabels()));
    writeln("PASS absorb-restores-predecessor");
}

// absorb-then-drop — a drop above the folded group (§9.7 consumers): Esc, then
// the task row, the drop row, g1 and the group pop in that order.
unittest {
    if (!cell("absorb-then-drop")) return;
    const r = rig();
    penArmUi(r);
    w("loop", "true");
    moveV5("absorb-then-drop g1");
    const g1 = penMesh();
    penKey(PEN_SDLK_ESCAPE, 0, "absorb-then-drop Esc");
    at("absorb-then-drop", "exit", g1, false, r.hp + 5);
    z("absorb-then-drop z1");
    at("absorb-then-drop", "z1 (task row)", g1, false, r.hp + 4);
    z("absorb-then-drop z2");
    at("absorb-then-drop", "z2 (drop row)", g1, true, r.hp + 3);
    z("absorb-then-drop z3");
    at("absorb-then-drop", "z3", r.a0, true, r.hp + 2);
    assert(attrStr("loop") == "true", "absorb-then-drop z3: loop " ~ attrStr("loop"));
    z("absorb-then-drop z4");
    at("absorb-then-drop", "z4", r.a0, false, r.hp);
    writeln("PASS absorb-then-drop");
}

// ===========================================================================
// Parameter-row redo (L2p, L2q, L2s, L44, L53, L54).
// ===========================================================================

// param-redo-in-instance — L2s (R-foreign): in the recording instance the
// undone row redoes with its value. (Above param-redo-after-rearm.)
unittest {
    if (!cell("param-redo-in-instance")) return;
    const r = rig();
    penArmUi(r);
    moveV5("param-redo-in-instance g1");
    const g1 = penMesh();
    w("offsetX", "0.1");
    z("param-redo-in-instance z1");
    at("param-redo-in-instance", "z1", g1, true, r.hp + 2);
    sz("param-redo-in-instance r1");
    at("param-redo-in-instance", "r1", g1, true, r.hp + 3);
    assert(is01(attrNum("offsetX")),
           "param-redo-in-instance r1: offsetX " ~ attrStr("offsetX"));
    writeln("PASS param-redo-in-instance");
}

// param-redo-after-rearm — L2p: the row written right after g1 and undone while
// still open is NOT redoable after a re-arm: the redo stack is cut after r2.
unittest {
    if (!cell("param-redo-after-rearm")) return;
    const r = rig();
    penArmUi(r);
    moveV5("param-redo-after-rearm g1");
    const g1 = penMesh();
    w("offsetX", "0.1");
    foreach (s; ["z1", "z2", "z3"]) z("param-redo-after-rearm " ~ s);
    at("param-redo-after-rearm", "z3", r.a0, false, r.hp);
    sz("param-redo-after-rearm r1");
    at("param-redo-after-rearm", "r1", r.a0, true, r.hp + 1);
    offsAre("param-redo-after-rearm", "r1", [0, 0, 0]);
    sz("param-redo-after-rearm r2");
    at("param-redo-after-rearm", "r2", g1, true, r.hp + 2);
    offsAre("param-redo-after-rearm", "r2", [0, 0, 0]);
    assert(redoLen() == 0, format("param-redo-after-rearm r2: redo %d (expected 0: the open row is "
                                  ~ "the old instance's)", redoLen()));
    sz("param-redo-after-rearm r3");
    at("param-redo-after-rearm", "r3 (nothing)", g1, true, r.hp + 2);
    offsAre("param-redo-after-rearm", "r3", [0, 0, 0]);
    writeln("PASS param-redo-after-rearm");
}

// descriptor-after-redo-rearm — L2q (N): after the re-arm an Offset write is a
// row and re-places nothing (S7a, and S7b by N: the descriptor was stripped).
unittest {
    if (!cell("descriptor-after-redo-rearm")) return;
    const r = rig();
    penArmUi(r);
    moveV5("descriptor-after-redo-rearm g1");
    const g1 = penMesh();
    w("offsetX", "0.1");
    foreach (s; ["z1", "z2", "z3"]) z("descriptor-after-redo-rearm " ~ s);
    sz("descriptor-after-redo-rearm r1");
    sz("descriptor-after-redo-rearm r2");
    at("descriptor-after-redo-rearm", "r2", g1, true, r.hp + 2);
    assert(stepKindNow() == 0 && stepVertsNow() == "[]",
           format("descriptor-after-redo-rearm r2: kind %s verts %s (stripped in a foreign instance)",
                  stepKindNow().to!string, stepVertsNow()));
    w("offsetY", "0.05");
    at("descriptor-after-redo-rearm", "w2", g1, true, r.hp + 3);
    z("descriptor-after-redo-rearm zz1");
    at("descriptor-after-redo-rearm", "zz1", g1, true, r.hp + 2);
    z("descriptor-after-redo-rearm zz2");
    at("descriptor-after-redo-rearm", "zz2", r.a0, true, r.hp + 1);
    writeln("PASS descriptor-after-redo-rearm");
}

// param-redo-closed-after-rearm — L44: a row written after an undo and then
// CLOSED by a press redoes after a re-arm (attribute-only, offsets 0).
unittest {
    if (!cell("param-redo-closed-after-rearm")) return;
    const r = rig();
    penArmUi(r);
    moveV5("param-redo-closed-after-rearm g1");
    const g1 = penMesh();
    moveV10("param-redo-closed-after-rearm g2");
    z("param-redo-closed-after-rearm z0");
    w("offsetX", "0.1");
    moveV6("param-redo-closed-after-rearm g3");
    const g3 = penMesh();
    assert(penHistoryLen() == r.hp + 4, "param-redo-closed-after-rearm rig: "
           ~ penHistoryLabels().join(","));
    foreach (s; ["z1", "z2", "z3", "z4"]) z("param-redo-closed-after-rearm " ~ s);
    at("param-redo-closed-after-rearm", "z4", r.a0, false, r.hp);
    sz("param-redo-closed-after-rearm r1");
    at("param-redo-closed-after-rearm", "r1", r.a0, true, r.hp + 1);
    sz("param-redo-closed-after-rearm r2");
    at("param-redo-closed-after-rearm", "r2", g1, true, r.hp + 2);
    sz("param-redo-closed-after-rearm r3");
    at("param-redo-closed-after-rearm", "r3 (the closed row redone)", g1, true, r.hp + 3);
    offsAre("param-redo-closed-after-rearm", "r3", [0, 0, 0]);
    sz("param-redo-closed-after-rearm r4");
    at("param-redo-closed-after-rearm", "r4", g3, true, r.hp + 4);
    writeln("PASS param-redo-closed-after-rearm");
}

// param-redo-open-undone — L53 (C4-redo-open-undone, Redone): a row written
// after an undo (no press below its open step) and never closed REDOES after a
// re-arm, attribute-only, offsets 0; then the redo stack is empty.
unittest {
    if (!cell("param-redo-open-undone")) return;
    const r = rig();
    penArmUi(r);
    moveV5("param-redo-open-undone g1");
    const g1 = penMesh();
    moveV10("param-redo-open-undone g2");
    z("param-redo-open-undone z0");
    w("offsetX", "0.1");
    foreach (s; ["z1", "z2", "z3"]) z("param-redo-open-undone " ~ s);
    at("param-redo-open-undone", "z3", r.a0, false, r.hp);
    sz("param-redo-open-undone r1");
    sz("param-redo-open-undone r2");
    at("param-redo-open-undone", "r2", g1, true, r.hp + 2);
    sz("param-redo-open-undone r3");
    at("param-redo-open-undone", "r3 (the row redone)", g1, true, r.hp + 3);
    offsAre("param-redo-open-undone", "r3", [0, 0, 0]);
    assert(redoLen() == 0, format("param-redo-open-undone r3: redo %d", redoLen()));
    writeln("PASS param-redo-open-undone");
}

// pop-one-open-rows — L54 (Pop-one + the plan's rule): two open rows pop one
// at a time; after the re-arm the first is refused even with the second above
// it (R-above refuted).
unittest {
    if (!cell("pop-one-open-rows")) return;
    const r = rig();
    penArmUi(r);
    moveV5("pop-one-open-rows g1");
    const g1 = penMesh();
    const o1 = offs();
    w("offsetX", "0.1");
    w("loop", "true");
    z("pop-one-open-rows z1");
    at("pop-one-open-rows", "z1", g1, true, r.hp + 3);
    assert(attrStr("loop") == "false" && is01(attrNum("offsetX")),
           format("pop-one-open-rows z1: loop %s offsetX %s", attrStr("loop"), attrStr("offsetX")));
    z("pop-one-open-rows z2");
    at("pop-one-open-rows", "z2", g1, true, r.hp + 2);
    offsAre("pop-one-open-rows", "z2 (g1's)", o1);
    z("pop-one-open-rows z3");
    z("pop-one-open-rows z4");
    at("pop-one-open-rows", "z4", r.a0, false, r.hp);
    sz("pop-one-open-rows r1");
    sz("pop-one-open-rows r2");
    at("pop-one-open-rows", "r2", g1, true, r.hp + 2);
    assert(redoLen() == 0, format("pop-one-open-rows r2: redo %d (both open rows are the old "
                                  ~ "instance's)", redoLen()));
    sz("pop-one-open-rows r3");
    at("pop-one-open-rows", "r3 (refused)", g1, true, r.hp + 2);
    writeln("PASS pop-one-open-rows");
}

// ===========================================================================
// The fold at a press, a switch, a re-typed arm (L38, L41-L45, L55).
// ===========================================================================

// fold-on-press — L38 (L2r): the row written after g1 folds into g1 at g2.
unittest {
    if (!cell("fold-on-press")) return;
    const r = rig();
    penArmUi(r);
    moveV5("fold-on-press g1");
    const g1 = penMesh();
    w("offsetX", "0.1");
    moveV10("fold-on-press g2");
    z("fold-on-press z1");
    at("fold-on-press", "z1", g1, true, r.hp + 3);
    offsAre("fold-on-press", "z1", [0, 0, 0]);
    z("fold-on-press z2");
    at("fold-on-press", "z2 (g1 and the row as one)", r.a0, true, r.hp + 1);
    z("fold-on-press z3");
    at("fold-on-press", "z3", r.a0, false, r.hp);
    writeln("PASS fold-on-press");
}

// fold-on-switch — L38 (L2u): a tool switch folds the open row into g1.
unittest {
    if (!cell("fold-on-switch")) return;
    const r = rig();
    penArmUi(r);
    moveV5("fold-on-switch g1");
    const g1 = penMesh();
    w("offsetX", "0.1");
    penKey(PEN_SDLK_w, 0, "fold-on-switch W");
    assert(!penArmed() && penHistoryLen() == r.hp + 4, "fold-on-switch W: " ~ penHistoryLabels().join(","));
    z("fold-on-switch z1");
    at("fold-on-switch", "z1", g1, true, r.hp + 3);
    offsAre("fold-on-switch", "z1", [0, 0, 0]);
    z("fold-on-switch z2");
    at("fold-on-switch", "z2 (g1 and the row as one)", r.a0, true, r.hp + 1);
    z("fold-on-switch z3");
    at("fold-on-switch", "z3", r.a0, false, r.hp);
    writeln("PASS fold-on-switch");
}

// fold-switch-group-redo — L2u-redo: the folded group redoes as one step in
// the re-armed instance, offsets 0.
unittest {
    if (!cell("fold-switch-group-redo")) return;
    const r = rig();
    penArmUi(r);
    moveV5("fold-switch-group-redo g1");
    const g1 = penMesh();
    w("offsetX", "0.1");
    penKey(PEN_SDLK_w, 0, "fold-switch-group-redo W");
    z("fold-switch-group-redo z1");
    z("fold-switch-group-redo z2");
    at("fold-switch-group-redo", "z2", r.a0, true, r.hp + 1);
    sz("fold-switch-group-redo r1");
    at("fold-switch-group-redo", "r1 (the group)", g1, true, r.hp + 3);
    offsAre("fold-switch-group-redo", "r1", [0, 0, 0]);
    writeln("PASS fold-switch-group-redo");
}

// fold-group-redo — L43 (C3-L2r2, G-after): in the recording instance the
// group's redo restores its LAST row's after image (offsetX 0.1).
unittest {
    if (!cell("fold-group-redo")) return;
    const r = rig();
    penArmUi(r);
    moveV5("fold-group-redo g1");
    const g1 = penMesh();
    w("offsetX", "0.1");
    const ow = offs();
    moveV10("fold-group-redo g2");
    const g2 = penMesh();
    z("fold-group-redo z1");
    z("fold-group-redo z2");
    at("fold-group-redo", "z2", r.a0, true, r.hp + 1);
    sz("fold-group-redo r1");
    at("fold-group-redo", "r1 (the group)", g1, true, r.hp + 3);
    offsAre("fold-group-redo", "r1 (the row's after offsets)", ow);
    sz("fold-group-redo r2");
    at("fold-group-redo", "r2", g2, true, r.hp + 4);
    writeln("PASS fold-group-redo");
}

// fold-group-redo-rearm — L43 (C3-L2r3, G-whole): after a re-arm the group
// redoes whole with offsets 0, then g2.
unittest {
    if (!cell("fold-group-redo-rearm")) return;
    const r = rig();
    penArmUi(r);
    moveV5("fold-group-redo-rearm g1");
    const g1 = penMesh();
    w("offsetX", "0.1");
    moveV10("fold-group-redo-rearm g2");
    const g2 = penMesh();
    foreach (s; ["z1", "z2", "z3"]) z("fold-group-redo-rearm " ~ s);
    at("fold-group-redo-rearm", "z3", r.a0, false, r.hp);
    sz("fold-group-redo-rearm r1");
    at("fold-group-redo-rearm", "r1", r.a0, true, r.hp + 1);
    sz("fold-group-redo-rearm r2");
    at("fold-group-redo-rearm", "r2 (the group)", g1, true, r.hp + 3);
    offsAre("fold-group-redo-rearm", "r2", [0, 0, 0]);
    sz("fold-group-redo-rearm r3");
    at("fold-group-redo-rearm", "r3", g2, true, r.hp + 4);
    writeln("PASS fold-group-redo-rearm");
}

// fold-after-redo — L42 (Reopen): the redo of g1 reopens its block, so the row
// written after it folds into g1 at g2.
unittest {
    if (!cell("fold-after-redo")) return;
    const r = rig();
    penArmUi(r);
    moveV5("fold-after-redo g1");
    const g1 = penMesh();
    z("fold-after-redo z0");
    sz("fold-after-redo r0");
    at("fold-after-redo", "r0", g1, true, r.hp + 2);
    w("offsetX", "0.1");
    moveV10("fold-after-redo g2");
    z("fold-after-redo z1");
    at("fold-after-redo", "z1", g1, true, r.hp + 3);
    z("fold-after-redo z2");
    at("fold-after-redo", "z2 (g1 and the row as one)", r.a0, true, r.hp + 1);
    z("fold-after-redo z3");
    at("fold-after-redo", "z3", r.a0, false, r.hp);
    writeln("PASS fold-after-redo");
}

// fold-not-after-undo — L41 (Block): an undo closes the block, so the row
// written after it is NOT folded into g1 by g3: it pops alone.
unittest {
    if (!cell("fold-not-after-undo")) return;
    const r = rig();
    penArmUi(r);
    moveV5("fold-not-after-undo g1");
    const g1 = penMesh();
    moveV10("fold-not-after-undo g2");
    z("fold-not-after-undo z0");
    w("offsetX", "0.1");
    moveV6("fold-not-after-undo g3");
    z("fold-not-after-undo z1");
    at("fold-not-after-undo", "z1", g1, true, r.hp + 3);
    z("fold-not-after-undo z2");
    at("fold-not-after-undo", "z2 (the row alone)", g1, true, r.hp + 2);
    z("fold-not-after-undo z3");
    at("fold-not-after-undo", "z3", r.a0, true, r.hp + 1);
    writeln("PASS fold-not-after-undo");
}

// fold-on-retype — L45 (C3-toggle-fold, Fold): a re-typed arm closes the open
// step like a switch.
unittest {
    if (!cell("fold-on-retype")) return;
    const r = rig();
    penArmUi(r);
    moveV5("fold-on-retype g1");
    const g1 = penMesh();
    w("offsetX", "0.1");
    penLineUi("tool.set " ~ kPenToolId ~ " on");
    at("fold-on-retype", "exit", g1, true, r.hp + 4);
    z("fold-on-retype z1");
    at("fold-on-retype", "z1", g1, true, r.hp + 3);
    z("fold-on-retype z2");
    at("fold-on-retype", "z2 (g1 and the row as one)", r.a0, true, r.hp + 1);
    z("fold-on-retype z3");
    at("fold-on-retype", "z3", r.a0, false, r.hp);
    writeln("PASS fold-on-retype");
}

// fold-all-rows — L45 (C3-w2-fold, Fold-all): every open row folds, not only
// the last.
unittest {
    if (!cell("fold-all-rows")) return;
    const r = rig();
    penArmUi(r);
    moveV5("fold-all-rows g1");
    const g1 = penMesh();
    w("offsetX", "0.1");
    w("loop", "true");
    moveV10("fold-all-rows g2");
    z("fold-all-rows z1");
    at("fold-all-rows", "z1", g1, true, r.hp + 4);
    assert(attrStr("loop") == "true", "fold-all-rows z1: loop " ~ attrStr("loop"));
    z("fold-all-rows z2");
    at("fold-all-rows", "z2 (g1 and both rows)", r.a0, true, r.hp + 1);
    assert(attrStr("loop") == "false", "fold-all-rows z2: loop " ~ attrStr("loop"));
    writeln("PASS fold-all-rows");
}

// fold-two-after-undo — L55 (C4-w2-after-undo, One-step): two rows written
// after an undo fold with EACH OTHER at the next press.
unittest {
    if (!cell("fold-two-after-undo")) return;
    const r = rig();
    penArmUi(r);
    moveV5("fold-two-after-undo g1");
    const g1 = penMesh();
    moveV10("fold-two-after-undo g2");
    z("fold-two-after-undo z0");
    w("offsetX", "0.1");
    w("loop", "true");
    moveV6("fold-two-after-undo g3");
    z("fold-two-after-undo z1");
    at("fold-two-after-undo", "z1", g1, true, r.hp + 4);
    z("fold-two-after-undo z2");
    at("fold-two-after-undo", "z2 (both rows as one)", g1, true, r.hp + 2);
    assert(attrStr("loop") == "false", "fold-two-after-undo z2: loop " ~ attrStr("loop"));
    offsAre("fold-two-after-undo", "z2", [0, 0, 0]);
    z("fold-two-after-undo z3");
    at("fold-two-after-undo", "z3", r.a0, true, r.hp + 1);
    writeln("PASS fold-two-after-undo");
}

// fold-after-param-redo — L55 (C4-redo-param, Reopen-base): the redo of a
// parameter row reopens the press below it, so the next write folds there too.
unittest {
    if (!cell("fold-after-param-redo")) return;
    const r = rig();
    penArmUi(r);
    moveV5("fold-after-param-redo g1");
    const g1 = penMesh();
    w("offsetX", "0.1");
    z("fold-after-param-redo z0");
    sz("fold-after-param-redo r0");
    at("fold-after-param-redo", "r0", g1, true, r.hp + 3);
    w("loop", "true");
    moveV10("fold-after-param-redo g2");
    z("fold-after-param-redo z1");
    at("fold-after-param-redo", "z1", g1, true, r.hp + 4);
    assert(attrStr("loop") == "true", "fold-after-param-redo z1: loop " ~ attrStr("loop"));
    z("fold-after-param-redo z2");
    at("fold-after-param-redo", "z2 (g1 and both rows)", r.a0, true, r.hp + 1);
    assert(attrStr("loop") == "false", "fold-after-param-redo z2: loop " ~ attrStr("loop"));
    z("fold-after-param-redo z3");
    at("fold-after-param-redo", "z3", r.a0, false, r.hp);
    writeln("PASS fold-after-param-redo");
}

// switch-closed-redo — C4-switch-closed (L53, Closed): a row written after an
// undo is CLOSED by the switch, so it redoes after the re-arm; then the switch.
unittest {
    if (!cell("switch-closed-redo")) return;
    const r = rig();
    penArmUi(r);
    moveV5("switch-closed-redo g1");
    const g1 = penMesh();
    moveV10("switch-closed-redo g2");
    z("switch-closed-redo z0");
    w("offsetX", "0.1");
    penKey(PEN_SDLK_w, 0, "switch-closed-redo W");
    const moveTool = penTool();
    assert(!penArmed() && moveTool.length && penHistoryLen() == r.hp + 4,
           "switch-closed-redo W: " ~ penHistoryLabels().join(","));
    z("switch-closed-redo z1");
    at("switch-closed-redo", "z1", g1, true, r.hp + 3);
    z("switch-closed-redo z2");
    at("switch-closed-redo", "z2 (the row alone)", g1, true, r.hp + 2);
    z("switch-closed-redo z3");
    z("switch-closed-redo z4");
    at("switch-closed-redo", "z4", r.a0, false, r.hp);
    sz("switch-closed-redo r1");
    sz("switch-closed-redo r2");
    at("switch-closed-redo", "r2", g1, true, r.hp + 2);
    sz("switch-closed-redo r3");
    at("switch-closed-redo", "r3 (the closed row redone)", g1, true, r.hp + 3);
    offsAre("switch-closed-redo", "r3", [0, 0, 0]);
    sz("switch-closed-redo r4");
    assert(penTool() == moveTool && penMesh() == g1 && penHistoryLen() == r.hp + 4,
           format("switch-closed-redo r4: tool '%s' (expected '%s'), history %s", penTool(), moveTool,
                  penHistoryLabels()));
    writeln("PASS switch-closed-redo");
}

// rearm-redo-opens-nothing — ours (the plan's rule, §9.19.3 "cleared by ANY
// navigation"; uncaptured for a re-arming redo, gap row (dd)'s family): the
// redo that re-arms the pen opens no block, so a write right after it is the
// base of its own step and pops alone after the next press.
unittest {
    if (!cell("rearm-redo-opens-nothing")) return;
    const r = rig();
    penArmUi(r);
    moveV5("rearm-redo-opens-nothing g1");
    z("rearm-redo-opens-nothing z0");
    z("rearm-redo-opens-nothing z00");
    at("rearm-redo-opens-nothing", "z00", r.a0, false, r.hp);
    sz("rearm-redo-opens-nothing r1");
    at("rearm-redo-opens-nothing", "r1", r.a0, true, r.hp + 1);
    w("offsetX", "0.1");
    moveV10("rearm-redo-opens-nothing g2");
    z("rearm-redo-opens-nothing z1");
    at("rearm-redo-opens-nothing", "z1", r.a0, true, r.hp + 2);
    z("rearm-redo-opens-nothing z2");
    at("rearm-redo-opens-nothing", "z2 (the row alone)", r.a0, true, r.hp + 1);
    z("rearm-redo-opens-nothing z3");
    at("rearm-redo-opens-nothing", "z3", r.a0, false, r.hp);
    writeln("PASS rearm-redo-opens-nothing");
}

// fold-on-drop — a drop closes the open step by the switch rule (§9.19.3; gap
// row (t): unobservable at the reference, whose drop undo loses the gesture):
// Esc, then the task row, the drop row, and g1 with the row as one step.
unittest {
    if (!cell("fold-on-drop")) return;
    const r = rig();
    penArmUi(r);
    moveV5("fold-on-drop g1");
    const g1 = penMesh();
    w("offsetX", "0.1");
    penKey(PEN_SDLK_ESCAPE, 0, "fold-on-drop Esc");
    at("fold-on-drop", "exit", g1, false, r.hp + 5);
    z("fold-on-drop z1");
    z("fold-on-drop z2");
    at("fold-on-drop", "z2 (drop row)", g1, true, r.hp + 3);
    z("fold-on-drop z3");
    at("fold-on-drop", "z3 (g1 and the row as one)", r.a0, true, r.hp + 1);
    writeln("PASS fold-on-drop");
}

// fold-not-on-command — the fold triggers are a press, a switch, a re-typed
// arm and a drop (§9.19.3 (i)/(ii), §9.22.1); nothing else closes the open
// step. A recording command through the UI door with the pen armed reaches the
// session's close (`CloseReason.command`) and leaves the pen armed: the row
// written before it stays its own step, under the command's own row.
unittest {
    if (!cell("fold-not-on-command")) return;
    const r = rig();
    penArmUi(r);
    moveV5("fold-not-on-command g1");
    const g1 = penMesh();
    const og1 = offs();
    assert(len3(og1) > 1e-3, "fold-not-on-command rig: g1 reported no offset " ~ fmt3(og1));
    w("offsetX", "0.1");
    penLineUi("select.element vertex set 0");
    at("fold-not-on-command", "command (the pen stays, the command is a row)", g1, true, r.hp + 4);
    z("fold-not-on-command z1");
    at("fold-not-on-command", "z1 (the command's row)", g1, true, r.hp + 3);
    z("fold-not-on-command z2");
    at("fold-not-on-command", "z2 (the parameter row alone)", g1, true, r.hp + 2);
    offsAre("fold-not-on-command", "z2 (the row's before image: g1's)", og1);
    z("fold-not-on-command z3");
    at("fold-not-on-command", "z3 (g1)", r.a0, true, r.hp + 1);
    writeln("PASS fold-not-on-command");
}

// discard-resets-offsets — a release while another pen button is held
// discards the gesture (§9.27 [A15-1]): its mesh AND its operation context go
// back to the press's (offsets 0, no descriptor).
unittest {
    if (!cell("discard-resets-offsets")) return;
    const r = rig();
    penArmUi(r);
    const e = penEmptyBackgroundPx();
    const v5 = penVertexPx(5, "discard-resets-offsets v5");
    string log = penMotion(20, e[0], e[1], 0, 0) ~ "\n"
               ~ penButton(40, true, 2, e[0], e[1], 0) ~ "\n"
               ~ penMotion(60, v5[0], v5[1], penButtonMask(2), 0) ~ "\n"
               ~ penButton(80, true, 1, v5[0], v5[1], 0) ~ "\n";
    foreach (i; 1 .. 9)
        log ~= penMotion(80 + 20 * i, v5[0] + 5 * i, v5[1] - 2 * i,
                         penButtonMask(1) | penButtonMask(2), 0) ~ "\n";
    penPlay(log[0 .. $ - 1], "discard-resets-offsets MMB hold, LMB drag");
    assert(penMoved(penMesh(), r.a0) == [5L] && len3(offs()) > 1e-3,
           format("discard-resets-offsets rig: the held drag moved %s, offsets %s",
                  penIdx(penMoved(penMesh(), r.a0)), fmt3(offs())));
    penPlay(penButton(20, false, 1, v5[0] + 40, v5[1] - 16, 0), "discard-resets-offsets LMB release");
    assert(penMesh() == r.a0, "discard-resets-offsets: the discard did not restore the press image");
    offsAre("discard-resets-offsets", "discarded", [0, 0, 0]);
    assert(stepKindNow() == 0, "discard-resets-offsets: kind " ~ stepKindNow().to!string);
    penPlay(penButton(20, false, 2, e[0], e[1], 0), "discard-resets-offsets MMB release");
    writeln("PASS discard-resets-offsets");
}

// ---------------------------------------------------------------------------
// Population: with no VIBE3D_CELL every cell above ran (declared last).
// ---------------------------------------------------------------------------
unittest {
    writeln("cells=", cellsRun);
    const only = environment.get("VIBE3D_CELL", "");
    if (only.length == 0)
        assert(cellsRun == 41, format("topology pen S7a laws: %d cells ran, expected 41", cellsRun));
    else
        assert(cellsRun == 1, format("topology pen S7a laws: VIBE3D_CELL=%s ran %d cells, expected 1 "
                                     ~ "(an unknown name runs none)", only, cellsRun));
}
