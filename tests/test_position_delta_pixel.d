// Task 1903 §L0-d — W4b: the FAST-PATH display-refresh probe, in pixels.
//
// ===========================================================================
// WHY THIS FILE EXISTS AT ALL
// ===========================================================================
// L0-P1 carved a fast path into `MeshEditDelta.revert`: a log whose every entry
// is index-space stable skips `rebuildEdges` + `buildLoops`, skips the corner
// carry, and takes a per-kind decision on the topology bump and on which
// display class to republish. It shipped with NO PRODUCTION CALLER — every
// migrated command still recorded a face-moving kind — so its display-refresh
// claim had no witness. L0-d's nine position commands are the first logs that
// take it, and this file is that witness.
//
// AND THE COUNTERS CANNOT BE IT — MEASURED, and more completely than the plan
// expected. A missed invalidation RE-SERVES THE SAME SLOT:
//   * `/api/frames/counts` — identical draw calls;
//   * `/api/model` — identical, the CAGE always follows an undo;
//   * the delivery count — identical, 1 `Position` per undo (CLAUDE.md's law);
//   * `mutationVersion` / `topologyVersion` — identical, `+1 / +0`, which is
//     EXACTLY what the hand-rolled revert this stage replaced also produced.
//   * `/api/subpatch/preview`'s `topologiesCreated` and `builds`, and
//     `/api/changes`'s `totalPolygons` / `totalPosition` / `totalMarks` —
//     identical, measured, with the carve-out defeated (see block 1's header
//     for the five numbers).
// So no counter on the wire distinguishes a correct fast-path undo from one
// whose republish never reached the uploader.
//
// AND NEITHER, IT TURNS OUT, DOES THIS FILE'S OWN PIXEL BLOCK — see block 2's
// header for the gate that was run and what it returned. The honest statement
// is recorded in doc/behavior_gap_registry.md rather than dressed up here.
//
// ===========================================================================
// THE RIG, AND EVERY REFUSAL IN IT — inherited verbatim from
// tests/test_bus_position_pixel.d:70-118, which is the authority for each
// ===========================================================================
//   * NOT A CUBE. On a closed solid a stale limit surface hides behind the
//     front half everywhere a probe could land, so "did not update" and "not
//     visible" read identically. This is an OPEN 4x4 grid patch in the XY
//     plane: 25 verts, 16 quads, a real boundary, nothing behind anything.
//   * SUBPATCH ON EVERY FACE, and `assertPreviewActive` as an ALWAYS-ON
//     PREMISE. The thing probed is the LIMIT SURFACE. With no preview the
//     framebuffer shows the CAGE, which follows an undo by construction — so
//     without this premise a mutation aimed at the preview channel changes the
//     SUBJECT instead of breaking the claim. Measured in that file: with
//     `rebuildIfStale`'s gate forced false, both arms went green over the cage.
//   * `P` IS READ OUT OF THE VBO, NOT PREDICTED — a triangle centroid, so it
//     cannot land on an edge or a vertex dot, with |y| > 0.3 so its pixel
//     clears the ground grid's horizon line.
//   * THE SILHOUETTES ARE DISJOINT. `mesh.magnet` with target (6,0,0),
//     strength 0.5 and dist 100 puts the Element/Smooth weight at ~1
//     everywhere (the radius is two orders above the patch extent), so every
//     vertex maps `v -> v + 0.5*(target - v)`: the patch halves and moves to
//     x ~ 3. Pre-op x in [-1,1], post-op x in [2.5,3.5]. "Arrived" is then a
//     real claim rather than "it was always there", and the cage stays
//     non-degenerate — a collapse-to-a-point op would leave the OSD stencil
//     table with a degenerate cage and `surface()`'s length floor would be
//     measuring the rig's own failure.
//   * `kDiffer` / `kMatch` ARE LIFTED VERBATIM together with the PREMISE
//     assert that justifies them. They are fixed numbers with a 2x margin on
//     the measured 18-vs-0 separation, not derived from the reading they judge.
//
// ===========================================================================
// TWO BLOCKS, AND WHY THEY ARE TWO
// ===========================================================================
// druntime stops a module at its first failed assert, so block 1's red would
// hide block 2's silence. Block 1 is the COUNTER tier (`topologiesCreated`,
// the one wire counter that separates fast from slow); block 2 is the PIXEL
// tier (the display-refresh claim, which nothing else can see).
import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv    : to;
import std.format  : format;
import std.math    : fabs, round, abs;
import std.stdio   : writefln;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow,
                      DHVec3 = Vec3;

void main() {}

alias BASE = testBaseUrl;


void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}
/// A state change is visible only once a frame has RENDERED with it, and a
/// probe reads the last COMPLETED frame — so this has to cover two.
void settle() { Thread.sleep(450.msecs); }

struct Px {
    int r, g, b, a;
    bool valid;
    string toString() const {
        return valid ? format("(%d, %d, %d, a=%d)", r, g, b, a) : "<unreadable>";
    }
}

Px probe1(int x, int y) {
    auto j = getJson(format("/api/viewport/probe?cell=0&points=%d,%d", x, y));
    assert("error" !in j, "probe failed: " ~ j.toString);
    // The `--test` single-rendered-cell trap: a never-filled FBO reads zeros,
    // and "the surface is absent" would then pass for the wrong reason.
    assert(j["renders"].type == JSONType.true_,
        "the probed cell is not rendered under --test; every reading in this "
      ~ "file would be void");
    auto e = j["points"].array[0];
    assert("error" !in e, format("pixel (%d, %d) could not be read: %s",
                                 x, y, e.toString));
    return Px(cast(int)e["r"].integer, cast(int)e["g"].integer,
              cast(int)e["b"].integer, cast(int)e["a"].integer, true);
}

int rgbDist(Px a, Px b) {
    return cast(int)(abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b));
}

enum int kDiffer = 9;   // "these two pixels show different things"
enum int kMatch  = 4;   // "these two pixels show the same thing"

/// The patch sits at y in [1, 3], NOT centred on the origin, and that is a
/// refusal rather than a detail: the ground grid's plane is y = 0 and the
/// camera is frontal, so that plane projects to a horizontal LINE across the
/// middle of the cell. `test_bus_position_pixel.d` dodges it by picking a probe
/// point with |y| > 0.3 — which works while the patch spans y in [-1, 1], but
/// this file's op SHRINKS the patch 2x, and after the shrink the only rows that
/// clear the horizon are its outermost ones. Measured: the probe then landed on
/// a CORNER triangle of the limit surface, a few pixels from the subpatch cage's
/// own corner, and read (184,184,184) — the cage wire, not the surface. Lifting
/// the whole patch clears the horizon by construction and lets the probe sit in
/// the INTERIOR, where a filled surface is several pixels wide in every
/// direction.
enum double kPatchY0 = 1.0;
enum double kPatchY1 = 3.0;

void loadOpenPatch() {
    enum int N = 4;
    string verts = "[";
    foreach (j; 0 .. N + 1)
        foreach (i; 0 .. N + 1) {
            if (i || j) verts ~= ",";
            verts ~= format("[%.6f,%.6f,0.0]",
                            -1.0 + 2.0 * i / N,
                            kPatchY0 + (kPatchY1 - kPatchY0) * j / N);
        }
    verts ~= "]";
    string faces = "[";
    foreach (j; 0 .. N)
        foreach (i; 0 .. N) {
            if (i || j) faces ~= ",";
            const int a = j * (N + 1) + i;
            faces ~= format("[%d,%d,%d,%d]", a, a + 1, a + N + 2, a + N + 1);
        }
    faces ~= "]";
    auto j = postJson("/api/command", commandBody("scene.loadMesh", format(`{"vertices":%s,"faces":%s}`, verts, faces)));
    assert(j["status"].str == "ok", "load-mesh failed: " ~ j.toString);
}

/// Frontal camera. Set AFTER the mesh load, which RESETS the camera. The
/// distance sets world-units-per-pixel and must be large enough that the
/// post-op patch at x ~ 3.5 still fits on the cell.
void frontalCamera(double distance) {
    post(BASE ~ "/api/camera?viewport=0",
         format(`{"azimuth":0.0,"elevation":0.0,"distance":%.3f}`, distance));
    settle();
    auto c = fetchCamera(BASE);
    assert(c.eye.z > 1.0f && fabs(c.eye.x) < 0.01f && fabs(c.eye.y) < 0.01f,
        format("rig: the camera must sit on +z looking at the origin. It is "
             ~ "at (%g, %g, %g), and the patch would not be facing it",
               c.eye.x, c.eye.y, c.eye.z));
}

void waitPreviewSettled(int timeoutMs = 30_000) {
    foreach (_; 0 .. timeoutMs / 20) {
        auto j = getJson("/api/subpatch/preview");
        if (j["pending"].type != JSONType.true_) { Thread.sleep(120.msecs); return; }
        Thread.sleep(20.msecs);
    }
    assert(false, "subpatch preview build did not settle");
}

void assertPreviewActive(string where) {
    auto j = getJson("/api/subpatch/preview");
    assert(j["active"].type == JSONType.true_,
        format("%s PREMISE: the subpatch preview must be ACTIVE — the thing "
             ~ "this file probes is the LIMIT SURFACE, and with no preview the "
             ~ "framebuffer shows the CAGE, which follows any undo by "
             ~ "construction. `/api/subpatch/preview` says %s",
               where, j.toString));
}

long topologiesCreated() {
    return getJson("/api/subpatch/preview")["topologiesCreated"].integer;
}

void enableSubpatchOnEveryFace() {
    cmd("select.typeFrom polygon");
    postJson("/api/command", `{"id":"mesh.subpatch_toggle"}`);
    waitPreviewSettled();
    cmd("select.typeFrom vertex");
    settle();
    assertPreviewActive("rig setup:");
}

struct Surface {
    DHVec3[] pos;
    double   xMin = 1e30, xMax = -1e30;
}

Surface surface() {
    auto j = getJson("/api/gpu/face-vbo");
    Surface s;
    foreach (p; j["positions"].array) {
        auto a = p.array;
        auto v = DHVec3(cast(float)a[0].floating, cast(float)a[1].floating,
                        cast(float)a[2].floating);
        s.pos ~= v;
        if (v.x < s.xMin) s.xMin = v.x;
        if (v.x > s.xMax) s.xMax = v.x;
    }
    assert(s.pos.length >= 3, "the face VBO is empty — nothing is drawn");
    return s;
}

/// A point definitely ON the rendered surface, in its INTERIOR, and on a
/// FILLED patch of it — returned together with the pixel it projects to.
///
/// THREE THINGS HAD TO BE MEASURED HERE, each of which broke a simpler rule:
///
///  1. "the first triangle that clears the horizon" (the rule
///     `test_bus_position_pixel.d` uses) picks a CORNER triangle, which sits a
///     few pixels from the subpatch cage's corner wire. Measured: (184,184,184),
///     the wire, against the surface's (105,105,105).
///  2. "the triangle closest to the bounding-box centre" picks the middle of
///     the patch — which is exactly where the cage's CENTRE wire runs. Measured:
///     the same (184,184,184), with (107,107,107) three pixels away.
///  3. so the rule is: order candidates by distance to a point offset an EIGHTH
///     of the extent from the centre (midway between two cage wires, since the
///     4x4 cage puts them a quarter apart), and take the first whose five-point
///     plus-shape is uniform.
///
/// THE SEARCH IS FOR A PROBE LOCATION, NOT FOR A GREEN. What it looks for is
/// "a filled region of the drawn surface"; the CLAIM is then evaluated at that
/// fixed pixel, and a location that satisfies the search says nothing about
/// whether the claim holds. If no candidate is filled the cell aborts naming
/// the readings, rather than widening until something passes.
struct ProbePoint { DHVec3 world; int[2] px; Px colour; }

ProbePoint surfaceProbe(const ref Surface s, string what) {
    import std.algorithm : sort;
    double yMin = 1e30, yMax = -1e30;
    foreach (ref v; s.pos) {
        if (v.y < yMin) yMin = v.y;
        if (v.y > yMax) yMax = v.y;
    }
    const double w = s.xMax - s.xMin, h = yMax - yMin;
    const double tx = (s.xMin + s.xMax) * 0.5 + w / 8.0;
    const double ty = (yMin + yMax)     * 0.5 + h / 8.0;

    struct Cand { double d; DHVec3 p; }
    Cand[] cands;
    for (size_t i = 0; i + 2 < s.pos.length; i += 3) {
        const double cx = (s.pos[i].x + s.pos[i+1].x + s.pos[i+2].x) / 3.0;
        const double cy = (s.pos[i].y + s.pos[i+1].y + s.pos[i+2].y) / 3.0;
        const double cz = (s.pos[i].z + s.pos[i+1].z + s.pos[i+2].z) / 3.0;
        cands ~= Cand((cx - tx) * (cx - tx) + (cy - ty) * (cy - ty),
                      DHVec3(cast(float)cx, cast(float)cy, cast(float)cz));
    }
    assert(cands.length >= 1, "the face VBO holds no complete triangle");
    sort!((a, b) => a.d < b.d)(cands);

    string[] rejected;
    foreach (c; cands[0 .. cands.length > 16 ? 16 : cands.length]) {
        // The horizon premise, asserted rather than assumed: the ground grid's
        // plane is y = 0 and it projects to a horizontal line through the cell.
        // The patch is loaded at y in [kPatchY0, kPatchY1] so this cannot fire;
        // it is here because the op could in principle move it.
        assert(c.p.y > 0.5,
            format("RIG FAILURE: a %s candidate is at y = %g, close enough to "
                 ~ "the ground grid's y = 0 plane that its pixel may be the "
                 ~ "horizon line rather than the surface.", what, c.p.y));
        const auto px = fbo(c.p, what);
        Px centre = probe1(px[0], px[1]);
        bool uniform = true;
        Px bad;
        static immutable int[2][4] arms = [[-3, 0], [3, 0], [0, -3], [0, 3]];
        foreach (a; arms) {
            const Px n = probe1(px[0] + a[0], px[1] + a[1]);
            if (rgbDist(n, centre) > kMatch) { uniform = false; bad = n; break; }
        }
        if (uniform) return ProbePoint(c.p, px, centre);
        rejected ~= format("(%g, %g) px (%d, %d) centre %s vs neighbour %s",
                           c.p.x, c.p.y, px[0], px[1], centre.toString,
                           bad.toString);
    }
    assert(false,
        format("RIG FAILURE: none of the 16 candidate points for %s lands on a "
             ~ "FILLED region of the drawn surface — every one has a neighbour "
             ~ "3 px away showing something else, i.e. a cage wire, a vertex "
             ~ "dot or the ground grid. A single pixel cannot tell a filled "
             ~ "surface from a one-pixel feature, and this file's whole "
             ~ "subject is whether a SURFACE is drawn. Rejected: %s",
               what, rejected));
}

/// World point -> FBO pixel, through the LIVE camera. No probe in this file is
/// a magic number.
///
/// `what` names the point so a clipped one reddens as a RIG failure rather
/// than wearing the costume of a claim failure: the post-op surface reaches
/// x ~ 3.5 off-axis, and a point outside the cell would make the probe read
/// whatever the clamp landed on.
int[2] fbo(DHVec3 world, string what) {
    auto camS = fetchCamera(BASE);
    auto vp   = viewportFromCamera(camS);
    float px, py;
    assert(projectToWindow(world, vp, px, py),
        format("RIG FAILURE: %s at (%g, %g, %g) is behind the camera",
               what, world.x, world.y, world.z));
    const int x = cast(int)round(px) - camS.vpX;
    const int y = cast(int)round(py) - camS.vpY;
    assert(x >= 4 && y >= 4 && x < camS.width - 4 && y < camS.height - 4,
        format("RIG FAILURE (not a claim failure): %s at (%g, %g, %g) projects "
             ~ "to cell pixel (%d, %d), which is outside or within 4 px of the "
             ~ "edge of the %dx%d cell. The camera distance is too small for "
             ~ "this displacement — widen it; do not weaken an assert below.",
               what, world.x, world.y, world.z, x, y, camS.width, camS.height));
    return [x, y];
}

/// The op under test, and the whole reason this file drives a COMMAND rather
/// than a gizmo: `mesh.magnet` records a `Kind.SetPos`-only op-log, so its
/// UNDO is the first production log to take L0-P1's fast path.
/// Wait until the GPU face VBO's x-extent has actually MOVED away from
/// `fromXMax`, bounded, and say so loudly if it never does.
///
/// `waitPreviewSettled` is necessary and NOT sufficient: it returns the moment
/// `pending` is false, and immediately after a command that is also true
/// BEFORE the rebuild has been scheduled — so a probe can land on a buffer the
/// uploader is midway through. Measured on this tree: with `waitPreviewSettled`
/// + one `settle()` alone, the post-magnet readback came back with every
/// position x == 0 while the same sequence driven by hand (a slower client) read
/// [2.498, 3.499]. That is a RIG race, not a claim failure, and it is treated
/// as one here.
///
/// THIS IS THE FORWARD ONLY. The post-UNDO readings are NOT polled — the undo's
/// display refresh IS the claim, and polling on it would turn a real staleness
/// into a rig timeout.
void waitForwardLanded(double fromXMax) {
    foreach (_; 0 .. 100) {
        auto s = surface();
        if (s.xMin > fromXMax + 0.25) return;
        Thread.sleep(100.msecs);
    }
    auto s = surface();
    assert(false,
        format("RIG FAILURE: 10 s after the magnet the GPU face VBO still "
             ~ "reads x in [%.3f, %.3f]; the pre-op surface ended at %.3f and "
             ~ "the displaced one must start well past it. Either the forward "
             ~ "never landed on the GPU, or the readback is racing the "
             ~ "uploader. This is the RIG settling, not the claim — the claim "
             ~ "is about the UNDO and its readings are not polled.",
               s.xMin, s.xMax, fromXMax));
}

void runMagnet() {
    // ARGS ARE TOP-LEVEL on `/api/command`, not nested under an `args` object.
    // Measured on this tree: the nested form is accepted with `status:ok` and
    // every param silently left at its DEFAULT — for magnet that is
    // `dist = 1.0`, `target = (0,0,0)`, which moves the patch's interior and
    // leaves its corners (at radius sqrt(2) > 1) where they were, so the
    // silhouette does not move and this file's disjointness premise reddens as
    // a rig failure. It did, first run.
    // `center`/`target` share the patch's own y, so the op is a pure x
    // displacement plus a 2x shrink AROUND that height: y in [1,3] -> [1.5,2.5],
    // x in [-1,1] -> [2.5,3.5]. Both post-op extents stay clear of the ground
    // grid's y = 0 plane.
    cmd(`{"id":"mesh.magnet","target":[6,2,0],"strength":0.5,`
      ~ `"dist":100,"center":[0,2,0]}`);
    waitPreviewSettled();
    settle();
}

void undo() {
    cmd(`{"id":"history.undo"}`);
    waitPreviewSettled();
    settle();
}

// ===========================================================================
// BLOCK 1 — A REGRESSION PIN, **NOT** A WITNESS. READ THIS BEFORE QUOTING IT.
//
// The plan (task 1903 §L0-d §5) called this "the only suite-tier proof the fast
// path executed", on P0-1 phase 2b's finding that a `topologyVersion` bump
// denies `rebuildIfStale` its position-only path and grows `topologiesCreated`.
//
// MEASURED HERE, AND THE CLAIM DOES NOT HOLD FOR THIS CELL. With the carve-out
// defeated (`fast = false` at `MeshEditDelta.revert`'s call site, so the undo
// takes the full `finalize`), every wire channel across the undo is
// BYTE-IDENTICAL to the carve-out-present run:
//
//     topologiesCreated  1 -> 1      (delta 0 in BOTH)
//     builds             1 -> 2      (delta 1 in BOTH)
//     totalPolygons      9 -> 10     (delta 1 in BOTH)
//     totalPosition      4 -> 6      (delta 2 in BOTH)
//     totalMarks         4 -> 4      (delta 0 in BOTH)
//
// The reason is that the cage TOPOLOGY does not change across a position undo,
// so `rebuildIfStale` reuses the OSD topology object it already holds whichever
// finalize ran; the counter counts topologies CREATED, not stencil work.
//
// SO THIS BLOCK PINS A NUMBER, NOT A MECHANISM. It is kept because the number
// is cheap and a future change that starts recreating an OSD topology on every
// position undo is worth catching. It is NOT evidence that the fast path ran.
// The witness for that is UNIT tier and it is potent: `g_rebuildEdgesRuns` 0
// vs 1, `g_buildLoopsRuns` 0 vs 1 and `g_hideDeriveRuns` 1 vs 2 in
// tests/unit/commands/mesh/position_delta_test.d, all three observed red under
// this same mutation.
// ===========================================================================
unittest {
    postJson("/api/command", commandBody("scene.reset"));
    loadOpenPatch();
    frontalCamera(13.0);
    enableSubpatchOnEveryFace();

    const double preXMax = surface().xMax;
    runMagnet();
    assertPreviewActive("after the magnet:");
    waitForwardLanded(preXMax);

    const long t0 = topologiesCreated();
    undo();
    assertPreviewActive("after the undo:");
    const long t1 = topologiesCreated();

    writefln("[L0-d W4b] block 1: topologiesCreated %d -> %d across the undo",
             t0, t1);

    // Non-vacuity: the counter must have moved AT ALL by this point, or a
    // delta of 0 across the undo says nothing about the undo.
    assert(t0 >= 1,
        format("RIG FAILURE: `topologiesCreated` is %d before the undo, so no "
             ~ "OSD stencil table was ever built and a delta of 0 across the "
             ~ "undo would be the counter standing still for the wrong reason. "
             ~ "The subpatch preview never became active, or never rebuilt for "
             ~ "the magnet.", t0));

    assert(t1 - t0 == 0,
        format("a position undo with a live subpatch preview recreated an OSD "
             ~ "topology (`topologiesCreated` %d -> %d, delta %d). The cage "
             ~ "topology does not change across a position undo, so the "
             ~ "existing topology object must be reused.\n"
             ~ "  THIS IS A REGRESSION PIN, NOT A WITNESS — see the block "
             ~ "header. Measured on this tree: this delta is 0 with the "
             ~ "carve-out present AND with it defeated, so a green here says "
             ~ "NOTHING about whether the fast path ran. The potent check for "
             ~ "that is the unit-tier derive/rebuild counter row in "
             ~ "tests/unit/commands/mesh/position_delta_test.d.",
               t0, t1, t1 - t0));
}

// ===========================================================================
// BLOCK 2 — THE PIXEL TIER. The limit surface on screen after the undo is the
// PRE-OP one.
//
// SIX READINGS, and each one is here because a named half-failure passes
// without it:
//
//   B0  background on P's screen row, pre-op   PREMISE — without it every
//                                              assert below compares two
//                                              shades of background
//   S0  P, pre-op                              the reference
//   S1  P, post-op   != S0                     POTENCY — a preview that never
//                                              updated at all gives S1 == S0
//                                              and everything after is vacuous
//   T1  P2, post-op  == S0                     the surface ARRIVED
//   S2  P, post-undo == S0                     THE CLAIM
//   T2  P2, post-undo == B2                    the surface LEFT the post-op
//                                              place; a preview drawn twice
//                                              satisfies "arrived" and fails
//                                              this
//
// THE GATE WAS RUN, AND THIS IS WHAT IT RETURNED (task 1903 §L0-d, R2.4).
// Three mutations, M-inst first, each in isolation:
//
//   M-inst (as the plan specified) — `GpuMesh.refreshPositions` made a no-op on
//       a matching layout: GREEN, and MEASURED-INERT for a reason worth
//       recording. On this cell the CPU uploader never runs at all: the
//       preview's positions reach the GPU through the OSD GPU FAN-OUT
//       (`rebuildIfStale`'s position-only path, `refreshIntoFaceVbo`), and
//       `app.d`'s upload block takes its `lastRefreshSkipNonFace` no-op arm on
//       both the forward and the undo (instrumented and counted).
//   M-inst-2 (the corrected instrument control) — `rebuildIfStale`'s
//       position-only path stamps its key forward WITHOUT refreshing: RED. So
//       the probe CAN see a stale limit surface. It reddens at the rig-settle
//       guard rather than at the claim, because the mutation starves the
//       forward's refresh too.
//   M-pub-1 — the fast path publishes `MeshEditScope.Marks` alone: GREEN.
//   M-pub-2 — the fast path calls `noteChange(scope_)`: no stamp, no delivery:
//       GREEN, and `changeBus.missedPublishers` stayed 0 as well.
//
// SO THE DISPLAY-REFRESH CLAIM SHIPS UNWITNESSED, and that is written down
// rather than papered over. What the two green publisher mutations show is that
// `finalize`'s publish is NOT what carries a position undo to the limit surface
// on this cell — the preview's own `{mesh address, geometry epoch,
// mutationVersion, depth}` key is, and something on the undo path moves it
// regardless. WHAT moves it under M-pub-2 is not established here and is a
// named follow-up, not an answer. Recorded in doc/behavior_gap_registry.md.
//
// This block therefore stands as the frozen evidence of what a position undo
// must do to the limit surface — pinned in the one channel a version key, a
// draw-call census and a cage read all fail to see — and NOT as a live guard
// on the publish side.
// ===========================================================================
unittest {
    postJson("/api/command", commandBody("scene.reset"));
    loadOpenPatch();
    frontalCamera(13.0);
    enableSubpatchOnEveryFace();

    const auto pre = surface();
    const double patchWidth = pre.xMax - pre.xMin;
    assert(patchWidth > 0.5,
        format("RIG FAILURE: the pre-op limit surface is %g wide in x — too "
             ~ "small to be a patch", patchWidth));

    const auto pp   = surfaceProbe(pre, "P (pre-op surface point)");
    const auto P    = pp.world;
    const auto pxP  = pp.px;
    const Px   s0   = pp.colour;
    // Background of P's OWN SCREEN ROW: one and a half patch-widths to the
    // LEFT, where nothing is drawn before or after a +X displacement. Same row
    // matters — the background gradient is vertical.
    const auto pxB0 = fbo(DHVec3(cast(float)(P.x - patchWidth * 1.5), P.y, P.z),
                          "B0 (background on P's row)");
    const Px   b0   = probe1(pxB0[0], pxB0[1]);

    assert(rgbDist(s0, b0) >= kDiffer,
        format("PREMISE: the pre-op probe must land ON the limit surface — it "
             ~ "reads %s, and the background of the same screen row reads %s "
             ~ "(distance %d < %d). Too close to tell apart, so every assert "
             ~ "below would be comparing two shades of background. A theme or "
             ~ "lighting change reddens HERE, loudly, instead of quietly making "
             ~ "the cells undecidable.",
               s0.toString, b0.toString, rgbDist(s0, b0), kDiffer));

    runMagnet();
    assertPreviewActive("after the magnet:");
    waitForwardLanded(pre.xMax);

    const auto post = surface();
    assert(post.xMin > pre.xMax,
        format("RIG FAILURE: the pre-op silhouette is x in [%.3f, %.3f] and "
             ~ "the post-op one is x in [%.3f, %.3f]. They must be DISJOINT or "
             ~ "\"the surface arrived\" is satisfied by \"it was always "
             ~ "there\". Adjust the magnet target, not the asserts.",
               pre.xMin, pre.xMax, post.xMin, post.xMax));
    const auto pp2 = surfaceProbe(post, "P2 (post-op surface point)");
    const auto P2  = pp2.world;
    const auto pxP2 = pp2.px;
    const Px   t1   = pp2.colour;
    const double postWidth = post.xMax - post.xMin;

    const Px s1 = probe1(pxP[0], pxP[1]);
    assert(rgbDist(s1, s0) >= kDiffer,
        format("POTENCY: the limit surface did not LEAVE the pixel it covered "
             ~ "before the magnet — it reads %s, was %s. The preview never "
             ~ "updated at all, so every assert below is vacuous: S2 would "
             ~ "match S0 whatever the undo did.", s1.toString, s0.toString));

    // Background of P2's OWN screen row, probed post-op where the patch has
    // already moved: one and a half POST widths to the right of P2.
    const auto pxB2 = fbo(DHVec3(cast(float)(P2.x + postWidth * 1.5),
                                 P2.y, P2.z),
                          "B2 (background on P2's row)");
    const Px b2 = probe1(pxB2[0], pxB2[1]);

    // THE SURFACE ARRIVED — stated against the BACKGROUND OF ITS OWN ROW, not
    // against `S0`. A same-shade comparison across two different world
    // positions would assume the shading is position-invariant, which a
    // Blinn-Phong specular term does not promise; `surfaceProbe`'s uniformity check is what
    // makes "something is drawn here" mean a filled surface rather than a wire.
    assert(rgbDist(t1, b2) >= kDiffer,
        format("the limit surface is not at its NEW place — the pixel at the "
             ~ "displaced surface point reads %s, and the background of the "
             ~ "same screen row reads %s (distance %d < %d). It left and did "
             ~ "not arrive, which is a preview that stopped drawing rather "
             ~ "than one that followed.",
               t1.toString, b2.toString, rgbDist(t1, b2), kDiffer));

    undo();
    assertPreviewActive("after the undo:");

    const Px s2 = probe1(pxP[0], pxP[1]);
    const Px t2 = probe1(pxP2[0], pxP2[1]);

    writefln("[L0-d W4b] block 2: surface x pre=[%.3f, %.3f] post=[%.3f, %.3f]",
             pre.xMin, pre.xMax, post.xMin, post.xMax);
    writefln("[L0-d W4b] block 2: S0=%s B0=%s S1=%s T1=%s S2=%s T2=%s B2=%s",
             s0.toString, b0.toString, s1.toString, t1.toString,
             s2.toString, t2.toString, b2.toString);

    // THE CLAIM. Same pixel, same world point, so the shading is identical by
    // construction and the comparison is exact.
    assert(rgbDist(s2, s0) <= kMatch,
        format("THE FAST-PATH UNDO DID NOT REFRESH THE DISPLAY. The pixel that "
             ~ "showed the pre-op limit surface reads %s after the undo; it "
             ~ "read %s before the magnet (distance %d > %d).\n"
             ~ "  The CAGE is back — `/api/model` says so and cannot get it "
             ~ "wrong. What is on screen is the limit surface, and it is still "
             ~ "the POST-op one: `finalize`'s fast branch republished a class "
             ~ "outside `display_sync.DisplayRefreshMask`, or did not "
             ~ "republish at all, so the uploader never re-read the positions.\n"
             ~ "  No counter in the tree sees this: mutationVersion +1, "
             ~ "topologyVersion +0, one Position delivery, identical draw "
             ~ "calls and an identical `/api/model` — all of them exactly what "
             ~ "a CORRECT undo produces.",
               s2.toString, s0.toString, rgbDist(s2, s0), kMatch));

    // …and the surface LEFT the post-op place. A preview drawn TWICE satisfies
    // the claim above and fails this.
    assert(rgbDist(t2, b2) <= kMatch,
        format("the limit surface did not LEAVE its post-magnet place: the "
             ~ "pixel at P2 reads %s after the undo, and the background of the "
             ~ "same screen row reads %s (distance %d > %d). The pre-op "
             ~ "surface came back AND the post-op one is still drawn — two "
             ~ "surfaces on screen, which the claim assert above is green over.",
               t2.toString, b2.toString, rgbDist(t2, b2), kMatch));
}
