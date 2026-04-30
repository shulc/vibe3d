module eventlog;

import bindbc.sdl;
import std.json;
import std.stdio : writeln, writefln, File;

// ---------------------------------------------------------------------------
// SDL call wrappers — replaced by mocks in unittest builds
// ---------------------------------------------------------------------------
version(unittest) {
    private __gshared uint function(int*, int*)  _mock_GetMouseState;
    private __gshared ulong function()           _mock_PerfCounter;
    private __gshared ulong function()           _mock_PerfFreq;
    private __gshared void function(SDL_Keymod)  _mock_SetModState;
    private __gshared int function(SDL_Event*)   _mock_PushEvent;
}

private uint _getMouseState(int* x, int* y) {
    version(unittest) if (_mock_GetMouseState) return _mock_GetMouseState(x, y);
    return SDL_GetMouseState(x, y);
}
private ulong _perfCounter() {
    version(unittest) if (_mock_PerfCounter) return _mock_PerfCounter();
    return SDL_GetPerformanceCounter();
}
private ulong _perfFreq() {
    version(unittest) if (_mock_PerfFreq) return _mock_PerfFreq();
    return SDL_GetPerformanceFrequency();
}
private void _setModState(SDL_Keymod mod) {
    version(unittest) if (_mock_SetModState) { _mock_SetModState(mod); return; }
    SDL_SetModState(mod);
}
private int _pushEvent(SDL_Event* e) {
    version(unittest) if (_mock_PushEvent) return _mock_PushEvent(e);
    return SDL_PushEvent(e);
}

// Mouse position source — overridden during event playback so that
// SDL_GetMouseState()-based picking uses replayed coordinates.
private int  g_mouseX, g_mouseY;
private bool g_mouseOverride;

void mouseOverride() {
    g_mouseOverride = true;
}

/// Update the override-mouse position. The EventPlayer calls this as it
/// dispatches motion events. handleMouseMotion in app.d also calls it so
/// queryMouse() reports the position of the CURRENTLY-being-processed
/// motion event (not the latest dispatched one) — needed for picking
/// during select-drag, where intermediate cursor positions matter.
void setOverrideMouse(int x, int y) {
    g_mouseX        = x;
    g_mouseY        = y;
    g_mouseOverride = true;
}

void queryMouse(out int mx, out int my) {
    if (g_mouseOverride) { mx = g_mouseX; my = g_mouseY; }
    else _getMouseState(&mx, &my);
}

// ---------------------------------------------------------------------------
// Viewport metadata for layout-/aspect-independent event playback.
//
// At record time the logger emits a single VIEWPORT line up front; at replay
// time the player remaps mouse coordinates from the recorded viewport into
// the current one. With identical fovY (the editor uses 45° everywhere),
// only ndc-x changes when aspect changes, and pixel→ndc→pixel round-trips
// stay accurate.
// ---------------------------------------------------------------------------

struct ViewportMeta {
    int   vpX, vpY, vpW, vpH;
    float fovY;
    bool  valid;
}

private __gshared ViewportMeta g_replayCurrentViewport;

/// Tell the EventPlayer what the runtime viewport looks like right now.
/// Call from app.d whenever Layout.resize() runs (record-time observers
/// don't need this — the recorded log carries its own viewport).
void setReplayCurrentViewport(int vpX, int vpY, int vpW, int vpH, float fovY) {
    g_replayCurrentViewport = ViewportMeta(vpX, vpY, vpW, vpH, fovY, true);
}

/// Reset the current viewport (mainly for tests).
void clearReplayCurrentViewport() {
    g_replayCurrentViewport = ViewportMeta.init;
}

// ---------------------------------------------------------------------------
// JSON helper — safe integer read from a JSONValue object
// ---------------------------------------------------------------------------
private long _jsonGet(JSONValue obj, string key, long def = 0) nothrow {
    try { return obj[key].integer; } catch (Exception) { return def; }
}

// ---------------------------------------------------------------------------
// EventLogger — serialises SDL events to a JSON Lines file (one object/line)
// ---------------------------------------------------------------------------

struct EventLogger {
    File  file;
    ulong startCounter;
    ulong freq;
    bool  active;

    void open(string path) {
        file         = File(path, "w");
        startCounter = _perfCounter();
        freq         = _perfFreq();
        active       = true;
        file.flush();
    }

    /// Write the viewport metadata line. Call once after open(), as soon as
    /// the layout is known. Makes the log layout-/aspect-independent on replay.
    void writeViewportMeta(int vpX, int vpY, int vpW, int vpH, float fovY) {
        if (!active) return;
        file.writefln(
            `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":%.6f}`,
            vpX, vpY, vpW, vpH, fovY);
        file.flush();
    }

    void close() {
        if (!active) return;
        file.close();
        active = false;
    }

    void log(ref const SDL_Event e) {
        if (!active) return;
        double t = cast(double)(_perfCounter() - startCounter)
                 / cast(double)freq * 1000.0;
        switch (e.type) {
            case SDL_QUIT:
                file.writefln(`{"t":%.3f,"type":"SDL_QUIT"}`, t);
                break;
            case SDL_KEYDOWN:
            case SDL_KEYUP:
                file.writefln(`{"t":%.3f,"type":"%s","sym":%d,"scan":%d,"mod":%u,"repeat":%d}`,
                    t,
                    e.type == SDL_KEYDOWN ? "SDL_KEYDOWN" : "SDL_KEYUP",
                    e.key.keysym.sym,
                    cast(int)e.key.keysym.scancode,
                    cast(uint)e.key.keysym.mod,
                    cast(int)e.key.repeat);
                break;
            case SDL_MOUSEBUTTONDOWN:
            case SDL_MOUSEBUTTONUP:
                file.writefln(`{"t":%.3f,"type":"%s","btn":%d,"x":%d,"y":%d,"clicks":%d,"mod":%u}`,
                    t,
                    e.type == SDL_MOUSEBUTTONDOWN ? "SDL_MOUSEBUTTONDOWN" : "SDL_MOUSEBUTTONUP",
                    e.button.button, e.button.x, e.button.y,
                    cast(int)e.button.clicks, cast(uint)SDL_GetModState());
                break;
            case SDL_MOUSEMOTION:
                file.writefln(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":%u,"mod":%u}`,
                    t, e.motion.x, e.motion.y,
                    e.motion.xrel, e.motion.yrel, e.motion.state,
                    cast(uint)SDL_GetModState());
                break;
            case SDL_MOUSEWHEEL:
                file.writefln(`{"t":%.3f,"type":"SDL_MOUSEWHEEL","x":%d,"y":%d}`,
                    t, e.wheel.x, e.wheel.y);
                break;
            case SDL_WINDOWEVENT:
                if (e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED)
                    file.writefln(`{"t":%.3f,"type":"SDL_WINDOWEVENT","sub":%d,"w":%d,"h":%d}`,
                        t, cast(int)e.window.event,
                        e.window.data1, e.window.data2);
                else
                    file.writefln(`{"t":%.3f,"type":"SDL_WINDOWEVENT","sub":%d}`,
                        t, cast(int)e.window.event);
                break;
            case SDL_TEXTINPUT:
                file.writefln(`{"t":%.3f,"type":"SDL_TEXTINPUT"}`, t);
                break;
            default:
                file.writefln(`{"t":%.3f,"type":"SDL_EVENT","sdl_type":%u}`, t, e.type);
                break;
        }
        file.flush();
    }
}

// ---------------------------------------------------------------------------
// EventPlayer — replays a recorded JSON Lines event log file
// ---------------------------------------------------------------------------

struct EventPlayer {
    struct Entry { double timeMs; SDL_Event event; SDL_Keymod mod; }
    Entry[] entries;
    size_t  idx;
    ulong   startCounter;
    ulong   freq;
    bool    active;
    int     mouseX, mouseY;   // current replayed cursor position
    bool    mouseDown;        // left button state (for visual feedback)

    // Recorded viewport from the log's VIEWPORT meta line, if present.
    // Used together with the module-level g_replayCurrentViewport to remap
    // pixel coordinates of mouse events on replay.
    ViewportMeta recordedViewport;

    // Load and parse a JSON Lines log file written by EventLogger.
    // Returns true on success.
    bool open(string path) {
        import std.file;
        try { return load(readText(path)); }
        catch (Exception) { writefln("EventPlayer: cannot open '%s'", path); return false; }

    }

    bool load(string data) {
        import std.string : splitLines;
        entries.length = 0;

        foreach (raw; data.splitLines()) {
            string line = cast(string)raw.idup;
            while (line.length && (line[$-1] == '\r' || line[$-1] == '\n' || line[$-1] == ' '))
                line = line[0..$-1];
            if (line.length == 0) continue;

            JSONValue obj;
            try { obj = parseJSON(line); }
            catch (JSONException) { continue; }

            double t;
            try {
                if (obj["t"].type == JSONType.integer)       t = cast(double)obj["t"].integer;
                else if (obj["t"].type == JSONType.uinteger) t = cast(double)obj["t"].uinteger;
                else                                         t = obj["t"].floating;
            } catch (Exception) { continue; }

            string typeName;
            try { typeName = obj["type"].str; } catch (Exception) { continue; }

            SDL_Event e;
            switch (typeName) {
                case "VIEWPORT":
                    // Meta line — store and skip; not an SDL event.
                    recordedViewport.vpX  = cast(int)_jsonGet(obj, "vpX");
                    recordedViewport.vpY  = cast(int)_jsonGet(obj, "vpY");
                    recordedViewport.vpW  = cast(int)_jsonGet(obj, "vpW");
                    recordedViewport.vpH  = cast(int)_jsonGet(obj, "vpH");
                    try { recordedViewport.fovY = cast(float)obj["fovY"].floating; }
                    catch (Exception) { recordedViewport.fovY = 0.7853982f; }
                    recordedViewport.valid = true;
                    continue;
                case "SDL_QUIT":
                    e.type = SDL_QUIT;
                    break;
                case "SDL_KEYDOWN", "SDL_KEYUP":
                    e.type = typeName == "SDL_KEYDOWN" ? SDL_KEYDOWN : SDL_KEYUP;
                    e.key.keysym.sym      = cast(SDL_Keycode)(_jsonGet(obj, "sym"));
                    e.key.keysym.scancode = cast(SDL_Scancode)(_jsonGet(obj, "scan"));
                    e.key.keysym.mod      = cast(SDL_Keymod)(_jsonGet(obj, "mod"));
                    e.key.repeat          = cast(ubyte)(_jsonGet(obj, "repeat"));
                    break;
                case "SDL_MOUSEBUTTONDOWN", "SDL_MOUSEBUTTONUP":
                    e.type          = typeName == "SDL_MOUSEBUTTONDOWN"
                                    ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
                    e.button.button = cast(ubyte)(_jsonGet(obj, "btn",    1));
                    e.button.x      = cast(int)  (_jsonGet(obj, "x"));
                    e.button.y      = cast(int)  (_jsonGet(obj, "y"));
                    e.button.clicks = cast(ubyte)(_jsonGet(obj, "clicks", 1));
                    e.button.state  = e.type == SDL_MOUSEBUTTONDOWN
                                    ? SDL_PRESSED : SDL_RELEASED;
                    entries ~= Entry(t, e, cast(SDL_Keymod)(_jsonGet(obj, "mod")));
                    continue;
                case "SDL_MOUSEMOTION":
                    e.type         = SDL_MOUSEMOTION;
                    e.motion.x     = cast(int)(_jsonGet(obj, "x"));
                    e.motion.y     = cast(int)(_jsonGet(obj, "y"));
                    e.motion.xrel  = cast(int)(_jsonGet(obj, "xrel"));
                    e.motion.yrel  = cast(int)(_jsonGet(obj, "yrel"));
                    e.motion.state = cast(uint)(_jsonGet(obj, "state"));
                    entries ~= Entry(t, e, cast(SDL_Keymod)(_jsonGet(obj, "mod")));
                    continue;
                case "SDL_MOUSEWHEEL":
                    e.type    = SDL_MOUSEWHEEL;
                    e.wheel.x = cast(int)(_jsonGet(obj, "x"));
                    e.wheel.y = cast(int)(_jsonGet(obj, "y"));
                    break;
                case "SDL_WINDOWEVENT":
                    e.type         = SDL_WINDOWEVENT;
                    e.window.event = cast(ubyte)(_jsonGet(obj, "sub"));
                    e.window.data1 = cast(int)  (_jsonGet(obj, "w"));
                    e.window.data2 = cast(int)  (_jsonGet(obj, "h"));
                    break;
                case "SDL_TEXTINPUT":
                    e.type = SDL_TEXTINPUT;
                    break;
                default:
                    if (typeName == "SDL_EVENT") {
                        e.type = cast(uint)(_jsonGet(obj, "sdl_type"));
                    } else {
                        continue; // unknown — skip
                    }
                    break;
            }

            entries ~= Entry(t, e);
        }

        startCounter = _perfCounter();
        freq         = _perfFreq();
        active       = entries.length > 0;
        idx          = 0;
        writefln("EventPlayer: loaded %d events", entries.length);
        return true;
    }

    // Remap (x, y) from the recorded viewport into the current one.
    // No-op if either viewport is unknown (legacy logs without meta).
    private void remapPixel(ref int x, ref int y) const {
        const rec = recordedViewport;
        const cur = g_replayCurrentViewport;
        if (!rec.valid || !cur.valid) return;
        if (rec.vpW <= 0 || rec.vpH <= 0 || cur.vpW <= 0 || cur.vpH <= 0) return;

        // ndc-y factor: invariant of fovY (assuming fixed fovY across versions)
        double ndcYFactor = (cast(double)y - rec.vpY) / (rec.vpH / 2.0);
        // ndc-x factor in [-1..1]
        double ndcX = (cast(double)x - rec.vpX) / (rec.vpW / 2.0) - 1.0;
        // aspect change (fovY constant): ndcX scales by recAspect/curAspect
        double recAspect = cast(double)rec.vpW / cast(double)rec.vpH;
        double curAspect = cast(double)cur.vpW / cast(double)cur.vpH;
        ndcX *= recAspect / curAspect;

        x = cast(int)(cur.vpX + (ndcX + 1.0) * (cur.vpW / 2.0) + 0.5);
        y = cast(int)(cur.vpY + ndcYFactor * (cur.vpH / 2.0) + 0.5);
    }

    // Remap a pixel delta (xrel/yrel). With fovY constant, both axes scale by
    // cur_vpH / rec_vpH (the x aspect-correction and the vpW/vpW factors cancel).
    private void remapDelta(ref int dx, ref int dy) const {
        const rec = recordedViewport;
        const cur = g_replayCurrentViewport;
        if (!rec.valid || !cur.valid) return;
        if (rec.vpH <= 0) return;
        double s = cast(double)cur.vpH / cast(double)rec.vpH;
        dx = cast(int)(dx * s + (dx >= 0 ? 0.5 : -0.5));
        dy = cast(int)(dy * s + (dy >= 0 ? 0.5 : -0.5));
    }

    // Call once per frame. Pushes all events whose timestamp has elapsed.
    // Returns false when playback is finished.
    bool tick() {
        if (!active) return false;
        double nowMs = cast(double)(_perfCounter() - startCounter)
                     / cast(double)freq * 1000.0;
        while (idx < entries.length && entries[idx].timeMs <= nowMs) {
            auto  entry = entries[idx];
            SDL_Event e = entry.event;
            // Remap mouse pixels from the recorded viewport into the current one.
            if (e.type == SDL_MOUSEMOTION) {
                int x = e.motion.x, y = e.motion.y;
                remapPixel(x, y);
                e.motion.x = x; e.motion.y = y;
                int dx = e.motion.xrel, dy = e.motion.yrel;
                remapDelta(dx, dy);
                e.motion.xrel = dx; e.motion.yrel = dy;
            } else if (e.type == SDL_MOUSEBUTTONDOWN || e.type == SDL_MOUSEBUTTONUP) {
                int x = e.button.x, y = e.button.y;
                remapPixel(x, y);
                e.button.x = x; e.button.y = y;
            }
            // Restore modifier key state for mouse events so that
            // SDL_GetModState() returns the correct value when the app
            // processes the pushed event (SDL_PushEvent does not update
            // SDL's internal modifier state on macOS).
            // Also update the global mouse-position override so that
            // queryMouse() returns the replayed position for picking code.
            // (Mouse coords here are post-remap so g_mouseX/Y stay consistent.)
            if (e.type == SDL_MOUSEMOTION) {
                _setModState(entry.mod);
                mouseX = e.motion.x;
                mouseY = e.motion.y;
                g_mouseX = mouseX; g_mouseY = mouseY; g_mouseOverride = true;
            } else if (e.type == SDL_MOUSEBUTTONDOWN || e.type == SDL_MOUSEBUTTONUP) {
                _setModState(entry.mod);
                mouseX = e.button.x;
                mouseY = e.button.y;
                g_mouseX = mouseX; g_mouseY = mouseY; g_mouseOverride = true;
                if (e.button.button == SDL_BUTTON_LEFT)
                    mouseDown = (e.type == SDL_MOUSEBUTTONDOWN);
            }
            _pushEvent(&e);
            ++idx;
        }
        if (idx >= entries.length) {
            active = false;
            writeln("EventPlayer: playback finished");
            return false;
        }
        return true;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version(unittest) private __gshared int g_testPushCount;

unittest { // mouseOverride: queryMouse returns overridden coords without SDL
    g_mouseX        = 42;
    g_mouseY        = 99;
    g_mouseOverride = false;
    mouseOverride();
    assert(g_mouseOverride == true);
    int mx, my;
    queryMouse(mx, my);
    assert(mx == 42 && my == 99);
}

unittest { // queryMouse without override uses SDL_GetMouseState mock
    _mock_GetMouseState = function(int* x, int* y) { *x = 7; *y = 13; return 0u; };
    scope(exit) _mock_GetMouseState = null;
    g_mouseOverride = false;
    int mx, my;
    queryMouse(mx, my);
    assert(mx == 7 && my == 13);
}

unittest { // EventLogger.close() is a no-op when already inactive
    EventLogger logger;
    logger.active = false;
    logger.close();
    assert(!logger.active);
}

unittest { // EventLogger: open sets up state, close marks inactive
    import std.file : remove, exists, tempDir;
    import std.path : buildPath;

    _mock_PerfCounter = function() { return 500UL; };
    _mock_PerfFreq    = function() { return 1000UL; };
    scope(exit) { _mock_PerfCounter = null; _mock_PerfFreq = null; }

    string path = buildPath(tempDir(), "el_open_test.txt");
    scope(exit) if (exists(path)) remove(path);

    EventLogger logger;
    logger.open(path);
    assert(logger.active);
    assert(logger.startCounter == 500);
    assert(logger.freq == 1000);

    logger.close();
    assert(!logger.active);
    assert(exists(path));
}

unittest { // EventLogger.log: SDL_QUIT writes JSON line with timestamp
    import std.file   : remove, exists, readText, tempDir;
    import std.path   : buildPath;
    import std.string : stripRight;

    _mock_PerfCounter = function() { return 1100UL; };
    scope(exit) _mock_PerfCounter = null;

    string path = buildPath(tempDir(), "el_log_quit.txt");
    scope(exit) if (exists(path)) remove(path);

    EventLogger logger;
    logger.file         = File(path, "w");
    logger.startCounter = 1000;  // t = (1100-1000)/1000*1000 = 100ms
    logger.freq         = 1000;
    logger.active       = true;

    SDL_Event e;
    e.type = SDL_QUIT;
    logger.log(e);
    logger.close();

    assert(readText(path).stripRight() == `{"t":100.000,"type":"SDL_QUIT"}`);
}

unittest { // EventLogger.log: SDL_KEYDOWN writes JSON with sym/scan/mod/repeat
    import std.file      : remove, exists, readText, tempDir;
    import std.path      : buildPath;
    import std.string    : stripRight;
    import std.algorithm : canFind;

    _mock_PerfCounter = function() { return 2000UL; };
    scope(exit) _mock_PerfCounter = null;

    string path = buildPath(tempDir(), "el_log_key.txt");
    scope(exit) if (exists(path)) remove(path);

    EventLogger logger;
    logger.file         = File(path, "w");
    logger.startCounter = 1000;  // t = 1000ms
    logger.freq         = 1000;
    logger.active       = true;

    SDL_Event e;
    e.type                = SDL_KEYDOWN;
    e.key.keysym.sym      = cast(SDL_Keycode)97;
    e.key.keysym.scancode = cast(SDL_Scancode)4;
    e.key.keysym.mod      = cast(SDL_Keymod)0;
    e.key.repeat          = 0;
    logger.log(e);
    logger.close();

    string line = readText(path).stripRight();
    assert(line.canFind("SDL_KEYDOWN"),  line);
    assert(line.canFind(`"sym":97`),     line);
    assert(line.canFind(`"scan":4`),     line);
}

unittest { // EventPlayer.tick() returns false immediately when inactive
    EventPlayer player;
    player.active = false;
    assert(player.tick() == false);
}

unittest { // EventPlayer.open: non-existent file returns false
    EventPlayer p;
    assert(!p.open("/nonexistent_path_for_unittest/file.txt"));
}

unittest { // EventPlayer.open: parse multiple event types from JSON Lines file
    import std.file : write, remove, tempDir;
    import std.path : buildPath;

    _mock_PerfCounter = function() { return 0UL; };
    _mock_PerfFreq    = function() { return 1000UL; };
    scope(exit) { _mock_PerfCounter = null; _mock_PerfFreq = null; }

    string path = buildPath(tempDir(), "ep_parse_test.txt");
    scope(exit) remove(path);

    write(path,
        `{"t":0.000,"type":"SDL_QUIT"}` ~ "\n" ~
        `{"t":1.000,"type":"SDL_KEYDOWN","sym":97,"scan":4,"mod":0,"repeat":0}` ~ "\n" ~
        `{"t":2.000,"type":"SDL_KEYUP","sym":65,"scan":4,"mod":0,"repeat":0}` ~ "\n" ~
        `{"t":3.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":100,"y":200,"clicks":1,"mod":0}` ~ "\n" ~
        `{"t":4.000,"type":"SDL_MOUSEMOTION","x":110,"y":210,"xrel":10,"yrel":10,"state":0,"mod":0}` ~ "\n" ~
        `{"t":5.000,"type":"SDL_MOUSEWHEEL","x":0,"y":-1}` ~ "\n" ~
        `{"t":6.000,"type":"SDL_WINDOWEVENT","sub":5,"w":1280,"h":720}` ~ "\n"
    );

    EventPlayer p;
    assert(p.open(path));
    assert(p.entries.length == 7);
    assert(p.entries[0].event.type == SDL_QUIT);
    assert(p.entries[1].event.type == SDL_KEYDOWN);
    assert(p.entries[1].event.key.keysym.sym == 97);
    assert(p.entries[2].event.type == SDL_KEYUP);
    assert(p.entries[2].event.key.keysym.sym == 65);
    assert(p.entries[3].event.type == SDL_MOUSEBUTTONDOWN);
    assert(p.entries[3].event.button.x == 100 && p.entries[3].event.button.y == 200);
    assert(p.entries[4].event.type == SDL_MOUSEMOTION);
    assert(p.entries[4].event.motion.x == 110 && p.entries[4].event.motion.xrel == 10);
    assert(p.entries[5].event.type == SDL_MOUSEWHEEL);
    assert(p.entries[5].event.wheel.y == -1);
    assert(p.entries[6].event.type == SDL_WINDOWEVENT);
    assert(p.entries[6].event.window.data1 == 1280);
    assert(p.active);
    assert(p.freq == 1000);
}

unittest { // EventPlayer.tick: fires only elapsed events, stays active while more remain
    _mock_PerfCounter = function() { return 2000UL; };
    _mock_PerfFreq    = function() { return 1000UL; };
    _mock_SetModState = function(SDL_Keymod m) {};
    _mock_PushEvent   = function(SDL_Event* e) { g_testPushCount++; return 1; };
    scope(exit) {
        _mock_PerfCounter = null; _mock_PerfFreq  = null;
        _mock_SetModState = null; _mock_PushEvent = null;
    }

    EventPlayer p;
    p.active       = true;
    p.startCounter = 0;
    p.freq         = 1000;
    p.idx          = 0;

    SDL_Event e;
    e.type = SDL_QUIT;
    p.entries = [
        EventPlayer.Entry(0.5,    e, cast(SDL_Keymod)0),  // nowMs=2000 → fires
        EventPlayer.Entry(1.5,    e, cast(SDL_Keymod)0),  // fires
        EventPlayer.Entry(5000.0, e, cast(SDL_Keymod)0),  // not yet due
    ];

    g_testPushCount = 0;
    assert(p.tick() == true);
    assert(g_testPushCount == 2);
    assert(p.idx == 2);
}

unittest { // EventPlayer.tick: deactivates when all events are consumed
    _mock_PerfCounter = function() { return 9000UL; };
    _mock_PerfFreq    = function() { return 1000UL; };
    _mock_SetModState = function(SDL_Keymod m) {};
    _mock_PushEvent   = function(SDL_Event* e) { g_testPushCount++; return 1; };
    scope(exit) {
        _mock_PerfCounter = null; _mock_PerfFreq  = null;
        _mock_SetModState = null; _mock_PushEvent = null;
    }

    EventPlayer p;
    p.active       = true;
    p.startCounter = 0;
    p.freq         = 1000;
    p.idx          = 0;

    SDL_Event e;
    e.type = SDL_QUIT;
    p.entries = [EventPlayer.Entry(1.0, e, cast(SDL_Keymod)0)];

    g_testPushCount = 0;
    assert(p.tick() == false);
    assert(!p.active);
    assert(g_testPushCount == 1);
}
