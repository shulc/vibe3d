// Task 1906 stage 2c (plan §3.3 row 9) — THE SYMMETRY PAIRING CACHE AFTER A
// VERSION-SILENT GIZMO DRAG.
//
// ===========================================================================
// WHAT THE CACHE IS AND WHY A POSITION CHANGE INVALIDATES IT
// ===========================================================================
// `SymmetryStage.evaluate` publishes a per-vertex `pairOf` table, and
// `symmetry.rebuildPairing` computes it by GEOMETRIC SEARCH: for each vertex,
// look for a partner within `epsilonWorld` of that vertex's position mirrored
// through the plane. So the table is a pure function of vertex POSITIONS —
// move one vertex and its partner is a different vertex, or none at all.
//
// Until stage 2c the staleness key was `(cachedMeshAddr_,
// cachedMutationVersion_)`, propped up by `app.d`'s frame flush reaching in
// and calling `invalidatePairingCache()` on any `Position` frame. An
// interactive gizmo Move/Rotate/Scale is version-silent — `mutationVersion`
// moves neither at the drag steps nor at the commit (CLAUDE.md, "The exception
// that breaks version-keying") — so the version half never saw the gesture,
// and the manual half was a second, subject-less channel every future
// publisher had to remember. Stage 2c replaces both with the change bus's own
// per-address geometry epoch (`mesh_dirty.g_geomEpochs`), compared inside
// `evaluate` at the lazy rebuild.
//
// ===========================================================================
// THE RIG, AND THE TWO REFUSALS IN IT
// ===========================================================================
// The observable is `/api/toolpipe/eval`'s `symmetry.pairOf` — the published
// packet's array, i.e. the cache itself, not a re-derivation of it.
//
//   * SYMMETRY IS OFF FOR THE DISPLACEMENT, and that is what makes the rig
//     discriminate at all. The `/api/select` of v6 runs while symmetry is
//     still armed, so the selection already contains its partner v7 and both
//     corners translate by the SAME delta (measured: v6 [1.5,…], v7 [0.5,…]);
//     disabling symmetry keeps the PAIRING from being re-driven, and the
//     post-drag configuration is asymmetric either way — with symmetry ON the
//     pair table would be re-derived and a stale cache and a fresh one would
//     agree. Toggling `enabled` does not drop the cache
//     (`applySetAttr` writes the bool and publishes state, nothing else) and
//     `evaluate` returns early while disabled, so the table survives the
//     toggle untouched. That is exactly the state this file needs.
//   * NO `/api/reset` BETWEEN THE BUILD AND THE READ. `SceneReset` runs
//     `resetAllPipeStages()`, and `SymmetryStage.reset()` clears the pair
//     table outright — which would rescue the broken code. Each arm resets
//     ONCE, at its start.
//
// WHAT THIS FILE DOES NOT PIN. It is GREEN on the pre-2c tree (measured in the
// 2c review): there the manual `invalidatePairingCache()` call from app.d's frame
// flush held the pair table correct, and the version key was dead weight beside it.
// Both arms redden only when the version key is restored WITHOUT that manual
// call. So this file pins the REPLACEMENT — that the epoch alone carries the
// load — not a bug a user could see before 2c.
//
// NOT A CALL-COUNT CHECK. A stale pair table is published exactly as often as
// a fresh one, through the same code path, with the same packet shape. The
// only observable that separates them is WHAT IS IN IT.
//
// Run via: ./run_test.d test_bus_symmetry_pairing_after_drag

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

/// `/api/model` vertex `idx`.
double[3] vpos(int idx) {
    auto v = getJson("/api/model")["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

/// The LIVE published pairing table — `SymmetryStage`'s `cachedPairOf_`, as
/// `evaluate` put it on the packet.
int[] pairOfNow() {
    auto j = getJson("/api/toolpipe/eval");
    assert("symmetry" in j, "/api/toolpipe/eval has no symmetry block: " ~ j.toString);
    int[] o;
    foreach (e; j["symmetry"]["pairOf"].array) o ~= cast(int)e.integer;
    return o;
}

/// reset → X-symmetry on → build the pair table and assert it is the cube's.
///
/// The expected table is spelled out rather than re-derived: `makeCube`'s
/// corners are v0..v7 with X = ∓0.5 in index pairs (0,1) (3,2) (4,5) (7,6),
/// so an X = 0 mirror pairs exactly those. If `makeCube` ever changes, this
/// premise fails loudly here instead of the arms below measuring something
/// else.
void armAndBuildPairing() {
    postJson("/api/reset", "");
    auto r = post(BASE ~ "/api/script",
        "tool.pipe.attr symmetry enabled true\n"
      ~ "tool.pipe.attr symmetry axis x\n"
      ~ "tool.pipe.attr symmetry offset 0\n");
    assert(parseJSON(cast(string)r)["status"].str == "ok",
        "symmetry config failed: " ~ cast(string)r);
    settle();

    auto p = pairOfNow();
    assert(p == [1, 0, 3, 2, 5, 4, 7, 6],
        format("PREMISE: X-symmetry on the reset cube must pair "
             ~ "(0,1)(3,2)(4,5)(7,6) — this evaluate is what BUILDS the cache "
             ~ "whose staleness the arms below measure. Got %s", p.to!string));
}

/// After a displacement that moved v6 off v7's mirror position, the pair table
/// must say so. `arm` names the mechanism that produced the displacement.
void assertPairingFollowed(string arm) {
    auto p = pairOfNow();
    writefln("[symm pairing] %s: pairOf=%s  v6=%s v7=%s",
             arm, p.to!string, vpos(6).to!string, vpos(7).to!string);

    assert(p.length == 8,
        format("%s: the packet must still carry a full 8-entry pair table; "
             ~ "got %s. A short or empty table means symmetry went OFF, and "
             ~ "then the -1s below would mean nothing", arm, p.to!string));

    // The in-arm control: two pairs NOTHING touched. They are +1/-1 partners
    // under both a stale and a fresh table, so they say "symmetry is on and
    // the search really ran" without saying anything about freshness. Without
    // them, the two -1 asserts below are satisfied by symmetry being broken.
    assert(p[0] == 1 && p[1] == 0 && p[4] == 5 && p[5] == 4,
        format("%s: the UNTOUCHED corners must still be paired — v0<->v1 and "
             ~ "v4<->v5 were not moved by anything in this file. Got %s; if "
             ~ "these are -1 the mirror search is failing for a reason that "
             ~ "has nothing to do with cache freshness", arm, p.to!string));

    assert(p[6] == -1,
        format("%s: v6 was moved to %s, so its mirror position has no vertex "
             ~ "within epsilon and pairOf[6] must be -1. Got %d — the pair "
             ~ "table is the PRE-displacement one, still mirroring v6 onto a "
             ~ "partner that is no longer there. Full table: %s",
               arm, vpos(6).to!string, p[6], p.to!string));

    assert(p[7] == -1,
        format("%s: v7 is at %s and the vertex that used to sit at its "
             ~ "mirror position moved away, so pairOf[7] must be -1. Got %d "
             ~ "— the stale table still pairs it with v6. Full table: %s",
               arm, vpos(7).to!string, p[7], p.to!string));
}

// ===========================================================================
// ARM B — THE MANDATORY NEGATIVE CONTROL, AND IT RUNS FIRST. The same rig and
// the same displacement, driven by `/api/transform` → `mesh.transform`, whose
// kernel calls `commitChange(Position)` and BUMPS `mutationVersion`. A version
// key catches that, so this arm was green before stage 2c and must STAY green:
// if a mutation aimed at ARM A reddens this block too, the rig is measuring
// the pairing machinery rather than the version-silent path.
//
// FIRST, and the order is the whole point of having it: druntime stops a
// MODULE at its first failed assert, so with ARM A above it this block would
// never execute under exactly the mutation it exists to answer for, and its
// silence would be indistinguishable from a pass.
// ===========================================================================
unittest {
    armAndBuildPairing();

    auto selR = postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[6]}`));
    assert(selR["status"].str == "ok", "select failed: " ~ selR.toString);

    // Symmetry OFF for the displacement — see the header. With it on, the
    // mirror would carry v7 along and the table would stay correct.
    cmd("tool.pipe.attr symmetry enabled false");

    const double x0 = vpos(6)[0];
    auto trR = postJson("/api/command", commandBody("mesh.transform", `{"kind":"translate","delta":[1.0,0,0]}`));
    assert("error" !in trR, "/api/transform failed: " ~ trR.toString);
    const double dx = vpos(6)[0] - x0;
    assert(dx > 0.5,
        format("the scripted translate moved v6 by %.4f in X; it must clear "
             ~ "the pairing epsilon by orders of magnitude", dx));

    cmd("tool.pipe.attr symmetry enabled true");
    settle();

    assertPairingFollowed("ARM B (scripted mesh.transform)");
}

// ===========================================================================
// ARM A — THE REAL GIZMO DRAG. Version-silent on Position: `mutationVersion`
// does not move, at the drag steps OR at the commit, which is exactly why the
// pairing cache's old version key could not see it.
// ===========================================================================
unittest {
    armAndBuildPairing();

    auto selR = postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[6]}`));
    assert(selR["status"].str == "ok", "select failed: " ~ selR.toString);

    cmd("tool.pipe.attr symmetry enabled false");
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
    enum double kWantDx = 1.0;
    float ax, ay, bx, by;
    assert(projectToWindow(pivot, vp, ax, ay)
        && projectToWindow(DHVec3(pivot.x + cast(float)kWantDx, pivot.y, pivot.z),
                           vp, bx, by),
        "rig: the displacement does not project");
    const double pxPerDx = sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));

    const double x0 = vpos(6)[0];
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             gx, gy,
                             gx + cast(int)round(pxPerDx * ux),
                             gy + cast(int)round(pxPerDx * uy),
                             12), BASE);
    settle();
    const double dx = vpos(6)[0] - x0;

    // Positive control: a grab that MISSED the arrow orbits the camera
    // instead, and then nothing below measures what it claims to.
    assert(dx > 0.5,
        format("the move-arrow grab did not land the displacement: v6 moved "
             ~ "%.4f in X, and it must clear v7's mirror position by far more "
             ~ "than the 1e-4 pairing epsilon", dx));
    auto camAfter = fetchCamera(BASE);
    assert(fabs(camAfter.eye.x - cam.eye.x) < 1e-3
        && fabs(camAfter.eye.z - cam.eye.z) < 1e-3,
        "the camera moved during the drag — the grab missed the arrow and "
      ~ "orbited instead, so the reading below is meaningless");

    cmd("tool.set move off");
    cmd("tool.pipe.attr symmetry enabled true");
    settle();

    assertPairingFollowed("ARM A (gizmo drag)");
}
