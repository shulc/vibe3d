// Topology Pen P11 — duploop_resnap (Tier-C, doc/topopen_p11_duploop_plan.md
// "Testing strategy").
//
// A Shift+RMB-drag on a BOUNDARY edge of a small quad grid (the
// owner-observed/measured spec case — REV1 FIX-1: a boundary seed gathers
// the FULL CLOSED perimeter), over a curved (sphere) background: the drag
// duplicates the closed rim into a new ring of quads (`Mesh.extendEdgesByMask`,
// identity TRS), then re-snaps EACH new (tail) vertex onto the sphere surface
// at that vertex's own SHARED-screen-delta-shifted pixel (camera-ray, the
// SAME primitive P10 Move Loop's re-snap ultimately rests on) —
// independently verified via `expectedRayHitOnSphere` (ray-sphere
// intersection computed from scratch, never a second call into the code
// under test). The primary layer's topology must grow by the computed
// closed-rim delta (+8v/+16e/+8f), the original 9 grid vertices must stay
// byte-unchanged, and each new vertex must match exactly one of the 8
// independently-computed expected targets (a bijective set match — the
// exact new-vertex INDEX ordering is an internal kernel detail, not part of
// the tool's contract).
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

    // Boundary seed: edge 0-1, a genuine top-row perimeter edge — the
    // owner-observed spec case (a side/boundary edge duplicates the WHOLE
    // closed rim).
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

    // Closed-rim topology delta: +8 verts, +16 edges (8 new ring + 8 spokes), +8 faces.
    assert(vertexCountLayer(1) == 17,
        format("Dup Loop must add exactly 8 vertices for the closed rim; got %d", vertexCountLayer(1)));
    assert(edgeCountLayer(1) == 28 && faceCountLayer(1) == 12,
        format("Dup Loop must add exactly 16 edges / 8 faces; got e=%d f=%d",
               edgeCountLayer(1), faceCountLayer(1)));
    assert(vertexCountLayer(0) == sphereVertexCount(LON, LAT), "bg vertex count must be unchanged");

    auto post = readVerticesLayer(1);
    assert(post.length == 17);

    // The 9 original grid verts (incl. the untouched center, 4) must be
    // exactly unchanged — DupLoop never writes the original loop.
    foreach (vi; 0 .. 9)
        assert(approxVec(gridPos[vi], post[vi], 1e-5),
            format("original grid vertex %d must stay exactly at its original position", vi));

    // The 8 rim source vertices' independently-computed shifted-pixel
    // camera-ray hits on the sphere.
    uint[8] rimIdx = [0, 1, 2, 3, 5, 6, 7, 8];
    Vec3[8] expected;
    foreach (k, vi; rimIdx) {
        float sx, sy;
        assert(projectToWindow(gridPos[vi], vp, sx, sy),
            format("setup: rim vertex %d must project on-screen", vi));
        assert(expectedRayHitOnSphere(c, sx + dx, sy + dy, R, expected[k]),
            format("rim vertex %d's shifted-pixel camera-ray must hit the sphere", vi));
    }

    // Bijective match: each of the 8 NEW (tail, indices 9..17) vertices must
    // match exactly one of the 8 expected targets (the exact index
    // correspondence is an internal kernel detail — extendEdgesByMask
    // iterates edges in ASCENDING INDEX order, not loop-chain order — so a
    // set match is the correct, robust assertion here).
    bool[8] used;
    foreach (ti; 9 .. 17) {
        Vec3 tv = toVec3(post[ti]);
        int bestK = -1;
        double bestD = double.infinity;
        foreach (k; 0 .. 8) {
            if (used[k]) continue;
            double d = distSq(tv, expected[k]);
            if (d < bestD) { bestD = d; bestK = cast(int)k; }
        }
        assert(bestK >= 0 && sqrt(bestD) < TOL,
            format("new vertex %d must match one of the 8 expected sphere-hit targets; "
                 ~ "nearest dist=%f", ti, sqrt(bestD)));
        used[bestK] = true;

        double distFromOrigin = sqrt(cast(double)dot(tv, tv));
        assert(abs(distFromOrigin - R) < TOL,
            format("new vertex %d must lie on the sphere surface", ti));
    }
    foreach (k; 0 .. 8)
        assert(used[k], format("expected target %d (rim vertex %d) must be matched by exactly "
                             ~ "one new vertex", k, rimIdx[k]));
}

Vec3 toVec3(double[3] v) { return Vec3(cast(float)v[0], cast(float)v[1], cast(float)v[2]); }
