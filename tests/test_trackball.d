// Trackball viewport navigation (task 0573) — the END-TO-END half.
//
// The arithmetic is pinned in closed form by the module unittests in
// `source/trackball.d` (the circle, the lift, the arc, the blend staircase over
// two pane shapes) and `source/view.d` (the sign, the frame invariants, the
// pane-local conversion). Repeating any of that here would mean this file
// recomputing the law it is supposed to be checking, which proves nothing.
//
// What only a running app can answer is the wiring, so that is all this file
// asks:
//
//   1. With the gesture OFF — the shipped default — an Alt+LMB orbit drag lands
//      on exactly the camera it landed on before, to the digit. That is the
//      "nothing changes for a user who does not use this" claim, end to end.
//   2. With it ON, the same drag from the pane centre orbits the same WAY but
//      more slowly, and still does not bank.
//   3. With it ON, a drag begun near the pane's edge BANKS the camera — and the
//      two-axis orbit it replaces cannot produce a bank at any pixel, so this
//      needs no arithmetic to be decisive.
//   4. The setting is restored, so nothing bleeds into the rest of the suite.

import std.net.curl;
import std.json;
import std.math   : fabs;
import std.conv   : to;
import std.format : format;
import core.thread : Thread;
import core.time   : dur;

void main() {}

immutable baseUrl = "http://localhost:8080";

JSONValue getJson(string path) { return parseJSON(cast(string) get(baseUrl ~ path)); }

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string) post(baseUrl ~ "/api/command", argstring));
    assert(j["status"].str == "ok",
        "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void resetApp() { post(baseUrl ~ "/api/reset", ""); }

/// Play a log WITHOUT resetting first.
///
/// Split from the reset deliberately. `/api/reset` runs `View.reset()`, which
/// clears the PER-CELL trackball override because that is camera state — so a
/// test that sets the override and then calls a reset-then-play helper has
/// silently wiped the thing it is about to assert. (It did: the first version
/// of case 4 below set `viewport on`, called a combined helper, and asserted
/// the gesture ran. It cannot, and the same test asserts three lines later that
/// a reset clears the override.) The GLOBAL setting is unaffected, which is why
/// the other cases can still set it before playing.
void play(string log) {
    auto r = parseJSON(cast(string) post(baseUrl ~ "/api/play-events", log));
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    for (int i = 0; i < 100; ++i) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }
}

void playEvents(string log) { resetApp(); play(log); }

// SDL's KMOD_LALT. The player calls SDL_SetModState with this per event, and
// both the press handler and the motion handler read the live mod state, so it
// has to be on EVERY line of the drag, not just the press.
enum uint kAlt = 0x0100;

/// The live viewport rect, so the synthetic log's VIEWPORT meta line matches it
/// exactly and the player's record-to-current coordinate remap is the identity.
/// Reading it rather than hard-coding it is what keeps this file honest if the
/// runner's default pane ever changes.
struct Pane { int x, y, w, h; }
Pane livePane() {
    auto c = getJson("/api/camera");
    return Pane(cast(int) c["vpX"].integer,   cast(int) c["vpY"].integer,
                cast(int) c["width"].integer, cast(int) c["height"].integer);
}

/// An Alt+LMB drag from (x0,y0) to (x0+dx, y0+dy) in `steps` motion events.
string dragLog(Pane p, int x0, int y0, int dx, int dy, int steps) {
    string s = format(
        `{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
        p.x, p.y, p.w, p.h) ~ "\n";
    s ~= format(
        `{"t":1,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":%d}`,
        x0, y0, kAlt) ~ "\n";
    s ~= format(
        `{"t":2,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%d}`,
        x0, y0, kAlt) ~ "\n";
    foreach (i; 1 .. steps + 1) {
        immutable int mx = x0 + dx * i / steps;
        immutable int my = y0 + dy * i / steps;
        s ~= format(
            `{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":1,"mod":%d}`,
            2 + i, mx, my, kAlt) ~ "\n";
    }
    s ~= format(
        `{"t":%d,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%d}`,
        3 + steps, x0 + dx, y0 + dy, kAlt) ~ "\n";
    return s;
}

struct Cam { double az, el, roll; }
Cam readCam() {
    auto c = getJson("/api/camera");
    return Cam(c["azimuth"].floating, c["elevation"].floating, c["roll"].floating);
}

double asNum(JSONValue v) {
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        default: assert(false, "orientation lane is not a number");
    }
}

/// The camera's stored 3x3, columns right / up / back — the LOSSLESS field.
///
/// The angle chart is the wrong instrument for this gesture and that is a
/// measurement, not an opinion: the trackball rotates about an axis fixed in
/// the SCREEN, so at a tilted camera a purely horizontal drag legitimately
/// moves the reported BANK as well as the heading (from the default camera,
/// elevation 0.4, a 100 px drag reports roll = -0.136 — which is exactly
/// atan2(sin(0.4)*sin(arc), cos(0.4))). That is the documented difference
/// between a trackball and a turntable. The invariants worth asserting are
/// therefore about the COLUMNS, which say what the rotation actually was.
double[9] readOrientation() {
    auto a = getJson("/api/camera")["orientation"].array;
    assert(a.length == 9, "orientation must be nine floats");
    double[9] o;
    foreach (i, ref e; a) o[i] = asNum(e);
    return o;
}

/// Cosine between the same basis column of two orientations. `c` is 0 = right,
/// 1 = up, 2 = back. Both are unit columns, so this is 1.0 iff that axis did
/// not move.
double colDot(double[9] a, double[9] b, int c) {
    return a[c*3+0]*b[c*3+0] + a[c*3+1]*b[c*3+1] + a[c*3+2]*b[c*3+2];
}

unittest { // (1) with the gesture OFF the orbit drag is untouched
    // Set explicitly rather than relying on the boot default: a worker runs
    // several test files against ONE app instance, so "still at its default"
    // is not something this file can assume. That the DEFAULT is off is a
    // unit-level claim and is asserted in `source/trackball.d`.
    cmd("pref.trackball global off");
    cmd("pref.trackball override off");
    auto p = livePane();
    immutable int cx = p.x + p.w / 2, cy = p.y + p.h / 2;

    playEvents(dragLog(p, cx, cy, 100, 60, 10));
    auto off = readCam();

    // The two-axis orbit is a flat 0.005 rad/px on the pointer delta, from the
    // default camera (azimuth 0.5, elevation 0.4): a +100/+60 drag lands on
    // 0.5 - 0.5 = 0.0 and 0.4 + 0.3 = 0.7, with the horizon dead level.
    assert(fabs(off.az - 0.0) < 1e-4,
        "trackball off: azimuth must be the two-axis result 0.0, got "
        ~ off.az.to!string);
    assert(fabs(off.el - 0.7) < 1e-4,
        "trackball off: elevation must be the two-axis result 0.7, got "
        ~ off.el.to!string);
    assert(fabs(off.roll) < 1e-6,
        "trackball off: the two-axis orbit cannot bank the camera, got "
        ~ off.roll.to!string);
}

unittest { // (2) ON, from the pane centre: same direction, slower, still level
    scope(exit) cmd("pref.trackball global off");

    auto p = livePane();
    immutable int cx = p.x + p.w / 2, cy = p.y + p.h / 2;

    playEvents(dragLog(p, cx, cy, 100, 0, 10));
    auto off = readCam();
    assert(fabs(off.roll) < 1e-6, "baseline must be level");

    // The camera the drag starts from, so the invariant below has a reference.
    resetApp();
    auto start = readOrientation();

    cmd("pref.trackball global on");
    playEvents(dragLog(p, cx, cy, 100, 0, 10));
    auto on    = readCam();
    auto onOri = readOrientation();

    // Reset does not clear the global (it is a user setting, not scene state),
    // so the second run really did have the trackball on.
    immutable double dOff = off.az - 0.5, dOn = on.az - 0.5;
    assert(dOff * dOn > 0.0,
        format("the trackball must turn the heading the SAME WAY as the orbit "
             ~ "it replaces (off %+.4f, on %+.4f)", dOff, dOn));
    // ...and more SLOWLY. The bound is deliberately loose because the exact
    // ratio is PANE-DEPENDENT (2.6x on a 1098-wide pane, ~1.4x on the runner's
    // 650-wide one) and is pinned to 1e-3 at two pane shapes by the module
    // unittests. What this bound has to catch is the named trap — a port that
    // builds the arcball but scales it by the two-axis orbit's flat
    // 0.005 rad/px. That lands ABOVE 1.0 here (the heading moves by the arc
    // divided by cos(elevation)), so any bound below 1 is decisive against it.
    assert(fabs(dOn) < fabs(dOff) * 0.85,
        format("and more SLOWLY — the centre rate is speed/radius, not the "
             ~ "two-axis 0.005 rad/px (off %+.4f, on %+.4f)", dOff, dOn));
    // "A centre press is a pure orbit" stated as the thing it actually means:
    // the arc's axis is SCREEN-UP, so screen-up is a fixed vector of the
    // rotation. Exact, and true at any camera — unlike a claim about the
    // reported bank, which is chart-relative (see `readOrientation`).
    assert(fabs(colDot(start, onOri, 1) - 1.0) < 1e-5,
        format("a horizontal centre drag must rotate about SCREEN-UP, leaving "
             ~ "it fixed; cos = %.9f", colDot(start, onOri, 1)));
    // ...and it really did rotate: the view direction moved.
    assert(colDot(start, onOri, 2) < 0.999,
        "the drag must actually have turned the camera");
}

unittest { // (3) ON, from near the pane edge: the camera BANKS
    scope(exit) cmd("pref.trackball global off");

    auto p = livePane();
    immutable int cy = p.y + p.h / 2;
    // Two pixels in from the pane's right edge — outside the ball (its radius
    // is 95 % of the larger half-extent, so the left and right strips are
    // outside on a landscape pane) without leaving the cell.
    immutable int px = p.x + p.w - 2;

    resetApp();
    auto start = readOrientation();

    cmd("pref.trackball global on");
    playEvents(dragLog(p, px, cy, 0, 150, 10));
    auto on    = readCam();
    auto onOri = readOrientation();

    // The sharp statement: an outside press rotates about the VIEW axis, so the
    // camera does not change where it looks — it only spins. The two-axis orbit
    // can do neither at any pixel.
    assert(fabs(colDot(start, onOri, 2) - 1.0) < 1e-5,
        format("an edge drag must rotate about the VIEW axis, leaving the view "
             ~ "direction fixed; cos = %.9f", colDot(start, onOri, 2)));
    assert(colDot(start, onOri, 0) < 0.999,
        "and it must actually spin the camera about it");

    assert(fabs(on.roll) > 0.02,
        format("a drag begun at the pane edge must BANK the camera; the "
             ~ "two-axis orbit cannot bank at any pixel. got roll=%.6f", on.roll));

    // And the same drag with the gesture off banks not at all — so the bank is
    // the gesture's doing, not the drag's.
    cmd("pref.trackball global off");
    playEvents(dragLog(p, px, cy, 0, 150, 10));
    auto off = readCam();
    assert(fabs(off.roll) < 1e-6,
        "with the trackball off the identical drag must leave the horizon "
        ~ "level, got " ~ off.roll.to!string);
}

unittest { // (4) the per-viewport option and the global override reach the app
    scope(exit) {
        cmd("pref.trackball global off");
        cmd("pref.trackball override off");
        cmd("pref.trackball viewport default");
        cmd("pref.trackball speed 1.0");
    }

    auto p = livePane();
    immutable int cy = p.y + p.h / 2;
    immutable int px = p.x + p.w - 2;

    // Per-cell On with the global still off. The override is set AFTER the
    // reset, because the reset is what clears it — see `play`.
    resetApp();
    cmd("pref.trackball viewport on");
    play(dragLog(p, px, cy, 0, 150, 10));
    assert(fabs(readCam().roll) > 0.02,
        "a per-viewport On must run the gesture with the global off");

    // ...and a reset really does clear it: the identical drag, with nothing
    // touched but the reset, no longer banks.
    resetApp();
    play(dragLog(p, px, cy, 0, 150, 10));
    assert(fabs(readCam().roll) < 1e-6,
        "reset must clear the per-viewport override");

    // The global override makes every cell read the global — which, with the
    // global off, means it turns an explicit On OFF. That is the reference's
    // rule and it is not the obvious one: the flag does not force the gesture
    // ON, it forces every cell to read the global, whatever the global says.
    resetApp();
    cmd("pref.trackball viewport on");
    cmd("pref.trackball override on");
    play(dragLog(p, px, cy, 0, 150, 10));
    assert(fabs(readCam().roll) < 1e-6,
        "the override with the global off must beat an explicit On — it "
        ~ "means 'read the global', not 'switch the gesture on'");
}

unittest { // (5) a bad setting is an error, not a silent fallback
    scope(exit) cmd("pref.trackball global off");

    foreach (bad; ["pref.trackball", "pref.trackball global",
                   "pref.trackball global yes", "pref.trackball nosuch on",
                   "pref.trackball speed abc"]) {
        auto j = parseJSON(cast(string) post(baseUrl ~ "/api/command", bad));
        assert(j["status"].str != "ok",
            "`" ~ bad ~ "` must be rejected — landing on a default here looks "
            ~ "exactly like the gesture was never ported");
    }
}
