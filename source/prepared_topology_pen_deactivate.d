module prepared_topology_pen_deactivate;

import core.atomic : atomicOp;
import prepared_record_context : PreparedRecordContext;
import toolpipe.guide : SnapGuide;
import toolpipe.pipeline : ToolPipeContext, g_pipeCtx;
import toolpipe.stage : TaskCode;
import toolpipe.stages.snap : SnapStage, PreparedSnapPushProjection;
import tools.edit.topology_pen.tool : TopologyPenTool,
    PreparedTopologyPenDeactivateImage;

struct PreparedTopologyPenDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedTopologyPenDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextTopologyPenDeactivateOwner;

final class PreparedTopologyPenDeactivateOwner {
private:
    TopologyPenTool target_;
    PreparedTopologyPenDeactivateImage image_;
    ToolPipeContext pipe_;
    SnapStage snap_;
    SnapGuide guide_;
    SnapGuide[] expectedGuides_, nextGuides_;
    PreparedSnapPushProjection snapProjection_;
    string snapOwner_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedTopologyPenDeactivateToken prepared_;
    ValidatedTopologyPenDeactivateToken validatedToken_;
public:
    @disable this();
    static PreparedTopologyPenDeactivateOwner prepare(TopologyPenTool target,
            PreparedRecordContext context) {
        if (target is null || target.classinfo !is TopologyPenTool.classinfo)
            return null;
        auto owner = new PreparedTopologyPenDeactivateOwner(target);
        owner.image_ = target.buildPreparedDeactivate(context);
        if (!owner.image_.valid) return null;
        owner.pipe_ = g_pipeCtx;
        owner.snap_ = target.preparedSnapStageForDeactivate();
        owner.guide_ = target.preparedSnapGuideForDeactivate();
        owner.snapOwner_ = target.preparedSnapArmOwner();
        if (owner.snap_ !is null) {
            owner.snapProjection_ = owner.snap_.capturePreparedPushProjection();
            owner.expectedGuides_ = owner.snap_.guides().dup;
            owner.nextGuides_ = owner.snap_.prepareGuideRemoval(owner.guide_);
        }
        return owner;
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
            !target_.preparedDeactivateLocalMatches(image_) ||
            target_.preparedSnapGuideForDeactivate() !is guide_ ||
            target_.preparedSnapArmOwner() != snapOwner_ || g_pipeCtx !is pipe_ ||
            !snapShapeValid()) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedDeactivate(image_);
        if (snap_ !is null) {
            snap_.installPreparedGuides(nextGuides_);
            snap_.installPreparedPopEnabled(snapOwner_);
        }
        consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
    bool historyPrepared() const nothrow @nogc { return image_.historyPrepared; }
private:
    this(TopologyPenTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextTopologyPenDeactivateOwner, 1UL);
    }
    bool snapShapeValid() nothrow @nogc {
        if (pipe_ is null) return snap_ is null;
        if (!pipe_.pipeline.ownsTaskStage(TaskCode.Snap, snap_)) return false;
        return snap_ is null ||
            (snap_.matchesPreparedPushProjection(snapProjection_) &&
             snap_.matchesPreparedGuides(expectedGuides_));
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; pipe_ = null; snap_ = null; guide_ = null;
        expectedGuides_ = nextGuides_ = null; snapOwner_ = null;
        pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

version(unittest) unittest {
    import command_history : CommandHistory;
    import prepared_tool_effect : PreparedDeactivateKind;
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
