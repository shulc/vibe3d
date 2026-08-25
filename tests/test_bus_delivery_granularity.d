// Task 1906 stage 1, plan row `0-R6` — THE DRAG DELIVERS ONCE PER GESTURE
// STEP, AND `lastFlushFlags` IS THE LAST DELIVERY RATHER THAN A FRAME UNION.
//
// ---------------------------------------------------------------------------
// Why this file exists when `tests/test_change_bus.d` already asserts flags
// ---------------------------------------------------------------------------
// `test_change_bus.d` has three `lastFlushFlags` asserts. Every one of them is
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
// never delivers: the class sat in `pendingChanges_` until the frame flush,
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
// (2) `lastFlushFlags` IS AN ASSIGNMENT — the `mesh.subdivide` control
// ---------------------------------------------------------------------------
// `change_bus.ChangeBus.flush` does `lastFlushFlags = meshFlags`, so the field
// names the most recent NON-EMPTY flush and nothing older. Mutation row
// `0-R6`: make it `|=` instead. Every existing assert stays green; this block
// reddens, because after a drag has put `Position` in the word, a
// `mesh.subdivide` flush carries `Geometry` and NO `Position` — and a union
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
long flushes()       { return getJson("/api/changes")["flushCount"].integer; }
uint lastFlushFlags() {
    return cast(uint)getJson("/api/changes")["lastFlushFlags"].integer;
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
             ~ "`noteChange`, which accumulates into pendingChanges_ and "
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
// (2) `lastFlushFlags` names the LAST flush, not the union of the session.
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

    const uint afterDrag = lastFlushFlags();
    assert((afterDrag & kPosition) != 0,
        format("PREMISE: after a move-arrow drag the most recent flush must "
             ~ "carry Position (%d); got %d. Without this the next assert "
             ~ "cannot distinguish an assignment from a union — there would "
             ~ "be no Position bit for a union to keep",
               kPosition, afterDrag));

    const long dBefore = deliveries();
    const long fBefore = flushes();
    postJson("/api/command", `{"id":"mesh.subdivide"}`);
    settle();

    assert(flushes() > fBefore,
        "PREMISE: the subdivide must produce a flush of its own — with no "
      ~ "new flush `lastFlushFlags` still names the drag and the assert "
      ~ "below would pass for the wrong reason");

    const uint afterSubdivide = lastFlushFlags();
    assert((afterSubdivide & kGeometry) != 0,
        format("PREMISE: the subdivide's flush must carry Geometry "
             ~ "(Points|Polygons = %d); got %d", kGeometry, afterSubdivide));

    // THE CELL. Under `lastFlushFlags |= meshFlags` this word would still
    // carry the drag's Position bit.
    assert((afterSubdivide & kPosition) == 0,
        format("`lastFlushFlags` must name the LAST delivered flush, not the "
             ~ "union of the session: the subdivide moved no vertex in place, "
             ~ "so Position (%d) must be GONE from the word. Got %d — a union "
             ~ "can never lose a bit, which is exactly what mutation row "
             ~ "`0-R6` restores", kPosition, afterSubdivide));

    // The stage-2 precondition, in executable form: this command's last mesh
    // publisher is a `noteChange`, and `noteChange` never delivers.
    const long dDelta = deliveries() - dBefore;
    writefln("[bus granularity] mesh.subdivide: lastFlushFlags=%d, "
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
