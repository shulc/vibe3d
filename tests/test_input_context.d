module test_input_context;

// Task 1810 — a chord means different things depending on where the cursor is.
//
// The claim under test is not "a scoped binding exists" but "the SAME chord at
// the SAME pixel opens a different menu depending on what is under the
// cursor". Both halves are driven through the real SDL router, and the pixel
// is literally identical between them — only the panel's presence changes.
//
// Four cases:
//   1. the readback — `/api/input/context` reports the zone AND which binding
//      wins, with its weight. Without this a test can only see the effect, and
//      "the scoped row won" would be indistinguishable from "the global row
//      won and happened to do the same thing".
//   2. same pixel, panel hidden  ⇒ the viewport menu.
//   3. same pixel, panel shown   ⇒ the Items menu.
//   4. regression — an UNSCOPED chord (W = Move) still fires from inside a
//      panel's zone. Flattening the three legacy sections into the scoped
//      table must not have made any of them zone-sensitive.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;

void main() {}

enum SYM_SPACE  = 32;
enum SCAN_SPACE = 44;
enum MOD_LCTRL  = 64;
enum SYM_W      = 119;   // SDLK_w
enum SCAN_W     = 26;    // SDL_SCANCODE_W

// One pixel, used by BOTH menu cases. It sits inside the 3D viewport and also
// inside the Items panel's (much larger, undocked) rect, which is what makes
// the two cases differ by nothing but the panel.
enum PROBE_X = 400;
enum PROBE_Y = 300;

enum EVENT_HEADER =
    `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}`;

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

int g_t = 0;
int nextT() { g_t += 20; return g_t; }

void play(string[] lines) {
    string log = EVENT_HEADER ~ "\n";
    foreach (l; lines) log ~= l ~ "\n";
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success", "/api/play-events failed: " ~ r.toString);
    waitPlayback();
}

string evMotion(int x, int y) {
    return format(`{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`,
                  nextT(), x, y);
}
string evKeyDown(int sym, int scan, int mod) {
    return format(`{"t":%d,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":%d,"repeat":0}`,
                  nextT(), sym, scan, mod);
}
string evKeyUp(int sym, int scan, int mod) {
    return format(`{"t":%d,"type":"SDL_KEYUP","sym":%d,"scan":%d,"mod":%d,"repeat":0}`,
                  nextT(), sym, scan, mod);
}

/// The labels of every wedge the last drawn frame put on screen — i.e. WHICH
/// MENU is open, not merely whether one is.
string[] pieLabels() {
    string[] out_;
    foreach (b; getJson("/api/buttons/availability")["buttons"].array)
        if (b["source"].str == "pie") out_ ~= b["label"].str;
    return out_;
}

string activeTool() {
    return getJson("/api/buttons/availability")["activeToolId"].str;
}

void openThenClose(int x, int y) {
    play([ evMotion(x, y), evKeyDown(SYM_SPACE, SCAN_SPACE, MOD_LCTRL) ]);
}
void releaseChord() {
    play([ evKeyUp(SYM_SPACE, SCAN_SPACE, MOD_LCTRL) ]);
}

/// Wait until the published zone frame actually reflects `present` for `name`.
///
/// `ui.layerList show` flips a flag; the zone registry only learns about the
/// panel when the NEXT frame draws it. Reading the context straight after the
/// command assumes a frame has already run — true on an idle machine, not true
/// under `-j 8`, where one such read failed once and passed on every isolated
/// re-run. Gating on the observable itself is the fix; a sleep would only move
/// the threshold.
void waitForZone(string name, bool present) {
    import core.thread : Thread;
    import core.time   : dur;
    for (int i = 0; i < 200; ++i) {
        bool have = false;
        foreach (z; getJson("/api/input/context")["zones"].array)
            if (z["name"].str == name) have = true;
        if (have == present) return;
        Thread.sleep(dur!"msecs"(20));
    }
    assert(false, "zone '" ~ name ~ "' never became "
                ~ (present ? "present" : "absent") ~ " in the published frame");
}

void showLayerPanel() { runCmd("ui.layerList show"); waitForZone("layerList", true);  }
void hideLayerPanel() { runCmd("ui.layerList hide"); waitForZone("layerList", false); }

void resetScene() {
    waitPlayerIdle();
    postJson("/api/reset", "{}");
    runCmd("prim.cube");
    hideLayerPanel();
}

// ===========================================================================

unittest {  // 1. the resolution itself is readable, and it changes with the zone
    resetScene();

    auto q = format("/api/input/context?x=%d&y=%d&key=ctrl+space", PROBE_X, PROBE_Y);

    auto overViewport = getJson(q);
    assert(overViewport["zone"].str == "viewport3d",
        "with no panel up, that pixel is the viewport, got " ~ overViewport["zone"].str);
    assert(overViewport["matched"].type == JSONType.TRUE);
    assert(overViewport["binding"]["args"].str == "viewport");
    assert(overViewport["binding"]["weight"].integer == 0,
        "the GLOBAL row (no slots) is what wins here — weight 0");

    showLayerPanel();
    auto overPanel = getJson(q);
    assert(overPanel["zone"].str == "layerList",
        "with the Items panel up, the same pixel is the panel, got " ~ overPanel["zone"].str);
    assert(overPanel["binding"]["args"].str == "layers");
    assert(overPanel["binding"]["weight"].integer == 4,
        "and the ZONE-scoped row wins — weight 4, not the global 0. Without "
        ~ "this the next two cases could pass on the global row alone");

    hideLayerPanel();
}

unittest {  // 2. the chord over the viewport opens the viewport menu
    resetScene();

    openThenClose(PROBE_X, PROBE_Y);
    auto labels = pieLabels();
    releaseChord();

    assert(labels.length == 8,
        "the viewport menu has 8 wedges, got " ~ labels.length.to!string);
    assert(labels[0] == "Top" && labels[2] == "Right",
        "expected the viewport menu, got " ~ labels.to!string);
}

unittest {  // 3. the SAME chord at the SAME pixel, with the panel up, opens the
            //    Items menu
    resetScene();
    showLayerPanel();

    openThenClose(PROBE_X, PROBE_Y);
    auto labels = pieLabels();
    releaseChord();
    hideLayerPanel();

    assert(labels.length == 4,
        "the Items menu has 4 wedges, got " ~ labels.length.to!string
        ~ " — " ~ labels.to!string);
    assert(labels[0] == "Add" && labels[2] == "Delete",
        "expected the Items menu, got " ~ labels.to!string);
}

unittest {  // 4. an UNSCOPED binding stays zone-blind
    resetScene();
    // Whatever the reset leaves armed, it must not already be Move — otherwise
    // this case would pass without W ever being routed.
    assert(activeTool() != "move",
        "setup: Move must not already be armed, got '" ~ activeTool() ~ "'");

    // W is bound in the plain `tools:` section, i.e. with every slot wildcard.
    // Pressed with the cursor inside a PANEL, it must still arm Move — the
    // flattening of the legacy sections into the scoped table must not have
    // made any of them accidentally zone-sensitive.
    showLayerPanel();
    play([
        evMotion(PROBE_X, PROBE_Y),
        evKeyDown(SYM_W, SCAN_W, 0),
        evKeyUp(SYM_W, SCAN_W, 0),
    ]);
    hideLayerPanel();

    assert(activeTool() == "move",
        "W must arm Move from any zone, got '" ~ activeTool() ~ "'");
}
