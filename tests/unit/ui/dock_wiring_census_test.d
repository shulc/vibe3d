module tests.unit.ui.dock_wiring_census_test;

import std.algorithm : canFind, count;
import std.file : dirEntries, exists, isFile, readText, SpanMode;
import std.path : buildPath, dirName;
import std.string : indexOf, lastIndexOf;
import tests.unit.census_symbols : blankNonCode;

private enum gateRepoRoot = dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))));

private string appSource() {
    const path = buildPath(gateRepoRoot, "source", "app.d");
    assert(exists(path) && isFile(path),
        "6245 dock census cannot find source/app.d");
    const source = readText(path);
    assert(source.length > 100_000,
        "6245 dock census population: app.d is unexpectedly small");
    return source;
}

private string appCode() {
    return blankNonCode(appSource());
}

unittest { // F4c: one drag state feeds both overlapping viewport windows
    const source = appCode();
    assert(source.count(
        "immutable bool dockDragActive = windowDockDragActive();") == 1,
        "6245 F4c expected one per-frame dock-drag sample");
    assert(source.count("viewportOverlayWindowFlags(") == 2,
        "6245 F4c expected both viewport overlays to use the drag gate");
}

unittest { // F4e: the removed node-level undock guard cannot creep back
    const sourceRoot = buildPath(gateRepoRoot, "source");
    size_t scanned;
    string[] noUndockingHits;
    string[] localFlagHits;
    foreach (entry; dirEntries(sourceRoot, "*.d", SpanMode.depth)) {
        if (!entry.isFile) continue;
        ++scanned;
        const code = blankNonCode(readText(entry.name));
        if (code.canFind("NoUndocking")) noUndockingHits ~= entry.name;
        if (code.canFind("ImGuiDockNode_SetLocalFlags"))
            localFlagHits ~= entry.name;
    }
    assert(scanned >= 200,
        "6245 F4e population: fewer than 200 source modules were scanned");
    assert(localFlagHits.length == 1
        && localFlagHits[0] == buildPath(sourceRoot, "app.d"),
        "6245 F4e positive control: scanner did not find the local-flags signal only in app.d");
    assert(noUndockingHits.length == 0,
        "6245 F4e NoUndocking returned; layout.reset is the recovery path");
}

unittest { // F4i: the class applies to ViewportHost, not an earlier window
    const raw = appSource();
    const source = blankNonCode(raw);
    enum beginPrefix = "ImGui.Begin(";
    enum viewportBegin = `ImGui.Begin("ViewportHost"`;
    size_t viewportBeginHits;
    size_t beginAt = size_t.max;
    for (size_t from = 0; from < source.length; ) {
        const relative = source[from .. $].indexOf(beginPrefix);
        if (relative < 0) break;
        const at = from + cast(size_t)relative;
        if (at + viewportBegin.length <= raw.length
            && raw[at .. at + viewportBegin.length] == viewportBegin) {
            ++viewportBeginHits;
            beginAt = at;
        }
        from = at + beginPrefix.length;
    }
    assert(viewportBeginHits == 1,
        "6245 F4i population: expected one ViewportHost Begin");
    assert(source.count("igSetNextWindowClass(") == 1,
        "6245 F4i population: expected one window-class call");
    assert(source.canFind("ImGuiDockNode_SetLocalFlags"),
        "6245 F4i positive control: scanner missed app.d's local-flags signal");

    const classAt = source.indexOf("igSetNextWindowClass(");
    assert(classAt >= 0 && cast(size_t)classAt < beginAt,
        "6245 F4i class call must precede ViewportHost Begin");
    assert(!source[cast(size_t)classAt .. beginAt].canFind("ImGui.Begin("),
        "6245 F4i another Begin consumed the ViewportHost window class");
    const windowClassAt = source.lastIndexOf("ImGuiWindowClassStorage", classAt);
    assert(windowClassAt >= 0
        && source[windowClassAt .. classAt].canFind("kDockFlagNoDockingOverMe"),
        "6245 F4i ViewportHost class assignment lost NoDockingOverMe");
    const hostFlagsAt = source.lastIndexOf("immutable int hostFlags", classAt);
    assert(hostFlagsAt >= 0
        && source[hostFlagsAt .. classAt].canFind("ImGuiWindowFlags.NoMouseInputs"),
        "6245 F4i ViewportHost lost the NoMouseInputs hover shield");
}
