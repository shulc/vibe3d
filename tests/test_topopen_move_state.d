// Topology Pen P4 — move_state (T5, Tier-C: /api/tool/state introspection,
// doc/topopen_p4_plan.md "Test enumeration" — "if feasible", implemented
// here).
//
// Asserts the armed Move/Place state `/api/tool/state` reports (task 0234
// pattern, extended for P4, mirroring test_topopen_build_state.d's P3
// coverage): a plain-LMB press on an existing vertex arms `moveArmed`/
// `grabbedVert` WITHOUT mutating the mesh; a stationary release disarms and
// mutates nothing (the eps no-op guard); a press on empty background arms
// `placeArmed` instead; and an external history navigation mid-drag clears
// the armed Move state via `resyncSession`.
//
// The mid-drag external-undo check uses the KEYBOARD Ctrl+Z path
// (SDL_KEYDOWN through handleKeyDown -> navHistory -> EditSession.navigate,
// which calls resyncSession on the active tool) — NOT the plain `/api/undo`
// HTTP endpoint, which deliberately bypasses navHistory/resyncSession (see
// test_topopen_build_state.d's own doc comment / app.d's `navHistory`
// frozen-contract comment).
//
// Run via: ./run_test.d topopen_move_state

import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

enum float R      = 2.0f;
enum int   LON    = 96, LAT = 72;

enum int SDLK_z     = 122;      // 'z'
enum int KMOD_LCTRL = 0x0040;   // canonFromEvent reads KMOD_CTRL

// A single mouse-button-down/-up JSON-Lines event, mod=0 (no modifier — the
// plain-LMB Move/Place slot), WITHOUT a matching partner — for probing the
// armed-but-not-yet-released state.
string downOnly(double t, int px, int py) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                  t, px, py);
}

string upOnly(double t, int px, int py) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                  t, px, py);
}

// Ctrl+Z KEYDOWN/KEYUP pair — drives the real keyboard undo chokepoint
// (handleKeyDown -> navHistory(true) -> EditSession.navigate ->
// resyncSession), mirroring test_topopen_build_state.d's `ctrlZTap`.
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

    // Place hub A via a plain click.
    postJson("/api/play-events", clickLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    waitPlayerIdle();
    assert(vertexCountLayer(1) == 1);

    // Baseline: nothing armed.
    auto s0 = getJson("/api/tool/state");
    assert(s0["moveArmed"].type == JSONType.false_, "must start with no armed Move");
    assert(s0["placeArmed"].type == JSONType.false_, "must start with no armed Place");
    assert(cast(int)s0["grabbedVert"].integer == -1, "must start with no grabbed vertex");

    auto viewport = format(`{"t":0.0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                          c.vpX, c.vpY, c.width, c.height);

    // --- 1) Plain-LMB DOWN on A must arm MOVE (grabbedVert=0), not Place ---
    postJson("/api/play-events", viewport ~ "\n" ~ downOnly(10.0, cx, cy) ~ "\n");
    waitPlayerIdle();

    auto s1 = getJson("/api/tool/state");
    assert(s1["moveArmed"].type == JSONType.true_, "a press on A must arm Move");
    assert(s1["placeArmed"].type == JSONType.false_, "a press on A must NOT arm Place");
    assert(cast(int)s1["grabbedVert"].integer == 0, "armed grab must be A(0)");
    assert(vertexCountLayer(1) == 1, "arming alone must not mutate the mesh");

    // Release WITHOUT motion (up at the SAME pixel) -> eps no-op: disarm,
    // mutate nothing.
    postJson("/api/play-events", viewport ~ "\n" ~ upOnly(20.0, cx, cy) ~ "\n");
    waitPlayerIdle();

    auto s2 = getJson("/api/tool/state");
    assert(s2["moveArmed"].type == JSONType.false_, "a stationary release must disarm Move");
    assert(cast(int)s2["grabbedVert"].integer == -1, "grabbedVert must clear after the no-op release");
    assert(vertexCountLayer(1) == 1, "a stationary release must mutate NOTHING (eps no-op guard)");

    // --- 2) A press on EMPTY background must arm Place, not Move ----------
    int ox = cx + 70, oy = cy + 30;
    postJson("/api/play-events", viewport ~ "\n" ~ downOnly(10.0, ox, oy) ~ "\n");
    waitPlayerIdle();

    auto s3 = getJson("/api/tool/state");
    assert(s3["placeArmed"].type == JSONType.true_, "a press on empty background must arm Place");
    assert(s3["moveArmed"].type == JSONType.false_, "a press on empty background must NOT arm Move");

    postJson("/api/play-events", viewport ~ "\n" ~ upOnly(20.0, ox, oy) ~ "\n");
    waitPlayerIdle();

    auto s4 = getJson("/api/tool/state");
    assert(s4["placeArmed"].type == JSONType.false_, "release must disarm Place");
    assert(vertexCountLayer(1) == 2, "the stationary background click must have PLACED a new vertex");

    // --- 3) Mid-drag external history navigation clears the armed Move
    // state (resyncSession), mirroring test_topopen_build_state.d's P3
    // coverage of the same mechanism ---------------------------------------
    postJson("/api/play-events", viewport ~ "\n" ~ downOnly(10.0, cx, cy) ~ "\n");
    waitPlayerIdle();

    auto s5 = getJson("/api/tool/state");
    assert(s5["moveArmed"].type == JSONType.true_, "re-press on A must arm Move again");

    postJson("/api/play-events", viewport ~ "\n" ~ ctrlZTap(30.0) ~ "\n");
    waitPlayerIdle();

    auto s6 = getJson("/api/tool/state");
    assert(s6["moveArmed"].type == JSONType.false_,
        "an external Ctrl+Z mid-drag must clear the armed Move state via resyncSession");
    assert(cast(int)s6["grabbedVert"].integer == -1,
        "grabbedVert must reset to -1 after the external undo");

    // The undo itself must have reverted the 2nd (Place) vertex, back to 1.
    assert(vertexCountLayer(1) == 1,
        "the undo itself must revert the Place gesture from step 2");

    // Release the now-stale down event so the harness's own button state
    // doesn't leak into the next test (up without a matching armed gesture
    // is a safe no-op — onMouseButtonUp gates on the armed flags).
    postJson("/api/play-events", viewport ~ "\n" ~ upOnly(20.0, cx, cy) ~ "\n");
    waitPlayerIdle();
}
