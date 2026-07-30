// Topology Pen — Shift+LMB dragged from an EDGE builds a polygon beside it
// (task 0485).
//
// The reference's Duplicate mode "duplicates an edge as you drag it", and
// widens that to a whole loop only "with Edge Loop enabled or by dragging with
// the right mouse button". vibe3d's Shift+LMB slot implemented only the
// VERTEX outcome (P3's drag-build) and declined an edge press outright, so the
// single most common retopo stroke — pull a quad off an existing border edge —
// did nothing.
//
// What one edge duplicate must produce, counted from the kernel's own
// semantics (`extendEdgesByMask` over a one-edge mask) rather than read back
// from vibe3d: two new vertices (the duplicate's endpoints), one new face (the
// bridge quad), and three new edges (the duplicate edge plus the two sides).
//
// The rig is the element-drag test's — background sphere (the surface the new
// vertices re-snap ONTO; with none, every re-snap is refused, the duplicate
// stays coincident, and the position assertions would be vacuous) plus one
// quad in the primary layer.
//
// TASK 0503 — WHAT THE RE-SNAP IS. Expected positions used to be a camera-ray
// hit: project the source endpoint, shift by the drag delta, intersect THAT
// pixel's ray with the sphere. That was the port's law, and Duplicate is the
// gesture on which it was measured wrong — dupedge_resnap_capture.md cell A
// reads |new edge|/|source edge| = cos(tilt) at 30/45/60 degrees to 2.9e-7,
// against 1.804 / 2.484 / 4.369 for a per-vertex ray (contract C-2), and
// 1.000 against the ray law's 1.220 on a FLAT background (cell A0-FLAT). The
// same perpendicular-foot law is measured independently on Add Loop
// (addloop_bgresnap_undo_capture.md verdict V-1). So the expectation is the
// NEAREST POINT on the background facet, clamped to that facet —
// `expectedNearestOnSphere`, solved here against the sphere's own facets,
// never a call into the code under test.
//
// Run via: ./run_test.d topopen_dup_edge_drag

import topopen_place_helpers;
import std.json;
import std.math   : sqrt, abs;
import std.format : format;

void main() {}

enum float R         = 2.0f;
enum int   LON       = 96, LAT = 72;
enum double TOL      = R * 0.04;
enum float kSnapPx   = 8.0f;     // the tool's own PRESS-PICK reach
                                 // (`topoPenPressPickPx`, task 0496)
enum float kQuadHalf = 0.75f;
enum uint  LSHIFT    = 0x0001;   // KMOD_LSHIFT — the Duplicate slot's modifier

/// Drag far enough to clear the 3px click-vs-drag gate, and outward so the
/// duplicate lands on clear background rather than back over the quad.
enum int kDragX = 45, kDragY = 30;

float distToSeg(float px, float py, float ax, float ay, float bx, float by) {
    float vx = bx - ax, vy = by - ay;
    float wx = px - ax, wy = py - ay;
    float len2 = vx * vx + vy * vy;
    float t = len2 > 1e-9f ? (wx * vx + wy * vy) / len2 : 0.0f;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    float dx = px - (ax + vx * t), dy = py - (ay + vy * t);
    return sqrt(dx * dx + dy * dy);
}

size_t undoDepth() {
    return getJson("/api/history")["undo"].array.length;
}

bool hasVertexNearVec(int layer, Vec3 want, double tol) {
    foreach (v; readVerticesLayer(layer))
        if (abs(v[0] - want.x) < tol && abs(v[1] - want.y) < tol && abs(v[2] - want.z) < tol)
            return true;
    return false;
}

unittest {
    setupSphereBg(R, LON, LAT);

    auto lq = postJson("/api/load-mesh", format(
        `{"vertices":[[%.4f,%.4f,0.0],[%.4f,%.4f,0.0],[%.4f,%.4f,0.0],[%.4f,%.4f,0.0]],`
      ~ `"faces":[[0,1,2,3]]}`,
        -kQuadHalf, -kQuadHalf,  kQuadHalf, -kQuadHalf,
         kQuadHalf,  kQuadHalf, -kQuadHalf,  kQuadHalf));
    assert(lq["status"].str == "ok", "load-mesh (primary quad) failed: " ~ lq.toString);
    assert(vertexCountLayer(1) == 4 && edgeCountLayer(1) == 4 && faceCountLayer(1) == 1,
        "setup: the primary layer must hold exactly the quad");

    // Camera LAST — `/api/load-mesh` restores the post-load camera.
    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);

    cmd("tool.set mesh.topoPen on");
    cmd("tool.attr mesh.topoPen mode move");   // the chord is absolute; pin the mode anyway

    auto before = readVerticesLayer(1);
    float[4] qx, qy;
    foreach (i; 0 .. 4) {
        float sx, sy;
        assert(projectToWindow(Vec3(cast(float)before[i][0], cast(float)before[i][1],
                                    cast(float)before[i][2]), vp, sx, sy),
            format("setup: quad corner %d must project on-screen", i));
        qx[i] = sx; qy[i] = sy;
    }

    // Which corners the pressed edge joins — read from the mesh's own edge
    // list, not assumed from corner order.
    auto edges = getJson("/api/model?layer=1")["edges"].array;
    int ea = -1, eb = -1;
    foreach (ed; edges) {
        immutable int a = cast(int)ed.array[0].integer, b = cast(int)ed.array[1].integer;
        if ((a == 0 && b == 1) || (a == 1 && b == 0)) { ea = a; eb = b; break; }
    }
    assert(ea >= 0, "setup: the quad must carry a 0-1 edge to duplicate");

    immutable int ex = cast(int)((qx[ea] + qx[eb]) * 0.5f);
    immutable int ey = cast(int)((qy[ea] + qy[eb]) * 0.5f);
    foreach (i; 0 .. 4) {
        float d = sqrt((qx[i] - ex) * (qx[i] - ex) + (qy[i] - ey) * (qy[i] - ey));
        assert(d > kSnapPx,
            format("setup: the press pixel must clear corner %d by more than %.0fpx (else the "
                 ~ "VERTEX outcome would arm instead); got %.1fpx", i, kSnapPx, d));
    }
    assert(distToSeg(ex, ey, qx[ea], qy[ea], qx[eb], qy[eb]) < 1.5f,
        "setup: the press pixel must lie on the edge it means to duplicate");

    // Where the duplicate's two endpoints must land — this file's own
    // computation of the kernel's law, never a readback.
    Vec3[2] want;
    foreach (k, src; [ea, eb]) {
        Vec3 srcPos = Vec3(cast(float)before[src][0], cast(float)before[src][1],
                           cast(float)before[src][2]);
        assert(expectedNearestOnSphere(c, srcPos, kDragX, kDragY, R, LON, LAT, want[k]),
            format("setup: source endpoint %d must project on-screen to have a drag-shifted "
                 ~ "point at all", src));
    }

    immutable size_t undo0 = undoDepth();

    auto pr = postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, ex, ey, ex + kDragX, ey + kDragY,
                     16, LSHIFT, 1));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    // One edge duplicated = +2 verts, +1 face, +3 edges.
    assert(vertexCountLayer(1) == 6,
        format("duplicating one edge must add exactly 2 vertices; got %d total",
               vertexCountLayer(1)));
    assert(faceCountLayer(1) == 2,
        format("duplicating one edge must add exactly 1 bridge polygon; got %d faces",
               faceCountLayer(1)));
    assert(edgeCountLayer(1) == 7,
        format("duplicating one edge must add 3 edges (the duplicate + two sides); got %d",
               edgeCountLayer(1)));

    // The two new vertices sit at their own independently-computed re-snap
    // points, and the four originals have not moved.
    foreach (k, w; want)
        assert(hasVertexNearVec(1, w, TOL),
            format("the duplicate's endpoint %d must land on its independently-computed "
                 ~ "re-snap point %s", k, w));
    auto after = readVerticesLayer(1);
    foreach (i; 0 .. 4)
        assert(abs(after[i][0] - before[i][0]) < 1e-5
            && abs(after[i][1] - before[i][1]) < 1e-5
            && abs(after[i][2] - before[i][2]) < 1e-5,
            format("original corner %d must not move — Duplicate ADDS, it does not drag the "
                 ~ "source edge", i));

    // The whole gesture is ONE undo entry, and undo restores the bare quad.
    assert(undoDepth() == undo0 + 1,
        format("the duplicate must record exactly ONE undo entry; depth %d -> %d",
               undo0, undoDepth()));
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);
    assert(vertexCountLayer(1) == 4 && edgeCountLayer(1) == 4 && faceCountLayer(1) == 1,
        "undo must restore the bare quad");
}

// A stationary Shift+CLICK on an edge duplicates nothing — the same
// click-vs-drag gate every gesture in this tool carries.
unittest {
    setupSphereBg(R, LON, LAT);

    auto lq = postJson("/api/load-mesh", format(
        `{"vertices":[[%.4f,%.4f,0.0],[%.4f,%.4f,0.0],[%.4f,%.4f,0.0],[%.4f,%.4f,0.0]],`
      ~ `"faces":[[0,1,2,3]]}`,
        -kQuadHalf, -kQuadHalf,  kQuadHalf, -kQuadHalf,
         kQuadHalf,  kQuadHalf, -kQuadHalf,  kQuadHalf));
    assert(lq["status"].str == "ok", "load-mesh (primary quad) failed: " ~ lq.toString);

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);
    cmd("tool.set mesh.topoPen on");

    auto qv = readVerticesLayer(1);
    float[4] qx, qy;
    foreach (i; 0 .. 4) {
        float sx, sy;
        assert(projectToWindow(Vec3(cast(float)qv[i][0], cast(float)qv[i][1],
                                    cast(float)qv[i][2]), vp, sx, sy));
        qx[i] = sx; qy[i] = sy;
    }
    immutable int ex = cast(int)((qx[0] + qx[1]) * 0.5f);
    immutable int ey = cast(int)((qy[0] + qy[1]) * 0.5f);

    immutable size_t undo0 = undoDepth();

    // A Shift+LMB down/up pair at the SAME pixel.
    string log = viewportLog(c.vpX, c.vpY, c.width, c.height) ~ "\n"
        ~ format(`{"t":10.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                 ex, ey, LSHIFT) ~ "\n"
        ~ format(`{"t":20.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                 ex, ey, LSHIFT) ~ "\n";
    auto pr = postJson("/api/play-events", log);
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 4 && edgeCountLayer(1) == 4 && faceCountLayer(1) == 1,
        "a stationary Shift+click on an edge must be a byte-identical no-op");
    assert(undoDepth() == undo0, "and must record no undo entry");
}
