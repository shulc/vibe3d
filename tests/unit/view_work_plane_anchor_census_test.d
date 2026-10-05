// Task 9411: ONE view work-plane anchor for every click reader. The old
// per-reader plane (the plane's own normal through its origin) is gone from
// the tree; the click readers call the create click law; `niceOrigin` has one
// body; the relocate has no plane chain of its own (task 9476). Raw source text
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

unittest {
    // Positive control first: the needle machinery finds the live readers.
    const world = roster("screenToPlacementWorld(");
    // tools/edit/edge_extend.d: the off-handle haul's anchor (task 9450, K-D D2)
    assert(world == ["falloff_handles.d:2", "tools/alignment/radial_array_tool.d:1",
                     "tools/common/command_wrapper.d:1", "tools/create/create_common.d:1",
                     "tools/edit/edge_extend.d:1", "tools/transform/transform.d:1"],
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
    // Task 9415 (P1): the pen's first point is the create click; its own
    // anchor rounding, quantum and the temporary re-export are gone. Polarity:
    // before P1 pen.d held niceOrigin 1 / relocateQuantum 1 / placementQuantum 3.
    assert(roster("niceOrigin(") == ["tools/transform/relocate_plane_test.d:9", "viewgrid.d:2"],
        format("niceOrigin( roster: %s", roster("niceOrigin(")));
    assert(roster("relocateQuantum(") == ["tools/transform/relocate_plane_test.d:2", "viewgrid.d:2"],
        format("relocateQuantum( roster: %s", roster("relocateQuantum(")));
    assert(roster("placementQuantum") == [] && roster("clickAnchor") == [],
        format("the pen's own click anchor returned: %s %s", roster("placementQuantum"),
               roster("clickAnchor")));
    assert(roster("screenToPlacementLocal(").count!(r => r == "tools/create/pen.d:1") == 1,
        format("the pen's first point must be the create click: %s", roster("screenToPlacementLocal(")));
    const rp = blankNonCode(readText(buildPath(repoRoot, "source", "tools", "transform",
                                               "relocate_plane.d")));
    assert(rp.indexOf("public import") < 0, "relocate_plane re-exports viewgrid names again");
    assert(rp.indexOf("bool orthoRelocateThroughPrior(") >= 0, "control: relocate_plane read");
    assert(rp.indexOf("lockedViewAxis") < 0,
        "relocate_plane regained a locked-view arm (unreachable from every click)");
    // Task 9476 (K-W3): the perspective relocate is the click law, pinned or
    // not; the unsnapped principal-plane chain is gone, every spelling.
    foreach (n; ["principalPlaneCenter", "posToPrincipalPlane", "workPlanePoint",
                 "RelocatePlanePrefs", "biasedAxis"])
        assert(roster(n) == [], format("the unsnapped relocate chain returned: %s %s",
                                       n, roster(n)));
}
