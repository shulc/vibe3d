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
    bool gui;          // Cmd on macOS, Windows/Super elsewhere.
    string args;       // Optional baked argstring embedded in the binding:
                       // the text after the key spec ("D ccsds" → "ccsds").
                       // A command with a non-empty schema then runs immediately
                       // with these args injected instead of opening the dialog.
                       // Not part of the canonical/display form (key spec only).

    // Canonical form used as hash key only: "alt+shift+a", "shift+up", etc.
    string toCanonical() const {
        if (key == 0) return "";
        string mods;
        if (alt)   mods ~= "alt+";
        if (ctrl)  mods ~= "ctrl+";
        if (gui)   mods ~= "cmd+";
        if (shift) mods ~= "shift+";
        return mods ~ keycodeSpelling(key);
    }

    // Display form for button labels: "Shift+Up", "W", "Alt+L"
    string display() const {
        if (key == 0) return "";
        string mods;
        version (OSX) {
            if (ctrl) mods ~= "⌃";
            if (alt) mods ~= "⌥";
            if (shift) mods ~= "⇧";
            if (gui) mods ~= "⌘";
        } else {
            if (alt) mods ~= "Alt+";
            if (ctrl) mods ~= "Ctrl+";
            if (gui) mods ~= "Super+";
            if (shift) mods ~= "Shift+";
        }
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

    // canon → baked argstring, for bindings that pin arguments (e.g.
    // `mesh.subdivide: "D ccsds"`). Absent for argless bindings; the dispatcher
    // consults it only in the command branch to run-with-args, no dialog.
    string[string] argsByCanon;

    // The scoped input map (task 1810): every legacy row above flattened with
    // wildcard slots, plus `bindings:`. This is what the KEYBOARD dispatcher
    // resolves against; the maps above remain the answer to "print the shortcut
    // for this id" and are unaffected.
    Binding[] bindings;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

Shortcut parseShortcut(string s) {
    s = s.strip();
    if (s.length == 0) return Shortcut(0, false, false, false, false);

    // A binding may carry a baked argstring after the key spec:
    //   "D ccsds"  →  key spec "D", args "ccsds"
    // The key spec never contains whitespace (modifiers join with '+'), so the
    // first whitespace run separates the key spec from its trailing arguments.
    string args;
    foreach (i, c; s) {
        if (c == ' ' || c == '\t') {
            args = s[i .. $].strip();
            s    = s[0 .. i].strip();
            break;
        }
    }

    string[] tokens;
    foreach (tok; s.split("+"))
        tokens ~= tok.strip();

    if (tokens.length == 0) return Shortcut(0, false, false, false, false);

    bool ctrl = false, shift = false, alt = false, gui = false;
    // All tokens except the last are modifiers.
    foreach (tok; tokens[0 .. $ - 1]) {
        string lo = tok.toLower();
        if      (lo == "ctrl")  ctrl  = true;
        else if (lo == "shift") shift = true;
        else if (lo == "alt")   alt   = true;
        else if (lo == "option") alt   = true;
        else if (lo == "cmd" || lo == "command" || lo == "gui" || lo == "super")
            gui = true;
        else throw new Exception(format("Unknown modifier '%s' in shortcut '%s'", tok, s));
    }

    SDL_Keycode key = parseKeyToken(tokens[$ - 1], s);
    auto sc = Shortcut(key, ctrl, shift, alt, gui);
    sc.args = args;
    return sc;
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
            case SDLK_SPACE: case SDLK_ESCAPE: case SDLK_RETURN:
            case SDLK_TAB: case SDLK_BACKSPACE:
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
    bool gui   = (mod & KMOD_GUI)   != 0;

    string mods;
    if (alt)   mods ~= "alt+";
    if (ctrl)  mods ~= "ctrl+";
    if (gui)   mods ~= "cmd+";
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
            if (canon.length > 0) {
                idByCanon[canon] = id;
                if (sc.args.length > 0)
                    tbl.argsByCanon[canon] = sc.args;
            }
        }
    }

    loadSection("tools",     tbl.byToolId,    tbl.toolIdByCanon);
    loadSection("commands",  tbl.byCommandId, tbl.commandIdByCanon);
    loadSection("editmodes", tbl.byEditMode,  tbl.editModeByCanon);

    // Task 1810 — the same three sections, flattened into the scoped-binding
    // table with every slot left wildcard, plus the `bindings:` list. The
    // legacy maps above stay populated: `byToolId` & co. are what the UI reads
    // to print "W" next to the Move button, and that is a different question
    // from "what does W do right now".
    tbl.bindings = buildBindings(root, tbl, path);

    return tbl;
}

// ===========================================================================
// Scoped bindings (task 1810)
// ===========================================================================

enum BindingKind { tool, command, editMode }

/// One row of the resolved input map: a chord, the context slots it requires,
/// and what it runs. An empty slot is a WILDCARD — it matches anything.
struct Binding {
    Shortcut    key;
    string      canon;      // key.toCanonical(), cached — the match is by this

    // ---- context slots; "" = wildcard --------------------------------------
    string      zone;       // input_zones name
    string      mode;       // selection type name
    string      whenTool;   // armed tool id; a trailing '*' matches by prefix

    // ---- action ------------------------------------------------------------
    BindingKind kind;
    string      id;
    string      args;       // baked argstring, as in `mesh.subdivide: "D ccsds"`

    // ---- tie-break provenance ---------------------------------------------
    bool        scoped_;    // came from `bindings:` rather than a legacy section
    int         legacyRank; // tool 0 / command 1 / editMode 2 — today's order in
                            // handleKeyDown, preserved rather than re-decided
}

/// How specific a binding is. **The weights are powers of two on purpose.**
///
/// With distinct powers, two bindings share a weight if and only if they fill
/// the SAME SET of slots — so "equally specific but along different axes"
/// cannot arise, and the resolver never has to invent a winner between, say, a
/// zone-scoped and a mode-scoped rule. That is exactly the ambiguity the
/// reference's own shipped map contains (its `ctrl-space` has two entries
/// differing only in whether the context slot is present), and it is the one
/// thing here deliberately NOT ported.
///
/// The ORDER zone > whenTool > mode is our decision, not a measurement: where
/// the cursor is is the most concrete thing about a keystroke, and what tool is
/// armed is more specific than which selection type is current.
int bindingWeight(const Binding b) {
    int w = 0;
    if (b.zone.length)     w += 4;
    if (b.whenTool.length) w += 2;
    if (b.mode.length)     w += 1;
    return w;
}

/// Does one slot pattern accept one live value? `""` is the wildcard; a
/// trailing `*` matches by prefix (`sculpt.*`), which is what keeps a family of
/// tools from needing one line each — without it, a chord that behaves the same
/// way under any one of a dozen sibling tools costs a dozen near-identical
/// rows, and the next sibling silently misses out.
bool slotMatches(string pattern, string value) {
    if (pattern.length == 0) return true;
    if (pattern[$ - 1] == '*')
        return value.length >= pattern.length - 1
            && value[0 .. pattern.length - 1] == pattern[0 .. $ - 1];
    return pattern == value;
}

/// Pick the binding that wins for `canon` in this context, or -1.
///
/// PURE, and that is the point: "which binding won" is otherwise invisible —
/// a chord that resolves to the wrong rule and a chord that resolves to
/// nothing look identical from outside (nothing happens, or the wrong thing
/// happens, with no way to tell which rule decided). Everything the rest of
/// the task does hangs off this function being separately checkable.
int resolveBinding(const(Binding)[] bindings, string canon,
                   string zone, string mode, string whenTool) {
    int best = -1, bestW = -1;
    foreach (i, ref b; bindings) {
        if (b.canon != canon) continue;
        if (!slotMatches(b.zone,     zone))     continue;
        if (!slotMatches(b.mode,     mode))     continue;
        if (!slotMatches(b.whenTool, whenTool)) continue;

        immutable int w = bindingWeight(b);
        if (w > bestW) { bestW = w; best = cast(int) i; continue; }
        if (w < bestW) continue;
        // Equal weight ⇒ identical slot SET (see bindingWeight). Break it the
        // way the app already behaved: an explicit `bindings:` row beats a
        // legacy section, and among legacy sections the order handleKeyDown
        // has always used — tool, then command, then editmode — decides.
        // A pair that ties even here cannot exist: the loader refuses it.
        auto cur = bindings[best];
        if (b.scoped_ && !cur.scoped_) { best = cast(int) i; continue; }
        if (!b.scoped_ && cur.scoped_) continue;
        if (b.legacyRank < cur.legacyRank) best = cast(int) i;
    }
    return best;
}

private Binding[] buildBindings(NodeT)(NodeT root, ref ShortcutTable tbl, string path) {
    import dyaml : Node;
    import input_zones : isKnownZone;
    import std.algorithm : canFind;

    Binding[] outb;

    // ---- the three legacy sections, as all-wildcard rows -------------------
    void flatten(string section, BindingKind kind, int rank) {
        if (!root.containsKey(section)) return;
        foreach (string id, Node val; root[section]) {
            Shortcut sc = parseShortcut(val.as!string);
            string canon = sc.toCanonical();
            if (canon.length == 0) continue;      // deliberately unbound ("")
            Binding b;
            b.key = sc; b.canon = canon;
            b.kind = kind; b.id = id; b.args = sc.args;
            b.legacyRank = rank;
            outb ~= b;
        }
    }
    flatten("tools",     BindingKind.tool,     0);
    flatten("commands",  BindingKind.command,  1);
    flatten("editmodes", BindingKind.editMode, 2);

    // ---- the scoped list ---------------------------------------------------
    if (root.containsKey("bindings")) {
        foreach (Node row; root["bindings"]) {
            if (!row.containsKey("key"))
                throw new Exception(format(
                    "shortcuts: a `bindings:` row in '%s' is missing 'key'", path));
            string rawKey = row["key"].as!string;

            Binding b;
            b.key     = parseShortcut(rawKey);
            b.canon   = b.key.toCanonical();
            b.args    = b.key.args;
            b.scoped_ = true;
            if (b.canon.length == 0)
                throw new Exception(format(
                    "shortcuts: `bindings:` row '%s' in '%s' has an unusable key",
                    rawKey, path));

            if (row.containsKey("zone")) {
                b.zone = row["zone"].as!string;
                // A zone nobody publishes is a binding that never fires and
                // never complains — the whole point of the closed list.
                if (!isKnownZone(b.zone))
                    throw new Exception(format(
                        "shortcuts: `bindings:` row '%s' in '%s' names unknown zone '%s'",
                        rawKey, path, b.zone));
            }
            if (row.containsKey("mode"))     b.mode     = row["mode"].as!string;
            if (row.containsKey("whenTool")) b.whenTool = row["whenTool"].as!string;

            int actions = 0;
            if (row.containsKey("command"))  ++actions;
            if (row.containsKey("tool"))     ++actions;
            if (row.containsKey("editmode")) ++actions;
            if (actions != 1)
                throw new Exception(format(
                    "shortcuts: `bindings:` row '%s' in '%s' must have exactly one of "
                    ~ "command / tool / editmode, found %d", rawKey, path, actions));

            if (row.containsKey("command")) {
                b.kind = BindingKind.command;
                // The command form carries its own arguments inline
                // ("ui.pie viewport"), the same shape the baked-argstring
                // bindings already use.
                string line = row["command"].as!string;
                size_t sp = 0;
                while (sp < line.length && line[sp] != ' ' && line[sp] != '\t') ++sp;
                b.id   = line[0 .. sp];
                b.args = sp < line.length ? line[sp .. $].strip : "";
            } else if (row.containsKey("tool")) {
                b.kind = BindingKind.tool;
                b.id   = row["tool"].as!string;
            } else {
                b.kind = BindingKind.editMode;
                b.id   = row["editmode"].as!string;
            }
            outb ~= b;
        }
    }

    // ---- refuse a pair nothing could choose between ------------------------
    foreach (i, ref a; outb)
        foreach (j; i + 1 .. outb.length) {
            auto b = outb[j];
            if (a.canon != b.canon) continue;
            if (a.zone != b.zone || a.mode != b.mode || a.whenTool != b.whenTool)
                continue;
            if (a.scoped_ != b.scoped_) continue;
            if (!a.scoped_ && a.legacyRank != b.legacyRank) continue;
            throw new Exception(format(
                "shortcuts: '%s' in '%s' is bound twice with identical scope "
                ~ "(%s / %s / %s) — '%s' and '%s'; nothing can choose between them",
                a.canon, path,
                a.zone.length     ? a.zone     : "any-zone",
                a.mode.length     ? a.mode     : "any-mode",
                a.whenTool.length ? a.whenTool : "any-tool",
                a.id, b.id));
        }

    return outb;
}
