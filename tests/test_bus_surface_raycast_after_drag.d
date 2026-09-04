// Task 1906 stage 2b — THE FOURTH 0401-CLASS STALE CACHE, IN THE ONE CHANNEL
// THAT CAN SEE IT: the SURFACE BVH (`bvh_pick.d :: pickSurfaceRay`) after a
// VERSION-SILENT gizmo drag.
//
// ===========================================================================
// WHAT IS BROKEN, AND WHY NOTHING ELSE IN THE TREE NOTICED
// ===========================================================================
// `BvhPick`'s SURFACE tree is keyed on `(sourceMesh.mutationVersion,
// &sourceMesh)` and `invalidateSurface()` has exactly two callers, both inside
// `source/bvh_pick.d` (`~this` and the rebuild path itself). Nothing outside
// the module invalidates it. An interactive gizmo Move/Rotate/Scale is
// deliberately version-silent on Position — `mutationVersion` never bumps for
// a drag OR for its commit (CLAUDE.md, "The exception that breaks
// version-keying") — so after a drag every surface consumer
// (`/api/surface-raycast`, the CONS stage's background projection, the
// Topology Pen's placement seed) reads the PRE-DRAG tree, forever.
//
// Task 0401 listed "BVH (bvh_pick.d)" under OK. That was the FACE tree, which
// keys on `GpuMesh.uploadVersion` and IS re-stamped by the drag's re-upload.
// The SURFACE tree is a separate cache with a separate key, and it was missed.
//
// `tests/test_fixture_topology_pen_version_invalidation.d` is the sibling of
// this file and it cannot see the defect BY CONSTRUCTION — its own header says
// so in as many words: it drives the displacement through `/api/transform`
// "DELIBERATELY", because the gizmo is version-silent and that is "not
// something this test should also trip over". ARM B below is that same
// mechanism, kept here as the mandatory negative control.
//
// ===========================================================================
// THE RIG, AND EVERY REFUSAL IN IT
// ===========================================================================
// `/api/surface-raycast` raycasts BACKGROUND layers only (`ConstrainStage`
// walks `snap.backgroundSourcesFull()`), while a gizmo drag can only edit the
// PRIMARY layer. So the rig must move a mesh through the primary seat and put
// it back:
//
//   layer1 = a cube, BACKGROUND     -> raycast #1 BUILDS its surface BVH
//   layer1 promoted to PRIMARY      -> gizmo drag moves it (version-silent)
//   layer1 demoted to BACKGROUND    -> raycast #2 must see the NEW geometry
//
// Three properties of `ConstrainStage` decide whether that rig discriminates
// anything at all, and each one is a way this file could have been born inert:
//
//   * `reset()` calls `_bgBvh.clear()`, and `resetTransient()` calls `reset()`
//     on EVERY tool activation and every tool DROP (`app.d ::
//     resetTransientPipeStages`, three call sites). A cleared cache rebuilds
//     from scratch and the stale read disappears. The guard is `userLocked`,
//     which `resetTransient()` honours and which a `tool.pipe.attr constrain
//     enabled true` write sets at the COMMAND layer — so CONS is enabled ONCE,
//     up front, and never disabled again in this file. Do not "tidy" that into
//     an enable/disable pair around the drag: `enabled=false` CLEARS
//     `userLocked` (constrain.d's own comment says so) and the next tool
//     switch then wipes the cache this file exists to catch reading.
//   * `bgSurfaceRayHit` PRUNES `_bgBvh` of every address that is not currently
//     a background source — and during the drag layer1 is the primary, i.e.
//     exactly such an address. A single CONS evaluate with a live cursor
//     mid-drag would therefore delete the entry and hand raycast #2 a fresh
//     tree. `geometry vector` for the duration of the drag is what stops that
//     branch running (`evaluate` gates it on Point|Screen), and it does NOT
//     touch `userLocked`.
//   * `geometry screen|point` would ALSO run CONS's projection post-pass over
//     the dragged vertices (`xfrm_transform.d :: applyTRS`), i.e. the drag
//     would land somewhere the surface dictates rather than where the arrow
//     was pulled. `vector` is a documented no-op there. The `dx` assert below
//     is what makes that self-checking rather than assumed.
//
// NOT A CALL-COUNT CHECK. A stale surface BVH answers the same one cache hit
// a fresh one does — same call count, same code path, different geometry. The
// only observable that separates them is WHERE THE HIT LANDS.
//
// Run via: ./run_test.d test_bus_surface_raycast_after_drag

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import std.math   : fabs, round, sqrt;
import std.stdio  : writefln;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow,
                      axisGrabPx, buildDragLog, playAndWait, DHVec3 = Vec3;

void main() {}

alias BASE = testBaseUrl;


void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

void settle() { Thread.sleep(250.msecs); }

/// The unit cube of `test_fixture_topology_pen_version_invalidation.d`, so the
/// two files' geometry (and therefore their Y ~ 0.5 top face) is the same.
enum string kCubeBody = `{
    "vertices":[[-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[0.5,0.5,-0.5],[-0.5,0.5,-0.5],
                [-0.5,-0.5,0.5],[0.5,-0.5,0.5],[0.5,0.5,0.5],[-0.5,0.5,0.5]],
    "faces":[[0,3,2,1],[4,5,6,7],[0,4,7,3],[1,2,6,5],[3,7,6,2],[0,1,5,4]]
}`;

enum double kAz   = 0.4;
enum double kEl   = 0.6;
enum double kDist = 6.0;    // 6, not the sibling's 4: the displacement below is
                            // ~1.6 world units and has to stay inside the cell.

void setCamera(double fx, double fy, double fz) {
    auto r = postJson("/api/camera",
        format(`{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,`
             ~ `"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`, kAz, kEl, kDist, fx, fy, fz));
    assert("error" !in r, "/api/camera failed: " ~ r.toString);
    settle();
}

/// The centre pixel of the active cell, in the window coordinates
/// `/api/surface-raycast` expects. Computed from the live camera rather than
/// hardcoded, so a layout change fails at the PREMISE assert below instead of
/// silently aiming at empty space.
int[2] centrePixel() {
    auto c = fetchCamera(BASE);
    return [c.vpX + c.width / 2, c.vpY + c.height / 2];
}

JSONValue raycastCentre() {
    auto p = centrePixel();
    return getJson(format("/api/surface-raycast?x=%d&y=%d", p[0], p[1]));
}

bool approx(double a, double b, double eps) { return fabs(a - b) < eps; }

/// Mean X of the PRIMARY layer's cage vertices — the measured displacement.
double meanX() {
    double sum = 0;
    auto vs = getJson("/api/model")["vertices"].array;
    foreach (v; vs) sum += v.array[0].floating;
    return sum / vs.length;
}

/// Two layers: layer0 = the reset cube (primary), layer1 = a second cube,
/// visible and NOT selected, i.e. background. CONS enabled ONCE here — see the
/// header for why it is never turned off again.
void buildTwoLayerRig() {
    postJson("/api/reset", "");
    // `enabled true` FIRST and through the command layer: this is the write
    // that sets `userLocked`, and everything below depends on it.
    cmd("tool.pipe.attr constrain enabled true");
    cmd("tool.pipe.attr constrain geometry screen");

    cmd("layer.add name:Bg");
    auto lr = postJson("/api/load-mesh", kCubeBody);
    assert(lr["status"].str == "ok", "load-mesh failed: " ~ lr.toString);
    cmd("layer.setVisible index:1 value:true");
    cmd("layer.select index:0");     // layer0 primary, layer1 background
    settle();
}

/// Raycast #1: aims at layer1's top-face centre through the focus-point trick
/// and asserts it lands there. This is the PREMISE — it is what builds the
/// surface BVH whose staleness the second raycast measures, and a miss here
/// would make every later reading void.
void buildTheSurfaceBvh() {
    setCamera(0.0, 0.5, 0.0);
    auto r = raycastCentre();
    assert(r["hit"].boolean == true,
        "PREMISE: raycast #1 must hit layer1's top face — it is what BUILDS "
      ~ "the surface BVH this file is about. Got " ~ r.toString);
    assert(r["layer"].integer == 1,
        "PREMISE: raycast #1 must hit the BACKGROUND layer (1), not the "
      ~ "primary — got " ~ r.toString);
    assert(approx(r["point"].array[1].floating, 0.5, 0.02),
        "PREMISE: raycast #1 must land on the top face at Y ~ 0.5; got "
      ~ r.toString);
}

/// Raycast #2, after the displacement: the surface must be found at its NEW
/// place. `dx` is the MEASURED cage displacement, not the requested one.
void assertSurfaceFollowed(double dx, string arm) {
    setCamera(dx, 0.5, 0.0);
    auto r = raycastCentre();
    writefln("[surf bvh] %s: dx=%.4f  raycast#2=%s", arm, dx, r.toString);

    assert(r["hit"].boolean == true,
        format("%s: the surface raycast MISSED after the displacement. The "
             ~ "camera is focused on the moved cube's top-face centre "
             ~ "(%.4f, 0.5, 0), so a hit is what a CURRENT surface BVH gives. "
             ~ "A miss is the stale tree still describing the cube at its OLD "
             ~ "place, %.4f units away. Got %s", arm, dx, fabs(dx), r.toString));
    assert(r["layer"].integer == 1,
        format("%s: raycast #2 must still resolve the background layer 1; "
             ~ "got %s", arm, r.toString));
    assert(approx(r["point"].array[0].floating, dx, 0.05),
        format("%s: the surface raycast reports X = %.4f, and the cube was "
             ~ "measured to have moved to X = %.4f. The BVH is describing "
             ~ "geometry the mesh no longer has — the stale surface tree. %s",
               arm, r["point"].array[0].floating, dx, r.toString));
    assert(approx(r["point"].array[1].floating, 0.5, 0.05),
        format("%s: the hit is off the top face (Y = %.4f, expected ~0.5) — "
             ~ "%s", arm, r["point"].array[1].floating, r.toString));
}

// ===========================================================================
// ARM B — THE MANDATORY NEGATIVE CONTROL. The same rig and the same
// displacement, driven by `/api/transform` → `mesh.transform`, whose kernel
// calls `mesh.commitChange(MeshEditScope.Position)` and BUMPS
// `mutationVersion`. A version key catches that, so this arm is GREEN on
// today's `main` and must STAY green: if a mutation aimed at ARM A reddens
// this block too, the rig is measuring the raycast machinery rather than the
// version-silent path — the exact way `tests/test_subpatch_move.d` stayed
// green through the whole of 0401.
//
// IT RUNS FIRST, AND THE ORDER IS THE WHOLE POINT OF HAVING IT (review of
// stage 2a/2b). A separate `unittest` block is NOT what makes a control
// observable: druntime stops a MODULE at its first failed assert, so with ARM A
// above it, ARM B would never execute under exactly the mutation it exists to
// answer for — its silence would be an artefact of the abort, indistinguishable
// from a pass. Written first, it always reports, and only then does ARM A get
// to fail. Do not reorder these two blocks.
// ===========================================================================
unittest {
    buildTwoLayerRig();
    buildTheSurfaceBvh();

    cmd("layer.select index:1");
    auto selR = postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`));
    assert(selR["status"].str == "ok", "select failed: " ~ selR.toString);

    const double x0 = meanX();
    auto trR = postJson("/api/transform", `{"kind":"translate","delta":[-1.6,0,0]}`);
    assert("error" !in trR, "/api/transform failed: " ~ trR.toString);
    const double dx = meanX() - x0;
    assert(fabs(dx) > 1.2,
        format("the scripted translate moved the cage by %.4f", dx));

    cmd("layer.select index:0");
    settle();

    assertSurfaceFollowed(dx, "ARM B (scripted mesh.transform)");
}

// ===========================================================================
// ARM A — THE REAL GIZMO DRAG. Version-silent on Position: `mutationVersion`
// does not move, at the drag steps OR at the commit, which is exactly why the
// surface BVH's version key cannot see it.
// ===========================================================================
unittest {
    buildTwoLayerRig();
    buildTheSurfaceBvh();

    // Promote layer1 and select all of it. Order matters: the item selection
    // flips the current SelType to Item and drops the active tool, so the tool
    // is armed AFTER the two selections, never between them.
    cmd("layer.select index:1");
    auto selR = postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`));
    assert(selR["status"].str == "ok", "select failed: " ~ selR.toString);

    // CONS off the raycast path for the drag — see the header: this keeps
    // `_bgBvh` un-pruned AND keeps the projection post-pass out of the drag,
    // without touching `userLocked`.
    cmd("tool.pipe.attr constrain geometry vector");
    cmd("tool.set move");
    settle();

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);

    // The gizmo pivot, read live rather than assumed — a pivot-law change must
    // fail loudly here rather than send the drag somewhere else.
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    const auto pivot = DHVec3(cast(float)c[0].floating,
                              cast(float)c[1].floating,
                              cast(float)c[2].floating);

    int gx, gy;
    double ux, uy;
    axisGrabPx(pivot, vp, gx, gy, ux, uy);

    // Pixels per world unit along +X, by projection rather than by guess.
    // Dragged in the NEGATIVE screen direction so the whole sweep stays inside
    // the cell (the grab point already sits ~0.7 of an arm to the +X side).
    enum double kWantDx = 2.0;
    float ax, ay, bx, by;
    assert(projectToWindow(pivot, vp, ax, ay)
        && projectToWindow(DHVec3(pivot.x + cast(float)kWantDx, pivot.y, pivot.z),
                           vp, bx, by),
        "rig: the displacement does not project");
    const double pxPerDx = sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));

    const double x0 = meanX();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             gx, gy,
                             gx - cast(int)round(pxPerDx * ux),
                             gy - cast(int)round(pxPerDx * uy),
                             12), BASE);
    settle();
    const double dx = meanX() - x0;

    // Positive control: a grab that MISSED the arrow orbits the camera
    // instead, and then nothing below measures what it claims to.
    assert(fabs(dx) > 1.2,
        format("the move-arrow grab did not land the displacement: the cage "
             ~ "centre moved %.4f, and it must clear the cube's own 1.0 width "
             ~ "for the old and new positions to be disjoint", dx));
    auto camAfter = fetchCamera(BASE);
    assert(fabs(camAfter.eye.x - cam.eye.x) < 1e-3
        && fabs(camAfter.eye.z - cam.eye.z) < 1e-3,
        "the camera moved during the drag — the grab missed the arrow and "
      ~ "orbited instead, so the aim of raycast #2 is meaningless");

    // Drop the tool and put layer1 back in the background seat. The tool drop
    // runs `resetTransientPipeStages()`; `userLocked` is what keeps `_bgBvh`
    // (and therefore the stale entry under test) alive across it.
    cmd("tool.set move off");
    cmd("layer.select index:0");
    cmd("tool.pipe.attr constrain geometry screen");
    settle();

    assertSurfaceFollowed(dx, "ARM A (gizmo drag)");
}
