module test_pie_menu;


import http_command_helpers : commandBody;
// Task 1800 — the pie (radial) menu, driven end to end through the real SDL
// event router (`/api/play-events`), never through a shortcut of its own.
//
// THE LAW UNDER TEST (owner's call 2026-08-23, matching the reference): the
// ring is HELD OPEN by the chord, and only a CLICK selects. Releasing the
// chord dismisses it and never runs anything, however it was aimed.
//
// Five cases, and each is written so that the BROKEN behaviour it guards
// against would show up as a different observable, not as a missing one:
//
//   1. HOLD + CLICK — chord down, aim north, click, then release. Asserts the
//      CAMERA moved to the clicked wedge's view. "The ring opened" is not the
//      claim; "the wedge the direction picked is the one that ran" is.
//   2. RELEASE DISMISSES — the discriminating case for the law above. The
//      chord is released while the ring is AIMED SQUARELY AT A WEDGE, and
//      nothing may run. An implementation that fires on release passes every
//      other case in this file and fails only this one.
//   3. ESC — dismisses with no camera change and no history entry.
//   4. INPUT GRAB — a click that WOULD select a polygon (proved first, with the
//      identical event log and no menu open) selects nothing while the ring is
//      up, and fires the wedge instead. Without the control click this case
//      could pass over a pixel that never hit geometry at all.
//   5. AUTO-REPEAT — the chord is still held after a wedge was clicked, so the
//      OS keeps repeating it. The ring must stay closed; a missing guard pops
//      it straight back up under the cursor.
//
// Coordinates: the fixture header declares the same viewport rect every other
// event fixture here uses, and the aim offsets are CARDINAL (straight up,
// straight right). The player remaps replayed pixels between the recorded and
// live viewport by ndc, which rescales x only — a cardinal aim survives that,
// a diagonal one would skew.

import http_client : testBaseUrl, getJson, postJson;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;

void main() {}

// ---- SDL constants used by the synthetic logs ------------------------------
enum SYM_SPACE   = 32;            // SDLK_SPACE
enum SCAN_SPACE  = 44;            // SDL_SCANCODE_SPACE
enum SYM_ESCAPE  = 27;            // SDLK_ESCAPE
enum SCAN_ESCAPE = 41;            // SDL_SCANCODE_ESCAPE
enum MOD_LCTRL   = 64;            // KMOD_LCTRL

// Where the ring is opened, and the aim offsets. `AIM` clears the dead zone
// (22 px) and stays inside the outer radius (108 px).
enum PIE_CX = 475;
enum PIE_CY = 330;
enum AIM    = 80;

// A pixel over the default cube's front face with the default camera.
// POLYGON mode, not vertex: a face is a big target, so the control click below
// is about the GRAB and not about hitting a 5-pixel vertex dot.
// (`GET /api/pick?x=475&y=300` answers faceIndex 1 on this scene.)
enum PICK_X = 475;
enum PICK_Y = 300;

enum EVENT_HEADER =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}`;

// ---- HTTP helpers (same shape as tests/test_numpad_view.d) -----------------


void runCmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

void waitPlayerIdle() {
    import core.thread : Thread;
    import core.time   : dur;
    for (int i = 0; i < 200; ++i) {
        auto s = parseJSON(get(testBaseUrl() ~ "/api/play-events/status"));
        auto f = "finished" in s;
        if (f is null || f.type != JSONType.FALSE) {
            Thread.sleep(dur!"msecs"(120));
            return;
        }
        Thread.sleep(dur!"msecs"(10));
    }
}

void waitPlayback() {
    import core.thread : Thread;
    import core.time   : dur;
    for (int i = 0; i < 200; ++i) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.TRUE) {
            Thread.sleep(dur!"msecs"(150));
            return;
        }
        Thread.sleep(dur!"msecs"(20));
    }
    assert(false, "play-events did not finish within 4 s");
}

void play(string[] lines) {
    string log = EVENT_HEADER ~ "\n";
    foreach (l; lines) log ~= l ~ "\n";
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success", "/api/play-events failed: " ~ r.toString);
    waitPlayback();
}

// ---- event-line builders ---------------------------------------------------
int g_t = 0;
int nextT() { g_t += 20; return g_t; }

string evMotion(int x, int y) {
    return format(`{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`,
                  nextT(), x, y);
}
string evKeyDown(int sym, int scan, int mod, int repeat = 0) {
    return format(`{"t":%d,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":%d,"repeat":%d}`,
                  nextT(), sym, scan, mod, repeat);
}
string evKeyUp(int sym, int scan, int mod) {
    return format(`{"t":%d,"type":"SDL_KEYUP","sym":%d,"scan":%d,"mod":%d,"repeat":0}`,
                  nextT(), sym, scan, mod);
}
string evClickDown(int x, int y) {
    return format(`{"t":%d,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                  nextT(), x, y);
}
string evClickUp(int x, int y) {
    return format(`{"t":%d,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                  nextT(), x, y);
}

// ---- readbacks -------------------------------------------------------------

/// How many wedges did the last drawn frame put on screen? 0 = no ring.
/// Reads the SAME per-frame record the side panel and status bar write to,
/// under source "pie".
int pieWedgesDrawn() {
    auto j = getJson("/api/buttons/availability");
    int n = 0;
    foreach (b; j["buttons"].array)
        if (b["source"].str == "pie") ++n;
    return n;
}

string cameraPreset() {
    return getJson("/api/camera?viewport=0")["viewPreset"].str;
}

size_t historyLen() {
    return getJson("/api/history")["undo"].array.length;
}

size_t selectedFaceCount() {
    return getJson("/api/selection")["selectedFaces"].array.length;
}

void resetScene() {
    waitPlayerIdle();
    postJson("/api/command", commandBody("scene.reset", "{}"));
    runCmd("prim.cube");
    runCmd("viewport.view Perspective");
    runCmd("select.typeFrom polygon");
}

// ===========================================================================

unittest {  // 1. hold the chord, aim north, CLICK ⇒ the north wedge runs
    resetScene();
    assert(cameraPreset() == "Perspective", "setup: camera should start Perspective");

    play([
        evMotion(PIE_CX, PIE_CY),                       // where the ring opens
        evKeyDown(SYM_SPACE, SCAN_SPACE, MOD_LCTRL),    // Ctrl+Space, held
        evMotion(PIE_CX, PIE_CY - AIM),                 // aim straight up
        evClickDown(PIE_CX, PIE_CY - AIM),              // click WHILE held
        evClickUp(PIE_CX, PIE_CY - AIM),
        evKeyUp(SYM_SPACE, SCAN_SPACE, MOD_LCTRL),      // let go afterwards
    ]);

    // Slot 0 is noon and config/pies.yaml puts "Top" there.
    assert(cameraPreset() == "Top",
        "clicking the noon wedge must run Top, got " ~ cameraPreset());
    assert(pieWedgesDrawn() == 0, "running a wedge must close the ring");
}

unittest {  // 2. releasing the chord DISMISSES — even aimed straight at a wedge
    resetScene();
    immutable before = historyLen();

    play([
        evMotion(PIE_CX, PIE_CY),
        evKeyDown(SYM_SPACE, SCAN_SPACE, MOD_LCTRL),
        evMotion(PIE_CX, PIE_CY - AIM),                 // squarely on the Top wedge
        evKeyUp(SYM_SPACE, SCAN_SPACE, MOD_LCTRL),      // let go WITHOUT clicking
    ]);

    assert(cameraPreset() == "Perspective",
        "a release must never select — the ring was aimed at Top and the camera "
        ~ "went to " ~ cameraPreset());
    assert(pieWedgesDrawn() == 0, "the ring lives only while the chord is held");
    assert(historyLen() == before,
        "a dismissed menu is not an edit — history grew from " ~ before.to!string
        ~ " to " ~ historyLen().to!string);

    // ...and the ring, held open again, still selects by CLICK — this half also
    // pins that index 2 is east.
    play([
        evMotion(PIE_CX, PIE_CY),
        evKeyDown(SYM_SPACE, SCAN_SPACE, MOD_LCTRL),
        evMotion(PIE_CX + AIM, PIE_CY),                 // aim east
        evClickDown(PIE_CX + AIM, PIE_CY),
        evClickUp(PIE_CX + AIM, PIE_CY),
        evKeyUp(SYM_SPACE, SCAN_SPACE, MOD_LCTRL),
    ]);

    assert(cameraPreset() == "Right",
        "slot 2 is east and config/pies.yaml puts Right there, got " ~ cameraPreset());
    assert(pieWedgesDrawn() == 0, "clicking a wedge must close the ring");
}

unittest {  // 3. Esc dismisses: no action, no history entry
    resetScene();
    immutable before = historyLen();

    play([
        evMotion(PIE_CX, PIE_CY),
        evKeyDown(SYM_SPACE, SCAN_SPACE, MOD_LCTRL),
        evMotion(PIE_CX, PIE_CY - AIM),                 // aimed at Top...
        evKeyDown(SYM_ESCAPE, SCAN_ESCAPE, 0),          // ...but dismissed
        evKeyUp(SYM_ESCAPE, SCAN_ESCAPE, 0),
        evKeyUp(SYM_SPACE, SCAN_SPACE, MOD_LCTRL),      // the trailing release
                                                        // of an already-closed
                                                        // ring must be harmless
    ]);

    assert(pieWedgesDrawn() == 0, "Esc must close the ring");
    assert(cameraPreset() == "Perspective",
        "a dismissed pie must not run the wedge it was aimed at, got " ~ cameraPreset());
    assert(historyLen() == before,
        "opening and dismissing a menu is not an edit — history grew from "
        ~ before.to!string ~ " to " ~ historyLen().to!string);
}

unittest {  // 4. the input grab: an open ring eats the click that would pick
    resetScene();

    // CONTROL — the same click, with no menu up, MUST select a vertex.
    // Without this half, case 4 would also pass over empty background.
    play([
        evMotion(PICK_X, PICK_Y),
        evClickDown(PICK_X, PICK_Y),
        evClickUp(PICK_X, PICK_Y),
    ]);
    assert(selectedFaceCount() == 1,
        "control: clicking " ~ PICK_X.to!string ~ "," ~ PICK_Y.to!string
        ~ " must pick a polygon, got " ~ selectedFaceCount().to!string
        ~ " — the fixture cannot show the grab if the pixel hits nothing");

    runCmd("select.drop");
    assert(selectedFaceCount() == 0, "setup: selection cleared");

    // Open the ring so that the pick pixel lands on a wedge (it is AIM px
    // north of the centre, i.e. the noon wedge, outside the dead zone).
    // NO release in this batch: the chord stays held across both of them, the
    // way a hand holds it — the ring exists only for as long as it is down.
    play([
        evMotion(PICK_X, PICK_Y + AIM),
        evKeyDown(SYM_SPACE, SCAN_SPACE, MOD_LCTRL),
    ]);
    assert(pieWedgesDrawn() == 8, "setup: the ring must be up for this case");

    play([
        evMotion(PICK_X, PICK_Y),
        evClickDown(PICK_X, PICK_Y),
        evClickUp(PICK_X, PICK_Y),
        evKeyUp(SYM_SPACE, SCAN_SPACE, MOD_LCTRL),      // the hand lets go last
    ]);

    assert(selectedFaceCount() == 0,
        "an open pie is modal: the click must not reach picking, but "
        ~ selectedFaceCount().to!string ~ " polygons got selected");
    assert(cameraPreset() == "Top",
        "...and it must reach the WEDGE instead — expected the noon wedge to "
        ~ "have run, got camera " ~ cameraPreset());

    runCmd("viewport.view Perspective");
}

unittest {  // 5. the chord is still held after the click — auto-repeat must not
            //    pop the ring back up
    resetScene();

    play([
        evMotion(PIE_CX, PIE_CY),
        evKeyDown(SYM_SPACE, SCAN_SPACE, MOD_LCTRL),
        evMotion(PIE_CX, PIE_CY - AIM),
        evClickDown(PIE_CX, PIE_CY - AIM),
        evClickUp(PIE_CX, PIE_CY - AIM),                // wedge runs, ring closes
    ]);
    assert(cameraPreset() == "Top", "setup: the click must have run the noon wedge");
    assert(pieWedgesDrawn() == 0,   "setup: the ring must be closed after the click");

    // The key is STILL physically down, so the OS keeps sending it. Nothing is
    // swallowing these now (the grab only runs while a ring is up), and each
    // one dispatches `ui.pie` unless the repeat flag is honoured.
    play([
        evKeyDown(SYM_SPACE, SCAN_SPACE, MOD_LCTRL, /*repeat=*/1),
        evKeyDown(SYM_SPACE, SCAN_SPACE, MOD_LCTRL, /*repeat=*/1),
        evKeyDown(SYM_SPACE, SCAN_SPACE, MOD_LCTRL, /*repeat=*/1),
    ]);

    assert(pieWedgesDrawn() == 0,
        "auto-repeat of a held chord must not re-open the ring, but "
        ~ pieWedgesDrawn().to!string ~ " wedges are on screen");

    play([ evKeyUp(SYM_SPACE, SCAN_SPACE, MOD_LCTRL) ]);
    assert(pieWedgesDrawn() == 0, "and it stays closed after the release");

    runCmd("viewport.view Perspective");
}

/// Is the wedge with no label recorded as inert?
bool emptySlotRecordedDisabled() {
    foreach (b; getJson("/api/buttons/availability")["buttons"].array)
        if (b["source"].str == "pie" && b["label"].str.length == 0)
            return b["disabled"].type == JSONType.TRUE;
    return false;
}

unittest {  // 6. the reserved EMPTY slot occupies its place and does nothing
            //
            // WHAT THIS CASE DOES *NOT* TEST, said plainly because the mutation
            // drill caught me claiming otherwise: it does NOT exercise
            // `pieFireHovered`'s `if (btn.disabled) return`. An empty slot
            // carries `Action.init` — kind `tool`, empty id — so a fire would
            // dispatch `activateToolById("")`, which does nothing. "Refused"
            // and "fired a no-op" are the same observation BY CONSTRUCTION, and
            // deleting that guard leaves every assertion here green (measured).
            //
            // What it DOES pin: the NW direction maps to the empty slot and not
            // to a neighbour's command — rotate the slot mapping by one and
            // this reddens with a camera change.
    resetScene();
    immutable before = historyLen();

    // NW = slot 7 of 8, i.e. up-and-left of the centre.
    enum int D = 56;                       // clears the 22 px dead zone on both
                                           // axes, well inside the outer radius
    play([
        evMotion(PIE_CX, PIE_CY),
        evKeyDown(SYM_SPACE, SCAN_SPACE, MOD_LCTRL),
        evMotion(PIE_CX - D, PIE_CY - D),  // aim NW
        evClickDown(PIE_CX - D, PIE_CY - D),
        evClickUp(PIE_CX - D, PIE_CY - D),
        evKeyUp(SYM_SPACE, SCAN_SPACE, MOD_LCTRL),
    ]);

    // It is a slot, not a gap: the menu still has eight wedges, which is what
    // keeps Top/Right/Bottom/Left on their compass points. Then it closed
    // without running anything.
    assert(cameraPreset() == "Perspective",
        "clicking the reserved empty slot must run nothing, camera went to "
        ~ cameraPreset());
    assert(historyLen() == before,
        "...and record nothing: history grew from " ~ before.to!string
        ~ " to " ~ historyLen().to!string);
    assert(pieWedgesDrawn() == 0, "the click still dismisses the ring");
}

unittest {  // 6b. the empty slot is CLASSIFIED inert, which is what greys it and
            //     what keeps it out of the hover highlight
    resetScene();
    play([
        evMotion(PIE_CX, PIE_CY),
        evKeyDown(SYM_SPACE, SCAN_SPACE, MOD_LCTRL),
    ]);
    immutable inert = emptySlotRecordedDisabled();
    play([ evKeyUp(SYM_SPACE, SCAN_SPACE, MOD_LCTRL) ]);

    assert(inert,
        "the unlabelled wedge must be drawn as disabled — that flag is what "
        ~ "denies it the hover highlight and the refusal path; an empty label "
        ~ "alone would leave a live, nameless, clickable wedge");
}

unittest {  // 7. ...and the slot really is DRAWN, all eight of them
    resetScene();
    play([
        evMotion(PIE_CX, PIE_CY),
        evKeyDown(SYM_SPACE, SCAN_SPACE, MOD_LCTRL),
    ]);
    auto n = pieWedgesDrawn();
    play([ evKeyUp(SYM_SPACE, SCAN_SPACE, MOD_LCTRL) ]);

    assert(n == 8,
        "the empty slot is still a slot — eight wedges, not seven, got "
        ~ n.to!string ~ ". Seven would divide the circle by 51.4° and put "
        ~ "Bottom 25° off south.");
}
