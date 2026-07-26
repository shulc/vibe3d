// Topology Pen — a plain-LMB (Move) press on a NON-VERTEX element must
// change NOTHING (doc/tasks/work/0482-topopen-move-nonvertex.md item 1).
//
// The defect this pins: `onPlainLmbDown` resolved its Move target with
// `findSourceVertex`, which searches VERTICES only. A press aimed at an EDGE
// or a FACE therefore resolved nothing, fell through to Place, and the
// release committed a `mesh.addVertex` at the background-snapped cursor
// point — aim at an edge, get a stray floating vertex, undoable but with no
// signal that anything unintended happened.
//
// The rig, and why each piece is load-bearing:
//   * BACKGROUND (layer 0) = a dense sphere at the origin. Without a
//     background the CONS stage publishes no surface hit, Place is a no-op on
//     its own, and "nothing changed" would be VACUOUSLY true — the test would
//     pass with the bug still in.
//   * PRIMARY (layer 1) = one axis-aligned quad near the origin, i.e. INSIDE
//     the background sphere. Depth is deliberately irrelevant to both queries
//     under test: the CONS raycast sees background layers only (so it always
//     reports the sphere, and a stray Place always had somewhere to land),
//     while the tool's face pick sees the primary layer only (so the sphere
//     never occludes the quad).
//   * The CONTROL press at the end fires the SAME gesture, same camera, same
//     tool, at a pixel clear of the quad — and must still place a vertex. That
//     is what proves the two no-ops above are genuine declines and not a dead
//     rig, and that a declined press leaves no stuck arm behind.
//
// ORDER MATTERS: `/api/load-mesh` restores the same post-load state
// `/api/reset` leaves behind, INCLUDING the camera. Every load therefore
// happens BEFORE `/api/camera` is posted — a camera set earlier is silently
// reverted by the next load, and every pixel here would then be computed
// against a camera the app no longer has (that failure mode looks exactly
// like a broken fix, which is why it is called out).
//
// The press pixels are DERIVED from the quad's own projected corners rather
// than assumed, and every geometric precondition is asserted: the
// edge-midpoint pixel resolves no vertex (else this would be a Move test),
// and the face-centre pixel is clear of every projected EDGE (so only the
// face term of the gate can decline it). A future camera/quad change cannot
// silently turn this into a test of something else.
//
// Run via: ./run_test.d topopen_move_nonvertex_decline

import topopen_place_helpers;
import std.json;
import std.math   : sqrt, abs, cos, sin, PI;
import std.format : format;

void main() {}

enum float  R    = 2.0f;
enum int    LON  = 96, LAT = 72;   // resolution rationale: topopen_place_helpers.d
enum double TOL  = R * 0.04;

// The tool's own screen-space pick tolerance (source/constraint.d's
// `kTopoPenSnapPx`) — mirrored here so the preconditions below are stated in
// the same units the code under test uses.
enum float kSnapPx = 12.0f;

// The primary quad: a 1.5x1.5 square in the world XY plane through the
// origin, well inside the R=2 background sphere. At distance 8 with the
// default viewport this projects to roughly 100x110px — comfortably larger
// than 2*kSnapPx in both screen directions, which is all the fixture needs
// (the exact projected size is measured, not assumed).
enum float kQuadHalf = 0.75f;

/// Distance from (px,py) to the SEGMENT (ax,ay)-(bx,by), in pixels — the same
/// point-to-segment measure the tool's edge pick uses.
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

/// Current undo-stack depth (`/api/history`), so "left no undo entry" is
/// asserted as a DELTA — the setup itself (load-mesh, layer.add) legitimately
/// records entries of its own.
size_t undoDepth() {
    return getJson("/api/history")["undo"].array.length;
}

unittest {
    // --- Rig: sphere background (layer 0) + a quad in the primary (layer 1).
    setupSphereBg(R, LON, LAT);

    auto lq = postJson("/api/load-mesh", format(
        `{"vertices":[[%.4f,%.4f,0.0],[%.4f,%.4f,0.0],[%.4f,%.4f,0.0],[%.4f,%.4f,0.0]],`
      ~ `"faces":[[0,1,2,3]]}`,
        -kQuadHalf, -kQuadHalf,  kQuadHalf, -kQuadHalf,
         kQuadHalf,  kQuadHalf, -kQuadHalf,  kQuadHalf));
    assert(lq["status"].str == "ok", "load-mesh (primary quad) failed: " ~ lq.toString);

    assert(vertexCountLayer(1) == 4 && edgeCountLayer(1) == 4 && faceCountLayer(1) == 1,
        format("setup: the primary layer must hold exactly the quad; got %d verts / %d edges "
             ~ "/ %d faces", vertexCountLayer(1), edgeCountLayer(1), faceCountLayer(1)));
    assert(vertexCountLayer(0) == sphereVertexCount(LON, LAT),
        "setup: the background sphere must be intact in layer 0");

    // Camera LAST — see the ORDER MATTERS note above.
    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);
    immutable int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;

    // The quad's own projected corners — every press pixel below is derived
    // from THESE, so no world-to-screen orientation convention is assumed.
    auto qv = readVerticesLayer(1);
    assert(qv.length == 4, "setup: the primary must still be the 4-corner quad");
    float[4] qx, qy;
    foreach (i; 0 .. 4) {
        float sx, sy;
        assert(projectToWindow(Vec3(cast(float)qv[i][0], cast(float)qv[i][1],
                                    cast(float)qv[i][2]), vp, sx, sy),
            format("setup: quad corner %d must project on-screen", i));
        qx[i] = sx; qy[i] = sy;
    }

    // Screen centroid + bounding radius of the quad, for the face-centre press
    // and for placing the control press safely outside it.
    float qcx = 0, qcy = 0;
    foreach (i; 0 .. 4) { qcx += qx[i]; qcy += qy[i]; }
    qcx /= 4; qcy /= 4;
    float qrMax = 0;
    foreach (i; 0 .. 4) {
        float d = sqrt((qx[i] - qcx) * (qx[i] - qcx) + (qy[i] - qcy) * (qy[i] - qcy));
        if (d > qrMax) qrMax = d;
    }
    assert(qrMax > 3.0f * kSnapPx,
        format("setup: the quad must project large enough for its centre to clear every edge "
             ~ "by more than %.0fpx; bounding radius is only %.1fpx", kSnapPx, qrMax));

    cmd("tool.set mesh.topoPen on");

    immutable size_t undo0 = undoDepth();

    // --- CASE 1: press at an EDGE MIDPOINT (the screen midpoint of the
    // corner-0..corner-1 edge). Lies exactly ON that projected segment, while
    // both endpoints are half an edge away — so no vertex resolves, and the
    // EDGE term of the gate is what must decline the press.
    immutable int ex = cast(int)((qx[0] + qx[1]) * 0.5f);
    immutable int ey = cast(int)((qy[0] + qy[1]) * 0.5f);
    foreach (i; 0 .. 4) {
        float d = sqrt((qx[i] - ex) * (qx[i] - ex) + (qy[i] - ey) * (qy[i] - ey));
        assert(d > kSnapPx,
            format("setup: the edge-midpoint pixel must be farther than %.0fpx from corner "
                 ~ "%d (else this would be a MOVE test); got %.1fpx", kSnapPx, i, d));
    }
    assert(distToSeg(ex, ey, qx[0], qy[0], qx[1], qy[1]) < 1.5f,
        "setup: the edge-midpoint pixel must lie on the quad's corner-0..1 edge segment");

    // A Place at this pixel WOULD have somewhere to land — the pixel's camera
    // ray hits the background sphere. Without this the no-op below would be
    // vacuous.
    Vec3 wouldBePlacedAt;
    assert(expectedRayHitOnSphere(c, cast(float)ex, cast(float)ey, R, wouldBePlacedAt),
        "setup: the edge-midpoint pixel's camera ray must hit the background sphere, "
      ~ "or a stray placement could not have happened there in the first place");

    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, ex, ey));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 4,
        format("a Move press on an EDGE must add NO vertex (the stray-vertex defect); got %d",
               vertexCountLayer(1)));
    assert(edgeCountLayer(1) == 4 && faceCountLayer(1) == 1,
        "a Move press on an EDGE must not change the primary layer's topology at all");
    assert(!hasVertexNear(1, wouldBePlacedAt, TOL),
        "no vertex may appear at the background hit the fall-through Place would have used");
    assert(undoDepth() == undo0,
        format("a Move press on an EDGE must leave NO undo entry; depth %d -> %d",
               undo0, undoDepth()));

    // --- CASE 2: press at the FACE CENTRE (the quad's screen centroid).
    // Asserted below to be clear of every projected edge by more than the snap
    // radius, so neither the vertex nor the edge term can fire: only the FACE
    // pick can decline this press.
    immutable int fx = cast(int)qcx, fy = cast(int)qcy;
    foreach (i; 0 .. 4) {
        immutable size_t j = (i + 1) % 4;
        float d = distToSeg(fx, fy, qx[i], qy[i], qx[j], qy[j]);
        assert(d > kSnapPx,
            format("setup: the face-centre pixel must be farther than %.0fpx from quad edge "
                 ~ "%d-%d (else the EDGE term, not the FACE term, would decline it); "
                 ~ "got %.1fpx", kSnapPx, i, j, d));
    }

    Vec3 wouldBePlacedAtCentre;
    assert(expectedRayHitOnSphere(c, cast(float)fx, cast(float)fy, R, wouldBePlacedAtCentre),
        "setup: the face-centre pixel's camera ray must hit the background sphere");

    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, fx, fy));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 4,
        format("a Move press on a FACE CENTRE must add NO vertex; got %d",
               vertexCountLayer(1)));
    assert(edgeCountLayer(1) == 4 && faceCountLayer(1) == 1,
        "a Move press on a FACE CENTRE must not change the primary layer's topology at all");
    assert(!hasVertexNear(1, wouldBePlacedAtCentre, TOL),
        "no vertex may appear at the background hit the fall-through Place would have used");
    assert(undoDepth() == undo0,
        format("a Move press on a FACE CENTRE must leave NO undo entry; depth %d -> %d",
               undo0, undoDepth()));

    // --- CONTROL: the SAME gesture on genuinely empty space must still place.
    // Searched rather than hardcoded, so no screen-orientation convention is
    // assumed: walk 8 compass directions out from the quad's screen centroid
    // at `qrMax + 40px` (a point outside a convex quad's bounding circle is at
    // least 40px from every one of its edges) and take the first candidate
    // whose own camera ray still hits the background sphere. If the guard
    // under test had been written as "decline every press that resolves no
    // vertex", this case — the pen's primary Draw gesture — would fail.
    int ctlx = -1, ctly = -1;
    Vec3 expectedControl;
    immutable float ctlR = qrMax + 40.0f;
    foreach (k; 0 .. 8) {
        immutable double a = 2.0 * PI * cast(double)k / 8.0;
        int px = cast(int)(qcx + ctlR * cast(float)cos(a));
        int py = cast(int)(qcy + ctlR * cast(float)sin(a));
        if (px < c.vpX + 4 || px > c.vpX + c.width - 4) continue;
        if (py < c.vpY + 4 || py > c.vpY + c.height - 4) continue;
        Vec3 hit;
        if (!expectedRayHitOnSphere(c, cast(float)px, cast(float)py, R, hit)) continue;
        ctlx = px; ctly = py; expectedControl = hit;
        break;
    }
    assert(ctlx >= 0,
        "setup: no control pixel outside the quad still hits the background sphere — the "
      ~ "camera/quad/sphere sizing no longer leaves room for the anti-vacuity control");
    foreach (i; 0 .. 4) {
        immutable size_t j = (i + 1) % 4;
        float d = distToSeg(ctlx, ctly, qx[i], qy[i], qx[j], qy[j]);
        assert(d > kSnapPx,
            format("setup: the control pixel must be clear of quad edge %d-%d; got %.1fpx",
                   i, j, d));
    }

    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, ctlx, ctly));
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 5,
        format("the control press on empty background must STILL place a vertex "
             ~ "(proves the rig is live and the guard did not kill Place); got %d verts",
               vertexCountLayer(1)));
    assert(hasVertexNear(1, expectedControl, TOL),
        "the control press's new vertex must sit at its own independently-computed "
      ~ "camera-ray hit on the background sphere");
    assert(undoDepth() == undo0 + 1,
        format("the control press must record exactly ONE undo entry; depth %d -> %d",
               undo0, undoDepth()));
}
