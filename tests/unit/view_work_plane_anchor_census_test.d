// Task 9411: ONE view work-plane anchor for every click reader. The old
// per-reader plane (the plane's own normal through its origin) is gone from
// the tree; the click readers call the create click law; `niceOrigin` has one
// body; the relocate has no plane chain of its own (task 9476). Raw source text
// with comments and strings blanked: a renamed or aliased reader shows up as a
// changed roster, not as a silent pass.
module tests.unit.view_work_plane_anchor_census_test;

import tests.unit.census_symbols : wave15InputsIntact, wave15InputStart;



import tests.unit.census_symbols : exists = wave15Exists;

import std.algorithm : count, sort;
import std.array     : array;
import std.file : SpanMode;
import tests.unit.census_symbols : dirEntries = wave15DirEntries, readText = wave15ReadText;
import std.format    : format;
import std.path      : buildPath, dirName, relativePath;
import std.string    : indexOf;

import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private struct CensusSource { string path, code; }

// Keep one validated snapshot per unittest; every needle sees the same inputs.
private CensusSource[] sourceSnapshot() {
    CensusSource[] r;
    foreach (scanSourceRoot; [buildPath(repoRoot, "source"), buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source"), buildPath(repoRoot, "packages/transform-ops/tests/source"), buildPath(repoRoot, "packages/selection-model/source"), buildPath(repoRoot, "packages/scene-query/source"), buildPath(repoRoot, "packages/editor-commands/source")])

    foreach (e; dirEntries(scanSourceRoot, "*.d", SpanMode.depth)) {
        r ~= CensusSource(relativePath(e.name, buildPath(repoRoot, "source")),
                          blankNonCode(readText(e.name)));
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

import tests.unit.census_symbols : exists = wave15Exists;
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

    }
    foreach (sourceCarrier; sourceCarriersWave14_1) {
        const sourceCarrierPath = buildPath(repoRoot, sourceCarrier);
        r ~= CensusSource(relativePath(sourceCarrierPath, buildPath(repoRoot, "source")),
                          blankNonCode(readText(sourceCarrierPath)));

    }
    return r;
}

/// "file:count" for every source file whose code text contains `needle`.
private string[] sourceRoster(string needle, const(CensusSource)[] sources) {
    string[] r;
    foreach (source; sources) {
        const n = source.code.count(needle);
        if (n) r ~= format("%s:%d", source.path, n);
    }
    sort(r);
    return r;
}

unittest {
    auto wave15Inputs = wave15InputStart();
    const sources = sourceSnapshot();
    string[] roster(string needle) { return sourceRoster(needle, sources); }
    // Positive control first: the needle machinery finds the live readers.
    const world = roster("screenToPlacementWorld(");
    // tools/edit/edge_extend.d: the off-handle haul's anchor (task 9450, K-D D2)
    assert(world == ["falloff_handles.d:2", "tools/alignment/radial_array_tool.d:1",
                     "tools/common/command_wrapper.d:1", "tools/create/create_common.d:1",
                     "tools/edit/edge_extend.d:1", "tools/transform/transform.d:1"],
        format("screenToPlacementWorld( roster: %s", world));
    // The deleted reader and its mode enum: zero, every spelling.
    assert((roster("screenToConstructionPlane") == [] && roster("ConstructionPlaneMode") == []) && wave15InputsIntact(wave15Inputs),
        format("the per-reader construction plane returned: %s %s",
               roster("screenToConstructionPlane"), roster("ConstructionPlaneMode")));
    assert(roster("placementPlaneHit(") == ["tools/create/create_common.d:3"],
        format("placementPlaneHit( roster: %s", roster("placementPlaneHit(")));
    // ui/viewport_render.d: the perspective work-plane lattice's offset (task 9509, K-GR rule 3).
    assert(roster("viewWorkPlaneAnchor(") == ["../packages/interaction-query/source/viewgrid.d:1",
                                              "tools/create/create_common.d:1", "ui/viewport_render.d:1"],
        format("viewWorkPlaneAnchor( roster: %s", roster("viewWorkPlaneAnchor(")));
    // One body of the anchor's rounding.
    assert(roster("Vec3 niceOrigin(") == ["../packages/interaction-query/source/viewgrid.d:1"],
        format("niceOrigin definitions: %s", roster("Vec3 niceOrigin(")));
    // Task 9415 (P1): the pen's first point is the create click; its own
    // anchor rounding, quantum and the temporary re-export are gone. Polarity:
    // before P1 pen.d held niceOrigin 1 / relocateQuantum 1 / placementQuantum 3.
    assert(roster("niceOrigin(") == ["../packages/interaction-query/source/viewgrid.d:2", "../packages/transform-ops/tests/source/tools/transform/relocate_plane_test.d:9"],
        format("niceOrigin( roster: %s", roster("niceOrigin(")));
    assert(roster("relocateQuantum(") == ["../packages/interaction-query/source/viewgrid.d:2", "../packages/transform-ops/tests/source/tools/transform/relocate_plane_test.d:2"],
        format("relocateQuantum( roster: %s", roster("relocateQuantum(")));
    assert((roster("placementQuantum") == [] && roster("clickAnchor") == []) && wave15InputsIntact(wave15Inputs),
        format("the pen's own click anchor returned: %s %s", roster("placementQuantum"),
               roster("clickAnchor")));
    assert(roster("screenToPlacementLocal(").count!(r => r == "tools/create/pen.d:1") == 1,
        format("the pen's first point must be the create click: %s", roster("screenToPlacementLocal(")));
    const rp = blankNonCode(readText(buildPath(repoRoot, "packages/transform-ops/source/tools/transform", "relocate_plane.d")));
    assert((rp.indexOf("public import") < 0) && wave15InputsIntact(wave15Inputs), "relocate_plane re-exports viewgrid names again");
    assert(rp.indexOf("bool orthoRelocateThroughPrior(") >= 0, "control: relocate_plane read");
    assert((rp.indexOf("lockedViewAxis") < 0) && wave15InputsIntact(wave15Inputs),
        "relocate_plane regained a locked-view arm (unreachable from every click)");
    // Task 9476 (K-W3): the perspective relocate is the click law, pinned or
    // not; the unsnapped principal-plane chain is gone, every spelling.
    foreach (n; ["principalPlaneCenter", "posToPrincipalPlane", "workPlanePoint",
                 "RelocatePlanePrefs", "biasedAxis"]) {
        assert((roster(n) == []) && wave15InputsIntact(wave15Inputs), format("the unsnapped relocate chain returned: %s %s",
                                       n, roster(n)));
    }
}
