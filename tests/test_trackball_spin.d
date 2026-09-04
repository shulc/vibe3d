// Trackball MOMENTUM SPIN (task 0582) — the END-TO-END half.
//
// The profiles are pinned in closed form by the module unittests in
// `source/trackball.d` (both time constants, the 4000 ms termination, the
// 1600 ms period, the post-end clamp) and the camera arithmetic by those in
// `source/view.d` (the rate is the last step's, a still release leaves nothing,
// a cancel freezes mid-profile, the total does not depend on how the frames
// fell). None of that is repeated here — a test that recomputes the law it is
// checking proves nothing.
//
// What only a running app can answer is whether the tick EXISTS and is reached:
// whether a release actually leaves the camera moving with no further input,
// whether it stops on its own, whether a press stops it early, and whether a
// user who has not switched the gesture on ever sees any of it. Those are the
// four cases below, and each of them is a claim about wiring, not about
// arithmetic.
//
// Every case reads the camera TWICE with a wait in between and compares the
// nine orientation lanes. Reading once cannot see a spin: a spin is not a
// different camera, it is a camera that keeps changing.

import http_client : testBaseUrl, getJson;
import std.net.curl;
import std.json;
import std.math   : fabs;
import std.conv   : to;
import std.format : format;
import core.thread : Thread;
import core.time   : dur;

void main() {}

alias baseUrl = testBaseUrl;


JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string) post(baseUrl ~ "/api/command", argstring));
    assert(j["status"].str == "ok",
        "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void resetApp() { post(baseUrl ~ "/api/reset", ""); }

void play(string log) {
    auto r = parseJSON(cast(string) post(baseUrl ~ "/api/play-events", log));
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    for (int i = 0; i < 100; ++i) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(20));
    }
}

// SDL's KMOD_LALT — on every line of the drag, because both the press handler
// and the motion handler read the LIVE mod state.
enum uint kAlt = 0x0100;

struct Pane { int x, y, w, h; }
Pane livePane() {
    auto c = getJson("/api/camera");
    return Pane(cast(int) c["vpX"].integer,   cast(int) c["vpY"].integer,
                cast(int) c["width"].integer, cast(int) c["height"].integer);
}

double asNum(JSONValue v) {
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        default: assert(false, "orientation lane is not a number");
    }
}

/// The camera's stored 3x3 — the lossless field, and the only honest readout
/// for this gesture (the angle chart mixes heading and bank at a tilted
/// camera; see tests/test_trackball.d).
double[9] readOrientation() {
    auto a = getJson("/api/camera")["orientation"].array;
    assert(a.length == 9, "orientation must be nine floats");
    double[9] o;
    foreach (i, ref e; a) o[i] = asNum(e);
    return o;
}

/// The largest difference over the nine lanes. Zero iff the camera did not
/// move at all between the two reads.
double lanesApart(double[9] a, double[9] b) {
    double worst = 0;
    foreach (i; 0 .. 9) {
        immutable double d = fabs(a[i] - b[i]);
        if (d > worst) worst = d;
    }
    return worst;
}

/// Is the camera still moving? Two reads `ms` apart.
double movementOver(int ms) {
    auto a = readOrientation();
    Thread.sleep(dur!"msecs"(ms));
    auto b = readOrientation();
    return lanesApart(a, b);
}

/// An Alt+LMB drag from (x0,y0) rightward by `dx`, one motion event per entry
/// of `atMs` — the STAMPS those events carry, in milliseconds.
///
/// **The stamps are the momentum, and they are the `ts` field, not `t`.** `t`
/// is the playback schedule (when the player hands the event over); `ts` is
/// what the event claims about when it happened, and the release rate is the
/// last step's arc divided by the interval between the last two stamps. Every
/// log written before this feature omits `ts`, so its events all carry 0, so
/// no replay of one can arm a spin — which is why this file has to build its
/// own logs and why nothing else in the suite changed.
///
/// The schedule is deliberately left dense (2 ms apart): the whole drag can
/// land in a single frame and the momentum is unaffected, because the stamps
/// are carried by the events rather than measured off the frame clock. That
/// independence is worth having in a test that runs eight-up on a loaded host.
string dragLog(Pane p, int x0, int y0, int dx, const(int)[] atMs) {
    string s = format(
        `{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
        p.x, p.y, p.w, p.h) ~ "\n";
    s ~= format(
        `{"t":1,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":%d}`,
        x0, y0, kAlt) ~ "\n";
    s ~= format(
        `{"t":2,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%d}`,
        x0, y0, kAlt) ~ "\n";
    foreach (i, ts; atMs)
        s ~= format(
            `{"t":%d,"ts":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":1,"mod":%d}`,
            3 + 2 * cast(int)i, ts, x0 + dx * (cast(int)i + 1), y0, kAlt) ~ "\n";
    s ~= format(
        `{"t":%d,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%d}`,
        4 + 2 * cast(int)atMs.length, x0 + dx * cast(int)atMs.length, y0, kAlt) ~ "\n";
    return s;
}

/// A bare press in the middle of the pane, with no modifier — a plain click.
string clickLog(Pane p, int x, int y) {
    return format(
        `{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
        p.x, p.y, p.w, p.h) ~ "\n" ~ format(
        `{"t":1,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        x, y) ~ "\n" ~ format(
        `{"t":2,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        x, y) ~ "\n";
}

/// The drag every case here plays: five steps of 12 px from the pane centre.
///
/// Started at the CENTRE so the arc is a pure orbit and the roll content is
/// zero — this file is about whether the spin happens, and a bank would only
/// add a second thing that could have moved.
///
/// The stamps are 250 ms apart, which makes the spin SLOW — roughly a fifth of
/// a radian over its whole four seconds. That is the number this file wants in
/// both directions: fast enough that two reads 250 ms apart differ by far more
/// than float dust, and slow enough that the camera cannot come back round to
/// where it started between them, which a fast spin genuinely can.
string spinDrag(Pane p) {
    return dragLog(p, p.x + p.w / 2, p.y + p.h / 2, 12, [250, 500, 750, 1000, 1250]);
}

unittest { // (1) with the gesture OFF — the shipped default — a release leaves
           // the camera exactly where the drag left it, for ever
    cmd("pref.trackball global off");
    cmd("pref.trackball override off");
    auto p = livePane();

    resetApp();
    play(spinDrag(p));

    // Half a second of nothing happening, sampled twice. If the tick were
    // running for a user who never switched the gesture on, this is where it
    // would show — and it is the only claim in this file that has to be true
    // for the 99 % of sessions that never touch the trackball.
    assert(movementOver(250) == 0.0,
        "trackball off: nothing may keep moving the camera after a drag");
    assert(movementOver(250) == 0.0,
        "and it must still be motionless a second later");
}

unittest { // (2) ON: the release leaves the camera turning, and it stops by itself
    scope(exit) cmd("pref.trackball global off");
    cmd("pref.trackball global on");
    cmd("pref.trackball override off");
    auto p = livePane();

    resetApp();
    play(spinDrag(p));

    // Still turning, with no input at all. The whole feature, end to end.
    immutable double moving = movementOver(250);
    assert(moving > 1e-4,
        format("a release with the cursor moving must leave the camera "
             ~ "turning; it moved %.3g over 250 ms", moving));

    // ...and it stops on its own. The profile lasts 4000 ms from the release;
    // wait it out with margin, then sample twice. Bit-equality is the right
    // bar here: once the spin ends the tick applies nothing, so the two reads
    // are the same nine floats and not merely close ones.
    Thread.sleep(dur!"msecs"(4200));
    assert(movementOver(250) == 0.0,
        "the settling spin must terminate on its own and leave the camera still");
}

unittest { // (3) ON: a press cancels a running spin
    scope(exit) cmd("pref.trackball global off");
    cmd("pref.trackball global on");
    cmd("pref.trackball override off");
    auto p = livePane();

    resetApp();
    play(spinDrag(p));
    assert(movementOver(200) > 1e-4, "the spin must be running to be cancelled");

    // A plain click in the viewport — no modifier, not a navigation drag.
    play(clickLog(p, p.x + p.w / 2, p.y + p.h / 2));

    // Frozen from that instant. Note WHEN this runs: well inside the 4000 ms
    // the profile would otherwise have kept going for, so this cannot pass by
    // the spin having simply finished.
    assert(movementOver(250) == 0.0,
        "a press must stop the spin dead, not wait for the profile to end");
    assert(movementOver(250) == 0.0, "and it stays stopped");
}

unittest { // (4) ON, but released STILL: no spin
    scope(exit) cmd("pref.trackball global off");
    cmd("pref.trackball global on");
    cmd("pref.trackball override off");
    auto p = livePane();

    // Every motion event on the SAME stamp: the interval between the last two
    // is zero, so there is no rate, so there is no spin. This is the rule that
    // keeps a careful drag — press, position, release — from throwing the
    // camera away at the end, and it is also what every log in the rest of the
    // suite gets for free by not carrying stamps at all.
    resetApp();
    play(dragLog(p, p.x + p.w / 2, p.y + p.h / 2, 12, [250, 250, 250, 250, 250]));
    assert(movementOver(250) == 0.0,
        "a release whose last two motion events share a timestamp leaves no spin");
}

unittest { // (5) the swing setting reaches the app, and its default is the
           // profile that terminates
    scope(exit) {
        cmd("pref.trackball global off");
        cmd("pref.trackball swing off");
    }
    cmd("pref.trackball global on");
    cmd("pref.trackball swing on");
    auto p = livePane();

    resetApp();
    play(spinDrag(p));

    // The swing does NOT terminate: still moving well past the 4000 ms at
    // which a settling spin would have stopped. That is the whole difference
    // between the two arms, and it is the only one visible from out here.
    Thread.sleep(dur!"msecs"(4200));
    assert(movementOver(250) > 1e-6,
        "the swing must still be swinging past 4000 ms");

    // Back to the default arm, and the same drag now DOES stop — so case (2)
    // was reading the default and not an accident of ordering.
    cmd("pref.trackball swing off");
    resetApp();
    play(spinDrag(p));
    Thread.sleep(dur!"msecs"(4200));
    assert(movementOver(250) == 0.0,
        "with swing off the spin terminates again");

    // A press stops the swing too — otherwise switching it on would be a way
    // to make the viewport permanently unusable.
    cmd("pref.trackball swing on");
    resetApp();
    play(spinDrag(p));
    play(clickLog(p, p.x + p.w / 2, p.y + p.h / 2));
    assert(movementOver(250) == 0.0, "a press stops the swing as well");
}

unittest { // (6) a bad swing value is an error, not a silent fallback
    scope(exit) cmd("pref.trackball swing off");
    foreach (bad; ["pref.trackball swing", "pref.trackball swing maybe"]) {
        auto j = parseJSON(cast(string) post(baseUrl ~ "/api/command", bad));
        assert(j["status"].str != "ok",
            "`" ~ bad ~ "` must be rejected");
    }
}
