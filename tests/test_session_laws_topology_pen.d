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
//
// The fixture also carries rows that do not hold on this rig yet (card 8650):
// the other four chords' outcomes (their port slices add `chord-*` cells), the
// switch-away redo walk and `no-op-presses` (L5); the slices that make them
// hold add their cells.
//
// `VIBE3D_CELL=<id>` runs one cell alone (druntime stops a module at its first
// failed assert); the last block pins the population: 9 with no filter, 1 with
// one (an unknown name must not pass by running nothing).
//
// Run via: ./run_test.d test_session_laws_topology_pen

import topology_pen_session_helpers;
import fixture_helpers : requireProvenance;
import std.format : format;
import std.json;
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
// [A2-8]) to the five chords that record on this rig; the other four
// (corner build, vertex slide, interior split, and remove's counts) diverge in
// OUTCOME and land as their port slices' `chord-*` cells.
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
    // `counts`: whether (nv, nf, ne) is asserted. Not for remove: the orphan
    // corner and its two edges are the port slice 8740's outcome.
    const Chord[string] spec = [
        "dup_edge": Chord(1, S, false, 0, 36 / kSp, true),
        "addloop":  Chord(2, S, false, 10 / kSp, 0, true),
        "moveloop": Chord(3, 0, false, 0, -15 / kSp, true),
        "remove":   Chord(2, C, true, 0, 0, false),
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
    assert(n == 5 && counted == 4 && redone == 1,
           format("chords: %d chords ran (expected 5), %d with counts (expected 4), %d redone "
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
// Population: with no VIBE3D_CELL every cell above ran (declared last, so it
// runs last).
// ---------------------------------------------------------------------------
unittest {
    writeln("cells=", cellsRun);
    const only = environment.get("VIBE3D_CELL", "");
    if (only.length == 0)
        assert(cellsRun == 9, format("topology pen session laws: %d cells ran, expected 9", cellsRun));
    else
        assert(cellsRun == 1, format("topology pen session laws: VIBE3D_CELL=%s ran %d cells, expected 1 "
                                     ~ "(an unknown name runs none)", only, cellsRun));
}
