module tests.unit.ui.model_preview_wiring_test;

import std.file : exists;

import std.file : readText, dirEntries, SpanMode;
import std.algorithm : count, endsWith;
import tests.unit.census_symbols : blankNonCode, symbolTokenHits;
import std.path : buildPath, dirName;
import std.string : indexOf;

private enum root = dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))));
private bool has(string text, string code) { return text.indexOf(code) >= 0; }

unittest {
    auto render = readText(buildPath(root, "source/ui/viewport_render.d"));
    auto bridge = blankNonCode(readText(buildPath(root, "source/tools/edit/bridge_tool.d")));
    auto family = blankNonCode(readText(buildPath(root, "source/tools/create/primitive_create_tool.d")));
    auto box = blankNonCode(readText(buildPath(root, "source/tools/create/box.d")));
    auto capability = blankNonCode(readText(buildPath(root, "source/model_preview.d")));
    assert(has(capability, "tool !is null && tool.modelPreview(candidate)"),
           "production queries final Tool operation");
    size_t files, adopters;
    foreach (scanSourceRoot; [buildPath(root, "source"), buildPath(root, "packages/command-runtime/source"), buildPath(root, "packages/application-core/source"), buildPath(root, "packages/camera-model/source"), buildPath(root, "packages/document-channels/source"), buildPath(root, "packages/image-codec/source"), buildPath(root, "packages/document-io/source"), buildPath(root, "packages/document-model/source"), buildPath(root, "packages/param-schema/source"), buildPath(root, "packages/pipe-runtime/source"), buildPath(root, "packages/mesh-ops/source"), buildPath(root, "packages/interchange/source"), buildPath(root, "packages/interaction-query/source"), buildPath(root, "packages/pipe-evaluation/source"), buildPath(root, "packages/tool-state/source"), buildPath(root, "packages/transform-ops/source"), buildPath(root, "packages/creation-ops/source"), buildPath(root, "packages/alignment-ops/source"), buildPath(root, "packages/input-events/source"), buildPath(root, "packages/display-policy/source"), buildPath(root, "packages/viewport-gpu/source"), buildPath(root, "packages/subpatch-preview/source"), buildPath(root, "packages/edit-contracts/source"), buildPath(root, "packages/mesh-change/source"), buildPath(root, "packages/mesh-contracts/source"), buildPath(root, "packages/mesh-edit-log/source"), buildPath(root, "packages/mesh-edit-replay/source"), buildPath(root, "packages/mesh-snapshot/source"), buildPath(root, "packages/mesh-topology/source"), buildPath(root, "packages/mesh/source"), buildPath(root, "packages/profiling/source"), buildPath(root, "packages/spatial/source"), buildPath(root, "util/log/source"), buildPath(root, "util/math/source"), buildPath(root, "util/parallel/source"), buildPath(root, "util/plane-bytes/source"), buildPath(root, "util/screen-buckets/source"), buildPath(root, "packages/selection-model/source"), buildPath(root, "packages/scene-query/source"), buildPath(root, "packages/editor-commands/source")])

    foreach (entry; dirEntries(scanSourceRoot, SpanMode.depth)) {
        if (!entry.isFile || !entry.name.endsWith(".d")) continue;
        ++files;
        auto code = blankNonCode(readText(entry.name));
        auto bindings = code.count("bindModelPreview(");
        if (entry.name == buildPath(root, "source/tool.d")) {
            assert(bindings == 1, "Tool declares exactly one preview binder");
            continue;
        }
        adopters += bindings;
        if (bindings != 0) {
            string expected;
            if (entry.name == buildPath(root, "source/tools/edit/bridge_tool.d")) expected = "BridgeTool.this";
            if (entry.name == buildPath(root, "source/tools/create/primitive_create_tool.d")) expected = "PrimitiveCreateTool.this";
            if (entry.name == buildPath(root, "source/tools/create/box.d")) expected = "BoxTool.this";
            assert(expected.length != 0 && bindings == 1, "only three production constructor preview binders");
            auto sites = symbolTokenHits(code, entry.name, "bindModelPreview(");
            assert(sites.length == 1 && sites[0].key == expected,
                   "each preview adopter binds once in its constructor");
        }
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

    }
    foreach (sourceCarrier; sourceCarriersWave14_1) {
        const sourceCarrierPath = buildPath(root, sourceCarrier);


        auto code = blankNonCode(readText(sourceCarrierPath));
        auto bindings = code.count("bindModelPreview(");
        if (sourceCarrierPath == buildPath(root, "source/tool.d")) {
            assert(bindings == 1, "Tool declares exactly one preview binder");
            continue;
        }
        adopters += bindings;
        if (bindings != 0) {
            string expected;
            if (sourceCarrierPath == buildPath(root, "source/tools/edit/bridge_tool.d")) expected = "BridgeTool.this";
            if (sourceCarrierPath == buildPath(root, "source/tools/create/primitive_create_tool.d")) expected = "PrimitiveCreateTool.this";
            if (sourceCarrierPath == buildPath(root, "source/tools/create/box.d")) expected = "BoxTool.this";
            assert(expected.length != 0 && bindings == 1, "only three production constructor preview binders");
            auto sites = symbolTokenHits(code, sourceCarrierPath, "bindModelPreview(");
            assert(sites.length == 1 && sites[0].key == expected,
                   "each preview adopter binds once in its constructor");
        }

    }
    assert(files >= 580 && adopters == 3,
           "production preview binder census requires Bridge, primitive family and Box adopters");
    assert(has(bridge, "bindModelPreview(&queryModelPreview);"),
           "Bridge constructor binds current display query");
    assert(has(render, "resolveModelPreview(tool, ModelPreviewView(scene.mesh, gpu.primary))"),
           "production resolves complete primary pair");
    assert(has(render, "auto chosen = primaryRepresentation(scene, gpuInputs, overlays.activeTool);")
        && has(render, "ref Mesh mesh = *chosen.view.mesh;")
        && has(render, "ref GpuMesh gpu = *chosen.view.gpu;"), "every ordinary pass binds chosen pair");
    assert(has(render, "litShader.setSurfaces(mesh.surfaces);")
        && has(render, "litShader.applyPlan(activePlan, surfaceIdForLayer(document.activeIndex()));")
        && has(render, "litShader.useProgram(meshModel, vp);")
        && has(render, "gpu.drawFaces(litShader, facePass);"), "replacement uses ordinary surface/model/plan bracket");
    assert(has(bridge, "private final bool queryModelPreview(") && !has(bridge, "drawLitPreview"),
           "Bridge replacement has no second complete-mesh overlay submission");
    assert(has(bridge, "!valid_ || !havePreviewCache || !sessionMeshIntact()"),
           "Bridge display requires valid uploaded cache and frozen source identity");
    foreach (code; [family, box]) {
        assert(has(code, "bindModelPreview(&queryModelPreview);") &&
               has(code, "private final bool queryModelPreview(") && !has(code, "drawLitPreview"),
               "primitive complete model uses final binding without mesh overlay submission");
        auto begin = code.indexOf("void rebuildPreview()");
        if (begin < 0) begin = code.indexOf("private void rebuildModelPreview(bool base)");
        assert(begin >= 0, "both adapters have a single candidate rebuild seam");
        auto body = code[begin .. $];
        auto invalidate = body.indexOf("previewUploaded_ = false;");
        auto restore = body.indexOf("receipt.restore(previewMesh);");
        auto upload = body.indexOf("previewGpu.upload(previewMesh);");
        auto snapshot = body.indexOf("previewSource_ = receipt;");
        auto pointer = body.indexOf("previewSourceMesh_ = source;");
        auto publish = body.indexOf("previewUploaded_ = true;");
        assert(invalidate >= 0 && restore > invalidate && upload > restore &&
               snapshot > upload && pointer > snapshot && publish > pointer,
               "production invalidates before mutation and publishes exact receipt only after successful upload");
    }
    foreach (field; ["Vertex", "Edge", "Face"])
        assert(has(render, "chosen.geometryHover(display.hovered" ~ field ~ ")"),
               "production suppresses each source-index hover slot");
    assert(has(render, "modelPreview_.rebuild(*chosen.view.mesh, scene.subpatchDepth);")
        && has(render, "modelPreviewGpu_.upload(modelPreview_.mesh,")
        && has(render, "modelPreview_.trace.faceOrigin"), "detached limit upload carries cage origins");
    assert(has(render, "if (!haveModelPreviewKey_ || modelPreviewKey_ != key)"),
           "second cell reuses derived upload on equal identity");
}

unittest {
    auto render = readText(buildPath(root, "source/ui/viewport_render.d"));
    auto frame = readText(buildPath(root, "source/frame_runner.d"));
    auto app = readText(buildPath(root, "source/app.d"));
    assert(has(render, "if (!chosen.replacement) retireModelPreview();"),
           "no-preview reconciliation retires derived residency");
    assert(has(render, "if (haveModelPreviewGpu_) modelPreviewGpu_.destroy();")
        && has(render, "modelPreview_.deactivate();")
        && has(render, "modelPreview_.dropTopologyCache();")
        && has(render, "modelPreviewKey_ = ModelPreviewKey.init;"), "retirement drops GL/topology/borrowed identity");
    assert(has(frame, "sceneRenderer_.reconcileModelPreview(tool);"), "FrameRunner forwards preview reconciliation");
    immutable reconcile = app.indexOf("frameRunner.reconcileModelPreview(activeTool);");
    immutable draw = app.indexOf("frameRunner.drawScene(_sceneInputs");
    assert(reconcile >= 0 && draw > reconcile, "production reconciles before dirty-gated cell draws");
    assert(has(render, "void shutdown() { retireModelPreview(); }")
        && has(frame, "sceneRenderer_.shutdown();"), "FrameRunner shutdown releases renderer GL while live");
    assert(has(app, "_sceneInputs.subpatchDepth = subpatchDepth;"), "production supplies authoritative depth");
}
