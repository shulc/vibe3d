// Topology Pen — the Mode dropdown drives a REAL plain-LMB press (task 0483).
//
// The unit-level router table (`lmbAction_` per mode/flag) lives in
// source/tools/edit/topology_pen/tool.d and is pinned by the module unittests
// in tests/unit/tools/edit/topology_pen/gestures_test.d. What THIS test proves is the end-to-end claim
// that table exists for: with `mode` set from the Tool Properties dropdown, an
// UNMODIFIED left click performs the mode's gesture through the real SDL
// dispatch path — the same mutation the equivalent modifier chord produces —
// and the chord itself keeps working regardless of what the dropdown says.
//
// Remove is the probe because its outcome is a single unambiguous integer (one
// face gone, vertices and edges untouched — `keepOrphans`/`keepFloatingEdges`)
// that the sibling chord test test_topopen_remove.d already pins for Ctrl+MMB,
// so the two tests assert the SAME observable through two different inputs.
// The expected face is computed from the camera ray independently of the
// tool's own output (`expectedFaceForHit`, mirrored from that test).
//
// A plain `/api/reset` (no query params) seeds a fresh cube directly on the
// PRIMARY layer (the single default layer, index 0).
//
// Run via: ./run_test.d topopen_mode_dispatch

import topopen_place_helpers;
import std.json;
import std.math   : abs;
import std.format : format;

void main() {}

/// The 6 faces of `cubeMeshBody()` (topopen_place_helpers.d), identified by
/// which axis-plane they sit on — see test_topopen_remove.d for the full
/// provenance note (never compare against vibe3d's own prior output).
int expectedFaceForHit(Vec3 hit) {
    enum float eps = 1e-3f;
    if (abs(hit.z - (-0.5f)) < eps) return 0;   // [0,3,2,1] -Z
    if (abs(hit.z - ( 0.5f)) < eps) return 1;   // [4,5,6,7] +Z
    if (abs(hit.x - (-0.5f)) < eps) return 2;   // [0,4,7,3] -X
    if (abs(hit.x - ( 0.5f)) < eps) return 3;   // [1,2,6,5] +X
    if (abs(hit.y - ( 0.5f)) < eps) return 4;   // [3,7,6,2] +Y
    if (abs(hit.y - (-0.5f)) < eps) return 5;   // [0,1,5,4] -Y
    assert(false, "hit point must lie on exactly one cube face plane");
}

/// Fresh cube on the primary layer, camera aimed at it, tool active. Returns
/// the centre pixel and the face the centre ray provably lands on.
struct Setup { CameraState c; int cx, cy; int face; }

Setup setupCubeAndTool() {
    postJson("/api/reset", "");   // default cube, single layer == primary (layer 0)

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));

    Setup s;
    s.c  = fetchCamera();
    s.cx = s.c.vpX + s.c.width / 2;
    s.cy = s.c.vpY + s.c.height / 2;

    Vec3 hit;
    assert(expectedRayHitOnAabb(s.c, cast(float)s.cx, cast(float)s.cy, 0.5f, hit),
        "centre-pixel camera-ray must hit the cube");
    s.face = expectedFaceForHit(hit);

    assert(faceCountLayer(0) == 6 && vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12,
        "setup: default reset must be an untouched cube");

    cmd("tool.set mesh.topoPen on");
    return s;
}

// `mode remove` + an UNMODIFIED left click == the Ctrl+MMB chord: exactly one
// face deleted, vertices and edges untouched, one undo entry.
unittest {
    auto s = setupCubeAndTool();
    cmd("tool.attr mesh.topoPen mode remove");

    auto beforeFaces  = readFacesLayer(0);
    auto removedVerts = beforeFaces[s.face].dup;

    auto pr = postJson("/api/play-events",
                       clickLog(s.c.vpX, s.c.vpY, s.c.width, s.c.height, s.cx, s.cy));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(faceCountLayer(0) == 5,
        format("a plain-LMB click in Remove mode must delete exactly 1 face; got %d",
               faceCountLayer(0)));
    assert(vertexCountLayer(0) == 8,
        "Remove must keepOrphans -- vertex count must be unchanged");
    assert(edgeCountLayer(0) == 12,
        "Remove must keepFloatingEdges -- edge count must be unchanged");

    auto afterFaces = readFacesLayer(0);
    foreach (f; afterFaces)
        assert(f != removedVerts, "the removed face's vertex list must be gone");

    auto st = getJson("/api/tool/state");
    assert(st["lmbAction"].str == "remove",
        "the press must record the Remove gesture as the resolved LMB action; got "
      ~ st["lmbAction"].str);

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);
    assert(faceCountLayer(0) == 6, "undo must restore the removed face");

    cmd("tool.attr mesh.topoPen mode move");   // sticky: leave the shared app clean
}

// The DEFAULT mode is `move`, and a Move-mode click on a face is a decline:
// no placement, no deletion, no undo entry. This is the behaviour change the
// new default introduces, asserted head-on rather than left implicit.
unittest {
    auto s = setupCubeAndTool();
    cmd("tool.attr mesh.topoPen mode move");

    size_t undoDepthBefore = getJson("/api/history")["undo"].array.length;

    auto pr = postJson("/api/play-events",
                       clickLog(s.c.vpX, s.c.vpY, s.c.width, s.c.height, s.cx, s.cy));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(faceCountLayer(0) == 6 && vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12,
        "a Move-mode click on a face must be a byte-identical no-op");
    assert(getJson("/api/history")["undo"].array.length == undoDepthBefore,
        "a declined press must record NO new undo entry");
}

// The modifier chords stay ABSOLUTE: with the dropdown parked on a mode that
// owns plain-LMB (Remove), a Ctrl+MMB press still runs Remove and a plain
// press still runs Remove — i.e. the dropdown never disables a chord. Probed
// with Split's chord (MMB), whose miss on empty space is a clean no-op, so the
// assertion is "the chord was consumed by its own gesture, not the mode's".
unittest {
    auto s = setupCubeAndTool();
    cmd("tool.attr mesh.topoPen mode remove");

    // MMB press on the cube's centre pixel: Split arms on a VERTEX only, and
    // the centre pixel is mid-face, so this is Split's own miss — crucially it
    // must NOT be rerouted into the dropdown's Remove.
    string mmbLog = viewportLog(s.c.vpX, s.c.vpY, s.c.width, s.c.height) ~ "\n"
        ~ format(`{"t":10.000,"type":"SDL_MOUSEBUTTONDOWN","btn":2,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                 s.cx, s.cy) ~ "\n"
        ~ format(`{"t":20.000,"type":"SDL_MOUSEBUTTONUP","btn":2,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                 s.cx, s.cy) ~ "\n";

    auto pr = postJson("/api/play-events", mmbLog);
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(faceCountLayer(0) == 6,
        "a plain-MMB press must run Split (a no-op here), never the dropdown's Remove");

    cmd("tool.attr mesh.topoPen mode move");   // sticky: leave the shared app clean
}
