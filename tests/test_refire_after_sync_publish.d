// Task 1906 stage 1 — THE NEGATIVE CONTROL FOR THE SYNCHRONOUS PUBLISH: the
// in-session falloff re-grade must still fire after a committed gizmo gesture.
//
// ===========================================================================
// What could silently break, and why nothing else would notice
// ===========================================================================
// Stage 1 turned the three interactive-apply publishers into `publishChange`,
// which DELIVERS the `Position` class at the edit boundary. The half that is
// easy to get wrong is the other half: the drag must stay VERSION-SILENT.
//
// `XfrmTransformTool.lastAppliedGestureMutationVersion` is stamped with
// `mesh.mutationVersion` at every gesture's mouse-up commit, and the ARM-2
// re-grade fires only while the live version still EQUALS that stamp. So a
// `mutationVersion` bump anywhere on the interactive apply path — the obvious
// "while I am here, let me also bump the counter" edit — moves the version off
// the stamp and makes every later falloff tweak INERT. Nothing crashes,
// nothing logs, the geometry simply stops responding to the falloff panel. It
// is the exact defect task 0401 protected against, and it is what §2.2 means
// by "version counters own STRUCTURE, the bus's Position class owns POSITION".
//
// `tests/test_falloff_idle_refire.d` would eventually catch it, which is why
// this file does not duplicate its six attr cases. What this file adds is the
// pairing: the same re-grade, asserted TOGETHER with the delivery counter that
// proves the synchronous publish happened on that very gesture. A drag that
// delivered nothing and a drag that re-graded correctly are two different
// facts, and only asserting them on ONE gesture rules out "the publish was
// removed" and "the re-grade was removed" independently.
//
// ===========================================================================
// The second block: the decoupling CENSUS (plan §2.3)
// ===========================================================================
// The guard above is the one `mutationVersion` consumer this task keeps — it
// is a GESTURE-IDENTITY question ("has a foreign edit landed since my gesture
// committed?"), not a cache freshness key, and the bus has no class for it.
// Stage 1 ships the measurement that says whether it could one day be re-keyed
// on `CommandHistory.undoEpoch()`, the name of the event the guard's own doc
// block describes:
//
//     (mesh.mutationVersion == lastAppliedGestureMutationVersion)
//       == (history.undoEpoch() == armedUndoEpoch)
//
// evaluated at all four read sites and reported as
// `regradeCensusChecks` / `regradeCensusDisagreements` on `/api/changes`.
// It is a counter and not an `assert` in the editor binary for a lane reason:
// an `AssertError` there kills the main thread while the process lives on, and
// every later HTTP request then costs the full 120 s command-bridge timeout —
// the suite would HANG rather than report.
//
// The assert therefore lives HERE, in the test binary, where a failure is a
// failure. Both halves are asserted and both are load-bearing:
//
//   * `checks` must MOVE — a census that never evaluated makes a zero
//     disagreement count meaningless, and that is the "the run never happened"
//     shape;
//   * `disagreements` must stay 0 — the measured verdict on this tree
//     (2026-08-25). Mutation: delete `armedUndoEpoch`'s arm in
//     `armRegradeStamp` and this reddens with the count.

import std.net.curl;
import std.json;
import std.conv    : to;
import std.format  : format;
import std.math    : fabs;
import std.stdio   : writefln;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers;

void main() {}

enum BASE = "http://localhost:8080";

JSONValue getJson(string path) { return parseJSON(cast(string)get(BASE ~ path)); }

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

void settle() { Thread.sleep(180.msecs); }

long undoCount()  { return getJson("/api/history")["undo"].array.length; }
long deliveries() { return getJson("/api/changes")["deliveryCount"].integer; }
long censusChecks() {
    return getJson("/api/changes")["regradeCensusChecks"].integer;
}
/// The rows where the two terms were FREE to differ — the stamp armed. The
/// honest denominator; `censusChecks` counts the disarmed rows too, and a
/// disarmed row holds the same `ulong.max` sentinel on both terms and is
/// scored as an agreement it could not have avoided.
long censusArmedChecks() {
    return getJson("/api/changes")["regradeCensusArmedChecks"].integer;
}
long censusDisagreements() {
    return getJson("/api/changes")["regradeCensusDisagreements"].integer;
}

/// The primary layer's `mutationVersion` — the guard's own left-hand term, on
/// the wire. `/api/layers` is its only wire view.
long meshMutationVersion() {
    return getJson("/api/layers")["layers"].array[0]["mutationVersion"].integer;
}

double[3] vert(int i) {
    auto v = getJson("/api/model")["vertices"].array[i].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

bool approxEq(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

/// The live gizmo pivot — `axisGrabPx` needs it to find the +X arm.
Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating, cast(float)c[1].floating,
                cast(float)c[2].floating);
}

/// One committed +X move-arrow gesture, verified by the undo count rather than
/// assumed — a missed grab records nothing and orbits the camera instead.
/// Returns the `deliveryCount` delta across the gesture that actually landed.
long moveGestureOnArrow(long wantCount, double dragPx = 60.0) {
    foreach (attempt; 0 .. 6) {
        settle();
        auto cam = fetchCamera(BASE);
        auto vp  = viewportFromCamera(cam);
        int gx, gy;
        double ux, uy;
        axisGrabPx(evalPivot(), vp, gx, gy, ux, uy);
        const long d0 = deliveries();
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 gx, gy,
                                 gx + cast(int)(dragPx * ux),
                                 gy + cast(int)(dragPx * uy),
                                 10), BASE);
        settle();
        if (undoCount() == wantCount) return deliveries() - d0;
    }
    assert(false, "the move gesture never landed (undo count never reached "
                ~ wantCount.to!string ~ ")");
}

// ---------------------------------------------------------------------------
// (1) The gesture DELIVERS and the idle falloff tweak still RE-GRADES.
//
//     Rig lifted from `tests/test_falloff_idle_refire.d`'s (DIST) case: an
//     Element sphere anchored at the cube's (-0.5,-0.5,-0.5) corner with a
//     tight radius of 0.3, so the far corner v6 (distance sqrt(3)) sits
//     OUTSIDE it and does not move with the gesture. Widening the radius to
//     3.0 at idle brings v6 into range, and the committed gesture is re-graded
//     against the new weights.
//
//     A cube is legitimate here and nowhere else in this task: the claim is
//     about a WEIGHT, not about facing or occlusion, and v6's distance from
//     the anchor is what decides it.
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr actionCenter userPlacedCenter "-0.5,-0.5,-0.5"`);
    cmd("tool.pipe.attr falloff dist 0.3");
    settle();

    const long floor = undoCount();
    const long delivered = moveGestureOnArrow(floor + 1);

    // The stage-1 half: this gesture published synchronously. Without it the
    // re-grade assert below would still pass on a tree where the publish was
    // simply deleted, and the file would be pinning only half the change.
    assert(delivered > 0,
        format("the committed gesture must have DELIVERED its Position class "
             ~ "synchronously; deliveryCount moved by %d. A 0 is the "
             ~ "pre-stage-1 `noteChange` shape", delivered));

    const auto v6AfterGesture = vert(6);
    assert(approxEq(v6AfterGesture[0], 0.5, 1e-3),
        format("PREMISE: v6 must sit OUTSIDE the tight 0.3 sphere and be "
             ~ "unmoved by the gesture; its x is %g. If the gesture already "
             ~ "moved it, widening the radius below could not change anything "
             ~ "and the re-grade assert would be vacuous",
               v6AfterGesture[0]));

    // THE CELL: an idle falloff tweak on a COMMITTED gesture. This fires only
    // while `mesh.mutationVersion` still equals the stamp taken at mouse-up —
    // i.e. only while the drag path stayed version-silent.
    cmd("tool.pipe.attr falloff dist 3.0");
    settle();
    const auto v6Regraded = vert(6);
    assert(!approxEq(v6Regraded[0], v6AfterGesture[0], 1e-3),
        format("the in-session falloff re-grade did NOT fire: v6.x was %g and "
             ~ "is still %g after widening the Element radius to 3.0. The "
             ~ "ARM-2 gate is `mesh.mutationVersion == "
             ~ "lastAppliedGestureMutationVersion`, so this is what a "
             ~ "`mutationVersion` bump on the interactive apply path looks "
             ~ "like — the synchronous Position publish must NOT have brought "
             ~ "one with it", v6AfterGesture[0], v6Regraded[0]));

    cmd("tool.set move off");
    postJson("/api/reset", "");
}

// ---------------------------------------------------------------------------
// (2) The decoupling census — its own block, because druntime stops a module
//     at its first failed assert and the two facts fail for different reasons.
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr actionCenter userPlacedCenter "-0.5,-0.5,-0.5"`);
    cmd("tool.pipe.attr falloff dist 0.3");
    settle();

    const long checks0 = censusChecks();
    const long armed0 = censusArmedChecks();
    const long disagree0 = censusDisagreements();

    const long floor = undoCount();
    moveGestureOnArrow(floor + 1);
    cmd("tool.pipe.attr falloff dist 3.0");
    settle();
    // A second tweak, so the census also covers the CONSECUTIVE-re-grade path
    // (`replaceInSessionTail`) and `recordPipeRefire`'s own re-stamp, not just
    // the first crossing.
    cmd("tool.pipe.attr falloff dist 4.0");
    settle();

    const long checks = censusChecks() - checks0;
    const long armed = censusArmedChecks() - armed0;
    const long disagree = censusDisagreements() - disagree0;
    writefln("[regrade census] checks=%d armedChecks=%d disagreements=%d",
             checks, armed, disagree);

    // THE FLOOR IS THE ARMED COUNT, NOT THE RAW ONE (review B1). A DISARMED
    // row holds the `ulong.max` sentinel in BOTH terms, both compares answer
    // false, and it is scored as an agreement it could not have avoided — so a
    // `checks > 0` floor could rest on evaluations incapable of producing the
    // finding. Measured on this scenario: EVERY row armed (117 of 117, 120 of
    // 120 — the absolute count is an idle-frame count and varies run to run,
    // the ratio is 1), i.e. the disarmed row the review predicted (~76 of 122)
    // does not
    // occur here at all — the only live read site short-circuits on
    // `history.runOpen()`, and an open run implies a gesture that armed the
    // stamp. The floor reads `armed` anyway: it costs nothing and it is the
    // count that would still mean something if that ever changed.
    assert(armed > 0,
        format("the re-grade census never evaluated with the stamp ARMED — "
             ~ "`regradeCensusArmedChecks` did not move across a committed "
             ~ "gesture plus two idle falloff tweaks (raw checks moved by "
             ~ "%d). A zero disagreement count over zero ARMED checks is the "
             ~ "'the run never happened' shape: only an armed row can hold "
             ~ "two different values in the two terms, so a verdict supported "
             ~ "by disarmed rows says nothing at all", checks));

    assert(disagree == 0,
        format("the re-grade staleness guard's `mutationVersion` term "
             ~ "disagreed with the `CommandHistory.undoEpoch()` term %d time(s)"
             ~ " out of %d evaluations. The two are claimed equivalent by plan "
             ~ "§2.3, which is what would let the guard be re-keyed off the "
             ~ "version counters; a non-zero here is the FINDING, and it means "
             ~ "the recorded remainder stays", disagree, checks));

    cmd("tool.set move off");
    postJson("/api/reset", "");
}

// ---------------------------------------------------------------------------
// (3) THE DRIVEN CELL — the two events that can actually separate the terms.
//
//     Block (2) reports a verdict over rows the SUITE happened to produce.
//     That is not the same as entering the state where the equivalence could
//     fail. Measured, its ~120 evaluations are ALL armed — and all of them
//     are armed-and-nothing-happened: neither term moved in any of them, so
//     every one is an agreement by default. A verdict built only from those
//     rows is an untested premise wearing a number.
//
//     There are exactly two events that move one term without the other:
//
//       (a) an in-session `Ctrl+Z` — bumps `CommandHistory.undoEpoch()`;
//       (b) a FOREIGN edit — bumps `Mesh.mutationVersion` and NOT the epoch.
//
//     This block DRIVES both, with the run open and the stamp armed.
//
//     WHY THE READING IS A RATE AND NOT A DELTA, and it is the whole design of
//     the block. The ARM-2 site evaluates the guard on EVERY idle frame while
//     the run is open and the stamp armed, so a delta taken across an HTTP
//     round-trip counts the frames that elapsed BEFORE the event as well as
//     after it — measured, that alone contributes 2 armed rows and it is what
//     a first version of this block mistook for "armed rows survived the
//     event". So each case reads a STEADY-STATE RATE: armed rows per settle
//     window, once before the event and once after it. A rate that falls to
//     zero says the event disarmed the guard; a rate that stays up says the
//     guard is still being asked, and `disagreements` beside it is then a real
//     verdict rather than silence.
// ---------------------------------------------------------------------------

/// Armed evaluations per settle window — the steady-state rate of the ARM-2
/// site. Two reads around one settle, so it cannot be confounded by whatever
/// happened before the first one.
long armedRatePerSettle() {
    const long a0 = censusArmedChecks();
    settle();
    return censusArmedChecks() - a0;
}

unittest {
    postJson("/api/reset", "");
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr actionCenter userPlacedCenter "-0.5,-0.5,-0.5"`);
    cmd("tool.pipe.attr falloff dist 0.3");
    settle();

    // ---------------------------------------------------------------------
    // (a) IN-SESSION Ctrl+Z, with the gesture's run still open.
    // ---------------------------------------------------------------------
    const long floorA = undoCount();
    moveGestureOnArrow(floorA + 1);

    // POSITIVE CONTROL for the whole block: with the gesture committed and the
    // run open, the guard is ARMED and the ARM-2 site evaluates it every idle
    // frame. If this rate is zero, nothing measured below is a measurement of
    // the census — it is a measurement of a tool that stopped asking.
    const long preUndoRate = armedRatePerSettle();
    assert(preUndoRate > 0,
        "PREMISE: with a committed gesture and an open run the ARM-2 site "
      ~ "must evaluate the ARMED guard on idle frames, and the rate is 0. "
      ~ "With no armed evaluation at all, neither driven case below could "
      ~ "distinguish 'the terms agreed' from 'nothing was asked'");

    const long uChecks0 = censusChecks();
    const long uArmed0  = censusArmedChecks();
    const long uDis0    = censusDisagreements();
    const long uVer0    = meshMutationVersion();
    const long uEpochUndoDepth = undoCount();

    cmd("history.undo");
    settle();

    const long uChecksWindow = censusChecks() - uChecks0;
    const long uArmedWindow  = censusArmedChecks() - uArmed0;
    const long uDisWindow    = censusDisagreements() - uDis0;
    const long uVerDelta     = meshMutationVersion() - uVer0;
    const long postUndoRate  = armedRatePerSettle();
    // Read AFTER the rate window, so the total covers the event frame, the
    // settle behind it and one further steady-state window.
    const long uDisTotal     = censusDisagreements() - uDis0;

    writefln("[regrade census / driven] undo: preRate=%d postRate=%d "
           ~ "windowArmed=%d windowChecks=%d windowDisagreements=%d "
           ~ "mutationVersionDelta=%d",
             preUndoRate, postUndoRate, uArmedWindow, uChecksWindow,
             uDisWindow, uVerDelta);

    // POSITIVE CONTROL: the undo actually landed. Without it every count above
    // is the count of a step that did nothing.
    assert(undoCount() == uEpochUndoDepth - 1,
        format("PREMISE: `history.undo` must have popped the gesture — the "
             ~ "undo depth is %d and was %d. A refused undo drives no cell "
             ~ "and bumps no epoch", undoCount(), uEpochUndoDepth));

    // ---------------------------------------------------------------------
    // (b) A FOREIGN mutationVersion bump, again with the run open and armed.
    // ---------------------------------------------------------------------
    postJson("/api/reset", "");
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr actionCenter userPlacedCenter "-0.5,-0.5,-0.5"`);
    cmd("tool.pipe.attr falloff dist 0.3");
    settle();

    const long floorB = undoCount();
    moveGestureOnArrow(floorB + 1);

    const long preForeignRate = armedRatePerSettle();
    assert(preForeignRate > 0,
        "PREMISE: the second gesture must leave the guard armed and asked "
      ~ "too — the armed rate before the foreign edit is 0");

    const long fChecks0 = censusChecks();
    const long fArmed0  = censusArmedChecks();
    const long fDis0    = censusDisagreements();
    const long fVer0    = meshMutationVersion();

    // `mesh.subdivide` is the foreign edit: a command the TOOL did not make,
    // which bumps `mutationVersion` and leaves `undoEpoch` alone. That is
    // exactly the asymmetry the equivalence claims cannot happen.
    postJson("/api/command", `{"id":"mesh.subdivide"}`);
    settle();

    const long fChecksWindow = censusChecks() - fChecks0;
    const long fArmedWindow  = censusArmedChecks() - fArmed0;
    const long fDisWindow    = censusDisagreements() - fDis0;
    const long fVerDelta     = meshMutationVersion() - fVer0;
    const long postForeignRate = armedRatePerSettle();
    const long fDisTotal     = censusDisagreements() - fDis0;

    writefln("[regrade census / driven] foreign bump: preRate=%d postRate=%d "
           ~ "windowArmed=%d windowChecks=%d windowDisagreements=%d "
           ~ "mutationVersionDelta=%d",
             preForeignRate, postForeignRate, fArmedWindow, fChecksWindow,
             fDisWindow, fVerDelta);

    // POSITIVE CONTROL: the foreign edit really moved the term it is here to
    // move. A subdivide that refused would bump nothing, and the cell would be
    // "nothing happened" wearing the cell's name.
    assert(fVerDelta != 0,
        "PREMISE: the foreign `mesh.subdivide` must have bumped "
      ~ "`mutationVersion` — it did not move, so no term was separated and "
      ~ "the reading above is not the driven cell");

    // ===================================================================
    // THE VERDICT — MEASURED 2026-08-25, AND IT IS NOT "THE TERMS AGREE"
    // ===================================================================
    // Readings, both cases: preRate 37 / 34 armed rows per settle, postRate
    // **0**, disagreements 0 throughout, `mutationVersion` delta +1 on the
    // undo and **-5** on the foreign edit.
    //
    // Read those together and the census answers a DIFFERENT question from the
    // one plan §2.3 posed:
    //
    //   * ON THE UNDO the two terms move TOGETHER, so they cannot separate.
    //     `undoEpoch` bumps, and the revert bumps `mutationVersion` too —
    //     `MeshVertexEdit.revert` ends in `commitChange(Position)`. The
    //     equivalence holds here for a REASON, not by luck.
    //   * ON THE FOREIGN EDIT they would separate — the version moves, the
    //     epoch does not — and the guard IS NEVER ASKED. The armed rate falls
    //     to 0 across the event, because two independent guards consume it
    //     before the next ARM-2 read:
    //       - the foreign edit is a COMMAND, and `CommandHistory`'s
    //         foreign-record guard (`consolidateOpenRunIfForeign`) closes the
    //         open run first, so `history.runOpen()` is already false and the
    //         ARM-2 branch short-circuits before the version term;
    //       - the wrapper's own selection/mutation-change boundary at the TOP
    //         of `update()` (`curMutVer != lastMutationVersion`) calls
    //         `invalidateRunRefireAnchor()`, which writes `ulong.max` into
    //         `lastAppliedGestureMutationVersion` AND `armedUndoEpoch` in the
    //         same statement pair.
    //
    // So the census does NOT establish that the guard could be re-keyed on
    // `undoEpoch`. It establishes that the ONLY cell where the two keys could
    // differ is unreachable at the read site — every event that would separate
    // them also disarms the guard on its way past. That is the answer recorded
    // against open question #21, and it is a stronger claim about the CODE and
    // a weaker one about the EQUIVALENCE than "0 disagreements out of 120".
    //
    // A third reading falls out of the same run and is worth its line:
    // `mutationVersion` went **backwards** (-5) across `mesh.subdivide`,
    // because that command replaces the mesh wholesale (`*mesh = …`) and the
    // fresh value starts from 0. A version key that can DECREASE cannot carry
    // "gesture identity" on its own — a foreign edit could in principle land
    // the counter back ON the stamp. Live only because the two disarms above
    // fire first; named here so a future re-key does not inherit the
    // assumption that the counter is monotone.
    // ===================================================================
    assert(uDisTotal == 0 && fDisTotal == 0,
        format("the re-grade staleness guard's `mutationVersion` term "
             ~ "disagreed with the `CommandHistory.undoEpoch()` term in a "
             ~ "DRIVEN cell: %d time(s) across the in-session undo and %d "
             ~ "time(s) across the foreign edit. A non-zero here is the "
             ~ "FINDING plan §2.3 asked for — the two are NOT equivalent, the "
             ~ "guard cannot be re-keyed on `undoEpoch`, and #21's recorded "
             ~ "remainder stays for good. NOTE the companion assert below: on "
             ~ "this tree these zeros are mostly SILENCE, so a disagreement "
             ~ "appearing here means something upstream also stopped disarming",
               uDisTotal, fDisTotal));

    assert(postUndoRate == 0 && postForeignRate == 0,
        format("the guard is STILL ARMED AND ASKED after a separating event: "
             ~ "%d armed rows per settle after the in-session undo (was %d "
             ~ "before it), %d after the foreign edit (was %d). On this tree "
             ~ "both must fall to 0 — `consolidateOpenRunIfForeign` closes the "
             ~ "run and the wrapper's selection/mutation boundary "
             ~ "(`invalidateRunRefireAnchor`, which disarms BOTH terms in one "
             ~ "statement pair) consume the event before the next ARM-2 read. "
             ~ "A non-zero means one of those two stopped consuming it — and "
             ~ "the census is then finally being asked the question it exists "
             ~ "to answer, so read `disagreements` for the answer rather than "
             ~ "restoring the guard blindly",
               postUndoRate, preUndoRate, postForeignRate, preForeignRate));

    // The version key is not monotone across a wholesale mesh replace. Pinned
    // because the assert above is only interesting while this is true: a key
    // that can move BACKWARDS is not a gesture identity, and that is half the
    // reason #21 stays a recorded remainder rather than a re-key.
    assert(fVerDelta < 0,
        format("`mesh.subdivide` was measured to RESET `mutationVersion` (the "
             ~ "`*mesh = …` swap starts a fresh counter): the delta was %d, "
             ~ "and a non-negative value here means the command now carries "
             ~ "its counter across. That is a better world, but it changes "
             ~ "what the re-grade guard's version compare means — re-read "
             ~ "plan §2.3 before treating this as a harmless improvement",
               fVerDelta));

    cmd("tool.set move off");
    postJson("/api/reset", "");
}
