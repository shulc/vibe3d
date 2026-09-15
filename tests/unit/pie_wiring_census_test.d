module tests.unit.pie_wiring_census_test;

import std.file : readText;
import std.string : count, indexOf;
import std.algorithm.searching : canFind;
import tests.unit.census_symbols : blankNonCode;

private string between(string text, string first, string next) {
    auto a = text.indexOf(first);
    auto b = text.indexOf(next, a + first.length);
    assert(a >= 0 && b > a, "U5 production census anchors moved");
    return text[a .. b];
}

private string bodyAt(string code, string marker) {
    auto at = code.indexOf(marker);
    assert(at >= 0, "U5 production body marker moved: " ~ marker);
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "U5 production body lost its opening brace: " ~ marker);
    immutable size_t begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    assert(false, "U5 production body lost its closing brace: " ~ marker);
    return null;
}

unittest { // U5a: input hover owns fixed geometry and unified availability
    auto text = blankNonCode(readText("source/input_router.d"));
    auto mask = between(text, "bool[PIE_SLOTS] pieLiveMask()",
                        "bool processEvent(");
    assert(mask.canFind("live[i] = !buttonUnavailable("),
        "U5a pie live mask ignores the unified availability result");
    auto grip = between(text, "if (g_pie.open)", "feedImGui(ev)");
    assert(grip.canFind("pieHoverAt(") && grip.canFind("g_pie.unitH")
           && grip.canFind("pieLiveMask()"),
        "U5a modal hover bypasses fixed geometry/live mask");
    assert(grip.canFind("case SDL_MOUSEMOTION:") && grip.canFind("return true;"),
        "U5a mouse motion can leak through the modal grip");
    assert(grip.canFind("g_pie.unitH, pieLiveMask());\n                    return true;"),
        "U5a mouse motion does not stop at the modal grip");
    auto mouseDown = between(grip, "case SDL_MOUSEBUTTONDOWN:",
                             "case SDL_MOUSEBUTTONUP:");
    assert(mouseDown.canFind("return true;"),
        "U5a mouse down does not stop at the modal grip");
    assert(grip.count("case SDL_TEXTINPUT:") >= 1,
        "U5a text input can leak through the modal grip");
    auto focus = bodyAt(grip,
        "if (ev.type == SDL_WINDOWEVENT &&");
    assert(!focus.canFind("return true;"),
        "U5a focus loss no longer reaches ImGui's focus reset");
}

unittest { // U5b: renderer uses one face for pixels and record
    auto text = readText("source/ui/pie_render.d");
    assert(text.canFind("drawButtonFace(dl, rmin, rmax, item.label, 0.5f, face, isCommand)"),
        "U5b pixels do not consume the recorded face variable");
    assert(text.canFind("faceName(face)"),
        "U5b drawn record does not consume the pixel face variable");
    assert(!text.canFind(".title") && !text.canFind("• ")
           && !text.canFind("PathFillConvex"),
        "U5b obsolete ring/title/checked rendering returned");
}

unittest { // U5c: opening and post-close ownership stay timestamped/latched
    auto command = readText("source/commands/ui/pie.d");
    auto rawInput = readText("source/input_router.d");
    auto input = blankNonCode(rawInput);
    assert(command.canFind("queryEventStamp()"),
        "U5c pie opening lost the input-event timestamp");
    assert(input.canFind("g_pie.swallowRemainder")
           && input.canFind("if (ev.type == SDL_TEXTINPUT) return true;")
           && input.canFind("if (ev.key.repeat != 0) return true;"),
        "U5c post-close repeat/text latch is not resident");
    assert(rawInput.canFind(`if (*id == "ui.pie" && kev.repeat != 0) return;`),
        "U5c held pie chord can reopen after a close");
}

unittest { // U5d: live, record and replay share the queued-loss focus rule
    auto app = blankNonCode(readText("source/app.d"));
    auto input = blankNonCode(readText("source/input_router.d"));
    auto eventlog = blankNonCode(readText("source/eventlog.d"));
    auto focusRule = bodyAt(app, "private bool liveKeyEventWindowFocused(");
    assert(focusRule.canFind("SDL_GetKeyboardFocus() != window")
           && focusRule.count("SDL_PeepEvents(") == 2
           && focusRule.canFind("SDL_PEEKEVENT")
           && focusRule.canFind("SDL_WINDOWEVENT_FOCUS_LOST")
           && focusRule.canFind("event.window.windowID == ownWindowId"),
        "U5d live focus rule stopped rejecting queued focus loss for this window");
    assert(app.canFind("? liveKeyEventWindowFocused(window)"),
        "U5d live key delivery bypasses the queued-loss focus rule");
    assert(input.canFind("evLog.log(*ev, eventWindowFocused)")
           && input.canFind("recLog.log(*ev, eventWindowFocused)"),
        "U5d the recorder stopped receiving the event focus bit");
    assert(eventlog.canFind("immediateSink_(&e, entry.windowFocused)"),
        "U5d replay stopped supplying the recorded focus bit");
    assert(app.canFind("ev.key.windowID = windowId"),
        "U5d replayed key events lost their real ImGui window id");
    assert(app.canFind("ev.window.windowID = windowId"),
        "U5d replayed window events lost their real ImGui window id");
}

unittest { // U5e: automation reset clears the linked ImGui keyboard state
    auto adapter = blankNonCode(readText("source/http_command_adapter.d"));
    auto gate = blankNonCode(readText("source/imgui_event_gate.d"));
    assert(adapter.canFind("automation_.clearImGuiInputKeys();"),
        "U5e automation reset stopped clearing ImGui input keys");
    assert(gate.canFind("ImGuiIO_ClearInputKeys(igGetIO_Nil());"),
        "U5e ImGui reset hook stopped calling the linked cimgui clear");
}
