// Topology Pen P3 — build_quad_unrelated_edge (KILLER-2, the "mesh-wide"
// guard).
//
// KILLER-2 warned that `deleteFacesByMask`'s OLD unconditional
// `rebuildEdges()` would wipe not just the spliced triangle's own orphan
// diagonal but ANY OTHER floating edge in the mesh (it rebuilds `edges[]`
// from scratch by walking `faces[]`, mesh-wide). This test builds a
// completely UNRELATED floating edge (its own hub + Shift+LMB drag,
// elsewhere on the sphere, never touched again) BEFORE running the full
// edge->triangle->quad hub-fan sequence around a SEPARATE hub, then asserts
// the unrelated edge — and its two vertices' positions — survive completely
// untouched by the quad splice.
//
// Run via: ./run_test.d topopen_build_quad_unrelated_edge

import topopen_place_helpers;
import std.json;
import std.math   : abs, sqrt;
import std.format : format;
import std.conv   : to;

void main() {}

enum float  R      = 2.0f;
enum int    LON    = 96, LAT = 72;
enum double TOL    = R * 0.04;
enum uint   LSHIFT = 0x0001;   // KMOD_LSHIFT — the build overlay's modifier

unittest {
    setupSphereBg(R, LON, LAT);

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;   // hub H0

    // Far away, unrelated hub + its own drag destination.
    int ux  = cx - 100, uy  = cy + 80;
    int ux2 = cx - 130, uy2 = cy + 100;

    int d1x = cx + 80, d1y = cy + 40;
    int d2x = cx - 70, d2y = cy - 50;
    int d3x = cx + 40, d3y = cy - 90;

    foreach (p; [[cx,cy],[ux,uy],[ux2,uy2],[d1x,d1y],[d2x,d2y],[d3x,d3y]]) {
        Vec3 tmp;
        assert(expectedRayHitOnSphere(c, cast(float)p[0], cast(float)p[1], R, tmp),
            format("pixel (%d,%d)'s camera-ray must hit the sphere", p[0], p[1]));
    }

    cmd("tool.set mesh.topoPen on");

    // Build the UNRELATED floating edge first: hub2(1) via P2 click, then a
    // Shift+LMB drag from it to vert 2 -> edge (1,2). NEVER touched again.
    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));   // H0 = 0
    waitPlayerIdle();
    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, ux, uy));   // hub2 = 1
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 2);

    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, ux, uy, ux2, uy2, 16, LSHIFT));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 3 && edgeCountLayer(1) == 1 && faceCountLayer(1) == 0,
        "the unrelated hub's own drag must build exactly one bare edge (1,2)");
    assert(hasEdgeLayer(1, 1, 2));

    auto unrelatedBefore = readVerticesLayer(1);

    // Now the full edge -> triangle -> quad hub-fan sequence around H0(0),
    // completely independent of hub2/vert2 above.
    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, d1x, d1y, 16, LSHIFT));   // -> 3
    waitPlayerIdle();
    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, d2x, d2y, 16, LSHIFT));   // -> 4, tri [0,4,3]
    waitPlayerIdle();
    assert(hasExactFace(1, [0, 4, 3]), "sanity: the tri around H0 must build first; got "
        ~ readFacesLayer(1).to!string);

    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, d3x, d3y, 16, LSHIFT));   // -> 5, quad [4,0,3,5]
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 6,
        format("expected 6 vertices total (3 unrelated-side + 3 H0-side); got %d",
               vertexCountLayer(1)));
    assert(faceCountLayer(1) == 1, "only H0's quad must exist as a face");
    assert(hasExactFace(1, [4, 0, 3, 5]), "H0's quad winding must be [P,A,Q,B]=[4,0,3,5]; got "
        ~ readFacesLayer(1).to!string);

    // The KILLER-2 guard: the unrelated edge (1,2), built LONG before the
    // quad splice and never touched by it, must be COMPLETELY untouched —
    // still present, and its endpoints have not moved.
    assert(hasEdgeLayer(1, 1, 2),
        "the UNRELATED floating edge (1,2) must survive the quad splice untouched — "
        ~ "this is exactly what the OLD unconditional rebuildEdges() would have wiped");
    assert(edgeCountLayer(1) == 6,
        format("expected 6 edges total (1 unrelated + 3 old H0 + 2 new H0); got %d",
               edgeCountLayer(1)));
    assert(hasEdgeLayer(1, 3, 4), "the H0 triangle's OLD edge (3,4) must survive as the diagonal");
    assert(!hasEdgeLayer(1, 0, 5), "H0-B edge (0,5) must be ABSENT (B connects to the neighbors, not the hub)");

    auto unrelatedAfter = readVerticesLayer(1);
    assert(approxVec(Vec3(cast(float)unrelatedBefore[1][0], cast(float)unrelatedBefore[1][1],
                          cast(float)unrelatedBefore[1][2]), unrelatedAfter[1], 1e-6),
        "unrelated hub vertex 1 must not have moved");
    assert(approxVec(Vec3(cast(float)unrelatedBefore[2][0], cast(float)unrelatedBefore[2][1],
                          cast(float)unrelatedBefore[2][2]), unrelatedAfter[2], 1e-6),
        "unrelated vertex 2 must not have moved");
}
