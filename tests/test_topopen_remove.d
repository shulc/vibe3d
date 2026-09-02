// Topology Pen P5 — remove (Ctrl+MMB), doc/topopen_p5_remove_plan.md.
//
// Best-effort Tier-C HTTP gesture test (plan Risk 3): `resolveGestureSlot`
// reads LIVE `SDL_GetModState()`, but `EventPlayer` already restores that
// live state per-event from each mouse event's own JSON "mod" field
// (source/eventlog.d's `_setModState(entry.mod)`, called immediately before
// every SDL_MOUSEBUTTONDOWN/UP is pushed) — the SAME mechanism the P3
// Shift+LMB build tests already rely on for their own modifier chord
// (test_topopen_build_tri.d's `LSHIFT` mod field), reused here verbatim for
// Ctrl+MMB (mod=KMOD_LCTRL, btn=SDL_BUTTON_MIDDLE). No separate KEYDOWN/UP
// chord is needed.
//
// A plain `/api/reset` (no query params) seeds a fresh cube directly on the
// PRIMARY layer (the single default layer, index 0) — Remove picks/edits
// the primary cage mesh only, unlike the placement tests' separate
// background-layer cube (topopen_place_helpers.setupCubeBg).
//
// Run via: ./run_test.d topopen_remove

import topopen_place_helpers;
import std.json;
import std.math   : abs;
import std.format : format;

void main() {}

enum uint LCTRL = 0x0040;   // KMOD_LCTRL — the Remove gesture's own modifier

string ctrlMmbClickAt(double t0, int px, int py) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":2,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                  t0, px, py, LCTRL) ~ "\n"
         ~ format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":2,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                  t0 + 10.0, px, py, LCTRL);
}

/// One Ctrl+MMB click at (px,py).
string ctrlMmbClickLog(int vpX, int vpY, int vpW, int vpH, int px, int py) {
    return viewportLog(vpX, vpY, vpW, vpH) ~ "\n" ~ ctrlMmbClickAt(10.0, px, py) ~ "\n";
}

/// The 6 faces of `cubeMeshBody()` (topopen_place_helpers.d), identified by
/// which axis-plane they sit on: a hit point's dominant near-±0.5
/// coordinate identifies its unique face for a ray that lands strictly
/// inside a face (not on an edge/corner) — independent of the tool's own
/// output, mirrors topopen_place_helpers.d's "never compare against
/// vibe3d's own prior output" rule.
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

unittest {
    postJson("/api/reset", "");   // default cube, single layer == primary (layer 0)

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;

    Vec3 expectedHit;
    assert(expectedRayHitOnAabb(c, cast(float)cx, cast(float)cy, 0.5f, expectedHit),
        "centre-pixel camera-ray must hit the cube");
    int expectedFace = expectedFaceForHit(expectedHit);

    assert(faceCountLayer(0) == 6 && vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12,
        "setup: default reset must be an untouched cube");
    auto beforeFaces = readFacesLayer(0);
    auto removedVerts = beforeFaces[expectedFace].dup;

    cmd("tool.set mesh.topoPen on");

    auto pr = postJson("/api/play-events", ctrlMmbClickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(faceCountLayer(0) == 5,
        format("Ctrl+MMB Remove must delete exactly 1 face; got %d", faceCountLayer(0)));
    assert(vertexCountLayer(0) == 8,
        "Remove must keepOrphans -- vertex count must be unchanged");
    assert(edgeCountLayer(0) == 12,
        "Remove must keepFloatingEdges -- edge count must be unchanged");

    auto afterFaces = readFacesLayer(0);
    foreach (f; afterFaces)
        assert(f != removedVerts, "the removed face's vertex list must be gone");

    // Undo restores the exact pre-removal state (face count back to 6).
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);
    assert(faceCountLayer(0) == 6, "undo must restore the removed face");
}

unittest {
    postJson("/api/reset", "");   // default cube, single layer == primary (layer 0)

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    // Corner of the viewport, far outside the cube's screen-space
    // footprint at this distance/fov -- a Ctrl+MMB press here must hit no
    // triangle at all.
    int mx = c.vpX + 4, my = c.vpY + 4;

    assert(faceCountLayer(0) == 6 && vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12);

    // Undo-stack depth BEFORE the miss click. `/api/reset` itself is a
    // Model-undoable entry (SceneReset), so the stack is non-empty even
    // here -- the miss assertion below is "no NEW entry", not "no entry".
    size_t undoDepthBefore = getJson("/api/history")["undo"].array.length;

    cmd("tool.set mesh.topoPen on");

    auto pr = postJson("/api/play-events", ctrlMmbClickLog(c.vpX, c.vpY, c.width, c.height, mx, my));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(faceCountLayer(0) == 6 && vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12,
        "a miss must be a byte-identical no-op");

    size_t undoDepthAfter = getJson("/api/history")["undo"].array.length;
    assert(undoDepthAfter == undoDepthBefore + 1,
        "a miss must add no edit row; only the surfaced arm is new");
}
