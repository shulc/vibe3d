module prepared_topology_pen_update_source_cells;

import prepared_topology_pen_update;
import core.atomic : atomicOp;
import vibe3d.editing.pipeline.contracts.operator : VectorStack;
import vibe3d.editing.contracts.prepared_tool_effect : PreparedTopologyPenUpdateKind;
import tools.edit.topology_pen.tool : TopologyPenTool,
    PreparedTopologyPenUpdateImage;

unittest {
    import command_history : CommandHistory;
    import prepared_record_context : PreparedRecordContext;
    import record_observer_hub : RecordObserverHub;
    import vibe3d.editing.pipeline.contracts.toolpipe.packets : ConstrainHitPacket, HoverTarget, SubjectPacket;

    auto tool = new TopologyPenTool(); VectorStack empty;
    ConstrainHitPacket initialHit; HoverTarget initialTarget;
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto effect = tool.prepareUpdate(empty, context);
    assert(effect.accepted && effect.kind ==
        PreparedTopologyPenUpdateKind.PacketAbsent && context.validate());
    context.install();
    assert(tool.preparedUpdateForTest(initialHit, initialTarget) &&
        context.installTraceForTest() == [42,8]);

    auto packetTool = new TopologyPenTool(); VectorStack packetStack;
    SubjectPacket subject; ConstrainHitPacket packet; packet.layer = 7;
    packetStack.put(&subject); packetStack.put(&packet);
    auto packetContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto packetEffect = packetTool.prepareUpdate(packetStack, packetContext);
    assert(packetEffect.accepted && packetEffect.kind ==
        PreparedTopologyPenUpdateKind.Packet && packetContext.validate());
    packetContext.install();
    assert(packetTool.preparedUpdateForTest(packet, HoverTarget.init) &&
        packetContext.installTraceForTest() == [42,8]);

    auto changed = new TopologyPenTool(); auto changedContext =
        new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    assert(changed.prepareUpdate(empty, changedContext).accepted);
    changed.mutatePreparedUpdateForTest();
    assert(!changedContext.validate()); changedContext.discard();
}
