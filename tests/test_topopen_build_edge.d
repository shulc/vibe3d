// Topology Pen P3 — build_edge (CASE-EDGE).
//
// A Shift+LMB drag FROM an isolated (degree-0) primary-layer vertex A TO a
// fresh on-surface point builds a bare edge A-B — no face (vibe3d has no
// degenerate "line polygon" representation; see doc/topopen_p3_plan.md's
// documented divergence). The Shift modifier is the DOCUMENTED gesture-map
// overlay slot for this tool's "Duplicate"/build action (gesture_map.md
// table A #4 — Shift+LMB drag), not an arbitrary choice; a plain
// (unmodified) drag is P2's placeVertexAt path and does not build anything.
// Asserts: exact vertex/edge/face counts, the edge connects the right two
// indices, B is an independently-recomputed camera-ray hit ON the sphere
// surface, and the whole gesture is ONE atomic undo (undo removes B + the
// edge together, back to the 1-vertex state a preceding plain P2 click left
// behind; redo restores bit-exact).
//
// Run via: ./run_test.d topopen_build_edge

import topopen_place_helpers;
import std.json;
import std.math   : abs, sqrt;
import std.format : format;

void main() {}

enum float  R   = 2.0f;
enum int    LON = 96, LAT = 72;   // resolution rationale: topopen_place_helpers.d
enum double TOL = R * 0.04;       // covers the mesh-resolution note there
enum uint   LSHIFT = 0x0001;      // KMOD_LSHIFT — the build overlay's modifier

unittest {
    setupSphereBg(R, LON, LAT);

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;
    int bx = cx + 80, by = cy + 40;

    Vec3 expectedA, expectedB;
    assert(expectedRayHitOnSphere(c, cast(float)cx, cast(float)cy, R, expectedA),
        "hub A's camera-ray must hit the sphere");
    assert(expectedRayHitOnSphere(c, cast(float)bx, cast(float)by, R, expectedB),
        "drag-destination B's camera-ray must hit the sphere");

    cmd("tool.set mesh.topoPen on");

    // 1) Place hub A via a plain P2 click (its own, separate atomic undo).
    auto pr1 = postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    assert("error" !in pr1, "hub click failed: " ~ pr1.toString);
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 1, "hub click must place exactly 1 vertex");
    assert(edgeCountLayer(1) == 0 && faceCountLayer(1) == 0);

    // 2) Shift+LMB drag FROM A (cx,cy) TO a fresh point (bx,by) — CASE-EDGE.
    auto pr2 = postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, bx, by, 16, LSHIFT));
    assert("error" !in pr2, "drag failed: " ~ pr2.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 2,
        format("expected 2 vertices after the drag; got %d", vertexCountLayer(1)));
    assert(edgeCountLayer(1) == 1,
        format("expected exactly 1 edge; got %d", edgeCountLayer(1)));
    assert(faceCountLayer(1) == 0,
        "CASE-EDGE must build NO face (a bare edge, not a degenerate polygon)");
    assert(hasEdgeLayer(1, 0, 1), "the new edge must connect A(0) and B(1)");

    auto verts = readVerticesLayer(1);
    assert(approxVec(expectedA, verts[0], TOL), "vertex 0 must be hub A's hit");
    assert(approxVec(expectedB, verts[1], TOL), "vertex 1 must be B's independently-computed hit");
    double distB = sqrt(verts[1][0]*verts[1][0] + verts[1][1]*verts[1][1] + verts[1][2]*verts[1][2]);
    assert(abs(distB - R) < TOL, "B must lie on the sphere surface");

    // 3) One atomic undo removes B + the edge together, back to the
    // 1-vertex/0-edge state the hub click alone left behind.
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);
    assert(vertexCountLayer(1) == 1, "undo must remove B (back to 1 vertex)");
    assert(edgeCountLayer(1) == 0, "undo must remove the edge atomically WITH B");

    // 4) Redo restores bit-exact.
    auto r = postJson("/api/redo", "");
    assert(r["status"].str == "ok", "redo must succeed: " ~ r.toString);
    assert(vertexCountLayer(1) == 2, "redo must restore both vertices");
    assert(edgeCountLayer(1) == 1, "redo must restore the edge");
    assert(hasEdgeLayer(1, 0, 1), "redo must restore the SAME edge (0,1)");
}
