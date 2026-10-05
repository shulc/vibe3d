// Task 9411: ONE view work-plane anchor for every click reader. The old
// per-reader plane (the plane's own normal through its origin) is gone from
// the tree; the click readers call the create click law; `niceOrigin` has one
// body; the relocate's plane chain has no locked-view arm. Raw source text
// with comments and strings blanked: a renamed or aliased reader shows up as a
// changed roster, not as a silent pass.
module tests.unit.view_work_plane_anchor_census_test;

import std.algorithm : count, sort;
import std.array     : array;
import std.file      : SpanMode, dirEntries, readText;
import std.format    : format;
import std.path      : buildPath, dirName, relativePath;
import std.string    : indexOf;

import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// "file:count" for every source file whose code text contains `needle`.
private string[] roster(string needle) {
    string[] r;
    foreach (e; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const n = blankNonCode(readText(e.name)).count(needle);
        if (n) r ~= format("%s:%d", relativePath(e.name, buildPath(repoRoot, "source")), n);
    }
    sort(r);
    return r;
}

private string bodyOf(string code, string marker) {
    const at = code.indexOf(marker);
    assert(at >= 0, "missing source marker `" ~ marker ~ "`");
    size_t i = cast(size_t)at, depth;
    while (code[i] != '{') ++i;
    foreach (j; i .. code.length) {
        if (code[j] == '{') ++depth;
        else if (code[j] == '}' && --depth == 0) return code[i .. j + 1];
    }
    assert(false, "unterminated body after `" ~ marker ~ "`");
}

unittest {
    // Positive control first: the needle machinery finds the live readers.
    const world = roster("screenToPlacementWorld(");
    assert(world == ["falloff_handles.d:2", "tools/alignment/radial_array_tool.d:1",
                     "tools/common/command_wrapper.d:1", "tools/create/create_common.d:1",
                     "tools/transform/transform.d:1"],
        format("screenToPlacementWorld( roster: %s", world));
    // The deleted reader and its mode enum: zero, every spelling.
    assert(roster("screenToConstructionPlane") == [] && roster("ConstructionPlaneMode") == [],
        format("the per-reader construction plane returned: %s %s",
               roster("screenToConstructionPlane"), roster("ConstructionPlaneMode")));
    assert(roster("placementPlaneHit(") == ["tools/create/create_common.d:3"],
        format("placementPlaneHit( roster: %s", roster("placementPlaneHit(")));
    assert(roster("viewWorkPlaneAnchor(") == ["tools/create/create_common.d:1", "viewgrid.d:1"],
        format("viewWorkPlaneAnchor( roster: %s", roster("viewWorkPlaneAnchor(")));
    // One body of the anchor's rounding.
    assert(roster("Vec3 niceOrigin(") == ["viewgrid.d:1"],
        format("niceOrigin definitions: %s", roster("Vec3 niceOrigin(")));
    const rp = blankNonCode(readText(buildPath(repoRoot, "source", "tools", "transform",
                                               "relocate_plane.d")));
    const wpp = bodyOf(rp, "PlanePoint workPlanePoint(");
    assert(wpp.indexOf("niceOrigin(") >= 0, "control: workPlanePoint body located");
    assert(rp.indexOf("lockedViewAxis") < 0,
        "relocate_plane regained a locked-view arm (unreachable from every click)");
}
