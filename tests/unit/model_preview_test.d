module tests.unit.model_preview_test;

import model_preview;
import mesh : Mesh, makeCube;
import mesh_gpu : GpuMesh;
import tools.edit.bridge_tool : BridgeTool;
import editmode : EditMode;
import math : Vec3;
import std.json : JSONType;

private class Provider : ModelPreviewProvider {
    ModelPreviewView view;
    bool ready = true;
    bool modelPreview(out ModelPreviewView candidate) {
        candidate = view;
        return ready;
    }
}

unittest {
    Mesh source, cage;
    GpuMesh sourceGpu, cageGpu;
    auto base = ModelPreviewView(&source, &sourceGpu);
    auto provider = new Provider;
    provider.view = ModelPreviewView(&cage, &cageGpu);
    auto normal = resolveModelPreview(new Object, base);
    assert(!normal.replacement && normal.view == base, "non-provider keeps source pair");
    auto chosen = resolveModelPreview(provider, base);
    assert(chosen.replacement && chosen.view == provider.view,
           "provider replaces both mesh and GPU");
    assert(chosen.geometryHover(17) == -1 && normal.geometryHover(17) == 17,
           "replacement suppresses source-index geometry hover");
    provider.ready = false;
    assert(resolveModelPreview(provider, base).view == base, "absent preview returns source");
    provider.ready = true;
    provider.view.mesh = null;
    assert(!resolveModelPreview(provider, base).replacement, "partial mesh pair refused");
    provider.view = ModelPreviewView(&cage, null);
    assert(!resolveModelPreview(provider, base).replacement, "partial GPU pair refused");
}

unittest {
    Mesh cage, otherCage;
    GpuMesh gpu, otherGpu;
    auto provider = new Provider;
    auto other = new Provider;
    provider.view = ModelPreviewView(&cage, &gpu);
    gpu.uploadVersion = 7;
    auto chosen = resolveModelPreview(provider, ModelPreviewView.init);
    auto key = ModelPreviewKey.from(chosen, 2);
    assert(key == ModelPreviewKey.from(chosen, 2), "same upload and depth is a cache hit across cells");
    gpu.uploadVersion++;
    assert(key != ModelPreviewKey.from(chosen, 2), "new upload at same cage address must rebuild");
    gpu.uploadVersion--;
    assert(key != ModelPreviewKey.from(chosen, 3), "depth change must rebuild");
    other.view = provider.view;
    assert(key != ModelPreviewKey.from(resolveModelPreview(other, ModelPreviewView.init), 2),
           "provider change must rebuild even with the same pair");
    chosen.view.mesh = &otherCage;
    assert(key != ModelPreviewKey.from(chosen, 2), "cage address change must rebuild");
    chosen.view.mesh = &cage;
    otherGpu.uploadVersion = gpu.uploadVersion;
    chosen.view.gpu = &otherGpu;
    assert(key != ModelPreviewKey.from(chosen, 2), "GPU address change must rebuild");
}

unittest {
    Mesh source;
    GpuMesh gpu;
    EditMode mode = EditMode.Polygons;
    foreach (p; [Vec3(-1,-1,-1), Vec3(1,-1,-1), Vec3(1,1,-1), Vec3(-1,1,-1),
                 Vec3(-1,-1,1), Vec3(1,-1,1), Vec3(1,1,1), Vec3(-1,1,1)])
        source.addVertex(p);
    source.addFace([0u,3u,2u,1u]); source.addFace([4u,5u,6u,7u]);
    source.buildLoops(); source.faceMarks.length = 2;
    source.faceSelectionOrder.length = 2;
    source.selectFace(0); source.selectFace(1);
    auto tool = new BridgeTool(() nothrow @nogc => &source, &gpu, null, &mode);
    ModelPreviewView view;
    assert(!tool.modelPreview(view), "Bridge without a cached activation has no preview");
    Mesh* selected;
    auto image = tool.buildPreparedActivation(selected);
    assert(image.selectionValid && image.preview.faces.length == 4,
           "fixture resolves two caps into four bridge walls");
    tool.installPreparedActivation(image);
    assert(tool.toolStateJson()["engaged"].type == JSONType.false_ && tool.modelPreview(view), "standing unengaged Bridge supplies replacement");
    assert(view.mesh !is &source && view.gpu !is &gpu && view.mesh.faces.length == 4,
           "Bridge lends its detached complete result");
    source = Mesh.init;
    assert(!tool.modelPreview(view) && view == ModelPreviewView.init,
           "Bridge stale source identity refuses display without publishing borrowed pointers");

    auto invalid = new BridgeTool(() nothrow @nogc => &source, &gpu, null, &mode);
    auto invalidImage = invalid.buildPreparedActivation(selected);
    assert(!invalidImage.selectionValid, "empty selection is invalid");
    invalid.installPreparedActivation(invalidImage);
    assert(!invalid.modelPreview(view), "invalid Bridge selection keeps normal display");
}
