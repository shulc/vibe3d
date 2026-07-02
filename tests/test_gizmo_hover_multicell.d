// Task 0212 regression: rotate/scale gizmo hover-highlight flicker.
//
// Pure unittest (no HTTP, no GL) proving the `syncGeometry()` fix. Model:
// tests/test_ai_handle_candidates.d.
//
// Root cause (doc/rotate_scale_hover_flicker_plan.md): RotateHandler's
// `arcX/Y/Z.startAngle` and ScaleHandler's `centerDisk.normal`/`radius` are
// camera-dependent members written ONLY inside `updateGeometry()` (called
// from `draw()`). In a multi-cell (Quad/Split) layout, the shared arbiter's
// Test pass (`ToolHandles.update()`/`.test()`) runs BEFORE the owner
// cell's bank `draw()` for this frame — so it can hit-test against
// geometry a FOREIGN (non-owner) cell's LAST draw left behind under a
// different camera. The fix is `XfrmTransformTool.refreshBankGeometry`
// calling the handler's public `syncGeometry(vp)` forwarder to re-derive
// this camera-dependent state for the OWNER's viewport immediately before
// the arbiter's Test pass runs.
//
// What this test asserts is the fix's actual guarantee: STATELESSNESS /
// IDEMPOTENCE. `syncGeometry(vp)`'s effect on the handler's hit-relevant
// state is a pure function of `vp` alone — independent of whatever camera
// a prior `syncGeometry` call (e.g. a foreign cell's draw) last ran with.
// Concretely: sync to vpA, capture state; sync to a genuinely different
// camera vpB; sync back to vpA; the recaptured state (and the hit-test
// result at a fixed screen point) must be IDENTICAL to the first vpA
// capture. This is what the fix guarantees and what the bug violated
// (before the fix, the arbiter's Test pass ran against whatever a foreign
// cell's last draw left behind). It also sidesteps the fragility of an
// earlier version of this test, which tried to find a specific vpA/vpB
// pair where the stale geometry happened to flip a chosen cursor point
// from a discrete HIT to a discrete MISS — a precondition that doesn't
// hold for every camera pair and isn't what the fix is actually about.
//
// NOTE: a full 180° (opposite-camera) delta is deliberately NOT used for
// vpB — `RotateHandler.applyStart`'s "flip to face camera" correction is
// symmetric under `camFwd -> -camFwd`, so an exact 180° swap cancels out
// and reproduces the SAME startAngle (no divergence to guard against).
// 90° has no such cancellation and is a genuinely different camera.

import std.math : PI, abs, cos, sin;

import handler : RotateHandler, ScaleHandler;
import math : Vec3, Viewport, cross, normalize, projectToWindowFull;
import view : View;

void main() {}

// Same local right/up frame construction as handler.d's PRIVATE `localFrame`
// (deliberately duplicated here — not importable across modules): given a
// plane `normal`, pick a right/up basis so `cos(angle)*right + sin(angle)*up`
// parametrizes the circle in that plane exactly as
// `SemicircleHandler.aiScreenDistance` / `CenterDiskGizmo.diskHitCheck` do.
private void localFrame(Vec3 normal, out Vec3 right, out Vec3 up) {
    Vec3 fwd = normalize(normal);
    Vec3 tmp = abs(fwd.x) < 0.9f ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
    right = normalize(cross(fwd, tmp));
    up    = cross(right, fwd);
}

// Project a point at `angle` on the circle through `center`, perpendicular
// to `normal`, of the given `radius`, into screen space under `vp`.
private bool projectCirclePoint(Vec3 center, Vec3 normal, float radius,
                                float angle, const ref Viewport vp,
                                out float sx, out float sy) {
    Vec3 right, up;
    localFrame(normal, right, up);
    Vec3 world = center + (right * cos(angle) + up * sin(angle)) * radius;
    float z;
    return projectToWindowFull(world, vp, sx, sy, z);
}

private bool vec3Close(Vec3 a, Vec3 b, float eps = 1e-6f) {
    return abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps;
}

unittest { // Rotate ring: syncGeometry() is a pure function of the current viewport
    auto v = new View(0, 0, 800, 600);
    // 90 degrees apart in azimuth (see module doc comment for why not 180).
    Viewport vpA = v.viewportWith(Vec3(0, 0, 0), 3.0f, 0.0f,      0.3f);
    Viewport vpB = v.viewportWith(Vec3(0, 0, 0), 3.0f, PI / 2.0f, 0.3f);

    auto rot = new RotateHandler(Vec3(0, 0, 0));

    // 1. Sync to vpA and capture the FULL hit-relevant state: everything
    //    `SemicircleHandler.hitTest`/`aiScreenDistance` reads.
    rot.syncGeometry(vpA);
    Vec3  centerA = rot.arcX.center;
    Vec3  normalA = rot.arcX.normal;
    float radiusA = rot.arcX.radius;
    float startA  = rot.arcX.startAngle;

    // Fixed screen point: the arc's own midpoint under vpA — guaranteed to
    // lie on the hittable half of the ring for THIS state.
    float midAngle = startA + PI / 2.0f;
    float sx, sy;
    assert(projectCirclePoint(centerA, normalA, radiusA, midAngle, vpA, sx, sy),
           "arc midpoint failed to project under vpA");
    int mx = cast(int)sx, my = cast(int)sy;
    bool hitA = rot.arcX.hitTest(mx, my, vpA);
    assert(hitA, "sanity: cursor should HIT the freshly-synced vpA ring");

    // 2. Simulate a foreign non-owner cell's draw (a real `updateGeometry`
    //    under a genuinely different camera) — the exact write task 0206's
    //    "visual" replica performs, and what the bug left lying around.
    rot.syncGeometry(vpB);

    // 3. The fix: re-sync to vpA immediately before the arbiter's Test pass
    //    — exactly what `XfrmTransformTool.refreshBankGeometry` does.
    rot.syncGeometry(vpA);

    // STATELESSNESS: re-syncing to vpA must fully restore vpA's geometry,
    // regardless of the intervening vpB sync.
    assert(vec3Close(rot.arcX.center, centerA),
           "FIX: center should be identical to the first vpA sync");
    assert(vec3Close(rot.arcX.normal, normalA),
           "FIX: normal should be identical to the first vpA sync");
    assert(abs(rot.arcX.radius - radiusA) < 1e-6f,
           "FIX: radius should be identical to the first vpA sync");
    assert(abs(rot.arcX.startAngle - startA) < 1e-6f,
           "FIX: startAngle should be identical to the first vpA sync "
           ~ "(this is the field the bug left stale from the vpB draw)");
    assert(rot.arcX.hitTest(mx, my, vpA) == hitA,
           "FIX: hit-test result at the fixed cursor point should be "
           ~ "identical to the first vpA sync");

    // PATH-INDEPENDENCE: a FRESH handler synced ONLY to vpA (no vpB
    // history at all) must reach the identical state. Confirms the state
    // is a pure function of the current viewport, not an accumulation of
    // whatever synced before it.
    auto rot2 = new RotateHandler(Vec3(0, 0, 0));
    rot2.syncGeometry(vpA);
    assert(vec3Close(rot2.arcX.center, centerA),
           "path-independence: fresh handler center should match");
    assert(vec3Close(rot2.arcX.normal, normalA),
           "path-independence: fresh handler normal should match");
    assert(abs(rot2.arcX.radius - radiusA) < 1e-6f,
           "path-independence: fresh handler radius should match");
    assert(abs(rot2.arcX.startAngle - startA) < 1e-6f,
           "path-independence: fresh handler startAngle should match");
}

unittest { // Scale center disc: syncGeometry() is a pure function of the current viewport
    auto v = new View(0, 0, 800, 600);
    Viewport vpA = v.viewportWith(Vec3(0, 0, 0), 3.0f, 0.0f,      0.3f);
    Viewport vpB = v.viewportWith(Vec3(0, 0, 0), 3.0f, PI / 2.0f, 0.3f);

    auto sc = new ScaleHandler(Vec3(0, 0, 0));

    // 1. Sync to vpA and capture the FULL hit-relevant state: everything
    //    `CenterDiskGizmo.diskHitCheck` reads (center/normal/radius; no
    //    startAngle on the disc).
    sc.syncGeometry(vpA);
    Vec3  centerA = sc.centerDisk.center;
    Vec3  normalA = sc.centerDisk.normal;
    float radiusA = sc.centerDisk.radius;

    // Fixed screen point: a point near the rim (90% of radius) along the
    // disc's own right-vector under vpA — a genuine hit for THIS state.
    Vec3 rightA, upA;
    localFrame(normalA, rightA, upA);
    Vec3 testPt = centerA + rightA * (radiusA * 0.9f);
    float sx, sy, z;
    assert(projectToWindowFull(testPt, vpA, sx, sy, z),
           "disc rim test point failed to project under vpA");
    int mx = cast(int)sx, my = cast(int)sy;
    bool hitA = sc.centerDisk.hitTest(mx, my, vpA);
    assert(hitA, "sanity: cursor should HIT the freshly-synced vpA disc");

    // 2. Simulate a foreign non-owner cell's draw under a different camera.
    sc.syncGeometry(vpB);

    // 3. The fix: re-sync to vpA immediately before the arbiter's Test pass.
    sc.syncGeometry(vpA);

    // STATELESSNESS: re-syncing to vpA must fully restore vpA's geometry,
    // regardless of the intervening vpB sync.
    assert(vec3Close(sc.centerDisk.center, centerA),
           "FIX: center should be identical to the first vpA sync");
    assert(vec3Close(sc.centerDisk.normal, normalA),
           "FIX: normal should be identical to the first vpA sync "
           ~ "(this is the field the bug left stale from the vpB draw)");
    assert(abs(sc.centerDisk.radius - radiusA) < 1e-6f,
           "FIX: radius should be identical to the first vpA sync");
    assert(sc.centerDisk.hitTest(mx, my, vpA) == hitA,
           "FIX: hit-test result at the fixed cursor point should be "
           ~ "identical to the first vpA sync");

    // PATH-INDEPENDENCE: a FRESH handler synced ONLY to vpA must reach the
    // identical state.
    auto sc2 = new ScaleHandler(Vec3(0, 0, 0));
    sc2.syncGeometry(vpA);
    assert(vec3Close(sc2.centerDisk.center, centerA),
           "path-independence: fresh handler center should match");
    assert(vec3Close(sc2.centerDisk.normal, normalA),
           "path-independence: fresh handler normal should match");
    assert(abs(sc2.centerDisk.radius - radiusA) < 1e-6f,
           "path-independence: fresh handler radius should match");
}
