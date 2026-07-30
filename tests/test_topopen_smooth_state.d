// Topology Pen P8 — smooth_state (T5, doc/topopen_p8_smooth_plan.md
// "Testing Strategy").
//
// A Shift+Ctrl+LMB press must arm the Smooth gesture regardless of what is
// under the cursor (no source pick — whole-primary-mesh scope, unlike
// every other gesture) and expose the click-vs-drag pass count over
// /api/tool/state: smoothPassCount==1 while stationary, and thereafter the
// measured law N = max(1, 1 + dx/5) on the SIGNED HORIZONTAL offset from the
// press pixel (task 0490) — so a +100px drag is exactly 21 passes, and a
// purely vertical drag of the same length is still 1.
//
// Run via: ./run_test.d topopen_smooth_state

import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

enum uint SHIFT_CTRL = 0x0001 | 0x0040;   // KMOD_LSHIFT | KMOD_LCTRL

string downOnlyLog(int vpX, int vpY, int vpW, int vpH, int px, int py) {
    return viewportLog(vpX, vpY, vpW, vpH) ~ "\n"
        ~ format(`{"t":10.0,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                 px, py, SHIFT_CTRL) ~ "\n";
}

string motionLog(int vpX, int vpY, int vpW, int vpH, int px, int py) {
    return viewportLog(vpX, vpY, vpW, vpH) ~ "\n"
        ~ format(`{"t":20.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":1,"mod":%u}`,
                 px, py, SHIFT_CTRL) ~ "\n";
}

string upOnlyLog(int vpX, int vpY, int vpW, int vpH, int px, int py) {
    return viewportLog(vpX, vpY, vpW, vpH) ~ "\n"
        ~ format(`{"t":30.0,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                 px, py, SHIFT_CTRL) ~ "\n";
}

unittest {
    postJson("/api/reset", "");   // default cube, single layer == primary (layer 0)

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));
    auto c = fetchCamera();
    int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;

    cmd("tool.set mesh.topoPen on");

    auto s0 = getJson("/api/tool/state");
    assert(s0["smoothArmed"].type == JSONType.false_, "must start disarmed");

    // Stationary press (no motion yet) — must arm regardless of what (if
    // anything) is under the cursor, and report exactly 1 pass.
    postJson("/api/play-events", downOnlyLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    waitPlayerIdle();

    auto s1 = getJson("/api/tool/state");
    assert(s1["smoothArmed"].type == JSONType.true_,
        "Shift+Ctrl+LMB press must arm the Smooth gesture regardless of what is under the cursor");
    assert(cast(int)s1["smoothPassCount"].integer == 1,
        "a stationary armed press must report exactly 1 pass");

    // Release the stationary press: click == 1 pass, and the arm clears.
    postJson("/api/play-events", upOnlyLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    waitPlayerIdle();

    auto s2 = getJson("/api/tool/state");
    assert(s2["smoothArmed"].type == JSONType.false_, "release must disarm Smooth");

    // A real rightward drag: the measured law is one extra pass per 5px of
    // SIGNED horizontal offset from the press pixel, so +100px is exactly 21.
    postJson("/api/play-events", downOnlyLog(c.vpX, c.vpY, c.width, c.height, cx, cy));
    waitPlayerIdle();
    postJson("/api/play-events", motionLog(c.vpX, c.vpY, c.width, c.height, cx + 100, cy));
    waitPlayerIdle();

    auto s3 = getJson("/api/tool/state");
    assert(s3["smoothArmed"].type == JSONType.true_, "must still be armed mid-drag");
    assert(cast(int)s3["smoothPassCount"].integer == 21,
        format("a +100px horizontal drag must report exactly 21 passes (1 + 100/5); got %s",
               s3["smoothPassCount"].toString));

    // Same cursor distance, purely VERTICAL: the law ignores y outright, so
    // this must still be the click's single pass.
    postJson("/api/play-events", motionLog(c.vpX, c.vpY, c.width, c.height, cx, cy + 100));
    waitPlayerIdle();

    auto s3b = getJson("/api/tool/state");
    assert(cast(int)s3b["smoothPassCount"].integer == 1,
        format("a purely vertical drag must report exactly 1 pass; got %s",
               s3b["smoothPassCount"].toString));

    // Cleanup release, leaving the gesture disarmed.
    postJson("/api/play-events", upOnlyLog(c.vpX, c.vpY, c.width, c.height, cx, cy + 100));
    waitPlayerIdle();

    auto s4 = getJson("/api/tool/state");
    assert(s4["smoothArmed"].type == JSONType.false_, "final release must leave Smooth disarmed");
}
