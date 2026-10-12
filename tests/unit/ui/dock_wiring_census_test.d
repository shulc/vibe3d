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
    foreach (scanSourceRoot; [sourceRoot, buildPath(gateRepoRoot, "packages/command-runtime/source"), buildPath(gateRepoRoot, "packages/application-core/source"), buildPath(gateRepoRoot, "packages/camera-model/source"), buildPath(gateRepoRoot, "packages/document-channels/source"), buildPath(gateRepoRoot, "packages/image-codec/source"), buildPath(gateRepoRoot, "packages/document-io/source"), buildPath(gateRepoRoot, "packages/document-model/source"), buildPath(gateRepoRoot, "packages/param-schema/source"), buildPath(gateRepoRoot, "packages/pipe-runtime/source"), buildPath(gateRepoRoot, "packages/mesh-ops/source"), buildPath(gateRepoRoot, "packages/interchange/source"), buildPath(gateRepoRoot, "packages/interaction-query/source"), buildPath(gateRepoRoot, "packages/pipe-evaluation/source"), buildPath(gateRepoRoot, "packages/tool-state/source"), buildPath(gateRepoRoot, "packages/transform-ops/source"), buildPath(gateRepoRoot, "packages/creation-ops/source"), buildPath(gateRepoRoot, "packages/alignment-ops/source"), buildPath(gateRepoRoot, "packages/input-events/source"), buildPath(gateRepoRoot, "packages/display-policy/source"), buildPath(gateRepoRoot, "packages/viewport-gpu/source"), buildPath(gateRepoRoot, "packages/subpatch-preview/source"), buildPath(gateRepoRoot, "packages/edit-contracts/source"), buildPath(gateRepoRoot, "packages/mesh-change/source"), buildPath(gateRepoRoot, "packages/mesh-contracts/source"), buildPath(gateRepoRoot, "packages/mesh-edit-log/source"), buildPath(gateRepoRoot, "packages/mesh-edit-replay/source"), buildPath(gateRepoRoot, "packages/mesh-snapshot/source"), buildPath(gateRepoRoot, "packages/mesh-topology/source"), buildPath(gateRepoRoot, "packages/mesh/source"), buildPath(gateRepoRoot, "packages/profiling/source"), buildPath(gateRepoRoot, "packages/spatial/source"), buildPath(gateRepoRoot, "util/log/source"), buildPath(gateRepoRoot, "util/math/source"), buildPath(gateRepoRoot, "util/parallel/source"), buildPath(gateRepoRoot, "util/plane-bytes/source"), buildPath(gateRepoRoot, "util/screen-buckets/source"), buildPath(gateRepoRoot, "packages/selection-model/source"), buildPath(gateRepoRoot, "packages/scene-query/source"), buildPath(gateRepoRoot, "packages/editor-commands/source")])

    foreach (entry; dirEntries(scanSourceRoot, "*.d", SpanMode.depth)) {
        if (!entry.isFile) continue;
        ++scanned;
        const code = blankNonCode(readText(entry.name));
        if (code.canFind("NoUndocking")) noUndockingHits ~= entry.name;
        if (code.canFind("ImGuiDockNode_SetLocalFlags"))
            localFlagHits ~= entry.name;
    }
    const string[] sourceCarriersWave14_1 = [
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
];
    import std.file : exists;
    import std.path : buildPath;
    foreach (relative; [
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
    ]) {
        size_t occurrences;
        foreach (candidate; sourceCarriersWave14_1) if (candidate == relative) ++occurrences;
        assert(occurrences == 1, "Wave14 logical source input missing/duplicate: " ~ relative);
        assert(exists(buildPath(gateRepoRoot, relative)), "Wave14 logical source physical input missing: " ~ relative);
    }
    foreach (sourceCarrier; sourceCarriersWave14_1) {
        const sourceCarrierPath = buildPath(gateRepoRoot, sourceCarrier);


        const code = blankNonCode(readText(sourceCarrierPath));
        if (code.canFind("NoUndocking")) noUndockingHits ~= sourceCarrierPath;
        if (code.canFind("ImGuiDockNode_SetLocalFlags"))
            localFlagHits ~= sourceCarrierPath;

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
