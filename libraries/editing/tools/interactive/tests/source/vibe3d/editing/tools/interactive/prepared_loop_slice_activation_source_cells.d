module vibe3d.editing.tools.interactive.prepared_loop_slice_activation_source_cells;

import vibe3d.editing.tools.interactive.prepared_loop_slice_activation;
import core.atomic : atomicOp;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.tools.interactive.tools.slice.loop_slice_tool : LoopSliceTool, PreparedLoopSliceActivationImage;

unittest {
    import vibe3d.editing.commands.runtime.command_history : CommandHistory;
    import vibe3d.editing.contracts.editmode : EditMode;
    import vibe3d.mesh.core.mesh : makeCube;
    import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
    import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedActivateKind;
    import vibe3d.editing.commands.runtime.record_observer_hub : RecordObserverHub;
    import vibe3d.viewport.gpu.shader : LitShader;

    Mesh mesh = makeCube(); GpuMesh gpu; EditMode mode = EditMode.Edges;
    auto tool = new LoopSliceTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest();
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.LoopSlice &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest() && context.installTraceForTest() == [31,8]);

    auto freeTool = new LoopSliceTool(() => &mesh, &gpu, &mode, LitShader.init);
    freeTool.seedPreparedActivationFreeForTest();
    auto freeContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(freeTool.prepareActivate(freeContext).accepted && freeContext.validate());
    freeContext.install(); assert(freeTool.preparedActivationFreeForTest());

    auto boundaryTool = new LoopSliceTool(() => &mesh, &gpu, &mode, LitShader.init);
    boundaryTool.seedPreparedActivationBoundaryForTest();
    auto boundaryContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(boundaryTool.prepareActivate(boundaryContext).accepted &&
        boundaryContext.validate());
    boundaryContext.install();
    assert(boundaryTool.preparedActivationBoundaryForTest());

    tool.seedPreparedActivationForTest();
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(tool.prepareActivate(changed).accepted);
    mesh.vertices[0].x += 1; assert(!changed.validate()); changed.discard();
    mesh.vertices[0].x -= 1;
    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new LoopSliceTool(() => selected, &gpu, &mode, LitShader.init);
    switching.seedPreparedActivationForTest();
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(switching.prepareActivate(switched).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    tool.seedPreparedActivationForTest();
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedLoopSliceActivationOwner.abortCountForTest(); bool threw;
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() && tool.preparedActivationDirtyForTest() &&
        PreparedLoopSliceActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());
    auto wrong = PreparedLoopSliceActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest();
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());
    auto once = PreparedLoopSliceActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    tool.seedPreparedActivationForTest();
    auto aborted = PreparedLoopSliceActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin() &&
        tool.preparedActivationDirtyForTest());
    auto missing = new LoopSliceTool(() => null, &gpu, &mode, LitShader.init);
    auto missingContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!missing.prepareActivate(missingContext).accepted &&
        !missingContext.validate() && !tool.prepareActivate(null).accepted);
}
