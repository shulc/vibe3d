module model_preview;

import mesh : Mesh;
import mesh_gpu : GpuMesh;

/// Borrowed complete primary-item representation; ownership stays with the tool.
struct ModelPreviewView {
    Mesh* mesh;
    GpuMesh* gpu;
}

interface ModelPreviewProvider {
    bool modelPreview(out ModelPreviewView view);
}

struct ModelPreviewResolution {
    ModelPreviewView view;
    ModelPreviewProvider provider;
    @property bool replacement() const { return provider !is null; }
    int geometryHover(int sourceIndex) const {
        return replacement ? -1 : sourceIndex;
    }
}

ModelPreviewResolution resolveModelPreview(Object tool, ModelPreviewView source) {
    auto provider = cast(ModelPreviewProvider)tool;
    ModelPreviewView candidate;
    if (provider !is null && provider.modelPreview(candidate)
        && candidate.mesh !is null && candidate.gpu !is null)
        return ModelPreviewResolution(candidate, provider);
    return ModelPreviewResolution(source, null);
}

/// Uploaded identity, rather than snapshot mutation counters, owns derived display.
struct ModelPreviewKey {
    ModelPreviewProvider provider;
    Mesh* mesh;
    GpuMesh* gpu;
    ulong uploadVersion;
    int depth;

    static ModelPreviewKey from(ModelPreviewResolution chosen, int depth) {
        assert(chosen.replacement);
        return ModelPreviewKey(chosen.provider, chosen.view.mesh, chosen.view.gpu,
                               chosen.view.gpu.uploadVersion, depth);
    }
}
