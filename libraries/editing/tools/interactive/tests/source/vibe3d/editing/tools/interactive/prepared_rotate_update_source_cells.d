module vibe3d.editing.tools.interactive.prepared_rotate_update_source_cells;

import vibe3d.editing.tools.interactive.prepared_rotate_update;
import core.atomic : atomicOp;
import vibe3d.documents.model.document : Layer;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext;
import vibe3d.editing.contracts.prepared_tool_effect : PreparedRotateUpdateKind;
import vibe3d.util.math.math : Vec3;
import vibe3d.editing.tools.interactive.tools.transform.rotate : RotateTool, PreparedRotateUpdateImage,
    PreparedRotateUpdateBranch;

unittest {
    import vibe3d.editing.commands.runtime.command_history : CommandHistory;
    import vibe3d.mesh.core.mesh : makeCube;
    import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
    import vibe3d.editing.commands.runtime.record_observer_hub : RecordObserverHub;

    auto layer = new Layer; layer.meshRef() = makeCube();
    GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto tool = new RotateTool(() => &layer.meshRef(), &gpu, &mode);
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto direct = PreparedRotateUpdateOwner.prepare(
        tool, layer, false, Vec3(0, 0, 0));
    assert(direct !is null && direct.targetMatchesForTest(), "rotate image mismatch immediately after prepare");
    direct.abort(); context.discard();
    context = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    auto effect = tool.prepareUpdate(false, Vec3(0, 0, 0), context, layer);
    assert(effect.accepted);
    assert(effect.kind == PreparedRotateUpdateKind.InactiveNoop);
    assert(context.validate());
    context.install(); context.install();
    assert(context.installTraceForTest() == [8, 56]);

    auto staleLayer = new Layer; staleLayer.meshRef() = makeCube();
    auto staleTool = new RotateTool(() => &staleLayer.meshRef(), &gpu, &mode);
    auto staleContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(staleTool.prepareUpdate(false, Vec3(0, 0, 0),
        staleContext, staleLayer).accepted);
    staleTool.seedPreparedUpdateProjectionForTest(true, -1, 1, 1);
    assert(!staleContext.validate()); staleContext.discard();
}
