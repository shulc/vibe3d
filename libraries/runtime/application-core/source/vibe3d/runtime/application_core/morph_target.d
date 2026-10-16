module vibe3d.runtime.application_core.morph_target;

// Session owns the sole pre-refresh slot and teardown; this adapter registers
// the lower preview owner's reset directly, preserving its function identity
// (task 20262420; doc/application_layers_wave9_model_2026-10-11.md).
public import vibe3d.mesh.preview.morph_preview : morphTargetName, morphTargetKind, hasMorphTarget,
    setMorphTarget, clearMorphTarget, resolveMorphTarget, forgetMorphTargetIfNamed,
    morphPreviewActive, displayPosition, displayVertices;

import vibe3d.runtime.application_core.session_owner : Session;

/// Register the morph module's own reset as the sole task-5720 lifecycle
/// consumer. A second consumer is outside this pilot and is refused loudly.
void registerMorphTargetLifecycle(Session* session) {
    if (session is null)
        throw new Exception("morph lifecycle requires a Session owner");
    if (!session.registerActiveLayerPreRefresh(&clearMorphTarget))
        throw new Exception("active-layer pre-refresh lifecycle is already owned");
}
