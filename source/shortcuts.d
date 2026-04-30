module shortcuts;

import bindbc.sdl;
import std.string : toLower, strip, toUpper;
import std.conv   : to;
import std.format : format;
import std.array  : split;

// ---------------------------------------------------------------------------
// Shortcut — a parsed key binding
// ---------------------------------------------------------------------------

struct Shortcut {
    SDL_Keycode key;   // 0 = unassigned (empty string in YAML)
    bool ctrl;
    bool shift;
    bool alt;

    // Canonical form used as hash key only: "alt+shift+a", "shift+up", etc.
    string toCanonical() const {
        if (key == 0) return "";
        string mods;
        if (alt)   mods ~= "alt+";
        if (ctrl)  mods ~= "ctrl+";
        if (shift) mods ~= "shift+";
        return mods ~ keycodeSpelling(key);
    }

    // Display form for button labels: "Shift+Up", "W", "Alt+L"
    string display() const {
        if (key == 0) return "";
        string mods;
        if (alt)   mods ~= "Alt+";
        if (ctrl)  mods ~= "Ctrl+";
        if (shift) mods ~= "Shift+";
        return mods ~ keycodeDisplaySpelling(key);
    }
}

// ---------------------------------------------------------------------------
// ShortcutTable
// ---------------------------------------------------------------------------

struct ShortcutTable {
    Shortcut[string] byToolId;
    Shortcut[string] byCommandId;
    Shortcut[string] byEditMode;

    // Reverse maps for O(1) lookup on keydown events.
    string[string] toolIdByCanon;
    string[string] commandIdByCanon;
    string[string] editModeByCanon;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

Shortcut parseShortcut(string s) {
    s = s.strip();
    if (s.length == 0) return Shortcut(0, false, false, false);

    string[] tokens;
    foreach (tok; s.split("+"))
        tokens ~= tok.strip();

    if (tokens.length == 0) return Shortcut(0, false, false, false);

    bool ctrl = false, shift = false, alt = false;
    // All tokens except the last are modifiers.
    foreach (tok; tokens[0 .. $ - 1]) {
        string lo = tok.toLower();
        if      (lo == "ctrl")  ctrl  = true;
        else if (lo == "shift") shift = true;
        else if (lo == "alt")   alt   = true;
        else throw new Exception(format("Unknown modifier '%s' in shortcut '%s'", tok, s));
    }

    SDL_Keycode key = parseKeyToken(tokens[$ - 1], s);
    return Shortcut(key, ctrl, shift, alt);
}

private SDL_Keycode parseKeyToken(string tok, string fullShortcut) {
    if (tok.length == 1) {
        char c = tok[0];
        if (c >= 'A' && c <= 'Z') return cast(SDL_Keycode)(SDLK_a + (c - 'A'));
        if (c >= 'a' && c <= 'z') return cast(SDL_Keycode)(SDLK_a + (c - 'a'));
        if (c >= '0' && c <= '9') return cast(SDL_Keycode)(SDLK_0 + (c - '0'));
        if (c == '[') return SDLK_LEFTBRACKET;
        if (c == ']') return SDLK_RIGHTBRACKET;
        if (c == '-') return SDLK_MINUS;
        if (c == '=') return SDLK_EQUALS;
    }

    switch (tok.toLower()) {
        case "up":        return SDLK_UP;
        case "down":      return SDLK_DOWN;
        case "left":      return SDLK_LEFT;
        case "right":     return SDLK_RIGHT;
        case "space":     return SDLK_SPACE;
        case "escape":    return SDLK_ESCAPE;
        case "enter":     return SDLK_RETURN;
        case "return":    return SDLK_RETURN;
        case "tab":       return SDLK_TAB;
        case "backspace": return SDLK_BACKSPACE;
        case "delete":    return SDLK_DELETE;
        default:
            throw new Exception(
                format("Unknown key token '%s' in shortcut '%s'", tok, fullShortcut));
    }
}

// Canonical lowercase spelling of a keycode (for hash keys).
private string keycodeSpelling(SDL_Keycode k) {
    if (k >= SDLK_a && k <= SDLK_z)
        return [cast(char)('a' + (k - SDLK_a))];
    if (k >= SDLK_0 && k <= SDLK_9)
        return [cast(char)('0' + (k - SDLK_0))];
    switch (k) {
        case SDLK_UP:            return "up";
        case SDLK_DOWN:          return "down";
        case SDLK_LEFT:          return "left";
        case SDLK_RIGHT:         return "right";
        case SDLK_SPACE:         return "space";
        case SDLK_ESCAPE:        return "escape";
        case SDLK_RETURN:        return "return";
        case SDLK_TAB:           return "tab";
        case SDLK_BACKSPACE:     return "backspace";
        case SDLK_DELETE:        return "delete";
        case SDLK_LEFTBRACKET:   return "[";
        case SDLK_RIGHTBRACKET:  return "]";
        case SDLK_MINUS:         return "-";
        case SDLK_EQUALS:        return "=";
        default:                 return format("key%d", cast(int)k);
    }
}

// Display spelling (first letter capitalised where applicable).
private string keycodeDisplaySpelling(SDL_Keycode k) {
    if (k >= SDLK_a && k <= SDLK_z)
        return [cast(char)('A' + (k - SDLK_a))];
    if (k >= SDLK_0 && k <= SDLK_9)
        return [cast(char)('0' + (k - SDLK_0))];
    switch (k) {
        case SDLK_UP:            return "Up";
        case SDLK_DOWN:          return "Down";
        case SDLK_LEFT:          return "Left";
        case SDLK_RIGHT:         return "Right";
        case SDLK_SPACE:         return "Space";
        case SDLK_ESCAPE:        return "Escape";
        case SDLK_RETURN:        return "Return";
        case SDLK_TAB:           return "Tab";
        case SDLK_BACKSPACE:     return "Backspace";
        case SDLK_DELETE:        return "Delete";
        case SDLK_LEFTBRACKET:   return "[";
        case SDLK_RIGHTBRACKET:  return "]";
        case SDLK_MINUS:         return "-";
        case SDLK_EQUALS:        return "=";
        default:                 return format("key%d", cast(int)k);
    }
}

// ---------------------------------------------------------------------------
// Build canonical string from an SDL key event (for reverse lookup).
// Returns "" if the key is not representable in our scheme.
// ---------------------------------------------------------------------------

string canonFromEvent(SDL_Keycode sym, SDL_Keymod mod) {
    // Only handle keys we can map.
    bool mappable = false;
    if (sym >= SDLK_a && sym <= SDLK_z)         mappable = true;
    else if (sym >= SDLK_0 && sym <= SDLK_9)    mappable = true;
    else {
        switch (sym) {
            case SDLK_UP: case SDLK_DOWN: case SDLK_LEFT: case SDLK_RIGHT:
            case SDLK_SPACE: case SDLK_RETURN: case SDLK_TAB: case SDLK_BACKSPACE:
            case SDLK_DELETE:
            case SDLK_LEFTBRACKET: case SDLK_RIGHTBRACKET:
            case SDLK_MINUS: case SDLK_EQUALS:
                mappable = true;
                break;
            default: break;
        }
    }
    if (!mappable) return "";

    bool ctrl  = (mod & KMOD_CTRL)  != 0;
    bool shift = (mod & KMOD_SHIFT) != 0;
    bool alt   = (mod & KMOD_ALT)   != 0;

    string mods;
    if (alt)   mods ~= "alt+";
    if (ctrl)  mods ~= "ctrl+";
    if (shift) mods ~= "shift+";
    return mods ~ keycodeSpelling(sym);
}

// ---------------------------------------------------------------------------
// Load shortcuts.yaml
// ---------------------------------------------------------------------------

ShortcutTable loadShortcuts(string path) {
    import dyaml;

    Node root = Loader.fromFile(path).load();
    ShortcutTable tbl;

    void loadSection(string section, ref Shortcut[string] byId, ref string[string] idByCanon) {
        if (!root.containsKey(section)) return;
        foreach (string id, Node val; root[section]) {
            string raw = val.as!string;
            Shortcut sc = parseShortcut(raw);
            byId[id] = sc;
            string canon = sc.toCanonical();
            if (canon.length > 0)
                idByCanon[canon] = id;
        }
    }

    loadSection("tools",     tbl.byToolId,    tbl.toolIdByCanon);
    loadSection("commands",  tbl.byCommandId, tbl.commandIdByCanon);
    loadSection("editmodes", tbl.byEditMode,  tbl.editModeByCanon);

    return tbl;
}
