// Task 2000 — THE SNAP CANDIDATE GRID IS BUILT ONCE PER GESTURE, NOT ONCE PER
// DRAG STEP.
//
// ===========================================================================
// WHY A RATE AND NOT A VALUE
// ===========================================================================
// `snap.queryCandidateGrid` answers each snap query from a screen-space bucket
// grid, and every candidate it offers is re-tested by the caller's exact walk.
// So a grid rebuilt on EVERY drag step returns exactly the same winner as a
// grid built once — same call count, same code path, same answer. Every value
// assertion in the snap suite is green over both. The only observable that
// separates them is HOW MANY TIMES the O(elements) projection pass ran, which
// is `snap.g_snapGridBuilds`, read here over `/api/cache/rebuilds`.
//
// The regression this file is the witness for (measured 2026-08-25): the
// grid's mesh term moved from `mesh.mutationVersion` to the change bus's
// geometry epoch, and — in the same window — a gizmo drag started delivering
// `Position` on every step. Both changes are right on their own; together
// they made the epoch advance 20 times per 20-step drag, so the grid was
// rebuilt 20 times. Five `#snapQuery` perf cases went +715..+1204 % and
// per-case allocation went up by exactly x20 = the step count.
//
// ===========================================================================
// WHY ONE REBUILD IS ENOUGH — THE EXCLUSION, NOT THE KEY
// ===========================================================================
// This is not "the cache is allowed to be slightly stale". `snap.d`'s section
// header states the invariant: the dragged set is applied at QUERY time
// (`kindExcluded`), an element is excluded iff ANY of its incident verts is
// moving, and so "moves with the drag" and "excluded" are the SAME predicate.
// A grid entry that the drag has made stale is an entry the query drops before
// the caller ever sees it. What the drag's own `Position` delivery invalidates
// is therefore exactly the set the query already refuses to return.
//
// ===========================================================================
// EVERY REFUSAL IN THE RIG
// ===========================================================================
//   * THE GRAB IS VERIFIED, NOT ASSUMED. A gesture that missed the +X arrow
//     plays 20 motion events, moves nothing and queries no snap — and would
//     read as a perfect `delta == 1` at the bottom. The drag is re-attempted
//     until the cage actually moved (`dragXAndCountBuilds`), exactly as
//     `test_bus_delivery_granularity.d` does for the same reason.
//   * `delta == 1` IS ALSO THE ANTI-VACUITY GUARD. Snap OFF, or a tool that
//     never reaches `snapCursor`, reads 0 here, not 1 — so the same equality
//     that catches the per-step rebuild catches a rig that engaged no snap at
//     all. Both sides are named in the message.
//   * MODEST SNAP RANGES. The neighbouring `test_snap_during_drag.d` uses
//     999999, which makes the whole screen one cell. That does not affect a
//     BUILD COUNT, but it does make every other snap fact in the file
//     meaningless, so the shipped 24/40 defaults are used instead.
//   * THE DRAG IS WHOLE-MESH (no selection), which is what four of the five
//     regressed perf cases are. Every candidate is then excluded, which is
//     precisely the case where a per-step rebuild is provably pure waste.
//   * WHICH ONE BUILD THE `1` IS. The first snap query of the gesture, at the
//     first motion event — `arm()`'s `/api/reset` published a real geometry
//     change, so the gesture opens on a stale grid and rebuilds once. The
//     other 19 steps reuse it. A `1` therefore says "rebuilt at the start and
//     not again", which is exactly the claim.
//
// Run via: ./run_test.d test_snap_grid_drag_rate

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
                      buildDragLog, playAndWait, projectToWindow,
                      DHVec3 = Vec3;

void main() {}

alias BASE = testBaseUrl;

/// The shipped SnapStage defaults (`toolpipe/packets.d :: SnapPacket`).
enum double kInnerRangePx = 24.0;
enum double kOuterRangePx = 40.0;


void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

void settle() { Thread.sleep(250.msecs); }

/// The always-on rate counter, monotone and never reset — read as a DELTA.
long gridBuilds() {
    return getJson("/api/cache/rebuilds")["snapGridBuilds"].integer;
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

/// The live gizmo pivot — the point `axisGrabPx` needs to find the +X arm.
DHVec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return DHVec3(cast(float)c[0].floating, cast(float)c[1].floating,
                  cast(float)c[2].floating);
}

/// reset → camera → snap at the shipped ranges → `move` armed.
void arm() {
    postJson("/api/command", commandBody("scene.reset"));
    auto camR = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":0.6,"distance":6.0,`
      ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert("error" !in camR, "/api/camera failed: " ~ camR.toString);

    auto r = post(BASE ~ "/api/script",
        "tool.pipe.attr snap enabled true\n"
      ~ "tool.pipe.attr snap types vertex\n"
      ~ format("tool.pipe.attr snap innerRange %g\n", kInnerRangePx)
      ~ format("tool.pipe.attr snap outerRange %g\n", kOuterRangePx));
    assert(parseJSON(cast(string)r)["status"].str == "ok",
        "snap config failed: " ~ cast(string)r);
    cmd("tool.set move");
    settle();
}

/// One +X move-arrow gesture of exactly `steps` motion events, with the grab
/// VERIFIED. Returns the `snapGridBuilds` delta across the gesture that
/// actually moved the cage.
long dragXAndCountBuilds(int steps, double dragPx = 70.0) {
    foreach (attempt; 0 .. 6) {
        settle();
        auto cam = fetchCamera(BASE);
        auto vp  = viewportFromCamera(cam);
        int gx, gy;
        double ux, uy;
        axisGrabPx(evalPivot(), vp, gx, gy, ux, uy);

        const auto before = vert0();
        const long b0 = gridBuilds();
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 gx, gy,
                                 gx + cast(int)(dragPx * ux),
                                 gy + cast(int)(dragPx * uy),
                                 steps), BASE);
        settle();
        const long delta = gridBuilds() - b0;
        if (dist2(before, vert0()) > 1e-4) return delta;
    }
    assert(false, "the move-arrow grab never landed — every attempt left the "
                ~ "cage where it was, so no build count below would be "
                ~ "measuring a drag with snap engaged");
}

/// One `/api/snap` query with the cursor parked on vertex 0's own pixel and
/// `excludeVerts` set to `excludeJson`; returns the `snapGridBuilds` delta.
///
/// The camera, the cursor, the ranges and the mesh are read BEFORE the counter
/// is sampled, so nothing inside the measured window but the query itself can
/// touch the grid. Two consecutive calls therefore differ in exactly one thing:
/// the exclusion set.
long snapProbe(string excludeJson) {
    auto vs  = getJson("/api/model")["vertices"].array[0].array;
    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    float px, py;
    assert(projectToWindow(DHVec3(cast(float)vs[0].floating,
                                  cast(float)vs[1].floating,
                                  cast(float)vs[2].floating), vp, px, py),
        "rig: vertex 0 does not project on-screen");

    const long b0 = gridBuilds();
    auto sr = postJson("/api/snap",
        format(`{"cursor":[%.6f,%.6f,%.6f],"sx":%d,"sy":%d,"excludeVerts":%s}`,
               vs[0].floating, vs[1].floating, vs[2].floating,
               cast(int)px, cast(int)py, excludeJson));
    assert("error" !in sr, "/api/snap failed: " ~ sr.toString);
    return gridBuilds() - b0;
}

// ---------------------------------------------------------------------------
// (1) A 20-step gizmo drag with vertex snap ON builds the candidate grid
//     EXACTLY ONCE.
// ---------------------------------------------------------------------------
unittest {
    arm();

    enum int kSteps = 20;
    const long delta = dragXAndCountBuilds(kSteps);

    writefln("[snap grid rate] %d-step drag rebuilt the candidate grid %d time(s)",
             kSteps, delta);

    assert(delta == 1,
        format("a %d-step gizmo drag with snap ON must build the snap "
             ~ "candidate grid ONCE, and it built it %d time(s).\n"
             ~ "  %d (or %d) means the grid's mesh term is advancing on the "
             ~ "drag's OWN per-step `Position` delivery. That delivery's "
             ~ "changed set IS the set `kindExcluded` drops at query time "
             ~ "(snap.d, 'EXCLUDE IS QUERY-TIME, NOT KEY'), so every one of "
             ~ "those rebuilds is pure waste: same candidates, same winner, "
             ~ "one O(elements) projection pass and ~2.4 MB per step.\n"
             ~ "  0 means the opposite failure — this rig engaged no snap at "
             ~ "all (snap off, or the drag never reached `snapCursor`), so "
             ~ "nothing below would be measuring the grid.",
               kSteps, delta, kSteps, kSteps + 1));
}

// ---------------------------------------------------------------------------
// (2) THE COMMITTED GESTURE RE-ARMS IT — a query that excludes NOTHING gets a
//     REBUILT grid, not the one the gesture was holding.
//
//     Holding one grid across a whole drag is sound for exactly one reason:
//     every element the drag moved is an element that query DROPS. A query
//     with a different exclusion set has no such cover, so it must not be
//     served from those buckets. `/api/snap` with an empty `excludeVerts` is
//     that query, and this block asserts it costs a rebuild.
//
//     THIS BLOCK IS ALSO RED ON THE PRE-FIX TREE, at 0, and for a DIFFERENT
//     reason than block (1) — say so rather than let a single red stand for
//     both. Pre-fix the grid was rebuilt at drag step 20, so it already held
//     the final positions and this probe correctly reused it; the 0 is
//     harmless there. Post-fix a 0 would mean a grid built at drag step 1 is
//     answering a query with no exclusion to hide the moved vertices behind.
//     Because D aborts a module at its first failing assert, measuring the two
//     reds separately means wrapping block (1) in D's nesting comment
//     `/+ ... +/` for that run.
//
//     WHAT IT DOES **NOT** SEPARATE, stated because the round-1 review found
//     the card claiming otherwise and the claim was wrong. On the SHIPPED tree
//     the rebuild this block demands is demanded by TWO guards at once — the
//     mesh key (`TransformTool.recordCommit`'s unconfined `Position` advanced
//     `g_settledGeomEpochs` before the probe runs) and the exclusion term —
//     so deleting either one alone leaves it green. Measured 2026-08-26:
//     with `|| g.excludeGen != excludeGen` removed from `snap.d` this block
//     still reads 1 and the whole file still passes; with
//     `recordCommit`'s publish removed it also still reads 1. It goes red only
//     when BOTH are gone. That is a fine belt-and-braces assertion of the seam
//     and a poor witness for either half, which is why block (3) below exists:
//     it holds the mesh key FIXED, so the exclusion term is the only guard
//     that can produce its rebuild.
//
//     What this block does NOT assert is that the rebuild produces the right
//     ANSWER — that is `tests/test_bus_snap_grid_after_drag.d`, which parks
//     the cursor on the moved vertex's new pixel and demands the query elect
//     it. The two are complementary: this one would stay green if the rebuild
//     computed garbage; that one would stay green if the rebuild happened 20
//     times.
// ---------------------------------------------------------------------------
unittest {
    // Self-contained: its own arm + its own committed gesture, so block (1)
    // can be commented out for an isolated red without taking this with it.
    arm();
    cast(void)dragXAndCountBuilds(20);

    const long delta = snapProbe("[]");

    writefln("[snap grid rate] post-commit probe with an empty exclude "
           ~ "rebuilt the grid %d time(s)", delta);
    assert(delta == 1,
        format("after the gesture committed, a snap query that excludes "
             ~ "NOTHING must rebuild the candidate grid — it got %d "
             ~ "rebuild(s). A 0 is the whole hazard of holding a grid across "
             ~ "a drag: the buckets describe where the moved vertices USED to "
             ~ "be, and this query has no exclusion to hide them behind. "
             ~ "(The value-level pin of the same seam is "
             ~ "tests/test_bus_snap_grid_after_drag.d.)", delta));

    cmd("tool.set move off");
}

// ---------------------------------------------------------------------------
// (3) THE EXCLUSION SET IS A KEY TERM — the block that is red on THAT term
//     alone.
//
//     Task 2000 lets one grid survive a whole gesture for one reason: every
//     element the gesture's `Position` deliveries moved is an element the
//     query DROPS (`kindExcluded`, snap.d's 'EXCLUDE IS QUERY-TIME, NOT KEY').
//     That cover is good for the set the query actually excludes and for no
//     other set, so the set itself has to be in the key
//     (`noteSlotExclusion`). Nothing else in this file can see that term:
//     block (1) never changes the exclusion, and block (2) always has an
//     advanced mesh epoch standing behind it.
//
//     THE RIG IS THE ONE WITH NO GEOMETRY CHANGE IN IT AT ALL. Four queries at
//     the same cursor, the same camera and the same ranges, over a mesh
//     nothing touches between them. `g_settledGeomEpochs` therefore cannot
//     move, `elemCount`, `cellPx` and the viewport cannot move, and the ONLY
//     key term left that can produce a rebuild is `excludeGen`.
//
//     THE PATTERN IS 0, 1, 0 AND ALL THREE READINGS CARRY WEIGHT:
//       * the REPEAT reading 0 is the premise — it says a grid is being HELD
//         across queries at all. Without it, a tree that rebuilt on every
//         single query would satisfy the 1 below for entirely the wrong
//         reason;
//       * the FLIP reading 1 is the term under test;
//       * the repeat AFTER the flip reading 0 says the rebuild re-STAMPED the
//         new generation instead of rebuilding from here to the end of time —
//         a distinction the `1` alone cannot make.
//     The warm-up build is asserted before any of them, so a rig that never
//     reached `queryCandidateGrid` reddens as itself rather than passing three
//     zeroes off as three cache hits.
//
//     THE MUTATION IT ANSWERS TO: delete `|| g.excludeGen != excludeGen` from
//     `snap.queryCandidateGrid` and this block reads 0 at the flip while every
//     other block in the suite stays green.
// ---------------------------------------------------------------------------
unittest {
    arm();

    const long warm = snapProbe("[]");
    assert(warm >= 1, format(
        "rig: the first snap query after /api/reset must BUILD the candidate "
      ~ "grid, and it built it %d time(s). A 0 means this block never reached "
      ~ "`queryCandidateGrid` — snap off, no tool armed, or vertex 0 outside "
      ~ "the projected domain — and the three deltas below would all read 0 "
      ~ "for a reason that has nothing to do with the cache key.", warm));

    const long hit    = snapProbe("[]");
    const long flip   = snapProbe("[0]");
    const long reheld = snapProbe("[0]");

    writefln("[snap grid rate] same-exclusion repeat %d, exclusion FLIP %d, "
           ~ "repeat after the flip %d", hit, flip, reheld);

    assert(hit == 0, format(
        "PREMISE: two IDENTICAL snap queries with no geometry change between "
      ~ "them must share one grid — this pair rebuilt it %d time(s). If this "
      ~ "is not 0 then no grid is being held across queries here, and the "
      ~ "flip assertion below would be green on a tree that rebuilds "
      ~ "unconditionally.", hit));

    assert(flip == 1, format(
        "a snap query differing from the one before it ONLY in `excludeVerts` "
      ~ "must rebuild the candidate grid — it rebuilt %d time(s).\n"
      ~ "  Nothing else could have caused a rebuild: no geometry changed, so "
      ~ "`g_settledGeomEpochs` did not move, and the cursor, camera, ranges "
      ~ "and element count are identical to the query before. The exclusion "
      ~ "generation is the only term left.\n"
      ~ "  A 0 is the hazard the term exists to close. A grid may be held "
      ~ "across a live gesture ONLY because every element that gesture moved "
      ~ "is one this query drops; a query that drops a DIFFERENT set has no "
      ~ "such cover, and serving it from those buckets answers with where a "
      ~ "vertex used to be.", flip));

    assert(reheld == 0, format(
        "after the flip rebuilt it, a repeat of the SAME query must be a hit "
      ~ "— it rebuilt %d time(s). A 1 means the rebuild never stamped the new "
      ~ "exclusion generation, so the term would cost one build per QUERY "
      ~ "rather than one per change of set — which is the regression this "
      ~ "whole file exists to catch, wearing different clothes.", reheld));

    cmd("tool.set move off");
}
