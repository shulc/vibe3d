module prepared_topology_pen_update;

import core.atomic : atomicOp;
import operator : VectorStack;
import prepared_tool_effect : PreparedTopologyPenUpdateKind;
import tools.edit.topology_pen.tool : TopologyPenTool,
    PreparedTopologyPenUpdateImage;

struct PreparedTopologyPenUpdateToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedTopologyPenUpdateToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextTopologyPenUpdateOwner;

final class PreparedTopologyPenUpdateOwner {
private:
    TopologyPenTool target_;
    PreparedTopologyPenUpdateImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedTopologyPenUpdateToken prepared_;
    ValidatedTopologyPenUpdateToken validatedToken_;
public:
    @disable this();
    static PreparedTopologyPenUpdateOwner prepare(TopologyPenTool target,
            ref VectorStack vts) {
        if (target is null || target.classinfo !is TopologyPenTool.classinfo)
            return null;
        auto owner = new PreparedTopologyPenUpdateOwner(target);
        owner.image_ = target.buildPreparedUpdate(vts);
        return owner.image_.valid ? owner : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is TopologyPenTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            !target_.preparedUpdateMatches(image_)) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedUpdate(image_); consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
    PreparedTopologyPenUpdateKind effectKind() const nothrow @nogc {
        if (!image_.valid) return PreparedTopologyPenUpdateKind.None;
        return image_.hasPacket ? PreparedTopologyPenUpdateKind.Packet :
            PreparedTopologyPenUpdateKind.PacketAbsent;
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && target_ is null;
    }
private:
    this(TopologyPenTool target) {
        target_ = target; owner_ = atomicOp!"+="(nextTopologyPenUpdateOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; pending_ = validated_ = false;
        consumed_ = true; prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

version(unittest) unittest {
    import command_history : CommandHistory;
    import prepared_record_context : PreparedRecordContext;
    import record_observer_hub : RecordObserverHub;
    import toolpipe.packets : ConstrainHitPacket, HoverTarget, SubjectPacket;

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
