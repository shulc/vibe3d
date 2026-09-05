// Both rules of `imgui_event_gate` as a table, plus the two checks that keep
// them reachable from `app.d` (task 1850).
//
// The rules are the two halves of one contract: `goesToImGui` (blocks A–E)
// keeps a bare Tab PRESS away from ImGui's focus walk, and
// `keyBelongsToEditor` (blocks F–G) keeps every key away from the editor while
// a text field is being edited — the half that stops a Tab typed into a filter
// box from toggling subpatch. The second is load-bearing BECAUSE of the first:
// once the press no longer reaches ImGui, the focus cannot walk off the field
// by itself, so nothing else stands between that Tab and `mesh.setSubpatch`.
//
// Each group is its OWN `unittest` block on purpose: druntime stops a module at
// its first failed assertion, and this file has to survive several separate
// mutations — a mutation that reddens group A would otherwise hide whatever
// group C had to say.
//
// `SDL_Event`s are built by hand. No SDL runtime is loaded and none is needed:
// the predicate reads two fields of a struct, and the struct's D declaration
// compiles on its own (the same thing `tests/unit/eventlog_test.d` and
// `tests/unit/tool_input_test.d` rely on).
module tests.unit.imgui_event_gate_test;

import bindbc.sdl;
import imgui_event_gate : goesToImGui, keyBelongsToEditor;

private SDL_Event keyEvent(uint type, SDL_Keycode sym, ushort mod = 0) {
    SDL_Event ev;
    ev.type            = type;
    ev.key.type        = type;
    ev.key.keysym.sym  = sym;
    ev.key.keysym.mod  = mod;
    return ev;
}

unittest {
    // ── A ── The rule itself: a bare Tab PRESS never reaches ImGui.
    //
    // Shift+Tab is in here because it is not a different key — it is the same
    // focus walk running backwards, and a predicate that only looked at
    // `mod == 0` would let the reverse walk straight through.
    foreach (mod; [cast(ushort) 0,
                   cast(ushort) KMOD_LSHIFT,
                   cast(ushort) KMOD_RSHIFT,
                   cast(ushort) (KMOD_LSHIFT | KMOD_NUM),
                   cast(ushort) KMOD_CAPS]) {
        auto ev = keyEvent(SDL_KEYDOWN, SDLK_TAB, mod);
        assert(!goesToImGui(&ev),
               "a Tab PRESS with no Ctrl/Alt must NOT reach ImGui: that is the "
               ~ "press ImGui turns into a keyboard-focus move, which is the "
               ~ "whole bug being fixed");
    }
}

unittest {
    // ── B ── The carve-out, sized to ImGui's own condition: with Ctrl or Alt
    // held, ImGui does not raise a tabbing request at all — Ctrl+Tab is the
    // docked-window switcher, a different consumer entirely. Suppressing those
    // would remove a behaviour nobody complained about.
    foreach (mod; [cast(ushort) KMOD_LCTRL,
                   cast(ushort) KMOD_RCTRL,
                   cast(ushort) (KMOD_LCTRL | KMOD_LSHIFT),
                   cast(ushort) KMOD_LALT,
                   cast(ushort) KMOD_RALT]) {
        auto ev = keyEvent(SDL_KEYDOWN, SDLK_TAB, mod);
        assert(goesToImGui(&ev),
               "Ctrl+Tab / Alt+Tab still belong to ImGui: they are not focus "
               ~ "moves, and Ctrl+Tab is the window switcher");
    }
}

unittest {
    // ── C ── ANTI-STICK. The RELEASE is forwarded in every state, including
    // the states whose press was held back.
    //
    // This is not symmetry for its own sake. If a release were suppressed too,
    // ImGui would go on believing Tab is held; its tabbing request reads Tab
    // with key-repeat, so the focus would then walk by itself, frame after
    // frame, with nobody touching the keyboard. A release for a press ImGui
    // never saw costs nothing — ImGui drops a key event that does not change
    // the key's state.
    foreach (mod; [cast(ushort) 0,
                   cast(ushort) KMOD_LSHIFT,
                   cast(ushort) KMOD_LCTRL,
                   cast(ushort) KMOD_LALT]) {
        auto ev = keyEvent(SDL_KEYUP, SDLK_TAB, mod);
        assert(goesToImGui(&ev),
               "a Tab RELEASE must ALWAYS reach ImGui, or ImGui keeps Tab "
               ~ "logically held and walks the focus on its own");
    }
}

unittest {
    // ── D ── Every other key is untouched. Delete and Escape are named
    // explicitly because both are shortcuts this app dispatches itself, and a
    // gate that grew from "Tab" to "the keys we handle" would silently take
    // ImGui's Escape (which closes popups) and its Delete (which edits the
    // text a field is holding) away from it.
    foreach (sym; [SDLK_a, SDLK_DELETE, SDLK_ESCAPE, SDLK_RETURN,
                   SDLK_BACKSPACE, SDLK_SPACE, SDLK_LSHIFT]) {
        auto down = keyEvent(SDL_KEYDOWN, sym);
        auto up   = keyEvent(SDL_KEYUP,   sym);
        assert(goesToImGui(&down),
               "only Tab is held back — every other key press still reaches ImGui");
        assert(goesToImGui(&up),
               "only Tab is held back — every other key release still reaches ImGui");
    }
}

unittest {
    // ── E ── Non-keyboard events are not a keyboard rule's business. The
    // mouse ones matter most: ImGui decides `WantCaptureMouse` from them, and
    // that is what keeps a click on a docked panel out of the 3D viewport.
    foreach (t; [SDL_MOUSEBUTTONDOWN, SDL_MOUSEBUTTONUP, SDL_MOUSEMOTION,
                 SDL_MOUSEWHEEL, SDL_TEXTINPUT, SDL_WINDOWEVENT]) {
        SDL_Event ev;
        ev.type = t;
        assert(goesToImGui(&ev),
               "the rule is about the Tab KEY only — no other event type may "
               ~ "be withheld from ImGui");
    }
}

unittest {
    // ── F ── THE OTHER HALF OF THE CONTRACT: while a text field is being
    // edited, NO key event reaches the editor's own dispatch — which is what
    // stops a Tab typed into the History filter from toggling subpatch.
    //
    // This rule is older than the fix, but the fix PROMOTED it. Before, a Tab
    // pressed in a focused field went to ImGui, the focus walked off onto the
    // neighbouring checkbox, `WantTextInput` went false, and Tab #2 sailed
    // through this gate into `mesh.setSubpatch` (measured on a live instance —
    // task file, П3). Now the press never reaches ImGui, the focus stays put,
    // and this predicate is the only thing left in the way. Nothing in either
    // lane could see it before this block existed.
    foreach (t; [SDL_KEYDOWN, SDL_KEYUP]) {
        assert(!keyBelongsToEditor(t, /*wantTextInput*/ true),
               "a key event while a text field is being edited must NOT reach "
               ~ "the editor's dispatch — this is what keeps Tab-mid-typing "
               ~ "away from the subpatch toggle");
        assert(keyBelongsToEditor(t, /*wantTextInput*/ false),
               "with no field being edited, key events are the editor's: this "
               ~ "is the ordinary shortcut path, Tab toggling subpatch included");
    }
}

unittest {
    // ── G ── …and the swallow is EXACTLY those two event types, no wider.
    //
    // A gate that grew from "keys" to "everything while typing" would freeze
    // the camera and eat the window's close button for as long as a filter box
    // held focus. `SDL_TEXTINPUT` is named first on purpose: it is the event
    // that carries the typed character, and it must keep flowing downstream.
    foreach (t; [SDL_TEXTINPUT, SDL_MOUSEBUTTONDOWN, SDL_MOUSEBUTTONUP,
                 SDL_MOUSEMOTION, SDL_MOUSEWHEEL, SDL_WINDOWEVENT, SDL_QUIT]) {
        assert(keyBelongsToEditor(t, /*wantTextInput*/ true),
               "only KEYDOWN/KEYUP are withheld while a field is edited — no "
               ~ "mouse, window or text-input event may be swallowed");
    }
}

unittest {
    // ── THE EXISTENCE CHECK ──
    //
    // Its own block, deliberately NOT folded into the uniqueness check below:
    // druntime stops a module at its first failed assertion, so one mutation
    // must not be able to hide the other's message.
    //
    // Uniqueness alone does not pin anything. `callers == [the gate module]`
    // is equally satisfied by "the dispatcher routes through the gate" and by
    // "the dispatcher calls nothing at all" — and the second was reached by
    // mutation: deleting `feedImGui(ev);` from the dispatcher left both lanes
    // green while that tree hands ImGui ZERO SDL events (no mouse capture, no
    // WantCaptureMouse, a dead UI) and the whole fix is gone. `scanned > 50`
    // below guards the denominator; this block guards the numerator.
    //
    // THE FILE NAMED HERE IS THE DISPATCHER'S HOME, and it moved: task 0781
    // step 2e lifted `processEvent` out of `app.d`'s `main()` into
    // `InputRouter` (source/input_router.d), taking both calls with it. The
    // scan follows the code rather than the filename it used to sit in — a
    // check still pointed at `app.d` would go red on a pure relocation and,
    // worse, could be "fixed" by pasting the call back into a file that no
    // longer dispatches anything.
    //
    // What it cannot see, said plainly: a call commented out in place still
    // reads as present. That is "someone deleted the fix by hand", not drift.
    import std.path : dirName, buildPath;
    import std.file : readText;
    import std.algorithm : canFind;

    enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    const dispatcher = readText(buildPath(repoRoot, "source", "input_router.d"));

    assert(dispatcher.canFind("feedImGui("),
           "source/input_router.d no longer routes SDL events through the gate "
           ~ "— ImGui is receiving nothing at all, and the uniqueness check "
           ~ "below is green for exactly that tree");
    assert(dispatcher.canFind("keyBelongsToEditor("),
           "source/input_router.d no longer consults keyBelongsToEditor, so "
           ~ "blocks F/G pin nothing: either the text-field gate is gone (a Tab "
           ~ "typed into a filter box now toggles subpatch) or it was re-inlined "
           ~ "past the predicate under test");
}

unittest {
    // ── THE DRIFT CHECK ──
    //
    // Every assertion above stays green if someone puts a direct call to the
    // SDL2 backend back into `app.d`: the predicate would still answer
    // correctly while nothing consulted it. So the thing actually pinned here
    // is "the door is single, and it is the gate module".
    //
    // The scan root is derived from this file's own compile-time path, not from
    // the process's working directory: a cwd-relative walk either throws in a
    // different cwd or, softened with an existence check, scans nothing and
    // passes over an empty input. Same construction as
    // `tests/unit/unittest_census_gate.d`. The denominator is asserted for the same
    // reason — a scan that reached zero files would satisfy every count below.
    import std.path : dirName, buildPath, relativePath;
    import std.file : dirEntries, SpanMode, readText, exists, isDir;
    import std.algorithm : canFind, sort;
    import std.array : array, replace;

    enum repoRoot  = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    enum sourceDir = buildPath(repoRoot, "source");

    // Written split so that this file — which lives outside the scanned tree
    // anyway — cannot be mistaken for a caller by a human reading the grep.
    enum needle = "ImGui_ImplSDL2_" ~ "ProcessEvent(";

    assert(exists(sourceDir) && isDir(sourceDir),
           "drift check cannot run: " ~ sourceDir ~ " is not a directory");

    string[] callers;
    size_t scanned;
    foreach (e; dirEntries(sourceDir, "*.d", SpanMode.depth)) {
        if (!e.isFile) continue;
        scanned++;
        if (readText(e.name).canFind(needle))
            callers ~= relativePath(e.name, repoRoot).replace("\\", "/");
    }

    assert(scanned > 50,
           "drift check scanned only a handful of files — the root is wrong, "
           ~ "and a check over an empty input passes for free");

    sort(callers);
    assert(callers == ["source/imgui_event_gate.d"],
           "the SDL2 backend's event entry point must be called from exactly "
           ~ "one place, source/imgui_event_gate.d, or the Tab rule is simply "
           ~ "bypassed; found instead: " ~ describe(callers));
}

// Formatting helper kept out of the assertion so the message stays readable
// when it fires.
private string describe(string[] xs) {
    import std.array : join;
    import std.conv  : to;
    return xs.length.to!string ~ " caller(s): " ~ xs.join(", ");
}
