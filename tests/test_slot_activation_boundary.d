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

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math   : fabs;
import std.conv   : to;

import drag_helpers;

void main() {}

alias baseUrl = testBaseUrl;


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

// Land ONE committed +X move-arrow gesture against the CURRENT gizmo pivot.
// Readiness is the tail's `inSession` bit, not raw list length: the measured
// surface in `toolcards/undo_surfaces/` adds the arm row, and at maxDepth=50 a
// successful append evicts the head while length stays 50.  Waiting for 51
// therefore made a landed gesture look like a miss.
void moveGestureOnArrow(double dragPx = 60.0) {
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
        if (runIsHeld()) return;
    }
    assert(false, "move gesture did not land (history tail never became in-session)");
}

// Arm a Move tool on a pristine cube, run `setup`, land one gesture, and
// return the post-gesture geometry. Asserts the precondition every cell needs:
// the landed gesture must leave an OPEN in-session run, or the cell is testing
// nothing.
double[3][] armAndLandGesture(string cellName, void delegate() setup) {
    postJson("/api/command", commandBody("scene.reset"));
    cmd("tool.set move");
    setup();
    settle();
    moveGestureOnArrow();
    settle();
    assert(runIsHeld(),
        "setup: the landed gesture must leave an OPEN in-session run for cell "
        ~ cellName ~ " to test anything");
    return dumpVerts();
}

void dropTool() {
    cmd("tool.set move off");
    postJson("/api/command", commandBody("scene.reset"));
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

// ===========================================================================
// (ROTATE-PANEL-SESSION) The boundary closes ALL THREE banks, not just Move.
//
// A panel-driven rotate (tool.beginSession + tool.attr RZ) leaves a Rotate
// sub-tool session open with a held, uncommitted angle. Before 0791 the idle
// slot poll committed only the wrapper's Move session, so an activation could
// leave that session open — the run ended around it. The boundary now commits
// the rotate and the scale sessions too, which is what "the held OPERATION
// ends" means when the preset composes more than one bank.
//
// Witness: the open session's edit lands as a committed undo entry at the
// activation (it is not left dangling), and the rotated geometry stays put.
// ===========================================================================
unittest {
    postJson("/api/command", commandBody("scene.reset"));
    cmd("tool.set Transform on");
    cmd("tool.pipe.attr actionCenter mode origin");
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "0,0,0"`);
    cmd(`tool.pipe.attr falloff size "40000,40000,40000"`);
    settle();

    cmd("tool.beginSession Transform");
    cmd("tool.attr Transform RZ 90");
    settle();
    auto held = dumpVerts();
    assert(!approxEq(held[0][0], -0.5, 1e-3),
        "setup: the panel rotate must have moved v0 off its pristine x; got "
        ~ held[0][0].to!string);
    long undosHeld = undoCount();

    // Activate the falloff slot while that session is open.
    cmd("tool.pipe.attr falloff type linear");
    settle();

    assert(undoCount() >= undosHeld,
        "the open panel session must be COMMITTED at the boundary, not "
        ~ "discarded: undo count went from " ~ undosHeld.to!string ~ " to "
        ~ undoCount().to!string);
    auto after = dumpVerts();
    foreach (i; 0 .. held.length)
        foreach (k; 0 .. 3)
            assert(approxEq(after[i][k], held[i][k], 1e-3),
                "the held rotate must stay frozen across the slot activation; "
                ~ "v" ~ i.to!string ~ " comp " ~ k.to!string ~ " was "
                ~ held[i][k].to!string ~ ", now " ~ after[i][k].to!string);

    cmd("tool.set Transform off");
    postJson("/api/command", commandBody("scene.reset"));
}

// ===========================================================================
// (SLOT-REFIRE) Re-issuing the tool ALREADY in the slot ends the run too.
//
// This is the cell nobody guesses, and it is why the check counts WRITES
// instead of comparing values. The reference was measured twice on it: once on
// the action-centre slot (a slot holding a tool, that exact tool re-issued) and
// once on the falloff slot. Both end the held operation even though the
// pipeline is byte-identical across the change — so the trigger is the
// activation EVENT.
//
// Here the falloff type is written with the value it ALREADY has. A
// signature-over-values would see nothing; the run must end anyway.
// ===========================================================================
unittest {
    auto before = armAndLandGesture("SLOT-REFIRE", () {
        cmd("tool.pipe.attr falloff type linear");
        cmd("tool.pipe.attr falloff shape linear");
        cmd(`tool.pipe.attr falloff center "0.2,0,0"`);
        cmd(`tool.pipe.attr falloff size "0.9,0.9,0.9"`);
    });
    // The SAME value the slot already holds.
    cmd("tool.pipe.attr falloff type linear");
    settle();
    assert(!runIsHeld(),
        "re-issuing the tool already in the slot is still an ACTIVATION and "
        ~ "must END the held run — a value comparison cannot see this case, "
        ~ "which is the whole reason the check counts writes");
    assertFrozen("SLOT-REFIRE", before);
    dropTool();
}

// ===========================================================================
// (SYMMETRY-SLOT) A symmetry change ends the held run.
//
// Measured late (task 0791 waves 2-3) and reversing what we shipped: both of
// the reference's symmetry commands end a held operation with the same
// activation bracket every other closing slot uses. Symmetry has no
// attribute-shaped half there, so EVERY symmetry write arms the slot here.
//
// The companion is (SNAP-SLOT) below: the two were measured in the same boot
// and they answer DIFFERENTLY, which is why neither is assumed from the other.
// ===========================================================================
unittest {
    auto before = armAndLandGesture("SYMMETRY-SLOT", () {
        cmd("tool.pipe.attr symmetry enabled 0");
    });
    cmd("tool.pipe.attr symmetry enabled 1");
    settle();
    assert(!runIsHeld(),
        "a symmetry change is a slot activation and must END the held run");
    assertFrozen("SYMMETRY-SLOT", before);
    cmd("tool.pipe.attr symmetry enabled 0");
    dropTool();
}

// ===========================================================================
// (SNAP-SLOT) A snap change does NOT end the held run — the one slot that
// does not follow the rule.
//
// Measured: arming a snap tool while an operation is held leaves it untouched.
// The reference's own trace shows why — the pipe activation runs, but no
// reflux bracket opens and nothing is rolled back. So this cell is not an
// omission, it is the counter-example that stops "activating a slot ends the
// run" from being over-applied.
// ===========================================================================
unittest {
    auto before = armAndLandGesture("SNAP-SLOT", () {
        cmd("tool.pipe.attr snap enabled false");
    });
    cmd("tool.pipe.attr snap enabled true");
    settle();
    assert(runIsHeld(),
        "a snap change must NOT end the held run — measured on the reference, "
        ~ "snap is the slot whose activation opens no bracket at all");
    assertFrozen("SNAP-SLOT", before);
    cmd("tool.pipe.attr snap enabled false");
    dropTool();
}

// ===========================================================================
// (SYMMETRY-VIA-ITS-OWN-COMMAND) The same activation through the route a USER
// actually takes.
//
// (SYMMETRY-SLOT) above drives `tool.pipe.attr symmetry enabled 1` — the
// headless spelling. The symmetry button and its keyboard shortcut fire
// `symmetry.toggle`, which writes the stage DIRECTLY instead of going through
// the pipe-attr command. This cell exists because that difference is invisible
// to every other cell here: the law was implemented by counting writes at the
// command sites, and an unlisted site is exactly the failure mode that kind of
// trigger has.
//
// Found by asking what the mutation numbers actually meant, not by a test
// failing: five of the eight counted sites could be deleted with the whole
// suite still green, which says the suite cannot defend the enumeration. This
// is that hole, made into a cell.
// ===========================================================================
unittest {
    auto before = armAndLandGesture("SYMMETRY-VIA-COMMAND", () {
        cmd("tool.pipe.attr symmetry enabled 0");
    });
    cmd("symmetry.toggle");
    settle();
    assert(!runIsHeld(),
        "a symmetry change through its OWN command must END the held run, "
        ~ "exactly as the pipe-attr spelling does — the user does not know "
        ~ "which route the UI took");
    assertFrozen("SYMMETRY-VIA-COMMAND", before);
    cmd("tool.pipe.attr symmetry enabled 0");
    dropTool();
}

// ===========================================================================
// (ACEN-PRESET-COMMAND) The action centre armed through its own preset command.
//
// `actr.<mode>` does not write the stage through `tool.pipe.attr` — it calls
// the stage's setUserMode, which the write funnel does not see. It therefore
// carries its own count, and this cell is what says so: the same audit that
// found the symmetry-toggle hole flags every command that reaches a stage by
// another door, and reading the code is not how that one was settled.
// ===========================================================================
unittest {
    auto before = armAndLandGesture("ACEN-PRESET-COMMAND", () {});
    cmd("actr.origin");
    settle();
    assert(!runIsHeld(),
        "the action-centre PRESET command must END the held run — it arms the "
        ~ "slot through setUserMode, which the setAttr funnel never sees");
    assertFrozen("ACEN-PRESET-COMMAND", before);
    dropTool();
}

// ===========================================================================
// (FALLOFF-REMOVE) A falloff node REMOVED from the slot.
//
// (FALLOFF-STACK) covers adding one. Removal takes yet another door — it
// unplugs the stage from the pipeline rather than writing any attribute — so
// it is covered, if at all, by the slot signature folding over the LIVE stage
// list. Same audit, same rule: measure the door, do not read it.
// ===========================================================================
unittest {
    auto before = armAndLandGesture("FALLOFF-REMOVE", () {
        cmd("tool.pipe.attr falloff type linear");
        cmd("tool.pipe.attr falloff shape linear");
        cmd(`tool.pipe.attr falloff center "0.2,0,0"`);
        cmd(`tool.pipe.attr falloff size "0.9,0.9,0.9"`);
        cmd("falloff.add radial");
        // The stacked node must not zero the weights, or the gesture records
        // nothing and the cell fails in its setup instead of its subject.
        cmd(`tool.pipe.attr falloff#1 center "0,0,0"`);
        cmd(`tool.pipe.attr falloff#1 size "20,20,20"`);
        cmd("tool.pipe.attr falloff#1 shape linear");
    });
    cmd("falloff.remove falloff#1");
    settle();
    assert(!runIsHeld(),
        "removing a falloff node from the slot must END the held run, like "
        ~ "adding one does");
    assertFrozen("FALLOFF-REMOVE", before);
    dropTool();
}

// ===========================================================================
// (WORKPLANE-SLOT) The work plane ends the held run.
//
// Measured on the reference late (task 0791 wave 10), on a slot that had been
// named as unmeasured rather than guessed: fitting the plane to the selection,
// OFFSETTING it and RESETTING it all end a held operation, each with the same
// activation bracket the other closing slots use. Like symmetry — and unlike
// falloff — it does not split into an activation half and an attribute half,
// so every write here arms the slot.
//
// Our workplane commands reach the stage through its own mutators rather than
// through an attribute write, which is the door class this task keeps finding,
// so the mutators count themselves. The one exception is `reset()`: that is
// also the stage's lifecycle hook (scene reset, tool switch), so the COMMAND
// counts instead — a lifecycle event is not a user arming anything.
// ===========================================================================
unittest {
    auto before = armAndLandGesture("WORKPLANE-SLOT", () {});
    cmd("workplane.offset axis:Y dist:0.5");
    settle();
    assert(!runIsHeld(),
        "a work-plane change must END the held run — measured on the reference "
        ~ "for fit / offset / reset alike");
    assertFrozen("WORKPLANE-SLOT", before);
    cmd("workplane.reset");
    dropTool();
}
