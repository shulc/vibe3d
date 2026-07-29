// Topology Pen P11 — duploop_undo (Tier-C, doc/topopen_p11_duploop_plan.md
// "Testing strategy").
//
// After a Shift+RMB Dup Loop drag on a BOUNDARY (closed-rim) edge, the
// KEYBOARD Ctrl+Z path (SDL_KEYDOWN through handleKeyDown -> navHistory ->
// EditSession.navigate, which calls resyncSession on the active tool) — NOT
// the plain `/api/undo` HTTP endpoint, which deliberately bypasses
// navHistory (see test_topopen_move_state.d's own doc comment / app.d's
// navHistory frozen-contract comment) — restores the primary layer EXACTLY
// to its pre-drag state (all new geometry removed, vertex/edge/face counts
// back to the untouched grid, every original vertex position unchanged); the
// keyboard Ctrl+Shift+Z redo path re-applies the exact post-drag topology +
// positions.
//
// Run via: ./run_test.d topopen_duploop_undo

import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

enum float R          = 2.0f;
enum int   LON        = 96, LAT = 72;
enum float GRID_HALF   = 0.6f;

enum int SDLK_z     = 122;              // 'z'
enum int KMOD_LCTRL  = 0x0040;
enum int KMOD_SHIFT  = KMOD_LCTRL | 0x0001;   // KMOD_LCTRL | KMOD_LSHIFT

string ctrlZTap(double t) {
    return format(`{"t":%.3f,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}`,
                  t, SDLK_z, KMOD_LCTRL) ~ "\n"
         ~ format(`{"t":%.3f,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}`,
                  t + 10.0, SDLK_z, KMOD_LCTRL);
}

string redoTap(double t) {
    return format(`{"t":%.3f,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}`,
                  t, SDLK_z, KMOD_SHIFT) ~ "\n"
         ~ format(`{"t":%.3f,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}`,
                  t + 10.0, SDLK_z, KMOD_SHIFT);
}

string gridPatchBody() {
    Vec3[9] v;
    foreach (i; 0 .. 3) foreach (j; 0 .. 3) {
        float x = -GRID_HALF + GRID_HALF * cast(float)j;
        float z = -GRID_HALF + GRID_HALF * cast(float)i;
        v[i * 3 + j] = Vec3(x, 0, z);
    }
    string vertsJson;
    foreach (k, p; v) {
        if (k) vertsJson ~= ",";
        vertsJson ~= format(`[%.6f,%.6f,%.6f]`, p.x, p.y, p.z);
    }
    string facesJson = "[0,1,4,3],[1,2,5,4],[3,4,7,6],[4,5,8,7]";
    return format(`{"vertices":[%s],"faces":[%s]}`, vertsJson, facesJson);
}

unittest {
    setupSphereBg(R, LON, LAT);

    auto lr = postJson("/api/load-mesh", gridPatchBody());
    assert(lr["status"].str == "ok", "load-mesh (grid patch) failed: " ~ lr.toString);
    assert(vertexCountLayer(1) == 9 && edgeCountLayer(1) == 12 && faceCountLayer(1) == 4,
        "setup: primary layer must be the untouched 3x3 grid patch");

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));
    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);

    Vec3[9] gridPos;
    foreach (i; 0 .. 3) foreach (j; 0 .. 3) {
        float x = -GRID_HALF + GRID_HALF * cast(float)j;
        float z = -GRID_HALF + GRID_HALF * cast(float)i;
        gridPos[i * 3 + j] = Vec3(x, 0, z);
    }

    float s0x, s0y, s1x, s1y;
    assert(projectToWindow(gridPos[0], vp, s0x, s0y), "setup: v0 must project on-screen");
    assert(projectToWindow(gridPos[1], vp, s1x, s1y), "setup: v1 must project on-screen");
    int downX = cast(int)((s0x + s1x) * 0.5f);
    int downY = cast(int)((s0y + s1y) * 0.5f);
    int upX = downX + 35, upY = downY - 20;

    cmd("tool.set mesh.topoPen on");

    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, downX, downY, upX, upY, 16, 0x0001 /*LSHIFT*/, 3));
    waitPlayerIdle();

    // Setup sanity: the drag must have actually grown the topology.
    // Task 0486: the committed set is the border RUN through the seed, not the
    // whole gathered rim — measured, see dragweld_dupedge_loopscope_capture.md.
    // Seed 0-1 on a 3x3 grid runs {0-1, 1-2} (the corners 0 and 2 stop it), so
    // an open 2-edge run: +3 vertices, +5 edges, +2 faces.
    assert(vertexCountLayer(1) == 12 && edgeCountLayer(1) == 17 && faceCountLayer(1) == 6,
        "setup: the drag must have duplicated the 2-edge border run (+3v/+5e/+2f)");

    auto moved = readVerticesLayer(1);

    auto viewport = format(`{"t":0.0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                          c.vpX, c.vpY, c.width, c.height);

    // One in-session Ctrl+Z must restore the primary layer EXACTLY to its
    // pre-drag state — every bit of new geometry removed.
    postJson("/api/play-events", viewport ~ "\n" ~ ctrlZTap(30.0) ~ "\n");
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 9 && edgeCountLayer(1) == 12 && faceCountLayer(1) == 4,
        "undo must remove every bit of new geometry, restoring the untouched grid counts");

    auto afterUndo = readVerticesLayer(1);
    foreach (vi; 0 .. 9)
        assert(approxVec(gridPos[vi], afterUndo[vi], 1e-4),
            format("undo must restore vertex %d's exact pre-drag position; got %s expected %s",
                   vi, afterUndo[vi], gridPos[vi]));

    // Ctrl+Shift+Z (redo) must re-apply the EXACT grown topology + moved positions.
    postJson("/api/play-events", viewport ~ "\n" ~ redoTap(60.0) ~ "\n");
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 12 && edgeCountLayer(1) == 17 && faceCountLayer(1) == 6,
        "redo must re-apply the exact topology growth (+3v/+5e/+2f)");

    auto afterRedo = readVerticesLayer(1);
    assert(afterRedo.length == 12);
    foreach (vi; 0 .. 12)
        assert(approxVec(toVec3(moved[vi]), afterRedo[vi], 1e-4),
            format("redo must restore vertex %d's exact post-drag position; got %s expected %s",
                   vi, afterRedo[vi], moved[vi]));
}

Vec3 toVec3(double[3] v) { return Vec3(cast(float)v[0], cast(float)v[1], cast(float)v[2]); }
