// test_gesture_zero_delta_undo_second_form — task 2660's measured law, wired to
// a live check as TWO KNOWN DIVERGENCES (self-retiring, red in BOTH directions).
//
// THE LAW, measured and frozen in
// `tests/fixtures/gesture_zero_delta_undo_second_form.json` (task 2660,
// verdict (b), live captures on fresh reference processes PLUS a breakpoint on
// the one instruction that increments the engine's undo-entry counter):
//
//   A COMMITTED GESTURE COSTS UNDO STEPS EVEN WHEN IT CHANGED NOTHING, IN
//   EVERY TOOL FAMILY — BUT THE COST IS PER TOOL, NOT A CONSTANT.
//   2 undo steps for a transform-handle haul (task 2640) and 1 for a cutting
//   tool, against ZERO for an identical run with no button press. The
//   recording decision keys on "did anything register an undoable action",
//   not on "did the mesh change".
//
//   And its dual, CORRECTED 2026-08-30 by a behavioural cross-check:
//   ARMING A TOOL AND DROPPING IT WITHOUT EVER ENGAGING IT COSTS ONE UNDO
//   STEP, AND THAT STEP IS BOUGHT BY THE ARM, NOT BY THE DROP — the drop of
//   a never-engaged tool and the whole pointer path around it register
//   nothing. It costs the SAME ONE in both stack shapes, over a preceding
//   model edit and over another armed-and-dropped region alike, so there is
//   still no stack-shape term.
//
//   THE 0/0 THIS FILE ASSERTED UNTIL 2026-08-30 WAS A WINDOW ARTEFACT, and
//   it is worth knowing which instrument lied and why. The debugger channel
//   attached by process id AFTER the arm command had already run, so its
//   window contained the wake keystroke, the pointer move and the drop and
//   never the arm; it read 0 and was RIGHT ABOUT WHAT IT BRACKETED. The
//   behavioural walk brackets a region that BEGINS with the arm and reads 1.
//   The fixture records the boundary at `decomposition.channel_boundary`,
//   and the two channels still agree exactly on the half they both measured
//   over the same region — 1 against 1 behaviourally, 0 against 0 on the
//   direct counter, +4 against +4 headless — which is the finding that
//   survived the correction: there is no stack-shape term.
//
// WE DIFFER TWICE, in opposite directions, and this file is the record of both.
//
//   (A) THE CUTTING FAMILY, and it is the SECOND family to show our rule is a
//       RESULT test. `SliceTool.commitCurrentSlice` returns early on
//       `!previewLive_`, and `previewLive_` is literally `nSplit > 0` — "did
//       the cut change anything". So a committed zero-distance cut gesture
//       costs us ZERO undo steps against the reference's ONE. Note that our
//       site is NOT the transform one (`TransformTool.commitEdit` /
//       `buildEditCmd`, registry row 86's first half): two independent
//       implementations of the same wrong predicate, which is why a port is a
//       policy change and not a one-site fix.
//
//   (B) THE ARM-AND-DROP REGION, and here WE COST LESS — by exactly ONE
//       step, once, from the first region onward. We record the same NUMBER
//       of entries the reference does, one per region, but at the opposite
//       end of the region and in a class the undo walk can hide:
//         * our ARM records nothing at all (the reference charges the arm);
//         * our DROP records a `HistoryFlags.ToolLifecycle` entry
//           (`ToolDeactivationCommand`, emitted from `setActiveTool` only for
//           tools implementing `LifecycleUndoEmitter` — `XfrmTransformTool`
//           is the sole implementor, so a cutting tool's drop records
//           nothing at all);
//         * `CommandHistory.undo`'s (R1) rule makes a lifecycle TAIL
//           transparent when a Model entry sits below it, and a HARD STEP
//           otherwise.
//       So the stand's own model entry absorbs exactly ONE region's entry
//       and n regions cost us n-1 undo steps against the reference's n.
//
//       "OUR FIRST REGION IS FREE" IS NOT THE LAW and must not be written
//       down as one — it is a property of what lies BELOW the region, not of
//       the region. Measured on this tree 2026-08-30: with no model edit
//       below it at all, the very FIRST region is a hard step and costs 1;
//       and after a single region over the stand, the second undo
//       RE-ACTIVATES the transform tool, which is the entry the first undo
//       stepped past. The entry was always recorded; the walk hid it.
//       Registry row 87.
//
// WHY A SIBLING FILE AND NOT MORE BLOCKS IN
// `tests/test_gesture_zero_delta_undo_divergence.d`. Three reasons, all
// load-bearing:
//   * druntime stops a module at its FIRST failed assert. That file already
//     carries seven blocks whose mutations were recorded one at a time; adding
//     five more would bury every one of them behind an earlier failure and
//     make the recorded mutation notes unreproducible without deleting blocks.
//   * its scope is declared and narrow — "every cell drives the TRANSFORM
//     tool", the family its fixture drove — and its `kStatus` is ONE
//     retirement switch for ONE gap. The two gaps here close independently of
//     that one and of each other, so they need their own switches; a single
//     token would retire the wrong gap.
//   * one reader per fixture keeps "which capture is this assertion from"
//     answerable by looking at the import.
//
// THE STATUS TOKENS ARE THE RETIREMENT SWITCHES. `kStatusCut` and
// `kStatusArmDrop` are each checked to be exactly "open" or "closed" (a typo
// must not silently pick a branch), and each "closed" branch demands PARITY.
// Porting either law is then a real two-line edit: flip the token and re-freeze
// the matching `kOurs*` constant. `kStatusArmDrop` now guards BLOCK 2 (shape 1),
// which is where the divergence moved on 2026-08-30; block 3 (shape 2) carries
// no branch because it is INVARIANT under the port — charging the arm one step
// per region leaves shape 2 at 1, which is what it already reads.
//
// THE INSTRUMENT IS THE CAPTURE'S OWN, AND THE ABSOLUTE INDEX IS NOT
// COMPARABLE. The reading is `steps(N) = kB(N) - kB(control)`, where kB is the
// index of the undo that reverts the edit PRECEDING the cell's own gesture.
// What else sits on the stack is engine bookkeeping; the DIFFERENCE against a
// control run identical except for the one varied step is the engine-
// independent quantity the fixture's `rig.reading` defines.
//
// THE STAND IS BUILT BY A COMMAND, NOT BY A DRAG, AND THAT IS FORCED BY (B).
// `mesh.move_vertex` leaves a plain Model entry at the tail of the undo stack —
// which is also the reference stand's own shape, whose one entry above the
// second real edit is a SELECTION change ((R1) skips UiUndo entries on its way
// down, so a selection between the model edit and the region changes nothing
// here). A drag-built stand would drop its own tool and leave a `ToolLifecycle`
// entry there instead — and then the FIRST arm-and-drop would already be "over
// another lifecycle region", the two stack shapes would collapse into one, and
// block 2 would read 1 for a reason that has nothing to do with the law. This
// is not a guess: a drag-built stand's tail is exactly the tail cell
// `armdrop_over_model_edit` leaves behind (a Model entry with a lifecycle entry
// on top of it), and the cost of one more arm-and-drop over THAT tail is
// measured, at 1 — it is what block 3 reads.
//
// ANTI-VACUITY, and it is the part that has already failed once on the sibling
// file: every undo-step reading below is satisfied just as well by a gesture
// that NEVER HAPPENED. Deleting the press records nothing either. The
// witnesses that separate "the gesture ran and recorded nothing" from "no
// gesture happened" are:
//   * `lineDrawn` — the cutting tool's OWN engagement flag, read from
//     `/api/tool/state`. FALSE in the control, TRUE in the zero-distance cell.
//     This is the strong witness: it is the tool saying it took the press.
//   * the change-bus delivery count, which moves for the zero cell and not for
//     the control — an independent second channel, kept because the two fail
//     for different reasons.
//   * the drawn line is DEGENERATE (start == end) in the zero cell, which is
//     what makes it the empty-delta flavour the fixture measured rather than
//     some other gesture;
//   * the mesh is byte-identical across the zero gesture (the premise of the
//     law, not a conclusion);
//   * the press pixel is IDENTICAL in all three cutting cells, so the zero
//     press lands where the positive control presses;
//   * the positive control must CUT and must cost at least one step — without
//     it, "we record nothing" is a statement about an instrument that cannot
//     see a recording at all.
// The ARM-AND-DROP cells have the same hole and it is now the LOAD-BEARING one,
// because block 2's divergence reading is ZERO and a region that never happened
// reads zero too. Two things separate them:
//   * `armsSeen` / `dropsSeen` — `/api/tool/state` reports `tool == "xfrm"`
//     inside every region and answers `{}` after every drop. This is the tool
//     saying it was armed, and it is the ONLY witness that reddens when the
//     region body is deleted;
//   * block 3, whose reading of 1 for the SECOND region is a positive count
//     that the regions register something at all.
//
// WHAT IS NOT COVERED, and why — read this before adding to it.
//   * Deforming, creating and painting families. The fixture's own
//     `not_measured` says no cell was driven for them; the MECHANISM argument
//     covers them and a test cannot assert a mechanism argument.
//   * Redo. Neither fixture makes a redo claim, so neither does this.
//   * A full-magnitude cutting gesture whose RESULT is empty. The capture's
//     cell for it cut the mesh anyway (`short_line_off_the_mesh`), so only the
//     zero-distance flavour of an empty delta is measured, on both sides.
//   * WHICH low-level blocks group into which user-visible undo step. The
//     fixture's `decomposition.not_measured` says that channel counted blocks
//     and could not separate the grouping.
//   * A cell that isolates the ARM on its own on the reference side. Charging
//     its one step to the arm rests on ELIMINATION — the region logged exactly
//     one command and the finer instrument priced every other act in it at
//     zero — not on a region containing only the arm. The fixture's
//     `not_measured` says so; block 2's message repeats it.
//   * Whether OUR arm would be charged if it were driven as a bare keystroke
//     rather than as `tool.set … on`. Every cell here drives the command.
//
// MUTATIONS THAT REDDEN IT: recorded at the bottom of this file.

import std.json;
import std.net.curl : get, post;
import std.format   : format;
import std.math     : fabs, sqrt;
import std.algorithm: canFind;
import core.thread  : Thread;
import core.time    : msecs;

import drag_helpers;

void main() {}

// The literal is spelled out because run_test.d rewrites "localhost:8080"
// per worker for parallel runs — do not build it dynamically.
enum BASE = "http://localhost:8080";

enum string kFixtureJson    = import("fixtures/gesture_zero_delta_undo_second_form.json");
/// Task 2640's fixture, held open beside this one for exactly one purpose:
/// block 6, which refuses a corpus where the two families' costs have been
/// normalised to a single number. That normalisation IS candidate (a).
enum string kFixtureOneJson = import("fixtures/gesture_zero_delta_undo.json");

// ---------------------------------------------------------------------------
// OUR SIDE, FROZEN. Measured on this tree 2026-08-30 through the rig below.
// Steps are RELATIVE, exactly as the fixture reads them.
// ---------------------------------------------------------------------------
enum long kOursCutControlSteps  = 0;   // slice tool armed and dropped, no press
enum long kOursCutZeroSteps     = 0;   // committed zero-distance cut gesture
enum long kOursCutPositiveSteps = 1;   // committed real cut

/// Arm-and-drop of the TRANSFORM tool, relative to the cell with one fewer
/// armed-and-dropped region. Shape 1 = over the stand's model entry.
/// The VALUES are unchanged by the 2026-08-30 correction and the ROLES are
/// swapped: the reference now costs 1 for BOTH shapes, so shape 1 is the
/// divergence (block 2) and shape 2 is the parity row (block 3).
enum long kOursArmDropOverModelSteps     = 0;   // the reference costs 1
enum long kOursArmDropOverLifecycleSteps = 1;   // parity with the reference

/// The retirement switches. "open" — we still differ, assert the gap.
/// "closed" — the law is ported, assert PARITY instead.
enum string kStatusCut     = "open";
enum string kStatusArmDrop = "open";

/// Rig constants. The fixture's cutting cells are prose ("sixteen pointer
/// moves that ALL land on the press pixel"; "a 700 px line drawn across the
/// mesh") and this fixture carries no machine drive record, so the step counts
/// are OURS and are declared here rather than pretended to be read out of it.
/// What IS read out of it is the cell semantics — block 0 pins "the zero cell
/// left the mesh unchanged" from the fixture's own vertex counts.
enum int kZeroMotionSteps = 16;
enum int kCutMotionSteps  = 20;
/// The positive control's far endpoint, in WORLD units along an in-plane axis.
/// A pixel distance would be camera-dependent; this is not.
enum float kCutReachWorld = 0.9f;

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
/// `HistoryFlags.ToolLifecycle` — which is precisely why block 4 asserts that
/// this instrument and the undo walk DISAGREE on the lifecycle cells.
long visibleUndoDepth() { return getJson("/api/history")["undo"].array.length; }

/// Change-bus deliveries so far. One of the two gesture witnesses.
long deliveries() { return getJson("/api/changes")["deliveryCount"].integer; }

/// The slice tool's own state. `lineDrawn` is the engagement witness; the
/// start/end triples say whether the drawn line is degenerate.
JSONValue sliceState() { return getJson("/api/tool/state"); }

/// The ARMED tool's own id, or "" when nothing is armed — `/api/tool/state`
/// answers a bare `{}` with no active tool and carries `"tool":"xfrm"` while
/// a transform tool is up. This is the arm-and-drop cells' engagement witness,
/// the counterpart of `lineDrawn` for the cutting cells: without it block 2's
/// reading of ZERO is satisfied just as well by a region that never happened.
string armedToolId() {
    auto j = getJson("/api/tool/state");
    return ("tool" in j) ? j["tool"].str : "";
}

// ---------------------------------------------------------------------------
// The rig
// ---------------------------------------------------------------------------

/// A pointer path with NO button press — the control's gesture path. Mirrors
/// `buildDragLog`'s header and timing so the two differ by the press and by
/// nothing else.
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

/// The stand's one model edit: move the mesh's first vertex a fixed distance
/// in +X through a COMMAND, so the tail of the undo stack is a plain Model
/// entry with no tool-lifecycle entry after it. Returns the pre-edit mesh.
double[][] buildStand() {
    postJson("/api/reset", "");
    settle();
    auto pre = verts();
    assert(pre.length > 0 && pre[0].length == 3,
        "the stand has no vertex 0 to move — /api/reset did not give a mesh");
    script(format("mesh.move_vertex from:{%g,%g,%g} to:{%g,%g,%g}",
                  pre[0][0], pre[0][1], pre[0][2],
                  pre[0][0] - 0.4, pre[0][1], pre[0][2]));
    settle();
    assert(!meshEq(pre, verts()),
        "the stand's model edit did not move the mesh — there is no preceding "
        ~ "edit for the undo walk to be about, and every kB below would be "
        ~ "measuring some other entry");
    return pre;
}

/// Walk the undo stack, reading the whole mesh after every step, and return
/// the index of the first undo that lands back on `pre`.
struct WalkResult {
    int    kB = -1;
    string firstStatus;
    bool   firstRevertsStand;
    bool   firstChangedMesh;
}

WalkResult undoWalk(string id, const double[][] pre, const double[][] post) {
    WalkResult w;
    foreach (k; 1 .. 7) {
        auto resp = postJson("/api/undo", "");
        settle();
        const v = verts();
        if (k == 1) {
            w.firstStatus       = ("status" in resp) ? resp["status"].str : "<none>";
            w.firstRevertsStand = meshEq(v, pre);
            w.firstChangedMesh  = !meshEq(post, v);
        }
        if (w.kB < 0 && meshEq(v, pre)) w.kB = cast(int) k;
    }
    assert(w.kB > 0,
        format("%s: no undo in six steps returned the mesh to its pre-stand "
               ~ "state — the walk found no kB and every reading built on it "
               ~ "would be meaningless", id));
    return w;
}

/// The world point the press pixel projects from, and a second point the
/// positive control drags to. Both lie on the construction plane the tool
/// itself picks (the most-facing world plane), so the drawn line crosses the
/// cube whatever the camera is doing. Replicates `pickMostFacingPlane`'s
/// X > Y > Z tie-break, exactly as tests/test_slice_session.d does.
void cutEndpoints(const ref Viewport vp, out Vec3 a, out Vec3 b) {
    const Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    const float ax = fabs(camBack.x), ay = fabs(camBack.y), az = fabs(camBack.z);
    Vec3 inPlane2;
    if (ax >= ay && ax >= az)      inPlane2 = Vec3(0, 0, 1);
    else if (ay >= ax && ay >= az) inPlane2 = Vec3(0, 0, 1);
    else                           inPlane2 = Vec3(0, 1, 0);
    a = Vec3(0, 0, 0);
    b = Vec3(inPlane2.x * kCutReachWorld,
             inPlane2.y * kCutReachWorld,
             inPlane2.z * kCutReachWorld);
}

void toPixel(Vec3 w, const ref Viewport vp, out int px, out int py) {
    float fx, fy;
    const bool ok = projectToWindow(w, vp, fx, fy);
    assert(ok, "a rig world point projected off-screen — the camera "
             ~ "assumptions this rig is built on no longer hold");
    px = cast(int)(fx + 0.5f);
    py = cast(int)(fy + 0.5f);
}

struct CutCell {
    int    pressX, pressY;
    int    kB;
    long   visibleDelta;
    long   deliveryDelta;
    bool   lineDrawn;
    bool   lineDegenerate;
    bool   gestureChangedMesh;
    string firstUndoStatus;
    bool   firstUndoRevertsStand;
    bool   firstUndoChangedMesh;
}

/// One cutting cell: build the stand, arm `mesh.sliceTool`, drive the gesture,
/// DROP the tool, then walk the undo stack.
///
/// The drop is inside EVERY cell including the control, deliberately: our
/// Slice tool's only commit point is `deactivate`, so a cell that never drops
/// could not record anything at all and the positive control would be dead.
/// Since the drop is common to all three cells, whatever it costs cancels in
/// `steps(N) = kB(N) - kB(control)`.
CutCell runCutCell(string id, bool press, bool reach) {
    CutCell c;
    const pre = buildStand();
    const postStand = verts();

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 wa, wb;
    cutEndpoints(vp, wa, wb);
    int fx, fy;
    toPixel(wa, vp, c.pressX, c.pressY);
    toPixel(wb, vp, fx, fy);

    const long vis0 = visibleUndoDepth();
    const long del0 = deliveries();

    script("tool.set mesh.sliceTool on");
    settle();
    if (press) {
        const int x1 = reach ? fx : c.pressX;
        const int y1 = reach ? fy : c.pressY;
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 c.pressX, c.pressY, x1, y1,
                                 reach ? kCutMotionSteps : kZeroMotionSteps), BASE);
    } else {
        playAndWait(buildMoveLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 c.pressX, c.pressY, c.pressX, c.pressY,
                                 kZeroMotionSteps), BASE);
    }
    settle();

    auto st = sliceState();
    c.lineDrawn = st["lineDrawn"].type == JSONType.true_;
    c.lineDegenerate =
        fabs(st["startX"].floating - st["endX"].floating) < 1e-5 &&
        fabs(st["startY"].floating - st["endY"].floating) < 1e-5 &&
        fabs(st["startZ"].floating - st["endZ"].floating) < 1e-5;

    script("tool.set mesh.sliceTool off");
    settle();

    c.visibleDelta  = visibleUndoDepth() - vis0;
    c.deliveryDelta = deliveries() - del0;
    const postN = verts();
    c.gestureChangedMesh = !meshEq(postStand, postN);

    auto w = undoWalk(id, pre, postN);
    c.kB                    = w.kB;
    c.firstUndoStatus       = w.firstStatus;
    c.firstUndoRevertsStand = w.firstRevertsStand;
    c.firstUndoChangedMesh  = w.firstChangedMesh;
    return c;
}

struct ArmDropCell {
    int  kB;
    long visibleDelta;
    long deliveryDelta;
    bool meshMoved;
    /// How many of this cell's regions were seen ARMED (the tool reported
    /// itself as `xfrm` after `tool.set move on`) and DROPPED (the endpoint
    /// answered `{}` after `tool.set move off`). Both must equal `regions`.
    int  armsSeen;
    int  dropsSeen;
}

/// `regions` armings-and-droppings of the TRANSFORM tool over the stand, each
/// with the same no-press pointer path the reference's cell drove, then the
/// undo walk. `regions == 0` is the baseline the first region is measured
/// against.
ArmDropCell runArmDropCell(string id, int regions) {
    ArmDropCell c;
    const pre = buildStand();
    const postStand = verts();

    auto cam = fetchCamera(BASE);
    const int px = cam.vpX + cam.width / 2;
    const int py = cam.vpY + cam.height / 2;

    const long vis0 = visibleUndoDepth();
    const long del0 = deliveries();
    foreach (i; 0 .. regions) {
        script("tool.set move on");
        settle();
        // WITNESS, read INSIDE the region: the tool is up. Everything below
        // reads zero for a region that never happened, so this is the line
        // that separates the two.
        if (armedToolId() == "xfrm") ++c.armsSeen;
        playAndWait(buildMoveLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 px, py, px, py, 8), BASE);
        settle();
        script("tool.set move off");
        settle();
        if (armedToolId().length == 0) ++c.dropsSeen;
    }
    c.visibleDelta  = visibleUndoDepth() - vis0;
    c.deliveryDelta = deliveries() - del0;

    const postN = verts();
    c.meshMoved = !meshEq(postStand, postN);
    assert(!c.meshMoved,
        format("%s: arming and dropping the transform tool MOVED the mesh — "
               ~ "the cell is supposed to be a tool that was never engaged, so "
               ~ "it is no longer the phenomenon the fixture measured", id));

    c.kB = undoWalk(id, pre, postN).kB;
    return c;
}

// ---------------------------------------------------------------------------
// The measurement, taken once and shared by the blocks below.
// ---------------------------------------------------------------------------
struct Measured {
    CutCell     cutControl, cutZero, cutPositive;
    ArmDropCell ad0, ad1, ad2, ad3;
    long        refCutControl, refCutZero, refCutPositive;
    int         refKbCutControl, refKbCutZero, refKbCutPositive;
    long        refArmDropModel, refArmDropLifecycle;
    long        refTransformZero;              // task 2640's fixture
}

private Measured* g_m;

JSONValue fixtureCase(JSONValue fx, string id) {
    foreach (c; fx["cases"].array) if (c["id"].str == id) return c;
    assert(false, "fixture has no case '" ~ id ~ "'");
}

Measured measured() {
    if (g_m !is null) return *g_m;
    auto fx  = parseJSON(kFixtureJson);
    auto fx1 = parseJSON(kFixtureOneJson);

    Measured m;
    auto cc = fixtureCase(fx, "control_no_press");
    auto cz = fixtureCase(fx, "zero_distance_gesture");
    auto cp = fixtureCase(fx, "positive_control_real_cut");
    m.refCutControl    = cc["entries_recorded"].integer;
    m.refCutZero       = cz["entries_recorded"].integer;
    m.refCutPositive   = cp["entries_recorded"].integer;
    m.refKbCutControl  = cast(int) cc["undo_index_that_reverts_the_previous_edit"].integer;
    m.refKbCutZero     = cast(int) cz["undo_index_that_reverts_the_previous_edit"].integer;
    m.refKbCutPositive = cast(int) cp["undo_index_that_reverts_the_previous_edit"].integer;
    m.refArmDropModel  =
        fixtureCase(fx, "armed_and_dropped_over_a_model_edit")["entries_recorded"].integer;
    m.refArmDropLifecycle =
        fixtureCase(fx, "armed_and_dropped_over_another_lifecycle_region")["entries_recorded"].integer;
    m.refTransformZero =
        fixtureCase(fx1, "zero_distance_gesture")["entries_recorded"].integer;

    m.cutControl  = runCutCell("cut_control_no_press",  false, false);
    m.cutZero     = runCutCell("cut_zero_distance",     true,  false);
    m.cutPositive = runCutCell("cut_positive_real_cut", true,  true);

    m.ad0 = runArmDropCell("armdrop_baseline_no_arm",   0);
    m.ad1 = runArmDropCell("armdrop_over_model_edit",   1);
    m.ad2 = runArmDropCell("armdrop_over_lifecycle",    2);
    m.ad3 = runArmDropCell("armdrop_over_lifecycle_2",  3);

    g_m = new Measured;
    *g_m = m;
    return m;
}

// ---------------------------------------------------------------------------
// 0 — THE FIXTURE'S OWN ARITHMETIC AND ITS OWN CELLS. `entries_recorded` and
//     the undo indices are two frozen views of one capture, related by the
//     declared reading `entries(N) = kB(N) - kB(control)`. Re-derive one from
//     the other, so a fixture edited on one side only fails HERE instead of
//     quietly moving the target every assertion below aims at. Plus: the two
//     armed-and-dropped cells must both be present and both read zero — that
//     pair IS the "there is no stack-shape term" finding, and with one of them
//     gone block 3's divergence row would be comparing against a caveat again.
// ---------------------------------------------------------------------------
unittest {
    auto fx = parseJSON(kFixtureJson);
    auto cc = fixtureCase(fx, "control_no_press");
    auto cz = fixtureCase(fx, "zero_distance_gesture");
    auto cp = fixtureCase(fx, "positive_control_real_cut");
    const long kbC = cc["undo_index_that_reverts_the_previous_edit"].integer;
    const long kbZ = cz["undo_index_that_reverts_the_previous_edit"].integer;
    const long kbP = cp["undo_index_that_reverts_the_previous_edit"].integer;

    assert(cz["entries_recorded"].integer == kbZ - kbC,
        format("the fixture contradicts itself: zero_distance_gesture declares "
               ~ "entries_recorded %d, but its undo indices give %d - %d = %d. "
               ~ "Re-measure; do not patch one side.",
               cz["entries_recorded"].integer, kbZ, kbC, kbZ - kbC));
    assert(cp["entries_recorded"].integer == kbP - kbC,
        format("the fixture contradicts itself: positive_control_real_cut "
               ~ "declares entries_recorded %d, but its undo indices give "
               ~ "%d - %d = %d",
               cp["entries_recorded"].integer, kbP, kbC, kbP - kbC));
    assert(cc["entries_recorded"].integer == 0,
        format("the fixture's control run declares %d entries; the whole "
               ~ "reading is relative to a control that costs nothing",
               cc["entries_recorded"].integer));
    assert(cz["entries_recorded"].integer > 0,
        format("the fixture declares %d entries for the zero-delta cutting "
               ~ "gesture — there is no divergence left for this file to "
               ~ "record", cz["entries_recorded"].integer));

    // The zero cell must BE an empty delta on the reference's own numbers, or
    // it is not the phenomenon and our matching cell is comparing to nothing.
    assert(cz["mesh_changed"].type == JSONType.false_,
        "the fixture's zero_distance_gesture no longer declares an unchanged "
        ~ "mesh — the empty-delta premise is gone from the reference side");
    assert(cz["vertex_count_after"].integer == cc["vertex_count_after"].integer,
        format("the fixture's zero cell ends at %d vertices and its control at "
               ~ "%d; an empty delta must leave the same mesh",
               cz["vertex_count_after"].integer,
               cc["vertex_count_after"].integer));
    // And the intended-but-failed cell must stay marked as a REAL cut, so
    // nobody later reads it as a second empty-delta data point.
    assert(fixtureCase(fx, "short_line_off_the_mesh")["mesh_changed"].type
               == JSONType.true_,
        "the fixture's short_line_off_the_mesh cell no longer declares that it "
        ~ "cut the mesh. Its own note says it was INTENDED as a full-magnitude "
        ~ "gesture with an empty result and cut anyway, which is why it is not "
        ~ "evidence about an empty delta — flipping that flag would silently "
        ~ "turn a real-cut cell into a second empty-delta claim");

    // The two stack shapes, and the fact that they cost the SAME.
    auto a0 = fixtureCase(fx, "baseline_no_region_at_all");
    auto a1 = fixtureCase(fx, "armed_and_dropped_over_a_model_edit");
    auto a2 = fixtureCase(fx, "armed_and_dropped_over_another_lifecycle_region");
    const long kbA0 = a0["undo_index_that_reverts_the_previous_edit"].integer;
    const long kbA1 = a1["undo_index_that_reverts_the_previous_edit"].integer;
    const long kbA2 = a2["undo_index_that_reverts_the_previous_edit"].integer;

    assert(a1["entries_recorded"].integer == 1
        && a2["entries_recorded"].integer == 1,
        format("the fixture's armed-and-dropped cells declare %d and %d "
               ~ "entries. The CORRECTED law (cross-check, 2026-08-30) is "
               ~ "that the DROP is free and the ARM is not: EACH "
               ~ "armed-and-dropped region costs the reference exactly ONE "
               ~ "entry. The 0/0 this assertion used to demand was a WINDOW "
               ~ "artefact of the debugger channel — it attached AFTER the arm "
               ~ "command had already run, so its window held the keystroke, "
               ~ "the pointer path and the drop and never the arm itself. The "
               ~ "behavioural walk brackets the arm and reads 1. What the two "
               ~ "cells being EQUAL still buys is the original finding, "
               ~ "untouched by the correction: there is no stack-shape term",
               a1["entries_recorded"].integer, a2["entries_recorded"].integer));

    // Re-derive both numbers from the frozen undo indices, each against the
    // baseline its own `entries_recorded_against` names. THIS IS THE CHECK
    // THAT WAS MISSING when the 0/0 went in: the indices said 3 - 2 = 1 and
    // 4 - 3 = 1 the whole time and nothing compared them against the declared
    // 0. A fixture edited on one side only must fail HERE, exactly as the
    // cutting cells above already do.
    assert(a1["entries_recorded_against"].str.canFind("baseline_no_region_at_all"),
        format("the shape-1 cell now measures itself against '%s'; the "
               ~ "subtraction below assumes the never-armed baseline",
               a1["entries_recorded_against"].str));
    assert(a2["entries_recorded_against"].str.canFind("armed_and_dropped_over_a_model_edit"),
        format("the shape-2 cell now measures itself against '%s'; the "
               ~ "subtraction below assumes the single-region cell",
               a2["entries_recorded_against"].str));
    assert(a1["entries_recorded"].integer == kbA1 - kbA0,
        format("the fixture contradicts itself: armed_and_dropped_over_a_"
               ~ "model_edit declares entries_recorded %d, but its undo "
               ~ "indices give %d - %d = %d. Re-measure; do not patch one side",
               a1["entries_recorded"].integer, kbA1, kbA0, kbA1 - kbA0));
    assert(a2["entries_recorded"].integer == kbA2 - kbA1,
        format("the fixture contradicts itself: armed_and_dropped_over_"
               ~ "another_lifecycle_region declares entries_recorded %d, but "
               ~ "its undo indices give %d - %d = %d. Re-measure; do not patch "
               ~ "one side",
               a2["entries_recorded"].integer, kbA2, kbA1, kbA2 - kbA1));

    assert(a1["low_level_blocks_created"].integer == 0
        && a2["low_level_blocks_created"].integer == 0,
        "the fixture's armed-and-dropped cells no longer declare zero "
        ~ "low-level blocks. That zero is a real reading of a NARROWER region "
        ~ "than the one entry count above — the debugger's window opens after "
        ~ "the arm, so it prices the pointer path and the drop alone (see the "
        ~ "fixture's decomposition.channel_boundary). It is what charges the "
        ~ "one entry to the ARM by elimination, and it must not be edited to "
        ~ "chase the corrected 1");

    assert(fx["verdict"].str == "b",
        format("the fixture's verdict is now '%s'. This file is built on (b) — "
               ~ "the law is general and the NUMBER is per tool; (a) and (c) "
               ~ "would make blocks 5 and 6 assert the wrong thing",
               fx["verdict"].str));

    assert(kStatusCut == "open" || kStatusCut == "closed",
        "kStatusCut must be exactly \"open\" or \"closed\" — a typo must not "
        ~ "silently pick the parity branch");
    assert(kStatusArmDrop == "open" || kStatusArmDrop == "closed",
        "kStatusArmDrop must be exactly \"open\" or \"closed\" — a typo must "
        ~ "not silently pick the parity branch");
}

// ---------------------------------------------------------------------------
// 1 — THE INSTRUMENT, on the cutting family. Both calibration points from the
//     fixture's own `instrument_calibration`: it must read ZERO on the control
//     and NONZERO on a real cut. Plus the two gesture witnesses, which are the
//     only things in this file that can tell "the gesture ran and recorded
//     nothing" from "the gesture never happened".
// ---------------------------------------------------------------------------
unittest {
    auto m = measured();

    assert(m.cutControl.pressX == m.cutZero.pressX
        && m.cutControl.pressY == m.cutZero.pressY
        && m.cutControl.pressX == m.cutPositive.pressX
        && m.cutControl.pressY == m.cutPositive.pressY,
        format("the three cutting cells pressed at different pixels — control "
               ~ "(%d,%d), zero (%d,%d), positive (%d,%d). They must differ by "
               ~ "the button press and by NOTHING else, or the zero cell is "
               ~ "not pressing where the positive control presses",
               m.cutControl.pressX, m.cutControl.pressY,
               m.cutZero.pressX, m.cutZero.pressY,
               m.cutPositive.pressX, m.cutPositive.pressY));

    // WITNESS 1 — the tool's own engagement flag.
    assert(!m.cutControl.lineDrawn,
        "the CONTROL cell's slice tool reports a DRAWN line although no button "
        ~ "was ever pressed. It is the quiet end of this comparison; if it is "
        ~ "not quiet, 'the zero cell engaged the tool' says nothing");
    assert(m.cutZero.lineDrawn,
        "the zero-distance gesture did NOT engage the cutting tool — its own "
        ~ "`lineDrawn` is still false, so the press never reached it and every "
        ~ "'we record nothing' reading below is about a gesture that did not "
        ~ "happen");
    assert(m.cutZero.lineDegenerate,
        "the zero-distance cell drew a line whose endpoints DIFFER — the cell "
        ~ "is supposed to be the zero-distance flavour of an empty delta, the "
        ~ "only flavour the fixture measured");

    // WITNESS 2 — an independent channel, kept because the two fail for
    // different reasons (a tool that engages without publishing, a publish
    // without engagement).
    assert(m.cutControl.deliveryDelta == 0,
        format("the CONTROL cell produced %d change-bus deliveries while "
               ~ "performing no gesture at all", m.cutControl.deliveryDelta));
    assert(m.cutZero.deliveryDelta > m.cutControl.deliveryDelta,
        format("the zero-distance gesture produced %d change-bus deliveries "
               ~ "against the control's %d — the press was never delivered",
               m.cutZero.deliveryDelta, m.cutControl.deliveryDelta));

    assert(!m.cutZero.gestureChangedMesh,
        "the zero-distance cut gesture MOVED the mesh — the premise of the law "
        ~ "is a committed gesture whose delta is EMPTY, so this cell is no "
        ~ "longer the phenomenon the fixture measured");

    assert(m.cutPositive.gestureChangedMesh,
        "the positive control's cut left the mesh where it was — a press at "
        ~ "that pixel with the same choreography does not cut at all, so the "
        ~ "zero cell below would be measuring nothing rather than a committed "
        ~ "gesture");
    assert(m.cutPositive.kB - m.cutControl.kB >= 1,
        format("the positive control cost %d undo steps: our instrument cannot "
               ~ "see an entry AT ALL, so every 'we record nothing' reading "
               ~ "below is vacuous", m.cutPositive.kB - m.cutControl.kB));
    assert(!m.cutPositive.firstUndoRevertsStand,
        "the positive control's FIRST undo reverted the stand's edit — a real "
        ~ "committed cut left nothing of its own on top, so the same "
        ~ "observable cannot say anything about the zero cell either");
    assert(m.cutControl.firstUndoRevertsStand,
        "the CONTROL cell's first undo did NOT revert the stand's edit, even "
        ~ "though no gesture was performed. Something unnamed is sitting on "
        ~ "top of the gesture window, and while it is there 'the first undo "
        ~ "did not revert the preceding edit' is green for that reason and "
        ~ "distinguishes no candidate law");

    assert(m.cutPositive.kB - m.cutControl.kB == kOursCutPositiveSteps,
        format("a real committed cut now costs %d undo steps, this file froze "
               ~ "%d. The reference costs %d for the same gesture and we AGREE "
               ~ "with it there — this is the parity end of the cutting "
               ~ "family, so losing it means the read moved, not the law",
               m.cutPositive.kB - m.cutControl.kB, kOursCutPositiveSteps,
               m.refCutPositive));
    assert(kOursCutControlSteps == 0,
        "kOursCutControlSteps is the control's own reading and is 0 by "
        ~ "construction; a non-zero value means the frozen record was edited "
        ~ "into something the rig cannot produce");
}

// ---------------------------------------------------------------------------
// 2 — assertions_for_a_port[3], FIRST HALF, AND SINCE 2026-08-30 IT IS THE
//     DIVERGENCE ROW:
//     "A tool that was armed and dropped WITHOUT ever being engaged must cost
//      exactly ONE undo step, and that step must be charged to the ARM."
//
//     Over a preceding MODEL edit we cost ZERO where the reference costs one.
//     This block was the PARITY row until the cross-check overturned the
//     reference's 0 (window artefact — see block 0 and the file header).
//     Registry row 87, shape 1.
//
//     THE MECHANISM IS OURS, AND IT IS NOT "the first region is free". Every
//     region records exactly one entry on our side too. Ours is a
//     `HistoryFlags.ToolLifecycle` entry from the DROP (our ARM records
//     nothing; the reference charges the arm and its drop is free), and
//     `CommandHistory.undo`'s (R1) rule makes a lifecycle TAIL transparent
//     when a Model entry sits directly below it — so the stand's own model
//     entry absorbs exactly ONE region's entry, whichever region is first.
//     Two measurements on this tree, 2026-08-30, say the freeness belongs to
//     what lies BELOW and not to the region: with no model edit below it the
//     very first region is a hard step and costs 1; and after ONE region over
//     the stand, the first undo reverts the stand and the SECOND undo
//     re-activates the transform tool — i.e. the entry existed all along and
//     the walk stepped past it.
//
//     THE INCREMENT AGREEMENT IS A COINCIDENCE, NOT A MATCH. Both engines
//     record one entry per region, so both accumulate at 1 per further
//     region. They do it at opposite ends of the region, and only one of the
//     two classes can be hidden by an undo rule. That is why the whole
//     divergence is a CONSTANT one step, and why it shows up here rather than
//     as a drift block 3 could see.
//
//     VACUITY IS THE LIVE RISK IN THIS BLOCK: it reads 0, and a region that
//     NEVER HAPPENED reads 0 too. The arms/drops witness below is what
//     separates them, and block 3's positive 1 is the second channel.
//
//     ON THE REFERENCE SIDE, the charge to the ARM rests on ELIMINATION (the
//     region logged exactly one command; the finer instrument priced every
//     other act in it at zero), not on a cell containing only an arm. The
//     fixture's `not_measured` says so and this message repeats it.
// ---------------------------------------------------------------------------
unittest {
    auto m = measured();
    const long ours = m.ad1.kB - m.ad0.kB;

    // THE WITNESS FIRST — the region HAPPENED. Everything below is satisfied
    // by a deleted region body, so this is the assertion that must fail when
    // the cell stops arming.
    assert(m.ad1.armsSeen == 1 && m.ad1.dropsSeen == 1,
        format("the single armed-and-dropped region reported %d arms and %d "
               ~ "drops through /api/tool/state; it must report 1 and 1. The "
               ~ "region never happened, so the ZERO undo steps this block "
               ~ "reads below is about nothing at all — a deleted region body "
               ~ "produces exactly the same reading",
               m.ad1.armsSeen, m.ad1.dropsSeen));
    assert(m.ad0.armsSeen == 0,
        format("the never-armed BASELINE reported %d arms. It is the quiet "
               ~ "end of this subtraction; if it arms anything, the "
               ~ "difference is not the cost of a region",
               m.ad0.armsSeen));

    if (kStatusArmDrop == "open") {
        assert(ours == kOursArmDropOverModelSteps && ours < m.refArmDropModel,
            format("arming and dropping the transform tool over a preceding "
                   ~ "MODEL edit cost %d undo steps (kB %d against the "
                   ~ "never-armed baseline's %d); this file froze %d against "
                   ~ "the reference's %d entries for the same region. A value "
                   ~ "of %d means the divergence CLOSED: flip kStatusArmDrop "
                   ~ "to \"closed\", re-freeze kOursArmDropOverModelSteps and "
                   ~ "retire registry row 87. Any other number means it "
                   ~ "CHANGED — re-measure, and re-measure the bare-stack and "
                   ~ "tool-reactivation cells with it, because they are what "
                   ~ "say the freeness belongs to the stand's tail and not to "
                   ~ "the region",
                   ours, m.ad1.kB, m.ad0.kB, kOursArmDropOverModelSteps,
                   m.refArmDropModel, m.refArmDropModel));
    } else {
        assert(ours == m.refArmDropModel,
            format("kStatusArmDrop says the law is ported, but an "
                   ~ "armed-and-dropped region over a MODEL edit still costs "
                   ~ "%d undo steps against the reference's %d",
                   ours, m.refArmDropModel));
    }
}

// ---------------------------------------------------------------------------
// 3 — assertions_for_a_port[3], SECOND HALF, AND SINCE 2026-08-30 IT IS THE
//     PARITY ROW:
//     "…and the number must be the SAME in both stack shapes: over a preceding
//      model edit and over another armed-and-dropped region alike."
//
//     A SECOND arm-and-drop, stacked on the first, costs us ONE — which is
//     what the reference costs for every region. We AGREE here, and the
//     agreement is load-bearing twice over:
//       * a file whose every assertion is "we differ" passes just as well when
//         the channel is broken. This row shows the channel CAN agree on the
//         same read;
//       * it is a POSITIVE count. Block 2's divergence reading is zero and
//         cannot tell a recorded-and-hidden entry from no entry at all; this
//         one goes red the moment the regions stop registering anything.
//
//     NO RETIREMENT BRANCH, deliberately. `kStatusArmDrop` guards block 2
//     because that is where the gap is. This row is INVARIANT under the port:
//     charging one step per region leaves shape 2 at 1, which is what it
//     already reads. If it ever moves, the law moved — re-measure.
//
//     A NOTE ON WHAT THE REFERENCE SIDE IS. The fixture's `not_measured` says
//     no cell isolates the arm on its own, so "the step is bought by the ARM"
//     is an inference by elimination. The NUMBER, 1 per region in both shapes,
//     is measured on the behavioural walk (undo indices 2 → 3 → 4).
// ---------------------------------------------------------------------------
unittest {
    auto m = measured();
    const long ours = m.ad2.kB - m.ad1.kB;

    assert(m.ad2.armsSeen == 2 && m.ad2.dropsSeen == 2,
        format("the two-region cell reported %d arms and %d drops through "
               ~ "/api/tool/state; it must report 2 and 2, or the difference "
               ~ "it contributes is not the cost of a second region",
               m.ad2.armsSeen, m.ad2.dropsSeen));

    assert(ours == m.refArmDropLifecycle,
        format("a SECOND armed-and-dropped transform region cost %d undo "
               ~ "steps (kB %d against the single region's %d); the reference "
               ~ "records %d entries for the same region. This is the PARITY "
               ~ "row — losing it means the read itself moved, not the law, "
               ~ "and it takes block 2's only positive witness with it",
               ours, m.ad2.kB, m.ad1.kB, m.refArmDropLifecycle));
    assert(ours == kOursArmDropOverLifecycleSteps,
        format("shape 2 now costs %d undo steps; this file froze %d",
               ours, kOursArmDropOverLifecycleSteps));

    // The registry row claims every FURTHER region costs another step, on both
    // sides. Without this the row would be over-claiming from a single cell.
    assert(m.ad3.kB - m.ad2.kB == ours,
        format("the THIRD armed-and-dropped region cost %d undo steps where "
               ~ "the second cost %d. Registry row 87 says every further "
               ~ "region costs the same on our side, which is what makes the "
               ~ "divergence a CONSTANT one step rather than a drift; one of "
               ~ "the two is now wrong", m.ad3.kB - m.ad2.kB, ours));
}

// ---------------------------------------------------------------------------
// 4 — THE INSTRUMENT THAT CANNOT SEE ROW 87, asserted so nobody writes the
//     next test on it. `/api/history` filters `HistoryFlags.ToolLifecycle`, so
//     its visible depth moves by ZERO across every armed-and-dropped cell
//     while the undo walk reads a hard step from the second region on. The
//     WALK is the law's instrument. Note the shape this leaves: on shape 1
//     the two instruments happen to AGREE at zero, which is exactly why the
//     cheap one cannot be used — it agrees for the wrong reason (it cannot
//     see the entry) with a reading that is itself a divergence.
//
//     The cutting cells are the control for this claim: there the two
//     instruments must AGREE, because no lifecycle entry is born in them at
//     all (only `XfrmTransformTool` implements `LifecycleUndoEmitter`). A
//     disagreement there means one appeared where this rig assumes none.
// ---------------------------------------------------------------------------
unittest {
    auto m = measured();

    assert(m.ad2.visibleDelta == 0 && m.ad1.visibleDelta == 0,
        format("/api/history's visible undo depth moved by %d and %d across "
               ~ "the armed-and-dropped cells. It is supposed to be BLIND to "
               ~ "lifecycle entries; if it can see them, blocks 2 and 3 could "
               ~ "have been written on the cheap instrument and this file's "
               ~ "whole undo walk is unnecessary — re-read (R1)",
               m.ad1.visibleDelta, m.ad2.visibleDelta));
    assert(m.ad2.kB - m.ad1.kB != m.ad2.visibleDelta - m.ad1.visibleDelta,
        "the two instruments AGREE on the second armed-and-dropped region. "
        ~ "They must not: the walk counts raw undo steps and /api/history "
        ~ "filters ToolLifecycle, so an agreement means either the drop stopped "
        ~ "recording a lifecycle entry or /api/history stopped filtering it");

    assert(m.cutZero.visibleDelta == m.cutZero.kB - m.cutControl.kB,
        format("the two instruments disagree on the CUTTING cells: "
               ~ "/api/history's visible depth moved by %d across the gesture, "
               ~ "the raw undo walk by %d. No lifecycle entry can be born "
               ~ "there — the Slice tool does not implement "
               ~ "LifecycleUndoEmitter — so a mismatch means one appeared "
               ~ "where this rig assumes none",
               m.cutZero.visibleDelta, m.cutZero.kB - m.cutControl.kB));
}

// ---------------------------------------------------------------------------
// 5 — assertions_for_a_port[0] and [1], ON THE CUTTING FAMILY:
//     "A committed gesture that produced no change MUST leave something on the
//      undo stack, in EVERY tool family: the first undo after it must NOT
//      revert the edit that preceded it" — and "that undo must succeed and
//      must leave the mesh byte-identical: it is silent, not refused."
//
//     THE DIVERGENCE. Ours reverts the stand immediately. Discriminating,
//     because block 1 pinned the two ends of the same observable: the
//     control's first undo DOES revert the stand, the positive control's does
//     NOT.
//
//     [1] SPLITS. The "succeeds" half is PARITY — our undo answers `ok`, as
//     the reference's did. The "byte-identical" half is the divergence.
//     Asserting only the second half would let a REFUSAL — also "not
//     byte-identical", for the wrong reason — pass unnoticed.
// ---------------------------------------------------------------------------
unittest {
    auto m = measured();

    assert(m.cutZero.firstUndoStatus == "ok",
        format("the first undo after the zero-delta cut gesture answered '%s'. "
               ~ "Both engines agree the undo EXECUTES — this is the parity "
               ~ "half, and a refusal here would make the divergence half "
               ~ "unreadable", m.cutZero.firstUndoStatus));

    if (kStatusCut == "open") {
        assert(m.cutZero.firstUndoRevertsStand,
            "DIVERGENCE CLOSED: the first undo after a committed zero-delta "
            ~ "CUTTING gesture no longer reverts the edit that preceded it — "
            ~ "which is what the reference does (task 2660, verdict (b)). If "
            ~ "the law was ported deliberately, flip kStatusCut to \"closed\", "
            ~ "re-freeze kOursCutZeroSteps, and retire the cutting half of "
            ~ "registry row 86 in doc/behavior_gap_registry.md.");
        assert(m.cutZero.firstUndoChangedMesh,
            "DIVERGENCE CLOSED: the first undo after a committed zero-delta "
            ~ "cutting gesture is now SILENT (it left the mesh "
            ~ "byte-identical), which is the reference's behaviour. Flip "
            ~ "kStatusCut to \"closed\", re-freeze kOursCutZeroSteps and "
            ~ "retire the cutting half of registry row 86.");
    } else {
        assert(!m.cutZero.firstUndoRevertsStand,
            "kStatusCut says the law is ported, but the first undo after a "
            ~ "committed zero-delta cutting gesture still reverts the edit "
            ~ "that preceded it");
        assert(!m.cutZero.firstUndoChangedMesh,
            "kStatusCut says the law is ported, but the first undo after the "
            ~ "zero-delta cut gesture still changed the mesh instead of being "
            ~ "silent");
    }
}

// ---------------------------------------------------------------------------
// 6 — THE LAW ITSELF: THE COST IS PER TOOL, NOT A CONSTANT (verdict (b)).
//     This is the one assertion that needs BOTH fixtures, and it is the guard
//     against the shape a port would most plausibly take by accident:
//     normalising the two families to one number. Candidate (a) is exactly
//     that normalisation, and the cutting cell refuted it.
//
//     Plus the gap on the cutting family, RECOMPUTED rather than declared —
//     narrow it in either direction and this reddens.
// ---------------------------------------------------------------------------
unittest {
    auto m = measured();

    assert(m.refTransformZero > 0 && m.refCutZero > 0,
        format("one of the two frozen zero-delta costs is not positive "
               ~ "(transform %d, cutting %d) — the law is that a committed "
               ~ "empty-delta gesture is NEVER free, in either family",
               m.refTransformZero, m.refCutZero));
    assert(m.refTransformZero != m.refCutZero,
        format("the two fixtures now declare the SAME cost for a committed "
               ~ "zero-delta gesture (transform %d, cutting %d). That is "
               ~ "candidate (a) — 'the law and its number are both general' — "
               ~ "which this capture refuted. A corpus normalised to one "
               ~ "number cannot discriminate (a) from (b), and a port built on "
               ~ "it would hard-code the wrong constant",
               m.refTransformZero, m.refCutZero));

    // (1) the regression pin on our own side
    assert(m.cutZero.kB - m.cutControl.kB == kOursCutZeroSteps,
        format("a committed zero-delta CUTTING gesture now costs %d undo "
               ~ "steps; this file froze %d. This is a KNOWN DIVERGENCE from "
               ~ "the reference's %d — if you changed the behaviour "
               ~ "deliberately, re-measure, update this file and update "
               ~ "registry row 86",
               m.cutZero.kB - m.cutControl.kB, kOursCutZeroSteps, m.refCutZero));

    // (3) the gap, recomputed
    const long gap = m.refCutZero - (m.cutZero.kB - m.cutControl.kB);
    if (kStatusCut == "open") {
        assert(gap == m.refCutZero - kOursCutZeroSteps && gap > 0,
            format("the cutting gap is now %d undo steps (reference %d, ours "
                   ~ "%d); this file records %d. A gap of 0 means the law is "
                   ~ "ported: flip kStatusCut to \"closed\", re-freeze "
                   ~ "kOursCutZeroSteps and retire the cutting half of "
                   ~ "registry row 86. Any other number means the divergence "
                   ~ "CHANGED — re-measure",
                   gap, m.refCutZero, m.cutZero.kB - m.cutControl.kB,
                   m.refCutZero - kOursCutZeroSteps));
    } else {
        assert(gap == 0,
            format("kStatusCut says the law is ported, but the gap is still %d "
                   ~ "undo steps (reference %d, ours %d)",
                   gap, m.refCutZero, m.cutZero.kB - m.cutControl.kB));
    }
}

// ---------------------------------------------------------------------------
// MUTATIONS THAT REDDEN IT, all run on this tree 2026-08-30, in isolation
// (druntime stops a module at its FIRST failed assert, so a mutation that
// reddens several blocks shows only the first unless the earlier ones are
// removed for the run). Product mutations were rebuilt and the app relaunched
// off the mutated binary — verified through /proc/PID/exe, which reads
// "… (deleted)" while a live instance still serves the previous image.
//
//   M1 — DELETE THE GESTURE. This is the VACUITY mutation, and it is the one
//        that defeated the sibling file's step readings: the zero cell stops
//        pressing (`runCutCell("cut_zero_distance", false, false)` in
//        `measured()`). EVERY undo-step reading in this file stays exactly as
//        it was — blocks 2, 3, 4, 5 and 6 all still pass with block 1 removed,
//        measured — and block 1's engagement witness is the only thing that
//        reddens:
//          "the zero-distance gesture did NOT engage the cutting tool — its
//           own `lineDrawn` is still false, so the press never reached it and
//           every 'we record nothing' reading below is about a gesture that
//           did not happen"
//
//   M5 — THE FIXTURE ARITHMETIC, and it is the check the 2026-08-30
//        correction repaired. In
//        `tests/fixtures/gesture_zero_delta_undo_second_form.json`, cell
//        `armed_and_dropped_over_a_model_edit`: `"entries_recorded": 1` ->
//        `0`, i.e. the refuted value this file used to demand. Block 0
//        reddens, at tests/test_gesture_zero_delta_undo_second_form.d:592:
//          "the fixture's armed-and-dropped cells declare 0 and 1 entries.
//           The CORRECTED law (cross-check, 2026-08-30) is that the DROP is
//           free and the ARM is not: EACH armed-and-dropped region costs the
//           reference exactly ONE entry. …"
//        The same edit ALSO contradicts the cell's own undo indices (3 - 2 =
//        1), which the re-derivation added in block 0 now catches — that
//        derivation is what was missing when the 0 first went in.
//
//   M5b — THE RE-DERIVATION IS NOT DEAD, run separately to prove the new
//        block-0 arithmetic discriminates on its own: the same cell's
//        `"undo_index_that_reverts_the_previous_edit": 3` -> `4`, leaving
//        `entries_recorded` at the correct 1. Block 0 reddens one assertion
//        further down, at tests/test_gesture_zero_delta_undo_second_form.d:663:
//          "the fixture contradicts itself: armed_and_dropped_over_a_model_edit
//           declares entries_recorded 1, but its undo indices give 4 - 2 = 2.
//           Re-measure; do not patch one side"
//
//   M6 — DELETE THE REGION. The VACUITY mutation for the arm-and-drop half,
//        and the one the brief demanded be proven: `runArmDropCell`'s
//        `foreach (i; 0 .. regions)` body is emptied, so no tool is ever
//        armed or dropped. EVERY undo-step reading in block 2 stays exactly
//        as it was — `ad0.kB == ad1.kB == 1`, so `ours == 0 ==
//        kOursArmDropOverModelSteps` and `0 < 1` both still hold — and the
//        arms/drops witness is the only thing that reddens, at
//        tests/test_gesture_zero_delta_undo_second_form.d:730:
//          "the single armed-and-dropped region reported 0 arms and 0 drops
//           through /api/tool/state; it must report 1 and 1. The region never
//           happened, so the ZERO undo steps this block reads below is about
//           nothing at all — a deleted region body produces exactly the same
//           reading"
//        This is the sibling file's M1 failure in its own shape: the reading
//        block 2 makes is ZERO, and nothing about a zero can tell a hidden
//        entry from an absent one.
//
//   M6b — THE VACUITY, MEASURED RATHER THAN ASSERTED. M6 again, with block
//        2's and block 3's arms/drops witnesses DELETED as well. Block 2's
//        divergence reading stays GREEN over a region that never happened —
//        `ad0.kB == ad1.kB == 1`, so `ours == 0` and `0 < 1` both hold — and
//        the first failure is block 3, the PARITY row, at
//        tests/test_gesture_zero_delta_undo_second_form.d:875:
//          "a SECOND armed-and-dropped transform region cost 0 undo steps (kB
//           1 against the single region's 1); the reference records 1 entries
//           for the same region. This is the PARITY row — losing it means the
//           read itself moved, not the law, and it takes block 2's only
//           positive witness with it"
//        So the two channels are independent and both are needed: without
//        the witness block 2 cannot fail on a deleted region, and block 3 is
//        the only step reading in the file that a deleted region reddens.
//
//   M3 — MAKE EVERY LIFECYCLE TAIL TRANSPARENT IN THE PRODUCT.
//        `CommandHistory.undo`'s (R1) block: `if (!foundModel)` -> `if
//        (false)`. This does NOT close row 87 — it WIDENS it, which is worth
//        knowing before anyone reaches for it as the port: shape 2 falls from
//        1 to 0 while shape 1 stays at 0, so every region becomes free and we
//        move further from the reference's one-per-region. Block 3, the
//        PARITY row, reddens first:
//          "a SECOND armed-and-dropped transform region cost 0 undo steps (kB
//           1 against the single region's 1); the reference records 1 entries
//           for the same region. This is the PARITY row — losing it means the
//           read itself moved, not the law, and it takes block 2's only
//           positive witness with it"
//        Block 4 reddens on the same mutation for its own reason (the two
//        instruments stop disagreeing), which is why the M2 run below removes
//        blocks 3 AND 4.
//
//   M2 — CLOSE THE CUTTING GAP IN THE PRODUCT. `SliceTool.updatePreview`
//        (source/tools/slice/slice_tool.d): `previewLive_ = nSplit > 0;` ->
//        `previewLive_ = true;`, i.e. record on a gesture that split no face.
//        With blocks 3 and 4 removed, block 5 reddens:
//          "DIVERGENCE CLOSED: the first undo after a committed zero-delta
//           CUTTING gesture no longer reverts the edit that preceded it —
//           which is what the reference does (task 2660, verdict (b)). …"
//        Note this mutation and not the more obvious one — dropping
//        `!previewLive_` from `commitCurrentSlice`'s early return — because
//        that one records in the CONTROL cell too and reddens block 1's
//        calibration instead, which says nothing about the law.
//
//   M4 — NOT A MUTATION, and deliberately not run as one: the reason the stand
//        is command-built. A drag-built stand ends in its own tool-drop
//        `ToolLifecycle` entry, which is the SAME stack tail that cell
//        `armdrop_over_model_edit` leaves behind — and the cost of one further
//        arm-and-drop over that tail is measured, at 1, by block 3 itself. So
//        a drag-built stand would make block 2 read 1, collapse the two stack
//        shapes into one, and lose the SHAPE-1 divergence for a reason that
//        has nothing to do with the law. No separate run is needed to know
//        that; block 3 is the measurement. Since 2026-08-30 this is also the
//        cheapest statement of row 87's mechanism: what the region costs us
//        is decided by the entry BELOW it, and (R1) hides exactly one
//        lifecycle tail per Model entry.
