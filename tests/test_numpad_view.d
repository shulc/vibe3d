module test_numpad_view;

// Task 0215 — numpad view shortcuts.
//
// Numpad 1/2/3 switch the hovered (else active) viewport cell's view,
// toggling to the opposite face on a repeat press of the same key; numpad
// `.` (decimal) always sets Perspective. The shortcut is read via SCANCODE
// (SDL_SCANCODE_KP_1/2/3/PERIOD = 89/90/91/99), not keysym, so it survives
// NumLock OFF — see source/app.d handleKeyDown.
//
// Two checks:
//   1. Step-by-step: press each numpad key in turn and assert the resulting
//      GET /api/camera?viewport=0 {viewPreset, projKind} after every single
//      press (the toggle sequence 1,1,2,2,3,3,.), and that a pre-existing
//      vertex selection survives the whole sequence untouched (view-switch
//      writes never touch selection/editMode/tool — the 0214 invariant).
//   2. End-to-end: replay the static fixture log
//      tests/events/numpad_view_toggle.log (the same 7-key sequence, as
//      literal SDL_KEYDOWN/UP scancode events) through the real event
//      router in one shot and assert the final state is Perspective.

import std.net.curl;
import std.json;
import std.file  : read;
import std.conv  : to;
import std.format : format;

void main() {}

// Wait for any in-flight event-log replay to drain before we reset and play
// our own log — see test_selection.d for the full rationale (a preceding
// test's /api/play-events can still be draining on this worker's shared
// vibe3d instance when this test starts).
void waitPlayerIdle() {
    import core.thread : Thread;
    import core.time   : dur;
    for (int i = 0; i < 200; ++i) {
        auto s = parseJSON(get("http://localhost:8080/api/play-events/status"));
        auto f = "finished" in s;
        if (f is null || f.type != JSONType.FALSE) {
            Thread.sleep(dur!"msecs"(120));
            return;
        }
        Thread.sleep(dur!"msecs"(10));
    }
}

JSONValue getJson(string path) {
    return parseJSON(cast(string)get("http://localhost:8080" ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post("http://localhost:8080" ~ path, body_));
}

void runCmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

void waitPlayback() {
    import core.thread : Thread;
    import core.time   : dur;
    for (int i = 0; i < 200; ++i) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.TRUE) {
            Thread.sleep(dur!"msecs"(120));
            return;
        }
        Thread.sleep(dur!"msecs"(20));
    }
    assert(false, "play-events did not finish within 4 s");
}

// Press one numpad key (scancode-based) via a synthetic KEYDOWN+KEYUP pair,
// same event-log JSON-Lines shape as every other event-driven test. `sym` is
// the real SDL keysym for the NumLock-ON case (SDLK_KP_1 = 1073741913, etc.)
// — irrelevant to routing here (the numpad branch reads scancode only), but
// kept realistic so the fixture also exercises canonFromEvent(sym) safely
// falling through to "" (out of its mappable ranges) rather than accidentally
// matching an unrelated shortcut.
void pressNumpad(int scan, int sym) {
    enum header =
        `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n";
    string events = header
        ~ format(`{"t":1,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":0,"repeat":0}`, sym, scan) ~ "\n"
        ~ format(`{"t":11,"type":"SDL_KEYUP","sym":%d,"scan":%d,"mod":0,"repeat":0}`, sym, scan) ~ "\n";
    auto r = postJson("/api/play-events", events);
    assert(r["status"].str == "success", "/api/play-events failed: " ~ r.toString);
    waitPlayback();
}

enum SCAN_KP_1      = 89;
enum SCAN_KP_2      = 90;
enum SCAN_KP_3      = 91;
enum SCAN_KP_PERIOD = 99;
enum SYM_KP_1      = 1_073_741_913;
enum SYM_KP_2      = 1_073_741_914;
enum SYM_KP_3      = 1_073_741_915;
enum SYM_KP_PERIOD = 1_073_741_923;

void assertCamera(string wantPreset, string wantProj, string ctx) {
    auto cam = getJson("/api/camera?viewport=0");
    assert(cam["viewPreset"].str == wantPreset,
        ctx ~ ": expected viewPreset=" ~ wantPreset ~ ", got " ~ cam["viewPreset"].str);
    assert(cam["projKind"].str == wantProj,
        ctx ~ ": expected projKind=" ~ wantProj ~ ", got " ~ cam["projKind"].str);
}

unittest { // step-by-step toggle sequence + selection preserved throughout
    waitPlayerIdle();
    postJson("/api/reset", "{}");
    runCmd("prim.cube");

    // Baseline: perspective, no toggle history yet.
    assertCamera("Perspective", "Perspective", "initial");

    // Establish a known selection BEFORE touching the view — the invariant
    // under test is that a numpad view switch must not disturb it.
    runCmd("select.typeFrom vertex");
    runCmd("select.element vertex set 0 2");
    auto selBefore = getJson("/api/selection");
    assert(selBefore["selectedVertices"].array.length == 2,
        "setup should have 2 selected vertices, got "
        ~ selBefore["selectedVertices"].array.length.to!string);

    // 1 -> Top
    pressNumpad(SCAN_KP_1, SYM_KP_1);
    assertCamera("Top", "Ortho", "1st press of 1");
    // 1 -> Bottom (toggle to opposite)
    pressNumpad(SCAN_KP_1, SYM_KP_1);
    assertCamera("Bottom", "Ortho", "2nd press of 1");
    // 2 -> Front
    pressNumpad(SCAN_KP_2, SYM_KP_2);
    assertCamera("Front", "Ortho", "1st press of 2");
    // 2 -> Back (toggle to opposite)
    pressNumpad(SCAN_KP_2, SYM_KP_2);
    assertCamera("Back", "Ortho", "2nd press of 2");
    // 3 -> Right
    pressNumpad(SCAN_KP_3, SYM_KP_3);
    assertCamera("Right", "Ortho", "1st press of 3");
    // 3 -> Left (toggle to opposite)
    pressNumpad(SCAN_KP_3, SYM_KP_3);
    assertCamera("Left", "Ortho", "2nd press of 3");
    // . -> Perspective (idempotent)
    pressNumpad(SCAN_KP_PERIOD, SYM_KP_PERIOD);
    assertCamera("Perspective", "Perspective", "1st press of .");
    pressNumpad(SCAN_KP_PERIOD, SYM_KP_PERIOD);
    assertCamera("Perspective", "Perspective", "2nd press of . (idempotent repeat)");

    // Selection + active tool must be untouched by the whole sequence.
    auto selAfter = getJson("/api/selection");
    assert(selAfter["mode"].str == selBefore["mode"].str,
        "numpad view switch must not change edit mode");
    assert(selAfter["selectedVertices"].array.length == 2
        && selAfter["selectedVertices"].array[0].integer == 0
        && selAfter["selectedVertices"].array[1].integer == 2,
        "numpad view switch must preserve the vertex selection, got "
        ~ selAfter["selectedVertices"].toString);

    // Restore perspective so any follow-on test on this worker sees the
    // normal camera (belt-and-suspenders; /api/reset also resets it).
    runCmd("viewport.view Perspective");
}

unittest { // end-to-end: real router replays the static fixture log deterministically
    waitPlayerIdle();
    postJson("/api/reset", "{}");
    runCmd("prim.cube");
    assertCamera("Perspective", "Perspective", "initial (fixture test)");

    auto events = cast(const(void)[])read("tests/events/numpad_view_toggle.log");
    auto playResponse = postJson("/api/play-events", cast(string)events);
    assert(playResponse["status"].str == "success",
        "play-events failed: " ~ playResponse.toString);
    waitPlayback();

    // Sequence in the fixture: 1,1,2,2,3,3,. -> ends on Perspective.
    assertCamera("Perspective", "Perspective", "after numpad_view_toggle.log");

    runCmd("viewport.view Perspective");
}
