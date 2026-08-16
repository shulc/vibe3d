// test_slot_activation_boundary.d — task 0791.
//
// THE LAW THIS FILE PINS, and where it came from.
//
// A transform gesture leaves a HELD run: the entry is tagged `inSession` and a
// later pipe change can still act on it. What a pipe change does to that held
// run splits in two, and the split is NOT "does the packet compare unequal":
//
//   ACTIVATING a slot   — putting a (possibly identical) tool into one of the
//                         pipe's slots — ENDS the run. The geometry stays
//                         frozen at the pipe state that produced it.
//   WRITING an ATTRIBUTE of a slot's tool — RE-WEIGHS the held run from its
//                         pre-gesture baseline (the idle re-grade, pinned by
//                         test_falloff_idle_refire.d / test_falloff_refire_rs.d).
//
// Measured on the reference under a debugger — eight cells in one boot, in full
// agreement with the trace. The decisive cell put the SAME tool back into a slot
// that already held it: the pipeline is byte-identical before and after and the
// held operation still ends, so the trigger is the activation EVENT, not a diff
// of the pipeline. That is also why there is no packet comparison to port: the
// reference compares nothing at all — it rolls the held result back and re-runs
// the whole pipe, and the two paths differ only in whether the run survives.
//
// Before 0791 we answered this THREE different ways depending on the route,
// measured cell by cell on our own engine (the full matrix is in the task
// report):
//
//   * the POINTER routes already ended the run — a click-away relocate, an
//     element-pick relocate and an off-gizmo click all take a mouse-down
//     boundary. Reference-conformant, and untouched by 0791.
//   * the ACEN MODE poll already ended it. Also untouched.
//   * the COMMAND-surface relocate (`tool.pipe.attr actionCenter
//     userPlacedCenter` / `userPlacedX|Y|Z`) did NOTHING AT ALL: the pivot
//     moved, the run stayed open, the geometry never reacted. Same user action
//     as the click, opposite law, purely because of where it arrived from.
//   * under an ELEMENT falloff that same command did a third thing — it
//     re-graded (task 0724, which read the missing reaction as a packet-equality
//     hole and closed it by adding `pickedCenter` to the comparison). Its own
//     click twin froze the geometry instead.
//   * the FALLOFF slot (`type`, and the stack depth via `falloff.add` /
//     `falloff.remove`) re-graded where the reference ends the run.
//   * the AXIS slot did nothing.
//
// Every cell below lands ONE committed Move gesture (leaving an open in-session
// run), makes exactly ONE change at idle, and reads back ONCE. The run state is
// read from `/api/history` — the `inSession` flag on the most recent entry —
// rather than inferred from geometry, because "the geometry did not move" is
// also what a run that is merely BLIND to the change looks like, and telling
// those two apart is the whole point of the file.
//
// (NULL) is the control that keeps the rest honest: a cell that changes nothing
// and reads back the same way must report the run still open. Without it a bug
// that closed every run on any readback would pass every other cell here.
//
// NOT COVERED, and deliberately not guessed: the SNAP and SYMMETRY slots. The
// reference was driven through three slots (action centre, falloff, axis) and
// those are the three this file pins. Enabling snap or symmetry mid-run still
// re-grades here, as it did before 0791 — see the task's gap list.

import std.net.curl;
import std.json;
import std.math   : fabs;
import std.conv   : to;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}
void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "/api/command '" ~ line ~ "' failed: "
        ~ r.toString);
}
void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(150.msecs);
}
long undoCount() { return getJson("/api/history")["undo"].array.length; }

double[3][] dumpVerts() {
    double[3][] vs;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        vs ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return vs;
}

bool approxEq(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

// The live gizmo pivot (ActionCenterPacket.center).
Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating, cast(float)c[1].floating,
                cast(float)c[2].floating);
}

// The most recent undo entry's `inSession` flag — CommandHistory's own answer
// to "is a run still held?", read directly instead of inferred from geometry.
bool runIsHeld() {
    auto arr = getJson("/api/history")["undo"].array;
    assert(arr.length > 0, "expected at least one undo entry");
    auto top = arr[$ - 1];
    return ("inSession" in top.object) !is null && top["inSession"].boolean;
}

// Land ONE committed +X move-arrow gesture against the CURRENT gizmo pivot —
// same verify-and-retry idiom as test_falloff_idle_refire.d (a missed grab
// records nothing; a hit records exactly one committed entry).
void moveGestureOnArrow(long wantCount, double dragPx = 60.0) {
    foreach (attempt; 0 .. 6) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        double ux, uy;
        int xa, ya;
        axisGrabPx(evalPivot(), vp, xa, ya, ux, uy);
        int xb = xa + cast(int)(dragPx * ux);
        int yb = ya + cast(int)(dragPx * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xa, ya, xb, yb, 10));
        settle();
        if (undoCount() == wantCount) return;
    }
    assert(false, "move gesture did not land (undo count never reached "
        ~ wantCount.to!string ~ ")");
}

// Arm a Move tool on a pristine cube, run `setup`, land one gesture, and
// return the post-gesture geometry. Asserts the precondition every cell needs:
// the landed gesture must leave an OPEN in-session run, or the cell is testing
// nothing.
double[3][] armAndLandGesture(string cellName, void delegate() setup) {
    postJson("/api/reset", "");
    cmd("tool.set move");
    setup();
    settle();
    long floor = undoCount();
    moveGestureOnArrow(floor + 1);
    settle();
    assert(runIsHeld(),
        "setup: the landed gesture must leave an OPEN in-session run for cell "
        ~ cellName ~ " to test anything");
    return dumpVerts();
}

void dropTool() {
    cmd("tool.set move off");
    postJson("/api/reset", "");
}

// Assert the geometry is exactly where the gesture left it — a slot activation
// FREEZES the held result, it does not recompute it.
void assertFrozen(string cellName, double[3][] before) {
    auto after = dumpVerts();
    assert(after.length == before.length,
        cellName ~ ": vertex count changed under a slot activation");
    foreach (i; 0 .. before.length)
        foreach (k; 0 .. 3)
            assert(approxEq(after[i][k], before[i][k]),
                cellName ~ ": a slot activation must FREEZE the held result, "
                ~ "not recompute it; v" ~ i.to!string ~ " comp " ~ k.to!string
                ~ " was " ~ before[i][k].to!string ~ ", now "
                ~ after[i][k].to!string);
}

// ===========================================================================
// (NULL) The control. Nothing changes ⇒ the run is still held, and the
// readbacks this file performs are not themselves a boundary.
// ===========================================================================
unittest {
    auto before = armAndLandGesture("NULL", () {});
    settle();
    assert(runIsHeld(),
        "a cell that changes nothing must leave the run HELD — if this fails, "
        ~ "every other cell in this file is measuring the readback, not the "
        ~ "change");
    assertFrozen("NULL", before);
    dropTool();
}

// ===========================================================================
// (ACEN-MODE) The action-centre slot's occupant. Pre-0791 behaviour, pinned
// here so the law's cells sit together.
// ===========================================================================
unittest {
    auto before = armAndLandGesture("ACEN-MODE", () {});
    cmd("tool.pipe.attr actionCenter mode origin");
    settle();
    assert(!runIsHeld(),
        "an action-centre MODE change is a slot activation and must END the "
        ~ "held run");
    assertFrozen("ACEN-MODE", before);
    dropTool();
}

// ===========================================================================
// (ACEN-RELOCATE-ATTR) The command-surface relocate. THE 0791 CELL: before
// this task the pivot moved and nothing else happened at all.
//
// A Move gesture is deliberately pivot-blind (translation does not depend on
// the pivot), so geometry alone cannot tell "ended" from "never noticed" —
// which is exactly why the run flag is the observable here.
// ===========================================================================
unittest {
    auto before = armAndLandGesture("ACEN-RELOCATE-ATTR", () {});
    auto pivotBefore = evalPivot();
    cmd(`tool.pipe.attr actionCenter userPlacedCenter "0.5,0.5,0.5"`);
    settle();
    auto pivotAfter = evalPivot();
    assert(!approxEq(pivotAfter.x, pivotBefore.x, 1e-3)
        || !approxEq(pivotAfter.y, pivotBefore.y, 1e-3)
        || !approxEq(pivotAfter.z, pivotBefore.z, 1e-3),
        "setup: the relocate must actually move the pivot, else the cell "
        ~ "proves nothing; pivot stayed at " ~ pivotBefore.x.to!string ~ ","
        ~ pivotBefore.y.to!string ~ "," ~ pivotBefore.z.to!string);
    assert(!runIsHeld(),
        "relocating the action centre through the COMMAND surface must END "
        ~ "the held run, exactly as the click relocate already does");
    assertFrozen("ACEN-RELOCATE-ATTR", before);
    dropTool();
}

// ===========================================================================
// (ACEN-RELOCATE-XYZ) The per-component relocate route. Same law — it is the
// same user action with a different spelling.
// ===========================================================================
unittest {
    auto before = armAndLandGesture("ACEN-RELOCATE-XYZ", () {});
    cmd("tool.pipe.attr actionCenter userPlacedX 0.5");
    settle();
    assert(!runIsHeld(),
        "the per-component relocate (userPlacedX/Y/Z) must END the held run "
        ~ "like every other relocate route");
    assertFrozen("ACEN-RELOCATE-XYZ", before);
    dropTool();
}

// ===========================================================================
// (ACEN-RELOCATE-ELEMENT) The same relocate with an ELEMENT falloff live —
// task 0724's own fixture, which used to RE-GRADE here.
//
// The sphere centre is the pivot, so a relocate genuinely changes which
// vertices the falloff grades: v0 sits AT the old centre (weight 1, fully
// moved) and v6 is sqrt(3) away, outside the 1.2 sphere (weight 0, unmoved).
// A re-grade would swap their roles. Under the law it does not: the held
// result is frozen at the centre that produced it.
// ===========================================================================
unittest {
    auto before = armAndLandGesture("ACEN-RELOCATE-ELEMENT", () {
        cmd("tool.pipe.attr falloff type element");
        cmd("tool.pipe.attr falloff shape linear");
        cmd(`tool.pipe.attr actionCenter userPlacedCenter "-0.5,-0.5,-0.5"`);
        cmd("tool.pipe.attr falloff dist 1.2");
    });
    assert(!approxEq(before[0][0], -0.5, 1e-3),
        "setup: v0 sits AT the sphere centre (weight 1) and must have moved; "
        ~ "got v0.x=" ~ before[0][0].to!string);
    assert(approxEq(before[6][0], 0.5, 1e-3),
        "setup: v6 is sqrt(3) from the centre, outside the 1.2 sphere "
        ~ "(weight 0) and must be unmoved; got v6.x=" ~ before[6][0].to!string);

    cmd(`tool.pipe.attr actionCenter userPlacedCenter "0.5,0.5,0.5"`);
    settle();
    assert(!runIsHeld(),
        "an element-falloff relocate is still a relocate: it must END the held "
        ~ "run rather than re-weigh it (this reverses task 0724's headless-only "
        ~ "re-grade, which its own click route never did)");
    assertFrozen("ACEN-RELOCATE-ELEMENT", before);
    dropTool();
}

// ===========================================================================
// (FALLOFF-TYPE) The falloff slot's occupant. This one CHANGES DIRECTION: it
// used to re-grade (a `type` edit is a FalloffConfig field, so the packet
// compared unequal and the idle trigger fired).
// ===========================================================================
unittest {
    auto before = armAndLandGesture("FALLOFF-TYPE", () {
        cmd("tool.pipe.attr falloff type linear");
        cmd("tool.pipe.attr falloff shape linear");
        cmd(`tool.pipe.attr falloff center "0.2,0,0"`);
        cmd(`tool.pipe.attr falloff size "0.9,0.9,0.9"`);
    });
    cmd("tool.pipe.attr falloff type radial");
    settle();
    assert(!runIsHeld(),
        "switching which weighting tool is in the falloff slot is an "
        ~ "activation and must END the held run");
    assertFrozen("FALLOFF-TYPE", before);
    dropTool();
}

// ===========================================================================
// (FALLOFF-STACK) A falloff node ADDED to the slot — the reference's own
// falloff cell was an added node, not a swapped one.
// ===========================================================================
unittest {
    auto before = armAndLandGesture("FALLOFF-STACK", () {
        cmd("tool.pipe.attr falloff type linear");
        cmd("tool.pipe.attr falloff shape linear");
        cmd(`tool.pipe.attr falloff center "0.2,0,0"`);
        cmd(`tool.pipe.attr falloff size "0.9,0.9,0.9"`);
    });
    cmd("falloff.add radial");
    settle();
    assert(!runIsHeld(),
        "stacking another falloff node into the slot is an activation and "
        ~ "must END the held run");
    assertFrozen("FALLOFF-STACK", before);
    cmd("falloff.remove falloff#1");
    dropTool();
}

// ===========================================================================
// (AXIS-MODE) The axis slot. Nothing in the transform re-grade ever read it,
// so before 0791 an axis change mid-run was simply invisible.
// ===========================================================================
unittest {
    auto before = armAndLandGesture("AXIS-MODE", () {
        cmd("tool.pipe.attr axis mode auto");
    });
    cmd("tool.pipe.attr axis mode origin");
    settle();
    assert(!runIsHeld(),
        "changing which axis tool is in the axis slot is an activation and "
        ~ "must END the held run");
    assertFrozen("AXIS-MODE", before);
    dropTool();
}

// ===========================================================================
// (FALLOFF-ATTR) The OTHER half of the law, and the guard that stops the
// boundary from swallowing the idle re-grade whole: an ATTRIBUTE write on the
// slot's tool still re-weighs the held gesture in place.
//
// `size` 0.9 -> 3.0 widens the support so v6 (a far corner, weight 0 under the
// tight box) comes into range and moves. The run must SURVIVE it.
// ===========================================================================
unittest {
    auto before = armAndLandGesture("FALLOFF-ATTR", () {
        cmd("tool.pipe.attr falloff type radial");
        cmd("tool.pipe.attr falloff shape linear");
        cmd(`tool.pipe.attr falloff center "-0.5,-0.5,-0.5"`);
        cmd(`tool.pipe.attr falloff size "0.9,0.9,0.9"`);
    });
    assert(approxEq(before[6][0], 0.5, 1e-3),
        "setup: v6 must sit outside the tight 0.9 support (unmoved); got "
        ~ before[6][0].to!string);

    cmd(`tool.pipe.attr falloff size "3,3,3"`);
    settle();
    assert(runIsHeld(),
        "an ATTRIBUTE write is not an activation: the held run must SURVIVE "
        ~ "it and be re-weighed in place");
    auto after = dumpVerts();
    assert(!approxEq(after[6][0], before[6][0], 1e-3),
        "...and the re-weigh must actually reach the geometry: v6.x was "
        ~ before[6][0].to!string ~ ", still " ~ after[6][0].to!string
        ~ " after widening size to 3");
    dropTool();
}
