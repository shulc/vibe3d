module prepared_topology_pen_deactivate_source_cells;

import prepared_topology_pen_deactivate;
import core.atomic : atomicOp;
import prepared_record_context : PreparedRecordContext;
import toolpipe.pipeline : ToolPipeContext, g_pipeCtx;
import toolpipe.stage : TaskCode;
import toolpipe.stages.snap : SnapStage, PreparedSnapPushProjection;
import tools.edit.topology_pen.tool : TopologyPenTool,
    PreparedTopologyPenDeactivateImage;

unittest {
    import command_history : CommandHistory;
    import vibe3d.editing.contracts.prepared_tool_effect : PreparedDeactivateKind;
    import record_observer_hub : RecordObserverHub;

    auto savedPipe = g_pipeCtx; scope(exit) g_pipeCtx = savedPipe;
    auto pipe = new ToolPipeContext(); auto snap = new SnapStage();
    pipe.pipeline.add(snap); g_pipeCtx = pipe;
    snap.pushEnabled("prior", false);
    snap.pushEnabled("mesh.topoPen", true);
    auto tool = new TopologyPenTool(); tool.seedPreparedActivationForTest();
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto effect = tool.prepareDeactivate(context);
    assert(effect.historyAccepted && effect.kind == PreparedDeactivateKind.TopologyPen &&
        context.validate());
    context.install(); context.install();
    assert(tool.preparedActivationInstalledForTest() && !snap.enabled &&
        !snap.hasPushedEnabled("mesh.topoPen") &&
        context.installTraceForTest() == [8, 58]);

    tool.seedPreparedActivationForTest();
    auto stale = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareDeactivate(stale).historyAccepted);
    tool.mutatePreparedActivationForTest();
    assert(!stale.validate()); stale.discard();
}
