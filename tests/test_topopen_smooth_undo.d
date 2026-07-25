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
// Run via: ./run_test.d topopen_smooth_undo

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

unittest {
    postJson("/api/reset", "");   // default cube, single layer == primary (layer 0)

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));
    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;

    Vec3[] pre;
    foreach (v; readVerticesLayer(0)) pre ~= toVec3(v);
    int undoDepthBefore = cast(int) getJson("/api/history")["undo"].array.length;

    cmd("tool.set mesh.topoPen on");

    // A genuine multi-step drag (>1 pass) over the default cube. No
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

    int undoDepthAfter = cast(int) getJson("/api/history")["undo"].array.length;
    assert(undoDepthAfter == undoDepthBefore + 1,
        format("one multi-pass Smooth gesture must record EXACTLY ONE undo entry; depth went %d -> %d",
               undoDepthBefore, undoDepthAfter));

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);

    Vec3[] restored;
    foreach (v; readVerticesLayer(0)) restored ~= toVec3(v);
    foreach (i, v; restored)
        assert(vecApproxEq(pre[i], v, 1e-5f),
            format("ONE undo must restore vertex %d to its EXACT pre-gesture position", i));
}
