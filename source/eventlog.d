module eventlog;

import bindbc.sdl;

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

void queryMouse(out int mx, out int my) {
    if (g_mouseOverride) { mx = g_mouseX; my = g_mouseY; }
    else _getMouseState(&mx, &my);
}


// ---------------------------------------------------------------------------
// EventLogger — serialises SDL events to a text file with ms timestamps
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
        file.writefln("# SDL event log — timestamps are ms from program start");
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
                file.writefln("%.3f SDL_QUIT", t);
                break;
            case SDL_KEYDOWN:
            case SDL_KEYUP:
                file.writefln("%.3f %-16s sym=%d scan=%d mod=0x%04x repeat=%d",
                    t,
                    e.type == SDL_KEYDOWN ? "SDL_KEYDOWN" : "SDL_KEYUP",
                    e.key.keysym.sym,
                    cast(int)e.key.keysym.scancode,
                    cast(uint)e.key.keysym.mod,
                    cast(int)e.key.repeat);
                break;
            case SDL_MOUSEBUTTONDOWN:
            case SDL_MOUSEBUTTONUP:
                file.writefln("%.3f %-24s btn=%d x=%d y=%d clicks=%d mod=0x%04x",
                    t,
                    e.type == SDL_MOUSEBUTTONDOWN ? "SDL_MOUSEBUTTONDOWN"
                                                  : "SDL_MOUSEBUTTONUP",
                    e.button.button, e.button.x, e.button.y,
                    cast(int)e.button.clicks, cast(uint)SDL_GetModState());
                break;
            case SDL_MOUSEMOTION:
                file.writefln("%.3f SDL_MOUSEMOTION          x=%d y=%d xrel=%d yrel=%d state=0x%x mod=0x%04x",
                    t, e.motion.x, e.motion.y,
                    e.motion.xrel, e.motion.yrel, e.motion.state,
                    cast(uint)SDL_GetModState());
                break;
            case SDL_MOUSEWHEEL:
                file.writefln("%.3f SDL_MOUSEWHEEL            x=%d y=%d",
                    t, e.wheel.x, e.wheel.y);
                break;
            case SDL_WINDOWEVENT:
                if (e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED)
                    file.writefln("%.3f SDL_WINDOWEVENT           sub=%d w=%d h=%d",
                        t, cast(int)e.window.event,
                        e.window.data1, e.window.data2);
                else
                    file.writefln("%.3f SDL_WINDOWEVENT           sub=%d",
                        t, cast(int)e.window.event);
                break;
            case SDL_TEXTINPUT:
                file.writefln("%.3f SDL_TEXTINPUT", t);
                break;
            default:
                file.writefln("%.3f SDL_EVENT                 type=0x%08x", t, e.type);
                break;
        }
        file.flush();
    }
}

// ---------------------------------------------------------------------------
// EventPlayer — replays a recorded event log file
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

    // Load and parse a log file written by EventLogger.
    // Returns true on success.
    bool open(string path) {
        import std.stdio   : File;
        import std.string  : startsWith, stripLeft, stripRight;
        import std.conv    : to, ConvException;
        import std.array   : split;
        import std.algorithm : startsWith;

        File f;
        try { f = File(path, "r"); }
        catch (Exception) { writefln("EventPlayer: cannot open '%s'", path); return false; }

        foreach (raw; f.byLine()) {
            string line = cast(string)raw.idup;
            // Strip trailing whitespace
            while (line.length && (line[$-1] == '\r' || line[$-1] == '\n' || line[$-1] == ' '))
                line = line[0..$-1];
            if (line.length == 0 || line[0] == '#') continue;

            // First token: timestamp
            auto parts = line.split(" ");
            if (parts.length < 2) continue;
            double t;
            try { t = to!double(parts[0]); } catch (ConvException) { continue; }

            // Second token: event type name (may have trailing spaces in log)
            string typeName = parts[1];

            // Remaining tokens: key=value pairs
            import std.string : indexOf;
            int[string] kv;
            foreach (p; parts[2..$]) {
                auto eq = p.indexOf('=');
                if (eq < 0) continue;
                string key = p[0..eq];
                string val = p[eq+1..$];
                try {
                    if (val.length > 2 && val[0..2] == "0x")
                        kv[key] = cast(int)to!uint(val[2..$], 16);
                    else
                        kv[key] = to!int(val);
                } catch (ConvException) {}
            }

            SDL_Event e;
            switch (typeName) {
                case "SDL_QUIT":
                    e.type = SDL_QUIT;
                    break;
                case "SDL_KEYDOWN", "SDL_KEYUP":
                    e.type = typeName == "SDL_KEYDOWN" ? SDL_KEYDOWN : SDL_KEYUP;
                    e.key.keysym.sym      = cast(SDL_Keycode)(kv.get("sym",  0));
                    e.key.keysym.scancode = cast(SDL_Scancode)(kv.get("scan", 0));
                    e.key.keysym.mod      = cast(SDL_Keymod)(kv.get("mod",  0));
                    e.key.repeat          = cast(ubyte)(kv.get("repeat", 0));
                    break;
                case "SDL_MOUSEBUTTONDOWN", "SDL_MOUSEBUTTONUP":
                    e.type        = typeName == "SDL_MOUSEBUTTONDOWN"
                                  ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
                    e.button.button = cast(ubyte)(kv.get("btn",    1));
                    e.button.x      = cast(int)  (kv.get("x",      0));
                    e.button.y      = cast(int)  (kv.get("y",      0));
                    e.button.clicks = cast(ubyte)(kv.get("clicks", 1));
                    e.button.state  = e.type == SDL_MOUSEBUTTONDOWN
                                    ? SDL_PRESSED : SDL_RELEASED;
                    entries ~= Entry(t, e, cast(SDL_Keymod)(kv.get("mod", 0)));
                    continue;
                case "SDL_MOUSEMOTION":
                    e.type        = SDL_MOUSEMOTION;
                    e.motion.x    = kv.get("x",    0);
                    e.motion.y    = kv.get("y",    0);
                    e.motion.xrel = kv.get("xrel", 0);
                    e.motion.yrel = kv.get("yrel", 0);
                    e.motion.state= cast(uint)(kv.get("state", 0));
                    entries ~= Entry(t, e, cast(SDL_Keymod)(kv.get("mod", 0)));
                    continue;
                case "SDL_MOUSEWHEEL":
                    e.type    = SDL_MOUSEWHEEL;
                    e.wheel.x = kv.get("x", 0);
                    e.wheel.y = kv.get("y", 0);
                    break;
                case "SDL_WINDOWEVENT":
                    e.type         = SDL_WINDOWEVENT;
                    e.window.event = cast(ubyte)(kv.get("sub", 0));
                    e.window.data1 = kv.get("w", 0);
                    e.window.data2 = kv.get("h", 0);
                    break;
                case "SDL_TEXTINPUT":
                    e.type = SDL_TEXTINPUT;
                    break;
                default:
                    if (typeName == "SDL_EVENT") {
                        e.type = cast(uint)(kv.get("type", 0));
                    } else {
                        continue; // unknown — skip
                    }
                    break;
            }

            entries ~= Entry(t, e);
        }
        f.close();

        startCounter = _perfCounter();
        freq         = _perfFreq();
        active       = entries.length > 0;
        idx          = 0;
        writefln("EventPlayer: loaded %d events from '%s'", entries.length, path);
        return true;
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
            // Restore modifier key state for mouse events so that
            // SDL_GetModState() returns the correct value when the app
            // processes the pushed event (SDL_PushEvent does not update
            // SDL's internal modifier state on macOS).
            // Also update the global mouse-position override so that
            // queryMouse() returns the replayed position for picking code.
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

unittest { // EventLogger.log: SDL_QUIT writes timestamped line
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

    assert(readText(path).stripRight() == "100.000 SDL_QUIT");
}

unittest { // EventLogger.log: SDL_KEYDOWN writes sym/scan/mod/repeat fields
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
    assert(line.canFind("SDL_KEYDOWN"), line);
    assert(line.canFind("sym=97"),      line);
    assert(line.canFind("scan=4"),      line);
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

unittest { // EventPlayer.open: parse multiple event types from temp file
    import std.file : write, remove, tempDir;
    import std.path : buildPath;

    _mock_PerfCounter = function() { return 0UL; };
    _mock_PerfFreq    = function() { return 1000UL; };
    scope(exit) { _mock_PerfCounter = null; _mock_PerfFreq = null; }

    string path = buildPath(tempDir(), "ep_parse_test.txt");
    scope(exit) remove(path);

    write(path,
        "# comment\n" ~
        "0.000 SDL_QUIT\n" ~
        "1.000 SDL_KEYDOWN sym=97 scan=4 mod=0x0000 repeat=0\n" ~
        "2.000 SDL_KEYUP sym=65 scan=4 mod=0x0000 repeat=0\n" ~
        "3.000 SDL_MOUSEBUTTONDOWN btn=1 x=100 y=200 clicks=1 mod=0x0000\n" ~
        "4.000 SDL_MOUSEMOTION x=110 y=210 xrel=10 yrel=10 state=0x0 mod=0x0000\n" ~
        "5.000 SDL_MOUSEWHEEL x=0 y=-1\n" ~
        "6.000 SDL_WINDOWEVENT sub=5 w=1280 h=720\n"
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