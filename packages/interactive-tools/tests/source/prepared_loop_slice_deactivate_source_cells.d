module prepared_loop_slice_deactivate_source_cells;

import prepared_loop_slice_deactivate;
import core.atomic : atomicOp;
import vibe3d.documents.model.document : Layer;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;
import tools.slice.loop_slice_tool : LoopSliceTool,
    PreparedLoopSliceDeactivateImage;

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

    EditMode mode = EditMode.Edges;
    auto view = new View(0,0,1,1);

    auto commitLayer = new Layer; commitLayer.meshRef() = makeCube();
    GpuMesh commitGpu; auto history = new CommandHistory();
    auto commitTool = new LoopSliceTool(() => &commitLayer.meshRef(),
        &commitGpu, &mode, LitShader.init);
    commitTool.setGestureBindings(history, () => new MeshSessionEdit(
        &commitLayer.meshRef(), view, mode, "test.loopSlice", "Loop Slice"));
    commitTool.seedPreparedDeactivateForTest(commitLayer.meshRef(), true);
    const commitVersion = commitLayer.meshRef().mutationVersion;
    auto commitContext = new PreparedRecordContext(history,
        new RecordObserverHub());
    auto commitEffect = commitTool.prepareDeactivate(commitContext, commitLayer,
        null);
    assert(commitEffect.resourceAccepted && commitEffect.historyAccepted &&
        commitEffect.kind == PreparedDeactivateKind.LoopSlice &&
        commitLayer.meshRef().mutationVersion == commitVersion &&
        commitContext.validate());
    commitContext.install(); size_t modelDepth, uiDepth;
    history.undoDepthCounts(modelDepth, uiDepth);
    assert(modelDepth == 1 && uiDepth == 0 &&
        commitTool.preparedDeactivateInstalledForTest(
            commitLayer.meshRef(), true) &&
        commitContext.installTraceForTest() == [1,67]);

    auto cancelLayer = new Layer; cancelLayer.meshRef() = makeCube();
    GpuMesh cancelGpu;
    auto cancelTool = new LoopSliceTool(() => &cancelLayer.meshRef(),
        &cancelGpu, &mode, LitShader.init);
    cancelTool.seedPreparedDeactivateForTest(cancelLayer.meshRef(), false);
    const cancelVersion = cancelLayer.meshRef().mutationVersion;
    auto cancelContext = new PreparedRecordContext(null,
        new RecordObserverHub()); cancelContext.setResourceIdentity(7, 11);
    auto cancelEffect = cancelTool.prepareDeactivate(cancelContext, cancelLayer,
        GpuUploadOwner.fakeForTest(&cancelGpu));
    assert(cancelEffect.resourceAccepted && !cancelEffect.historyAccepted &&
        cancelLayer.meshRef().mutationVersion == cancelVersion &&
        cancelContext.validate());
    cancelContext.install();
    assert(cancelTool.preparedDeactivateInstalledForTest(
        cancelLayer.meshRef(), true) &&
        cancelContext.installTraceForTest() == [3,4,2,8,67]);

    auto idleLayer = new Layer; idleLayer.meshRef() = makeCube(); GpuMesh idleGpu;
    auto idleTool = new LoopSliceTool(() => &idleLayer.meshRef(), &idleGpu,
        &mode, LitShader.init);
    auto idleContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto idleEffect = idleTool.prepareDeactivate(idleContext, idleLayer, null);
    assert(idleEffect.resourceAccepted && !idleEffect.historyAccepted &&
        idleContext.validate());
    idleContext.install();
    assert(idleTool.preparedDeactivateInstalledForTest(idleLayer.meshRef(), false) &&
        idleContext.installTraceForTest() == [8,67]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube(); GpuMesh staleGpu;
    auto staleTool = new LoopSliceTool(() => &staleLayer.meshRef(), &staleGpu,
        &mode, LitShader.init);
    staleTool.seedPreparedDeactivateForTest(staleLayer.meshRef(), false);
    auto staleContext = new PreparedRecordContext(null, new RecordObserverHub());
    staleContext.setResourceIdentity(7, 11);
    assert(staleTool.prepareDeactivate(staleContext, staleLayer,
        GpuUploadOwner.fakeForTest(&staleGpu)).resourceAccepted);
    staleTool.mutatePreparedDeactivateForTest();
    assert(!staleContext.validate());
}
