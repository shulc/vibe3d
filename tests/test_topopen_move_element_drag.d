// Topology Pen — Move drags an EDGE and a POLYGON, not just a vertex
// (task 0484).
//
// The reference's Move mode "moves an element as you drag it, but it remains
// fixed against the background surface as it slides around ... useful in
// editing vertices, EDGES, and POLYGONS". vibe3d used to grab vertices only
// and decline everything else (0482 — the behaviour was unmeasured then). This
// pins the two new grabs end-to-end, through the real SDL dispatch.
//
// The rig is test_topopen_move_nonvertex_decline.d's, and every piece is
// load-bearing for the same reasons documented there:
//   * BACKGROUND (layer 0) = a dense sphere at the origin — the surface the
//     moved vertices re-snap ONTO. With no background every re-snap misses,
//     the documented miss policy keeps every vertex put, and the whole test
//     would pass vacuously.
//   * PRIMARY (layer 1) = one quad inside that sphere. The CONS raycast sees
//     background layers only and the tool's element pick sees the primary
//     only, so neither occludes the other.
//   * ORDER MATTERS: `/api/load-mesh` restores the post-load camera, so the
//     camera is posted AFTER every load.
//
// Expected positions are computed INDEPENDENTLY, never read back from vibe3d
// and re-compared.
//
// TASK 0503 — WHAT THE RE-SNAP IS. The law used to be "project the vertex's
// pre-drag position, shift by the drag's pixel delta, intersect THAT pixel's
// camera ray with the background sphere". The ray was the port's own
// invention and is measured wrong twice over — dupedge_resnap_capture.md
// contract C-2 (|new edge|/|source edge| = cos(tilt) to 2.9e-7 at three tilt
// angles, against 1.804 / 2.484 / 4.369 for a per-vertex ray; and 1.000
// against 1.220 on a flat background, cell A0-FLAT) and
// addloop_bgresnap_undo_capture.md verdict V-1 on a second gesture and rig.
// The measured law is the NEAREST POINT on the background facet, clamped to
// that facet, so this file's arithmetic is now `expectedNearestOnSphere`
// (`shiftedWorldPoint` + a brute-force nearest foot over the sphere's own
// facets, both written out in topopen_place_helpers.d).
//
// EDGE and POLYGON grabs are the two Move outcomes this file pins, and they
// are the ones that changed: they resolve their targets through
// `perVertexTargetsFrom`. A VERTEX grab does NOT — it rides the cursor's own
// CONS hit, which is still a camera ray, and its fixtures
// (test_topopen_move_drag.d and friends) are untouched by 0503.
//
// Run via: ./run_test.d topopen_move_element_drag

import topopen_place_helpers;
import std.json;
import std.math   : sqrt, abs;
import std.format : format;

void main() {}

enum float  R    = 2.0f;
enum int    LON  = 96, LAT = 72;   // resolution rationale: topopen_place_helpers.d
enum double TOL  = R * 0.04;       // covers the mesh-resolution note there

/// The tool's own screen-space PRESS-PICK reach (`topoPenPressPickPx`),
/// mirrored so the preconditions below are stated in the units the code under
/// test uses. Task 0496: a press consults this, not the wider drag-snap radius.
enum float kSnapPx = 8.0f;

/// A 1.5x1.5 quad in the world XY plane through the origin — well inside the
/// R=2 background sphere.
enum float kQuadHalf = 0.75f;

/// The drag, in pixels. Comfortably past the tool's 3px click-vs-drag gate,
/// and small enough that every shifted pixel still lands on the sphere.
enum int kDragX = 40, kDragY = 25;

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

bool sameVec(double[] a, Vec3 b, double tol) {
    return abs(a[0] - b.x) < tol && abs(a[1] - b.y) < tol && abs(a[2] - b.z) < tol;
}

/// Rebuild the rig and return the camera. Each unittest starts from a clean
/// one — the drags mutate the primary layer, so they must not share it.
CameraState setupRig() {
    setupSphereBg(R, LON, LAT);

    auto lq = postJson("/api/load-mesh", format(
        `{"vertices":[[%.4f,%.4f,0.0],[%.4f,%.4f,0.0],[%.4f,%.4f,0.0],[%.4f,%.4f,0.0]],`
      ~ `"faces":[[0,1,2,3]]}`,
        -kQuadHalf, -kQuadHalf,  kQuadHalf, -kQuadHalf,
         kQuadHalf,  kQuadHalf, -kQuadHalf,  kQuadHalf));
    assert(lq["status"].str == "ok", "load-mesh (primary quad) failed: " ~ lq.toString);
    assert(vertexCountLayer(1) == 4 && edgeCountLayer(1) == 4 && faceCountLayer(1) == 1,
        "setup: the primary layer must hold exactly the quad");

    // Camera LAST — see the ORDER MATTERS note above.
    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    cmd("tool.set mesh.topoPen on");
    cmd("tool.attr mesh.topoPen mode move");
    cmd("tool.attr mesh.topoPen loop false");
    cmd("tool.attr mesh.topoPen slide false");
    return fetchCamera();
}

/// Where vertex `base` must end up after a (kDragX, kDragY) pixel drag —
/// this file's OWN computation of the tool's law, not a readback.
Vec3 expectedAfterDrag(CameraState c, Viewport vp, double[] base) {
    Vec3 src = Vec3(cast(float)base[0], cast(float)base[1], cast(float)base[2]);
    Vec3 foot;
    assert(expectedNearestOnSphere(c, src, kDragX, kDragY, R, LON, LAT, foot),
        "setup: a moving vertex must project on-screen to have a drag-shifted point at all");
    return foot;
}

// --- EDGE grab: exactly the two endpoints move, the other two corners stay.
unittest {
    auto c  = setupRig();
    auto vp = viewportFromCamera(c);

    auto before = readVerticesLayer(1);
    float[4] qx, qy;
    foreach (i; 0 .. 4) {
        float sx, sy;
        assert(projectToWindow(Vec3(cast(float)before[i][0], cast(float)before[i][1],
                                    cast(float)before[i][2]), vp, sx, sy),
            format("setup: quad corner %d must project on-screen", i));
        qx[i] = sx; qy[i] = sy;
    }

    // Press the screen midpoint of the corner-0..corner-1 edge: on that
    // segment by construction, and both endpoints half an edge away, so the
    // EDGE term of the pick — not the vertex term — is what resolves.
    immutable int ex = cast(int)((qx[0] + qx[1]) * 0.5f);
    immutable int ey = cast(int)((qy[0] + qy[1]) * 0.5f);
    foreach (i; 0 .. 4) {
        float d = sqrt((qx[i] - ex) * (qx[i] - ex) + (qy[i] - ey) * (qy[i] - ey));
        assert(d > kSnapPx,
            format("setup: the edge-midpoint pixel must be farther than %.0fpx from corner %d "
                 ~ "(else this would be a VERTEX grab); got %.1fpx", kSnapPx, i, d));
    }
    assert(distToSeg(ex, ey, qx[0], qy[0], qx[1], qy[1]) < 1.5f,
        "setup: the press pixel must lie on the quad's corner-0..1 edge segment");

    // Which quad corners ARE the pressed edge's endpoints, read from the
    // mesh's own edge list rather than assumed from corner order.
    auto edges = getJson("/api/model?layer=1")["edges"].array;
    int ea = -1, eb = -1;
    foreach (ed; edges) {
        immutable int a = cast(int)ed.array[0].integer, b = cast(int)ed.array[1].integer;
        if ((a == 0 && b == 1) || (a == 1 && b == 0)) { ea = a; eb = b; break; }
    }
    assert(ea >= 0, "setup: the quad must carry a 0-1 edge to grab");

    Vec3 wantA = expectedAfterDrag(c, vp, before[ea]);
    Vec3 wantB = expectedAfterDrag(c, vp, before[eb]);

    immutable size_t undo0 = undoDepth();

    auto pr = postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, ex, ey, ex + kDragX, ey + kDragY, 16, 0, 1));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 4 && edgeCountLayer(1) == 4 && faceCountLayer(1) == 1,
        "an edge MOVE must not change topology — no vertex added, nothing split");

    auto after = readVerticesLayer(1);
    assert(sameVec(after[ea], wantA, TOL),
        format("the pressed edge's endpoint %d must land on its own independently-computed "
             ~ "re-snap point %s; got %s", ea, wantA, after[ea]));
    assert(sameVec(after[eb], wantB, TOL),
        format("the pressed edge's endpoint %d must land on its own independently-computed "
             ~ "re-snap point %s; got %s", eb, wantB, after[eb]));

    foreach (i; 0 .. 4) {
        if (i == ea || i == eb) continue;
        assert(sameVec(after[i], Vec3(cast(float)before[i][0], cast(float)before[i][1],
                                      cast(float)before[i][2]), 1e-5),
            format("corner %d is not on the grabbed edge and must not have moved", i));
    }

    // The whole drag — press, N motion events, release — is ONE undo entry,
    // and undoing it restores every corner.
    assert(undoDepth() == undo0 + 1,
        format("an edge drag must record exactly ONE undo entry, not one per motion event; "
             ~ "depth %d -> %d", undo0, undoDepth()));
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);
    auto restored = readVerticesLayer(1);
    foreach (i; 0 .. 4)
        assert(sameVec(restored[i], Vec3(cast(float)before[i][0], cast(float)before[i][1],
                                         cast(float)before[i][2]), 1e-5),
            format("undo must restore corner %d exactly", i));
}

// --- POLYGON grab: every corner of the pressed face moves.
unittest {
    auto c  = setupRig();
    auto vp = viewportFromCamera(c);

    auto before = readVerticesLayer(1);
    float[4] qx, qy;
    float qcx = 0, qcy = 0;
    foreach (i; 0 .. 4) {
        float sx, sy;
        assert(projectToWindow(Vec3(cast(float)before[i][0], cast(float)before[i][1],
                                    cast(float)before[i][2]), vp, sx, sy),
            format("setup: quad corner %d must project on-screen", i));
        qx[i] = sx; qy[i] = sy; qcx += sx; qcy += sy;
    }
    qcx /= 4; qcy /= 4;

    // Press the quad's screen centroid, asserted clear of every projected
    // edge by more than the snap radius so neither the vertex nor the edge
    // term can fire — only the FACE pick can resolve this press.
    immutable int fx = cast(int)qcx, fy = cast(int)qcy;
    foreach (i; 0 .. 4) {
        immutable size_t j = (i + 1) % 4;
        float d = distToSeg(fx, fy, qx[i], qy[i], qx[j], qy[j]);
        assert(d > kSnapPx,
            format("setup: the face-centre pixel must be farther than %.0fpx from quad edge "
                 ~ "%d-%d (else the EDGE term would resolve it); got %.1fpx", kSnapPx, i, j, d));
    }

    Vec3[4] want;
    foreach (i; 0 .. 4) want[i] = expectedAfterDrag(c, vp, before[i]);

    immutable size_t undo0 = undoDepth();

    auto pr = postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, fx, fy, fx + kDragX, fy + kDragY, 16, 0, 1));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 4 && edgeCountLayer(1) == 4 && faceCountLayer(1) == 1,
        "a polygon MOVE must not change topology");

    auto after = readVerticesLayer(1);
    foreach (i; 0 .. 4)
        assert(sameVec(after[i], want[i], TOL),
            format("corner %d must land on its own independently-computed re-snap point %s; "
                 ~ "got %s", i, want[i], after[i]));

    assert(undoDepth() == undo0 + 1,
        format("a polygon drag must record exactly ONE undo entry; depth %d -> %d",
               undo0, undoDepth()));
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);
    auto restored = readVerticesLayer(1);
    foreach (i; 0 .. 4)
        assert(sameVec(restored[i], Vec3(cast(float)before[i][0], cast(float)before[i][1],
                                         cast(float)before[i][2]), 1e-5),
            format("undo must restore corner %d exactly", i));
}

// --- The drag is LIVE: the mesh has already moved BEFORE the button is
// released. This is the half a final-state assertion cannot see — a
// commit-only implementation would produce identical end geometry.
unittest {
    auto c  = setupRig();
    auto vp = viewportFromCamera(c);

    auto before = readVerticesLayer(1);
    float qcx = 0, qcy = 0;
    float[4] qx, qy;
    foreach (i; 0 .. 4) {
        float sx, sy;
        assert(projectToWindow(Vec3(cast(float)before[i][0], cast(float)before[i][1],
                                    cast(float)before[i][2]), vp, sx, sy),
            format("setup: quad corner %d must project on-screen", i));
        qx[i] = sx; qy[i] = sy; qcx += sx; qcy += sy;
    }
    qcx /= 4; qcy /= 4;

    // Press + motion, WITHOUT the release: a down event and one drag step.
    immutable int fx = cast(int)qcx, fy = cast(int)qcy;
    string log = viewportLog(c.vpX, c.vpY, c.width, c.height) ~ "\n"
        ~ format(`{"t":10.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                 fx, fy) ~ "\n"
        ~ format(`{"t":20.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}`,
                 fx + kDragX, fy + kDragY, kDragX, kDragY) ~ "\n";
    auto pr = postJson("/api/play-events", log);
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    auto st = getJson("/api/tool/state");
    assert(st["moveArmed"].type == JSONType.true_,
        "the gesture must still be armed — no release was sent: " ~ st.toString);
    assert(st["moveElem"].str == "face",
        "the press must have grabbed the FACE; got " ~ st["moveElem"].str);
    assert(st["moveVertCount"].integer == 4, "a quad grab drags all four corners");
    assert(st["moveDirty"].type == JSONType.true_,
        "the live drag must have written the mesh already, mid-gesture");

    auto mid = readVerticesLayer(1);
    bool anyMoved = false;
    foreach (i; 0 .. 4)
        if (!sameVec(mid[i], Vec3(cast(float)before[i][0], cast(float)before[i][1],
                                  cast(float)before[i][2]), 1e-4)) { anyMoved = true; break; }
    assert(anyMoved,
        "the geometry must ALREADY have moved before the button is released — that is what "
      ~ "makes the drag live rather than a ghost preview");

    // Release, so the shared app is left with no armed gesture for the next
    // test on this worker.
    postJson("/api/play-events", viewportLog(c.vpX, c.vpY, c.width, c.height) ~ "\n"
        ~ format(`{"t":30.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                 fx + kDragX, fy + kDragY) ~ "\n");
    waitPlayerIdle();
    assert(getJson("/api/tool/state")["moveArmed"].type == JSONType.false_,
        "the release must disarm the gesture");
}
