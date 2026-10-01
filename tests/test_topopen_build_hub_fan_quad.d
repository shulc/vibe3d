// Topology Pen P3 — build_hub_fan_quad (CASE-QUAD end to end, then the closed
// hub).
//
// Reproduces the SESSION-3 hub-fan sequence: THREE successive Shift+LMB drags
// from the SAME hub H0 (the gesture-map overlay slot for this tool's
// "Duplicate"/build action, gesture_map.md table A #4) — drag1 builds a plain
// edge, drag2 auto-closes a triangle, drag3 (H0 now a corner of that one
// triangle) builds the QUAD across the triangle's two other corners and KEEPS
// the triangle beside it. A FOURTH drag from the hub, whose two edges now each
// lie on two polygons, builds nothing: it MOVES the hub.
//
// CORRECTED by task 8720 (plan P1), deliberately: this test used to pin the
// splice REPLACING the triangle and drag4 leaving the hub in place. The
// session capture refutes both (C1-B4b h3: the quad with the triangle kept, h4:
// a vertex move; C2-B6b-far: the splice [18,16,17,19] with the triangle kept;
// the 2026 build capture's own raw dump agrees, phase hub3 faces
// [..,[0,5,4],[5,0,4,6]]) — laws L37 R-closed and S-inTri.
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

    // drag3 (THE PIVOTAL gesture): H0(0) is a corner of ONE triangle
    // [0,2,1] whose sides to 2 and 1 are its border edges -> CASE-QUAD. The
    // triangle runs 0 -> 2 and 1 -> 0, so the quad runs each side against it:
    // [P,A,Q,B] = [2,0,1,3]. The triangle stays.
    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, d3x, d3y, 16, LSHIFT));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 4,
        format("expected 4 vertices after drag3; got %d", vertexCountLayer(1)));
    assert(edgeCountLayer(1) == 5,
        format("expected 5 edges (3 old + 2 new); got %d", edgeCountLayer(1)));
    assert(faceCountLayer(1) == 2,
        format("expected 2 faces (the triangle KEPT beside the new quad); got %d",
               faceCountLayer(1)));
    assert(hasExactFace(1, [2, 0, 1, 3]),
        "quad winding must be [P,A,Q,B]=[2,0,1,3] verbatim; got " ~ readFacesLayer(1).to!string);
    assert(hasExactFace(1, [0, 2, 1]),
        "the triangle [0,2,1] must be kept beside the quad; got " ~ readFacesLayer(1).to!string);

    assert(hasEdgeLayer(1, 0, 1), "pre-existing edge (0,1) must survive as a quad boundary edge");
    assert(hasEdgeLayer(1, 0, 2), "pre-existing edge (0,2) must survive as a quad boundary edge");
    assert(hasEdgeLayer(1, 1, 2), "the triangle's third edge (1,2) must survive as its side");
    assert(hasEdgeLayer(1, 1, 3), "new quad boundary edge (1,3) must exist");
    assert(hasEdgeLayer(1, 2, 3), "new quad boundary edge (2,3) must exist");
    assert(!hasEdgeLayer(1, 0, 3),
        "the hub-to-new-point edge (0,3)=A-B must be ABSENT — B connects to the "
        ~ "triangle's two neighbors, never to the hub directly");

    auto verts = readVerticesLayer(1);
    double distB = sqrt(verts[3][0]*verts[3][0] + verts[3][1]*verts[3][1] + verts[3][2]*verts[3][2]);
    assert(abs(distB - R) < TOL, "the quad's new vertex must lie on the sphere surface");

    // Undo peels ONLY drag3's quad build, back to drag2's 3-vertex/3-edge/
    // 1-triangle state; redo restores the quad beside the triangle.
    auto u = postJson("/api/command", commandBody("history.undo"));
    assert(u["status"].str == "ok");
    assert(vertexCountLayer(1) == 3 && edgeCountLayer(1) == 3 && faceCountLayer(1) == 1,
        "undo of the quad-build must land exactly on drag2's post-triangle state");
    assert(hasExactFace(1, [0, 2, 1]), "undo must leave the ORIGINAL triangle alone");

    auto r = postJson("/api/command", commandBody("history.redo"));
    assert(r["status"].str == "ok");
    assert(vertexCountLayer(1) == 4 && edgeCountLayer(1) == 5 && faceCountLayer(1) == 2);
    assert(hasExactFace(1, [2, 0, 1, 3]) && hasExactFace(1, [0, 2, 1]),
        "redo must restore the SAME quad winding beside the triangle");

    // drag4 (CLOSED HUB): each of H0's edges now lies on the triangle AND the
    // quad, so the press builds nothing — it moves the hub (C1-B4b h4).
    auto before = readVerticesLayer(1);
    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, d4x, d4y, 16, LSHIFT));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 4, "closed hub: vertex count must stay 4");
    assert(edgeCountLayer(1) == 5, "closed hub: edge count must stay 5");
    assert(faceCountLayer(1) == 2, "closed hub: face count must stay 2");
    assert(hasExactFace(1, [2, 0, 1, 3]) && hasExactFace(1, [0, 2, 1]),
        "closed hub: the quad and the triangle must stay exactly as-is");
    auto after = readVerticesLayer(1);
    foreach (i; 1 .. before.length)
        assert(approxVec(Vec3(cast(float)before[i][0], cast(float)before[i][1], cast(float)before[i][2]),
                          after[i], 1e-6),
            format("closed hub: vertex %d must not move", i));
    const hubMove = sqrt((after[0][0] - before[0][0]) ^^ 2 + (after[0][1] - before[0][1]) ^^ 2
                         + (after[0][2] - before[0][2]) ^^ 2);
    const hubR = sqrt(after[0][0] ^^ 2 + after[0][1] ^^ 2 + after[0][2] ^^ 2);
    assert(hubMove >= 1e-3 && abs(hubR - R) < TOL,
        format("closed hub: the hub must MOVE onto the sphere (moved %.4g, radius %.4f)", hubMove, hubR));
}
