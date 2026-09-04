// test_app_version.d — the binary can name itself, and names itself ONCE
// (task 0641).
//
// WHAT THESE ASSERT, AND WHY THAT IS THE HARD PART
//
// "A version constant is declared" asserts nothing: that was true of no build
// this program ever shipped, and would have been just as true on every day of
// the bug these tests close. The failure being pinned here is not a missing
// constant, it is a SECOND one — a literal written into a surface that agrees
// with the real version on the day it is typed and drifts on the day the
// version is bumped. `/info` shipped exactly that: a hardcoded "1.0" that
// outlived every release after it.
//
// So each test below is written so that a second literal reads a DIFFERENT
// number through it:
//
//   1. no-display     `--version` prints and exits 0 with DISPLAY and
//                     WAYLAND_DISPLAY removed from the environment. The
//                     reports this flag exists for come from machines whose
//                     editor will not start; a flag that needs a window is no
//                     use to them.
//   2. one source     The terminal block and the block the running editor
//                     serves are compared LINE FOR LINE. The served array is
//                     the array the About window draws, so a literal typed
//                     into either surface moves one side of this equality and
//                     not the other.
//   3. dub.json       The mirror in dub.json is compared against what the
//                     binary reports. This is the drift the manifest invites:
//                     two files, one number.
//   4. /info          The endpoint that used to lie now reads the same source.
//   5. About opens    The command behind File ▸ About… is dispatched, and the
//                     editor is still answering afterwards — so an
//                     unregistered command or a throwing draw fails here.
//   6. About draw     The About window's draw body is checked to contain no
//                     version-shaped literal of its own — the one link in the
//                     chain no HTTP request can observe, since nothing over
//                     the wire can see what ImGui put on screen.
//
// Run from the repo root (the runner's cwd), which is where `./vibe3d`,
// `dub.json` and `source/` are.

import http_client : testBaseUrl, getJson;
import std.net.curl;
import std.json;
import std.process : execute, environment, Config;
import std.file    : readText;
import std.string  : splitLines, strip, startsWith, indexOf;
import std.algorithm : canFind, filter, map;
import std.array   : array, join;
import std.ascii   : isDigit, isAlpha;
import std.conv    : to;

void main() {}

alias baseUrl = testBaseUrl;


/// Run `./vibe3d --version` in an environment where SDL video CANNOT come up.
///
/// `Config.newEnv` REPLACES the child environment rather than merging into it —
/// that is what actually removes DISPLAY, since a merged environment has no way
/// to express "unset".
///
/// Removing DISPLAY/WAYLAND_DISPLAY ALONE DOES NOT DISCRIMINATE, and that was
/// measured, not assumed: an implementation that called `SDL_Init(SDL_INIT_
/// VIDEO)` before printing was built and still passed, because SDL quietly
/// falls back to a driver that needs no display server (offscreen/kmsdrm/dummy)
/// and initialises fine. The bogus `SDL_VIDEODRIVER` is what closes that hole —
/// with no driver by that name, SDL video init cannot succeed by any route, so
/// only an implementation that never asks for it can answer.
auto runVersionFlag() {
    string[string] env;
    foreach (k, v; environment.toAA()) {
        // The handles by which a process finds a display server.
        if (k == "DISPLAY" || k == "WAYLAND_DISPLAY" || k == "XDG_SESSION_TYPE")
            continue;
        env[k] = v;
    }
    // No SDL video backend exists under this name, so SDL_Init(SDL_INIT_VIDEO)
    // is guaranteed to fail here.
    env["SDL_VIDEODRIVER"] = "no_such_driver_0641";
    return execute(["./vibe3d", "--version"], env, Config.newEnv);
}

unittest { // 1. --version prints and exits, with no display of any kind
    auto r = runVersionFlag();
    assert(r.status == 0,
        "`vibe3d --version` with no DISPLAY/WAYLAND_DISPLAY exited "
        ~ r.status.to!string ~ ", output was: " ~ r.output);

    auto lines = r.output.splitLines.map!(l => l.strip)
                                    .filter!(l => l.length > 0).array;
    assert(lines.length >= 1,
        "`vibe3d --version` printed nothing (status "
        ~ r.status.to!string ~ ", empty stdout)");
    assert(lines[0].startsWith("vibe3d "),
        "first --version line should name the program, got: " ~ lines[0]);

    // The whole block, not just its first line: an implementation that bails
    // partway through (or into an SDL error path) must not read as a pass.
    assert(lines.length == 4,
        "expected the 4-line identity block, got " ~ lines.length.to!string
        ~ " line(s): " ~ lines.join(" | "));
    assert(lines.canFind!(l => l.startsWith("build: "))
        && lines.canFind!(l => l.startsWith("platform: ")),
        "identity block is missing the build/platform facts: "
        ~ lines.join(" | "));
}

unittest { // 2. ONE source: the terminal block IS the block the editor serves
    auto served = getJson("/api/version");
    string[] servedLines;
    foreach (v; served["lines"].array) servedLines ~= v.str;

    auto r = runVersionFlag();
    assert(r.status == 0, "`vibe3d --version` failed: " ~ r.output);
    auto printed = r.output.splitLines.map!(l => l.strip)
                                      .filter!(l => l.length > 0).array;

    // Line for line. The served array is what the About window draws, so this
    // equality is the whole claim: terminal and UI read one array, not two
    // literals that happen to agree.
    assert(printed == servedLines,
        "`--version` and /api/version disagree.\n"
        ~ "  printed: " ~ printed.join(" | ") ~ "\n"
        ~ "  served:  " ~ servedLines.join(" | "));

    // And the scalar field the rest of the payload is keyed on is the same
    // number that block leads with.
    assert(servedLines[0] == "vibe3d " ~ served["version"].str,
        "/api/version's `lines[0]` (" ~ servedLines[0]
        ~ ") does not carry its own `version` field ("
        ~ served["version"].str ~ ")");
}

unittest { // 3. the dub.json mirror has not drifted from the binary
    auto served  = getJson("/api/version");
    auto reported = served["version"].str;

    auto manifest = parseJSON(readText("dub.json"));
    assert("version" in manifest,
        "dub.json declares no root `version` field — the manifest and the "
        ~ "binary cannot be checked against each other");
    auto declared = manifest["version"].str;

    assert(declared == reported,
        "dub.json says version " ~ declared
        ~ " but the running binary reports " ~ reported
        ~ " — the manifest mirror has drifted from source/app_version.d");

    // A version that is not version-shaped is a version nobody can compare.
    size_t dots = 0;
    foreach (c; reported) {
        if (c == '.') ++dots;
        else assert(c.isDigit || c == '-' || c.isAlpha,
            "unexpected character '" ~ c ~ "' in version " ~ reported);
    }
    assert(dots == 2, "version should be MAJOR.MINOR.PATCH, got " ~ reported);
}

unittest { // 4. /info no longer carries a literal of its own
    auto served = getJson("/api/version");
    auto info   = getJson("/info");
    assert(info["version"].str == served["version"].str,
        "/info reports version " ~ info["version"].str
        ~ " but /api/version reports " ~ served["version"].str
        ~ " — /info is back to a literal of its own");
}

unittest { // 5. the File ▸ About… action actually opens the window
    // The menu item dispatches `ui.about show` through the same handler this
    // POST reaches, so a command that is unregistered, or a draw body that
    // throws the first time it runs, fails HERE rather than in a user's hands.
    //
    // MUST leave the window hidden: it is a floating window, and one left open
    // would sit over the viewport for every later test in this worker's slice
    // and start swallowing their synthetic drags.
    scope(exit) post(baseUrl ~ "/api/command", "ui.about hide");

    void cmd(string line) {
        auto r = parseJSON(cast(string)post(baseUrl ~ "/api/command", line));
        assert(r["status"].str == "ok",
            "/api/command \"" ~ line ~ "\" failed: " ~ r.toString);
    }

    cmd("ui.about show");
    // Liveness: the window is now drawn on every frame. If drawAboutPanel
    // threw, or left the ImGui window stack unbalanced, the editor would not
    // still be answering.
    auto ping = parseJSON(cast(string)get(baseUrl ~ "/api/ping"));
    assert(ping["status"].str == "ok",
        "editor stopped answering after `ui.about show`: " ~ ping.toString);
    // And it is still serving real state, not just the static ping.
    auto model = getJson("/api/model");
    assert(model["vertices"].array.length == 8,
        "scene is wrong after `ui.about show` — expected the 8-vertex startup "
        ~ "cube, got " ~ model["vertices"].array.length.to!string ~ " vertices");

    cmd("ui.about toggle");
    cmd("ui.about hide");
}

unittest { // 6. the About window draws the shared array, not a literal
    // The one link no HTTP request can see: whether the ImGui window renders
    // the shared rows or a string typed into the draw. Checked at the source,
    // because the alternative is asserting glyphs in a framebuffer.
    auto src = readText("source/ui/panels.d");
    auto at  = src.indexOf("void drawAboutPanel(");
    assert(at >= 0, "drawAboutPanel not found in source/ui/panels.d");

    // Slice to the next section banner. The function's doc comment sits ABOVE
    // the signature and so is excluded — a gate that reads its own prose is a
    // gate that fails on a reworded comment.
    auto rest = src[at .. $];
    auto end  = rest.indexOf("\n// ====");
    auto body_ = end >= 0 ? rest[0 .. end] : rest;

    // Strip line comments before scanning: the body explains itself, and the
    // explanation must not be what trips the check.
    string code;
    foreach (line; body_.splitLines) {
        auto c = line.indexOf("//");
        code ~= (c >= 0 ? line[0 .. c] : line) ~ "\n";
    }

    assert(code.canFind("appAboutLines"),
        "drawAboutPanel no longer reads app_version.appAboutLines — the About "
        ~ "window has stopped sharing a source with --version");

    // No digit may appear inside a string literal in the draw. Reading the
    // shared array needs none; printing "vibe3d 0.0.2" cannot avoid one.
    bool inStr = false;
    foreach (i, c; code) {
        if (c == '"' && (i == 0 || code[i - 1] != '\\')) { inStr = !inStr; continue; }
        assert(!(inStr && c.isDigit),
            "drawAboutPanel contains a string literal with a digit in it — "
            ~ "that is a second version literal, which is the drift this "
            ~ "task exists to prevent");
    }
}
