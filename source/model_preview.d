module model_preview;

import mesh : Mesh;
import mesh_gpu : GpuMesh;
import tool : Tool;

/// Borrowed complete primary-item representation; ownership stays with the tool.
struct ModelPreviewView {
    Mesh* mesh;
    GpuMesh* gpu;
}

struct ModelPreviewResolution {
    ModelPreviewView view;
    Tool owner;
    @property bool replacement() const { return owner !is null; }
    int geometryHover(int sourceIndex) const {
        return replacement ? -1 : sourceIndex;
    }
}

ModelPreviewResolution resolveModelPreview(Tool tool, ModelPreviewView source) {
    ModelPreviewView candidate;
    if (tool !is null && tool.modelPreview(candidate)
        && candidate.mesh !is null && candidate.gpu !is null)
        return ModelPreviewResolution(candidate, tool);
    return ModelPreviewResolution(source, null);
}

/// Uploaded identity, rather than snapshot mutation counters, owns derived display.
struct ModelPreviewKey {
    Tool owner;
    Mesh* mesh;
    GpuMesh* gpu;
    ulong uploadVersion;
    int depth;

    static ModelPreviewKey from(ModelPreviewResolution chosen, int depth) {
        assert(chosen.replacement);
        return ModelPreviewKey(chosen.owner, chosen.view.mesh, chosen.view.gpu,
                               chosen.view.gpu.uploadVersion, depth);
    }
}
