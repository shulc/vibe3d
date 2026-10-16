// Every CommandWrapperTool product owns a VertexPositionResultBuilder
// implementation. This source census forces the subclass, factory, capability
// and retired-collector rosters to move together.
module tests.unit.command_wrapper_result_census_test;


import tests.unit.census_symbols : exists = wave15Exists;

import std.algorithm : count;
import std.file : SpanMode;
import tests.unit.census_symbols : dirEntries = wave15DirEntries, readText = wave15ReadText;
import std.format : format;
import std.path : buildPath, dirName;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies;

import vibe3d.editing.commands.editor.commands.mesh.edge_slide : MeshEdgeSlide;
import vibe3d.editing.commands.editor.commands.mesh.jitter : MeshJitter;
import vibe3d.editing.commands.editor.commands.mesh.vertex_position_result : VertexPositionResultBuilder;
import vibe3d.editing.tools.interactive.tools.common.command_wrapper : CommandWrapperTool, XfrmJitterTool,
    XfrmQuantizeTool, XfrmSmoothTool;
import vibe3d.editing.tools.interactive.tools.slice.edge_slide : EdgeSlideTool;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private size_t countInSource(string needle) {
    size_t hits;
    foreach (scanSourceRoot; [buildPath(repoRoot, "source"), buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source"), buildPath(repoRoot, "packages/selection-model/source"), buildPath(repoRoot, "packages/scene-query/source"), buildPath(repoRoot, "packages/editor-commands/source")])

    foreach (de; dirEntries(scanSourceRoot, "*.d", SpanMode.depth)) {
        const code = blankUnittestBodies(blankNonCode(readText(de.name)));
        hits += code.count(needle);
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
        const code = blankUnittestBodies(blankNonCode(readText(sourceCarrierPath)));
        hits += code.count(needle);

    }
    return hits;
}

unittest {
    const builderHits = countInSource("VertexPositionResultBuilder");
    assert(builderHits == 16, format(
        "VertexPositionResultBuilder census changed: expected the interface, " ~
        "its Quantize/Smooth/Jitter/EdgeSlide implementations, and " ~
        "CommandWrapperTool's mandatory adapters (16 code hits); found %d",
        builderHits));

    const legacyHits = countInSource("collectLegacyLiveResult");
    assert(legacyHits == 0, format(
        "collectLegacyLiveResult returned to source: expected the retired " ~
        "collector roster to stay empty beside the populated builder census; " ~
        "found %d", legacyHits));

    const wrapper = blankUnittestBodies(blankNonCode(readText(buildPath(repoRoot,
        "source", "tools", "common", "command_wrapper.d"))));
    const diffReads = wrapper.count(
        "auto a = baseline[i], b = meshPtr.vertices[i];");
    const indexAppends = wrapper.count("result.indices ~= cast(uint)i;");
    const beforeAppends = wrapper.count("result.before ~= a;");
    const afterAppends = wrapper.count("result.after ~= b;");
    assert(diffReads == 0 && indexAppends == 0 && beforeAppends == 0 &&
           afterAppends == 0, format(
        "wrapper live-mesh diff collector appeared: expected no " ~
        "reads/indices/before/after collector fragments, found %d/%d/%d/%d",
        diffReads, indexAppends,
        beforeAppends, afterAppends));

    const wrapperSubclassDecls = wrapper.count(": CommandWrapperTool");
    assert(wrapperSubclassDecls == 3, format(
        "in-module CommandWrapperTool subclass roster changed: expected " ~
        "Smooth/Jitter/Quantize, found %d declaration(s)", wrapperSubclassDecls));
    const edgeSlide = readText(buildPath(
        repoRoot, "source", "tools", "slice", "edge_slide.d"));
    assert(edgeSlide.count("final class EdgeSlideTool : CommandWrapperTool") == 1,
        "external CommandWrapperTool subclass roster changed: expected EdgeSlide");

    const registration = blankUnittestBodies(blankNonCode(readText(buildPath(
        repoRoot, "source", "transform_tool_registration.d"))));
    const compositionRoot = blankUnittestBodies(blankNonCode(readText(buildPath(
        repoRoot, "source", "registration.d"))));
    static foreach (name; ["XfrmSmoothTool", "XfrmJitterTool",
                           "XfrmQuantizeTool", "EdgeSlideTool"]) {
        assert(registration.count("typedToolFactory!" ~ name) == 1 &&
               registration.count("new " ~ name ~ "(") == 1, format(
            "CommandWrapper factory adapter roster changed for %s", name));
    }
    assert(registration.count("typedToolFactory!Xfrm") >= 3,
        "factory census population floor lost the three xfrm wrappers");
    static foreach (name; ["XfrmSmoothTool", "XfrmJitterTool",
                           "XfrmQuantizeTool", "EdgeSlideTool"])
        assert(compositionRoot.count("typedToolFactory!" ~ name) == 0
            && compositionRoot.count("new " ~ name ~ "(") == 0,
            "CommandWrapper factory adapter returned to registration.d: " ~ name);

    const prepared = blankUnittestBodies(blankNonCode(readText(buildPath(
        repoRoot, "source", "prepared_command_wrapper_activation.d"))));
    assert(prepared.count("target.classinfo is ") == 4,
        "prepared CommandWrapper exact-product roster must contain four types");
    static foreach (name; ["XfrmSmoothTool", "XfrmJitterTool",
                           "XfrmQuantizeTool", "EdgeSlideTool"])
        assert(prepared.count("target.classinfo is " ~ name ~ ".classinfo") == 1,
            "prepared CommandWrapper adapter lost " ~ name);

    size_t sourceFiles;
    foreach (scanSourceRoot; [buildPath(repoRoot, "source"), buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source"), buildPath(repoRoot, "packages/selection-model/source"), buildPath(repoRoot, "packages/scene-query/source"), buildPath(repoRoot, "packages/editor-commands/source")])

    foreach (_; dirEntries(scanSourceRoot, "*.d", SpanMode.depth))
        ++sourceFiles;
    assert(sourceFiles > 400, format(
        "command-wrapper result census walked only %d source files", sourceFiles));
}

static assert(is(XfrmSmoothTool : CommandWrapperTool));
static assert(is(XfrmJitterTool : CommandWrapperTool));
static assert(is(XfrmQuantizeTool : CommandWrapperTool));
static assert(is(EdgeSlideTool : CommandWrapperTool));
static assert(is(MeshJitter : VertexPositionResultBuilder),
    "Jitter fell back to the legacy live-result client");
static assert(is(MeshEdgeSlide : VertexPositionResultBuilder),
    "EdgeSlide lost the mandatory wrapper result-builder capability");
