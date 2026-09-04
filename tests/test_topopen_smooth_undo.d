// Topology Pen P8 — smooth_undo (T3, doc/topopen_p8_smooth_plan.md
// "Testing Strategy").
//
// A multi-pass Shift+Ctrl+LMB DRAG (several relax passes, deferred to
// release) commits as ONE atomic undo entry — a single /api/undo restores
// every vertex to its EXACT pre-gesture position, proving the N-pass
// gesture coalesces into one entry rather than the reference's own
// per-pass multi-entry undo (the plan's one deliberate, flagged
// divergence). REV1 FIX-1: uses plain /api/undo (the proven pattern in
// test_topopen_move_undo_redo.d), NOT the keyboard Ctrl+Z play-events
// path — for a POST-COMMIT undo the keyboard path's extra
// `resyncSession()` only clears already-reset tool booleans and never
// touches vertex data, so the two are equivalent here.
//
// RIG NOTE (reference-parity kernel, doc/tasks/work/0478-topopen-smooth-kernel.md):
// this test used to run on `/api/reset`'s default cube. It cannot any more —
// and the reason is a property of the measured relaxation law, not a defect.
// That law accumulates, for each vertex, its own edge-perpendicular force AND
// an equal-and-opposite reaction from every neighbour. On a perfectly regular
// mesh those two cancel EXACTLY: a unit cube is a fixed point, moving 0.0
// (not merely a little) for any strength and any number of iterations. The
// old inverse-edge-length law instead contracted the cube toward its
// centroid, which is what used to make this rig move.
//
// The assertions below are UNCHANGED — one gesture, one undo entry, exact
// restore. Only the rig is swapped for an irregular hexahedron with the same
// 8/12/6 topology, which relaxes ~0.15 world units over this drag. Weakening
// the movement threshold instead would have hidden the fixed-point property
// rather than accommodating it.
//
// Run via: ./run_test.d topopen_smooth_undo

import http_command_helpers : commandBody;
import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

enum uint SHIFT_CTRL = 0x0001 | 0x0040;   // KMOD_LSHIFT | KMOD_LCTRL

Vec3 toVec3(double[3] v) { return Vec3(cast(float)v[0], cast(float)v[1], cast(float)v[2]); }

bool vecApproxEq(Vec3 a, Vec3 b, float eps) {
    Vec3 d = a - b;
    return dot(d, d) < eps * eps;
}

// An IRREGULAR closed hexahedron: a unit cube with the (1,1,1) corner pulled
// out to (1.8,1.3,1.1). Same 8 vertices / 12 edges / 6 faces as the default
// cube, so every topology assertion below is unchanged — but see the rig note
// in this file's header for why the default cube itself cannot be used.
string irregularHexBody() {
    return `{"vertices":[[-1,-1,-1],[1,-1,-1],[1,1,-1],[-1,1,-1],`
         ~ `[-1,-1,1],[1,-1,1],[1.8,1.3,1.1],[-1,1,1]],`
         ~ `"faces":[[0,3,2,1],[4,5,6,7],[0,1,5,4],[2,3,7,6],[1,2,6,5],[0,4,7,3]]}`;
}

unittest {
    postJson("/api/reset", "");   // single layer == primary (layer 0)

    auto lr = postJson("/api/command", commandBody("scene.loadMesh", irregularHexBody()));
    assert(lr["status"].str == "ok", "load-mesh (irregular hexahedron) failed: " ~ lr.toString);

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));
    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;

    Vec3[] pre;
    foreach (v; readVerticesLayer(0)) pre ~= toVec3(v);
    auto historyBefore = historySurfaceCounts();

    cmd("tool.set mesh.topoPen on");

    // A genuine multi-step drag (>1 pass) over the irregular hexahedron. No
    // background layer exists here (single-layer scene), so this exercises
    // pure relaxation (no re-snap) — T1 elsewhere covers the re-snap crux.
    auto pr = postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, cx + 120, cy + 40, 8, SHIFT_CTRL, 1));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12 && faceCountLayer(0) == 6,
        "Smooth must never change topology (zero delta)");

    Vec3[] post;
    foreach (v; readVerticesLayer(0)) post ~= toVec3(v);
    bool anyMoved = false;
    foreach (i; 0 .. post.length)
        if (!vecApproxEq(pre[i], post[i], 1e-5f)) anyMoved = true;
    assert(anyMoved, "setup: the multi-step drag must have genuinely relaxed at least one vertex");

    // Classify rows instead of adding one blindly for the lifecycle surface
    // measured in `toolcards/undo_surfaces/`.  This Topology Pen gesture owns
    // one coalesced edit row, while arming the pen owns one lifecycle row; a
    // total-depth expectation cannot distinguish those classes.
    auto historyAfter = historySurfaceCounts();
    assert(historyAfter.editRows == historyBefore.editRows + 1,
        format("one multi-pass Smooth gesture must add EXACTLY ONE edit row; edit rows went %d -> %d",
               historyBefore.editRows, historyAfter.editRows));
    assert(historyAfter.lifecycleRows == historyBefore.lifecycleRows + 1,
        format("arming Topology Pen must add EXACTLY ONE lifecycle row; got %d",
               historyAfter.lifecycleRows - historyBefore.lifecycleRows));

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);

    Vec3[] restored;
    foreach (v; readVerticesLayer(0)) restored ~= toVec3(v);
    foreach (i, v; restored)
        assert(vecApproxEq(pre[i], v, 1e-5f),
            format("ONE undo must restore vertex %d to its EXACT pre-gesture position", i));
}
