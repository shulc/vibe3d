// Task 5930: the linked UI package's own C header is the only authority for
// popup/input flag integers. This census closes both production consumers and
// the accessor shape; M4/M5 are census-only by construction because their old
// values are behaviourally indistinguishable at those specific call sites.
module tests.unit.imgui_flag_boundary_census_test;

import std.algorithm : canFind;
import std.array : appender;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName, relativePath;
import std.string : indexOf, splitLines, strip;
import tests.unit.census_symbols : blankNonCode, countOccurrences;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest { // every used flag crosses one int(void) accessor and one D funnel
    const cPath = buildPath(repoRoot, "source", "imgui_flag_abi.c");
    const cSource = readText(cPath);
    const cCode = blankNonCode(cSource);
    string[] accessors;
    foreach (line; cSource.splitLines) {
        const s = line.strip;
        if (s.canFind("vibe3d_imgui_")) accessors ~= s;
    }
    assert(accessors.length == 4,
        format("flag-boundary census: found %s accessor line(s), expected 4",
            accessors.length));
    assert(countOccurrences(cSource, "vibe3d_imgui_") == 4,
        "flag-boundary census: an accessor no longer has the required int name(void) line");

    immutable expected = [
        "int vibe3d_imgui_popup_any(void) { return ImGuiPopupFlags_AnyPopup; }",
        "int vibe3d_imgui_popup_context_window_over_empty_space(void) { return ImGuiPopupFlags_MouseButtonRight | ImGuiPopupFlags_NoOpenOverItems; }",
        "int vibe3d_imgui_popup_context_item(void) { return ImGuiPopupFlags_MouseButtonRight; }",
        "int vibe3d_imgui_input_text_enter_returns_true(void) { return ImGuiInputTextFlags_EnterReturnsTrue; }",
    ];
    foreach (i, line; accessors) {
        const start = line.indexOf("return ");
        assert(start >= 0, "flag-boundary census: accessor lost its return expression");
        const body = line[cast(size_t)start + "return ".length .. $];
        foreach (ch; body)
            assert(ch < '0' || ch > '9',
                "flag-boundary census: accessor bodies must contain no digits");
        assert(!body.canFind("sizeof") && !body.canFind("struct "),
            "flag-boundary census: sizeof or a struct type crossed the integer-only boundary");
        assert(line == expected[i],
            format("flag-boundary census: accessor %s is not exact int name(void): %s",
                i, line));
    }
    assert(!cCode.canFind("sizeof") && !cCode.canFind("struct "),
        "flag-boundary census: C boundary must expose no sizeof or struct types");

    const sourceRoot = buildPath(repoRoot, "source");
    auto offenders = appender!string;
    size_t dFiles;
    foreach (entry; dirEntries(sourceRoot, "*.d", SpanMode.depth)) {
        ++dFiles;
        const rel = relativePath(entry.name, repoRoot);
        const code = blankNonCode(readText(entry.name));
        if (rel == "source/imgui_flag_boundary.d") continue;
        foreach (needle; ["ImGuiPopupFlags.", "ImGuiInputTextFlags.",
                          "ImGuiSelectableFlags.Highlight",
                          "BeginPopupContextItem(", "BeginPopupContextWindow(",
                          "BeginPopupContextVoid(", "igIsPopupOpen_Str("])
            if (code.canFind(needle))
                offenders.put(format("\n  %s: %s", rel, needle));
    }
    assert(dFiles > 500,
        format("flag-boundary census: source population collapsed to %s D files", dFiles));
    assert(offenders.data.length == 0,
        "flag-boundary census: a consumer bypassed the canonical D funnel:"
        ~ offenders.data);

    const boundary = blankNonCode(readText(buildPath(
        sourceRoot, "imgui_flag_boundary.d")));
    assert(countOccurrences(boundary, "ImGui.BeginPopupContextWindow(") == 1
        && countOccurrences(boundary, "ImGui.BeginPopupContextItem(") == 1
        && countOccurrences(boundary, "igIsPopupOpen_Str(") == 2
        && countOccurrences(boundary, "ImGui.InputText(") == 1,
        "flag-boundary census: canonical D funnel call population changed");

    const panels = readText(buildPath(sourceRoot, "ui", "panels.d"));
    assert(countOccurrences(panels,
            "beginPanelContextMenu(\"hist-panel-ctx\")") == 1
        && countOccurrences(panels,
            "beginItemContextMenu(\"hist-row-ctx\")") == 1
        && countOccurrences(panels, "inputTextSubmitOnEnter(") == 2,
        "flag-boundary census: production history/rename consumers left the funnel");
    const layerList = readText(buildPath(sourceRoot, "ui", "layer_list_panel.d"));
    assert(countOccurrences(layerList, "inputTextSubmitOnEnter(") == 1,
        "flag-boundary census: the Layers rename field left the funnel");

    const runner = readText(buildPath(repoRoot, "run_test.d"));
    assert(runner.canFind("g_compileFlags ~= gather(\"dflags\"")
        && runner.canFind(`foreach (pattern; ["*.d", "*.c"])`)
        && runner.canFind(
            "project test-lib build failed; refusing per-test -i fallback")
        && !runner.canFind("dmd -unittest -i")
        && !runner.canFind(
            "project test-lib build failed; falling back to per-test -i compile"),
        "flag-boundary census: suite runner stopped hashing ImportC, harvesting dflags, or restored its quiet fallback");
}
