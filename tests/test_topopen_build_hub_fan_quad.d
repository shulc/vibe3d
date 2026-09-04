// Topology Pen P3 — build_hub_fan_quad (CASE-QUAD, the KILLER-2
// end-to-end guard, plus the measured one-shot ceiling).
//
// Reproduces the SESSION-3 hub-fan sequence bit-for-bit: THREE successive
// Shift+LMB drags from the SAME hub H0 (the documented gesture-map overlay
// slot for this tool's "Duplicate"/build action, gesture_map.md table A #4)
// — drag1 builds a plain edge, drag2 auto-closes a triangle, drag3 (with H0
// now the hub of that one triangle) splices the new point into the
// boundary, growing the triangle into a QUAD and leaving the triangle's
// third edge behind as a non-bounding orphan diagonal. A FOURTH drag from
// the now quad-embedded hub does NOTHING topological (the measured one-shot
// ceiling — no quad-to-pentagon growth).
//
// Run via: ./run_test.d topopen_build_hub_fan_quad

import http_command_helpers : commandBody;
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
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;   // H0
    int d1x = cx + 80, d1y = cy + 40;    // drag1 destination -> vert 1
    int d2x = cx - 70, d2y = cy - 50;    // drag2 destination -> vert 2 (tri apex)
    int d3x = cx + 40, d3y = cy - 90;    // drag3 destination -> vert 3 (quad apex)
    int d4x = cx - 30, d4y = cy + 90;    // drag4 destination -> the one-shot no-op attempt

    foreach (p; [[cx,cy],[d1x,d1y],[d2x,d2y],[d3x,d3y],[d4x,d4y]]) {
        Vec3 tmp;
        assert(expectedRayHitOnSphere(c, cast(float)p[0], cast(float)p[1], R, tmp),
            format("pixel (%d,%d)'s camera-ray must hit the sphere", p[0], p[1]));
    }

    cmd("tool.set mesh.topoPen on");
    // Mode dropdown (task 0483): this test drives PLAIN-LMB presses and
    // expects the place-on-empty/grab-move gesture, which is `point` —
    // the default is now `move`, which places nothing on empty space.
    cmd("tool.attr mesh.topoPen mode point");

    // Place H0 via a plain P2 click.
    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 1);

    // drag1: H0(0) -> 1. CASE-EDGE.
    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, d1x, d1y, 16, LSHIFT));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 2 && edgeCountLayer(1) == 1 && faceCountLayer(1) == 0,
        "drag1 must build the plain edge (0,1)");

    // drag2: H0(0) -> 2. CASE-TRI: auto-close [0,2,1] (hub, newest, older).
    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, d2x, d2y, 16, LSHIFT));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 3 && edgeCountLayer(1) == 3 && faceCountLayer(1) == 1,
        "drag2 must auto-close the triangle");
    assert(hasExactFace(1, [0, 2, 1]), "drag2's triangle winding must be [hub,newest,older]=[0,2,1]; got "
        ~ readFacesLayer(1).to!string);

    // drag3 (THE PIVOTAL gesture): H0(0) is now the hub of ONE existing
    // triangle [0,2,1] -> CASE-QUAD. A's index within [0,2,1] is slot 0, so
    // P=cyclic-next(A)=face[1]=2, Q=cyclic-prev(A)=face[2]=1 -> emitted quad
    // [P,A,Q,B] = [2,0,1,3].
    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, d3x, d3y, 16, LSHIFT));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 4,
        format("expected 4 vertices after drag3; got %d", vertexCountLayer(1)));
    assert(edgeCountLayer(1) == 5,
        format("expected 5 edges (3 old + 2 new); got %d", edgeCountLayer(1)));
    assert(faceCountLayer(1) == 1,
        format("expected exactly 1 face (the spliced quad, old triangle gone); got %d",
               faceCountLayer(1)));
    assert(hasExactFace(1, [2, 0, 1, 3]),
        "quad winding must be [P,A,Q,B]=[2,0,1,3] verbatim; got " ~ readFacesLayer(1).to!string);

    assert(hasEdgeLayer(1, 0, 1), "pre-existing edge (0,1) must survive as a quad boundary edge");
    assert(hasEdgeLayer(1, 0, 2), "pre-existing edge (0,2) must survive as a quad boundary edge");
    assert(hasEdgeLayer(1, 1, 2),
        "the triangle's OLD third edge (1,2) must survive as a non-bounding orphan diagonal");
    assert(hasEdgeLayer(1, 1, 3), "new quad boundary edge (1,3) must exist");
    assert(hasEdgeLayer(1, 2, 3), "new quad boundary edge (2,3) must exist");
    assert(!hasEdgeLayer(1, 0, 3),
        "the hub-to-new-point edge (0,3)=A-B must be ABSENT — B connects to the "
        ~ "triangle's two neighbors, never to the hub directly");

    auto verts = readVerticesLayer(1);
    double distB = sqrt(verts[3][0]*verts[3][0] + verts[3][1]*verts[3][1] + verts[3][2]*verts[3][2]);
    assert(abs(distB - R) < TOL, "the quad's new vertex must lie on the sphere surface");

    // Undo peels ONLY drag3's quad-splice gesture, back to drag2's
    // 3-vertex/3-edge/1-triangle state; redo restores the quad bit-exact.
    auto u = postJson("/api/command", commandBody("history.undo"));
    assert(u["status"].str == "ok");
    assert(vertexCountLayer(1) == 3 && edgeCountLayer(1) == 3 && faceCountLayer(1) == 1,
        "undo of the quad-build must land exactly on drag2's post-triangle state");
    assert(hasExactFace(1, [0, 2, 1]), "undo must restore the ORIGINAL triangle, not a lingering quad");

    auto r = postJson("/api/redo", "");
    assert(r["status"].str == "ok");
    assert(vertexCountLayer(1) == 4 && edgeCountLayer(1) == 5 && faceCountLayer(1) == 1);
    assert(hasExactFace(1, [2, 0, 1, 3]), "redo must restore the SAME quad winding");

    // drag4 (ONE-SHOT CEILING): H0 is now a corner of the 4-sided quad — a
    // further drag from it must build NOTHING (no quad-to-pentagon growth).
    auto before = readVerticesLayer(1);
    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, d4x, d4y, 16, LSHIFT));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 4, "one-shot ceiling: vertex count must stay 4");
    assert(edgeCountLayer(1) == 5, "one-shot ceiling: edge count must stay 5");
    assert(faceCountLayer(1) == 1, "one-shot ceiling: face count must stay 1");
    assert(hasExactFace(1, [2, 0, 1, 3]), "one-shot ceiling: the quad must stay exactly as-is");
    auto after = readVerticesLayer(1);
    foreach (i; 0 .. before.length)
        assert(approxVec(Vec3(cast(float)before[i][0], cast(float)before[i][1], cast(float)before[i][2]),
                          after[i], 1e-6),
            format("one-shot ceiling: vertex %d must not move either", i));
}
