// The EditorApp active-tool accessors expose live reads, not a write channel.
module tests.unit.active_tool_accessor_readonly_test;

import vibe3d.apps.desktop.editor_app : EditorApp;
import vibe3d.editing.tools.interactive.tool : Tool;

import std.algorithm : sort;
import std.file : SpanMode;
import tests.unit.census_symbols : dirEntries = wave15DirEntries, exists = wave15Exists, readText = wave15ReadText;
import std.format : format;
import std.path : buildPath, dirName;
import std.string : indexOf, join, splitLines;

import tests.unit.census_symbols : blankNonCode, isIdentChar;

private struct RefShape
{
    Tool* activeToolPtr;
    string* activeToolIdPtr;
    @property ref Tool activeTool() { return *activeToolPtr; }
    @property ref string activeToolId() { return *activeToolIdPtr; }
}

private void bindRef(ref Tool) {}
private void bindOut(out string) {}

private enum assignTool(T) = __traits(compiles,
    (ref T a, Tool t) { a.activeTool = t; });
// Shared templates keep the with-form locals t/s identical for positive and negative cells.
private enum withAssignTool(T) = __traits(compiles,
    (ref T a, Tool t) { with (a) activeTool = t; });
private enum refBindTool(T) = __traits(compiles,
    (ref T a) { bindRef(a.activeTool); });
private enum assignId(T) = __traits(compiles,
    (ref T a, string s) { a.activeToolId = s; });
private enum appendId(T) = __traits(compiles,
    (ref T a, string s) { a.activeToolId ~= s; });
private enum withAssignId(T) = __traits(compiles,
    (ref T a, string s) { with (a) activeToolId = s; });
private enum outBindId(T) = __traits(compiles,
    (ref T a) { bindOut(a.activeToolId); });
private enum readsBoth(T) = __traits(compiles, (ref T a) {
    Tool t = a.activeTool;
    string s = a.activeToolId;
    with (a) {
        t = activeTool;
        s = activeToolId;
    }
});

private bool hasRefAttribute(string[] attributes)
{
    foreach (attribute; attributes)
        if (attribute == "ref") return true;
    return false;
}

unittest
{
    static assert(readsBoth!RefShape && readsBoth!EditorApp,
        "active-tool accessor read control no longer compiles");

    static assert(assignTool!RefShape, "CONTROL assignTool is not ref-shaped");
    static assert(withAssignTool!RefShape,
        "CONTROL withAssignTool is not ref-shaped");
    static assert(refBindTool!RefShape,
        "CONTROL refBindTool is not ref-shaped");
    static assert(assignId!RefShape, "CONTROL assignId is not ref-shaped");
    static assert(appendId!RefShape, "CONTROL appendId is not ref-shaped");
    static assert(withAssignId!RefShape,
        "CONTROL withAssignId is not ref-shaped");
    static assert(outBindId!RefShape,
        "CONTROL outBindId is not ref-shaped");

    static assert(!assignTool!EditorApp,
        "activeTool assignment compiles: accessor returns ref again or gained a setter");
    static assert(!withAssignTool!EditorApp,
        "activeTool with-assignment compiles: accessor returns ref again or gained a setter");
    static assert(!refBindTool!EditorApp,
        "activeTool binds to ref: accessor returns ref again");

    static assert(!assignId!EditorApp,
        "activeToolId assignment compiles: accessor returns ref again or gained a setter");
    static assert(!appendId!EditorApp,
        "activeToolId append compiles: accessor returns ref again");
    static assert(!withAssignId!EditorApp,
        "activeToolId with-assignment compiles: accessor returns ref again or gained a setter");
    static assert(!outBindId!EditorApp,
        "activeToolId binds to out: accessor returns ref again");

    static assert(__traits(getOverloads, EditorApp, "activeTool").length == 1,
        "activeTool declaration census: expected one overload");
    static assert(__traits(getOverloads, EditorApp, "activeToolId").length == 1,
        "activeToolId declaration census: expected one overload");
    static assert(is(typeof(EditorApp.init.activeTool) == Tool),
        "activeTool declaration census: expected Tool return type");
    static assert(is(typeof(EditorApp.init.activeToolId) == string),
        "activeToolId declaration census: expected string return type");
    enum toolAttributes = [__traits(getFunctionAttributes, EditorApp.activeTool)];
    enum idAttributes = [__traits(getFunctionAttributes, EditorApp.activeToolId)];
    static assert(!hasRefAttribute(toolAttributes),
        "activeTool declaration census: accessor returns ref again");
    static assert(!hasRefAttribute(idAttributes),
        "activeToolId declaration census: accessor returns ref again");
}

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private immutable pointerNames = ["activeToolIdPtr", "activeToolPtr"];

private struct PointerRow
{
    string name;
    string file;
    size_t count;
}

private size_t countIdentifier(string text, string name)
{
    if (name.length == 0 || name.length > text.length) return 0;
    size_t count;
    size_t from;
    while (from + name.length <= text.length)
    {
        const offset = text[from .. $].indexOf(name);
        if (offset < 0) break;
        const pos = from + cast(size_t) offset;
        const end = pos + name.length;
        if ((pos == 0 || !isIdentChar(text[pos - 1]))
            && (end == text.length || !isIdentChar(text[end])))
            ++count;
        from = end;
    }
    return count;
}

private string rowsText(const PointerRow[] rows)
{
    string[] lines;
    foreach (row; rows)
        lines ~= format("%s %s %d", row.name, row.file, row.count);
    return lines.join("\n");
}

unittest
{
    static assert(__traits(compiles,
        (ref EditorApp a, Tool t) { *a.activeToolPtr = t; }),
        "pointer-channel control: activeToolPtr is no longer writable");
    static assert(__traits(compiles,
        (ref EditorApp a, string s) { *a.activeToolIdPtr = s; }),
        "pointer-channel control: activeToolIdPtr is no longer writable");

    const sourceRoot = buildPath(repoRoot, "source");
    assert(sourceRoot.exists,
        "active-tool pointer census cannot find source/; an empty walk is not green");

    string[] paths;
    foreach (scanSourceRoot; [sourceRoot, buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source"), buildPath(repoRoot, "packages/selection-model/source"), buildPath(repoRoot, "packages/scene-query/source"), buildPath(repoRoot, "packages/editor-commands/source")])

    foreach (entry; dirEntries(scanSourceRoot, "*.d", SpanMode.depth))
        paths ~= entry.name;
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

import tests.unit.census_symbols : exists = wave15Exists;
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

    }
    foreach (sourceCarrier; sourceCarriersWave14_1)
        paths ~= buildPath(repoRoot, sourceCarrier);
    paths.sort();

    assert(paths.length >= 500, format(
        "active-tool pointer census scanned %d source files, expected at least 500",
        paths.length));

    PointerRow[] actual;
    foreach (path; paths)
    {
        const code = blankNonCode(readText(path));
        const file = path[repoRoot.length + 1 .. $];
        foreach (name; pointerNames)
        {
            const count = countIdentifier(code, name);
            if (count > 0) actual ~= PointerRow(name, file, count);
        }
    }
    actual.sort!((a, b) => a.name == b.name
        ? a.file < b.file : a.name < b.name)();

    immutable expected = [
        PointerRow("activeToolIdPtr", "source/app.d", 1),
        PointerRow("activeToolIdPtr", "source/editor_app.d", 2),
        PointerRow("activeToolPtr", "source/app.d", 1),
        PointerRow("activeToolPtr", "source/editor_app.d", 2),
    ];
    assert(actual == expected, format(
        "active-tool pointer census changed; writes belong to the drop/arm doors "
      ~ "in app.d, and the pointer channel is listed at its single wiring site.\n"
      ~ "expected:\n%s\nactual:\n%s",
        rowsText(expected), rowsText(actual)));
}
