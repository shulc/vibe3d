// Task 1906 stage 2c (plan §3.3 rows 8 / 30) — THE SNAP CANDIDATE GRID AFTER A
// VERSION-SILENT GIZMO DRAG.
//
// ===========================================================================
// WHAT THE CACHE IS AND WHY A POSITION CHANGE INVALIDATES IT
// ===========================================================================
// `snap.queryCandidateGrid` answers each snap query from a screen-space bucket
// grid: every element of a kind is projected once and dropped into the cell
// its pixel falls in, and a query scans the 3×3 block around the cursor cell.
// Move a vertex and its stored bucket describes where it USED to be — a
// cursor sitting on its new pixel scans cells that no longer hold it, and the
// candidate is silently absent.
//
// Until stage 2c the staleness key was `(meshAddr, mesh.mutationVersion)`,
// propped up by `app.d`'s frame flush calling `invalidateSnapGrids()` on any
// `Position` frame. An interactive gizmo Move/Rotate/Scale is version-silent —
// `mutationVersion` moves neither at the drag steps nor at the commit
// (CLAUDE.md, "The exception that breaks version-keying") — so the version
// half never saw the gesture, and the manual half was a second, subject-less
// channel: it dropped EVERY source slot's grid because SOME layer changed, and
// every future publisher had to remember it existed. Stage 2c replaces both
// with the change bus's own per-address geometry epoch
// (`mesh_dirty.g_geomEpochs`), compared inside `queryCandidateGrid`.
//
// ===========================================================================
// THE RIG, AND EVERY REFUSAL IN IT
// ===========================================================================
// The observable is `/api/snap`'s `targetIndex` — does the query find the
// moved vertex at its NEW pixel?
//
//   * THE SNAP RANGE MUST STAY MODEST, and this is the way this file would
//     most easily be born inert. The grid's CELL SIZE is `outerRangePx`. The
//     neighbouring `test_snap_during_drag.d` sets both ranges to 999999 so
//     that everything is in range — under that config the whole screen is ONE
//     cell, the 3×3 block covers the entire projected domain, and a completely
//     stale grid still offers every element. The 24/40 pair below is the
//     shipped default, and the `kMinPixelSeparation` assert is what proves the
//     displacement actually clears the block rather than assuming it does.
//   * SNAP IS OFF FOR THE DISPLACEMENT. With it on, the drag queries snap on
//     every motion event, which (a) rebuilds the grid mid-gesture on the fixed
//     code, so the final query would be measuring the drag's own last rebuild
//     rather than the mechanism, and (b) lets the dragged vertex snap onto a
//     neighbour and land somewhere other than where the arrow was pulled.
//     Off, the grid built by the premise query is the ONLY one either code
//     path has, and the two are separated by nothing but the key.
//
// WHAT THIS FILE DOES NOT PIN. It is GREEN on the pre-2c tree (measured in the
// 2c review): there the manual `invalidateSnapGrids()` call from app.d's frame
// flush held the grid correct, and the version key was dead weight beside it.
// Both arms redden only when the version key is restored WITHOUT that manual
// call. So this file pins the REPLACEMENT — that the epoch alone carries the
// load — not a bug a user could see before 2c.
//   * THE WHOLE CUBE MOVES, not one corner. Snap's candidate walk runs each
//     vertex through `vertVisible` (the facing predicate over its ring), and
//     dragging a single corner two units out of the solid reshapes those rings
//     — a `snapped:false` would then be ambiguous between "the grid is stale"
//     and "the vertex got culled". A rigid translation leaves every ring's
//     facing as the premise query already measured it.
//
// NOT A CALL-COUNT CHECK. A stale grid is queried exactly as often as a fresh
// one, through the same code path, and answers in the same shape. The only
// observable that separates them is WHAT COMES BACK.
//
// Run via: ./run_test.d test_bus_snap_grid_after_drag

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

enum BASE = "http://localhost:8080";

/// The shipped SnapStage defaults (`toolpipe/packets.d :: SnapPacket`). Spelled
/// out because the grid's CELL SIZE is `kOuterRangePx` and every separation
/// figure below is stated in units of it — see the header on inertness.
enum double kInnerRangePx = 24.0;
enum double kOuterRangePx = 40.0;
/// A displacement must put the moved vertex this far from EVERY stale bucket,
/// so a 3×3 block scan (± one cell) around the new pixel cannot reach one.
enum double kMinPixelSeparation = 3.0 * kOuterRangePx;

/// The vertex this file aims at: `makeCube`'s +X+Y+Z corner, which the camera
/// below looks straight at. The premise query asserts the index, so a camera
/// or cube change fails loudly here instead of quietly aiming elsewhere.
enum int kTarget = 6;

JSONValue getJson(string path) { return parseJSON(cast(string)get(BASE ~ path)); }

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(BASE ~ path, body_));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

void settle() { Thread.sleep(250.msecs); }

double[3][] modelVerts() {
    double[3][] o;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        o ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return o;
}

/// World → window pixel through the LIVE camera, the same projection
/// `/api/snap` resolves the cursor with.
double[2] pixelOf(double[3] w) {
    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    float px, py;
    assert(projectToWindow(DHVec3(cast(float)w[0], cast(float)w[1], cast(float)w[2]),
                           vp, px, py),
        format("rig: %s does not project on-screen", w.to!string));
    return [cast(double)px, cast(double)py];
}

double pixelDist(double[2] a, double[2] b) {
    const double dx = a[0] - b[0], dy = a[1] - b[1];
    return sqrt(dx * dx + dy * dy);
}

/// One `/api/snap` probe with the cursor parked on `world`'s own pixel.
JSONValue snapAt(double[3] world) {
    auto p = pixelOf(world);
    return postJson("/api/snap",
        format(`{"cursor":[%.6f,%.6f,%.6f],"sx":%d,"sy":%d,"excludeVerts":[]}`,
               world[0], world[1], world[2],
               cast(int)round(p[0]), cast(int)round(p[1])));
}

/// reset → a camera that looks at the cube's +X+Y+Z corner → snap configured
/// at the shipped ranges → ONE probe that BUILDS the candidate grid.
void armAndBuildGrid() {
    postJson("/api/reset", "");
    auto camR = postJson("/api/camera",
        `{"azimuth":0.4,"elevation":0.6,"distance":6.0,`
      ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert("error" !in camR, "/api/camera failed: " ~ camR.toString);

    // No tool is armed here on purpose: `tool.pipe.attr` writes the stage
    // directly, and ARM B must not run its scripted transform under a live
    // gizmo. ARM A arms `move` itself, AFTER the premise probe.
    auto r = post(BASE ~ "/api/script",
        "tool.pipe.attr snap enabled true\n"
      ~ "tool.pipe.attr snap types vertex\n"
      ~ format("tool.pipe.attr snap innerRange %g\n", kInnerRangePx)
      ~ format("tool.pipe.attr snap outerRange %g\n", kOuterRangePx));
    assert(parseJSON(cast(string)r)["status"].str == "ok",
        "snap config failed: " ~ cast(string)r);
    settle();

    auto vs = modelVerts();
    auto sr = snapAt(vs[kTarget]);
    assert("error" !in sr, "/api/snap failed: " ~ sr.toString);
    assert(sr["snapped"].boolean == true && sr["targetIndex"].integer == kTarget,
        format("PREMISE: with the cursor parked on vertex %d's own pixel the "
             ~ "snap query must elect it — this probe is what BUILDS the "
             ~ "candidate grid whose staleness the arms below measure, and it "
             ~ "is also what proves the vertex passes snap's facing gate. "
             ~ "Got %s", kTarget, sr.toString));
}

/// After the whole cube has been displaced, the query at the target's NEW
/// pixel must still elect it. `arm` names the mechanism that moved it.
void assertGridFollowed(double[3][] before, string arm) {
    auto after = modelVerts();

    // The rig is not inert: the new pixel must be outside the 3×3 block of
    // EVERY bucket the stale grid holds. Measured, not assumed.
    auto newPx = pixelOf(after[kTarget]);
    double nearestStale = double.max;
    int    nearestIdx   = -1;
    foreach (i, w; before) {
        const double d = pixelDist(newPx, pixelOf(w));
        if (d < nearestStale) { nearestStale = d; nearestIdx = cast(int)i; }
    }
    assert(nearestStale > kMinPixelSeparation,
        format("%s: the displacement is too small to discriminate. Vertex %d's "
             ~ "new pixel is %.1f px from the STALE bucket of vertex %d, and a "
             ~ "3×3 scan over %.0f px cells reaches %.0f px — so a stale grid "
             ~ "could answer correctly by accident",
               arm, kTarget, nearestStale, nearestIdx, kOuterRangePx,
               kMinPixelSeparation));

    auto sr = snapAt(after[kTarget]);
    writefln("[snap grid] %s: target moved %s -> %s (nearest stale bucket "
           ~ "%.1f px away), snap=%s",
             arm, before[kTarget].to!string, after[kTarget].to!string,
             nearestStale, sr.toString);

    assert("error" !in sr, format("%s: /api/snap failed: %s", arm, sr.toString));
    assert(sr["snapped"].boolean == true,
        format("%s: the snap query found NOTHING with the cursor parked on "
             ~ "vertex %d's own pixel. The vertex is at %s and the grid still "
             ~ "buckets it at its pre-displacement pixel %.1f px away, so the "
             ~ "3×3 scan around the cursor never reaches it. Got %s",
               arm, kTarget, after[kTarget].to!string,
               pixelDist(newPx, pixelOf(before[kTarget])), sr.toString));
    assert(sr["targetIndex"].integer == kTarget,
        format("%s: the snap query elected vertex %d, not %d, with the cursor "
             ~ "on vertex %d's own pixel — the candidate set is the stale "
             ~ "one. Got %s", arm, sr["targetIndex"].integer, kTarget,
               kTarget, sr.toString));

    auto wp = sr["worldPos"].array;
    foreach (k; 0 .. 3)
        assert(fabs(wp[k].floating - after[kTarget][k]) < 0.02,
            format("%s: the snap target's reported world position is "
                 ~ "[%s,%s,%s] but vertex %d is at %s — the grid is offering "
                 ~ "geometry the mesh no longer has",
                   arm, wp[0].floating.to!string, wp[1].floating.to!string,
                   wp[2].floating.to!string, kTarget, after[kTarget].to!string));
}

// ===========================================================================
// ARM B — THE MANDATORY NEGATIVE CONTROL, AND IT RUNS FIRST. The same rig and
// the same displacement, driven by `/api/transform` → `mesh.transform`, whose
// kernel calls `commitChange(Position)` and BUMPS `mutationVersion`. A version
// key catches that, so this arm was green before stage 2c and must STAY green:
// if a mutation aimed at ARM A reddens this block too, the rig is measuring
// the snap machinery rather than the version-silent path.
//
// FIRST, and the order is the whole point of having it: druntime stops a
// MODULE at its first failed assert, so with ARM A above it this block would
// never execute under exactly the mutation it exists to answer for, and its
// silence would be indistinguishable from a pass.
// ===========================================================================
unittest {
    armAndBuildGrid();
    auto before = modelVerts();

    auto selR = postJson("/api/select",
                         `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(selR["status"].str == "ok", "select failed: " ~ selR.toString);

    cmd("tool.pipe.attr snap enabled false");
    auto trR = postJson("/api/transform", `{"kind":"translate","delta":[2.0,0,0]}`);
    assert("error" !in trR, "/api/transform failed: " ~ trR.toString);
    cmd("tool.pipe.attr snap enabled true");
    settle();

    const double dx = modelVerts()[kTarget][0] - before[kTarget][0];
    assert(dx > 1.5,
        format("the scripted translate moved the cube by %.4f in X", dx));

    assertGridFollowed(before, "ARM B (scripted mesh.transform)");
}

// ===========================================================================
// ARM A — THE REAL GIZMO DRAG. Version-silent on Position: `mutationVersion`
// does not move, at the drag steps OR at the commit, which is exactly why the
// grid's old version key could not see it.
// ===========================================================================
unittest {
    armAndBuildGrid();
    auto before = modelVerts();

    auto selR = postJson("/api/select",
                         `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(selR["status"].str == "ok", "select failed: " ~ selR.toString);

    // Snap OFF for the gesture — see the header: this is what keeps the grid
    // built by the premise query the ONLY one either code path has.
    cmd("tool.pipe.attr snap enabled false");
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
    enum double kWantDx = 2.0;
    float ax, ay, bx, by;
    assert(projectToWindow(pivot, vp, ax, ay)
        && projectToWindow(DHVec3(pivot.x + cast(float)kWantDx, pivot.y, pivot.z),
                           vp, bx, by),
        "rig: the displacement does not project");
    const double pxPerDx = sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));

    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             gx, gy,
                             gx + cast(int)round(pxPerDx * ux),
                             gy + cast(int)round(pxPerDx * uy),
                             12), BASE);
    settle();
    const double dx = modelVerts()[kTarget][0] - before[kTarget][0];

    // Positive control: a grab that MISSED the arrow orbits the camera
    // instead, and then nothing below measures what it claims to.
    assert(dx > 1.5,
        format("the move-arrow grab did not land the displacement: vertex %d "
             ~ "moved %.4f in X, and it must clear the cube's own 1.0 width "
             ~ "for the old and new bucket neighbourhoods to be disjoint",
               kTarget, dx));
    auto camAfter = fetchCamera(BASE);
    assert(fabs(camAfter.eye.x - cam.eye.x) < 1e-3
        && fabs(camAfter.eye.z - cam.eye.z) < 1e-3,
        "the camera moved during the drag — the grab missed the arrow and "
      ~ "orbited instead, which would ALSO re-key the grid (the viewport terms "
      ~ "are part of the key) and make the reading below meaningless");

    cmd("tool.set move off");
    cmd("tool.pipe.attr snap enabled true");
    settle();

    assertGridFollowed(before, "ARM A (gizmo drag)");
}
