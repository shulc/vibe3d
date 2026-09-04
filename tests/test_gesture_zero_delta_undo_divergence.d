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
// Measured after strict lifecycle LIFO: kB = 2 / 2 / 3 for control /
// zero-distance / real drag,
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
//       commits an engaged tool; here the commit boundary is MOUSE-UP, and the
//       positive control proves it with a real history entry before any drop.
//       Our common lifecycle prefix belongs to the ARM and is now measured
//       explicitly by the control; adding a drop would change consolidation
//       choreography without buying a discriminator for the empty gesture.
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
//   * the CONTROL's first undo MUST consume exactly one arm lifecycle record
//     without touching geometry, and its second undo MUST revert E2. The
//     POSITIVE cell still does not revert E2 on its first undo. Together those
//     observations prove both that the common lifecycle prefix is real and
//     that the stand can expose the preceding edit.
//
// WHAT IS NOT COVERED, and why — read this before adding to it.
//   * The original control fixture DID drive the whole no-press path, including
//     the drop. The old live parity row did not: it left the tool armed and
//     therefore compared a different region. RESOLVED ELSEWHERE, 2026-08-30
//     (task 2660): the second-form capture re-drove the complete arm-and-drop
//     region in both stack shapes and corrected its cost to ONE. Block 2 now
//     drives that complete region too, takes the number from the later fixture,
//     and witnesses both endpoints. Registry row 87 and the sibling test own
//     the corrected law; this file retains an independent agreement row so its
//     divergence channel cannot pass vacuously.
//   * Nothing about tools outside the transform family (the fixture's own
//     `not_measured`). The CUTTING family is measured in the second-form
//     fixture and read by the sibling file above; this file's scope is
//     unchanged.
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
//   M3 — MEASURE THE WRONG REGION. The pre-3694 parity row used
//        `stepsOf(m.control, m.noTool)`: ARM ONLY against never-armed, although
//        the assertion and fixture both named ARM-AND-DROP. Once lifecycle
//        became strict LIFO, the owner gate reddened that row first:
//        "arming the transform tool over the same stand cost 1 undo steps
//        (kB 2 against the never-armed baseline's 1); the reference costs 0".
//        That observed red is why block 2 now has its own complete-region cell
//        rather than changing the expected number under the mismatched drive.
//
//   M4 — DELETE THE COMPLETE REGION. Empty `runArmDropParityCell`'s arm/drop
//        body. The step subtraction can then read zero for a region that never
//        happened, but block 2's FIRST assertion reddens on "reported 0 arms
//        and 0 drops ... it must report 1 and 1". This is the same witness and
//        mutation already executed for the sibling's `runArmDropCell` (task
//        2660, M6); this file deliberately reuses that proven discriminator.
//
//   M2 — DELETE THE GESTURE. `if (d.press)` -> `if (d.press && d.gesture !=
//        "zero")` in `runCell`, i.e. the zero cell stops pressing at all.
//        EVERY undo-step reading in this file stays exactly as it was — which
//        is the whole point — and block 1's delivery guard is the only thing
//        that reddens: "the zero-distance gesture produced 0 change-bus
//        deliveries against the control's 0 — the press was never delivered".

import http_client : testBaseUrl, getJson, postJson;
import std.json;
import std.net.curl : get, post;
import std.format   : format;
import std.math     : fabs, sqrt;
import core.thread  : Thread;
import core.time    : msecs;

import drag_helpers;

void main() {}

// Resolve the per-worker port through the shared HTTP client.
alias BASE = testBaseUrl;

enum string kFixtureJson = import("fixtures/gesture_zero_delta_undo.json");
enum string kArmDropFixtureJson =
    import("fixtures/gesture_zero_delta_undo_second_form.json");

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
enum long kOursArmDropSteps  = 1;   // complete no-press arm-and-drop region

/// The retirement switch. "open" — we still differ, assert the gap.
/// "closed" — the law is ported, assert PARITY instead.
enum string kStatus = "open";

// ---------------------------------------------------------------------------
// HTTP plumbing
// ---------------------------------------------------------------------------


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

/// Depth of the surfaced strict-LIFO undo stack. `/api/history` includes
/// `HistoryFlags.ToolLifecycle`, so this is also a raw step count.
long visibleUndoDepth() { return getJson("/api/history")["undo"].array.length; }

/// Raw lifecycle records on the undo stack. Unlike `/api/history`, this sees
/// the common arm prefix and lets the control prove its first silent step is
/// real rather than a dead stand.
long lifecycleCount() {
    return getJson("/api/undo/status")["toolLifecycleCount"].integer;
}

/// Change-bus deliveries so far. The gesture's own witness: it moves whether
/// or not the gesture leaves anything on the undo stack, so it can tell "ran
/// and recorded nothing" from "never ran".
long deliveries() { return getJson("/api/changes")["deliveryCount"].integer; }

/// The armed tool's own id, or "" when no tool is armed. The complete-region
/// parity cell uses this as a positive witness at both ends: its undo count is
/// otherwise also satisfied by deleting the region it claims to measure.
string armedToolId() {
    auto j = getJson("/api/tool/state");
    return ("tool" in j) ? j["tool"].str : "";
}

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
    long   firstUndoLifecycleDelta;
    string secondUndoStatus;
    bool   secondUndoRevertsPrecedingEdit;
    bool   secondUndoChangedMesh;
}

struct ArmDropResult {
    int  kB = -1;
    int  armsSeen;
    int  dropsSeen;
    bool meshChanged;
}

/// A pointer path with NO button press. It mirrors the gesture transport's
/// header and timing while keeping `state:0` throughout.
string buildMoveLog(int vpX, int vpY, int vpW, int vpH,
                    int x0, int y0, int x1, int y1, int steps)
{
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    int lastX = x0, lastY = y0;
    foreach (i; 0 .. steps + 1) {
        const int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / steps);
        const int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / steps);
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":0,"mod":0}` ~ "\n",
            50.0 + i * 50.0, x, y, x - lastX, y - lastY);
        lastX = x; lastY = y;
    }
    return log;
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

    // The undo walk. Lifecycle strict-LIFO gives every armed cell one common
    // silent first step; the second-step fields retain the old discriminating
    // observation after that real prefix.
    const long lifecycleBeforeUndo = lifecycleCount();
    foreach (k; 1 .. 7) {
        auto resp = postJson("/api/undo", "");
        settle();
        const v = verts();
        if (k == 1) {
            r.firstUndoStatus = ("status" in resp) ? resp["status"].str : "<none>";
            r.firstUndoRevertsPrecedingEdit = meshEq(v, preE2);
            r.firstUndoChangedMesh          = !meshEq(postN, v);
            r.firstUndoLifecycleDelta       = lifecycleCount() - lifecycleBeforeUndo;
        }
        if (k == 2) {
            r.secondUndoStatus = ("status" in resp) ? resp["status"].str : "<none>";
            r.secondUndoRevertsPrecedingEdit = meshEq(v, preE2);
            r.secondUndoChangedMesh          = !meshEq(postN, v);
        }
        if (r.kB < 0 && meshEq(v, preE2)) r.kB = cast(int) k;
    }
    assert(r.kB > 0,
        format("%s: no undo in six steps returned the mesh to its pre-E2 "
               ~ "state — the walk found no kB and every reading below would "
               ~ "be meaningless", d.id));
    return r;
}

/// The COMPLETE no-press region named by the parity law: arm, localise and
/// hover the handle without a button press, drop, then walk undo. This is
/// separate from `control`, which must stay armed so control/zero/positive
/// retain identical gesture commit choreography.
ArmDropResult runArmDropParityCell(double stdMagPx, int stdSteps) {
    ArmDropResult r;

    post(BASE ~ "/api/reset", "");
    settle();

    selectVerts([2, 3, 6, 7]);
    assert(realDrag(stdMagPx, stdSteps),
        "arm-drop parity: E1 did not move the mesh");

    const preE2 = verts();
    selectVerts([0, 1, 4, 5]);
    assert(realDrag(stdMagPx, stdSteps),
        "arm-drop parity: E2 did not move the mesh");
    const postE2 = verts();
    assert(!meshEq(preE2, postE2),
        "arm-drop parity: E2 left the mesh unchanged");

    script("tool.set move on");
    settle();
    if (armedToolId() == "xfrm") ++r.armsSeen;

    int gx, gy; double ux, uy;
    grabPixel(gx, gy, ux, uy);
    auto cam = fetchCamera(BASE);
    playAndWait(buildMoveLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             gx, gy, gx, gy, 8), BASE);
    settle();

    script("tool.set move off");
    settle();
    if (armedToolId().length == 0) ++r.dropsSeen;

    const postRegion = verts();
    r.meshChanged = !meshEq(postE2, postRegion);

    foreach (k; 1 .. 7) {
        auto resp = postJson("/api/undo", "");
        assert(("status" in resp) && resp["status"].str == "ok",
            format("arm-drop parity: undo %d did not execute: %s",
                   k, resp.toString));
        settle();
        if (r.kB < 0 && meshEq(verts(), preE2)) r.kB = cast(int) k;
    }
    assert(r.kB > 0,
        "arm-drop parity: no undo in six steps reverted E2");
    return r;
}

// ---------------------------------------------------------------------------
// The measurement, taken once and shared by the blocks below.
// ---------------------------------------------------------------------------
struct Measured {
    CellResult noTool, control, zero, positive;
    ArmDropResult armDrop;
    long refZero, refPositive;               // task-2640 entry counts
    long refArmDrop;                         // corrected complete-region count
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
    m.refZero       = cz["entries_recorded"].integer;
    m.refPositive   = cp["entries_recorded"].integer;

    auto fxArmDrop = parseJSON(kArmDropFixtureJson);
    m.refArmDrop = fixtureCase(
        fxArmDrop, "armed_and_dropped_over_a_model_edit"
    )["entries_recorded"].integer;
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
    m.armDrop  = runArmDropParityCell(dpos.magPx, dpos.steps);

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
//     the target of its task-2640 assertions.
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

    // Task 2660 is the corrective capture for the complete no-press region.
    // Re-derive that later number here too: block 2 must not turn a half-edited
    // fixture into a new target merely because it imports the newer file.
    auto fxArmDrop = parseJSON(kArmDropFixtureJson);
    auto ca = fixtureCase(fxArmDrop, "armed_and_dropped_over_a_model_edit");
    auto cb = fixtureCase(fxArmDrop, "baseline_no_region_at_all");
    const long refArmDrop = ca["entries_recorded"].integer;
    const long kbA = ca["undo_index_that_reverts_the_previous_edit"].integer;
    const long kbBase = cb["undo_index_that_reverts_the_previous_edit"].integer;
    assert(refArmDrop == 1 && refArmDrop == kbA - kbBase,
        format("the corrective arm-and-drop fixture declares %d entries, but "
               ~ "the measured law is 1 and its undo indices give %d - %d = "
               ~ "%d. Re-measure; do not patch one side.",
               refArmDrop, kbA, kbBase, kbA - kbBase));
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

    assert(m.control.firstUndoLifecycleDelta == -1,
        format("the CONTROL cell's first undo changed lifecycle depth by %d, "
               ~ "not -1; it must consume the common arm record rather than "
               ~ "look silent for an unnamed reason",
               m.control.firstUndoLifecycleDelta));
    assert(!m.control.firstUndoChangedMesh
        && !m.control.firstUndoRevertsPrecedingEdit,
        "the CONTROL cell's first undo changed geometry; strict LIFO must "
        ~ "consume only the arm record at this step");
    assert(m.control.kB == 2 && m.control.secondUndoRevertsPrecedingEdit,
        format("the CONTROL cell did not revert the preceding edit on its "
               ~ "second undo (kB=%d); the stand can no longer demonstrate "
               ~ "a working geometry rollback", m.control.kB));

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
//     The quoted zero is the superseded task-2640 reading. Task 2660 re-drove
//     the COMPLETE region, re-derived its count from undo indices, and corrected
//     it to ONE. We drive that same complete region here. The agreement remains
//     load-bearing: a file whose every assertion is "we differ" passes just as
//     well when the channel is broken. This row shows the channel CAN agree.
// ---------------------------------------------------------------------------
unittest {
    auto m = measured();
    // The witness comes before the number: deleting the whole region can also
    // make a subtraction read zero, so the endpoints must prove it happened.
    assert(m.armDrop.armsSeen == 1 && m.armDrop.dropsSeen == 1,
        format("the complete no-press region reported %d arms and %d drops "
               ~ "through /api/tool/state; it must report 1 and 1. The region "
               ~ "never happened, so its undo-step reading is about nothing",
               m.armDrop.armsSeen, m.armDrop.dropsSeen));
    assert(!m.armDrop.meshChanged,
        "the no-press arm-and-drop region changed geometry; it is no longer "
        ~ "the parity phenomenon the fixture measured");

    // Compare with the same stand where the tool was NEVER ARMED. The later
    // fixture owns the corrected complete-region number; the task-2640 zero
    // remains checked in block 0 as the internally consistent historical read.
    const long ours = m.armDrop.kB - m.noTool.kB;
    assert(ours == m.refArmDrop,
        format("a complete no-press transform arm-and-drop region cost %d undo "
               ~ "steps (kB %d against the never-armed baseline's %d); the "
               ~ "corrected complete-region capture costs %d. This is the "
               ~ "PARITY row of the divergence — losing it means the read "
               ~ "itself moved, not the open zero-delta law.",
               ours, m.armDrop.kB, m.noTool.kB, m.refArmDrop));
    assert(ours == kOursArmDropSteps,
        format("the complete arm-and-drop region now costs %d undo steps; "
               ~ "this file froze %d", ours, kOursArmDropSteps));
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
//      undo stack: after the common arm step, the next undo must NOT revert the
//      edit that preceded it."
//
//     THE DIVERGENCE. Ours reverts it on undo₂, exactly where the control does.
//     Block 1 proves undo₁ consumed a real lifecycle record and undo₂ can
//     expose the preceding edit, so a silent result cannot come from a dead
//     stand.
// ---------------------------------------------------------------------------
unittest {
    auto m = measured();
    if (kStatus == "open") {
        assert(m.zero.secondUndoRevertsPrecedingEdit,
            "DIVERGENCE CLOSED: the first undo after the common arm step of a committed zero-delta "
            ~ "transform gesture no longer reverts the preceding edit — which "
            ~ "is what the reference does (task 2640, verdict (b)). If the law "
            ~ "was ported deliberately, flip kStatus to \"closed\", re-freeze "
            ~ "kOursZeroSteps, and retire registry row 86 in "
            ~ "doc/behavior_gap_registry.md.");
    } else {
        assert(!m.zero.secondUndoRevertsPrecedingEdit,
            "kStatus says the law is ported, but the first undo after the "
            ~ "common arm step of a committed zero-delta transform gesture "
            ~ "still reverts the preceding edit");
    }
}

// ---------------------------------------------------------------------------
// 4 — assertions_for_a_port[1]:
//     "That post-arm undo must succeed and must leave the mesh byte-identical —
//      it is silent, not refused."
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
    assert(m.zero.secondUndoStatus == "ok",
        format("the first undo after the common arm step of the zero-delta gesture answered '%s'. "
               ~ "Both engines agree the undo EXECUTES — this is the parity "
               ~ "half of assertions_for_a_port[1], and a refusal here would "
               ~ "make the divergence half unreadable.",
               m.zero.secondUndoStatus));

    if (kStatus == "open") {
        assert(m.zero.secondUndoChangedMesh,
            "DIVERGENCE CLOSED: the first undo after the common arm step of a committed zero-delta "
            ~ "transform gesture is now SILENT (it left the mesh "
            ~ "byte-identical), which is the reference's behaviour. Flip "
            ~ "kStatus to \"closed\", re-freeze kOursZeroSteps, and retire "
            ~ "registry row 86.");
    } else {
        assert(!m.zero.secondUndoChangedMesh,
            "kStatus says the law is ported, but the first undo after the "
            ~ "common arm step of the zero-delta gesture still changed the "
            ~ "mesh instead of being silent");
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
//     Plus the two instruments' coupling. Both the walk and `/api/history`
//     count RAW undo steps. In THIS rig no tool is dropped inside the gesture
//     window, so the two deltas must agree directly.
// ---------------------------------------------------------------------------
unittest {
    auto m = measured();

    assert(m.zero.visibleDelta == stepsOf(m.zero, m.control),
        format("the two instruments disagree: /api/history's surfaced depth "
               ~ "moved by %d across the gesture, the raw undo walk by %d "
               ~ "(kB %d against the control's %d). The WALK is the law's "
               ~ "instrument — the reference had no stack read and the "
               ~ "fixture's reading is defined on undo steps — so a mismatch "
               ~ "means the surfaced row count and the undo walk no longer "
               ~ "share one strict-LIFO coordinate space.",
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
