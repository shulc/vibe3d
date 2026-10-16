module prepared_edge_slice_deactivate_source_cells;

import prepared_edge_slice_deactivate;
import core.atomic : atomicOp;
import vibe3d.documents.model.document : Layer;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;
import tools.slice.edge_slice_tool : EdgeSliceTool,
    PreparedEdgeSliceDeactivateImage;

unittest {
    import command_history : CommandHistory;
    import commands.mesh.session_edit : MeshSessionEdit;
    import vibe3d.editing.contracts.editmode : EditMode;
    import vibe3d.mesh.core.mesh : makeCube;
    import mesh_gpu : GpuMesh;
    import mesh_gpu : GpuUploadOwner;
    import prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedDeactivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;
    import vibe3d.viewport.camera.view : View;

    auto layer = new Layer; layer.meshRef() = makeCube();
    GpuMesh gpu; EditMode mode = EditMode.Edges;
    auto history = new CommandHistory(); auto view = new View(0,0,1,1);
    auto tool = new EdgeSliceTool(() => &layer.meshRef(), &gpu, &mode,
        LitShader.init);
    tool.setGestureBindings(history, () => new MeshSessionEdit(
        &layer.meshRef(), view, mode, "test.edgeSlice", "Edge Slice"));
    tool.seedPreparedDeactivateForTest(layer.meshRef());
    const liveVersion = layer.meshRef().mutationVersion;
    auto context = new PreparedRecordContext(history, new RecordObserverHub());
    context.setResourceIdentity(7, 11);
    auto effect = tool.prepareDeactivate(context, layer,
        GpuUploadOwner.fakeForTest(&gpu), null);
    assert(effect.resourceAccepted && effect.historyAccepted &&
        effect.kind == PreparedDeactivateKind.EdgeSlice &&
        layer.meshRef().mutationVersion == liveVersion && context.validate());
    context.install(); size_t modelDepth, uiDepth;
    history.undoDepthCounts(modelDepth, uiDepth);
    assert(modelDepth == 1 && uiDepth == 0 &&
        tool.preparedDeactivateInstalledForTest() &&
        context.installTraceForTest() == [3,4,2,1,65]);

    auto idleLayer = new Layer; idleLayer.meshRef() = makeCube(); GpuMesh idleGpu;
    auto idleTool = new EdgeSliceTool(() => &idleLayer.meshRef(), &idleGpu,
        &mode, LitShader.init);
    auto idleContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto idle = idleTool.prepareDeactivate(idleContext, idleLayer, null, null);
    assert(idle.resourceAccepted && !idle.historyAccepted && idleContext.validate());
    idleContext.install();
    assert(idleTool.preparedDeactivateInstalledForTest() &&
        idleContext.installTraceForTest() == [8,65]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube(); GpuMesh staleGpu;
    auto staleTool = new EdgeSliceTool(() => &staleLayer.meshRef(), &staleGpu,
        &mode, LitShader.init);
    auto staleHistory = new CommandHistory();
    staleTool.setGestureBindings(staleHistory, () => new MeshSessionEdit(
        &staleLayer.meshRef(), view, mode, "test.edgeSlice", "Edge Slice"));
    staleTool.seedPreparedDeactivateForTest(staleLayer.meshRef());
    auto staleContext = new PreparedRecordContext(staleHistory,
        new RecordObserverHub()); staleContext.setResourceIdentity(7, 11);
    assert(staleTool.prepareDeactivate(staleContext, staleLayer,
        GpuUploadOwner.fakeForTest(&staleGpu), null).resourceAccepted);
    staleTool.mutatePreparedDeactivateForTest();
    assert(!staleContext.validate());
}
