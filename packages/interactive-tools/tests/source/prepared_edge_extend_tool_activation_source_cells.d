module prepared_edge_extend_tool_activation_source_cells;

import prepared_edge_extend_tool_activation;
import core.atomic : atomicOp;
import mesh : Mesh;
import tools.edit.edge_extend : EdgeExtendTool,
    PreparedEdgeExtendToolActivationImage;
import prepared_xfrm_activation_session : PreparedXfrmActivationSessionOwner;
import prepared_transform_product_activation :
    PreparedTransformProductActivationOwner;

unittest {
    import command_history : CommandHistory;
    import vibe3d.editing.contracts.editmode : EditMode;
    import math : Vec3;
    import mesh : makeCube;
    import mesh_gpu : GpuMesh;
    import prepared_record_context : PreparedRecordContext;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
    import shader : LitShader;

    auto mesh = makeCube(); mesh.syncSelection(); mesh.selectEdge(0);
    auto expectedPivot = mesh.selectionBBoxCenterEdges();
    GpuMesh gpu; EditMode mode = EditMode.Edges;
    auto tool = new EdgeExtendTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest();
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.EdgeExtend);
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationInstalledForTest(expectedPivot) &&
        tool.preparedEmbeddedMoveInstalledForTest() &&
        tool.preparedEmbeddedInputsForTest() &&
        context.installTraceForTest() == [37,18,8,19,38]);

    auto offMesh = makeCube(); offMesh.syncSelection(); offMesh.selectEdge(1);
    auto offPivot = offMesh.selectionBBoxCenterEdges();
    auto offTool = new EdgeExtendTool(() => &offMesh, &gpu, &mode, LitShader.init);
    offTool.setPreparedBanksForTest(false, false, false);
    offTool.seedPreparedActivationForTest();
    auto offContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(offTool.prepareActivate(offContext).accepted && offContext.validate());
    offContext.install();
    assert(offTool.preparedActivationInstalledForTest(offPivot) &&
        offTool.preparedEmbeddedMoveInstalledForTest() &&
        offContext.installTraceForTest() == [37,18,8,19,38]);

    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(changed).accepted);
    mesh.vertices[0].x += 1; assert(!changed.validate()); changed.discard();
    mesh.vertices[0].x -= 1;

    auto bankChanged = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(bankChanged).accepted);
    tool.setPreparedBanksForTest(false, false, false);
    assert(!bankChanged.validate()); bankChanged.discard();
    tool.setPreparedBanksForTest(true, false, false);

    Mesh replacement = makeCube(); Mesh* selected = &mesh;
    auto switching = new EdgeExtendTool(() => selected, &gpu, &mode, LitShader.init);
    auto switched = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(switching.prepareActivate(switched).accepted);
    selected = &replacement; assert(!switched.validate()); switched.discard();

    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); bool threw;
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate());
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate()); retry.discard();

    auto corrupt = PreparedEdgeExtendToolActivationOwner.prepare(tool);
    assert(corrupt.beginPre() && corrupt.beginPost());
    corrupt.corruptPreparedForTest(false);
    assert(!corrupt.validatePre()); corrupt.abort(); assert(corrupt.payloadEmpty());
    assert(!tool.prepareActivate(null).accepted &&
        PreparedEdgeExtendToolActivationOwner.prepare(null) is null);
}
