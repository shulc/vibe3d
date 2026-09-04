// Topology Pen P0 (doc/topopen_p0_plan.md) — golden-fixture Tier B:
// version-invalidation. Not expressible in the single-raycast-per-case
// runSurfaceRaycastSuite schema (it needs TWO raycasts around a mesh
// mutation), so this is a direct, hand-written HTTP-driving test rather
// than a JSON fixture.
//
// This test exercises the `_bgBvh` mutationVersion cache via
// `constrain.d`'s shared `bgSurfaceRayHit` helper — SCREEN mode's own
// values are asserted here, but the cache is shared with Point mode too
// (both dispatch through the same helper: Point mode's placement seed is
// now the camera-ray hit, per a live cross-engine differential against the reference editor —
// see constrain.d's `pointNearestFootBackground`), so Point mode is
// subject to the identical invalidation behavior, just not separately
// re-asserted here. Uses `geometry screen` (this was always a camera-ray
// probe, unaffected by the placement-seed fix); values unchanged.
//
// Recipe:
//   1. Two-layer scene: layer0 = cube (primary), layer1 = cube (background,
//      visible). CONS enabled, geometry=screen.
//   2. Camera focus = the TOP FACE centre of layer1's cube (0, 0.5, 0) —
//      the "focus-point trick" (see topo_pen_surface_raycast.json's
//      provenance notes) guarantees the centre-pixel ray lands there
//      exactly. Raycast #1: assert hit at Y ~ 0.5.
//   3. Promote layer1 to primary (layer.select index:1 — layer0 becomes
//      background in its place), select all its vertices and translate
//      them by TY=2 via POST /api/transform (kind:"translate"), then
//      demote back to background (layer.select index:0). The mesh's
//      Layer is a class with a STABLE heap address (project convention),
//      so ConstrainStage's per-mesh-address BvhPick cache entry for
//      layer1 is the SAME cache entry across this select/select-back —
//      this is exactly the aliasing scenario `mutationVersion` keying
//      must catch.
//
//      /api/transform is used rather than the interactive move gizmo
//      DELIBERATELY: an interactive gizmo Move/Rotate/Scale is
//      version-silent on Position (it fires the change-notification bus
//      + bumps gpu.uploadVersion but does NOT bump mesh.mutationVersion —
//      a documented, systemic property covering several OTHER caches
//      too, not something this test should also trip over).
//      commands/mesh/transform.d's MeshTransform DOES call
//      `mesh.commitChange(MeshEditScope.Position)`, which unconditionally
//      bumps mutationVersion — the exact signal BvhPick.pickSurfaceRay's
//      cache key is designed to react to (REV-3: this is the SURFACE-pick
//      cache's own key, independent of pickFace's uploadVersion). It also
//      never touches CONS's projection post-pass (that lives in
//      xfrm_transform.d's applyTRS only), so there's no cross-feature
//      contamination to route around either.
//   4. NEW camera call, SAME azimuth/elevation/distance but focus
//      recalibrated to the NEW expected top-face centre (0, 2.5, 0) (the
//      cube moved by +2 in Y; X/Z unchanged). Raycast #2: assert hit at
//      Y ~ 2.5 — a STALE (un-rebuilt) surface-pick cache would instead
//      report the OLD (Y ~ 0.5) geometry (or a near-miss/drifted point),
//      never Y ~ 2.5.
//
// Run via: ./run_test.d topology_pen_version_invalidation

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math  : fabs;
import std.format: format;

void main() {}

alias baseUrl = testBaseUrl;


void cmd(string argstring) {
    auto j = postJson("/api/command", argstring);
    assert(j["status"].str == "ok",
        "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
}

string cubeMeshBody() {
    return `{
        "vertices":[[-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[0.5,0.5,-0.5],[-0.5,0.5,-0.5],
                    [-0.5,-0.5,0.5],[0.5,-0.5,0.5],[0.5,0.5,0.5],[-0.5,0.5,0.5]],
        "faces":[[0,3,2,1],[4,5,6,7],[0,4,7,3],[1,2,6,5],[3,7,6,2],[0,1,5,4]]
    }`;
}

void setCamera(double az, double el, double dist, double fx, double fy, double fz) {
    auto r = postJson("/api/camera",
        format(`{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,`
             ~ `"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
               az, el, dist, fx, fy, fz));
    assert("error" !in r, "/api/camera failed: " ~ r.toString);
}

JSONValue raycast(int x, int y) {
    return getJson(format("/api/surface-raycast?x=%d&y=%d", x, y));
}

bool approx(double a, double b, double eps = 0.02) { return fabs(a - b) < eps; }

enum int CX = 475, CY = 300;

unittest {
    postJson("/api/reset", "");

    cmd("tool.pipe.attr constrain enabled true");
    cmd("tool.pipe.attr constrain geometry screen");

    cmd("layer.add name:Bg");
    auto lr = postJson("/api/command", commandBody("scene.loadMesh", cubeMeshBody()));
    assert(lr["status"].str == "ok", "load-mesh failed: " ~ lr.toString);
    cmd("layer.setVisible index:1 value:true");
    cmd("layer.select index:0");   // layer0 primary, layer1 background

    setCamera(0.4, 0.6, 4.0, 0.0, 0.5, 0.0);

    auto r1 = raycast(CX, CY);
    assert(r1["hit"].boolean == true, "raycast #1: expected a hit; got " ~ r1.toString);
    assert(approx(r1["point"].array[1].floating, 0.5),
        "raycast #1: expected top-face Y~0.5; got " ~ r1.toString);
    assert(r1["layer"].integer == 1, "raycast #1: expected Document layer 1");

    // Promote layer1 to primary, select all 8 verts, translate by TY=2 via
    // /api/transform (mutationVersion-correct — see the file header), then
    // demote back to background.
    cmd("layer.select index:1");   // layer1 primary now (layer0 becomes background)
    auto selR = postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`));
    assert(selR["status"].str == "ok", "select failed: " ~ selR.toString);
    auto trR = postJson("/api/command", commandBody("mesh.transform", `{"kind":"translate","delta":[0,2,0]}`));
    assert("error" !in trR, "/api/transform failed: " ~ trR.toString);
    cmd("layer.select index:0");   // back to: layer0 primary, layer1 background

    // Recalibrate the camera's focus to the NEW expected top-face centre
    // (same azimuth/elevation/distance — only the focus point moves, by
    // exactly the +2 Y the mesh itself moved).
    setCamera(0.4, 0.6, 4.0, 0.0, 2.5, 0.0);

    auto r2 = raycast(CX, CY);
    assert(r2["hit"].boolean == true, "raycast #2: expected a hit; got " ~ r2.toString);
    assert(approx(r2["point"].array[1].floating, 2.5),
        "raycast #2: expected top-face Y~2.5 (surface-pick cache must have "
        ~ "rebuilt after the mutationVersion bump) — got " ~ r2.toString);
    assert(r2["layer"].integer == 1, "raycast #2: expected Document layer 1");
}
