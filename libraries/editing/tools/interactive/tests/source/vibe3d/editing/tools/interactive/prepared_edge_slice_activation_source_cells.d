module vibe3d.editing.tools.interactive.prepared_edge_slice_activation_source_cells;

import vibe3d.editing.tools.interactive.prepared_edge_slice_activation;
import core.atomic : atomicOp;
import vibe3d.editing.tools.interactive.tools.slice.edge_slice_tool : EdgeSliceTool, PreparedEdgeSliceActivationImage;

unittest {
    import vibe3d.editing.commands.runtime.command_history : CommandHistory;
    import vibe3d.editing.contracts.editmode : EditMode;
    import vibe3d.mesh.core.mesh : makeCube;
    import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
    import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedActivateKind;
    import vibe3d.editing.commands.runtime.record_observer_hub : RecordObserverHub;
    import vibe3d.viewport.gpu.shader : LitShader;

    auto mesh = makeCube(), oldMesh = makeCube(); GpuMesh gpu;
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeSliceTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest(oldMesh);
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.EdgeSlice &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest(oldMesh));
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(oldMesh) &&
        context.installTraceForTest() == [30,8]);

    tool.seedPreparedActivationForTest(oldMesh);
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedEdgeSliceActivationOwner.abortCountForTest(); bool threw;
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() &&
        tool.preparedActivationDirtyForTest(oldMesh) &&
        PreparedEdgeSliceActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest(oldMesh));
    auto wrong = PreparedEdgeSliceActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest();
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());
    auto once = PreparedEdgeSliceActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    tool.seedPreparedActivationForTest(oldMesh);
    auto aborted = PreparedEdgeSliceActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin() &&
        tool.preparedActivationDirtyForTest(oldMesh));
    assert(!tool.prepareActivate(null).accepted);
    assert(PreparedEdgeSliceActivationOwner.prepare(null) is null);
}
