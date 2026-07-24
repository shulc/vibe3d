// Topology Pen P3 — build_tri (CASE-TRI, the KILLER-1 end-to-end guard).
//
// Both drags below use Shift+LMB — the DOCUMENTED gesture-map overlay slot
// for this tool's "Duplicate"/build action (gesture_map.md table A #4), not
// an arbitrary choice.
//
// A SECOND drag from the SAME hub A (now carrying exactly one bare edge to
// N from a prior drag) auto-closes a triangle, in the CAPTURED index order
// [A, B, N] = [hub, newest, older-neighbor] (doc/topopen_p3_plan.md
// SESSION 2's "v0_second_drag_DECISIVE" finding). This is the KILLER-1
// end-to-end guard: `classifySource` must see A's bare edge via the raw
// `edgeNeighbors` scan (edgesAroundVertex/vertexValence, seeded from
// vertLoop, are blind to a face-less edge) — if it mis-detected degree-0,
// this second drag would re-emit ANOTHER bare edge instead of closing the
// triangle.
//
// Also verifies the gesture is its OWN atomic undo: undo peels back to
// the 2-vertex/1-edge state the FIRST drag (its own separate undo entry)
// left behind — not all the way to empty — and redo restores the
// triangle bit-exact.
//
// Run via: ./run_test.d topopen_build_tri

import topopen_place_helpers;
import std.json;
import std.math   : abs, sqrt;
import std.format : format;
import std.conv   : to;

void main() {}

enum float  R   = 2.0f;
enum int    LON = 96, LAT = 72;
enum double TOL = R * 0.04;
enum uint   LSHIFT = 0x0001;      // KMOD_LSHIFT — the build overlay's modifier

unittest {
    setupSphereBg(R, LON, LAT);

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;
    int nx = cx + 80, ny = cy + 40;   // N: drag1's destination
    int bx = cx - 70, by = cy - 50;   // B: drag2's destination (the new apex)

    Vec3 expA, expN, expB;
    assert(expectedRayHitOnSphere(c, cast(float)cx, cast(float)cy, R, expA));
    assert(expectedRayHitOnSphere(c, cast(float)nx, cast(float)ny, R, expN));
    assert(expectedRayHitOnSphere(c, cast(float)bx, cast(float)by, R, expB));

    cmd("tool.set mesh.topoPen on");

    // Hub A via a plain P2 click.
    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 1);

    // drag1: A(0) -> N(1). CASE-EDGE (A was degree-0 at press time).
    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, nx, ny, 16, LSHIFT));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 2 && edgeCountLayer(1) == 1 && faceCountLayer(1) == 0,
        "drag1 must build the plain edge (0,1)");
    assert(hasEdgeLayer(1, 0, 1));

    // drag2: A(0) -> B(2) again. A is now degree-1 (one bare edge to N=1)
    // -> CASE-TRI: auto-close triangle [A, B, N] = [0, 2, 1].
    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, bx, by, 16, LSHIFT));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 3,
        format("expected 3 vertices after drag2; got %d", vertexCountLayer(1)));
    assert(edgeCountLayer(1) == 3,
        format("expected 3 edges (0,1)+(0,2)+(1,2); got %d", edgeCountLayer(1)));
    assert(faceCountLayer(1) == 1,
        format("expected exactly 1 face (the auto-closed triangle); got %d", faceCountLayer(1)));
    assert(hasExactFace(1, [0, 2, 1]),
        "triangle winding must be emitted VERBATIM as [hub, newest, older-neighbor] = [0,2,1] "
        ~ "(construction-order convention, capture-verified) — got faces: "
        ~ readFacesLayer(1).to!string);
    assert(hasEdgeLayer(1, 0, 1), "the original A-N edge must survive");
    assert(hasEdgeLayer(1, 0, 2), "the new A-B edge (the drag itself) must exist");
    assert(hasEdgeLayer(1, 1, 2), "the auto-connect B-N edge must exist");

    auto verts = readVerticesLayer(1);
    assert(approxVec(expA, verts[0], TOL));
    assert(approxVec(expN, verts[1], TOL));
    assert(approxVec(expB, verts[2], TOL));

    // Undo peels ONLY drag2's gesture — back to the 2v/1e state drag1 left,
    // NOT all the way to 0. Redo restores the triangle bit-exact.
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok");
    assert(vertexCountLayer(1) == 2, "undo of the tri-build must land on drag1's 2-vertex state");
    assert(edgeCountLayer(1) == 1 && faceCountLayer(1) == 0);
    assert(hasEdgeLayer(1, 0, 1), "drag1's own edge must survive the tri-build's undo");

    auto r = postJson("/api/redo", "");
    assert(r["status"].str == "ok");
    assert(vertexCountLayer(1) == 3 && edgeCountLayer(1) == 3 && faceCountLayer(1) == 1);
    assert(hasExactFace(1, [0, 2, 1]), "redo must restore the SAME winding");
}
