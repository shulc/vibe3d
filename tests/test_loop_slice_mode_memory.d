// The Loop Slice slice list is STORED, never derived, under every Mode
// (task 9340; captured: toolcard `loop_slice_position_memory` Q1-Q3 and the
// mode cells). Only a write that changes the law's input — Count, Mode, Add,
// Remove — re-lays it; three paths take it as it is:
//
//   A. drop -> reactivate, for every Mode x Count 1..3 (only `current` resets);
//   B. a session step undo (Ctrl+Z after two scrubs) under Symmetry, Count 2;
//   C. a new arm in the same activation (Enter, then a fresh click) under
//      Symmetry, Count 2.
//
// The discriminating values: a Symmetry pair other than the uniform
// (1/3, 2/3), and a Free triple that is neither uniform nor 0.5.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.json;
import std.conv : to;
import std.format : format;
import std.math : fabs;
import core.thread : Thread;
import core.time : msecs;

void main() {}

void cmd(string s) {
    auto r = postJson("/api/command", s);
    assert(r["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ r.toString);
}

void cmdUi(string s) {
    auto r = postJson("/api/command?origin=ui", s);
    assert(r["status"].str == "ok", "ui cmd `" ~ s ~ "` failed: " ~ r.toString);
}

JSONValue query(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" && "value" in r, "query `" ~ line ~ "` failed: " ~ r.toString);
    return r["value"];
}

double[] positions() {
    double[] r;
    foreach (v; getJson("/api/tool/state")["positions"].array) r ~= v.floating;
    return r;
}

bool same(double[] a, double[] b) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length) if (fabs(a[i] - b[i]) > 1e-4) return false;
    return true;
}

bool uniform(double[] a) {
    foreach (k, v; a) if (fabs(v - (k + 1.0) / (a.length + 1.0)) > 1e-4) return false;
    return true;
}

void resetCube() { cmd(commandBody("scene.reset")); }

// --- play-events (the viewport rect of tests/test_loop_slice_ctrlz.d) ------

enum VPX = 150, VPY = 28, VPW = 650, VPH = 544;
enum CX = VPX + VPW / 2, CY = VPY + VPH / 2;

void play(string body_) {
    auto r = postJson("/api/play-events", format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
        VPX, VPY, VPW, VPH) ~ "\n" ~ body_);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    foreach (_; 0 .. 200) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.true_) break;
        Thread.sleep(50.msecs);
    }
    Thread.sleep(150.msecs);
}

void click() {
    play(format(`{"t":10.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}
{"t":30.0,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}
{"t":50.0,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, CX, CY, CX, CY, CX, CY));
}

// A press, a horizontal drag of `dx` px in four motion events, a release.
void drag(int dx) {
    string s = format(`{"t":10.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}
{"t":30.0,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, CX, CY, CX, CY);
    foreach (i; 1 .. 5)
        s ~= format("\n" ~ `{"t":%.1f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":0,"state":1,"mod":0}`,
                    30.0 + 20 * i, CX + dx * i / 4, CY, dx / 4);
    s ~= format("\n" ~ `{"t":150.0,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                CX + dx, CY);
    play(s);
}

void key(int sym, int mod = 0) {
    play(format(`{"t":10.0,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}
{"t":30.0,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}`, sym, mod, sym, mod));
}

/// Two adjacent cube faces selected in polygon mode: the arm click seeds
/// from the selection (`activationSeeds`), so it needs no hovered pixel.
void selectTwoFaces() {
    cmd(commandBody("mesh.select", `{"mode":"polygons","indices":[4,1]}`));
}

/// Writes `want` slice by slice through `current` + `position`, under `mode`.
void setList(string mode, double[] want) {
    cmd("tool.attr mesh.loopSliceTool mode " ~ mode);
    cmd("tool.attr mesh.loopSliceTool count " ~ want.length.to!string);
    foreach (k, v; want) {
        cmd("tool.attr mesh.loopSliceTool current " ~ k.to!string);
        cmd("tool.attr mesh.loopSliceTool position " ~ v.to!string);
    }
}

// ---------------------------------------------------------------------------
// A. drop -> reactivate keeps Mode, Count and the list; `current` resets.
// ---------------------------------------------------------------------------
unittest {
    struct Cell { string mode; double[] write; double[] want; }
    // Symmetry: slice k and count-1-k mirror (the write of slice 0 moves
    // slice count-1 too). Uniform and a single Symmetry slice ignore a write, so their
    // list is the even spacing — still pinned, it must not drift either.
    immutable Cell[] cells = [
        Cell("free",     [0.2],             [0.2]),
        Cell("free",     [0.15, 0.6],       [0.15, 0.6]),
        Cell("free",     [0.1, 0.3, 0.85],  [0.1, 0.3, 0.85]),
        Cell("uniform",  [0.2],             [0.5]),   // a single slice does not move
        Cell("uniform",  [0.2, 0.9],        [1.0 / 3, 2.0 / 3]),
        Cell("uniform",  [0.1, 0.3, 0.85],  [0.25, 0.5, 0.75]),
        Cell("symmetry", [0.2],             [0.5]),   // self-mirrored: pinned at 0.5
        Cell("symmetry", [0.2, 0.8],        [0.2, 0.8]),
        Cell("symmetry", [0.1, 0.5, 0.9],   [0.1, 0.5, 0.9]),
    ];
    size_t ran;
    foreach (c; cells) {
        resetCube();
        cmd("tool.set mesh.loopSliceTool");
        setList(c.mode, c.write.dup);
        if (c.mode == "symmetry" && c.want.length > 1) {
            // write slice 0 last: its mirror then holds 1 - want[0]
            cmd("tool.attr mesh.loopSliceTool current 0");
            cmd("tool.attr mesh.loopSliceTool position " ~ c.want[0].to!string);
        }
        immutable tag = format("[%s x%d]", c.mode, c.want.length);
        auto before = positions();
        assert(same(before, c.want.dup),
            format("%s rig: the list did not land before the drop: %s", tag, before));
        assert(c.want.length < 2 || c.mode == "uniform" || !uniform(before),
            format("%s rig: the list is the uniform spacing; a re-lay could not show", tag));
        cmd("tool.attr mesh.loopSliceTool current " ~ (c.want.length - 1).to!string);

        cmd("tool.set mesh.loopSliceTool off");
        cmd("tool.set mesh.loopSliceTool");

        auto after = positions();
        assert(same(after, c.want.dup),
            format("%s the slice list must survive drop -> reactivate: want %s, got %s",
                   tag, c.want, after));
        assert(query("tool.attr mesh.loopSliceTool mode ?").str == c.mode,
            format("%s mode must survive drop -> reactivate", tag));
        assert(query("tool.attr mesh.loopSliceTool count ?").integer == c.want.length,
            format("%s count must survive drop -> reactivate", tag));
        assert(query("tool.attr mesh.loopSliceTool current ?").integer == 0,
            format("%s current must reset to 0 at activation", tag));
        cmd("tool.set mesh.loopSliceTool off");
        ++ran;
    }
    assert(ran == 9, "population: 9 cells");
}

// ---------------------------------------------------------------------------
// B. A session step undo restores the Symmetry pair it popped back to.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmdUi("tool.set mesh.loopSliceTool on");
    setList("symmetry", [0.5, 0.5]);
    cmd("tool.attr mesh.loopSliceTool current 0");
    cmd("tool.attr mesh.loopSliceTool position 0.3");
    selectTwoFaces();
    click();                                   // arm (the session's first step)
    assert(getJson("/api/tool/state")["armed"].type == JSONType.true_, "B rig: not armed");
    drag(-80);
    auto one = positions();
    drag(-60);
    auto two = positions();
    assert(one.length == 2 && !uniform(one) && !same(one, two),
        format("B rig: the two scrubs must leave two distinct non-uniform pairs: %s, %s", one, two));
    assert(fabs(one[0] + one[1] - 1) < 1e-4, format("B rig: not a mirrored pair: %s", one));

    key(122, 64);                              // Ctrl+Z: pops the second scrub
    assert(getJson("/api/tool/state")["armed"].type == JSONType.true_,
        "B rig: Ctrl+Z ended the session instead of popping a step");
    auto back = positions();
    assert(same(back, one),
        format("a session undo must restore the Symmetry pair it pops back to: want %s, got %s",
               one, back));
    cmd("tool.set mesh.loopSliceTool off");
}

// ---------------------------------------------------------------------------
// C. A new arm in the same activation cuts at the stored Symmetry pair.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set mesh.loopSliceTool");
    setList("symmetry", [0.5, 0.5]);
    cmd("tool.attr mesh.loopSliceTool current 0");
    cmd("tool.attr mesh.loopSliceTool position 0.2");
    selectTwoFaces();
    click();
    assert(getJson("/api/tool/state")["armed"].type == JSONType.true_, "C rig: not armed");
    key(13);                                   // Enter: commit, the tool stays
    auto st = getJson("/api/tool/state");
    assert(st["armed"].type == JSONType.false_, "C rig: Enter did not commit");
    cmd(commandBody("mesh.select", `{"mode":"polygons","indices":[4,1]}`));
    click();                                   // a new arm
    assert(getJson("/api/tool/state")["armed"].type == JSONType.true_, "C rig: re-arm failed");
    auto after = positions();
    assert(same(after, [0.2, 0.8]),
        format("a new arm must cut at the stored Symmetry pair [0.2, 0.8], got %s", after));
    cmd("tool.set mesh.loopSliceTool off");
}

// ---------------------------------------------------------------------------
// D. Undoing a committed cut while the tool stays idle re-syncs the session
//    (`resyncSession`); the stored Symmetry pair survives it.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmdUi("tool.set mesh.loopSliceTool on");
    setList("symmetry", [0.5, 0.5]);
    cmd("tool.attr mesh.loopSliceTool current 0");
    cmd("tool.attr mesh.loopSliceTool position 0.2");
    selectTwoFaces();
    click();
    key(13);                                   // Enter: commit, the tool stays
    assert(getJson("/api/tool/state")["armed"].type == JSONType.false_, "D rig: Enter did not commit");
    immutable long cutFaces = getJson("/api/model")["faceCount"].integer;
    key(122, 64);                              // Ctrl+Z: undo the committed cut
    auto st = getJson("/api/tool/state");
    assert("tool" in st.object && st["tool"].type == JSONType.string,
        "D rig: Ctrl+Z after a commit must keep the tool");
    assert(getJson("/api/model")["faceCount"].integer < cutFaces,
        "D rig: Ctrl+Z did not undo the committed cut");
    auto after = positions();
    assert(same(after, [0.2, 0.8]),
        format("an undo resync must keep the stored Symmetry pair [0.2, 0.8], got %s", after));
    cmd("tool.set mesh.loopSliceTool off");
}

// ---------------------------------------------------------------------------
// E. Symmetry, odd Count: the middle slice is pinned at 0.5 — a write to it
//    moves nothing, a write to an outer slice moves its mirror (captured S2).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set mesh.loopSliceTool");
    setList("symmetry", [0.5, 0.5, 0.5]);
    cmd("tool.attr mesh.loopSliceTool current 0");
    cmd("tool.attr mesh.loopSliceTool position 0.2");
    auto outer = positions();
    assert(same(outer, [0.2, 0.5, 0.8]),
        format("E rig: an outer write must move its mirror: want [0.2, 0.5, 0.8], got %s", outer));
    cmd("tool.attr mesh.loopSliceTool current 1");
    cmd("tool.attr mesh.loopSliceTool position 0.3");
    auto after = positions();
    assert(same(after, [0.2, 0.5, 0.8]),
        format("Symmetry middle slice moved: want it pinned at 0.5, got %s", after));
    cmd("tool.set mesh.loopSliceTool off");
}

// ---------------------------------------------------------------------------
// The Mode and Count laws, cell by cell from the formulas read under a
// debugger (toolcard `loop_slice_position_memory`, F1-F4). Each cell sets a
// list headlessly (tool active, nothing armed), applies one write, reads the
// list.
// ---------------------------------------------------------------------------

/// A Free list in INDEX order (Free writes do not reorder or re-space).
void freeList(double[] v) {
    cmd("tool.attr mesh.loopSliceTool mode free");
    cmd("tool.attr mesh.loopSliceTool count " ~ v.length.to!string);
    foreach (k, x; v) {
        cmd("tool.attr mesh.loopSliceTool current " ~ k.to!string);
        cmd("tool.attr mesh.loopSliceTool position " ~ x.to!string);
    }
    assert(same(positions(), v), format("rig: Free list %s did not land: %s", v, positions()));
}

/// A Symmetry list through its first slice.
void symList(size_t n, double first) {
    cmd("tool.attr mesh.loopSliceTool mode symmetry");
    cmd("tool.attr mesh.loopSliceTool count " ~ n.to!string);
    cmd("tool.attr mesh.loopSliceTool current 0");
    cmd("tool.attr mesh.loopSliceTool position " ~ first.to!string);
}

unittest { // F1: a Mode write to Symmetry mirrors by index, the slice at n/2 picks the half
    struct C { double[] from; double[] want; }
    immutable C[] cells = [
        C([0.9, 0.1, 0.35],      [0.9, 0.5, 0.1]),        // non-ascending: index, not value
        C([0.3, 0.95, 0.6, 0.2], [0.8, 0.4, 0.6, 0.2]),   // pivot 0.6 > 0.5: upper half wins
        C([0.3, 0.5],            [0.3, 0.7]),             // pivot exactly 0.5: lower wins
        C([0.7, 0.5],            [0.7, 0.3]),
        C([0.2, 0.5, 0.9],       [0.2, 0.5, 0.8]),
        C([0.3],                 [0.5]),
    ];
    resetCube();
    cmd("tool.set mesh.loopSliceTool");
    foreach (c; cells) {
        freeList(c.from.dup);
        cmd("tool.attr mesh.loopSliceTool mode symmetry");
        assert(same(positions(), c.want.dup),
            format("F1 Free %s -> Symmetry: want %s, got %s", c.from, c.want, positions()));
    }
    cmd("tool.attr mesh.loopSliceTool mode uniform");
    assert(same(positions(), [0.5]), "F1 -> Uniform must space evenly");
    cmd("tool.set mesh.loopSliceTool off");
}

unittest { // F2: a Symmetry Count write inserts after `current` (appends at the last), then re-mirrors
    struct C { size_t n; double first; int cur; int to; double[] want; }
    immutable C[] cells = [
        C(2, 0.3, 0, 3, [0.3, 0.5, 0.7]),
        C(2, 0.3, 1, 3, [0.15, 0.5, 0.85]),
        C(2, 0.3, 0, 5, [0.3, 0.4, 0.5, 0.6, 0.7]),
        C(2, 0.3, 1, 5, [0.075, 0.15, 0.5, 0.85, 0.925]),
        C(3, 0.2, 0, 4, [0.2, 0.35, 0.65, 0.8]),
        C(3, 0.2, 1, 4, [0.2, 0.35, 0.65, 0.8]),
        C(3, 0.2, 2, 4, [0.1, 0.2, 0.8, 0.9]),
        C(3, 0.2, 0, 2, [0.2, 0.8]),
        C(3, 0.2, 0, 1, [0.5]),
    ];
    resetCube();
    cmd("tool.set mesh.loopSliceTool");
    foreach (c; cells) {
        cmd("tool.attr mesh.loopSliceTool mode free");
        cmd("tool.attr mesh.loopSliceTool count 1");
        symList(c.n, c.first);
        cmd("tool.attr mesh.loopSliceTool current " ~ c.cur.to!string);
        cmd("tool.attr mesh.loopSliceTool count " ~ c.to.to!string);
        assert(same(positions(), c.want.dup),
            format("F2 Symmetry x%d first %s, current %d, Count -> %d: want %s, got %s",
                   c.n, c.first, c.cur, c.to, c.want, positions()));
    }
    cmd("tool.set mesh.loopSliceTool off");
}

unittest { // F2 shrink: 5 -> 2 truncates the append cell's list and re-mirrors
    resetCube();
    cmd("tool.set mesh.loopSliceTool");
    cmd("tool.attr mesh.loopSliceTool mode free");
    cmd("tool.attr mesh.loopSliceTool count 1");
    symList(2, 0.3);
    cmd("tool.attr mesh.loopSliceTool current 1");
    cmd("tool.attr mesh.loopSliceTool count 5");
    assert(same(positions(), [0.075, 0.15, 0.5, 0.85, 0.925]), "F2 rig: the append cell");
    cmd("tool.attr mesh.loopSliceTool count 2");
    assert(same(positions(), [0.075, 0.925]),
        format("F2 Symmetry 5 -> 2: want [0.075, 0.925], got %s", positions()));
    cmd("tool.set mesh.loopSliceTool off");
}

unittest { // F4: a Free or Uniform Count write re-spaces evenly, grow and shrink
    resetCube();
    cmd("tool.set mesh.loopSliceTool");
    foreach (cur; [0, 2]) {
        freeList([0.1, 0.3, 0.85]);
        cmd("tool.attr mesh.loopSliceTool current " ~ cur.to!string);
        cmd("tool.attr mesh.loopSliceTool count 5");
        assert(same(positions(), [1/6.0, 2/6.0, 3/6.0, 4/6.0, 5/6.0]),
            format("F4 Free 3 -> 5 (current %d) must re-space evenly, got %s", cur, positions()));
    }
    freeList([0.1, 0.3, 0.85]);
    cmd("tool.attr mesh.loopSliceTool count 2");
    assert(same(positions(), [1/3.0, 2/3.0]), format("F4 Free 3 -> 2, got %s", positions()));
    cmd("tool.attr mesh.loopSliceTool count 1");
    assert(same(positions(), [0.5]), format("F4 Free -> 1, got %s", positions()));
    cmd("tool.attr mesh.loopSliceTool mode uniform");
    cmd("tool.attr mesh.loopSliceTool count 4");
    assert(same(positions(), [0.2, 0.4, 0.6, 0.8]), format("F4 Uniform 1 -> 4, got %s", positions()));
    cmd("tool.set mesh.loopSliceTool off");
}

unittest { // F3 writes: a Symmetry slice stays on its side of 0.5; Uniform ignores a write
    resetCube();
    cmd("tool.set mesh.loopSliceTool");
    cmd("tool.attr mesh.loopSliceTool mode free");
    cmd("tool.attr mesh.loopSliceTool count 1");
    symList(2, 0.3);
    assert(same(positions(), [0.3, 0.7]), "F3 rig: [0.3, 0.7]");
    cmd("tool.attr mesh.loopSliceTool position 0.8");     // current 0, below 0.5
    assert(same(positions(), [0.5, 0.5]),
        format("F3 a Symmetry write must stop at its half: want [0.5, 0.5], got %s", positions()));
    cmd("tool.attr mesh.loopSliceTool mode uniform");
    cmd("tool.attr mesh.loopSliceTool current 0");
    cmd("tool.attr mesh.loopSliceTool position 0.1");
    assert(same(positions(), [1/3.0, 2/3.0]), format("F3 Uniform must ignore a write, got %s", positions()));
    cmd("tool.set mesh.loopSliceTool off");
}

unittest { // F3 scrub: [0.005, 0.995] and never past an index neighbour (Free {0.3, 0.6})
    double[] reach(int cur, int dx) {
        resetCube();
        cmdUi("tool.set mesh.loopSliceTool on");
        freeList([0.3, 0.6]);
        cmd("tool.attr mesh.loopSliceTool current " ~ cur.to!string);
        selectTwoFaces();
        click();
        assert(getJson("/api/tool/state")["armed"].type == JSONType.true_, "F3 scrub rig: not armed");
        drag(dx);
        auto r = positions();
        cmd("tool.set mesh.loopSliceTool off");
        return r;
    }
    // Slice 1 (the last): one direction is open to 0.995, the other stops at slice 0.
    auto a = reach(1, 300), b = reach(1, -300);
    double[] ends = [a[1], b[1]];
    assert((fabs(ends[0] - 0.995) < 1e-4 && fabs(ends[1] - 0.3) < 1e-4)
        || (fabs(ends[1] - 0.995) < 1e-4 && fabs(ends[0] - 0.3) < 1e-4),
        format("F3 scrub of the last slice must end at 0.995 or at its neighbour 0.3, got %s", ends));
    // Slice 0: 0.005 one way, its neighbour 0.6 the other.
    auto c = reach(0, 300), d = reach(0, -300);
    ends = [c[0], d[0]];
    assert((fabs(ends[0] - 0.005) < 1e-4 && fabs(ends[1] - 0.6) < 1e-4)
        || (fabs(ends[1] - 0.005) < 1e-4 && fabs(ends[0] - 0.6) < 1e-4),
        format("F3 scrub of slice 0 must end at 0.005 or at its neighbour 0.6, got %s", ends));
}

unittest { // F3 scrub, Symmetry {0.3, 0.7}: a slice stops at 0.5 (its half), or at 0.005 / 0.995
    double[] reach(int cur, int dx) {
        resetCube();
        cmdUi("tool.set mesh.loopSliceTool on");
        cmd("tool.attr mesh.loopSliceTool mode free");
        cmd("tool.attr mesh.loopSliceTool count 1");
        symList(2, 0.3);
        assert(same(positions(), [0.3, 0.7]), "F3 sym scrub rig: [0.3, 0.7]");
        cmd("tool.attr mesh.loopSliceTool current " ~ cur.to!string);
        selectTwoFaces();
        click();
        assert(getJson("/api/tool/state")["armed"].type == JSONType.true_, "F3 sym scrub rig: not armed");
        drag(dx);
        auto r = positions();
        cmd("tool.set mesh.loopSliceTool off");
        return r;
    }
    foreach (cur; [0, 1]) {
        immutable double outer = cur == 0 ? 0.005 : 0.995;
        auto a = reach(cur, 300), b = reach(cur, -300);
        double[] ends = [a[cur], b[cur]];
        assert((fabs(ends[0] - 0.5) < 1e-4 && fabs(ends[1] - outer) < 1e-4)
            || (fabs(ends[1] - 0.5) < 1e-4 && fabs(ends[0] - outer) < 1e-4),
            format("F3 a Symmetry scrub of slice %d must stop at 0.5 (its own half) or %s, got %s / %s",
                   cur, outer, a, b));
    }
}
