// test_gesture_zero_delta_undo_divergence — task 2640's measured law, wired to
// a live check as a KNOWN DIVERGENCE (self-retiring, red in BOTH directions).
//
// THE LAW, measured and frozen in `tests/fixtures/gesture_zero_delta_undo.json`
// (task 2640, verdict (b), live captures on fresh reference processes):
//
//   A COMMITTED GESTURE COSTS UNDO STEPS EVEN WHEN IT CHANGED NOTHING.
//   A press-move-release on a transform handle that never leaves the press
//   pixel leaves the mesh byte-identical and still adds TWO undo entries —
//   against ZERO for an otherwise identical run with no press at all, and
//   THREE for the same gesture with a real displacement.
//
// WE DO NOT DO THAT, and this file is the record of the difference.
// `TransformTool.commitEdit` (source/tools/transform/transform.d) builds the
// undo record with `buildEditCmd`, which returns null when no position moved
// (and when no capture session was ever opened), and `commitEdit` then returns
// BEFORE `recordCommit`. Measured here: our zero-distance gesture adds ZERO
// undo steps. Registry row 86 in `doc/behavior_gap_registry.md`.
//
// Which of the two nulls we take is deliberately NOT asserted: the fixture's
// own `not_measured` says the decision to record being taken before or after
// the gesture runs is observationally identical, and it is identical here too.
//
// WHY THIS FILE AND NOT `runKnownDivergenceSuite`. That runner — and its
// command-level sibling `runCommandDivergenceSuite` — recompute the gap between
// two frozen VERTEX / FACE / selection / applied observations. The gap here
// lives in none of them: it is a COUNT OF UNDO STEPS, a dimension neither
// runner measures, and the reference side has no coordinates to freeze at all
// (its stand and its drag distance are its own; only the entry COUNTS and the
// undo INDICES were captured). Feed this to a vertex-set comparison and you get
// an empty difference, i.e. a green test that has measured nothing. What is
// ported here is the runners' DISCIPLINE, which is the load-bearing part:
//
//   (1) our live output still equals what we froze  — a plain regression pin;
//   (2) the reference's frozen measurement is untouched — read from the fixture,
//       and re-derived from that fixture's OWN undo indices, so a half-edited
//       fixture fails instead of silently moving the target;
//   (3) the gap RECOMPUTED between (1) and (2) is EXACTLY the declared gap —
//       narrow it in either direction and this file goes red, which is the
//       prompt to re-measure and to retire the marker once it closes.
//
// THE STATUS TOKEN IS THE RETIREMENT SWITCH. `kStatus` is checked to be exactly
// "open" or "closed" (a typo must not silently pick a branch), and the "closed"
// branch demands PARITY. Porting the law is then a real two-line edit: flip the
// token and re-freeze `kOursZeroSteps`.
//
// SCOPE — DELIBERATELY NARROWER THAN "UNDO". The fixture's own `not_measured`
// list ends with "whether tools outside the transform family behave the same",
// so nothing here is asserted about any tool outside that family. Every cell
// drives the TRANSFORM tool (`tool.set move on`, the +X move arrow), which is
// the family the capture drove, and the failure messages say so.
//
// THE INSTRUMENT IS THE CAPTURE'S OWN, AND THE ABSOLUTE INDEX IS NOT COMPARABLE.
// The reading is `steps(N) = kB(N) - kB(control)`, where kB is the index of the
// undo that reverts the edit PRECEDING the gesture under test. The absolute kB
// differs between engines — what else sits on the stack is engine bookkeeping —
// and the DIFFERENCE against a control run identical except for the button
// press is the engine-independent quantity the fixture's `rig.reading` defines.
// Measured here: kB = 1 / 1 / 2 for control / zero-distance / real drag,
// against the reference's 4 / 6 / 7.
//
// TWO DEPARTURES FROM THE CAPTURE'S RIG. Both were forced by measurement, both
// BUY evidence rather than spend it, and neither touches the reading above.
//
//   (a) N IS DRIVEN ON E2'S OWN SELECTION, not on a third disjoint set. The
//       capture used a third set for a reason that is purely about the
//       reference's GUI (its handle localiser needs a centred handle, and a set
//       that has already moved carries its handle out of frame). We localise
//       the arm analytically. Keeping the extra selection would COST evidence:
//       in this engine a selection change is itself an undo entry, it would sit
//       on top of the gesture's window, and "the first undo after the gesture"
//       would then answer the same way whether the gesture recorded anything or
//       not — a check satisfied by the broken code too.
//
//   (b) THE TOOL IS NOT DROPPED AFTER N. In the reference the drop is what
//       commits an engaged tool; here the commit boundary is the MOUSE-UP, and
//       the positive control proves it (its entry is on the stack with no drop
//       anywhere). Dropping would have the same effect as (a) for a different
//       reason: `ToolDeactivationCommand` records a `HistoryFlags.ToolLifecycle`
//       entry, invisible in `/api/history` but real on the raw undo stack, and
//       `CommandHistory.undo`'s (R1) rule makes a lifecycle tail a HARD STEP
//       when the entry below it is also a lifecycle one. Measured on this tree:
//       with the drop, the control's kB moves 1 → 2 and its first undo stops
//       being the one that reverts E2. Every cell would then look like the
//       reference for a reason that has nothing to do with the law.
//
//       That measurement is itself an ADJACENT FACT this file does NOT claim —
//       see "WHAT IS NOT COVERED" below.
//
// ANTI-VACUITY, and it is not decoration. Every undo-step reading below is
// satisfied just as well by a gesture that NEVER HAPPENED — deleting the press
// records nothing too. Six guards, four of them the fixture's own
// `validity_checks`:
//   * the grab pixel is computed the same way in all three cells and asserted
//     IDENTICAL, so the zero-distance press lands on the same pixel the
//     positive control presses;
//   * the positive control, pressing that same pixel with the same
//     choreography, MUST move the mesh and MUST cost an undo step — which is
//     what proves a press at that pixel engages the transform tool at all.
//     (It is deliberately NOT claimed to prove the ARROW was grabbed: measured
//     on this tree, a press-drag anywhere in the viewport with the tool armed
//     moves the selection too, by more. The law does not turn on which handle
//     the gesture used, only on the gesture being committed.);
//   * the zero-distance cell must produce change-bus DELIVERIES where the
//     control produces none. This is the guard that separates "the gesture ran
//     and recorded nothing" from "the press was never delivered, so nothing
//     happened" — without it, deleting the press outright leaves every other
//     assertion in this file exactly as green;
//   * the zero-distance cell's mesh MUST be byte-identical across the gesture,
//     because "the delta is empty" is the premise of the law, not a conclusion;
//   * the two preceding real edits (E1, E2) must each move the mesh, or there
//     is nothing on the stack for the undo walk to be about;
//   * and the one departure (b) exists for: in the CONTROL cell the first undo
//     MUST revert E2, and in the POSITIVE cell it must NOT. Without that pair,
//     "the first undo did not revert the preceding edit" could be a green
//     produced by some unnamed neighbour on the stack and would distinguish no
//     candidate law at all.
//
// WHAT IS NOT COVERED, and why — read this before adding to it.
//   * `assertions_for_a_port[3]` is covered for a tool ARMED and left armed
//     (parity: costs nothing, measured against a fourth cell that never arms
//     the tool at all — a vibe3d-side baseline the capture has no counterpart
//     for, and without which that row would compare 0 against 0 by
//     construction). Its "and DROPPED" half is NOT: our drop records
//     a `ToolLifecycle` entry where the reference logs no command at all, but
//     whether that entry costs the user an undo STEP is stack-shape dependent
//     (transparent over a model entry, a hard step over another lifecycle one),
//     and the capture drove only one shape. Over-claiming a flat divergence
//     there would freeze a number nobody measured. Recorded as an adjacent
//     fact on registry row 86 instead.
//   * Nothing about tools outside the transform family (the fixture's own
//     `not_measured`).
//   * Nothing about redo: the fixture makes no redo claim, so neither does this.
//   * Nothing about WHAT the reference's two entries are. `decomposition.
//     not_measured` says that channel counted entries and did not name them.
//
// MUTATIONS THAT REDDEN IT, both run on this tree 2026-08-30, in isolation
// (druntime stops a module at its first failed assert, so a mutation that
// reddens several blocks shows only the first unless the earlier ones are
// removed for the run):
//
//   M1 — CLOSE THE GAP IN THE PRODUCT. `buildEditCmd`'s `if (!changed) return
//        null;` -> `if (false) return null;`
//        (source/tools/transform/transform.d), rebuilt, and the app relaunched
//        off the mutated binary (verified through /proc/PID/exe, because a
//        rebuild leaves the previous instance running a deleted image).
//        Block 3 reddens: "DIVERGENCE CLOSED: the first undo after a committed
//        zero-delta transform gesture no longer reverts the preceding edit".
//        With block 3 removed, block 5 reddens: "the zero-delta gesture now
//        shifts the preceding edit's undo index by 1 (kB 2 against the
//        control's 1)". With 3, 4 and 5 removed, block 6 reddens: "a committed
//        zero-delta transform gesture now costs 1 undo steps; this file froze
//        0".
//
//   M3 — MAKE THE PARITY ROW FALSE. Drop the tool inside the control cell's
//        gesture window (`if (d.armTool && !d.press) script("tool.set move
//        off");` in `runCell`). Block 1's calibration guard reddens first
//        ("the positive control cost 0 undo steps"), because the control's kB
//        moves with it; with block 1 removed, block 2 — the parity row —
//        reddens: "arming the transform tool over the same stand cost 1 undo
//        steps (kB 2 against the never-armed baseline's 1)". That is also the
//        measurement behind adjacent fact (a) above.
//
//   M2 — DELETE THE GESTURE. `if (d.press)` -> `if (d.press && d.gesture !=
//        "zero")` in `runCell`, i.e. the zero cell stops pressing at all.
//        EVERY undo-step reading in this file stays exactly as it was — which
//        is the whole point — and block 1's delivery guard is the only thing
//        that reddens: "the zero-distance gesture produced 0 change-bus
//        deliveries against the control's 0 — the press was never delivered".

import std.json;
import std.net.curl : get, post;
import std.format   : format;
import std.math     : fabs, sqrt;
import core.thread  : Thread;
import core.time    : msecs;

import drag_helpers;

void main() {}

// The literal is spelled out because run_test.d rewrites "localhost:8080"
// per worker for parallel runs — do not build it dynamically.
enum BASE = "http://localhost:8080";

enum string kFixtureJson = import("fixtures/gesture_zero_delta_undo.json");

// ---------------------------------------------------------------------------
// OUR SIDE, FROZEN. Measured on this tree 2026-08-30 through the rig below.
// These are the `vibe3d_current` half of the divergence: change our behaviour
// and (1) reddens even when the gap happens to stay the same size.
//
// Steps are RELATIVE to the control run, exactly as the fixture reads them.
// ---------------------------------------------------------------------------
enum long kOursControlSteps  = 0;   // tool armed, no press
enum long kOursZeroSteps     = 0;   // committed zero-distance gesture
enum long kOursPositiveSteps = 1;   // committed real drag

/// The retirement switch. "open" — we still differ, assert the gap.
/// "closed" — the law is ported, assert PARITY instead.
enum string kStatus = "open";

// ---------------------------------------------------------------------------
// HTTP plumbing
// ---------------------------------------------------------------------------
JSONValue getJson(string p)  { return parseJSON(cast(string) get(BASE ~ p)); }
JSONValue postJson(string p, string b) {
    return parseJSON(cast(string) post(BASE ~ p, b));
}

void settle() { Thread.sleep(250.msecs); }

void script(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        format("/api/command '%s' failed: %s", line, r.toString));
}

double[][] verts() {
    double[][] o;
    foreach (v; getJson("/api/model")["vertices"].array) {
        double[] a;
        foreach (c; v.array) a ~= c.floating;
        o ~= a;
    }
    return o;
}

bool meshEq(const double[][] a, const double[][] b) {
    if (a.length != b.length) return false;
    foreach (i, row; a) {
        if (row.length != b[i].length) return false;
        foreach (k, c; row) if (fabs(c - b[i][k]) > 1e-9) return false;
    }
    return true;
}

/// Depth of the VISIBLE undo stack. `/api/history` filters
/// `HistoryFlags.ToolLifecycle`, so this is not the raw stack — see the
/// coupling assertion in block 6 for exactly what that buys and costs.
long visibleUndoDepth() { return getJson("/api/history")["undo"].array.length; }

/// Change-bus deliveries so far. The gesture's own witness: it moves whether
/// or not the gesture leaves anything on the undo stack, so it can tell "ran
/// and recorded nothing" from "never ran".
long deliveries() { return getJson("/api/changes")["deliveryCount"].integer; }

/// The live gizmo pivot — the point `axisGrabPx` needs to find the +X arm.
Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float) c[0].floating, cast(float) c[1].floating,
                cast(float) c[2].floating);
}

void selectVerts(const int[] idx) {
    string s = "[";
    foreach (k, v; idx) { if (k) s ~= ","; s ~= format("%d", v); }
    s ~= "]";
    auto r = postJson("/api/select",
                      format(`{"mode":"vertices","indices":%s}`, s));
    assert(r["status"].str == "ok",
        format("select %s failed: %s", idx, r.toString));
}

// ---------------------------------------------------------------------------
// The rig
// ---------------------------------------------------------------------------

/// What one cell drives, read out of the fixture's own retained drive record
/// (`parameters.cells[].drove[0].values`) rather than re-typed here.
struct CellDrive {
    string id;
    string gesture;     // "none" | "zero" | "linear"
    bool   press;
    int    steps;       // motion events; 0 when there is no press
    double magPx;       // |(dx_px, dy_px)| along the handle's screen direction
    bool   armTool = true;   // false only for the vibe3d-side no-tool baseline
}

struct CellResult {
    int    grabX, grabY;
    long   visibleDelta;               // visible undo depth across the gesture
    long   deliveryDelta;              // change-bus deliveries across the gesture
    int    kB = -1;                    // undo index that reverts the prior edit
    bool   gestureChangedMesh;
    string firstUndoStatus;
    bool   firstUndoRevertsPrecedingEdit;
    bool   firstUndoChangedMesh;
}

/// Compute the +X move-arrow grab pixel for the CURRENT selection and camera.
void grabPixel(out int gx, out int gy, out double ux, out double uy) {
    settle();
    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    axisGrabPx(evalPivot(), vp, gx, gy, ux, uy);
}

/// One press-move-release on the +X move arrow. `magPx == 0` is the
/// zero-distance flavour: every motion event lands back on the press pixel.
void playArrowGesture(int gx, int gy, double ux, double uy,
                      double magPx, int steps) {
    auto cam = fetchCamera(BASE);
    const int x1 = gx + cast(int)(magPx * ux);
    const int y1 = gy + cast(int)(magPx * uy);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             gx, gy, x1, y1, steps), BASE);
    settle();
}

/// A real committed drag of the current selection, used to build the stand's
/// two preceding edits. Arms and DROPS the tool — the stand is deliberately a
/// realistic stack, lifecycle entries and all. Returns true if the mesh moved.
bool realDrag(double magPx, int steps) {
    script("tool.set move on");
    int gx, gy; double ux, uy;
    grabPixel(gx, gy, ux, uy);
    const before = verts();
    playArrowGesture(gx, gy, ux, uy, magPx, steps);
    script("tool.set move off");
    settle();
    return !meshEq(before, verts());
}

/// Drive one cell end to end on a fresh scene and read it back.
///
/// E1 = a real committed drag of the top corners. E2 = a real committed drag of
/// the bottom corners, and the state the undo walk starts from. N = the gesture
/// under test, on E2's own selection, with no tool drop after it (departures
/// (a) and (b) in the header). Then undo, reading the whole mesh after each one.
/// Mirrors `rig.shape` in the fixture.
CellResult runCell(CellDrive d, double stdMagPx, int stdSteps) {
    CellResult r;

    post(BASE ~ "/api/reset", "");
    settle();

    // E1
    selectVerts([2, 3, 6, 7]);
    assert(realDrag(stdMagPx, stdSteps),
        format("%s: E1 did not move the mesh — the stand was never built, so "
               ~ "every undo index below would be measuring nothing", d.id));

    const preE2 = verts();

    // E2 — the edit the undo walk is about
    selectVerts([0, 1, 4, 5]);
    assert(realDrag(stdMagPx, stdSteps),
        format("%s: E2 did not move the mesh — there is no preceding edit for "
               ~ "the walk to revert", d.id));

    const postE2 = verts();
    assert(!meshEq(preE2, postE2),
        format("%s: E2 left the mesh unchanged", d.id));

    // N — the gesture under test. No selection change, no tool drop.
    double ux = 0, uy = 0;
    if (d.armTool) {
        script("tool.set move on");
        grabPixel(r.grabX, r.grabY, ux, uy);
    } else {
        settle();
    }
    const long vis0 = visibleUndoDepth();
    const long del0 = deliveries();
    if (d.press)
        playArrowGesture(r.grabX, r.grabY, ux, uy,
                         d.gesture == "zero" ? 0.0 : d.magPx, d.steps);
    settle();
    r.visibleDelta  = visibleUndoDepth() - vis0;
    r.deliveryDelta = deliveries() - del0;

    const postN = verts();
    r.gestureChangedMesh = !meshEq(postE2, postN);

    // The undo walk
    foreach (k; 1 .. 7) {
        auto resp = postJson("/api/undo", "");
        settle();
        const v = verts();
        if (k == 1) {
            r.firstUndoStatus = ("status" in resp) ? resp["status"].str : "<none>";
            r.firstUndoRevertsPrecedingEdit = meshEq(v, preE2);
            r.firstUndoChangedMesh          = !meshEq(postN, v);
        }
        if (r.kB < 0 && meshEq(v, preE2)) r.kB = cast(int) k;
    }
    assert(r.kB > 0,
        format("%s: no undo in six steps returned the mesh to its pre-E2 "
               ~ "state — the walk found no kB and every reading below would "
               ~ "be meaningless", d.id));
    return r;
}

// ---------------------------------------------------------------------------
// The measurement, taken once and shared by the blocks below.
// ---------------------------------------------------------------------------
struct Measured {
    CellResult noTool, control, zero, positive;
    long refControl, refZero, refPositive;   // reference entry counts
    int  refKbControl, refKbZero, refKbPositive;
}

private Measured* g_m;

JSONValue fixtureCase(JSONValue fx, string id) {
    foreach (c; fx["cases"].array) if (c["id"].str == id) return c;
    assert(false, "fixture has no case '" ~ id ~ "'");
}

JSONValue driveValues(JSONValue fx, string cellName) {
    foreach (c; fx["parameters"]["cells"].array)
        if (c["cell"].str == cellName) return c["drove"].array[0]["values"];
    assert(false, "fixture has no parameters cell '" ~ cellName ~ "'");
}

CellDrive driveFor(JSONValue fx, string id) {
    auto v = driveValues(fx, id);
    assert(v["handle"].str == "x",
        format("%s: the fixture's drive record names handle %s, but this rig "
               ~ "grabs the +X arm — the driver and the record have diverged",
               id, v["handle"].toString));
    assert(v["flags.T"].type == JSONType.true_,
        format("%s: the fixture's drive record does not set flags.T, but this "
               ~ "rig arms the translate-only transform preset", id));
    CellDrive d;
    d.id      = id;
    d.gesture = v["gesture"].str;
    d.press   = v["press"].type == JSONType.true_;
    d.steps   = ("motion_steps" in v) ? cast(int) v["motion_steps"].integer : 0;
    const double dx = cast(double) v["dx_px"].integer;
    const double dy = cast(double) v["dy_px"].integer;
    d.magPx = sqrt(dx * dx + dy * dy);
    return d;
}

Measured measured() {
    if (g_m !is null) return *g_m;
    auto fx = parseJSON(kFixtureJson);

    Measured m;
    auto cc = fixtureCase(fx, "control_no_press");
    auto cz = fixtureCase(fx, "zero_distance_gesture");
    auto cp = fixtureCase(fx, "positive_control_real_drag");
    m.refControl    = cc["entries_recorded"].integer;
    m.refZero       = cz["entries_recorded"].integer;
    m.refPositive   = cp["entries_recorded"].integer;
    m.refKbControl  = cast(int) cc["undo_index_that_reverts_the_previous_edit"].integer;
    m.refKbZero     = cast(int) cz["undo_index_that_reverts_the_previous_edit"].integer;
    m.refKbPositive = cast(int) cp["undo_index_that_reverts_the_previous_edit"].integer;

    auto dctl = driveFor(fx, "control_no_press");
    auto dzer = driveFor(fx, "zero_distance_gesture");
    auto dpos = driveFor(fx, "positive_control_real_drag");

    // A vibe3d-side baseline the capture has no counterpart for, and block 2
    // needs it: the same stand with the tool never armed. Without it the
    // "arming costs nothing" row compares 0 against 0 by construction and
    // could not come out differently.
    CellDrive dnone;
    dnone.id      = "no_tool_baseline";
    dnone.gesture = "none";
    dnone.press   = false;
    dnone.armTool = false;

    // The stand's own two edits use the positive control's drive parameters —
    // the same handle, the same distance, the same step count.
    m.noTool   = runCell(dnone, dpos.magPx, dpos.steps);
    m.control  = runCell(dctl, dpos.magPx, dpos.steps);
    m.zero     = runCell(dzer, dpos.magPx, dpos.steps);
    m.positive = runCell(dpos, dpos.magPx, dpos.steps);

    g_m = new Measured;
    *g_m = m;
    return m;
}

/// Undo steps the gesture cost, read the fixture's way: relative to a control
/// run identical except for the button press.
long stepsOf(const ref CellResult c, const ref CellResult control) {
    return c.kB - control.kB;
}

// ---------------------------------------------------------------------------
// 0 — THE FIXTURE'S OWN ARITHMETIC. `entries_recorded` and the undo indices are
//     two frozen views of the same capture, related by the fixture's declared
//     reading `entries(N) = kB(N) - kB(control)`. Re-derive one from the other
//     so a fixture edited on one side only fails here instead of quietly moving
//     the target every assertion below aims at.
// ---------------------------------------------------------------------------
unittest {
    auto fx = parseJSON(kFixtureJson);
    auto cc = fixtureCase(fx, "control_no_press");
    auto cz = fixtureCase(fx, "zero_distance_gesture");
    auto cp = fixtureCase(fx, "positive_control_real_drag");
    const long refControl  = cc["entries_recorded"].integer;
    const long refZero     = cz["entries_recorded"].integer;
    const long refPositive = cp["entries_recorded"].integer;
    const long kbC = cc["undo_index_that_reverts_the_previous_edit"].integer;
    const long kbZ = cz["undo_index_that_reverts_the_previous_edit"].integer;
    const long kbP = cp["undo_index_that_reverts_the_previous_edit"].integer;

    assert(refZero == kbZ - kbC,
        format("the fixture contradicts itself: zero_distance_gesture declares "
               ~ "entries_recorded %d, but its undo indices give %d - %d = %d. "
               ~ "Re-measure; do not patch one side.",
               refZero, kbZ, kbC, kbZ - kbC));
    assert(refPositive == kbP - kbC,
        format("the fixture contradicts itself: positive_control_real_drag "
               ~ "declares entries_recorded %d, but its undo indices give "
               ~ "%d - %d = %d", refPositive, kbP, kbC, kbP - kbC));
    assert(refControl == 0,
        format("the fixture's control run declares %d entries; the whole "
               ~ "reading is relative to a control that costs nothing",
               refControl));
    assert(refZero > 0,
        format("the fixture declares %d entries for the zero-delta gesture — "
               ~ "there is no divergence left for this file to record",
               refZero));
    assert(kStatus == "open" || kStatus == "closed",
        "kStatus must be exactly \"open\" or \"closed\" — a typo must not "
        ~ "silently pick the parity branch");
}

// ---------------------------------------------------------------------------
// 1 — THE INSTRUMENT. Both calibration points from the fixture's own
//     `instrument_calibration`: it must read ZERO on the control and NONZERO on
//     a real displacement. A rig that cannot read zero makes every non-zero
//     unfalsifiable; a rig with no positive control cannot show it would have
//     seen an entry at all.
//
//     Plus the localisation: all three cells compute the same arm pixel, so
//     the zero-distance press lands where the positive control presses.
// ---------------------------------------------------------------------------
unittest {
    auto m = measured();

    assert(m.control.grabX == m.zero.grabX && m.control.grabY == m.zero.grabY
        && m.control.grabX == m.positive.grabX
        && m.control.grabY == m.positive.grabY,
        format("the three cells localised the move arrow at different pixels "
               ~ "— control (%d,%d), zero (%d,%d), positive (%d,%d). They must "
               ~ "differ by the button press and by NOTHING else, or the "
               ~ "zero-distance cell is not pressing where the positive "
               ~ "control presses.",
               m.control.grabX, m.control.grabY, m.zero.grabX, m.zero.grabY,
               m.positive.grabX, m.positive.grabY));

    assert(m.positive.gestureChangedMesh,
        "the positive control's drag left the mesh where it was — a press at "
        ~ "that pixel with the same choreography does not engage the transform "
        ~ "tool at all, so the zero-distance cell below would be measuring "
        ~ "nothing rather than a committed gesture");

    // The gesture's own witness, and the guard that survives the press being
    // deleted. Every undo-step reading in this file is identical between "the
    // gesture ran and recorded nothing" and "no gesture happened"; these two
    // are what separate them.
    assert(m.control.deliveryDelta == 0,
        format("the CONTROL cell produced %d change-bus deliveries while "
               ~ "performing no gesture at all. It is supposed to be the "
               ~ "quiet end of this comparison; if it is not, 'the "
               ~ "zero-distance cell delivered' says nothing.",
               m.control.deliveryDelta));
    assert(m.zero.deliveryDelta > m.control.deliveryDelta,
        format("the zero-distance gesture produced %d change-bus deliveries "
               ~ "against the control's %d — the press was never delivered, so "
               ~ "every 'we record nothing' reading below is about a gesture "
               ~ "that did not happen",
               m.zero.deliveryDelta, m.control.deliveryDelta));

    assert(stepsOf(m.positive, m.control) >= 1,
        format("the positive control cost %d undo steps: our instrument cannot "
               ~ "see an entry AT ALL, so every 'we record nothing' reading "
               ~ "below is vacuous",
               stepsOf(m.positive, m.control)));

    assert(!m.positive.firstUndoRevertsPrecedingEdit,
        "the positive control's FIRST undo reverted the edit that preceded the "
        ~ "gesture — a real committed drag left nothing of its own on top, so "
        ~ "the same observable cannot say anything about the zero-delta cell "
        ~ "either");

    assert(m.control.firstUndoRevertsPrecedingEdit,
        "the CONTROL cell's first undo did NOT revert the preceding edit, even "
        ~ "though no gesture was performed. Something unnamed is sitting on "
        ~ "top of the gesture's window (a selection entry, a tool-lifecycle "
        ~ "entry), and while it is there 'the first undo did not revert the "
        ~ "preceding edit' is green for that reason and distinguishes no "
        ~ "candidate law — see departures (a)/(b) in this file's header");

    assert(stepsOf(m.positive, m.control) == kOursPositiveSteps,
        format("a real committed +X drag now costs %d undo steps, this file "
               ~ "froze %d. That is OUR bookkeeping, not the measured law (the "
               ~ "reference's %d for the same gesture is its own decomposition, "
               ~ "and `decomposition.not_measured` says WHICH entries was never "
               ~ "read) — but it moved, so re-freeze it deliberately.",
               stepsOf(m.positive, m.control), kOursPositiveSteps,
               m.refPositive));

    assert(!m.zero.gestureChangedMesh,
        "the zero-distance gesture MOVED the mesh — the premise of the whole "
        ~ "law is a committed gesture whose delta is EMPTY, so this cell is no "
        ~ "longer the phenomenon the fixture measured");
}

// ---------------------------------------------------------------------------
// 2 — assertions_for_a_port[3], AND IT IS THE PARITY ROW:
//     "A tool that was armed and dropped WITHOUT any gesture must cost nothing
//      at all."
//
//     Covered for ARMED (see "WHAT IS NOT COVERED" for the dropped half). We
//     agree with the reference here, and the agreement is load-bearing: a file
//     whose every assertion is "we differ" passes just as well when the channel
//     is broken. This row shows the channel CAN agree on the same read.
// ---------------------------------------------------------------------------
unittest {
    auto m = measured();
    // Measured against a stand where the tool was NEVER ARMED — not against
    // the control itself, which would be 0 by construction and could not come
    // out differently.
    const long ours = stepsOf(m.control, m.noTool);
    assert(ours == m.refControl,
        format("arming the transform tool over the same stand cost %d undo "
               ~ "steps (kB %d against the never-armed baseline's %d); the "
               ~ "reference costs %d for its whole no-press gesture path. This "
               ~ "is the PARITY row of the divergence — losing it means the "
               ~ "read itself moved, not the law.",
               ours, m.control.kB, m.noTool.kB, m.refControl));
    // NOTE: "the control and the zero cell reach the preceding edit at the same
    // index" is deliberately NOT asserted here. It is block 5's whole content,
    // and duplicating it in an EARLIER block would make block 5 unreachable on
    // the one mutation that matters — druntime stops a module at its first
    // failed assert, so the second guard would write the message and the named
    // check would never be seen red.
    assert(kOursControlSteps == 0,
        "kOursControlSteps is the control's own reading and is 0 by "
        ~ "construction; a non-zero value here means the frozen record was "
        ~ "edited into something the rig cannot produce");
}

// ---------------------------------------------------------------------------
// 3 — assertions_for_a_port[0]:
//     "A committed gesture that produced no change MUST leave something on the
//      undo stack: the first undo after it must NOT revert the edit that
//      preceded it."
//
//     THE DIVERGENCE. Ours reverts it immediately. Discriminating, because
//     block 1 pinned the two ends of the same observable: the control's first
//     undo DOES revert the preceding edit, the positive control's does NOT.
// ---------------------------------------------------------------------------
unittest {
    auto m = measured();
    if (kStatus == "open") {
        assert(m.zero.firstUndoRevertsPrecedingEdit,
            "DIVERGENCE CLOSED: the first undo after a committed zero-delta "
            ~ "transform gesture no longer reverts the preceding edit — which "
            ~ "is what the reference does (task 2640, verdict (b)). If the law "
            ~ "was ported deliberately, flip kStatus to \"closed\", re-freeze "
            ~ "kOursZeroSteps, and retire registry row 86 in "
            ~ "doc/behavior_gap_registry.md.");
    } else {
        assert(!m.zero.firstUndoRevertsPrecedingEdit,
            "kStatus says the law is ported, but the first undo after a "
            ~ "committed zero-delta transform gesture still reverts the "
            ~ "preceding edit");
    }
}

// ---------------------------------------------------------------------------
// 4 — assertions_for_a_port[1]:
//     "That undo must succeed and must leave the mesh byte-identical — it is
//      silent, not refused."
//
//     THIS ONE SPLITS. The "succeeds" half is PARITY: our undo answers `ok`,
//     as the reference's did (its own command history confirmed every undo
//     executed). The "byte-identical" half is the divergence: ours is not
//     silent, it reverts real geometry. Asserting only the second half would
//     let a REFUSAL — also "not byte-identical", for the wrong reason — pass
//     unnoticed.
// ---------------------------------------------------------------------------
unittest {
    auto m = measured();
    assert(m.zero.firstUndoStatus == "ok",
        format("the first undo after the zero-delta gesture answered '%s'. "
               ~ "Both engines agree the undo EXECUTES — this is the parity "
               ~ "half of assertions_for_a_port[1], and a refusal here would "
               ~ "make the divergence half unreadable.",
               m.zero.firstUndoStatus));

    if (kStatus == "open") {
        assert(m.zero.firstUndoChangedMesh,
            "DIVERGENCE CLOSED: the first undo after a committed zero-delta "
            ~ "transform gesture is now SILENT (it left the mesh "
            ~ "byte-identical), which is the reference's behaviour. Flip "
            ~ "kStatus to \"closed\", re-freeze kOursZeroSteps, and retire "
            ~ "registry row 86.");
    } else {
        assert(!m.zero.firstUndoChangedMesh,
            "kStatus says the law is ported, but the first undo after the "
            ~ "zero-delta gesture still changed the mesh instead of being "
            ~ "silent");
    }
}

// ---------------------------------------------------------------------------
// 5 — assertions_for_a_port[2]:
//     "The gesture must not fold into the preceding entry: the preceding edit
//      reverts LATER than it would have without the gesture, never earlier and
//      never at the same index."
//
//     THE COUNT, and it is what the fixture says a port must be judged by: for
//     an empty delta, candidates (a) "no entry created" and (c) "it coalesced"
//     are observationally identical, so the rig separates {a, c} from {b} only.
//     We land on the {a, c} side — our preceding edit reverts at the SAME index
//     as in the control run — and the count is what says so.
// ---------------------------------------------------------------------------
unittest {
    auto m = measured();
    const long oursShift = stepsOf(m.zero, m.control);
    const long refShift  = m.refKbZero - m.refKbControl;

    if (kStatus == "open") {
        assert(oursShift == 0,
            format("the zero-delta gesture now shifts the preceding edit's "
                   ~ "undo index by %d (kB %d against the control's %d). This "
                   ~ "file froze 0 — the gesture folding into nothing. The "
                   ~ "reference shifts it by %d. Either the gap moved or it "
                   ~ "closed; re-measure and update this file and registry "
                   ~ "row 86.", oursShift, m.zero.kB, m.control.kB, refShift));
        assert(oursShift < refShift,
            format("DIVERGENCE CLOSED OR REVERSED: our shift is %d and the "
                   ~ "reference's is %d. The recorded gap is 'we shift by "
                   ~ "strictly less'.", oursShift, refShift));
    } else {
        assert(oursShift == refShift,
            format("kStatus says the law is ported, but our zero-delta gesture "
                   ~ "shifts the preceding edit's undo index by %d against the "
                   ~ "reference's %d", oursShift, refShift));
    }
}

// ---------------------------------------------------------------------------
// 6 — THE GAP ITSELF, recomputed rather than declared, over the step COUNT.
//     Discipline (3): the difference between our live reading and the frozen
//     reference measurement must be exactly what is recorded here. Narrow it in
//     EITHER direction and this reddens.
//
//     Plus the two instruments' coupling. The walk counts RAW undo steps; the
//     `/api/history` depth counts VISIBLE entries, filtering
//     `HistoryFlags.ToolLifecycle`. In THIS rig no tool is dropped inside the
//     gesture window, so no lifecycle entry is born there and the two must
//     agree. A disagreement means one appeared where the rig assumes none —
//     which silently changes what the walk is counting.
// ---------------------------------------------------------------------------
unittest {
    auto m = measured();

    assert(m.zero.visibleDelta == stepsOf(m.zero, m.control),
        format("the two instruments disagree: /api/history's visible depth "
               ~ "moved by %d across the gesture, the raw undo walk by %d "
               ~ "(kB %d against the control's %d). The WALK is the law's "
               ~ "instrument — the reference had no stack read and the "
               ~ "fixture's reading is defined on undo steps — so a mismatch "
               ~ "means a ToolLifecycle entry was born inside the gesture "
               ~ "window, where this rig assumes none.",
               m.zero.visibleDelta, stepsOf(m.zero, m.control), m.zero.kB,
               m.control.kB));

    // (1) the regression pin on our own side
    assert(stepsOf(m.zero, m.control) == kOursZeroSteps,
        format("a committed zero-delta transform gesture now costs %d undo "
               ~ "steps; this file froze %d. This is a KNOWN DIVERGENCE from "
               ~ "the reference's %d — if you changed the behaviour "
               ~ "deliberately, re-measure, update this file and update "
               ~ "registry row 86.",
               stepsOf(m.zero, m.control), kOursZeroSteps, m.refZero));

    // (3) the gap, recomputed
    const long gap = m.refZero - stepsOf(m.zero, m.control);
    if (kStatus == "open") {
        assert(gap == m.refZero - kOursZeroSteps && gap > 0,
            format("the gap is now %d undo steps (reference %d, ours %d); this "
                   ~ "file records %d. A gap of 0 means the law is ported: "
                   ~ "flip kStatus to \"closed\", re-freeze kOursZeroSteps and "
                   ~ "retire registry row 86. Any other number means the "
                   ~ "divergence CHANGED — re-measure.",
                   gap, m.refZero, stepsOf(m.zero, m.control),
                   m.refZero - kOursZeroSteps));
    } else {
        assert(gap == 0,
            format("kStatus says the law is ported, but the gap is still %d "
                   ~ "undo steps (reference %d, ours %d)",
                   gap, m.refZero, stepsOf(m.zero, m.control)));
    }
}
