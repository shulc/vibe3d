module vibe3d.editing.tools.interactive.prepared_slice_deactivate_source_cells;

import vibe3d.editing.tools.interactive.prepared_slice_deactivate;
import core.atomic : atomicOp;
import vibe3d.documents.model.document : Layer;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.tools.interactive.tools.slice.slice_tool : SliceTool, PreparedSliceDeactivateImage;

unittest {
    import vibe3d.editing.commands.runtime.command_history : CommandHistory;
    import vibe3d.editing.commands.editor.commands.mesh.session_edit : MeshSessionEdit;
    import vibe3d.editing.contracts.editmode : EditMode;
    import vibe3d.mesh.core.mesh : makeCube;
    import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
    import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedDeactivateKind;
    import vibe3d.editing.commands.runtime.record_observer_hub : RecordObserverHub;
    import vibe3d.viewport.gpu.shader : LitShader;
    import vibe3d.viewport.camera.view : View;

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
