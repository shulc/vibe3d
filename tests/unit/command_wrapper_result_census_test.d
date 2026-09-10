// Every CommandWrapperTool product owns a VertexPositionResultBuilder
// implementation. This source census forces the subclass, factory, capability
// and retired-collector rosters to move together.
module tests.unit.command_wrapper_result_census_test;

import std.algorithm : count;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies;

import commands.mesh.edge_slide : MeshEdgeSlide;
import commands.mesh.jitter : MeshJitter;
import commands.mesh.vertex_position_result : VertexPositionResultBuilder;
import tools.common.command_wrapper : CommandWrapperTool, XfrmJitterTool,
    XfrmQuantizeTool, XfrmSmoothTool;
import tools.slice.edge_slide : EdgeSlideTool;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private size_t countInSource(string needle) {
    size_t hits;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const code = blankUnittestBodies(blankNonCode(readText(de.name)));
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
        repoRoot, "source", "registration.d"))));
    static foreach (name; ["XfrmSmoothTool", "XfrmJitterTool",
                           "XfrmQuantizeTool", "EdgeSlideTool"]) {
        assert(registration.count("typedToolFactory!" ~ name) == 1 &&
               registration.count("new " ~ name ~ "(") == 1, format(
            "CommandWrapper factory adapter roster changed for %s", name));
    }
    assert(registration.count("typedToolFactory!Xfrm") >= 3,
        "factory census population floor lost the three xfrm wrappers");

    const prepared = blankUnittestBodies(blankNonCode(readText(buildPath(
        repoRoot, "source", "prepared_command_wrapper_activation.d"))));
    assert(prepared.count("target.classinfo is ") == 4,
        "prepared CommandWrapper exact-product roster must contain four types");
    static foreach (name; ["XfrmSmoothTool", "XfrmJitterTool",
                           "XfrmQuantizeTool", "EdgeSlideTool"])
        assert(prepared.count("target.classinfo is " ~ name ~ ".classinfo") == 1,
            "prepared CommandWrapper adapter lost " ~ name);

    size_t sourceFiles;
    foreach (_; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth))
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
