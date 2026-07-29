// Topology Pen P3 — build_state (Tier C: /api/tool/state introspection).
//
// Asserts the armed drag-build state `/api/tool/state` reports (task 0234
// pattern, extended for P3): a Shift+LMB press on an existing vertex arms
// `dragArmed`/`sourceVert`/`case` WITHOUT mutating the mesh; a bare-edge
// vertex classifies as "tri" — the KILLER-1 regression guard AT THE STATE
// LEVEL, one layer below the full build (test_topopen_build_tri.d already
// covers the end-to-end mesh result); a release without motion disarms and
// builds nothing; and an external history navigation mid-drag clears the
// armed source via `resyncSession`.
//
// The undo used for the last check is the KEYBOARD Ctrl+Z path
// (SDL_KEYDOWN through handleKeyDown -> navHistory -> EditSession.navigate,
// which calls resyncSession on the active tool) — NOT the plain
// `/api/undo` HTTP endpoint, which app.d documents as a frozen contract
// that deliberately BYPASSES navHistory/resyncSession (straight
// `history.undo()`, no tool resync at all; see app.d's `navHistory` doc
// comment). Only the keyboard chokepoint exercises the resyncSession path
// this guard is actually about.
//
// Run via: ./run_test.d topopen_build_state

import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

enum float R      = 2.0f;
enum int   LON    = 96, LAT = 72;
enum uint  LSHIFT = 0x0001;   // KMOD_LSHIFT — the build overlay's modifier

enum int SDLK_z     = 122;      // 'z'
enum int KMOD_LCTRL = 0x0040;   // canonFromEvent reads KMOD_CTRL

// A single mouse-button-down JSON-Lines event, mod bits included, WITHOUT a
// matching up — for probing the armed-but-not-yet-released state.
string downOnly(double t, int px, int py, uint mod) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                  t, px, py, mod);
}

string upOnly(double t, int px, int py, uint mod) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                  t, px, py, mod);
}

// Ctrl+Z KEYDOWN/KEYUP pair — drives the real keyboard undo chokepoint
// (handleKeyDown -> navHistory(true) -> EditSession.navigate ->
// resyncSession), mirroring test_tool_undo_coordination.d's `keyTap`.
string ctrlZTap(double t) {
    return format(`{"t":%.3f,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}`,
                  t, SDLK_z, KMOD_LCTRL) ~ "\n"
         ~ format(`{"t":%.3f,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}`,
                  t + 10.0, SDLK_z, KMOD_LCTRL);
}

unittest {
    setupSphereBg(R, LON, LAT);

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;

    cmd("tool.set mesh.topoPen on");
    // Mode dropdown (task 0483): this test drives PLAIN-LMB presses and
    // expects the place-on-empty/grab-move gesture, which is `point` —
    // the default is now `move`, which places nothing on empty space.
    cmd("tool.attr mesh.topoPen mode point");

    // Place hub A via a plain P2 click.
    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 1);

    // Baseline: no drag armed.
    auto s0 = getJson("/api/tool/state");
    assert(s0["dragArmed"].type == JSONType.false_, "must start disarmed");
    assert(cast(int)s0["sourceVert"].integer == -1, "must start with no source vertex");
    assert(s0["case"].str == "none", "must start with case=none");

    // --- 1) Shift+LMB DOWN on A (degree-0) arms with case=edge ---------------
    auto viewport = format(`{"t":0.0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                          c.vpX, c.vpY, c.width, c.height);
    postJson("/api/play-events", viewport ~ "\n" ~ downOnly(10.0, cx, cy, LSHIFT) ~ "\n");
    waitPlayerIdle();

    auto s1 = getJson("/api/tool/state");
    assert(s1["dragArmed"].type == JSONType.true_, "Shift+LMB down on A must arm the drag");
    assert(cast(int)s1["sourceVert"].integer == 0, "armed source must be A(0)");
    assert(s1["case"].str == "edge", "A is degree-0 at press time -> case=edge");

    // Release WITHOUT motion (up at the SAME pixel) -> disarm, build nothing.
    postJson("/api/play-events", viewport ~ "\n" ~ upOnly(20.0, cx, cy, LSHIFT) ~ "\n");
    waitPlayerIdle();

    auto s2 = getJson("/api/tool/state");
    assert(s2["dragArmed"].type == JSONType.false_, "a release without motion must disarm");
    assert(cast(int)s2["sourceVert"].integer == -1, "source must clear after the no-op release");
    assert(vertexCountLayer(1) == 1 && edgeCountLayer(1) == 0,
        "a release without motion must build NOTHING");

    // --- 2) Build the real bare edge (A now degree-1), then re-arm: the
    // KILLER-1 regression guard — A must classify as "tri", NOT "edge" again.
    int nx = cx + 80, ny = cy + 40;
    postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, nx, ny, 16, LSHIFT));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 2 && edgeCountLayer(1) == 1,
        "the real drag must build the plain edge (0,1)");

    postJson("/api/play-events", viewport ~ "\n" ~ downOnly(10.0, cx, cy, LSHIFT) ~ "\n");
    waitPlayerIdle();

    auto s3 = getJson("/api/tool/state");
    assert(s3["dragArmed"].type == JSONType.true_, "re-press on A must arm again");
    assert(cast(int)s3["sourceVert"].integer == 0, "armed source must still be A(0)");
    assert(s3["case"].str == "tri",
        "KILLER-1 regression guard: A now carries ONE bare edge — classifySource must see it via "
        ~ "the raw edgeNeighbors scan and report case=tri, NOT edge=degree-0 again "
        ~ "(edgesAroundVertex/vertexValence are blind to a face-less edge); got case="
        ~ s3["case"].str);

    // --- 3) Mid-drag external history navigation clears the armed source ---
    // Ctrl+Z (the keyboard chokepoint, navHistory -> EditSession.navigate),
    // NOT /api/undo — see the module doc comment.
    postJson("/api/play-events", viewport ~ "\n" ~ ctrlZTap(30.0) ~ "\n");
    waitPlayerIdle();

    auto s4 = getJson("/api/tool/state");
    assert(s4["dragArmed"].type == JSONType.false_,
        "an external Ctrl+Z mid-drag must clear the armed source via resyncSession");
    assert(cast(int)s4["sourceVert"].integer == -1, "sourceVert must reset to -1 after the external undo");
    assert(s4["case"].str == "none", "case must reset to none after the external undo");

    // The undo itself must have reverted the drag1 edge-build (back to 1
    // vertex) — resyncSession clearing the armed state is orthogonal to, but
    // must not interfere with, the undo's own effect.
    assert(vertexCountLayer(1) == 1 && edgeCountLayer(1) == 0,
        "the undo itself must revert drag1's edge-build");

    // Release the now-stale down event so the harness's own button state
    // doesn't leak into the next test (up without a matching armed drag is a
    // safe no-op — onMouseButtonUp gates on dragArmed_).
    postJson("/api/play-events", viewport ~ "\n" ~ upOnly(20.0, cx, cy, LSHIFT) ~ "\n");
    waitPlayerIdle();
}
