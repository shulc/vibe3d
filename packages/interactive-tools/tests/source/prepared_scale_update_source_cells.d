module prepared_scale_update_source_cells;

import prepared_scale_update;
import core.atomic : atomicOp;
import document : Layer;
import vibe3d.editing.contracts.editmode : EditMode;
import mesh : Mesh;
import prepared_record_context : PreparedRecordContext;
import vibe3d.editing.contracts.prepared_tool_effect : PreparedScaleUpdateKind;
import math : Vec3;
import tools.transform.scale : ScaleTool, PreparedScaleUpdateImage,
    PreparedScaleUpdateBranch;

unittest {
    import command_history : CommandHistory;
    import mesh : makeCube;
    import mesh_gpu : GpuMesh;
    import record_observer_hub : RecordObserverHub;

    auto layer = new Layer; layer.meshRef() = makeCube();
    GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto tool = new ScaleTool(() => &layer.meshRef(), &gpu, &mode);
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto direct = PreparedScaleUpdateOwner.prepare(
        tool, layer, false, Vec3(0, 0, 0));
    assert(direct !is null && direct.targetMatchesForTest(), "scale image mismatch immediately after prepare");
    direct.abort(); context.discard();
    context = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    auto effect = tool.prepareUpdate(false, Vec3(0, 0, 0), context, layer);
    assert(effect.accepted);
    assert(effect.kind == PreparedScaleUpdateKind.InactiveNoop);
    assert(context.validate());
    context.install(); context.install();
    assert(context.installTraceForTest() == [8, 57]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube();
    auto staleTool = new ScaleTool(() => &staleLayer.meshRef(), &gpu, &mode);
    auto staleContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(staleTool.prepareUpdate(false, Vec3(0, 0, 0),
        staleContext, staleLayer).accepted);
    staleTool.seedPreparedUpdateProjectionForTest(true, -1, 1, 1);
    assert(!staleContext.validate()); staleContext.discard();
}
