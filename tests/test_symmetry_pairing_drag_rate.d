// Task 2000 — THE SYMMETRY PAIR TABLE IS REBUILT ONCE PER GESTURE, NOT ONCE
// PER DRAG STEP.
//
// ===========================================================================
// WHY A RATE AND NOT A VALUE
// ===========================================================================
// `SymmetryStage.evaluate` keeps a mirror pair table (`pairOf` / `onPlane` /
// `vertSign`) rebuilt by a geometric search over vertex POSITIONS. Rebuild it
// once or twenty times and every value it publishes is identical, so no
// assertion about a mirrored transform can see the difference. The only
// observable is `toolpipe.stages.symmetry.g_symPairingRebuilds`, read here
// over `/api/cache/rebuilds`.
//
// Measured 2026-08-25, from the same pair of changes that hit the snap grid
// (task 2000's card): keying this cache on a watcher that carries a live
// drag's per-step `Position` deliveries turned one rebuild per gesture into
// one per STEP. `move/symmetry=X` `pipeSymmetry` read 1 021.7 ms across a
// 20-step drag against a 0.6 ms kernel, with 2 MB allocated per step — and
// the stage timer's MEDIAN stayed at 0, because most of its calls were still
// cache hits. A median cannot see a cost that lands on 20 of 45 calls; a
// count can.
//
// ===========================================================================
// WHY ONE REBUILD IS ENOUGH
// ===========================================================================
// A drag under an ENABLED symmetry stage applies the mirror, so the mesh stays
// symmetric through the gesture and the pair table it would recompute at step
// 20 is the table it computed at step 1. What must NOT be held is a table
// across a change the mirror did not make symmetric — a command, an undo, a
// load — and those are exactly the publishers that still advance the stage's
// key.
//
// ===========================================================================
// EVERY REFUSAL IN THE RIG
// ===========================================================================
//   * THE GRAB IS VERIFIED. A gesture that missed the +X arrow moves nothing,
//     evaluates no pipe step and would read as a perfect `delta == 1`.
//   * `delta == 1` IS ALSO THE ANTI-VACUITY GUARD: symmetry OFF reads 0 here
//     (`evaluate`'s rebuild block is inside `if (enabled && ...)`), not 1.
//   * WHERE THE ONE REBUILD COMES FROM, because "1" would otherwise read as
//     "the first drag step rebuilt and the other 19 did not". It is the
//     COMMIT, not a step: the table is already built before the count starts
//     (`evalPivot()` evaluates the pipe to find the gizmo), no drag step
//     invalidates it, and `TransformTool.recordCommit` then publishes an
//     UNCONFINED `Position` at mouse-up, which the next frame's evaluate sees.
//     So this one assertion pins BOTH halves of the fix at once — no per-step
//     rebuild AND a re-arm at the commit — and a 0 means the re-arm is gone
//     just as surely as it means symmetry never engaged.
//   * THE CUBE IS SYMMETRIC ABOUT X, so the pairing is non-trivial — a mesh
//     with no mirror partners would still "rebuild", but the table would be
//     empty and the file would be measuring an early-out.
//
// Run via: ./run_test.d test_symmetry_pairing_drag_rate

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import std.stdio  : writefln;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers : fetchCamera, viewportFromCamera, axisGrabPx,
                      buildDragLog, playAndWait, DHVec3 = Vec3;

void main() {}

alias BASE = testBaseUrl;


void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

void settle() { Thread.sleep(250.msecs); }

long pairingRebuilds() {
    return getJson("/api/cache/rebuilds")["symmetryPairingRebuilds"].integer;
}

double[3] vert0() {
    auto v = getJson("/api/model")["vertices"].array[0].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

double dist2(double[3] a, double[3] b) {
    double s = 0;
    foreach (k; 0 .. 3) s += (a[k] - b[k]) * (a[k] - b[k]);
    return s;
}

DHVec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return DHVec3(cast(float)c[0].floating, cast(float)c[1].floating,
                  cast(float)c[2].floating);
}

void arm() {
    postJson("/api/command", commandBody("scene.reset"));
    auto camR = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":0.6,"distance":6.0,`
      ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert("error" !in camR, "/api/camera failed: " ~ camR.toString);

    auto r = post(BASE ~ "/api/script",
        "tool.pipe.attr symmetry enabled true\n"
      ~ "tool.pipe.attr symmetry axis x\n");
    assert(parseJSON(cast(string)r)["status"].str == "ok",
        "symmetry config failed: " ~ cast(string)r);
    cmd("tool.set move");
    settle();
}

/// One verified +X move-arrow gesture; returns the `symmetryPairingRebuilds`
/// delta across the gesture that actually moved the cage.
long dragXAndCountRebuilds(int steps, double dragPx = 70.0) {
    foreach (attempt; 0 .. 6) {
        settle();
        auto cam = fetchCamera(BASE);
        auto vp  = viewportFromCamera(cam);
        int gx, gy;
        double ux, uy;
        axisGrabPx(evalPivot(), vp, gx, gy, ux, uy);

        const auto before = vert0();
        const long b0 = pairingRebuilds();
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 gx, gy,
                                 gx + cast(int)(dragPx * ux),
                                 gy + cast(int)(dragPx * uy),
                                 steps), BASE);
        settle();
        const long delta = pairingRebuilds() - b0;
        if (dist2(before, vert0()) > 1e-4) return delta;
    }
    assert(false, "the move-arrow grab never landed — every attempt left the "
                ~ "cage where it was, so no rebuild count below would be "
                ~ "measuring a drag under a live symmetry stage");
}

// ---------------------------------------------------------------------------
// (1) A 20-step gizmo drag under symmetry X rebuilds the pair table ONCE.
// ---------------------------------------------------------------------------
unittest {
    arm();

    enum int kSteps = 20;
    const long delta = dragXAndCountRebuilds(kSteps);

    writefln("[symmetry pairing rate] %d-step drag rebuilt the pair table %d time(s)",
             kSteps, delta);

    assert(delta == 1,
        format("a %d-step gizmo drag under symmetry X must rebuild the mirror "
             ~ "pair table ONCE, and it rebuilt it %d time(s).\n"
             ~ "  %d means the stage's freshness term is advancing on the "
             ~ "drag's own per-step `Position` delivery. The mirror keeps the "
             ~ "mesh symmetric through the gesture, so every one of those "
             ~ "rebuilds recomputes the table it already had — measured at "
             ~ "~51 ms and ~2 MB each on the n=316 perf grid.\n"
             ~ "  0 has TWO causes and both are defects: symmetry never "
             ~ "engaged (so nothing here measured the pair table at all), or "
             ~ "the gesture's COMMIT no longer re-arms the watcher — "
             ~ "`TransformTool.recordCommit`'s unconfined `Position` — and a "
             ~ "table built before the gesture is now outliving the geometry "
             ~ "it describes.",
               kSteps, delta, kSteps));

    cmd("tool.set move off");
}

// ---------------------------------------------------------------------------
// (2) A COMMAND still drops it. The narrowing in (1) must cost nothing in the
//     direction that matters: a mesh edit the mirror did NOT make symmetric
//     has to invalidate the table, or a stale pairing outlives the geometry
//     it describes.
//
//     `mesh.subdivide` is the vehicle: it changes both the vertex count and
//     every position, through the ordinary command path, with no gesture in
//     sight.
// ---------------------------------------------------------------------------
unittest {
    arm();
    // One evaluate to make sure the table is BUILT before the command — else
    // the +1 below could be the very first build rather than an invalidation.
    getJson("/api/toolpipe/eval");
    settle();
    const long b0 = pairingRebuilds();

    cmd("mesh.subdivide");
    settle();
    getJson("/api/toolpipe/eval");
    settle();

    const long delta = pairingRebuilds() - b0;
    writefln("[symmetry pairing rate] subdivide + one evaluate rebuilt the "
           ~ "pair table %d time(s)", delta);
    assert(delta >= 1,
        format("a command that changes every vertex must invalidate the "
             ~ "symmetry pair table — it rebuilt %d time(s). A 0 means the "
             ~ "stage's key stopped seeing NON-gesture geometry changes, "
             ~ "which is the over-correction this narrowing must not make.",
               delta));

    cmd("tool.set move off");
}
