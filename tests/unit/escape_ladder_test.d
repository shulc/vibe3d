// Active tools leave Escape to the editor-level ladder. This census keeps
// executable tool handlers from reclaiming that key (task 5911, EL-c).
module tests.unit.escape_ladder_test;

import std.array : appender;
import std.algorithm.searching : canFind;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName, relativePath;
import std.string : indexOf;
import std.json : JSONType, JSONValue, parseJSON;
import ImGui = d_imgui;
import d_imgui.imgui_h : ImGuiConfigFlags, ImGuiKey;
import imgui_event_gate : escapeReachesEditor, imguiPopupOpen;
import input_context : EscapeRung, escapeRungFor;
import tests.unit.census_symbols : blankNonCode, countOccurrences;
import tests.unit.ui.headless_panel : openPanel;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest { // EL-c: tool key handlers do not consume Escape.
    const toolsRoot = buildPath(repoRoot, "source", "tools");
    size_t files, createFiles, sliceFiles, keyHandlers, escapeSites;
    auto offenders = appender!string;

    foreach (entry; dirEntries(toolsRoot, "*.d", SpanMode.depth)) {
        ++files;
        const rel = relativePath(entry.name, toolsRoot);
        if (rel.canFind("create/")) ++createFiles;
        if (rel.canFind("slice/")) ++sliceFiles;

        const code = blankNonCode(readText(entry.name));
        keyHandlers += countOccurrences(code, "override bool onKeyDown");
        const hits = countOccurrences(code, "SDLK_ESCAPE");
        if (hits) {
            escapeSites += hits;
            offenders.put(format("\n  %s: %s", rel, hits));
        }
    }

    assert(files > 30 && createFiles >= 1 && sliceFiles >= 1,
        format("EL-c: source/tools census is under-populated: files=%s create=%s slice=%s",
            files, createFiles, sliceFiles));
    assert(keyHandlers >= 4,
        format("EL-c: found only %s override bool onKeyDown handlers", keyHandlers));
    assert(escapeSites == 0,
        format("EL-c: active tools must not consume SDLK_ESCAPE; found %s site(s):%s",
            escapeSites, offenders.data));
}

unittest { // EL-a: every fixture press resolves to its recorded ladder rung.
    auto fixture = parseJSON(readText(buildPath(
        repoRoot, "tests", "fixtures", "tool_drop_pipe_stages.json")));
    immutable ids = ["C1/escape", "C6g/escape", "X2/escape", "E1", "E2",
        "E2a", "E2x", "E2f", "E2c", "E2s", "E3v", "E3p", "E5ls",
        "E5pen2/escape", "E6t", "E6n", "E7a", "E7b", "EB", "EB2",
        "U1inv/escape"];
    size_t cells, ladderPresses, nonLadderPresses;
    size_t[EscapeRung] rungCounts;

    foreach (cell; fixture["cells"].array) {
        if (cell["file"].str != "escape") continue;
        assert(cells < ids.length && cell["id"].str == ids[cells],
            format("EL-a: escape cell order drift at %s", cells));
        ++cells;
        JSONValue before = cell["expect"]["rig"];
        assertLadderState(before, cell["id"].str ~ " rig");

        foreach (i, press; cell["presses"].array) {
            assertLadderState(press["after"],
                format("%s press %s after", cell["id"].str, i + 1));
            const ladder = press["key"].str == "escape"
                || (press["key"].str == "space" && before["mode"].str == "item");
            if (!ladder) {
                ++nonLadderPresses;
                assert(press["rung"].type == JSONType.null_,
                    format("EL-a: %s press %s is outside the ladder but names rung %s",
                        cell["id"].str, i + 1, press["rung"].toString));
                before = press["after"];
                continue;
            }

            ++ladderPresses;
            const got = escapeRungFor(before["tool"].str.length != 0,
                statePipeHoldsTask(before), stateHasCurrentSelection(before),
                before["mode"].str == "item", before["sel"]["items"].integer != 0);
            const want = rungFromString(press["rung"].str);
            ++rungCounts[got];
            assert(got == want,
                format("EL-a: %s press %s resolved %s, expected %s",
                    cell["id"].str, i + 1, got, want));
            before = press["after"];
        }
    }

    assert(cells == ids.length,
        format("EL-a: executed %s escape cells, expected %s", cells, ids.length));
    assert(ladderPresses == 37 && nonLadderPresses == 1,
        format("EL-a: presses were %s ladder / %s non-ladder, expected 37 / 1",
            ladderPresses, nonLadderPresses));
    foreach (r; [EscapeRung.dropTool, EscapeRung.clearPipe,
                 EscapeRung.dropCurrentType, EscapeRung.dropItems,
                 EscapeRung.nothing])
        assert(rungCounts[r] >= 1,
            format("EL-a: fixture has no press for rung %s", r));
}

unittest { // EL-b: popup priority and both inline ladder doors stay wired.
    const code = blankNonCode(readText(buildPath(repoRoot, "source", "input_router.d")));
    const anchor = code.indexOf("void handleKeyDown(ref SDL_KeyboardEvent kev)");
    assert(anchor >= 0, "EL-b(1): InputRouter.handleKeyDown anchor vanished");
    const body = bodyAt(code, code.indexOf("{", anchor));
    assert(body.length > 100,
        "EL-b(1): InputRouter.handleKeyDown body census would scan nothing");

    // The WHOLE statement, whitespace-collapsed: a gate that keeps its call
    // text but tests another key or no longer returns must redden here.
    import std.array : join;
    import std.string : split;
    const flat = body.split().join(" ");
    const gate = flat.indexOf(
        "if (kev.keysym.sym == SDLK_ESCAPE && !escapeReachesEditor(imguiPopupOpen())) return;");
    const tool = flat.indexOf("activeTool.onKeyDown(");
    assert(gate >= 0 && tool >= 0 && gate < tool,
        "EL-b(1): the popup Escape gate (Esc, popup open -> return) must precede "
        ~ "activeTool.onKeyDown");

    const escAnchor = body.indexOf("case SDLK_ESCAPE:");
    assert(escAnchor >= 0, "EL-b(2): case SDLK_ESCAPE vanished");
    const escTail = body[cast(size_t)escAnchor + "case SDLK_ESCAPE:".length .. $];
    const nextCase = escTail.indexOf("case ");
    assert(nextCase >= 0 && escTail[0 .. cast(size_t)nextCase].canFind("escapeLadder("),
        "EL-b(2): the Escape case must call escapeLadder");

    const spaceAnchor = body.indexOf("case SDLK_SPACE:");
    assert(spaceAnchor >= 0, "EL-b(3): case SDLK_SPACE vanished");
    const tabOffset = body[cast(size_t)spaceAnchor .. $].indexOf("case SDLK_TAB");
    const tabAnchor = tabOffset < 0 ? -1 : spaceAnchor + tabOffset;
    assert(spaceAnchor >= 0 && tabAnchor > spaceAnchor,
        "EL-b(3): Space/Tab case anchors vanished");
    const spaceBody = body[cast(size_t)spaceAnchor .. cast(size_t)tabAnchor];
    const item = spaceBody.indexOf("SelType.Item");
    const ladder = spaceBody.indexOf("escapeLadder(");
    const drop = spaceBody.indexOf("dropActiveTool(");
    assert(item >= 0 && ladder >= 0 && drop >= 0 && ladder < drop,
        "EL-b(3): item-mode Space must call escapeLadder before the component drop");
    const spaceFlat = spaceBody.split().join(" ");
    assert(spaceFlat.canFind(
        "if (escapeReachesEditor(imguiPopupOpen())) escapeLadder();"),
        "EL-b(3): item-mode Space must not run the ladder under an open popup");

    const ladderAnchor = code.indexOf("void escapeLadder()");
    assert(ladderAnchor >= 0, "EL-b(4): escapeLadder anchor vanished");
    const ladderBody = bodyAt(code, code.indexOf("{", ladderAnchor));
    assert(ladderBody.canFind("escapeRungFor(")
        && countOccurrences(ladderBody, "final switch") == 1,
        "EL-b(4): escapeLadder must call escapeRungFor and contain one final switch");
}

unittest { // EL-d0: the event gate delegates to the header-derived boundary.
    const code = blankNonCode(readText(buildPath(repoRoot, "source", "imgui_event_gate.d")));
    const anchor = code.indexOf("bool imguiPopupOpen()");
    assert(anchor >= 0, "EL-d0: imguiPopupOpen anchor vanished");
    const body = bodyAt(code, code.indexOf("{", anchor));
    assert(body.length > 0 && body.canFind("anyPopupOpen()")
        && !body.canFind("ImGuiPopupFlags"),
        "EL-d0: imguiPopupOpen must delegate to the header-derived boundary");
}

unittest { // EL-d: the query observes the real popup stack between frames.
    bool wantOpen, wantClose;
    auto ui = openPanel({
        if (wantOpen) {
            ImGui.OpenPopup("probe");
            wantOpen = false;
        }
        if (ImGui.BeginPopupModal("probe")) {
            if (wantClose) {
                ImGui.CloseCurrentPopup();
                wantClose = false;
            }
            ImGui.EndPopup();
        }
    }, "Popup query probe");
    scope (exit) ui.close();

    ui.frame();
    assert(!imguiPopupOpen(), "EL-d control: no popup should be open");
    wantOpen = true;
    ui.frame();
    assert(imguiPopupOpen(), "EL-d: imguiPopupOpen missed an open modal");
    wantClose = true;
    ui.frame();
    ui.frame();
    assert(!imguiPopupOpen(), "EL-d: imguiPopupOpen stayed true after close");
}

unittest { // EL-e: keyboard navigation closes menus, not inert modals.
    // Keep these four rows above the production census: under M32 they pass,
    // then the source assertion below is the named red line.
    assert(popupOpenAfterEscape(false, true));
    assert(popupOpenAfterEscape(false, false));
    assert(popupOpenAfterEscape(true, true));
    assert(!popupOpenAfterEscape(true, false));

    const app = blankNonCode(readText(buildPath(repoRoot, "source", "app.d")));
    assert(app.length > 200_000,
        "EL-e: source/app.d census is implausibly small");
    assert(countOccurrences(app,
        "io.ConfigFlags |= ImGuiConfigFlags.NavEnableKeyboard;") == 1,
        "EL-e: app must enable ImGui keyboard navigation exactly once");
}

private bool popupOpenAfterEscape(bool navEnabled, bool modal) {
    bool wantOpen = true;
    auto ui = openPanel({
        if (wantOpen) {
            ImGui.OpenPopup("probe");
            wantOpen = false;
        }
        if (modal) {
            if (ImGui.BeginPopupModal("probe")) ImGui.EndPopup();
        } else {
            if (ImGui.BeginPopup("probe")) ImGui.EndPopup();
        }
    }, modal ? "Modal Escape probe" : "Menu Escape probe");
    scope (exit) ui.close();

    if (navEnabled)
        ImGui.GetIO().ConfigFlags |= ImGuiConfigFlags.NavEnableKeyboard;
    ui.frame();
    assert(imguiPopupOpen(),
        format("EL-e floor: popup was not open (nav=%s modal=%s)", navEnabled, modal));
    ui.keyDown(cast(int) ImGuiKey.Escape);
    assert(imguiPopupOpen(),
        format("EL-e production moment: popup changed before frame (nav=%s modal=%s)",
            navEnabled, modal));
    ui.frame();
    ui.keyUp(cast(int) ImGuiKey.Escape);
    ui.frame();
    return imguiPopupOpen();
}

private void assertLadderState(JSONValue state, string where) {
    foreach (key; ["tool", "mode", "actionCenter", "axis", "falloff",
                   "constrain", "stackedFalloffs", "sel"])
        assert((key in state.object) !is null,
            format("EL-a: %s lacks required key %s", where, key));
    foreach (key; ["vertex", "edge", "polygon", "items"])
        assert((key in state["sel"].object) !is null,
            format("EL-a: %s lacks required selection key %s", where, key));
}

private bool statePipeHoldsTask(JSONValue state) {
    return state["actionCenter"].str != "none" || state["axis"].str != "none"
        || state["falloff"].str != "none" || state["constrain"].str == "true"
        || state["stackedFalloffs"].integer > 0;
}

private bool stateHasCurrentSelection(JSONValue state) {
    const mode = state["mode"].str;
    return state["sel"][mode == "item" ? "items" : mode].integer > 0;
}

private EscapeRung rungFromString(string rung) {
    switch (rung) {
        case "dropTool":        return EscapeRung.dropTool;
        case "clearPipe":       return EscapeRung.clearPipe;
        case "dropCurrentType": return EscapeRung.dropCurrentType;
        case "dropItems":       return EscapeRung.dropItems;
        case "nothing":         return EscapeRung.nothing;
        default: assert(0, "EL-a: unknown fixture rung " ~ rung);
    }
}

/// The balanced body a `{` opens, or `""` when the anchor is absent.
private string bodyAt(string text, ptrdiff_t open) {
    if (open < 0 || open >= text.length || text[open] != '{') return "";
    size_t depth;
    foreach (i; cast(size_t) open .. text.length) {
        if (text[i] == '{') ++depth;
        else if (text[i] == '}') {
            --depth;
            if (depth == 0) return text[cast(size_t) open + 1 .. i];
        }
    }
    return "";
}
