// Shortcut configuration coverage for platform-specific quit bindings.
//
// `file.quit` is not dispatched by command tests because it terminates the
// app main loop. This pins the config/parser layer instead: normal config uses
// Ctrl+Q, while macOS UI config uses Cmd+Q.

import shortcuts;
import bindbc.sdl : SDL_Keymod, SDLK_ESCAPE;

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
    assert(neutral.byCommandId["select.drop"].toCanonical() == "escape");
    assert(neutral.commandIdByCanon["escape"] == "select.drop");
}

unittest {
    auto macos = loadShortcuts("config/shortcuts_macos.yaml");
    assert(macos.byCommandId["file.quit"].toCanonical() == "cmd+q");
    assert(macos.commandIdByCanon["cmd+q"] == "file.quit");
    assert(macos.byCommandId["select.drop"].toCanonical() == "escape");
    assert(macos.commandIdByCanon["escape"] == "select.drop");
}
