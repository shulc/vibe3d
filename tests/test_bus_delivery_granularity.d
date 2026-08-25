// Task 1906 — DELIVERY GRANULARITY: HOW OFTEN THE BUS FIRES PER GESTURE.
//
// Six blocks, and they pin three DIFFERENT ceilings — read the block headers
// before assuming one covers another:
//   (1) a gizmo DRAG        — once per gesture STEP, never per vertex
//   (2) the flag word       — an assignment, not a union
//   (3) a selection COMMAND — exactly once
//   (4) an interactive LASSO— exactly once for the whole gesture (stage 3)
//   (5) a lasso that moved no mark — ZERO (stage 3)
//   (6) a paint STROKE      — once per element ADDED, not per motion (stage 3)
//
// Blocks (4)-(6) were added by the stage-3 review: (1) bounds a per-APPLY
// publisher whose count is twelve whatever the mesh size is, so it is not a
// witness for the PICK paths, where the per-element shape actually appeared.
//
// Original header follows.
//
// Task 1906 stage 1, plan row `0-R6` — THE DRAG DELIVERS ONCE PER GESTURE
// STEP, AND THE FLAG WORD IS THE LAST DELIVERY RATHER THAN A UNION.
//
// TASK 1906 STAGE 3 — THE FIELD THIS FILE WATCHES CHANGED ITS NAME AND ITS
// OWNER, and block (2) was re-read rather than repointed. It watched
// `lastFlushFlags`, the per-frame flush's mesh word; stage 3 took the mesh
// channel off the flush entirely and deleted that field. The property it
// pinned — "the word NAMES the most recent publication and does not
// accumulate" — is now `lastDeliveryFlags`, assigned by `ChangeBus.deliverMesh`,
// and mutation row `0-R6` transfers verbatim: make that assignment a `|=` and
// this block reddens because a union can never LOSE the drag's Position bit.
//
// ---------------------------------------------------------------------------
// Why this file exists when `tests/test_change_bus.d` already asserts flags
// ---------------------------------------------------------------------------
// `test_change_bus.d` has three flag-word asserts. Every one of them is
// a SINGLE-COMMIT scripted case — one command, one flush — and on a single
// commit "the last delivery's flags" and "the union of this frame's flags" are
// the SAME WORD. So all three stay green under either semantics, and neither
// of them can see the thing this task changed.
//
// The two claims below need a MULTI-STEP INTERACTIVE GESTURE, which is why
// this is a suite test driving a real gizmo drag through
// `drag_helpers.buildDragLog` / `playAndWait` rather than another scripted
// `/api/command` round.
//
// ---------------------------------------------------------------------------
// (1) GRANULARITY — `deliveryCount` moves once per gesture STEP
// ---------------------------------------------------------------------------
// Before stage 1 the three interactive-apply sites
// (`tools/transform/xfrm_apply.d` x2, `tools/transform/transform.d ::
// uploadToGpu`) called `mesh.noteChange(Position)`, which ACCUMULATES and
// never delivers: the class sat in `undeliveredChanges_` until the frame flush,
// and `deliveryCount` — the synchronous-delivery counter — did not move AT
// ALL for a whole drag. Measured on `main` before this change: a 12-step drag
// moved `deliveryCount` by 0.
//
// After stage 1 those three sites are `mesh.publishChange(Position)`: same
// class, same once-per-apply granularity, and the delivery happens at the edit
// boundary.
//
// The assert is a BAND, `>= steps && <= 2 * steps`, and each side is there for
// its own reason.
//
//   * The FLOOR refuses the pre-stage-1 shape: `noteChange` accumulates and
//     never delivers, so a whole drag moved `deliveryCount` by 0.
//   * The CEILING refuses a PER-VERTEX publish. Move the call inside the
//     kernel's vertex loop and a 12-step drag on the default cube delivers
//     12 x 8 = 96 times; on any real mesh, 12 x N. Without the ceiling the
//     "once per apply, never per vertex" half of the claim has no witness at
//     all, and that half is the one that decides whether synchronous delivery
//     is affordable.
//   * 2x rather than 1x, because a step can legitimately publish twice: the
//     three sites are per-APPLY, and `uploadToGpu` is a second one. It is not
//     what a plain drag does — measured here, the count is exactly `steps`,
//     because `uploadToGpu` is reached only through `needsGpuUpdate`, which
//     the single-bank gizmo fast path never sets (it stays on `gpuMatrix`).
//     The branches that do set it — a cross-bank Move, a dirty run buffer
//     under Rotate/Scale, the value/panel translate replay, the ARM-1/ARM-2
//     re-grade — are the transform family's own apply structure, which this
//     task neither owns nor freezes, so the band leaves them room.
//
// THE POSITIVE CONTROL IS LOAD-BEARING. A drag whose grab MISSES the arrow
// moves the CAMERA instead of the mesh, and a camera orbit publishes no mesh
// class at all — so a missed grab produces a delta of 0 and would read as the
// pre-stage-1 behaviour. The block therefore verifies the cage actually moved
// before it believes any count, and retries the grab if it did not.
//
// ---------------------------------------------------------------------------
// (2) THE FLAG WORD IS AN ASSIGNMENT — the `mesh.subdivide` control
// ---------------------------------------------------------------------------
// `change_bus.ChangeBus.deliverMesh` does `lastDeliveryFlags = meshFlags`, so
// the field names the most recent NON-EMPTY delivery and nothing older.
// Mutation row `0-R6`: make it `|=` instead. Every existing assert stays green;
// this block reddens, because after a drag has put `Position` in the word, a
// `mesh.subdivide` delivery carries `Geometry` and NO `Position` — and a union
// can never LOSE a bit.
//
// `mesh.subdivide` is the right control for a second reason: it is a command
// whose LAST mesh publisher is a `noteChange(Geometry)`
// (`commands/mesh/subdivide.d` — the `*mesh = ...` swap reset the counters, so
// the command notes rather than commits), which is the shape the plan's
// stage-2 precondition is about.
//
// MEASURED HERE, AND IT CORRECTS THAT PRECONDITION AS WRITTEN. The plan says
// such a command "delivers NOTHING synchronously". On this tree it delivers
// EXACTLY ONCE, with flags 14 (`Points|Polygons|Marks`). The reason is stage
// 0b's `final Command.apply()` wrapper: a SIBLING publisher inside the same
// command does commit, which registers the mesh in the deferred set, and the
// batch close then delivers the ACCUMULATED word — the trailing `noteChange`
// bits ride that one delivery instead of being orphaned. So the precondition
// holds for the PUBLISHER (`noteChange` still never delivers on its own) and
// NOT for the COMMAND. Stage 2 must key on that distinction; this block pins
// the number so the distinction cannot drift unobserved.

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

// `MeshEditScope` (source/mesh_edit_delta.d) — spelled out rather than
// imported, because these test binaries compile standalone.
enum uint kPosition = 1 << 0;
enum uint kPoints   = 1 << 1;
enum uint kPolygons = 1 << 2;
enum uint kMarks    = 1 << 3;
enum uint kGeometry = kPoints | kPolygons;
/// The measured word `mesh.subdivide` delivers on this tree (2026-08-25):
/// Points|Polygons|Marks. Spelled as a sum of its bits so a failure message
/// says WHICH class moved rather than "14 became 15".
enum uint kSubdivideDelivery = kPoints | kPolygons | kMarks;   // == 14

JSONValue getJson(string path) { return parseJSON(cast(string)get(BASE ~ path)); }

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

void settle() { Thread.sleep(200.msecs); }

long deliveries()    { return getJson("/api/changes")["deliveryCount"].integer; }
uint lastDeliveryFlagsNow() {
    return cast(uint)getJson("/api/changes")["lastDeliveryFlags"].integer;
}

double[3] vert0() {
    auto v = getJson("/api/model")["vertices"].array[0].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

double dist(double[3] a, double[3] b) {
    double s = 0;
    foreach (k; 0 .. 3) s += (a[k] - b[k]) * (a[k] - b[k]);
    return s;
}

/// The live gizmo pivot — the point `axisGrabPx` needs to find the +X arm.
Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating, cast(float)c[1].floating,
                cast(float)c[2].floating);
}

/// One +X move-arrow gesture of exactly `steps` motion events, with the grab
/// verified rather than assumed. Returns the `deliveryCount` delta measured
/// across the gesture that ACTUALLY moved the cage.
long dragXAndCountDeliveries(int steps, double dragPx = 70.0) {
    foreach (attempt; 0 .. 6) {
        settle();
        auto cam = fetchCamera(BASE);
        auto vp  = viewportFromCamera(cam);
        int gx, gy;
        double ux, uy;
        axisGrabPx(evalPivot(), vp, gx, gy, ux, uy);

        const auto before = vert0();
        const long d0 = deliveries();
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 gx, gy,
                                 gx + cast(int)(dragPx * ux),
                                 gy + cast(int)(dragPx * uy),
                                 steps), BASE);
        settle();
        const long delta = deliveries() - d0;
        if (dist(before, vert0()) > 1e-4) return delta;
    }
    assert(false, "the move-arrow grab never landed — every attempt left the "
                ~ "cage where it was, so no delivery count below would be "
                ~ "measuring a drag");
}

// ---------------------------------------------------------------------------
// (1) A 12-step drag delivers between 12 and 24 times — once per gesture
//     STEP, never once per VERTEX.
//
//     Measured here: exactly 12 — one per motion event. The band is `>=` at
//     the bottom and `<= 2x` at the top because `uploadToGpu` is a SECOND
//     per-apply publish site; the unified wrapper this drag arms stays on the
//     GPU-matrix fast path and reaches `applyFold` only, so the two coincide
//     today and need not tomorrow. Measured on `main` with the same log: 0.
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    cmd("tool.set move");
    settle();

    enum int kSteps = 12;
    const long delta = dragXAndCountDeliveries(kSteps);

    writefln("[bus granularity] %d-step drag delivered %d times", kSteps, delta);
    assert(delta >= kSteps,
        format("a %d-step gizmo drag must deliver at least once per step; "
             ~ "deliveryCount moved by %d. A 0 is the pre-stage-1 shape "
             ~ "exactly: the three interactive-apply sites called "
             ~ "`noteChange`, which accumulates into undeliveredChanges_ and "
             ~ "waits for the frame flush, so no synchronous delivery "
             ~ "happened for the whole gesture", kSteps, delta));
    // The other side of the band: ONCE PER APPLY, NEVER PER VERTEX. A publish
    // moved inside the transform kernel's vertex loop delivers steps x N — on
    // the default cube 12 x 8 = 96 — and every count in that shape is above
    // this ceiling. Without it the floor alone is satisfied by the per-vertex
    // publish too, and the claim this file is named for goes untested.
    const long verts = getJson("/api/model")["vertices"].array.length;
    assert(delta <= 2 * kSteps,
        format("a %d-step gizmo drag must deliver ONCE PER APPLY, never once "
             ~ "per vertex: deliveryCount moved by %d, and the ceiling is "
             ~ "%d (two per-apply publish sites x %d steps). The mesh has %d "
             ~ "vertices, so a publish that slipped inside the kernel's "
             ~ "vertex loop would read as about %d here",
               kSteps, delta, 2 * kSteps, kSteps, verts, kSteps * verts));

    cmd("tool.set move off");
}

// ---------------------------------------------------------------------------
// (2) `lastDeliveryFlags` names the LAST delivery, not the union of the session.
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    cmd("tool.set move");
    settle();

    // Put `Position` in the word with a real drag — a scripted transform would
    // do it too, but then the premise and the thing under test would share a
    // path and the block would say nothing about the interactive one.
    dragXAndCountDeliveries(6);
    cmd("tool.set move off");
    settle();

    const uint afterDrag = lastDeliveryFlagsNow();
    assert((afterDrag & kPosition) != 0,
        format("PREMISE: after a move-arrow drag the most recent delivery must "
             ~ "carry Position (%d); got %d. Without this the next assert "
             ~ "cannot distinguish an assignment from a union — there would "
             ~ "be no Position bit for a union to keep",
               kPosition, afterDrag));

    const long dBefore = deliveries();
    postJson("/api/command", `{"id":"mesh.subdivide"}`);
    settle();

    assert(deliveries() > dBefore,
        "PREMISE: the subdivide must produce a DELIVERY of its own — with no "
      ~ "new delivery `lastDeliveryFlags` still names the drag and the assert "
      ~ "below would pass for the wrong reason");

    const uint afterSubdivide = lastDeliveryFlagsNow();
    assert((afterSubdivide & kGeometry) != 0,
        format("PREMISE: the subdivide's delivery must carry Geometry "
             ~ "(Points|Polygons = %d); got %d", kGeometry, afterSubdivide));

    // THE CELL. Under `lastDeliveryFlags |= meshFlags` this word would still
    // carry the drag's Position bit.
    assert((afterSubdivide & kPosition) == 0,
        format("`lastDeliveryFlags` must name the LAST delivery, not the "
             ~ "union of the session: the subdivide moved no vertex in place, "
             ~ "so Position (%d) must be GONE from the word. Got %d — a union "
             ~ "can never lose a bit, which is exactly what mutation row "
             ~ "`0-R6` restores", kPosition, afterSubdivide));

    // The stage-2 precondition, in executable form: this command's last mesh
    // publisher is a `noteChange`, and `noteChange` never delivers.
    const long dDelta = deliveries() - dBefore;
    writefln("[bus granularity] mesh.subdivide: lastDeliveryFlags=%d, "
           ~ "deliveryCount delta=%d", afterSubdivide, dDelta);
    const uint lastDelivery =
        cast(uint)getJson("/api/changes")["lastDeliveryFlags"].integer;
    assert(dDelta == 1,
        format("`mesh.subdivide` must produce EXACTLY ONE delivery — its own "
             ~ "publishers are wrapped in the one delivery batch `final "
             ~ "Command.apply()` opens; got %d. A 0 would mean the command "
             ~ "stopped committing entirely (and the plan's stage-2 "
             ~ "precondition would then be literally true for it); anything "
             ~ "above 1 means a publisher escaped the batch", dDelta));
    assert(lastDelivery == kSubdivideDelivery,
        format("the subdivide's one delivery must carry EXACTLY "
             ~ "Points|Polygons|Marks (%d) — it replaces the mesh wholesale, "
             ~ "so it moves no vertex in place and a Position bit (%d) here "
             ~ "would mean the drag's class was carried into a later, "
             ~ "unrelated delivery. Got %d. This is the DELIVERY channel's "
             ~ "own version of the assert above, and it is an EQUALITY on "
             ~ "purpose: the header claims stage 2 must key on \"this command "
             ~ "delivers exactly one accumulated word\", and a mask test "
             ~ "would let that word gain or lose a class unobserved",
               kSubdivideDelivery, kPosition, lastDelivery));
}

// ---------------------------------------------------------------------------
// (3) TASK 1906 STAGE 3 — A SELECTION-ONLY COMMAND DELIVERS, AND EXACTLY ONCE.
// ---------------------------------------------------------------------------
// This is the witness for the stage-3 precondition conversion, and the number
// it pins was MEASURED on both sides.
//
// Before stage 3: `select.invert` and the `select.byStat.*` family moved
// `deliveryCount` by **0**. They never call a publisher at all — the marks
// setters they drive end in `noteSelectionChange`, which accumulates and never
// delivers — so their whole channel was the per-frame drain of
// `Mesh.pendingChanges_` that stage 3 deletes. Fired one per `/api/reset` on
// the live app, each of them showed `deliveryCount +0, flushCount +1,
// totalMarks +1`.
//
// After stage 3: **1**, structurally. Two changes make it so, and either one
// alone would leave a hole:
//   * `Command.apply`'s `scope(exit)` OFFERS the command's own mesh to the
//     delivery batch it already opened, so a command whose publishers are all
//     accumulate-only still delivers at the close;
//   * the selection WRITERS on `Mesh` deliver, which covers the meshes a
//     command touches that are not its own (`select.set.apply` walks every
//     foreground layer) and the tool paths that are not commands at all.
//
// MUTATIONS, each in isolation:
//   * delete the `mesh.deliverAccumulated()` line from `Command.apply`'s
//     `scope(exit)` ⇒ this block reddens with delta 0 …
//   * … only if the writers are ALSO reverted; with the writers delivering,
//     the count survives the anchor's removal, which is why the assert below
//     is an EQUALITY (a second delivery would mean the two mechanisms stopped
//     coalescing) and why the header says either alone leaves a hole.
//
// The control is the FIRST assert: `select.invert` must actually change the
// selection, or "one delivery" would be a claim about a command that did
// nothing.
unittest {
    postJson("/api/reset", "");
    settle();

    const long selBefore =
        getJson("/api/selection")["selectedVertices"].array.length;
    assert(selBefore == 0,
        format("PREMISE: a fresh /api/reset must leave nothing selected; got "
             ~ "%d — the invert below would then be a different edit",
               selBefore));

    const long dBefore = deliveries();
    cmd("select.invert");
    settle();
    const long dDelta = deliveries() - dBefore;

    const long selAfter =
        getJson("/api/selection")["selectedVertices"].array.length;
    assert(selAfter == 8,
        format("PREMISE: select.invert on an empty selection must select all "
             ~ "eight cube vertices; got %d — with no selection change there "
             ~ "would be nothing to deliver and the count below would be a "
             ~ "claim about a command that did nothing", selAfter));

    assert(dDelta == 1,
        format("a selection-only command must deliver EXACTLY ONCE. Got %d. "
             ~ "0 is the pre-stage-3 shape — the command's only publisher is "
             ~ "`noteSelectionChange`, which accumulates and never delivers, "
             ~ "so its classes reached the bus only through the per-frame "
             ~ "drain this stage deleted. Above 1 means the command anchor and "
             ~ "the delivering writers stopped coalescing into one batch",
               dDelta));
}

// ---------------------------------------------------------------------------
// (4) TASK 1906 STAGE 3 (review M1) — AN INTERACTIVE LASSO DELIVERS ONCE PER
//     GESTURE, NOT ONCE PER PICKED ELEMENT.
// ---------------------------------------------------------------------------
// THE CEILING THIS PINS IS THE ONE BLOCK (1) DOES NOT. Block (1) bounds a
// twelve-step GIZMO DRAG, whose publisher is per-apply and whose count is
// therefore twelve whatever the mesh size is. It says nothing about the PICK
// paths, and those are where the per-element shape actually appeared: since
// stage 3 every selection writer on `Mesh` delivers, `symmetry_pick.d`'s
// helpers batch per PICKED ELEMENT, and the lasso commit loops over every
// enclosed face. MEASURED on this tree with the batch removed:
//
//     grid n=32 → 838 faces selected → deliveryCount +838
//     grid n=64 → 3 417 faces        → deliveryCount +3 417
//
// i.e. the count is O(selected elements) for ONE gesture — every one a fan-out
// to every listener. With the gesture batch in `input_router.d`'s lasso commit
// block: +1 and +1.
//
// THE MUTATION ROW: delete the `app.mesh.beginDeliveryBatch()` /
// `scope(exit) { deliverAccumulated(); endDeliveryBatch(); }` pair from the
// lasso commit block in `source/input_router.d`. This block then reddens with
// a delta in the hundreds, and the message names the count.
//
// WHY A GRID AND NOT THE DEFAULT CUBE. On a cube the whole mesh is six faces,
// so "once per gesture" and "once per element" differ by at most six and a
// flake in either direction reads as the other. The grid makes the two
// hypotheses differ by three orders of magnitude.
//
// WHY THE CAMERA IS BELOW THE PLANE: the grid's Newell-method winding makes
// the Polygons-lasso front-facing pre-check reject every face from the default
// above-plane camera, so the gesture would select NOTHING and the count would
// be 0 under both hypotheses. `elevation:-0.4` is the same setup the frame
// lane's `lasso-dense` scenario uses, and the selected-count floor below is
// what proves it took.
// ---------------------------------------------------------------------------

/// A closed rectangular RMB band, in the shape `EventPlayer` replays. Local to
/// this file rather than in `drag_helpers`: it is the only consumer, and the
/// helper modules carry no `unittest` of their own by rule.
string buildLassoLog(int vpX, int vpY, int vpW, int vpH,
                     int cx, int cy, int halfW, int halfH,
                     int stepsPerSide = 20) {
    enum int kRMask = 4;   // SDL_BUTTON_RMASK
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    int[2][5] corners = [
        [cx - halfW, cy - halfH], [cx + halfW, cy - halfH],
        [cx + halfW, cy + halfH], [cx - halfW, cy + halfH],
        [cx - halfW, cy - halfH],
    ];
    double t = 50.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, corners[0][0], corners[0][1]);
    int lastX = corners[0][0], lastY = corners[0][1];
    foreach (side; 0 .. 4) {
        int x0 = corners[side][0],     y0 = corners[side][1];
        int x1 = corners[side + 1][0], y1 = corners[side + 1][1];
        foreach (i; 1 .. stepsPerSide + 1) {
            int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / stepsPerSide);
            int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / stepsPerSide);
            t += 10.0;
            log ~= format(
                `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":%d,"mod":0}` ~ "\n",
                t, x, y, x - lastX, y - lastY, kRMask);
            lastX = x; lastY = y;
        }
    }
    t += 10.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, lastX, lastY);
    return log;
}

/// An LMB press-drag-release across the mesh — the paint stroke, one motion
/// event per step.
string buildPaintLog(int vpX, int vpY, int vpW, int vpH,
                     int x0, int y0, int x1, int y1, int motions) {
    enum int kLMask = 1;   // SDL_BUTTON_LMASK
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    double t = 50.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x0, y0);
    int lx = x0, ly = y0;
    foreach (i; 1 .. motions + 1) {
        int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / motions);
        int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / motions);
        t += 16.0;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":%d,"mod":0}` ~ "\n",
            t, x, y, x - lx, y - ly, kLMask);
        lx = x; ly = y;
    }
    t += 16.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, lx, ly);
    return log;
}

long selectedFaceCount() {
    return getJson("/api/selection")["selectedFaces"].array.length;
}
long selectedVertexCount() {
    return getJson("/api/selection")["selectedVertices"].array.length;
}

/// Reset to a dense grid, put the current type on `mode`, and look at it from
/// below so the Polygons-lasso front-facing pre-check accepts the faces.
void gridSceneBelow(int n, string mode) {
    postJson("/api/reset?type=grid&n=" ~ n.to!string, "");
    postJson("/api/select", `{"mode":"` ~ mode ~ `","indices":[]}`);
    postJson("/api/camera", `{"elevation":-0.4}`);
    settle();
}

unittest {
    gridSceneBelow(32, "polygons");

    auto cam = fetchCamera(BASE);
    const int cx    = cam.vpX + cam.width  / 2;
    const int cy    = cam.vpY + cam.height / 2;
    const int halfW = cast(int)(cam.width  * 0.30);
    const int halfH = cast(int)(cam.height * 0.30);

    const long dBefore = deliveries();
    playAndWait(buildLassoLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              cx, cy, halfW, halfH), BASE);
    settle();
    const long dDelta   = deliveries() - dBefore;
    const long selected = selectedFaceCount();

    // THE POSITIVE CONTROL, and it is load-bearing exactly as block (1)'s is:
    // a lasso that selected nothing delivers once per nothing, so `dDelta == 1`
    // would read as a pass under the per-element shape too.
    assert(selected > 100,
        format("PREMISE: the band must enclose hundreds of faces, or 'one "
             ~ "delivery per gesture' and 'one per element' are the same "
             ~ "number and the assert below is free. Got %d selected — the "
             ~ "camera elevation or the grid reset did not take", selected));

    assert(dDelta == 1,
        format("an interactive LASSO must deliver ONCE for the whole gesture. "
             ~ "Got %d deliveries for %d selected faces. A delta near the "
             ~ "selected count is the per-ELEMENT shape: the gesture batch "
             ~ "around the lasso commit block in `source/input_router.d` is "
             ~ "gone, `symmetricSelect*`'s per-element batch is closing at "
             ~ "depth 0 again, and one full-viewport band on a dense mesh is "
             ~ "tens of thousands of fan-outs to every listener",
               dDelta, selected));
}

// ---------------------------------------------------------------------------
// (5) THE ZERO ARM — a gesture that changes no selection delivers NOTHING.
// ---------------------------------------------------------------------------
// This is the closest representable thing to the batch-ABORT half of the
// selection-service contract this seam follows (provenance in doc/, not here —
// no proprietary symbol names in tracked source), and the difference is worth
// stating rather than papering over: an abort there discards a batch of
// selection changes that were themselves rolled back. Our
// batch accumulates INVALIDATION for marks already written, so a discard would
// under-invalidate rather than undo — and there is no window for one anyway,
// because the whole lasso (band close, clear, select) runs inside a single
// mouse-up handler. What we CAN state, and what a listener actually cares
// about, is that a gesture which moves no mark produces no delivery.
//
// MUTATION ROW: delete the `if (any)` compare-before-set guard from
// `Mesh.clearFaceSelection` (or from `selectFace`). The empty band then
// publishes a `Marks` change for a selection that did not move and this block
// reddens with delta 1.
// ---------------------------------------------------------------------------
unittest {
    gridSceneBelow(32, "polygons");
    assert(selectedFaceCount() == 0,
        "PREMISE: the grid reset must leave nothing selected, or the band "
      ~ "below would legitimately deliver the clear");

    auto cam = fetchCamera(BASE);
    // A two-pixel band in the viewport's top-left corner: >= 3 path points, so
    // the lasso commit block IS entered and the clear IS reached, but nothing
    // is enclosed.
    const long dBefore = deliveries();
    playAndWait(buildLassoLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              cam.vpX + 3, cam.vpY + 3, 1, 1), BASE);
    settle();
    const long dDelta = deliveries() - dBefore;

    assert(selectedFaceCount() == 0,
        "PREMISE: the degenerate band must still enclose nothing");
    assert(dDelta == 0,
        format("a lasso gesture that moved no mark must deliver NOTHING; got "
             ~ "%d. Something on the gesture path publishes unconditionally — "
             ~ "a clear or a setter lost its compare-before-set guard",
               dDelta));
}

// ---------------------------------------------------------------------------
// (6) A PAINT STROKE DELIVERS ONCE PER ELEMENT IT ADDS — never once per
//     MOTION EVENT, and never once per PICK.
// ---------------------------------------------------------------------------
// THE LAW, and it is an EQUALITY rather than a band because the measurement
// says it can be: over a stroke that starts from an empty selection, the
// number of deliveries equals the number of elements the stroke SELECTED.
// Measured on `grid n=32`, three runs: 60 motions → 34 deliveries / 34
// vertices; 120 motions → 42 / 42, twice.
//
// TWO SEPARATE FACTS MAKE THAT TRUE, and the equality is what holds both:
//
//   * a pick writes the element AND its symmetry counterpart, and
//     `symmetry_pick.d` batches the pair into ONE delivery;
//   * a pick that lands on an element already selected delivers NOTHING,
//     because `Mesh.selectVertex/Edge/Face` compare before they set.
//
// The second is not a corner case: a stroke picks TWICE per cursor position —
// once from the motion event (`InputRouter.doSelectPickAt`) and once from the
// frame's own picker sweep — so without the guard the count is ~2.34x the
// motion count and has nothing to do with what was selected. MEASURED with the
// guard removed: 120 motions → 280 deliveries against 42 selected vertices.
//
// WHY THE STROKE IS NOT ONE BATCH, stated because the public SDK would make it
// one: the highlight must follow the cursor DURING the stroke, and the sel
// channel is what tells the FBO selection key to re-render. Holding one batch
// from mouse-down to mouse-up would defer every invalidation to the drop and
// freeze the highlight for the whole gesture. The per-gesture batch is
// therefore right for the LASSO (which commits in a single handler) and wrong
// for the paint stroke; the ceiling that applies here is per-CHANGE.
//
// MUTATION ROWS:
//   * delete the `if (marks[idx] & Marks.Select) return;` guard from
//     `Mesh.selectVertex` ⇒ deliveries jump to ~2.34 per motion and this block
//     reddens with the two numbers side by side;
//   * delete the `mesh.beginDeliveryBatch()` pair from
//     `symmetry_pick.symmetricSelectVertex` and turn symmetry on ⇒ the pair
//     write becomes two deliveries and the equality breaks upward.
// ---------------------------------------------------------------------------
unittest {
    gridSceneBelow(32, "vertices");
    assert(selectedVertexCount() == 0,
        "PREMISE: the grid reset must leave nothing selected");

    auto cam = fetchCamera(BASE);
    const int y  = cam.vpY + cam.height / 2;
    const int x0 = cam.vpX + cast(int)(cam.width * 0.2);
    const int x1 = cam.vpX + cast(int)(cam.width * 0.8);
    enum int kMotions = 120;

    const long dBefore = deliveries();
    playAndWait(buildPaintLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y, x1, y, kMotions), BASE);
    settle();
    const long dDelta   = deliveries() - dBefore;
    const long selected = selectedVertexCount();

    // POSITIVE CONTROL: the stroke must have painted something, and enough of
    // it that "once per added element" and "once per motion event" are
    // different numbers.
    assert(selected > 5 && selected < kMotions,
        format("PREMISE: the stroke must select several vertices and FEWER "
             ~ "than its %d motion events, or the equality below cannot tell "
             ~ "the per-change law from a per-motion one. Got %d",
               kMotions, selected));

    assert(dDelta == selected,
        format("a paint stroke must deliver exactly once per element it ADDS. "
             ~ "Got %d deliveries for %d newly selected vertices over %d "
             ~ "motion events. Above the selected count means a re-pick on an "
             ~ "already-selected element is publishing again (the "
             ~ "compare-before-set guard in `Mesh.selectVertex`), or the "
             ~ "symmetry pair is delivering twice (the batch in "
             ~ "`symmetry_pick.symmetricSelectVertex`)",
               dDelta, selected, kMotions));
}

// ---------------------------------------------------------------------------
// (7) TASK 1906 STAGE 3 (review round 2, R2-1) — AN UNDO DELIVERS ONCE, LIKE
// THE COMMAND IT REVERSES.
//
// `Command.apply` is `final` and opens the global delivery batch, so a forward
// `mesh.remove` over N edges delivers once. `Command.revert()` is a plain
// virtual with no batch, and a tracker delta restores the pre-op selection one
// element at a time (`mesh_edit_delta.finalize` -> `selectEdge` per recorded
// edge), each a delivering publisher since stage 3. Measured before the fix on
// `grid n=40`: forward 1, UNDO 3 003, redo 1 — the per-element shape the lasso
// batch (block 4) removed from the interactive path, surviving on the undo
// path. The fix is the same global batch, opened in `CommandHistory.undo()`
// and `redo()`. The law pinned here is an EQUALITY on both directions.
// ---------------------------------------------------------------------------
unittest {
    gridSceneBelow(40, "edges");
    enum int kEdges = 3000;
    string idx;
    foreach (i; 0 .. kEdges) idx ~= (i ? "," : "") ~ i.to!string;
    postJson("/api/select", `{"mode":"edges","indices":[` ~ idx ~ `]}`);

    const long d0 = deliveries();
    cmd("mesh.remove");
    const long dForward = deliveries() - d0;
    assert(dForward == 1,
        format("PREMISE: the forward mesh.remove over %d edges must deliver "
             ~ "exactly once (Command.apply's batch); got %d", kEdges, dForward));

    const long d1 = deliveries();
    postJson("/api/undo", "");
    const long dUndo = deliveries() - d1;
    assert(dUndo == 1,
        format("UNDO of a %d-edge remove delivered %d time(s), expected exactly 1. "
             ~ "The per-element shape is back on the undo path: the tracker delta "
             ~ "restores the selection with one `selectEdge` per recorded edge and "
             ~ "each one delivers unless CommandHistory.undo() holds the global "
             ~ "delivery batch (task 1906 stage 3, review round 2 R2-1: measured "
             ~ "3 003 before the fix).", kEdges, dUndo));

    const long d2 = deliveries();
    postJson("/api/redo", "");
    const long dRedo = deliveries() - d2;
    assert(dRedo == 1,
        format("REDO delivered %d time(s), expected exactly 1 — CommandHistory.redo() "
             ~ "must hold the same batch undo() does", dRedo));
}

// ---------------------------------------------------------------------------
// (8) TASK 1906 STAGE 3 (review round 3) — A RE-FIRE STEP DELIVERS ONCE.
//
// `CommandHistory.fire()` is the third entry point that runs a `revert()`
// outside `Command.apply`'s batch: inside a refire window (`/api/refire`
// begin … end — the panel's Post-Mode attribute drag) the second fire reverts
// the live command and applies the new one. The revert's per-element
// selection restore delivered 3 005 times for a 3 000-edge remove (measured)
// where the first fire delivered once. Block (7) cannot see this path — it
// drives undo/redo. The fix is the same global batch, held by `fire()`.
// ---------------------------------------------------------------------------
unittest {
    gridSceneBelow(40, "edges");
    enum int kEdges = 3000;
    string idx;
    foreach (i; 0 .. kEdges) idx ~= (i ? "," : "") ~ i.to!string;
    postJson("/api/select", `{"mode":"edges","indices":[` ~ idx ~ `]}`);

    auto begun = postJson("/api/refire", `{"action":"begin"}`);
    assert(begun["status"].str == "ok", "PREMISE: /api/refire begin must be accepted");
    scope(exit) postJson("/api/refire", `{"action":"end"}`);

    const long d0 = deliveries();
    cmd("mesh.remove");
    const long dFirst = deliveries() - d0;
    assert(dFirst == 1,
        format("PREMISE: the FIRST fire over %d edges must deliver exactly once; got %d",
               kEdges, dFirst));

    const long d1 = deliveries();
    cmd("mesh.remove");                       // re-fire: revert #1, apply #2
    const long dSecond = deliveries() - d1;
    assert(dSecond == 1,
        format("the SECOND fire (revert the live command, apply the new one) "
             ~ "delivered %d time(s), expected exactly 1. The per-element shape is "
             ~ "back on the re-fire path: CommandHistory.fire() must hold the global "
             ~ "delivery batch like undo()/redo() (task 1906 stage 3, review round 3: "
             ~ "measured 3 005 before the fix).", dSecond));
}
