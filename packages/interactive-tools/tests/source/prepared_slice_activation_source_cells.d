module prepared_slice_activation_source_cells;

import prepared_slice_activation;
import core.atomic : atomicOp;
import mesh : Mesh;
import tools.slice.slice_tool : SliceTool, PreparedSliceActivationImage;

unittest {
    import command_history : CommandHistory;
    import vibe3d.editing.contracts.editmode : EditMode;
    import mesh : makeCube;
    import mesh_gpu : GpuMesh;
    import prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;

    Mesh mesh = makeCube(); GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto tool = new SliceTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest();
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.Slice &&
        effect.owner == tool.preparedOwnerForTest() &&
        tool.preparedActivationDirtyForTest());
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationForTest(true) &&
        context.installTraceForTest() == [32,8]);

    Mesh emptySelection = makeCube();
    auto emptyTool = new SliceTool(() => &emptySelection, &gpu, &mode, LitShader.init);
    emptyTool.seedPreparedActivationForTest(); emptyTool.clearFaceSelectionForTest();
    auto emptyContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(emptyTool.prepareActivate(emptyContext).accepted && emptyContext.validate());
    emptyContext.install(); assert(emptyTool.preparedActivationForTest(false));

    tool.seedPreparedActivationForTest();
    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(tool.prepareActivate(changed).accepted);
    mesh.vertices[0].x += 1; assert(!changed.validate()); changed.discard();
    mesh.vertices[0].x -= 1;
    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new SliceTool(() => selected, &gpu, &mode, LitShader.init);
    switching.seedPreparedActivationForTest();
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); assert(switching.prepareActivate(switched).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    tool.seedPreparedActivationForTest();
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto aborts = PreparedSliceActivationOwner.abortCountForTest(); bool threw;
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() && tool.preparedActivationDirtyForTest() &&
        PreparedSliceActivationOwner.abortCountForTest() == aborts + 1);
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.discard(); assert(tool.preparedActivationDirtyForTest());
    auto wrong = PreparedSliceActivationOwner.prepare(tool);
    assert(wrong.begin()); wrong.corruptPreparedForTest();
    assert(!wrong.validate()); wrong.abort(); assert(wrong.payloadEmpty());
    auto once = PreparedSliceActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    tool.seedPreparedActivationForTest();
    auto aborted = PreparedSliceActivationOwner.prepare(tool);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin() &&
        tool.preparedActivationDirtyForTest());
    auto missing = new SliceTool(() => null, &gpu, &mode, LitShader.init);
    auto missingContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!missing.prepareActivate(missingContext).accepted &&
        !missingContext.validate() && !tool.prepareActivate(null).accepted);
}
