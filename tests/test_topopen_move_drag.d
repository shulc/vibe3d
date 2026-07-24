// Topology Pen P4 — move_drag (T2, doc/topopen_p4_plan.md "Test
// enumeration").
//
// Grab a vertex on a sphere-bg scene via a plain LMB drag (NO modifier —
// the base "Move" gesture, distinct from P3's Shift+LMB build overlay),
// release at a NEW pixel: the grabbed vertex must land at the
// INDEPENDENTLY-computed camera-ray hit for the RELEASE pixel
// (`expectedRayHitOnSphere`, reused verbatim from the P2 place fixtures —
// derived from the scene geometry, NOT from the tool's own output). All
// other vertices/edges/faces stay unchanged — Move never adds/removes
// topology.
//
// Run via: ./run_test.d topopen_move_drag

import topopen_place_helpers;
import std.json;
import std.math   : abs, sqrt;
import std.format : format;

void main() {}

enum float  R   = 2.0f;
enum int    LON = 96, LAT = 72;   // resolution rationale: topopen_place_helpers.d
enum double TOL = R * 0.04;       // covers the mesh-resolution note there

unittest {
    setupSphereBg(R, LON, LAT);

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;
    int nx = cx + 80, ny = cy + 40;   // the drag's release destination

    Vec3 expectedA, expectedMoved;
    assert(expectedRayHitOnSphere(c, cast(float)cx, cast(float)cy, R, expectedA),
        "hub A's camera-ray must hit the sphere");
    assert(expectedRayHitOnSphere(c, cast(float)nx, cast(float)ny, R, expectedMoved),
        "the drag-destination pixel's camera-ray must hit the sphere");

    cmd("tool.set mesh.topoPen on");

    // 1) Place A via a plain (stationary) P2/P4-Place click.
    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 1, "setup click must place exactly 1 vertex");
    assert(edgeCountLayer(1) == 0 && faceCountLayer(1) == 0);

    // 2) Plain-LMB drag FROM A (cx,cy) TO (nx,ny) — no Shift, so this grabs
    // A (Move), it does NOT build (mod defaults to 0 in buildDragLog).
    auto pr = postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, nx, ny, 16));
    assert("error" !in pr, "drag failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 1,
        format("Move must never add/remove vertices; got %d", vertexCountLayer(1)));
    assert(edgeCountLayer(1) == 0 && faceCountLayer(1) == 0,
        "Move must never create topology (no edges/faces)");

    auto verts = readVerticesLayer(1);
    assert(approxVec(expectedMoved, verts[0], TOL),
        format("moved vertex %s should match the independently-computed camera-ray hit at the "
             ~ "RELEASE pixel (%f,%f,%f)", verts[0], expectedMoved.x, expectedMoved.y, expectedMoved.z));
    assert(!approxVec(expectedA, verts[0], TOL * 2),
        "sanity: the moved position must genuinely differ from the pre-move position");

    double dist = sqrt(verts[0][0]*verts[0][0] + verts[0][1]*verts[0][1] + verts[0][2]*verts[0][2]);
    assert(abs(dist - R) < TOL, "the moved vertex must still lie on the sphere surface");
}
