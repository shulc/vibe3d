module vibe3d.editing.tools.interactive.prepared_edge_extend_deactivate_source_cells;

import vibe3d.editing.tools.interactive.prepared_edge_extend_deactivate;
import core.atomic : atomicOp;
import vibe3d.editing.commands.editor.commands.mesh.session_edit : MeshSessionEdit;
import vibe3d.documents.model.document : Layer;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.tools.interactive.tools.edit.edge_extend : EdgeExtendTool, PreparedEdgeExtendDeactivateImage;

unittest {
    import vibe3d.editing.commands.runtime.command_history : CommandHistory;
    import vibe3d.editing.contracts.editmode : EditMode;
    import vibe3d.mesh.core.mesh : makeCube;
    import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
    import vibe3d.viewport.gpu.mesh_gpu : GpuUploadOwner;
    import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedDeactivateKind;
    import vibe3d.editing.commands.runtime.record_observer_hub : RecordObserverHub;
    import vibe3d.viewport.gpu.shader : LitShader;
    import vibe3d.viewport.camera.view : View;

    EditMode mode = EditMode.Edges; auto view = new View(0,0,1,1);
    auto layer = new Layer; layer.meshRef() = makeCube();
    layer.meshRef().syncSelection(); layer.meshRef().selectEdge(0);
    GpuMesh gpu; auto history = new CommandHistory();
    auto tool = new EdgeExtendTool(() => &layer.meshRef(), &gpu, &mode,
        LitShader.init);
    tool.setGestureBindings(history, () => new MeshSessionEdit(
        &layer.meshRef(), view, mode, "test.edgeExtend", "Edge Extend"));
    tool.seedPreparedDeactivateForTest(layer.meshRef());
    const liveVersion = layer.meshRef().mutationVersion;
    auto context = new PreparedRecordContext(history, new RecordObserverHub());
    context.setResourceIdentity(7, 11);
    auto effect = tool.prepareDeactivate(context, layer,
        GpuUploadOwner.fakeForTest(&gpu));
    assert(effect.resourceAccepted && effect.historyAccepted &&
        effect.kind == PreparedDeactivateKind.EdgeExtend &&
        layer.meshRef().mutationVersion == liveVersion && context.validate());
    context.install(); size_t modelDepth, uiDepth;
    history.undoDepthCounts(modelDepth, uiDepth);
    assert(modelDepth == 1 && uiDepth == 0 &&
        tool.preparedDeactivateInstalledForTest() &&
        context.installTraceForTest() == [3,4,2,1,70]);

    auto idleLayer = new Layer; idleLayer.meshRef() = makeCube(); GpuMesh idleGpu;
    auto idleTool = new EdgeExtendTool(() => &idleLayer.meshRef(), &idleGpu,
        &mode, LitShader.init);
    auto idleContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto idle = idleTool.prepareDeactivate(idleContext, idleLayer, null);
    assert(idle.resourceAccepted && !idle.historyAccepted && idleContext.validate());
    idleContext.install();
    assert(idleTool.preparedDeactivateInstalledForTest() &&
        idleContext.installTraceForTest() == [8,70]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube(); GpuMesh staleGpu;
    auto staleTool = new EdgeExtendTool(() => &staleLayer.meshRef(), &staleGpu,
        &mode, LitShader.init);
    auto staleContext = new PreparedRecordContext(null, new RecordObserverHub());
    assert(staleTool.prepareDeactivate(staleContext, staleLayer, null).resourceAccepted);
    staleTool.mutatePreparedDeactivateForTest();
    assert(!staleContext.validate());
}
