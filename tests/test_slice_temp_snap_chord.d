// Slice tool — the X chord's TEMPORARY snap inversion, press AND release
// (task 0709).
//
// The chord: while X is held in the viewport the Slice tool's effective snap
// state is the inverse of its `snap` panel value; on release it returns. The
// tool implements both halves — `onKeyDown` sets the flag, `onKeyUp` clears
// it — but until task 0709 `processEvent`'s event switch in `app.d` had no
// `case SDL_KEYUP` at all. No key release reached any tool, so the release
// half was unreachable dead code and the inversion LATCHED: one press of X
// left the tool snapping by the inverse for the rest of the session (the flag
// is otherwise cleared only by activate()/deactivate()).
//
// What this file pins, and the mutation each assertion catches:
//
//   1. Press inverts. (Passed before 0709 too — `onKeyDown` was dispatched.
//      Kept as the precondition that makes 2 meaningful: without it, 2 would
//      be satisfied by a chord that never engaged at all.)
//   2. RELEASE RESTORES. This is the defect. Deleting the `case SDL_KEYUP`
//      line from `app.d`'s switch — or the `handleKeyUp` body — puts the
//      release back out of reach and this fails with the latch still on.
//   3. The chord round-trips a second time, so 2 cannot be satisfied by a
//      one-shot clear (e.g. a reset that happens to fire once).
//   4. A release of a DIFFERENT key does not clear the latch. Guards the
//      lazy fix — "any key-up clears it" — which would pass 2 and 3 while
//      making the chord respond to keys it has nothing to do with.
//
// Observability: `snapTempInvert` / `effectiveSnap` were added to the Slice
// tool's `toolStateJson()` by the same task. `snap` alone is the panel value
// and reports nothing about whether the chord is engaged, so before those two
// keys neither the bug nor its fix was visible to a headless test.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

enum string BASE = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(BASE ~ path));
}

void cmd(string argstring) {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
}

void resetCube() {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
}

// ---------------------------------------------------------------------------
// Key press / release, driven through the SAME event router the app uses for
// real input (EventPlayer's direct dispatch -> processEvent). Driving the tool
// method directly would prove nothing here: the defect IS the missing route.
// ---------------------------------------------------------------------------

enum int SDLK_x_     = 120;   // 'x'
enum int SCAN_X      = 27;    // SDL_SCANCODE_X
enum int SDLK_y_     = 121;   // 'y' — the unrelated key for assertion 4
enum int SCAN_Y      = 28;    // SDL_SCANCODE_Y

enum string VIEWPORT_HEADER =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n";

void waitPlayback() {
    foreach (_; 0 .. 200) {
        auto st = getJson("/api/play-events/status");
        if (st["finished"].type == JSONType.TRUE) {
            // Drain guard: the player reports `finished` from the HTTP thread
            // while the main loop may still be inside the frame that consumed
            // the last event. The tool state is written on that thread.
            Thread.sleep(120.msecs);
            return;
        }
        Thread.sleep(20.msecs);
    }
    assert(false, "play-events did not finish within 4 s");
}

void playKey(string type, int sym, int scan) {
    string events = VIEWPORT_HEADER
        ~ format(`{"t":1,"type":"%s","sym":%d,"scan":%d,"mod":0,"repeat":0}`,
                 type, sym, scan) ~ "\n";
    auto r = parseJSON(cast(string) post(BASE ~ "/api/play-events", events));
    assert(r["status"].str == "success", "/api/play-events failed: " ~ r.toString);
    waitPlayback();
}

void keyDown(int sym, int scan) { playKey("SDL_KEYDOWN", sym, scan); }
void keyUp  (int sym, int scan) { playKey("SDL_KEYUP",   sym, scan); }

// ---------------------------------------------------------------------------

struct SnapState {
    bool snap;            // the panel value
    bool tempInvert;      // is the X chord engaged?
    bool effective;       // what the tool actually snaps by
}

SnapState sliceSnapState(string ctx) {
    auto st = getJson("/api/tool/state");
    assert("tool" in st && st["tool"].str == "slice",
        ctx ~ ": /api/tool/state is not the Slice tool's (got "
        ~ st.toString ~ "). Every assertion below would be about nothing.");
    foreach (k; ["snap", "snapTempInvert", "effectiveSnap"])
        assert(k in st,
            ctx ~ ": /api/tool/state has no `" ~ k ~ "` key — the Slice tool "
            ~ "stopped publishing the chord state, so this test can no longer "
            ~ "see the thing it exists to check. Payload: " ~ st.toString);
    return SnapState(st["snap"].boolean,
                     st["snapTempInvert"].boolean,
                     st["effectiveSnap"].boolean);
}

string show(SnapState s) {
    return format("snap=%s snapTempInvert=%s effectiveSnap=%s",
                  s.snap, s.tempInvert, s.effective);
}

void withSliceTool(void delegate() body_) {
    resetCube();
    cmd("tool.set mesh.sliceTool on");
    scope(exit) cmd("tool.set mesh.sliceTool off");
    body_();
}

// ---------------------------------------------------------------------------
// 1 + 2 — press inverts, release restores.
// ---------------------------------------------------------------------------
unittest {
    withSliceTool({
        auto idle = sliceSnapState("fresh session");
        assert(!idle.tempInvert,
            "precondition: a fresh Slice session must not have the X chord "
            ~ "engaged; got " ~ show(idle));
        assert(idle.effective == idle.snap,
            "precondition: with no chord held the effective snap IS the panel "
            ~ "value; got " ~ show(idle));

        keyDown(SDLK_x_, SCAN_X);
        auto held = sliceSnapState("X held");
        assert(held.tempInvert,
            "X down must engage the temporary snap inversion; got " ~ show(held));
        assert(held.effective == !held.snap,
            "while X is held the effective snap must be the INVERSE of the "
            ~ "panel value; got " ~ show(held));

        keyUp(SDLK_x_, SCAN_X);
        auto released = sliceSnapState("X released");
        assert(!released.tempInvert,
            "X UP must clear the temporary snap inversion. It stayed engaged, "
            ~ "which is the task 0709 defect: no `case SDL_KEYUP` in the event "
            ~ "switch means no release ever reaches the tool, so the chord "
            ~ "latches for the rest of the session. Got " ~ show(released));
        assert(released.effective == released.snap,
            "after the release the effective snap must be the panel value "
            ~ "again; got " ~ show(released));
    });
}

// ---------------------------------------------------------------------------
// 3 — the chord round-trips more than once.
// ---------------------------------------------------------------------------
unittest {
    withSliceTool({
        foreach (round; 0 .. 2) {
            keyDown(SDLK_x_, SCAN_X);
            auto held = sliceSnapState(format("round %d, X held", round));
            assert(held.tempInvert && held.effective == !held.snap,
                format("round %d: X down must invert; got %s", round, show(held)));

            keyUp(SDLK_x_, SCAN_X);
            auto rel = sliceSnapState(format("round %d, X released", round));
            assert(!rel.tempInvert && rel.effective == rel.snap,
                format("round %d: X up must restore — the chord must work "
                       ~ "every time, not once; got %s", round, show(rel)));
        }
    });
}

// ---------------------------------------------------------------------------
// 4 — an unrelated key's release leaves the chord alone.
// ---------------------------------------------------------------------------
unittest {
    withSliceTool({
        keyDown(SDLK_x_, SCAN_X);
        assert(sliceSnapState("X held").tempInvert, "precondition: chord engaged");

        keyUp(SDLK_y_, SCAN_Y);
        auto after = sliceSnapState("after an unrelated key release");
        assert(after.tempInvert,
            "releasing a key that is not X must leave the chord engaged — the "
            ~ "release handler is keyed on X, not on 'any key came up'. Got "
            ~ show(after));

        // and X still ends it
        keyUp(SDLK_x_, SCAN_X);
        assert(!sliceSnapState("X finally released").tempInvert,
            "X up must still end the chord after an unrelated release");
    });
}
