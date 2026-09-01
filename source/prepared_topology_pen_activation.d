module prepared_topology_pen_activation;

import core.atomic : atomicOp;
import toolpipe.pipeline : ToolPipeContext, g_pipeCtx;
import toolpipe.stage : TaskCode;
import toolpipe.stages.snap : SnapStage, PreparedSnapPushProjection;
import toolpipe.stages.constrain : ConstrainStage,
    PreparedConstrainCompositionProjection;
import tools.edit.topology_pen.tool : TopologyPenTool,
    PreparedTopologyPenActivationImage;

struct PreparedTopologyPenActivationToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedTopologyPenActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextTopologyPenActivationOwner;

final class PreparedTopologyPenActivationOwner {
private:
    TopologyPenTool target_;
    PreparedTopologyPenActivationImage image_;
    ToolPipeContext pipe_;
    SnapStage snap_;
    ConstrainStage constrain_;
    PreparedSnapPushProjection snapProjection_;
    PreparedConstrainCompositionProjection constrainProjection_;
    string snapOwner_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedTopologyPenActivationToken prepared_;
    ValidatedTopologyPenActivationToken validatedToken_;
public:
    @disable this();
    static PreparedTopologyPenActivationOwner prepare(TopologyPenTool target) {
        if (target is null || target.classinfo !is TopologyPenTool.classinfo)
            return null;
        auto result = new PreparedTopologyPenActivationOwner(target);
        result.image_ = target.buildPreparedActivation();
        result.snapOwner_ = target.preparedSnapArmOwner();
        result.pipe_ = g_pipeCtx;
        if (result.pipe_ !is null) {
            result.snap_ = cast(SnapStage)
                result.pipe_.pipeline.findByTask(TaskCode.Snap);
            result.constrain_ = cast(ConstrainStage)
                result.pipe_.pipeline.findByTask(TaskCode.Cons);
            if (result.snap_ !is null)
                result.snapProjection_ = result.snap_.capturePreparedPushProjection();
            if (result.constrain_ !is null)
                result.constrainProjection_ =
                    result.constrain_.capturePreparedCompositionProjection();
        }
        return result.image_.valid ? result : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is TopologyPenTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            !target_.preparedActivationLocalMatches(image_) ||
            target_.preparedSnapArmOwner() != snapOwner_ || g_pipeCtx !is pipe_ ||
            !stageShapeValid()) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedActivation(image_);
        if (snap_ !is null) snap_.installPreparedPushEnabled(snapOwner_, true);
        if (constrain_ !is null && !constrainProjection_.userLocked)
            constrain_.installPreparedPointComposition();
        consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
    version(unittest) void corruptPreparedForTest() nothrow @nogc {
        ++prepared_.generation;
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && target_ is null && pipe_ is null &&
            snap_ is null && constrain_ is null;
    }
private:
    this(TopologyPenTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextTopologyPenActivationOwner, 1UL);
    }
    bool stageShapeValid() nothrow @nogc {
        if (pipe_ is null) return snap_ is null && constrain_ is null;
        if (!pipe_.pipeline.ownsTaskStage(TaskCode.Snap, snap_) ||
            !pipe_.pipeline.ownsTaskStage(TaskCode.Cons, constrain_)) return false;
        if (snap_ !is null &&
            !snap_.matchesPreparedPushProjection(snapProjection_)) return false;
        if (constrain_ !is null &&
            !constrain_.matchesPreparedCompositionProjection(
                constrainProjection_)) return false;
        return true;
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; pipe_ = null; snap_ = null;
        constrain_ = null; snapOwner_ = null;
        pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

version(unittest) unittest {
    import command_history : CommandHistory;
    import popup_state : getStatePath;
    import prepared_record_context : PreparedRecordContext;
    import prepared_tool_effect : PreparedActivateKind;
    import record_observer_hub : RecordObserverHub;
    import toolpipe.packets : ConstrainGeom;

    auto savedPipe = g_pipeCtx; scope(exit) g_pipeCtx = savedPipe;
    auto pipe = new ToolPipeContext();
    auto snap = new SnapStage(); auto cons = new ConstrainStage();
    pipe.pipeline.add(snap); pipe.pipeline.add(cons); g_pipeCtx = pipe;
    snap.pushEnabled("prior", true);
    cons.enabled = false; cons.geom = ConstrainGeom.Screen;
    auto tool = new TopologyPenTool(); tool.seedPreparedActivationForTest();
    auto context = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    auto effect = tool.prepareActivate(context);
    assert(effect.accepted && effect.kind == PreparedActivateKind.TopologyPen);
    assert(context.validate()); context.install(); context.install();
    assert(tool.preparedActivationInstalledForTest() && snap.enabled &&
        snap.hasPushedEnabled("mesh.topoPen") && cons.enabled &&
        cons.geom == ConstrainGeom.Point &&
        getStatePath("snap/enabled") == "true" &&
        getStatePath("constrain/enabled") == "true" &&
        getStatePath("constrain/geometry") == "point" &&
        context.installTraceForTest() == [39,8]);
    snap.popEnabled("mesh.topoPen");
    assert(snap.enabled, "pen push must preserve the overwritten prior enabled value");

    auto lockedPipe = new ToolPipeContext();
    auto lockedSnap = new SnapStage(); auto locked = new ConstrainStage();
    lockedPipe.pipeline.add(lockedSnap); lockedPipe.pipeline.add(locked);
    locked.enabled = false; locked.geom = ConstrainGeom.Vector;
    locked.userLocked = true; g_pipeCtx = lockedPipe;
    auto lockedTool = new TopologyPenTool();
    auto lockedContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(lockedTool.prepareActivate(lockedContext).accepted &&
        lockedContext.validate()); lockedContext.install();
    assert(lockedSnap.enabled && lockedSnap.hasPushedEnabled("mesh.topoPen") &&
        !locked.enabled && locked.geom == ConstrainGeom.Vector && locked.userLocked);

    g_pipeCtx = null;
    auto noPipeTool = new TopologyPenTool(); noPipeTool.seedPreparedActivationForTest();
    auto noPipeContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(noPipeTool.prepareActivate(noPipeContext).accepted &&
        noPipeContext.validate()); noPipeContext.install();
    assert(noPipeTool.preparedActivationInstalledForTest());

    g_pipeCtx = pipe; tool.seedPreparedActivationForTest();
    auto localChanged = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(localChanged).accepted);
    tool.mutatePreparedActivationForTest();
    assert(!localChanged.validate()); localChanged.discard();

    tool.seedPreparedActivationForTest();
    auto stageChanged = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(stageChanged).accepted);
    snap.pushEnabled("mutated", false);
    assert(!stageChanged.validate()); stageChanged.discard();

    snap.popEnabled("mutated"); tool.seedPreparedActivationForTest();
    auto replaced = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(replaced).accepted);
    pipe.pipeline.add(new SnapStage());
    assert(!replaced.validate()); replaced.discard();

    auto freshSnap = cast(SnapStage)pipe.pipeline.findByTask(TaskCode.Snap);
    assert(freshSnap !is null); tool.seedPreparedActivationForTest();
    auto fault = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); bool threw;
    PreparedRecordContext.failAfterResourceBeginForTest(true);
    try tool.prepareActivate(fault); catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBeginForTest(false);
    assert(threw && !fault.validate());
    auto retry = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub());
    assert(tool.prepareActivate(retry).accepted && retry.validate()); retry.discard();

    auto corrupt = PreparedTopologyPenActivationOwner.prepare(tool);
    assert(corrupt.begin()); corrupt.corruptPreparedForTest();
    assert(!corrupt.validate()); corrupt.abort(); assert(corrupt.payloadEmpty());
    auto once = PreparedTopologyPenActivationOwner.prepare(tool);
    assert(once.begin() && once.validate()); once.install();
    assert(once.payloadEmpty() && !once.begin());
    assert(!tool.prepareActivate(null).accepted &&
        PreparedTopologyPenActivationOwner.prepare(null) is null);
}
