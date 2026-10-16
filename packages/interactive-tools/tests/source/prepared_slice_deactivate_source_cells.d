module prepared_slice_deactivate_source_cells;

import prepared_slice_deactivate;
import core.atomic : atomicOp;
import document : Layer;
import mesh : Mesh;
import tools.slice.slice_tool : SliceTool, PreparedSliceDeactivateImage;

unittest {
    import command_history : CommandHistory;
    import commands.mesh.session_edit : MeshSessionEdit;
    import vibe3d.editing.contracts.editmode : EditMode;
    import mesh : makeCube;
    import mesh_gpu : GpuMesh;
    import prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedDeactivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;
    import view : View;

    auto layer = new Layer; layer.meshRef() = makeCube();
    GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto tool = new SliceTool(() => &layer.meshRef(), &gpu, &mode,
        LitShader.init);
    tool.seedPreparedDeactivateForTest(layer.meshRef());
    auto history = new CommandHistory(); auto view = new View(0,0,1,1);
    tool.setGestureBindings(history, () => new MeshSessionEdit(
        &layer.meshRef(), view, mode, "test.slice", "Slice"));
    auto context = new PreparedRecordContext(history, new RecordObserverHub());
    auto effect = tool.prepareDeactivate(context, layer);
    assert(effect.resourceAccepted && effect.historyAccepted &&
        effect.kind == PreparedDeactivateKind.Slice && context.validate());
    context.install(); size_t modelDepth, uiDepth;
    history.undoDepthCounts(modelDepth, uiDepth);
    assert(modelDepth == 1 && uiDepth == 0 &&
        tool.preparedDeactivateInstalledForTest() &&
        context.installTraceForTest() == [1,55]);

    auto idleLayer = new Layer; idleLayer.meshRef() = makeCube();
    GpuMesh idleGpu;
    auto idleTool = new SliceTool(() => &idleLayer.meshRef(), &idleGpu, &mode,
        LitShader.init);
    auto idleContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto idle = idleTool.prepareDeactivate(idleContext, idleLayer);
    assert(idle.resourceAccepted && !idle.historyAccepted &&
        idleContext.validate()); idleContext.install();
    assert(idleContext.installTraceForTest() == [8,55]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube();
    GpuMesh staleGpu;
    auto staleTool = new SliceTool(() => &staleLayer.meshRef(), &staleGpu,
        &mode, LitShader.init);
    staleTool.seedPreparedDeactivateForTest(staleLayer.meshRef());
    auto staleContext = new PreparedRecordContext(null, new RecordObserverHub());
    assert(staleTool.prepareDeactivate(staleContext, staleLayer).resourceAccepted);
    staleTool.mutatePreparedDeactivateForTest();
    assert(!staleContext.validate());
}
