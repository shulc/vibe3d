module tests.unit.ui.model_preview_wiring_test;

import std.file : readText;
import std.path : buildPath, dirName;
import std.string : indexOf;

private enum root = dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))));
private bool has(string text, string code) { return text.indexOf(code) >= 0; }

unittest {
    auto render = readText(buildPath(root, "source/ui/viewport_render.d"));
    auto bridge = readText(buildPath(root, "source/tools/edit/bridge_tool.d"));
    auto capability = readText(buildPath(root, "source/model_preview.d"));
    assert(has(capability, "cast(ModelPreviewProvider)tool"), "production discovers generic capability");
    assert(has(render, "resolveModelPreview(tool, ModelPreviewView(scene.mesh, gpu.primary))"),
           "production resolves complete primary pair");
    assert(has(render, "auto chosen = primaryRepresentation(scene, gpuInputs, overlays.activeTool);")
        && has(render, "ref Mesh mesh = *chosen.view.mesh;")
        && has(render, "ref GpuMesh gpu = *chosen.view.gpu;"), "every ordinary pass binds chosen pair");
    assert(has(render, "litShader.setSurfaces(mesh.surfaces);")
        && has(render, "litShader.applyPlan(activePlan, surfaceIdForLayer(document.activeIndex()));")
        && has(render, "litShader.useProgram(meshModel, vp);")
        && has(render, "gpu.drawFaces(litShader, facePass);"), "replacement uses ordinary surface/model/plan bracket");
    assert(has(bridge, "ModelPreviewProvider {") && !has(bridge, "drawLitPreview"),
           "Bridge replacement has no second complete-mesh overlay submission");
    assert(has(bridge, "!valid_ || !havePreviewCache || !sessionMeshIntact()"),
           "Bridge display requires valid uploaded cache and frozen source identity");
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
