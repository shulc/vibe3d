// Topology Pen P10 — moveloop_resnap (Tier-C, doc/topopen_p10_moveloop_plan.md
// "Testing strategy").
//
// A plain RMB-drag on an INTERIOR edge of a small quad grid, over a curved
// (sphere) background: the drag gathers the classic in-line edge-loop chain
// through the seed edge (REV1 FIX-1 — `Mesh.selectLoopEdges`, the middle
// ROW of the grid), then re-snaps EACH loop vertex onto the sphere surface
// independently. Every OTHER grid vertex (outside the loop) must stay
// byte-unchanged, and the primary layer's topology (vertex/edge/face counts)
// must not change (δ=0).
//
// TASK 0503 — WHAT THE RE-SNAP IS. This file used to assert the camera-ray
// hit at each vertex's own shifted pixel, which was the port's law and is
// measured wrong. The reference takes the NEAREST POINT on the background
// facet, clamped to that facet:
//
//   * dupedge_resnap_capture.md, contract C-2, cells A5-TILT30 / A1-TILT
//     (two boots) / A6-TILT60 — |new edge|/|source edge| = cos(tilt) to
//     2.9e-7, where a per-vertex ray predicts 1.804 / 2.484 / 4.369;
//     cell A0-FLAT — 1.000 against the ray law's 1.220 on a FLAT background;
//   * addloop_bgresnap_undo_capture.md, verdict V-1, cells AL-BG-1/2/MID/RAY
//     — every inserted vertex on the background plane to 1.1e-09…7.6e-09 D,
//     matching the perpendicular foot to 5.36e-09 D against 5.75e-03 D for
//     the ray.
//
// So the expectation here is `expectedNearestOnSphere` — this suite's own
// nearest-foot solve against the sphere's OWN FACETS, computed from scratch,
// never a second call into the code under test. (The facets, not the ideal
// sphere: see that helper's own note.) The tilted-background fixture that
// makes the two laws differ loudly lives in the pen's own module unittests
// (`tests/unit/tools/edit/topology_pen/gestures_test.d`) — a sphere
// background cannot show a cos(tilt) ratio.
//
// Run via: ./run_test.d topopen_moveloop_resnap

import topopen_place_helpers;
import std.json;
import std.math   : abs, sqrt;
import std.format : format;

void main() {}

enum float  R   = 2.0f;
enum int    LON = 96, LAT = 72;   // resolution rationale: topopen_place_helpers.d
enum double TOL = R * 0.04;       // covers the mesh-resolution note there
enum float  GRID_HALF = 0.6f;     // grid extent, kept well inside the sphere's silhouette

// A 3x3 quad-grid patch (matches source/mesh.d:makeGridPlane(2)'s own
// row-major layout, index(i,j) = i*3+j) at y=0, half-extent GRID_HALF, so
// the middle row (verts 3,4,5) is an easy hand-known interior seed.
string gridPatchBody() {
    Vec3[9] v;
    foreach (i; 0 .. 3) foreach (j; 0 .. 3) {
        float x = -GRID_HALF + GRID_HALF * cast(float)j;
        float z = -GRID_HALF + GRID_HALF * cast(float)i;
        v[i * 3 + j] = Vec3(x, 0, z);
    }
    string vertsJson;
    foreach (k, p; v) {
        if (k) vertsJson ~= ",";
        vertsJson ~= format(`[%.6f,%.6f,%.6f]`, p.x, p.y, p.z);
    }
    // CCW quads viewed from +Y, mirroring makeGridPlane's own winding.
    string facesJson = "[0,1,4,3],[1,2,5,4],[3,4,7,6],[4,5,8,7]";
    return format(`{"vertices":[%s],"faces":[%s]}`, vertsJson, facesJson);
}

unittest {
    setupSphereBg(R, LON, LAT);

    auto lr = postJson("/api/load-mesh", gridPatchBody());
    assert(lr["status"].str == "ok", "load-mesh (grid patch) failed: " ~ lr.toString);
    assert(vertexCountLayer(1) == 9 && edgeCountLayer(1) == 12 && faceCountLayer(1) == 4,
        "setup: primary layer must be the untouched 3x3 grid patch");

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));
    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);

    // Grid vertex world positions (matches gridPatchBody's own layout).
    Vec3[9] gridPos;
    foreach (i; 0 .. 3) foreach (j; 0 .. 3) {
        float x = -GRID_HALF + GRID_HALF * cast(float)j;
        float z = -GRID_HALF + GRID_HALF * cast(float)i;
        gridPos[i * 3 + j] = Vec3(x, 0, z);
    }

    float s3x, s3y, s4x, s4y;
    assert(projectToWindow(gridPos[3], vp, s3x, s3y), "setup: v3 must project on-screen");
    assert(projectToWindow(gridPos[4], vp, s4x, s4y), "setup: v4 must project on-screen");
    int downX = cast(int)((s3x + s4x) * 0.5f);
    int downY = cast(int)((s3y + s4y) * 0.5f);   // seed-edge midpoint -> a valid RMB-down pick

    int upX = downX + 40, upY = downY - 25;   // a modest drag, well within the sphere's silhouette
    int dx  = upX - downX, dy = upY - downY;

    cmd("tool.set mesh.topoPen on");

    auto pr = postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, downX, downY, upX, upY, 16, 0, 3));
    assert("error" !in pr, "RMB drag failed: " ~ pr.toString);
    waitPlayerIdle();

    // δ=0 — Move Loop never adds/removes geometry.
    assert(vertexCountLayer(1) == 9 && edgeCountLayer(1) == 12 && faceCountLayer(1) == 4,
        "Move Loop must never change the primary layer's topology");
    assert(vertexCountLayer(0) == sphereVertexCount(LON, LAT), "bg vertex count must be unchanged");

    auto post = readVerticesLayer(1);

    // The 3 loop vertices (3, 4, 5 — the middle row) must each land at the
    // INDEPENDENTLY-computed NEAREST POINT on the sphere's facets, taken
    // from THEIR OWN drag-shifted world point.
    foreach (vi; [3, 4, 5]) {
        Vec3 expected;
        assert(expectedNearestOnSphere(c, gridPos[vi], dx, dy, R, LON, LAT, expected),
            format("setup: v%d must project on-screen to have a shifted point at all", vi));
        assert(approxVec(expected, post[vi], TOL),
            format("loop vertex %d %s should match the independently-computed nearest point "
                 ~ "on the background facets (%f,%f,%f)",
                   vi, post[vi], expected.x, expected.y, expected.z));

        double dist = sqrt(post[vi][0]*post[vi][0] + post[vi][1]*post[vi][1] + post[vi][2]*post[vi][2]);
        assert(abs(dist - R) < TOL, format("loop vertex %d must lie on the sphere surface", vi));
    }

    // Every OTHER grid vertex (outside the gathered loop) must stay
    // byte-unchanged — the loop-gather is scoped to the in-line chain
    // only, never the whole mesh.
    foreach (vi; [0, 1, 2, 6, 7, 8])
        assert(approxVec(gridPos[vi], post[vi], 1e-5),
            format("non-loop vertex %d must stay exactly at its original position", vi));

    // Consecutive loop-vertex spacing must not collapse toward a point —
    // the failure mode this guards is an implementation that averaged or
    // interpolated instead of writing every target verbatim.
    //
    // TASK 0503: the old UPPER band (3x pre-drag) was a property of the
    // camera ray, not of the loop. A nearest-foot re-snap taken from INSIDE
    // the sphere pushes each vertex out radially, magnifying every
    // separation by roughly R/|q| — inherent geometry, not a defect, and the
    // exact post-drag positions are already pinned per-vertex above. What
    // replaces it is a real invariant rather than a calibrated one: two
    // points that both lie on a sphere of radius R cannot be farther apart
    // than its diameter.
    double preD01 = sqrt(cast(double)dot(gridPos[4] - gridPos[3], gridPos[4] - gridPos[3]));
    Vec3 p3 = toVec3(post[3]), p4 = toVec3(post[4]), p5 = toVec3(post[5]);
    double postD01 = sqrt(cast(double)dot(p4 - p3, p4 - p3));
    double postD12 = sqrt(cast(double)dot(p5 - p4, p5 - p4));
    assert(postD01 > preD01 * 0.3 && postD01 < 2.0 * R,
        format("consecutive spacing (3-4) must not collapse, and cannot exceed the sphere's "
             ~ "diameter; pre=%f post=%f", preD01, postD01));
    assert(postD12 > preD01 * 0.3 && postD12 < 2.0 * R,
        format("consecutive spacing (4-5) must not collapse, and cannot exceed the sphere's "
             ~ "diameter; pre=%f post=%f", preD01, postD12));
}

Vec3 toVec3(double[3] v) { return Vec3(cast(float)v[0], cast(float)v[1], cast(float)v[2]); }
