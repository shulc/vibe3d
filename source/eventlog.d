module eventlog;

import bindbc.sdl;

import std.stdio : writeln, writefln, File;

// Mouse position source — overridden during event playback so that
// SDL_GetMouseState()-based picking uses replayed coordinates.
private int  g_mouseX, g_mouseY;
private bool g_mouseOverride;

void mouseOverride() {
    g_mouseOverride = true;
}

void queryMouse(out int mx, out int my) {
    if (g_mouseOverride) { mx = g_mouseX; my = g_mouseY; }
    else SDL_GetMouseState(&mx, &my);
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
        startCounter = SDL_GetPerformanceCounter();
        freq         = SDL_GetPerformanceFrequency();
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
        double t = cast(double)(SDL_GetPerformanceCounter() - startCounter)
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

        startCounter = SDL_GetPerformanceCounter();
        freq         = SDL_GetPerformanceFrequency();
        active       = entries.length > 0;
        idx          = 0;
        writefln("EventPlayer: loaded %d events from '%s'", entries.length, path);
        return true;
    }

    // Call once per frame. Pushes all events whose timestamp has elapsed.
    // Returns false when playback is finished.
    bool tick() {
        if (!active) return false;
        double nowMs = cast(double)(SDL_GetPerformanceCounter() - startCounter)
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
                SDL_SetModState(entry.mod);
                mouseX = e.motion.x;
                mouseY = e.motion.y;
                g_mouseX = mouseX; g_mouseY = mouseY; g_mouseOverride = true;
            } else if (e.type == SDL_MOUSEBUTTONDOWN || e.type == SDL_MOUSEBUTTONUP) {
                SDL_SetModState(entry.mod);
                mouseX = e.button.x;
                mouseY = e.button.y;
                g_mouseX = mouseX; g_mouseY = mouseY; g_mouseOverride = true;
                if (e.button.button == SDL_BUTTON_LEFT)
                    mouseDown = (e.type == SDL_MOUSEBUTTONDOWN);
            }
            SDL_PushEvent(&e);
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