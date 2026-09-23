// Shortcut configuration coverage for platform-specific quit bindings.
//
// `file.quit` is not dispatched by command tests because it terminates the
// app main loop. This pins the config/parser layer instead: normal config uses
// Ctrl+Q, while macOS UI config uses Cmd+Q.

import shortcuts;
import bindbc.sdl : SDL_Keymod, SDLK_ESCAPE, SDLK_BACKSPACE, SDLK_DELETE, SDLK_p,
                   KMOD_LSHIFT, KMOD_LGUI;

void main() {}

unittest {
    auto sc = parseShortcut("Cmd+Q");
    assert(sc.gui);
    assert(!sc.ctrl);
    assert(sc.toCanonical() == "cmd+q");

    sc = parseShortcut("Command+Q");
    assert(sc.gui);
    assert(sc.toCanonical() == "cmd+q");
}

unittest {
    assert(canonFromEvent(SDLK_ESCAPE, cast(SDL_Keymod)0) == "escape");
}

// A binding may carry a baked argstring after the key spec ("D ccsds").
// The args ride on the Shortcut but never leak into the canonical/display key.
unittest {
    auto sc = parseShortcut("D ccsds");
    assert(sc.args == "ccsds");
    assert(sc.toCanonical() == "d");        // key spec only — args excluded
    assert(sc.display() == "D");

    // Argless bindings leave args empty.
    assert(parseShortcut("Shift+A").args.length == 0);

    // The loader exposes the argstring keyed by canonical form, so the
    // dispatcher can run the command immediately with it (no args dialog).
    auto neutral = loadShortcuts("config/shortcuts.yaml");
    assert(neutral.commandIdByCanon["d"] == "mesh.subdivide");
    assert(neutral.argsByCanon["d"] == "ccsds");
    assert(("shift+a" in neutral.argsByCanon) is null);  // argless → absent
}

unittest {
    auto neutral = loadShortcuts("config/shortcuts.yaml");
    assert(neutral.byCommandId["file.quit"].toCanonical() == "ctrl+q");
    assert(neutral.commandIdByCanon["ctrl+q"] == "file.quit");
    assert(neutral.byCommandId["tool.release"].toCanonical() == "q");
    assert(neutral.commandIdByCanon["q"] == "tool.release");
    assertNoLadderBinding(neutral, "neutral");
}

unittest {
    auto macos = loadShortcuts("config/shortcuts_macos.yaml");
    assert(macos.byCommandId["file.quit"].toCanonical() == "cmd+q");
    assert(macos.commandIdByCanon["cmd+q"] == "file.quit");
    assert(macos.byCommandId["tool.release"].toCanonical() == "q");
    assert(macos.commandIdByCanon["q"] == "tool.release");
    assertNoLadderBinding(macos, "macOS");
}

private void assertNoLadderBinding(ShortcutTable shortcuts, string label) {
    size_t scopedPieRows, qRows;
    foreach (binding; shortcuts.bindings) {
        assert(binding.canon != "escape" && binding.canon != "space",
            label ~ " shortcut map must leave Escape and bare Space to the inline ladder");
        if (binding.scoped_ && binding.canon == "ctrl+space") ++scopedPieRows;
        if (binding.canon == "q") ++qRows;
    }
    assert(scopedPieRows >= 1,
        label ~ " shortcut census found no scoped Ctrl+Space row");
    assert(qRows >= 1,
        label ~ " shortcut census found no Q row");
}

// Task 7131 (wave bugfix S11 items 3 and 16): the component-mode delete keys
// and P, pinned per layout, per chord AND per component mode through the
// loader and the SAME resolver the keyboard dispatcher uses (`resolveBinding`,
// no zone, no tool), with each chord canonicalised from the SDL event rather
// than typed as a string. Law: Backspace and Delete = mesh.delete,
// Shift+Backspace = mesh.remove, on BOTH layouts and in EVERY component mode;
// the old remove chord is gone; P = make polygon. The mode loop is load-
// bearing (task 7132): a Backspace row scoped to `mode: polygon` alone passed
// a polygon-only pin while vertex and edge mode still removed. The two
// already-true surfaces sit above the red ones in each mode (one assert per
// surface; the module stops at its first red, the rest are shown by
// isolation — task card 7131).
private string boundCommand(ShortcutTable tbl, int sym, int mod, string mode) {
    immutable canon = canonFromEvent(sym, cast(SDL_Keymod) mod);
    assert(canon.length, "chord did not canonicalise");
    immutable i = resolveBinding(tbl.bindings, canon, "", mode, "");
    if (i < 0) return "";
    assert(tbl.bindings[i].kind == BindingKind.command);
    return tbl.bindings[i].id;
}

/// The pinned argstring of the resolved row. Make Polygon declares a visible
/// `flip` param, so a bare `P` row opens the args dialog instead of running
/// (`handleKeyDown` -> `tryOpenArgsDialog`); the row must pin its args.
private string boundArgs(ShortcutTable tbl, int sym, int mod, string mode) {
    immutable canon = canonFromEvent(sym, cast(SDL_Keymod) mod);
    immutable i = resolveBinding(tbl.bindings, canon, "", mode, "");
    return i < 0 ? "" : tbl.bindings[i].args;
}

unittest {
    auto linux = loadShortcuts("config/shortcuts.yaml");
    auto macos = loadShortcuts("config/shortcuts_macos.yaml");
    assert(linux.bindings.length > 0 && macos.bindings.length > 0);

    size_t modes;
    foreach (mode; ["vertex", "edge", "polygon"]) {
        immutable at = " (" ~ mode ~ " mode)";
        // Already true on both layouts (green controls).
        assert(boundCommand(linux, SDLK_DELETE, 0, mode) == "mesh.delete",
            "linux delete is not delete" ~ at);
        assert(boundCommand(macos, SDLK_BACKSPACE, 0, mode) == "mesh.delete",
            "macos backspace is not delete" ~ at);

        assert(boundCommand(linux, SDLK_BACKSPACE, 0, mode) == "mesh.delete",
            "linux backspace is not delete" ~ at);
        assert(boundCommand(linux, SDLK_BACKSPACE, KMOD_LSHIFT, mode) == "mesh.remove",
            "linux shift+backspace is not remove" ~ at);
        assert(boundCommand(macos, SDLK_DELETE, 0, mode) == "mesh.delete",
            "macos delete is not delete" ~ at);
        assert(boundCommand(macos, SDLK_BACKSPACE, KMOD_LSHIFT, mode) == "mesh.remove",
            "macos shift+backspace is not remove" ~ at);
        assert(boundCommand(macos, SDLK_BACKSPACE, KMOD_LGUI, mode) == "",
            "macos still binds cmd+backspace" ~ at);
        assert(boundCommand(linux, SDLK_p, 0, mode) == "mesh.makePolygon",
            "linux p is not make polygon" ~ at);
        assert(boundCommand(macos, SDLK_p, 0, mode) == "mesh.makePolygon",
            "macos p is not make polygon" ~ at);
        assert(boundArgs(linux, SDLK_p, 0, mode) == "false",
            "linux p opens the args dialog" ~ at);
        assert(boundArgs(macos, SDLK_p, 0, mode) == "false",
            "macos p opens the args dialog" ~ at);
        ++modes;
    }
    assert(modes == 3, "population floor: the pins did not run in 3 modes");
}
