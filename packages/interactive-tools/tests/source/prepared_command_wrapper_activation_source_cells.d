module prepared_command_wrapper_activation_source_cells;

import prepared_command_wrapper_activation;
import core.atomic : atomicOp;
import mesh : Mesh;
import tools.common.command_wrapper : CommandWrapperTool,
    PreparedCommandWrapperActivationImage, XfrmSmoothTool, XfrmJitterTool,
    XfrmQuantizeTool;
import tools.slice.edge_slide : EdgeSlideTool;

unittest {
    import commands.mesh.vertex_position_result : VertexPositionResultBuilder;
    import command_history : CommandHistory;
    import vibe3d.editing.contracts.editmode : EditMode;
    import mesh : makeCube;
    import mesh_gpu : GpuMesh;
    import prepared_record_context : PreparedRecordContext;
    import record_observer_hub : RecordObserverHub;
    import view : View;

    auto mesh = makeCube(); GpuMesh gpu; View view;
    auto tool = new XfrmSmoothTool(&mesh, view, EditMode.Vertices, &gpu);
    auto oldHandle = tool.seedPreparedActivationForTest();
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto effect = tool.prepareActivate(context);
    assert(effect.accepted && context.validate()); context.install();
    assert(tool.preparedActivationInstalledForTest(oldHandle) &&
        context.installTraceForTest() == [34, 8]);

    auto changed = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(changed).accepted);
    mesh.vertices[0].x += 1;
    assert(!changed.validate()); changed.discard();
    mesh.vertices[0].x -= 1;

    oldHandle = tool.seedPreparedActivationForTest();
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); bool threw;
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate() &&
        !tool.preparedActivationInstalledForTest(oldHandle));
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate());
    retry.install(); assert(tool.preparedActivationInstalledForTest(oldHandle));

    auto corrupt = PreparedCommandWrapperActivationOwner.prepare(tool);
    assert(corrupt.begin()); corrupt.corruptPreparedForTest();
    assert(!corrupt.validate()); corrupt.abort(); assert(corrupt.payloadEmpty());
    auto once = PreparedCommandWrapperActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());

    class ForeignWrapper : CommandWrapperTool {
        this(Mesh* source, GpuMesh* target) { meshPtr = source; gpu = target; }
        protected override void onDragDelta(int, int) {}
        protected override float handleSize() const { return 0; }
        protected override VertexPositionResultBuilder resultBuilder() { return null; }
    }
    auto foreign = new ForeignWrapper(&mesh, &gpu);
    auto refused = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(!foreign.prepareActivate(refused).accepted && !refused.validate());
    assert(!tool.prepareActivate(null).accepted &&
        PreparedCommandWrapperActivationOwner.prepare(null) is null);
}
