// Topology Pen P10 — moveloop_undo (Tier-C, doc/topopen_p10_moveloop_plan.md
// "Testing strategy").
//
// After an RMB Move Loop drag, the KEYBOARD Ctrl+Z path (SDL_KEYDOWN through
// handleKeyDown -> navHistory -> EditSession.navigate, which calls
// resyncSession on the active tool) — NOT the plain `/api/undo` HTTP
// endpoint, which deliberately bypasses navHistory (see
// test_topopen_move_state.d's own doc comment / app.d's navHistory
// frozen-contract comment) — restores every loop vertex's EXACT pre-drag
// position; the keyboard Ctrl+Shift+Z redo path re-applies the exact
// post-drag positions.
//
// Run via: ./run_test.d topopen_moveloop_undo

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

    float s3x, s3y, s4x, s4y;
    assert(projectToWindow(gridPos[3], vp, s3x, s3y), "setup: v3 must project on-screen");
    assert(projectToWindow(gridPos[4], vp, s4x, s4y), "setup: v4 must project on-screen");
    int downX = cast(int)((s3x + s4x) * 0.5f);
    int downY = cast(int)((s3y + s4y) * 0.5f);
    int upX = downX + 40, upY = downY - 25;

    cmd("tool.set mesh.topoPen on");

    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, downX, downY, upX, upY, 16, 0, 3));
    waitPlayerIdle();

    auto moved = readVerticesLayer(1);
    // Setup sanity: the drag must have actually moved the loop (vertex 3,
    // part of the gathered middle-row chain).
    assert(!approxVec(gridPos[3], moved[3], 1e-4),
        "setup: the drag must have moved vertex 3 off its original position");

    auto viewport = format(`{"t":0.0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                          c.vpX, c.vpY, c.width, c.height);

    // One in-session Ctrl+Z must restore EVERY vertex — including the
    // never-touched ones outside the loop — to its exact pre-drag position.
    postJson("/api/play-events", viewport ~ "\n" ~ ctrlZTap(30.0) ~ "\n");
    waitPlayerIdle();

    auto afterUndo = readVerticesLayer(1);
    foreach (vi; 0 .. 9)
        assert(approxVec(gridPos[vi], afterUndo[vi], 1e-4),
            format("undo must restore vertex %d's exact pre-drag position; got %s expected %s",
                   vi, afterUndo[vi], gridPos[vi]));
    assert(vertexCountLayer(1) == 9 && edgeCountLayer(1) == 12 && faceCountLayer(1) == 4,
        "undo must not change the primary layer's topology (Move Loop was already δ=0)");

    // Ctrl+Shift+Z (redo) must re-apply the EXACT moved positions.
    postJson("/api/play-events", viewport ~ "\n" ~ redoTap(60.0) ~ "\n");
    waitPlayerIdle();

    auto afterRedo = readVerticesLayer(1);
    foreach (vi; 0 .. 9)
        assert(approxVec(toVec3(moved[vi]), afterRedo[vi], 1e-4),
            format("redo must restore vertex %d's exact post-drag position; got %s expected %s",
                   vi, afterRedo[vi], moved[vi]));
}

Vec3 toVec3(double[3] v) { return Vec3(cast(float)v[0], cast(float)v[1], cast(float)v[2]); }
