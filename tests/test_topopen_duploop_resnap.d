// Topology Pen P11 — duploop_resnap (Tier-C, doc/topopen_p11_duploop_plan.md
// "Testing strategy").
//
// A Shift+RMB-drag on a BOUNDARY edge of a small quad grid, over a curved
// (sphere) background: the drag duplicates the border RUN through that seed
// into new quads (`Mesh.extendEdgesByMask`, identity TRS), then re-snaps EACH
// new (tail) vertex onto the sphere surface independently. The primary
// layer's topology must grow by the computed border-run delta (+3v/+5e/+2f),
// the original 9 grid vertices must stay byte-unchanged, and each new vertex
// must match exactly one of the 3 independently-computed expected targets (a
// bijective set match — the exact new-vertex INDEX ordering is an internal
// kernel detail, not part of the tool's contract).
//
// TASK 0503 — WHAT THE RE-SNAP IS. This file used to assert the camera-ray
// hit at each source vertex's own shifted pixel. That was the port's law and
// it is measured wrong on THIS VERY GESTURE: dupedge_resnap_capture.md's
// cell A is a Duplicate, and it measures |new edge|/|source edge| = cos(tilt)
// at 30/45/60 degrees to 2.9e-7 where a per-vertex ray predicts
// 1.804 / 2.484 / 4.369 (contract C-2), plus 1.000 against the ray law's
// 1.220 on a FLAT background (cell A0-FLAT). Add Loop's own capture
// (addloop_bgresnap_undo_capture.md, verdict V-1) puts the same
// perpendicular-foot law on a second gesture and a second rig, to
// 5.36e-09 D against 5.75e-03 D for the ray.
//
// The expectation is therefore `expectedNearestOnSphere` — this suite's own
// nearest-foot solve against the sphere's OWN FACETS, from scratch, never a
// second call into the code under test. The tilted-background fixture where
// the two laws differ loudly is in `source/tools/edit/topology_pen.d`'s own
// unittests; a sphere cannot show a cos(tilt) ratio.
//
// Also measured on this gesture and NOT asserted here, deliberately: the
// reference feeds the query `src_i + Δ` with ONE 3D offset shared by every
// new vertex, where this port shifts each vertex's own pixel by a shared
// SCREEN delta (a depth-dependent world delta). The two agree whenever the
// moving vertices share a view depth — as they do on every rig either
// capture ran — and Δ's own law is explicitly not established, so porting it
// would mean inventing it. See `shiftedWorldPoint` in the tool.
//
// TASK 0486: this test used to assert the FULL CLOSED RIM (+8v/+16e/+8f) on
// the strength of an owner observation recorded at the time. A live capture
// of the reference refuted it (`dragweld_dupedge_loopscope_capture.md`): the
// gather is indeed the whole perimeter, but the COMMITTED set is the border
// run through the seed, stopping at the chain-end vertices with a single
// incident polygon — the patch corners. On this 3x3 grid the seed 0-1 run is
// {0-1, 1-2}, i.e. the top row, and the two corners 0 and 2 end it. The rim
// reading is exactly the owner's later "it takes all edges" report.
//
// Run via: ./run_test.d topopen_duploop_resnap

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
// row-major layout, index(i,j) = i*3+j) at y=0, half-extent GRID_HALF — the
// boundary rim is verts {0,1,2,3,5,6,7,8} (every vertex but the untouched
// center, 4), an 8-edge closed perimeter.
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

double distSq(Vec3 a, Vec3 b) { Vec3 d = a - b; return cast(double)dot(d, d); }

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

    // Boundary seed: edge 0-1, a genuine top-row perimeter edge. Its trimmed
    // run is the top row {0-1, 1-2}: vertex 0 and vertex 2 are patch corners
    // (one incident polygon each) and stop the walk in each direction.
    float s0x, s0y, s1x, s1y;
    assert(projectToWindow(gridPos[0], vp, s0x, s0y), "setup: v0 must project on-screen");
    assert(projectToWindow(gridPos[1], vp, s1x, s1y), "setup: v1 must project on-screen");
    int downX = cast(int)((s0x + s1x) * 0.5f);
    int downY = cast(int)((s0y + s1y) * 0.5f);   // seed-edge midpoint -> a valid Shift+RMB-down pick

    int upX = downX + 35, upY = downY - 20;   // a modest drag, well within the sphere's silhouette
    int dx  = upX - downX, dy = upY - downY;

    cmd("tool.set mesh.topoPen on");

    auto pr = postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, downX, downY, upX, upY, 16, 0x0001 /*LSHIFT*/, 3));
    assert("error" !in pr, "Shift+RMB drag failed: " ~ pr.toString);
    waitPlayerIdle();

    // Border-run delta: an OPEN run of n edges duplicates to +(n+1) vertices,
    // +(2n+1) edges (n duplicated + n+1 rungs) and +n faces — the arithmetic
    // the reference was measured at for n=1 and n=3. Here n=2, so +3/+5/+2.
    assert(vertexCountLayer(1) == 12,
        format("Dup Loop must add exactly 3 vertices for the 2-edge border run; got %d total",
               vertexCountLayer(1)));
    assert(edgeCountLayer(1) == 17 && faceCountLayer(1) == 6,
        format("Dup Loop must add exactly 5 edges / 2 faces; got e=%d f=%d",
               edgeCountLayer(1), faceCountLayer(1)));
    assert(vertexCountLayer(0) == sphereVertexCount(LON, LAT), "bg vertex count must be unchanged");

    auto post = readVerticesLayer(1);
    assert(post.length == 12);

    // The 9 original grid verts (incl. the untouched center, 4) must be
    // exactly unchanged — DupLoop never writes the original loop.
    foreach (vi; 0 .. 9)
        assert(approxVec(gridPos[vi], post[vi], 1e-5),
            format("original grid vertex %d must stay exactly at its original position", vi));

    // The 3 RUN source vertices' independently-computed NEAREST POINTS on
    // the sphere's facets, from their own drag-shifted world points (the top
    // row; NOT the whole rim).
    uint[3] rimIdx = [0, 1, 2];
    Vec3[3] expected;
    foreach (k, vi; rimIdx)
        assert(expectedNearestOnSphere(c, gridPos[vi], dx, dy, R, LON, LAT, expected[k]),
            format("setup: run vertex %d must project on-screen to have a shifted point", vi));

    // Bijective match: each of the 3 NEW (tail, indices 9..12) vertices must
    // match exactly one of the 3 expected targets (the exact index
    // correspondence is an internal kernel detail — extendEdgesByMask
    // iterates edges in ASCENDING INDEX order, not loop-chain order — so a
    // set match is the correct, robust assertion here).
    bool[3] used;
    foreach (ti; 9 .. 12) {
        Vec3 tv = toVec3(post[ti]);
        int bestK = -1;
        double bestD = double.infinity;
        foreach (k; 0 .. 3) {
            if (used[k]) continue;
            double d = distSq(tv, expected[k]);
            if (d < bestD) { bestD = d; bestK = cast(int)k; }
        }
        assert(bestK >= 0 && sqrt(bestD) < TOL,
            format("new vertex %d must match one of the 3 expected nearest-foot targets; "
                 ~ "nearest dist=%f", ti, sqrt(bestD)));
        used[bestK] = true;

        double distFromOrigin = sqrt(cast(double)dot(tv, tv));
        assert(abs(distFromOrigin - R) < TOL,
            format("new vertex %d must lie on the sphere surface", ti));
    }
    foreach (k; 0 .. 3)
        assert(used[k], format("expected target %d (run vertex %d) must be matched by exactly "
                             ~ "one new vertex", k, rimIdx[k]));
}

Vec3 toVec3(double[3] v) { return Vec3(cast(float)v[0], cast(float)v[1], cast(float)v[2]); }
