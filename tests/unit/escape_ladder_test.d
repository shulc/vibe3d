// Active tools leave Escape to the editor-level ladder. This census keeps
// executable tool handlers from reclaiming that key (task 5911, EL-c).
module tests.unit.escape_ladder_test;

import std.array : appender;
import std.algorithm.searching : canFind;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName, relativePath;
import std.string : indexOf;
import ImGui = d_imgui;
import d_imgui.imgui_h : ImGuiConfigFlags, ImGuiKey;
import imgui_event_gate : escapeReachesEditor, imguiPopupOpen,
                          kCimguiAnyPopup;
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

unittest { // EL-b(1): the popup gate precedes active-tool dispatch.
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
}

unittest { // EL-d0: fail by name before a stale popup flag can crash EL-d.
    static assert(kCimguiAnyPopup == 3072);
    const code = blankNonCode(readText(buildPath(repoRoot, "source", "imgui_event_gate.d")));
    const anchor = code.indexOf("bool imguiPopupOpen()");
    assert(anchor >= 0, "EL-d0: imguiPopupOpen anchor vanished");
    const body = bodyAt(code, code.indexOf("{", anchor));
    assert(body.length > 0 && body.canFind("kCimguiAnyPopup")
        && !body.canFind("ImGuiPopupFlags"),
        "EL-d0: imguiPopupOpen must pass kCimguiAnyPopup (the linked lib's "
        ~ "AnyPopup = 3072); the D shim's ImGuiPopupFlags.AnyPopup is 384 "
        ~ "and segfaults between frames");
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
    ui.frame();
    ui.keyUp(cast(int) ImGuiKey.Escape);
    ui.frame();
    return imguiPopupOpen();
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
