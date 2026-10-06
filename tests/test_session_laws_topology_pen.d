// Topology pen session laws — the rig, the neutral fixture and the laws that
// already hold (task 8650; wave plan 8640 slice S2). Later slices add their
// cells here. Rig and transport: tests/topology_pen_session_helpers.d.
// Expectations: tests/fixtures/topology_pen_session_laws.json (structural only;
// every mesh comparison is within OUR run, never against reference numbers).
//
//   arm-two-moves        L1  the UI-door activation is its own step (K1)
//   held-undo            L6  a Ctrl+Z while a drag's button is held is dropped
//   branch               L10 a gesture after an undo replaces the redo branch
//   alt-chords           L12 no Alt chord reaches the pen
//   smooth-loop-interior L13 (interior) Smoothing + Edge Loop is the loop
//   smooth-loop-border   L13 (border) the loop holds its face-valence-1 corners
//   chords               L4  the five chords that record today: one step each
//   switch-away          L9  (z1..z3) undo walks back through a tool switch
//   chord-split-interior L4  MMB split v5 -> v10: an interior same-polygon target
//   chord-remove-*       L35 a face remove takes exactly the orphans IT makes
//   no-op-presses        L5  three presses that change nothing are three steps
//   no-op-chord-clicks   L5  nine motionless chord clicks are nine steps
//   redo-rearm           L2  redo re-arms the popped pen, then each gesture
//   switch-away-redo     L9  (r1..r3) redo walks forward through the switch
//   drop-mid-drag            a drop during a held drag records that press,
//                            below the drop row (S6)
//   param-write-*        L14 an interactive attribute write is its own step
//   split-*-row          L40 a refused split is still one step
//   remove-edge-noop-row L5  a Remove press latched on nothing removable
//   fill-refusal-move        a Fill refusal's press ends as a Move row
//   rmb-press-block          a declined RMB press never reaches the lasso
//   two-button-rev           L56 overlapping buttons, LMB released first: two rows
//   two-button-fwd           L56 MMB released first: two rows, no loop
//   two-button-cut-move          a second press cuts a held Move (§9.27 [A15-2])
//   two-button-discard-move      a release while another button is held discards
//   chord-slide-vertex   L4  Ctrl+LMB on a vertex slides it alone, onto the BG
//   chord-slide-vertex-orbit           L47 the same under an orbited camera: -Z
//   chord-slide-vertex-foreshortened   L49 world Z foreshortened: -Z, not Y
//   chord-build-*        L34/L37 corner build: neighbour by angle, closed fan
//                        moves, a triangle corner builds the border quad
//   chord-dup-interior-edge  C-0 Shift+LMB on an interior edge moves it
//   chord-dup-empty      Shift+LMB on empty space changes nothing
//   chord-build-angle-orbit  L52 the build neighbour is chosen in the surface plane
//   drop-esc             L8/L32/L39 Esc: a drop row + the empty task row (S6)
//   drop-space           L8/L32 Space: one drop row; its undo keeps g1, empties redo
//   drop-q               L8/L32 Q (tool.release): one drop row
//   drop-command         L8/L32 `tool.set mesh.topoPen off` (UI door): one drop row
//   drop-sel             L8/L32 key 3: the drop row's undo restores the type
//   drop-sel-item        L8 key 5 (Items): the same, through the item door
//   drop-bare            L32 arm, Esc: key door and raw door both refuse the redo
//   rearm-typed              a re-typed arm while armed is a same-tool switch row
//   non-user-drop            a primary move keeps the pen and writes no drop row
//   chord-build-then-remove  L46 the build consumes the bare edge under its new side
//   chord-build-consume-undo L46 undo of that build re-registers the bare edge
//   fill-consume-then-remove L46 Fill consumes the bare edge along its new side
//
// Slice S5 (task 8730) added the cells from `no-op-presses` on: since then
// every pen press is one topology step the session records (wave plan 8646).
// The fixture still carries rows that do not hold on this rig yet: the other
// chords' outcomes (their port slices add `chord-*` cells).
//
// `VIBE3D_CELL=<id>` runs one cell alone (druntime stops a module at its first
// failed assert); the last block pins the population: 55 with no filter, 1 with
// one (an unknown name must not pass by running nothing).
//
// Run via: ./run_test.d test_session_laws_topology_pen

import topology_pen_session_helpers;
import http_client : getJson;
import drag_helpers : fetchCamera;
import fixture_helpers : requireProvenance;
import std.file : readText;
import std.algorithm : canFind;
import std.array : join;
import std.format : format;
import std.json;
import std.math : PI, abs, cos, round, sin, sqrt;
import drag_helpers : viewportFromCameraMatrices;
import std.path : buildPath, dirName;
import std.string : lastIndexOf;
import std.process : environment;
import std.stdio : writeln;

/// D source with every comment (`//`, `/* */`, nesting `/+ +/`) removed and
/// all whitespace dropped; string and character literals are kept verbatim so
/// a comment marker inside one is not taken for a comment.
string codeOnly(string s) {
    import std.ascii : isWhite;
    char[] o;
    size_t i;
    while (i < s.length) {
        const c = s[i];
        if (c == '"' || c == '\'' || c == '`') {
            const q = c;
            o ~= c; ++i;
            while (i < s.length && s[i] != q) {
                if (s[i] == '\\' && q != '`' && i + 1 < s.length) { o ~= s[i .. i + 2]; i += 2; continue; }
                o ~= s[i++];
            }
            if (i < s.length) o ~= s[i++];
        } else if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
            while (i < s.length && s[i] != '\n') ++i;
        } else if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
            i += 2;
            while (i + 1 < s.length && !(s[i] == '*' && s[i + 1] == '/')) ++i;
            i += 2;
        } else if (c == '/' && i + 1 < s.length && s[i + 1] == '+') {
            int depth = 1;
            i += 2;
            while (i + 1 < s.length && depth > 0) {
                if (s[i] == '/' && s[i + 1] == '+') { ++depth; i += 2; }
                else if (s[i] == '+' && s[i + 1] == '/') { --depth; i += 2; }
                else ++i;
            }
        } else {
            if (!isWhite(c)) o ~= c;
            ++i;
        }
    }
    return o.idup;
}

void main() {}

__gshared int cellsRun;

bool cell(string id) {
    const only = environment.get("VIBE3D_CELL", "");
    const on = only.length == 0 || only == id;
    if (on) ++cellsRun;
    return on;
}

JSONValue laws() {
    static JSONValue fx;
    static bool loaded;
    if (!loaded) {
        fx = parseJSON(import("fixtures/topology_pen_session_laws.json"));
        requireProvenance(fx, "topology_pen_session_laws");
        loaded = true;
    }
    return fx;
}

JSONValue cellFx(string id) { return laws()["cells"][id]; }

long[] idxOf(JSONValue a) {
    long[] r;
    foreach (x; a.array) r ~= x.integer;
    return r;
}

PenRig rig() {
    return penRigLoad(buildPath(dirName(__FILE_FULL_PATH__), "fixtures",
                                "topology_pen_session_rig.v3d"));
}

/// The standard Move gestures of the capture rig, in grid spacings (the capture
/// dragged 20,12 / -18,10 / 16,-14 px at a 66.8 px spacing).
enum double kSp = 66.8;
void moveV5(string what)  { penGesture(penVertexPx(5, what), 20 / kSp, 12 / kSp, 1, 0, what); }
void moveV10(string what) { penGesture(penVertexPx(10, what), -18 / kSp, 10 / kSp, 1, 0, what); }
void moveV6(string what)  { penGesture(penVertexPx(6, what), 16 / kSp, -14 / kSp, 1, 0, what); }

void expectState(string cellId, string step, const PenMesh want, bool armed, long hist) {
    const m = penMesh();
    assert(m == want && penArmed() == armed && penHistoryLen() == hist,
           format("%s %s: mesh %s (%s the expected %s), armed %s (expected %s), history %d "
                  ~ "(expected %d) %s", cellId, step, m.toString, m == want ? "==" : "!=",
                  want.toString, penArmed(), armed, penHistoryLen(), hist, penHistoryLabels()));
}

// ---------------------------------------------------------------------------
// arm-two-moves — L1: the UI-door activation is its own undo step.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("arm-two-moves")) return;
    auto fx = cellFx("arm-two-moves");
    const r = rig();
    penArmUi(r);
    assert(penHistoryLen() == r.hp + 1,
           format("arm-two-moves a0: the UI-door arm did not write its own row: %s", penHistoryLabels()));
    moveV5("arm-two-moves g1");
    const g1 = penMesh();
    moveV10("arm-two-moves g2");
    const g2 = penMesh();
    assert(penMoved(g1, r.a0) == idxOf(fx["moved"]["g1"]) && penMoved(g2, g1) == idxOf(fx["moved"]["g2"]),
           format("arm-two-moves: g1 moved %s (expected %s), g2 moved %s (expected %s)",
                  penIdx(penMoved(g1, r.a0)), fx["moved"]["g1"], penIdx(penMoved(g2, g1)),
                  fx["moved"]["g2"]));
    assert(penHistoryLen() == r.hp + 3,
           format("arm-two-moves: two gestures after the arm are not two rows: %s", penHistoryLabels()));
    // Task 8930: the pen is outside the captured topology model — its rows carry no
    // step origin / operation (published only for a classified row). Floor: the
    // arm row and the two gesture rows are read.
    size_t read;
    foreach (row; getJson("/api/history")["undo"].array) {
        assert("stepOrigin" !in row && "stepOperation" !in row,
               format("arm-two-moves: the pen row %s carries a step origin: %s", row["label"], row));
        ++read;
    }
    assert(read == r.hp + 3, format("arm-two-moves: read %s history rows, expected %s", read, r.hp + 3));
    const PenMesh[string] at = ["a0": r.a0, "g1": g1, "g2": g2];
    long hist = r.hp + 3;
    size_t n;
    foreach (row; fx["undo"].array) {
        penCtrlZ("arm-two-moves " ~ row["step"].str);
        --hist;
        expectState("arm-two-moves", row["step"].str, at[row["equals"].str],
                    row["armed"].type == JSONType.true_, hist);
        ++n;
    }
    assert(n == 3, "arm-two-moves: the fixture's undo walk is not three steps");
    writeln("PASS arm-two-moves");
}

// ---------------------------------------------------------------------------
// held-undo — L6: a Ctrl+Z pressed while a Move drag's button is held is
// dropped; the drag completes and two gesture rows are on the stack.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("held-undo")) return;
    auto fx = cellFx("held-undo");
    const r = rig();
    penArmUi(r);
    moveV5("held-undo g1");
    const g1 = penMesh();
    const from = penVertexPx(10, "held-undo g2");
    const step = 3 * penSpacingPx() / kSp;
    string log = penMotion(20, from[0], from[1], 0, 0) ~ "\n" ~ penButton(40, true, 1, from[0], from[1], 0) ~ "\n";
    int x = from[0], y = from[1];
    double t = 40;
    foreach (i; 1 .. 7) {
        t += 40;
        log ~= penMotion(t, from[0] + cast(int)(step * i), from[1] + cast(int)(step * i * 2 / 3), 1, 0) ~ "\n";
    }
    log ~= penKeyEvents(t + 20, PEN_SDLK_z, PEN_KMOD_LCTRL) ~ "\n";
    t += 60;
    foreach (i; 7 .. 13) {
        t += 40;
        x = from[0] + cast(int)(step * i);
        y = from[1] + cast(int)(step * i * 2 / 3);
        log ~= penMotion(t, x, y, 1, 0) ~ "\n";
    }
    log ~= penButton(t + 40, false, 1, x, y, 0);
    penPlay(log, "held-undo: drag with a Ctrl+Z inside the hold");
    const rel = penMesh();
    assert(penMoved(rel, g1) == idxOf(fx["moved"]["rel"])
           && penHistoryLen() == r.hp + 1 + fx["rowsAfterArm"].integer && penArmed(),
           format("held-undo: after the release moved %s (expected %s), history %s (expected %d rows "
                  ~ "after the arm), armed %s", penIdx(penMoved(rel, g1)), fx["moved"]["rel"],
                  penHistoryLabels(), fx["rowsAfterArm"].integer, penArmed()));
    const PenMesh[string] at = ["a0": r.a0, "g1": g1];
    long hist = r.hp + 3;
    size_t n;
    foreach (row; fx["undo"].array) {
        penCtrlZ("held-undo " ~ row["step"].str);
        expectState("held-undo", row["step"].str, at[row["equals"].str],
                    row["armed"].type == JSONType.true_, --hist);
        ++n;
    }
    assert(n == 2, format("held-undo: %d of the two undo steps ran", n));
    writeln("PASS held-undo");
}

// ---------------------------------------------------------------------------
// branch — L10: g1, g2, Ctrl+Z, g3: the next Ctrl+Z pops g3, the next g1.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("branch")) return;
    auto fx = cellFx("branch");
    const r = rig();
    penArmUi(r);
    moveV5("branch g1");
    const g1 = penMesh();
    moveV10("branch g2");
    penCtrlZ("branch z1");
    expectState("branch", "z1", g1, true, r.hp + 2);
    const z1 = penMesh();
    moveV6("branch g3");
    const g3 = penMesh();
    assert(penMoved(g3, z1) == idxOf(fx["moved"]["g3"]) && penHistoryLen() == r.hp + 3 && !penCanRedo(),
           format("branch g3: moved %s (expected %s), history %s, redo left %s",
                  penIdx(penMoved(g3, z1)), fx["moved"]["g3"], penHistoryLabels(), penCanRedo()));
    const PenMesh[string] at = ["a0": r.a0, "z1": z1];
    long hist = r.hp + 3;
    size_t n;
    foreach (row; fx["undo"].array) {
        penCtrlZ("branch " ~ row["step"].str);
        expectState("branch", row["step"].str, at[row["equals"].str], true, --hist);
        ++n;
    }
    assert(n == 2, format("branch: %d of the two undo steps ran", n));
    writeln("PASS branch");
}

// ---------------------------------------------------------------------------
// alt-chords — L12: no Alt chord reaches the pen.
// ---------------------------------------------------------------------------
int modOf(JSONValue mods) {
    int m;
    foreach (x; mods.array) {
        if (x.str == "alt") m |= PEN_KMOD_LALT;
        else if (x.str == "shift") m |= PEN_KMOD_LSHIFT;
        else if (x.str == "ctrl") m |= PEN_KMOD_LCTRL;
        else assert(false, "alt-chords: unknown modifier " ~ x.str);
    }
    return m;
}

unittest {
    if (!cell("alt-chords")) return;
    auto fx = cellFx("alt-chords");
    const r = rig();
    penArmUi(r);
    size_t n;
    foreach (c; fx["chords"].array) {
        const id = c["id"].str;
        const mod = modOf(c["mods"]);
        assert((mod & PEN_KMOD_LALT) != 0, "alt-chords: a chord without Alt: " ~ id);
        penResetCamera();
        penGesture(penVertexPx(5, id), 30 / kSp, 18 / kSp, cast(int)c["button"].integer, mod, id);
        expectState("alt-chords", id, r.a0, true, r.hp + 1);
        ++n;
    }
    assert(n == fx["population"].integer && n == 8,
           format("alt-chords: %d chords ran, the fixture lists %d", n, fx["population"].integer));
    // Positive control, below the eight: the same drag with no modifier does
    // reach the pen (so "unchanged" above was not an unreachable vertex).
    penResetCamera();
    penGesture(penVertexPx(5, "alt-chords control"), 30 / kSp, 18 / kSp, 1, 0, "alt-chords control");
    assert(penMoved(penMesh(), r.a0) == [5L] && penHistoryLen() == r.hp + 2,
           format("alt-chords control: the unmodified drag moved %s, history %s",
                  penIdx(penMoved(penMesh(), r.a0)), penHistoryLabels()));
    writeln("PASS alt-chords");
}

// ---------------------------------------------------------------------------
// smooth-loop-interior — L13 (interior): Shift+Ctrl+RMB on edge 5-6 moves
// exactly its loop's two interior vertices; plain Shift+Ctrl+LMB there moves
// all 16. One step each, undo bit-exact, the tool stays armed.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("smooth-loop-interior")) return;
    auto fx = cellFx("smooth-loop");
    enum SC = PEN_KMOD_LSHIFT | PEN_KMOD_LCTRL;
    const r = rig();
    penArmUi(r);
    const e = idxOf(fx["interior"]["edge"]);
    penTap(penEdgePx(e[0], e[1], "smooth-loop"), 3, SC, "Shift+Ctrl+RMB on the interior edge");
    const loopM = penMesh();
    assert(penMoved(loopM, r.a0) == idxOf(fx["interior"]["moved"]) && penHistoryLen() == r.hp + 2,
           format("smooth-loop-interior: Shift+Ctrl+RMB moved %s (expected %s), history %s",
                  penIdx(penMoved(loopM, r.a0)), fx["interior"]["moved"], penHistoryLabels()));
    penCtrlZ("smooth-loop-interior z1");
    expectState("smooth-loop-interior", "loop_z", r.a0, true, r.hp + 1);
    penTap(penEdgePx(e[0], e[1], "smooth"), 1, SC, "Shift+Ctrl+LMB on the interior edge");
    const plainM = penMesh();
    assert(penMoved(plainM, r.a0).length == fx["plainMovedCount"].integer && penHistoryLen() == r.hp + 2,
           format("smooth-loop-interior: plain smoothing moved %s (expected %d vertices), history %s",
                  penIdx(penMoved(plainM, r.a0)), fx["plainMovedCount"].integer, penHistoryLabels()));
    penCtrlZ("smooth-loop-interior z2");
    expectState("smooth-loop-interior", "plain_z", r.a0, true, r.hp + 1);
    writeln("PASS smooth-loop-interior");
}

// ---------------------------------------------------------------------------
// smooth-loop-border — L13 (border): Shift+Ctrl+RMB on border edge 0-1 gathers
// the 12-vertex perimeter and moves it EXCEPT its four face-valence-1 corners
// (slice S4, task 8680). One step, undo bit-exact, the tool stays armed.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("smooth-loop-border")) return;
    auto fx = cellFx("smooth-loop");
    const r = rig();
    penArmUi(r);
    const e = idxOf(fx["border"]["edge"]);
    penTap(penEdgePx(e[0], e[1], "border"), 3, PEN_KMOD_LSHIFT | PEN_KMOD_LCTRL,
           "Shift+Ctrl+RMB on the border edge");
    const m = penMesh();
    assert(penMoved(m, r.a0) == idxOf(fx["border"]["moved"]) && penHistoryLen() == r.hp + 2,
           format("smooth-loop-border: moved %s (expected %s), history %s",
                  penIdx(penMoved(m, r.a0)), fx["border"]["moved"], penHistoryLabels()));
    penCtrlZ("smooth-loop-border z1");
    expectState("smooth-loop-border", "border_z", r.a0, true, r.hp + 1);
    writeln("PASS smooth-loop-border");
}

// ---------------------------------------------------------------------------
// chords — L4: every chord that records today is exactly one Ctrl+Z step, undo
// is bit-exact and the tool stays armed. Narrowed by the wave plan (§9.14
// [A2-8]) to the five chords that record on this rig; the other three
// (corner build, vertex slide, interior split) diverge in OUTCOME and land as
// their port slices' `chord-*` cells. Remove's counts hold since slice 8710.
// ---------------------------------------------------------------------------
struct Chord { int btn; int mod; bool tap; double dx, dy; bool counts; }

int[2] chordFrom(string id) {
    switch (id) {
    case "dup_edge": return penEdgePx(0, 1, id);
    case "addloop":  return penEdgePx(5, 6, id);
    case "moveloop": return penEdgePx(5, 6, id);
    case "remove":   return penFacePx(0);
    case "smooth":   return penFacePx(4);
    default: assert(false, "chords: unknown gesture " ~ id);
    }
}

unittest {
    if (!cell("chords")) return;
    auto fx = cellFx("chords");
    enum S = PEN_KMOD_LSHIFT, C = PEN_KMOD_LCTRL;
    // `counts`: whether (nv, nf, ne) is asserted.
    const Chord[string] spec = [
        "dup_edge": Chord(1, S, false, 0, 36 / kSp, true),
        "addloop":  Chord(2, S, false, 10 / kSp, 0, true),
        "moveloop": Chord(3, 0, false, 0, -15 / kSp, true),
        "remove":   Chord(2, C, true, 0, 0, true),
        "smooth":   Chord(1, S | C, true, 0, 0, true),
    ];
    const r = rig();
    penArmUi(r);
    size_t n, counted, redone;
    foreach (g; fx["gestures"].array) {
        const id = g["id"].str;
        if (id !in spec) continue;
        const ch = spec[id];
        const from = chordFrom(id);
        if (ch.tap) penTap(from, ch.btn, ch.mod, id);
        else penGesture(from, ch.dx, ch.dy, ch.btn, ch.mod, id);
        const m = penMesh();
        const cnt = idxOf(g["counts"]);
        assert(m != r.a0 && penHistoryLen() == r.hp + 2,
               format("chords %s: mesh %s (changed %s), history %s (expected one row after the arm)",
                      id, m.toString, m != r.a0, penHistoryLabels()));
        if (ch.counts) {
            assert([m.nv, m.nf, m.edges] == cnt,
                   format("chords %s: counts %s (expected %s)", id, m.toString, cnt));
            ++counted;
        }
        if ("moved" in g.object)
            assert(penMoved(m, r.a0) == idxOf(g["moved"]),
                   format("chords %s: moved %s, expected %s", id, penIdx(penMoved(m, r.a0)), g["moved"]));
        penCtrlZ("chords " ~ id ~ " Ctrl+Z");
        expectState("chords", id ~ "_z", r.a0, g["undoArmed"].type == JSONType.true_, r.hp + 1);
        if ("redoBitExact" in g.object) {
            penCtrlShiftZ("chords " ~ id ~ " Ctrl+Shift+Z");
            expectState("chords", id ~ "_r", m, true, r.hp + 2);
            penCtrlZ("chords " ~ id ~ " Ctrl+Z again");
            expectState("chords", id ~ "_rz", r.a0, true, r.hp + 1);
            ++redone;
        }
        ++n;
    }
    // remove is the one chord here the fixture marks redo-bit-exact.
    assert(n == 5 && counted == 5 && redone == 1,
           format("chords: %d chords ran (expected 5), %d with counts (expected 5), %d redone "
                  ~ "(expected 1)", n, counted, redone));
    penCtrlZ("chords final Ctrl+Z");
    expectState("chords", "arm_z", r.a0, fx["finalUndoArmed"].type == JSONType.true_, r.hp);
    writeln("PASS chords");
}

// ---------------------------------------------------------------------------
// switch-away — L9 (z1..z3): g1, W (another tool), then three Ctrl+Z walk back
// through the switch, the gesture and the pen's activation. The redo walk
// (r1..r3) is slice S5's `switch-away-redo` (wave plan §9.14 [A2-9]).
// ---------------------------------------------------------------------------
unittest {
    if (!cell("switch-away")) return;
    auto fx = cellFx("switch-away");
    const r = rig();
    penArmUi(r);
    moveV5("switch-away g1");
    const g1 = penMesh();
    penKey(PEN_SDLK_w, 0, "switch-away W");
    const moveTool = penTool();
    assert(moveTool.length && moveTool != kPenToolId && penMesh() == g1,
           format("switch-away exit: W did not switch to another tool keeping g1: tool '%s', mesh %s",
                  moveTool, penMesh().toString));
    const PenMesh[string] at = ["a0": r.a0, "g1": g1];
    string[string] toolOf = ["pen": kPenToolId, "none": "", "move": moveTool];
    size_t n;
    foreach (row; fx["undo"].array) {
        const step = row["step"].str;
        penCtrlZ("switch-away " ~ step);
        const want = toolOf[row["tool"].str];
        assert(penMesh() == at[row["equals"].str] && penTool() == want,
               format("switch-away %s: mesh %s (expected %s = %s), tool '%s' (expected '%s'), "
                      ~ "history %s", step, penMesh().toString, row["equals"].str,
                      at[row["equals"].str].toString, penTool(), want, penHistoryLabels()));
        ++n;
    }
    assert(n == 3, format("switch-away: %d of the three undo steps ran", n));
    writeln("PASS switch-away");
}

// ---------------------------------------------------------------------------
// chord-split-interior — L4, port slice 8730 (task 8690): plain MMB from v5
// onto v10, an INTERIOR vertex of the quad (5, 6, 10, 9), splits that quad into
// the fixture's two triangles (vertex sets) at innerSnap's default; one row,
// undo and redo bit-exact, the tool stays armed.
// ---------------------------------------------------------------------------
long[][] faceSets(const PenMesh m) {
    import std.algorithm : sort;
    long[][] r;
    foreach (f; m.faces) { auto c = f.dup; sort(c); r ~= c; }
    sort(r);
    return r;
}

long[][] setDiff(long[][] a, long[][] b) {
    import std.algorithm : canFind;
    long[][] r;
    foreach (f; a) if (!b.canFind(f)) r ~= f;
    return r;
}

long[][] facesOf(JSONValue a) {
    long[][] r;
    foreach (f; a.array) r ~= idxOf(f);
    return r;
}

unittest {
    if (!cell("chord-split-interior")) return;
    JSONValue g;
    size_t found;
    foreach (x; cellFx("chords")["gestures"].array) if (x["id"].str == "split") { g = x; ++found; }
    assert(found == 1, format("chord-split-interior: %d split rows in the fixture, expected 1", found));
    const r = rig();
    penArmUi(r);
    const from = penVertexPx(5, "chord-split-interior v5");
    const to = penVertexPx(10, "chord-split-interior v10");
    penPlay(penGestureEvents(from[0], from[1], to[0], to[1], 2, 0, 8), "chord-split-interior MMB v5 -> v10");
    const m = penMesh();
    const gone = setDiff(faceSets(r.a0), faceSets(m)), born = setDiff(faceSets(m), faceSets(r.a0));
    assert([m.nv, m.nf, m.edges] == idxOf(g["counts"]) && penHistoryLen() == r.hp + 2
           && gone == facesOf(g["goneFaces"]) && born == facesOf(g["newFaces"])
           && penMoved(m, r.a0) == idxOf(g["moved"]),
           format("chord-split-interior: mesh %s (expected counts %s), faces gone %s (expected %s), "
                  ~ "born %s (expected %s), moved %s, history %s", m.toString, g["counts"], gone,
                  g["goneFaces"], born, g["newFaces"], penIdx(penMoved(m, r.a0)), penHistoryLabels()));
    penCtrlZ("chord-split-interior Ctrl+Z");
    expectState("chord-split-interior", "split_z", r.a0, g["undoArmed"].type == JSONType.true_, r.hp + 1);
    assert(g["redoBitExact"].type == JSONType.true_, "chord-split-interior: the fixture's split is redo-bit-exact");
    penCtrlShiftZ("chord-split-interior Ctrl+Shift+Z");
    expectState("chord-split-interior", "split_r", m, true, r.hp + 2);
    penCtrlZ("chord-split-interior Ctrl+Z again");
    expectState("chord-split-interior", "split_rz", r.a0, true, r.hp + 1);
    writeln("PASS chord-split-interior");
}

// ---------------------------------------------------------------------------
// chord-remove-* — L35 (slice 8710): Ctrl+MMB on a face removes it with exactly
// the vertices and edges it leaves with no polygon, and nothing else. corner:
// f0 (v0 and edges 0-1, 0-4 go); border: f1 (no vertex is orphaned, the border
// edge 1-2 goes); leaves-loose: f0 again after the pen placed a point that is
// in no polygon and drew a bare wire edge elsewhere: both stay. Each: one row,
// the survivors keep their positions in order, Ctrl+Z is bit-exact and the tool
// stays armed.
// ---------------------------------------------------------------------------

/// Remove face `c["face"]` of `r.a0` with Ctrl+MMB (the pen armed) and check
/// the law. `bareEdgeFaces`: faces the capture counted that our rig holds as
/// a wire edge instead (the leaves-loose rig's bare edge).
void removeCase(string cellId, JSONValue c, const PenRig r) {
    const f = c["face"].integer;
    const long bare = ("bareEdgeFaces" in c.object) ? c["bareEdgeFaces"].integer : 0;
    long[] ours(JSONValue n) { auto x = idxOf(n); x[1] -= bare; return x; }
    assert(r.a0.faces[cast(size_t)f] == idxOf(c["removedFace"])
           && [r.a0.nv, r.a0.nf, r.a0.edges] == ours(c["before"]),
           format("%s rig: face %d is %s (expected %s), mesh %s (expected %s)", cellId, f,
                  r.a0.faces[cast(size_t)f], c["removedFace"], r.a0.toString, ours(c["before"])));
    penTap(penFacePx(f), 2, PEN_KMOD_LCTRL, cellId);
    const m = penMesh();
    assert([m.nv, m.nf, m.edges] == ours(c["after"]) && penHistoryLen() == r.hp + 1,
           format("%s: counts %s (expected %s), history %s (expected one row after the rig)",
                  cellId, m.toString, ours(c["after"]), penHistoryLabels()));
    // The expected mesh, from OUR a0: the survivors in order, the other faces
    // renumbered onto them.
    const surv = idxOf(c["survivors"]);
    long[long] newOf;
    PenMesh want;
    foreach (i, o; surv) { newOf[o] = cast(long)i; want.pos ~= r.a0.pos[cast(size_t)o]; }
    foreach (fi, face; r.a0.faces) {
        if (fi == f) continue;
        long[] nf;
        foreach (v; face) nf ~= newOf[v];
        want.faces ~= nf;
    }
    want.edges = m.edges;
    assert(m == want, format("%s: the survivors or the faces differ: faces %s (expected %s)",
                             cellId, m.faces, want.faces));
    penCtrlZ(cellId ~ " Ctrl+Z");
    expectState(cellId, "z1", r.a0, c["undoArmed"].type == JSONType.true_, r.hp);
}

/// The grid rig armed through the UI door; `hp` counts the activation row.
PenRig armedRig() {
    PenRig r = rig();
    penArmUi(r);
    assert(penHistoryLen() == r.hp + 1,
           format("chord-remove: the UI-door arm did not write its own row: %s", penHistoryLabels()));
    r.hp = penHistoryLen();
    return r;
}

unittest {
    if (!cell("chord-remove-corner")) return;
    removeCase("chord-remove-corner", cellFx("chord-remove-corner"), armedRig());
    writeln("PASS chord-remove-corner");
}

unittest {
    if (!cell("chord-remove-border")) return;
    removeCase("chord-remove-border", cellFx("chord-remove-border"), armedRig());
    writeln("PASS chord-remove-border");
}

unittest {
    if (!cell("chord-remove-leaves-loose")) return;
    enum id = "chord-remove-leaves-loose";
    auto c = cellFx(id);
    PenRig r = armedRig();
    // The rig, with the pen's own gestures: a Point-mode click places the
    // loose point (16) and a second point (17); a Shift+LMB drag from 17
    // duplicates it into the bare wire edge (17, 18).
    double[3] pt(string k) {
        auto a = c["rigPoints"][k].array;
        return [penNum(a[0]), penNum(a[1]), penNum(a[2])];
    }
    {
        auto a = penPost("/api/command", "tool.attr mesh.topoPen mode point");
        assert(a["status"].str == "ok", id ~ " rig: mode point refused: " ~ a.toString);
    }
    penTap(penRound(penProject(pt("loose"))), 1, 0, id ~ " place the loose point");
    penTap(penRound(penProject(pt("bareFrom"))), 1, 0, id ~ " place the bare edge's first point");
    const from = penVertexPx(17, id ~ " bare edge");
    const to = penRound(penProject(pt("bareTo")));
    const sp = penSpacingPx();
    penGesture(from, (to[0] - from[0]) / sp, (to[1] - from[1]) / sp, 1, PEN_KMOD_LSHIFT,
               id ~ " duplicate drag");
    {
        auto a = penPost("/api/command", "tool.attr mesh.topoPen mode move");
        assert(a["status"].str == "ok", id ~ " rig: mode move refused: " ~ a.toString);
    }
    r.a0 = penMesh();
    r.hp = penHistoryLen();
    // Floors (the capture's precondition): 16 is in no polygon and on no edge,
    // (17, 18) is an edge no polygon holds.
    bool onFace(long v) { foreach (face; r.a0.faces) foreach (x; face) if (x == v) return true; return false; }
    bool onEdge(long v) {
        foreach (e; getJson("/api/model")["edges"].array)
            if (e.array[0].integer == v || e.array[1].integer == v) return true;
        return false;
    }
    assert(r.a0.nv == 19 && !onFace(16) && !onEdge(16) && penEdgeId(17, 18) >= 0
           && !onFace(17) && !onFace(18) && penArmed(),
           format("%s rig: mesh %s, vertex 16 on a face %s / an edge %s, edge (17,18) id %d, "
                  ~ "17/18 on a face %s/%s, armed %s", id, r.a0.toString, onFace(16), onEdge(16),
                  penEdgeId(17, 18), onFace(17), onFace(18), penArmed()));
    removeCase(id, c, r);
    writeln("PASS ", id);
}

// ===========================================================================
// Slice S5 (task 8730, wave plan 8646): every pen press is one topology step.
// ===========================================================================

/// The pixel of a named rig element ("v5", "e56", ...): one digit per index.
int[2] elementPx(string at, string what) {
    import std.conv : to;
    if (at[0] == 'v') return penVertexPx(at[1 .. $].to!long, what);
    assert(at[0] == 'e' && at.length == 3, "elementPx: unknown element " ~ at);
    return penEdgePx(at[1 .. 2].to!long, at[2 .. 3].to!long, what);
}

/// An interactive (panel-origin) attribute write on the armed pen.
void penAttrInteractive(string attr, string value) {
    auto r = penPost("/api/script?interactive=true",
                     "tool.attr " ~ kPenToolId ~ " " ~ attr ~ " " ~ value);
    assert(r["status"].str == "ok", "interactive write " ~ attr ~ " " ~ value ~ " failed: "
                                    ~ r.toString);
}

/// The pen's current value of `attr`, as the attribute query answers it.
string penAttr(string attr) {
    auto r = penPost("/api/command", "tool.attr " ~ kPenToolId ~ " " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "attribute query " ~ attr ~ " failed: " ~ r.toString);
    return r["value"].toString;
}

string topLabel() {
    const l = penHistoryLabels();
    return l.length ? l[$ - 1] : "";
}

// ---------------------------------------------------------------------------
// no-op-presses — L5 (fixture: K-noop): a motionless click on v5, a click on
// empty background and a zero-length drag on v10 each add one step with the
// mesh bit-identical to a0; Ctrl+Z pops one and the pen stays armed. The click
// on v5 is also the motionless-vertex-click law: it applies NOTHING.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("no-op-presses")) return;
    auto fx = cellFx("no-op-presses");
    const r = rig();
    penArmUi(r);
    penTap(penVertexPx(5, "no-op-presses v5"), 1, 0, "no-op-presses tap v5");
    expectState("no-op-presses", "tap_v", r.a0, true, r.hp + 2);
    penTap(penEmptyBackgroundPx(), 1, 0, "no-op-presses tap empty background");
    expectState("no-op-presses", "tap_bg", r.a0, true, r.hp + 3);
    const v10 = penVertexPx(10, "no-op-presses v10");
    string log = penMotion(20, v10[0], v10[1], 0, 0) ~ "\n" ~ penButton(40, true, 1, v10[0], v10[1], 0) ~ "\n";
    foreach (i; 0 .. 4) log ~= penMotion(80 + 40 * i, v10[0], v10[1], 1, 0) ~ "\n";
    log ~= penButton(300, false, 1, v10[0], v10[1], 0);
    penPlay(log, "no-op-presses zero-length drag on v10");
    expectState("no-op-presses", "zero_drag", r.a0, true, r.hp + 4);
    assert(fx["presses"].array.length == 3 && fx["rowsAdded"].integer == 3,
           "no-op-presses: the fixture's three presses add three rows");
    penCtrlZ("no-op-presses z1");
    expectState("no-op-presses", "z1", r.a0, fx["undoArmed"].type == JSONType.true_, r.hp + 3);
    writeln("PASS no-op-presses");
}

// ---------------------------------------------------------------------------
// no-op-chord-clicks — L5 (fixture: the nine motionless chord clicks): each is
// one step; the seven the capture shows editing nothing leave the mesh
// bit-identical, the Shift+MMB (a loop cut) and Shift+Ctrl+RMB (a loop
// smooth) clicks edit it.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("no-op-chord-clicks")) return;
    auto fx = cellFx("no-op-chord-clicks");
    const r = rig();
    penArmUi(r);
    long hist = r.hp + 1;
    size_t n, unchanged;
    // Every pixel is taken on a0, as the capture aimed: after the loop cut the
    // edge (5, 6) no longer exists, and the clicks after it hit the same pixel.
    int[2][string] px;
    foreach (c; fx["clicks"].array)
        if (c["at"].str !in px) px[c["at"].str] = elementPx(c["at"].str, "no-op-chord-clicks a0");
    foreach (c; fx["clicks"].array) {
        const id = "no-op-chord-clicks " ~ c["id"].str;
        const before = penMesh();
        penTap(px[c["at"].str], cast(int)c["button"].integer, modOf(c["mods"]), id);
        const m = penMesh();
        const same = c["meshUnchanged"].type == JSONType.true_;
        assert(penHistoryLen() == ++hist && penArmed() && (m == before) == same,
               format("%s: history %s (expected %d rows), armed %s, mesh %s the one before "
                      ~ "(the capture: %s)", id, penHistoryLabels(), hist, penArmed(),
                      m == before ? "==" : "!=", same ? "unchanged" : "changed"));
        if (same) ++unchanged;
        ++n;
    }
    assert(n == 9 && unchanged == 7 && fx["population"].integer == 9 && fx["rowsAdded"].integer == 9,
           format("no-op-chord-clicks: %d clicks ran (9), %d unchanged (7)", n, unchanged));
    writeln("PASS no-op-chord-clicks");
}

// ---------------------------------------------------------------------------
// redo-rearm — L2: arm, two moves, three Ctrl+Z (the pen dropped), then three
// Ctrl+Shift+Z: r1 re-arms the pen at a0, r2 is g1, r3 is g2, armed throughout.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("redo-rearm")) return;
    auto fx = cellFx("arm-two-moves");
    const r = rig();
    penArmUi(r);
    moveV5("redo-rearm g1");
    const g1 = penMesh();
    moveV10("redo-rearm g2");
    const g2 = penMesh();
    foreach (z; ["z1", "z2", "z3"]) penCtrlZ("redo-rearm " ~ z);
    expectState("redo-rearm", "z3", r.a0, false, r.hp);
    const PenMesh[string] at = ["a0": r.a0, "g1": g1, "g2": g2];
    long hist = r.hp;
    size_t n;
    foreach (row; fx["redo"].array) {
        penCtrlShiftZ("redo-rearm " ~ row["step"].str);
        expectState("redo-rearm", row["step"].str, at[row["equals"].str],
                    row["armed"].type == JSONType.true_, ++hist);
        ++n;
    }
    assert(n == 3, format("redo-rearm: %d of the three redo steps ran", n));
    writeln("PASS redo-rearm");
}

// ---------------------------------------------------------------------------
// switch-away-redo — L9 (r1..r3): after switch-away's three Ctrl+Z, three
// Ctrl+Shift+Z: the pen re-armed at a0, g1, then the other tool re-armed with
// the mesh at g1 (the switch's own redo survives its undo).
// ---------------------------------------------------------------------------
unittest {
    if (!cell("switch-away-redo")) return;
    auto fx = cellFx("switch-away");
    const r = rig();
    penArmUi(r);
    moveV5("switch-away-redo g1");
    const g1 = penMesh();
    penKey(PEN_SDLK_w, 0, "switch-away-redo W");
    const moveTool = penTool();
    assert(moveTool.length && moveTool != kPenToolId && penMesh() == g1,
           format("switch-away-redo exit: W did not switch tools keeping g1: '%s'", moveTool));
    foreach (z; ["z1", "z2", "z3"]) penCtrlZ("switch-away-redo " ~ z);
    assert(penTool() == "" && penMesh() == r.a0,
           format("switch-away-redo z3: tool '%s', mesh %s", penTool(), penMesh().toString));
    const PenMesh[string] at = ["a0": r.a0, "g1": g1];
    string[string] toolOf = ["pen": kPenToolId, "none": "", "move": moveTool];
    size_t n;
    foreach (row; fx["redo"].array) {
        const step = row["step"].str;
        penCtrlShiftZ("switch-away-redo " ~ step);
        const want = toolOf[row["tool"].str];
        assert(penMesh() == at[row["equals"].str] && penTool() == want,
               format("switch-away-redo %s: mesh %s (expected %s), tool '%s' (expected '%s'), "
                      ~ "history %s", step, penMesh().toString, row["equals"].str, penTool(),
                      want, penHistoryLabels()));
        ++n;
    }
    assert(n == 3, format("switch-away-redo: %d of the three redo steps ran", n));
    writeln("PASS switch-away-redo");
}

// ---------------------------------------------------------------------------
// drop-mid-drag — the salvage (wave plan 8646 §4.5): a drop through the UI
// door while a Move drag is held records that press as ONE row with the mesh
// as it stands, and the drop row (S6) lands ABOVE it: Ctrl+Z re-arms the pen
// with the moved mesh kept (L8, our divergence), the next restores a0.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("drop-mid-drag")) return;
    const r = rig();
    penArmUi(r);
    const from = penVertexPx(5, "drop-mid-drag v5");
    const step = penSpacingPx() / kSp;
    string log = penMotion(20, from[0], from[1], 0, 0) ~ "\n" ~ penButton(40, true, 1, from[0], from[1], 0) ~ "\n";
    int x = from[0], y = from[1];
    foreach (i; 1 .. 7) {
        x = from[0] + cast(int)(20 * step * i / 6);
        y = from[1] + cast(int)(12 * step * i / 6);
        log ~= penMotion(40 + 40 * i, x, y, 1, 0) ~ "\n";
    }
    penPlay(log, "drop-mid-drag: held drag on v5");
    const held = penMesh();
    assert(penMoved(held, r.a0) == [5L] && penHistoryLen() == r.hp + 1,
           format("drop-mid-drag rig: the held drag moved %s, history %s",
                  penIdx(penMoved(held, r.a0)), penHistoryLabels()));
    penLineUi("tool.set " ~ kPenToolId ~ " off");
    penPlay(penButton(20, false, 1, x, y, 0), "drop-mid-drag: release after the drop");
    const labels = penHistoryLabels();
    assert(!penArmed() && penMesh() == held && penHistoryLen() == r.hp + 3
           && labels[$ - 2 .. $] == ["Topology Move", "Tool Drop"],
           format("drop-mid-drag: the drop must record the held press as one Move row below the "
                  ~ "drop row: armed %s, mesh %s the held one, history %s", penArmed(),
                  penMesh() == held ? "==" : "!=", labels));
    penCtrlZ("drop-mid-drag z1");
    assert(penMesh() == r.a0 && penArmed() && penHistoryLen() == r.hp + 2,
           format("drop-mid-drag z1: mesh %s the held one, armed %s (expected re-armed), history %s",
                  penMesh() == held ? "==" : "!=", penArmed(), penHistoryLabels()));
    penCtrlZ("drop-mid-drag z2");
    assert(penMesh() == r.a0 && penArmed() && penHistoryLen() == r.hp + 1,
           format("drop-mid-drag z2: mesh %s (expected a0), armed %s, history %s",
                  penMesh().toString, penArmed(), penHistoryLabels()));
    writeln("PASS drop-mid-drag");
}

// ---------------------------------------------------------------------------
// param-write-* — L14 (fixture: three attribute captures): an interactive
// write on the armed pen is its own row, before a press or after one, and its
// undo restores the prior value (wave plan 8646 §9.5; `attr` carrier).
// ---------------------------------------------------------------------------
unittest {
    if (!cell("param-write-idle")) return;
    auto fx = cellFx("param-write-idle");
    const r = rig();
    penArmUi(r);
    penAttrInteractive(fx["attr"].str, fx["value"].str);
    // The read-back FIRST: a write whose step closed with no carrier is
    // reverted on the spot.
    assert(penAttr(fx["attr"].str) == `"` ~ fx["value"].str ~ `"`,
           "param-write-idle: the write was reverted: " ~ penAttr(fx["attr"].str));
    assert(penHistoryLen() == r.hp + 2 && topLabel() == "Topology Attribute" && penMesh() == r.a0,
           format("param-write-idle: the write is not one row: %s", penHistoryLabels()));
    penCtrlZ("param-write-idle z1");
    assert(penAttr(fx["attr"].str) == `"` ~ fx["prior"].str ~ `"`
           && penArmed() == (fx["z1Armed"].type == JSONType.true_),
           format("param-write-idle z1: %s = %s, armed %s", fx["attr"].str,
                  penAttr(fx["attr"].str), penArmed()));
    penCtrlZ("param-write-idle z2");
    assert(penArmed() == (fx["z2Armed"].type == JSONType.true_),
           format("param-write-idle z2: armed %s", penArmed()));
    writeln("PASS param-write-idle");
}

unittest {
    if (!cell("param-write-post-press")) return;
    auto fx = cellFx("param-write-post-press");
    const r = rig();
    penArmUi(r);
    moveV5("param-write-post-press g1");
    const g1 = penMesh();
    penAttrInteractive(fx["attr"].str, "true");
    // The row is the attribute's, not the press's that came before it.
    assert(topLabel() == "Topology Attribute",
           "param-write-post-press w1: the row after a press is labelled " ~ topLabel());
    assert(penAttr(fx["attr"].str) == "true" && penMesh() == g1 && penHistoryLen() == r.hp + 3,
           format("param-write-post-press w1: %s = %s, mesh %s g1, history %s", fx["attr"].str,
                  penAttr(fx["attr"].str), penMesh() == g1 ? "==" : "!=", penHistoryLabels()));
    penCtrlZ("param-write-post-press z1");
    assert(penAttr(fx["attr"].str) == "false" && penMesh() == g1 && penArmed(),
           format("param-write-post-press z1: %s = %s, mesh %s g1, armed %s", fx["attr"].str,
                  penAttr(fx["attr"].str), penMesh() == g1 ? "==" : "!=", penArmed()));
    penCtrlZ("param-write-post-press z2");
    expectState("param-write-post-press", "z2", r.a0, fx["z2Armed"].type == JSONType.true_, r.hp + 1);
    writeln("PASS param-write-post-press");
}

unittest {
    if (!cell("param-write-show")) return;
    auto fx = cellFx("param-write-show");
    const r = rig();
    penArmUi(r);
    penAttrInteractive(fx["attr"].str, "false");
    assert(penAttr(fx["attr"].str) == "false" && penHistoryLen() == r.hp + 2,
           format("param-write-show w1: %s = %s, history %s", fx["attr"].str,
                  penAttr(fx["attr"].str), penHistoryLabels()));
    penCtrlZ("param-write-show z1");
    assert(penAttr(fx["attr"].str) == "true" && penArmed() == (fx["z1Armed"].type == JSONType.true_),
           format("param-write-show z1: %s = %s, armed %s", fx["attr"].str,
                  penAttr(fx["attr"].str), penArmed()));
    writeln("PASS param-write-show");
}

// ---------------------------------------------------------------------------
// split-*-row — L40 (fixture: the three refused-split captures): an MMB split
// from v5 released on a vertex sharing no polygon (v15), on an adjacent corner
// (v6) or on empty background is ONE step with the mesh unchanged; Ctrl+Z pops
// it (armed), the next pops the activation.
// ---------------------------------------------------------------------------
void splitRowCase(string id) {
    auto fx = cellFx(id);
    const r = rig();
    penArmUi(r);
    const from = elementPx(fx["from"].str, id);
    const rel = fx["release"].str;
    const int[2] to = rel == "empty" ? penEmptyBackgroundPx() : elementPx(rel, id);
    if (rel == "empty") {
        // The release must be clear of every vertex by more than the snap gather
        // radius (40 px nominal, `SnapPacket.outerRangePx`), or this is a split
        // with a target, not an empty release.
        import std.math : hypot;
        double nearest = double.max;
        foreach (v; 0 .. 16) {
            const p = penVertexPx(v, id ~ " floor");
            const d = hypot(cast(double)(p[0] - to[0]), cast(double)(p[1] - to[1]));
            if (d < nearest) nearest = d;
        }
        assert(nearest > 40, format("%s rig: the empty release is %.1f px from a vertex", id, nearest));
    }
    penPlay(penGestureEvents(from[0], from[1], to[0], to[1], 2, 0, 8), id ~ " MMB");
    assert(fx["meshUnchanged"].type == JSONType.true_ && fx["rowsAdded"].integer == 1,
           id ~ ": the fixture's refused split changes nothing and adds one row");
    expectState(id, "g1", r.a0, true, r.hp + 2);
    penCtrlZ(id ~ " z1");
    expectState(id, "z1", r.a0, fx["z1Armed"].type == JSONType.true_, r.hp + 1);
    penCtrlZ(id ~ " z2");
    expectState(id, "z2", r.a0, fx["z2Armed"].type == JSONType.true_, r.hp);
}

unittest {
    if (!cell("split-far-row")) return;
    splitRowCase("split-far-row");
    writeln("PASS split-far-row");
}

unittest {
    if (!cell("split-adjacent-row")) return;
    splitRowCase("split-adjacent-row");
    writeln("PASS split-adjacent-row");
}

unittest {
    if (!cell("split-empty-release")) return;
    splitRowCase("split-empty-release");
    writeln("PASS split-empty-release");
}

// ---------------------------------------------------------------------------
// remove-edge-noop-row — L5 for the Remove chord: a Ctrl+MMB press latched on
// the BORDER edge e01 (no edge to dissolve: it has one polygon) changes
// nothing and is still one step, through the chord's default carrier (wave
// plan 8646 §9.19.6: the edge primitive no longer restores-and-returns).
// ---------------------------------------------------------------------------
unittest {
    if (!cell("remove-edge-noop-row")) return;
    const r = rig();
    penArmUi(r);
    penTap(penEdgePx(0, 1, "remove-edge-noop-row e01"), 2, PEN_KMOD_LCTRL, "remove-edge-noop-row");
    expectState("remove-edge-noop-row", "g1", r.a0, true, r.hp + 2);
    assert(topLabel() == "Topology Remove",
           "remove-edge-noop-row: the row's label is " ~ topLabel());
    penCtrlZ("remove-edge-noop-row z1");
    expectState("remove-edge-noop-row", "z1", r.a0, true, r.hp + 1);
    writeln("PASS remove-edge-noop-row");
}

// ---------------------------------------------------------------------------
// fill-refusal-move — the carrier is the handler's, decided at its ARM (wave
// plan 8646 [R2-4]): in Fill mode a press on the border edge e01, where the
// ring gate refuses, grabs that edge as a Move. A 12-step drag is one row
// labelled Topology Move with the edge's two vertices moved; the motionless
// twin of the same press is one row, also Topology Move, mesh unchanged.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("fill-refusal-move")) return;
    const r = rig();
    penArmUi(r);
    {
        auto a = penPost("/api/command", "tool.attr " ~ kPenToolId ~ " mode fill");
        assert(a["status"].str == "ok", "fill-refusal-move rig: mode fill refused: " ~ a.toString);
    }
    const e01 = penEdgePx(0, 1, "fill-refusal-move e01");
    penTap(e01, 1, 0, "fill-refusal-move motionless twin");
    expectState("fill-refusal-move", "tap", r.a0, true, r.hp + 2);
    assert(topLabel() == "Topology Move",
           "fill-refusal-move: the motionless refusal's row is " ~ topLabel());
    penGesture(e01, 0, -15 / kSp, 1, 0, "fill-refusal-move drag", 12);
    const m = penMesh();
    assert(penMoved(m, r.a0) == [0L, 1L] && penHistoryLen() == r.hp + 3
           && topLabel() == "Topology Move",
           format("fill-refusal-move: the drag moved %s (expected [0,1]), history %s",
                  penIdx(penMoved(m, r.a0)), penHistoryLabels()));
    penCtrlZ("fill-refusal-move z1");
    expectState("fill-refusal-move", "z1", r.a0, true, r.hp + 2);
    {
        auto a = penPost("/api/command", "tool.attr " ~ kPenToolId ~ " mode move");
        assert(a["status"].str == "ok", "fill-refusal-move: mode move refused: " ~ a.toString);
    }
    writeln("PASS fill-refusal-move");
}

// ---------------------------------------------------------------------------
// rmb-press-block — every bound chord press is the pen's (wave plan 8646 §1.2
// M-F): an RMB drag that starts on empty background is one no-op step and
// never reaches the application's region selection, which it did while a
// declined press passed through.
// ---------------------------------------------------------------------------
unittest {
    if (!cell("rmb-press-block")) return;
    const r = rig();
    penArmUi(r);
    const from = penEmptyBackgroundPx();
    const far = penVertexPx(15, "rmb-press-block v15");
    penPlay(penGestureEvents(from[0], from[1], far[0] + 20, far[1] - 20, 3, 0, 8),
            "rmb-press-block RMB drag across the grid");
    auto sel = getJson("/api/selection");
    size_t picked;
    foreach (k; ["selectedVertices", "selectedEdges", "selectedFaces"])
        if (k in sel.object) picked += sel[k].array.length;
    assert(picked == 0 && penMesh() == r.a0 && penHistoryLen() == r.hp + 2 && penArmed(),
           format("rmb-press-block: %d elements selected, mesh %s a0, history %s, armed %s",
                  picked, penMesh() == r.a0 ? "==" : "!=", penHistoryLabels(), penArmed()));
    writeln("PASS rmb-press-block");
}

// ---------------------------------------------------------------------------
// Overlapping pen buttons — L56 (C4-two-button / -rev; wave plan §9.26.1 and
// §9.27 [A15-1]): a second press while the first button is held ends the
// first gesture and opens its OWN step, so there are two rows in both release
// orders. The LMB press on e56 arms an edge Move ("Topology Move", unchanged:
// it never moves); the Shift+MMB press on the same pixel arms Add Loop, whose
// row keeps the chord's label "Topology Add Loop" whether it commits (rev) or
// is discarded (fwd). Each handler's own label, last row on top.
// ---------------------------------------------------------------------------

/// LMB press on `at`, then Shift+MMB press on the same pixel (no motion).
string twoButtonPresses(int[2] at) {
    return penMotion(20, at[0], at[1], 0, 0) ~ "\n"
         ~ penButton(40, true, 1, at[0], at[1], 0) ~ "\n"
         ~ penMotion(60, at[0], at[1], penButtonMask(1), PEN_KMOD_LSHIFT) ~ "\n"
         ~ penButton(80, true, 2, at[0], at[1], PEN_KMOD_LSHIFT);
}

void expectTopLabels(string id, string[] want) {
    const l = penHistoryLabels();
    assert(l.length >= want.length && l[$ - want.length .. $] == want,
           format("%s: the top rows are %s, expected %s", id, l, want));
}

// two-button-rev — the S5 review repro: release LMB first, then MMB. The loop
// lands on its own row; undo/redo keep it.
unittest {
    if (!cell("two-button-rev")) return;
    const r = rig();
    penArmUi(r);
    const at = penEdgePx(5, 6, "two-button-rev e56");
    penPlay(twoButtonPresses(at) ~ "\n"
            ~ penButton(100, false, 1, at[0], at[1], PEN_KMOD_LSHIFT) ~ "\n"
            ~ penButton(120, false, 2, at[0], at[1], PEN_KMOD_LSHIFT), "two-button-rev gesture");
    const g = penMesh();
    assert(penHistoryLen() == r.hp + 3 && g.nv == 20 && g.nf == 12 && g.edges == 31 && penArmed(),
           format("two-button-rev: history %s (expected arm + 2 rows), mesh %s (expected nv 20, "
                  ~ "nf 12, ne 31)", penHistoryLabels(), g.toString));
    expectTopLabels("two-button-rev", ["Topology Move", "Topology Add Loop"]);
    penCtrlZ("two-button-rev z1");
    expectState("two-button-rev", "z1 (the loop's row)", r.a0, true, r.hp + 2);
    penCtrlShiftZ("two-button-rev r1");
    expectState("two-button-rev", "r1", g, true, r.hp + 3);
    penCtrlZ("two-button-rev z1'");
    penCtrlZ("two-button-rev z2 (the LMB row)");
    expectState("two-button-rev", "z2", r.a0, true, r.hp + 1);
    penCtrlZ("two-button-rev z3 (the activation)");
    expectState("two-button-rev", "z3", r.a0, false, r.hp);
    writeln("PASS two-button-rev");
}

// two-button-fwd — release MMB first while LMB is still held, then LMB: the
// MMB row is written but its loop is discarded; LMB's release is inert.
unittest {
    if (!cell("two-button-fwd")) return;
    const r = rig();
    penArmUi(r);
    const at = penEdgePx(5, 6, "two-button-fwd e56");
    penPlay(twoButtonPresses(at) ~ "\n"
            ~ penButton(100, false, 2, at[0], at[1], PEN_KMOD_LSHIFT) ~ "\n"
            ~ penButton(120, false, 1, at[0], at[1], 0), "two-button-fwd gesture");
    expectState("two-button-fwd", "g", r.a0, true, r.hp + 3);
    expectTopLabels("two-button-fwd", ["Topology Move", "Topology Add Loop"]);
    penCtrlZ("two-button-fwd z1 (the MMB row)");
    expectState("two-button-fwd", "z1", r.a0, true, r.hp + 2);
    penCtrlZ("two-button-fwd z2 (the LMB row)");
    expectState("two-button-fwd", "z2", r.a0, true, r.hp + 1);
    penCtrlZ("two-button-fwd z3 (the activation)");
    expectState("two-button-fwd", "z3", r.a0, false, r.hp);
    writeln("PASS two-button-fwd");
}

// two-button-cut-move — wave plan §9.27 [A15-2]: a Move on v5 is CUT by a
// Shift+MMB press on e9-10; 40 px of held motion after it must not move v5
// (the Move is disarmed). LMB is released first (inert), so MMB's release
// commits with nothing held and keeps whatever the motion did: v5 must still
// be where the second press found it. Two rows.
unittest {
    if (!cell("two-button-cut-move")) return;
    const r = rig();
    penArmUi(r);
    const v5 = penVertexPx(5, "two-button-cut-move v5");
    const e = penEdgePx(9, 10, "two-button-cut-move e9-10");
    penPlay(penMotion(20, v5[0], v5[1], 0, 0) ~ "\n" ~ penButton(40, true, 1, v5[0], v5[1], 0) ~ "\n"
            ~ penButton(60, true, 2, e[0], e[1], PEN_KMOD_LSHIFT), "two-button-cut-move presses");
    const atSecond = penMesh();
    assert(penHistoryLen() == r.hp + 2 && atSecond == r.a0,
           format("two-button-cut-move: the second press must close the motionless Move as one "
                  ~ "row: history %s, mesh %s a0", penHistoryLabels(), atSecond == r.a0 ? "==" : "!="));
    string log;
    foreach (i; 1 .. 9)
        log ~= penMotion(60 + 20 * i, e[0] + 5 * i, e[1], penButtonMask(1) | penButtonMask(2),
                         PEN_KMOD_LSHIFT) ~ "\n";
    penPlay(log[0 .. $ - 1], "two-button-cut-move 40 px held motion");
    const ex = e[0] + 40;
    penPlay(penButton(20, false, 1, ex, e[1], PEN_KMOD_LSHIFT) ~ "\n"
            ~ penButton(40, false, 2, ex, e[1], PEN_KMOD_LSHIFT), "two-button-cut-move releases");
    const m = penMesh();
    assert(m.pos[5] == atSecond.pos[5] && penHistoryLen() == r.hp + 3 && penArmed(),
           format("two-button-cut-move: v5 %s (at the second press %s), history %s", m.pos[5],
                  atSecond.pos[5], penHistoryLabels()));
    expectTopLabels("two-button-cut-move", ["Topology Move", "Topology Add Loop"]);
    writeln("PASS two-button-cut-move");
}

// two-button-discard-move — the release-time discard (§9.27 [A15-1]): with
// Shift+MMB held on e56, an LMB Move drag of v5 opens its own step (the MMB
// one closes unchanged); LMB released while MMB is still held throws the drag
// away — v5 comes back to the step's open image — and records an unchanged
// row; MMB's release is inert.
unittest {
    if (!cell("two-button-discard-move")) return;
    const r = rig();
    penArmUi(r);
    const e = penEdgePx(5, 6, "two-button-discard-move e56");
    const v5 = penVertexPx(5, "two-button-discard-move v5");
    string log = penMotion(20, e[0], e[1], 0, PEN_KMOD_LSHIFT) ~ "\n"
               ~ penButton(40, true, 2, e[0], e[1], PEN_KMOD_LSHIFT) ~ "\n"
               ~ penMotion(60, v5[0], v5[1], penButtonMask(2), 0) ~ "\n"
               ~ penButton(80, true, 1, v5[0], v5[1], 0) ~ "\n";
    foreach (i; 1 .. 9)
        log ~= penMotion(80 + 20 * i, v5[0] + 5 * i, v5[1] - 2 * i,
                         penButtonMask(1) | penButtonMask(2), 0) ~ "\n";
    penPlay(log[0 .. $ - 1], "two-button-discard-move MMB hold, LMB drag");
    const dragged = penMesh();
    assert(penMoved(dragged, r.a0) == [5L] && penHistoryLen() == r.hp + 2,
           format("two-button-discard-move rig: the held LMB drag must move v5 alone (moved %s), "
                  ~ "the MMB step closed as one row: %s", penIdx(penMoved(dragged, r.a0)),
                  penHistoryLabels()));
    const up = [v5[0] + 40, v5[1] - 16];
    penPlay(penButton(20, false, 1, up[0], up[1], 0), "two-button-discard-move LMB release");
    expectState("two-button-discard-move", "LMB released (MMB held)", r.a0, true, r.hp + 3);
    penPlay(penButton(20, false, 2, up[0], up[1], 0), "two-button-discard-move MMB release");
    expectState("two-button-discard-move", "MMB released (inert)", r.a0, true, r.hp + 3);
    expectTopLabels("two-button-discard-move", ["Topology Add Loop", "Topology Move"]);
    writeln("PASS two-button-discard-move");
}

// ---------------------------------------------------------------------------
// chord-slide-vertex — L4 outcome (task 8700, wave slice P2; laws L36, L47,
// L49): Ctrl+LMB on a vertex slides it ALONE, one channel, along the world
// axis whose SCREEN image is most parallel to the drag (an axis seen nearly
// end-on skipped), and lands it on the background, v = nearestBG(u + s e_axis).
// The fit is done here against the rig file's own background facets, so the
// residual is a property of the law, not of our kernel. Three rigs separate
// the rivals: the TURNED grid (Y; no incident edge line holds v5), the
// ORBITED camera (-Z; the world axis nearest the drag is Y) and the
// FORESHORTENED one (-Z; the view-plane axis is Y). The front-view diagonal
// drag is the one where an end-on Z would win without the skip. The
// magnitude is floored (`sMin`) and held within `kSlideMagnitudeBand` of the
// capture's `sCaptured`: that pins "about the captured value", not the exact
// magnitude law, which stays uncaptured (gap row (q), card 8700).
// ---------------------------------------------------------------------------
/// Ours: the band |s - sCaptured| <= this x |sCaptured| (measured unmutated
/// worst 6.6%; the off-by-the-offset-length rival lands at 120% and above).
enum double kSlideMagnitudeBand = 0.15;
double[3] vsub(double[3] a, double[3] b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
double vdot(double[3] a, double[3] b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
double[3] vmad(double[3] a, double[3] b, double s) { return [a[0] + b[0] * s, a[1] + b[1] * s, a[2] + b[2] * s]; }
double vdist(double[3] a, double[3] b) { const d = vsub(a, b); return sqrt(vdot(d, d)); }

/// Closest point on triangle (a, b, c) to p (the standard Voronoi-region walk).
double[3] closestOnTri(double[3] p, double[3] a, double[3] b, double[3] c) {
    const ab = vsub(b, a), ac = vsub(c, a), ap = vsub(p, a);
    const d1 = vdot(ab, ap), d2 = vdot(ac, ap);
    if (d1 <= 0 && d2 <= 0) return a;
    const bp = vsub(p, b);
    const d3 = vdot(ab, bp), d4 = vdot(ac, bp);
    if (d3 >= 0 && d4 <= d3) return b;
    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0 && d1 >= 0 && d3 <= 0) return vmad(a, ab, d1 / (d1 - d3));
    const cp = vsub(p, c);
    const d5 = vdot(ab, cp), d6 = vdot(ac, cp);
    if (d6 >= 0 && d5 <= d6) return c;
    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0 && d2 >= 0 && d6 <= 0) return vmad(a, ac, d2 / (d2 - d6));
    const va = d3 * d6 - d5 * d4;
    if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0)
        return vmad(b, vsub(c, b), (d4 - d3) / ((d4 - d3) + (d5 - d6)));
    const den = 1.0 / (va + vb + vc);
    return vmad(vmad(a, ab, vb * den), ac, vc * den);
}

/// The rig's background layer as triangles (each polygon fanned), read from
/// the rig file itself; floor: the 482 v / 512 f sphere penBackgroundLayerFloor
/// pins on the loaded document.
double[3][3][] rigBackgroundTris() {
    auto rigFile = parseJSON(readText(buildPath(dirName(__FILE_FULL_PATH__), "fixtures",
                                                "topology_pen_session_rig.v3d")));
    auto bg = rigFile["layers"].array[1]["mesh"];
    double[3][] v;
    foreach (x; bg["vertices"].array)
        v ~= [penNum(x.array[0]), penNum(x.array[1]), penNum(x.array[2])];
    double[3][3][] tris;
    foreach (f; bg["faces"].array)
        foreach (k; 1 .. f.array.length - 1)
            tris ~= [v[f.array[0].integer], v[f.array[k].integer], v[f.array[k + 1].integer]];
    assert(v.length == 482 && bg["faces"].array.length == 512 && tris.length == 448 * 2 + 64,
           format("chord-slide-vertex: the rig background is not the 482v/512f sphere: %d v, %d f, %d tris",
                  v.length, bg["faces"].array.length, tris.length));
    return tris;
}

double[3] nearestOn(const double[3][3][] tris, double[3] p) {
    double best = double.infinity;
    double[3] r;
    foreach (t; tris) {
        const q = closestOnTri(p, t[0], t[1], t[2]);
        const d = vdist(q, p);
        if (d < best) { best = d; r = q; }
    }
    return r;
}

/// Fit s of p = nearestOn(u + s e) (e a unit direction): a 0.005 scan over
/// +-0.5 around the projection of p (a slide INTO the sphere lands far from
/// that projection), then golden section around the best; returns [s, residual].
double[2] fitAlong(const double[3][3][] tris, double[3] u, double[3] e, double[3] p) {
    const s0 = vdot(vsub(p, u), e);
    double res(double s) { return vdist(nearestOn(tris, vmad(u, e, s)), p); }
    double sBest = s0, rBest = res(s0);
    foreach (i; -100 .. 101) {
        const r = res(s0 + 0.005 * i);
        if (r < rBest) { rBest = r; sBest = s0 + 0.005 * i; }
    }
    double lo = sBest - 0.005, hi = sBest + 0.005;
    enum double g = 0.6180339887498949;
    foreach (_; 0 .. 80) {
        const a = hi - g * (hi - lo), b = lo + g * (hi - lo);
        if (res(a) < res(b)) hi = b; else lo = a;
    }
    const s = (lo + hi) / 2;
    return [s, res(s)];
}

double lineDistance(double[3] p, double[3] a, double[3] b) {
    const e = vsub(b, a);
    return vdist(p, vmad(a, e, vdot(vsub(p, a), e) / vdot(e, e)));
}

double[3] unitAxis(long k) { double[3] e = [0, 0, 0]; e[cast(size_t)k] = 1; return e; }

/// The camera of a fixture row: basis (right, up, back), distance, focus at
/// the origin; floor: GET /api/camera's view matrix carries that basis.
void penSetCamera(JSONValue cam) {
    double[] o;
    foreach (k; ["right", "up", "back"])
        foreach (x; cam[k].array) o ~= penNum(x);
    auto r = penPost("/api/camera", format(`{"orientation":[%(%.17g,%)],"distance":%.17g,`
                                           ~ `"focus":{"x":0,"y":0,"z":0}}`, o, penNum(cam["distance"])));
    const vp = viewportFromCameraMatrices();
    foreach (c; 0 .. 3)
        foreach (k; 0 .. 3)
            assert(abs(vp.view[k * 4 + c] - o[c * 3 + k]) < 1e-5,
                   format("pen rig: the camera did not take basis %s: view %s (%s)", o, vp.view, r.toString));
}

/// The screen images (window px, y down) of unit world steps along X, Y, Z
/// at world point `p` under the live camera, by central difference in double
/// (an oracle independent of the kernel's analytic one).
double[2][3] screenAxisImagesAt(double[3] p) {
    const vp = viewportFromCameraMatrices();
    double[2] pix(double[3] q) {
        double[4] v, c;
        foreach (r; 0 .. 4)
            v[r] = vp.view[r] * q[0] + vp.view[r + 4] * q[1] + vp.view[r + 8] * q[2] + vp.view[r + 12];
        foreach (r; 0 .. 4)
            c[r] = vp.proj[r] * v[0] + vp.proj[r + 4] * v[1] + vp.proj[r + 8] * v[2] + vp.proj[r + 12] * v[3];
        return [(c[0] / c[3] * 0.5 + 0.5) * vp.width, (0.5 - c[1] / c[3] * 0.5) * vp.height];
    }
    double[2][3] J;
    enum double h = 1e-4;
    foreach (i; 0 .. 3) {
        const a = pix(vmad(p, unitAxis(i), h)), b = pix(vmad(p, unitAxis(i), -h));
        J[i] = [(a[0] - b[0]) / (2 * h), (a[1] - b[1]) / (2 * h)];
    }
    return J;
}

/// One vertex slide per a fixture gesture: vertex `vertex` (default 5), the
/// foreground turned by `fgRotZ` degrees about world Z (default 0), the
/// camera of `camera` when given (the drag scaled by our focal length over the
/// capture's) else the rig's (the drag scaled by the v5-v6 spacing). Asserts
/// the law and the session half, undoes it, and returns the fitted s.
double slideVertex(JSONValue fx, JSONValue g, const double[3][3][] tris, const PenMesh a0, long hist) {
    const id = g["id"].str;
    const size_t v = ("vertex" in g) ? cast(size_t)g["vertex"].integer : 5;
    const long sgn = ("sign" in g) ? g["sign"].integer : 1;
    const rot = ("fgRotZ" in g) ? penNum(g["fgRotZ"]) : 0.0;
    const c = cos(rot * PI / 180), sn = sin(rot * PI / 180);
    double[3] w(double[3] l) { return [c * l[0] - sn * l[1], sn * l[0] + c * l[1], l[2]]; }
    const px = penRound(penProject(w(a0.pos[v])));
    penHover(px);
    assert(penHoverIndicator()["nearestVert"].integer == v && penArmed(),
           format("chord-slide-vertex %s: pixel %s of v%d hovers vertex %d, armed %s", id, px, v,
                  penHoverIndicator()["nearestVert"].integer, penArmed()));
    double scale;
    if ("camera" in g) {
        const vp = viewportFromCameraMatrices();
        scale = vp.proj[5] * vp.height / 2 / penNum(g["camera"]["focalPx"]);
    } else {
        scale = penSpacingPx() / penNum(g["spacingPx"]);
    }
    const ddx = penNum(g["dragPx"].array[0]) * scale, ddy = penNum(g["dragPx"].array[1]) * scale;
    {
        // The election's inputs under OUR viewport, printed for the card:
        // each axis's |J| over the longest, and |cos| to the drag.
        const J = screenAxisImagesAt(w(a0.pos[v]));
        double[3] len, cs;
        foreach (i; 0 .. 3) {
            len[i] = sqrt(J[i][0] ^^ 2 + J[i][1] ^^ 2);
            cs[i] = abs(J[i][0] * ddx + J[i][1] * ddy) / (len[i] * sqrt(ddx * ddx + ddy * ddy));
        }
        const mx = len[0] > len[1] ? (len[0] > len[2] ? len[0] : len[2]) : (len[1] > len[2] ? len[1] : len[2]);
        writeln(format("chord-slide-vertex %s: |J|/max X %.3f Y %.3f Z %.3f, |cos| X %.3f Y %.3f Z %.3f, "
                       ~ "drag (%.1f, %.1f) px", id, len[0] / mx, len[1] / mx, len[2] / mx, cs[0], cs[1],
                       cs[2], ddx, ddy));
    }
    const x1 = cast(int)round(px[0] + ddx), y1 = cast(int)round(px[1] + ddy);
    penPlay(penGestureEvents(px[0], px[1], x1, y1, 1, PEN_KMOD_LCTRL, 8), id);
    const m = penMesh();
    assert(penMoved(m, a0) == idxOf(g["moved"]) && [m.nv, m.nf, m.edges] == idxOf(g["counts"])
           && m.faces == a0.faces && penHistoryLen() == hist + 1 && penArmed(),
           format("chord-slide-vertex %s: moved %s (expected %s), counts %s (expected %s), faces "
                  ~ "kept %s, history %s (expected one row more than %d), armed %s", id,
                  penIdx(penMoved(m, a0)), g["moved"], m.toString, g["counts"], m.faces == a0.faces,
                  penHistoryLabels(), hist, penArmed()));
    const u = w(a0.pos[v]), p = w(m.pos[v]);
    const axis = g["axis"].integer;
    const fit = fitAlong(tris, u, unitAxis(axis), p);
    const sMin = penNum(fx["sMin"]), resMax = penNum(fx["fitResidualMax"]);
    // Rivals: every OTHER world axis must miss (one channel), and the vertex
    // must have left each named edge line (the landing, and on the turned
    // grid the edge readings).
    double otherBest = double.infinity;
    foreach (k; 0 .. 3)
        if (k != axis) {
            const r = fitAlong(tris, u, unitAxis(k), p)[1];
            if (r < otherBest) otherBest = r;
        }
    double edgeMin = double.infinity;
    foreach (n; g["offEdgeLines"].array) {
        const d = lineDistance(p, u, w(a0.pos[cast(size_t)n.integer]));
        if (d < edgeMin) edgeMin = d;
    }
    const sCap = penNum(g["sCaptured"]);
    assert(abs(fit[0] - sCap) <= kSlideMagnitudeBand * abs(sCap),
           format("chord-slide-vertex %s: fit s %.5f is %.1f%% off the captured %.5f (band %.0f%%)", id,
                  fit[0], 100 * abs(fit[0] - sCap) / abs(sCap), sCap, 100 * kSlideMagnitudeBand));
    assert(fit[1] <= resMax && fit[0] * sgn > sMin && otherBest > 1e3 * resMax
           && edgeMin >= penNum(fx["lineDistanceMin"]),
           format("chord-slide-vertex %s: v%d %s is not nearestBG(u + s e%d) with %s s > %g: fit s %.5f "
                  ~ "residual %.3g (max %g); best other axis residual %.3g; nearest edge line %.3g "
                  ~ "(min %g)", id, v, p, axis, sgn > 0 ? "+" : "-", sMin, fit[0], fit[1], resMax,
                  otherBest, edgeMin, penNum(fx["lineDistanceMin"])));
    penCtrlZ("chord-slide-vertex " ~ id ~ " Ctrl+Z");
    expectState("chord-slide-vertex", id ~ "_z", a0, g["undoArmed"].type == JSONType.true_, hist);
    writeln(format("chord-slide-vertex %s: axis %d s %.5f (captured %.5f, banded) residual %.3g, "
                   ~ "other axes %.3g, edge lines >= %.3g", id, axis, fit[0], penNum(g["sCaptured"]),
                   fit[1], otherBest, edgeMin));
    return fit[0];
}

unittest {
    if (!cell("chord-slide-vertex")) return;
    auto fx = cellFx("chord-slide-vertex");
    const tris = rigBackgroundTris();
    const r = rig();
    penArmUi(r);
    size_t n;
    foreach (g; fx["gestures"].array) {
        assert(penNum(g["fgRotZ"]) == 0, "chord-slide-vertex: an unturned gesture expected");
        slideVertex(fx, g, tris, r.a0, r.hp + 1);
        ++n;
    }
    assert(n == fx["population"].integer && n == 2,
           format("chord-slide-vertex: %d slides ran, the fixture lists %d (expected 2)", n,
                  fx["population"].integer));

    // Control, below the population (ours, not a captured law): a Ctrl+LMB
    // press on an EDGE still takes the edge slide — border edge 0-1: both
    // endpoints move, v5 does not, and over this background each lands at
    // nearestBG(u + offset) with ONE world channel, Y (the edge slide's law
    // since S7b, L47/L50; its cells are test_session_laws_topology_pen_offset.d).
    // A vertex arm left over from the gestures above would slide v5 instead.
    penGesture(penEdgePx(0, 1, "chord-slide-vertex edge control"), 0, -20 / kSp, 1, PEN_KMOD_LCTRL,
               "chord-slide-vertex edge control");
    const ec = penMesh();
    import std.conv : to;
    const double[3] eo = [penAttr("offsetX").to!double, penAttr("offsetY").to!double,
                          penAttr("offsetZ").to!double];
    const e0 = vdist(ec.pos[0], nearestOn(tris, vmad(r.a0.pos[0], eo, 1)));
    const e1 = vdist(ec.pos[1], nearestOn(tris, vmad(r.a0.pos[1], eo, 1)));
    assert(penMoved(ec, r.a0) == [0L, 1L] && penHistoryLen() == r.hp + 2
           && eo[0] == 0 && eo[2] == 0 && abs(eo[1]) > 1e-3 && e0 <= 1e-6 && e1 <= 1e-6,
           format("chord-slide-vertex edge control: the edge press moved %s (expected [0,1]), offset "
                  ~ "%s (one channel Y), off nearestBG(u + offset) by %.3g / %.3g (max 1e-6), history %s",
                  penIdx(penMoved(ec, r.a0)), eo, e0, e1, penHistoryLabels()));
    penCtrlZ("chord-slide-vertex edge control Ctrl+Z");
    expectState("chord-slide-vertex", "edge_z", r.a0, true, r.hp + 1);

    // Mid-drag (ours: the preview state): with the button still held the
    // vertex slide is armed on v5 and its live axis is world X, moving +X.
    // The release lands FURTHER along +X than the last motion, and the commit
    // is the release's own evaluation (as the edge slide's is), not the last
    // motion's: its s exceeds the held scalar.
    {
        const sp = penSpacingPx();
        const from = penVertexPx(5, "chord-slide-vertex mid-drag");
        const x1 = cast(int)(from[0] + 20 / kSp * sp), y1 = cast(int)(from[1] - 10 / kSp * sp);
        auto ev = penGestureEvents(from[0], from[1], x1, y1, 1, PEN_KMOD_LCTRL, 8);
        const cut = ev.lastIndexOf("\n");
        penPlay(ev[0 .. cut], "chord-slide-vertex mid-drag: press and hold");
        auto st = getJson("/api/tool/state");
        const armed = st["slideArmed"].type == JSONType.true_;
        const sv = st["slideVertex"].integer, ax = st["slideAxis"].integer;
        const k = penNum(st["slideDeltaK"]);
        // Held back on the press pixel: a zero drag elects no axis.
        penPlay(penMotion(480, from[0], from[1], penButtonMask(1), PEN_KMOD_LCTRL),
                "chord-slide-vertex mid-drag: back on the press pixel");
        auto st0 = getJson("/api/tool/state");
        assert(st0["slideArmed"].type == JSONType.true_ && st0["slideVertex"].integer == 5
               && st0["slideAxis"].integer == -1,
               format("chord-slide-vertex mid-drag: held on the press pixel, armed %s, vertex %d, axis %d "
                      ~ "(expected -1)", st0["slideArmed"], st0["slideVertex"].integer,
                      st0["slideAxis"].integer));
        const x2 = x1 + (x1 - from[0]) / 2;
        penPlay(penButton(500, false, 1, x2, y1, PEN_KMOD_LCTRL), "chord-slide-vertex mid-drag: release further");
        const sRel = fitAlong(tris, r.a0.pos[5], unitAxis(0), penMesh().pos[5]);
        assert(armed && sv == 5 && ax == 0 && k > 0 && penMoved(penMesh(), r.a0) == [5L]
               && penHistoryLen() == r.hp + 2 && sRel[1] <= penNum(fx["fitResidualMax"])
               && sRel[0] > 1.2 * k,
               format("chord-slide-vertex mid-drag: armed %s, vertex %d (expected 5), axis %d "
                      ~ "(expected 0), scalar %g (expected > 0); after the release (%d px further) "
                      ~ "moved %s, s %.5f residual %.3g (expected > 1.2 x the held scalar), history %s",
                      armed, sv, ax, k, x2 - x1, penIdx(penMoved(penMesh(), r.a0)), sRel[0], sRel[1],
                      penHistoryLabels()));
        penCtrlZ("chord-slide-vertex mid-drag Ctrl+Z");
        expectState("chord-slide-vertex", "mid_z", r.a0, true, r.hp + 1);
    }

    // The background ray MISSES (ours, not captured — gap note "behaviour on
    // a ray miss", card 8700): v5 dragged screen-LEFT past the sphere's
    // silhouette (the rig's sphere reaches the window's right edge, so only
    // the left side has room). The magnitude then falls back to the
    // view-plane drag delta (`planeDragDelta`), so the held state elects
    // world X, negative, with a channel |k| larger than any background hit
    // can give (a hit lies on the sphere, at most its own -x extent from v5),
    // and the release at the same pixel lands v5 at nearestBG(u + k e_X) —
    // one channel, the elected axis, non-zero.
    {
        double bgMinX = double.infinity;
        foreach (t; tris)
            foreach (q; t) if (q[0] < bgMinX) bgMinX = q[0];
        const u = r.a0.pos[5];
        const hitBound = u[0] - bgMinX;
        const from = penVertexPx(5, "chord-slide-vertex ray miss");
        const far = penRound(penProject([u[0] - hitBound - 0.25, u[1], u[2]]));
        assert(hitBound > 0.5 && far[0] > 0,
               format("chord-slide-vertex ray miss: rig floor: background -x extent %.3f from v5, "
                      ~ "drag pixel %s (v5 at %s)", hitBound, far, from));
        auto ev = penGestureEvents(from[0], from[1], far[0], from[1], 1, PEN_KMOD_LCTRL, 8);
        penPlay(ev[0 .. ev.lastIndexOf("\n")], "chord-slide-vertex ray miss: press and hold");
        auto st = getJson("/api/tool/state");
        const ax = st["slideAxis"].integer;
        const k = penNum(st["slideDeltaK"]);
        penPlay(penButton(500, false, 1, far[0], from[1], PEN_KMOD_LCTRL), "chord-slide-vertex ray miss: release");
        const p = penMesh().pos[5];
        const want = nearestOn(tris, vmad(u, unitAxis(0), k));
        assert(ax == 0 && k < -(hitBound + 0.1) && penMoved(penMesh(), r.a0) == [5L]
               && penHistoryLen() == r.hp + 2 && vdist(p, want) <= 1e-4,
               format("chord-slide-vertex ray miss: held axis %d (expected 0), channel %.5f (expected < "
                      ~ "-%.3f, beyond any background hit); after the release moved %s, v5 %s vs "
                      ~ "nearestBG(u + k e_X) %s (%.3g, max 1e-4), history %s", ax, k, hitBound + 0.1,
                      penIdx(penMoved(penMesh(), r.a0)), p, want, vdist(p, want), penHistoryLabels()));
        penCtrlZ("chord-slide-vertex ray miss Ctrl+Z");
        expectState("chord-slide-vertex", "miss_z", r.a0, true, r.hp + 1);
        writeln(format("chord-slide-vertex ray miss: drag %d px, axis %d, k %.5f (hit bound %.3f)",
                       far[0] - from[0], ax, k, hitBound));
    }

    // THE DISCRIMINATING GESTURE: the grid turned 30 degrees about world Z
    // (the foreground's item transform: the kernel runs in its local frame,
    // the law is a world law), drag nearly up the screen: the axis is world Y.
    {
        auto tg = fx["turned"];
        auto lt = penPost("/api/command", format("layer.attr 0 rot.z %s", penNum(tg["fgRotZ"])));
        assert(lt["status"].str == "ok", "chord-slide-vertex turned: layer.attr failed: " ~ lt.toString);
        assert(penNum(tg["fgRotZ"]) != 0 && tg["axis"].integer == 1,
               "chord-slide-vertex turned: the fixture's turned gesture is not the Y-axis one");
        slideVertex(fx, tg, tris, penMesh(), penHistoryLen());
    }
    writeln("PASS chord-slide-vertex");
}

// The orbited camera (C3-SV3, L47): v13 dragged screen-right slides along -Z,
// where the world axis nearest the drag's background delta is +Y.
// The foreshortened camera (C4-SV4, L49): world Z nearly along the view, v14
// dragged (35, -61) slides along -Z, where the view-plane rule names Y.
void slideUnderCamera(string id) {
    auto fx = cellFx(id);
    auto g = fx["gesture"];
    const tris = rigBackgroundTris();
    const r = rig();
    penArmUi(r);   // its background floor hovers a pixel of the rig's own camera
    penSetCamera(g["camera"]);
    slideVertex(fx, g, tris, r.a0, r.hp + 1);
    writeln("PASS " ~ id);
}

unittest {
    if (!cell("chord-slide-vertex-orbit")) return;
    slideUnderCamera("chord-slide-vertex-orbit");
}

unittest {
    if (!cell("chord-slide-vertex-foreshortened")) return;
    slideUnderCamera("chord-slide-vertex-foreshortened");
}

// ---------------------------------------------------------------------------
// chord-build-* — L34 (N-angle) and L37 (R-closed + S-inTri), port slice 8710
// P1 (task 8720): a Shift+LMB drag from v0. corner (K-chords): triangle
// [0,4,16] on the bisector; angle-left/-down (B1a/B1b): the neighbour nearest
// the drag; closed (a triangle over the corner quad): no build, the press moves
// v0; tri-corner (B5a) and tri-corner-in-wedge (B5b-far): a quad across the
// two BORDER neighbours 1 and 16, the triangles kept, wherever the drag points;
// inside-wedge (B6a-big): a quad corner dragged into its own quad's wedge still
// builds the triangle with edge (0,16). Each: one row, the new faces as cycles
// (winding included), the new vertex ON the background, Ctrl+Z bit-exact and
// the tool stays armed. Every release is >= 55 px from every vertex (the
// capture's release weld, wave plan §9.19.1): drags shorter than that are
// lengthened along their own direction (`kLonger`).
// ---------------------------------------------------------------------------

enum double kWeldClearPx = 55;

/// Drag lengthening per case: the C1/C2 cells whose capture release lay
/// closer than kWeldClearPx (B1a/B1b/B5a: 41 px) are doubled, direction kept.
enum double[string] kLonger = ["corner": 1, "angle-left": 2, "angle-down": 2, "closed": 1,
                               "tri-corner": 2, "tri-corner-in-wedge": 1, "inside-wedge": 1];

/// View zoom per case, over the capture's spacing: B6a-big's release sat 55.0
/// px from v1 at the closest point of its own drag ray, so no lengthening
/// clears it here; the grid is shown 10% larger instead (drag scaled with it,
/// so the gesture's geometry is the capture's).
enum double[string] kZoom = ["inside-wedge": 1.1];

string rigFile(string rigName) {
    return buildPath(dirName(__FILE_FULL_PATH__), "fixtures", rigName == "grid"
                     ? "topology_pen_session_rig.v3d" : "topology_pen_session_rig_" ~ rigName ~ ".v3d");
}

/// A face as a cycle starting at its smallest index (winding kept).
long[] cycleOf(const long[] f) {
    size_t lo;
    foreach (i, v; f) if (v < f[lo]) lo = i;
    return f[lo .. $].dup ~ f[0 .. lo];
}

long[][] cyclesOf(const long[][] fs) {
    import std.algorithm : sort;
    long[][] r;
    foreach (f; fs) r ~= cycleOf(f);
    sort(r);
    return r;
}

/// Distance from `p` to the background layer of `rigFile` (its faces fanned
/// into triangles): the "on the background" read of a built vertex.
double bgDistance(string rigPath, double[3] p) {
    import std.file : readText;
    import std.math : sqrt;
    static double[3][] pos;
    static long[][] faces;
    static string loadedFrom;
    if (loadedFrom != rigPath) {
        auto bg = parseJSON(readText(rigPath))["layers"][1]["mesh"];
        pos = null; faces = null;
        foreach (v; bg["vertices"].array) pos ~= [penNum(v[0]), penNum(v[1]), penNum(v[2])];
        foreach (f; bg["faces"].array) faces ~= idxOf(f);
        loadedFrom = rigPath;
    }
    static double[3] sub(double[3] a, double[3] b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
    static double dot(double[3] a, double[3] b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
    // Closest point on triangle abc to p (Ericson, Real-Time Collision Detection 5.1.5).
    static double triDist(double[3] p, double[3] a, double[3] b, double[3] c) {
        const ab = sub(b, a), ac = sub(c, a), ap = sub(p, a);
        const d1 = dot(ab, ap), d2 = dot(ac, ap);
        double[3] q;
        if (d1 <= 0 && d2 <= 0) q = a;
        else {
            const bp = sub(p, b), d3 = dot(ab, bp), d4 = dot(ac, bp);
            const cp = sub(p, c), d5 = dot(ab, cp), d6 = dot(ac, cp);
            const vc = d1 * d4 - d3 * d2, vb = d5 * d2 - d1 * d6, va = d3 * d6 - d5 * d4;
            if (d3 >= 0 && d4 <= d3) q = b;
            else if (d6 >= 0 && d5 <= d6) q = c;
            else if (vc <= 0 && d1 >= 0 && d3 <= 0) {
                const t = d1 / (d1 - d3);
                q = [a[0] + t * ab[0], a[1] + t * ab[1], a[2] + t * ab[2]];
            } else if (vb <= 0 && d2 >= 0 && d6 <= 0) {
                const t = d2 / (d2 - d6);
                q = [a[0] + t * ac[0], a[1] + t * ac[1], a[2] + t * ac[2]];
            } else if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0) {
                const t = (d4 - d3) / ((d4 - d3) + (d5 - d6));
                q = [b[0] + t * (c[0] - b[0]), b[1] + t * (c[1] - b[1]), b[2] + t * (c[2] - b[2])];
            } else {
                const den = 1 / (va + vb + vc), v = vb * den, w = vc * den;
                q = [a[0] + ab[0] * v + ac[0] * w, a[1] + ab[1] * v + ac[1] * w,
                     a[2] + ab[2] * v + ac[2] * w];
            }
        }
        const d = sub(p, q);
        return sqrt(dot(d, d));
    }
    double best = double.infinity;
    foreach (f; faces)
        foreach (k; 1 .. f.length - 1) {
            const d = triDist(p, pos[cast(size_t)f[0]], pos[cast(size_t)f[k]], pos[cast(size_t)f[k + 1]]);
            if (d < best) best = d;
        }
    assert(faces.length == 512, format("chord-build: the background read %d faces, expected 512", faces.length));
    return best;
}

/// Move the rig camera (eye on +Z, looking at the origin) to the distance at
/// which the grid spacing v5 -> v6 reads `targetPx`; floor: within 0.5 px.
void penZoomToSpacing(double targetPx, string what) {
    import std.math : abs;
    double dist = 4.0;
    foreach (i; 0 .. 4) {
        const sp = penSpacingPx();
        if (abs(sp - targetPx) < 0.1) break;
        const z = penMesh().pos[5][2];   // the grid's depth under the eye
        dist = z + (dist - z) * sp / targetPx;
        penPost("/api/camera", format(`{"azimuth":0.0,"elevation":0.0,"distance":%.9f,`
                                      ~ `"focus":{"x":0.0,"y":0.0,"z":0.0}}`, dist));
    }
    assert(abs(penSpacingPx() - targetPx) < 0.5,
           format("%s rig: the grid spacing reads %.2f px at camera distance %.4f, expected %.1f",
                  what, penSpacingPx(), dist, targetPx));
}

void buildCase(string key) {
    import std.math : round, sqrt;
    const cellId = "chord-build-" ~ key;
    auto c = cellFx("chord-build")[key];
    const path = rigFile(c["rig"].str);
    const b0 = idxOf(c["before"]), b1 = idxOf(c["after"]);
    PenRig r = penRigLoad(path, [b0[0], b0[1], b0[2]]);
    penArmUi(r);
    assert(penHistoryLen() == r.hp + 1,
           format("%s: the UI-door arm did not write its own row: %s", cellId, penHistoryLabels()));
    r.hp = penHistoryLen();

    // The capture's own grid spacing on screen (our viewport is smaller): the
    // camera moves in along its axis until v5 -> v6 reads the capture's
    // pixels, so the captured drags and their release clearances replay as
    // measured. The residual ratio still scales the drag below.
    penZoomToSpacing(penNum(c["spacingPx"]) * kZoom.get(key, 1.0), cellId);
    const from = penVertexPx(0, cellId ~ " v0");
    const s = penSpacingPx() / penNum(c["spacingPx"]) * kLonger[key];
    const d = c["drag"].array;
    const int[2] to = [from[0] + cast(int)round(penNum(d[0]) * s), from[1] + cast(int)round(penNum(d[1]) * s)];
    // Rig trap floor: the release is clear of every vertex (population: all of them).
    double nearest = double.infinity;
    size_t seen;
    foreach (p; r.a0.pos) {
        const q = penProject(p);
        const dist = sqrt((q[0] - to[0]) ^^ 2 + (q[1] - to[1]) ^^ 2);
        if (dist < nearest) nearest = dist;
        ++seen;
    }
    assert(seen == b0[0] && nearest >= kWeldClearPx,
           format("%s rig: the release %s is %.1f px from the nearest vertex (needs >= %.0f; %d of %d "
                  ~ "vertices projected)", cellId, to, nearest, kWeldClearPx, seen, b0[0]));
    penPlay(penGestureEvents(from[0], from[1], to[0], to[1], 1, PEN_KMOD_LSHIFT, 8), cellId ~ " Shift+LMB drag");

    const m = penMesh();
    const labels = penHistoryLabels();
    const bool builds = b1[0] > b0[0];
    long[][] born, gone;
    foreach (f; m.faces) { bool had; foreach (g; r.a0.faces) if (g == f) had = true; if (!had) born ~= f.dup; }
    foreach (f; r.a0.faces) { bool has; foreach (g; m.faces) if (g == f) has = true; if (!has) gone ~= f.dup; }
    assert([m.nv, m.nf, m.edges] == b1 && penHistoryLen() == r.hp + 1
           && labels[$ - 1] == (builds ? "Topology Build" : "Topology Move")
           && cyclesOf(born) == cyclesOf(facesOf(c["newFaces"])) && gone == facesOf(c["goneFaces"]),
           format("%s: mesh %s (expected counts %s), faces born %s (expected the cycles %s), gone %s "
                  ~ "(expected %s), history %s", cellId, m.toString, b1, born, c["newFaces"], gone,
                  c["goneFaces"], labels));
    if (builds) {
        const long nb = b0[0];
        assert((penEdgeId(0, nb) >= 0) == (c["sourceEdge"].type == JSONType.true_)
               && penMoved(m, r.a0) is null,
               format("%s: edge (0,%d) %s (the capture: %s)", cellId, nb,
                      penEdgeId(0, nb) >= 0 ? "present" : "absent", c["sourceEdge"]));
        // The new vertex = nearestBG(v0 + offset), offset = b - v0 (L17's
        // anchor for a build): it is ON the background, under the release.
        const b = m.pos[cast(size_t)nb];
        const q = penProject(b);
        const bgD = bgDistance(path, b);
        const px = sqrt((q[0] - to[0]) ^^ 2 + (q[1] - to[1]) ^^ 2);
        assert(bgD <= 1e-6 && px <= 1.0,
               format("%s: the new vertex %s is %.3g from the background (needs <= 1e-6) and %.2f px "
                      ~ "from the release %s", cellId, b, bgD, px, to));
    } else {
        assert(penMoved(m, r.a0) == idxOf(c["moved"]) && m.faces == r.a0.faces,
               format("%s: moved %s (expected %s), faces %s", cellId, penIdx(penMoved(m, r.a0)),
                      c["moved"], m.faces));
    }
    penCtrlZ(cellId ~ " Ctrl+Z");
    expectState(cellId, "z1", r.a0, c["undoArmed"].type == JSONType.true_, r.hp);
    writeln("PASS ", cellId);
}

unittest { if (cell("chord-build-corner")) buildCase("corner"); }
unittest { if (cell("chord-build-angle-left")) buildCase("angle-left"); }
unittest { if (cell("chord-build-angle-down")) buildCase("angle-down"); }
unittest { if (cell("chord-build-closed")) buildCase("closed"); }
unittest { if (cell("chord-build-tri-corner")) buildCase("tri-corner"); }
unittest { if (cell("chord-build-tri-corner-in-wedge")) buildCase("tri-corner-in-wedge"); }
unittest { if (cell("chord-build-inside-wedge")) buildCase("inside-wedge"); }

// ---------------------------------------------------------------------------
// chord-build-angle-orbit — L52 (fixture: C4-B1o): the build neighbour is the
// smallest angle in the SURFACE plane, not on screen. The S2 grid under the
// captured orbit (azimuth 12, elevation 20 deg, zoomed until v5 -> v6 reads the
// capture's spacing); Shift+LMB from corner v12 to the pixel of u12 plus the
// captured surface delta. Rig floors: in OUR viewport the screen-angle rule
// names v13 and the plane rule v8, and the release clears every vertex. The
// build is the triangle {12, 16, 8}; one row; Ctrl+Z bit-exact, armed.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs, acos, cos, sin, sqrt, PI;
    import std.algorithm : min;
    enum id = "chord-build-angle-orbit";
    if (!cell(id)) return;
    auto c = cellFx("chord-build-orbit");
    PenRig r = armedRig();
    const az = penNum(c["camera"]["azimuthDeg"]) * PI / 180, el = penNum(c["camera"]["elevationDeg"]) * PI / 180;
    double dist = penNum(c["camera"]["distance"]);
    void place() {
        penPost("/api/camera", format(`{"azimuth":%.9f,"elevation":%.9f,"distance":%.9f,`
                                      ~ `"focus":{"x":0.0,"y":0.0,"z":0.0}}`, az, el, dist));
    }
    place();
    const cam = fetchCamera();
    const double[3] eyeWant = [dist * sin(az) * cos(el), dist * sin(el), dist * cos(az) * cos(el)];
    assert(abs(cam.eye.x - eyeWant[0]) + abs(cam.eye.y - eyeWant[1]) + abs(cam.eye.z - eyeWant[2]) < 1e-3,
           format("%s rig: the camera eye is %s, expected %s", id, cam.eye, eyeWant));
    // Zoom along the view axis to the capture's grid spacing (same ratio law
    // as `penZoomToSpacing`, distance measured from the focus).
    const target = penNum(c["spacingPx"]);
    foreach (i; 0 .. 6) {
        const sp = penSpacingPx();
        if (abs(sp - target) < 0.1) break;
        dist = 1.0 + (dist - 1.0) * sp / target;
        place();
    }
    assert(abs(penSpacingPx() - target) < 0.5,
           format("%s rig: the spacing reads %.2f px, expected %.1f", id, penSpacingPx(), target));

    const src = c["source"].integer;
    const u = r.a0.pos[cast(size_t)src];
    const dl = c["surfaceDelta"].array;
    const double[3] hitRel = [u[0] + penNum(dl[0]), u[1] + penNum(dl[1]), u[2] + penNum(dl[2])];
    const from = penVertexPx(src, id ~ " v12");
    const int[2] to = penRound(penProject(hitRel));
    // Rig floor 1: the release clears every vertex (population: all 16).
    double nearest = double.infinity;
    size_t seen;
    foreach (p; r.a0.pos) {
        const q = penProject(p);
        nearest = min(nearest, sqrt((q[0] - to[0]) ^^ 2 + (q[1] - to[1]) ^^ 2));
        ++seen;
    }
    assert(seen == 16 && nearest >= kWeldClearPx,
           format("%s rig: the release %s is %.1f px from the nearest vertex (needs >= %.0f)",
                  id, to, nearest, kWeldClearPx));
    // Rig floor 2: the two rules disagree HERE. Screen: the drag against each
    // border neighbour's projected edge. Plane: the world edge against the
    // surface delta, both in the tangent plane of the unit-sphere BG at u.
    double[3] sub3(const double[3] a, const double[3] b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
    double dot3(const double[3] a, const double[3] b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
    const double un = sqrt(dot3(u, u));
    const double[3] nrm = [u[0] / un, u[1] / un, u[2] / un];
    double[3] tan3(const double[3] v) { const k = dot3(v, nrm); return [v[0] - k * nrm[0], v[1] - k * nrm[1], v[2] - k * nrm[2]]; }
    double angle(const double[3] a, const double[3] b) {
        return acos(dot3(a, b) / sqrt(dot3(a, a) * dot3(b, b))) * 180 / PI;
    }
    const pu = penProject(u);
    const double[3] drag2 = [to[0] - from[0], to[1] - from[1], 0];
    const double[3] dT = tan3(sub3(hitRel, u));
    long screenPick = -1, planePick = -1;
    double screenBest = double.infinity, planeBest = double.infinity;
    string angles;
    foreach (n; [8L, 13L]) {
        const pn = penProject(r.a0.pos[cast(size_t)n]);
        const sa = angle([pn[0] - pu[0], pn[1] - pu[1], 0], drag2);
        const pa = angle(tan3(sub3(r.a0.pos[cast(size_t)n], u)), dT);
        angles ~= format(" v%d screen %.1f plane %.1f;", n, sa, pa);
        if (sa < screenBest) { screenBest = sa; screenPick = n; }
        if (pa < planeBest) { planeBest = pa; planePick = n; }
    }
    assert(screenPick == c["screenNeighbour"].integer && planePick == c["planeNeighbour"].integer,
           format("%s rig: in our viewport the screen rule names v%d (the capture: v%d) and the plane "
                  ~ "rule v%d (v%d) -- the rig does not discriminate:%s", id, screenPick,
                  c["screenNeighbour"].integer, planePick, c["planeNeighbour"].integer, angles));

    // The same gesture as `penGestureEvents`, played in three parts so the Tri
    // ghost's neighbour (`triGhost`, set per cursor move) is read while held:
    // at the press it is the zero-drag answer, after the motions it must name
    // the neighbour the release then builds on.
    const mod = PEN_KMOD_LSHIFT;
    penPlay(penMotion(20, from[0], from[1], 0, mod) ~ "\n" ~ penMotion(40, from[0], from[1], 0, mod) ~ "\n"
            ~ penButton(60, true, 1, from[0], from[1], mod), id ~ " Shift+LMB press");
    const g0 = getJson("/api/tool/state");
    string moves;
    foreach (i; 1 .. 9)
        moves ~= penMotion(60 + 40 * i, from[0] + (to[0] - from[0]) * i / 8, from[1] + (to[1] - from[1]) * i / 8,
                           penButtonMask(1), mod) ~ "\n";
    penPlay(moves, id ~ " held motions");
    const g1 = getJson("/api/tool/state");
    assert(g0["dragArmed"].type == JSONType.true_ && g0["case"].str == "tri"
           && g1["dragArmed"].type == JSONType.true_ && g0["triGhost"].integer != planePick
           && (g0["triGhost"].integer == 8 || g0["triGhost"].integer == 13)
           && g1["triGhost"].integer == planePick,
           format("%s: the ghost names v%s at the press and v%s after the motions (expected another "
                  ~ "neighbour, then the plane rule's v%d); armed %s/%s, case %s", id, g0["triGhost"],
                  g1["triGhost"], planePick, g0["dragArmed"], g1["dragArmed"], g0["case"]));
    {
        // The drawn ghost reads that same field (`drawBuildGhost`, Tri arm): the
        // state read above says nothing about the line on screen otherwise. The
        // arm is read from the EXECUTABLE text (comments stripped, whitespace
        // dropped) between `case BuildCase.Tri:` and its `break;`, so a comment
        // that keeps the old call's spelling cannot satisfy it (task 8790).
        import std.algorithm : count;
        import std.file : readText;
        import std.string : indexOf;
        const code = codeOnly(readText(buildPath(dirName(__FILE_FULL_PATH__), "..", "source", "tools",
                                                 "edit", "topology_pen", "render.d")));
        enum kArm = "caseBuildCase.Tri:";
        const at0 = code.indexOf(kArm);
        assert(at0 >= 0 && code.count(kArm) == 1,
               format("%s: render.d has %d `case BuildCase.Tri:` arms (expected 1)", id, code.count(kArm)));
        const tail = code[at0 + kArm.length .. $];
        const brk = tail.indexOf("break;");
        assert(brk >= 0, id ~ ": render.d's Tri arm has no `break;`");
        const arm = tail[0 .. brk];
        assert(arm.count("ghostTo(") == 1 && arm.count("ghostTo(ghostTriN_);") == 1,
               format("%s: render.d's Tri arm must draw exactly `ghostTo(ghostTriN_)`; it reads `%s`",
                      id, arm));
    }
    penPlay(penButton(500, false, 1, to[0], to[1], mod), id ~ " release");
    const m = penMesh();
    const labels = penHistoryLabels();
    long[][] born;
    foreach (f; m.faces) { bool had; foreach (g; r.a0.faces) if (g == f) had = true; if (!had) born ~= f.dup; }
    assert([m.nv, m.nf, m.edges] == idxOf(c["after"]) && penHistoryLen() == r.hp + 1
           && labels[$ - 1] == "Topology Build" && cyclesOf(born) == cyclesOf(facesOf(c["newFaces"])),
           format("%s: mesh %s (expected counts %s), faces born %s (expected the cycle %s; the screen rule "
                  ~ "builds on v%d), history %s;%s", id, m.toString, c["after"], born, c["newFaces"],
                  screenPick, labels, angles));
    penCtrlZ(id ~ " Ctrl+Z");
    expectState(id, "z1", r.a0, c["undoArmed"].type == JSONType.true_, r.hp);
    writeln("PASS ", id);
}

// ---------------------------------------------------------------------------
// chord-dup-interior-edge — contract C-0 (task 0486; not this capture) through
// the real Shift+LMB chord: on interior edge 5-6 the Duplicate slot moves the
// edge's two vertices instead. One row, Ctrl+Z bit-exact, the tool stays armed.
// Task 8720: that release used to dispatch back into the build leg forever.
// ---------------------------------------------------------------------------
unittest {
    enum id = "chord-dup-interior-edge";
    if (!cell(id)) return;
    PenRig r = armedRig();
    penGesture(penEdgePx(5, 6, id), 0, 20 / kSp, 1, PEN_KMOD_LSHIFT, id);
    const m = penMesh();
    const labels = penHistoryLabels();
    assert([m.nv, m.nf, m.edges] == [r.a0.nv, r.a0.nf, r.a0.edges] && m.faces == r.a0.faces
           && penMoved(m, r.a0) == [5L, 6L] && penHistoryLen() == r.hp + 1
           && labels[$ - 1] == "Topology Move",
           format("%s: mesh %s, moved %s (expected [5,6]), history %s", id, m.toString,
                  penIdx(penMoved(m, r.a0)), labels));
    penCtrlZ(id ~ " Ctrl+Z");
    expectState(id, "z1", r.a0, true, r.hp);
    writeln("PASS ", id);
}

// ---------------------------------------------------------------------------
// chord-dup-empty — a Shift+LMB drag that starts on empty space arms nothing
// (Duplicate always starts on an element): no mesh change, ONE history row (L5,
// slice S5: every press is a step, a no-op one included), Ctrl+Z pops it with
// the pen armed, and the app answers afterwards. Task 8720: the base arms the
// button before the press declines and the press is stamped `Build`
// regardless, so this release too used to dispatch back into the build leg
// forever (no HTTP answer).
// ---------------------------------------------------------------------------
unittest {
    enum id = "chord-dup-empty";
    if (!cell(id)) return;
    PenRig r = armedRig();
    const v0 = penVertexPx(0, id ~ " v0");
    const int[2] from = [v0[0] - 200, v0[1]];
    const int[2] to   = [from[0] - 40, from[1] + 20];
    // Rig floor: both ends are inside the viewport and hover no element.
    auto c = fetchCamera();
    foreach (p; [from, to]) {
        penHover(p);
        auto hi = penHoverIndicator();
        assert(p[0] > c.vpX + 10 && p[0] < c.vpX + c.width - 10
               && hi["nearestVert"].integer == -1 && hi["nearestEdge"].integer == -1,
               format("%s rig: %s is not empty space inside the viewport (x %d..%d): hover %s",
                      id, p, c.vpX, c.vpX + c.width, hi.toString));
    }
    penPlay(penGestureEvents(from[0], from[1], to[0], to[1], 1, PEN_KMOD_LSHIFT, 8), id ~ " Shift+LMB drag");
    expectState(id, "release", r.a0, true, r.hp + 1);
    penCtrlZ(id ~ " Ctrl+Z");
    expectState(id, "z1", r.a0, true, r.hp);
    writeln("PASS ", id);
}

// ---------------------------------------------------------------------------
// S6 (wave plan 8640 §4.6, §9.6, §9.17.4, [A6-1], [A7-4]) — a user drop of the
// pen writes a DROP row. Undoing it re-arms the pen and reverts the newest
// completed press block (L8), and
// EMPTIES the redo stack (L32, ported). Esc also writes an empty task row
// above it (L39), whose undo keeps redo (X-esc-r R-task).
// ---------------------------------------------------------------------------
enum PEN_SDLK_ESCAPE = 27;
enum PEN_SDLK_SPACE  = 32;
enum PEN_SDLK_q      = 113;
enum PEN_SDLK_1      = 49;
enum PEN_SDLK_3      = 51;

long penRedoLen() { return cast(long)getJson("/api/history")["redo"].array.length; }
string penSelType() { return getJson("/api/selection")["selType"].str; }
enum PEN_SDLK_5      = 53;

/// The re-armed pen's own steps (`/api/tool/state` session.steps: rows of ITS
/// session token). After a drop row's undo the pen must continue the dropped
/// session (`adoptPredecessorToken_`), so g1 counts as its step.
long penSessionSteps() {
    auto s = getJson("/api/tool/state");
    return ("session" in s.object) && s["session"].type == JSONType.object
        ? s["session"]["steps"].integer : -1;
}

/// armed / mesh / undo length / redo length at one step of a drop ladder.
void dropStep(string id, string step, const PenMesh want, bool armed, long hist, long redo) {
    const m = penMesh();
    assert(m == want && penArmed() == armed && penHistoryLen() == hist && penRedoLen() == redo,
           format("%s %s: mesh %s the expected one, armed %s (expected %s), history %d (expected %d), "
                  ~ "redo %d (expected %d) %s", id, step, m == want ? "==" : "!=", penArmed(), armed,
                  penHistoryLen(), hist, penRedoLen(), redo, penHistoryLabels()));
}

/// arm, g1, the drop door, then the ladder. `taskRow`: the door is Esc, whose
/// task row sits above the drop row.
void dropLadder(string id, void delegate() drop, bool taskRow) {
    const r = rig();
    penArmUi(r);
    moveV5(id ~ " g1");
    const g1 = penMesh();
    const long h = r.hp + 2;     // the activation row + g1
    assert(penHistoryLen() == h, format("%s rig: arm + g1 is not two rows: %s", id, penHistoryLabels()));
    drop();
    const long hd = h + (taskRow ? 2 : 1);
    dropStep(id, "exit", g1, false, hd, 0);
    const labels = penHistoryLabels();
    assert(labels[$ - 1] == (taskRow ? "Clear Tool Task" : "Tool Drop"),
           format("%s exit: the top rows are %s", id, labels));
    if (taskRow) {
        assert(labels[$ - 2] == "Tool Drop", format("%s exit: the drop row is not below the task row: %s",
                                                    id, labels));
        // X-esc-r (R-task): popping only the task row keeps redo; Shift+Z
        // brings it back.
        penCtrlZ(id ~ " zt");
        dropStep(id, "zt (task row)", g1, false, h + 1, 1);
        penCtrlShiftZ(id ~ " rt");
        dropStep(id, "rt (task row redone)", g1, false, h + 2, 0);
        penCtrlZ(id ~ " zt2");
        dropStep(id, "zt2 (task row)", g1, false, h + 1, 1);
    }
    penCtrlZ(id ~ " z1");
    dropStep(id, "z1 (drop plus newest press, redo discarded)", r.a0, true, h, 0);
    assert(penSessionSteps() == 0, format("%s z1: reverted press remains in session", id));
    penCtrlShiftZ(id ~ " z1-redo");
    dropStep(id, "z1-redo (nothing to redo)", r.a0, true, h, 0);
    penCtrlZ(id ~ " z2");
    dropStep(id, "z2 (marker)", r.a0, true, h - 1, 0);
    penCtrlShiftZ(id ~ " r1");
    dropStep(id, "r1 (marker has no redo)", r.a0, true, h - 1, 0);
    writeln("PASS ", id);
}

unittest {
    if (!cell("drop-esc")) return;
    dropLadder("drop-esc", () { penKey(PEN_SDLK_ESCAPE, 0, "drop-esc Esc"); }, true);
}

unittest {
    if (!cell("drop-space")) return;
    dropLadder("drop-space", () { penKey(PEN_SDLK_SPACE, 0, "drop-space Space"); }, false);
}

unittest {
    if (!cell("drop-q")) return;
    dropLadder("drop-q", () { penKey(PEN_SDLK_q, 0, "drop-q Q"); }, false);
}

unittest {
    if (!cell("drop-command")) return;
    dropLadder("drop-command", () { penLineUi("tool.set " ~ kPenToolId ~ " off"); }, false);
}

// drop-sel — key 1 before the arm, g1, key 3 (a front flip drops the pen): the
// drop row's undo re-arms the pen AND restores Vertex through the funnel that
// does not drop it.
unittest {
    if (!cell("drop-sel")) return;
    const r = rig();
    penKey(PEN_SDLK_1, 0, "drop-sel key 1");
    assert(penSelType() == "vertex", "drop-sel rig: key 1 did not select vertices: " ~ penSelType());
    penArmUi(r);
    moveV5("drop-sel g1");
    const g1 = penMesh();
    const long h = r.hp + 2;
    penKey(PEN_SDLK_3, 0, "drop-sel key 3");
    dropStep("drop-sel", "exit", g1, false, h + 1, 0);
    assert(penSelType() == "polygon" && penHistoryLabels()[$ - 1] == "Tool Drop",
           format("drop-sel exit: type %s, history %s", penSelType(), penHistoryLabels()));
    penCtrlZ("drop-sel z1");
    dropStep("drop-sel", "z1", r.a0, true, h, 0);
    assert(penSelType() == "vertex", "drop-sel z1: selection type not restored");
    assert(penSessionSteps() == 0, "drop-sel z1: reverted press still owned");
    penCtrlShiftZ("drop-sel refused redo");
    dropStep("drop-sel", "r0", r.a0, true, h, 0);
    penCtrlZ("drop-sel z2");
    dropStep("drop-sel", "z2 (marker)", r.a0, true, h - 1, 0);
    penCtrlShiftZ("drop-sel r1");
    dropStep("drop-sel", "r1", r.a0, true, h - 1, 0);
    writeln("PASS drop-sel");
}

// drop-sel-item — the item-mode key (5) flips the front type to Items and drops
// the pen; the drop row's undo re-arms it and restores Vertex (the item door of
// the same selection-type drop, `switchItemType`).
unittest {
    if (!cell("drop-sel-item")) return;
    const r = rig();
    penKey(PEN_SDLK_1, 0, "drop-sel-item key 1");
    penArmUi(r);
    moveV5("drop-sel-item g1");
    const g1 = penMesh();
    const long h = r.hp + 2;
    penKey(PEN_SDLK_5, 0, "drop-sel-item key 5");
    dropStep("drop-sel-item", "exit", g1, false, h + 1, 0);
    assert(penSelType() == "item" && penHistoryLabels()[$ - 1] == "Tool Drop",
           format("drop-sel-item exit: type %s, history %s", penSelType(), penHistoryLabels()));
    penCtrlZ("drop-sel-item z1");
    dropStep("drop-sel-item", "z1", r.a0, true, h, 0);
    assert(penSelType() == "vertex",
           "drop-sel-item z1: the selection type was not restored: " ~ penSelType());
    writeln("PASS drop-sel-item");
}

// drop-bare — arm, Esc, no gesture (X-bare, X-bare-redo): the key door, then
// the raw `history.undo` / `history.redo` doors, whose redo is REFUSED
// (status:error — the empty redo stack) with the pen still armed.
unittest {
    if (!cell("drop-bare")) return;
    const r = rig();
    penArmUi(r);
    const long h = r.hp + 1;
    penKey(PEN_SDLK_ESCAPE, 0, "drop-bare Esc");
    dropStep("drop-bare", "exit", r.a0, false, h + 2, 0);
    penCtrlZ("drop-bare z1");
    dropStep("drop-bare", "z1 (task row)", r.a0, false, h + 1, 1);
    penCtrlZ("drop-bare z2");
    dropStep("drop-bare", "z2 (drop row)", r.a0, true, h, 0);
    penCtrlShiftZ("drop-bare r1");
    dropStep("drop-bare", "r1 (nothing to redo)", r.a0, true, h, 0);
    // the raw doors
    penKey(PEN_SDLK_ESCAPE, 0, "drop-bare Esc (raw pass)");
    dropStep("drop-bare", "raw exit", r.a0, false, h + 2, 0);
    penCmd("history.undo");
    dropStep("drop-bare", "raw z1 (task row)", r.a0, false, h + 1, 1);
    penCmd("history.undo");
    dropStep("drop-bare", "raw z2 (drop row)", r.a0, true, h, 0);
    auto rr = penPost("/api/command", `{"id":"history.redo"}`);
    assert(rr["status"].str == "error",
           "drop-bare raw redo: an empty redo stack must refuse: " ~ rr.toString);
    dropStep("drop-bare", "raw r1 (refused)", r.a0, true, h, 0);
    writeln("PASS drop-bare");
}

// rearm-typed — X-toggle: `tool.set mesh.topoPen on` (UI door) while the pen is
// armed is a same-tool switch row (armed == previous == the pen), not a drop.
unittest {
    if (!cell("rearm-typed")) return;
    const r = rig();
    penArmUi(r);
    moveV5("rearm-typed g1");
    const g1 = penMesh();
    const long h = r.hp + 2;
    penLineUi("tool.set " ~ kPenToolId ~ " on");
    dropStep("rearm-typed", "exit", g1, true, h + 1, 0);
    assert(penHistoryLabels()[$ - 1] == "Activate Tool",
           format("rearm-typed exit: the re-arm is not an activation row: %s", penHistoryLabels()));
    penCtrlZ("rearm-typed z1");
    assert(penArmed() && penMesh() == g1 && penHistoryLen() == h,
           format("rearm-typed z1: armed %s, mesh %s g1, history %s", penArmed(),
                  penMesh() == g1 ? "==" : "!=", penHistoryLabels()));
    penCtrlZ("rearm-typed z2");
    assert(penArmed() && penMesh() == r.a0 && penHistoryLen() == h - 1,
           format("rearm-typed z2: armed %s, mesh %s a0, history %s", penArmed(),
                  penMesh() == r.a0 ? "==" : "!=", penHistoryLabels()));
    penCtrlZ("rearm-typed z3");
    assert(!penArmed() && penMesh() == r.a0 && penHistoryLen() == h - 2,
           format("rearm-typed z3: armed %s, history %s", penArmed(), penHistoryLabels()));
    writeln("PASS rearm-typed");
}

// non-user-drop — a primary move drops the pen on its own mesh and re-arms it on
// the new primary (9511, K-CD4 rule 1) with NO drop row: only the layer
// selection's own row lands.
unittest {
    if (!cell("non-user-drop")) return;
    const r = rig();
    penArmUi(r);
    moveV5("non-user-drop g1");
    const long h = r.hp + 2;
    assert(penHistoryLen() == h, "non-user-drop rig: " ~ penHistoryLabels().join(","));
    penCmd("layer.select", `{"index":1,"mode":"set"}`);
    const labels = penHistoryLabels();
    assert(penArmed() && penHistoryLen() == h + 1 && !labels.canFind("Tool Drop"),
           format("non-user-drop: armed %s, history %s (expected g1's rows + the layer selection, "
                  ~ "no drop row)", penArmed(), labels));
    writeln("PASS non-user-drop");
}

// ---------------------------------------------------------------------------
// W1 — L46 (task 8750, wave plan 8770 §9.21/§9.22.3; captured C3-R3-rev, C3-R4):
// a build that closes a triangle over a bare edge, and a Fill whose new side
// runs along one, consume that edge's wire key (the capture's line polygon), so
// a later remove of the new face takes the edge with it. Our A is the removed
// triangle's own orphan and goes too; the capture keeps it through its point
// polygon (named divergence, gap row (v)). The key is read from a native save.
//   chord-build-then-remove   C3-R3-rev drag order: 17/9/24 -> 19/10/27 -> 16/9/24
//   chord-build-consume-undo  Ctrl+Z after the close re-registers (A, N')
//   fill-consume-then-remove  the r4 rig: Fill over the hole, then remove it
// ---------------------------------------------------------------------------

/// The registered wire keys of the primary layer, read from a native save of
/// the live document (the only place they surface). Side effects: `file.save`
/// sets the document's path to the temp file and marks the document clean;
/// the file itself (under /var/tmp) is deleted on scope exit. Floors: the save
/// writes no history row and leaves the pen armed as it was.
long[2][] penWireKeys(string what) {
    import std.file : exists, remove;
    import std.process : thisProcessID;
    import std.conv : to;
    const path = "/var/tmp/vibe3d_w1_wire_keys_" ~ thisProcessID.to!string ~ ".v3d";
    if (exists(path)) remove(path);
    scope (exit) if (exists(path)) remove(path);
    const hist = penHistoryLen();
    const wasArmed = penArmed();
    penCmd("file.save", format(`{"path":%s}`, JSONValue(path).toString));
    auto doc = parseJSON(readText(path));
    assert(penHistoryLen() == hist && penArmed() == wasArmed,
           format("%s: the native save moved the session: history %d -> %d, armed %s -> %s",
                  what, hist, penHistoryLen(), wasArmed, penArmed()));
    auto mesh = doc["layers"][cast(size_t)doc["primaryLayer"].integer]["mesh"];
    long[2][] r;
    if (auto w = "wireEdges" in mesh.object)
        foreach (e; w.array) r ~= [e.array[0].integer, e.array[1].integer];
    return r;
}

bool hasKey(const long[2][] keys, long a, long b) {
    foreach (k; keys) if ((k[0] == a && k[1] == b) || (k[0] == b && k[1] == a)) return true;
    return false;
}

/// The C3-R3-rev rig on the armed grid: a Point-mode click places A (16) at the
/// captured hub, a Shift+LMB drag from A draws the bare edge (16, 17) [h1], a
/// second closes the triangle [16, 18, 17] [h2]. Floors at each stage: counts,
/// one row per gesture, the key (16, 17) registered after h1 and gone after h2.
/// `grid` is the armed grid before A; `h1` the mesh after the bare edge.
PenMesh consumeBuild(string id, JSONValue c, out PenMesh grid, out PenMesh h1, out long hpH1) {
    PenRig r = armedRig();
    grid = r.a0;
    {
        auto a = penPost("/api/command", "tool.attr mesh.topoPen mode point");
        assert(a["status"].str == "ok", id ~ " rig: mode point refused: " ~ a.toString);
    }
    auto ap = c["rigPoint"].array;
    penTap(penRound(penProject([penNum(ap[0]), penNum(ap[1]), penNum(ap[2])])), 1, 0, id ~ " place A");
    {
        auto a = penPost("/api/command", "tool.attr mesh.topoPen mode move");
        assert(a["status"].str == "ok", id ~ " rig: mode move refused: " ~ a.toString);
    }
    const m0 = penMesh();
    assert([m0.nv, m0.nf, m0.edges] == idxOf(c["a0"]) && penWireKeys(id ~ " a0").length == 0,
           format("%s rig: after placing A the mesh is %s (expected %s)", id, m0.toString, c["a0"]));
    const s = penSpacingPx() / penNum(c["spacingPx"]);
    const de = c["dragEdge"].array, dc = c["dragClose"].array;
    const from = penVertexPx(16, id ~ " A");
    long hp = penHistoryLen();
    penPlay(penGestureEvents(from[0], from[1], from[0] + cast(int)round(penNum(de[0]) * s),
                             from[1] + cast(int)round(penNum(de[1]) * s), 1, PEN_KMOD_LSHIFT, 8),
            id ~ " h1 bare edge");
    h1 = penMesh();
    const k1 = penWireKeys(id ~ " h1");
    assert([h1.nv, h1.nf, h1.edges] == idxOf(c["h1"]) && penEdgeId(16, 17) >= 0 && hasKey(k1, 16, 17)
           && k1.length == 1 && penHistoryLen() == hp + 1,
           format("%s h1: mesh %s (expected %s), edge (16,17) id %d, keys %s, history %s", id,
                  h1.toString, c["h1"], penEdgeId(16, 17), k1, penHistoryLabels()));
    hpH1 = penHistoryLen();
    const from2 = penVertexPx(16, id ~ " A again");
    penPlay(penGestureEvents(from2[0], from2[1], from2[0] + cast(int)round(penNum(dc[0]) * s),
                             from2[1] + cast(int)round(penNum(dc[1]) * s), 1, PEN_KMOD_LSHIFT, 8),
            id ~ " h2 close");
    PenMesh h2 = penMesh();
    const k2 = penWireKeys(id ~ " h2");
    long[][] born;
    foreach (f; h2.faces) { bool had; foreach (g; h1.faces) if (g == f) had = true; if (!had) born ~= f.dup; }
    assert([h2.nv, h2.nf, h2.edges] == idxOf(c["h2"]) && cyclesOf(born) == [cycleOf(idxOf(c["newFace"]))]
           && penHistoryLen() == hpH1 + 1 && penHistoryLabels()[$ - 1] == "Topology Build",
           format("%s h2: mesh %s (expected %s), born %s (expected %s), history %s", id, h2.toString,
                  c["h2"], born, c["newFace"], penHistoryLabels()));
    assert(!hasKey(k2, 16, 17) && k2.length == 0,
           format("%s h2: the build left the bare edge's key registered: keys %s", id, k2));
    return h2;
}

unittest {
    enum id = "chord-build-then-remove";
    if (!cell(id)) return;
    auto c = cellFx("chord-build-consume");
    PenMesh grid, h1;
    long hpH1;
    const h2 = consumeBuild(id, c, grid, h1, hpH1);
    const hp = penHistoryLen();
    penTap(penFacePx(9), 2, PEN_KMOD_LCTRL, id ~ " Ctrl+MMB the triangle");
    const m = penMesh();
    assert([m.nv, m.nf, m.edges] == idxOf(c["rm"]) && m == grid && penHistoryLen() == hp + 1
           && penHistoryLabels()[$ - 1] == "Topology Remove",
           format("%s: after the remove the mesh is %s (expected %s, the grid %s bit-exact: %s; the "
                  ~ "capture %s keeps A), edge (16,17) id %d, history %s", id, m.toString, c["rm"],
                  grid.toString, m == grid, c["rmCapture"], penEdgeId(16, 17), penHistoryLabels()));
    penCtrlZ(id ~ " Ctrl+Z");
    expectState(id, "z1", h2, c["undoArmed"].type == JSONType.true_, hp);
    writeln("PASS ", id);
}

unittest {
    enum id = "chord-build-consume-undo";
    if (!cell(id)) return;
    auto c = cellFx("chord-build-consume");
    PenMesh grid, h1;
    long hpH1;
    const h2 = consumeBuild(id, c, grid, h1, hpH1);
    penCtrlZ(id ~ " Ctrl+Z");
    expectState(id, "z1", h1, c["undoArmed"].type == JSONType.true_, hpH1);
    const kz = penWireKeys(id ~ " z1");
    assert(hasKey(kz, 16, 17) && kz.length == 1,
           format("%s z1: the undo did not re-register the bare edge's key: keys %s", id, kz));
    penCtrlShiftZ(id ~ " Ctrl+Shift+Z");
    expectState(id, "r1", h2, true, hpH1 + 1);
    const kr = penWireKeys(id ~ " r1");
    assert(kr.length == 0, format("%s r1: the redo brought the consumed key back: keys %s", id, kr));
    writeln("PASS ", id);
}

unittest {
    enum id = "fill-consume-then-remove";
    if (!cell(id)) return;
    auto c = cellFx("fill-consume");
    const a0c = idxOf(c["a0"]);
    PenRig r = penRigLoad(rigFile(c["rig"].str), [a0c[0], a0c[1], a0c[2]]);
    penArmUi(r);
    foreach (w; [["mode", "fill"], ["range", c["range"].str]]) {
        auto a = penPost("/api/command", "tool.attr mesh.topoPen " ~ w[0] ~ " " ~ w[1]);
        assert(a["status"].str == "ok", format("%s rig: %s %s refused: %s", id, w[0], w[1], a.toString));
    }
    const be = idxOf(c["bareEdge"]);
    const k0 = penWireKeys(id ~ " a0");
    assert(penEdgeId(be[0], be[1]) >= 0 && hasKey(k0, be[0], be[1]) && k0.length == 1,
           format("%s rig: edge (%d,%d) id %d, keys %s (expected exactly that key)", id, be[0], be[1],
                  penEdgeId(be[0], be[1]), k0));
    // The capture's press sat 5 px inside edge 5-6 toward the hole, then dragged
    // 10 px further in; both scaled by the spacing ratio.
    const s = penSpacingPx() / penNum(c["spacingPx"]);
    const pe = idxOf(c["pressEdge"]);
    const e = penEdgePx(pe[0], pe[1], id ~ " e56");
    const off = c["pressOffsetPx"].array, d = c["drag"].array;
    const int[2] from = [e[0] + cast(int)round(penNum(off[0]) * s), e[1] + cast(int)round(penNum(off[1]) * s)];
    const int[2] to = [from[0] + cast(int)round(penNum(d[0]) * s), from[1] + cast(int)round(penNum(d[1]) * s)];
    const hp = penHistoryLen();
    const a0 = penMesh();
    penPlay(penGestureEvents(from[0], from[1], to[0], to[1], 1, 0, 4), id ~ " Fill drag");
    const g1 = penMesh();
    long[][] born;
    foreach (f; g1.faces) { bool had; foreach (g; a0.faces) if (g == f) had = true; if (!had) born ~= f.dup; }
    bool side(const long[] f, long a, long b) {
        foreach (i; 0 .. f.length)
            if ((f[i] == a && f[(i + 1) % $] == b) || (f[i] == b && f[(i + 1) % $] == a)) return true;
        return false;
    }
    long[] sortedNew = idxOf(c["newFace"]).dup;
    {
        import std.algorithm : sort;
        sort(sortedNew);
    }
    long[] bornSet = born.length == 1 ? born[0].dup : null;
    {
        import std.algorithm : sort;
        sort(bornSet);
    }
    const kg = penWireKeys(id ~ " g1");
    assert([g1.nv, g1.nf, g1.edges] == idxOf(c["g1"]) && born.length == 1 && bornSet == sortedNew
           && side(born[0], be[0], be[1]) && penHistoryLen() == hp + 1
           && penHistoryLabels()[$ - 1] == "Topology Fill",
           format("%s g1: mesh %s (expected %s), born %s (expected the corners of %s with (%d,%d) a "
                  ~ "SIDE), history %s", id, g1.toString, c["g1"], born, c["newFace"], be[0], be[1],
                  penHistoryLabels()));
    writeln(id, ": the Fill built the ring ", born[0]);
    assert(kg.length == 0, format("%s g1: the Fill left the bare edge's key registered: keys %s", id, kg));
    {
        auto a = penPost("/api/command", "tool.attr mesh.topoPen mode move");
        assert(a["status"].str == "ok", id ~ ": mode move refused: " ~ a.toString);
    }
    const hpRm = penHistoryLen();
    penTap(penFacePx(g1.nf - 1), 2, PEN_KMOD_LCTRL, id ~ " Ctrl+MMB the filled face");
    const m = penMesh();
    assert([m.nv, m.nf, m.edges] == idxOf(c["rm"]) && penEdgeId(be[0], be[1]) < 0
           && m.faces == a0.faces && m.pos == a0.pos && penHistoryLen() == hpRm + 1,
           format("%s rm: mesh %s (expected %s), edge (%d,%d) id %d (expected gone with the face), "
                  ~ "faces %s, history %s", id, m.toString, c["rm"], be[0], be[1],
                  penEdgeId(be[0], be[1]), m.faces, penHistoryLabels()));
    penCtrlZ(id ~ " Ctrl+Z");
    expectState(id, "z1", g1, c["undoArmed"].type == JSONType.true_, hpRm);
    writeln("PASS ", id);
}

// ---------------------------------------------------------------------------
// Population: with no VIBE3D_CELL every cell above ran (declared last, so it
// runs last).
// ---------------------------------------------------------------------------
unittest {
    writeln("cells=", cellsRun);
    const only = environment.get("VIBE3D_CELL", "");
    if (only.length == 0)
        assert(cellsRun == 55, format("topology pen session laws: %d cells ran, expected 55", cellsRun));
    else
        assert(cellsRun == 1, format("topology pen session laws: VIBE3D_CELL=%s ran %d cells, expected 1 "
                                     ~ "(an unknown name runs none)", only, cellsRun));
}
