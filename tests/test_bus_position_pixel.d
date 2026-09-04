// Task 1906 — THE 0401 CELL, IN PIXELS: a version-silent gizmo drag must move
// what is on the screen, and the thing on the screen is the subpatch LIMIT
// SURFACE (the stale-cache class 0401 was about).
//
// ===========================================================================
// WHAT THIS FILE DISCRIMINATES, AND WHEN — read this before trusting a green
// ===========================================================================
// Measured on `main` at stage 1 (2026-08-25), and it CORRECTS the plan's §5
// row `1` prediction: ARM A IS GREEN ON `main`, and it is green with the
// stage-1 publish sites reverted to `noteChange` as well. The display path was
// already correct then, and the reason was structural rather than lucky —
// `app.d`'s hub (`changeBus.onMeshChanged` → `meshChangedFlags`) was fed by
// BOTH delivery paths, the synchronous one and the once-per-frame flush of
// `Mesh.pendingChanges_`, and the flush sat ABOVE the subpatch-preview poll in
// the loop body. So a drag whose class only reached the accumulator still
// reached the preview, one flush later, in the same frame.
//
// STAGE 3 CLOSED THAT SECOND PATH: the mesh channel left `ChangeBus.flush`
// entirely and the drain is deleted, so the hub is fed by the synchronous
// delivery ALONE. That removes the reason ARM A was green under a reverted
// publish — but it does NOT turn this file into a live guard, because the
// paragraph below stands unchanged: the channel that actually carries a
// version-silent drag to the limit surface was never identified, and starving
// both paths at once left both arms green.
//
// That does not make this file a test that cannot fail. It makes its
// discriminating mutation a LATER one. Measured at stage 2d (plan §2.4): ARM A
// rides `g_geomEpochs` fed by the hub — removing the per-frame drain (2d-6b)
// or the uploader's `commitChange(Position)` leaves it green — so the mutation
// this file reddens for is a stripped `Position` class at the hub subscriber
// (`test_bus_epoch_position_class` carries that pin, and since stage 3 deleted
// the second feed that pin is ONE line rather than a pair), and stage 3's
// drain deletion is pinned by the same-batch cells, not here. What this file
// is, then, is the FROZEN EVIDENCE of the 0401 cell: what the drag must do to
// the limit surface, pinned in the one channel — rendered pixels — that a
// version key, a draw-call census and a cage-position read all fail to see.
//
// AND THE "SECOND PATH TO THE HUB" IS NOT THE WHOLE REASON (review S5,
// measured 2026-08-25 in an rsync'd scratch copy). The review asked for a
// stronger mutation than row `1`: revert `applyFold`'s publish to `noteChange`
// AND make `app.d`'s hub subscriber drop the class outright
// (`meshChangedFlags |= flags & ~MeshEditScope.Position`), which starves BOTH
// delivery paths at once. ARM A stayed GREEN, and so did ARM B. Two further
// readings from the same tree say why that is not a fluke:
//
//   * after a committed gizmo drag the flush word is exactly `1` — Position
//     alone, no Marks and no Geometry — so `meshChangedFlags` really is
//     starved under that mutation;
//   * the preview's `builds` counter does NOT move across a drag (1 -> 1),
//     i.e. a drag never triggers a full preview rebuild in the first place.
//
// So the channel that carries a version-silent drag to the limit surface is
// still UNIDENTIFIED, and identifying it is a stage-3 prerequisite rather than
// a nicety: stage 3 deletes the per-frame drain, and it must know what it is
// deleting. IT STILL IS unidentified — stage 3 shipped the deletion with the
// question open, on the evidence that the same starve-both-paths mutation
// leaves both arms green either way. So no mutation of the PUBLISH side can
// redden this file, and the honest statement of what it pins is the frozen
// evidence above — not a live guard.
//
// The live staleness this task's survey did find (the surface BVH,
// `bvh_pick.d :: pickSurfaceRay` keyed on `mutationVersion` with no bus term
// and no external `invalidateSurface()` caller) is NOT probed here: it is
// stage 2b's, it is red on `main` AND red after stage 1, and a test asserting
// it is fresh could not be shipped green today.
//
// ===========================================================================
// THE RIG, AND EVERY REFUSAL IN IT
// ===========================================================================
//   * NOT A CUBE. On a closed solid a stale limit surface hides behind the
//     front half everywhere a probe could land, so "did not update" and "not
//     visible" read identically. The rig is an OPEN 4x4 grid patch (25 verts,
//     16 quads) in the XY plane — a real boundary, nothing behind anything.
//   * NOT A CAGE-POSITION READ. `/api/model` says where the CAGE vertices
//     are, and the cage moves even when the limit surface does not: that is
//     precisely the 0401 defect. The observable has to be the surface.
//   * NOT A DRAW-CALL COUNT. A stale preview re-serves the SAME slot: same
//     draw calls, byte-identical `/api/frames/counts`. The same trap as the
//     second selection pass (task 1860).
//   * NOT `/api/transform`. That path calls `commitChange(Position)` and BUMPS
//     `mutationVersion`, so every version key in the tree catches it. It is
//     ARM B, the mandatory negative control — and it is verbatim how
//     `tests/test_subpatch_move.d` stayed green while the gizmo was broken.
//     Separate `unittest` block, because druntime stops a module at its first
//     failed assert and ARM A's red would hide ARM B's silence.
//   * THE TOOL IS DROPPED BEFORE THE AFTER-PROBES. The gizmo arms are 120 px
//     long and are drawn at the pivot the drag just moved; a probe pixel they
//     covered would change colour for the wrong reason.
//   * EVERY VERTEX IS SELECTED, in BOTH arms. The tool would move the whole
//     mesh on an empty selection (the documented empty-selection rule), but
//     `/api/transform` would move NOTHING — it is selection-aware with no such
//     fallback (measured: an empty-selection ARM B displaced the cage by 0).
//     A control that differs from its arm in the SELECTION as well as in the
//     mechanism controls for two things at once, so both arms select the same
//     set and differ only in how the displacement is produced.
//
// ===========================================================================
// THE THREE READINGS
// ===========================================================================
// `P` is a point ON the pre-drag limit surface, read out of `/api/gpu/face-vbo`
// rather than predicted — a triangle centroid, so it cannot land on an edge or
// a vertex dot, and chosen with |y| > 0.3 so its pixel is clear of the ground
// grid's horizon line (the grid plane is y = 0 and the camera is frontal, so
// that plane projects to a horizontal line through the middle of the cell).
//
//   before, at P          -> S0, the surface
//   after,  at P          -> S1, must DIFFER from S0: the surface LEFT
//   after,  at P + (dx,0,0) -> S2, must MATCH S0: the surface ARRIVED
//
// The displacement is forced to exceed the patch's own x-extent, so the two
// silhouettes are DISJOINT and "arrived" is a real claim rather than "it was
// always there". Each half alone is insufficient and both are asserted: a
// preview that simply stopped drawing satisfies "left" and fails "arrived"; a
// preview drawn twice satisfies "arrived" and fails "left".
//
// `S0` is proved to be the surface, not an assumption, by a fourth reading: a
// background pixel outside the patch. If S0 did not differ strongly from it,
// the probe never found the surface and every assert below would be measuring
// two shades of background.

import http_client : testBaseUrl, getJson, postJson;
import std.net.curl;
import std.json;
import std.conv    : to;
import std.format  : format;
import std.math    : fabs, round, abs;
import std.stdio   : writefln;
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

/// A state change is visible only once a frame has RENDERED with it, and a
/// probe reads the last COMPLETED frame — so this has to cover two.
void settle() { Thread.sleep(450.msecs); }

// ---------------------------------------------------------------------------
// Pixels
// ---------------------------------------------------------------------------

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

/// Manhattan distance over RGB — a scalar so the failure messages can quote
/// "how far apart" rather than three channel pairs.
int rgbDist(Px a, Px b) {
    return cast(int)(abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b));
}

// The two thresholds, and the MEASURED readings they sit between (2026-08-25,
// this rig, both arms): the lit flat patch reads (105, 105, 105) and the
// background of the SAME SCREEN ROW reads (92, 102, 107) — a distance of 18.
// Every "same" pair below measures 0, exactly, because the rendering is
// deterministic and the background gradient is vertical: the old-place pixel
// and the background reference share a screen row by construction, so after
// the displacement the first reads the second's value to the byte.
//
// So the separation is 18 against 0, and these constants are fixed numbers
// with a 2x margin on the smaller side rather than anything derived from the
// reading they judge. 18 is not a large contrast; that is what the PREMISE
// assert is for. A theme or lighting change that brings the surface closer to
// the background reddens the premise — loudly, and with both values quoted —
// instead of quietly making the two cells below undecidable.
enum int kDiffer = 9;   // "these two pixels show different things"
enum int kMatch  = 4;   // "these two pixels show the same thing"

// ---------------------------------------------------------------------------
// The rig
// ---------------------------------------------------------------------------

/// A 4x4-quad open grid patch in the XY plane, x,y in [-1,1]: 25 vertices,
/// 16 quads, a real boundary. Wound CCW as seen from +z, which is where the
/// frontal camera sits.
void loadOpenPatch() {
    enum int N = 4;                         // quads per side
    string verts = "[";
    foreach (j; 0 .. N + 1) {
        foreach (i; 0 .. N + 1) {
            if (i || j) verts ~= ",";
            const double x = -1.0 + 2.0 * i / N;
            const double y = -1.0 + 2.0 * j / N;
            verts ~= format("[%.6f,%.6f,0.0]", x, y);
        }
    }
    verts ~= "]";

    string faces = "[";
    foreach (j; 0 .. N) {
        foreach (i; 0 .. N) {
            if (i || j) faces ~= ",";
            const int a = j * (N + 1) + i;
            faces ~= format("[%d,%d,%d,%d]", a, a + 1, a + N + 2, a + N + 1);
        }
    }
    faces ~= "]";

    auto j = postJson("/api/load-mesh",
                      format(`{"vertices":%s,"faces":%s}`, verts, faces));
    assert(j["status"].str == "ok", "load-mesh failed: " ~ j.toString);
}

/// Frontal camera. Set AFTER the mesh load, which resets the camera. The
/// distance is what sets world-units-per-pixel, and it has to be large enough
/// that a displacement wider than the patch still fits on the cell.
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

/// Task 1500 — the preview is built on a worker thread and `/api/gpu/face-vbo`
/// answers during a build, showing the CAGE. Wait for it.
void waitPreviewSettled(int timeoutMs = 30_000) {
    foreach (_; 0 .. timeoutMs / 20) {
        auto j = getJson("/api/subpatch/preview");
        if (j["pending"].type != JSONType.true_) { Thread.sleep(120.msecs); return; }
        Thread.sleep(20.msecs);
    }
    assert(false, "subpatch preview build did not settle");
}

/// THE PREMISE THIS FILE IS NAMED FOR, AND IT WAS MISSING (review S5).
///
/// Every assert below says "the surface followed the drag". The CAGE follows a
/// drag unconditionally — that is what `/api/model` reports and what no version
/// key can get wrong. The claim worth pinning is about the LIMIT SURFACE, and
/// the two are separable only if the preview is actually ACTIVE: when it is
/// not, `/api/gpu/face-vbo` and the framebuffer both show the cage, every
/// reading below still lines up, and the file passes while measuring something
/// else entirely.
///
/// MEASURED, not hypothesised: with `app.d`'s `rebuildIfStale` gate forced
/// false, both arms of this file stayed GREEN — the preview simply never became
/// active and the cage took its place on screen. So a mutation aimed at the
/// preview's refresh channel could not redden this file; it changed the SUBJECT
/// instead of breaking the claim. This assert is what closes that hole.
void assertPreviewActive(string where) {
    auto j = getJson("/api/subpatch/preview");
    assert(j["active"].type == JSONType.true_,
        format("%s PREMISE: the subpatch preview must be ACTIVE — the thing "
             ~ "this file probes is the LIMIT SURFACE, and with no preview the "
             ~ "framebuffer shows the CAGE, which follows any drag by "
             ~ "construction. `/api/subpatch/preview` says %s",
               where, j.toString));
}

/// Both arms move the SAME set: `/api/transform` moves the selection and
/// nothing else, so an empty selection makes ARM B a no-op.
void selectAllVertices() {
    auto n = getJson("/api/model")["vertices"].array.length;
    string idx = "[";
    foreach (i; 0 .. n) { if (i) idx ~= ","; idx ~= i.to!string; }
    idx ~= "]";
    auto r = postJson("/api/select",
                      `{"mode":"vertices","indices":` ~ idx ~ `}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);
    settle();
}

void enableSubpatchOnEveryFace() {
    // Polygons mode with no selection: `mesh.subpatch_toggle` flips every
    // face, which is what the Tab key does.
    cmd("select.typeFrom polygon");
    postJson("/api/command", `{"id":"mesh.subpatch_toggle"}`);
    waitPreviewSettled();
    cmd("select.typeFrom vertex");
    settle();
    assertPreviewActive("rig setup:");
}

struct Surface {
    DHVec3[] pos;      // face-VBO vertex positions (triangle soup)
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

/// A point that is definitely ON the rendered surface: the centroid of one of
/// its triangles. Read out of the VBO rather than predicted, so no assumption
/// about where a Catmull-Clark limit boundary falls can make it miss. Chosen
/// with |y| > 0.3 to clear the ground grid's horizon line.
DHVec3 surfacePoint(const ref Surface s) {
    for (size_t i = 0; i + 2 < s.pos.length; i += 3) {
        const double cx = (s.pos[i].x + s.pos[i+1].x + s.pos[i+2].x) / 3.0;
        const double cy = (s.pos[i].y + s.pos[i+1].y + s.pos[i+2].y) / 3.0;
        const double cz = (s.pos[i].z + s.pos[i+1].z + s.pos[i+2].z) / 3.0;
        if (fabs(cy) > 0.3)
            return DHVec3(cast(float)cx, cast(float)cy, cast(float)cz);
    }
    assert(false, "no surface triangle clears the ground-grid horizon line");
}

/// World point -> FBO pixel, through the LIVE camera. No probe below is a
/// magic number.
int[2] fbo(DHVec3 world) {
    auto camS = fetchCamera(BASE);
    auto vp   = viewportFromCamera(camS);
    float px, py;
    assert(projectToWindow(world, vp, px, py),
        format("rig: the world point (%g, %g, %g) is behind the camera",
               world.x, world.y, world.z));
    const int x = cast(int)round(px) - camS.vpX;
    const int y = cast(int)round(py) - camS.vpY;
    assert(x >= 0 && y >= 0 && x < camS.width && y < camS.height,
        format("rig: (%g, %g, %g) projects to cell pixel (%d, %d), outside "
             ~ "the %dx%d cell — the camera distance is wrong for this "
             ~ "displacement", world.x, world.y, world.z, x, y,
               camS.width, camS.height));
    return [x, y];
}

double meanCageX() {
    double sum = 0;
    auto vs = getJson("/api/model")["vertices"].array;
    foreach (v; vs) sum += v.array[0].floating;
    return sum / vs.length;
}

// ---------------------------------------------------------------------------
// The three readings, shared by both arms so the two differ ONLY in HOW the
// displacement was produced.
// ---------------------------------------------------------------------------
struct Readings { Px s0, s1, s2, bg; double dx; }

void assertSurfaceFollowed(const ref Readings r, string armLabel) {
    writefln("[bus pixel] %s: dx=%.3f  S0=%s  S1=%s  S2=%s  bg=%s",
             armLabel, r.dx, r.s0.toString, r.s1.toString, r.s2.toString,
             r.bg.toString);

    // Premise: the "before" probe really found the surface.
    assert(rgbDist(r.s0, r.bg) > kDiffer,
        format("%s PREMISE: the pre-drag probe must land ON the limit surface "
             ~ "— it reads %s, and a background pixel of the same frame reads "
             ~ "%s. Too close to tell apart, so every assert below would be "
             ~ "comparing two shades of background",
               armLabel, r.s0.toString, r.bg.toString));

    // (1) The surface LEFT its old place.
    assert(rgbDist(r.s1, r.s0) > kDiffer,
        format("%s: the limit surface did not LEAVE the pixel it covered "
             ~ "before the displacement — it reads %s, was %s. A cage that "
             ~ "moved while the surface stayed is the whole of the 0401 "
             ~ "class, and `/api/model` cannot see it",
               armLabel, r.s1.toString, r.s0.toString));

    // (1b) …and what it left behind is the BACKGROUND OF ITS OWN SCREEN ROW,
    //      not some third thing. `bg` was probed one patch-width to the left
    //      at the same world y, so it shares the screen row and the vertical
    //      background gradient makes the two bytes-equal. This is what refuses
    //      "the surface moved a little" and "a different overlay took the
    //      pixel over" without needing a second frame.
    assert(rgbDist(r.s1, r.bg) <= kMatch,
        format("%s: the vacated pixel reads %s, and the background of the "
             ~ "same screen row reads %s. The surface left, but what replaced "
             ~ "it is not the background — something else is drawing there and "
             ~ "assert (1) passed for the wrong reason",
               armLabel, r.s1.toString, r.bg.toString));

    // (2) The surface ARRIVED at the new place. Without this half a preview
    //     that simply stopped drawing would satisfy (1).
    assert(rgbDist(r.s2, r.s0) <= kMatch,
        format("%s: the limit surface is not at its NEW place — the pixel at "
             ~ "the displaced surface point reads %s, and the surface read %s "
             ~ "before. It left (assert 1) and did not arrive, which is a "
             ~ "preview that stopped drawing, not one that followed",
               armLabel, r.s2.toString, r.s0.toString));
}

// ===========================================================================
// ARM A — THE REAL GIZMO DRAG. Version-silent: no `mutationVersion` bump
// anywhere on this path, which is exactly why no version key can catch it.
// ===========================================================================
unittest {
    postJson("/api/reset", "");
    loadOpenPatch();
    frontalCamera(11.0);
    enableSubpatchOnEveryFace();
    selectAllVertices();

    const auto pre = surface();
    const auto P   = surfacePoint(pre);
    const double patchWidth = pre.xMax - pre.xMin;
    assert(patchWidth > 0.5, format("rig: the limit surface is %g wide in x — "
                                  ~ "too small to be a patch", patchWidth));

    // The displacement must exceed the patch's own width, so the pre- and
    // post-drag silhouettes are DISJOINT and "arrived" is a real claim. 2.0x
    // rather than the 1.3x this started at: a gizmo drag delivers about 0.8 of
    // the world delta its pixel delta projects to (measured 2.08 for a
    // requested 2.6), so 1.3x landed 4 % clear of the patch width and 2.0x
    // lands ~60 % clear.
    const double wantDx = patchWidth * 2.0;

    const auto pxP = fbo(P);
    const Px s0 = probe1(pxP[0], pxP[1]);
    // A background pixel of the SAME frame: one patch-width to the LEFT, where
    // nothing is drawn either before or after a +X displacement.
    const auto pxBg = fbo(DHVec3(cast(float)(P.x - patchWidth * 1.5),
                                 P.y, P.z));
    const Px bg = probe1(pxBg[0], pxBg[1]);

    // Arm the move tool and grab the +X arrow. The drag distance is computed
    // by PROJECTION rather than guessed: with a frontal camera the +X axis is
    // parallel to the screen, so a screen delta maps linearly to a world one.
    cmd("tool.set move");
    settle();
    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    float ax, ay, bx, by;
    assert(projectToWindow(DHVec3(0, 0, 0), vp, ax, ay)
        && projectToWindow(DHVec3(cast(float)wantDx, 0, 0), vp, bx, by),
        "rig: the displacement does not project");
    const double pxPerDx = bx - ax;

    int gx, gy;
    double ux, uy;
    // The gizmo pivot with nothing selected is the mesh centre — read it live
    // rather than assumed, so a pivot-law change fails loudly here.
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    axisGrabPx(DHVec3(cast(float)c[0].floating, cast(float)c[1].floating,
                      cast(float)c[2].floating),
               vp, gx, gy, ux, uy);

    const double x0 = meanCageX();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             gx, gy,
                             gx + cast(int)round(pxPerDx * ux),
                             gy + cast(int)round(pxPerDx * uy),
                             12), BASE);
    settle();
    const double dx = meanCageX() - x0;

    // Positive control: a grab that MISSED the arrow orbits the camera, and
    // then every projection above is stale and every probe below is void.
    assert(dx > patchWidth * 1.05,
        format("the move-arrow grab did not land the displacement: the cage "
             ~ "centre moved %g, and it must exceed the patch width %g for "
             ~ "the two silhouettes to be disjoint", dx, patchWidth));
    auto camAfter = fetchCamera(BASE);
    assert(fabs(camAfter.eye.x - cam.eye.x) < 1e-3
        && fabs(camAfter.eye.z - cam.eye.z) < 1e-3,
        "the camera moved during the drag — the grab missed the arrow and "
      ~ "orbited instead, so the pixel geometry below is stale");

    // Drop the tool BEFORE probing: the gizmo is drawn at the pivot the drag
    // just moved, and its arms are 120 px long.
    cmd("tool.set move off");
    waitPreviewSettled();
    settle();
    // Again at PROBE time: a preview that was active before the drag and
    // silently went away during it would leave the cage under the probe, and
    // the three readings would agree for the wrong reason.
    assertPreviewActive("ARM A (gizmo drag) at probe time:");

    Readings r;
    r.dx = dx;
    r.s0 = s0;
    r.bg = bg;
    r.s1 = probe1(pxP[0], pxP[1]);
    const auto pxNew = fbo(DHVec3(cast(float)(P.x + dx), P.y, P.z));
    r.s2 = probe1(pxNew[0], pxNew[1]);
    assertSurfaceFollowed(r, "ARM A (gizmo drag)");
}

// ===========================================================================
// ARM B — THE MANDATORY NEGATIVE CONTROL. Same rig, same displacement, driven
// by the scripted path: `/api/transform` builds `mesh.transform`
// (`http_providers.d`, `reg.commandFactories["mesh.transform"]`), whose
// kernel calls `mesh.commitChange(MeshEditScope.Position)` and BUMPS
// `mutationVersion`.
//
// It must stay GREEN whatever happens to the interactive publish sites. If a
// mutation aimed at ARM A reddens this block too, the rig is measuring
// something other than the version-silent path — which is the failure mode
// task 0401 actually shipped: `tests/test_subpatch_move.d` was green on this
// very path the whole time the gizmo was broken.
// ===========================================================================
unittest {
    postJson("/api/reset", "");
    loadOpenPatch();
    frontalCamera(11.0);
    enableSubpatchOnEveryFace();
    selectAllVertices();

    const auto pre = surface();
    const auto P   = surfacePoint(pre);
    const double patchWidth = pre.xMax - pre.xMin;
    const double wantDx = patchWidth * 2.0;

    const auto pxP = fbo(P);
    const Px s0 = probe1(pxP[0], pxP[1]);
    const auto pxBg = fbo(DHVec3(cast(float)(P.x - patchWidth * 1.5),
                                 P.y, P.z));
    const Px bg = probe1(pxBg[0], pxBg[1]);

    const double x0 = meanCageX();
    auto t = postJson("/api/transform",
                      format(`{"kind":"translate","delta":[%.6f,0,0]}`, wantDx));
    assert(t["status"].str == "ok", "/api/transform failed: " ~ t.toString);
    waitPreviewSettled();
    settle();
    assertPreviewActive("ARM B (scripted mesh.transform) at probe time:");
    const double dx = meanCageX() - x0;
    assert(dx > patchWidth * 1.05,
        format("the scripted translate moved the cage by %g, which must "
             ~ "exceed the patch width %g", dx, patchWidth));

    Readings r;
    r.dx = dx;
    r.s0 = s0;
    r.bg = bg;
    r.s1 = probe1(pxP[0], pxP[1]);
    const auto pxNew = fbo(DHVec3(cast(float)(P.x + dx), P.y, P.z));
    r.s2 = probe1(pxNew[0], pxNew[1]);
    assertSurfaceFollowed(r, "ARM B (scripted mesh.transform)");
}
